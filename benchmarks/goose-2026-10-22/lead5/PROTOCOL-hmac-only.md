# Isolating HMAC after rejecting the fused feed

The complete first holdout and its failed stability outcome remain unchanged
in `holdout-selected/`. The next development stage was declared in
`PROTOCOL-feed-hmac.md` before its selection measurements.

The combined feed/HMAC candidate passed correctness but is rejected: both
side-swapped shared-CPU pairs were slower than the first candidate
(ratios 0.9844147769 and 0.9870770311). Its Rust ratios were 1.0230359631
and 1.0388098135. All six pair attempts, including the A/A gate, remain in
`paired-diagnostic-feed-hmac/`; none is confirmation evidence.

The next candidate keeps the original selected feed and isolates the reviewed
keyed HMAC state reuse. No other runtime or toolchain change is introduced.
Its source, image and binary receive fresh identity and correctness checks,
then a new side-swapped diagnostic with A/A controls. This declaration precedes
that candidate's first performance measurement.

If selected, it receives a separately named fresh holdout with exactly the
acceptance rules of `PROTOCOL.md` and the common driver correction declared in
`PROTOCOL-monotonic.md`. Ten clean matched triplets, all 45-second measurements,
all attempted errors, at most two protocol-failure replacement triplets,
unchanged Rust/retained Goose controls, the geometric mean and one-sided 95%
lower bound of at least 1.05, at least nine individual ratios above 1.05, and
the median p99 gate remain required. Low throughput never excludes a run.

No prior holdout or diagnostic is pooled into that comparison. The rejected
feed change is not installed. Both completed holdout outcomes must remain
visible if a second holdout is performed.
