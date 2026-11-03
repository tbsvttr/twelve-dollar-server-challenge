# WebAssembly, hand-written (WAT) / WasmEdge AOT / SQLite

Direct HTTP/1.1 on `$HOST:$PORT` (no Nginx). The server is written by hand in WebAssembly's text format,
compiled ahead of time to native code by WasmEdge, and run by a small C embedder.

## What is WAT and what is C

| File | Language | What it does |
|---|---|---|
| `src/app.wat` | WAT, hand-written | Everything a request touches: the io_uring event loop (it writes every submission entry and reads every completion itself), HTTP/1.1 parsing, routing, JSON reading and writing, base64url, SHA-256 and HMAC for the HS256 JWT check, SQL statement calls, group commit, when to checkpoint the WAL, and the B-tree read paths (record decoding, which cursors to open and seek) |
| `src/host.c` | C, ~200 lines | WasmEdge embedder: loads the AOT-compiled module, gives it WASI (used only by SQLite for file I/O, env vars and the clock) and five Linux imports: `listen`; `ring_new` (sets up an io_uring and its fixed-file table); `ring_pbuf` (registers a provided-buffer ring that lives in wasm memory); `ring_go` (copies the SQEs the WAT wrote into the ring, calls `io_uring_enter`, copies the completions back); and `membase` (the native address of wasm memory, which the kernel needs for buffer addresses). It also starts one thread that calls `fdatasync` on the WAL file every 100 ms (below). There is no request logic in it |
| `src/sqlite_glue.c` | C, ~130 lines | `#include`s the stock SQLite amalgamation and exports what the WAT calls: the public SQL API; one-line wrappers over SQLite's B-tree cursor functions (open, first, next, previous, seek, payload); a WAL hook that records the WAL's size, and a passive `sqlite3_wal_checkpoint_v2`; and a page cache that wraps SQLite's default one (below). All of it is SQLite's public API. When to checkpoint is decided in the WAT |
| SQLite 3.54.1 | C, stock | The amalgamation, unmodified, compiled to wasm with wasi-sdk |
| wasi-libc | C | From wasi-sdk, for SQLite (malloc, file calls) |
| `experiments/` | notes, scripts, C | The worklog of every measured change, and `baseline/cserve.c`, the C reference server used to compare WAT with C compiled to wasm. Not built or run by the entry |

The WAT and SQLite are two wasm modules joined into one with `wasm-merge`; WasmEdge compiles the result
with LLVM (`wasmedge compile --optimize=3`) to a shared object that `host` loads.

## Versions

All pinned by version and sha256, installed by `install.sh` from official release tarballs, or
downloaded by `build.sh`:

- wabt 1.0.39 (`wat2wasm`), wasi-sdk 34 (clang for wasm32-wasip1), binaryen 125 (`wasm-merge`)
- WasmEdge 0.18.1 (AOT compiler and runtime library)
- SQLite 3.54.1 amalgamation
- gcc from Ubuntu 24.04 for `host.c`

## Design

- **One thread, io_uring, direct.** The WAT runs the loop through io_uring, with the host only copying
  submission and completion entries in and out (WASI's `poll_oneoff` would re-register every socket on
  every call). A multishot accept puts each new connection straight into a slot of the ring's
  fixed-file table, so connections never take a process file descriptor: with `LimitNOFILE=65535` the
  server still keeps every user's keep-alive connection, in up to 8 rings of 65,535 slots (320,000
  users tested). All 8 rings are set up at start, while memory is not yet fragmented: Linux 6.8 puts
  each ring in one 512 KiB block of contiguous pages, which a 2 GB box under load may not have, and a
  ring that can't be set up only lowers the cap instead of stopping the server. The accept moves to the
  next ring when one gets near full. Each connection has a
  multishot receive with buffer selection (2,048 x 2 KiB buffers per ring, in wasm memory). Ring 0 is
  the one waited on and holds a multishot poll on each other ring's fd.
- **Responses go out from one buffer.** After COMMIT, every response of the batch is a send straight
  from the batch's output buffer, all submitted in one `io_uring_enter`; with `MSG_DONTWAIT` they
  complete inside that call. A remainder the socket did not take is copied out and sent on its own;
  a send the kernel would retry later is waited for briefly and then cancelled (the connection is
  closed), so the buffer is never reused under a send. One send in flight per connection.
- **SQLite:** WAL, `synchronous=NORMAL`, persistent prepared statements, 64 MiB page cache,
  `temp_store=MEMORY` (WASI has no temp directory). WASI has no shared memory, so the connection runs with
  `locking_mode=EXCLUSIVE` (the WAL index lives in its heap); it is the only connection anyway.
  With no thread or fork in WASI, checkpoints run on the event loop, every 128,000 frames (500 MiB of
  WAL) instead of SQLite's default 1,000, so one comes every ~25 s at 300,000 users.
