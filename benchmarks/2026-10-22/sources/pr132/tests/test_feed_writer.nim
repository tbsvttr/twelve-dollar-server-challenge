## test_feed_writer.nim: byte-exact proof for the direct feed writers.
##
## `writeFeedJson` (dense direct writer with the ordered-query decline path) and
## `writeFeedFallbackJson` (the ordered query, serialized directly) are both
## compared against the scalar serialization:
##
##     ordered feed rows -> Post objects (getPost) -> per-byte scalar escaper
##
## The scalar escaper and the feed envelope below are test-only copies, so a
## shared bug in the SSE2 raw-span escaper cannot hide. Expected row order is
## computed independently from the scenario's
## (id, created_at) list, never from the production feed query.
##
## Matrix: empty / 1 / 19 / 20 / 21 rows, dense and non-dense id windows,
## reordered created_at, 0/1/many likes, quote/backslash/control/UTF-8/NUL
## bodies, escaped created_at and author, 500-char body, and an orphan post
## (JOIN drops it) that forces the dense writer to decline after partial output.
##
## Prints "PASS <name>" per case; the first mismatch prints both byte strings and
## exits non-zero.

import std/[algorithm, os, strformat, strutils]

import ../src/sqlite3
import ../src/model
import ../src/db

const Hex = "0123456789abcdef"

# ---------------------------------------------------------------------------
# Test-only scalar serialization: exactly the object serializer/addEscaped bytes.
# ---------------------------------------------------------------------------
proc scalarEscaped(buf: var string, s: string) =
  for c in s:
    case c
    of '"':  buf.add "\\\""
    of '\\': buf.add "\\\\"
    of '\b': buf.add "\\b"
    of '\f': buf.add "\\f"
    of '\n': buf.add "\\n"
    of '\r': buf.add "\\r"
    of '\t': buf.add "\\t"
    else:
      if c.ord < 0x20:
        let o = c.ord
        buf.add "\\u00"
        buf.add Hex[(o shr 4) and 0xF]
        buf.add Hex[o and 0xF]
      else:
        buf.add c

proc scalarWritePost(buf: var string, p: Post) =
  buf.add "{\"id\":"
  buf.add $p.id
  buf.add ",\"body\":\""
  scalarEscaped(buf, p.body)
  buf.add "\",\"created_at\":\""
  scalarEscaped(buf, p.createdAt)
  buf.add "\",\"author\":\""
  scalarEscaped(buf, p.author)
  buf.add "\",\"like_count\":"
  buf.add $p.likeCount
  buf.add "}"

# ---------------------------------------------------------------------------
# Scenario bookkeeping.
# ---------------------------------------------------------------------------
type ScenarioPost = object
  id: int64
  userId: int64
  createdAt: string

var scenarioPosts: seq[ScenarioPost]
var validUsers: seq[int64]
var gHandle: ptr Sqlite3
var gSchema: string
var checks = 0
var failures = 0

proc failDetail(name, want, got: string) =
  inc failures
  echo "FAIL ", name
  echo "  want (", want.len, " B): ", escape(want)
  echo "  got  (", got.len, " B): ", escape(got)
  quit(1)

proc compare(name, want, got: string) =
  inc checks
  if want == got:
    echo "PASS ", name
  else:
    failDetail(name, want, got)

proc ts(sec: int): string =
  &"2025-01-01T00:{sec div 60:02}:{sec mod 60:02}.000Z"

proc execSchema() =
  let rc = sqlite3_exec(gHandle, gSchema.cstring, nil, nil, nil)
  if rc != SQLITE_OK:
    quit("sqlite3_exec failed (rc=" & $rc & "): " & $sqlite3_errmsg(gHandle))

proc insertUser(id: int64, name: string) =
  var stmt: ptr Sqlite3Stmt
  let rc = sqlite3_prepare_v3(gHandle,
    "INSERT INTO users(id, username) VALUES(?, ?)".cstring, -1,
    SQLITE_PREPARE_PERSISTENT, addr stmt, nil)
  if rc != SQLITE_OK: quit("prepare user failed: " & $sqlite3_errmsg(gHandle))
  discard sqlite3_bind_int64(stmt, 1, id)
  discard sqlite3_bind_text(stmt, 2, name.cstring, name.len.cint, SQLITE_TRANSIENT)
  if sqlite3_step(stmt) != SQLITE_DONE:
    quit("insert user failed: " & $sqlite3_errmsg(gHandle))
  discard sqlite3_finalize(stmt)
  validUsers.add id

