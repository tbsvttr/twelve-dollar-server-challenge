# Goose server: HMAC-only follow-up

**Predeclared stable ≥5% target: UNMET.** Paired Goose/Rust geometric mean: **1.13725× (+13.72%)**; one-sided 95% lower bound: **1.01854× (+1.85%)**; pairs above 5%: **8/10**.

The runtime change reuses keyed HMAC state while preserving the original feed, fresh signature checks and commit-before-response behavior.

The measured binary comes from a clean normal-user source build with fresh SQLite/application PGO under one CPU, 2 GiB and no swap. Only one server instance runs at a time; the load generator is external to its budget. [Resource/build proof](<candidates/hmac-budget/resource-budget-build.json>).

[Latest complete report: every round, error and frozen identity](<holdout-hmac/RESULT.md>); [raw attempts](<holdout-hmac/measurements.json>); [independent audit](<holdout-hmac/independent-audit.json>).

The first independent ten-round holdout **failed** the stable 5% target: 1.10729× (+10.73%) paired geometric mean, 1.04132× (+4.13%) lower bound and 7/10 pairs above 5%. Its [report](<holdout-selected/RESULT.md>), [raw measurements](<holdout-selected/measurements.json>) and [audit](<holdout-selected/independent-audit.json>) remain preserved. Those measurements are not pooled with this new holdout.

All earlier discovery results remain in [the first holdout index](<README-first-holdout.md>) and [earlier experiment reports](<..>). Rejected SQL-inclusive LTO and trainer-v2 candidates remain unshipped.

Scope: local Apple M2 Pro, native Linux ARM64 Docker, unchanged occupied host and the common declared monotonic wrk driver. These results compare complete implementations and do not establish official x86-64 k6 capacity.

## Later SQL aggregation check: rejected

The three-line grouped-count variant passed correctness but regressed in both direct comparisons: **−4.55%** geometrically versus HMAC-only Goose. It was not installed and received no new confirmation. [All six attempts and decision](counts-checks/RESULT.md) remain preserved; the completed confirmation outcome above is unchanged.
