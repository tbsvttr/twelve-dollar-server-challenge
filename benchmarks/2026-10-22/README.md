# Fixed-submission benchmark follow-up — 2026-10-22

[Full combined report](report.md) · [CSV](comparison.csv) · [Filterable HTML (download and open locally)](comparison.html) · [Before/after CSV](before-after.csv) · [Raw trials](trials.csv) · [Original fixed-target audit](audit-final.json) · [Goose addition audit](independent-audit.json)

**Goose main-list addition.** PR #143 is included as current outcome 120, from a separate three-trial stock-wrk 15-second batch, with 117,565.71 median successful req/s and status `measured_with_errors`. Every one of the previous 119 outcomes keeps all measurements and source identities; only displayed ranks are recomputed. The two prior measured revisions remain in the before/after table. [New batch evidence](../goose-2026-10-22/ranking-3x15-2026-10-22/measurements.json). The unchanged new #82 control measured 106,162.00 req/s with 34 reported wrk timeouts; its original main-list score remains unchanged. Goose recorded 0 HTTP errors and 38 socket-error counters (38 timeouts); any nonzero counter excludes it from clean ranking. The separate monotonic-driver 10×45-second holdout is not used for this main-list row.

Retested eight implementations from PRs #32, #92, #103, #123 (three servers), #127, and #132. **Seven passed all 42 official API checks, dynamic checks, database integrity/committed-write checks, and three error-free throughput trials.** #127 still exits at startup because its package start command overrides `SQLITE_PATH` with `./feed.db`; [diagnostic evidence](diagnostics-pr127.json) retains the exact failure. #132 replaces the closed #120.

The combined report contains **120 outcomes: 98 clean ranked, 8 diagnostic/reference, and 14 without a valid three-trial result.** It retains 111 unchanged October 20 measurements with their original date labels. It is a targeted update, not an all-submission rerun.

The unchanged previous leader (#82) measured 105,569.55 req/s versus 108,275.04 previously (-2.50%); its original ranking measurement is retained. No result was rescaled.

Conditions match the previous local native Linux ARM64 comparison: one server CPU, 2 GiB RAM, `wrk -t2 -c64`, three 15-second runs with a two-second warm-up and fresh process/database per trial. This measures saturation throughput; it does not determine the official x86-64 k6 maximum-user capacity. Full conditions, latency/RAM/error metrics, exact revisions, setup substitutions and evidence limits appear in the report.

The publication includes current target source trees, source hashes/inventories, setup/build/controller/analyzer/audit helpers, raw verification/measurement JSON, and complete logs. Large seed fixtures, downloaded archives and duplicated control source are omitted; the report documents rebuilding prerequisites and fixture-hash validation. Local Docker tags identify cached images; no container images are distributed. The prior batch remains available at [../2026-10-20/](../2026-10-20/).
