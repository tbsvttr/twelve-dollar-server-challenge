import Feed.Proofs.Http
import Feed.Proofs.Auth
import Feed.Proofs.Body
import Feed.Proofs.Store
import Feed.Proofs.Batch

/-!
# The batch, end to end

`runBatch`, on any storage in a state monad (`Store (StateM σ)`) that meets the contract of
`Feed/Proofs/Store.lean`, computes `Spec.batch` from the input bytes, the database the storage
stands for, JWT_SECRET's bytes and the clock (`runBatch_correct`); `readLoop_correct` and
`decide_correct` say the same of one connection's read phase and of one request, and
`runBatch_correct_model` is the instance at the model.

These four take no hypothesis about what the parser, the token check or the body check return:
they use the theorems `Http.parse_view` and `Http.parse_sound` (`Feed/Proofs/Http.lean`), by which
the Lean definition of `Http.parse` computes the specification's frame of the input and a request
it returns is the specification's request of its bytes, and `authenticate_spec`
(`Feed/Proofs/Auth.lean`) and `postText_spec` (`Feed/Proofs/Body.lean`), by which the token check
and the body check decide as the specification does. What `readLoop` does with what the parser
returns is proved too (`readLoop_bad`, `readLoop_reply`, from `bs_respondReject`, `bs_stripBody`
and `Http.headAt_eq`): it answers malformed input with `Spec.Http.rejectResponse` (the head only
when the input starts with HEAD, and 414 with its own status line), and sends the head of the
response to a HEAD request.

On a storage that meets the contract, `decide` and `readLoop` return what they return on the model
and leave a state that stands for the model's database (`decide_sim`, `readLoop_sim`). A page is
the model's only up to `Page.Same`, which the handler cannot tell apart. The same holds of
`runBatch` (`runBatch_sim`) given that every text `postText` accepts is one that
`Spec.Body.accept` returns, which follows from `postText_spec`: the contract answers `insertPost`
only for such a text, and each write a read phase hands over carries a text `postText` accepted
(`readAll_accepted`).

The server runs `runBatch` at `IO` (`batch_eq`), on the C storage, which is not a `StateM σ`, so
these theorems do not reach it: that `Feed.batch` answers as `runBatch` does on a storage that
meets the contract, the step from `StateM σ` to `IO`, is assumed, not proved
(`Feed/Proofs/Store.lean`); Lean has no model of `IO`'s effects to state it in. So is the rest:
each C leaf computes its Lean definition (checked by the self-test), and the transport
(runtime/uring.c) hands each connection's unread bytes to `Feed.batch` in order and does with each
reply what `Reply.toSpec` says. The theorems say nothing of when a request is answered (a write
waits for a batch in which writes are on, a 65th pipelined request for a later batch), of timing
(RFC 7518 §3.2 asks for a constant-time MAC comparison), of what the transport does once the peer
half-closes, a send fails or a connection closes while its batch runs, or of whether the stored
bodies, timestamps and usernames are UTF-8, which SPEC.md:25 ("Every body is compact JSON") needs
of them.
-/
namespace Feed
open Spec

/-- The transport's entry point is `runBatch` with the key it builds once (Server.lean:142-147,
uring.c:1250). -/
theorem batch_eq (chunks : Array ByteArray) (now uptime : UInt64) (w : UInt8) (secret : ByteArray) :
    batch chunks now uptime w (makeKey secret) =
      runBatch ⟨Hmac.Key.of secret, now.toNat, uptime.toNat, w != 0⟩ chunks := rfl

/-- info: 'Feed.batch_eq' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms batch_eq

/-! ## A storage that meets the contract, against the model -/

theorem eq_of_bs {a b : ByteArray} (h : bs a = bs b) : a = b := ByteArray.ext (Array.toList_inj.mp h)

/-- `x`, run on a storage from a state that stands for a database under `R`, returns what `y`
returns on the model from that database, and leaves a state that stands for the model's. -/
def Sim {σ : Type} (R : σ → DB → Prop) {α : Type} (x : StateM σ α) (y : Model α) : Prop :=
  ∀ ⦃s : σ⦄ ⦃db : DB⦄, R s db → (x.run s).1 = (y.run db).1 ∧ R (x.run s).2 (y.run db).2

namespace Sim
variable {σ : Type} {R : σ → DB → Prop}

protected theorem pure {α : Type} (a : α) : Sim R (pure a) (pure a) := fun _ _ h => ⟨rfl, h⟩

protected theorem bind {α β : Type} {x : StateM σ α} {y : Model α} {f : α → StateM σ β} {g : α → Model β}
    (hx : Sim R x y) (hf : ∀ a, Sim R (f a) (g a)) : Sim R (x >>= f) (y >>= g) := by
  intro s db h
  obtain ⟨h1, h2⟩ := hx h
  simp only [StateT.run_bind, id_bind]
  rw [h1]
  exact hf _ h2

/-- `bind` when the continuations agree only on what the model's `y` can return. -/
theorem bind_of {α β : Type} {x : StateM σ α} {y : Model α} {f : α → StateM σ β} {g : α → Model β}
    {P : α → Prop} (hx : Sim R x y) (hy : ∀ db, P (y.run db).1) (hf : ∀ a, P a → Sim R (f a) (g a)) :
    Sim R (x >>= f) (y >>= g) := by
  intro s db h
  obtain ⟨h1, h2⟩ := hx h
  simp only [StateT.run_bind, id_bind]
  rw [h1]
  exact hf _ (hy db) h2

end Sim

section
variable {σ : Type} [Store (StateM σ)] {R : σ → DB → Prop}

theorem Sim.begin (hc : Store.Contract σ R) : Sim R (Store.begin (m := StateM σ)) (Store.begin (m := Model)) :=
  fun _ _ h => hc.begin h

theorem Sim.health (hc : Store.Contract σ R) : Sim R (Store.health (m := StateM σ)) (Store.health (m := Model)) :=
  fun _ _ h => hc.health h

theorem Sim.endReads (hc : Store.Contract σ R) :
    Sim R (Store.endReads (m := StateM σ)) (Store.endReads (m := Model)) :=
  fun _ _ h => ⟨rfl, hc.endReads h⟩

