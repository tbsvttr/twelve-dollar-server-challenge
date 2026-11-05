import Feed.Proofs.Decide
import Feed.Proofs.HttpLines
import Feed.Proofs.Write
import Feed.Server

/-!
# Batches

`runBatch` on the model is a serial execution: every request answered in the read phase is
answered from the snapshot the batch started with, as if it ran before all of the batch's writes;
the writes then run one after another in connection order, each seeing the ones before it; the
database at the end is the snapshot with those writes applied. A connection's requests stay in
order: its answered reads come before its write, and nothing after its write is answered in the
same batch.
-/
namespace Feed
open Spec Http

/-! ## Reads leave the snapshot as it is -/

theorem feedLoop_db (db : DB) (close : Bool) : ∀ (fuel want : Nat) (out : ByteArray),
    ((feedLoop (m := Model) out close want fuel).run db).2 = db := by
  intro fuel
  induction fuel with
  | zero => intro want out; rfl
  | succ f ih =>
    intro want out
    simp only [feedLoop, StateT.run_bind, run_feedPage, id_bind]
    split
    · rfl
    · exact ih _ _

theorem postResponse_db (db : DB) (out : ByteArray) (pid : Nat) (close : Bool) :
    ((postResponse (m := Model) out pid close).run db).2 = db := by
  rfl

/-- A request's read phase does not change the database. -/
theorem decide_db (env : Env) (a : ByteArray) (r : Req) (out scratch : ByteArray) (db : DB) :
    ((decide (m := Model) env a r out scratch).run db).2 = db := by
  simp only [decide]
  split
  · simp only [StateT.run_bind]
    rw [run_eq_of_snd (show ((feedResponse (m := Model) out r.close).run db).2 = db from feedLoop_db db _ _ _ _)]
    rfl
  · rfl
  · simp only [StateT.run_bind]
    rw [run_eq_of_snd (postResponse_db db _ _ _)]
    rfl
  · simp only [StateT.run_bind, run_health, id_bind, ↓reduceIte]; rfl
  · split
    · rfl
    · split <;> rfl
  · split
    · rfl
    · split <;> rfl
  · rfl

theorem readLoop_db (env : Env) (a : ByteArray) (db : DB) : ∀ fuel pos n (out : ByteArray),
    ((readLoop (m := Model) env a pos n out fuel).run db).2 = db := by
  intro fuel
  induction fuel with
  | zero => intros; rfl
  | succ f ih =>
    intro pos n out
    simp only [readLoop]
    split
    · rfl
    · rfl
    · simp only [StateT.run_bind]
      rw [run_eq_of_snd (decide_db env a _ out ByteArray.empty db)]
      simp only [id_bind]
      split
      · split <;> rfl
      · split
        · rfl
        · exact ih _ _ _

theorem readAll_db (env : Env) (chunks : Array ByteArray) (db : DB) : ∀ fuel i (outs : Array ChunkOut),
    ((readAll (m := Model) env chunks i outs fuel).run db).2 = db := by
  intro fuel
  induction fuel with
  | zero => intros; rfl
  | succ f ih =>
    intro i outs
    simp only [readAll]
    split
    · simp only [StateT.run_bind, readPhase]
      rw [run_eq_of_snd (readLoop_db env _ db _ _ _ _)]
      exact ih _ _
    · rfl

/-! ## Writes in order -/

/-- The specification's answer to a write (status and body) and the database after it. -/
def Write.spec (db : DB) : Write → (Nat × List UInt8) × DB
  | .like uid pid => db.like uid pid
  | .create uid text name => db.create uid (bs text) (bs name)

/-- The writes one after another, each on the database the ones before it left: their answers
and the database at the end. -/
def applyWrites : DB → List Write → List (Nat × List UInt8) × DB
  | db, [] => ([], db)
  | db, w :: ws =>
    let a := w.spec db
    let rest := applyWrites a.2 ws
    (a.1 :: rest.1, rest.2)

theorem perform_spec (db : DB) (w : Write) :
    let r := (perform (m := Model) w).run db
    (r.1.1, bs r.1.2) = (w.spec db).1 ∧ r.2 = (w.spec db).2 := by
  cases w with
  | like uid pid =>
    obtain ⟨h1, h2, h3⟩ := perform_like db uid pid
    exact ⟨Prod.ext h1 h2, h3⟩
  | create uid text name =>
    obtain ⟨h1, h2, h3⟩ := perform_create db uid text name
    exact ⟨Prod.ext h1 h2, h3⟩

