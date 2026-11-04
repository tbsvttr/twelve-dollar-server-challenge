# WAT entry worklog (boxes: opt-box = i5-11400F VM, 4 vCPU; Synteq = Xeon Platinum 8260 VM, 8 vCPU, from S4 on. Neither is the grader)

Every number up to and including S3 is from opt-box. From S4 on, each entry names its box.
Harness: `ub.sh` starts the server pinned to CPU 0 on a fresh copy of the seed (on disk, `~/watlab/wb`),
then `ul` (own C load generator, `bench/load.js` user loop with think times x SCALE, keep-alive,
reconnects on `Connection: close`) on CPUs 1-3. us/req = server process CPU (utime+stime) / requests
in the measure window. Loopback: part of the server's kernel TCP work is charged to the client cores.

## Setup (1 Nov)
- opt-box `~/watlab`: wasi-sdk 34 (clang 23.1.0), wabt 1.0.39, binaryen 125, WasmEdge 0.18.1,
  SQLite 3.54.1 amalgamation (sha256 0a9c8e34… = the ObjC entry's pin). Seed copied from `~/tdsc/repo/seed`.
- Reference `wserve.c` (C, poll loop) native: 42/42; WasmEdge AOT: 42/42.
- WasmEdge 0.18.1 source read (`lib/host/wasi/inode-linux.cpp`): `poll_oneoff` keeps one epoll fd but
  does an `epoll_ctl` ADD/MOD for every subscription on every call, DELs the ones not passed again,
  and an `ioctl(FIONREAD)` per ready fd. So a call costs O(subscriptions) syscalls. WASI fds are random
  32-bit numbers (an `unordered_map`), so the program cannot index by fd; poll userdata carries the slot.
- WasmEdge's listener needs `sock_setsockopt(SO_REUSEADDR)` or a restart fails to bind while old
  connections sit in TIME_WAIT ("wasmedge socket setup failed").

## E1: keep-alive vs a new connection per request (Connection: close), C reference
4000 users, scale 0.1 (~4.2k req/s), 15 s, 3 interleaved reps.
| variant | us/req (3 reps) | p99 ms |
|---|---|---|
| native, keep-alive (poll over ~4000 fds) | 189.3, 188.4, 189.0 | 34-37 |
| native, Connection: close | 17.48, 17.49, … | 34-38 |
| WasmEdge AOT, keep-alive (epoll_ctl per fd per call) | 134.5, 137.7, … | 38-42 |
| WasmEdge AOT, Connection: close | 20.19, 19.51, … | 33-36 |
Finding: with every user holding an idle keep-alive connection, the per-call O(n) poll dominates
(7-10x). Closing after every response keeps the poll set tiny. load.js think times are >= 3 s, so
keeping a connection for less than 3 s never gets reused anyway, and keeping it longer at 280k users
would need ~80k+ fds (LimitNOFILE is 65,535). Decision: answer with `Connection: close`.
p99 ~35 ms in every variant: probably the inline WAL checkpoint (to check).

## Linking test (1 Nov)
`wat2wasm main.wat` + SQLite reactor module (wasi-sdk clang, `-mexec-model=reactor`, `--global-base=16 MiB`)
joined by binaryen `wasm-merge sq.wasm sq main.wasm main`: the WAT module imports the SQLite module's
memory and functions; runs under WasmEdge interpreter and AOT. wasm-ld default is stack-first
(stack [0, 64 KiB)); with `-z stack-size=1 MiB` and `--global-base=16 MiB` the WAT owns [1 MiB, 16 MiB).

## SQLite survey (user request, 1 Nov)
How the top entries use SQLite (grep of their sources):
- All: WAL + `synchronous=NORMAL`, one connection, persistent prepared statements, group commit per batch,
  `temp_store=MEMORY`, `unix-excl` VFS (WAL index on the heap, no shm), mostly `mmap_size=0`
  (ObjC measured a 32 MB page cache ~3% faster than mmap), cache_size -512 KiB … -64 MiB.
- Checkpoints off the event loop: `wal_autocheckpoint=0` and PASSIVE checkpoints from a second
  connection on a thread (Lean, Mojo, pavlyhalim, public, shivanshthapliyal, V) or a forked child (ObjC),
  with a write gate around 8-16k frames. c-iouring-public's inline "bounded" mode held 17.5k vs 15.5k req/s
  depending on pass size: inline checkpoints stall the loop.
- Compile flags (Mojo/ObjC/public/pavlyhalim share most): THREADSAFE=0/2, DEFAULT_MEMSTATUS=0,
  DEFAULT_WAL_SYNCHRONOUS=1, DQS=0, LIKE_DOESNT_MATCH_BLOBS, MAX_EXPR_DEPTH=0, OMIT_DEPRECATED,
  OMIT_SHARED_CACHE, OMIT_PROGRESS_CALLBACK, OMIT_LOAD_EXTENSION, USE_ALLOCA, OMIT_DECLTYPE,
  (pavlyhalim also OMIT_AUTOINIT/JSON/UTF16/TRACE, TEMP_STORE=3, own PCACHE2 plugin).
- Fastest reads: SQLite B-tree cursor calls from a TU that includes the amalgamation (ObjC, Mojo,
  pavlyhalim, public, V).

Existing wasm SQLite builds, checked for WASI use:
- SQLite official `ext/wasm`, sql.js, wa-sqlite: Emscripten, browser VFS (OPFS/IndexedDB). Not WASI.
- ncruces/go-sqlite3 (build now in ncruces/go-sqlite3-wasm `build/build.sh`): freestanding `--target=wasm32`,
  own libc, `SQLITE_OS_OTHER` with the VFS in Go on the host, `wasm-opt -O4 --gufa-optimizing …`, then
  wasm2go. Not WASI (its VFS is host code). Reusable: its option list (`sqlite_opt.h`) and the wasm-opt pass.
- VMware Wasm Labs (webassembly-language-runtimes) libsqlite: their patches were upstreamed;
  since 3.41.0 stock SQLite builds for WASI (`SQLITE_WASI`: no fchmod/mremap, default VFS
  `unix-dotfile`, no shm). Their article says WAL is off in their build; with
  `locking_mode=EXCLUSIVE` WAL works with the index on the heap (the reference 42/42 runs that way).
Decision: build the stock pinned amalgamation with wasi-sdk (that is the WASI-ready path), borrow
flags from the top entries / ncruces, and A/B: flag set, wasm-opt on the SQLite module, page cache,
VFS (`unix-none` avoids a stale `.lock` dir after a crash), checkpoint policy.
Open: checkpoints. No fork/threads in plain WASI; WasmEdge wasi-threads support to check.

## E2: the WAT server, first build (1 Nov) — 42/42
Built by `experiments/dev-build.sh` on opt-box: SQLite 3.54.1 + `src/sqlite_glue.c` (wasi-sdk 34, `-O2`,
reactor, 1 MiB stack, data from 16 MiB) and `src/app.wat` (wat2wasm 1.0.39), joined by `wasm-merge`
(binaryen 125), `wasmedge compile --optimize=3` → `app.so` (3.7 MB), run by `src/host.c` (WasmEdge 0.18.1
C API, `WasmEdge_ConfigureSetRunMode(AOT)` is required or the .so is rejected).
Design: SPEC wants HTTP/1.1 keep-alive, so instead of E1's `Connection: close` the host gives the WAT
8 raw Linux calls ("sys": listen, epoll_create/ctl/wait, accept4, recv, send, close); level-triggered
epoll, per-fd state in a table indexed by the real fd. WASI is kept only for SQLite's file I/O, env and
clock. SQLite: one connection, `unix-none` VFS, locking_mode=EXCLUSIVE, WAL, synchronous=NORMAL,
64 MiB cache, persistent prepared statements, default autocheckpoint (inline).
Result: `t.sh e2 out/host out/app.so` → passed=42 failed=0 on the first full run.

## E3: WAT (epoll, keep-alive) vs the E1 references (1 Nov)
4000 users, scale 0.1 (~4.2k req/s), 15 s, 3 interleaved reps, server on CPU 0.
| variant | us/req (3 reps) | p99 ms |
|---|---|---|
| WAT, WasmEdge AOT, epoll host, keep-alive | 9.91, 10.09, 13.39 | 32-35 |
| C native, poll, Connection: close | 17.34, 19.04, 16.87 | 34-36 |
| C→wasm WasmEdge AOT, poll_oneoff, Connection: close | 19.17, 19.36, 18.98 | 35-38 |
| C native, poll, keep-alive | 186.7, 182.2, 185.7 | 32-36 |
The epoll host plus keep-alive takes the WAT build below the best E1 variant at this load. Not yet a fair
WAT-vs-C test: the C side still uses poll. E4 puts the same C on the same epoll loop and host.
p99 ~33 ms everywhere: still suspect the inline WAL checkpoint.

## E4: same epoll loop and host, WAT vs C→wasm vs C native (1 Nov)
`baseline/cserve.c` = the C reference (wserve.c) with its poll loop replaced by the WAT entry's loop and
"sys" calls; wasm build runs on the same `host` (42/42), native build uses the calls as syscalls (42/42).
4000 users, scale 0.02 (~20k req/s), 20 s, 3 interleaved reps.
| variant | us/req | p95 ms | p99 ms | rss |
|---|---|---|---|---|
| WAT, WasmEdge AOT | 7.91, 7.84, 7.92 | 38.2, 34.7, 38.0 | 44.3, 40.7, 135.2 | 59 MB |
| C→wasm, WasmEdge AOT, same host | 7.54, 7.99, 7.52 | 35.3, 35.9, 35.3 | 39.5, 40.4, 41.7 | 96 MB |
| C native (gcc -O2), epoll | 8.41, 8.60, 8.82 | 33.0, 32.5, 32.7 | 38.7, 37.8, 38.0 | 48 MB |
Server CPU is only ~16% at 20k req/s: loopback charges much of the TCP work to the client cores, and
most of a request's server cost is SQLite. WAT ≈ C→wasm here (C→wasm ~2% lower median, within noise);
both wasm builds are a bit below native (unexplained; malloc? check later). The real problem: p95
~35 ms in all three at 20k req/s. Suspect the inline WAL autocheckpoint (E5).

## E5: inline autocheckpoint off (diagnostic only; WAL grows without bound) (1 Nov)
Same load as E4 (4000 users, x0.02, 20 s), 3 interleaved reps.
| variant | rps | us/req | p95 ms | p99 ms |
|---|---|---|---|---|
| WAT (autocheckpoint 1000) | 20215, 20285, 20357 | 7.54, 8.06, 7.79 | 38.4, 36.8, 35.9 | 44.6, 42.3, 40.9 |
| WAT, wal_autocheckpoint=0 | 21134, 21192, 21187 | 8.16, 7.90, 7.91 | 0.40, 0.35, 0.35 | 4.45, 0.60, 0.55 |
Confirmed: the ~35 ms p95 is the inline checkpoint (its fsyncs block the loop); CPU per request is
about the same, so the cost is blocked time, not CPU (~4.5% fewer requests served in the window).
Not kept (can't ship without checkpoints). Next: checkpoints off the loop (no threads/fork in WASI).

## Setup: install.sh / build.sh / start.sh + clean-container CI mimic (1 Nov)
install.sh (root): apt build-essential/curl/unzip, then wabt 1.0.39, wasi-sdk 34, binaryen 125 and
WasmEdge 0.18.1 (ubuntu20.04 build) release tarballs, each sha256-pinned, into /opt/wat-tdsc (the same
way merged entries fetch LLVM/Lean/Mojo toolchains). build.sh (user): SQLite 3.54.1 amalgamation
(sha256 0a9c8e34…) → sq.wasm, app.wat → app.wasm, wasm-merge, `wasmedge compile`, gcc host.c.
CI mimic (`~/watlab/ci.sh`: fresh ubuntu:24.04 container, install.sh as root, test/run.sh as a user):
passed=42 failed=0.

## E6: past the fd cap — idle keep-alive eviction (1 Nov)
Harness: `ul` now binds source addresses 127.0.0.2-9 (more than 64k client ports) and reports error kinds;
`ub.sh` limits only the server to 65,535 fds (like the grader's LimitNOFILE). Real think times (scale 1.0),
ramp 30 s, measure 30 s, single runs (a cliff test, not an A/B).
| variant | users | rps | us/req | p95/p99 ms | err | note |
|---|---|---|---|---|---|---|
| E2 build | 40,000 | 4235 | 10.78 | 4.2 / 37.3 | 0 | 80k sockets, ~600 MB RAM |
| E2 build | 80,000 | 7025 | 55.28 | 20.9 / 39.6 | 0* | ~14k users never accepted; EMFILE busy-loop on the level-triggered listener (*ul has no timeout; k6 would time out) |
| evict ≥1.5 s idle when >60k conns | 80,000 | 8435 | 15.02 | 35.4 / 125.0 | 0.77% | ECONNRESET: closed sockets that already held an unread request |
| + read once before closing | 80,000 | 8417 | 14.69 | 40.2 / 171.4 | 0.000% | recv0=141 over the whole run incl. ramp |
Kept: when more than 60,000 sockets are open (or accept hits EMFILE), every 0.5 s close keep-alive
sockets idle ≥ 1.5 s with no partial request or unsent output, after one recv() that must return EAGAIN
(else the request is served). On EMFILE with nothing to free, the listener is paused until the next sweep.
Cost: past ~60k users most requests come on a fresh connection (~15 vs ~11 us/req on loopback; the
grader's real NIC adds more). io_uring direct descriptors (what ObjC/Lean/Mojo use) would lift the cap;
consider later via the host.

## E7: baselines, ObjC #154 and c-iouring-public #158 vs WAT and C→wasm (1 Nov)
The two entries were built by their own install.sh/build.sh in fresh ubuntu:24.04 containers
(`~/watlab/mkbase.sh`), then their `/app` was copied out and run natively by `ub.sh` like ours (CPU 0,
nofile 65,535). In Docker, the default seccomp profile refuses io_uring (ObjC exits, the C entry falls back
to epoll), so native runs are the fair setup. Both use io_uring here (checked in their startup logs).
4000 users, scale 0.02, 20 s, 3 interleaved reps (WAT, C→wasm, ObjC, C), the same load as E4.
| variant | us/req | rps | p95 ms | p99 ms | rss |
|---|---|---|---|---|---|
| WAT, WasmEdge AOT | 8.07, 8.04, 7.99 | 20.1–20.3k | 41.9, 35.4, 35.1 | 48.6, 41.3, 40.8 | 59 MB |
| C→wasm (cserve.c), same host | 7.80, 7.79, 8.25 | 20.3k | 35.4, 35.0, 35.4 | 40.3, 40.2, 40.7 | 96 MB |
| ObjC #154 (objc-uring-delneg) | 6.23, 6.13, 5.95 | 21.1k | 1.5, 1.5, 1.5 | 1.8, 1.6, 1.6 | 25 MB |
| C #158 (c-iouring-public) | 7.22, 6.30, 6.50 | 21.1k | 1.3, 1.25, 1.25 | 1.75, 1.45, 1.5 | 13 MB |
WAT is ~30% more CPU per request than ObjC and ~20% more than the top C entry, and about level with
C→wasm. The wasm builds also serve ~4% fewer req/s at the same offered load, because the inline
checkpoint stalls (p95 ~35 ms) delay each user's next think period. Both baselines checkpoint off the
loop (ObjC: a forked child; C: a thread). They also read /feed and posts through SQLite's B-tree layer
with no bytecode, batch writes into one transaction, and (ObjC) use PGO.

## E8: profile, WAT vs ObjC (perf, 4000 users x0.02) (1 Nov)
`perf record` on the server under E7's load. The AOT `.so` names functions `f<index>`; a copy built with
`wat2wasm --debug-names` and `wasm-merge -g` maps them (`out/prof/names.txt`).
WAT: app.so 57.6% (sqlite3VdbeExec 9.3, BtreeTableMoveto 6.6, BtreeIndexMoveto 4.3,
vdbeRecordCompareInt 3.9, pcache1Fetch 2.9, getAndInitPage 2.6 ... the WAT's own functions together ~6%:
putjson 2.9, post_json 1.9, process 0.6), kernel 33.3%, libwasmedge 6.1% + libc rwlock 1% (host-call and
WASI dispatch). ObjC: kernel 67%, its own code 30% (`_i_TDStore__feed_` 9.9%: the feed on the B-tree layer).
In samples, WAT's user time is ~3x ObjC's while kernel time is about equal. So the gap is SQLite's
bytecode path for /feed and posts, not the WAT code and not the runtime: E9 (group commit) and E10
(B-tree reads) next.

## E9: group commit, one transaction per epoll batch (1 Nov) — kept
BEGIN after each epoll_wait, COMMIT after the batch; responses wait in OUTB (now 12 MiB at 0x400000,
with a record list at 0x300000) and are sent only after COMMIT, so no 201 goes out before its row is
committed; if COMMIT fails, the batch's connections are closed unanswered. Bug found on the way: inside
an explicit transaction, `INSERT ... RETURNING` needs a temp file, and WASI has no temp directory
("disk I/O error", then "cannot commit - no transaction is active"): fixed with `PRAGMA temp_store=MEMORY`.
42/42. 4000 users x0.02, 20 s, 3 interleaved reps:
| variant | us/req | p95 ms | rps |
|---|---|---|---|
| base (c01300f) | 8.03, 7.87, 7.84 | 37.5, 35.2, 34.5 | 20.3k |
| E9 group commit | 7.12, 6.05, 6.38 | 39.1, 37.0, 38.0 | 20.5k |
Median -19% CPU per request; every E9 rep is below every base rep. p95 unchanged (checkpoint stalls).

## Metric correction: ul's CPU number undercounts ~2x (1 Nov)
ul's `cpu=` (and every us/req above, E3-E9) comes from the server's /proc utime+stime ticks over the
window. Under `perf stat -e task-clock` on the same runs it reads about half: e.g. E9 "6-7 us/req" is
21 us/req of task-clock. The comparisons inside one table still hold (same bias for every variant, all
interleaved), but the absolute numbers are low. From here on: `pstat.sh` = ub.sh with a 25 s window and
`sudo perf stat -p <server> -- sleep 15` from second 14; it prints task-clock us/req and user/kernel
cycles and instructions per request. 4000 users x0.013 (~30k req/s, below ul's ~62k ceiling, so every
variant serves the same offered load).

## E10: /feed and GET /posts/:id on SQLite's B-tree layer (1 Nov) — kept
`sqlite_glue.c` now `#include`s the amalgamation (one translation unit) and exports one-line wrappers
over the cursor functions (`sqlite3BtreeCursor`, First/Next/Previous, TableMoveto, IndexMoveto with a
one-field UnpackedRecord, PayloadFetch). The WAT reads the schema's root pages at start, keeps four
cursors (posts, users, posts_created_at_id_idx, likes_post_id_idx) open per transaction, decodes records
itself (varints, serial types) and counts likes by an index range scan (one scan over the 20 feed ids
when their span is < 256, else one seek each). Guards: UTF-8 database, schema cookie checked per
transaction, overflow pages or anything unexpected fall back to the SQL statements. Same pager, page
cache, WAL and locks: only the bytecode engine is skipped. Responses byte-identical to E9 over 314
requests; 42/42. pstat, 4000 users x0.013, 3 interleaved reps:
| variant | task-clock us/req | user cycles/req | user instr/req | kernel instr/req | p95 ms | rps |
|---|---|---|---|---|---|---|
| E9 (fddfada) | 21.03, 21.23, 21.31 | 55.5k, 56.0k, 56.2k | 155k | 28k | 42.5-43.6 | 30.0k |
| E10 | 15.26, 15.25, 15.55 | 28.8k, 28.9k, 29.6k | 76.4k | 28k | 39.3-39.9 | 30.5k |
| ObjC (objc-uring-delneg) | 10.08, 9.47, 9.94 | 10.7k-11.1k | 27.1k | 25k | 1.8-1.85 | 32.4k |
| C (c-iouring-public) | 9.58, 9.48, 9.65 | 10.5k-10.9k | 22.4k | 26k | 1.45 | 32.5k |
-28% CPU per request, user instructions halved. WAT is now ~1.6x the baselines' CPU: user cycles ~2.7x
theirs, kernel about equal. Their p95 is 1.5-1.9 ms against WAT's ~40 ms: the inline WAL checkpoint
(both baselines checkpoint off the loop). E11 next.

## E11: smaller WAL checkpoints (`wal_autocheckpoint` 1000 -> 250 / 100) (1 Nov) — discarded
pstat, 4000 users x0.013, 3 interleaved reps:
| variant | task-clock us/req | p50 ms | p95 ms | rps |
|---|---|---|---|---|
| E10 (1000 pages) | 15.41, 15.33, 15.39 | 0.30 | 38.9-41.1 | 30.4k |
| 250 pages | 15.78, 14.98, 15.17 | 8.5-8.95 | 28.5-28.7 | 30.0k |
| 100 pages | 15.15, 14.98, 14.83 | 22.7-23.3 | 39.3-40.1 | 27.4k |
Shorter stalls but many more, and the median goes from 0.3 to 9-23 ms: each checkpoint costs two
fsyncs whatever its size. opt-box's disk: fsync of 200 KB takes 16.9 ms (p50, 30 tries). Counting
syscalls over 15 s (`fsc.sh`, perf tracepoints): E10 makes 240 fsyncs (8 checkpoints/s, ~3.3k
commits/s), so the loop sits in fsync ~27% of the time; even at ~half CPU this costs 7% of the offered
load (30.5k vs 32.6k served). A diagnostic build with `synchronous=OFF` (not allowed by rule 6, never
kept) has p95 0.40 ms and serves all 32.6k. So: fewer checkpoints (E12) or checkpoints off the loop.

## E12: bigger WAL checkpoints (`wal_autocheckpoint` 4000 / 16000) (1 Nov) — discarded
`fsc.sh` (fsync count over 15 s), 4000 users x0.013, 3 interleaved reps:
| variant | fsyncs / 15 s | p50 ms | p95 ms | p99 ms | max ms | rps |
|---|---|---|---|---|---|---|
| E10 (1000) | 238, 243, 240 | 0.25 | 38.7-40.1 | 45-47 | 54-72 | 30.4k |
| 4000 | 71, 72, 71 | 0.20 | 69.6-73.9 | 83-88 | 99-143 | 30.2k |
| 16000 | 18, 18, 18 | 0.15 | 43.5-73.6 | 189-198 | 219-622 | 30.7k |
Fewer checkpoints, but each copies and fsyncs more distinct pages: ~80 ms at 4000, ~200 ms at 16000.
Blocked time drops (~27% -> ~19% -> ~12%) but the tail gets worse. Consulted DeepSeek and Gemini on
moving fsync off the loop (a VFS shim whose xSync hands the fd to a host thread): both say it is
`synchronous=OFF` in effect (SQLite's noSync path skips exactly those syncs), and the stall would move
to the next WAL restart anyway. Not doing it. A real off-loop checkpointer needs a shared wal-index
(wasi-threads, or a host-backed xShm + a native checkpoint thread): big, and C. Cheaper first: write
less WAL (E13).

## E13: group-commit window of 2 ms; per-fd generation for held responses (1 Nov) — kept
A transaction that has written stays open across epoll_wait calls (timeout = what is left of the
window) until 2 ms after it began; one with no writes commits at the end of its batch as before, so
read-only traffic waits for nothing. Responses are still sent only after COMMIT. Fixes a latent bug the
longer hold would have made likelier: a held response checked only that its fd was open, so a
connection closed and its fd reused by an accept in the same batch could get the old response. Now
each fd has a generation (GEN at 0x144000, bumped on close) and the record keeps it. 42/42.
4000 users x0.013, 3 interleaved reps each of fsc.sh then pstat.sh:
| variant | fsyncs / 15 s | task-clock us/req | user / kernel cycles | p50 ms | p95 ms | rps |
|---|---|---|---|---|---|---|
| E10 | 237, 240, 243 | 15.43, 15.23, 15.34 | 29.1k / 26.0k | 0.25-0.30 | 37.8-43.9 | 30.3k |
| E13, 2 ms | 178, 180, 180 | 14.46, 14.33, 14.37 | 27.8k / 24.1k | 2.35-2.5 | 37.3-43.1 | 30.7k |
| 5 ms | 158, 156, 156 | 15.06, 14.60, 14.31 | 27.5k / 24.2k | 4.7-5.2 | 43.2-47.4 | 29.9k |
-6% CPU per request (fewer commits: less SQLite commit work and fewer WAL writes and syscalls) and
-25% fsyncs. The WAL volume follows the number of writes more than the number of commits: a like
dirties random leaves of two indexes. 5 ms: no better CPU, and the closed-loop users get fewer
requests in. The median latency cost (2.5 ms) is nothing next to the 500 ms p95 budget.

## E14: SIMD fast path in the JSON string writer; fixed lengths for constant strings (1 Nov) — kept
Profile of E13 (perf record, names from a `--debug-names` / `wasm-merge -g` copy): kernel 46%, app.so
42%, libwasmedge 7.7% + libc 3.7% (host-call path: rwlock, free). In app.so: sqlite3BtreeTableMoveto
5.9, putjson 5.0, bt_post_out 3.8, pcache1Fetch 2.6, record 2.5, sha_block only 0.6. `putjson` escaped
byte by byte; `$puts` ran strlen over each constant. Now putjson copies 16 bytes at a time with one
v128 compare while none is '"', '\\' or < 0x20 (then byte by byte as before), and the feed's field
names and the Content-Type header are written with their lengths. Responses identical to E13
(`cmp.py`: /feed + 182 GET /posts/:id hashed, plus 7 POSTed bodies with quotes, backslashes, control
characters and UTF-8 read back through /posts/:id and /feed). 42/42. pstat, 4000 x0.013, 3 reps:
| variant | task-clock us/req | user cycles | user instr |
|---|---|---|---|
| E13 | 14.60, 14.51, 14.33 | 27.6k-28.2k | 76.2k |
| E14 | 13.43, 13.57, 13.74 | 24.7k-24.9k | 66.3k |
-6% CPU per request, -13% user instructions.

## E15: SQLite with `-DUSE_PREAD` (1 Nov) — kept (neutral on CPU)
Syscalls under load (perf tracepoints, 10 s at ~30.7k req/s): recvfrom 308k, sendto 307k, lseek 124k,
writev 100k, readv 21k, epoll_wait 21k, fsync ~120; 876k in all (2.85 per request). Without
`USE_PREAD` SQLite's unix VFS seeks before every read and write, and WASI turns each into `fd_seek` +
`fd_write`. With it: preadv 21k + pwritev 101k, no lseek, 758k syscalls (-14%). pstat, 3 reps:
E14 13.94, 13.60, 13.59 us/req; E15 14.12, 13.42, 13.50. Within noise; kept as fewer syscalls (it may
matter more on a box where syscalls cost more). Also: ~14.5 requests per epoll_wait at this load, and
~6k WAL frames/s (two pwritev each: frame header and page).

## E16: one host call sends the whole batch (`sys.sendmany`) (1 Nov) — kept
Host calls cost: libwasmedge 7.7% + libc 3.7% (rwlock) of the E13 profile, ~1.5 us per request over
~2.3 host calls. `$flush` made one `send` host call per response; now it marks records whose connection
is gone (fd -1, by generation), hands the record list to `sendmany` (host: one `send` per record, results
into RBUF, up to 32768 per call), then handles partial sends and errors as before. host.c +12 lines, no
logic (a loop over records and one syscall each). Responses identical (cmp.py), 42/42. pstat, 3 reps:
E15 13.58, 13.93, 13.77 us/req; E16 12.99, 13.29, 13.32 (-3.6%; every E16 rep below every E15 rep).

## E17: one host call waits and receives (`sys.epoll_recv`) (1 Nov) — kept
The host's epoll_recv does epoll_wait, then one `recv` (4 KiB) for each event that is neither the
listener's nor write-ready, into RSLOT (0xe00000, 512 x 4 KiB; OUTB shrinks to 10 MiB). The WAT serves a
connection straight from its slot, or joins it after an unfinished request's bytes in RBUF; a request
longer than 4 KiB just takes more batches (epoll is level-triggered). Two guards, because the bytes are
now read before the WAT looks at the connection: every event's connection is marked active before the
eviction sweep can run, and each event keeps its connection's generation so an event whose connection
was closed in between (a send error during an early flush) is skipped. Tests: 42/42, cmp.py identical,
`big.py` (a 12 KB request over several slots, 3 pipelined requests, a sender dribbling 7 bytes every
2 ms) same as E16. pstat, 3 reps: E16 13.45, 13.38, 13.03 us/req; E17 13.08, 12.91, 12.97 (-3%).

## E18: SQLite at clang -O3; binaryen `wasm-opt -O3` before AOT (1 Nov) — wasm-opt kept
pstat, 3 interleaved reps: E17 13.02, 13.09, 13.04 us/req; SQLite -O3 13.31, 12.97, 13.16 (nothing:
WasmEdge's LLVM -O3 sees it all anyway); wasm-opt -O3 on the merged module 12.72, 12.85, 12.90 (-1.5%,
user instructions 63.1k -> 61.7k; every rep below every E17 rep). 42/42 on both. Kept wasm-opt (binaryen
is already installed for wasm-merge).

## S1: saturation under a CPU cap (1 Nov) — measurement, no change
`sat.sh` runs the server in a `systemd-run --user --scope -p CPUQuota=40%` scope and loads it past its
limit (4000 users x 0.007), reading the scope's `cpu.stat` over 15 s. E18: 34.5k, 34.8k, 33.7k rps;
ObjC 49.8k; top C (cpub) 50.0k: WAT is at 0.69x. Per request at the cap: E18 11.55 us (user 5.5, sys 6.1),
ObjC 8.17 us (user 2.5, sys 5.6). The sync=OFF diagnostic build (never kept) gives 34.6k, 35.1k: only
+2%, so at saturation fsync stalls are not the limit; user CPU is (2.2x ObjC's). Profile of E18 at
4000 x 0.013: kernel 51.6%, app.so 39.1%, libwasmedge 6.2%, libc 2.6%; top of app.so:
sqlite3BtreeTableMoveto 5.55, pcache1Fetch 2.71, record 2.68, bt_post_out 2.51, putjson 2.16,
getCellInfo 1.94, getAndInitPage 1.94, IndexMoveto 1.43, PcacheRelease 1.24.

## S2: C→wasm at saturation (1 Nov) — measurement
Same harness as S1, 2 interleaved reps: C→wasm (`baseline/cserve.c`, E4's build) 15.9k, 15.3k rps at
25.2, 26.3 us/req; E18 35.2k, 34.5k at 11.4, 11.6. The C→wasm baseline is the plain C reference (one SQL
statement set, no B-tree reads, no group-commit window, no batched host calls), so this is mostly the
design, not the language: E4 measured WAT ≈ C→wasm with the same loop and the same SQL.

## E19: ObjC's SQLite compile options (1 Nov) — discarded
`-DSQLITE_DQS=0 -DSQLITE_OMIT_DEPRECATED -DSQLITE_OMIT_SHARED_CACHE -DSQLITE_OMIT_PROGRESS_CALLBACK
-DSQLITE_LIKE_DOESNT_MATCH_BLOBS -DSQLITE_MAX_EXPR_DEPTH=0 -DSQLITE_USE_ALLOCA`. 42/42. pstat, 3
interleaved reps: E18 12.95, 13.00, 12.84 us/req; E19 13.00, 12.94, 12.68; user instructions the same
(61.7-62.1k). Noise; discarded.

## E20: `$put` without memory.copy (1 Nov) — (a) kept, (b) discarded
A profile (perf record) put ~6% in libwasmedge and ~0.7% in pthread_rwlock; disassembly of the hot
libwasmedge code shows a function that looks up two memory instances, bounds-checks (`pages << 16`) and
calls memmove: WasmEdge's AOT code makes every `memory.copy` a call into the runtime. `$put` (some 200
calls per `/feed`) used one memory.copy per call. (a) `$put` copies with v128/i64/i32/byte loads and
stores, and keeps memory.copy for over 256 bytes. (b) also SQLite: its own memcpy/memmove/memset with
plain loads/stores, built with `-mno-bulk-memory -mno-bulk-memory-opt` (LLVM 23 splits the latter out;
`-mno-bulk-memory` alone still inlines memory.copy). 42/42, cmp.py identical, big.py same, both.
pstat, 3 interleaved reps: E18 13.18, 12.97, 13.06 us/req; E20a 12.67, 12.48, 12.59 (-3.7%; user
instructions 61.9k -> 56.5k, every rep below every E18 rep); E20b 12.65, 12.82, 12.53 (no better than a:
SQLite's copies aren't on the hot read path). Kept (a) only.

## S3: saturation, E20 vs the baselines (1 Nov) — measurement
`sat2.sh`, CPUQuota=40%, 4000 users x0.007, 3 interleaved reps (rps; scope CPU per request):
E20 35.3k, 35.8k, 35.8k (11.33, 11.19 us); ObjC 49.5k, 49.7k, 48.7k (8.08, 8.06 us); top C (cpub)
50.4k, 49.9k, 48.5k (7.94, 8.02 us). WAT at 0.72x of either; p95 at saturation ~105 ms against ~45 ms.

## S4: Synteq set up (1 Nov, Synteq) — setup
Synteq (`root@167.17.74.246`, `/root/watlab`): Xeon Platinum 8260 (Cascade Lake, AVX-512 without
VBMI), 8 vCPU, 15 GB, Ubuntu 24.04.5, kernel 6.8, ~2.3 GB disk free. Copied from opt-box: WasmEdge lib
and CLI, the seed, `ul`, the scripts, E20a. Each app is built for this CPU: WAT `app.so` AOT-compiled
on Synteq from the same `merged.opt.wasm`; ObjC and cpub rebuilt in a clean ubuntu:24.04 container on
opt-box with `-march=cascadelake` (`mkcl.sh`), because their opt-box `-march=native` builds crash here
(ObjC: Illegal instruction). All three 42/42 here; WAT cmp.py digest 8aece8930ce55536, bad=0.
Harness `ss.sh`: the server alone on CPU 0 in `systemd-run --scope -p MemoryMax=2G -p MemorySwapMax=0`
(the 1 vCPU / 2 GB stand-in; docker's default seccomp blocks io_uring, so no container), `ul` on CPUs
1-7 with 7 threads, fresh seed copy per run; scope cgroup cpu.stat over 15 s of the 25 s window.
fsync on this disk: 4 KiB O_DSYNC writes ~2.2 ms each.

Probe (Synteq, 6000 users x0.004, 1 run each): WAT 31.5k rps at 82% of the core, p50 151 ms, 26.0
us/req (cgroup); ObjC 42.0k at 99%, p50 106 ms, p95 128 ms, 23.6 us/req. Kernel time per request is
~3x opt-box's here (ObjC user 6.1 + sys ~17.5 us). WAT does not fill the core: `perf trace --duration 3`
shows a checkpoint every ~500 ms (wal_autocheckpoint 1000 pages), each with fsync(WAL) 13-16 ms and
fsync(db) 35-65 ms on the event loop, i.e. ~10-15% of wall time stalled. ObjC checkpoints in a child.

## E21: `wal_autocheckpoint` 1000 / 4000 / 16000 (1 Nov, Synteq) — 16000 kept
S4 showed the inline checkpoints stall the loop. Larger values mean fewer checkpoints, and each copies
fewer frames per committed request (a hot page is copied once per checkpoint). `ss.sh`, 6000 users
x0.004, 3 interleaved reps, rps (cgroup us/req):
- 1000 (E20a): 34.0k, 33.5k, 32.8k (24.1, 24.3, 24.5)
- 4000: 38.6k, 37.8k, 38.0k (23.9, 24.6, 24.9)
- 16000: 40.6k, 39.3k, 40.5k (24.0, 24.2, 23.4), +19%, core 95-98% busy
- ObjC: 43.4k, 44.9k, 41.7k (22.8, 22.1, 23.8); cpub: 47.4k, 48.1k, 48.3k (20.1, 20.2, 19.9)
CPU per request does not change; the gain is the core no longer idling in fsync. WAT is now at 0.92x
ObjC and 0.84x cpub in rps here, and ~5% above ObjC in CPU per request. `perf trace` at 16000: a
checkpoint every ~7 s, stalling ~150-200 ms (fsync WAL ~68 ms, copy, fsync db 48-108 ms); the first one
~450 ms (the WAL file grows to 64 MiB once). 42/42 (Synteq, opt-box), cmp.py digest 8aece8930ce55536,
big.py ok. ul's p95/p99 here are not usable: above 200 ms its buckets were 1 s wide (fixed after E21:
5 ms buckets to ~5.3 s).

## S5: scorer-like load (1 Nov, Synteq) — measurement
LEADERBOARD.md: the grader is a Synteq 1 vCPU / 2 GB VPS, Xeon Platinum 8260, Ubuntu 24.04, kernel 6.8,
the same CPU as our Synteq box; the top entries hold ~280k users at ~26.7k req/s, 27 us/req.
`sc.sh`: `bench/load.js` think times (scale 1), 250,000 users, 60 s ramp, 10 s settle, 120 s measured,
server alone on CPU 0 with MemoryMax=2G (ul now has 5 ms buckets above 200 ms, so p95/p99 are usable):
- E21 (WAT, 16000): 21.1k rps, p50 1.59 s, p95 >5.3 s, err 0.064%, 3,572,770 dials, cgroup 95.6%,
  45.4 us/req, 315 MB
- ObjC: 26.5k rps, p50 2.7 ms, p95 7.0 ms, p99 15.8 ms, 0 errors, 250,000 dials, cgroup 69.2%,
  26.2 us/req, 533 MB (the leaderboard has 27 us/req for it: this harness matches the grader's)
The WAT server holds at most ~60k sockets (epoll and the process fd table, LimitNOFILE=65535) and
closes the ones idle for 1.5 s, so with 250k users almost every request comes on a new connection
(~19k dials/s): accept, epoll_ctl, the kernel's TCP setup and teardown, a sweep recv and close. That
costs ~20 us per request and saturates the core. ObjC keeps all 250k connections in io_uring fixed-file
tables (8 rings x 65,535 slots, which don't count against RLIMIT_NOFILE). The 6000-user tests above
never saw this. On loopback the client's CPU takes part of the server's TCP work, so on the grader the
churn costs the server more, not less.
More WAT points (Synteq, sc.sh): 150k users: 15.5k rps, p50 16 ms, p95 1.08 s, p99 1.32 s, 2.40M dials,
73% CPU, 47.4 us/req; 180k: 18.3k rps, p95 1.54 s, 2.93M dials, 89%, 48.5 us/req. 200k: 19.1k rps, p95 3.18 s, p99 5.09 s,
3.14M dials, 94.3%, 49.3 us/req. So the entry fails
p95 at 150k already, with the core 27% idle: during a checkpoint stall (150-450 ms) ~16k dials/s
overrun the 4096-entry accept queue (somaxconn), and a dropped SYN is retried after 1 s
(TcpExtListenOverflows/ListenDrops climb; SyncookiesSent too). Keeping connections removes both the
per-request TCP setup and the accept queue from the picture.
Consult (DeepSeek, 2 rounds) on the fix: fork + SO_REUSEPORT is out (one DB owner: EXCLUSIVE locking,
WAL index in the wasm heap); parking idle sockets in io_uring slots and installing them back
(FIXED_FD_INSTALL) rejected: same churn count, two state machines, spin risk at EMFILE. Plan E22:
connections live only in io_uring fixed-file slots (accept4, register into a chosen slot, close the
fd), recv/send/close as ring ops, ~5 rings x 65535 slots, generation in user_data, one send in flight
per connection.

## E22: connections in io_uring fixed-file slots (1 Nov) — fixed in E23
The epoll loop and its ten host calls are replaced by io_uring, driven from the WAT. host.c sets up
rings (`ring_new`: ring fd, mmaps, a sparse fixed-file table of min(RLIMIT_NOFILE, 65535) slots),
registers a provided-buffer ring that lives in wasm memory (`ring_pbuf`), and has one submit/reap call
(`ring_go`: copy the SQEs the WAT wrote, enter, copy the CQEs back). The WAT writes every SQE:
- multishot ACCEPT straight into a free slot (IORING_FILE_INDEX_ALLOC), on one ring at a time; at a
  high-water mark (n - min(n/4, 4096)) it is cancelled and moved to the next ring (up to 8 rings,
  cid = ring << 16 | slot); slots do not count against RLIMIT_NOFILE, so no idle sweep any more
- multishot RECV with buffer select (2048 x 2 KiB buffers per ring, recycled by the WAT)
- the batch's responses as SENDs straight from OUTB with MSG_DONTWAIT (they complete in the submit;
  a remainder is copied out and sent by an ordinary SEND); one send in flight per connection
- close: SHUTDOWN linked to CLOSE of the slot; a generation per cid in user_data
- ring 0 (DEFER_TASKRUN) is the one waited on; it holds a multishot POLL on each other ring's fd
- Ubuntu's 6.8.0-147 rejects the buffer-ring registration unless resv[0]=1 (same workaround as ObjC)
42/42 on opt-box and Synteq. Synteq sc.sh 250k: 19.0k rps, p95 230 ms, 29.2 us/req, 56% CPU,
250,000 dials: the connections are kept, but rps was 28% short of the offered load. ul had no request
timeout, so a request that never got an answer was never counted; ul now reports in-flight requests
at the end (`stuck>2s`). Rerun: 89,770 users stuck (opt-box 50k x 0.35: 13,655).
Bug, found with a debug build that logs connection states every 5 s: when a batch has over 1024
responses (after a checkpoint stall), `$sqe` submits mid-staging and reaps the first sends'
completions before `$from` was taken, so `$scan_sends` never saw them and `$on_cqe` ignores that kind.
Those connections kept "send in flight" forever (later responses queued behind it), and `$nsendb`
never got back to 0, so every later flush spent ~100 ms in the fallback wait loop.

## E23: E22 with the send scan fixed (1 Nov) — kept
`$from` is taken before staging. The fallback for a send that did not complete in the submit (EAGAIN:
the kernel retries it later, reading OUTB) waits up to ~20 ms, then ASYNC_CANCELs what is still out
(those connections are dropped), so OUTB is never reused under a send. 42/42 on opt-box and Synteq.
- opt-box 50k x 0.35 (debug build): 15.1k rps (all of the offered load), p50 1.3 ms, 0 stuck, nlate 0
- opt-box 70k x 0.35 (two rings): 21.1k rps (all of it), p50 1.5 ms, p95 85 ms, 0 stuck
- opt-box CPUQuota=40%, 4000 x 0.007, interleaved: E21 34.8k, 35.6k, 35.5k (11.11, 10.81, 10.80
  us/req); E23 35.8k, 35.3k, 34.4k (10.90, 10.93, 11.05). Same CPU per request when no connection churns.
- Synteq sc.sh 250k (ul spread over 32 source addresses from here on): 26.3k rps, p50 2.05 ms,
  p95 335 ms, p99 645 ms, max 1.42 s, 0 errors, 0 stuck, 250,000 dials, cgroup 76.8%, 29.2 us/req,
  614 MB. E21: 21.1k rps, p95 >5.3 s. ObjC in the same session (8 addresses): 26.4k rps, p95 8.6 ms.
The remaining tail is the checkpoint stall (fsyncs on the event loop): that is now what limits the
score, not connections.

## S6: 280k, E23 vs ObjC (1 Nov, Synteq) — measurement
sc.sh, 2 min, 280,000 users, 32 source addresses. E23: 29.5k rps, p95 315 ms, p99 550 ms, cgroup 82.5%,
28.0 us/req, 656 MB. ObjC: 29.6k rps, p50 3.4 ms, p95 11.2 ms, p99 23.4 ms, 75.5%, 25.5 us/req, 585 MB.
With 8 source addresses `ul` itself got stuck in connect() near 280k; 32 fixed it.

## E24: WAL flusher thread in host.c (1-2 Nov) — kept
A host pthread fdatasyncs `$SQLITE_PATH-wal` (own fd) every WALSYNC_MS (default 100; 0 = off), so the
WAL sync a checkpoint starts with is short.
- Synteq sc.sh 280k, interleaved, 3 reps: E23 p95 325, 385, 425 / p99 620, 735, 800 ms, 27.67, 27.92,
  27.70 us/req; E24 p95 196, 138, 184 / p99 465, 285, 390 ms, 28.87, 28.87, 28.66 us/req (+~1 us/req,
  likely smaller batches while the loop no longer stalls as long).
- opt-box q40, 4000 x 0.007: E23 36.1k, 33.2k, 35.1k rps, p99 230-290 ms; E24 36.2k, 36.7k, 36.1k,
  p99 89-103 ms. opt-box 50k x 0.35: E23 p99 225, 183, 185 ms; E24 35, 40, 33 ms.
- bpftrace on Synteq 280k (sc26, `ck.bt`): the db-file sync after the copy takes 93-136 ms every ~3 s
  (fd 4); the loop's own WAL sync is now under 20 ms except once (421 ms, while the flusher's own sync
  took 394 ms). That db sync is the remaining stall.

## E25: wal_autocheckpoint 4000 / 8000 / 16000 with the flusher (2 Nov, opt-box) — 16000 kept
50k x 0.35, 3 interleaved reps, p99: 16000 31.8, 33.2, 32.8 ms; 8000 49.8, 44.3, 43.3; 4000 44.8, 43.7,
44.8. q40 rps: 16000 35.8k, 36.6k, 35.8k; 8000 36.0k, 36.7k, 37.5k; 4000 36.3k, 37.5k, 37.0k (noise).

## S7: 5-minute hold, E24 (2 Nov, Synteq) — measurement
hold.sh (sc.sh with a 300 s window), 280,000 users: 29.4k rps, p50 2.8 ms, p95 355 ms, p99 670 ms, max
1.52 s, 0 errors, 0 stuck, cgroup 83.8%, 28.5 us/req, 719 MB. Passes the score's limits; the 2-minute
probes read lower (p95 138-196 ms), so the 5-minute window catches more checkpoint stalls.
Clean build (opt-box `ci2.sh`): a fresh ubuntu:24.04 container runs install.sh as root and build.sh as a
user; the built folder is then tested outside the container (docker's default seccomp profile refuses
io_uring): passed=42 failed=0. Also 42/42 on opt-box and Synteq from their own builds.

## S8: 2-minute probes above 280k, E24 (2 Nov, Synteq) — measurement
sc.sh: 300,000 users: 31.5k rps, p95 255 ms, p99 525 ms, max 985 ms, 0 errors, cgroup 89.2%, 28.3 us/req,
686 MB. 320,000 users: 33.6k rps, p50 13.3 ms, p95 315 ms, p99 640 ms, max 1.49 s, 0 errors, 91.4%,
27.2 us/req, 727 MB. CPU is close to the 1-vCPU limit at 320k.

## E26: the checkpoint's database-file sync through io_uring (2 Nov)
wal_autocheckpoint=0; the WAT checkpoints itself at the end of $flush (responses sent, no transaction open)
once CKPT_FRAMES (16000) frames are not backfilled. sqlite_glue.c swaps the main db file's io_methods for a
copy whose xSync returns at once while db_ckpt(db, 1) runs; the WAL sync before the copy is unchanged.
After the copy the WAT puts nBackfill back (wal_backfill), so SQLite cannot restart the WAL over frames
whose pages are not yet durable in the db file, and submits IORING_OP_FSYNC (DATASYNC) on a read-only fd
of the db file (new host import file_fd). On its CQE nBackfill moves up; frames written meanwhile get
another round, or an ordinary inline checkpoint once at most CKPT_TAIL (2000) remain, after which the WAL
restarts. CKPT_DEFER=0: plain inline checkpoints at the same point.
- opt-box: 42/42. e26chk.sh (5000 users, CKPT_FRAMES=2000 CKPT_TAIL=200, kill -9 after 24 s):
  integrity_check ok in both modes; WAL file stays at ~8.3-9.4 MB (restarts). strace: inline mode, the
  loop's fsync of the db took 368 ms; deferred, two rounds went to io_uring and the inline tail's
  fsync took ~11 ms.
- Synteq: 42/42 from the AOT build there.
- Synteq sc.sh 300k, interleaved, 3 reps: E24b p95 280, 230, 265 / p99 560, 440, 520 ms / max 1226, 828,
  966 ms, 27.93, 27.27, 28.03 us/req; E26 p95 134, 127, 109 / p99 345, 310, 250 / max 1232, 916, 552,
  28.75, 28.46, 29.03 us/req. Kept: p99 down ~40%; ~+0.8 us/req (as with E24, shorter stalls mean
  smaller batches).
- Clean container build (opt-box ci2.sh): 42/42.

## S9: 5-minute hold at 320k, E26 (2 Nov, Synteq) — measurement
hold.sh: 33.7k rps, p50 8.85 ms, p95 198 ms, p99 455 ms, max 1.82 s, 0 errors, 0 stuck, cgroup 93.6%,
27.78 us/req, 880 MB. Passes.

## S10: where the time goes at 300k, E26 (2 Nov, Synteq) — measurement
perf record -C 0 (20 s): kernel 64%, app.so 33% (WAT + SQLite), libc 1%, libwasmedge 1%. Top: SQLite
sqlite3BtreeTableMoveto 5.4%, __inet_lookup_established 4.5% (the box's ehash has 131,072 buckets for
~600k sockets, both ends local), then WAT record/putjson/put/after_recv and pcache1Fetch at 1.3-2.2% each.
(Symbols: wasm-opt --symbolmap on a merge of sq.wasm and a --debug-names app.wasm gives the same binary.)
Loop gaps > 40 ms (gap.bt, 100 s): 33 of 41 have 3 syncs = the inline tail checkpoint (90-157 ms); 5 are
a deferred round's copy (~41 ms incl. a 13 ms WAL sync). sy.bt: per cycle, WAL sync 15 ms, io_uring
fdatasync of the db 110-157 ms (off the loop), tail: WAL sync 15 ms + db fsync 49 ms + restart header
sync 4 ms.

## E26b: CKPT_TAIL=300 (2 Nov, Synteq) — rejected
1 rep at 300k: p50 18.8 ms, p95 230, p99 670 ms, 1136 MB: under load a round never ends with <= 300 frames
left, so the WAL keeps growing (145 MB) instead of restarting. (Its first paired TAIL=2000 run lost the
server at start: the previous run's server, closing 300k sockets, still held the port; ubs.sh now waits
for the port to be free.) Stopped after rep 1.

## E27: SQLite syncs with fdatasync (2 Nov)
strace showed every SQLite sync as fsync(): the amalgamation defines fdatasync as fsync unless
HAVE_FDATASYNC, and the WASI build has no configure step. Stock Linux builds use fdatasync. Build flag
-DHAVE_FDATASYNC=1 (wasi-libc has fdatasync -> fd_datasync). opt-box: 42/42, kill -9 check ok, strace
now shows fdatasync on the db and WAL. Synteq: 42/42.
A/B at 300k (Synteq, interleaved, 3 reps): E26 p95 86, 89, 108 / p99 188, 192, 265 / 28.01, 28.13,
28.46 us/req; E27 p95 162, 80, 95 / p99 400, 182, 240 / 29.10, 28.08, 28.26 us/req. No difference beyond
noise (this session's E26 runs were also faster than S8's). sy.bt on E27: the io_uring db sync still
takes 120-184 ms and the tail's db sync 40-57 ms, so data, not metadata, dominates. Not kept for speed;
the flag stays in the E28 build only to match stock Linux builds (to decide with E28).

## E28: DB_CHUNK (SQLITE_FCNTL_CHUNK_SIZE) — crashes under WASI, dropped
With DB_CHUNK=64 MB the server died at the first checkpoint: "integer divide by zero" in _start. The
checkpoint's SQLITE_FCNTL_SIZE_HINT goes to fcntlSizeHint, whose non-fallocate path divides by
st_blksize, and WASI's filestat has no block size (0). Integrity ok after the crash. Removed.

## E28: CKPT_WAL — let the WAL grow before a restart (2 Nov)
The inline tail (90-157 ms loop stall) runs once per restart cycle, about every 3 s at 300k. With
CKPT_WAL=N, the async rounds go on (every CKPT_FRAMES frames) until the WAL has N frames, and only then
does a round end in the tail + restart, so the stall comes ~N/16000 times less often for N/4 KB of WAL
file. opt-box: 42/42 (defaults, and FRAMES=500 TAIL=200 WAL=6000); kill -9 check with FRAMES=400
WAL=2000: the WAL file stays at ~2025 frames (restarts), integrity ok, counts match.
A/B at 300k (Synteq, interleaved, 3 reps; e28 built with -DHAVE_FDATASYNC=1):
- E26: p95 65.6, 88.3, 100.6 / p99 141, 197, 225 / max 363, 574, 640 / 27.44, 28.40, 27.43 us/req, 675 MB
- FRAMES=4000 WAL=64000: p95 42.2, 82.7, 79.8 / p99 114, 315, 350 / max 726, 1100, 1366 / 28.50, 28.90, 28.65, 870 MB
- FRAMES=16000 WAL=64000: p95 41.9, 166.8, 78.6 / p99 129, 740, 285 / max 537, 2236, 1351 / 27.65, 29.25, 28.48, 880 MB
Not better on p99/max as measured; the box's run-to-run noise is as large as the effect.
gap.bt over 100 s (Synteq, 300k), WAL=64000: 10 loop gaps > 40 ms (9 tails, 44-122 ms, every ~10.5 s; total
~1.0 s) vs E26's 41 (3.6 s total, S10). New: one 279 ms gap holding a single 237 ms sync (a round's WAL
sync, it seems), which E26's trace never showed. Next: interleaved 5-minute holds at 340k, E26 vs WAL=64000.
5-minute holds (Synteq): 340k fails CPU-bound for both (E26 34.7k rps, p95 1.42 s, p99 4.9 s, 97.8%; WAL=64000
33.5k rps, p95 2.5 s, 96.9%). 330k, interleaved: WAL=64000 p95 360, 1060 / p99 1475, 3845 ms; E26 p95
830, 580 / p99 2350, 1610 ms; all four fail, at 96-97.5% cgroup CPU. Synteq's ceiling is ~320k and it is
CPU. E28 dropped (code reverted); its log stays.

## E29: keep pcache1's iMaxKey off the lock-byte page (2 Nov)
perf had pcache1Truncate at 1.2% of CPU 0. uprobes (Synteq, 300k, 10 s): ~500 calls/s on the main cache,
most 1-8 us, but ~50/s take 128-512 us (~250 us each). Reading PCache1 out of wasm memory at those calls:
iMaxKey = 262,145, nHash 8,192, nPage ~8,100, iLimit = dbSize + 1 (~64,700). A ustack on pcache1Fetch(key
262,145) points at sqlite3PcacheMove: balance_nonroot swaps two new pages through a temporary key,
PENDING_BYTE / pageSize + 1, and pcache1Rekey raises iMaxKey to it. The commit's pcache1Truncate(dbSize+1)
then sees iMaxKey - iLimit >= nHash and walks the whole hash table for pages that are not there. Fix in
sqlite_glue.c (SQLite itself unchanged): db_open wraps sqlite3GlobalConfig.pcache2.xRekey; on a rekey to
that number it puts iMaxKey back (the page moves on to a real number before balance_nonroot returns, and
no truncate runs in between). opt-box: 42/42, kill -9 check ok. Synteq: 42/42.
(The two small caches truncated to 1-2 are the RETURNING statements' ephemeral tables, ~0.2% each.)
A/B at 300k (Synteq, interleaved, 3 reps): E29 p95 85.9, 59.3, 78.3 / p99 215, 132, 176 / 27.77, 27.06,
27.60 us/req; E26 p95 76.1, 67.0, 147 / p99 210, 155, 420 / 27.32, 27.74, 27.71 us/req. perf -C 0 (20 s,
E29): pcache1Truncate (f1131) 0.00%, was 1.2%. The us/req difference is within the box's noise.
Clean container (opt-box ci2.sh): 42/42. 5-minute holds at 320k, Synteq (afternoon, paired): E29 alone
p95 275 / p99 800; then E26 295/835, E29 265/785, E26 280/765, E29 365/1165 (fails p99). All 0 errors,
93-95% CPU. The morning's E26 hold (S9) gave 198/455: 320k is this box's edge, and the spread between
holds of one build is larger than any difference between these two. Kept: it only removes work.

## M1: why the scorer's box refused connections at 280k (Synteq, E26 = f220565)
Scorer (1 vCPU / 2 GB, 31 us/req): 270k held; 280k and 320k collapsed in the 2-min probe with 71 % / 76 %
errors, nearly all "connection refused", which suggests no listener (server gone). Tried to reproduce:
- s44, 280k, memory breakdown at t=150 s: cgroup current 650 MB = anon 101 + file 95 + kernel 453
  (slab reclaimable 294, unreclaimable 154), sock 12 KB; VmRSS 145 MB; 560,168 sockets (both ends local).
- s45, 340k (overload), sampled every 10 s: anon 63 -> 116 MB, file 69 -> 640 MB because the WAL grew
  64 -> 605 MB (checkpoints fall behind), slab plateau ~355 + 178 MB, sock peak 76 MB, current peak 1,330 MB.
  Server survived: 34,974 rps, p95 900, p99 3,760 ms, 97.0 % CPU, 27.73 us/req.
- s46, 280k with the server's scope capped at CPUQuota=89 % (to mimic a slower CPU): passed, 29,610 rps,
  p95 70.8, p99 150.9 ms, 0 errors, 83.1 % CPU, 28.08 us/req, 638 MB; WAL stayed 63-68 MB; listener up
  for the whole run.
Not reproduced on Synteq. Open: what kills the server on a 2 GB droplet (OOM with OS + slab + WAL cache
under overload is the leading guess, unchecked; a $fatal path is the other).
- s47, 340k with the server's scope capped at MemoryMax=1200M: no OOM (memory.events high/max/oom all 0),
  current peak 955 MB (anon 116, file 278, dirty 0-3 MB, WAL 67 -> 242 MB), listener up for the whole run.
  35,485 rps, p95 550, p99 1,185 ms, 0 errors, 96.2 % CPU, 27.11 us/req. Memory pressure alone does not
  kill the server here.
- Synteq is not the scorer's box: ours has 8 cores / 16 GB and sysctl tuning (90-million.conf: tcp_mem,
  somaxconn 65535, file-max ...); the scorer's is a stock Synteq 1 vCPU / 1,967 MB (LEADERBOARD.md).
- Code path that exits under load: $arm_acc called $ring_create for a new ring at runtime (the 5th ring
  starts at ~245k connections), and any failure there went to $fatal -> exit 1 -> "connection refused" for
  everyone. In Linux 6.8 io_uring/io_uring.c, io_mem_alloc() is __get_free_pages(GFP_KERNEL_ACCOUNT |
  __GFP_ZERO | __GFP_NOWARN | __GFP_COMP, get_order(size)): our CQ ring (16,384 CQEs + SQ array) is one
  512 KiB block (order 7) and the SQEs one 256 KiB block (order 6), and a failure leaves nothing in the
  kernel log. On a 2 GB box holding ~450 MB of socket slab, an order-7 allocation can fail. Unchecked on
  the scorer's box: the server log there would show "fatal: io_uring setup failed".

## E30: set up all 8 rings at start (opt-box build; Synteq tests)
$ring_create split into $ring_setup (kernel ring, fixed-file table, buffer ring and receive buffers; returns
1 on failure instead of exiting) and $ring_on (counts the ring in, arms ring 0's poll on it). _start sets up
rings 0-7 before the first accept; a ring that fails there caps the count ($nmax) instead of exiting. Rings
still come into use one at a time as before. Startup (Synteq): 8 io_uring fds instead of 1, VmRSS 74.8 MB
vs 70.6 MB. opt-box: 42/42, kill -9 check ok. Synteq: 42/42.
A/B at 300k (Synteq, interleaved, 3 reps, 0 errors everywhere): E30 p95 89.5, 78.9, 92.2 / p99 210, 177,
205 / 27.91, 27.45, 27.78 us/req, 703, 681, 682 MB; E29 p95 67.6, 126.8, 130.9 / p99 145, 370, 315 /
27.62, 27.84, 28.09 us/req, 676, 696, 697 MB. Same speed within the box's noise. Kept as a robustness fix;
it can't be shown on Synteq (16 GB never runs short of contiguous pages). Committed, not pushed (the PR
head waits for the scorer's ruling on nBackfill).

## F1: fallback if nBackfill writes are ruled out: E30 with CKPT_DEFER=0 (2 Nov, Synteq) — measurement
Same build, all checkpoints inline at the end of $flush (database sync on the loop, no wal_backfill calls).
locking_mode=EXCLUSIVE with one connection means no public-API way (a reader's read mark, a VFS) keeps the
WAL from restarting before an async database sync completes, so inline is the honest fallback.
sc.sh 300k, interleaved, 3 reps, 0 errors: deferred (E30) p95 74.3, 82.5, 104.5 / p99 163, 189, 260 /
max 455, 559, 723 ms, 27.76, 27.90, 28.19 us/req; inline p95 265, 245, 220 / p99 565, 475, 405 / max
1517, 841, 736 ms, 27.91, 27.62, 27.34 us/req. Inline keeps CPU the same but p99 is ~2.5x higher (like
E24b: 440-560 ms); the scorer's 5-minute hold at 270k with the deferred sync was already p99 845 ms, so
inline would likely score lower there (unchecked).

## S12: syscall and io_uring census at 300k, E30 (2 Nov, Synteq) — measurement
bpftrace (cen.bt), 20 s in the middle of a 300k sc.sh run (31.6k rps, p95 154, p99 460 ms, 28.6 us/req):
SEND 635,432 (one per request), POLL_ADD 39,802 (ring 0's poll on the other rings, re-armed ~2k/s), RECV
2,186 (multishot re-arms), FSYNC 6; 1,314,533 CQEs (~2.1 per request). Syscalls: pwritev 251,717 (WAL
frames, header + page each, ~12.6k/s), io_uring_enter 79,704, preadv 28,361, everything else < 200.
In the E29 profile (perf41) the pwritev path is < 0.5 % self time, so buffering WAL writes is not worth it.
Top app functions (symbol map): sqlite3BtreeTableMoveto 6.2 % (mostly the 20 author seeks per feed:
random user ids; the posts already step back with cur_prev and the like counts are one range scan),
record 2.3, pcache1Fetch 2.3, putjson 1.7, put 1.6, IndexMoveto 1.5, after_recv 1.5. Kernel time is the
network path (both ends local here). No large CPU lever left inside the app.

## S13: 5-minute hold at 320k, E30 (2 Nov, Synteq) — measurement
hold.sh: 33.5k rps, p50 39.4 ms, p95 505 ms, p99 1,160 ms, max 2.10 s, 0 errors, cgroup 94.4 %,
28.23 us/req, 1,122 MB. Fails (p95 and p99), like the last E29 hold in S11 (365 / 1,165); single run, not
paired, so no comparison with E29 is drawn. 320k stays this box's edge.

## E31: SQLite's own checkpointing, public API only (2 Nov, opt-box build, Synteq runs) — kept (required)
Arjay held the merge over the glue writing SQLite's internal nBackfill; Denis: switch back to SQLite's own
checkpointing. The glue now uses only public API: a WAL hook (sqlite3_wal_hook) records the WAL size; at
CKPT_FRAMES (16,000) the WAT calls sqlite3_wal_checkpoint_v2(PASSIVE) at the end of $flush, after the
responses are sent; CKPT_AUTO=1 uses sqlite3_wal_autocheckpoint(CKPT_FRAMES) instead. Gone: wal_backfill,
wal_mx, db_ckpt/db_fsync, the io_methods swap, file_fd and the CQE fsync branch. E29's cache fix is redone
through SQLITE_CONFIG_GETPCACHE2/PCACHE2: a wrapper tracks its own max key (ignoring the rekey temp key
PENDING_BYTE/szPage+1) and skips xTruncate past it. 42/42 on opt-box (both modes) and Synteq; kill -9
during load then integrity_check ok in both modes on opt-box.
sc.sh 300k, interleaved, 3 reps, 0 errors (Synteq):
E30 (deferred db sync): p95 135, 81, 102 / p99 315, 177, 245 / max 1107, 627, 646 ms, 28.52, 28.26, 27.46 us/req
E31 (checkpoint after flush): p95 225, 255, 265 / p99 430, 505, 510 / max 777, 892, 1099 ms, 27.75, 28.24, 27.97
E31 CKPT_AUTO=1: p95 250, 255, 275 / p99 515, 495, 575 / max 1705, 1164, 1389 ms, 27.45, 27.51, 28.13
As F1 predicted: same CPU, p99 about 2x E30's. The flush checkpoint is a little better than autocheckpoint
(it runs after the responses go out) and is the default.

## E32: host thread starts writeback of the database file every 5 ms (2 Nov, opt-box build, Synteq runs) — dropped
The WAL flusher thread also called sync_file_range(dbfd, 0, 0, SYNC_FILE_RANGE_WRITE) every DBWB_MS (5), so
pages a checkpoint copies are already being written when SQLite's own fsync of the database comes. 42/42
(opt-box, Synteq); integrity ok after kill -9. Also CKPT_FRAMES=4000 on the same build.
sc.sh 300k, interleaved, 3 reps, 0 errors (Synteq):
E31: p95 390, 250, 240 / p99 815, 475, 425 / max 1435, 931, 756 ms, 28.33, 27.33, 27.43 us/req
E32: p95 245, 270, 335 / p99 475, 715, 695 / max 940, 1818, 1952 ms, 27.51, 28.10, 28.59
E32 CKPT_FRAMES=4000: p95 795, 540, 555 / p99 1870, 1020, 1170 / max 3190, 1493, 2419 ms, 27.46, 26.95, 27.24
No gain from the writeback (noise is as large as any difference); reverted. Checkpoints every 4,000 frames
are much worse: each checkpoint seems to have a large fixed cost, so fewer, larger ones next (s54).

## E33: SQLite built with HAVE_FDATASYNC=1 (2 Nov, opt-box build, Synteq runs) — dropped
Without it SQLite's unix VFS #defines fdatasync to fsync. strace (opt-box, 24 s write load): the loop
thread's syncs are fdatasync with the flag, fsync without. 42/42 on opt-box and Synteq. Measured in s55
below (CKPT_FRAMES=64000): p95 135, 59, 88 / p99 515, 285, 345 ms vs E31's 66, 52, 48 / 230, 210, 193.
No gain; dropped.

## E34: CKPT_FRAMES 16k / 32k / 64k with SQLite's own checkpoint (2 Nov, Synteq) — measurement
Build E32 (writeback on; it made no difference in E32), env only. sc.sh 300k, interleaved, 3 reps, 0 errors:
16,000: p95 220, 225, 245 / p99 415, 410, 480 / max 849, 808, 970 ms, 27.48, 27.51, 28.21 us/req, 690 MB
32,000: p95 170, 163, 168 / p99 430, 445, 405 / max 943, 1204, 1037 ms, 28.80, 28.14, 28.81, 750 MB
64,000: p95 37, 119, 73 / p99 168, 425, 315 / max 587, 1194, 1650 ms, 28.10, 28.51, 27.80, 880 MB
Fewer, larger checkpoints win (with 4,000 the worst, E32): each checkpoint has a large fixed cost. 64,000
frames is a 250 MiB WAL; memory (cgroup, page cache included) goes up ~190 MB.

## M2: loop-thread syncs at CKPT_FRAMES 16k vs 64k, E31 (2 Nov, Synteq) — measurement
bpftrace (ck.bt) on fsync/fdatasync for 100 s of a 300k sc.sh run (my per-key printing came out split, so
counts only): the loop thread made ~105 fsyncs at 16,000 frames and ~33 at 64,000 (about 3 per
checkpoint: every ~3 s vs every ~12 s). Runs under tracing: 16k p95 240 / p99 450 ms; 64k p95 70 / p99 235.

## E35: CKPT_FRAMES 64k vs 128k, and E33, on E31 (2 Nov, Synteq) — 64k/128k both good
sc.sh 300k, interleaved, 3 reps, 0 errors:
E31 64,000: p95 66, 52, 48 / p99 230, 210, 193 / max 715, 927, 691 ms, 28.05, 28.66, 28.25 us/req, 876 MB
E33 64,000: p95 135, 59, 88 / p99 515, 285, 345 / max 2038, 1373, 909 ms, 28.02, 27.52, 28.81, 875-902 MB
E31 128,000: p95 24, 51, 28 / p99 181, 270, 143 / max 1085, 1266, 567 ms, 28.32, 28.32, 29.04, 1,135 MB
SQLite's own checkpoint every 64,000 frames is as good as E30's deferred sync was (s52: p99 177-315).

## E36: default CKPT_FRAMES 128,000 (2 Nov, opt-box build, Synteq runs) — kept
5-minute holds (hold.sh, MemoryMax=2G), E31 build with env, interleaved, 0 errors:
64,000: p95 141, 152 / p99 425, 460 / max 1534, 1197 ms, 28.27, 28.00 us/req, 951-952 MB
128,000: p95 63, 46 / p99 325, 305 / max 1074, 1057 ms, 28.36, 27.88 us/req, 1,206-1,207 MB
MemoryMax=1200M (scm.sh, 2 min, 300k, 128,000): p95 33, p99 270 ms, 0 errors, peak 1,145 MB.
Default set to 128,000 in app.wat (E36). 42/42 on opt-box, Synteq and the clean ubuntu:24.04 container
build (ci2.sh); kill -9 under load then integrity_check ok (opt-box). Holds of E36 itself: 300k p95 82,
p99 330, max 1097 ms, 31.7k rps, 91.2 %, 28.78 us/req, 1,210 MB; 320k p95 315, p99 1,005 (fails p99
by 5 ms), max 2647, 33.6k rps, 95.2 %, 28.33 us/req, 1,259 MB. Same edge as E26-E30.

## S14: a scorer-like harness, and the 210k cliff reproduced (3 Nov, Synteq; TdscWat3 from here on)
The scorer (7792fa9 = #272): 200,000 held, 210k and up failed ("connection refused", 35 % errors) at ~55 % CPU,
while TdscWat2's Synteq runs held 300k. The scoring README: a DigitalOcean Basic droplet, 1 vCPU / 2 GB, no swap,
k6 on another machine, no kernel tuning. Harness `hs.sh` (Synteq `/root/watlab`, scripts copied in
`/tmp/tdsc-wat3/` on the Mac): the server is a systemd unit as a new non-root user `deploy`, `LimitNOFILE=65535`,
every other limit systemd's default (memlock 8 MiB), CPU 0, no Restart, fresh seed DB; `ul` on CPUs 1-7 as before;
samples every 10 s (sockets, cgroup, MemAvailable, slab, TCP pages, WAL size, ul and server RSS). `FAITH=1` starts a
memory hog (`hog.py`, touched anonymous memory, no swap on Synteq) sized so the server gets what a 1,967 MB box
leaves it: MemAvailable minus 1,650 MiB minus the load generator's own cost, measured at 11.5 KiB per user (ul RSS
1,684 MB at 210k = 8.2 KiB/user, plus a client socket ~3.7 KiB: TCP 2.31 + sock_inode 0.81 + filp 0.25 + dentry
0.19 KiB). Sysctls set to a 2 GB droplet's defaults: tcp_mem 22000 29400 44000, tcp_rmem 4096 131072 6291456,
tcp_max_orphans 16384, tcp_max_syn_backlog 256 (originals in `/root/watlab/w3/sysctl.orig`: tcp_mem 1572864
2097152 3145728, rmem 4096 16384 4194304, orphans 1048576, syn_backlog 1024; somaxconn 4096 and min_free_kbytes
67584 unchanged); to be restored at the end. Build `b7792` = 7792fa9 (opt-box build, AOT on Synteq; app.so
identical to out/e36). All 2-minute runs at 210,000 users:
- h1, deploy user, page cache dropped before start, no hog: collapse (13.7k rps, p95 5.3 s, 29.6 % errors,
  187,533 connect errors), TCP memory 390k pages, server at ~95 % CPU. h2, TdscWat2's root ubs.sh, same app:
  22.2k rps, p99 4.3 ms. h3, deploy user, no cache drop: 22.2k, p99 51 ms. So the non-root user and limits
  are not the cause (all 8 rings come up under memlock 8 MiB); a cold or short page cache is.
- h4 (healthy, 16 GB): server-side kernel memory per connection ~3.7 KiB + ~0.35 KiB of io_uring recv state
  (io_kiocb, kmalloc-96), ~850 MB at 210k, mostly outside the server's cgroup (allocated in softirq).
- h5, h6 with FAITH=1: 14.3k / 14.9k rps, p95 3.9 / 5.3 s, p99 5.3 s, 78k / 95k requests stuck in flight, 0 %
  errors in ul. Reproduced. Sequence: at the end of the ramp the WAL reaches 500 MiB (CKPT_FRAMES 128,000) and the
  first checkpoint stalls the loop; tens of thousands of sockets queue a request meanwhile, each charging at least a
  page to tcp_mem, TCP memory jumps to 60-90k pages, past the 2 GB box's hard limit (44,000), the kernel prunes and
  drops, and CPU per request doubles (ul 13.6 -> 28-30 us/req). The server never catches up; page cache was ~650 MB
  (DB 243 MB + WAL 500 MB don't fit). Not seen on 16 GB because tcp_mem there is 70x larger.
- Consult (DeepSeek + Gemini, session 1103-090543-2964): both say "connection refused" (RST to SYN) means no
  listener, i.e. the process died (OOM kill, or a crash loop past systemd's start limit), not a stall. DeepSeek's
  tcp_mem formula (/8, 2x mine) is wrong: opt-box (4 GB) has 45114 60155 90228 = /16, so a 2 GB box has ~22.5k/30k/45k
  as set. Rejected: async DB xSync and journal_mode=MEMORY (rule 6), checkpoint on another thread (one wasm
  instance, SQLite not shared). ENOBUFS recv is re-armed (checked, `$on_recv`). The scorer's c193a82 notes fit a death:
  "2-minute probes passed 240k and 260k... the 260k 5-minute hold collapsed at 47 % errors, nearly all connection
  refused". hs.sh so far protected both the hog and (by size) ul from the OOM killer only by luck: from here ul gets
  oom_score_adj -1000 too, so a memory death lands on the server, as it would on the droplet.

## E38: CKPT_FRAMES 4,000 vs 16,000 at 250k (3 Nov, Synteq, hs.sh FAITH=1, b7792, env only) — 4,000 better
Per-second counters added to hs.sh (server CPU and state, read_bytes, kswapd/direct scans, major faults, TcpExt
PruneCalled / TCPRcvQDrop / TCPMemoryPressures). Two earlier 16k runs at 250k: 25.8k rps p95 2.0 s; and 12.8k rps,
3.35 % errors: from the end of the ramp kswapd scans ~100-300k pages/10 s, the server reads 150-250 MB/10 s (re-reading
the 63 MB WAL at each checkpoint, ~every 4 s, once LRU has evicted it), thousands of major faults, PruneCalled
~300k/10 s, TCPRcvQDrop up to 25k/10 s, D state, CPU ~60 %. MemAvailable (~600 MB) overstates: ~250 MB of it is
socket inode/dentry slab pinned by open sockets. Interleaved, 2 reps, 2-min:
- 4,000: 26.1k / 26.3k rps, p95 290 / 215, p99 2,435 / 320 ms, max 5.2 / 0.8 s, read 62 / 44 MB, prune 349 / 578
- 16,000: 25.7k / 26.0k rps, p95 2,015 / 1,330, p99 5,320 / 5,320 ms, read 82 / 83 MB, prune 904k / 725k
4k: WAL 16 MB stays cached; p50 rises (6.8-9.9 vs ~2 ms, more checkpoints). The 4k r1 tail: one kswapd event at
mid-run (47k pages scanned, 361 major faults, 26 MB read, CPU dip, TCP 33k pages). 4k r2 passes at 250k.

## E39: 4,000 and 2,000 frames at 280k (3 Nov, Synteq, hs.sh FAITH=1 with ul OOM-protected) — the scorer's failure reproduced
Both runs: at the end of the ramp the loop stalls (D state, ~600 MB read in 20 s, major faults), each user's next
request queues in the kernel, TCP memory reaches 173k pages (676 MB, ~4x tcp_mem's hard limit) and the kernel OOM
killer kills the server: `watsrv.service: Failed with result 'oom-kill'`, every later dial fails (5.7M / 6.5M
connect errors = "connection refused", 98-100 % errors). That is the scorer's "connection refused at ~55 % CPU":
an OOM kill, not a stall. dmesg: "ul invoked oom-killer ... tcp_stream_alloc_skb".

## E40: 4,000 frames at 250k, residency (3 Nov, Synteq) — measurement
26.3k rps, p95 220, p99 365 ms, 0 errors (4k at 250k: 2 passes of 3). Server smaps at steady state: anon 85 MB,
libwasmedge.so resident 5.6 MB, io_uring rings 4.2 MB, app.so < 2 MB: the code in use (~7.5 MB) fits the default
8 MiB RLIMIT_MEMLOCK. `bin/fc` (mincore, `/tmp/tdsc-wat3/fc.c`) now samples the page-cache residency of app.so,
libwasmedge, feed.db and the WAL every 2 s.

## E41: lock the code in memory (3 Nov, host.c `pincode`, PIN=0 turns it off) — kept for now, no gain shown
The WAL-sync thread mlocks app.so's code, then the resident pages of the other libraries' code, every 5 s for the
first minute, until mlock fails at the limit (VmLck reached 8,192 kB). 270k, 4k frames: pinned and unpinned both
OOM-killed at the end of the ramp (99.0 / 99.6 % errors); the pinned run's trace: kswapd from ~1 GB available,
then TCP memory 3k -> 90k pages in 10 s, feed.db's page cache 243 MB -> 0, libwasmedge 49 -> 2 MB, disk reads,
OOM. Memory is the edge at 270k on this harness (the scorer's: f220565 held 270k, died at 280k; c193a82 died in a
260k hold, so the harness is about right, maybe slightly pessimistic). Server-side kernel memory per connection
(~3.8 KiB socket + ~0.35 KiB io_uring) is ~41 MB per 10k users and can't be cut, so the room has to come from what
the loop needs that can be evicted: DB pages, WAL pages, code.

## E42: SQLite page cache 64 -> 256 MiB (3 Nov, b42 = E41 + cache_size=-262144, 4k frames by env) — no effect on RSS
250k: 26.3k rps, p95 190, p99 290, max 514 ms, 0 errors, 4 MB read, 0 prunes (cleanest 250k so far), but server RSS
stayed 116 MB: SQLite never held more than ~64 MB, so the larger limit changed nothing and 250k at 4k frames just
varies (now 3 passes of 4). 270k: OOM-killed (73.6 % errors). Trace: at the end of the ramp feed.db's page cache
243 -> 0 MB and libwasmedge 49 -> 2 MB within 12 s, then a sustained thrash for 70+ s: TCP memory 100-170k pages,
PruneCalled ~40k/s, kswapd and direct reclaim every second, major faults, server at 60-100 % CPU, until the OOM kill.
At 270k this harness's box is full with sockets alone (MemAvailable 550-630 MB, of which ~270 MB is socket
inode/dentry slab pinned by open sockets). Next: calibrate the harness on a build the scorer has scored.

## C1: calibrating hs.sh on a build the scorer scored (3 Nov, Synteq) — in progress
f220565 (`out/e26`) on the scorer: 270k held 5 min, 280k probe "connection refused" (71 %). On hs.sh:
- SRVMB 1650, tcp_mem 22000 29400 44000: 270k OOM-killed at the end of the ramp (99.8 % errors). Too harsh.
- SRVMB 1800: 270k 14.2k rps, p95 5.3 s, 3.2 % errors, 2.0 GB read; 280k the same. Not killed, but thrashing.
- SRVMB 1800, tcp_mem doubled to 45000 60000 90000 (on loopback the one global limit also carries the load
  generator's queued and retransmitted requests, which on the scorer sit on the k6 machines): 270k 12.5k rps,
  p95 5.3 s; 280k OOM-killed (91 %).
Snapshot in the 270k thrash: TCP memory 115k pages (450 MB), skbuff_small_head 118 MB, a 512-byte slab
(pool_workqueue, merged) 87 MB that healthy runs don't have; AnonPages: hog 10.4 GB + ul ~2.2 GB (8.2 KiB/user)
+ server 0.1 GB. A 16 GB box also has two zones (lowmem reserve) and min_free_kbytes 67 MB that a 2 GB droplet
doesn't lose the same way. Rather than model every term, SRVMB is fitted to the scorer's numbers.
- SRVMB 2000 (tcp_mem doubled): 270k p99 74 ms, 280k p99 127 ms, both clean: too generous (the scorer killed 280k).
- SRVMB 1900: 280k p95 695, p99 5.3 s (fails, not killed); 270k (rerun; the first try overlapped an AOT
  compile on the box and was void) 28.5k rps, p95 70, p99 230 ms, 0 errors: holds, as on the scorer.
**Calibrated harness from here: hs.sh FAITH=1 SRVMB=1900, tcp_mem 45000 60000 90000.** It matches f220565's
scorer result (270k held, 280k failed); a bit generous at 280k (fails on latency, the scorer's died).

## E43: 4,000 frames by default + code pinning (E41) + CONN/GEN tables not zero-filled (3 Nov, b43) — kept
`$ck_t` default 128,000 -> 4,000 (CKPT_FRAMES still overrides), cache_size back to 64 MiB, `memory.fill` of the
16 MiB CONN and 2 MiB GEN tables dropped (a slot's CONN entry is zeroed when a connection lands in it; a GEN value
only has to match itself). Calibrated harness, 2-min:
- 270k: 28.4k rps, p50 16.7, p95 215, p99 330, max 505 ms, 0 errors, 0 MB read, 0 prunes, RSS 119 MB
- 280k: 29.5k rps, p50 29.8, p95 235, p99 365, max 570 ms, 0 errors, 0 MB read, RSS 141 MB
(f220565 = e26 on the same harness: 270k p99 230; 280k fails.) p50 is higher than with large checkpoints (one
every ~1 s now), well inside the limits.

## E44: E43 at 300k / 320k, and a control (3 Nov, calibrated harness, 2-min)
- control: 7792fa9 with CKPT_FRAMES=4000 by env only, 280k: 29.3k rps, p50 54, p95 370, p99 980, max 2,122 ms
  (b43 at 280k: p95 235, p99 365), so pinning and the untouched tables help (one run each)
- b43 300k: 31.4k rps, p50 73, p95 405, p99 850, max 1,591 ms, 0 errors, 0 MB read, CPU ~88 %
- b43 320k: 31.2k rps (short of ~33.4k), p50 315, p95 4,020, p99 5,320 ms, 0 errors, CPU 90-91 %: CPU-bound
  (TCP memory < 35k pages, nothing read from disk). ~28 us/req, as before. Edge ~300-310k on this harness.

## H1: 5-minute holds of b43 (= f3e9410) (3 Nov, calibrated harness)
- 280k: 29.4k rps, p50 36, p95 280, p99 480, max 1,421 ms, 0 errors, 0 MB read — passes
- 290k: 30.2k rps, p50 80, p95 515, p99 1,645, max 3,097 ms, 0 errors — fails
- 300k: 31.2k rps, p50 92, p95 555, p99 1,215, max 2,553 ms, 0 errors — fails
Not memory any more (no reads, TCP memory < 14k pages, RSS 115 -> 159 MB as SQLite's cache fills): CPU 85-90 %
(~28.5 us/req) plus the checkpoints' fixed cost (~3 syncs on the loop each, one checkpoint per ~1 s).

## E45: CKPT_FRAMES 8,000 vs 4,000, 5-minute holds at 290k (3 Nov, b43, env; calibrated harness) — 8,000 kept
Interleaved, 2 reps, 0 errors everywhere, nothing read from disk:
- 8,000: 30.4k / 30.4k rps, p50 21 / 29, p95 325 / 345, p99 600 / 585, max 1,548 / 1,138 ms, ul us/req 15.8 / 16.3
- 4,000: 30.3k / 30.4k rps, p50 60 / 56, p95 385 / 360, p99 855 / 740, max 2,220 / 2,168 ms, ul us/req 16.8 / 16.4
Half as many checkpoints (each ~3 syncs on the loop and a copy of every hot page) for 16 MB more WAL in the
page cache. (H1's 4k hold at 290k failed; 4k passed both holds here: the edge varies hold to hold.)

## E46: 8,000 frames by default (3 Nov, b46), 5-minute holds — kept
42/42 (opt-box). Calibrated harness:
- 300k r1: 31.4k rps, p50 61, p95 440, p99 795, max 1,851 ms, 0 errors — passes (b43, 4k frames, failed here)
- 310k: 32.3k rps, p50 77, p95 535, p99 1,290, max 2,745 ms, 0 errors — fails
- 300k r2: 31.2k rps, p50 73, p95 625, p99 1,945, max 19.1 s, 0 errors — fails: at the end of the ramp the page
  cache was squeezed (feed.db 241 -> 22 MB, WAL 31 -> 18 MB within 30 s), checkpoints read the WAL back
  (121 MB read), TCP memory spiked to 81k pages; recovered, no OOM. MemAvailable low-water 724 MB (of which
  ~300 MB is socket inode/dentry slab pinned by open sockets).
300k is a coin flip on this harness (memory and CPU both run out there); 290k held 2 of 2 (E45).
Consult (same session, round 2): mlock is a setting inside the process (fails soft here: a failed lock just
stops pinning) but must be A/B'd on its own (E47); don't headline 300k; the harness can't see the NIC's receive
softirq on the server's one vCPU (on loopback it runs on the client's CPUs) or the scorer's back-to-back probes.
Rejected: DeepSeek's tcp_mem formula again (/8; opt-box measures /16), the fd-limit worry (fixed-file slots
don't count against LimitNOFILE; the scorer held 270k with f220565).

## E47: code locking on/off (3 Nov, b46, PIN=0 by env), 5-minute holds at 290k — kept
Interleaved, 2 reps, 0 errors, ~0 MB read:
- pinned: p50 21 / 29, p95 315 / 350, p99 530 / 575, max 1,015 / 1,227 ms
- PIN=0:  p50 44 / 30, p95 395 / 345, p99 720 / 605, max 2,050 / 1,679 ms
A modest gain in p99 and max. With E45, four 5-minute holds at 290k passed with 8,000 frames and pinning.

## PR #288 (3 Nov): follow-up to #272 from `wat-wasm-delneg-3` at c3f81f7
Clean ubuntu:24.04 container build (opt-box ci2.sh): 42/42. Body through humanizer-v3, every number marked as ours.

## M3: where the CPU goes at 280k (3 Nov, Synteq, calibrated harness, debug-names build of c3f81f7)
perf record -F 997 on the server for 30 s, 40 s after the ramp (that run: 29.4k rps, p95 325, p99 575 ms).
By library: kernel 64.6 %, app.so 32.7 %, libc 1.3 %, libwasmedge 1.1 %. Kernel: network/TCP ~32 %, locks 6 %,
AppArmor's socket hooks 3.5 %, io_uring only 3.0 %, rest (copies, page clears, wakeups) ~20 %. Top symbols:
sqlite3BtreeTableMoveto 5.8 (mostly the 20 author seeks per /feed), __inet_lookup_established 5.4, record 2.2,
rep_movs 1.9, pcache1Fetch 1.8, putjson 1.6, BtreeIndexMoveto 1.4, bt_post_out 1.2, getPageNormal 1.2.
Our code is ~9 of the ~28 us per request; most of the rest is TCP work every entry pays.
Harness gap found here: the established-socket hash has one bucket per 128 KiB of RAM, 131,072 on this 16 GB box
(both ends' sockets, ~4 per chain at 280k) against ~16,384 on a 2 GB droplet (~18 per chain at 290k, server side
only), and every incoming packet walks a chain, so the droplet pays more per request than this box shows. A boot
with `thash_entries=32768` would match the chain length; not done.

## E48: POSIX_FADV_WILLNEED on the WAL after each 100 ms sync (3 Nov, b48 = c3f81f7 + that, WALWN=0 off) — dropped
Meant to keep a checkpoint's WAL reads off the disk when the ramp's end squeezes the page cache. 300k 5-minute
holds, interleaved, 2 reps, 0 errors:
- WILLNEED: p50 60 / 65, p95 455 / 470, p99 880 / 1,025, max 1,758 / 2,954 ms, 0 MB read
- off:      p50 45 / 49, p95 370 / 405, p99 680 / 725, max 1,541 / 2,078 ms, 21 / 0 MB read
Worse with it (the readahead walk every 100 ms, and it keeps 32 MB hot that the kernel would rather reclaim);
reverted. The "off" arm is the PR head's code: with E46, 300k now holds in 3 of 4 runs on this harness.

## Wrap-up (3 Nov, TdscWat3)
Synteq's sysctls restored to `/root/watlab/w3/sysctl.orig` (checked with diff); hog and server stopped; perf data
deleted. Left on Synteq: user `deploy` (+ /home/deploy/we, the WasmEdge lib copy, 108 MB), hs.sh, q.sh, hog.py,
samp.py, prof.sh, bin/fc, out/b7792..b48, w3/ logs (5 MB). To rerun the calibrated harness, set tcp_mem
45000 60000 90000, tcp_rmem 4096 131072 6291456, tcp_max_orphans 16384, tcp_max_syn_backlog 256, then
`SRVMB=1900 MEAS=300 bash q.sh <name> "<label> <build> <users> [ENV=..]"`.
Not done: a boot with thash_entries=32768 (M3), back-to-back holds without a restart, CPU work in the app
(our code is ~9 of ~28 us per request; most of the rest is TCP).

## Cut C (3 Nov, TdscWat3): a separate pass to cut host.c + sqlite_glue.c (232 + 127 = 359 lines at f3e9410)
Gate for each cut: 42/42, and no speed loss beyond noise in 5-minute holds at 290k on the calibrated harness.

## E49: the glue's public-API wrappers go; the WAT calls SQLite directly (b e49) — kept
`build.sh` exports from the C module each function `app.wat` imports (sqlite3_exec, _prepare_v3, _step,
_column_*, _wal_hook, _wal_checkpoint_v2, getenv, malloc, ...) and the function table (`--export-table
--growable-table`). The WAT grows the table by 10 and fills it from a passive element segment: its own WAL
hook (`$wal_cb`) and the page-cache wrapper (`$pc_create` .. `$pc_shrink`, installed with sqlite3_config
GETPCACHE2/PCACHE2; the variadic argument goes as a pointer to it). `ENC(db)` (internal) became `PRAGMA
encoding`. Dead exports db_last_rowid and mem_realloc dropped. sqlite_glue.c 127 -> 42 lines (the B-tree
wrappers stay: they call SQLite's internal B-tree functions, reachable only from its translation unit).
Checked with a throwaway build that logs from the wrapper: 5 caches created, truncates skipped. 42/42.
Interleaved, 2 reps, 0 errors:
- e49:         p50 23 / 35, p95 320 / 370, p99 550 / 690, max 1,505 / 1,554 ms, 16.2 / 17.0 us/req
- head df9da40: p50 44 / 31, p95 420 / 355, p99 850 / 690, max 2,196 / 1,649 ms, 17.1 / 16.8 us/req
No loss.

## E50: listen, the provided-buffer ring and the fixed-file table move to the WAT via one `syscall` import (b e50) — kept
host.c gets one generic import, `syscall(nr, a1..a6)` (i64s, -errno on failure), and the WAT now does
socket/setsockopt/bind/listen, IORING_REGISTER_PBUF_RING (with the 6.8.0-147 retry), prlimit64 +
IORING_REGISTER_FILES2, and publishes the buffer-ring tail itself before each `ring_go`. WASI gets the whole
environment instead of six named variables. host.c 232 -> 202 lines.
Tried first and dropped: mapping each ring into wasm memory (mmap MAP_FIXED at membase + offset) so the WAT
could read and write the rings itself and `ring_go`/`ring_new` could go too. The kernel refuses it: mmap of
an io_uring fd at a caller-chosen address returns EINVAL (io_uring's get_unmapped_area rejects any address);
NO_MMAP on 6.8 needs one physically contiguous folio. So the rings stay mapped by C, outside wasm memory.
42/42 (opt-box, and the clean ubuntu:24.04 container build). Interleaved, 2 reps, 0 errors:
- e50: p50 28 / 30, p95 335 / 335, p99 570 / 570, max 1,146 / 1,249 ms, 16.0 / 16.4 us/req
- e49: p50 32 / 33, p95 385 / 410, p99 795 / 1,000, max 1,866 / 3,080 ms, 16.3 / 16.4 us/req
No loss. C lines: #259 195; #272 (7792fa9) 200 + 127 = 327; f3e9410 359; now 202 + 42 = 244.

## Score of PR #288 (3 Nov, benchmark agent's comment at 13:41 UTC, on df9da40)
200,000 held 5 min on the $12 box (19,619 req/s, p95 229 / p99 356 ms, 0 % errors, 68 % CPU, 32 us/req,
712 MB peak); 210k and 220k failed the 2-minute probe on p99 (1.5 s / 4.5 s, 0 errors, 69-75 % CPU); 240k
and 320k failed on connection refused (~80 % errors). A tie with #272, so not merged; the PR stays open.
Our harness held 290k at ~16 us/req: the droplet spends ~2x the CPU per request, so the harness is far too
lenient on CPU and tail latency (see M3's hash-chain gap) even though it reproduced the refusals.

## H2: a harness that fails where the scorer failed #288 (3 Nov, Synteq)
The loopback harness held 290k; the scorer held df9da40 at 200k and failed 210k/220k on p99 with 0 errors.
Two gaps found: on loopback the receive softirq runs on the sender's CPU, so the server's CPU never paid for
TCP receive, and the app ran at ~2x the droplet's speed per request.
Harness v2 (`hs2.sh` + `ns.sh` on Synteq): the server runs in its own network namespace, created after
`net.ipv4.tcp_child_ehash_entries=16384` (a 2 GB box's established-hash size; its max_syn_backlog comes out
128), reached over a veth pair; RPS steers the namespace's receive processing to CPU 0, the server's CPU,
and the client side's to CPUs 1-7; tcp_rmem/wmem set to a 2 GB box's values; the load generator dials from
32 source addresses. Same memory hog, systemd unit and limits as before. A harness-only build patch
(never committed) busy-waits SPIN_NS at the start of each request, to give the app the droplet's speed.
Calibration on df9da40 (2-minute probes, 0 errors in every run; scorer's numbers in brackets):
- no spin: 200k p95 175 / p99 285; 220k p95 172 / p99 275 (scorer: fails) -> still lenient
- SPIN_NS=17000: 200k p95 3,440 (scorer: holds) -> too harsh
- SPIN_NS=10000: 200k p95 245 / p99 380 [229 / 356]; 210k p99 2,035 [1.5 s, fail]; 220k p99 1,245 [4.5 s, fail]
So the harness from here on is v2 with SPIN_NS=10000. CPU 0 has no idle time at 200k (busy 86 %, the rest is
io_uring wait, which 6.8 counts as iowait). Caveat: the app cgroup shows 88 % of CPU 0 here against the
scorer's 68 %, so cgroup CPU % is not comparable between the two; the latency profile is what matches.
The #272 code (7792fa9) collapses at 200k on v2 (its 500 MiB WAL is reread from disk under memory pressure);
the scorer held it there and lost it at 210k, so it sits on a memory edge and is not used for calibration.
Where the p95 comes from (bpftrace on the loop thread, 200k): every ~2 s the loop stops for ~160 ms, ~140 ms
of it in 2-3 fsync/fdatasync calls: the inline PASSIVE checkpoint. ~8 % of wall time.
Considered and not done: a VFS whose DB xSync returns before the sync completes (io_uring FSYNC, writes held
back until it lands). Consult (DeepSeek and Gemini) both judged it a likely breach of "synchronous=NORMAL" in
spirit; not built.

## C3: Cut C (4e7ad9d) against df9da40 on harness v2 (SPIN_NS=10000), 5-minute holds at 200k — costs speed
Interleaved, 2 reps, 0 errors:
- 4e7ad9d: p50 19 / 24, p95 355 / 375, p99 635 / 630 ms, 17.2 / 16.7 us/req (process CPU)
- df9da40: p50 14 / 13, p95 330 / 325, p99 520 / 525 ms, 16.6 / 16.1 us/req
A third pair in the profile runs below gave the same sign (15.33 vs 14.60 us/req; p99 465 vs 435). The loopback
harness (E49, E50) could not show it: its CPU was never saturated. perf (30 s each, names builds): no single
symbol stands out; the kernel's share is ~2 points higher with the cuts (47.4 vs 45.3 %), app.so's lower. The
spin's WASI clock calls show up as libc rwlock + vdso (~13 %) in both; that is the harness, not the app.
Bisecting: 18c5199 (glue cut only) against df9da40 next.

## E51: checkpoint size on harness v2 (2-minute probes at 210k, 0 errors)
- 8,000 frames: p95 355, p99 565 (the calibration run with the same build gave p99 2,035: 210k is on the cliff)
- 2,000 frames: p95 1,015, p99 1,740 -> smaller checkpoints are worse
Why: a like writes one random leaf of sqlite_autoindex_likes_1 (7,511 leaves in the seed DB; posts_user_id_idx
has 1,342; the tables and the other indexes grow at their tails). A checkpoint writes each distinct page once,
so its fsync work is ~min(likes since the last one, 7,511) pages at ~65 us each on this disk (1,000 random
overwrites + fdatasync: 65 ms; one 4K overwrite 0.8 ms, an extend 2.2 ms). At 2 s per checkpoint that is
~2,400 leaves (~150 ms, as measured); at 32 s (#272's 128,000 frames) nearly all 7,500, i.e. ~5x fewer page
writes in total, which is why #272's p95 was 13 ms on the scorer. Bigger checkpoints: less sync work in total,
longer single stalls (capped near ~0.5 s), more WAL in the page cache. Next: 16,000 and 32,000 frames.

## C4: the glue cut alone (18c5199) against df9da40, same harness and holds — kept; the host cut is dropped
Interleaved, 3 reps of each, 0 errors:
- 18c5199: p95 305 / 290 / 340, p99 490 / 440 / 565 ms, 15.8 / 15.6 / 15.4 us/req
- df9da40: p95 295 / 330 / (c3: 330, 325), p99 455 / 675 / (c3: 520, 525) ms, 17.6 / 16.5 us/req
No loss from the glue cut (paired runs: 1.0-1.8 us/req lower, p95/p99 within the run-to-run spread). The loss in
C3 is the host cut's (E50): its code is reverted here (host.c back to 232 lines; C total 232 + 42 = 274). What in
it costs was not found (perf shows no single symbol); the README lists it as tried and dropped.

## E52: 16,000 / 24,000 / 32,000 frames, and the group-commit window (WINDOW_MS), harness v2, 2-minute probes, 0 errors
Checkpoint size (window 2 ms):
- 200k: 16,000 p95 240 / 210, p99 445 / 385 (two runs); 32,000 p95 1,485, p99 5,320 (the WAL is reread from
  disk: 159 MB read during the run; memory pressure)
- 210k: 8,000 p95 330, p99 500; 16,000 p95 215, p99 390; 24,000 p95 350, p99 960 (13 MB reread)
- 220k: 16,000 p95 495, p99 3,230; 24,000 p95 5,320 (115 MB reread) -> 220k fails at every size tried
- 230k: 16,000 p95 4,070
Group-commit window with 16,000 frames (new env knob WINDOW_MS, default 2 ms as before):
- 210k: 2 ms p95 230 / p99 410; 5 ms 220 / 395; 10 ms 285 / 695
- 220k: 5 ms p95 1,385 / p99 5,320; 10 ms 1,170 / 5,320
The window makes no difference beyond noise at 2-5 ms and hurts at 10. 16,000 frames is the only change that
moves 210k well inside the limits; 220k is past the edge (CPU 0 busy 94-95 %, page-cache rereads start).
Next: 5-minute holds, df9da40 against 16,000 frames, at 210k and 215k (h3).

## H3: 5-minute holds, df9da40 against 16,000 frames + WINDOW_MS=5 (harness v2, SPIN_NS=10000, conntrack off on veth0) — 16,000 dropped
NOTRACK rules for veth0 were added first (Docker on this box turns conntrack on in the root netns; the scorer's
box has no Docker). Interleaved, 0 errors:
- df9da40, 210k: p95 350 / 580, p99 555 / 1,430 ms; 0 MB of the database reread from disk -> 1 of 2 pass
- 16,000 frames, 210k: p95 450 / 410, p99 1,675 / 1,260 ms; 26 / 32 MB reread -> 0 of 2
- 16,000 frames, 215k: p95 740 / 470, p99 4,350 / 1,765 ms; 47 / 37 MB reread -> 0 of 2
The harness now matches the scorer at the edge (200k holds, 210k fails about half the time). The bigger WAL
(63 MB against 32 MB) costs the box page cache: the reads come in the ~15 s after the ramp ends, when the
sockets' kernel memory peaks, and they block the loop. The 2-minute wins in E52 did not survive 5 minutes.
Memory at 210k (slabtop, server side): ~4 KB of kernel memory per connection (TCP 2.3 KB, sock_inode 0.8 KB,
filp, dentry, io_kiocb 0.25 KB + async poll 0.1 KB for the armed recv), ~840 MB in all; server RSS ~150 MB.
Consult (DeepSeek, Gemini), what next: a longer commit window (Gemini) is already measured worse (E52); a
native SQLite in the host sharing the wal-index (Gemini) adds a second SQLite to the C, not done; a clustered
likes key or a stored like count (DeepSeek) changes the schema or comes close to caching, not done without the
owner. Taken up: check whether 240k's refusals are memory or a queue (next), and whether the p99 spikes line
up with checkpoints or with reclaim.

## H4: what happens at 240k (df9da40, harness v2, 2-minute probe) — capacity, not a bug
p50 600, p95/p99 5,320 ms (capped), 0 errors in ul (it waits; k6 on the scorer times out or is reset, not
seen here), 21.7k req/s against ~25k asked, CPU 0 busy 98 %. ListenOverflows 0, ListenDrops 0, no OOM kill,
0 MB reread. With the loop behind, nearly every connection holds a request in its socket: TCP memory went
50k -> 103k pages (tcp_mem 45,000 / 60,000 / 90,000), PruneCalled +48,676, TCPMemoryPressures up. So 240k
asks for more requests than one vCPU serves; the memory blow-up follows from the backlog.
Pinning the database's page cache (DeepSeek's idea, to make 16,000 frames safe) is out: a non-root unit has
RLIMIT_MEMLOCK 8 MiB (VmLck 8,192 kB), which the code pinning already uses.
Synteq sysctls restored from w3/sysctl.orig; the calibrated values are in w3/sysctl.cal.

## TdscWat4 (3 Nov on): hypotheses first (experiments/hypotheses.md, append-only, locked), then E53+
Paid calls tally (limit $1): consult 1103-205423-0386 round 1 $0.0233, round 2 $0.0177, round 3 $0.0087. Total $0.050.
Boxes: Synteq (harness v2 = hs2.sh/q2.sh, SPIN_NS=10000 unless marked), opt-box (builds).

## E53 (H3): fsync cost against dirty pages, Synteq disk (3 Nov, root, `bin/fsb`, source /tmp/tdsc-wat4/fsb.c)
A copy of the seed feed.db (243 MB); N random 4 KiB pages read and rewritten in place, then one fdatasync; 3 reps each
(ms): N=1: 1.3, 1.5, 156 (one outlier, likely an ext4 journal commit); 10: 2.1-2.6; 30: 3.1-4.5; 100: 5.7-7.1 (one 20);
300: 20-42; 1,000: 73-89; 2,400: 147-150. So ~1.3 ms floor and ~60 us per page above ~100 pages: today's checkpoint
(~2,400 leaves) is the 150 ms stall measured on the loop. Verdict H3: the cost scales with dirty pages, not a fixed floor,
so a tail checkpoint of <= ~30 pages costs ~3-5 ms. H1's inline tail is viable if the tail stays that small.
(/dev/sda1, ext4 commit=30, discard, mq-deadline, non-rotational.)

## E54 (H1): checkpoints on a second wasm instance, first build `h1a` (3 Nov, harness v2, SPIN_NS=10000, 2-minute probes, 210k)
Build: sqlite_glue.c gets a VFS "shmx" wrapping unix-none with xShmMap/xShmLock/xShmBarrier/xShmUnmap (one memfd mapped by
the host into a page-aligned 8 MiB slice of each instance's memory; lock words and handshake are host atomics); host.c
starts a pthread (nice 10) running a second WasmEdge VM on the same app.so (`_initialize`, then `ckpt_main`: own
connection, PASSIVE on request, polls every 1 ms); app.wat opens with "shmx" and locking_mode NORMAL, and `$ckpt_step`
calls `ck_tick`: WAL >= 8,000 frames -> bulk pass on the checkpointer; while frames since > CKPT_TAIL (300) another pass;
then one inline PASSIVE (the tail) and the next write restarts the WAL. SHMX=0 keeps the old path. 42/42 (opt-box).
Functional check (opt-box, CKPT_FRAMES=200, 3,000 likes over curl): WAL stayed at 1.45 MB (restarts happen), the DB file
grew, integrity_check ok, 3,000 new likes present.
Interleaved (b4s = c49b70d with the spin patch, i.e. f5115b9's code; h1as = this build with the spin patch), 0 errors:
- b4s r1: 21.9k rps, p50 39, p95 460, p99 1,305, max 1,901 ms, 16.16 us/req, prune 96,831
- h1as r1: 22.0k rps, p50 32, p95 340, p99 690, max 1,159 ms, 18.67 us/req, prune 10,978
- b4s r2: 22.1k rps, p50 33, p95 410, p99 1,000, max 2,102 ms, 16.48 us/req
- h1as r2: 22.1k rps, p50 5.4, p95 260, p99 410, max 631 ms, 17.89 us/req
The tail moves well inside the limits at 210k (both h1 runs pass; both b4 runs fail p99 >= 1 s), but the server process
spends +1.4-2.5 us per request more. Next (E55): where that comes from, at 150k (below the cliff, CPU per request only).

## E55 (H1/H12): where h1a's extra CPU goes (3 Nov, harness v2, SPIN_NS=10000, 2-minute probes at 150k, below the cliff)
- b4s: 15.9k rps, p95 127, p99 240 ms, 11.91 us/req, CPU0 busy 63 %
- h1as: p95 106, p99 215 ms, 13.47 us/req, busy 64 %
- h1as SHMX=0 (same binary, old exclusive path): p95 129, p99 240 ms, 11.82 us/req, busy 61 %
- h1as CKPT_NAP_US=20000 (checkpointer polls every 20 ms instead of 1 ms): p95 119, p99 230 ms, 12.50 us/req, busy 62 %
The new binary costs nothing on the old path. Of h1a's +1.56 us/req, ~1.0 is the checkpointer's 1 ms polling (a
thread wakeup plus host calls 1,000 times a second, on the same CPU); the rest (~0.6) is the shared mode itself (read
locks per transaction through host calls, the barrier host call) plus the extra tail checkpoints. Next: h1b with a futex
wait instead of polling, one host call per xShmLock, and an empty xShmBarrier (an indirect call is a compiler barrier and
x86 keeps load-load and store-store order, which is all SQLite's two header copies rely on).

## E57: verdicts by measurement and arithmetic, no server runs (H5, H7, H8, H9, H14) (3 Nov)
- H5: SQLite built with `-mno-bulk-memory` gives a byte-identical merged.opt.wasm (sha256 1f27de56... both ways): clang
  then calls wasi-libc's memcpy/memset, which are themselves `memory.copy`/`memory.fill`, and wasm-opt -O3 inlines them
  back (sq.wasm: 320 copies / 159 fills; merged: 334 / 165). The flag can't remove them. Avoiding them needs our own
  memcpy/memset in the glue (a loop the AOT may turn back into a native call). Upper bound from M3's profile:
  libwasmedge 1.1 % + libc 1.3 % of CPU. Left as a low-value follow-up (H5b), not built.
- H7 (JWT offload): only likes and posts carry a JWT, 0.17 of every 2.17 requests (7.8 %). The HMAC pads are set up once
  at start (`$hmac_init`), so a check is ~3 SHA-256 blocks (~1 us in wasm at a few hundred MB/s). Averaged over all
  requests that is < 0.1 us of ~28-35 us. A plugin (wasi_crypto) or a native host import can't save more than that, and
  the Xeon 8260 has no SHA-NI. Dead.
- H8 (HTTP compression): /feed is 5,102 bytes (4 TCP segments), GET /posts/:id 361. gzip -1 makes /feed 1,982 bytes, but
  zlib level 1 costs 38.5 us per /feed natively (opt-box, Python's zlib): more than the whole request costs today, for ~2
  fewer segments (a few us of kernel at most). k6 decompresses gzip and probably sends Accept-Encoding (unverified, from
  memory of k6's Go client); load.js sets only Authorization and Content-Type. Dead on CPU, whatever k6 sends.
- H9 (C -> Rust): the host binary doesn't appear in M3's profile (kernel 64.6 + app.so 32.7 + libc 1.3 + libwasmedge 1.1 =
  99.7 %): <= 0.3 % of CPU, the same LLVM code either way, not fewer lines, and a Rust toolchain to pin in install.sh.
  No speed to gain. Dead for speed (only a matter of taste).
- H14 (registered ring fd): S12 counted 79,704 io_uring_enter in 20 s at 31.6k req/s, 0.13 per request; skipping the
  fdget/fput (~50 ns) saves < 0.01 us/req. Dead.

## E56 (H1): h1b = futex instead of polling, one host call per xShmLock, empty xShmBarrier (3 Nov, harness v2, SPIN_NS=10000, 2-minute probes, 0 errors)
- 150k: b4s p95 118, p99 220, 11.96 us/req; h1bs p95 106, p99 215, 11.79 us/req -> the overhead is gone (E55 had +1.56)
- 210k: h1bs r1 p50 5.8, p95 275, p99 440, max 744 ms, 16.15 us/req; b4s p50 38, p95 350, p99 550, max 967 ms, 17.07; h1bs r2 p50 3.6, p95 240, p99 390, max 601 ms, 15.59
With E54's two baseline runs, b4 at 210k is p99 1,305 / 1,000 / 550 and h1 is 690 / 410 / 440 / 390. CPU 0 is busy 88 % against 91 %.

## E59 (H10, H5b): WAT against clang -O3 and rustc opt-level=3 wasm, routine by routine (4 Nov, opt-box, AOT --optimize=3, one CPU, best of 5, source /tmp/tdsc-wat4/cmp, ~/watlab/compilers)
ns per call, all merged and put through wasm-opt -O3 like the entry; WAT = the functions copied out of app.wat:
- SHA-256 block: WAT 205, C 219, Rust 215. A hand-written round loop beats both compilers; nothing to learn there.
- integer formatting (6 digits): WAT 9.8, C 11.8, Rust 12.5.
- JSON string, 12 / 47 / 200 clean bytes: WAT 12.7 / 18.6 / 21.9; C 9.2 / 12.8 / 17.5; Rust 9.4 / 13.0 / 17.5.
  The compilers keep the write cursor in a local for the whole loop; our WAT wrote the global $w on every step and
  called $put/$putc for the rest. Taken from them: the local cursor. Added beyond them: the bytes after the last full 16
  are checked with one overlapping 16-byte load, instead of a byte loop.
  New $putjson: 12.9 / 5.9 / 15.7 ns (the short case is unchanged, it has no full block). A differential check against the
  C version: 0 mismatches over 3M random strings with quotes, backslashes and control characters.
  At ~40 putjson calls per /feed (20 bodies, 20 usernames) that is at most ~0.3 us per /feed, ~0.15 us per request.
- memory.copy (H5b): 8-40 bytes 5.8 ns against an inline loop's 2.4-3.2; 100-200 bytes 6.3-7.0 against 6.7-8.6. So the runtime
  call costs ~3 ns on small copies, not the tens of ns we assumed. SQLite's copies aren't worth replacing: dead.
The compiler output has no trick that moves the total: our own code is a small slice of ~28-35 us and most of it matches or beats them.

## E58 (H1): 5-minute holds at 220k on harness v2 with the spin (4 Nov) — no gain there, because that harness is CPU-bound
- h1bs: 22.8k rps, p50 92, p95 715, p99 1,380, max 2,208 ms, 0 errors, CPU 0 busy 95 %
- b4s: 22.8k rps, p50 115, p95 735, p99 1,215, max 2,461 ms, 0 errors, CPU 0 busy 93 %
Both fail. With 10 us of spin per request CPU 0 has no room at 220k, so taking the stall off the loop can't help; the scorer ran 220k at
69-75 % CPU, so it was not out of CPU there (fact F2 in hypotheses.md). The rest of that queue (repeat pair, 230k, 240k) was stopped: more
spin runs can't answer the question. Next: H2, a harness without the spin whose disk is slowed instead.

## E60 (H1): correctness of the shared wal-index (4 Nov, opt-box, `h1check.py`, CKPT_FRAMES=100 so checkpoints never stop; DeepSeek asked for this before trusting any number)
8 writer connections (random user, random post) + 4 oracle connections: one post each, distinct users in order, and after each 201 a GET
must show exactly one more like; then kill -9 under load; the database is opened with native SQLite; the server restarted on it.
k2: 16,260 read-your-writes checks, 0 stale; 110,378 acked likes, 0 missing after kill -9; integrity_check ok; restart: /health 200, /feed fine.
k3 (below): 15,927 checks, 0 stale; 107,933 acked, 0 missing; integrity ok. The WAL at the kill was 45.7 MB in k2 with a 100-frame threshold:
if passes can't catch up it would keep growing, so k3 adds a limit: past 3x the threshold the loop does one inline checkpoint (11.7 MB at the
kill). In the 220k holds it peaked at 46 MB, so passes do converge there. 42/42.

## E61 (H2): harness v3 = v2 without the spin, the disk slowed by a cgroup cap (hs3.sh/q3.sh on Synteq; 4 Nov)
The cap (`IOWriteIOPSMax=/dev/sda N` on the unit) only bites if the file's inode belongs to the unit's cgroup (writeback goes to the inode's owner), so the unit
copies the seed itself in ExecStartPre (a plain systemd-run on a file made by root's shell showed no slowdown at all). fsb, 2,400 dirty pages: no cap ~170 ms; 8,000 IOPS 250 ms; 4,000 525 ms; 2,000 1,110 ms.
Baseline (b4 = c49b70d, no spin), 2-minute probes, 0 errors in all:
- 8,000: 210k p95 194, p99 295
- 4,000: 200k p95 305, p99 430; 210k 345 / 490; 220k 350 / 500; 240k 455 / 700
- 3,000: 210k p95 495, p99 685; 220k 530 / 745
Scorer on df9da40: 200k 229 / 356 held; 210k p99 1.5 s; 220k p99 4.5 s; 240k+ refused. The app cgroup now uses 64-68 % of CPU 0 at 200-210k, as the scorer's 68 %, which the spin build didn't (88 %).
But it has no cliff at 210k: the tail grows smoothly. So neither calibration reproduces the scorer: the spin gets the cliff by running out of CPU the scorer still has, and the cap gets the CPU right
without the cliff. Whatever turns ~70 % CPU into p99 1.5 s on the scorer isn't modelled yet. A harness caveat, not a result.

## E62 (H1, H26): baseline against H1 on harness v3, ENOBUFS and loop gaps (4 Nov, cap 3,000 IOPS, no spin, 2-minute probes, 0 errors)
- 240k: k3 p50 18, p95 535, p99 780, max 1,345 ms; b4 p50 59, p95 625, p99 895, max 1,324 ms
- 260k: k3 p50 83, p95 665, p99 1,025, max 1,754 ms; b4 p50 97, p95 680, p99 985, max 1,748 ms
- 280k: k3 p95 2,150, p99 4,110; b4 p95 1,740, p99 2,885 (CPU 0 busy 94 % / 89 %)
So H1 as built gains little under the cap, and the reason is measurable (gap.bt on the loop thread, k3 at 240k, p95 570, p99 820):
273 loop gaps > 40 ms in ~180 s, mean 176 ms, worst ~490 ms, each with ~3 fsyncs on the loop thread (sync_ms ~ gap): the inline tail. At up to 300 frames, under
a slowed disk and behind the bulk pass's queued writes, the tail is far from the few ms E53 implied on the free disk. Next: CKPT_TAIL=30 (E63), and if needed H1c (hold writes, no sync on the loop at all).
H26 (bpftrace enob.bt, baseline b4 at 220k): 315,223 receives ended -ENOBUFS out of 8.98M completions, ~3,000 per second at 22k req/s: during each long stall a ring's 2,048 buffers run dry, and each of those
connections takes a re-arm. CQ overflow only at the end of the run (135k, when the load generator closes every connection). k3 at 240k: 403,123 (its stalls are still long).

## E63 (H26, H24, H27): smaller buffers, smaller tail, nice (4 Nov, harness v3, cap 3,000 IOPS, 2-minute probes, 0 errors)
Buffers (8,192 x 512 B per ring instead of 2,048 x 2 KiB, same 4 MiB). bb = b4 with them, k4 = k3 with them:
- 240k: b4 625/895, bb 590/850; k3 535/780 (570/820 with bpftrace), k4 525/770
- 260k: b4 680/985, bb 965/2,415 (one bad run); k3 665/1,025, k4 600/875 and 595/900
H26 verdict: ENOBUFS gone (0 of 9.1M completions, was 403k), which helps a little at most: the stalls are the cost, the storm a side effect. Kept, costs nothing.
k4 CKPT_TAIL=30 (H24): 240k 525/780, 260k 585/855. Nothing: gap.bt still has ~195 gaps > 40 ms in 180 s, mean 209 ms, 3 fsyncs each, sync_ms ~ gap (184, 353, 438 ms). So the size of the tail
isn't the cost. Each inline fsync waits for the disk under the writes already queued, whatever the tail adds. H24 done for the tail. (pw=0 in those lines isn't real: WasmEdge's WASI doesn't use pwrite64.)
CKPT_NICE=0 (H27): 260k 560/840 against 585/855, within noise. Dead.
Without the cap, k4 CKPT_TAIL=30 at 240k: 198/325.

## E64 (H1c): writes held while the checkpointer finishes, no sync on the loop at all (4 Nov, harness v3, 2-minute probes, 0 errors)
k5 = k4 + hold, sha256 afb95b16 of merged.opt.wasm, rebuilt identically from the worktree. After a bulk pass with <= 300 frames left the loop parks POSTs in the connection's pending bytes (GETs go on), the
checkpointer does the last pass, and the first write afterwards restarts the WAL. A hold ends after 250 ms at the latest. Only the 3x-threshold inline checkpoint can still sync on the loop.
- 240k cap 3,000: k5 p50 1.4, p95 16.6, p99 164, max 876 (k4 22/525/770)
- 260k cap 3,000: k5 p50 1.5, p95 18, p99 124, max 401 (k4 65/595/900)
- 280k cap 3,000: k5 p50 1.8, p95 65, p99 235, max 1,084 (k4 and b4 failed here in E62)
A step, not a trim: p95 falls 30-fold, us/req 17.3 -> 15.3. This matches the f220565 finding (E26: DB sync off the loop held 270k on the scorer), now without writing private state.
Checks: 42/42. h1check.py: 672 checks 0 stale, 4,122 acked 0 missing after kill -9, integrity ok (CKPT_FRAMES=100). holdcheck.py (new, raw sockets through constant holds): 1,193 split POSTs, 1,115 pipelined
POST+GET+POST in order, 1,143 POSTs over 3 KiB split, 1,137 closes right after a POST; 0 bad, 0 of 4,566 acked missing after kill -9, integrity ok.

## E65-E67 (H1c): the k5 runs that finished the picture (4 Nov, harness v3, cap 3,000 unless noted, 0 errors unless noted)
2-minute probes: k4 280k 745/1,275; k5 240k without the cap 5/36; k5 CKPT_HOLD=50 240k 5/27. k5 300k p95 5,320, 1.3 % errors, tcp up to 173k pages; 320k and 340k: the OOM killer took the server (global OOM, E39's "refused"),
so memory ends this harness somewhere between 280k and 300k whatever the loop does.
5-minute holds tell a different story from the 2-minute probes: k5 280k 3,110/5,320 (fail), k4 260k 860/1,255 (fail). k5's WAL stepped 49, 73, 91, 95 MB: 95 MB is the 3x force limit (24,000 frames), so the passes weren't catching up
(tail target 300 frames with new frames arriving while each pass runs) and the inline last resort fired, seconds of stall on the loop at 3,000 IOPS, then ~3 MB/s of rereads. Also seen: feed.db in page cache goes from 243 MB to ~25 MB at
the end of the ramp at 240k and up, memory pressure from the sockets; the 64 MiB SQLite cache and few rereads carry it until a long stall.

## E68 (H1c, k6): hold earlier, longer, and no inline last resort short of 8x (4 Nov, harness v3, cap 3,000, 5-minute holds, 0 errors)
k6: hold from 1,000 frames left, 500 ms limit (2 s past 3x), inline only past 8x the threshold. New CKPT_LOG=1 logs every step. wasm sha256 2b453565. 42/42, holdcheck.py 0 bad, 0 of 1,430 missing after kill -9.
- 260k: k6 p50 1.35, p95 42, p99 280, max 756 ms, 15.2 us/req, RSS 162 MB (k4 860/1,255 fail)
- 280k: k6 p50 1.9, p95 280, p99 1,050, max 5,810 ms, 17.2 us/req (k5 3,110/5,320): just over the p99 limit
Event log at 260k: 195 checkpoints in 300 s, 428 bulk passes, 109 holds that timed out, tail pass p50 371, p90 463 ms: the tail is slow under the cap, holds are often lost. GET traffic flows through all of it.

## E69-E72 (H1c, H24): repeats and the tail target (4 Nov, harness v3, 5-minute holds, 0 errors; pass = p95<500, p99<1,000)
- b4 (the df9da40-style baseline) 240k cap 3,000: p50 124, p95 860, p99 1,175, max 1,799: FAIL
- k4 (H1 with inline tail) 260k cap 3,000: 860/1,255: FAIL
- k6 260k cap 3,000: 42/280, repeat 47/280, max 756/690
- k6 270k cap 3,000: 74/315, max 970
- k6 280k cap 3,000: 280/1,050 (fail by 50 ms), CKPT_NICE=0 260/770, CKPT_TAIL=400 75/310, max 794
- k6 260k no cap: 14/81, max 561
CKPT_TAIL=400 beats 1,000 at 280k: fewer lost holds, one run each so far. H24's "the tail's size doesn't matter" (E63) was for an inline tail; with a hold it does.

DeepSeek round 3 on H1c. Taken: test slower disks and a read cap with less memory (E76, E77), since the harness caps writes only and the page cache collapses at ramp end; holds must stay short of the p95/p99 budget on a slower disk.
Rejected after checking the code: "n drifts" (n is SQLite's own mxFrame from the WAL hook), "stranger gets a response" (replay checks the generation, holdcheck.py closes mid-hold), "replay re-arms a bulk pass each cycle" (after a restart n starts from 0; bulk starts at 8,000).
"The hold doesn't save disk work": true and beside the point, it moves the sync off the loop.

## E73 (H1c, H24, H27): repeats of k6 with a smaller tail target (4 Nov, harness v3, cap 3,000, 5-minute holds, 0 errors; ms p95/p99/max)
- 280k CKPT_TAIL=400: 75/310/794, 126/420/1,645, 77/325/1,102: passes three times of three
- 280k CKPT_TAIL=200: 53/295/665, 14.82 us/req
- 280k CKPT_TAIL=400 CKPT_NICE=0: 76/320/679
- 290k CKPT_TAIL=400: 270/1,210/4,653 (fail); with CKPT_NICE=0: 280/870/2,883 (pass, one run)
Default becomes CKPT_TAIL=200. Clearly above 200k here, the bar for stopping; what's left is the checks that decide how far this harness can be believed: E74 (spin harness), E76 (less memory, read cap), E77 (half the IOPS), then E78 and the last open verdicts.

## E74, E76, E77 (H1c): other calibrations (4 Nov, 5-minute holds, 0 errors; ms p95/p99/max)
Spin harness v2, 220k, SPIN_NS=10000: k6 CKPT_TAIL=400 3.25/25/279, CPU 0 66 %; b4 925/2,440/4,023, CPU 0 94 %. So on v2 the checkpoint fsync was most of what looked like CPU in E58: iowait 34 % against 6 %.
Half the IOPS (cap 1,500 writes and 1,500 reads, SRVMB=1900, CKPT_TAIL=200): k6 240k 69/440/1,193, 260k 90/455/1,417; b4 210k 1,405/1,970/2,950 FAIL. The baseline's failure here looks like the scorer's 210k (p99 1.5 s), which E61 couldn't reproduce with cap 3,000-8,000.
Less memory (SRVMB=1650, cap 3,000 writes and reads, CKPT_TAIL=200): k6 240k 3,495/5,320, 658 MB read; 260k 5,320/5,320, 1,787 MB read, 17k rps; b4 210k 640/820. All page-cache thrash; E39-era calibration already called SRVMB 1650 too harsh (f220565 OOM-killed at 270k there, while it held 270k on the scorer), and fitted 1900 to those scorer numbers. So this doesn't count against k6, but it is the real wall: memory ends the climb with or without the hold, and the scorer killed f220565 at 280k.

## E78 (H27, H24): nice and tail at the edge (4 Nov, harness v3, cap 3,000, 5-minute holds, 0 errors; ms p95/p99/max)
- 290k: CKPT_TAIL=200 CKPT_NICE=0 98/350/969; CKPT_TAIL=400 CKPT_NICE=0 280/870/2,883; CKPT_TAIL=200 nice 10 1,075/3,305/9,974 FAIL; CKPT_TAIL=400 nice 10 270/1,210/4,653 FAIL
- 280k: CKPT_TAIL=200 CKPT_NICE=0 74/320/819; CKPT_TAIL=200 nice 10 53/295/665, 59/300/846
H27 reverses E63's "within noise": with the hold the checkpointer's speed sets how long POSTs wait, and at 290k a niced one loses on a loaded CPU. Defaults now CKPT_TAIL=200 and CKPT_NICE=0 (build k7, wasm ba492bfc, 42/42, h1check 391 checks 0 stale, 0 of 2,270 missing after kill -9; holdcheck 0 bad, 0 of 2,156 missing).

## E75, E79 (H21, H23, H22, H6; memory margin) (4 Nov, harness v3, cap 3,000, CKPT_TAIL=200)
2-minute A/Bs at 270k, ms p95/p99, us/req, two reps each: NODELAY on 24/194 14.50, 29/210 13.69; off 33/205 15.36, 33/210 15.59 (H21: small gain, keep). WALSYNC=0 23/193 14.27, 24/184 14.60 (H23: the flusher no longer buys any latency; left in, it keeps the loss window after a power cut at 100 ms). 
k6 with a 16 MiB cache at 290k, nice 10: 2,085/5,320, RSS only ~17 MB lower (H22: dead, the pages it stops caching come back as page cache or disk reads). wasm-opt -O4 --converge against -O3 at 150k: 13.71, 13.68 vs 14.73, 13.97 us/req, p95 2.7 both, 432 B smaller (H6: within noise of what E56 calls noise, not taken).
E79, 5-minute holds, k7: 290k OOM-killed 1 min into the hold (96.7 % errors), 280k OOM-killed 3 min in. Same settings on k6 passed at 15:46-16:00 (E78). The two runs differ in one thing: the hog was 86 MB bigger (10,382 against 10,296 MiB at 280k), since it's sized from MemAvailable, which read higher after the AOT step; memory snapshots otherwise match within 1 MB (AnonPages +88 MB, MemAvailable -88 MB, slab equal). So the margin at 280-290k is under ~90 MB: a harness measurement error of that size flips a pass into an OOM kill. Rerun with drop_caches before sizing the hog (E80).

## E80, E81 (H1c): the final build against the memory wall (4 Nov, harness v3, cap 3,000, SRVMB=1900, drop_caches before sizing the hog, 5-minute holds; ms p95/p99/max)
k7 = wasm ba492bfc, CKPT_TAIL=200, CKPT_NICE=0.
- 260k: 56/335/1,716, 52/355/2,536. Passes twice, 0 errors. Baseline b4 at 210k: 670/855/1,331, p95 FAIL.
- 270k: 51/305/825 pass; 255/1,035/4,999 fails p99 by 35 ms
- 280k: OOM-killed (41 % errors); 81/340/2,016 pass
- CKPT_FRAMES=4000: 280k and 290k OOM-killed; no help (H4)
drop_caches narrowed the hog's noise but didn't remove it (10,367-10,522 MiB, not monotonic in users). The wall is memory: 2.5 GB of slab at 280k on this box counts both ends, sockets dominate, RSS 164 MB of which SQLite's cache is 64. A stall burst of tcp pages then tips it over. f220565 on the scorer held 270k and died at 280k, so 260-270k is what I'd expect there; unchecked until scored.
Summary against the brief's bar: 5-minute holds with 0 errors, final settings or within one knob of them: 260k passes on cap 3,000 (4 of 4: k6 twice, k7 twice), 260k at cap 1,500 (1 of 1); baseline fails 210k at both caps and at 240k. Spin harness v2 220k 3/25 vs 925/2,440.
Not done: the scorer itself. Every number here is Synteq. C is host.c 304 + sqlite_glue.c 146 lines; a WAT port of the VFS could cut that, not attempted.