- **WAL flusher thread.** A checkpoint starts by syncing the WAL, which by then holds up to 500 MiB, and
  the loop waits for it. A thread in `host.c` calls `fdatasync` on the WAL file (through its own
  descriptor) every 100 ms, so that sync finds little left to write. It only makes data durable sooner;
  SQLite still makes every sync it would make anyway. At 280,000 users this halved p95 and p99 (below).
- **Checkpoints are SQLite's own.** `wal_autocheckpoint` is off and a WAL hook records the WAL's size
  after each commit; once it reaches `CKPT_FRAMES` (128,000), the WAT calls
  `sqlite3_wal_checkpoint_v2(PASSIVE)` after the batch's responses are sent, so that batch does not wait
  for it (the loop does: the copy and the syncs run on it). SQLite does every step and every sync itself,
  through its public API only. `CKPT_AUTO=1` uses `sqlite3_wal_autocheckpoint(CKPT_FRAMES)` instead (the
  checkpoint then runs inside the commit). Each checkpoint stops the loop for a time that grows only
  slowly with its size, so fewer, larger ones give a better tail: at 300,000 users p99 went from 410-480 ms
  at 16,000 frames to 143-270 ms at 128,000 (below). The WAL then takes up to ~500 MiB on disk and in the
  page cache; with `MemoryMax=1200M` the server still ran without errors. An earlier build skipped the
  checkpoint's database sync and sent it to io_uring, which meant writing SQLite's internal `nBackfill`;
  that is gone.
- **A page-cache fix in the glue.** perf showed `pcache1Truncate` at 1.2% of the CPU. Each commit calls
  it with the database's size, and about one commit in ten made it walk all 8,192 hash slots (~250 µs).
  The cause is SQLite's `balance_nonroot`, which swaps two pages through a temporary page number, the
  lock-byte page's (262,145 here), and the cache then believes it holds a page that far out. The glue
  installs a page cache (`SQLITE_CONFIG_PCACHE2`) that wraps SQLite's default one, tracks the highest
  page number it holds (not counting that temporary one) and skips a truncate that is past it. Public
  API only; SQLite's source and internals are untouched. With the first version of this fix, which set
  the default cache's internal mark directly, `pcache1Truncate` showed 0.00% in the same profile.
- **Group commit.** One transaction per batch of completions: BEGIN after the wait, every request of
  the batch, then COMMIT, and only then are the responses sent. A transaction that has written stays
  open for up to 2 ms across waits to take in more writes; one that has only read commits at the end of
  its batch. If COMMIT fails, the batch's connections are closed unanswered, so no 201 is ever sent for
  a row that isn't committed. A generation counter per slot, carried in each entry's `user_data`, makes
  sure a held response or a late completion never reaches a new connection in the same slot.
- **Reads on SQLite's B-tree layer.** `/feed` and `GET /posts/:id` skip SQL's bytecode engine: the WAT
  opens cursors on `posts`, `users`, `posts_created_at_id_idx` and `likes_post_id_idx` (root pages read
  from `sqlite_schema` at start), seeks them, decodes the records itself, and counts likes with an index
  range scan. Same pager, page cache, WAL and locks; the schema cookie is checked in every transaction,
  and anything unexpected (a non-UTF-8 database, overflow pages, a changed schema) falls back to the SQL
  statements, which are always prepared. `POST /posts` and likes use SQL.
- **JSON** is written straight into the output buffer; string escaping checks 16 bytes at a time (SIMD).
  Short copies use plain loads and stores, because WasmEdge's AOT code turns each `memory.copy` into a
  call into the runtime (a lock, a bounds check and a memmove).
- **JWT:** HS256 verified on every request (SHA-256 and HMAC in WAT), `exp` checked; nothing is cached.

## Measured

**Scorer-like load, Synteq.** A rented 8 vCPU box with the grader droplet's CPU (Xeon Platinum 8260) and
kernel (6.8.0). The server runs alone on CPU 0 in a scope with `MemoryMax=2G`, with `LimitNOFILE=65535`;
the load generator (`ul`, C, the `bench/load.js` user loop with its real think times, one keep-alive
connection per user, 32 source addresses) runs on CPUs 1-7. 60 s ramp, then the measured window.
`experiments/worklog.md` has every run, including the changes that didn't help.

5-minute holds with SQLite's own checkpoint every 128,000 frames (this commit): at 300,000 users,
31.7k req/s, p50 2.1 ms, **p95 82 ms, p99 330 ms, 0 errors**, max 1.1 s, 91% of the CPU (28.8 µs per
request), 1,210 MB peak (cgroup, page cache included); two earlier holds of the same setting gave p95 63
and 46 ms / p99 325 and 305 ms, against p95 141 and 152 / p99 425 and 460 every 64,000 frames. At 320,000
users: 33.6k req/s, p95 315 ms, p99 1,005 ms (just over the limit), 0 errors, 95% CPU, so 320,000 is
still this box's edge, as it was with the earlier deferred database sync (p99 455-1,165 ms there over
five holds). 330,000 and 340,000 users fail on CPU (97-98%).

