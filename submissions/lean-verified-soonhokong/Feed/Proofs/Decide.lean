import Feed.Proofs.Plan
import Feed.Proofs.Route

/-!
# One request

What `decide` does with one parsed request, on the model: the response the specification gives
for the request's route, or the write the request asks for. Whether the token and the post body
are accepted is decided by the handler's own `authenticate` and `postText`, which appear in the
statement; `authenticate_spec` (`Feed/Proofs/Auth.lean`) and `postText_spec`
(`Feed/Proofs/Body.lean`) say what they decide, and `decide_correct` (`Feed/Proofs/EndToEnd.lean`)
states the answer with them.
-/
namespace Feed
open Spec Http

/-! ## Response bytes (`bs_respond` is in `Feed.Proofs.Bytes`) -/

/-- The error bodies are the messages of SPEC.md. -/
theorem bs_err_body (e : Err) : bs e.body = errJson (match e with
    | .notFound => "not found" | .invalidId => "invalid post id" | .postNotFound => "post not found"
    | .missingBearer => "missing bearer token" | .invalidToken => "invalid or expired token"
    | .invalidPayload => "invalid token payload" | .malformedJson => "malformed JSON body"
    | .bodyRequired => "body is required" | .bodyTooLong => "body must be at most 500 characters"
    | .internal => "internal server error" | .badRequest => "bad request" | .tooLarge => "request too large"
    | .headTooLarge => "request header too large") := by
  cases e <;> decide

theorem bs_respondErr (out : ByteArray) (e : Err) (close : Bool) :
    bs (respondErr out e close) = bs out ++ response e.status (bs e.body) close :=
  bs_respond out e.status e.body close

/-! ## The answer of one request -/

/-- What one request leads to: a response, or a write for the batch's write phase. -/
inductive Outcome where
  | reply (status : Nat) (body : List UInt8)
  | write (w : Write)

/-- The specification's outcome of a request with this route, given the result of its token check
and of its body check. Authenticated routes check the token first, then the id or the body. -/
def expected (env : Env) (db : DB) (route : Spec.Route) (auth : Except Err (Nat × ByteArray))
    (text : Except Err ByteArray) : Outcome :=
  match route with
  | .feed => .reply 200 (feedJson db.feed)
  | .post none => .reply 400 (errJson "invalid post id")
  | .post (some pid) =>
    match db.getPost pid with
    | some v => .reply 200 (Spec.postJson v)
    | none => .reply 404 (errJson "post not found")
  | .health => .reply 200 (healthJson env.uptime)
  | .notFound => .reply 404 (errJson "not found")
  | .create =>
    match auth with
    | .error e => .reply e.status (bs e.body)
    | .ok (uid, name) =>
      match text with
      | .error e => .reply e.status (bs e.body)
      | .ok t => .write (.create uid t name)
  | .like id =>
    match auth with
    | .error e => .reply e.status (bs e.body)
    | .ok (uid, _) =>
      match id with
      | none => .reply 400 (errJson "invalid post id")
      | some pid => .write (.like uid pid)

/-- How a step of the handler realizes an outcome: a reply is appended to the connection's
output; a write leaves the output as it is and is handed to the write phase. -/
def Realizes (out : ByteArray) (close : Bool) (st : Step) : Outcome → Prop
  | .reply status body => st.write = none ∧ bs st.out = bs out ++ response status body close
  | .write w => st.write = some w ∧ st.out = out

@[simp] theorem run_health (db : DB) : (Store.health (m := Model)).run db = (true, db) := rfl

/-- **One request is answered as the specification says**, given what `authenticate` and
`postText` return, from the batch's snapshot `db` (which it leaves unchanged): the route of its
method and path, then the endpoint's answer, or for a write the write to perform. -/
theorem decide_spec (env : Env) (a : ByteArray) (r : Req) (out scratch : ByteArray) (db : DB)
    (hsize : db.posts.length < 20 * 2 ^ 63) :
    let st := (decide (m := Model) env a r out scratch).run db
    st.2 = db ∧
    Realizes out r.close st.1
      (expected env db (Spec.route r.method (slice a r.pathLo r.pathHi)) (authenticate env.key env.now a r)
        (postText a r)) := by
  intro st
  rw [← route_spec a r]
  simp only [st, decide]
  cases hr : route a r with
  | feed =>
    obtain ⟨hst, hb⟩ := feedResponse_correct db hsize out r.close
    simp only [StateT.run_bind]
    rw [run_eq_of_snd hst]
    simp only [id_bind, StateT.run_pure, id_pure, Route.toSpec, expected, Realizes]
    exact ⟨trivial, trivial, hb⟩
  | post id =>
    cases id with
    | invalid =>
      simp only [StateT.run_pure, id_pure, Route.toSpec, PostId.toOption, expected, Realizes]
      refine ⟨trivial, trivial, ?_⟩
      rw [bs_respondErr, bs_err_body]; rfl
    | ok pid =>
      obtain ⟨hst, hb⟩ := postResponse_correct db out pid r.close
      simp only [StateT.run_bind]
      rw [run_eq_of_snd hst]
      cases hg : db.getPost pid with
      | none =>
        simp only [hg] at hb
        simp only [id_bind, StateT.run_pure, id_pure, Route.toSpec, PostId.toOption, expected, hg, Realizes]
        exact ⟨trivial, trivial, hb⟩
      | some v =>
        simp only [hg] at hb
        simp only [id_bind, StateT.run_pure, id_pure, Route.toSpec, PostId.toOption, expected, hg, Realizes]
        exact ⟨trivial, trivial, hb⟩
  | health =>
    simp only [StateT.run_bind, run_health, id_bind, ↓reduceIte, StateT.run_pure, id_pure, Route.toSpec, expected,
      Realizes]
    refine ⟨trivial, trivial, ?_⟩
    rw [bs_respond]
    simp only [bs_appendAll, bs_appendNat, bs_clear, List.nil_append, kHealth, kWrapEnd, bs_lit]
    rfl
  | create =>
    simp only [Route.toSpec, expected]
    cases authenticate env.key env.now a r with
    | error e =>
      simp only [StateT.run_pure, id_pure, Realizes]
      exact ⟨trivial, trivial, bs_respondErr out e r.close⟩
    | ok p =>
      obtain ⟨uid, name⟩ := p
      cases postText a r with
      | error e =>
        simp only [StateT.run_pure, id_pure, Realizes]
        exact ⟨trivial, trivial, bs_respondErr out e r.close⟩
      | ok text =>
        simp only [StateT.run_pure, id_pure, Realizes]
        exact ⟨trivial, trivial, trivial⟩
  | like id =>
    simp only [Route.toSpec, expected]
    cases authenticate env.key env.now a r with
    | error e =>
      simp only [StateT.run_pure, id_pure, Realizes]
      exact ⟨trivial, trivial, bs_respondErr out e r.close⟩
    | ok p =>
      obtain ⟨uid, name⟩ := p
      cases id with
      | invalid =>
        simp only [StateT.run_pure, id_pure, PostId.toOption, Realizes]
        refine ⟨trivial, trivial, ?_⟩
        rw [bs_respondErr, bs_err_body]; rfl
      | ok pid =>
        simp only [StateT.run_pure, id_pure, PostId.toOption, Realizes]
        exact ⟨trivial, trivial, trivial⟩
  | notFound =>
    simp only [StateT.run_pure, id_pure, Route.toSpec, expected, Realizes]
    refine ⟨trivial, trivial, ?_⟩
    rw [bs_respondErr, bs_err_body]; rfl

/-- info: 'Feed.decide_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms decide_spec

end Feed
