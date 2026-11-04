# Rust, no framework: io_uring + SQLite B-tree reads

One thread drives everything: an io_uring event loop, an HTTP/1.1 parser, a JSON reader/writer,
HS256 verification, and SQLite (the pinned, unmodified amalgamation, linked in statically). The
one exception is WAL checkpoints, which a second, low-priority thread runs.

| | |
|---|---|
| Language | Rust 1.94.0 (official standalone tarball, sha256-checked by `install.sh`) |
| Crates | `io-uring` 0.7.15, `libc` 0.2.183, `sha2` 0.10.9, `memchr` 2.8.0, `cc` 1.2.56 (build); pinned in `Cargo.lock` |
| SQLite | 3.54.1 amalgamation, sha256-checked, compiled by `build.rs` with `-O3 -march=native` |
| Nginx or direct | **Direct**: serves `HOST:PORT` itself (`0.0.0.0:80` on the benchmark box) |
| Needs | Linux 6.1+ (io_uring with `DEFER_TASKRUN`, multishot receive, provided-buffer rings). There is no epoll fallback, so it won't start where io_uring is blocked (e.g. Docker's default seccomp profile). Ubuntu's 6.8.0-136+ kernels refuse a buffer-ring registration whose reserved words are zero ([Launchpad #2162843](https://bugs.launchpad.net/ubuntu/+source/linux/+bug/2162843), an inverted check), so a refused registration is retried once with `resv[0]=1` |

## Reads go through SQLite's B-tree, not its SQL engine

`GET /feed` and `GET /posts/:id` read SQLite's own B-tree cursors
(`csrc/shim.c` `#include`s the unmodified amalgamation), inside the pass's SQLite transaction. Rust then
decodes the record bytes SQLite returns and writes the JSON directly. There's no bytecode engine,
no `sqlite3_column_*` calls, and no copying through SQLite values. The amalgamation is
unmodified, writes go through SQL, and there's a SQL fallback.

- **Feed:** walk `posts_created_at_id_idx` from its first entry. The index is
  `(created_at DESC, id DESC)`, so this is exactly `ORDER BY created_at DESC, id DESC`, and its
  records already hold `created_at` and `id`. The 20 posts are then looked up in ascending id
  order. Consecutive ids land on the next cell of the same leaf (SQLite's own `TableMoveto`
  fast path), so no root-to-leaf descent is needed per row. Next come the 20 authors in `users`.
  The like counts take one range walk of `likes_post_id_idx` when the ids fall within 512 of each
  other, and a seek per post otherwise.
- **No assumptions about the data:** the plan doesn't need dense ids, timestamps in id order, or
  any remembered state. If a post has no user row (where the SQL `JOIN` would drop it), the
  reference SQL query answers instead. At startup the server checks the column order of every
  table and index it decodes, and refuses to start on a different schema.
- **Live reads:** every request reads its rows from SQLite while it is served (rule 5).
  Only prepared statements, cursors, KeyInfo objects and the four B-tree root page numbers
  (read from `sqlite_schema` at startup) are reused. The `unix-excl` VFS keeps other processes
  off the file, and the server's second connection only checkpoints, so nothing can change the
  schema while the server runs.
- **Writes use SQL:** `INSERT … RETURNING id, created_at` for posts, `INSERT … ON CONFLICT DO
  NOTHING` for likes. Only `sqlite3_changes` tells a new like from a repeat. The like handler's
  check that the post exists (the 404 case) is a B-tree seek on `posts`, like the reads.

## Durability and batching

- WAL with `synchronous=NORMAL`, opened through SQLite's `unix-excl` VFS: the process takes an
  exclusive lock on the file at the first read and keeps it, so no other process can open it,
  and the WAL index lives in heap memory shared by the process's two connections (no `-shm`
  file, no file locks per transaction).
- Each event-loop pass is one SQLite transaction. Its reads share a snapshot, and its writes are
  group-committed (rule 6). **No response from a pass is handed to the kernel until its COMMIT
  returns.** If a commit fails, every response from that pass is replaced with a 500 and the
  connection is closed, so a 201 never claims a write that didn't land. Reads that see this
  pass's own writes are also held until COMMIT, and become 500s if it fails, so no client ever
  sees a row that wasn't committed. If SQLite rolls the transaction back by itself mid-pass
  (`SQLITE_FULL`, I/O errors), the rest of the pass doesn't write, and its COMMIT reports the
  failure.
