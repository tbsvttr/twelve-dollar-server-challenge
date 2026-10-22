# Goose HMAC-only follow-up

**Predeclared stable ≥5% target: UNMET.** Paired Goose/Rust geometric mean: **1.13725× (+13.72%)**; one-sided 95% lower bound: **1.01854× (+1.85%)**; pairs above 5%: **8/10**.

Failed gates: one sided 95 percent lower bound at least 5 percent, nine of ten pairs at least 5 percent, independent target audit.

The target requires all primary and independent audit gates. A positive point estimate alone is insufficient. [Final summary](<finalholdout-summary.json>); [independent audit](<independent-audit.json>); [selection and declaration](<selection.json>).

The first independent ten-round holdout **failed** the stable 5% target: 1.10729× (+10.73%) paired geometric mean, 1.04132× (+4.13%) lower bound and 7/10 pairs above 5%. Its [report](<../holdout-selected/RESULT.md>), [raw measurements](<../holdout-selected/measurements.json>) and [audit](<../holdout-selected/independent-audit.json>) remain preserved. Those measurements are not pooled with this new holdout.

## Confirmation

| Requirement | Observed | Gate |
| --- | --- | --- |
| Clean normal source build: one CPU, 2 GiB, no swap | Fresh SQLite and application PGO | PASS |
| Identity/correctness/database/resource evidence | All recorded checks | PASS |
| Ten clean matched rounds | 10/10 | PASS |
| At most two invalid-round replacements | 0 | PASS |
| No candidate errors in any attempt, including warmup | 0 | PASS |
| Every candidate attempt valid | [] | PASS |
| Geometric mean ≥1.05 | 1.13725× (+13.72%) | PASS |
| One-sided 95% Student-t lower bound ≥1.05 | 1.01854× (+1.85%) | FAIL |
| At least nine of ten pairs above 5% | 8/10 | FAIL |
| Median p99 ≤1.05× Rust | Goose 25.27 ms; Rust 25.55 ms | PASS |

All 30 attempts in 10 rounds are retained. Invalid rounds are excluded for all three implementations; low throughput alone is never an exclusion. The success test uses the first ten clean paired log ratios and a one-sided 95% Student-t bound with nine degrees of freedom.

| Round | Selected | Rust req/s | New Goose req/s | Goose control: 73148f5d49e0 req/s | New / Rust |
| --- | --- | --- | --- | --- | --- |
| 1 | yes | 78,990.26 | 115,939.73 | 108,814.27 | 1.46777× (+46.78%) |
| 2 | yes | 85,960.20 | 114,092.22 | 106,147.24 | 1.32727× (+32.73%) |
| 3 | yes | 85,046.92 | 116,771.41 | 106,932.13 | 1.37302× (+37.30%) |
| 4 | yes | 108,752.77 | 116,522.38 | 104,168.07 | 1.07144× (+7.14%) |
| 5 | yes | 104,193.53 | 113,174.28 | 97,500.41 | 1.08619× (+8.62%) |
| 6 | yes | 101,750.06 | 124,384.82 | 113,404.49 | 1.22245× (+22.25%) |
| 7 | yes | 112,421.82 | 83,878.52 | 69,879.99 | 0.74611× (-25.39%) |
| 8 | yes | 102,762.44 | 118,321.99 | 108,533.80 | 1.15141× (+15.14%) |
| 9 | yes | 114,295.94 | 118,892.31 | 111,919.10 | 1.04021× (+4.02%) |
| 10 | yes | 109,984.36 | 117,038.02 | 103,779.63 | 1.06413× (+6.41%) |

| Selected-round medians | Req/s | p95 ms | p99 ms | RSS MiB | CPU % |
| --- | --- | --- | --- | --- | --- |
| Rust PR 82 | 103,477.99 | 14.93 | 25.55 | 66.96 | 87.03 |
| HMAC-only Goose | 116,646.90 | 16.70 | 25.27 | 15.26 | 86.85 |
| Goose control: 73148f5d49e0 | 106,539.68 | 15.80 | 25.68 | 58.19 | 90.46 |

## Every attempt

