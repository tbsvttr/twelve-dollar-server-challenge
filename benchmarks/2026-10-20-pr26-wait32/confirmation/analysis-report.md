# PR26 tuning — confirmation

6 expected rounds per case; complete=True; evidence valid=True; all counters clean=True.

Same native ARM64, one server CPU/2 GiB, separate two-CPU load, wrk 2 threads/64 connections, fresh process/database, 2s warmup then 15s per trial.

Descriptive tuning experiment, not statistical significance or an automatic #1 claim. Screening and confirmation are never pooled.

| Case | Status | Clean / expected | Successful req/s median [range] | p95 ms | p99 ms | RSS MiB | CPU % | CPU µs/request | HTTP | Socket C/R/W/T |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|
| 26-b32-w4000 | clean | 6/6 | 91,103 [85,288–99,520] | 10.102 | 13.765 | 41.86 | 74.1 | 8.219 | 0 | 0/0/0/0 |
| 26-original | clean | 6/6 | 63,850 [58,670–65,556] | 6.870 | 12.020 | 39.29 | 48.7 | 7.683 | 0 | 0/0/0/0 |
| 82-leader | clean | 6/6 | 101,552 [80,193–104,995] | 12.863 | 23.560 | 47.60 | 87.2 | 8.680 | 0 | 0/0/0/0 |

CPU microseconds per completed request = 1e6 * sampled self+waited-child CPU delta / wrk completed requests; medians of per-trial values.

wrk timeout counters count completed samples outside its two-second histogram range. They remain in throughput and are omitted from latency percentiles; HTTP/timeout counters can overlap.

**Screen selection:** Selection is performed only on the original six-case screening stage.

| Candidate / control | Clean pairs | Wins | Median paired ratio | Per-round ratios |
|---|---:|---:|---:|---|
| 26-b32-w4000 / 26-original | 6/6 | 6 | 1.466 | 1:1.553, 2:1.490, 3:1.443, 4:1.340, 5:1.304, 6:1.582 |
| 26-b32-w4000 / 82-leader | 6/6 | 1 | 0.930 | 1:0.948, 2:0.940, 3:1.115, 4:0.919, 5:0.833, 6:0.893 |
| 26-original / 82-leader | 6/6 | 0 | 0.635 | 1:0.610, 2:0.631, 3:0.772, 4:0.686, 5:0.639, 6:0.564 |
| 82-leader / 26-original | 6/6 | 6 | 1.575 | 1:1.638, 2:1.584, 3:1.295, 4:1.458, 5:1.565, 6:1.772 |

An asterisk marks an invalid/unclean pair. Ratios and wins use valid retained throughput even when counters are present; those comparisons are diagnostic. A paired median requires every expected pair to be valid. Counter-flagged leader runs are never called clean.

**Failures and incomplete evidence**

None.

Latest attempts: 18; raw measurement attempts: 18; superseded failed/error attempts retained in JSON: 0.

Original evidence files are never edited. `analysis-summary.json`, `analysis-cases.csv`, and `analysis-trials.csv` retain identities, validation details and trial data.
