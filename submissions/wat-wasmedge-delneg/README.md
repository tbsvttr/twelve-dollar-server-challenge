# WebAssembly, hand-written (WAT) / WasmEdge AOT / SQLite

Direct HTTP/1.1 on `$HOST:$PORT` (no Nginx). The server is written by hand in WebAssembly's text format,
compiled ahead of time to native code by WasmEdge, and run by a small C embedder.

## What is WAT and what is C

| File | Language | What it does |
|---|---|---|
| `src/app.wat` | WAT, hand-written | Everything a request touches: the io_uring event loop (it writes every submission entry and reads every completion itself), HTTP/1.1 parsing, routing, JSON reading and writing, base64url, SHA-256 and HMAC for the HS256 JWT check, SQL statement calls, group commit, parking POSTs during a checkpoint hold, and the B-tree read paths (record decoding, which cursors to open and seek) |
| `src/host.c` | C, ~300 lines | WasmEdge embedder: loads the AOT-compiled module, gives it WASI (used only by SQLite for file I/O, env vars and the clock) and five Linux imports: `listen`; `ring_new` (sets up an io_uring and its fixed-file table); `ring_pbuf` (registers a provided-buffer ring that lives in wasm memory); `ring_go` (copies the SQEs the WAT wrote into the ring, calls `io_uring_enter`, copies the completions back); and `membase` (the native address of wasm memory, which the kernel needs for buffer addresses). It also starts one thread that calls `fdatasync` on the WAL file every 100 ms and a second that runs the checkpointer in its own WasmEdge VM, and gives both instances the shared-memory, atomic and futex imports they need (below). There is no request logic in it |
| `src/sqlite_glue.c` | C, ~150 lines | `#include`s the stock SQLite amalgamation and adds one-line wrappers over SQLite's B-tree cursor functions (open, first, next, previous, seek, payload), which only exist inside SQLite's own translation unit; a small VFS that gives SQLite the shared-memory methods its WASI build lacks; and the checkpoint logic: `ck_tick` on the loop, `ckpt_main` on the checkpointer (below). Everything else the WAT calls directly: SQLite's public API (`build.sh` exports each function `app.wat` imports), and through the exported function table it installs its own WAL hook and page-cache wrapper (below) |
| SQLite 3.54.1 | C, stock | The amalgamation, unmodified, compiled to wasm with wasi-sdk |
| wasi-libc | C | From wasi-sdk, for SQLite (malloc, file calls) |
| `experiments/` | notes, scripts, C | The worklog of every measured change, and `baseline/cserve.c`, the C reference server used to compare WAT with C compiled to wasm. Not built or run by the entry |

The C that stays, and why:

- `host.c` `main`: something has to create the WasmEdge VM, give it WASI and the "sys" module and run
  the AOT code; the `wasmedge` CLI can add host functions only through a plugin, which would be C too. It also raises the soft `RLIMIT_NOFILE` to
  the hard one and ignores SIGPIPE (one line each).
