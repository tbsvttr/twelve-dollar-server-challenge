import Feed.Bytes
import Feed.Http
import Feed.Json
import Feed.Jwt
import Feed.Store

/-!
# The API

Routing, authentication, validation, the read plans and the response bytes of every endpoint
(SPEC.md). The handler is generic in the storage monad (`Feed.Store`); the server runs it in `IO`,
the proofs run it on the list model.
-/
namespace Feed
open Http

/-! ## Response bytes -/

def lit (s : String) : ByteArray := s.toUTF8

def statusLine : Nat → ByteArray
  | 200 => lit "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "
  | 201 => lit "HTTP/1.1 201 Created\r\nContent-Type: application/json\r\nContent-Length: "
  | 400 => lit "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: "
  | 401 => lit "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nContent-Length: "
  | 404 => lit "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: "
  | 413 => lit "HTTP/1.1 413 Payload Too Large\r\nContent-Type: application/json\r\nContent-Length: "
  | 431 => lit "HTTP/1.1 431 Request Header Fields Too Large\r\nContent-Type: application/json\r\nContent-Length: "
  | 503 => lit "HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\nContent-Length: "
  | _ => lit "HTTP/1.1 500 Internal Server Error\r\nContent-Type: application/json\r\nContent-Length: "

def endHead : ByteArray := lit "\r\n\r\n"
def endHeadClose : ByteArray := lit "\r\nConnection: close\r\n\r\n"

