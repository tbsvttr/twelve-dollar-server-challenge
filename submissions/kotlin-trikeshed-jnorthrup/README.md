# kotlin-trikeshed-jnorthrup

Kotlin with no framework, one tree, five runtimes. The box serves the Kotlin/Native build: one thread over io_uring
direct descriptors, with SQLite linked in. The same server code also builds for GraalVM native image, the GraalVM JIT,
Node.js and WASI (wasmtime). [BENCHMARK.md](BENCHMARK.md) has every runtime built in a 1 CPU / 2 GB / no-swap box, the
42 checks and a 1,000-user run of each, and why Kotlin/Native is the scored one.

| | |
|---|---|
| Language | Kotlin 2.4.21 (Kotlin Multiplatform Gradle project) |
| Runtime (scored, `start.sh` default) | Kotlin/Native linuxX64 executable `feed.kexe`, built by `build.sh` |
| Other runtimes (`RUNTIME=`) | `graal-static` (native image), `graal-jit` (Oracle GraalVM 25.4.4.1.1 JDK, Graal JIT), `node` (Kotlin/JS on Node.js 24), `wasi` (Kotlin/Wasm on wasmtime 46); built by `bench/all1000.sh` |
| Build | Gradle 9.6.1, official distribution, and Oracle GraalVM 25.4.4.1.1 as Gradle's JDK, both installed by `install.sh` |
| HTTP | own, on io_uring: rings with sparse direct-descriptor tables, provided buffers and one response arena (`server/src/nativeInterop/cinterop/feedc.def`, liburing vendored in TrikeShed); sockets live outside the descriptor table |
| SQLite | 3.54.0 amalgamation, compiled by `build.sh` and linked into `feed.kexe`; the download is checked against the SHA3-256 sqlite.org publishes. `sqlite3.c` is not changed: `server/src/nativeInterop/feedbt.c` includes it whole and adds the B-tree read plans for `GET /feed` and `GET /posts/:id` |
| Driver | Kotlin/Native cinterop calls into that SQLite (`feedc.def`) |
| Libraries | TrikeShed (HMAC-SHA256 for JWT, SHA-3, the I/O layer), compiled on the box from the checkout `trikeshed/TrikeShed` at the commit pinned in `build.sh`: the files listed in `trikeshed/sources.txt`. `build.sh` compiles it, the server and the link in separate Gradle JVMs |

## Nginx or direct

Direct: run with `HOST=0.0.0.0 PORT=80`.

## Scoring request

`start.sh` serves Kotlin/Native by default, and that is the entry's score if only one run is made. All five runtimes
build and pass in the droplet's limits ([BENCHMARK.md](BENCHMARK.md)). If the batch has room, please also run the
benchmark with `RUNTIME=graal-static`, `graal-jit`, `node` and `wasi`, and score the fastest.
[bench/RUNNER.md](bench/RUNNER.md) says how to build and launch each one, one at a time.

## What happens per request, and why

This section describes the `graal-jit` runtime (the JVM build, which is where these designs were first measured). The
Kotlin/Native build keeps the group commit, SQLite settings, JWT and query rules below and replaces the selector loop
with the io_uring rings in `feedc.def`.

