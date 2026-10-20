# PR26 batching follow-up

**No: the tuning improves PR26, but the current #1 reference remains faster in this confirmation.**

Frozen setting: `WAIT_NR=32`, `WAIT_USEC=4000`. Confirmation: 91,103 median successful req/s, +42.7% versus original PR26 and -10.3% versus the leader.

[Read the full result, all settings and six paired rounds](RESULT.md).

Stage reports: [initial 2×2 screen](analysis-report.md) · [bounded 32/16/8 screen](followup-screen/analysis-report.md) · [independent confirmation](confirmation/analysis-report.md).

The final conclusion uses only the independent six-round confirmation. Both exploratory screens, counter flags, durability attempts and the frozen identity audits remain linked in the result. This is a local ARM64 throughput experiment, not the official k6 capacity score or a newly published leaderboard.

To regenerate these two local documents after all stage reports and audits are complete:

```sh
python3 summarize_tuning.py
```

The generator refuses incomplete/stale evidence and runs no builds, containers, workloads or remote actions.


## Public evidence copy

This folder publishes all **51 timed trials** and the retained correctness, fault,
durability and identity evidence. See [publication scope and checksums](PUBLICATION.md).

The regeneration command above describes the complete original local workspace.
The scripts here are preserved recipes, not a standalone replay package: seed
databases/tokens, built images, full source trees and adjacent reference-analysis
helpers are omitted, and private host paths are normalized in these public copies.
Restore the original pinned inputs and path layout before using validation or
regeneration commands. Recorded fingerprints and audit input hashes remain the
original values; the publication manifest maps original bytes to public bytes.