theorem Sim.commit (hc : Store.Contract σ R) : Sim R (Store.commit (m := StateM σ)) (Store.commit (m := Model)) :=
  fun _ _ h => hc.commit h

theorem Sim.postExists (hc : Store.Contract σ R) (pid : Nat) :
    Sim R (Store.postExists (m := StateM σ) pid) (Store.postExists (m := Model) pid) :=
  fun _ _ h => hc.postExists pid h

theorem Sim.insertLike (hc : Store.Contract σ R) (uid pid : Nat) :
    Sim R (Store.insertLike (m := StateM σ) uid pid) (Store.insertLike (m := Model) uid pid) :=
  fun _ _ h => hc.insertLike uid pid h

theorem Sim.insertPost (hc : Store.Contract σ R) (uid : Nat) (body : ByteArray)
    (hb : ∃ t, Body.accept t = .ok (bs body)) :
    Sim R (Store.insertPost (m := StateM σ) uid body) (Store.insertPost (m := Model) uid body) := by
  intro s db h
  obtain ⟨h1, h2, h3⟩ := hc.insertPost uid body h hb
  rw [run_insertPost]
  exact ⟨Prod.ext (eq_of_bs (by rw [h1, bs_mk])) h2, h3⟩

/-- The feed's plan reads further, and answers, as it does on the model: the pages differ, but
only up to `Page.Same` (`respondFeed_congr`). -/
theorem feedLoop_sim (hc : Store.Contract σ R) (close : Bool) : ∀ fuel want (out : ByteArray),
    Sim R (feedLoop (m := StateM σ) out close want fuel) (feedLoop (m := Model) out close want fuel) := by
  intro fuel
  induction fuel with
  | zero => intro want out; exact Sim.pure _
  | succ f ih =>
    intro want out s db h
    obtain ⟨hp, h'⟩ := hc.feedPage want h
    obtain ⟨hb, ha, hn⟩ := respondFeed_congr out close _ _ hp
    simp only [feedLoop, StateT.run_bind, id_bind, run_feedPage]
    rw [ha, hn]
    split
    · exact ⟨eq_of_bs hb, h'⟩
    · exact ih _ _ h'

theorem postResponse_sim (hc : Store.Contract σ R) (out : ByteArray) (pid : Nat) (close : Bool) :
    Sim R (postResponse (m := StateM σ) out pid close) (postResponse (m := Model) out pid close) := by
  intro s db h
  obtain ⟨hp, h'⟩ := hc.postPage pid h
  obtain ⟨hb, hf⟩ := respondPost_congr out pid close _ _ hp
  simp only [postResponse, StateT.run_bind, id_bind, run_postPage]
  rw [hf]
  split
  · exact ⟨eq_of_bs hb, h'⟩
  · exact ⟨rfl, h'⟩

/-- **One request does on a storage that meets the contract what it does on the model**: the same
step (output, scratch buffer, write), and a state that stands for the model's database. -/
theorem decide_sim (hc : Store.Contract σ R) (env : Env) (a : ByteArray) (r : Http.Req) (out scratch : ByteArray) :
    Sim R (decide (m := StateM σ) env a r out scratch) (decide (m := Model) env a r out scratch) := by
  simp only [decide]
  split
  · exact Sim.bind (feedLoop_sim hc _ _ _ _) fun _ => Sim.pure _
  · exact Sim.pure _
  · exact Sim.bind (postResponse_sim hc _ _ _) fun _ => Sim.pure _
  · exact Sim.bind (Sim.health hc) fun b => by cases b <;> exact Sim.pure _
  · split
    · exact Sim.pure _
    · split <;> exact Sim.pure _
  · split
    · exact Sim.pure _
    · split <;> exact Sim.pure _
  · exact Sim.pure _

/-- **A connection's read phase does on a storage that meets the contract what it does on the
model.** -/
theorem readLoop_sim (hc : Store.Contract σ R) (env : Env) (a : ByteArray) : ∀ fuel pos n (out : ByteArray),
    Sim R (readLoop (m := StateM σ) env a pos n out fuel) (readLoop (m := Model) env a pos n out fuel) := by
  intro fuel
  induction fuel with
  | zero => intros; exact Sim.pure _
  | succ f ih =>
    intro pos n out
    simp only [readLoop]
    split
    · exact Sim.pure _
    · exact Sim.pure _
    · refine Sim.bind (decide_sim hc env a _ out _) fun st => ?_
      split
      · split <;> exact Sim.pure _
      · split
        · exact Sim.pure _
        · exact ih _ _ _

theorem readAll_sim (hc : Store.Contract σ R) (env : Env) (chunks : Array ByteArray) :
    ∀ fuel i (outs : Array ChunkOut),
      Sim R (readAll (m := StateM σ) env chunks i outs fuel) (readAll (m := Model) env chunks i outs fuel) := by
  intro fuel
  induction fuel with
  | zero => intros; exact Sim.pure _
  | succ f ih =>
    intro i outs
    simp only [readAll]
    split
    · exact Sim.bind (readLoop_sim hc env _ _ _ _ _) fun _ => ih _ _
    · exact Sim.pure _

end

/-! ### The bodies `insertPost` is given -/

/-- A write the contract's `insertPost` answers for: a post's text the API takes. -/
def Write.Accepted : Write → Prop
  | .like _ _ => True
  | .create _ text _ => ∃ t, Body.accept t = .ok (bs text)

/-- The write a read phase hands over, if any, is one the contract answers for. -/
def ChunkOut.Accepted (o : ChunkOut) : Prop := ∀ w c, o.write = some (w, c) → w.Accepted