- **One thread.** The selector thread accepts, reads, parses, queries SQLite and writes. The box has 1 vCPU, so there
  are no locks and no hand-offs between threads. It owns four selectors, one per transport state class (listen, header
  read, body read, buffered write), each private to that class's selector object and selected only by its own typed
  dispatch loop (`Xio.kt`, `Poller.kt`). Kernel interest follows the state lazily, so an ordinary request changes none:
  a header key keeps read interest across requests and is disarmed only if input arrives while its connection waits
  for a commit or a write; a body key is armed only while a body is incomplete; write interest is set only when a
  write finds the socket full, and cleared when it drains. Every response joins the write selector's own queue, and
  only that selector's loop writes. In the ordinary state the header selector's select is the wait (at most 5 ms
  before the listen selector is selected, plus that pass's header visits); its consumer visits up to 64 ready
  connections per pass and queues the rest in order. While a body or write key is armed, the thread waits on all four
  at once: on Linux one `poll(2)` over their epoll descriptors.
- **Group commit (rule 6).** The first write opens `BEGIN IMMEDIATE`, and later writes join it until the transaction is
  64 ms old, counted from that first write; the thread waits at most until then and checks the deadline after every
  connection it serves. Then there is one `COMMIT`, and only then are the responses held
  since the transaction opened written (reads inside it included), so a 201 always follows its commit. Historical
  measurements, committed in a06b671 before the four-selector reactor, when `start.sh` used `-Xms128m -Xmx384m`; the
  container's host is not recorded. This repo's load model at 64,000 users against a 1-CPU / 2 GB container (2 min
  holds, alternating runs), server CPU per request: one `COMMIT` per selector pass 67.1-69.6 us (p95 10-17 ms); a
  32 ms window 59.7-62.1 us (p95 52-59 ms); 64 ms 56.2-59.0 us (p95 89-104 ms, p99 122-150 ms); 128 ms 56.3-56.4 us
  (p95 180-183 ms, p99 309-399 ms). A 5-minute hold at 64,000 users with the 64 ms window: 56.2 us per request,
  6,736 requests/s, p95 95 ms, p99 124 ms, max 190 ms, no errors. Current measurements: Benchmark, below.
- **SQLite settings.** `journal_mode=WAL`, `synchronous=NORMAL`, `locking_mode=EXCLUSIVE` (the wal-index lives in
  process memory, with no `-shm` file), `mmap_size` 1 GiB, `cache_size` 16 MiB, `temp_store=MEMORY`. Statements are
  prepared once with `SQLITE_PREPARE_PERSISTENT` and reused. They cache plans, not data (rule 5).
- **SQLite build.** `SQLITE_THREADSAFE=0` because one thread owns the connection. From the list at
  sqlite.org/compile.html#rcmd: `DQS=0`, `DEFAULT_MEMSTATUS=0`, `DEFAULT_WAL_SYNCHRONOUS=1`, `LIKE_DOESNT_MATCH_BLOBS`,
  `MAX_EXPR_DEPTH=0`, `OMIT_DECLTYPE`, `OMIT_DEPRECATED`, `OMIT_PROGRESS_CALLBACK`, `OMIT_SHARED_CACHE`. Also
  `USE_ALLOCA`, `OMIT_LOAD_EXTENSION` and `ENABLE_QPSG`. Without the query planner stability guarantee, SQLite 3.54.0
  re-prepares the post-by-id statement every time a different id is bound (`sqlite3ExprIsInteger` marks the
  parameter); under load that re-prepare took 17% of the server's CPU.
- **FFM downcalls** are linked as `critical`: there is no thread-state transition per call, and Kotlin byte arrays go to
  `sqlite3_bind_text` in place.
- **HTTP.** Only `Content-Length`, `Authorization` and `Connection` are read (RelaxFactory's header interest), and other
  headers are skipped. Pipelined requests on one connection are answered with one write. Idle keep-alive connections
  stay open.
- **Responses.** JSON is written from byte templates into one reused buffer. Text columns are copied out of SQLite and
  escaped in place. Each response then waits for its write in a reused 1 MiB output chunk (a larger one in its own
  array).
- **JWT.** The HS256 signature is checked on every request (rule 5) with a constant-time compare. `alg` must be `HS256`,
  and `exp` is checked.
- **Queries.** The post, feed and create queries are the ones in SPEC.md. A like is one statement,
  `INSERT ... SELECT ... WHERE EXISTS (post) ON CONFLICT DO NOTHING`, plus `sqlite3_changes()`. The post is looked up
  separately only when nothing was inserted.
- **JVM.** `-XX:+UseSerialGC -Xms384m -Xmx384m` (a fixed heap).

## Benchmark: 64,000 users, fixed heap

Measured 2026-10-18, one run each, on a Kali Linux WSL2 laptop (i7-6820HK). Every run started a fresh JVM with no
warmup; the OS page cache was not flushed. 60 s ramp, then a 300 s hold with all 64,000 users connected. Server: CPU 1
(`taskset` and cgroup cpuset), `cpu.max 100000 100000`, `memory.max` 2 GiB and no swap for the server's cgroup,
`-XX:+UseSerialGC -Xms384m -Xmx384m`. Client: `loadgen` on CPUs 2-7 in its own cgroup, without a memory limit. CPU per
request is the server cgroup's CPU time over the 300 s hold.

| run | server | client source addresses | full run p95 / p99 / max (ms) | hold requests/s | hold p95 / p99 / max (ms) | server CPU per request |
|---|---|---|---|---|---|---|
| before | single selector | 127.0.0.2-4 | 135.2 / 1261.6 / 3861.0 (fails p99 < 1000) | 6,723.77 | 108.5 / 131.1 / 184.8 | 69.56 us |
| control | single selector | 127.0.0.2-7 | 107.5 / 133.1 / 189.4 | 6,728.01 | 108.5 / 133.1 / 189.4 | 69.50 us |
| c025 | four selectors, interest changed per request (c0252c2e) | 127.0.0.2-7 | 120.8 / 149.5 / 363.6 | 6,723.62 | 121.9 / 151.6 / 363.6 | 89.65 us |
| final | four selectors, lazy interest (this tree, jar 3ec68cd5) | 127.0.0.2-7 | 100.4 / 123.9 / 245.0 | 6,732.29 | 100.4 / 122.9 / 176.6 | 69.91 us |

No run had a failed or unfinished request, a failed check, a connect failure or a disconnect. The before run's ramp
tail came from the client: with 3 source addresses its six CPUs ran in kernel code from about 42,000 connections
(3 x half of the ephemeral ports 32768-60999 = 42,348) until the ramp ended; with 6 addresses and the same server the
tail is gone. The first four-selector reactor (c025) cost 29 % more server CPU per request than the single selector:
it made four `epoll_ctl` interest changes per request, where the single selector made none unless a write was partial.
This tree changes interest only when a connection leaves the ordinary request/response cycle (One thread, above). A
snapshot near the end of the ramp found four eventpoll descriptors; only the header selector carried connection read
interests, while body and write selectors had only their wakeup descriptors. Its server CPU per request is 0.41 us
(0.6 %) above the single selector's (user 29.48 vs 29.39 us, system 40.43 vs 40.12 us), and its hold tails are
shorter; its full-run maximum, 245.0 ms, fell outside the hold. Two intermediate builds of it measured 71.47 us (a
`poll(2)` over the four selectors before every header select) and 70.41 us (the header select as the wait, every
ready connection queued before its visit). The historical numbers under Group commit came from a different setup
(a06b671, `-Xms128m -Xmx384m`, host not recorded) and are not comparable with these.

To reproduce from this directory after `./build.sh` and `gradle :loadgen:app` (Linux; any 127.x address is loopback
and needs no setup; no sysctl was changed):

    # server: in a cgroup with cpuset.cpus=1, cpu.max="100000 100000", memory.max=2147483648, memory.swap.max=0
    ulimit -n 1048576
    cp ../../seed/feed.db* /tmp/
    SQLITE_PATH=/tmp/feed.db JWT_SECRET=twelve-dollar-challenge HOST=127.0.0.1 PORT=3100 TRANSPORT=xio \
      taskset -c 1 java -XX:+UseSerialGC -Xms384m -Xmx384m -XX:-UsePerfData -Xlog:gc:file=gc.log \
      --enable-native-access=ALL-UNNAMED -Dsqlite.lib=$PWD/server/build/sqlite/libsqlite3.so \
      -cp 'server/build/app/*' borg.trikeshed.feed.MainKt

    # client: another shell, in its own cgroup; guard= is the server cgroup's directory
    ulimit -n 1048576
    taskset -c 2-7 java -Xms2g -Xmx6g -XX:+UseParallelGC -XX:-UsePerfData -Xlog:gc:file=loadgen-gc.log \
      --enable-native-access=ALL-UNNAMED -cp 'loadgen/build/app/*' borg.trikeshed.loadgen.MainKt run \
      host=127.0.0.1 ports=3100 tls=false mode=native tokens=../../seed/tokens.json out=lg \
      vus=64000 ramp=60 hold=300 threads=6 guard=/sys/fs/cgroup/SERVER_GROUP \
      sources=127.0.0.2,127.0.0.3,127.0.0.4,127.0.0.5,127.0.0.6,127.0.0.7

## Layout

| Path | |
|---|---|
| `server/src/commonMain` | HTTP framing, JSON scanner and writer, JWT, routing (`Feed.kt`); the reactor's transport states and group commit (`Xio.kt`) |
| `server/src/jvmMain` | `Poller.kt` (the four selectors, their dispatch loops and the wait over them), `Sqlite.kt` (FFM binding and statements), `SqliteSource.kt` (fetch + SHA3-256 check) |
| `loadgen/` | the load generator used under Benchmark (`gradle :loadgen:app` writes `loadgen/build/app`) |
| `trikeshed/` | Gradle module `:trikeshed`: `build.gradle.kts` and `sources.txt`, no sources of its own |
| `trikeshed/TrikeShed` | jnorthrup/TrikeShed checkout, not tracked here. If it is empty, `build.sh` fetches the commit pinned as `TRIKESHED_COMMIT` (`git` from `install.sh`) |
| `install.sh`, `build.sh`, `start.sh` | the challenge contract |
| `tester.sh` | a tester's walk through git, the TrikeShed linkage, scaffolding, and each edition's build, tests and run, into `build/editions/<os>-<arch>/` |
