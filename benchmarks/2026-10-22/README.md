# Server comparison — October 22, 2026

[One combined table](report.md) · [Filterable HTML](comparison.html) · [CSV](comparison.csv) · [Exact row JSON](comparison-rows.json) · [Unified-table audit](unified-audit.json)

The same **127 rows** appear in Markdown, HTML, CSV and row JSON, sorted by successful req/s: 120 current outcomes plus two previous measured revisions, two short-run Rust controls and three longer confirmation measurements. Every earlier value, source identity and clean rank is preserved. `summary.json` retains the 120-current-outcome inventory; `current-outcomes.csv` retains its current-only export.

Columns identify each row's role, status, batch and protocol. Stock-wrk 3×15-second trials and monotonic-wrk 10×45-second confirmation stay distinct in the shared table. Only the existing 98 eligible current rows have a clean rank; errors, references, historical revisions and unmeasured outcomes remain visible alongside them.

All measured servers use one CPU and 2 GiB RAM with no container swap. This presentation update runs no new benchmarks and changes no source code, measurement or ranking rule. Local ARM64 throughput does not determine official x86-64 k6 maximum-user capacity. The stable ≥5% Goose/Rust confirmation target remains unmet.

[Original fixed-target audit](audit-final.json) and [previous 120-outcome integration audit](independent-audit.json) remain historical evidence. The unified-table audit checks this presentation against the same retained records. [Before/after history](before-after.csv), [original raw fixed-target trials](trials.csv) and [the October 20 report](../2026-10-20/report.md) remain available unchanged.
