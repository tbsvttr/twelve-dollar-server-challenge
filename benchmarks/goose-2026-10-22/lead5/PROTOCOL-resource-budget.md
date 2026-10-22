# Resource-budget correction before HMAC-only performance measurement

The user asked that all work stay within the original challenge situation:
one vCPU, 2 GB RAM and no swap. Previous confirmation server containers already
had one-CPU quota, 2 GiB memory and no swap; all 30 actual configurations remain
in `holdout-selected/measurements.json`. Extra CPUs were used for compilation,
functional checks and the external load generator. That distinction was not
clear enough. Earlier local ARM64 results are preserved without relabeling them
as official Ubuntu x86-64/k6 scores.

All further server builds and functional checks use one CPU, 2 GiB memory and
no swap. The HMAC-only source has received a clean normal-user build with fresh
SQLite and application PGO, without object reuse. It succeeded in 44.276 s,
using 412,934,144 peak cgroup bytes. Its evidence is retained in
`candidates/hmac-budget/resource-budget-build.json`. An earlier build failed on
stale root-owned generated artifacts; that failure remains archived separately.

Only one server instance runs at a time from this point. The clock monitor is
stopped. The load generator remains outside the server budget, as official k6
runs on a separate machine. On this Mac both still share the Docker host; this
does not recreate a separate physical host or the official x86-64 platform.

For selection only, replace the previously proposed shared-CPU A/A diagnostic
with exactly two sequential matched triplets of 15-second runs: new Goose,
unchanged Rust, and the previous selected Goose. Each server has the same
one-CPU/2-GiB/no-swap limits, a fresh database, and the same common driver and
workload. Keep every run. Require all six attempts to be valid/error-free, a
paired geometric mean Goose/Rust ratio of at least 1.05, and a paired geometric
mean over the previous Goose greater than 1.0 before selecting the candidate.
Low throughput is never a reason to repeat or exclude a run.

This resource correction and changed selection format are recorded before the
normal-build HMAC-only binary's first performance measurement. The new source
remains the HMAC-only change described in `PROTOCOL-hmac-only.md`; the fused
feed stays rejected. No earlier performance data is pooled into this selection.

If selected, the fresh 45-second, ten-clean-triplet confirmation uses exactly
the unchanged acceptance gates in `PROTOCOL.md`, the unchanged Rust and retained
Goose controls, and the common driver in `PROTOCOL-monotonic.md`. Selection
samples and the first failed holdout remain separate from confirmation.
