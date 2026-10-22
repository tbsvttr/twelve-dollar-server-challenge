# C++ + EASTL, no framework

| | |
|---|---|
| Language | C++23, Ubuntu 24.04's default GCC (13.3), `-O3 -march=native -flto=auto`, stripped |
| Framework | none: hand-written single-threaded `io_uring` server (Linux 6.0+, `liburing`) |
| Architectures | x86-64 (SSE2) and arm64 (NEON); a portable scalar path for anything else |
| Standard library | EASTL 3.27.01 where it has what I need; `std::charconv` otherwise |
| SQLite driver | C API, SQLite 3.53.4 built from the amalgamation with PGO |
| JSON | hand-written scanner and writer |
| **Nginx or direct** | **Direct**: serves `0.0.0.0:80` itself |

EASTL is pinned by git tag. yyjson 0.13.0 is only a fuzz-test oracle and isn't linked. The SQLite amalgamation is checked against its SHA-256. OpenSSL, liburing and GoogleTest come from apt.

## Running it

```bash
sudo bash install.sh
bash build.sh
SQLITE_PATH=... JWT_SECRET=... HOST=0.0.0.0 PORT=80 bash start.sh
```

`build.sh` runs `cmake --workflow --preset release` (configure, build, unit tests). The SQLite PGO step adds about 40 s: instrumented build, a few seconds of training on a synthetic DB (`pgo/train.cpp`), rebuild with the profile. If training fails it falls back to a plain build.

Needs `io_uring`: kernel 6.0+, `kernel.io_uring_disabled=0`, no seccomp profile blocking it. Otherwise the server exits with the reason. Docker's default profile plus `io_uring_setup`, `io_uring_enter` and `io_uring_register` is enough.

SIGTERM or SIGINT stops it cleanly: the loop exits and SQLite closes, which checkpoints the WAL.

## Trying it in Docker

`docker-compose.yml` mimics the droplet: one CPU (`CPUSET`, default 0), 2 GB, no swap, `nofile` 65535, host network. Docker's default seccomp blocks `io_uring`, so the compose file disables it. The container isn't root, so it listens on `HOST_PORT` (default 8080).

```bash
cp seed/feed.db /tmp/feed.db
DB_DIR=/tmp docker compose up --build
```

## Optimizations, and why

- **One thread, `io_uring`, SQLite inline.** One vCPU, so more threads only add context switches. Multishot `recv` into a shared provided-buffer ring, 256 single-shot `accept`s kept armed, batched submits.
- **Wake-ups are batched.** When the last pass handled 4+ completions, the loop waits for 128 completions or 6 ms. Fewer syscalls and wake-ups, bigger group commits. It costs latency (p99 about 7 ms at 40k users instead of under 1 ms), well inside the limit. CPU per request at 40k users: 25 us with no batching, 21 us at 1.5 ms, 18 us at 3 ms, 16.7 us at 6 ms, 15.6 us at 12 ms. 6 ms is where it flattens.
- **The batch target is capped at 40% of open connections.** With a few connections and no think time (`wrk -c64`), 128 completions never arrive, so every pass sat out the full 6 ms: 9k req/s with the core 85% idle. Capping the target fixes that (about 59k req/s) and changes nothing from 320 open connections up. Throughput fell off between 50% and 62%; 40% leaves margin for a faster or slower client. Waiting for as many completions as the last pass handled doesn't work: it settles at the stalled 9k.
- **Connections live in `io_uring` file tables**, so they don't count against `LimitNOFILE`. A table can't be bigger than `RLIMIT_NOFILE`, so there are 5 rings of 65,535 slots, filled in order and all driven by the one thread: 327,675 connections. Slots are reserved when an `accept` is armed, because the kernel accepts the connection before it looks for a free slot and drops it if the table is full.
- **Past capacity, evict a connection that was just served.** The think-time loop visits users in the same order every time, so LRU would evict the one needed next. Connections that haven't been answered yet are never evicted. Without direct file tables (old kernel) it falls back to normal fds with LRU eviction.
- **No allocation on the request path.** Connection state is an `mmap`ed table indexed by slot, 64 bytes each. Requests are parsed in place; responses are built in pooled 64 KiB blocks with the header written right-aligned in front of the body, sent with one `send`. A unit test counts allocations while serving reads and expects zero.
- **JSON parser for exactly these inputs.** One validating pass, keeps only the fields the server uses, 16-byte SIMD string scan, `memcmp` shortcut for the canonical JWT header. Fuzzed against yyjson (400k mutated documents, 200k random strings).
- **Header scan 16 bytes at a time** (SSE2 on x86-64, NEON on arm64, both in `src/simd.hpp`). A `GET` parses in about 35 ns vs 70-80 for `memmem`/`memchr`; a `POST` with a JWT in 65 ns vs 165. The scalar version stays in the tests as an oracle (700k mutated and random requests agree).
- **JWT checked on every request**: HS256 only, constant-time compare, `exp` checked. The HMAC pads are hashed once at startup, so a request costs two short hash continuations. Nothing is cached (rule 5).
- **Group commit.** Writes in one batch of completions share a `BEGIN IMMEDIATE` transaction. Every response produced while it's open (reads too) waits for the commit, so nothing uncommitted is visible (rule 6). A failed commit turns them into 500s.
- **Feed as three range scans.** Read the 20 newest ids from the `(created_at, id)` index; if they're consecutive, count likes for that id range in one scan and read the rows in one scan of `posts`. Otherwise run the reference query. Every response still comes from queries for that request. A differential test covers empty, gapped, reordered and tied data.
- **SQLite PGO.** On the seed data: feed 11.6 us vs 16.3 for Ubuntu's 3.45.1, post lookup 3.7 vs 4.5. No profile is committed; the build generates it.
- **`-march=native`, not hand-picked arm64 flags.** GCC 13 has no Apple cores, so on an M-series VM `native` falls back to `armv8-a` plus every feature the guest kernel reports: exactly what the VM exposes, never more. A hard-coded M2 string (`armv8.6-a+crc+lse+rcpc+...+i8mm+bf16`) changed 9 of about 194k instructions in the server (`ldar` to `ldapr`) and would break on a VM that hides a feature or on older arm64 such as Graviton 2. HMAC uses `libcrypto`, which picks its SHA2 instructions at run time anyway.
- **Pragmas**: `locking_mode=EXCLUSIVE`, WAL, `synchronous=NORMAL`, 1 GiB mmap, 64 MiB cache. Exclusive locking drops the `fcntl` shm locking WAL does per read (post lookup 3.2 -> 1.8 us, feed 10.7 -> 9.1 us), and nothing else needs to read the file.

