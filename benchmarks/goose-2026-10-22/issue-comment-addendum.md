**New Goose submission — separate October 22 local confirmation batch.**

[Goose PR](https://github.com/arjaythedev/twelve-dollar-server-challenge/pull/143) · [Full report, all trials and independent audit](https://github.com/tbsvttr/twelve-dollar-server-challenge/blob/91c6ba1384015ffd8f27910cbb16e98dbaf90f44/benchmarks/goose-2026-10-22/README.md)

The existing 119-outcome October 20/22 comparison and its historical rows remain unchanged. The additional submission below uses a different declared protocol: native Linux ARM64, one server CPU, 2 GiB RAM with no container swap, monotonic-clock wrk, two load threads/64 connections, ten 45-second trials after two-second warm-ups, and fresh process/database per trial. Matched controls are new reference measurements; they do not replace their earlier table rows.

| This batch only | Median req/s | Median p99 ms | Median RSS MiB | Measured / warmup HTTP+socket errors |
|---|---:|---:|---:|---|
| [Goose](https://github.com/arjaythedev/twelve-dollar-server-challenge/pull/143) | 116,646.90 | 25.265 | 15.26 | 0 / 0 |
| Rust PR82 matched control | 103,477.99 | 25.550 | 66.96 | 0 / 0 |
| Previous local Goose control | 106,539.68 | 25.680 | 58.19 | 0 / 0 |

Goose/Rust paired geometric mean: **+13.72%**; one-sided 95% lower bound: **+1.85%**; **8/10** rounds exceed 5%. The predeclared stable ≥5% target remains **UNMET**. All 30 attempts were clean; official API, semantic, database and supplemental checks passed.

This local saturation measurement establishes no official x86-64 k6 concurrent-user capacity. No cross-batch rank or weighted preference score is assigned.