/-- A request hands over a new post only with the text `postText` accepted. -/
theorem decide_write (env : Env) (a : ByteArray) (r : Http.Req) (out scratch : ByteArray) (db : DB) {w : Write}
    (h : ((decide (m := Model) env a r out scratch).run db).1.write = some w) :
    (∃ uid t name, w = .create uid t name ∧ postText a r = .ok t) ∨ ∃ uid pid, w = .like uid pid := by
  simp only [decide] at h
  split at h
  · simp at h
  · simp at h
  · simp at h
  · simp only [StateT.run_bind, run_health, id_bind, ↓reduceIte, StateT.run_pure, id_pure] at h
    simp at h
  · split at h
    · simp at h
    · split at h
      · simp at h
      · rename_i text htext
        simp only [StateT.run_pure, id_pure, Option.some.injEq] at h
        exact .inl ⟨_, _, _, h.symm, htext⟩
  · split at h
    · simp at h
    · split at h
      · simp at h
      · simp only [StateT.run_pure, id_pure, Option.some.injEq] at h
        exact .inr ⟨_, _, h.symm⟩
  · simp at h

theorem readLoop_accepted (hpost : ∀ a r t, postText a r = .ok t → ∃ u, Body.accept u = .ok (bs t))
    (env : Env) (a : ByteArray) : ∀ fuel pos n (out : ByteArray) (db : DB),
      ((readLoop (m := Model) env a pos n out fuel).run db).1.Accepted := by
  intro fuel
  induction fuel with
  | zero => intro pos n out db w c h; simp [readLoop] at h
  | succ f ih =>
    intro pos n out db
    simp only [readLoop]
    split
    · intro w c h; simp at h
    · intro w c h; simp at h
    · simp only [StateT.run_bind, id_bind]
      split
      · rename_i w hw
        split
        · intro w' c h
          simp only [StateT.run_pure, id_pure, Option.some.injEq, Prod.mk.injEq] at h
          obtain ⟨rfl, -⟩ := h
          rcases decide_write env a _ out _ db hw with ⟨uid, t, name, rfl, ht⟩ | ⟨uid, pid, rfl⟩
          · exact hpost _ _ _ ht
          · trivial
        · intro w c h; simp at h
      · split
        · intro w c h; simp at h
        · exact ih _ _ _ _

/-- **Every write of a batch's read phase is one the contract answers for**, given that a text
`postText` accepts is one that `Spec.Body.accept` returns (which follows from `postText_spec`). -/
theorem readAll_accepted (hpost : ∀ a r t, postText a r = .ok t → ∃ u, Body.accept u = .ok (bs t))
    (env : Env) (chunks : Array ByteArray) : ∀ fuel i (outs : Array ChunkOut) (db : DB),
      (∀ o ∈ outs.toList, o.Accepted) →
        ∀ o ∈ ((readAll (m := Model) env chunks i outs fuel).run db).1.toList, o.Accepted := by
  intro fuel
  induction fuel with
  | zero => intro i outs db h; exact h
  | succ f ih =>
    intro i outs db h
    simp only [readAll]
    split
    · simp only [StateT.run_bind, id_bind, readPhase]
      apply ih
      intro o ho
      simp only [Array.toList_push, List.mem_append, List.mem_singleton] at ho
      rcases ho with ho | rfl
      · exact h o ho
      · exact readLoop_accepted hpost env _ _ _ _ _ _
    · exact h

section
variable {σ : Type} [Store (StateM σ)] {R : σ → DB → Prop}

theorem perform_sim (hc : Store.Contract σ R) (w : Write) (hw : w.Accepted) :
    Sim R (perform (m := StateM σ) w) (perform (m := Model) w) := by
  cases w with
  | like uid pid =>
    simp only [perform]
    refine Sim.bind (Sim.postExists hc pid) fun _ => ?_
    split
    · exact Sim.pure _
    · exact Sim.bind (Sim.insertLike hc uid pid) fun _ => by split <;> exact Sim.pure _
    · exact Sim.pure _
  | create uid text name =>
    simp only [perform]
    refine Sim.bind (Sim.insertPost hc uid text hw) fun _ => ?_
    split <;> exact Sim.pure _

theorem writeAll_sim (hc : Store.Contract σ R) (outs : Array ChunkOut) (hw : ∀ o ∈ outs.toList, o.Accepted) :
    ∀ fuel i (res : Array (Nat × ByteArray)),
      Sim R (writeAll (m := StateM σ) outs i res fuel) (writeAll (m := Model) outs i res fuel) := by
  intro fuel
  induction fuel with
  | zero => intros; exact Sim.pure _
  | succ f ih =>
    intro i res
    simp only [writeAll]
    split
    · split
      · rename_i w c hwc
        exact Sim.bind (perform_sim hc w (hw _ (by simp) w c hwc)) fun _ => ih _ _
      · exact ih _ _
    · exact Sim.pure _

/-- **On a storage that meets the contract, a batch computes what it computes on the model**:
the same replies, and a state that stands for the model's database after the batch. It takes as
given that every text `postText` accepts is one that `Spec.Body.accept` returns, which follows
from `postText_spec` (`runBatch_correct` derives it). -/
theorem runBatch_sim (hc : Store.Contract σ R)
    (hpost : ∀ a r t, postText a r = .ok t → ∃ u, Body.accept u = .ok (bs t)) (env : Env) (chunks : Array ByteArray) :
    Sim R (runBatch (m := StateM σ) env chunks) (runBatch (m := Model) env chunks) := by
  simp only [runBatch]
  refine Sim.bind (Sim.begin hc) fun ok => ?_
  split
  · exact Sim.pure _
  · refine Sim.bind_of (P := fun outs => ∀ o ∈ outs.toList, o.Accepted) (readAll_sim hc env chunks _ _ _)
      (fun db => readAll_accepted hpost env chunks chunks.size 0 (Array.mkEmpty chunks.size) db (by simp))
      fun outs hacc => ?_
    refine Sim.bind (Sim.endReads hc) fun _ => ?_
    refine Sim.bind (writeAll_sim hc outs hacc _ _ _) fun _ => ?_
    exact Sim.bind (Sim.commit hc) fun _ => Sim.pure _

end

/-! ## One request, in the specification's terms -/

/-- An outcome of `expected` as the specification's answer. -/
def Outcome.toAnswer : Outcome → Spec.Answer
  | .reply status body => .reply status body
  | .write w => w.toAnswer

