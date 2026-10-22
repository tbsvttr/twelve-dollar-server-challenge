# Checkpoint and transport experiments

This follow-up tests the ideas identified while reviewing PR #82 and submissions #32, #55, #91, #98, #68 and #90. Their architectures suggested experiments; their reported speeds are not measurements of this submission. The already accepted parser change is documented in [LUFP.md](LUFP.md). Serde remains a development-only differential-test dependency.

The selected server change increases the synchronous WAL checkpoint trigger from 1,000 to 4,096 frames. It keeps the same serialized SQLite connection and RESTART checkpoint mode. Less frequent checkpoints amortize their I/O over more writes. Every successful write still waits for its transaction to commit, with WAL and `synchronous=NORMAL`; moving pages from WAL into the main file is separate from committing the write.

The tradeoff is a larger WAL between checkpoints and longer individual checkpoint stalls. With the supplied 4 KiB pages, 4,096 WAL frames occupy approximately 16 MiB, versus approximately 4 MiB for 1,000 frames. These are trigger sizes, not hard limits: a commit can cross the threshold, and unsuccessful checkpoints are retried. The existing 64 MiB `journal_size_limit` is also not a hard WAL cap.

## Method

Measurements use Ubuntu 24.04.4 under WSL2, Linux 6.6.87.2, an Intel i9-13900H and Rust 1.94.0. The native Ubuntu host remained unreachable. The server has one logical CPU, 2 GiB memory, no swap and 65,535 descriptors. The generator uses separate logical CPUs on the same host. These are local comparisons, not measurements on the official DigitalOcean droplet or a maximum-user search. Test-harness CPU assignment is not part of the application; no host tuning is submitted.

Every trial starts from a fresh official seed. Monotonic-clock wrk drives live requests, including real writes, and checks HTTP status and response semantics. Execution order is balanced and workload order rotates. All candidate builds and correctness tests finish before their timings. Later confirmations reject known concurrent compiler/replay jobs and record host pressure and boot identity. Earlier noisy screens are retained and are not acceptance evidence.

Exploratory variants independently start from `932131523fe0a16d8ad99f1f1ca0cab48ec79376`, before LUFP. The final candidates are rebuilt over LUFP commit `bdf985e44e18645f5b40b511009fd2dec11ba033` at the same original manifest path, using the same fixed SQLite PGO archive. Rebuilding the unchanged LUFP control reproduces its binary SHA-256 exactly (`66f0e52f2bbf18eb851127ed23280c568e1f71e58cf614fa5fceda41d9bbe547`). This avoids attributing build-path or independently trained SQLite changes to the candidate.

## Final checkpoint confirmation

The selected 4,096-frame binary is compared against LUFP alone in six independent balanced pairs per workload, with 15-second measurements after 10-second warmups. The final confirmation is separate from the shorter candidate screens.

| Connections / workload | LUFP median req/s | 4,096-frame median req/s | Paired geometric mean change | Bootstrap 95% interval |
|---|---:|---:|---:|---:|
| 64 / feed | 74,917 | 75,362 | −0.26% | −2.16% to +1.56% |
| 64 / mixed | 75,008 | 81,195 | +8.97% | +7.30% to +10.65% |
| 1,024 / mixed | 83,864 | 96,001 | +14.46% | +13.01% to +15.70% |

Every 64-connection mixed pair improves, from +6.12% to +11.79%. Feed has three positive and three negative pairs; no feed improvement or regression is established. Mixed CPU/request changes range from −1.48% to +4.08%, and median p99 rises from 20.63 to 27.22 ms. This is a throughput improvement with a checkpoint-latency tradeoff, not a claim that every metric improves.

Every 1,024-connection pair also improves, from +11.27% to +16.27%. Mixed CPU/request decreases in five of six pairs (range −3.44% to +0.98%; bootstrap interval −2.58% to −0.24%). Median p99 rises from 37.02 to 43.53 ms. All warmups and measurements report zero socket, HTTP-status and semantic errors.

