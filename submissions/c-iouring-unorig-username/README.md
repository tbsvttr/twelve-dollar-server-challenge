# C + io_uring + SQLite

| | |
|---|---|
| Language | C (GCC 13.3, Ubuntu 24.04's `build-essential`), `-O3 -march=native -flto`, profile-guided, built on the box it runs on |
| Framework | none: one `io_uring` event loop, hand-written HTTP/1.1, JSON and JWT code |
| io_uring | liburing 2.12, built from the release tarball (SHA-256 pinned in `build.sh`) |
| SQLite | 3.54.1, the unmodified official amalgamation (SHA-256 pinned in `build.sh`), one translation unit with the server |
| Other dependencies | none (SHA-256/HMAC, base64url and JSON are in `server.c`) |
| **Nginx or direct** | **Direct**: serves `HOST:PORT` itself (`0.0.0.0:80` on the benchmark box) |

Needs Linux 6.1 or newer with io_uring enabled (Ubuntu 24.04's 6.8 kernel has it on by default).

## Running it

```bash
sudo bash install.sh   # apt: build-essential, curl, ca-certificates, unzip
bash build.sh          # downloads and verifies SQLite and liburing, builds bin/server (about 2 minutes)
SQLITE_PATH=... JWT_SECRET=... HOST=0.0.0.0 PORT=80 bash start.sh
```

## Design

- **One event-loop thread.** The box has one vCPU, so more loops would only add context switches. A
  second thread only runs checkpoints. Every ring is `DEFER_TASKRUN` and `SINGLE_ISSUER`, so a ring's
  completion work runs when the loop enters that ring and never interrupts a pass. Each pass gives
  each extra ring one non-blocking `io_uring_enter`, then waits on ring 0.
- **Wake-ups are batched when busy.** If the last pass handled 4 or more completions, the wait asks for
  ring 0's share of 128 completions (capped at a third of open connections, so a few clients without
  think time never sit out the timer) or 2 ms, whichever comes first; otherwise it wakes on the first
  one. With more than one ring, or while POSTs are held, the wait is always timed, so
  other rings and held writes never depend on a new event on ring 0. Each wake-up then
  carries more requests, so the syscalls, the batch's `COMMIT` and the send submissions are shared by
  more of them. It only delays when responses are sent, never what they contain: every response still
  waits for its batch's commit.
- **Accepted sockets are registered (direct) descriptors, not process descriptors.** Accepts use
  `IORING_FILE_INDEX_ALLOC`, so a client occupies a slot in the ring's registered file table and the
  process descriptor table only holds the listener, the rings and SQLite's files. The kernel caps one
  table at `RLIMIT_NOFILE`, so when a table is full the loop adds another ring (same thread, up to 32)
  and accepts there. With `LimitNOFILE=65535` that is about 2 million clients in one process, instead
  of forking a new worker every 65,535.
- **Eight `SO_REUSEPORT` listeners, single-shot accepts, 64 in flight on each.** A listen queue is
  capped at `net.core.somaxconn` (4,096 on the box), so eight queues hold 32,000 pending connections
  through a ramp. A multishot accept can't be stopped before its table fills, and the accept that finds
  the table full has already taken the connection off the queue, so the kernel can only reset it
  (measured: the client at slot 1,025 got `ECONNRESET`). Single-shot accepts are only issued while a
  table has room. Each listener counts its own: connections are hashed to listeners, and with one
  shared count a listener could end up with none armed while accepts armed on idle listeners never
  completed (measured: a few hundred requests waited out the client's 60 s timeout after a ramp).
- **Multishot receives into provided buffer rings** (2,048 x 1 KB per ring, 2 MB rather than 8 MB: the ring cycles through all of them, so all of them stay resident). A receive stays armed for
  the life of the connection; each chunk arrives in a kernel-picked buffer that goes back to the ring as
  soon as it is parsed. Idle clients hold no buffer. A partial request is copied into a per-connection
  buffer until the rest arrives. If the ring ran dry (`ENOBUFS`) the connection goes on a read queue (below).
- **A transaction per completion batch (group commit).** The first request in a batch that touches the
  database opens the transaction; every read and write in the batch runs inside it, and the batch
  ends with one `COMMIT`. Responses are written into an arena and only handed to `send` SQEs after that
  `COMMIT` returns, so a `201` always means the row is committed (rule 6). If a commit fails, nothing
  from a batch with writes is sent: those connections are closed instead.
- **Sends go through io_uring**, one in flight per connection so responses stay in order (later ones
  queue behind it). Each send owns a copy of its bytes, so the arena is reused immediately and a slow
  reader can never pin it. Short sends resubmit the rest. Closing a connection cancels its pending
  receive (and send, if one is in flight) and closes the slot in one linked chain; generation numbers in
  the completion tags make completions for a reused slot harmless. The cancels name the operations by
  their completion tags, which the kernel looks up in a hash table. Cancelling by descriptor instead
  walks every pending operation on the ring (one receive per open connection): with 20,000 idle
  clients that made each close cost about 300 us of CPU instead of about 20 us.
- **Reads use SQLite's B-tree cursors, not its SQL engine.** `server.c` includes the unmodified
  amalgamation. `/feed` walks `posts_created_at_id_idx` for the 20 newest, counts their likes in one walk
  of `likes_post_id_idx` (reading a leaf's cells directly), fetches the rows in ascending id order so
  consecutive ids are usually one step along a leaf, then looks up each author. `/posts/:id` is the same plan for
  one row. Records are decoded in place. Every request still reads its rows from SQLite while it is
  served (rule 5); what is kept between requests is prepared statements, cursor memory, `KeyInfo` objects
  and root page numbers.
- **SQL is the fallback.** At startup the server checks the columns and sort order of everything it
  decodes; on any difference every read uses the reference SQL. At run time any record it doesn't expect
  (overflow pages, a post without a user, a column of another type, a missing post) sends that request to
  SQL. Writes always use prepared SQL. A like's post check is a B-tree seek.
- **A worker thread copies the log back, and the event loop decides when.** The worker runs at nice 19 on its own connection,
  through the `unix-excl` VFS: the process owns the file, the WAL index lives in its heap, and a transaction takes no file locks.
  The loop asks for a `PASSIVE` pass over an eventfd after 8,192 WAL frames (32 MB) and the outcome comes back on a second
  eventfd as an ordinary ring completion, so the loop never waits for an fsync. A log only restarts once fully copied, which
  steady writes prevent, so if frames arrived during a pass, POSTs stay unread for one more pass, for at most 250 ms (reads go
  on). Past 32,768 frames (a CPU saturated long enough to starve the worker) they wait however long that pass takes. Durability is unchanged: WAL with `synchronous=NORMAL`, and a response
  waits for its `COMMIT`. If a commit fails, nothing from a batch with writes is sent and its connections are closed.
- **Provided-buffer registration retries.** Ubuntu's 6.8.0-136 and later kernels reject a buffer ring whose
  reserved words are zero (Launchpad #2162843), which stops a server from starting at all. It retries once
  with `resv[0] = 1`, which correct kernels never see.
- **Profile-guided build.** `build.sh` first builds an instrumented binary with `train.c` compiled in.
  It creates a synthetic database (20k users, 200k posts, 600k likes; the schema's tables and indexes,
  none of the challenge seed) and serves 300,000 requests in the benchmark mix from memory: parsing,
  JWT checks, queries, writes and commits. The real binary is then compiled with that profile. The
  training binary and database are deleted; `train.c` is not in the final binary.
- **SQLite settings**: WAL, `synchronous=NORMAL`, no `mmap`, a 32 MB page cache (a cached page keeps its
  parsed header and needs no WAL lookup; `mmap` measured 4% more CPU per request), prepared statements built
  once with `SQLITE_PREPARE_PERSISTENT`, `SQLITE_THREADSAFE=2` with unused features left out.
- **No caching** (rule 5): every request runs its queries, and every token's HMAC is computed. The only
  thing computed once is the HMAC key schedule derived from `JWT_SECRET`.
- **Strict input handling** (shared with our epoll entry): a full RFC 8259 JSON validator (duplicate
  keys: last wins, like `JSON.parse`), `\u` escapes and surrogate pairs decoded, invalid UTF-8 rejected
  as malformed JSON, whitespace trimmed with JavaScript's `String.prototype.trim` set, and the
  500-character limit counted in code points. JWTs: HS256 only, constant-time signature compare, `exp`
  and `nbf` checked (`exp` is required).
- **After a stall, reads and answers are bounded.** When the server stops reading, every user with a request in flight
  leaves it in a socket buffer: a 2 s freeze at 300,000 users measured about 250 MB against TCP's 170 MB hard limit. A receive
  that runs out of buffers is not rearmed; its connection goes on a read queue, read by single-shot `MSG_DONTWAIT` receives,
  never more on a ring than it has buffers, and back to a multishot receive once drained. A pass does at most 4,096 of these
  reads and answers 1,024 requests from reads and that list; requests released from other waits, such as held POSTs, aren't counted. What it reads beyond that waits on its connection in a copy the size of the request, on a list, and
  while anything waits the loop doesn't sleep. Requests that have just arrived are answered before that list: the backlog has
  already missed any latency target, and answering it first made the requests behind it miss too (6.2% of all requests over 1 s
  in a freeze test on an earlier build with 2,048 answers, against 5.2% this way). The constants come from a sweep; see below.
- **Hot memory sits on huge pages.** The page cache (one contiguous region instead of a malloc per page,
  through `SQLITE_CONFIG_PAGECACHE`), the receive buffers, the connection tables and the response arena are
  `MADV_HUGEPAGE` regions, which Ubuntu's default THP mode honours. A TLB miss on a VM walks two page tables.
- **Escaping scans eight bytes at a time.** Output strings almost never need escaping, so a SWAR test finds
  that out and they go out in one copy.
- **Send buffers come from a small LIFO pool**, so the next response is written into the buffer used most
  recently, still in cache, rather than wherever `malloc` finds room.
- **Memory is budgeted, because on 2 GB it is the next wall.** Each open connection costs about 4.3 KB of
  kernel memory (measured at 330,000: 3.3 KB unreclaimable slab, 1 KB of dentries and inodes that count as
  reclaimable but stay pinned while the socket is open), so every 100 MB the process keeps is about 23,000
  users. The page cache is 32 MB, the receive pools 2 MB per ring, the send pool at most 512 x 8 KB. WAL
  checkpoints start at 8,192 frames: larger thresholds cost less CPU but keep the WAL in page cache, and
  32,000 frames brought the out-of-memory kill forward from about 350,000 connections to about 330,000.
- **HTTP/1.1 keep-alive** with no idle timeout, pipelining, `Connection: close`, HTTP/1.0 and
  `Expect: 100-continue`. Chunked request bodies aren't supported (they're out of scope).
- **No tuning outside the process** (rule 11): it only raises its own soft descriptor limit to the hard
  limit it was given.

## Measurements on x86

These are from EC2, not the benchmark box, and they are not a prediction of a score there. `m5n.large` (Xeon 8259CL, Cascade
Lake like the benchmark box's 8260), booted with one CPU and 2 GB, kernel 6.8, MTU 1500, a separate load generator, each run on
a fresh database, `MemoryMax=1750M` (the leaderboard says the app is capped at 1,750 MB but not how, so that is an assumption).
Compare only within a table: results shift between instances and sessions.

Commits: the tables and the durability and build figures below are from this entry at `40bf738`, whose `server.c` is the one submitted;
rust-iouring-kensac is at `4298101`, its unmerged #264 (the 310,000 row).

CPU per request, whole box, softirq included, 250,000 users, 3 interleaved rounds, own load generator with k6-shaped requests:

| | us/request | rounds |
|---|---:|---|
| this entry | 17.34 | 17.20, 17.38, 17.44 |
| rust-iouring-kensac #264 | 18.23 | 18.17, 18.38, 18.14 |

Holds with `mload` (`bade685`, think scale 1, 60 s timeout), 60 s ramp, 5 minutes, with a real-time process spinning for 20% of
the CPU to slow the core down. That share is an approximation, not a calibration, though it does put #264's limit where its
scoring comment does. Fail means p99 over 1 s with no errors; OOM means the process was killed:

| Users | this entry | rust-iouring-kensac #264 |
|---|---|---|
| 310,000 | pass, p99 194 ms, WAL 46 MB | pass, p99 170 ms, WAL 49 MB |
| 320,000 | pass (p99 210 ms) and fail (1.06 s), WAL 54, 78 MB | fail twice (7.9, 5.3 s), WAL 151, 131 MB |
| 330,000 | fail twice (6.7, 1.66 s), WAL 121, 78 MB | fail twice (50, 43 s), WAL 46, 94 MB |
| 340,000 | OOM twice, at 190 and 148 s | OOM twice, at 332 and 356 s |

Three freezes (SIGSTOP) at 300,000 users, 3 rounds for 2 s and 2 for 1 s and 4 s, own load generator. Share of all requests over
1 s, and time until under 1% of requests take over 100 ms:

| Freeze | this entry | rust-iouring-kensac #264 | TCP memory peak (limits 113 and 170 MB) |
|---|---|---|---|
| 1 s | 1.73, 1.65%; 2 to 3 s | 2.19, 2.25%; 2 to 4 s | about 125 MB, one run 229 MB |
| 2 s | 4.82, 4.71, 4.69%; 4 to 5 s | 5.88, 5.55, 5.81%; 4 to 7 s | 231 to 251 MB |
| 4 s | 10.16, 10.15%; 5 to 7 s | 10.61, 10.82%; 5 to 9 s | 500 to 514 MB |

The answer and read bounds come from a sweep on an earlier build (`c25f357` plus these bounds) with the same 2 s freezes, 2 rounds each, share over 1 s: 1,024 answers and 4,096
reads 4.72, 4.73%; 1,024 and 8,192 4.61, 4.59%; 1,024 and 2,048 4.71, 5.18%; 2,048 and 4,096 5.80, 4.85%; 3,000 and 4,096 4.94,
5.01%; 3,000 and 8,192 4.94, 4.83%. The differences among the 1,024 rows are within noise.

Known limit: on Linux 6.8 a closed connection's socket, and the client's EOF, can wait until older connections' receives end. Replies carry `Content-Length`, so clients get every reply. Shutting the socket down first gave immediate EOF, but when every client reconnected at 300,000 users (one run each) that build was killed for memory and this one survived, so it isn't kept.

Tried and not kept: moving the program text onto a huge page and static linking (level), 1,024 x 1 KB receive buffers (same CPU,
but p95 over the ramp went from 7 to 118 ms), `mmap` instead of the page cache (4% more CPU), and answering the backlog before new
arrivals. Removing one addition at a time from an earlier build, one run each, so rough: huge pages about 4%, the escaping scan
about 4%, the send pool about 1%.

Without the spinning process, `mload` at 310,000 and 320,000 users held 5 minutes (p99 73 and 130 ms, WAL 53 and 43 MB, one run each);
at 340,000 this box runs out of memory or crawls (p99 43 and 52 s, WAL 58 and 124 MB, 2 runs). With the spinning process and my
load generator, 330,000 failed for both entries (this entry p99 38 s and one OOM; #264 p99 48 and 46 s, 2 runs each). So 330,000
is past what this box holds reliably, whatever the generator.

A build from clean on the same 2 GB box without swap peaks at 315 MB (maximum resident set size) in 1:40. `test/test.sh` passes all
42. `kill -9` under write load, during checkpoints: all 552,425 acknowledged writes present after restart, `integrity_check` ok,
WAL 136 MB.

## Credits

Code adapted from rust-iouring-kensac (`csrc/shim.c`, #248 and #264): `key_info`, `seek_row`, `rootpage`, `layout_is`, `prep` and
the setup of the index seek in `likes_from` follow it closely, including some names. Ideas from the same entry: B-tree cursor
reads, the `unix-excl` VFS, page cache over `mmap`, a low-priority checkpoint thread with write holds, `SO_REUSEPORT` listeners,
`DEFER_TASKRUN` on every ring, and bounded reads and answers after a burst (#264). Checkpoint coordination and the likes count
were rewritten for this entry, and its bounds and answer order were chosen by the sweep above. The `resv[0]` retry is also from
rust-iouring-kensac and from c-iouring-pavlyhalim (#245).

## Earlier measurements (arm64, before the B-tree reads)

Measured in Docker on an Apple-silicon host, native arm64 (Rosetta has no io_uring), server limited to
one CPU, 2 GB RAM, no swap and 65,535 descriptors, load generators in separate containers. Docker's
default seccomp profile blocks the io_uring syscalls, so these containers ran with it off; the
benchmark droplet and CI run on a plain VM. Same session, alternating runs against our epoll entry,
three 15-second runs each (mean):

| wrk | epoll entry | this entry | change |
|---|---:|---:|---:|
| mixed, 64 connections | 88,600 req/s, 11.3 us CPU/req | 115,800 req/s, 8.7 us CPU/req | +31% |
| mixed, 1,024 connections | 87,500 req/s, 11.4 us CPU/req | 98,800 req/s, 10.1 us CPU/req | +13% |
| writes, 256 connections | 57,500 req/s, 17.3 us CPU/req | 69,500 req/s, 13.9 us CPU/req | +21% |

Where it comes from: the io_uring loop alone (no feed change, no PGO) is level with epoll at 64
connections (+1.5%) and 8% behind at 1,024; two thirds of the server's CPU here is the kernel's TCP
work, which is the same either way. The feed range scans take feed-only throughput from about 62k to
88k req/s (15 to 10.5 us CPU per request). PGO adds about 6% on mixed (6% less CPU per request, every
pair). k6 `bench/load.js` with 80,000 users (more than one table holds): 0% failures, p95 1 ms, p99 8 ms,
36% CPU, 170 MB; the epoll entry at the same load: p95 4.3 ms, p99 72 ms, 44% CPU, 143 MB.

Batched wake-ups, same setup, k6 `bench/load.js` with 80,000 users and think times scaled to 0.3
(about 28,000 req/s, the request rate of roughly 260,000 real users), 90-second hold, alternating
runs: 16.2, 16.4 and 16.6 us CPU per request against 20.6, 19.6, 21.5 and 21.7 without (-21%), 46%
CPU instead of 55 to 61%, p95 5 to 10 ms, 0% errors. wrk is unchanged (mixed at 64 and 1,024
connections, writes at 256: within 2%, both directions). 256 completions or 12 ms gave the same
16.5 and 16.7 us, so the shorter wait stays.

Tried and dropped: synchronous
`RESTART` checkpoints in the loop every 4,096 WAL frames (writes -40%, mixed p99 56 to 106 ms against
7 to 9 ms), and capping a batch at 128 responses (within noise).

## License

MIT, under the repo's [license](../../LICENSE).