/-- The writes the read phase handed over, in connection order. -/
def writesOf (outs : List ChunkOut) : List Write := outs.filterMap fun o => o.write.map (·.1)

def answerBytes (x : Nat × ByteArray) : Nat × List UInt8 := (x.1, bs x.2)

theorem writeAll_spec (outs : Array ChunkOut) : ∀ fuel i (res : Array (Nat × ByteArray)) (db : DB),
    outs.size ≤ i + fuel →
    let r := (writeAll (m := Model) outs i res fuel).run db
    r.1.toList.map answerBytes = res.toList.map answerBytes ++ (applyWrites db (writesOf (outs.toList.drop i))).1 ∧
    r.2 = (applyWrites db (writesOf (outs.toList.drop i))).2 := by
  intro fuel
  induction fuel with
  | zero =>
    intro i res db h
    have : outs.toList.drop i = [] := List.drop_eq_nil_of_le (by simp; omega)
    simp [writeAll, this, writesOf, applyWrites]
  | succ f ih =>
    intro i res db h
    simp only [writeAll]
    split
    · rename_i hi
      have hdrop : outs.toList.drop i = outs[i] :: outs.toList.drop (i + 1) := by
        rw [List.drop_eq_getElem_cons (by simpa using hi)]; simp
      rw [hdrop]
      split
      · rename_i w c hw
        simp only [StateT.run_bind]
        obtain ⟨hp1, hp2⟩ := perform_spec db w
        generalize hr : (perform (m := Model) w).run db = pr at hp1 hp2
        obtain ⟨x, db1⟩ := pr
        simp only at hp1 hp2
        simp only [id_bind]
        obtain ⟨h1, h2⟩ := ih (i + 1) (res.push x) db1 (by omega)
        simp only [writesOf, List.filterMap_cons, hw, Option.map_some] at h1 h2 ⊢
        refine ⟨?_, ?_⟩
        · rw [h1]
          simp only [Array.toList_push, List.map_append, List.map_cons, List.map_nil, applyWrites, List.append_assoc,
            List.cons_append, List.nil_append]
          rw [show answerBytes x = (w.spec db).1 from hp1, hp2]
        · rw [h2, applyWrites, hp2]
      · rename_i hw
        simp only [writesOf, List.filterMap_cons, hw, Option.map_none] at ih ⊢
        exact ih (i + 1) res db (by omega)
    · rename_i hi
      have : outs.toList.drop i = [] := List.drop_eq_nil_of_le (by simp; omega)
      simp [this, writesOf, applyWrites]

/-! ## Replies -/

/-- The bytes each connection gets: its read answers, then for a connection whose write was
performed, the answer of that write (the `k`-th one for the `k`-th such connection). -/
def replyBytes : List ChunkOut → List (Nat × List UInt8) → List (List UInt8)
  | [], _ => []
  | o :: os, ans =>
    match o.write with
    | some (_, close) =>
      match ans with
      | a :: ans' => (bs o.out ++ response a.1 a.2 close) :: replyBytes os ans'
      | [] => (bs o.out ++ response 0 [] close) :: replyBytes os []
    | none => bs o.out :: replyBytes os ans

