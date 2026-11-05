import Feed.Bytes
import Feed.Http

/-!
# The specification

SPEC.md and schema.sql as plain Lean: the tables as lists of rows, and what each endpoint
answers. Nothing here is executed by the server; the handler (`Feed/Handler.lean`) is proved to
compute these functions (`Feed/Proofs/`).

Text is kept as the stored UTF-8 bytes (`List UInt8`), which is what SQLite returns and what the
API sends (`created_at` "as stored", usernames and bodies as stored, escaped for JSON).
-/
namespace Feed.Spec

structure User where
  id : Nat
  name : List UInt8
  deriving DecidableEq, Repr, Inhabited

structure Post where
  id : Nat
  userId : Nat
  body : List UInt8
  createdAt : List UInt8
  deriving DecidableEq, Repr, Inhabited

structure Like where
  userId : Nat
  postId : Nat
  deriving DecidableEq, Repr, Inhabited

/-- The database: each table as its rows. `clock` is the time of the batch's write phase in the
format of the column default, `strftime('%Y-%m-%dT%H:%M:%fZ','now')`: one clock reading per write
phase, the `created_at` of every post the phase inserts (`runtime/db.c` takes the time at the
phase's first insert and reuses it, where the column default would read it at each statement). -/
structure DB where
  users : List User
  posts : List Post
  likes : List Like
  clock : List UInt8
  deriving Inhabited

/-! ## Reading -/

/-- SQLite's BINARY collation on TEXT: bytewise lexicographic order. -/
def textLt : List UInt8 → List UInt8 → Bool
  | [], [] => false
  | [], _ :: _ => true
  | _ :: _, [] => false
  | a :: as, b :: bs => a < b || (a == b && textLt as bs)

/-- `ORDER BY created_at DESC, id DESC`: whether `a` may come before `b`. -/
def newerEq (a b : Post) : Bool :=
  textLt b.createdAt a.createdAt || (b.createdAt == a.createdAt && b.id ≤ a.id)

/-- The posts in `(created_at DESC, id DESC)` order. -/
def DB.sorted (db : DB) : List Post := db.posts.mergeSort newerEq

def DB.user? (db : DB) (uid : Nat) : Option User := db.users.find? (·.id == uid)
def DB.post? (db : DB) (pid : Nat) : Option Post := db.posts.find? (·.id == pid)

/-- `(SELECT count(*) FROM likes l WHERE l.post_id = p.id)` -/
def DB.likeCount (db : DB) (pid : Nat) : Nat := db.likes.countP (·.postId == pid)

/-- A post object of the API. -/
structure View where
  id : Nat
  body : List UInt8
  createdAt : List UInt8
  author : List UInt8
  likes : Nat
  deriving DecidableEq, Repr, Inhabited

/-- `posts p JOIN users u ON u.id = p.user_id`, with the like count: a post whose user row is
missing has no view (the inner join drops it). -/
def DB.view (db : DB) (p : Post) : Option View :=
  (db.user? p.userId).map fun u => ⟨p.id, p.body, p.createdAt, u.name, db.likeCount p.id⟩

/-- `GET /feed`: `... ORDER BY p.created_at DESC, p.id DESC LIMIT 20`. -/
def DB.feed (db : DB) : List View := (db.sorted.filterMap db.view).take 20

/-- `GET /posts/:id`: `... WHERE p.id = ?`. -/
def DB.getPost (db : DB) (pid : Nat) : Option View := (db.post? pid).bind db.view

/-! ## Writing -/

/-- SQLite's rowid for an insert without an explicit one: one more than the largest in use. -/
def DB.nextPostId (db : DB) : Nat := (db.posts.map (·.id)).foldl max 0 + 1

/-- `INSERT INTO posts (user_id, body) VALUES (?, ?) RETURNING id, created_at` -/
def DB.insertPost (db : DB) (uid : Nat) (body : List UInt8) : Post × DB :=
  let p : Post := ⟨db.nextPostId, uid, body, db.clock⟩
  (p, { db with posts := db.posts ++ [p] })

/-- `INSERT INTO likes (user_id, post_id) VALUES (?, ?) ON CONFLICT (user_id, post_id) DO NOTHING`:
whether the like was already there. -/
def DB.insertLike (db : DB) (uid pid : Nat) : Bool × DB :=
  if db.likes.any (fun l => l.userId == uid && l.postId == pid) then (true, db)
  else (false, { db with likes := db.likes ++ [⟨uid, pid⟩] })

/-! ## Bytes on the wire -/

/-- The UTF-8 bytes of a literal. -/
def lit (s : String) : List UInt8 := s.toUTF8.data.toList

/-- The decimal digits of a number, as JSON writes an integer. -/
def digits (n : Nat) : List UInt8 := lit (toString n)

/-- A post object: `{"id":…,"body":…,"created_at":…,"author":…,"like_count":…}`, the strings
escaped as `JSON.stringify` does (`Feed.escape`). -/
def viewJson (v : View) : List UInt8 :=
  lit "{\"id\":" ++ digits v.id ++ lit ",\"body\":\"" ++ escape v.body ++ lit "\",\"created_at\":\"" ++
  escape v.createdAt ++ lit "\",\"author\":\"" ++ escape v.author ++ lit "\",\"like_count\":" ++
  digits v.likes ++ lit "}"

/-- Elements separated by commas. -/
def commaSep : List (List UInt8) → List UInt8
  | [] => []
  | [x] => x
  | x :: xs => x ++ [0x2c] ++ commaSep xs

/-- `{"posts":[…]}` -/
def feedJson (vs : List View) : List UInt8 :=
  lit "{\"posts\":[" ++ commaSep (vs.map viewJson) ++ lit "]}"

/-- `{"post":…}` -/
def postJson (v : View) : List UInt8 := lit "{\"post\":" ++ viewJson v ++ lit "}"

/-- `{"error":"…"}` -/
def errJson (msg : String) : List UInt8 := lit "{\"error\":\"" ++ lit msg ++ lit "\"}"

/-- `{"liked":true,"already_liked":…,"post_id":…}` -/
def likeJson (already : Bool) (pid : Nat) : List UInt8 :=
  lit "{\"liked\":true,\"already_liked\":" ++ lit (if already then "true" else "false") ++ lit ",\"post_id\":" ++
  digits pid ++ lit "}"

/-! ## Responses on the wire -/

/-- The status line's code and reason phrase for each status the API uses; any other number is
answered as a 500. -/
def statusPhrase : Nat → String
  | 200 => "200 OK"
  | 201 => "201 Created"
  | 400 => "400 Bad Request"
  | 401 => "401 Unauthorized"
  | 404 => "404 Not Found"
  | 413 => "413 Payload Too Large"
  | 431 => "431 Request Header Fields Too Large"
  | 503 => "503 Service Unavailable"
  | _ => "500 Internal Server Error"

/-- A complete response: the status line, `Content-Type` and `Content-Length`, `Connection: close`
when the connection closes after it, then the body. -/
def response (status : Nat) (body : List UInt8) (close : Bool) : List UInt8 :=
  lit ("HTTP/1.1 " ++ statusPhrase status ++ "\r\nContent-Type: application/json\r\nContent-Length: ") ++
  digits body.length ++ lit (if close then "\r\nConnection: close\r\n\r\n" else "\r\n\r\n") ++ body

/-- `GET /health` after `SELECT 1` succeeded, `uptime` seconds after the start. -/
def healthJson (uptime : Nat) : List UInt8 :=
  lit "{\"status\":\"ok\",\"db\":\"ok\",\"uptime_s\":" ++ digits uptime ++ lit "}"

/-! ## Requests -/

/-- The value of a list of decimal digits, if every byte is one (`acc` so far). -/
def decimal : List UInt8 → Nat → Option Nat
  | [], acc => some acc
  | c :: cs, acc => if 0x30 ≤ c ∧ c ≤ 0x39 then decimal cs (acc * 10 + (c - 0x30).toNat) else none

/-- A `:id` path segment that is a positive integer, written in decimal digits. -/
def postId (seg : List UInt8) : Option Nat :=
  match decimal seg 0 with
  | some (n + 1) => some (n + 1)
  | _ => none

/-- `l` without the prefix `pre`, if it starts with it. -/
def dropPrefix (pre l : List UInt8) : Option (List UInt8) :=
  if l.take pre.length = pre then some (l.drop pre.length) else none

/-- `l` without the suffix `suf`, if it ends with it. -/
def dropSuffix (suf l : List UInt8) : Option (List UInt8) :=
  if l.length ≥ suf.length ∧ l.drop (l.length - suf.length) = suf then some (l.take (l.length - suf.length)) else none

/-- What a request asks for. A `:id` that is not a positive integer is `none`. -/
inductive Route where
  | health | feed | create | notFound
  | post (id : Option Nat)
  | like (id : Option Nat)
  deriving DecidableEq, Repr

/-- The route of a request, from its method and its path (the query string removed): the five
endpoints, `:id` being one non-empty path segment. -/
def route : Http.Method → List UInt8 → Route
  | .get, p =>
    if p = lit "/feed" then .feed
    else if p = lit "/health" then .health
    else match dropPrefix (lit "/posts/") p with
      | some seg => if seg ≠ [] ∧ 0x2f ∉ seg then .post (postId seg) else .notFound
      | none => .notFound
  | .post, p =>
    if p = lit "/posts" then .create
    else match (dropPrefix (lit "/posts/") p).bind (dropSuffix (lit "/like")) with
      | some seg => if seg ≠ [] ∧ 0x2f ∉ seg then .like (postId seg) else .notFound
      | none => .notFound
  | .other, _ => .notFound

/-! ## The writes, with their answers (status and body) -/

/-- `POST /posts/:id/like` as user `uid`: 404 if there is no such post; otherwise one like per
user and post, 201 the first time and 200 on repeats. -/
def DB.like (db : DB) (uid pid : Nat) : (Nat × List UInt8) × DB :=
  match db.post? pid with
  | none => ((404, errJson "post not found"), db)
  | some _ =>
    let (had, db') := db.insertLike uid pid
    ((if had then 200 else 201, likeJson had pid), db')

/-- `POST /posts` as user `uid` named `name`: the new post, its author the token's username and no
likes yet. -/
def DB.create (db : DB) (uid : Nat) (body name : List UInt8) : (Nat × List UInt8) × DB :=
  let (p, db') := db.insertPost uid body
  ((201, postJson ⟨p.id, body, p.createdAt, name, 0⟩), db')

end Feed.Spec
