# c-epoll-patrickryankenneth

- **Language / framework:** C (gcc, `-O3 -march=x86-64-v2`), no framework. io_uring (multishot accept, direct sockets) with an epoll fallback.
- **Database:** SQLite 3.50.4 amalgamation, built from source in `build.sh`, in-process, `SQLITE_THREADSAFE=0`.
- **Nginx:** none. Serves directly on `HOST:PORT` (set `0.0.0.0:80` for the benchmark).

## What it does
- Hand-rolled HTTP/1.1 parser with keep-alive and pipelining; idle connections are never timed out.
- Idle connections own no buffers: one shared read buffer, per-connection memory only for partial requests / blocked writes.
- Hand-rolled SHA-256 + HMAC with the ipad/opad midstates precomputed; every token's signature and `exp` is verified on every request.
- Validating, zero-allocation JSON scanner for tokens and request bodies.
- Prepared, persistent statements; WAL + `synchronous=NORMAL`; each write is committed before its response is sent.
- No response caches, query caches or table copies.

## Local test notes
- Load was generated with a custom epoll client that follows bench/load.js's user model, not k6 itself, because k6 needs a lot of RAM per VU on a single test machine.
- Local results (podman, 2 GB cgroup, custom epoll-based load generator): 350,000 users, 0 failures, p99 12 ms; 400,000 passed with p95 269 ms. On a 1 vCPU / 2 GB Ubuntu 24.04 VM (kernel 6.8.0-117, systemd service, nofile 65535, database on the VM disk), 340,000 users is the claimed capacity: 345,000 passed a 5-minute hold three times (p99 195, 114 and 245 ms), while 360,000 and 375,000 failed. io_uring rings each get their own SO_REUSEPORT listener so connections spread evenly across them, and writes are group-committed: one SQLite transaction per event-loop pass, with no reply sent before its commit; the WAL auto-checkpoint threshold is raised to 10,000 pages so checkpoints stay out of the commit path. Kernel socket memory is about 3.4 KB per connection.
- These runs used a tuned host: nofile 1,048,576, fs.file-max and fs.nr_open 2,097,152, somaxconn 65535, conntrack_max raised. Per rule 11 the benchmark box is not tuned, so results there depend on its default limits.
- The server raises its soft RLIMIT_NOFILE to the hard limit and caps at 2,097,152 fds. A hard-coded 262,144 cap was the earlier ceiling.
