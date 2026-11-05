// Twelve challenge — feed API handlers.
//
// All response bodies go through std/json:emit (schema-directed writer,
// correct escaping); all request JSON through std/json:parse (generated
// parser, no DOM). SQLite access is libs/sqlite3's pooled connections with
// RETURNING for the write paths.

import orisha
import std/env
import std/json
import std/string
import libs/sqlite3
import twelve/support

pub tor health { req: *orisha:Request } -> orisha:Response
pub tor feed { req: *orisha:Request } -> orisha:Response
pub tor get-post { req: *orisha:Request, id: string } -> orisha:Response
pub tor create-post { req: *orisha:Request } -> orisha:Response
pub tor like-post { req: *orisha:Request, id: string } -> orisha:Response

// ---- shared bits -----------------------------------------------------------

tor err-resp { status: u16, msg: string } -> orisha:Response
err-resp -> { status, body: msg, content_type: "application/json", body_static: true }

tor err-internal {} -> orisha:Response
err-internal -> { status: 500, body: "{\"error\":\"internal server error\"}", content_type: "application/json", body_static: true }

tor bad-id {} -> orisha:Response
bad-id -> { status: 400, body: "{\"error\":\"invalid post id\"}", content_type: "application/json", body_static: true }

tor no-post {} -> orisha:Response
no-post -> { status: 404, body: "{\"error\":\"post not found\"}", content_type: "application/json", body_static: true }

tor malformed-body {} -> orisha:Response
malformed-body -> { status: 400, body: "{\"error\":\"malformed JSON body\"}", content_type: "application/json", body_static: true }

tor body-required {} -> orisha:Response
body-required -> { status: 400, body: "{\"error\":\"body is required\"}", content_type: "application/json", body_static: true }

tor body-too-long {} -> orisha:Response
body-too-long -> { status: 400, body: "{\"error\":\"body must be at most 500 characters\"}", content_type: "application/json", body_static: true }

// Rebinds that mint typed locals out of opaque label-payload fields — emit
// resolves bindings by declared type, and destructure fields arrive opaque.
tor uname { s: string } -> string
uname -> s

// An emitted string becomes the response's owned body: copy it into a
// String, discharge the emit obligation, hand the detached bytes over.
tor emit-response { out: string<!std/json:emitted>, status: u16 } -> orisha:Response
emit-response = std/string:from-page(text: "")
| ok h |> std/string:take(s: h): b
    |> std/string:append(s: b, text: out)
        | ok |> std/json:emit.free(text: out) |> std/string:detach(s: b): bytes -> { status, body: bytes, content_type: "application/json", body_allocated: true }
        | err _ |> std/json:emit.free(text: out) |> std/string:free(s: b) |> err-internal(): res -> res
| err _ |> std/json:emit.free(text: out) |> err-internal(): res -> res

// Bearer JWT -> claims or a ready denial response. Auth runs before the id
// check on routes that carry one (spec: auth first, then the id).
tor authed { req: *orisha:Request }
| ok { sub: i64, username: string }
| denied orisha:Response

authed = orisha:header(req, name: "authorization"): h
|> std/env:get.or(name: "JWT_SECRET", default: "twelve-dollar-challenge"): sec
|> twelve/support:jwt-auth(auth: h, secret: sec)
    | ok a => ok { a.sub, a.username }
    | missing |> err-resp(status: 401, msg: "{\"error\":\"missing bearer token\"}"): r => denied r
    | invalid |> err-resp(status: 401, msg: "{\"error\":\"invalid or expired token\"}"): r => denied r
    | badpayload |> err-resp(status: 401, msg: "{\"error\":\"invalid token payload\"}"): r => denied r

// ---- init ------------------------------------------------------------------

orisha:init = twelve/support:boot-mark()
|> std/env:get.or(name: "SQLITE_PATH", default: "feed.db"): dbp
    |> libs/sqlite3:open.pooled(path: dbp)
        | db d |> libs/sqlite3:close.pooled(conn: d) => ready
        | err _ => failed "sqlite open failed"

// ---- GET /health ------------------------------------------------------------

health = std/env:get.or(name: "SQLITE_PATH", default: "feed.db"): dbp
|> libs/sqlite3:open.pooled(path: dbp)
    | db d |> libs/sqlite3:exec(conn: d, sql: "SELECT 1")
        | ok |> libs/sqlite3:close.pooled(conn: d) |> twelve/support:uptime-s(): up
            |> std/json:emit(value: { status: "ok", db: "ok", uptime_s: up }): out
            |> emit-response(out, status: 200): res -> res
        | err _ |> std/json:emit(value: { status: "degraded", db: "unreachable", error: "query failed" }): out
            |> libs/sqlite3:close.pooled(conn: d) |> emit-response(out, status: 503): res -> res
    | err _ |> std/json:emit(value: { status: "degraded", db: "unreachable", error: "open failed" }): out
        |> emit-response(out, status: 503): res -> res