- Automatic checkpoints are off. Checkpoints run on a second thread, on its own connection, at
  nice 19, so the event loop never waits for their fsyncs. After a commit leaves 4,096 or more
  WAL frames (16 MB), the loop wakes the thread, which runs a PASSIVE checkpoint while the loop
  goes on reading and writing. A PASSIVE checkpoint never waits on the loop's locks, and the
  loop never waits on the thread.
- Under steady writes that checkpoint can't copy the frames written while it ran, and the log
  only restarts once it is fully copied. So when the thread is done, writes are **held**: the
  next POST on each connection stays unread in that connection's buffer (reads go on), and the
  thread copies the rest. The hold then ends, and the next write restarts the log. A hold starts
  and ends only between passes, never inside one. It lasts at most 250 ms: if the thread is
  slower than that, writes go on and the next round tries again. Past 65,536 frames the loop
  checkpoints by itself, as a last resort.
- Measured in a 1-CPU container (load generator on the same CPU, 200 keep-alive connections,
  ~77k req/s, 30% likes and 5% posts, 20 s): with the old inline checkpoint every request had
  p99 31 ms and max 199 ms. With the thread, reads were at p99 6 ms and max 39 ms, writes at
  p99 43 ms and max 155 ms (holds of 80–95 ms), with the same CPU per request (thread included).
  A `kill -9` during a checkpoint lost none of the 255k acknowledged writes, and
  `integrity_check` was ok.
- Moving the checkpoint off the loop meant dropping `locking_mode=EXCLUSIVE` for `unix-excl`
  (two connections) and building with `THREADSAFE=2`. A transaction is one pass, not one
  request, so the extra cost is per pass. Measured per pass (1 to 40 requests, with and
  without writes), the difference is within noise (±1%).
- No `mmap`: reads go through SQLite's page cache (64 MB). A cached page keeps its parsed
  B-tree header and is found without a WAL-index lookup; an mmap page pays both on every fetch.

## Connections

Every k6 user holds a keep-alive connection, so a high score means hundreds of thousands of
sockets under `LimitNOFILE=65535`.

- Accepted sockets are io_uring **direct descriptors**. They live in a ring's file table, not the
  process fd table. A table can be no larger than `RLIMIT_NOFILE`, so the server raises its soft
  limit to the hard one and gives each ring that many slots.
- It starts with one ring. When a ring is within a margin of full (1/8 of its slots, up to
  1,024), accepting moves to the next ring, adding one if needed (up to 16). Accepting moves
  before the table is actually full because an accept that finds no free slot has already taken
  the connection off the listen queue, and the kernel would drop it. Accepts are single-shot,
  at most 512 in flight (a sixteenth of a small table), always fewer than the margin, so no
  more than that can land after the switch. A ring accepts again once more than twice the
  margin of its slots are free. If a ring can't be added, adding is retried once a second.
- An accept is re-armed only after a pass sees it complete, so the number in flight bounds the
  accept rate. With 64, a ramp of a few thousand new connections a second outran it on a 1 vCPU
  droplet: the listen queue filled and new connections waited out SYN retransmits (1 s, 3 s,
  7 s). 512 keeps up.
- The port has eight `SO_REUSEPORT` listeners, each with an eighth of the accepts. A listen
  queue is capped at `net.core.somaxconn` (4,096 by default), so eight queues hold 32k pending
  connections through a ramp or a slow pass instead of refusing them.
- One thread drives every ring (`SINGLE_ISSUER`, `DEFER_TASKRUN`). Each pass first gives every
  other ring one non-blocking `io_uring_enter` that submits its queued sends and collects its
  completions. Then ring 0 submits and waits for 256 completions or 1 ms, whichever comes
  first. So a pass never spins, and bigger passes share one COMMIT. The wait adds about 1 ms of
  latency on ring 0, and up to about 2 ms on the other rings.
- Under `LimitNOFILE=65535`, every ring preallocates a 65,535-entry table of 48-byte connection
  records (3.1 MB) and 2 MiB of receive buffers: ~6 MB of user space per ring, ~30 MB for five
  rings (300k connections). The table size follows the hard descriptor limit. The pool of
  output buffers adds at most 2,048 × 32 KB. Kernel socket memory (~3.4 KB per connection
  measured) comes on top of all this.
- Each connection has one **multishot receive** into a provided-buffer ring (1,024 × 2 KB per
  ring), so an idle connection holds no receive buffer, and a request costs one completion.
