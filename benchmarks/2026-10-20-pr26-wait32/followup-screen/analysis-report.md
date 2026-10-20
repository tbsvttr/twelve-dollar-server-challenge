# PR26 tuning — followup

3 expected rounds per case; complete=True; evidence valid=True; all counters clean=True.

Same native ARM64, one server CPU/2 GiB, separate two-CPU load, wrk 2 threads/64 connections, fresh process/database, 2s warmup then 15s per trial.

Descriptive tuning experiment, not statistical significance or an automatic #1 claim. Screening and confirmation are never pooled.

| Case | Status | Clean / expected | Successful req/s median [range] | p95 ms | p99 ms | RSS MiB | CPU % | CPU µs/request | HTTP | Socket C/R/W/T |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|
| 26-original | clean | 3/3 | 65,302 [63,830–66,012] | 6.986 | 11.930 | 53.72 | 49.4 | 7.666 | 0 | 0/0/0/0 |
| 82-leader | clean | 3/3 | 106,330 [99,607–106,917] | 13.451 | 23.320 | 48.16 | 88.7 | 8.420 | 0 | 0/0/0/0 |
| 26-b32-w4000 | clean | 3/3 | 96,029 [93,924–100,498] | 9.821 | 13.560 | 55.36 | 75.5 | 7.920 | 0 | 0/0/0/0 |
| 26-b16-w4000 | clean | 3/3 | 98,659 [97,048–101,520] | 9.926 | 13.000 | 58.96 | 76.3 | 7.807 | 0 | 0/0/0/0 |
| 26-b8-w4000 | clean | 3/3 | 98,765 [86,952–99,381] | 10.743 | 13.720 | 59.00 | 75.8 | 7.946 | 0 | 0/0/0/0 |

CPU microseconds per completed request = 1e6 * sampled self+waited-child CPU delta / wrk completed requests; medians of per-trial values.

wrk timeout counters count completed samples outside its two-second histogram range. They remain in throughput and are omitted from latency percentiles; HTTP/timeout counters can overlap.

**Screen selection:** Selection is performed only on the original six-case screening stage.

| Candidate / control | Clean pairs | Wins | Median paired ratio | Per-round ratios |
|---|---:|---:|---:|---|
| 26-original / 82-leader | 3/3 | 0 | 0.621 | 1:0.621, 2:0.611, 3:0.641 |
| 82-leader / 26-original | 3/3 | 3 | 1.611 | 1:1.611, 2:1.637, 3:1.561 |
| 26-b32-w4000 / 26-original | 3/3 | 3 | 1.504 | 1:1.522, 2:1.438, 3:1.504 |
| 26-b32-w4000 / 82-leader | 3/3 | 0 | 0.945 | 1:0.945, 2:0.878, 3:0.964 |
| 26-b16-w4000 / 26-original | 3/3 | 3 | 1.520 | 1:1.495, 2:1.555, 3:1.520 |
| 26-b16-w4000 / 82-leader | 3/3 | 0 | 0.950 | 1:0.928, 2:0.950, 3:0.974 |
| 26-b8-w4000 / 26-original | 3/3 | 3 | 1.496 | 1:1.496, 2:1.332, 3:1.557 |
| 26-b8-w4000 / 82-leader | 3/3 | 0 | 0.929 | 1:0.929, 2:0.813, 3:0.998 |

An asterisk marks an invalid/unclean pair. Ratios and wins use valid retained throughput even when counters are present; those comparisons are diagnostic. A paired median requires every expected pair to be valid. Counter-flagged leader runs are never called clean.

**Failures and incomplete evidence**

None.

Latest attempts: 15; raw measurement attempts: 15; superseded failed/error attempts retained in JSON: 0.

Original evidence files are never edited. `analysis-summary.json`, `analysis-cases.csv`, and `analysis-trials.csv` retain identities, validation details and trial data.