// ---- GET /feed --------------------------------------------------------------

// Row fragments accumulate ",{post}" each; the leading comma is stripped
// once, at the end, by substring(1) — no separator state crosses rows.
feed = std/env:get.or(name: "SQLITE_PATH", default: "feed.db"): dbp
|> libs/sqlite3:open.pooled(path: dbp)
    | db d |> std/string:from-page(text: "")
        | ok fbv |> std/string:take(s: fbv): fb
            |> libs/sqlite3(conn: d) {
                SELECT p.id, p.body, p.created_at, u.username,
                       (SELECT count(*) FROM likes l WHERE l.post_id = p.id) AS like_count
                  FROM posts p JOIN users u ON u.id = p.user_id
                 ORDER BY p.created_at DESC, p.id DESC LIMIT 20
            }
            ! row r |> libs/sqlite3:col.int(stmt: r, index: 0): rid
                |> libs/sqlite3:col.text(stmt: r, index: 1): rb
                |> libs/sqlite3:col.text(stmt: r, index: 2): rc
                |> libs/sqlite3:col.text(stmt: r, index: 3): ra
                |> libs/sqlite3:col.int(stmt: r, index: 4): rl
                |> std/string:append(s: fb, text: ",")
                    | ok |> std/json:emit(value: { id: rid, body: rb, created_at: rc, author: ra, like_count: rl }): pout
                        |> std/string:append(s: fb, text: pout)
                            | ok |> std/json:emit.free(text: pout)
                            | err _ |> std/json:emit.free(text: pout)
                    | err _ |> _
            | done d2 |> feed-finish(buf: fb, conn: d2): r -> r
            | err e |> std/string:free(s: fb) |> libs/sqlite3:close.pooled(e.conn) |> err-internal(): res -> res
        | err _ |> libs/sqlite3:close.pooled(conn: d) |> err-internal(): res -> res
    | err _ |> err-internal(): res -> res

tor feed-empty {} -> orisha:Response
feed-empty -> { status: 200, body: "{\"posts\":[]}", content_type: "application/json", body_static: true }

tor feed-finish { buf: *std/string:String<!instance>, conn: *libs/sqlite3:Connection<!opened> } -> orisha:Response
feed-finish = std/string:len(s: buf): n
|> libs/sqlite3:close.pooled(conn)
|> if(n == 0)
    | then |> std/string:free(s: buf) |> feed-empty(): r -> r
    | else |> std/string:substring(s: buf, start: 1, end: n)
        | ok sub |> feed-wrap(sub, buf): r -> r
        | err _ |> std/string:free(s: buf) |> err-internal(): res -> res

tor feed-wrap { sub: *std/string:String<!view>, buf: *std/string:String<!instance> } -> orisha:Response
feed-wrap = std/string:from-page(text: "{\"posts\":[")
| ok env0 |> std/string:take(s: env0): env
    |> std/string:append(s: env, text: sub.data)
        | ok |> std/string:append(s: env, text: "]}")
            | ok |> std/string:free(s: sub) |> std/string:free(s: buf) |> std/string:detach(s: env): bytes -> { status: 200, body: bytes, content_type: "application/json", body_allocated: true }
            | err _ |> std/string:free(s: sub) |> std/string:free(s: buf) |> std/string:free(s: env) |> err-internal(): res -> res
        | err _ |> std/string:free(s: sub) |> std/string:free(s: buf) |> std/string:free(s: env) |> err-internal(): res -> res
| err _ |> std/string:free(s: sub) |> std/string:free(s: buf) |> err-internal(): res -> res

// ---- GET /posts/:id ---------------------------------------------------------

