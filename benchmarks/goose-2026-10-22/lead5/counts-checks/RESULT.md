# Live-count aggregation: rejected

The grouped likes query is **rejected**. Across the two predeclared sequential 15-second triplets, its geometric mean was **-4.55% versus the immediately preceding HMAC-only Goose**, and **+0.44% versus pinned Rust**. It misses both selection margins. No confirmation batch was started, and this source was never installed.

| Trial | Candidate req/s | Previous Goose req/s | Rust req/s | New / previous | New / Rust |
| --- | --- | --- | --- | --- | --- |
| 1 | 114,630.11 | 116,289.17 | 111,617.90 | -1.43% | +2.70% |
| 2 | 110,878.48 | 119,967.16 | 112,871.95 | -7.58% | -1.77% |

All six attempts are retained and valid, with zero measured HTTP/socket errors. The official 42 checks, semantic/database checks, 18 parser checks, 25 edge checks and nine range-boundary checks passed. The unchanged HMAC implementation retains its earlier differential/fault/sanitizer proofs.

The candidate was built normally as UID 1001 with fresh SQLite/application PGO, one CPU quota, 2 GiB RAM and no swap. Build peak: 395.92 MiB. Every API and measured server used the same CPU/RAM/no-swap limits; one server ran at a time. The external load generator was separate from its budget.

SQLite 3.53.4 confirms the existing covering index and no temporary sort. The initial plan probe against the read-only seed failed; a writable temporary copy allowed the plan check. Both attempts remain archived.

[Raw attempts](measurements.json), [selection summary](selection-summary.json), [verification](verification.json), [declaration](../PROTOCOL-counts-query.md), [build proof](../candidates/counts-query/resource-budget-build.json), [source/image proof](../candidates/counts-query/image-proof.json), [query plan](../candidates/counts-query/plan.txt).

The two earlier complete stability confirmations remain unchanged and both remain UNMET. The installed source is still the verified HMAC-only source 9a298580; this rejected grouped-count source is 2048a840. These six selection attempts are not pooled with confirmation.
