# Publication scope and integrity

This evidence copy accompanies the PR26 change from `WAIT_NR=128` to `32`, with
`WAIT_USEC=4000` retained. The result is a descriptive local ARM64 throughput
experiment: higher throughput than original PR26, below the current leader in the
independent confirmation. It is not an official five-minute k6 capacity score.

The bundle preserves **all 51 timed trials**: 18 initial screening trials, 15 bounded
follow-up screening trials, and 18 independent confirmation trials. Stage results
remain separate. The 14 correctness records, all exploratory patches and source
inventories, raw wrk output, server/build logs, frozen identities, pre/post audits,
host observation, and repeated fault-diagnostic results are included. The initial
screen leader has two wrk histogram-overlimit counters; the final confirmation is
entirely counter-clean. Such counters do not establish dropped requests.

Negative outcomes remain visible: threshold 8 failed rollback-recovery assertions
and was rejected; its lifecycle/SIGKILL step did not run after that failure.
Threshold 16 was not additionally fault-tested or adopted. The selected threshold
32 passed the recorded fault and persistence assertions. Its first durability
attempt failed before checks because of test-workspace permissions; the corrected
second attempt and all repeat diagnostics are retained. Passing diagnostic clients
also permit transient POST status 0 and do not guarantee a specific HTTP response
for every injected write.

Only publication copies were normalized. Personal host workspace/home prefixes,
the host username and hostname use placeholders. Container paths and public source
identities are retained. The public README also explains the replay limits. Numeric
measurements, source commits, image IDs, source/fixture hashes, record fingerprints
and canonical audit input hashes were not changed. JSON object keys containing
personal paths were normalized too. Historical authorization/phase fields describe
the state when recorded; this later evidence publication does not rewrite them.

`publication-manifest.json` gives each original repository-relative path, original
SHA256/size, public SHA256/size and transformations. Original audit/input hashes refer
to original bytes, not normalized public copies. The manifest excludes itself from
its per-file map. `publication-checks.json` records the packaging checks. This is
an evidence publication, not a claim that normalized files reproduce the original
hashes or that an independent auditor reran the workloads.

Omitted: generated seed database and benchmark tokens; full application source
copies; built images, caches and build contexts; progress/lock files; PR-planning
metadata; and the unused threshold-8 confirmation directory, where no timing or
verification ran. Source commits, per-file inventories, all patches, image IDs and
fixture checksums remain available. The preserved scripts require restored pinned
inputs, the original path layout and adjacent reference-analysis helpers before
fresh validation/replay. No workloads, builds or external actions were run to
prepare this bundle. Canonical local evidence was left untouched.
