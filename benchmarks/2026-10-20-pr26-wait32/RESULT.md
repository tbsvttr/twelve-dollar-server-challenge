# PR26 batching experiment — final local result

**No: the tuning improves PR26, but the current #1 reference remains faster in this confirmation.**

Selected the initial screen winner after rejecting threshold 8 for repeated rollback-recovery assertion failures. Threshold 32 passed the original commit suite and SIGKILL persistence assertions, followed by three original and three instrumented commit suites. Unchanged PR26 passed all six diagnostic repeats. The exact threshold-8 failure cause remains unresolved; no phantom rows were observed. Confirmation used the frozen initial selection and six balanced orders. ([recorded decision](RUN_STATUS.json)).

The frozen `26-b32-w4000` candidate changed `WAIT_NR` from **128 to 32**, retaining `WAIT_USEC=4000`. In the six-round confirmation its median successful throughput was **+42.7% versus original PR26** and **-10.3% versus the current #1 reference**. These percentages divide stage medians; paired ratios are shown separately.

## Independent confirmation

| Case | Median req/s [range] | p95 ms | p99 ms | RSS MiB | CPU % | CPU µs/request | HTTP | Socket C/R/W/T | Clean / valid |
|---|---:|---:|---:|---:|---:|---:|---:|---|---:|
| 26-original | 63,850 [58,670–65,556] | 6.870 | 12.020 | 39.29 | 48.7 | 7.683 | 0 | 0/0/0/0 | 6/6 / 6/6 |
| 26-b32-w4000 | 91,103 [85,288–99,520] | 10.102 | 13.765 | 41.86 | 74.1 | 8.219 | 0 | 0/0/0/0 | 6/6 / 6/6 |
| 82-leader | 101,552 [80,193–104,995] | 12.863 | 23.560 | 47.60 | 87.2 | 8.680 | 0 | 0/0/0/0 | 6/6 / 6/6 |

| Round | Candidate / original | Candidate / leader | Counters clean for both pairs? |
|---:|---:|---:|---|
| 1 | 1.5527× | 0.9479× | original pair: True; leader pair: True |
| 2 | 1.4895× | 0.9402× | original pair: True; leader pair: True |
| 3 | 1.4434× | 1.1148× | original pair: True; leader pair: True |
| 4 | 1.3397× | 0.9190× | original pair: True; leader pair: True |
| 5 | 1.3043× | 0.8334× | original pair: True; leader pair: True |
| 6 | 1.5818× | 0.8925× | original pair: True; leader pair: True |

Median within-round ratio: **1.4665× original** (6/6 wins), **0.9296× leader** (1/6 wins). All six permutations were used once, with each implementation in each position twice. No screening trial is included in these confirmation values.

The comparisons are descriptive. Six short rounds do not establish statistical significance, and a higher noisy median alone is not treated as a #1 result. Counter-flagged valid reference runs remain visible and qualify their paired comparisons; the published zero-error ranking rule is unchanged.

Service CPU changed from **48.7% to 74.1%**; p95 changed from **6.870 to 10.102 ms**. The throughput gain came with higher service CPU usage and worse p95 latency in this confirmation. RSS is end-of-load summed service RSS, not peak/container memory. CPU µs/request uses each trial’s sampled CPU delta divided by completed requests.

**Host variability.** A [host observation during confirmation](confirmation/host-observation.json) recorded load averages **13.35 / 10.56 / 10.10**. The thermal-status read failed. No cause of the throughput variation was established, and no trial was excluded or adjusted. The six paired rounds retain the observed variation; these local shared-host measurements have limited precision.

## How the setting was chosen

Stage reports: [initial 2×2 screen](analysis-report.md) · [bounded 32/16/8 screen](followup-screen/analysis-report.md) · [independent confirmation](confirmation/analysis-report.md).

The original screen tested the full 2×2 completion-count/wait grid and a rebuilt unchanged control. The bounded follow-up then compared 32, 16 and 8 completions with the 4 ms wait retained. Only after that exploratory comparison was one setting frozen for the independent confirmation. All tested settings remain below.

### Initial screen — three rounds per case

| Case | Median req/s [range] | CPU % | HTTP | Socket C/R/W/T | Clean / valid / expected |
|---|---:|---:|---:|---|---:|
| 26-original | 65,869 [65,825–66,529] | 49.1 | 0 | 0/0/0/0 | 3 / 3 / 3 |
| 82-leader | 103,501 [97,109–109,212] | 88.2 | 0 | 0/0/0/2 | 2 / 3 / 3 |
| 26-b128-w4000 | 65,648 [65,366–66,344] | 49.5 | 0 | 0/0/0/0 | 3 / 3 / 3 |
| 26-b32-w4000 | 97,713 [92,971–102,778] | 76.1 | 0 | 0/0/0/0 | 3 / 3 / 3 |
| 26-b128-w250 | 65,977 [63,917–67,224] | 51.9 | 0 | 0/0/0/0 | 3 / 3 / 3 |
| 26-b32-w250 | 96,734 [95,501–96,852] | 74.6 | 0 | 0/0/0/0 | 3 / 3 / 3 |

### Bounded follow-up — three rounds per case

| Case | Median req/s [range] | CPU % | HTTP | Socket C/R/W/T | Clean / valid / expected |
|---|---:|---:|---:|---|---:|
| 26-original | 65,302 [63,830–66,012] | 49.4 | 0 | 0/0/0/0 | 3 / 3 / 3 |
| 82-leader | 106,330 [99,607–106,917] | 88.7 | 0 | 0/0/0/0 | 3 / 3 / 3 |
| 26-b32-w4000 | 96,029 [93,924–100,498] | 75.5 | 0 | 0/0/0/0 | 3 / 3 / 3 |
| 26-b16-w4000 | 98,659 [97,048–101,520] | 76.3 | 0 | 0/0/0/0 | 3 / 3 / 3 |
| 26-b8-w4000 | 98,765 [86,952–99,381] | 75.8 | 0 | 0/0/0/0 | 3 / 3 / 3 |