proc insertPost(id, userId: int64, body, createdAt: string) =
  var stmt: ptr Sqlite3Stmt
  let rc = sqlite3_prepare_v3(gHandle,
    "INSERT INTO posts(id, user_id, body, created_at) VALUES(?, ?, ?, ?)".cstring,
    -1, SQLITE_PREPARE_PERSISTENT, addr stmt, nil)
  if rc != SQLITE_OK: quit("prepare post failed: " & $sqlite3_errmsg(gHandle))
  discard sqlite3_bind_int64(stmt, 1, id)
  discard sqlite3_bind_int64(stmt, 2, userId)
  # Explicit length: the corpus contains an embedded NUL, which cstring alone
  # would truncate on the wire into SQLite.
  discard sqlite3_bind_text(stmt, 3, body.cstring, body.len.cint, SQLITE_TRANSIENT)
  discard sqlite3_bind_text(stmt, 4, createdAt.cstring, createdAt.len.cint,
                            SQLITE_TRANSIENT)
  if sqlite3_step(stmt) != SQLITE_DONE:
    quit("insert post failed: " & $sqlite3_errmsg(gHandle))
  discard sqlite3_finalize(stmt)
  scenarioPosts.add ScenarioPost(id: id, userId: userId, createdAt: createdAt)

proc insertLike(userId, postId: int64) =
  var stmt: ptr Sqlite3Stmt
  let rc = sqlite3_prepare_v3(gHandle,
    "INSERT INTO likes(user_id, post_id) VALUES(?, ?)".cstring, -1,
    SQLITE_PREPARE_PERSISTENT, addr stmt, nil)
  if rc != SQLITE_OK: quit("prepare like failed: " & $sqlite3_errmsg(gHandle))
  discard sqlite3_bind_int64(stmt, 1, userId)
  discard sqlite3_bind_int64(stmt, 2, postId)
  if sqlite3_step(stmt) != SQLITE_DONE:
    quit("insert like failed: " & $sqlite3_errmsg(gHandle))
  discard sqlite3_finalize(stmt)

proc orderedExpected(db: Db, buf: var string) =
  ## The scalar feed serialization: independently sorted scenario rows, fetched as
  ## Post objects through getPost (which drops a row whose user is missing, just
  ## like the production JOIN), then written with the per-byte scalar escaper.
  var ordered = scenarioPosts
  ordered.sort(proc(a, b: ScenarioPost): int =
    result = cmp(b.createdAt, a.createdAt)
    if result == 0: result = cmp(b.id, a.id))
  buf.add "{\"posts\":["
  var emitted = 0
  for sp in ordered:
    if emitted == 20: break
    var p: Post
    if not db.getPost(sp.id, p):
      continue
    if emitted > 0: buf.add ','
    scalarWritePost(buf, p)
    inc emitted
  buf.add "]}"

proc pathKind(): string =
  var ordered = scenarioPosts
  ordered.sort(proc(a, b: ScenarioPost): int =
    result = cmp(b.createdAt, a.createdAt)
    if result == 0: result = cmp(b.id, a.id))
  let n = min(20, ordered.len)
  if n == 0:
    return "empty"
  var lo = ordered[0].id
  var hi = ordered[0].id
  var orphan = false
  for i in 0 ..< n:
    lo = min(lo, ordered[i].id)
    hi = max(hi, ordered[i].id)
    if ordered[i].userId notin validUsers:
      orphan = true
  if hi - lo >= 256:
    return "non-dense (ordered fallback)"
  if orphan:
    return "dense window, orphan -> decline+fallback"
  "dense window (direct writer)"

# ---------------------------------------------------------------------------
# Scenario runner.
# ---------------------------------------------------------------------------
var tmpDir = ""

proc runScenario(name: string, setup: proc(h: ptr Sqlite3)) =
  scenarioPosts.setLen(0)
  validUsers.setLen(0)
  let path = tmpDir / (name & ".db")
  var h: ptr Sqlite3
  let rc = sqlite3_open_v2(path.cstring, addr h,
    SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE, nil)
  if rc != SQLITE_OK: quit("open " & path & " failed (rc=" & $rc & ")")
  gHandle = h
  execSchema()
  setup(h)
  discard sqlite3_close_v2(h)
  gHandle = nil

  let db = openDb(path)
  var actual, ordered, want: string
  db.writeFeedJson(actual)
  db.writeFeedFallbackJson(ordered)
  orderedExpected(db, want)

  echo "# scenario ", name, ": rows=", scenarioPosts.len,
       " expected-bytes=", want.len, " path=", pathKind()
  compare(name & ".writeFeedJson_vs_scalar", want, actual)
  compare(name & ".ordered_vs_scalar", want, ordered)

# ---------------------------------------------------------------------------
# Scenarios (all inserts happen on a raw connection before openDb).
# ---------------------------------------------------------------------------
proc sEmpty(h: ptr Sqlite3) = discard