Median server-cgroup peak memory for mixed traffic increases from 45.32 to 58.85 MiB at 64 connections and from 56.94 to 70.83 MiB at 1,024. This includes page cache and kernel memory, consistent with the larger WAL. The largest candidate peak in these confirmations is 71.57 MiB. Seed copies happen outside the server cgroup, so these figures are not whole-host memory consumption.

## Candidate decisions

Short screens identify regressions and select candidates; two-pair intervals are not strong confidence estimates. Percentages below summarize the named local experiments, not changes in the official score.

| Candidate | Result and decision |
|---|---|
| LUFP parsing | Accepted previously: approximately twice as fast for isolated parsing, lower CPU per create in every longer pair. No established mixed-workload gain. See LUFP.md. |
| SQL `GROUP BY` for feed like counts | Rejected. Four pairs: feed −16.36%, mixed −9.16%. SQLite aggregation costs exceed the saved FFI work here. |
| Submit committed sends before checkpoint | Rejected. Two pairs: mixed −2.51%; creates inconsistent (−0.56%, +3.97%). Commit-before-reply ordering stays intact. |
| Original process checkpointer | Rejected. Four longer pairs: creates +30.26%, but mixed +1.95% with an interval spanning zero, mixed CPU/request approximately 22–29% higher and likes −2.85%. Better write p99 alone does not justify this architecture. |
| Original thread checkpointer | Rejected. Extended screen: creates +35.47%, mixed +3.01%, but mixed CPU/request approximately 20–22% higher and likes −4.51%. The separate connection uses a thread-safe SQLite build. |
| Process helper scheduled by newly appended frames | Not selected. Fixing repeated requests based on absolute WAL height improves scheduling. Over LUFP, mixed gains are +15.25% at 64 connections and +16.54% at 1,024 in short screens, but CPU/request is higher and likes regress in two of three pairs. Hardened helper startup/failure/fallback tests pass; the simpler interval has a better resource profile. |
| Thread helper scheduled by newly appended frames | Not selected. Short independent screen: mixed +17.47%, but CPU/request approximately 6–8% higher and feed −3.93%. It adds thread/connection/failure handling without a demonstrated advantage over the selected interval. |
| Synchronous PASSIVE checkpoint | Rejected. Mixed falls in both pairs (−2.55%, −0.58%); creates are inconsistent. |
| Synchronous interval of 4,096 frames | Accepted after longer confirmation and normal-production validation. Mixed throughput improves consistently, with a larger WAL and longer checkpoint stalls; likes are neutral in the composite screen. Only the checkpoint trigger changes in production. |
| Synchronous interval of 16,384 frames | Not selected. Short screen: creates +50.90%, but mixed +7.69%, approximately 10–12% more mixed CPU/request and create p99 approximately 53 ms, versus approximately 26 ms at 4,096 frames. |
| One issuer, polling all rings | Rejected. Feed −3.84% and a small mixed gain with no CPU reduction; no demonstrated advantage worth replacing the current scheduling. |
| One issuer with lazy/deferred task handling | Rejected before performance acceptance. Two full-suite attempts return EOF instead of HTTP 400 on ambiguous framing. Focused runs and instrumented versions can pass; the cause remains unresolved. |
| One issuer with automatic kernel task handling | Rejected. Feed −7.11%, mixed −8.59% in its screen. |
| One issuer owning App directly, without the mutex | Rejected. Feed −8.13%, mixed −9.07% in its screen. |
| Batch target 64 instead of 32 | Rejected after four longer pairs at 1,024 connections. Feed loses every pair; mixed changes +6.47%, +0.58%, −0.72%, −1.17%. Keep 32. |
| Completion wait 1,000 μs instead of 250 μs | Rejected after four longer pairs at 1,024 connections. Mixed changes +3.01%, +0.98%, +1.04%, −0.91%; feed is noisy. Keep 250 μs. |

