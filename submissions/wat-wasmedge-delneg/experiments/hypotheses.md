# Hypotheses (TdscWat4, from 3 Nov). APPEND-ONLY: lines are never edited or deleted; a status change is a new line.

Denis asked for this (3 Nov): "try other solutions, getting some data (conclusions)", challenge the current
assumptions, a hypothesis list written and locked before any experiment, results in worklog.md (E53 on).
The ids here (H1, H2...) are this file's. The worklog's older "H1-H4" sections are 5-minute holds, a different thing.
Each entry gives the idea, the assumption it challenges, the expected effect and why, the rule check and the cost to test.
Phase 1 sources: our own README/worklog/app.wat/host.c/build.sh, the top entries' code (rust-iouring-kensac shim.c,
c-iouring-pavlyhalim db.h, mojo-iouring-oh-meh shim.c), LEADERBOARD.md, SQLite 3.54.1's os_unix.c WASI section,
`wasmedge compile --help`, a DeepSeek consult (session 1103-205423-0386, $0.023).
The two survey/compiler subagents could not be started (only Opt can spawn), so that survey was done in-line and kept small.

## Facts gathered in Phase 1 that change the picture
- F1. The scorer's own numbers: df9da40 at 200k used 68 % CPU (19.6k req/s, ~34.7 us/req of the box); 210k and 220k failed
  on p99 at 69-75 % CPU with 0 errors. ~30 % of the CPU was idle while p99 broke, so on the scorer the cliff is not CPU.
- F2. Harness v2 without the spin already costs ~35 us/req of CPU 0 at 240k (h4: busy 98 % = user+sys 70 + softirq 28, of
  which the 10 us spin is ~22 points, at 21.7k req/s -> (98-22)/21.7k = 35 us), about the scorer's 34.7. The SPIN_NS=10000
  calibration matched the scorer's tail by adding CPU the scorer doesn't spend. So "240k is CPU-bound" holds for the
  harness with spin, not necessarily for the scorer. The scorer's tail is more likely the checkpoint stall, longer on its disk.
- F3. Every top entry checkpoints from a second connection on another thread: rust-iouring-kensac (shim.c:118-150, a
  "bulk" PASSIVE on the thread, then writes held and a "tail" PASSIVE so the WAL is fully copied and the next write
  restarts it, shim.c:280-305), c-iouring-pavlyhalim (db.h:105, :498), mojo-iouring-oh-meh (shim.c:554, :605). We are the
  only top-40 entry that fsyncs a checkpoint on the event loop.