/-- The token check answers with SPEC.md's rows only (none of the answers to malformed input). -/
theorem authenticate_error_api {key : Hmac.Key} {now : Nat} {a : ByteArray} {r : Http.Req} {e : Err}
    (h : authenticate key now a r = .error e) : e.toApi.status = e.status ∧ e.toApi.body = bs e.body := by
  unfold authenticate at h
  split at h
  · cases h; decide
  · split at h <;> cases h <;> decide

/-- The body check answers with SPEC.md's rows only (none of the answers to malformed input). -/
theorem postText_error_api {a : ByteArray} {r : Http.Req} {e : Err}
    (h : postText a r = .error e) : e.toApi.status = e.status ∧ e.toApi.body = bs e.body := by
  unfold postText at h
  split at h
  · cases h; decide
  · cases h; decide
  · rename_i fs _
    simp only at h
    by_cases hk : (fs[0]!.kind != Json.Kind.str) = true
    · rw [ite_eq_left hk] at h; cases h; decide
    · rw [ite_eq_right hk] at h
      generalize trimRange (Json.decodeString a fs[0]!.lo fs[0]!.hi) = p at h
      obtain ⟨lo, hi⟩ := p
      simp only at h
      by_cases h1 : lo ≥ hi
      · rw [ite_eq_left h1] at h; cases h; decide
      · rw [ite_eq_right h1] at h
        by_cases h2 : codePoints (Json.decodeString a fs[0]!.lo fs[0]!.hi) lo hi > 500
        · rw [ite_eq_left h2] at h; cases h; decide
        · rw [ite_eq_right h2] at h
          by_cases h3 : ((Json.decodeString a fs[0]!.lo fs[0]!.hi).get! lo == 0) = true
          · rw [ite_eq_left h3] at h; cases h; decide
          · rw [ite_eq_right h3] at h; cases h

/-- `expected`, from the handler's own token and body checks, is `Spec.answerRoute` of their
outcomes read as SPEC.md's. -/
theorem expected_toAnswer (env : Env) (db : DB) (rt : Spec.Route) (auth : Except Err (Nat × ByteArray))
    (text : Except Err ByteArray)
    (hauth : ∀ e, auth = .error e → e.toApi.status = e.status ∧ e.toApi.body = bs e.body)
    (htext : ∀ e, text = .error e → e.toApi.status = e.status ∧ e.toApi.body = bs e.body) :
    (expected env db rt auth text).toAnswer = answerRoute env.uptime db rt (authToSpec auth) (textToSpec text) := by
  cases rt with
  | health => rfl
  | feed => rfl
  | notFound => rfl
  | post id =>
    cases id with
    | none => rfl
    | some pid => simp only [expected, answerRoute]; cases db.getPost pid <;> rfl
  | create =>
    cases auth with
    | error e =>
      obtain ⟨h1, h2⟩ := hauth e rfl
      simp only [expected, answerRoute, authToSpec, Outcome.toAnswer, ApiErr.reply, h1, h2]
    | ok p =>
      obtain ⟨uid, name⟩ := p
      cases text with
      | error e =>
        obtain ⟨h1, h2⟩ := htext e rfl
        simp only [expected, answerRoute, authToSpec, textToSpec, Outcome.toAnswer, ApiErr.reply, h1, h2]
      | ok t => rfl
  | like id =>
    cases auth with
    | error e =>
      obtain ⟨h1, h2⟩ := hauth e rfl
      simp only [expected, answerRoute, authToSpec, Outcome.toAnswer, ApiErr.reply, h1, h2]
    | ok p =>
      obtain ⟨uid, name⟩ := p
      cases id <;> rfl

/-- One request on the model: the specification's answer (`decide_spec`, with the token and body
checks read as SPEC.md's by `authenticate_spec` and `postText_spec`). -/
theorem decide_answer (secret : ByteArray) (c : Spec.Clock) (a : ByteArray) (r : Http.Req)
    (out scratch : ByteArray) (db : Spec.DB) (hsize : db.posts.length < 20 * 2 ^ 63) :
    let st := (decide (m := Model) ⟨Hmac.Key.of secret, c.now, c.uptime, c.writesOk⟩ a r out scratch).run db
    st.2 = db ∧
    match Spec.answer (bs secret) c db (r.toRequest a) with
    | .reply status body => st.1.write = none ∧ bs st.1.out = bs out ++ Spec.response status body r.close
    | w => st.1.write.map Write.toAnswer = some w ∧ st.1.out = out := by
  intro st
  obtain ⟨h1, h2⟩ := decide_spec ⟨Hmac.Key.of secret, c.now, c.uptime, c.writesOk⟩ a r out scratch db hsize
  refine ⟨h1, ?_⟩
  have hans : Spec.answer (bs secret) c db (r.toRequest a) =
      (expected ⟨Hmac.Key.of secret, c.now, c.uptime, c.writesOk⟩ db (Spec.route r.method (slice a r.pathLo r.pathHi))
        (authenticate (Hmac.Key.of secret) c.now a r) (postText a r)).toAnswer := by
    rw [expected_toAnswer _ _ _ _ _ (fun _ he => authenticate_error_api he) (fun _ he => postText_error_api he),
      authenticate_spec, postText_spec]
    rfl
  rw [hans]
  generalize expected _ _ _ _ _ = oc at h2
  cases oc with
  | reply status body => exact h2
  | write w =>
    obtain ⟨hw1, hw2⟩ := h2
    cases w <;> exact ⟨by simp [st, hw1, Outcome.toAnswer], hw2⟩

/-! ## One connection's read phase -/

/-- On input that `Http.parse` finds malformed, `readLoop` answers `Spec.Http.rejectResponse` for
`Spec.Http.headRequest` of the input, uses it all up and closes. -/
theorem readLoop_bad (env : Env) (a : ByteArray) (pos n : Nat) (out : ByteArray) (fuel st : Nat) (db : DB)
    (h : Http.parse a pos = .bad st) :
    ∃ o, (readLoop (m := Model) env a pos n out (fuel + 1)).run db = (⟨o, a.size, 1, none⟩, db) ∧
      bs o = bs out ++ Spec.Http.rejectResponse (Spec.Http.headRequest ((bs a).drop pos)) st := by
  refine ⟨respondReject out (Http.headAt a pos) st, ?_, ?_⟩
  · simp only [readLoop, h]; rfl
  · rw [bs_respondReject, Http.headAt_eq]