get-post = twelve/support:pos-id(s: id)
| bad |> bad-id(): r -> r
| ok pid |> std/env:get.or(name: "SQLITE_PATH", default: "feed.db"): dbp
    |> libs/sqlite3:open.pooled(path: dbp)
        | db d |> libs/sqlite3:query(conn: d)[SQL]{
                SELECT p.id, p.body, p.created_at, u.username,
                       (SELECT count(*) FROM likes l WHERE l.post_id = p.id) AS like_count
                  FROM posts p JOIN users u ON u.id = p.user_id
                 WHERE p.id = {{ pid:d }}
            }
            | row r |> libs/sqlite3:scol.int(stmt: r, index: 0): pid2
                |> libs/sqlite3:scol.text(stmt: r, index: 1): pb
                |> libs/sqlite3:scol.text(stmt: r, index: 2): pc
                |> libs/sqlite3:scol.text(stmt: r, index: 3): pa
                |> libs/sqlite3:scol.int(stmt: r, index: 4): pl
                |> std/json:emit(value: { post: { id: pid2, body: pb, created_at: pc, author: pa, like_count: pl } }): out
                |> libs/sqlite3:finalize.stmt(stmt: r): cx
                |> libs/sqlite3:close.pooled(conn: cx) |> emit-response(out, status: 200): res -> res
            | empty c |> libs/sqlite3:close.pooled(conn: c) |> no-post(): r -> r
            | err e |> libs/sqlite3:close.pooled(e.conn) |> err-internal(): res -> res
        | err _ |> err-internal(): res -> res

// ---- POST /posts ------------------------------------------------------------

create-post = authed(req)
| denied r -> r
| ok a |> uname(s: a.username): author |> orisha:body(req): bd
    |> std/json:parse(input: bd orelse "")
        | malformed _ |> malformed-body(): r -> r
        | ok _ |> std/json:parse(input: bd orelse "")
            | malformed _ |> body-required(): r -> r
            | ok { body: ?string } |> twelve/support:trim-body(s: body orelse "")
                | required |> body-required(): r -> r
                | too-long |> body-too-long(): r -> r
                | ok t |> std/env:get.or(name: "SQLITE_PATH", default: "feed.db"): dbp
                    |> libs/sqlite3:open.pooled(path: dbp)
                        | db d |> libs/sqlite3:query(conn: d)[SQL]{
                                INSERT INTO posts (user_id, body) VALUES ({{ a.sub:d }}, {{ t:s }})
                                RETURNING id, created_at
                            }
                            | row r |> libs/sqlite3:scol.int(stmt: r, index: 0): nid
                                |> libs/sqlite3:scol.text(stmt: r, index: 1): nts
                                |> std/json:emit(value: { post: { id: nid, body: t, created_at: nts, author, like_count: 0 } }): out
                                |> libs/sqlite3:finalize.stmt(stmt: r): cx
                                |> libs/sqlite3:close.pooled(conn: cx) |> emit-response(out, status: 201): res -> res
                            | empty c |> libs/sqlite3:close.pooled(conn: c) |> err-internal(): res -> res
                            | err e |> libs/sqlite3:close.pooled(e.conn) |> err-internal(): res -> res
                        | err _ |> err-internal(): res -> res

// ---- POST /posts/:id/like ---------------------------------------------------

// INSERT ... RETURNING 1 yields a row only when the like actually landed:
// a row means 201. Empty means either a repeat like or a missing post —
// one existence query tells which.
like-post = authed(req)
| denied r -> r
| ok a |> twelve/support:pos-id(s: id)
    | bad |> bad-id(): r -> r
    | ok pid |> std/env:get.or(name: "SQLITE_PATH", default: "feed.db"): dbp
        |> libs/sqlite3:open.pooled(path: dbp)
            | db d |> libs/sqlite3:query(conn: d)[SQL]{
                    SELECT 1 FROM posts WHERE id = {{ pid:d }}
                }
                | row r |> libs/sqlite3:finalize.stmt(stmt: r): cx
                    |> libs/sqlite3:query(conn: cx)[SQL]{
                        INSERT INTO likes (user_id, post_id) VALUES ({{ a.sub:d }}, {{ pid:d }})
                        ON CONFLICT (user_id, post_id) DO NOTHING
                        RETURNING 1
                    }
                    | row r2 |> libs/sqlite3:finalize.stmt(stmt: r2): c2
                        |> libs/sqlite3:close.pooled(conn: c2)
                        |> std/json:emit(value: { liked: true, already_liked: false, post_id: pid }): out
                        |> emit-response(out, status: 201): res -> res
                    | empty c2 |> libs/sqlite3:close.pooled(conn: c2)
                        |> std/json:emit(value: { liked: true, already_liked: true, post_id: pid }): out
                        |> emit-response(out, status: 200): res -> res
                    | err e2 |> libs/sqlite3:close.pooled(e2.conn) |> err-internal(): res -> res
                | empty ec |> libs/sqlite3:close.pooled(conn: ec) |> no-post(): r -> r
                | err e |> libs/sqlite3:close.pooled(e.conn) |> err-internal(): res -> res
            | err _ |> err-internal(): res -> res