The helper's failure tests cover killing the helper, synchronous fallback, acknowledged-write recovery, reaping and restart. Its LUFP composite also tests unavailable-helper startup and bounded WAL growth during fallback. These experimental sources are retained for audit, not compiled into the submission.

## Production build and validation

The exact selected sources also build successfully with the original, unmodified `build.sh` and `build.rs`, including normal synthetic SQLite PGO training. The resulting production binary has SHA-256 `33633216a43eb33806128879d9bcd8d520fa4bf6282e2c6f2c4f1b01d349ce68`. It is distinct from the fixed-archive comparison binary. The previously tested LUFP production binary is preserved as the production control.

This production build passes all 42 official checks, six reference-SQLite feed checks, ten Rust tests including ignored diagnostics, and 96 protocol/auth/recovery checks. The latter include recovery of acknowledged writes after SIGKILL, 15,000 simultaneous validated keep-alive sockets and reuse of original sockets after 66 seconds. The normal dependency graph contains neither `serde` nor `serde_json`; they remain pinned development dependencies only.

An additional consistency check compares the actual production binaries with their own normally trained SQLite libraries. At 1,024 connections, two balanced pairs measure 85,201 → 97,386 median mixed req/s. Individual throughput gains are +14.03% and +14.58%, with CPU/request reductions of 0.60% and 3.09%. Median p99 increases from 35.55 to 42.39 ms. These two pairs supplement the longer fixed-archive confirmation; their small sample is not a separate strong confidence estimate.

The initial production check at 64 connections gives −0.44% and +5.48% throughput changes, with CPU/request 6.42–10.17% higher. That uncertainty prompts a separate six-pair confirmation after the sustained hold, using the same 15-second measurements and 10-second warmups. It measures 75,526 → 82,182 median mixed req/s, with a paired geometric mean gain of **7.96%** (bootstrap 95% interval **+6.04% to +9.89%**). Every pair improves (+4.28% to +11.45%), with zero warmup or measurement errors. CPU/request increases in every pair (+1.32% to +5.92%); median p99 rises from 22.42 to 27.65 ms. The initial screen and longer confirmation are both retained, and the extra CPU cost is part of the tradeoff.

The normal production binary passes the unchanged official `bench/load.js`: 1,000 users for the two-minute warmup, followed by 15,000 users for a five-minute hold, retaining default ramps and think times on the same server and database. The complete main run, including ramps, records 559,968 requests and successful checks, zero failures, p95 0.407 ms and p99 2.01 ms. Peak server-cgroup memory is 72.81 MiB. This validates a sustained local workload; it does not measure maximum capacity or an official score.

## Evidence and reproduction

[`bench/research-results.json.gz`](bench/research-results.json.gz) contains raw trials and analyses, correctness logs, exact experimental source snapshots, source/binary hashes, build manifests and local runner sources. Rejected and noisy versions are included. Binaries, seed databases and token files are excluded. The parser's separate evidence remains in `bench/lufp-results.json.gz`.

Inspect the archive without executing anything:

```bash
gzip -dc bench/research-results.json.gz | python3 -m json.tool > /tmp/research-results.json
```

For reproduction, adapt the archived runners' absolute workspace paths, account and available CPU numbers. `benchmark.py` records the limits and fresh-seed setup; `confirm_selected.py` runs the final balanced comparisons; `build_selected_production.py` and `check_selected_production.py` build normally, validate and run the unchanged official workload. `confirm_selected_production.py` runs the extended 64-connection production comparison after that workload exits. The archived experimental `build.rs` overrides only hold the SQLite archive constant for comparisons. The submitted `build.rs` and `build.sh` have no such override.

All shipped changes stay in this submission directory. The fixed schema and indexes, live SQLite reads, individual JWT signature checks and commit-before-response gate remain intact. No cache, benchmark detection, added service or host tuning is introduced. The pre-existing leading-NUL/schema CHECK boundary remains unresolved; constraints and text binding are not weakened to hide it.