The exploratory winner `26-b8-w4000` exceeded runner-up `26-b16-w4000` by only **0.11%** in median throughput. That selection difference does not establish a uniquely optimal setting.

The median screen winner was `26-b8-w4000`; the final `26-b32-w4000` setting was an explicit fallback after the recorded rejection, not an undeclared reselection.

**Rejected or unadopted settings:**

- `26-b8-w4000`: Rollback-recovery assertion failed in the initial check, in one of three original-client repeats, and in one of three instrumented-client repeats. The failed diagnostic final feed request returned status 0: no successfully parsed complete HTTP response. The original control passed six corresponding repeats. No data leak was observed; root cause unresolved. Not accepted for adoption. [26-b8-w4000.json](followup-screen/durability/26-b8-w4000.json), [result.json](followup-screen/commit-diagnostics/26-b8-w4000/result.json), [commit-diagnostic-3.log](followup-screen/commit-diagnostics/26-b8-w4000/commit-diagnostic-3.log), [result.json](followup-screen/commit-diagnostics/26-original/result.json)

- `26-b16-w4000`: Exploratory median only 2.74% above the fresh 32/4000 control and 0.11% below threshold 8, with overlapping ranges. Additional rollback-fault validation was not performed; no fault failure is claimed. Retained the initial threshold-32 winner while recovery behavior at lower thresholds remains unresolved. [analysis-summary.json](followup-screen/analysis-summary.json)

## Correctness, durability and frozen identities

Every measured case passed 42 official API checks, six dynamic semantic checks, and post-stop SQLite integrity/committed-growth validation before or during its stage. The final confirmation contains six valid trials for each of its three cases. The pre/post audit matched the frozen selection, images, source inventories, controller, twelve fixture hashes, orders and parent-stage lineage.

Identity evidence: [pre audit](confirmation/identity-audit-pre.json) · [post audit](confirmation/identity-audit-post.json) · [frozen selection](confirmation/selection.json) · [one-constant patch](confirmation/patches/26-b32-w4000.patch).

Selected candidate identity:

```text
sha256:63c9077452d1b89a1890e49a8e11786ac9047b7640dd0a93a6dffda2d56f5fa0
11da0037c4bcc4d0dc9d938b7e036f417bfafabd2809ca171159a48233c8802e
```

The recorded commit-fault and production-binary SIGKILL persistence assertions passed for the selected image: [durability evidence](durability/26-b32-w4000-attempt2.json). The lifecycle check used two connections and zero idle seconds; it is a correctness check, not a capacity measurement.

| Durability attempt | Result | Note |
|---|---|---|
| [26-b32-w4000 #2](durability/26-b32-w4000-attempt2.json) | True | Passed recorded checks. |
| [26-b32-w4000 #1](durability/26-b32-w4000.json) | False | Test workspace permission failure before checks; disposable workspace ownership was corrected for the retry. |
| [26-b8-w4000 #1](followup-screen/durability/26-b8-w4000.json) | False | Durability step 2 failed:  |

The initial permission failure remains recorded and is not classified as an application failure.

### Repeated commit-fault diagnostics

| Case | Completed commit-suite runs | Failed runs | Evidence |
|---|---:|---:|---|
| 26-b32-w4000 | 6 | 0 | [retained diagnostic](followup-screen/commit-diagnostics/26-b32-w4000/result.json) |
| 26-b8-w4000 | 6 | 2 | [retained diagnostic](followup-screen/commit-diagnostics/26-b8-w4000/result.json) |
| 26-original | 6 | 0 | [retained diagnostic](followup-screen/commit-diagnostics/26-original/result.json) |

Failed diagnostic runs remain visible even when their exploratory throughput was attractive. A setting that was not fault-tested is not described as having passed these additional checks. These are the clients’ recorded assertions: passing diagnostic clients also permit transient POST status 0, so a passing run does not guarantee a particular HTTP response for every injected write.

## Scope and retained evidence

Native Linux ARM64, one server CPU/2 GiB, two separate load CPUs, 64 active connections, 2-second warmup and 15-second measurements on fresh processes/databases. This local workload does not establish the official five-minute k6 maximum-user score or rerank all submissions. wrk histogram-overlimit counters represent completed responses outside its two-second histogram; they stay in throughput and are absent from latency percentiles. HTTP and timeout counters are kept separate.

The original published benchmark and all stage records are unchanged. This follow-up is local; no external publication is performed by this generator.

| Stage | Cases × rounds | Raw attempts | Latest attempts | HTTP errors | Socket C/R/W/T | Valid? |
|---|---:|---:|---:|---:|---|---|
| [Initial screen](analysis-report.md) | 6 × 3 | 18 | 18 | 0 | 0/0/0/2 | True |
| [Bounded follow-up](followup-screen/analysis-report.md) | 5 × 3 | 15 | 15 | 0 | 0/0/0/0 | True |
| [Confirmation](confirmation/analysis-report.md) | 3 × 6 | 18 | 18 | 0 | 0/0/0/0 | True |

Each stage retains its own measurements.json, verification.json, analysis-summary.json, CSVs, logs and source/fixture identities. No cross-stage pooling or selective trial removal was used. Superseded attempts, if any, remain in raw evidence and stage analysis.