- **After a burst, reads are bounded.** After a stall, every connection has a request waiting,
  and the multishot receives use up the buffer ring at once. The rest end with ENOBUFS. Re-arming
  them all together would only repeat that, pass after pass. So a receive that ends is not
  re-armed. Its connection goes on a first-in, first-out read queue instead. Each pass then
  issues one single-shot receive per queued connection, with `MSG_DONTWAIT`, and never more on a
  ring than it has buffers. The reads are submitted and reaped in the same pass (with
  `DEFER_TASKRUN` they complete inside the non-blocking enter), in rounds while the queue is
  longer than the buffers. A read that fills its buffer is queued again. A shorter read, or
  EAGAIN, means the socket is drained, and the multishot receive is armed again.
- **Drain first.** A pass reads up to 16,384 times but answers at most 2,048 reads. The rest are
  kept on the connection, next to a partial request, and go on a ready list that later passes
  answer first, oldest first. While anything is queued, ring 0 doesn't wait. Reading costs a
  copy the size of the request, while a request left in its socket costs a 3–4 KB socket buffer.
  So the socket queues empty as fast as the reads can run, instead of building up toward TCP's
  memory limit. In a 40k-user run with four 2 s stalls, receives ended with ENOBUFS about once
  per connection per stall (119k in all), where re-arming them all at once had caused 2.15
  million. Half a second after each stall, TCP held ~600 of its ~29k pages, where it had held
  ~20k before.
  [c-iouring-pavlyhalim](../c-iouring-pavlyhalim) (#245) reads this way all the time, from a
  readiness poll. Here that costs ~10% more CPU per request in steady state (a poll completion
  and a read for each request), so it is used only to recover from a burst.
- Output buffers come from a pool and go back once a send completes, so idle connections hold
  no heap memory, only a fixed 48-byte record (its three buffers are null pointers until
  used). One send per connection is in flight at a time. Pipelined responses queue behind it.
- Closing is a `SHUTDOWN` hard-linked to a fixed-file `CLOSE`. The shutdown ends the multishot
  receive or the single-shot read in flight. A generation number in every `user_data` drops completions for a reused slot.
- Idle connections are never closed by the server (Nginx-style 65 s reuse is safe).

## Request path

- **HTTP:** one pass over the head's lines finds the request line, `Authorization` and
  `Content-Length`. A request split across receives is kept per connection until it completes.
  Heads over 16 KB, bodies over 1 MB, chunked bodies and malformed request lines get
  400 `{"error":"bad request"}` and the connection is closed (out of scope in SPEC).
- **JWT:** the HMAC key's inner and outer padded blocks are hashed once at startup. Each
  request hashes only `header.payload` plus the outer block, and compares the result in constant
  time. Every token's signature, `alg` (HS256 only) and `exp` (required) are checked on every
  request. Only the canonical base64url spelling of a signature is accepted.
- **JSON:** a validating reader checks whole request bodies and reports the top-level members,
  allocating only for escaped strings. The last duplicate key wins and escaped member names
  are decoded, as in `JSON.parse`. Escaped strings are decoded once. Output strings are scanned 8 bytes at a time for characters that need escaping,
  and copied in one piece when none do. `Content-Length` is back-filled.
- `body` is trimmed with JavaScript's `trim()` whitespace set and counted in characters (code points,
  the same unit as the schema's `CHECK (length(body) …)`).

## Files

| | |
|---|---|
| `src/main.rs` | rings, accept/receive/send/close, the batch loop |
| `src/app.rs` | routes, handlers, responses |
| `src/db.rs` | record decoding, the feed and post plans, writes (FFI to the shim) |
| `src/http.rs`, `src/json.rs`, `src/jwt.rs` | request framing, JSON, HS256 |
| `csrc/shim.c` | the amalgamation plus B-tree cursor and statement helpers, the checkpoint thread |
| `build.rs` | compiles the shim and SQLite with the options below |

SQLite options (all in `build.rs`): `THREADSAFE=2` (each connection used by one thread), `DEFAULT_MEMSTATUS=0`,
`DEFAULT_WAL_SYNCHRONOUS=1`, `DQS=0`, `LIKE_DOESNT_MATCH_BLOBS`, `MAX_EXPR_DEPTH=0`,
`USE_ALLOCA`, `OMIT_DEPRECATED`, `OMIT_PROGRESS_CALLBACK`, `OMIT_SHARED_CACHE`,
`OMIT_LOAD_EXTENSION`, `OMIT_AUTOINIT`, `OMIT_UTF16`, `OMIT_TRACE`, `OMIT_COMPLETE`,
`OMIT_GET_TABLE`, `OMIT_TCL_VARIABLE`, `HAVE_FDATASYNC`, `HAVE_USLEEP`.

## Run

```bash
sudo bash install.sh
bash build.sh
SQLITE_PATH=/path/to/feed.db JWT_SECRET=twelve-dollar-challenge HOST=0.0.0.0 PORT=80 bash start.sh
```
