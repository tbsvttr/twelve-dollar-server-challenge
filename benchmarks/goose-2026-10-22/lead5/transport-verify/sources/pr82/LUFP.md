The 16 October 2026 follow-up replaces production serde_json parsing with a standalone LUFP-style cursor in `src/lufp.rs`. The comparison baseline is PR #82 head `932131523fe0a16d8ad99f1f1ca0cab48ec79376`.

The cursor extracts the JWT header, claims and post body while validating each complete JSON document. Plain strings borrow their input; escaped strings use a checked decoder. Unknown nested values, trailing bytes, UTF-8, surrogate pairs, numbers and nesting limits are validated. JWT fields reject duplicates, and post bodies retain the previous last-key-wins behavior. JWT roots now require objects, fixing the previous acceptance of signed array-shaped headers and claims. Every token still receives an individual HS256 signature and expiration check.

serde and serde_json remain pinned development dependencies for the original-parser oracle and existing tests. They are absent from `cargo tree --locked --edges normal`. Cargo.lock consequently still contains them. The parser is self-contained; it does not depend on the unrelated trading workspace's LUFP crate or its sibling packages.

Measurements use Ubuntu 24.04.4 under WSL2, Linux 6.6.87.2, an Intel i9-13900H and Rust 1.94.0. The native Ubuntu test host was unreachable. These local results are not a DigitalOcean score. The server has one CPU, 2 GiB memory, no swap and an inherited 65,535 descriptor limit. CPU isolation is supplied by the test harness; the submitted application adds no affinity or host tuning. The load generator uses separate logical CPUs on the same machine.

Twelve balanced parser-only pairs each perform 500,000 iterations of header + claims + body parsing with optimizer barriers. Original parsing takes 221–244 ns per iteration and LUFP takes 107–124 ns. A second twelve-pair run after formatting and adding the guarded-input test measures 235–269 ns versus 119–140 ns. LUFP wins every pair in both runs: approximately twice as fast for this parsing work. Both versions already have zero Rust allocations for ordinary warmed requests.

The longer server comparison uses six balanced pairs per workload, 15-second measurements after three-second warmups, 64 connections and fresh copies of the official seed. Both binaries link the same SQLite PGO archive to avoid conflating parser changes with a retrained database library. No compilation runs during timing. All warmups and measured runs report zero socket, HTTP-status and semantic errors.

| Workload | Original median req/s | LUFP median req/s | Paired geometric mean change | Bootstrap 95% interval |
|---|---:|---:|---:|---:|
| Feed | 76,394 | 76,008 | −0.34% | −1.66% to +0.92% |
| Create | 32,343 | 33,622 | +5.11% | +1.46% to +10.27% |
| Like | 96,274 | 97,381 | +0.88% | −0.07% to +1.58% |
| Mixed | 74,409 | 74,959 | +0.21% | −0.80% to +1.26% |

Creation improves in all six throughput pairs and uses 1.31–3.73% less CPU per request in every pair. Creation's storage stalls still make its throughput gain less precise than its CPU reduction. Likes improve in five of six pairs. Feed and mixed intervals span both directions, so these results do not establish a mixed-workload speedup. The earlier four-pair, ten-second screen, including slower candidate runs, is retained in the evidence. This change is retained for its repeatable parsing gain and the longer creation results, without claiming an overall capacity gain.

The official workload averages 2 reads, 0.15 likes and 0.02 creates per successful user loop. JWT parsing therefore affects about 7.83% of requests and body parsing about 0.92%. Those are request proportions, not CPU shares; a substantial parser improvement can have a small overall effect.

Validation of the formatted source passes all 42 official checks, six reference-SQLite feed checks, ten Rust tests including the ignored diagnostics, and 96 additional protocol/auth/recovery checks with 15,000 simultaneous sockets and reuse of original sockets after 66 seconds. New tests cover Unicode, duplicate fields, grammar and depth boundaries, 60,000 mutated documents against the previous body parser, and SIMD input tails immediately adjacent to an inaccessible page. The original production build script also builds successfully and its binary passes the official, feed and 95-check protocol suites.

The normal production build passes the unchanged official `bench/load.js` at 15,000 users for a five-minute hold after a 1,000-user/two-minute warmup. Default ramps and think times are retained. The complete main run, including ramps, records 560,270 successful requests and checks, zero failures, p95 0.484 ms and p99 3.35 ms. The server cgroup peaks at 60.7 MiB. Seed copies are made outside the server cgroup, so that peak is not whole-host memory consumption. This confirms a sustained local load, not maximum capacity or a comparison against the old parser.

The fixed schema, queries, live reads, per-request signature checks, WAL/NORMAL settings and commit-before-reply behavior are preserved. The existing leading-NUL/schema CHECK boundary remains unresolved; no schema or constraint workaround is included.

Raw measurements, source/binary identities, validation logs and runner sources are retained in `bench/lufp-results.json.gz`. The comparison-only SQLite archive override is confined to the benchmark copy and is not part of the submitted build script. The normal production build and sustained workload use the unchanged build script and its own synthetic PGO training.