2-minute runs, 3 interleaved reps each:

| server | users | p95 (ms) | p99 (ms) | CPU per request |
|---|---|---|---|---|
| io_uring loop, no WAL flusher | 280,000 | 325, 385, 425 | 620, 735, 800 | 27.7-27.9 µs |
| + WAL flusher | 280,000 | 196, 138, 184 | 465, 285, 390 | 28.7-28.9 µs |
| + WAL flusher | 300,000 | 280, 230, 265 | 560, 440, 520 | 27.3-28.0 µs |
| + database sync through io_uring | 300,000 | 134, 127, 109 | 345, 310, 250 | 28.5-29.0 µs |
| same, rerun later, paired with the next row | 300,000 | 76, 67, 147 | 210, 155, 420 | 27.3-27.7 µs |
| + page-cache fix | 300,000 | 86, 59, 78 | 215, 132, 176 | 27.1-27.8 µs |
| that build again (E30), paired with the next two rows | 300,000 | 135, 81, 102 | 315, 177, 245 | 27.5-28.5 µs |
| SQLite's own checkpoint, every 16,000 frames | 300,000 | 225, 255, 265 | 430, 505, 510 | 27.8-28.2 µs |
| same, with `wal_autocheckpoint` (`CKPT_AUTO=1`) | 300,000 | 250, 255, 275 | 515, 495, 575 | 27.5-28.1 µs |
| SQLite's own checkpoint, every 64,000 frames | 300,000 | 66, 52, 48 | 230, 210, 193 | 28.1-28.7 µs |
| SQLite's own checkpoint, every 128,000 frames (this commit) | 300,000 | 24, 51, 28 | 181, 270, 143 | 28.3-29.0 µs |
| objc-uring-delneg, for reference (1 run) | 280,000 | 11.2 | 23.4 | 25.5 µs |

At 320,000 users the server is at 91-94% of its one CPU, so CPU per request is the next limit.

The ObjC entry checkpoints from a separate process, so its loop never waits for an fsync; that is most
of the gap in the tail. It uses about 0.9x this entry's CPU per request here.

The build merged in #259 (epoll, one file descriptor per connection) had to close idle keep-alive
connections past ~60,000 users; the io_uring loop keeps all of them.

**CPU per request, opt-box.** The numbers below are older, from opt-box (a 4 vCPU VM whose disk takes
~17 ms per fsync) and the earlier epoll loop; the io_uring loop measures the same there (35.8k, 36.6k,
35.8k req/s, 10.9-11.2 µs per request). The server runs on CPU 0, a load generator on CPUs 1-3, with think
times multiplied by a scale factor.

Throughput with the server held to 40% of one CPU (`systemd-run --scope -p CPUQuota=40%`), 4,000 users
at scale 0.007 (more than any of them can serve), 3 interleaved runs:

| server | req/s | CPU per request | p95 |
|---|---|---|---|
| this entry (WAT) | 35.3k, 35.8k, 35.8k | 11.2-11.3 µs | ~105 ms |
| objc-uring-delneg | 49.5k, 49.7k, 48.7k | 8.1 µs | ~45 ms |
| c-iouring-public | 50.4k, 49.9k, 48.5k | 7.9-8.0 µs | ~46 ms |

So this entry does about 0.72x of either io_uring entry's work per CPU second. Both read `/feed` and
posts through SQLite's B-tree layer the same way, natively (ObjC also with PGO), and their kernel time
per request is close to this entry's. This entry's user time is about 2x theirs: SQLite and the WAT
running as wasm. They also checkpoint the WAL off the event loop (a forked child, a thread). WASI here
has neither, so checkpoints run inline and their fsyncs pause the loop: at ~30k req/s, p95 is ~38 ms
against 1.5-1.9 ms for the two baselines. That is well inside the score's 500 ms.

**WAT vs C compiled to wasm.** With the same epoll loop, the same host and the same SQL statements, the
WAT server and the C reference server compiled to wasm used the same CPU per request (7.9 against
7.7 µs on an older, lower-reading metric, within noise). The C reference as it is (SQL only, each write
its own transaction, no batched host calls) serves 15.3k-15.9k req/s in the test above. The lead over
that build comes from the design; the language made no measurable difference.

How the CPU per request came down (perf task-clock, 4,000 users at scale 0.013, ~30k req/s):

| change | µs per request |
|---|---|
| group commit, one transaction per epoll batch | 21.2 |
| `/feed` and `GET /posts/:id` on the B-tree layer | 15.3 |
| writes held up to 2 ms for more of them | 14.4 |
| SIMD JSON escaping | 13.6 |
| one host call to send a whole batch | 13.2 |
| one host call to wait and receive | 13.0 |
| binaryen `wasm-opt -O3` before AOT | 12.8 |
| `$put` without `memory.copy` | 12.6 |
