# Server comparison — October 22, 2026

[One comparison table](report.md) · [Filterable HTML](comparison.html) · [CSV](comparison.csv) · [Visible row JSON](visible-rows.json) · [All retained records](comparison-rows.json)

The main table contains **126 rows**, including **one current Goose result** from the complete new stock-wrk recheck: 120 current outcomes, two previous measured revisions, three separate short-run Rust controls and one longer Rust reference. CSV, HTML and visible-row JSON contain the same view. The canonical row JSON preserves every original record and appends the two recheck records (129 total). All previous Goose measurements and error counters remain available in the [previous complete table](https://github.com/tbsvttr/twelve-dollar-server-challenge/blob/bb2f2def4f6c2e2ef2eb1262f406a754b5757844/benchmarks/2026-10-22/report.md).

**Local conditions:** **✓ PASS** requires SQLite with committed data, 42/42 API and dynamic/database checks, three stock-wrk 15s runs with 2s warmups and zero measured HTTP/socket errors, and one server CPU / 2 GiB / no swap. **✗ FAIL** names an observed failure; **? UNVERIFIED** means insufficient applicable evidence; **↔ OTHER PROTOCOL** identifies a corrected-driver 10×45s reference. Throughput order does not qualify a failed or different-protocol row.

**Original challenge conditions are not reproduced here:** these are ARM64 Docker/wrk runs with CPU affinity, rather than the official x86-64 droplet/k6 runs without affinity. PASS confirms the documented local runtime checks only; full challenge-rule compliance and the source-build resource budget are not uniformly verified.

The recheck uses the unchanged three-by-15-second stock-wrk protocol with 2-second warmups and the same source/image, one server CPU, 2 GiB RAM and no swap. All six new trials (three per case) are retained. No prior run or error counter was changed. Full-precision statistics, source/image identities, local conditions and raw evidence links remain in the exports.

The stable ≥5% Goose/Rust confirmation target remains **unmet**. Local runtime qualification does not establish that statistical claim or official x86-64 k6 user capacity.

`summary.json` and `current-outcomes.csv` retain the previous 120-current-outcome inventory unchanged. Earlier audits describe their recorded historical snapshots. [Before/after history](before-after.csv), [original fixed-target trials](trials.csv) and [the October 20 report](../2026-10-20/report.md) remain unchanged.
