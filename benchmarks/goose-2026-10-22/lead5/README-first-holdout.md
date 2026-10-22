# Goose versus Rust: 5% holdout — UNMET

**Predeclared stable ≥5% target: UNMET.** Failed gates: one sided 95 percent lower bound at least 5 percent, nine of ten pairs at least 5 percent, independent target audit.

Goose/Rust geometric mean of paired throughput ratios: **1.10729× (+10.73%)**. One-sided 95% Student-t lower bound: **1.04132× (+4.13%)**. 7/10 selected pairs exceeded 5%. Independent evidence audit: **PASS**; independent target audit: **FAIL**.

The outcome uses the [predeclared protocol](<PROTOCOL.md>), [final primary summary](<holdout-selected/finalholdout-summary.json>) and [independent audit](<holdout-selected/independent-audit.json>). A positive point estimate alone does not satisfy the target.

The complete selected holdout report is [holdout-selected/RESULT.md](<holdout-selected/RESULT.md>). Earlier reports remain unchanged in [the experiment archive](<..>).

## Confirmation

| Requirement | Observed | Gate |
| --- | --- | --- |
| Identity, fixtures, raw correctness, database and resource evidence | All verified | PASS |
| Complete clean matched rounds | 10/10 | PASS |
| Replacement bound | 0 excluded; at most two replacements | PASS |
| Candidate errors in every attempted run, including warmup | 0 | PASS |
| Every candidate attempt valid | [] | PASS |
| Paired geometric mean ≥1.05 | 1.10729× (+10.73%) | PASS |
| One-sided 95% lower bound ≥1.05 | 1.04132× (+4.13%) | FAIL |
| At least 9/10 pairs above 5% | 7/10 | FAIL |
| Candidate median p99 ≤1.05× Rust | 24.86 / 25.02 ms; 0.99361× (-0.64%) | PASS |

10 rounds and 30 server attempts are retained. Selected rounds: 1, 2, 3, 4, 5, 6, 7, 8, 9, 10. Any invalid round is excluded for all three implementations. Low throughput alone is not an exclusion reason. The confidence bound uses log ratios and Student-t with nine degrees of freedom when ten clean rounds exist.

| Round | Selected | Rust req/s | New Goose req/s | Retained Goose req/s | New / Rust |
| --- | --- | --- | --- | --- | --- |
| 1 | yes | 75,785.37 | 89,615.45 | 80,273.26 | 1.18249× (+18.25%) |
| 2 | yes | 67,644.01 | 96,052.58 | 96,791.53 | 1.41997× (+42.00%) |
| 3 | yes | 97,565.91 | 108,845.50 | 96,875.42 | 1.11561× (+11.56%) |
| 4 | yes | 99,899.47 | 108,998.58 | 97,387.38 | 1.09108× (+9.11%) |
| 5 | yes | 99,922.66 | 108,019.65 | 95,629.95 | 1.08103× (+8.10%) |
| 6 | yes | 100,087.64 | 113,308.12 | 97,463.59 | 1.13209× (+13.21%) |
| 7 | yes | 105,515.10 | 114,427.24 | 104,861.53 | 1.08446× (+8.45%) |
| 8 | yes | 109,625.81 | 113,466.02 | 79,283.88 | 1.03503× (+3.50%) |
| 9 | yes | 109,017.72 | 113,840.61 | 106,340.56 | 1.04424× (+4.42%) |
| 10 | yes | 110,178.10 | 104,125.60 | 92,692.48 | 0.94507× (-5.49%) |

Selected-round medians are descriptive; the success test uses paired ratios.

| Implementation | Req/s | p95 ms | p99 ms | RSS MiB | CPU % |
| --- | --- | --- | --- | --- | --- |
| Rust PR 82 | 100,005.15 | 14.80 | 25.02 | 66.38 | 89.19 |
| Selected Goose | 108,922.04 | 15.51 | 24.86 | 15.27 | 87.97 |
| Retained Goose | 96,833.48 | 14.31 | 25.95 | 55.41 | 90.88 |

## All attempts

Every raw latency and error count remains in [measurements.json](<holdout-selected/measurements.json>); links below retain the raw output. Candidate errors also prevent success when their whole round is excluded.

