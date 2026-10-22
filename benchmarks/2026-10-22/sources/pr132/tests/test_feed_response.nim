## test_feed_response.nim: full-response byte proof for the direct feed writer.
##
## `db.writeFeedResponse` builds the GET /feed response in place: it reserves
## head room, writes the body there with `writeFeedJson`, shifts the body left
## and formats the head. This test compares the COMPLETE response bytes (head +
## body) it appends against `http.addResponse(200, writeFeedJson(body))` for
## both Connection tokens, and against a pipelined mix of generic and feed
## responses on one output buffer (multiple feeds, non-zero start offset, a
## closing response at the end).
##
## The DB is built from the repository schema in a temp dir; the feed body is
## produced by the production `writeFeedJson` for both the expected and actual
## bytes, so the body is not re-implemented here - this test isolates framing.

import std/[os, strutils]

import ../src/sqlite3
import ../src/db
import ../src/http

var checks = 0
var failures = 0

proc compare(name, want, got: string) =
  inc checks
  if want == got:
    echo "PASS ", name
  else:
    inc failures
    echo "FAIL ", name
    echo "  want (", want.len, " B): ", escape(want)
    echo "  got  (", got.len, " B): ", escape(got)
    quit(1)

proc execSql(h: ptr Sqlite3; sql: string) =
  let rc = sqlite3_exec(h, sql.cstring, nil, nil, nil)
  if rc != SQLITE_OK:
    quit("sqlite3_exec failed (rc=" & $rc & "): " & $sqlite3_errmsg(h))

proc insertUser(h: ptr Sqlite3; id: int64; name: string) =
  var stmt: ptr Sqlite3Stmt
  let rc = sqlite3_prepare_v3(h,
    "INSERT INTO users(id, username) VALUES(?, ?)".cstring, -1,
    SQLITE_PREPARE_PERSISTENT, addr stmt, nil)
  if rc != SQLITE_OK: quit("prepare user failed: " & $sqlite3_errmsg(h))
  discard sqlite3_bind_int64(stmt, 1, id)
  discard sqlite3_bind_text(stmt, 2, name.cstring, name.len.cint, SQLITE_TRANSIENT)
  if sqlite3_step(stmt) != SQLITE_DONE:
    quit("insert user failed: " & $sqlite3_errmsg(h))
  discard sqlite3_finalize(stmt)

proc insertPost(h: ptr Sqlite3; id, userId: int64; body, createdAt: string) =
  var stmt: ptr Sqlite3Stmt
  let rc = sqlite3_prepare_v3(h,
    "INSERT INTO posts(id, user_id, body, created_at) VALUES(?, ?, ?, ?)".cstring,
    -1, SQLITE_PREPARE_PERSISTENT, addr stmt, nil)
  if rc != SQLITE_OK: quit("prepare post failed: " & $sqlite3_errmsg(h))
  discard sqlite3_bind_int64(stmt, 1, id)
  discard sqlite3_bind_int64(stmt, 2, userId)
  discard sqlite3_bind_text(stmt, 3, body.cstring, body.len.cint, SQLITE_TRANSIENT)
  discard sqlite3_bind_text(stmt, 4, createdAt.cstring, createdAt.len.cint,
                            SQLITE_TRANSIENT)
  if sqlite3_step(stmt) != SQLITE_DONE:
    quit("insert post failed: " & $sqlite3_errmsg(h))
  discard sqlite3_finalize(stmt)

proc insertLike(h: ptr Sqlite3; userId, postId: int64) =
  var stmt: ptr Sqlite3Stmt
  let rc = sqlite3_prepare_v3(h,
    "INSERT INTO likes(user_id, post_id) VALUES(?, ?)".cstring, -1,
    SQLITE_PREPARE_PERSISTENT, addr stmt, nil)
  if rc != SQLITE_OK: quit("prepare like failed: " & $sqlite3_errmsg(h))
  discard sqlite3_bind_int64(stmt, 1, userId)
  discard sqlite3_bind_int64(stmt, 2, postId)
  if sqlite3_step(stmt) != SQLITE_DONE:
    quit("insert like failed: " & $sqlite3_errmsg(h))
  discard sqlite3_finalize(stmt)

proc main() =
  # The bundled amalgamation is compiled with SQLITE_OMIT_AUTOINIT.
  discard sqlite3_initialize()
  let src = currentSourcePath().parentDir
  let schemaPath = src.parentDir.parentDir.parentDir / "schema.sql"
  if not fileExists(schemaPath):
    quit("schema.sql not found: " & schemaPath)
  let schema = readFile(schemaPath)

  let tmpDir = getTempDir() / ("t30b_feed_response_" & $getCurrentProcessId())
  createDir(tmpDir)
  defer:
    for f in walkFiles(tmpDir / "*"):
      try: removeFile(f) except OSError: discard
    try: removeDir(tmpDir) except OSError: discard
  let path = tmpDir / "feed.db"

  var h: ptr Sqlite3
  let rc = sqlite3_open_v2(path.cstring, addr h,
    SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE, nil)
  if rc != SQLITE_OK: quit("open " & path & " failed (rc=" & $rc & ")")
  execSql(h, schema)
  insertUser(h, 1, "u1")
  insertUser(h, 2, "café \"q\" \\")
  # Escapes + real content, dense ids so the direct feed writer runs.
  insertPost(h, 1, 1, "plain", "2025-01-01T00:00:01.000Z")
  insertPost(h, 2, 1, "quote \" backslash \\ and\nnewline\t", "2025-01-01T00:00:02.000Z")
  insertPost(h, 3, 2, "café ✓ Привет 日本語", "2025-01-01T00:00:03.000Z")
  insertLike(h, 2, 2)
  discard sqlite3_close_v2(h)

  let db = openDb(path)
  var body = ""
  db.writeFeedJson(body)
  echo "# feed body bytes=", body.len
  if body.len == 0: quit("empty feed body")

  # 1. Single response, both Connection tokens, exact full bytes.
  for keepAlive in [true, false]:
    let token = if keepAlive: "keep-alive" else: "close"
    var want = ""
    want.addResponse(200, body, keepAlive)
    var got = ""
    db.writeFeedResponse(got, keepAlive)
    compare("full response Connection: " & token, want, got)

    # Spelled out independently (not via addResponse) so a shared framing bug
    # cannot hide: no Date, exactly these headers, decimal Content-Length.
    let expectedHead =
      "HTTP/1.1 200 OK\r\n" &
      "Content-Type: application/json\r\n" &
      "Content-Length: " & $body.len & "\r\n" &
      "Connection: " & token & "\r\n\r\n"
    compare("head Connection: " & token, expectedHead,
            got[0 ..< expectedHead.len])
    compare("body Connection: " & token, body,
            got[expectedHead.len ..< got.len])

  # 2. Pipelined output on one buffer: existing generic bytes, two keep-alive
  #    feeds at a non-zero start offset, then a closing feed.
  var want = ""
  want.addResponse(200, """{"status":"ok"}""", true)
  want.addResponse(200, body, true)
  want.addResponse(200, body, true)
  want.addResponse(200, body, false)
  var got = ""
  got.addResponse(200, """{"status":"ok"}""", true)
  db.writeFeedResponse(got, true)
  db.writeFeedResponse(got, true)
  db.writeFeedResponse(got, false)
  compare("pipelined generic + 2 keep-alive feeds + close feed", want, got)

  echo "FEED_RESPONSE checks=", checks, " failures=", failures
  if failures != 0: quit(1)
  echo "FEED_RESPONSE PASS"

main()
