import Feed.Proofs.Plan
import Feed.Spec.Body

/-!
# The storage contract

What the theorems ask of a storage implementation, as a relation to the specification's database.
An implementation runs on states `σ`, and `R s db` says that the state `s` stands for the
database `db`. From a state that stands for `db`, each operation returns what the specification
says of `db` (a page up to `Page.Same`, which the handler cannot tell apart) and leaves a state
that stands for the database after it. The model meets the contract with the databases themselves
as states (`Store.model_contract`).

`insertPost` is asked to do so only for a body that is a post's text as the API takes it, what
`Spec.Body.accept` returns for some request body: the UTF-8 of 1 to 500 characters, with no
whitespace at either end and not led by U+0000. The handler inserts no other body: each write a
read phase hands over carries a text `postText` accepted (`readAll_accepted` in
`Feed/Proofs/EndToEnd.lean`), and by `postText_spec` (`Feed/Proofs/Body.lean`) such a text is what
`Spec.Body.accept` returns. The premise is needed: schema.sql's
`CHECK (length(body) BETWEEN 1 AND 500)` refuses a body in which SQLite's `length` counts no
character before the first NUL, one led by U+0000 for instance, or more than 500, and SQLite adds
no row for it where the model adds one, so db.c does not meet a contract for every body. Every
body of the premise passes the CHECK (`Spec.Body.accept` ends with `schemaOk`), and no narrower
premise covers the texts the handler can insert, so the contract asks nothing of db.c about a body
it is never given. Because of the premise, `model_contract` says what the model's `insertPost`
does only with such bodies; `run_insertPost` (`Feed/Proofs/Write.lean`) says what it does with
every body.

The contract is about a storage whose operations are state transformers, a `Store (StateM σ)`.
The server runs the handler at `IO` (`Store IO`, `Feed/Store.lean`), whose operations are the C
functions of `runtime/db.c` on the SQLite file and the memory db.c keeps. Lean has no model of
their effects, so the contract cannot be stated of them, and the step from a theorem about
`runBatch` on a `StateM σ` storage that meets the contract to `Feed.batch`, which is `runBatch` at
`IO` (`batch_eq`), is assumed, not proved: that db.c, run at `IO`, does what some storage meeting
this contract does. The self-test checks each operation against the model on a random database
(`Feed/Selftest.lean`: `checkReads`, `checkWrites`, `checkBatch`), `insertPost` also on bodies
outside the premise: random ones over an alphabet with a space and a tab, which may be at either
end, and bodies led by U+0000, which must add no row. Parts of the contract hold of SQLite only
under conditions a test does not reach: no operation fails (`begin`, `health` and `commit`
succeed, every lookup and insert answers), and a new post's id is one more than the largest, which
SQLite does while ids stay below 2^63 - 1. Every post of a write phase gets the database's one
`clock` as its `created_at`, and db.c takes the time once per write phase, at its first insert
(`checkWrites` gives the model one clock per phase).
-/
namespace Feed
open Spec

/-- **The storage contract** of the `Store` operations on states `σ`, under `R`. -/
structure Store.Contract (σ : Type) [Store (StateM σ)] (R : σ → DB → Prop) : Prop where
  begin {s : σ} {db : DB} : R s db →
    ((Store.begin (m := StateM σ)).run s).1 = true ∧ R ((Store.begin (m := StateM σ)).run s).2 db
  feedPage (n : Nat) {s : σ} {db : DB} : R s db →
    ((Store.feedPage (m := StateM σ) n).run s).1.Same (mkPage ((db.sorted.take n).map db.entry)) ∧
      R ((Store.feedPage (m := StateM σ) n).run s).2 db
  postPage (id : Nat) {s : σ} {db : DB} : R s db →
    ((Store.postPage (m := StateM σ) id).run s).1.Same (mkPage ((db.post? id).toList.map db.entry)) ∧
      R ((Store.postPage (m := StateM σ) id).run s).2 db
  health {s : σ} {db : DB} : R s db →
    ((Store.health (m := StateM σ)).run s).1 = true ∧ R ((Store.health (m := StateM σ)).run s).2 db
  endReads {s : σ} {db : DB} : R s db → R ((Store.endReads (m := StateM σ)).run s).2 db
  postExists (id : Nat) {s : σ} {db : DB} : R s db →
    ((Store.postExists (m := StateM σ) id).run s).1 = (if (db.post? id).isSome then 1 else 0) ∧
      R ((Store.postExists (m := StateM σ) id).run s).2 db
  insertLike (uid pid : Nat) {s : σ} {db : DB} : R s db →
    ((Store.insertLike (m := StateM σ) uid pid).run s).1 = (if (db.insertLike uid pid).1 then 0 else 1) ∧
      R ((Store.insertLike (m := StateM σ) uid pid).run s).2 (db.insertLike uid pid).2
  /-- for a body that is a post's text as `Spec.Body.accept` returns it, the only bodies the handler
  inserts (the module doc says why the premise is there) -/
  insertPost (uid : Nat) (body : ByteArray) {s : σ} {db : DB} : R s db → (∃ t, Body.accept t = .ok (bs body)) →
    bs ((Store.insertPost (m := StateM σ) uid body).run s).1.1 = (db.insertPost uid (bs body)).1.createdAt ∧
      ((Store.insertPost (m := StateM σ) uid body).run s).1.2 = (db.insertPost uid (bs body)).1.id ∧
      R ((Store.insertPost (m := StateM σ) uid body).run s).2 (db.insertPost uid (bs body)).2
  commit {s : σ} {db : DB} : R s db →
    ((Store.commit (m := StateM σ)).run s).1 = true ∧ R ((Store.commit (m := StateM σ)).run s).2 db

theorem Page.Same.refl (p : Page) : p.Same p := ⟨rfl, fun _ _ => rfl⟩

/-- The model meets the storage contract, its states being the databases they stand for. -/
theorem Store.model_contract : Store.Contract DB (· = ·) where
  begin := by intro _ _ h; subst h; exact ⟨rfl, rfl⟩
  feedPage := by intro _ _ _ h; subst h; exact ⟨Page.Same.refl _, rfl⟩
  postPage := by intro _ _ _ h; subst h; exact ⟨Page.Same.refl _, rfl⟩
  health := by intro _ _ h; subst h; exact ⟨rfl, rfl⟩
  endReads := by intro _ _ h; subst h; rfl
  postExists := by intro _ _ _ h; subst h; exact ⟨rfl, rfl⟩
  insertLike := by intro _ _ _ _ h; subst h; exact ⟨rfl, rfl⟩
  insertPost := by intro _ _ _ _ h _; subst h; exact ⟨bs_mk _, rfl, rfl⟩
  commit := by intro _ _ h; subst h; exact ⟨rfl, rfl⟩

/-- info: 'Feed.Store.model_contract' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Store.model_contract

end Feed