/-- A complete response: status line, headers (with the body's length) and body. -/
def respond (out : ByteArray) (status : Nat) (body : ByteArray) (close : Bool) : ByteArray :=
  let out := if out.size == 0 then ByteArray.emptyWithCapacity (body.size + 160) else out
  let out := Bytes.appendAll out (statusLine status)
  let out := Bytes.appendNat out body.size
  let out := Bytes.appendAll out (if close then endHeadClose else endHead)
  Bytes.appendAll out body

/-- The error messages of SPEC.md, as complete bodies. -/
inductive Err where
  | notFound | invalidId | postNotFound | missingBearer | invalidToken | invalidPayload
  | malformedJson | bodyRequired | bodyTooLong | internal | badRequest | tooLarge | headTooLarge
  deriving BEq, Inhabited

def Err.status : Err → Nat
  | .notFound | .postNotFound => 404
  | .invalidId | .malformedJson | .bodyRequired | .bodyTooLong | .badRequest => 400
  | .missingBearer | .invalidToken | .invalidPayload => 401
  | .internal => 500
  | .tooLarge => 413
  | .headTooLarge => 431

def Err.body : Err → ByteArray
  | .notFound => lit "{\"error\":\"not found\"}"
  | .invalidId => lit "{\"error\":\"invalid post id\"}"
  | .postNotFound => lit "{\"error\":\"post not found\"}"
  | .missingBearer => lit "{\"error\":\"missing bearer token\"}"
  | .invalidToken => lit "{\"error\":\"invalid or expired token\"}"
  | .invalidPayload => lit "{\"error\":\"invalid token payload\"}"
  | .malformedJson => lit "{\"error\":\"malformed JSON body\"}"
  | .bodyRequired => lit "{\"error\":\"body is required\"}"
  | .bodyTooLong => lit "{\"error\":\"body must be at most 500 characters\"}"
  | .internal => lit "{\"error\":\"internal server error\"}"
  | .badRequest => lit "{\"error\":\"bad request\"}"
  | .tooLarge => lit "{\"error\":\"request too large\"}"
  | .headTooLarge => lit "{\"error\":\"request header too large\"}"

def respondErr (out : ByteArray) (e : Err) (close : Bool) : ByteArray := respond out e.status e.body close

/-! ## Post objects -/

def kId : ByteArray := lit "{\"id\":"
def kBody : ByteArray := lit ",\"body\":\""
def kCreated : ByteArray := lit "\",\"created_at\":\""
def kAuthor : ByteArray := lit "\",\"author\":\""
def kLikes : ByteArray := lit "\",\"like_count\":"
def kClose : ByteArray := lit "}"

def kCommaId : ByteArray := lit ",{\"id\":"

/-- `{"id":…,"body":…,"created_at":…,"author":…,"like_count":…}` from stored text, after
`start` (the object's first bytes: `kId`, or `kCommaId` after a previous object). -/
def postJsonAfter (out : ByteArray) (start : @& ByteArray) (id : @& Nat) (src : @& ByteArray) (b c e : @& Nat)
    (names : @& ByteArray) (ns ne : @& Nat) (likes : @& Nat) : ByteArray :=
  let out := Bytes.appendLitNat out start id
  let out := Bytes.appendLitEsc out kBody src b c
  let out := Bytes.appendLitEsc out kCreated src c e
  let out := Bytes.appendLitEsc out kAuthor names ns ne
  let out := Bytes.appendLitNat out kLikes likes
  Bytes.appendAll out kClose

@[inline] def postJson (out : ByteArray) (id : Nat) (src : ByteArray) (b c e : Nat)
    (names : ByteArray) (ns ne : Nat) (likes : Nat) : ByteArray :=
  postJsonAfter out kId id src b c e names ns ne likes

/-! ## Read plans -/

/-- The page size of the feed. -/
def feedSize : Nat := 20

/-- Render the posts of the page that have an author, at most `limit` of them; also how many were
rendered. -/
def renderPage (out : ByteArray) (pg : Page) (limit : Nat) : ByteArray × Nat :=
  go 0 (pg.cols.size / 8) out 0
where
  go (k : Nat) : Nat → ByteArray → Nat → ByteArray × Nat
    | 0, out, n => (out, n)
    | f + 1, out, n =>
      if n ≥ limit then (out, n) else
      let m := pg.cols
      if m[8 * k + 4]! != 1 then go (k + 1) f out n else
      let out := postJsonAfter out (if n == 0 then kId else kCommaId) m[8 * k]! pg.blob m[8 * k + 1]! m[8 * k + 2]! m[8 * k + 3]!
        pg.blob m[8 * k + 5]! m[8 * k + 6]! m[8 * k + 7]!
      go (k + 1) f out (n + 1)

def kPosts : ByteArray := lit "{\"posts\":["
def kPostsEnd : ByteArray := lit "]}"

/-- The feed's body from a page: its posts that have an author, at most 20; also how many it
rendered and how many rows the page had. -/
@[extern "feed_feed_from_page"]
def feedFromPage (body : ByteArray) (pg : @& Page) : ByteArray × Nat × Nat :=
  let (b, n) := renderPage (Bytes.appendAll (Bytes.clear body) kPosts) pg feedSize
  (Bytes.appendAll b kPostsEnd, n, pg.cols.size / 8)

/-- How many rows of the page have an author, at most `limit`: the number of posts `renderPage`
renders from it. -/
@[extern "feed_page_authored"]
def Page.authored (pg : @& Page) (limit : @& Nat) : Nat :=
  go 0 (pg.cols.size / 8) 0
where
  go (k : Nat) : Nat → Nat → Nat
    | 0, n => n
    | f + 1, n =>
      if n ≥ limit then n else
      if pg.cols[8 * k + 4]! != 1 then go (k + 1) f n else go (k + 1) f (n + 1)

/-- The feed's response from a page, appended to `out`: the status line and headers, then the
body `feedFromPage` renders. The C version writes the body in place, after the headers. -/
@[extern "feed_respond_feed"]
def respondFeed (out : ByteArray) (pg : @& Page) (close : Bool) : ByteArray :=
  respond out 200 (feedFromPage ByteArray.empty pg).1 close

/-- `GET /feed`: the first 20 posts in `(created_at DESC, id DESC)` order that have an author
(the join drops a post whose user row is missing; then the next one is taken). The page of the
first `want` posts is answered when it has 20 posts with an author or holds every post;
otherwise twice as many are read. The response is appended to `out`. -/
def feedLoop [Monad m] [Store m] (out : ByteArray) (close : Bool) (want : Nat) : Nat → m ByteArray
  | 0 => return out
  | fuel + 1 => do
    let pg ← Store.feedPage want
    if pg.authored feedSize ≥ feedSize || pg.cols.size / 8 < want then return respondFeed out pg close
    else feedLoop out close (want * 2) fuel

/-- `GET /feed`'s response, appended to `out`. -/
def feedResponse [Monad m] [Store m] (out : ByteArray) (close : Bool) : m ByteArray := feedLoop out close feedSize 64

def kPostWrap : ByteArray := lit "{\"post\":"
def kWrapEnd : ByteArray := lit "}"

/-- A post's body from its page: whether the page has the post with its author row, and then its
body (otherwise the scratch buffer back). -/
def postFromPage (scratch : ByteArray) (id : Nat) (pg : Page) : Bool × ByteArray :=
  if pg.cols.size < 8 || pg.cols[4]! != 1 then (false, scratch) else
  let out := Bytes.appendAll (Bytes.clear scratch) kPostWrap
  let out := postJson out id pg.blob pg.cols[1]! pg.cols[2]! pg.cols[3]! pg.blob pg.cols[5]! pg.cols[6]! pg.cols[7]!
  (true, Bytes.appendAll out kWrapEnd)

/-- Whether a post's page has the post with its author row (what `postFromPage` decides). -/
def postFound (pg : @& Page) : Bool := !(pg.cols.size < 8 || pg.cols[4]! != 1)

/-- A post's response from its page, appended to `out`: the status line and headers, then the
body `postFromPage` renders. The C version writes the body in place, after the headers. -/
@[extern "feed_respond_post"]
def respondPost (out : ByteArray) (id : @& Nat) (pg : @& Page) (close : Bool) : ByteArray :=
  respond out 200 (postFromPage ByteArray.empty id pg).2 close

/-- `GET /posts/:id`: the post with its author and like count, or not found. The response is
appended to `out`. -/
def postResponse [Monad m] [Store m] (out : ByteArray) (id : Nat) (close : Bool) : m ByteArray := do
  let pg ← Store.postPage id
  return if postFound pg then respondPost out id pg close else respondErr out .postNotFound close

/-! ## Requests -/

def pHealth : ByteArray := lit "/health"
def pFeed : ByteArray := lit "/feed"
def pPosts : ByteArray := lit "/posts"
def pPostsSlash : ByteArray := lit "/posts/"
def pLike : ByteArray := lit "/like"

inductive PostId where
  | ok (n : Nat)
  | invalid
  deriving Inhabited

/-- The `:id` path segment: a positive decimal integer. -/
def parseId (a : ByteArray) (lo hi : Nat) : PostId :=
  match go lo (hi - lo) 0 with
  | some (n + 1) => if lo < hi then .ok (n + 1) else .invalid
  | _ => .invalid
where
  go (i : Nat) : Nat → Nat → Option Nat
    | 0, acc => some acc
    | f + 1, acc =>
      let c := a.get! i
      if 0x30 ≤ c && c ≤ 0x39 then go (i + 1) f (acc * 10 + (c - 0x30).toNat) else none

inductive Route where
  | health | feed | post (id : PostId) | create | like (id : PostId) | notFound
  deriving Inhabited

@[extern "feed_route"]
def route (a : @& ByteArray) (r : @& Req) : Route :=
  let hi := min r.pathHi a.size
  let lo := min r.pathLo hi
  match r.method with
  | .get =>
    if eqAt a lo hi pFeed then .feed
    else if eqAt a lo hi pHealth then .health
    else if hi - lo > 7 && eqAt a lo (lo + 7) pPostsSlash && Bytes.findByte a 0x2f (lo + 7) hi == hi then .post (parseId a (lo + 7) hi)
    else .notFound
  | .post =>
    if eqAt a lo hi pPosts then .create
    else if hi - lo > 12 && eqAt a lo (lo + 7) pPostsSlash && eqAt a (hi - 5) hi pLike
      && Bytes.findByte a 0x2f (lo + 7) (hi - 5) == hi - 5 then .like (parseId a (lo + 7) (hi - 5))
    else .notFound
  | .other => .notFound

def bearer : ByteArray := lit "Bearer "

/-- Authentication: the user id and username of a valid token, or the error. -/
def authenticate (key : Hmac.Key) (now : Nat) (a : ByteArray) (r : Req) : Except Err (Nat × ByteArray) :=
  if !r.hasAuth || r.authHi < r.authLo + 7 || !eqAt a r.authLo (r.authLo + 7) bearer then .error .missingBearer
  else match Jwt.verify key now a (r.authLo + 7) r.authHi with
    | .invalid => .error .invalidToken
    | .badPayload => .error .invalidPayload
    | .ok uid name => .ok (uid, name)

/-! ## Post bodies -/

/-- The code point of the UTF-8 sequence starting at `i` and its length (valid UTF-8 assumed, as
produced by `Json.decodeString`). -/
def cpAt (s : ByteArray) (i : Nat) : Nat × Nat :=
  let b := (s.get! i).toNat
  if b < 0x80 then (b, 1)
  else if b < 0xe0 then ((b % 32) * 64 + (s.get! (i + 1)).toNat % 64, 2)
  else if b < 0xf0 then (((b % 16) * 64 + (s.get! (i + 1)).toNat % 64) * 64 + (s.get! (i + 2)).toNat % 64, 3)
  else ((((b % 8) * 64 + (s.get! (i + 1)).toNat % 64) * 64 + (s.get! (i + 2)).toNat % 64) * 64 + (s.get! (i + 3)).toNat % 64, 4)

/-- `String.prototype.trim`'s whitespace: WhiteSpace and LineTerminator code points. -/
def jsSpace (c : Nat) : Bool :=
  (9 ≤ c && c ≤ 13) || c == 32 || c == 0xa0 || c == 0x1680 || (0x2000 ≤ c && c ≤ 0x200a) ||
  c == 0x2028 || c == 0x2029 || c == 0x202f || c == 0x205f || c == 0x3000 || c == 0xfeff

/-- The start of the last UTF-8 sequence ending before `e`. -/
def prevStart (s : ByteArray) (e : Nat) : Nat :=
  go (e - 1) 3
where
  go (i : Nat) : Nat → Nat
    | 0 => i
    | f + 1 => if i > 0 && (s.get! i) &&& 0xc0 == 0x80 then go (i - 1) f else i

/-- Trim JS whitespace from both ends of valid UTF-8: the remaining range. -/
def trimRange (s : ByteArray) : Nat × Nat :=
  let lo := front 0 s.size
  (lo, back lo s.size s.size)
where
  front (i : Nat) : Nat → Nat
    | 0 => i
    | f + 1 => if i < s.size then (let (c, n) := cpAt s i; if jsSpace c then front (i + n) f else i) else i
  back (lo e : Nat) : Nat → Nat
    | 0 => e
    | f + 1 => if e > lo then (let p := prevStart s e; if jsSpace (cpAt s p).1 then back lo p f else e) else e

/-- The number of code points of valid UTF-8 `s[lo, hi)`. -/
def codePoints (s : ByteArray) (lo hi : Nat) : Nat :=
  go lo (hi - lo) 0
where
  go (i : Nat) : Nat → Nat → Nat
    | 0, n => n
    | f + 1, n => go (i + 1) f (if (s.get! i) &&& 0xc0 == 0x80 then n else n + 1)

def kBodyKey : ByteArray := lit "body"

/-- The trimmed post body of a `POST /posts` request. A text that starts with U+0000 is answered
500: SQLite's `length` counts the characters before the first NUL, so schema.sql's
`CHECK (length(body) BETWEEN 1 AND 500)` refuses it and the insert would add no row (SPEC.md's
"anything else"). -/
def postText (a : ByteArray) (r : Req) : Except Err ByteArray :=
  match Json.parseTop a r.bodyLo r.bodyHi #[kBodyKey] with
  | .malformed => .error .malformedJson
  | .notObject => .error .bodyRequired
  | .object fs =>
    let f := fs[0]!
    if f.kind != .str then .error .bodyRequired else
    let s := Json.decodeString a f.lo f.hi
    let (lo, hi) := trimRange s
    if lo ≥ hi then .error .bodyRequired
    else if codePoints s lo hi > 500 then .error .bodyTooLong
    else if s.get! lo == 0 then .error .internal
    else .ok (s.extract lo hi)

/-! ## One request -/

/-- A write waiting for the batch's write phase. -/
inductive Write where
  | like (uid pid : Nat)
  | create (uid : Nat) (body name : ByteArray)
  deriving Inhabited

structure Env where
  key : Hmac.Key
  now : Nat
  uptime : Nat
  /-- whether this batch may write (the transport pauses writes while the log is checkpointed) -/
  writesOk : Bool

def kHealth : ByteArray := lit "{\"status\":\"ok\",\"db\":\"ok\",\"uptime_s\":"
def kDegraded : ByteArray := lit "{\"status\":\"degraded\",\"db\":\"unreachable\",\"error\":\"SELECT 1 failed\"}"

/-- The outcome of one request: answers so far (`out`), the scratch buffer, and the write the
request asks for, if it is one. -/
structure Step where
  out : ByteArray
  scratch : ByteArray
  write : Option Write
  deriving Inhabited

/-- Handle one request. A read is answered from the batch's snapshot and appended to `out`. -/
@[inline] def decide [Monad m] [Store m] (env : Env) (a : ByteArray) (r : Req) (out scratch : ByteArray) : m Step := do
  let err (e : Err) : Step := ⟨respondErr out e r.close, scratch, none⟩
  match route a r with
  | .feed => return ⟨← feedResponse out r.close, scratch, none⟩
  | .post .invalid => return err .invalidId
  | .post (.ok id) => return ⟨← postResponse out id r.close, scratch, none⟩
  | .health =>
    if ← Store.health then
      let b := Bytes.appendAll (Bytes.appendNat (Bytes.appendAll (Bytes.clear scratch) kHealth) env.uptime) kWrapEnd
      return ⟨respond out 200 b r.close, b, none⟩
    else return ⟨respond out 503 kDegraded r.close, scratch, none⟩
  | .create =>
    match authenticate env.key env.now a r with
    | .error e => return err e
    | .ok (uid, name) =>
      match postText a r with
      | .error e => return err e
      | .ok text => return ⟨out, scratch, some (.create uid text name)⟩
  | .like id =>
    match authenticate env.key env.now a r with
    | .error e => return err e
    | .ok (uid, _) =>
      match id with
      | .invalid => return err .invalidId
      | .ok pid => return ⟨out, scratch, some (.like uid pid)⟩
  | .notFound => return err .notFound

def kLiked : ByteArray := lit "{\"liked\":true,\"already_liked\":"
def kLikedPost : ByteArray := lit ",\"post_id\":"
def kTrue : ByteArray := lit "true"
def kFalse : ByteArray := lit "false"
def kZeroLikes : ByteArray := lit "\",\"like_count\":0}}"

/-- Perform a write (in the batch's write phase): its status and body. -/
def perform [Monad m] [Store m] : Write → m (Nat × ByteArray)
  | .like uid pid => do
    match ← Store.postExists pid with
    | 0 => return (404, Err.postNotFound.body)
    | 1 =>
      match ← Store.insertLike uid pid with
      | 2 => return (500, Err.internal.body)
      | r =>
        let b := Bytes.appendAll (ByteArray.emptyWithCapacity 64) kLiked
        let b := Bytes.appendAll b (if r == 0 then kTrue else kFalse)
        let b := Bytes.appendAll b kLikedPost
        let b := Bytes.appendNat b pid
        return (if r == 0 then 200 else 201, Bytes.appendAll b kWrapEnd)
    | _ => return (500, Err.internal.body)
  | .create uid text name => do
    let (created, id) ← Store.insertPost uid text
    if id == 0 then return (500, Err.internal.body)
    let b := Bytes.appendAll (ByteArray.emptyWithCapacity (text.size + 160)) kPostWrap
    let b := Bytes.appendAll b kId
    let b := Bytes.appendNat b id
    let b := Bytes.appendAll b kBody
    let b := Bytes.appendEsc b text 0 text.size
    let b := Bytes.appendAll b kCreated
    let b := Bytes.appendEsc b created 0 created.size
    let b := Bytes.appendAll b kAuthor
    let b := Bytes.appendEsc b name 0 name.size
    return (201, Bytes.appendAll b kZeroLikes)

end Feed