/-- After a request that `decide` answers with a reply, `readLoop` sends the response, its head only
for a HEAD request (`Spec.Http.responseHead`), and goes on at the next request unless the
connection closes. -/
theorem readLoop_reply (env : Env) (a : ByteArray) (pos n : Nat) (out : ByteArray) (fuel : Nat) (db : DB)
    (r : Http.Req) (status : Nat) (body : List UInt8) (h : Http.parse a pos = .ok r)
    (hw : ((decide (m := Model) env a r out ByteArray.empty).run db).1.write = none)
    (ho : bs ((decide (m := Model) env a r out ByteArray.empty).run db).1.out =
      bs out ++ Spec.response status body r.close) :
    ∃ o, bs o = bs out ++ (if r.head then Spec.Http.responseHead status body r.close
        else Spec.response status body r.close) ∧
      (readLoop (m := Model) env a pos n out (fuel + 1)).run db =
        if r.close then (⟨o, r.next, 1, none⟩, db) else (readLoop (m := Model) env a r.next (n + 1) o fuel).run db := by
  refine ⟨if r.head then stripBody ((decide (m := Model) env a r out ByteArray.empty).run db).1.out out.size
      else ((decide (m := Model) env a r out ByteArray.empty).run db).1.out, ?_, ?_⟩
  · cases r.head
    · simpa using ho
    · simpa using bs_stripBody _ out status body r.close ho
  · simp only [readLoop, h, StateT.run_bind]
    rw [run_eq_of_snd (decide_db env a r out ByteArray.empty db)]
    simp only [id_bind, hw]
    split <;> rfl

/-- One connection's read phase on the model is `Spec.connRead`, given the answer of each request
(`decide_answer`): the parser frames the input as the specification does (`Http.parse_view`,
`Http.parse_sound`). The answers are appended to `out`. -/
theorem readLoop_connRead (secret : ByteArray) (c : Spec.Clock) (a : ByteArray) (db : DB)
    (hdecide : ∀ (r : Http.Req) (out : ByteArray),
      let st := (decide (m := Model) ⟨Hmac.Key.of secret, c.now, c.uptime, c.writesOk⟩ a r out ByteArray.empty).run db
      st.2 = db ∧
      match Spec.answer (bs secret) c db (r.toRequest a) with
      | .reply status body => st.1.write = none ∧ bs st.1.out = bs out ++ Spec.response status body r.close
      | w => st.1.write.map Write.toAnswer = some w ∧ st.1.out = out) :
    ∀ fuel pos n (out : ByteArray), pos ≤ a.size →
      let o := (readLoop (m := Model) ⟨Hmac.Key.of secret, c.now, c.uptime, c.writesOk⟩ a pos n out fuel).run db
      let x := Spec.connRead (bs secret) c db fuel n ((bs a).drop pos)
      o.2 = db ∧ ChunkOut.toSpec o.1 a = ⟨bs out ++ x.out, x.rest, x.next, x.write⟩ := by
  intro fuel
  induction fuel with
  | zero =>
    intro pos n out hp
    refine ⟨rfl, ?_⟩
    simp only [readLoop, StateT.run_pure, id_pure, Spec.connRead, ChunkOut.toSpec, List.append_nil]
    by_cases h : pos < a.size
    · have : (bs a).drop pos ≠ [] := by simp [List.drop_eq_nil_iff]; omega
      simp [h, this]
    · have : (bs a).drop pos = [] := by simp [List.drop_eq_nil_iff]; omega
      simp [h, this]
  | succ f ih =>
    intro pos n out hp
    simp only [Spec.connRead]
    rw [← Http.parse_view a pos hp]
    cases hparse : Http.parse a pos with
    | incomplete =>
      simp [readLoop, hparse, Http.Parse.view, ChunkOut.toSpec]
    | bad st =>
      obtain ⟨o, hrun, hbo⟩ := readLoop_bad _ a pos n out f st db hparse
      rw [hrun]
      simp [Http.Parse.view, ChunkOut.toSpec, hbo, List.drop_eq_nil_iff]
    | ok r =>
      obtain ⟨hpn, hna, -, -⟩ := Http.parse_sound hp hparse
      have hrest : ((bs a).drop pos).drop (r.next - pos) = (bs a).drop r.next := by
        rw [List.drop_drop]; congr 1; omega
      have hlen : (r.next - pos < ((bs a).drop pos).length) ↔ r.next < a.size := by
        simp only [List.length_drop, bs_size]; omega
      obtain ⟨hdb, hans⟩ := hdecide r out
      simp only [Http.Parse.view]
      generalize Spec.answer (bs secret) c db (r.toRequest a) = A at hans
      cases A
      case reply status body =>
        obtain ⟨hw, hout⟩ := hans
        obtain ⟨o, hbo, hrun⟩ := readLoop_reply _ a pos n out f db r status body hparse hw hout
        rw [hrun]
        simp only [Http.Req.toRequest, hrest]
        rcases Bool.eq_false_or_eq_true r.close with hcl | hcl <;> simp only [hcl] at hbo ⊢
        · simp [ChunkOut.toSpec, hbo]
        · obtain ⟨h1, h2⟩ := ih r.next (n + 1) o hna
          simp only [Bool.false_eq_true, ↓reduceIte]
          refine ⟨h1, ?_⟩
          rw [h2, hbo, List.append_assoc]
      all_goals
        obtain ⟨hw, hout⟩ := hans
        obtain ⟨w, hw1, hw2⟩ := Option.map_eq_some_iff.mp hw
        simp only [readLoop, hparse, StateT.run_bind, id_bind]
        rw [hw1]
        simp only [Http.Req.toRequest, hrest, hout]
        by_cases hn : n = 0 ∧ c.writesOk = true
        · obtain ⟨rfl, hwk⟩ := hn
          simp only [hwk] at hdb ⊢
          simp only [beq_self_eq_true, Bool.and_self, ↓reduceIte, and_self, StateT.run_pure, id_pure, hdb,
            true_and, ChunkOut.toSpec, List.append_nil, Option.map_some, hw2]
          simp only [hlen]
          by_cases hlt : r.next < a.size <;> by_cases hcl : r.close = true <;> simp [hlt, hcl]
        · have : (n == 0 && c.writesOk) = false := by
            cases hk : c.writesOk <;> simp_all
          simp only [this, Bool.false_eq_true, ↓reduceIte, hn, StateT.run_pure, id_pure, hdb, true_and,
            ChunkOut.toSpec, List.append_nil]
          simp

