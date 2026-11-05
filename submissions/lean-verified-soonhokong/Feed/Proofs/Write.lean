import Feed.Proofs.Plan

/-!
# The writes

`perform` (the write phase of a batch) run on the model gives the specification's answers and
changes the tables as the specification does.
-/
namespace Feed
open Spec

@[simp] theorem run_postExists (id : Nat) (db : DB) :
    (Store.postExists (m := Model) id).run db = (if (db.post? id).isSome then 1 else 0, db) := rfl
@[simp] theorem run_insertLike (uid pid : Nat) (db : DB) :
    (Store.insertLike (m := Model) uid pid).run db =
      (if (db.insertLike uid pid).1 then 0 else 1, (db.insertLike uid pid).2) := rfl
@[simp] theorem run_insertPost (uid : Nat) (body : ByteArray) (db : DB) :
    (Store.insertPost (m := Model) uid body).run db =
      ((⟨(db.insertPost uid (bs body)).1.createdAt.toArray⟩, (db.insertPost uid (bs body)).1.id),
        (db.insertPost uid (bs body)).2) := rfl

/-- **A like answers and writes as the specification says.** -/
theorem perform_like (db : DB) (uid pid : Nat) :
    let r := (perform (m := Model) (.like uid pid)).run db
    r.1.1 = (db.like uid pid).1.1 ∧ bs r.1.2 = (db.like uid pid).1.2 ∧ r.2 = (db.like uid pid).2 := by
  intro r
  simp only [r, perform, StateT.run_bind, run_postExists, id_bind]
  cases hp : db.post? pid with
  | none =>
    simp [DB.like, hp, errJson, Err.body]
    rfl
  | some p =>
    simp only [Option.isSome_some, ↓reduceIte, StateT.run_bind, run_insertLike, id_bind, DB.like, hp]
    cases hh : (db.insertLike uid pid).1 <;>
      simp [kLiked, kTrue, kFalse, kLikedPost, kWrapEnd, likeJson]

/-- info: 'Feed.perform_like' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms perform_like

theorem DB.nextPostId_pos (db : DB) : db.nextPostId ≠ 0 := by simp [DB.nextPostId]

/-- **A new post answers and writes as the specification says**: the row the insert adds, with
the token's username as author and no likes. -/
theorem perform_create (db : DB) (uid : Nat) (text name : ByteArray) :
    let r := (perform (m := Model) (.create uid text name)).run db
    r.1.1 = (db.create uid (bs text) (bs name)).1.1 ∧ bs r.1.2 = (db.create uid (bs text) (bs name)).1.2 ∧
    r.2 = (db.create uid (bs text) (bs name)).2 := by
  intro r
  simp only [r, perform, StateT.run_bind, run_insertPost, id_bind, DB.create]
  have hid : (db.insertPost uid (bs text)).1.id ≠ 0 := by simp [DB.insertPost, DB.nextPostId_pos]
  simp only [hid, beq_iff_eq, ↓reduceIte, StateT.run_pure, id_pure]
  refine ⟨trivial, ?_, trivial⟩
  simp only [bs_appendAll, bs_appendNat, bs_appendEsc, bs_emptyWithCapacity, List.nil_append, kPostWrap, kId, kBody,
    kCreated, kAuthor, kZeroLikes, bs_lit, Spec.postJson, viewJson, List.append_assoc]
  have hslice : ∀ a : ByteArray, slice a 0 a.size = bs a := by
    intro a
    simp only [slice, List.drop_zero, Nat.sub_zero]
    rw [size_eq_length]; exact List.take_length
  simp only [hslice, bs_mk]
  have h0 : Spec.lit "\",\"like_count\":0}}" = Spec.lit "\",\"like_count\":" ++ (digits 0 ++ (Spec.lit "}" ++ Spec.lit "}")) := by
    decide
  rw [h0]

/-- info: 'Feed.perform_create' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms perform_create

end Feed
