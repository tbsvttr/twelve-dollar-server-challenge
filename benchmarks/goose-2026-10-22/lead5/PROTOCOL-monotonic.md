# Explicit load-clock correction for the remaining experiments

Declared before the first monotonic-driver throughput sample. The sixteen
stock-driver cache-grid attempts remain unchanged and are discovery evidence.
All remaining discovery cases and every confirmation implementation use the
same corrected driver. All selection and confirmation thresholds in
`PROTOCOL.md`, including the 45-second duration and 5% confidence-bound target,
remain unchanged.

The original driver is Ubuntu wrk 4.1.0-4build2, `/usr/bin/wrk`, SHA256
`55157ab26d15f39e68d80ed3e16240dcdcb1722abf0fa7d74bfd3e20dd50254c`.
Its unsigned latency helper reads `gettimeofday`. A backward clock step can
wrap an otherwise completed response's latency above the histogram limit and
increment the timeout counter. The actual source helpers and histogram code
reproduce this deterministically. The VM monitor has observed backward wall
steps. The pinned Rust submission independently documents the same earlier
problem in its `bench/README.md` and supplies a monotonic-clock driver recipe.

The new driver retains the exact Ubuntu 4.1.0 source package and its packaging
patches. The only additional source change is an include and replacement of
`wrk.c:time_us()` with `clock_gettime(CLOCK_MONOTONIC)`. Request scripts, counters,
timeouts, histogram bounds and event-loop behavior remain unchanged. Matched
rebuilt stock and corrected binaries use identical compiler flags and libraries.
The deterministic test also verifies that a genuine response over two seconds
still increments the original timeout counter for both binaries.

Selected load image: `twelve-load-wrk-monotonic:2026-10-22`,
`sha256:a5e8736dcfaf72bf79c0196a89fe3fd49774916ab7ea4ce06a8a2cdfd3a4b504`.
Selected executable: `/opt/wrk-clock/bin/wrk`, SHA256
`20ec627b07490f94b7d1ed73e16ed64e04d993457ceacf4cb92fd66f93f7cb39`.
The source archives, patch, build recipe, matched binaries' hashes and test
evidence are retained in `wrk-monotonic/`.

This corrects a demonstrated driver defect. It does not establish that every
historical timeout was caused by clock steps: the CPU 5 monitor recorded no
step exceeding 1 ms during the latest 26-timeout sample. Preserve that limitation
and all original error counts. The corrected driver also cannot remove host
scheduling noise; unchanged controls remain necessary.
