Add a Goose implementation with a direct Linux HTTP server and SQLite. Goose owns routing, JWT claims, JSON/Unicode validation, SQL and response construction; native C helpers provide transport, SQLite, HMAC and JSON quoting. Dependencies are pinned and verified, and the build trains PGO on independent disposable fixtures.

The server defaults to epoll, reuses prepared SQLite statements and HMAC key setup, and commits writes before sending responses. It serves fresh database results and verifies every token signature.

Validation: local Linux ARM64 runs passed 42/42 official assertions, six live semantic checks, 52 supplemental API checks, and crypto differential/failure/sanitizer checks. A fresh application/SQLite PGO build with the compiler preinstalled passed under one CPU / 2 GiB / no swap (44.28 s, 393.80 MiB peak). The upstream Ubuntu 24.04 install/build/API workflow also passed on x86-64. Clean compiler bootstrap within the one-CPU/2-GiB budget remains unverified.

Ten matched 45-second trials per implementation gave Goose 116,646.90 median req/s against pinned Rust PR82's 103,477.99. The paired geometric mean was +13.72%, but the one-sided 95% lower bound was +1.85%, with 8/10 pairs above 5%: the stable ≥5% target remains unmet. This is a local ARM64 wrk saturation comparison, with no official x86-64 k6 capacity claim. All attempts and the unchanged controls are preserved.

Only `submissions/goose-native-tbsvttr/` is added. The README, benchmark-results.json and validation-results.json describe the implementation, limits and public evidence. Runtime sources and scripts match the measured source snapshot.

[Public measurement evidence](https://github.com/tbsvttr/twelve-dollar-server-challenge/blob/91c6ba1384015ffd8f27910cbb16e98dbaf90f44/benchmarks/goose-2026-10-22/README.md)


**Unified comparison table:** [The main list](https://github.com/arjaythedev/twelve-dollar-server-challenge/issues/7#issuecomment-6292218419) and [CSV](https://github.com/tbsvttr/twelve-dollar-server-challenge/blob/benchmark-2026-10-22/benchmarks/2026-10-22/comparison.csv) now include PR143 as outcome 120. The original stock-wrk 3×15-second protocol measured 117,565.71 successful req/s, p99 22.060 ms and 15.26 MiB RSS. All official/dynamic/database checks passed; The error columns retain all 38 reported wrk timeouts alongside the throughput value. Every prior measurement remains preserved. The longer corrected-driver confirmation above remains separate.


All 127 current, historical, control and confirmation rows share one throughput-sorted table with explicit status and protocol columns.


**Requirement status:** The table explicitly labels recorded local conditions: the 3×15s Goose row is FAIL (38 reported wrk timeouts); the 10×45s row is DIFFERENT_PROTOCOL. PASS elsewhere means only the documented local runtime checks. Original x86-64 droplet/k6 conditions without CPU affinity were not reproduced by the local ARM64 Docker/wrk experiments. Full challenge-rule compliance and source-build resource limits remain unverified.