- `listen`, `ring_new`, `ring_pbuf`, `ring_go` and `membase`: WebAssembly has no way to make a Linux call
  or to know where its memory is. The kernel maps an io_uring's rings only at an address it picks: mapping
  them into wasm memory with `MAP_FIXED` fails with EINVAL (we tried; io_uring refuses a caller's address),
  and `IORING_SETUP_NO_MMAP` on Linux 6.8 needs the rings in one physically contiguous block (a huge page).
  So the rings are outside wasm memory, and only C can copy SQEs in and CQEs out; `ring_go` also drains CQ
  overflow. We also tried one generic `syscall` import with the socket and ring registration in the WAT
  (30 lines less C): on our scorer-like harness it cost ~0.7 µs per request and more p99, so it was dropped.
- The WAL thread (`walsync`, with `pincode`): the `fdatasync` every 100 ms has to run beside the event
  loop, and the wasm side runs on a single thread. Pinning runs in the same thread so the loop never waits for it.
- The checkpointer (`ckthread`, the `shm_*` and `ck_*` imports): a checkpoint's fsyncs have to happen off
  the event loop. WASI has no threads and no shared memory, so the host starts the second instance on a
  thread, maps one memfd into both instances' memories and provides the atomics and the futex.
- `sqlite_glue.c`'s B-tree wrappers: they call SQLite's internal B-tree functions, which exist only
  inside SQLite's own translation unit. Its VFS and checkpoint logic use SQLite's public API, as does
  everything else the WAT calls. They are C for convenience, not necessity: a WAT port could cut them, but
  it hasn't been tried.

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
  `temp_store=MEMORY` (WASI has no temp directory). `wal_autocheckpoint` is off and a WAL hook records the
  WAL's size after each commit.
- **Checkpoints on a second wasm instance.** The host runs the same `app.so` a second time on its own
  thread, with its own SQLite connection (`ckpt_main` in `sqlite_glue.c`). WASI SQLite has no shared
  memory, so a small VFS over `unix-none` adds the four `xShm` methods: the wal-index is one memfd mapped
  into both instances' memories, and its locks are atomic words in the host. The loop's connection uses
  `locking_mode=NORMAL`, and every step is SQLite's own `sqlite3_wal_checkpoint_v2(PASSIVE)` through its
  public API.
- **Short write holds finish each round.** At `CKPT_FRAMES` (8,000 frames, 32 MiB) the loop asks for a pass
  and keeps serving. Passes repeat until `CKPT_TAIL` (200) frames or fewer are left, or the WAL reaches 3x
  the threshold. Then the loop parks incoming POSTs in their connections' pending bytes while GETs go on, up to
  4,096 parked at a time (past that a POST is served and the round may not finish), and the last pass copies
  the rest. With nothing written since, the WAL is fully copied and the next write restarts it. A hold
  ends after `CKPT_HOLD` (500 ms) at the latest, or 2 s once the WAL is past 3x the threshold, and the parked
  POSTs are then served. Each still commits before its response is sent.
- **What still syncs on the loop.** SQLite syncs the WAL's new header when the next write restarts the WAL
  (once a round; the rest of the file was synced by the checkpoint), and past 8x the threshold (64,000 frames)
  or with `CKPT_HOLD=0` the loop runs one inline PASSIVE checkpoint as the last resort. `SHMX=0` turns the
  whole mechanism off: `locking_mode=EXCLUSIVE` and inline checkpoints, as in the build scored at `df9da40`.
- **WAL flusher thread.** A thread in `host.c` calls `fdatasync` on the WAL file (through its own
  descriptor) every 100 ms. It only makes data durable sooner. It halved p95 and p99 when checkpoints ran
  on the loop; with the checkpointer it no longer buys any latency (2-minute A/B at 270,000 users, E75), and it stays
  to keep the loss window after a power cut at 100 ms. The same thread does the code locking below.
- **Memory on the 2 GB box.** Each open connection costs the kernel ~3.8 KiB (socket, inode, file,
  dentry) plus ~0.35 KiB for its pending io_uring receive, so 300,000 users take ~1.2 GB before the
  server does anything. What is left for the page cache is small, and the kernel evicts file pages as the
  ramp ends: the database, the WAL and our own machine code. With one loop thread, every evicted page it
  needs is a wait on the disk; meanwhile every user's next request queues in the kernel (each holds at
  least a page of TCP memory), TCP memory passes its limit, and in the end the OOM killer takes the
  server. That is the "connection refused" #272 got from 210,000 users on. Three changes keep the loop
  off the disk: the small WAL above (it stays cached; #272 let it grow to 128,000 frames, 500 MiB), `mlock` on the code (the WAL thread in `host.c`
  locks app.so's code and the pages of the libraries' code in use, ~7 MiB, within the default 8 MiB
  `RLIMIT_MEMLOCK`; `PIN=0` turns it off), and the 18 MiB connection tables are no longer zeroed at start,
  so slots that are never used never become resident. SQLite's 64 MiB page cache holds the hot pages in
  the process's own memory, which the kernel can't evict (no swap).
- **A page-cache fix.** perf showed `pcache1Truncate` at 1.2% of the CPU. Each commit calls
  it with the database's size, and about one commit in ten made it walk all 8,192 hash slots (~250 µs).
  The cause is SQLite's `balance_nonroot`, which swaps two pages through a temporary page number, the
  lock-byte page's (262,145 here), and the cache then believes it holds a page that far out. The WAT
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

All of this is our own harness, not the scorer. Twice it read too high: #272 held 300,000 here and scored
200,000, and `df9da40` held 290,000 here and scored 200,000 (210,000 failed on p99 with 0 errors). So read
the 260,000 below as an upper guess.

**This head, harness v3** (`experiments/worklog.md` E61-E81). The harness below, without the CPU spin and
with the disk capped at 3,000 write IOPS (systemd `IOWriteIOPSMax`), `SRVMB=1900`, 5-minute holds. p95/p99 in ms:

