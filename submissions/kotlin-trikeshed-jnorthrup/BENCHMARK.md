# Benchmark: one server, five runtimes

This folder holds one HTTP server, written once in Kotlin, built for five runtimes. The box runs one of them: the
Kotlin/Native build. This page says why, shows that every runtime builds and passes in a box like the droplet, and
lists what was measured, where, and how to run it again.

## The short version

- The scored runtime is **Kotlin/Native** (`feed.kexe`). `build.sh` builds only that; `start.sh` serves it by default.
- All five runtimes build in a clean Ubuntu 24.04 container held to the droplet's limits (1 CPU, 2 GB, no swap), and
  each passes the challenge's 42 checks.
- At 1,000 users every runtime passes with no failed requests. Kotlin/Native uses the least server CPU per request.
- Nothing here is a cache, a prebuilt binary or a changed SQLite. Every response that follows a write waits for its
  `COMMIT` (rule 6). How the SQLite side got here, including what was tried and dropped:
  [SQLITE-HISTORY.md](SQLITE-HISTORY.md).

## Why Kotlin/Native is the scored runtime

1. **It costs the least CPU per request** in the 1,000-user run below, and the box has one CPU.
2. **It keeps sockets out of the descriptor table.** The box allows 65,535 open files (`LimitNOFILE`). A server that
   holds one descriptor per connection cannot pass about 65,400 users, whatever its speed. The Kotlin/Native server
   takes connections into io_uring direct descriptors (`feedc.def`: 8 rings, each with a sparse direct-descriptor
   table of up to 65,535 slots, provided buffers, one response arena), so its connections do not count against that
   limit. The cross-runtime comparison below uses 1,000 users.
3. **It fits the build box.** `build.sh` (TrikeShed compiled from source, four Gradle stages) ran on kali under the
   rig's limits (1 CPU, MemoryMax=1536M, no swap, clean build folders): rc=0 in 353 s, anon peak 1,220 MB, 42/42 checks.

## The runtimes

| `RUNTIME=` | What runs | I/O | Built by |
|---|---|---|---|
| `kn` (default) | Kotlin/Native linuxX64 executable, SQLite linked in | io_uring, direct descriptors | `build.sh` |
| `graal-static` | GraalVM native image of the JVM build | io_uring ring (`TRANSPORT=ring`) or epoll (`xio`) | `bench/all1000.sh` |
| `graal-jit` | Oracle GraalVM 25.4.4.1.1 JDK, Graal JIT, SQLite through FFM | io_uring ring or epoll | `bench/all1000.sh` |
| `node` | Kotlin/JS on Node.js 24 (`node:net`, `node:sqlite`) | libuv | `bench/all1000.sh` |
| `wasi` | Kotlin/Wasm on wasmtime 46; SQLite as a second wasm module | WASI preview 1 sockets, `poll_oneoff` | `bench/all1000.sh` |

The WASI build is two modules: the server (`server.wasm`) and the stock SQLite amalgamation compiled with wasi-sdk 34
(`sqlite.wasm`, plus the small byte bridge `server/src/wasmWasiMain/c/sqlbridge.c`). wasmtime links them with
`--preload sqlite=sqlite.wasm`. It needs wasmtime 46: release 47 removed the preview 1 socket support
(`-S preview2=n -S tcplisten`).

## What the box installs and builds

`install.sh` (root): apt `aria2 build-essential zlib1g-dev ca-certificates curl git unzip`, then Oracle GraalVM
25.4.4.1.1 and Gradle 9.6.1 from their official sites through aria2c, each checked against a pinned sha256.

`build.sh` fetches TrikeShed's source at the pinned commit (`TRIKESHED_COMMIT`, `20280e86761b3df64cedd4579e311c04411d22b4`)
and compiles it on the box; it uses no prebuilt library and no Maven repository of ours. Four single-use Gradle
invocations run in order: the SQLite downloader (it verifies the amalgamation), TrikeShed's Kotlin/Native compile, the
server's Kotlin/Native compile, then the release link. The Gradle heap starts at 64 MiB and can grow to 600 MiB. Each
stage ends its JVM, so the link starts without the compilers' JVM and native allocations.

The downloads from the earlier five-runtime comparison, with their sha256 sums, are in [`bench/DEPS.tsv`](bench/DEPS.tsv) (185 entries: the tools, the
Kotlin/Native toolchain archives and the Maven artifacts of every runtime). The runtimes the box does not need (Node.js
24.21.0, wasmtime 46.0.3, wasi-sdk 34) are installed by [`bench/install-extra.sh`](bench/install-extra.sh) the same way.

## Clean builds in the droplet's limits

Each row is one fresh `ubuntu:24.04` container (`docker run --cpus=1 --memory=2g --memory-swap=2g`), run by
[`bench/droplet-ci.sh`](bench/droplet-ci.sh): CI's own tool step, `install.sh` as root, then the challenge's
`test/run.sh` as a normal user (build, start, health, the 42 checks), then a check of which runtime `start.sh` served.
Host: kali (Linux on WSL2, i7-6820HK), x86_64. "Anon peak" is the container's anonymous memory, sampled every second
(page cache is not counted; the kernel can drop it).

| Runtime | TrikeShed | install.sh | build + start + 42 checks | Anon peak | Checks | Served by |
|---|---|---|---|---|---|---|
| kn | 20280e867 | 556 s | 1,094 s | 1,817 MB | 42/42 | kn |
| graal-static | 20280e867 | 553 s | 1,319 s | 1,793 MB | 42/42 | graal-static |
| graal-jit | 722dfc5c6 | 325 s | 365 s | not sampled | 42/42 | graal-jit |
| node | 722dfc5c6 | 236 s | 300 s | 1,263 MB | 42/42 | node |
| wasi | 722dfc5c6 | 225 s | 521 s | 1,555 MB | 42/42 | wasi |

