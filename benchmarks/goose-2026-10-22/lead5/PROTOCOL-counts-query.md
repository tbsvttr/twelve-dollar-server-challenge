# Bounded live-count aggregation after two completed failed holdouts

Both completed confirmation batches remain unchanged and are not pooled:
`holdout-selected/` (+10.73% mean, +4.13% lower, 7/10 above 5%) and
`holdout-hmac/` (+13.72% mean, +1.85% lower, 8/10 above 5%). Neither met the
original stable 5% target. All raw attempts, errors, audits and reports remain.

One further concrete server change is isolated from source 9a298580: the compact
feed's bounded likes query groups by post_id and returns count(*). Goose still
owns the SQL, selected-ID mapping, ordering, fallback, validation and JSON.
This replaces repeated per-like SQLite step/column calls with per-post live
counts. It changes no schema, durability, authentication or cross-request data
caching. The rejected full-row feed fusion remains rejected.

An equivalent bounded GROUP BY query lost a single earlier screen on the
older 17-file, pre-application-PGO/cache baseline; that evidence remains in
`../optimization/candidates/grouped/`. This is a fresh ablation on the changed
19-file normal-budget HMAC implementation, not a previously proven improvement.

Build normally from source as UID1001 with fresh SQLite and application PGO,
one CPU quota, 2 GiB memory and no swap. All API servers use the same budget.
Only one server runs at a time; the load generator stays outside its budget.
The Mac and unrelated host activity remain as-is. No new profiling framework or
hardware tuning is introduced.

Before any performance measurement, require exact-source/image/binary proof,
42 official checks, semantic/database checks, 18 parser checks, 25 edge checks,
and 9 additional likes-boundary checks. The unchanged db.c retains its previously
verified HMAC differential/failure/sanitizer proofs.

Selection is exactly two sequential matched 15-second triplets against unchanged
Rust and the immediately preceding normal-budget HMAC image (afde328e / a5e1c087).
Every run remains. Require all six attempts valid/error-free, geometric paired
Goose/Rust ratio at least 1.05 and paired new/previous ratio at least 1.05.
No low-throughput exclusions or repetitions. Selection does not establish the
stable target and is never pooled into confirmation.

If selected, freeze this source/image/binary and all declaration/proof hashes
before a separately named fresh confirmation. Keep exactly the original gates
in PROTOCOL.md: first ten clean full triplets at 45 seconds, two-second warmup,
unchanged Rust and retained Goose controls, at most two whole protocol-failure
replacement rounds, no candidate errors in any attempt, geometric mean and
one-sided 95% lower ratio both at least 1.05, at least 9/10 individual ratios
above 1.05, and the median p99 gate. Same common monotonic driver. This declaration
precedes this candidate's first performance sample.