| # | Round | Case | Used | Req/s | Seconds | p50/p95/p99 ms | RSS MiB | CPU % | HTTP/socket | Warmup HTTP/socket | Output |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 1 | Selected Goose | yes | 89,615.45 | 45.09 | 0.460/16.982/28.170 | 15.26 | 86.55 | 0/0 | 0/0 | [raw](<holdout-selected/logs/bench-goose-1.log>) |
| 2 | 1 | Rust PR 82 | yes | 75,785.37 | 45.07 | 0.583/15.044/29.020 | 59.36 | 84.85 | 0/0 | 0/0 | [raw](<holdout-selected/logs/bench-82-1.log>) |
| 3 | 1 | Retained Goose | yes | 80,273.26 | 45.10 | 0.535/14.261/27.050 | 50.61 | 89.09 | 0/0 | 0/0 | [raw](<holdout-selected/logs/bench-baseline-1.log>) |
| 4 | 2 | Selected Goose | yes | 96,052.58 | 45.07 | 0.442/16.092/28.330 | 15.27 | 87.55 | 0/0 | 0/0 | [raw](<holdout-selected/logs/bench-goose-2.log>) |
| 5 | 2 | Rust PR 82 | yes | 67,644.01 | 45.08 | 0.664/13.494/28.560 | 57.05 | 84.56 | 0/0 | 0/0 | [raw](<holdout-selected/logs/bench-82-2.log>) |
| 6 | 2 | Retained Goose | yes | 96,791.53 | 45.06 | 0.478/14.202/24.910 | 55.13 | 90.83 | 0/0 | 0/0 | [raw](<holdout-selected/logs/bench-baseline-2.log>) |
| 7 | 3 | Selected Goose | yes | 108,845.50 | 45.06 | 0.405/15.162/24.610 | 15.26 | 88.99 | 0/0 | 0/0 | [raw](<holdout-selected/logs/bench-goose-3.log>) |
| 8 | 3 | Retained Goose | yes | 96,875.42 | 45.09 | 0.494/14.847/25.570 | 55.77 | 91.31 | 0/0 | 0/0 | [raw](<holdout-selected/logs/bench-baseline-3.log>) |
| 9 | 3 | Rust PR 82 | yes | 97,565.91 | 45.04 | 0.481/14.248/25.050 | 64.96 | 89.16 | 0/0 | 0/0 | [raw](<holdout-selected/logs/bench-82-3.log>) |
| 10 | 4 | Rust PR 82 | yes | 99,899.47 | 45.08 | 0.476/14.382/24.800 | 66.57 | 89.82 | 0/0 | 0/0 | [raw](<holdout-selected/logs/bench-82-4.log>) |
| 11 | 4 | Selected Goose | yes | 108,998.58 | 45.07 | 0.403/15.366/24.550 | 15.26 | 88.69 | 0/0 | 0/0 | [raw](<holdout-selected/logs/bench-goose-4.log>) |
| 12 | 4 | Retained Goose | yes | 97,387.38 | 45.06 | 0.485/16.186/27.100 | 55.86 | 90.93 | 0/0 | 0/0 | [raw](<holdout-selected/logs/bench-baseline-4.log>) |
| 13 | 5 | Selected Goose | yes | 108,019.65 | 45.08 | 0.405/15.655/25.110 | 15.25 | 88.39 | 0/0 | 0/0 | [raw](<holdout-selected/logs/bench-goose-5.log>) |
| 14 | 5 | Retained Goose | yes | 95,629.95 | 45.06 | 0.489/15.650/26.570 | 55.68 | 90.97 | 0/0 | 0/0 | [raw](<holdout-selected/logs/bench-baseline-5.log>) |
| 15 | 5 | Rust PR 82 | yes | 99,922.66 | 45.10 | 0.470/15.438/25.960 | 66.19 | 89.25 | 0/0 | 0/0 | [raw](<holdout-selected/logs/bench-82-5.log>) |
| 16 | 6 | Rust PR 82 | yes | 100,087.64 | 45.05 | 0.471/15.274/25.980 | 65.87 | 89.29 | 0/0 | 0/0 | [raw](<holdout-selected/logs/bench-82-6.log>) |
| 17 | 6 | Retained Goose | yes | 97,463.59 | 45.06 | 0.473/13.863/24.740 | 54.89 | 90.61 | 0/0 | 0/0 | [raw](<holdout-selected/logs/bench-baseline-6.log>) |
| 18 | 6 | Selected Goose | yes | 113,308.12 | 45.09 | 0.384/16.672/25.950 | 15.35 | 87.21 | 0/0 | 0/0 | [raw](<holdout-selected/logs/bench-goose-6.log>) |
| 19 | 7 | Rust PR 82 | yes | 105,515.10 | 45.09 | 0.442/14.685/24.990 | 68.09 | 88.39 | 0/0 | 0/0 | [raw](<holdout-selected/logs/bench-82-7.log>) |
| 20 | 7 | Retained Goose | yes | 104,861.53 | 45.06 | 0.464/12.594/22.350 | 58.32 | 91.88 | 0/0 | 0/0 | [raw](<holdout-selected/logs/bench-baseline-7.log>) |
| 21 | 7 | Selected Goose | yes | 114,427.24 | 45.10 | 0.387/14.706/23.890 | 15.37 | 88.50 | 0/0 | 0/0 | [raw](<holdout-selected/logs/bench-goose-7.log>) |
| 22 | 8 | Rust PR 82 | yes | 109,625.81 | 45.05 | 0.436/14.907/24.560 | 68.36 | 89.23 | 0/0 | 0/0 | [raw](<holdout-selected/logs/bench-82-8.log>) |
| 23 | 8 | Selected Goose | yes | 113,466.02 | 45.08 | 0.382/14.566/23.480 | 15.27 | 87.25 | 0/0 | 0/0 | [raw](<holdout-selected/logs/bench-goose-8.log>) |
| 24 | 8 | Retained Goose | yes | 79,283.88 | 45.09 | 0.524/13.169/26.320 | 49.83 | 82.68 | 0/0 | 0/0 | [raw](<holdout-selected/logs/bench-baseline-8.log>) |
| 25 | 9 | Selected Goose | yes | 113,840.61 | 45.07 | 0.391/14.227/23.130 | 15.38 | 88.40 | 0/0 | 0/0 | [raw](<holdout-selected/logs/bench-goose-9.log>) |
| 26 | 9 | Rust PR 82 | yes | 109,017.72 | 45.07 | 0.438/15.099/24.700 | 68.53 | 89.14 | 0/0 | 0/0 | [raw](<holdout-selected/logs/bench-82-9.log>) |
| 27 | 9 | Retained Goose | yes | 106,340.56 | 45.08 | 0.455/14.359/24.240 | 58.61 | 91.56 | 0/0 | 0/0 | [raw](<holdout-selected/logs/bench-baseline-9.log>) |
| 28 | 10 | Rust PR 82 | yes | 110,178.10 | 45.07 | 0.435/14.133/23.620 | 68.41 | 89.88 | 0/0 | 0/0 | [raw](<holdout-selected/logs/bench-82-10.log>) |
| 29 | 10 | Selected Goose | yes | 104,125.60 | 45.06 | 0.414/17.511/29.130 | 15.37 | 86.82 | 0/0 | 0/0 | [raw](<holdout-selected/logs/bench-goose-10.log>) |
| 30 | 10 | Retained Goose | yes | 92,692.48 | 45.07 | 0.496/14.980/26.420 | 53.96 | 89.67 | 0/0 | 0/0 | [raw](<holdout-selected/logs/bench-baseline-10.log>) |

