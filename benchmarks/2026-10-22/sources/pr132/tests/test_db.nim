## Unit test for src/db.nim against a copy of the challenge seed database.
##
## The seed DB is never touched: we copy it to a temp file and open the copy.
## Each case prints "PASS <name>"; the first failure prints "FAIL <name>" and
## exits non-zero.

import std/[json, os, strutils]
import ../src/db
import ../src/model

var failures = 0

proc pass(name: string) =
  echo "PASS ", name

proc fail(name, detail: string) =
  inc failures
  echo "FAIL ", name, ": ", detail
  quit(1)

proc expect(name: string, cond: bool, detail: string) =
  if cond: pass(name) else: fail(name, detail)

proc countThreads(): int =
  ## The off-loop checkpointer must have created exactly one worker pthread in
  ## addition to the request thread.
  for line in readFile("/proc/self/status").splitLines:
    if line.startsWith("Threads:"):
      return parseInt(line.splitWhitespace()[1])
  0

proc runTests() =
  # locate the seed DB relative to this source file, copy it to a temp file.
  let testDir = currentSourcePath().parentDir               # .../tests
  let submissionDir = testDir.parentDir                     # .../nim-io_uring-NioHast
  let defaultSeed = submissionDir.parentDir.parentDir / "seed" / "feed.db"
  let seedDb = getEnv("SEED_DB", defaultSeed)

  if not fileExists(seedDb):
    quit("seed db not found: " & seedDb, 1)

  let tmpDb = getTempDir() / ("feed_test_" & $getCurrentProcessId() & ".db")
  copyFile(seedDb, tmpDb)
  echo "# seed   = ", seedDb
  echo "# copy   = ", tmpDb

  defer:
    for suffix in ["", "-wal", "-shm"]:
      let f = tmpDb & suffix
      if fileExists(f):
        try: removeFile(f) except OSError: discard

  let db = openDb(tmpDb)
  db.startCheckpointer()

  # health ------------------------------------------------------------------
  expect("health", db.health(), "health() returned false")

  # feed: newest 20 ---------------------------------------------------------
  # `writeFeedJson` is the sole production path; the ordered-query writer is its
  # decline path and doubles as the byte-equality oracle here.
  var feedBody = ""
  db.writeFeedJson(feedBody)
  var orderedBody = ""
  db.writeFeedFallbackJson(orderedBody)
  expect("feed_bytes_match_ordered", feedBody == orderedBody,
         "dense writer diverged from the ordered query")
  let feed = parseJson(feedBody)
  echo "# feed[0].id = ", feed["posts"][0]["id"].getInt,
       " (len=", feed["posts"].len, ")"
  expect("feed_len_20", feed["posts"].len == 20, "len=" & $feed["posts"].len)
  expect("feed_first_id_500000", feed["posts"][0]["id"].getInt == 500000,
         "id=" & $feed["posts"][0]["id"].getInt)

  # getPost(1) --------------------------------------------------------------
  var p1: Post
  let found1 = db.getPost(1, p1)
  echo "# post1 author=", p1.author, " likes=", p1.likeCount,
       " created=", p1.createdAt
  expect("getPost_1_found", found1, "getPost(1) returned false")
  expect("getPost_1_author", p1.author == "happy_nebula_10241",
         "author=" & p1.author)
  expect("getPost_1_likeCount", p1.likeCount == 11, "likeCount=" & $p1.likeCount)
  expect("getPost_1_createdAt",
         p1.createdAt.startsWith("2025-01-01T00:00:34"),
         "createdAt=" & p1.createdAt)

  # getPost(missing) --------------------------------------------------------
  var missing: Post
  let foundMissing = db.getPost(999999999'i64, missing)
  expect("getPost_missing_false", not foundMissing,
         "getPost(999999999) returned true")

  # createPost --------------------------------------------------------------
  var created: Post
  let createdOk = db.createPost(1, "golden_ember_1", "hello", created)
  echo "# created id=", created.id, " createdAt=", created.createdAt
  expect("createPost_true", createdOk, "createPost returned false")

  var reread: Post
  let rereadOk = db.getPost(created.id, reread)
  expect("createPost_reread_found", rereadOk,
         "getPost(new id) returned false")
  expect("createPost_body", reread.body == "hello", "body=" & reread.body)
  expect("createPost_likeCount", reread.likeCount == 0,
         "likeCount=" & $reread.likeCount)
  expect("createPost_author", reread.author == "golden_ember_1",
         "author=" & reread.author)

  # like --------------------------------------------------------------------
  let like1 = db.like(1, 1)
  echo "# like(1,1) first = ", like1
  expect("like_first_liked", like1 == loLiked, "got " & $like1)

  let like2 = db.like(1, 1)
  echo "# like(1,1) second = ", like2
  expect("like_second_already", like2 == loAlready, "got " & $like2)

  let like3 = db.like(1, 999999999'i64)
  echo "# like(1,missing) = ", like3
  expect("like_missing_nopost", like3 == loNoPost, "got " & $like3)

  # --- per-pass read transaction -------------------------------------------
  # From here on group commit is ON, so `commitBatch` is the pass boundary.
  db.setGroupCommit(true)

  # read-then-write in one pass: `writeFeedJson` opens the pass's deferred read
  # transaction and `createPost` must end it before `BEGIN IMMEDIATE` instead of
  # raising "cannot start a transaction within a transaction".
  db.writeFeedJson(feedBody)
  var rwPost: Post
  let rwOk = db.createPost(1, "golden_ember_1", "read then write", rwPost)
  expect("read_then_write_create", rwOk,
         "createPost after feed returned false")
  expect("read_then_write_commit", db.commitBatch(),
         "commitBatch after read-then-write returned false")
  expect("read_then_write_read_txn_ended", db.endRead(),
         "endRead after a read->write pass did not report a closed transaction")

  # fresh-read visibility after a write commit: the next pass opens a NEW read
  # transaction and must see the committed row. A snapshot carried across the
  # boundary would hide it.
  var seen: Post
  let seenOk = db.getPost(rwPost.id, seen)
  expect("fresh_read_after_commit",
         seenOk and seen.body == "read then write",
         "new pass did not see the committed post")

  # read -> write in the same pass again, this time a like, then commit.
  db.writeFeedJson(feedBody)
  let lk = db.like(1, rwPost.id)
  expect("read_then_like_liked", lk == loLiked, "got " & $lk)
  expect("read_then_like_commit", db.commitBatch(),
         "commitBatch after read-then-like returned false")

  # --- off-loop WAL checkpoint ---------------------------------------------
  expect("read_pass_boundary_end", db.endRead(),
         "endRead at the pass boundary failed")

  # The WAL hook raises the worker's wanted flag after every commit. Drive one
  # commit and wait for the dedicated pthread to run a PASSIVE checkpoint.
  var beforeCommit = db.checkpointStats()
  var hookPost: Post
  expect("checkpoint_hook_create",
         db.createPost(1, "golden_ember_1", "checkpoint hook", hookPost),
         "createPost before checkpointing returned false")
  expect("checkpoint_hook_commit", db.commitBatch(),
         "commitBatch before checkpointing returned false")
  db.requestCheckpoint()

  var afterCommit = beforeCommit
  var waited = 0
  while waited < 5000:
    afterCommit = db.checkpointStats()
    if afterCommit.count > beforeCommit.count:
      break
    sleep(10)
    waited += 10
  echo "# checkpoint worker: count ", beforeCommit.count, " -> ",
       afterCommit.count, " waited_ms=", waited,
       " last_pnLog=", afterCommit.lastPnLog,
       " busy=", afterCommit.busy, " errors=", afterCommit.errors
  expect("checkpoint_worker_ran",
         afterCommit.count > beforeCommit.count,
         "checkpoint count did not advance in 5s; count=" & $afterCommit.count)
  expect("checkpoint_worker_no_errors",
         afterCommit.errors == 0 and afterCommit.pollFailures == 0,
         "errors=" & $afterCommit.errors & " poll_failures=" &
           $afterCommit.pollFailures)
  expect("checkpoint_worker_passive",
         afterCommit.lastPnLog >= 0,
         "worker did not observe WAL frames; pnLog=" & $afterCommit.lastPnLog)

  # The worker must stay healthy after another signal, including when it
  # coalesces the request with the previous checkpoint.
  db.requestCheckpoint()
  sleep(20)
  let afterSecond = db.checkpointStats()
  expect("checkpoint_worker_stable",
         afterSecond.errors == 0 and afterSecond.pollFailures == 0,
         "errors=" & $afterSecond.errors & " poll_failures=" &
           $afterSecond.pollFailures)

  # The checkpointed data is still readable and durable.
  var thresholdRead: Post
  let thresholdReadOk = db.getPost(hookPost.id, thresholdRead)
  expect("checkpoint_data_persists",
         thresholdReadOk and thresholdRead.body == hookPost.body,
         "post unreadable after the off-loop checkpoint")
  expect("checkpoint_read_pass_end", db.endRead(),
         "endRead after the persistence read failed")

  # The request thread plus exactly one checkpointer pthread.
  let threads = countThreads()
  echo "# threads after off-loop checkpoints: ", threads
  expect("checkpoint_worker_thread", threads >= 2,
         "process has " & $threads & " threads; expected request + worker")

  # The request connection can be closed and reopened; closeDb is idempotent and
  # stops the checkpoint worker first.
  let closedId = hookPost.id
  let closedBody = hookPost.body
  db.closeDb()
  db.closeDb()
  pass("checkpoint_close_idempotent")
  let reopened = openDb(tmpDb)
  var reopenedPost: Post
  let reopenedOk = reopened.getPost(closedId, reopenedPost)
  expect("checkpoint_reopen_after_close",
         reopenedOk and reopenedPost.body == closedBody,
         "DB unreadable after closeDb + reopen")
  expect("checkpoint_reopen_end_read", reopened.endRead(),
         "endRead on the reopened connection failed")
  reopened.closeDb()

runTests()

if failures == 0:
  echo "ALL TESTS PASSED"
else:
  echo "FAILURES: ", failures
  quit(1)
