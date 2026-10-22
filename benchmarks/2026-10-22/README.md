# Current implementation comparison — October 22, 2026

[One table](report.md) · [CSV](comparison.csv) · [HTML](comparison.html) · [Visible rows](visible-rows.json) · [All 129 records](comparison-rows.json)

**118 implementations, each appearing once.** Current source revisions and latest complete stock-protocol batches determine this view. Rust #82 replaces its older #19 revision and uses the fresh recheck measured alongside Goose. The inherited unchanged c-iouring folder in #121 is represented by its original #112 submission; #121 c-libco remains separate. Older revisions and repeated controls/confirmations stay in the [archive](https://github.com/tbsvttr/twelve-dollar-server-challenge/blob/a1c066b40856f021072747b26efda566039e00a6/benchmarks/2026-10-22/report.md). No source, measurement, counter or condition label changed.

**Local conditions:** **✓ PASS** requires SQLite with committed data, 42/42 API and dynamic/database checks, three stock-wrk 15s runs with 2s warmups and zero measured HTTP/socket errors, and one server CPU / 2 GiB / no swap. **✗ FAIL** names an observed failure; **? UNVERIFIED** means insufficient applicable evidence; **↔ OTHER PROTOCOL** identifies a corrected-driver 10×45s reference. Throughput order does not qualify a failed or different-protocol row.

**Original challenge conditions are not reproduced here:** these are ARM64 Docker/wrk runs with CPU affinity, rather than the official x86-64 droplet/k6 runs without affinity. PASS confirms the documented local runtime checks only; full challenge-rule compliance and the source-build resource budget are not uniformly verified.

[Current-view audit](current-only-audit.json) · [Recheck evidence audit](recheck-audit.json). Historical summary.json/current-outcomes.csv and earlier audits describe their original snapshots. The stable ≥5% target remains unmet.