The kn and graal-static rows ran side by side and shared the host's network and disk, so their times run long. The
graal-jit, node and wasi rows ran against an earlier TrikeShed (722dfc5c6 with the WASI socket commit, which is in
20280e867); the 1,000-user run below builds all five against 20280e867.

Two build failures were found this way and fixed in this commit:

- **Kotlin/Native: `Compilation failed: Metaspace`.** The Gradle JVM's class metadata was capped at 384 MB
  (`gradle.properties`). The container's memory was not the limit: it peaked at 1,553 MB. That run raised the cap to 768 MB, and
  that build peaked at 1,817 MB.
- **graal-static: `ld: cannot find -lz`.** The native image links zlib, and `install.sh` did not install
  `zlib1g-dev`. It does now. The image build itself fits (peak RSS 1.84 GiB).

A run of the same steps in OrbStack on an Apple M3 Pro (x86_64 through Rosetta) did not fit: the Kotlin/Native build's
Gradle JVM was killed at 2,045 MB, and the native image ran out of memory. On x86 hardware both builds fit. Emulated
x86 is not used for any result on this page.

## 1,000 users, every runtime

[`bench/all1000.sh`](bench/all1000.sh) builds all five runtimes from this tree (TrikeShed 20280e867 from GitHub,
Gradle 9.8.2 through TrikeShed's `gradlew`), then runs each server alone in a systemd unit with the droplet's limits
(CPU 1, 2 GB, no swap, 65,535 files) on a fresh copy of the seed database: the 42 checks, then 1,000 users of this
folder's load generator (k6's user model and request mix: feed, post, like, create) with a 10 s ramp and a 30 s hold.
The client runs on CPUs 2-7. Run on kali (Linux on WSL2, i7-6820HK), 2026-11-03.

| Runtime | Transport | io_uring fds | Checks | req/s | p50 / p95 / p99 ms | Failed | Server CPU µs/request | Anon peak MB |
|---|---|---|---|---|---|---|---|---|
| kn | io_uring | 8 | 42/42 | 110 | 0.3 / 65.0 / 65.5 | 0 | **156** | 39 |
| graal-static | ring | 1 | 42/42 | 110 | 0.3 / 64.5 / 65.0 | 0 | 201 | 56 |
| graal-static | xio (epoll) | 0 | 42/42 | 110 | 0.3 / 65.0 / 65.5 | 0 | 227 | 37 |
| graal-jit | ring | 1 | 42/42 | 109 | 0.3 / 65.0 / 65.5 | 0 | 633 | 150 |
| graal-jit | xio (epoll) | 0 | 42/42 | 111 | 0.3 / 65.0 / 65.5 | 0 | 479 | 89 |
| node | libuv | 3 | 42/42 | 110 | 1.0 / 65.0 / 66.6 | 0 | 652 | 39 |
| wasi | WASI sockets | 0 | 42/42 | 109 | 5.6 / 68.6 / 135.2 | 0 | 4,347 | 123 |

Build times in the same run (no memory limit on the builds): JVM jars 131 s, kn 217 s, node 80 s, wasi 139 s,
native image 173 s.

How to read it:

- **1,000 users is a light load: about 110 requests/s.** Every runtime keeps up, so requests/s is the same for all.
- **The p95 of about 65 ms is the commit window, not server speed.** Writes join one transaction for up to 64 ms
  (group commit, rule 6), and every response produced while it is open, reads included, waits for its `COMMIT`.
- **CPU per request is the number that separates the runtimes.** It is the server's cgroup CPU time over the run
  divided by its requests. The run is short (40 s), so it includes warm-up: the JIT runtimes (graal-jit, node, and
  wasmtime's compiler) look worse here than they would after minutes of load. It ranks the runtimes; it is not the
  steady cost on the droplet.
- **The io_uring column shows each runtime does what it claims.** kn holds 8 rings, the GraalVM ring transport 1;
  the epoll builds and wasmtime hold none. Node holds 3: libuv in Node 24 uses io_uring for file operations.
- During this run another Gradle job (not part of this benchmark) was also running on the host (load average 2.16 at
  the start). CPU per request is counted per server cgroup; latency can include that contention.

## How to run it again

On a Linux host with systemd and passwordless sudo, 8 CPUs, and the tools from `install.sh` and
`bench/install-extra.sh`:

```bash
bash seed/make-seed.sh                                         # once, from the repository root
bash submissions/kotlin-trikeshed-jnorthrup/build.sh           # fetches TrikeShed at the pinned commit
bash submissions/kotlin-trikeshed-jnorthrup/bench/all1000.sh   # builds all five, then 42 checks + 1,000 users each
```

`VUS`, `RAMP`, `HOLD`, `SEED`, `TESTS` and `W` (the output directory) override the defaults. For the clean-container
build of one runtime:

```bash
docker run --rm --cpus=1 --memory=2g --memory-swap=2g --security-opt seccomp=unconfined \
  -v "$PWD":/src:ro -v /tmp/out:/out ubuntu:24.04 \
  bash /src/submissions/kotlin-trikeshed-jnorthrup/bench/droplet-ci.sh kn
```

`seccomp=unconfined`: Docker's default seccomp filter refuses io_uring, and the droplet has no such filter.