proc sOne(h: ptr Sqlite3) =
  insertUser(1, "u1")
  insertPost(1, 1, "hello", ts(0))

proc s19(h: ptr Sqlite3) =
  insertUser(1, "u1")
  for i in 1 .. 19:
    insertPost(int64(i), 1, "post " & $i, ts(i))

proc s20(h: ptr Sqlite3) =
  insertUser(1, "u1")
  for i in 1 .. 20:
    insertPost(int64(i), 1, "post " & $i, ts(i))

proc s21(h: ptr Sqlite3) =
  insertUser(1, "u1")
  for i in 1 .. 21:
    insertPost(int64(i), 1, "post " & $i, ts(i))

proc sNonDense(h: ptr Sqlite3) =
  insertUser(1, "u1")
  for i in 1 .. 19:
    insertPost(int64(i), 1, "post " & $i, ts(i))
  insertPost(1000, 1, "far away", ts(20))

proc sReordered(h: ptr Sqlite3) =
  insertUser(1, "u1")
  for i in 1 .. 20:
    # Unique timestamps in a non-id order: the row scan order differs from id
    # order inside an otherwise dense window.
    insertPost(int64(i), 1, "post " & $i, ts((i * 7) mod 20))

proc sLikes(h: ptr Sqlite3) =
  for u in 1 .. 8:
    insertUser(int64(u), "u" & $u)
  for i in 1 .. 20:
    insertPost(int64(i), 1, "post " & $i, ts(i))
  insertLike(2, 2)                    # one like
  for u in 1 .. 7:
    insertLike(int64(u), 3)           # many likes

proc sEscapes(h: ptr Sqlite3) =
  insertUser(1, "author \"q\" \\ end")
  insertUser(2, "café ✓ Привет")
  insertUser(3, "ctrl" & char(0x01) & "name")
  let long500 = 'x'.repeat(500)
  let bodies = [
    "plain",
    "quote \" and backslash \\ here",
    "controls \n\t\r\b\f",
    "raw " & char(0x00) & char(0x01) & char(0x1F) & " tail",
    "café ✓ Привет 🌍 日本語",
    long500,
    "\"" & 'a'.repeat(7) & "\\" & 'b'.repeat(7) & "\"",
    "trailing backslash \\",
    "trailing quote \"",
    "nul in middle: a" & char(0x00) & "b",
    "all quotes \"\"\"\"\"\"\"\"\"\"",
    "tabs\t\ttabs",
    "slash / solidus",
  ]
  for i in 0 ..< 20:
    let body = if i < bodies.len: bodies[i] else: "filler " & $i
    let uid = int64((i mod 3) + 1)
    insertPost(int64(i + 1), uid, body, ts(i))
  # Escape created_at too: still a TEXT column, still sorts lexicographically.
  # :99 sorts after the :00..:19 timestamps above, so this row is in the feed.
  insertUser(4, "four")
  insertPost(21, 4, "escaped timestamp", "2025-01-01T00:00:99.000Z \"q\" \\")

proc sOrphan(h: ptr Sqlite3) =
  insertUser(1, "u1")
  for i in 1 .. 21:
    insertPost(int64(i), 1, "post " & $i, ts(i))
  # id 22 is in the dense window but its user row does not exist: the JOIN drops
  # it, so the dense row scan cannot match the id list and must decline.
  insertPost(22, 999, "orphan", ts(10))

proc main() =
  discard sqlite3_initialize()
  # The scenario DBs are tiny; keep each connection's mmap reservation small.
  putEnv("SQLITE_MMAP_SIZE", "67108864")
  tmpDir = getTempDir() / ("t30a_feed_writer_" & $getCurrentProcessId())
  createDir(tmpDir)
  defer:
    for f in walkFiles(tmpDir / "*"):
      try: removeFile(f) except OSError: discard
    try: removeDir(tmpDir) except OSError: discard

  # schema.sql sits at the repository root (submission/tests -> repo root).
  let src = currentSourcePath().parentDir
  let schemaPath = src.parentDir.parentDir.parentDir / "schema.sql"
  if not fileExists(schemaPath):
    quit("schema.sql not found: " & schemaPath)
  gSchema = readFile(schemaPath)

  runScenario("empty", sEmpty)
  runScenario("one", sOne)
  runScenario("19rows", s19)
  runScenario("20rows", s20)
  runScenario("21rows", s21)
  runScenario("nondense", sNonDense)
  runScenario("reordered", sReordered)
  runScenario("likes", sLikes)
  runScenario("escapes", sEscapes)
  runScenario("orphan", sOrphan)

  echo "FEED_WRITER checks=", checks, " failures=", failures
  if failures != 0: quit(1)
  echo "FEED_WRITER PASS"

main()
