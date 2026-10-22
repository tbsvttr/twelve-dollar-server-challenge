# Goose: at least 5% over the pinned Rust control

This is a new experiment. All earlier results, sources, images, failures and
audits remain historical evidence. The previous retained Goose image is
`sha256:a69064953b766ec5c800389b8e17a7d184f73aa8dd46cd4aa2048955ee86eb0f`.
Rust stays at PR 82 commit `95aa405a0003599dbc7fb4dfa47a09e8343239df`, image
`sha256:64227e803306084617be2a4ebc1c3623260d265f158dd8c009f647558a280135`.

## Discovery

Screen SQLite cache/mmap settings, full application PGO, response header/time
primitives and, if useful, a range-query adjustment. Freeze each candidate's
source and binary identity. Use the same native ARM64 machine, server CPU 0,
one CPU quota, 2 GiB memory, load CPUs 1 and 2, original mixed workload,
fresh 500,000-post seed, 2-second warmup and 15-second discovery samples.
Run correctness before throughput. Discovery is for selection; it cannot
establish the requested stable 5% lead.

## Confirmation, fixed before discovery measurements

Select and freeze one candidate before collecting confirmation data. Run ten
fresh matched rounds against unchanged Rust and retained Goose, each with a
2-second warmup and a 45-second measurement. Randomize order within each round
using the existing deterministic controller. No builds, training or other
CPU-heavy diagnostics run during throughput measurements.

Success requires all of:

- Official 42/42 checks, semantic checks, supplemental parsing/edge checks,
  and post-run database growth and integrity pass for the selected candidate.
- Zero HTTP or socket errors for the selected candidate in every attempted
  confirmation run; no crash, invalid duration or missing evidence.
- At least ten complete clean matched rounds, with a maximum of two replacement
  rounds. Any protocol-invalid round is excluded as a whole, and retained with
  its reason. Low throughput alone never justifies exclusion.
- Candidate/Rust geometric mean of paired throughput ratios is at least 1.05,
  and its one-sided 95% Student-t lower confidence bound on log ratios is at
  least 1.05. At least 9 of the first 10 clean paired rounds must individually
  exceed Rust by 5%.
- Candidate median p99 latency must be no more than 5% above Rust's, with every
  raw latency and error count reported. Memory must fit the 2 GiB limit.

If the target fails, report it honestly. Any further tuning starts a separately
named discovery and fresh confirmation batch; do not select favorable rounds
or silently change this protocol. A VM clock monitor supplies diagnostic
evidence only. Keep the load generator unchanged unless a proven defect
requires a separately declared experiment for every implementation.
