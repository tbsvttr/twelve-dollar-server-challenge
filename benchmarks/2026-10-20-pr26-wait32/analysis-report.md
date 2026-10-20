# PR26 tuning — screening

3 expected rounds per case; complete=True; evidence valid=True; all counters clean=False.

Same native ARM64, one server CPU/2 GiB, separate two-CPU load, wrk 2 threads/64 connections, fresh process/database, 2s warmup then 15s per trial.

Descriptive tuning experiment, not statistical significance or an automatic #1 claim. Screening and confirmation are never pooled.

| Case | Status | Clean / expected | Successful req/s median [range] | p95 ms | p99 ms | RSS MiB | CPU % | CPU µs/request | HTTP | Socket C/R/W/T |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|
| 26-original | clean | 3/3 | 65,869 [65,825–66,529] | 7.380 | 12.340 | 55.46 | 49.1 | 7.506 | 0 | 0/0/0/0 |
| 82-leader | measured_with_errors | 2/3 | 103,501 [97,109–109,212] | 12.086 | 22.760 | 47.67 | 88.2 | 8.595 | 0 | 0/0/0/2 |
| 26-b128-w4000 | clean | 3/3 | 65,648 [65,366–66,344] | 7.101 | 11.940 | 55.48 | 49.5 | 7.583 | 0 | 0/0/0/0 |
| 26-b32-w4000 | clean | 3/3 | 97,713 [92,971–102,778] | 10.062 | 13.050 | 58.89 | 76.1 | 7.847 | 0 | 0/0/0/0 |
| 26-b128-w250 | clean | 3/3 | 65,977 [63,917–67,224] | 8.468 | 13.230 | 55.74 | 51.9 | 7.884 | 0 | 0/0/0/0 |
| 26-b32-w250 | clean | 3/3 | 96,734 [95,501–96,852] | 10.823 | 16.000 | 58.88 | 74.6 | 7.816 | 0 | 0/0/0/0 |

CPU microseconds per completed request = 1e6 * sampled self+waited-child CPU delta / wrk completed requests; medians of per-trial values.

wrk timeout counters count completed samples outside its two-second histogram range. They remain in throughput and are omitted from latency percentiles; HTTP/timeout counters can overlap.

**Screen selection:** Highest clean tuned-cell median; >=5% above both original and rebuilt controls.

Selected `26-b32-w4000`: 1.483× original; 1.488× rebuilt. Promising=True. The 5% trigger is a practical decision rule, not a significance test.

| Candidate / control | Clean pairs | Wins | Median paired ratio | Per-round ratios |
|---|---:|---:|---:|---|
| 26-original / 82-leader | 2/3 | 0 | 0.636 | 1:0.603, 2:0.685, 3:0.636* |
| 82-leader / 26-original | 2/3 | 3 | 1.572 | 1:1.658, 2:1.460, 3:1.572* |
| 26-b128-w4000 / 26-original | 3/3 | 1 | 0.997 | 1:1.007, 2:0.983, 3:0.997 |
| 26-b128-w4000 / 82-leader | 2/3 | 0 | 0.634 | 1:0.607, 2:0.673, 3:0.634* |
| 26-b32-w4000 / 26-original | 3/3 | 3 | 1.483 | 1:1.483, 2:1.397, 3:1.561 |
| 26-b32-w4000 / 82-leader | 2/3 | 0 | 0.957 | 1:0.895, 2:0.957, 3:0.993* |
| 26-b128-w250 / 26-original | 3/3 | 2 | 1.002 | 1:1.021, 2:0.961, 3:1.002 |
| 26-b128-w250 / 82-leader | 2/3 | 0 | 0.637 | 1:0.616, 2:0.658, 3:0.637* |
| 26-b32-w250 / 26-original | 3/3 | 3 | 1.454 | 1:1.450, 2:1.454, 3:1.471 |
| 26-b32-w250 / 82-leader | 2/3 | 0 | 0.936 | 1:0.874, 2:0.996, 3:0.936* |

An asterisk marks an invalid/unclean pair. Ratios and wins use valid retained throughput even when counters are present; those comparisons are diagnostic. A paired median requires every expected pair to be valid. Counter-flagged leader runs are never called clean.

**Failures and incomplete evidence**

- 82-leader round 3: HTTP=0, sockets={'connect': 0, 'read': 0, 'write': 0, 'timeout': 2}.

Latest attempts: 18; raw measurement attempts: 18; superseded failed/error attempts retained in JSON: 0.

Original evidence files are never edited. `analysis-summary.json`, `analysis-cases.csv`, and `analysis-trials.csv` retain identities, validation details and trial data.