| Round | Case | Used | Req/s | Seconds | p99 ms | HTTP/socket | Warmup HTTP/socket | Output |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | HMAC-only Goose | yes | 115,939.73 | 45.08 | 26.82 | 0/0 | 0/0 | [raw](<logs/bench-goose-1.log>) |
| 1 | Rust PR 82 | yes | 78,990.26 | 45.05 | 25.96 | 0/0 | 0/0 | [raw](<logs/bench-82-1.log>) |
| 1 | Goose control: 73148f5d49e0 | yes | 108,814.27 | 45.08 | 22.80 | 0/0 | 0/0 | [raw](<logs/bench-baseline-1.log>) |
| 2 | HMAC-only Goose | yes | 114,092.22 | 45.06 | 24.58 | 0/0 | 0/0 | [raw](<logs/bench-goose-2.log>) |
| 2 | Rust PR 82 | yes | 85,960.20 | 45.02 | 25.88 | 0/0 | 0/0 | [raw](<logs/bench-82-2.log>) |
| 2 | Goose control: 73148f5d49e0 | yes | 106,147.24 | 45.08 | 25.25 | 0/0 | 0/0 | [raw](<logs/bench-baseline-2.log>) |
| 3 | HMAC-only Goose | yes | 116,771.41 | 45.09 | 24.26 | 0/0 | 0/0 | [raw](<logs/bench-goose-3.log>) |
| 3 | Goose control: 73148f5d49e0 | yes | 106,932.13 | 45.08 | 26.02 | 0/0 | 0/0 | [raw](<logs/bench-baseline-3.log>) |
| 3 | Rust PR 82 | yes | 85,046.92 | 45.02 | 25.33 | 0/0 | 0/0 | [raw](<logs/bench-82-3.log>) |
| 4 | Rust PR 82 | yes | 108,752.77 | 45.06 | 24.61 | 0/0 | 0/0 | [raw](<logs/bench-82-4.log>) |
| 4 | HMAC-only Goose | yes | 116,522.38 | 45.06 | 25.52 | 0/0 | 0/0 | [raw](<logs/bench-goose-4.log>) |
| 4 | Goose control: 73148f5d49e0 | yes | 104,168.07 | 45.09 | 26.11 | 0/0 | 0/0 | [raw](<logs/bench-baseline-4.log>) |
| 5 | HMAC-only Goose | yes | 113,174.28 | 45.07 | 24.13 | 0/0 | 0/0 | [raw](<logs/bench-goose-5.log>) |
| 5 | Goose control: 73148f5d49e0 | yes | 97,500.41 | 45.10 | 25.34 | 0/0 | 0/0 | [raw](<logs/bench-baseline-5.log>) |
| 5 | Rust PR 82 | yes | 104,193.53 | 45.09 | 25.77 | 0/0 | 0/0 | [raw](<logs/bench-82-5.log>) |
| 6 | Rust PR 82 | yes | 101,750.06 | 45.10 | 24.09 | 0/0 | 0/0 | [raw](<logs/bench-82-6.log>) |
| 6 | Goose control: 73148f5d49e0 | yes | 113,404.49 | 45.07 | 24.32 | 0/0 | 0/0 | [raw](<logs/bench-baseline-6.log>) |
| 6 | HMAC-only Goose | yes | 124,384.82 | 45.09 | 24.54 | 0/0 | 0/0 | [raw](<logs/bench-goose-6.log>) |
| 7 | Rust PR 82 | yes | 112,421.82 | 45.10 | 24.33 | 0/0 | 0/0 | [raw](<logs/bench-82-7.log>) |
| 7 | Goose control: 73148f5d49e0 | yes | 69,879.99 | 45.06 | 23.94 | 0/0 | 0/0 | [raw](<logs/bench-baseline-7.log>) |
| 7 | HMAC-only Goose | yes | 83,878.52 | 45.07 | 25.23 | 0/0 | 0/0 | [raw](<logs/bench-goose-7.log>) |
| 8 | Rust PR 82 | yes | 102,762.44 | 45.08 | 26.98 | 0/0 | 0/0 | [raw](<logs/bench-82-8.log>) |
| 8 | HMAC-only Goose | yes | 118,321.99 | 45.09 | 25.30 | 0/0 | 0/0 | [raw](<logs/bench-goose-8.log>) |
| 8 | Goose control: 73148f5d49e0 | yes | 108,533.80 | 45.10 | 26.57 | 0/0 | 0/0 | [raw](<logs/bench-baseline-8.log>) |
| 9 | HMAC-only Goose | yes | 118,892.31 | 45.09 | 25.41 | 0/0 | 0/0 | [raw](<logs/bench-goose-9.log>) |
| 9 | Rust PR 82 | yes | 114,295.94 | 45.06 | 25.23 | 0/0 | 0/0 | [raw](<logs/bench-82-9.log>) |
| 9 | Goose control: 73148f5d49e0 | yes | 111,919.10 | 45.08 | 26.68 | 0/0 | 0/0 | [raw](<logs/bench-baseline-9.log>) |
| 10 | Rust PR 82 | yes | 109,984.36 | 45.07 | 26.59 | 0/0 | 0/0 | [raw](<logs/bench-82-10.log>) |
| 10 | HMAC-only Goose | yes | 117,038.02 | 45.08 | 26.63 | 0/0 | 0/0 | [raw](<logs/bench-goose-10.log>) |
| 10 | Goose control: 73148f5d49e0 | yes | 103,779.63 | 45.10 | 26.62 | 0/0 | 0/0 | [raw](<logs/bench-baseline-10.log>) |

