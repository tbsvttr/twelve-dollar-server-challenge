# Server comparison — October 22, 2026

[One combined table](report.md) · [Filterable HTML](comparison.html) · [CSV](comparison.csv) · [Exact row JSON](comparison-rows.json) · [Unified-table audit](unified-audit.json)

The same **127 rows** appear in Markdown, HTML, CSV and row JSON, sorted by successful req/s: 120 current outcomes plus two previous measured revisions, two short-run Rust controls and three longer confirmation measurements. Every earlier value and source identity is preserved. `summary.json` retains the 120-current-outcome inventory; `current-outcomes.csv` retains its current-only export.

Columns identify each row's role, status, batch and protocol. Stock-wrk 3×15-second trials and monotonic-wrk 10×45-second confirmation stay distinct in the shared table. All measurements are placed by their recorded throughput, with errors, references, historical revisions and unmeasured outcomes visible in the same view. Original ranking metadata remains in the retained source records and exports.

**Local conditions** are checked explicitly per row: PASS, FAIL with its reason, UNVERIFIED, or DIFFERENT_PROTOCOL. PASS means the recorded SQLite/API/live-data/database/resource and zero-error stock-wrk 3×15s checks; it does not establish official challenge compliance. The HTML can filter by this field.

**Official conditions were not reproduced:** the local runs use ARM64 Docker/wrk with CPU affinity, rather than the official x86-64 droplet/k6 without affinity. Full source-rule compliance and the clean source-build resource budget are not uniformly verified.

All measured servers use one CPU and 2 GiB RAM with no container swap. This presentation update runs no new benchmarks and changes no source code, measurement or ranking rule. Local ARM64 throughput does not determine official x86-64 k6 maximum-user capacity. The stable ≥5% Goose/Rust confirmation target remains unmet.

[Original fixed-target audit](audit-final.json) and [previous 120-outcome integration audit](independent-audit.json) remain historical evidence. The unified-table audit checks this presentation against the same retained records. [Before/after history](before-after.csv), [original raw fixed-target trials](trials.csv) and [the October 20 report](../2026-10-20/report.md) remain available unchanged.
