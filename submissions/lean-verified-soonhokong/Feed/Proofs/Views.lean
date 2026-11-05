import Feed.Spec.Server
import Feed.Proofs.Route
import Feed.Server

/-!
# The implementation's values as the specification's

How a value of the code is read as one of `Feed/Spec/*.lean`: a parsed request as the request it
stands for, a parse result as a frame, the handler's errors as SPEC.md's rows, a write as an
answer, and what the transport is handed (a read phase, a reply) as a connection's answer. The
theorems relating the code to the specification are stated through these.
-/
namespace Feed
open Spec

/-- The request a parse result stands for, read off the input. -/
def Http.Req.toRequest (a : ByteArray) (r : Http.Req) : Spec.Http.Request :=
  { method := r.method, head := r.head, path := slice a r.pathLo r.pathHi,
    auth := if r.hasAuth then some (slice a r.authLo r.authHi) else none,
    body := slice a r.bodyLo r.bodyHi, close := r.close }

/-- A parse at `pos` as the frame of the input from `pos` (the request's length counted from `pos`). -/
def Http.Parse.view (a : ByteArray) (pos : Nat) : Http.Parse → Spec.Http.Frame
  | .incomplete => .incomplete
  | .bad st => .bad st
  | .ok r => .ok (r.toRequest a) (r.next - pos)

/-- The handler's errors as SPEC.md's rows. `authenticate` and `postText` never give the last
three, which are the answers to malformed input. -/
def Err.toApi : Err → Spec.ApiErr
  | .notFound => .notFound | .invalidId => .invalidId | .postNotFound => .postNotFound
  | .missingBearer => .missingBearer | .invalidToken => .invalidToken | .invalidPayload => .invalidPayload
  | .malformedJson => .malformedJson | .bodyRequired => .bodyRequired | .bodyTooLong => .bodyTooLong
  | .internal | .badRequest | .tooLarge | .headTooLarge => .internal

def authToSpec : Except Err (Nat × ByteArray) → Except Spec.ApiErr (Nat × List UInt8)
  | .error e => .error e.toApi
  | .ok (uid, name) => .ok (uid, bs name)

def textToSpec : Except Err ByteArray → Except Spec.ApiErr (List UInt8)
  | .error e => .error e.toApi
  | .ok t => .ok (bs t)

/-- A token check's outcome as the code's (`Jwt.verify`'s result). -/
def Jwt.Result.ofSpec : Spec.Auth.TokenCheck → Jwt.Result
  | .invalid => .invalid
  | .badPayload => .badPayload
  | .ok uid u => .ok uid ⟨u.toArray⟩

def Write.toAnswer : Write → Spec.Answer
  | .like uid pid => .like uid pid
  | .create uid text name => .create uid (bs text) (bs name)

/-- A read phase as the transport will see it (`replies` ORs a write's close bit in later). -/
def ChunkOut.toSpec (o : ChunkOut) (a : ByteArray) : Spec.ConnRead :=
  ⟨bs o.out, (bs a).drop o.consumed,
    if o.flags % 2 = 1 ∨ (o.write.map (·.2)) = some true then .close
    else if o.flags / 2 % 2 = 1 then .again else .wait,
    o.write.map fun (w, cl) => (w.toAnswer, cl)⟩

/-- What the transport does with a reply (runtime/uring.c:1106-1123): send `resp[start..]`, keep
`input[consumed..]`, close on bit 0, present the rest again on bit 1. -/
def Reply.toSpec (rep : Reply) (inp : ByteArray) : Spec.ConnReply :=
  ⟨(bs rep.resp).drop rep.start, (bs inp).drop rep.consumed,
    if rep.flags % 2 = 1 then .close else if rep.flags / 2 % 2 = 1 then .again else .wait⟩

/-- `route_spec` on the request a parse result stands for. -/
theorem route_toRequest (a : ByteArray) (r : Http.Req) :
    (route a r).toSpec = Spec.route (r.toRequest a).method (r.toRequest a).path :=
  route_spec a r

/-- info: 'Feed.route_toRequest' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms route_toRequest

end Feed
