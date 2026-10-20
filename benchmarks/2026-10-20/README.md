# All-submission benchmark — 2026-10-20

This evidence bundle accompanies [issue #7](https://github.com/arjaythedev/twelve-dollar-server-challenge/issues/7). It accounts for 126 PRs in the frozen snapshot: 116 current submission PRs with 119 implementations, plus 10 excluded PRs. The local ARM64 comparison contains 92 clean ranked implementations, 8 measured diagnostic/reference rows and 19 documented outcomes without a valid three-trial result.

- [Read the report](report.md) for the creator's video references, conditions, results and failures.
- [Download the comparison CSV](comparison.csv) or [all 300 recorded trials](trials.csv).
- [Download the interactive HTML table](comparison.html) and open it locally. GitHub's file view does not execute the table's JavaScript.
- [Summary](summary.json), [raw measurements](measurements.json), [verification results](verification.json) and [frozen submission manifest](manifest.json) retain the underlying records.
- [Publication manifest](publication-manifest.json) maps original evidence hashes to the hashes of these public copies and records every normalization or script adaptation.

The ranking measures this common local workload. It does not establish the organizer's maximum-user score on the official x86-64 server. Read the [report](report.md) and [wrk counter diagnostic](diagnostics-wrk-timeouts.json) before interpreting error counters and latency values.

## Reanalyze the recorded results

Python 3 can regenerate the tables from the recorded evidence without Docker, seed files or application source trees:

```sh
cd benchmarks/2026-10-20
python3 analyze.py --recorded-fixtures --strict
```

`--recorded-fixtures` is an explicit public-copy-only adaptation. It uses the fixture digests already recorded in [shared-sha256.json](shared-sha256.json). This mode reanalyzes the saved records; it does not rerun servers or independently verify omitted fixture bytes. The analyzer's default behavior still hashes actual fixture files and requires them to be present. Running the analyzer writes regenerated report/table files in its directory, so use a disposable copy if you want to retain these publication copies byte-for-byte. A new audit of regenerated files would use the public inputs; the retained canonical audits record the original run's inputs.

## What a full rerun requires

The controller, setup helpers and fixture definitions are supporting recipes, not a standalone container distribution. A new benchmark needs the following setup before `python3 run.py verify` and `python3 run.py bench`:

1. A native Linux ARM64 Docker environment with enough CPUs to separate the one-CPU service from the two-CPU load generator, the recorded memory/file-descriptor limits, and the included [seccomp profile](seccomp-io-uring.json). The [environment records](environment-bench.json) and [preflight](preflight.json) describe the measured setup.
2. The local base image `twelve-unified:2026-10-07` and the pinned per-submission images. These images are not published here. Their recorded identities and build/setup details are retained in [build-status.json](build-status.json), its three build shards, [runtime helpers](runtime-scripts/) and [wrk binary provenance](wrk-binary-provenance.json). Reconstructing an equivalent environment and resolving recorded toolchains are separate setup work.
3. The exact source revisions listed in [manifest.json](manifest.json). The source URLs and archive endpoints identify the public revisions; source trees and downloaded archive tarballs are omitted. The small [per-file source hash inventories](archives/) and [LOC inventories](source-inventories/) are included for comparison after fetching the pinned sources. Fetch by the recorded commit rather than current PR head.
4. `seed/feed.db` and `seed/tokens.json` matching the recorded digests. Both generated files are omitted. [Seed generation scripts](seed/make-seed.sh), [generator](seed/generate.mjs), [schema](schema.sql), [golden API fixtures](test/) and the [mixed workload](mixed.lua) are included. Restoring or regenerating fixtures, checking their recorded hashes, and supplying the harness's expected source/image layout are required before a full rerun; newly generated tokens or fixtures are not automatically byte-identical to the recorded ones.

The build scripts preserve the submitted application/build/start code and record native runtime adapters. The report documents build-only resource exceptions. A new run must record its own source, fixture, runtime and image identities; these archived image IDs do not describe newly rebuilt images automatically.

## Evidence and publication normalization

[Canonical final audit](audit-final.json), [round audits](audit-round1.json), [round 2](audit-round2.json), [round 3](audit-round3.json), command logs, server logs and diagnostics retain the evidence for the recorded outcomes. `archives/` contains only per-file SHA256 inventories, not source tarballs. Seed database/tokens, source trees, fetched archives, runtime caches, container images and progress/state files are excluded from this bundle.

Only these public copies were normalized: personal host nodenames were replaced with `<HOSTNAME>`; absolute host evidence paths were made relative; other personal host workspace, home and temporary directory prefixes were replaced with explicit placeholders. One already-public PR body personal home prefix was normalized as <SOURCE_AUTHOR_HOME>. Linux container paths and public source URLs remain intact. Numeric measurements, case IDs, source revisions, image IDs and recorded source/fixture hash values were preserved. Public upstream author metadata and development-secret examples already present in source documentation remain source evidence.

Hashes inside the retained audits refer to the original canonical bytes. For normalized files, use `canonical_sha256` and `publication_sha256` in [publication-manifest.json](publication-manifest.json) to distinguish the recorded original from the published copy. The same mapping records the analyzer's small offline reanalysis adaptation. This manifest does not hash itself.
