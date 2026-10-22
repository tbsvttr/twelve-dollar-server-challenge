# Further candidate after the first completed holdout

The first frozen candidate's complete 30-attempt holdout is retained in
`holdout-selected/`. Its paired geometric mean was +10.7286%, its one-sided
95% lower bound was +4.1322%, and only 7/10 pairs exceeded 5%. It did not meet
the predeclared stability target. No attempt is removed or replaced.

A genuinely changed candidate may now be developed: fuse the feed's latest-ID
and full-row traversals, and reuse OpenSSL keyed HMAC setup while verifying
every token. All retained correctness, authorization, durability, sparse-feed
and live-likes behavior must be preserved. These are hypotheses until measured.
Changes are staged separately from the installed and previously measured source.

Correctness and selection measurements precede a new immutable selection. The
selection diagnostic retains A/A checks and reverses shared-CPU sides. It may
compare the new candidate with both unchanged Rust and the first candidate.
All diagnostics remain selection evidence, outside confirmation statistics.

A new selected implementation receives a fresh, separately named holdout using
the exact same acceptance gates in `PROTOCOL.md`: ten clean complete triplets,
45-second runs with two-second warmups, unchanged pinned Rust and retained Goose
controls, the common declared monotonic wrk driver, at most two whole-round
replacements for protocol failures, and no exclusions for low throughput. The
paired geometric mean and one-sided 95% lower bound must both be at least 1.05; at
least nine pairs must individually exceed 1.05. Candidate errors in any attempt
prevent success, and the median p99 gate remains unchanged.

The second holdout is not pooled with the first or with discovery. Both outcomes
will be disclosed. No second confirmation is started for the unchanged first
candidate, and a new candidate's frozen source, image and binary cannot change
during its holdout. This declaration is recorded before the new candidate's
first performance measurement.