/-! ## The batch -/

/-- The read phase over all chunks, on the model: each chunk's read phase from the snapshot. -/
theorem readAll_model (env : Env) (chunks : Array ByteArray) (db : DB) : ∀ fuel i (outs : Array ChunkOut),
    ((readAll (m := Model) env chunks i outs fuel).run db).1.toList =
      outs.toList ++ ((chunks.toList.drop i).take fuel).map fun ch => ((readPhase (m := Model) env ch).run db).1 := by
  intro fuel
  induction fuel with
  | zero => intros; simp [readAll]
  | succ f ih =>
    intro i outs
    simp only [readAll]
    split
    · rename_i hi
      simp only [StateT.run_bind, readPhase]
      rw [run_eq_of_snd (readLoop_db env _ db _ _ _ _)]
      simp only [id_bind]
      rw [ih]
      have hdrop : chunks.toList.drop i = chunks[i] :: chunks.toList.drop (i + 1) := by
        rw [List.drop_eq_getElem_cons (by simpa using hi)]; simp
      rw [hdrop]
      simp [readPhase]
    · rename_i hi
      have : chunks.toList.drop i = [] := List.drop_eq_nil_of_le (by simp; omega)
      simp [this]

/-- `replies` after a commit, on lists: each connection's output, with the next write's answer
appended for a connection that handed one over. -/
def replyList : List ChunkOut → List (Nat × ByteArray) → List Reply
  | [], _ => []
  | o :: os, res =>
    match o.write with
    | some (_, close) =>
      let x := res.headD default
      ⟨respond o.out x.1 x.2 close, 0, o.consumed, o.flags ||| (if close then 1 else 0)⟩ :: replyList os res.tail
    | none => ⟨o.out, 0, o.consumed, o.flags⟩ :: replyList os res

theorem replyList_length : ∀ (outs : List ChunkOut) (res : List (Nat × ByteArray)),
    (replyList outs res).length = outs.length
  | [], _ => rfl
  | o :: os, res => by
    simp only [replyList]
    split <;> simp [replyList_length]