- F4. Why we couldn't: SQLite's WASI build has no shared memory (os_unix.c: `unixShmMap 0` under SQLITE_WASI; default VFS
  unix-dotfile). We use "unix-none" with locking_mode=EXCLUSIVE, so the wal-index is in the heap of one connection.
  But xShmMap/xShmLock/xShmBarrier/xShmUnmap are io-method slots a VFS wrapper may fill (public API), and the host can
  map the same physical pages into two wasm linear memories (memfd + mmap MAP_FIXED inside WasmEdge's in-place memory).
- F5. Only likes (15 % per iteration) and posts (2 %) carry a JWT: ~7.8 % of requests (0.17 of 2.17). The HMAC key pads
  are already computed once at start (`$hmac_init`).
- F6. The SQLite part of the merged module has 318 `memory.copy` and 159 `memory.fill` sites (clang inlines memcpy/memset
  as bulk-memory ops); WasmEdge's AOT turns each into a runtime call (README). perf M3: libwasmedge 1.1 %, libc 1.3 %.
- F7. `wasmedge compile` options: --generic-binary (we don't use it, so native CPU), --interruptible (off), --enable-threads,
  --disable-* for proposals, --optimize. No bounds-check switch.

## Hypotheses

H1. A second SQLite connection on a second wasm instance runs the checkpoints, so the event loop never waits for the
  checkpoint's fsyncs. The host starts a pthread running a second WasmEdge VM on the same app.so (its own linear memory,
  its own copy of SQLite's globals, so SQLITE_THREADSAFE=0 stays safe); a memfd is mapped MAP_SHARED|MAP_FIXED into a
  page-aligned slice of each instance's memory and serves as the wal-index; a VFS wrapper around unix-none (glue C, public
  sqlite3_vfs/io_methods API) adds xShmMap (slices of that region), xShmLock (8 process-wide lock words, CAS through host
  imports, per-instance held masks), xShmBarrier (host fence), xShmUnmap (no-op). locking_mode NORMAL. Protocol after the
  Rust #1: WAL >= T frames -> the checkpointer does a bulk PASSIVE; while the frames written since exceed TAIL it does
  another; then the loop runs one small inline PASSIVE between batches (nothing open, so it copies everything), and the next
  write restarts the WAL.
  Challenges: "WASI has no shm, so no second connection"; "nothing within the rules takes the fsync off the loop".
  Expected: the ~140 ms stall every ~2 s becomes a few ms (tail: tens of pages + two syncs; F-floor ~0.8 ms per sync here);
  p99 at 210-220k back under ~500 ms; on the scorer (F1, ~30 % idle) the next limit moves to memory/CPU, maybe 240-260k.
  Costs on the loop: NORMAL locking (a read-mark lock and header check per transaction, through host calls), ~1-3 %.
  Rules: SQLite in-process (same process, second thread: rule 1 allows threads), stock amalgamation, public VFS API only,
  synchronous=NORMAL unchanged and SQLite does every sync itself, no kernel tuning. C grows (~80 lines glue + ~50 host)
  for the experiment; a WAT port of the VFS can follow if it wins. Cost: high (1-2 days of agent time compressed: 2-3 builds).
H1b. Fallback for H1 if two VMs in one process fail: fork() in the embedder before _start, child runs the checkpointer
  role; the shared pages are a MAP_SHARED mapping placed into wasm memory before the fork. Same expected effect, more risk
  (fd inheritance, COW, two processes counted by the OOM killer). Only if H1 is blocked.
H1c. If H1's inline tail still costs (e.g. the scorer's fsync floor is high): hold writes and let the checkpointer do the
  tail too (as the Rust #1), so no sync ever runs on the loop. Needs write-deferral in the WAT's group commit. Only if H1's
  tail shows in the p99.
H2. Second harness calibration: no spin, the disk slowed instead (systemd IOWriteIOPSMax / IOWriteBandwidthMax on the
  server unit, cgroup io.max), fitted so df9da40 holds 200k and fails 210k as on the scorer. Challenges "the harness matches
  the scorer" (F2: the spin adds CPU the scorer doesn't spend). Expected: tells whether the scorer's limit is the stall
  (then H1's gain is larger than the spin harness shows) or CPU. Rules: harness only. Cost: medium (3-5 2-minute probes).
H3. Measure the checkpoint fsync cost against the number of dirty pages on Synteq's disk (floor and slope), with the same
  file and page pattern. Challenges DeepSeek's worry that the cost is a fixed device floor (then H1's inline tail would be
  as slow as today's checkpoint). Expected: ~0.8 ms floor + ~65 us/page (worklog E51 numbers, to be confirmed). Cost: low.
H4. Checkpoint by wall time or by dirty pages instead of by frames (DeepSeek: the index grows over 5 minutes, so a fixed
  frame count is non-stationary). Without H1: E11/E51 already found smaller, more frequent checkpoints worse (fsync floor +
  per-page cost); no new reason to retest. With H1: the checkpointer's cadence (T, TAIL) is the knob; tuned inside H1.
H5. SQLite's 318 memory.copy / 159 memory.fill sites each become a WasmEdge runtime call. Building SQLite with
  -mno-bulk-memory makes clang call wasi-libc's memcpy/memset (wasm loops, compiled by the AOT like the rest), or inline
  small fixed-size copies as loads/stores. Challenges "SQLite's C build is as good as it gets" (E18/E19 only tried -O3 and
  ObjC's defines). Expected: ~0.2-0.6 us/req (perf F6 bounds it near 2 % of CPU). Rules: compile flags of stock SQLite: OK.
  Cost: low (one build, A/B).
H6. More binaryen passes on the merged module (-O4, --converge, -O3 twice, --inlining-optimizing with higher limits)
  before the AOT. Challenges "wasm-opt -O3 then LLVM -O3 already catches everything". Expected: 0-2 %. Cost: low.
H7. Offload the JWT check (WasmEdge wasi_crypto plugin, or a native HMAC host import). Challenges "JWT in WAT is a cost".
  Expected: negligible: only ~7.8 % of requests carry a JWT (F5), ~3 SHA-256 blocks each with the pads precomputed, so even a
  2x faster native SHA-256 saves < 0.1 us per request on average. The Xeon 8260 has no SHA-NI. A plugin also has to be pinned
  and installed. Verdict expected by arithmetic plus one microbench of the WAT SHA-256; no build unless the microbench
  surprises. Cost: low.
H8. "Compression": HTTP response compression (gzip/deflate) of /feed. Challenges nothing we assumed, but Denis asked. Needs
  Accept-Encoding from k6 (to check: bench/load.js sets no headers; k6's default) and costs deflate CPU (~10+ us for a ~6 KB
  feed in wasm) against fewer TCP segments/ACKs. Expected: loses on CPU, or isn't allowed if k6 doesn't ask (rule 4/7). Other
  readings of "compression" (SQLite page density / smaller page size, WAL frame size) are H13 / H1. Cost: low (check + estimate).
H9. host.c and the glue in Rust instead of C. Challenges "C must stay C". Expected: no speed change (the host runs ~1-2 % of
  the CPU: ring_go copies; the same LLVM code either way), no fewer lines, plus a pinned Rust toolchain in install.sh. Verdict
  by profile share and line count. Cost: low (analysis), a port only if Denis wants it for its own sake.
H10. Compiler output: our WAT's hot routines (SHA-256 block, JSON string escape, integer formatting, request-line parse,
  record decode) against clang -O3 / rustc opt-level=3 wasm of the same routines, after wasm-opt and the AOT: patterns the
  compilers use that we don't (loop shapes, br_table, select, local reuse, SIMD). Challenges "hand-written WAT is as fast as
  compiled" (E4 measured parity on the whole server, not per routine). Expected: < 0.5 us/req (our own code is ~9 of ~28 us,
  much of it SQLite's C). Cost: medium; done as a small microbench on opt-box.
H11. /feed's 20 author lookups (sqlite3BtreeTableMoveto 5.8 %, mostly these): seek them in ascending user-id order on one
  users cursor, so neighbouring seeks share the upper levels, or skip the seek when the cursor is already on that id.
  Challenges "the B-tree read path is done". Expected: ~0.5-1 us per /feed (~46 % of requests). Rules: same B-tree read
  path, nothing cached across requests. Cost: medium (WAT change + 42/42).
H12. NORMAL locking's CPU cost on the loop (part of H1): measured on its own by running H1's build with the checkpointer
  disabled. Cost: low once H1 builds.
H13. Bigger page size (VACUUM at start into 8 or 16 KiB pages) so the likes autoindex has 2-4x fewer leaves and a
  checkpoint writes fewer distinct pages. Challenges "~2,400 leaves per checkpoint is fixed". Rule risk: rule 3 ("schema and
  data are fixed") and rule 10 (healthy within 60 s; a 243 MB VACUUM on 1 vCPU in wasm may take longer); also every WAL
  frame grows 2-4x. Not tested without Denis; if H1 fails, write the case for him.
H14. io_uring registered ring fd (IORING_REGISTER_RING_FDS + IORING_ENTER_REGISTERED_RING). Expected negligible (one
  enter per loop pass, thousands per second, not per request). Verdict by the S12 census numbers. Cost: low (analysis).
H15. Socket memory at 240k+: on the scorer 240k died with "connection refused" (an OOM kill per E39). Challenges "memory
  is fixed per connection". With H1 the backlog that blows up TCP memory during stalls should go; a smaller SO_RCVBUF on
  the listener (inherited by accepted sockets, a setting inside the process) would cap what a stalled socket queues.
  Expected: matters only past H1; test if H1's 5-minute holds at 240k+ fail on memory. Cost: low (env knob).
H16. Wasm threads / shared memory in WasmEdge with SQLITE_THREADSAFE=2 and both connections in one instance. Rejected in
  favour of H1: needs a threads build of wasi-libc and SQLite with mutexes on every page allocation (DeepSeek: pcache1's
  global list has no mutex with THREADSAFE=0), more CPU per request; H1 gets the same with two instances. Not tested.
H17. SQLite compile-time options with a reason ObjC's set (E19) didn't have: SQLITE_OMIT_SHARED_CACHE (drops the
  shared-cache table-lock checks on every B-tree access), SQLITE_DEFAULT_LOOKASIDE tuning, SQLITE_MAX_EXPR_DEPTH=0,
  SQLITE_OMIT_DEPRECATED, SQLITE_DQS=0. Expected: 0-2 %. Rules: compile options of stock SQLite: OK. Cost: low, bundled
  with H5 as one A/B.
H18. PGO for the wasm (clang profile of SQLite + LLVM AOT). Untested: wasi-sdk has no profile runtime for wasm32-wasip1 and
  WasmEdge's AOT takes no profile; too costly for this round.
H19. Likes through the B-tree layer (write path): skip SQL's bytecode for the like's exists check and insert. Expected
  small (~7 % of requests, ~3-5 us each -> ~0.3 us/req), and inserting through internal B-tree calls skips constraint and
  index maintenance that SQL does for us (two indexes): risky against rule 4 and "public plugin APIs". Not tested.
H20. "240k is pure capacity" (TdscWat3) on the scorer: F1/F2 say otherwise; H1 + H2 test it. No separate experiment.

--- LIST LOCKED 2026-11-03T19:01Z ---

Ranking by expected impact / cost (highest first). Order of work: H3, H1 (+H12 inside it), H2, then the cheap CPU A/Bs.
1. H3  (low cost; decides whether H1's tail is cheap)
2. H1  (largest expected impact: the stall the scorer fails on)
3. H12 (comes free with H1's build)
4. H2  (medium; tells how much of H1's gain the scorer would see)
5. H5 + H17 (one build, low cost, a few %)
6. H6  (low cost, 0-2 %)
7. H11 (medium, ~1 us on /feed)
8. H7, H8, H9, H14 (verdicts by arithmetic + one check each)
9. H10 (medium, small expected)
10. H15, H1c, H1b (only if H1's results call for them)
11. H13, H16, H18, H19 (not tested: rule risk or cost; reasons above)
H3: tested in E53, done: ~1.3 ms floor + ~60 us/page; H1's inline tail viable if <= ~30 pages
H1: E54 (2-min, 210k): p99 690/410 vs baseline 1,305/1,000; +1.4-2.5 us/req CPU to explain (E55)
H12: E55: shared mode costs ~0.6 us/req at 150k; 1 ms polling another ~1.0 (fix in h1b)
H5: E57: -mno-bulk-memory is a no-op (byte-identical module); own memcpy in glue = H5b, low value, not built
H7: E57: dead (7.8 % of requests carry a JWT; < 0.1 us/req to gain)
H8: E57: dead (gzip-1 of /feed costs 38.5 us natively for ~2 fewer segments)
H9: E57: dead for speed (host <= 0.3 % of CPU)
H14: E57: dead (0.13 enters per request)
H12: E56: with futex + one host call per lock the shared mode costs nothing measurable (11.79 vs 11.96 us/req at 150k)
H1: E56 (2-min, 210k): h1b p99 440/390 vs baseline 550 (and 1,305/1,000 in E54), 15.6-16.2 vs 17.1 us/req. 5-min holds next
NEW H21. TCP_NODELAY on the listener (accepted sockets inherit it). Every top entry sets it (rust-iouring-kensac main.rs:686, objc-uring-delneg main.m:25, c-iouring-pavlyhalim, shivanshthapliyal); we never did (host.c h_listen: only SO_REUSEADDR). Challenges "the socket setup is fine". Expected: small or nothing: /feed is 3 full segments + a partial one, and Linux's Minshall-style Nagle holds a partial only while an earlier small segment is unacked, which a request-response connection rarely has. Rules: a socket option inside the process: OK. Cost: one line, env A/B.
NEW H22. A smaller SQLite page cache (the top entries use 8-64 MiB; we use 64): RSS is ~130 MB at 210k, and each MiB saved is ~250 users of kernel socket memory. Challenges "64 MiB is right on the 2 GB box". Expected: a few thousand users of memory headroom against more preads per request. Only worth it if holds at 240k+ fail on memory. Cost: low.
NEW H23. With H1 the WAL flusher's fdatasync every 100 ms may not be needed: the checkpointer's own WAL sync no longer stops the loop, only the tail's does, and the tail's WAL sync covers little. Challenges the E24 finding, made for an inline checkpoint. Expected: slightly less CPU and I/O; the thread could then do only the code pinning. Cost: WALSYNC_MS env, but that also turns pinning off, so needs a small build change. Rules: fine.
NEW H24. H4 inside H1: CKPT_FRAMES and CKPT_TAIL again. The stall no longer grows with the checkpoint, so bigger checkpoints could coalesce more likes, up to the WAL's page-cache cost (E52/H3 lost at 16,000 frames for that reason, not for the stall). Smaller tail = shorter inline sync, more bulk passes. Cost: env only.
NEW H25. Survey (3 Nov): PGO in native entries (objc-uring-delneg, c-iouring-pavlyhalim: -fprofile-use) and -DSQLITE_USE_ALLOCA, -DSQLITE_OMIT_SHARED_CACHE etc. (mojo, shivansh, pavlyhalim). E19 already measured the defines as noise on wasm (12.95 vs 12.94 us/req); no new reason for H17 beyond that, and H18 (PGO) stays untested.
H10: E59: WAT already beats clang/rustc on SHA-256 and integers; JSON lost 15-45 %, fixed (local cursor + overlapping tail): ~0.15 us/req
H5: E59: H5b dead, memory.copy costs ~3 ns extra on small copies
H1: E58: 5-min holds at 220k on the spin harness: both fail on CPU (p99 1,380 h1b, 1,215 b4). Spin harness can't judge H1 past 210k; H2 next
NEW H26. Buffer-ring exhaustion at a stall (DeepSeek round 2): each ring has 2,048 x 2 KiB provided buffers; 22k req/s spread over 4 rings is ~5.5k/s per ring, so a stall over ~370 ms runs a ring dry and multishot receives end with -ENOBUFS, each needing its own re-arm. That is a hard threshold at constant CPU, a possible shape for the scorer's jump between 200k and 210k at ~70 % CPU. Same check for CQ overflow. Test: bpftrace on io_uring_complete res -105 and io_uring_cqe_overflow at the failure point. Fix if real: more, smaller buffers (8,192 x 512 B has the same memory). Cost: low.
NEW H27. CKPT_NICE: 10 against 0. On one vCPU a niced checkpointer may fall behind when it matters most (DeepSeek). Cost: env.
NOTE evidence for H1 found while weighing DeepSeek's "wrong trigger": f220565 (E26), whose database sync went through io_uring and so never stopped the loop, HELD 270,000 on the real scorer; #272 and df9da40, whose checkpoints fsync on the loop, held 200,000. So on the scorer, keeping the DB sync off the loop was worth ~70k users. That build was dropped only because it wrote SQLite's private nBackfill. H1 gets the same effect through public APIs.
H1: E62: on the capped harness H1 gains little at 240-280k because the inline tail still stalls the loop (mean 176 ms, 3 syncs). CKPT_TAIL=30 next
H26: E62: confirmed ENOBUFS storm (~3,000/s at 22k req/s under long stalls); k4/bb build has 8,192 x 512 B buffers, A/B pending
H26: E63: ENOBUFS gone (0 of 9.1M) with 8,192 x 512 B, little latency change; kept
H24: E63: CKPT_TAIL=30 changes nothing, the inline fsync's cost doesn't depend on the tail's size
H27: E63: CKPT_NICE 0 vs 10 within noise; dead
H11: dead by source: sqlite3BtreeTableMoveto only shortcuts to key+1 (BtreeNext); other seeks start with moveToRoot, so sorting 20 scattered ids saves no descent
H1c: E64: k5, no sync on the loop: 240k p95/p99 17/164 vs k4 525/770; 280k 65/235, k4 fails. Holds next
H1c: E68: k6 (hold from 1,000 frames left, 500 ms limit, no inline before 8x): 5-min hold 260k p95/p99 42/280 vs k4 860/1,255; 280k 280/1,050. Repeats next
H2: E77: a cap of 1,500 IOPS gives the baseline a failure like the scorer's at 210k (p99 1,970 vs 1.5 s); no such cliff at 3,000+ (E61)
H1c: E73, E74, E77: repeated 5-min holds: 280k passes 4 of 4 with tail <= 400 at cap 3,000; 260k passes at cap 1,500 (b4 fails 210k); v2 220k 3/25 vs b4 925/2,440
H22 (context): E76: memory is the wall; SRVMB 1650 thrashes k6 at 240k
H27: E78: alive after all with the hold: 290k passes twice at nice 0, fails twice at nice 10; default now 0
H24: E78: with a hold the tail target matters: 200 best at 280-290k; default now 200
H21: E75: small gain (15 % fewer p95 ms, ~1 us/req); kept
H23: E75: no latency change with WALSYNC=0; flusher kept for the 100 ms loss window, can go if Denis prefers less C
H22: E75: dead, 16 MiB cache worse at 290k
H6: E75: within noise, not taken
H1c: E80, E81: k7 260k 56/335, 52/355; 270k 51/305, 255/1,035; 280k OOM, 81/340. Memory wall at 270-280k. HELPS, the result of this round
H1: helps only with H1c: the second instance alone gave little under the cap (E62), and the hold needs it
H4: E80: CKPT_FRAMES=4000 no help at the wall; with no stall on the loop the threshold stopped mattering. Dead
H2: done (E61, E77): harness v3; cap 1,500 reproduces the baseline's 210k failure
H20: dead: "240k is pure capacity" is wrong; 280k passes when memory lasts, at 16 us/req
H1b: not needed, two VMs in one process work
H13: untested: VACUUM to 8-16 KiB pages at start risks the 60 s health limit; less page-write work no longer matters without a loop stall
H15: untested: tcp stays < 1,000 pages when the loop doesn't stall; only post-stall bursts remain, and buffer limits there would drop data, not save the run
H16: blocked: threads/shared memory stay rejected, H1 got the same result without them
H17, H25: no new reason beyond E19's noise; untested
H18: blocked: wasi-sdk has no profile runtime for wasm32-wasip1
H19: untested: expected ~1 % of CPU; CPU is not the limit now, memory is