## Tests

75 unit tests in `build.sh`: JSON, JWT (checked against OpenSSL `HMAC` for secret lengths 0-200), HTTP parser (plus differential fuzz), writer, block pool, SIMD scans (every byte value in every lane, against a naive scan), DB layer (transactions, exclusive lock, feed vs reference query), and every route. `test/test.sh` passes 42/42. Also run clean under ASan/UBSan and in the Ubuntu 24.04 container.

arm64: the unchanged `install.sh` and `build.sh` pass in an arm64 Ubuntu 24.04 container under qemu (about 13 minutes). For a faster loop, `bash cross/build.sh` cross-compiles with `aarch64-linux-gnu-g++` 13.3 and runs the tests under qemu in about 2.5 minutes. Not run on real arm64 hardware.

## Local results

### `wrk -t2 -c64`, the 2026-10-20 community benchmark's workload

Not the benchmark's machine: x86-64 (Ryzen 9 5900X), Docker Desktop on WSL2. Server container on CPU 0 with 2 GiB, no swap, `nofile` 65535 and Docker's default seccomp profile plus the three `io_uring` calls; `wrk` 4.1.0 on CPUs 1-2 with its `mixed.lua`; fresh seed DB, 2 s warm-up, 15 s measured.

| Build | req/s | p50 | p99 | Server CPU |
|---|---:|---:|---:|---:|
| fixed 128 / 6 ms target | 8,900-9,100 (5 runs) | 7.0 ms | 7.9 ms | 15% |
| no batching | 55,700-56,400 (3 runs) | n/a | 1.9-2.2 ms | 97% |
| target capped at 40% of open connections (final) | 59,200-60,100 (4 runs) | 0.96 ms | 1.8-2.1 ms | 97% |

After a run and `docker stop` the DB passes `quick_check` and holds the posts and likes written during the run; RSS is about 69 MB.

wrk times requests with `gettimeofday` and an unsigned subtraction, so a backward step of the wall clock turns every in-flight request into a "timeout". The WSL2 VM steps its clock back about 1 ms every so often. That caused all the timeouts seen here: they appear only in runs with a step, and the server's own monotonic-clock trace never saw a request take over 50 ms.

### k6, the official workload

Not a droplet run. Ryzen 9 5900X, Ubuntu 24.04 container (GCC 13.3) pinned to one CPU thread, 2 GB, no swap, `nofile` 65535, host network, load generator on other cores. A 5900X core is faster than a droplet vCPU, so expect worse on the real box.

Up to 65k users it's k6 with `bench/load.js` (90 s hold). Above that it's the raw-socket generator from #26 (`tests/loadgen.c`, not part of this submission; 120 s hold). It shifts some loopback cost onto its own cores, so its CPU figures aren't comparable with k6's. Holds are shorter than the scored 5 minutes.

| Generator | Users | CPU per request | p95 | p99 | Failed |
|---|---:|---:|---:|---:|---:|
| k6 | 40,000 | 17.2 us (two runs) | 6.6 ms | 7.0 ms | 0.00% |
| k6 | 65,000 | 16.8 us | 7.3 ms | 7.9 ms | 0.00% |
| raw sockets | 100,000 | 11.2 us (11.8% of the core) | 7.5 ms | 7.8 ms | 0.00% |
| raw sockets | 200,000 | 10.3 us (21.9%) | 8.8 ms | 9.5 ms | 0.00% |
| raw sockets | 250,000 | 10.4 us (27.4%) | 10.1 ms | 11.1 ms | 0.00% |

Eviction was only exercised at small scale: `nofile` 10,000 (50,000 slots) with 70,000 users gave 0.03% failures and p99 about 7.6 ms.

**Not tested:** anything above about 262k users. This box's `nf_conntrack_max` is 262,144 and the kernel logs `table full, dropping packet`, so runs past that measure the firewall. Eviction at the real 327k capacity and the limit search (doubling from 2,500 users, then a 5-minute hold) haven't been run.

CPU per request at 40k users (k6, container):

| Build | CPU per request |
|---|---:|
| system SQLite, before exclusive locking and group commit | 39.8, 41.9 us |
| PGO SQLite, exclusive locking, group commit, vectorized parser | 30.2, 32.1 us |
| + file tables, three-scan feed, HMAC pads (no batching) | 24.1, 26.5 us |
| + batching at 1.5 ms / 48 | 22.9, 19.4 us |
| + batching at 6 ms / 128 (final) | 17.2, 17.2 us |

## License

MIT, under the repo's [license](../../LICENSE).