theorem replies_eq (outs : Array ChunkOut) (results : Array (Nat × ByteArray)) : ∀ fuel i wi (acc : Array Reply),
    outs.size ≤ i + fuel →
    (replies true outs results i wi acc fuel).toList =
      acc.toList ++ replyList (outs.toList.drop i) (results.toList.drop wi) := by
  intro fuel
  induction fuel with
  | zero =>
    intro i wi acc h
    have : outs.toList.drop i = [] := List.drop_eq_nil_of_le (by simp; omega)
    simp [replies, this, replyList]
  | succ f ih =>
    intro i wi acc h
    simp only [replies]
    split
    · rename_i hi
      have hdrop : outs.toList.drop i = outs[i] :: outs.toList.drop (i + 1) := by
        rw [List.drop_eq_getElem_cons (by simpa using hi)]; simp
      rw [hdrop]
      split
      · rename_i w c hw
        rw [ih (i + 1) (wi + 1) _ (by omega)]
        have hx : results[wi]! = (results.toList.drop wi).headD default := by
          by_cases hw' : wi < results.size
          · rw [getElem!_pos results wi hw', List.drop_eq_getElem_cons (by simpa using hw')]; simp
          · rw [getElem!_neg results wi hw', List.drop_eq_nil_of_le (by simp; omega)]; rfl
        have ht : results.toList.drop (wi + 1) = (results.toList.drop wi).tail := by
          rw [List.tail_drop]
        simp only [replyList, hw, Array.toList_push, List.append_assoc, List.cons_append, List.nil_append,
          Bool.true_or, ↓reduceIte, hx, ht]
      · rename_i hw
        rw [ih (i + 1) wi _ (by omega)]
        simp only [replyList, hw, Array.toList_push, List.append_assoc, List.cons_append, List.nil_append]
    · rename_i hi
      have : outs.toList.drop i = [] := List.drop_eq_nil_of_le (by simp; omega)
      simp [this, replyList]

theorem perform_toAnswer (db : DB) (w : Write) : w.toAnswer.perform db = w.spec db := by
  cases w <;> rfl

/-- The replies are `Spec.writePhase` of the read phases, given the writes' answers in order. -/
theorem replyList_spec : ∀ (outs : List ChunkOut) (inputs : List ByteArray) (res : List (Nat × ByteArray)) (db : DB),
    outs.length = inputs.length → res.map answerBytes = (applyWrites db (writesOf outs)).1 →
    List.zipWith Reply.toSpec (replyList outs res) inputs =
        (writePhase db (List.zipWith ChunkOut.toSpec outs inputs)).1 ∧
      (writePhase db (List.zipWith ChunkOut.toSpec outs inputs)).2 = (applyWrites db (writesOf outs)).2
  | [], [], res, db, _, _ => by simp [replyList, writePhase, writesOf, applyWrites]
  | [], _ :: _, _, _, hl, _ => by simp at hl
  | _ :: _, [], _, _, hl, _ => by simp at hl
  | o :: os, x :: xs, res, db, hl, hres => by
    cases hw : o.write with
    | none =>
      have hres' : res.map answerBytes = (applyWrites db (writesOf os)).1 := by
        simpa [writesOf, hw] using hres
      obtain ⟨h1, h2⟩ := replyList_spec os xs res db (by simpa using hl) hres'
      simp only [replyList, hw, List.zipWith_cons_cons, writePhase, ChunkOut.toSpec, Option.map_none, h1, h2]
      refine ⟨?_, by simp [writesOf, hw]⟩
      simp [Reply.toSpec]
    | some p =>
      obtain ⟨w, close⟩ := p
      have hws : writesOf (o :: os) = w :: writesOf os := by simp [writesOf, hw]
      rw [hws] at hres ⊢
      cases res with
      | nil => simp [applyWrites] at hres
      | cons y res' =>
        simp only [List.map_cons, applyWrites, List.cons.injEq] at hres
        obtain ⟨hy, hres'⟩ := hres
        obtain ⟨h1, h2⟩ := replyList_spec os xs res' (w.spec db).2 (by simpa using hl) hres'
        simp only [replyList, hw, List.zipWith_cons_cons, writePhase, ChunkOut.toSpec, Option.map_some,
          perform_toAnswer, List.headD_cons, List.tail_cons, h1, h2, applyWrites, and_true]
        simp only [answerBytes, Prod.ext_iff] at hy
        refine congrArg (· :: _) ?_
        simp only [Reply.toSpec, bs_respond, List.drop_zero, hy.1, hy.2]
        cases close
        · simp
        · have : (o.flags ||| 1) % 2 = 1 := by rw [Nat.mod_two_eq_one_iff_testBit_zero, Nat.testBit_or]; simp
          simp [this]

/-- A batch on the model is `Spec.batch`, given that each connection's read phase is
`Spec.connRead`. -/
theorem runBatch_of_reads (env : Env) (secret : ByteArray) (c : Spec.Clock) (chunks : Array ByteArray) (db : DB)
    (hread : ∀ ch : ByteArray, ChunkOut.toSpec ((readPhase (m := Model) env ch).run db).1 ch =
      Spec.connRead (bs secret) c db Spec.maxPipeline 0 (bs ch)) :
    let impl := (runBatch (m := Model) env chunks).run db
    let spec := Spec.batch (bs secret) c db (chunks.toList.map bs)
    impl.2 = spec.2 ∧ impl.1.size = chunks.size ∧ List.zipWith Reply.toSpec impl.1.toList chunks.toList = spec.1 := by
  intro impl spec
  have hreads := readAll_model env chunks db chunks.size 0 (Array.mkEmpty chunks.size)
  simp only [List.drop_zero, List.take_of_length_le (by simp : chunks.toList.length ≤ chunks.size)] at hreads
  simp only [impl, runBatch, StateT.run_bind, run_begin, id_bind, Bool.not_true, Bool.false_eq_true, ↓reduceIte]
  rw [run_eq_of_snd (readAll_db env chunks db _ _ _)]
  generalize ((readAll (m := Model) env chunks 0 (Array.mkEmpty chunks.size) chunks.size).run db).1 = outs at hreads
  simp only [run_endReads]
  have hout : outs.toList = chunks.toList.map fun ch => ((readPhase (m := Model) env ch).run db).1 := by
    rw [hreads]; simp [Array.mkEmpty]
  have hlen : outs.toList.length = chunks.toList.length := by rw [hout, List.length_map]
  have hzip : List.zipWith ChunkOut.toSpec outs.toList chunks.toList =
      (chunks.toList.map bs).map (Spec.connRead (bs secret) c db Spec.maxPipeline 0) := by
    rw [hout, List.zipWith_map_left, List.zipWith_self, List.map_map]
    exact List.map_congr_left fun ch _ => hread ch
  obtain ⟨hw1, hw2⟩ := writeAll_spec outs outs.size 0 (Array.mkEmpty 0) db (by omega)
  simp only [List.drop_zero] at hw1 hw2
  generalize (writeAll (m := Model) outs 0 (Array.mkEmpty 0) outs.size).run db = W at hw1 hw2
  obtain ⟨results, db'⟩ := W
  simp only at hw1 hw2
  simp only [run_commit, StateT.run_pure, id_pure]
  have hrep := replies_eq outs results outs.size 0 0 (Array.mkEmpty outs.size) (by omega)
  simp only [List.drop_zero] at hrep
  obtain ⟨hr1, hr2⟩ := replyList_spec outs.toList chunks.toList results.toList db hlen
    (by simpa [Array.mkEmpty] using hw1)
  refine ⟨?_, ?_, ?_⟩
  · rw [hw2, ← hr2, hzip]; rfl
  · rw [← Array.length_toList, hrep]
    simp [Array.mkEmpty, replyList_length, hlen]
  · rw [hrep]
    simp only [Array.mkEmpty, List.nil_append]
    rw [hr1, hzip]; rfl

/-! ## End to end

The theorems of this section take no statement still to prove as a hypothesis: they use the
theorems `authenticate_spec` and `postText_spec` (through `decide_answer`) and `Http.parse_view`
and `Http.parse_sound` (through `readLoop_connRead`). What they assume is in their arguments: a
storage that meets the contract (`hc`), a state of it that stands for the snapshot (`hs`), and
fewer than 20·2⁶³ posts (`hsize`). `runBatch_correct_model` is `runBatch_correct` at the model,
which meets the contract (`Store.model_contract`). `check-docs.sh` checks that none of the four
takes a hypothesis that does not depend on its other arguments, as a statement still to prove
would be. -/

/-- **One request is answered as the specification says**, on any storage that meets the contract:
the answer is the specification's (`Spec.answer`: the route, the token checked with HMAC-SHA256
under JWT_SECRET's bytes, the body as SPEC.md and schema.sql take it, from the snapshot `db`),
appended to `out` for a reply, handed over for a write; the storage still stands for `db`. -/
theorem decide_correct {σ : Type} [Store (StateM σ)] {R : σ → Spec.DB → Prop} (hc : Store.Contract σ R)
    (secret : ByteArray) (c : Spec.Clock) (a : ByteArray) (r : Http.Req) (out scratch : ByteArray)
    {s : σ} {db : Spec.DB} (hs : R s db) (hsize : db.posts.length < 20 * 2 ^ 63) :
    let st := (decide (m := StateM σ) ⟨Hmac.Key.of secret, c.now, c.uptime, c.writesOk⟩ a r out scratch).run s
    R st.2 db ∧
    match Spec.answer (bs secret) c db (r.toRequest a) with
    | .reply status body => st.1.write = none ∧ bs st.1.out = bs out ++ Spec.response status body r.close
    | w => st.1.write.map Write.toAnswer = some w ∧ st.1.out = out := by
  intro st
  obtain ⟨h1, h2⟩ := decide_sim hc ⟨Hmac.Key.of secret, c.now, c.uptime, c.writesOk⟩ a r out scratch hs
  obtain ⟨m1, m2⟩ := decide_answer secret c a r out scratch db hsize
  simp only [st, h1]
  rw [m1] at h2
  exact ⟨h2, m2⟩

/-- **A connection's read phase is the specification's**, on any storage that meets the contract:
`Spec.connRead`, its requests framed by `Spec.Http.frame` and each answered with `Spec.answer` from
the snapshot `db`, until the input is used up or incomplete, the input is malformed, a write comes
(handed over only as the connection's first request while writes are on), the connection is to
close, or `fuel` requests were answered; the storage still stands for `db`. -/
theorem readLoop_correct {σ : Type} [Store (StateM σ)] {R : σ → Spec.DB → Prop} (hc : Store.Contract σ R)
    (secret : ByteArray) (c : Spec.Clock) (a : ByteArray) {s : σ} {db : Spec.DB} (hs : R s db)
    (hsize : db.posts.length < 20 * 2 ^ 63) :
    ∀ fuel pos n, pos ≤ a.size →
      let o := (readLoop (m := StateM σ) ⟨Hmac.Key.of secret, c.now, c.uptime, c.writesOk⟩ a pos n
        ByteArray.empty fuel).run s
      R o.2 db ∧ ChunkOut.toSpec o.1 a = Spec.connRead (bs secret) c db fuel n ((bs a).drop pos) := by
  intro fuel pos n hp o
  obtain ⟨h1, h2⟩ := readLoop_sim hc ⟨Hmac.Key.of secret, c.now, c.uptime, c.writesOk⟩ a fuel pos n ByteArray.empty hs
  obtain ⟨m1, m2⟩ := readLoop_connRead secret c a db
    (fun r out => decide_answer secret c a r out ByteArray.empty db hsize)
    fuel pos n ByteArray.empty hp
  simp only [o, h1]
  rw [m1] at h2
  refine ⟨h2, ?_⟩
  rw [m2]
  simp

/-- **The batch, end to end**, on any storage that meets the contract: for every connection's input
and any database the storage stands for, what `Spec.batch` computes from the input bytes, the
snapshot, JWT_SECRET's bytes and the clock: the bytes sent to each connection, the input it keeps,
whether it closes or is presented again, and a state that stands for the database after the
batch's writes. -/
theorem runBatch_correct {σ : Type} [Store (StateM σ)] {R : σ → Spec.DB → Prop} (hc : Store.Contract σ R)
    (secret : ByteArray) (c : Spec.Clock) (chunks : Array ByteArray) {s : σ} {db : Spec.DB} (hs : R s db)
    (hsize : db.posts.length < 20 * 2 ^ 63) :
    let impl := (runBatch (m := StateM σ) ⟨Hmac.Key.of secret, c.now, c.uptime, c.writesOk⟩ chunks).run s
    let spec := Spec.batch (bs secret) c db (chunks.toList.map bs)
    R impl.2 spec.2 ∧ impl.1.size = chunks.size ∧
      List.zipWith Reply.toSpec impl.1.toList chunks.toList = spec.1 := by
  intro impl spec
  have hpost : ∀ a r t, postText a r = .ok t → ∃ u, Body.accept u = .ok (bs t) := fun a r t h =>
    ⟨(r.toRequest a).body, (postText_spec a r).symm.trans (by rw [h]; rfl)⟩
  obtain ⟨h1, h2⟩ := runBatch_sim hc hpost ⟨Hmac.Key.of secret, c.now, c.uptime, c.writesOk⟩ chunks hs
  obtain ⟨m1, m2, m3⟩ := runBatch_of_reads ⟨Hmac.Key.of secret, c.now, c.uptime, c.writesOk⟩ secret c chunks db
    fun ch => by
      obtain ⟨-, h⟩ := readLoop_connRead secret c ch db
        (fun r out => decide_answer secret c ch r out ByteArray.empty db hsize)
        maxPipeline 0 0 ByteArray.empty (Nat.zero_le _)
      rw [readPhase, h]
      simp [maxPipeline, Spec.maxPipeline]
  simp only [impl, spec, h1]
  rw [m1] at h2
  exact ⟨h2, m2, m3⟩

/-- `runBatch_correct` on the model, whose states are the databases. -/
theorem runBatch_correct_model (secret : ByteArray) (c : Spec.Clock) (chunks : Array ByteArray) (db : Spec.DB)
    (hsize : db.posts.length < 20 * 2 ^ 63) :
    let impl := (runBatch (m := Model) ⟨Hmac.Key.of secret, c.now, c.uptime, c.writesOk⟩ chunks).run db
    let spec := Spec.batch (bs secret) c db (chunks.toList.map bs)
    impl.2 = spec.2 ∧ impl.1.size = chunks.size ∧
      List.zipWith Reply.toSpec impl.1.toList chunks.toList = spec.1 :=
  runBatch_correct Store.model_contract secret c chunks rfl hsize

/-- info: 'Feed.decide_sim' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms decide_sim

/-- info: 'Feed.readLoop_sim' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms readLoop_sim

/-- info: 'Feed.readAll_accepted' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms readAll_accepted

/-- info: 'Feed.runBatch_sim' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms runBatch_sim

/-- info: 'Feed.readLoop_bad' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms readLoop_bad

/-- info: 'Feed.readLoop_reply' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms readLoop_reply

/-- info: 'Feed.decide_correct' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms decide_correct

/-- info: 'Feed.readLoop_correct' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms readLoop_correct

/-- info: 'Feed.runBatch_correct' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms runBatch_correct

/-- info: 'Feed.runBatch_correct_model' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms runBatch_correct_model

end Feed