| All attempted runs | HTTP | Socket | Warmup HTTP | Warmup socket |
| --- | --- | --- | --- | --- |
| HMAC-only Goose | 0 | 0 | 0 | 0 |
| Rust PR 82 | 0 | 0 | 0 | 0 |
| Goose control: 73148f5d49e0 | 0 | 0 | 0 | 0 |

[Raw measurements and all percentiles](<measurements.json>); [server logs](<server-logs>).

## The server change

HMAC/SHA256 uses owned keyed EVP_MAC state, reinitialized for each token; changed secrets replace state transactionally and crypto errors fail closed. Every token still receives a fresh signature computation. There is no token, response or query-result cache. The original three-query feed and its sparse fallback remain unchanged; Goose retains routing, validation, SQL and response structure.

This change builds on source `09e695a0652cc4654e12d5382b423adf75b7ea7c5ef18978313ddff3cc9d13ed`: legacy SQLite PGO, four-unit application PGO/LTO, response-header/time batching, 8 MiB SQLite cache with mmap disabled, and bounded likes scanning. Commit-before-response behavior and durability settings remain.

| Implementation | Source SHA-256 | Image SHA-256 | Binary SHA-256 |
| --- | --- | --- | --- |
| Rust PR 82 | b91b9491e2a7a8856f8f360bc89f376b6493ae9b9a3907c557836b94f5131438 | sha256:64227e803306084617be2a4ebc1c3623260d265f158dd8c009f647558a280135 | 61d48f1be2feb858a14b1617cf3221bebf68df6caaac3541116e0dfbb7562026 |
| HMAC-only Goose | 9a298580809e2a6821c7a8068b6a45315ae7aaa4b58bb79edc3f94606b9f861b | sha256:afde328ec4a000f300730f264ee883f973769130994762ebd8c8efdf794a8508 | a5e1c087110e0dde7bda696620327a6c37178ee62e09d3c56d53c49a708c10fb |
| Goose control: 73148f5d49e0 | 73148f5d49e07fc62289bf582e261b8df0e1ef51d478d6fb9d44a68fec87b88a | sha256:a69064953b766ec5c800389b8e17a7d184f73aa8dd46cd4aa2048955ee86eb0f | f0b086e53343263381c55a9046dbd65f400c4ec5ebbfc872c5d682d20a5679ab |

