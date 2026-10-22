# Goose local comparison — October 22, 2026

This archive adds a Goose submission and a separately identified local measurement batch. It preserves the existing [119-outcome comparison](../2026-10-22/README.md) and its files unchanged. The new batch does not replace an earlier Rust or Goose result, receive a cross-batch rank, or establish official x86-64 k6 capacity.

[Submission PR #143](https://github.com/arjaythedev/twelve-dollar-server-challenge/pull/143) · [New submission row (CSV)](goose-addition.csv) · [Matched controls (CSV)](matched-controls.csv) · [Structured addition](goose-addition.json) · [Benchmark details](benchmark-results.json) · [Validation details](validation-results.json)

The current measured source is `9a298580809e2a6821c7a8068b6a45315ae7aaa4b58bb79edc3f94606b9f861b`. [The exact measured 19-file source](lead5/holdout-hmac/sources/prgoose) and [per-file hashes](lead5/holdout-hmac/archives/prgoose-sha256.json) are retained. The submission PR updates its README and adds two result JSON files; executable source and build scripts are unchanged from this snapshot.

| Current batch: ten trials per case | Median successful req/s | Median p99 ms | Median RSS MiB |
| --- | ---: | ---: | ---: |
| Goose | 116,646.90 | 25.265 | 15.26 |
| Pinned Rust PR82 | 103,477.99 | 25.550 | 66.96 |
| Previous local Goose control | 106,539.68 | 25.680 | 58.19 |

The paired Goose/Rust geometric mean is **+13.72%**, with a one-sided 95% Student-t lower bound of **+1.85%**. Eight of ten pairs exceed 5%. The predeclared stable ≥5% target remains **UNMET**. All 30 attempts, including the slower Goose round, are retained without exclusions; measured and warmup HTTP/socket errors are zero.

- [Current complete report](lead5/holdout-hmac/RESULT.md), [all raw measurements](lead5/holdout-hmac/measurements.json), [summary](lead5/holdout-hmac/holdout-summary.json), [independent audit](lead5/holdout-hmac/independent-audit.json), [identity audit](lead5/holdout-hmac/independent-identity-audit.json), [statistics audit](lead5/holdout-hmac/independent-statistics-audit.json).
- [Earlier completed confirmation](lead5/holdout-selected/RESULT.md), [all 30 earlier measurements](lead5/holdout-selected/measurements.json), [earlier independent audit](lead5/holdout-selected/independent-audit.json). Its +10.73% point estimate and +4.13% lower bound also missed the target. It uses a different candidate and is not pooled with the new batch.
- [All experiment index](lead5/README.md), [rejected final counts experiment](lead5/counts-checks/RESULT.md), [selection declaration](lead5/PROTOCOL-hmac-only.md), [resource declaration](lead5/PROTOCOL-resource-budget.md), [clock correction declaration](lead5/PROTOCOL-monotonic.md).

The current batch ran native Linux ARM64 in Docker Desktop on an Apple M2 Pro. Unrelated host activity remained running. Each server had a one-CPU quota, CPU set 0, 2 GiB RAM and no container swap. Only one server ran at a time. The external load generator used guest CPUs 1–2, two wrk threads and 64 connections. Each measurement lasted 45 seconds after a two-second warmup, using a fresh server process and seed database copy. Cases ran in randomized matched sequential triplets. Host scheduling remains a source of variation.

Every case used the same declared wrk 4.1.0 [minimal monotonic timeout-clock patch](lead5/wrk-monotonic/monotonic-clock-only.patch), with [runtime proof](lead5/wrk-monotonic/runtime-proof.json). Only the `time_us()` timeout timer is changed to `CLOCK_MONOTONIC`, preventing backward-wall-clock unsigned underflow; real timeouts still count, and event-loop scheduling still uses wall time. This protocol is different from the earlier 3×15-second overview, so the new measurements remain a separate batch.

Correctness passed 42 official assertions, six live semantic checks and 52 supplemental API checks. [Full validation](lead5/hmac-budget-checks/verification.json), [parser](lead5/hmac-budget-checks/parser-checks.json), [edge cases](lead5/hmac-budget-checks/edge-checks.json), and [likes above the maximum](lead5/hmac-budget-checks/above-max-checks.json) are retained. The HMAC adapter passed [139 differential and injected-failure checks](lead5/candidates/feed-hmac/hmac-tests/results.json) and [sanitizer checks](lead5/candidates/feed-hmac/hmac-tests/proof.json).

The [clean application/SQLite PGO build receipt](lead5/candidates/hmac-budget/resource-budget-build.json) records UID 1001, 44.276 seconds and 412,934,144 bytes (393.80 MiB) peak cgroup memory under one CPU / 2 GiB / no swap. The compiler was already installed. Full compiler bootstrap within 2 GiB and native x86-64 execution remain unverified by these local records. Earlier discovery and compiler bootstrap used larger build/test resource allowances; those records remain historical evidence and are not current-budget proofs.

[The source-count audit](code-count-audit.json) records 559 Goose plus 1,670 native helper physical lines (2,229 runtime lines) and 470 authored setup/training lines, totaling 2,699 authored lines. It excludes the credited 55-line borrowed SQLite trainer and corrects the old recorded 2,493 total without modifying its original manifest. Counts include comments/blanks; dependency source size and weighted scores remain unassigned.

This is a text evidence archive of the retained `lead5` experiment tree, plus relevant harness scripts and code-count audits. Downloaded dependencies, generated build directories, binaries, profiles, compressed archives and seed database/token copies are omitted. Their recorded hashes remain in original receipts. The repository's seed generator and schema provide the challenge fixtures. This archive contains recorded evidence; image hashes do not imply that container image layers are published. [The file inventory](artifact-inventory.json) hashes every other included file. Original reports and logs are preserved as recorded, including references to local paths and omitted generated artifacts.