| build | users | p95 / p99 (ms) | result |
|---|---|---|---|
| inline checkpoints (`c49b70d`) | 210,000 | 670 / 855 | fails on p95 |
| this head | 260,000 (2 holds) | 56 / 335, 52 / 355 | pass, 0 errors |
| this head | 270,000 (2 holds) | 51 / 305, 255 / 1,035 | one pass, one misses p99 by 35 ms |
| this head | 280,000 (2 holds) | 81 / 340, then OOM-killed | one pass, one fail (41% errors) |

At half the IOPS (1,500 reads and writes) the previous tuning held 260,000 at 90 / 455, and the inline build
failed 210,000 at 1,405 / 1,970. Memory is what ends the climb: at 280,000 sockets dominate 2.5 GB of slab
(both ends counted on this box), and the margin there is under ~90 MB. With less memory (`SRVMB=1650`) 240,000
fails too, from page-cache thrash; that setting is harsher than the scorer, by the calibration below.

This harness doesn't reproduce the scorer's cliff at 210,000: at 3,000 IOPS the old build's tail grows smoothly in
2-minute probes. Correctness of the shared wal-index, on this build (E78; method in E60, E64): 391 read-your-writes checks with 0 stale, 0 of
2,270 acked writes missing after `kill -9`, integrity ok; the hold checks (split, pipelined and large POSTs, closes
mid-hold) found 0 bad. 42/42. The clean `ubuntu:24.04` install has not been rerun for this head.

**Before the checkpointer: why memory was the first wall.** Our earlier bench box (below) held 300,000 users with #272,
which then scored 200,000: on the real 2 GB droplet it was OOM-killed after the ramp ("connection refused"
from 210,000 on). `experiments/worklog.md` (S14, E37-E48, C1, M3) has how we reproduced that. The harness, on
the same rented 8 vCPU box: the server is a systemd unit as a non-root user, `LimitNOFILE=65535`, every
other limit at systemd's default (8 MiB of locked memory), on CPU 0; a memory hog leaves the server what a
1,967 MB box would, after the load generator's own memory (11.5 KiB per user, measured); `tcp_mem` at
twice a 2 GB box's default, since on loopback it also carries the load generator's sockets. We fitted the
hog to a build the scorer has scored: f220565 held 270,000 there and failed at 280,000, and it does the
same here. What this harness can't show: on loopback the kernel's receive work for the
server's sockets runs on the load generator's CPUs, while the droplet's single vCPU pays for it, and
the scorer's probes run back to back.

5-minute holds there of `df9da40` ("this one", inline checkpoints), 0 errors in all of them:

| build | users | p95 (ms) | p99 (ms) |
|---|---|---|---|
| the same with 4,000 frames (f3e9410) | 280,000 | 280 | 480 |
| this one | 290,000 (4 holds) | 325, 345, 315, 350 | 600, 585, 530, 575 |
| this one, without the code locking (`PIN=0`) | 290,000 | 395, 345 | 720, 605 |
| this one | 300,000 (4 holds) | 440, 625, 370, 405 | 795, 1,945, 680, 725 (in the second the ramp's end evicted the WAL, and checkpoints read it back from disk) |
| this one | 310,000 | 535 | 1,290 |

At 290,000 users: ~30.4k req/s, ~87% of the CPU (~28.5 µs per request), RSS 115-160 MB.

**Earlier: scorer-like load, Synteq.** A rented 8 vCPU box with the grader droplet's CPU (Xeon Platinum 8260) and
kernel (6.8.0). The server runs alone on CPU 0 in a scope with `MemoryMax=2G`, with `LimitNOFILE=65535`;
the load generator (`ul`, C, the `bench/load.js` user loop with its real think times, one keep-alive
connection per user, 32 source addresses) runs on CPUs 1-7. 60 s ramp, then the measured window.
`experiments/worklog.md` has every run, including the changes that didn't help.

5-minute holds with SQLite's own checkpoint every 128,000 frames (#272): at 300,000 users,
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
| SQLite's own checkpoint, every 128,000 frames (#272) | 300,000 | 24, 51, 28 | 181, 270, 143 | 28.3-29.0 µs |
| objc-uring-delneg, for reference (1 run) | 280,000 | 11.2 | 23.4 | 25.5 µs |

At 320,000 users the server is at 91-94% of its one CPU, so CPU per request is the next limit.

The ObjC entry checkpoints from a separate process, so its loop never waits for an fsync; that was most
of the gap in the tail, and it is what the checkpointer above copies. It uses about 0.9x this entry's CPU per request here.

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
running as wasm. They also checkpoint the WAL off the event loop (a forked child, a thread). This entry
did not yet (these numbers predate the checkpointer), so checkpoints ran inline and their fsyncs paused the loop: at ~30k req/s, p95 is ~38 ms
against 1.5-1.9 ms for the two baselines.

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
