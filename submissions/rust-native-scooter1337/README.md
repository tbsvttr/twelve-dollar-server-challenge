# Rust / native SQLite read plans / io_uring

Direct HTTP/1.1 on `HOST:PORT` (`0.0.0.0:80` by default), without Nginx.
Rust 1.94.0, SQLite 3.54.1, pinned Cargo dependencies. Linux 6.1+ with io_uring enabled.

```sh
sudo bash install.sh
bash build.sh
SQLITE_PATH=/path/to/feed.db JWT_SECRET=twelve-dollar-challenge bash start.sh
```

The main idea comes from [hargup's Lean-derived C submission, #153](https://github.com/arjaythedev/twelve-dollar-server-challenge/pull/153):
execute known read plans through SQLite's own B-tree cursors, skipping the SQL
bytecode interpreter. The small C bridge exposes opaque cursors from the pinned
amalgamation. Record decoding, query plans, HTTP, JSON and authentication are Rust.

- Feed ordering is read from `posts_created_at_id_idx` on every request. No startup
  table scan, dense-ID assumption, remembered ordering invariant or result cache.
  Nearby IDs share a live likes-index range scan; sparse IDs use individual seeks.
  Consecutive descending IDs walk the posts cursor backwards. Both plans handle
  timestamp ties, gaps and out-of-order timestamps.
- One issuer drives all io_uring rings. Multishot accept/receive, fixed descriptor
  tables and provided buffers support more connections than ordinary process FDs.
  Passes handle at most 2,048 completions per ring, backed by 4,096 receive
  buffers. Retryable submission errors retain their CQEs.
  Idle connections retain no response allocation. Sends retain ownership until
  their final completion; generations reject completions for reused slots.
- A dedicated SQLite owner executes POSTs and commits while the issuer serves
  live reads through its own connection. Bounded queues transfer owned request
  and response buffers, reused from pools. Queue slots cover up to 4 KiB per job;
  all rings share a 32 MiB budget for capacity above that. Across both 8,192-job
  queues and the 1,024-job batch, outstanding raw-request capacity is at most
  100 MiB, including executing jobs and pending replies.
  Writes gather for 20 ms before opening
  a transaction, then execute at most 1,024 queued requests. Responses wait for
  successful commit; failed commits replace tentative replies with errors.
- Each connection's pipeline waits for its write response before serving the next
  request. Generations reject old-slot replies, and complete queued writes survive
  receive EOF. Full queues park held connections until the writer makes progress.
- SQLite's own 16 MiB page cache per request connection serves reads with mmap
  disabled. No application data or query results are cached.
- A separate connection performs SQLite's own PASSIVE checkpoints. WAL/NORMAL,
  foreign keys and the schema are unchanged. There is no custom storage engine or
  VFS, CPU affinity or kernel tuning. The process may raise its soft descriptor
  limit to its inherited hard limit.
- HS256 signatures and expiration are checked on every authenticated request.
  LUFP validates JSON; borrowed fields and reusable buffers avoid ordinary request
  allocations. SSE2/NEON escaping and a bounded unsafe writer reserve once per post.

Schema/index mismatches and unsupported io_uring operations fail explicitly.
Dependencies and the SQLite archive are pinned; the downloaded archive is checksum-verified.

Validation from the challenge root:

```sh
bash test/run.sh submissions/rust-native-scooter1337
python3 submissions/rust-native-scooter1337/tests/native_oracle.py \
  submissions/rust-native-scooter1337/target/release/twelve-rust-native schema.sql
```

The SQL oracle covers sparse IDs, unordered/tied timestamps, overflow records,
escaped UTF-8, committed writes and recovery after process termination.
The production binary passes all 42 repository checks, 17 Rust tests, the SQL
oracle, six feed checks and 96 protocol/recovery checks.
Protocol checks cover 15,000 simultaneous connections, original sockets reused
after 66 seconds idle, commit failures and recovery after SIGKILL. Regression
checks cover checkpoint-held and asynchronously queued writes across EOF,
commit-before-publication, failed-batch rollback, pipelines, reused slots, shared
request-byte backpressure and prompt descriptor release after closing EOF.

The last [official result, #238](https://github.com/arjaythedev/twelve-dollar-server-challenge/pull/238#issuecomment-6553794291),
is **210,000 users**. Comparisons on local linux proxmox use a one-CPU server quota,
2 GiB/no swap and a 65,535 descriptor hard limit. The host OS has multiple CPUs;
these diagnostics do not establish an official VM score.

Local comparison of dedicated-writer revision `a613014` against the merged #238
binary, using fresh seeds, the unchanged
`bench/load.js`, its standard 60-second ramp and a five-minute hold at 100k users:

| Version | Requests | p95 | p99 | Failed requests/checks |
| --- | ---: | ---: | ---: | ---: |
| Merged #238 | 3,730,460 | 76.37 ms | 249.97 ms | 0 |
| Dedicated writer | 3,734,811 | 15.75 ms | 68.63 ms | 0 |

Both pass persisted-data integrity checks. p99 falls 72.5%, with 0.12% more
requests. WAL size before shutdown falls from 3.47 GB to 2.09 GB. This does not
establish a RAM reduction: file cache dominates the container's memory usage.

A separate C load-generator diagnostic at 295k users, with a 60-second ramp and
five-minute hold, completes 31,219 versus 31,087 hold req/s (+0.43%). p95 falls
245 → 28 ms and p99 403 → 178 ms. The 91 requests pending at cutoff count as
failures (versus 714); there are no request/connect timeouts or connection errors.
Both databases pass integrity checks. This is a diagnostic generator, not the
scored JS workload or a comparison against a C server.

Two saturated comparisons in reversed order average 58,924 versus 56,170 completed
req/s (+4.9%). These use 1,024 clients without think time and nominal one-minute holds (68 seconds observed);
work pending at cutoff counts as failure. Batching increases saturated p95 from
23–26 ms to 51–52 ms; p99 ranges 151–189 ms versus 135–151 ms. These diagnostics
measure throughput and its latency tradeoff, not the challenge's user score.

The request-budget and closing-EOF follow-up retains the full correctness suite.
Four reversed one-minute saturation runs average 61,667 versus 61,737 completed
req/s (-0.11%, within the 0.5% regression tolerance). These review checks are
separate from the five-minute `a613014` results above.
