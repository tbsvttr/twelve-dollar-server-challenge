# Ruby + io_uring + SQLite B-tree reads

Ok ok, maybe there were some ideas left. This one is at the edge of what I consider the challenge: a
read-only extension seems to be right at the edge of what should work. I saw other entries doing the
same, so I wanted to test this one to see how it behaved.

It's [`ruby-uring-cicloid`](../ruby-uring-cicloid) (scored 130,000), which stays as it was, with one
change: `GET /feed` and `GET /posts/:id` no longer run SQL. A small C extension, `ext/lite.c`, walks
SQLite's own B-tree cursors and writes those two documents. Everything else is the same Ruby server:
the io_uring connection layer and its epoll fallback, the HTTP parser, JWT verification, the writes
and group commit.

| | |
|---|---|
| Language | Ruby 4.0.7 with YJIT, built from source with jemalloc and `-march=native` |
| Framework | [async](https://github.com/socketry/async) 2.46.0 reactor on io-event 1.22.1; our own HTTP/1.1 layer (`http.rb`) over io_uring direct descriptors (`uring_server.rb`, `uring.rb`), with an epoll fallback (`epoll_server.rb`, `epoll.rb`) |
| SQLite driver | `ext/lite.c`, our own extension, with the SQLite 3.54.0 amalgamation compiled in unmodified, profile-guided on the server's own workload |
| Reads | `GET /feed` and `GET /posts/:id` rendered in `ext/lite.c` from SQLite's B-tree cursor API (allowed per Arjay's 2026-10-31 ruling in LEADERBOARD.md) |
| Writes | SQL, as before: `INSERT ... RETURNING json_object(...)`, group commit |
| JWT | HMAC-SHA256 from libsodium 1.0.22, called through rbnacl 7.1.2's FFI bindings |
| JSON | read documents written by `ext/lite.c`; write documents by SQLite (`json_object`); json 3.1.0 parses request bodies and JWT claims |
| **Nginx or direct** | **Direct**: serves `0.0.0.0:80` itself |

Ruby, SQLite and libsodium are downloaded at pinned versions and checked against their SHA-256 sums.
Every gem, transitive ones included, is pinned with checksums in `Gemfile.lock`.

## Running it

```bash
sudo bash install.sh   # apt build deps, then Ruby, libsodium and the SQLite amalgamation (~10 min on 1 vCPU)
bash build.sh          # gems into vendor/bundle, then ext/lite.so, profile-guided (~3 min)
SQLITE_PATH=... JWT_SECRET=... HOST=0.0.0.0 PORT=80 bash start.sh
```