theorem replies_spec (outs : Array ChunkOut) (results : Array (Nat × ByteArray)) : ∀ fuel i wi (acc : Array Reply),
    outs.size ≤ i + fuel →
    (replies true outs results i wi acc fuel).toList.map (fun r => bs r.resp) =
      acc.toList.map (fun r => bs r.resp) ++ replyBytes (outs.toList.drop i) ((results.toList.drop wi).map answerBytes) := by
  intro fuel
  induction fuel with
  | zero =>
    intro i wi acc h
    have : outs.toList.drop i = [] := List.drop_eq_nil_of_le (by simp; omega)
    simp [replies, this, replyBytes]
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
        simp only [replyBytes, hw, Array.toList_push, List.map_append, List.map_cons, List.map_nil, List.append_assoc,
          List.cons_append, List.nil_append, Bool.true_or, ↓reduceIte]
        by_cases hw' : wi < results.size
        · have hd : results.toList.drop wi = results[wi] :: results.toList.drop (wi + 1) := by
            rw [List.drop_eq_getElem_cons (by simpa using hw')]; simp
          rw [hd, getElem!_pos results wi hw']
          simp only [List.map_cons, answerBytes, bs_respond]
        · have hd : results.toList.drop wi = [] := List.drop_eq_nil_of_le (by simp; omega)
          have hd' : results.toList.drop (wi + 1) = [] := List.drop_eq_nil_of_le (by simp; omega)
          rw [hd, hd', getElem!_neg results wi hw']
          simp only [List.map_nil, bs_respond]
          rfl
      · rename_i hw
        rw [ih (i + 1) wi _ (by omega)]
        simp only [replyBytes, hw, Array.toList_push, List.map_append, List.map_cons, List.map_nil, List.append_assoc,
          List.cons_append, List.nil_append]
    · rename_i hi
      have : outs.toList.drop i = [] := List.drop_eq_nil_of_le (by simp; omega)
      simp [this, replyBytes]

/-! ## One connection's read phase -/

theorem bs_rejectBody (st : Nat) : bs (rejectBody st) = Spec.Http.badBody st := by
  unfold rejectBody Spec.Http.badBody
  by_cases h3 : st = 413
  · subst h3; rfl
  by_cases h4 : st = 414
  · subst h4; rfl
  by_cases h1 : st = 431
  · subst h1; rfl
  rw [ite_eq_right (by simpa using h3), ite_eq_right (by simpa using h4), ite_eq_right (by simpa using h1)]
  split
  · exact absurd rfl h3
  · exact absurd rfl h4
  · exact absurd rfl h1
  · rfl

/-- The answer to malformed input is the specification's. -/
theorem bs_respondReject (out : ByteArray) (head : Bool) (st : Nat) :
    bs (respondReject out head st) = bs out ++ Spec.Http.rejectResponse head st := by
  have hline : bs (if st == 414 then k414 else statusLine st) = Spec.lit ("HTTP/1.1 " ++ Spec.Http.rejectPhrase st ++
      "\r\nContent-Type: application/json\r\nContent-Length: ") := by
    by_cases h : st = 414
    · subst h; rfl
    · rw [ite_eq_right (by simpa using h), bs_statusLine, Spec.Http.rejectPhrase, ite_eq_right h]
  have hsize : (rejectBody st).size = (Spec.Http.badBody st).length := by rw [size_eq_length, bs_rejectBody]
  unfold respondReject Spec.Http.rejectResponse Spec.Http.rejectHead
  cases head <;> simp only [Bool.false_eq_true, ↓reduceIte, bs_appendAll, bs_appendNat, hline, hsize, bs_rejectBody,
    endHeadClose, bs_lit, List.append_assoc]

/-- info: 'Feed.bs_respondReject' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms bs_respondReject

/-- The answer to HEAD is the head of the response GET gets, which `x` ends with from `out`'s size. -/
theorem bs_stripBody (x out : ByteArray) (st : Nat) (b : List UInt8) (close : Bool)
    (h : bs x = bs out ++ Spec.response st b close) :
    bs (stripBody x out.size) = bs out ++ Spec.Http.responseHead st b close := by
  have hsz : x.size = out.size + (Spec.response st b close).length := by
    rw [size_eq_length x, size_eq_length out, h, List.length_append]
  have hsl : slice x out.size x.size = Spec.response st b close := by
    simp only [slice]
    rw [show x.data.toList = bs x from rfl, h, size_eq_length out, List.drop_left, hsz, size_eq_length out]
    simp
  have hlen : 4 ≤ (Spec.Http.responseHead st b close).length := by
    have h1 : (Spec.lit "\r\nConnection: close\r\n\r\n").length = 23 := rfl
    have h2 : (Spec.lit "\r\n\r\n").length = 4 := rfl
    simp only [Spec.Http.responseHead, List.length_append]
    cases close <;> simp only [Bool.false_eq_true, ↓reduceIte, h1, h2] <;> omega
  unfold stripBody
  rw [Http.headEnd_eq x (by omega) (Nat.le_refl _), hsl, crlf2Idx_response]
  simp only [Option.map_some]
  rw [show bs (x.extract 0 (out.size + ((Spec.Http.responseHead st b close).length - 4) + 4)) =
      (bs x).take (out.size + (Spec.Http.responseHead st b close).length) by
    simp only [bs, ByteArray.data_extract, Array.toList_extract, List.extract, List.drop_zero]
    congr 1 <;> omega]
  rw [h, Spec.Http.response_eq_head, size_eq_length out, ← List.append_assoc, List.take_left' (by simp)]

/-- info: 'Feed.bs_stripBody' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms bs_stripBody

/-- The specification's read phase of one connection's input `a` from position `pos`, `n`
requests answered so far: the requests in order, each answered with the specification's outcome
from the snapshot `db`, until the input runs out, a request is incomplete or malformed, a write
comes, or the connection is to close. A write is handed over when it is the connection's first
request of the batch and writes are on; otherwise it waits, with everything after it, for the next
batch. Malformed input gets `Spec.Http.rejectResponse`, and a HEAD request the head of GET's
response (`Spec.Http.responseHead`). Result: the answers' bytes, the input used, the transport's
flags, the write handed over. -/
def specRead (env : Env) (db : DB) (a : ByteArray) :
    Nat → Nat → Nat → List UInt8 × Nat × Nat × Option (Write × Bool)
  | pos, _, 0 => ([], pos, if pos < a.size then 2 else 0, none)
  | pos, n, fuel + 1 =>
    match Http.parse a pos with
    | .incomplete => ([], pos, 0, none)
    | .bad st => (Spec.Http.rejectResponse (Spec.Http.headRequest ((bs a).drop pos)) st, a.size, 1, none)
    | .ok r =>
      match expected env db (Spec.route r.method (slice a r.pathLo r.pathHi)) (authenticate env.key env.now a r)
          (postText a r) with
      | .write w =>
        if n == 0 && env.writesOk then ([], r.next, if r.next < a.size then 2 else 0, some (w, r.close))
        else ([], pos, 2, none)
      | .reply st body =>
        let bytes := if r.head then Spec.Http.responseHead st body r.close else response st body r.close
        if r.close then (bytes, r.next, 1, none)
        else
          let rest := specRead env db a r.next (n + 1) fuel
          (bytes ++ rest.1, rest.2)

/-- What the transport takes from a connection's read phase. -/
def ChunkOut.view (o : ChunkOut) : List UInt8 × Nat × Nat × Option (Write × Bool) :=
  (bs o.out, o.consumed, o.flags, o.write)

theorem readLoop_spec (env : Env) (a : ByteArray) (db : DB) (hsize : db.posts.length < 20 * 2 ^ 63) :
    ∀ fuel pos n (out : ByteArray),
      let o := ((readLoop (m := Model) env a pos n out fuel).run db).1
      let s := specRead env db a pos n fuel
      bs o.out = bs out ++ s.1 ∧ o.consumed = s.2.1 ∧ o.flags = s.2.2.1 ∧ o.write = s.2.2.2 := by
  intro fuel
  induction fuel with
  | zero => intro pos n out; simp [readLoop, specRead]
  | succ f ih =>
    intro pos n out
    simp only [readLoop, specRead]
    cases Http.parse a pos with
    | incomplete => simp
    | bad st =>
      simp only [StateT.run_pure, id_pure]
      refine ⟨by rw [bs_respondReject, Http.headAt_eq], ?_, ?_, ?_⟩ <;> trivial
    | ok r =>
      obtain ⟨hst, hreal⟩ := decide_spec env a r out ByteArray.empty db hsize
      simp only [StateT.run_bind]
      rw [run_eq_of_snd hst]
      simp only [id_bind]
      generalize ((decide (m := Model) env a r out ByteArray.empty).run db).1 = st at hreal
      generalize expected env db (Spec.route r.method (slice a r.pathLo r.pathHi)) (authenticate env.key env.now a r)
        (postText a r) = oc at hreal
      cases oc with
      | write w =>
        obtain ⟨hw, ho⟩ := hreal
        simp only [hw]
        split <;> simp [ho]
      | reply status body =>
        obtain ⟨hw, ho⟩ := hreal
        have hb : bs (if r.head then stripBody st.out out.size else st.out) = bs out ++
            (if r.head then Spec.Http.responseHead status body r.close else response status body r.close) := by
          cases r.head
          · simpa using ho
          · simpa using bs_stripBody st.out out status body r.close ho
        simp only [hw]
        split
        · exact ⟨hb, rfl, rfl, rfl⟩
        · obtain ⟨h1, h2, h3, h4⟩ := ih r.next (n + 1) (if r.head then stripBody st.out out.size else st.out)
          exact ⟨by rw [h1, hb, List.append_assoc], h2, h3, h4⟩

/-- info: 'Feed.readLoop_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms readLoop_spec

/-- `specRead` as it was before HEAD and 414 got their own answers (version 011a111), on the parse
of this version. -/
def specReadOld (env : Env) (db : DB) (a : ByteArray) :
    Nat → Nat → Nat → List UInt8 × Nat × Nat × Option (Write × Bool)
  | pos, _, 0 => ([], pos, if pos < a.size then 2 else 0, none)
  | pos, n, fuel + 1 =>
    match Http.parse a pos with
    | .incomplete => ([], pos, 0, none)
    | .bad st =>
      let e := if st == 413 then Err.tooLarge else if st == 431 then Err.headTooLarge else Err.badRequest
      (response e.status (bs e.body) true, a.size, 1, none)
    | .ok r =>
      match expected env db (Spec.route r.method (slice a r.pathLo r.pathHi)) (authenticate env.key env.now a r)
          (postText a r) with
      | .write w =>
        if n == 0 && env.writesOk then ([], r.next, if r.next < a.size then 2 else 0, some (w, r.close))
        else ([], pos, 2, none)
      | .reply st body =>
        if r.close then (response st body r.close, r.next, 1, none)
        else
          let rest := specReadOld env db a r.next (n + 1) fuel
          (response st body r.close ++ rest.1, rest.2)

/-- **What `readLoop_spec` says changed only for HEAD and 414**, and so what `readAll_spec` and
`runBatch_spec` say, which are stated with `specRead` too: on input in which no request is a HEAD
request and every malformed one is answered 400, 413 or 431 and does not start with "HEAD ",
`specRead` is the definition they were stated with before, on this version's parser. -/
theorem specRead_eq_old (env : Env) (db : DB) (a : ByteArray)
    (hbad : ∀ p st, Http.parse a p = .bad st →
      (st = 400 ∨ st = 413 ∨ st = 431) ∧ Spec.Http.headRequest ((bs a).drop p) = false)
    (hok : ∀ p r, Http.parse a p = .ok r → r.head = false) :
    ∀ fuel pos n, specRead env db a pos n fuel = specReadOld env db a pos n fuel := by
  intro fuel
  induction fuel with
  | zero => intro pos n; rfl
  | succ f ih =>
    intro pos n
    simp only [specRead, specReadOld]
    split
    · rfl
    · rename_i st hp
      obtain ⟨hst, hh⟩ := hbad pos st hp
      rw [hh, Spec.Http.rejectResponse_false (by omega)]
      rcases hst with rfl | rfl | rfl
      · rw [bs_err_body]; rfl
      · rw [bs_err_body]; rfl
      · rw [bs_err_body]; rfl
    · rename_i r hp
      have hr := hok pos r hp
      split
      · rfl
      · simp only [hr, Bool.false_eq_true, ↓reduceIte]
        split
        · rfl
        · rw [ih]

/-- info: 'Feed.specRead_eq_old' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms specRead_eq_old

theorem readAll_spec (env : Env) (chunks : Array ByteArray) (db : DB)
    (hsize : db.posts.length < 20 * 2 ^ 63) : ∀ fuel i (outs : Array ChunkOut),
      ((readAll (m := Model) env chunks i outs fuel).run db).1.toList.map ChunkOut.view =
        outs.toList.map ChunkOut.view ++
          ((chunks.toList.drop i).take fuel).map fun c => specRead env db c 0 0 maxPipeline := by
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
      obtain ⟨h1, h2, h3, h4⟩ := readLoop_spec env chunks[i] db hsize maxPipeline 0 0 ByteArray.empty
      rw [hdrop]
      simp only [Array.toList_push, List.map_append, List.map_cons, List.map_nil, List.take_succ_cons,
        List.append_assoc, List.cons_append, List.nil_append]
      congr 2
      simp only [ChunkOut.view, h1, h2, h3, h4, bs_empty, List.nil_append]
    · rename_i hi
      have : chunks.toList.drop i = [] := List.drop_eq_nil_of_le (by simp; omega)
      simp [this]

/-! ## The batch -/

/-- The bytes each connection gets, from the views of the read phases and the writes' answers. -/
def replyView : List (List UInt8 × Nat × Nat × Option (Write × Bool)) → List (Nat × List UInt8) → List (List UInt8)
  | [], _ => []
  | v :: vs, ans =>
    match v.2.2.2 with
    | some (_, close) =>
      match ans with
      | a :: ans' => (v.1 ++ response a.1 a.2 close) :: replyView vs ans'
      | [] => (v.1 ++ response 0 [] close) :: replyView vs []
    | none => v.1 :: replyView vs ans

theorem replyBytes_view (outs : List ChunkOut) (ans : List (Nat × List UInt8)) :
    replyBytes outs ans = replyView (outs.map ChunkOut.view) ans := by
  induction outs generalizing ans with
  | nil => rfl
  | cons o os ih =>
    simp only [replyBytes, List.map_cons, replyView, ChunkOut.view]
    split
    · cases ans <;> simp [ih]
    · simp [ih]

theorem writesOf_view (outs : List ChunkOut) :
    writesOf outs = (outs.map ChunkOut.view).filterMap fun v => v.2.2.2.map (·.1) := by
  simp [writesOf, List.filterMap_map, ChunkOut.view, Function.comp_def]

@[simp] theorem run_begin (db : DB) : (Store.begin (m := Model)).run db = (true, db) := rfl
@[simp] theorem run_endReads (db : DB) : (Store.endReads (m := Model)).run db = ((), db) := rfl
@[simp] theorem run_commit (db : DB) : (Store.commit (m := Model)).run db = (true, db) := rfl

/-- **A batch is a serial execution.** Run on the snapshot `db`, the batch answers every
connection with the specification's answers to the requests of its read phase, all computed
from `db`, followed by the answer of its write, if it handed one over; the writes run in
connection order, each on the database the earlier ones left, and the database ends as `db`
with all of them applied. This is the result of running, one at a time, first every answered
read and then every write: each connection's requests keep their order, and no answer leaves
before the batch has committed. -/
theorem runBatch_spec (env : Env) (chunks : Array ByteArray) (db : DB)
    (hsize : db.posts.length < 20 * 2 ^ 63) :
    let reads := chunks.toList.map fun c => specRead env db c 0 0 maxPipeline
    let w := applyWrites db (reads.filterMap fun v => v.2.2.2.map (·.1))
    let r := (runBatch (m := Model) env chunks).run db
    r.2 = w.2 ∧ r.1.toList.map (fun rep => bs rep.resp) = replyView reads w.1 := by
  intro reads w r
  have hreads := readAll_spec env chunks db hsize chunks.size 0 (Array.mkEmpty chunks.size)
  simp only [List.drop_zero, List.take_of_length_le (by simp : chunks.toList.length ≤ chunks.size)] at hreads
  simp only [r, runBatch, StateT.run_bind, run_begin, id_bind, Bool.not_true, Bool.false_eq_true, ↓reduceIte]
  rw [run_eq_of_snd (readAll_db env chunks db _ _ _)]
  generalize ((readAll (m := Model) env chunks 0 (Array.mkEmpty chunks.size) chunks.size).run db).1 = outs at hreads
  simp only [run_endReads]
  have hv : outs.toList.map ChunkOut.view = reads := by
    rw [hreads]; simp [reads, Array.mkEmpty]
  obtain ⟨hw1, hw2⟩ := writeAll_spec outs outs.size 0 (Array.mkEmpty 0) db (by omega)
  simp only [List.drop_zero, writesOf_view, hv] at hw1 hw2
  generalize (writeAll (m := Model) outs 0 (Array.mkEmpty 0) outs.size).run db = W at hw1 hw2
  obtain ⟨results, db'⟩ := W
  simp only at hw1 hw2
  simp only [run_commit, StateT.run_pure, id_pure]
  refine ⟨hw2, ?_⟩
  rw [replies_spec outs results outs.size 0 0 (Array.mkEmpty outs.size) (by omega)]
  simp only [List.drop_zero, replyBytes_view, hv, hw1]
  simp [Array.mkEmpty, w]

/-- info: 'Feed.runBatch_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms runBatch_spec

end Feed