The frozen candidate contains 19 source files. Compiler: gcc (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0; goose runtime df5f78ce88d4. Rust Git commit: `95aa405a0003599dbc7fb4dfa47a09e8343239df`. [Build/source/binary proofs](<build-status.json>); [normal-build candidate image proof](<../candidates/hmac-budget/image-proof.json>). The measured candidate is a clean normal-user source build with fresh legacy SQLite PGO and fresh four-unit application PGO, using independent synthetic fixtures and no object reuse. The earlier unmeasured rebuild applies only to source 09e695 and is [recorded separately](<../candidates/selected-reproduction/comparison.json>).

The normal build succeeded as UID 1001 in 44.276 seconds. Recorded cgroup peak memory: 412,934,144 bytes (393.80 MiB). Limits: cpu.max=`100000 100000`, memory.max=`2147483648`, memory.swap.max=`0`. [Complete resource/build proof](<../candidates/hmac-budget/resource-budget-build.json>). The initial attempt failed on stale root-owned generated artifacts; [that failure remains archived](<../candidates/hmac-only/resource-budget-build-first-failure.json>).

## Correctness

| Evidence | Checks | Result |
| --- | --- | --- |
| Rust PR 82 | 42/42 | PASS |
| HMAC-only Goose | 42/42 | PASS |
| Goose control: 73148f5d49e0 | 42/42 | PASS |
| Parser | 18/18 | PASS |
| Edge cases | 25/25 | PASS |
| Likes above maximum | 9/9 | PASS |

Official checks are accompanied by dynamic create/read/like/feed semantic and committed SQLite integrity checks. [Verification records](<verification.json>). The crypto adapter passed 139/139 differential and injected-failure checks against the frozen one-shot implementation and Python HMAC; 10,000 valid and 10,000 invalid-signature calls passed ASAN/UBSAN/leak checks, including key changes and actual exit cleanup. [Crypto results/proof](<../candidates/feed-hmac/hmac-tests/proof.json>); [sanitizer log](<../candidates/feed-hmac/hmac-tests/sanitizer.log>). The unchanged transport retains its 2,320 byte-for-byte header comparisons and socket/clock sanitizer regressions in [transport evidence](<../transport/results.json>).

## Selection and measurement scope

The normal-build binary was selected using exactly two sequential 15-second matched triplets (six server attempts), with only one server instance running at a time. There was no new A/A or shared-server diagnostic. These samples are selection evidence only and are excluded from confirmation statistics.

| Trial | New Goose req/s | Rust req/s | Previous09 Goose req/s | New / Rust | New / previous09 | HTTP/socket errors |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | 115,902.31 | 105,501.06 | 102,495.27 | 1.09859× (+9.86%) | 1.13081× (+13.08%) | 0 |
| 2 | 117,688.35 | 106,649.32 | 117,863.58 | 1.10351× (+10.35%) | 0.99851× (-0.15%) | 0 |

[Complete sequential selection records](<../hmac-budget-checks/measurements.json>). The fused-feed/HMAC candidate was rejected after both side-swapped comparisons were slower than source 09e695; [its six diagnostic pairs](<../paired-diagnostic-feed-hmac/summary.json>) and [HMAC-only declaration](<../PROTOCOL-hmac-only.md>) preserve that decision. The rejected fused feed is not installed. Earlier discovery also remains available: [paired-diagnostic-first](<../paired-diagnostic-first/summary.json>), [paired-diagnostic-second](<../paired-diagnostic-second/summary.json>), [paired-diagnostic-final-selection](<../paired-diagnostic-final-selection/summary.json>); [cache grid](<../cache-grid/measurements.json>) and [isolated screen](<../isolated-screen/measurements.json>). All 32 earlier sequential attempts and 18 earlier shared pairs remain selection-only evidence; [the first index](<../README-first-holdout.md>) retains their comparison matrix.

The comparison uses unchanged Rust and the explicitly pinned Goose control, identical fixtures and mixed workload, two-second warmups and 45-second measurements. Servers use guest CPU 0, one CPU quota and 2 GiB RAM; swap is disabled and only one server instance runs at a time. The external load generator uses CPUs 1–2, two threads and 64 connections. Host: Apple M2 Pro, kept as-is with unrelated activity. All cases use the same declared monotonic-clock wrk driver; [driver declaration](<../PROTOCOL-monotonic.md>) and [runtime/clock proof](<../wrk-monotonic/runtime-proof.json>). The clock correction preserves genuine timeout accounting; event-loop scheduling still uses wall time and host scheduling noise remains. This is a complete-implementation comparison in native Linux ARM64 Docker on a local Mac, not an isolated language effect or official x86-64 k6 capacity result.

The first holdout already enforced one-CPU/2-GiB/no-swap limits on every confirmation server; its actual configurations remain in [all thirty original attempts](<../holdout-selected/measurements.json>). Earlier compilation and functional checks used extra CPUs. From the [resource-budget declaration](<../PROTOCOL-resource-budget.md>) onward, server builds and functional checks also use one CPU, 2 GiB and no swap; the clock monitor is stopped and shared-server diagnostics are discontinued. The load generator remains outside the server budget, as official k6 runs on a separate machine; on this Mac it still shares the Docker host.