| All attempted runs | HTTP | Socket | Warmup HTTP | Warmup socket |
| --- | --- | --- | --- | --- |
| Selected Goose | 0 | 0 | 0 | 0 |
| Rust PR 82 | 0 | 0 | 0 | 0 |
| Retained Goose | 0 | 0 | 0 | 0 |

## Frozen implementation

| Implementation | Source snapshot / Git commit | Image SHA-256 | Binary SHA-256 |
| --- | --- | --- | --- |
| Rust PR 82 | b91b9491e2a7a8856f8f360bc89f376b6493ae9b9a3907c557836b94f5131438; commit 95aa405a0003599dbc7fb4dfa47a09e8343239df | sha256:64227e803306084617be2a4ebc1c3623260d265f158dd8c009f647558a280135 | 61d48f1be2feb858a14b1617cf3221bebf68df6caaac3541116e0dfbb7562026 |
| Selected Goose | 09e695a0652cc4654e12d5382b423adf75b7ea7c5ef18978313ddff3cc9d13ed | sha256:d0a2f1e95817cefd26c9563d86849efff6cb2bb5dc0e2ff733ed7656577ef9ea | 309f1138b9c5d6b404670a8c0eaf1d42c2f96d4fc7e30d7a89f5bff326a5af2e |
| Retained Goose | 73148f5d49e07fc62289bf582e261b8df0e1ef51d478d6fb9d44a68fec87b88a | sha256:a69064953b766ec5c800389b8e17a7d184f73aa8dd46cd4aa2048955ee86eb0f | f0b086e53343263381c55a9046dbd65f400c4ec5ebbfc872c5d682d20a5679ab |

