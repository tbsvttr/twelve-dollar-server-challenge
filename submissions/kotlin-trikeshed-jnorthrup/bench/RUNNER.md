# Directions for the benchmark runner

The scored runtime is Kotlin/Native. Build and load measurements are in [BENCHMARK.md](../BENCHMARK.md).

## The scored run (nothing extra)

```bash
sudo bash install.sh     # apt packages, Oracle GraalVM 25.4.4.1.1, Gradle 9.6.1
bash build.sh            # TrikeShed at the pinned commit, then feed.kexe (Kotlin/Native)
bash start.sh            # serves RUNTIME=kn; first line on stderr: "start.sh: RUNTIME=kn"
```

The scored build ran on kali with one CPU, MemoryMax=1536M and no swap: rc=0 in 353 s, anon peak 1,220 MB, 42/42
checks. `build.sh` compiles TrikeShed from its pinned source and runs four single-use Gradle stages (SQLite download,
TrikeShed's Kotlin/Native compile, the server's compile, the release link).

## The other four runtimes (optional; we ask you to score the fastest)

`start.sh` picks the runtime with `RUNTIME=`. Build and run them **one at a time**: every build peaks near 1.8 GB, so
two builds at once, or a build beside a running server, do not fit in 2 GB. Stop the server before the next build.

| `RUNTIME=` | Extra install (root) | Build (user, from this folder) | Build memory peak |
|---|---|---|---|
| `kn` | none | `bash build.sh` | 1.22 GB (under a 1,536 MB limit) |
| `graal-static` | none | `/opt/gradle/bin/gradle --no-daemon -q :server:app :server:sqliteLib`, then the `native-image` line in `bench/all1000.sh` | 1.79 GB |
| `graal-jit` | none | `/opt/gradle/bin/gradle --no-daemon -q :server:app :server:sqliteLib` | not sampled (Gradle heap 1 GB) |
| `node` | `bash bench/install-extra.sh` | `/opt/gradle/bin/gradle --no-daemon -q -Ptrike.targets=js :server:nodeDist` | 1.26 GB |
| `wasi` | `bash bench/install-extra.sh` | `/opt/gradle/bin/gradle --no-daemon -q -Ptrike.targets=wasmWasi :server:wasiDist` | 1.56 GB |

Set `JAVA_HOME=/opt/graalvm` for the Gradle lines (`build.sh` does it itself). `bench/install-extra.sh` fetches Node.js
24.21.0, wasmtime 46.0.3 and wasi-sdk 34 with aria2c, checks each against `bench/DEPS.tsv`, and links them onto PATH.
It adds about 0.7 GB under `/opt`.

Launch any of them the same way, with the challenge's environment:

```bash
RUNTIME=graal-static bash start.sh        # TRANSPORT=ring by default; TRANSPORT=xio for epoll
RUNTIME=graal-jit    bash start.sh
RUNTIME=node         bash start.sh
RUNTIME=wasi         bash start.sh        # needs wasmtime 46 on PATH; start.sh refuses 47 or newer
```

A runtime whose build is missing falls back along kn, graal-static, graal-jit. Read the `start.sh: RUNTIME=` line to
see which one is serving.

## Any user count

`bench/all1000.sh` is named for its default, not limited to it. It builds all five runtimes, then gives each the 42
checks and `VUS` users of this folder's load generator:

```bash
VUS=64000 RAMP=60 HOLD=300 bash bench/all1000.sh
```

It needs a Linux host with systemd and passwordless sudo, and 8 CPUs: it pins the server to CPU 1 in a 1 CPU / 2 GB
unit and the client to CPUs 2-7. It is our test harness, not the scoring method. Your k6 runs (`bench/load.js`)
against each `RUNTIME=` are the score.

Results go to `$W/results.tsv` (default `/tmp/a1k`). Above about 65,000 users, the client needs a high file limit (the
script sets `ulimit -n 1048576` for the client only) and enough loopback source addresses (it uses 127.0.0.2-9).
