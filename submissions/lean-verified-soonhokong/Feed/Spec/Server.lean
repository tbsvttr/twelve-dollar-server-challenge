import Feed.Spec.Http
import Feed.Spec.Auth
import Feed.Spec.Body
import Feed.Spec.Sha256

/-!
# The server's answers

What the server answers to every connection's input in one batch, in the terms of the other
specification modules only: requests framed by `Http.frame`, the token checked by
`Auth.authenticate` with HMAC-SHA256 under JWT_SECRET's bytes, the body taken by `Body.accept`, the
routes and the database of `Feed/Spec.lean`. A batch answers the reads of every connection from
one snapshot, then performs the writes in connection order, each on the database the earlier ones
left (`Feed/Server.lean` describes the batch the transport runs).
-/
namespace Feed.Spec

abbrev Bytes := List UInt8

/-- Per batch: the clock in whole seconds, the uptime, whether this batch may write. -/
structure Clock where
  now : Nat
  uptime : Nat
  writesOk : Bool

inductive Answer where
  | reply (status : Nat) (body : Bytes)
  | like (uid pid : Nat)
  | create (uid : Nat) (body name : Bytes)

def ApiErr.reply (e : ApiErr) : Answer := .reply e.status e.body

/-- SPEC.md:36-42 and 59-72: the answer from the route and the token's and the body's outcomes;
authenticated routes check the token first, then the id or the body (SPEC.md:72). -/
def answerRoute (uptime : Nat) (db : DB) : Route → Except ApiErr (Nat × Bytes) → Except ApiErr Bytes → Answer
  | .feed, _, _ => .reply 200 (feedJson db.feed)
  | .health, _, _ => .reply 200 (healthJson uptime)
  | .notFound, _, _ => ApiErr.notFound.reply
  | .post none, _, _ => ApiErr.invalidId.reply
  | .post (some pid), _, _ =>
    match db.getPost pid with
    | some v => .reply 200 (postJson v)
    | none => ApiErr.postNotFound.reply
  | .create, .error e, _ => e.reply
  | .create, .ok _, .error e => e.reply
  | .create, .ok (uid, name), .ok text => .create uid text name
  | .like _, .error e, _ => e.reply
  | .like none, .ok _, _ => ApiErr.invalidId.reply
  | .like (some pid), .ok (uid, _), _ => .like uid pid

/-- One request's answer, from the batch's snapshot `db`. -/
noncomputable def answer (secret : Bytes) (c : Clock) (db : DB) (q : Http.Request) : Answer :=
  answerRoute c.uptime db (route q.method q.path)
    (Auth.authenticate (HMAC.hmacSha256 secret) c.now q.auth) (Body.accept q.body)

/-- A write's answer and the database after it (SPEC.md:41-42). -/
def Answer.perform (db : DB) : Answer → (Nat × Bytes) × DB
  | .reply st b => ((st, b), db)
  | .like uid pid => db.like uid pid
  | .create uid body name => db.create uid body name

/-- What the transport does next with the connection. -/
inductive Next where
  | wait | again | close
  deriving DecidableEq, Repr

structure ConnRead where
  out : Bytes
  rest : Bytes
  next : Next
  write : Option (Answer × Bool)

/-- One connection's input in one batch: its requests in order (RFC 9112 §9.3.2), reads answered
from the snapshot `db`, until the input is used up or incomplete, the input is malformed (answered,
then close; without content when it is a HEAD request), a write comes (handed over only as the
connection's first request while writes are on; otherwise it and the rest wait), the connection is
to close (RFC 9112 §9.6), or `fuel` requests were answered. A HEAD request is answered with the
head of the response GET gets (RFC 9110 §9.3.2). -/
noncomputable def connRead (secret : Bytes) (c : Clock) (db : DB) : Nat → Nat → Bytes → ConnRead
  | 0, _, s => ⟨[], s, if s = [] then .wait else .again, none⟩
  | fuel + 1, n, s =>
    match Http.frame s with
    | .incomplete => ⟨[], s, .wait, none⟩
    | .bad st => ⟨Http.rejectResponse (Http.headRequest s) st, [], .close, none⟩
    | .ok q len =>
      match answer secret c db q with
      | .reply st body =>
        let bytes := if q.head then Http.responseHead st body q.close else response st body q.close
        if q.close then ⟨bytes, s.drop len, .close, none⟩
        else
          let r := connRead secret c db fuel (n + 1) (s.drop len)
          ⟨bytes ++ r.out, r.rest, r.next, r.write⟩
      | w =>
        if n = 0 ∧ c.writesOk = true then
          ⟨[], s.drop len, if q.close then .close else if len < s.length then .again else .wait, some (w, q.close)⟩
        else ⟨[], s, .again, none⟩

structure ConnReply where
  bytes : Bytes
  rest : Bytes
  next : Next

/-- The writes in connection order, each on the database the earlier ones left; a connection's
bytes are its reads' answers, then its write's answer. Every post the write phase creates gets the
snapshot's `clock` as its `created_at` (`DB.insertPost`): one `created_at` per write phase. -/
def writePhase : DB → List ConnRead → List ConnReply × DB
  | db, [] => ([], db)
  | db, r :: rs =>
    match r.write with
    | none => let t := writePhase db rs; (⟨r.out, r.rest, r.next⟩ :: t.1, t.2)
    | some (w, close) =>
      let a := w.perform db
      let t := writePhase a.2 rs
      (⟨r.out ++ response a.1.1 a.1.2 close, r.rest, r.next⟩ :: t.1, t.2)

/-- requests answered per connection per batch (Server.lean:38) -/
def maxPipeline : Nat := 64

/-- One batch on the snapshot `db`, from every connection's unread input. -/
noncomputable def batch (secret : Bytes) (c : Clock) (db : DB) (inputs : List Bytes) : List ConnReply × DB :=
  writePhase db (inputs.map (connRead secret c db maxPipeline 0))

end Feed.Spec