The selected Goose snapshot contains 19 files. [Selection record](<holdout-selected/selection.json>) binds the source, image, binary, protocol and common driver before confirmation. Compiler: gcc (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0; Goose runtime goose runtime df5f78ce88d4, compiler commit `f605b5a07dd2aa3a5cb3f4c9b14002bd3c9d3d1a`.

The shipping build uses separately trained **legacy SQLite PGO** and **four-unit application PGO/LTO** (generated Goose, transport, database adapters and JSON quoting). Runtime changes are fixed response-header fragments/decimal lengths, monotonic activity time refreshed per poll/flush including after commit, an 8 MiB SQLite page cache with mmap disabled, and an indexed lower-bound likes query whose upper bound is checked in Goose before bounded array access. Writes commit before responses. This selected build does not include SQLite in application LTO and does not use trainer v2.

## Correctness and transport

| Evidence | Checks | Result |
| --- | --- | --- |
| Rust PR 82 | 42/42 | PASS |
| Selected Goose | 42/42 | PASS |
| Retained Goose | 42/42 | PASS |
| Selected parser | 18/18 | PASS |
| Selected edge cases | 25/25 | PASS |
| Likes above maximum / omitted IDs | 9/9 | PASS |

Official checks are followed by dynamic create/read/like/feed semantic checks and committed SQLite growth/integrity checks. See [verification](<holdout-selected/verification.json>), [parser checks](<holdout-selected/parser-checks.json>), [edge checks](<holdout-selected/edge-checks.json>) and [nine additional likes checks](<holdout-selected/above-max-checks.json>).

Transport regression result: **passed**. The retained suite covers 2,320 exact header comparisons, clock freshness after waits/commits, fragmentation, pipelining, chunked bodies, large/blocked writes, half-close and failed-commit responses. Address/undefined-behavior sanitizers and leak checks returned exit code 0. The initial clock-fixture failure and correction are retained with the [transport evidence](<transport/results.json>).

## Discovery and rejected variants

All **32 sequential discovery attempts** and **18 shared-CPU pair attempts** (36 measured server instances) remain preserved as selection evidence. They are excluded from the holdout statistics. The shared diagnostics put two servers on one guest CPU and swapped sides; their ratios describe that diagnostic setup.

| Sequential batch | Attempts | HTTP errors | Socket errors | Rust RPS range | Retained Goose RPS range |
| --- | --- | --- | --- | --- | --- |
| [cache-grid](<cache-grid/measurements.json>) | 16 | 0 | 26 | 53,646.90–101,907.17 | 89,193.87–109,633.78 |
| [isolated-screen](<isolated-screen/measurements.json>) | 16 | 0 | 0 | 48,966.84–62,544.82 | 32,874.33–79,432.28 |

Sequential controls varied substantially on the occupied Mac. The unchanged host state and scheduling noise limit interpretation of those discovery rates. A/A checks and the complete comparison matrix are retained below; their exploratory results cannot establish the predeclared 5% target.

| Shared batch | Requested first / second | Both ratios | Median ratio | Valid / attempted | A/A gate | Raw pairs |
| --- | --- | --- | --- | --- | --- | --- |
| first | Retained Goose A/A / Retained Goose A/A | 0.99470×, 0.99521× | 0.99495× (-0.50%) | 2/2 | PASS | [pair01-repeat01](<paired-diagnostic-first/pair01-repeat01.json>), [pair01-repeat02](<paired-diagnostic-first/pair01-repeat02.json>) |
| first | Combined cache/header/application PGO / Rust PR 82 | 1.03942×, 1.03635× | 1.03788× (+3.79%) | 2/2 | PASS | [pair02-repeat01](<paired-diagnostic-first/pair02-repeat01.json>), [pair02-repeat02](<paired-diagnostic-first/pair02-repeat02.json>) |
| first | Combined + application-query SQLite PGO / Rust PR 82 | 1.02504×, 1.01574× | 1.02039× (+2.04%) | 2/2 | PASS | [pair03-repeat01](<paired-diagnostic-first/pair03-repeat01.json>), [pair03-repeat02](<paired-diagnostic-first/pair03-repeat02.json>) |
| second | Retained Goose A/A / Retained Goose A/A | 0.97782×, 1.00383× | 0.99083× (-0.92%) | 2/2 | PASS | [pair01-repeat01](<paired-diagnostic-second/pair01-repeat01.json>), [pair01-repeat02](<paired-diagnostic-second/pair01-repeat02.json>) |
| second | Selected combined + bounded likes / Rust PR 82 | 1.07162×, 1.05386× | 1.06274× (+6.27%) | 2/2 | PASS | [pair02-repeat01](<paired-diagnostic-second/pair02-repeat01.json>), [pair02-repeat02](<paired-diagnostic-second/pair02-repeat02.json>) |
| second | Unified five-unit PGO/LTO / Rust PR 82 | 1.04054×, 1.06092× | 1.05073× (+5.07%) | 2/2 | PASS | [pair03-repeat01](<paired-diagnostic-second/pair03-repeat01.json>), [pair03-repeat02](<paired-diagnostic-second/pair03-repeat02.json>) |
| final-selection | Retained Goose A/A / Retained Goose A/A | 1.00152×, 0.99117× | 0.99634× (-0.37%) | 2/2 | PASS | [pair01-repeat01](<paired-diagnostic-final-selection/pair01-repeat01.json>), [pair01-repeat02](<paired-diagnostic-final-selection/pair01-repeat02.json>) |
| final-selection | Unified PGO/LTO + bounded likes / Rust PR 82 | 1.02237×, 1.04182× | 1.03209× (+3.21%) | 2/2 | PASS | [pair02-repeat01](<paired-diagnostic-final-selection/pair02-repeat01.json>), [pair02-repeat02](<paired-diagnostic-final-selection/pair02-repeat02.json>) |
| final-selection | Unified + bounded likes + trainer v2 / Rust PR 82 | 1.05167×, 1.04282× | 1.04724× (+4.72%) | 2/2 | PASS | [pair03-repeat01](<paired-diagnostic-final-selection/pair03-repeat01.json>), [pair03-repeat02](<paired-diagnostic-final-selection/pair03-repeat02.json>) |

Only the combined candidate with legacy SQLite PGO, four-unit application PGO, transport/header changes, 8 MiB cache/mmap disabled and the bounded likes query was selected. Five-unit SQLite-inclusive LTO, application-query SQLite training and trainer-v2 variants were not selected and are not shipped. Their sources, builds and measurements remain in [candidates/](<candidates>).

## Measurement scope and build reproduction

The host is Apple M2 Pro. Servers run native Linux ARM64 containers on guest CPU 0 with one CPU quota and 2 GiB memory; the unchanged mixed load runs on CPUs 1–2 with two threads and 64 connections. Confirmation uses two-second warmups and 45-second measurements. The Mac stayed as-is, including unrelated host activity. These are comparisons of complete Goose+C/SQLite/OpenSSL and Rust/SQLite implementations, not an isolated language-speed result or an official x86-64 k6 capacity claim.

All confirmation implementations use the same declared corrected Ubuntu wrk 4.1.0 driver: image `sha256:a5e8736dcfaf72bf79c0196a89fe3fd49774916ab7ea4ce06a8a2cdfd3a4b504`, executable `/opt/wrk-clock/bin/wrk`, SHA-256 `20ec627b07490f94b7d1ed73e16ed64e04d993457ceacf4cb92fd66f93f7cb39`. The minimal patch moves wrk elapsed timestamps to CLOCK_MONOTONIC; the deterministic proof preserves real over-two-second timeout accounting. Event-loop scheduling remains on wall time. The correction does not prove that every historical timeout came from a clock step, and it cannot remove host scheduling noise. See the [declaration](<PROTOCOL-monotonic.md>) and [runtime and clock proof](<wrk-monotonic/runtime-proof.json>).

A full normal build of the exact selected 19-file source succeeded with fresh legacy SQLite and application feedback. Source bytes and generated C match. The rebuild is not bit-identical: selected binary `309f1138b9c5d6b404670a8c0eaf1d42c2f96d4fc7e30d7a89f5bff326a5af2e`, reproduced binary `c4aa7c89126bd854d14d2c3d0fccef9ef8b2523d3d17d683193480abe77f226b`; size difference -24 bytes. Fresh execution counters differ beyond the compilation stamp. The reproduction is retained **unmeasured** and never replaces the frozen holdout binary. See [source reproduction comparison](<candidates/selected-reproduction/comparison.json>).

Raw records, every exclusion and error, all exploratory sources/builds and prior reports remain preserved. Only this selected holdout determines the target outcome.
