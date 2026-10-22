This is a staged, build-only synthetic PGO trainer. It has not constructed a
database, trained an instrumented binary or supplied a measured candidate yet.
Existing trainer snapshots, the live submission and the current LTO comparison
are unchanged. Adoption should copy this file into a separate candidate source
snapshot and regenerate both SQLite and application profiles under unchanged
compiler flags, then validate that candidate separately.

The frozen `combined-sqlite/source/bench/train_app.py` main loop chooses every
post read and like from its original fixture-ID list. Successful creates allocate
IDs beyond that list, and feed response IDs are discarded. Consequently no
main-loop post read or like can target a post created during that training run.
It also uses one authenticated user, 8,192 dense seed posts, and route weights
48/43/7/2 percent. The local mixed workload follows feed IDs and has relative
route weights 100/100/15/2 out of 217. The old fixture may fit an 8 MiB SQLite
cache; its actual resident working set and cache misses were not measured here.

The replacement uses an independently generated dense fixture of 131,072 posts
and variable zero-to-ten initial likes per post. Synthetic dates increase in
groups of sixteen, retaining timestamp-tie coverage. Fixture rows are streamed
into SQLite rather than constructing all likes in memory. It records database
bytes, page size/count, row counts and nominal runtime cache configuration, and
requires the dense database file to exceed 8 MiB. A larger database plus broad
seed access exposes more cache-page paths; source inspection alone cannot
quantify cache misses or predict a performance gain.

The main dense phase sends 32,768 requests with the mixed workload's relative
route weights. Eighty percent of post/like targets come from the latest parsed
HTTP feed response, and twenty percent are uniform original seed IDs. Newly
created IDs are tracked from real create responses for coverage reporting; they
enter the hot target list only through a subsequent real feed response. The
32-request pipeline introduces bounded response-feedback lag. A pool of 256
independently signed synthetic users exercises new likes and duplicate likes.
This is a declared synthetic training distribution, not a replay of benchmark
requests, payloads, seed data or tokens.

The original exact schema, synthetic text constants, JWT generator and all error
diagnostics are retained. Sparse IDs still use a stride of 37 with 8,192 posts
and 1,024 mixed requests; the empty-feed/missing-post phase remains. A deterministic
fresh-post probe obtains its ID through a live feed, inserts one like, repeats
the same like, and checks both the post and next feed report a count of exactly
one. Main-loop coverage separately requires observed likes on newly created
feed posts, so the probe cannot hide failure to exercise that path naturally.

All databases are disposable and checked before and after training. Profile
shutdown retains the existing synchronized SIGUSR1 helper contract. No challenge
fixture, golden payload or challenge token is opened by this trainer. The
`static-review.json` file records syntax/schema/function-preservation checks
only; runtime coverage, profile artifacts, correctness and throughput remain
unverified until a separately authorized build and run.