The connection layer, its requirements and its settings (`CONNECTIONS`, `URING_RINGS`) are as in
[`ruby-uring-cicloid`](../ruby-uring-cicloid#connection-layer-io_uring-with-an-automatic-epoll-fallback),
with three differences:

- `URING_RINGS` defaults to 4: room for 262,140 connections. With two rings the server stopped
  accepting at 131,070, which is where the first score (126,000) stopped.
- Ruby reads and writes the rings in place. liburing still sets each ring up and enters the kernel,
  but `uring.rb` writes submission entries straight into the ring's shared memory and reads
  completions from it, with no FFI call or `FFI::Pointer` per entry. Each entry is written field by
  field as liburing's `io_uring_prep_*` helpers write it; we compared them byte for byte.
- Receive buffers live in a buffer ring (`IORING_REGISTER_PBUF_RING`). A buffer goes back to the
  kernel as one ring entry and a tail store, once its bytes are copied out, with no submission.
  Ubuntu's 6.8.0-136+ kernels refuse the registration unless a reserved field is set (Launchpad
  #2162843), so a refusal is retried with it, as the PyPy entry does.

The HTTP parser checks the request line, the method and `/feed` byte by byte with `getbyte`, and a
`GET` without any of the four headers the API reads skips the case-insensitive header scan. Both
used to be regex matches.

## What the extension does, and what it doesn't

`ext/lite.c` includes `sqlite3.c` with `SQLITE_PRIVATE` defined empty, so SQLite's internal B-tree
functions (`sqlite3BtreeCursor`, `sqlite3BtreeTableMoveto`, `sqlite3BtreeIndexMoveto`,
`sqlite3BtreeNext`, `sqlite3BtreePayloadFetch`, ...) are visible to it. The SQLite source is not
patched. The extension provides:

- **A minimal SQL binding** (`Lite::DB`, `Lite::Stmt`): open, exec, prepare, bind, step, column. It
  replaces extralite; the writes, the health check and checkpoints use it exactly as before.
- **Cursors** (`Lite::Cursor`) on the four B-trees the reads need: `posts`, `users`,
  `likes_post_id_idx` and `posts_created_at_id_idx`. Ruby opens and closes them.
- **`Lite.feed` and `Lite.post`**, which walk those cursors and write the response bytes:
  - the feed takes the first 20 entries of `posts_created_at_id_idx` (newest first), counts likes for
    all 20 posts in one walk of `likes_post_id_idx`, then seeks each post and its author by rowid;
  - a single post is one seek in `posts`, a walk of its likes and one seek in `users`.

  Records are decoded per [SQLite's record format](https://sqlite.org/fileformat.html#record_format),
  and strings are escaped as `json_object` escapes them: both documents are byte-for-byte what the
  SQL statements returned, which we checked on the seed and on a database after a load run (bodies
  with quotes, backslashes, newlines and tabs included).

Every page still comes through SQLite's pager, WAL and page cache, inside a SQLite transaction; only
the SQL compiler and the bytecode engine are skipped. What stays in Ruby: routing, JWT verification,
body parsing and validation, the writes and group commit, the HTTP layer and the connection layer,
and `reads.rb`, which decides which transaction the cursors read in:

- **Outside a write batch** they read in their own read transaction (`sqlite3BtreeBeginTrans`), which
  stays open across requests until the store runs SQL (a batch, a checkpoint, the health check) and
  closes it first. All writes go through the same connection, so a read never misses a committed
  write.
- **Inside a write batch** they read in the batch's write transaction, so they see its rows, and the
  response waits for the COMMIT like every read in a batch did before. The cursors close before the
  COMMIT.

If a record isn't shaped the way the schema says (an unexpected serial type, a record on overflow
pages), the extension raises `Lite::Fallback` and the store answers with the old SQL statement. The
first fallback is logged, because the answer is still correct and nothing else would show it.

## Why rendering moved into C

We started with only the cursors in C and everything else in Ruby: record decoding, counting, and
the JSON built as hashes for `JSON.generate`, the way the PyPy entry does it in Python. It worked
(42/42) and SQLite's share of the CPU fell from 20.5% to 8.5%, but at saturation it was a wash:
136.2 µs per request against 136.6 for `ruby-uring-cicloid`. Ruby (VM, JIT code, allocation, GC and
the JSON generator) went from 17% to 30% and ate the whole saving: about five objects per post, 100
per feed, against one string from SQLite. PyPy's tracing JIT removes most of those temporaries; YJIT
doesn't.

With the rendering in C as well, the reads cost (on the test VM, warm, transaction held):

| | SQL (`json_object`) | B-tree, rendered in Ruby | B-tree, rendered in C |
|---|---:|---:|---:|
| `GET /feed` | 50–70 µs | 60 µs | 17–25 µs |
| `GET /posts/:id` | 6.5 µs | 2.6–3.7 µs | 1.7–1.8 µs |

Two things we found on the way:

- **Index entries come in two shapes.** In `posts_created_at_id_idx`, the seed's entries hold
  `(created_at, id)`; entries for posts the server inserts also carry the rowid (the same id) after
  it. A decoder that accepts only the seed's shape falls back to SQL on every feed once the load test
  has written a post, and the tests can't tell. Ours reads both.
- **Reads during a batch matter.** At saturation about a third of feeds arrive while a write batch is
  open. Sending those to SQL left most of the gain on the table, so the cursors read inside the
  batch's transaction too.

## Results on a 1-vCPU test VM

These ran on our Proxmox VM (1 vCPU, 2 GB, Ubuntu 24.04, kernel 6.8, descriptor limit 65,535), with
load from `mload` (`bench/mload` in million-users-challenge) on two load VMs, results merged.

**Saturation, paired** (2,000 users with no think time, 2-minute hold, builds alternated in the same
session; CPU per request is the server's `utime+stime` over the run divided by requests):

| Build | Round 1 | Round 2 | req/s | p95 |
|---|---:|---:|---:|---:|
| `ruby-uring-cicloid` | 132.5 µs | 132.7 µs | ~7,600 | 460 ms |
| B-tree, rendered in C | 115.6 µs | 115.6 µs | ~8,630 | 397 ms |
| `ruby-uring-cicloid` (second session) | 134.1 µs | 134.5 µs | ~7,500 | 465 ms |
| B-tree, rendered in C, profile-guided (this build) | 112.7 µs | 114.2 µs | ~8,820 | 393 ms |

About 15% less CPU per request than `ruby-uring-cicloid`, and 18% more throughput at saturation. The
test VM ran about 1.7× slower per request than in October (the Proxmox host was busy and the guest
showed heavy steal time), so compare the rows with each other, not with `ruby-uring-cicloid`'s
README.

**Ring access and parser, paired** (the same VM with a full core, 4 rings, 120,000 `mload` users
with 1 s think time on three load VMs, 3-minute hold, builds alternated within a session; every run
saturated the core, so CPU per request is what changes; no run had errors):

| Session | Build | Round 1 | Round 2 |
|---|---|---:|---:|
| 1 | as scored in #300 | 84.1 µs | 84.1 µs |
| 1 | rings in place, classic provided buffers | 82.0 µs | 82.7 µs |
| 2 | rings in place, buffer ring | 83.2 µs | 82.6 µs |
| 2 | rings in place, buffer ring, parser (this build) | 81.6 µs | 81.9 µs |

Session 2 ran slower overall; a third session put the two buffer schemes within 0.1 µs of each
other. Together, about 3% less CPU per request than #300. A profile at 120,000 users puts about 60% of the CPU in the
kernel's TCP stack and virtio, 10% in SQLite and 27% in Ruby; the Async reactor itself is under 1%.

Test suite: 42/42, on io_uring and on the epoll fallback.

## Trade-offs

- The read path is C. Ruby still routes every request and does everything else, but the two
  endpoints that are about 90% of the load test's requests are rendered by the extension.
- `ext/lite.c` depends on SQLite internals (`SQLITE_PRIVATE` functions and struct layouts such as
  `KeyInfo` and `UnpackedRecord`), which can change between SQLite versions; the amalgamation is
  pinned for that reason.
- The decoder knows this schema: column order and types, and the two indexes. A schema change needs
  a code change; until then, anything unexpected falls back to SQL.
- The rest is as in [`ruby-uring-cicloid`](../ruby-uring-cicloid#trade-offs): Linux only, two
  connection layers, no idle timeout, peak RSS around 300 MB.

## License

MIT, under the repo's [license](../../LICENSE).
