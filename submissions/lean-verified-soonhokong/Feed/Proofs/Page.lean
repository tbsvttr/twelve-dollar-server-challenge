import Feed.Proofs.Bytes

/-!
# Pages

The flat form the storage layer returns (`Feed.Page`) read back row by row: the model's encoding
(`mkPage`) gives back, row by row, the post objects of the entries it was built from.
-/
namespace Feed
open Spec

theorem getElem!_nat (a : Array Nat) (i : Nat) : a[i]! = (a[i]?).getD 0 := by
  rw [getElem!_def]; cases a[i]? <;> rfl

theorem getElem!_toArray_nat (L : List Nat) (i : Nat) : L.toArray[i]! = (L[i]?).getD 0 := by
  rw [getElem!_nat]; simp

/-- Decoding a column list eight numbers at a time against a blob. -/
def decodePage (B : List UInt8) : List Nat → List (Option View)
  | id :: b :: c :: e :: f :: s :: t :: n :: rest =>
    (if f = 1 then some ⟨id, (B.drop b).take (c - b), (B.drop c).take (e - c), (B.drop s).take (t - s), n⟩ else none)
      :: decodePage B rest
  | _ => []

theorem encPage_length (ps : List (Post × Option (List UInt8) × Nat)) (off : Nat) :
    (encPage ps off).2.length = 8 * ps.length := by
  induction ps generalizing off with
  | nil => simp [encPage]
  | cons p ps ih =>
    obtain ⟨p, u, n⟩ := p
    cases u <;> simp [encPage, ih] <;> omega

/-- The segment `X` of `A ++ X ++ R`, read by its offset and length. -/
theorem take_drop_seg (A X R : List UInt8) {a x : Nat} (ha : a = A.length) (hx : x = X.length) :
    ((A ++ X ++ R).drop a).take x = X := by
  subst ha; subst hx; simp

theorem decode_encPage (ps : List (Post × Option (List UInt8) × Nat)) :
    ∀ (pre post : List UInt8),
      decodePage (pre ++ (encPage ps pre.length).1 ++ post) (encPage ps pre.length).2 = ps.map entryView := by
  induction ps with
  | nil => intros; simp [encPage, decodePage]
  | cons p ps ih =>
    intro pre post
    obtain ⟨p, u, n⟩ := p
    cases u with
    | none =>
      have key := ih (pre ++ p.body ++ p.createdAt) post
      simp only [List.length_append] at key
      simp only [encPage, List.cons_append, List.nil_append, decodePage, List.map_cons, entryView, Option.map_none]
      simp only [Nat.zero_ne_one, ↓reduceIte, List.cons.injEq, true_and]
      simpa [List.append_assoc, Nat.add_assoc] using key
    | some u =>
      have key := ih (pre ++ p.body ++ p.createdAt ++ u) post
      simp only [List.length_append] at key
      simp only [encPage, List.cons_append, List.nil_append, decodePage, List.map_cons, entryView, Option.map_some,
        ↓reduceIte, List.cons.injEq, Option.some.injEq]
      refine ⟨?_, ?_⟩
      · have hb := take_drop_seg pre p.body (p.createdAt ++ u ++ (encPage ps (pre.length + p.body.length +
          p.createdAt.length + u.length)).1 ++ post) (a := pre.length) (x := pre.length + p.body.length - pre.length)
          rfl (by omega)
        have hc := take_drop_seg (pre ++ p.body) p.createdAt (u ++ (encPage ps (pre.length + p.body.length +
          p.createdAt.length + u.length)).1 ++ post) (a := pre.length + p.body.length)
          (x := pre.length + p.body.length + p.createdAt.length - (pre.length + p.body.length)) (by simp) (by omega)
        have hu := take_drop_seg (pre ++ p.body ++ p.createdAt) u ((encPage ps (pre.length + p.body.length +
          p.createdAt.length + u.length)).1 ++ post) (a := pre.length + p.body.length + p.createdAt.length)
          (x := pre.length + p.body.length + p.createdAt.length + u.length -
            (pre.length + p.body.length + p.createdAt.length)) (by simp; omega) (by omega)
        simp only [List.append_assoc] at hb hc hu
        simp only [List.append_assoc]
        rw [hb, hc, hu]
      · simpa [List.append_assoc, Nat.add_assoc] using key

/-- `Page.view` reads the same rows as `decodePage`, wherever eight columns exist. -/
theorem view_eq_decode (blob : ByteArray) :
    ∀ (L : List Nat) (k : Nat), 8 * k + 8 ≤ L.length →
      Page.view ⟨blob, L.toArray⟩ k = ((decodePage (bs blob) L)[k]?).getD none := by
  intro L k
  induction k generalizing L with
  | zero =>
    intro h
    match L, h with
    | id :: b :: c :: e :: f :: s :: t :: n :: rest, _ =>
      simp only [Page.view, getElem!_toArray_nat, decodePage, slice]
      simp
  | succ k ih =>
    intro h
    match L, h with
    | id :: b :: c :: e :: f :: s :: t :: n :: rest, h =>
      have h' : 8 * k + 8 ≤ rest.length := by simp at h; omega
      have := ih rest h'
      simp only [Page.view, getElem!_toArray_nat] at this ⊢
      simp only [decodePage, List.getElem?_cons_succ]
      have e0 : 8 * (k + 1) = 8 * k + 8 := by omega
      simp only [e0] at *
      simp only [List.getElem?_cons_succ] at *
      exact this

theorem count_mkPage (ps : List (Post × Option (List UInt8) × Nat)) : (mkPage ps).count = ps.length := by
  simp [Page.count, mkPage, encPage_length]

/-- The model's page reads back as the post objects of its entries. -/
theorem view_mkPage (ps : List (Post × Option (List UInt8) × Nat)) (k : Nat) (hk : k < ps.length) :
    (mkPage ps).view k = entryView ps[k] := by
  have hlen := encPage_length ps 0
  have h := view_eq_decode ⟨(encPage ps 0).1.toArray⟩ (encPage ps 0).2 k (by omega)
  simp only [mkPage]
  rw [h]
  have := decode_encPage ps [] []
  simp only [List.length_nil, List.nil_append, List.append_nil] at this
  simp [bs, this, hk]

/-- An entry's post object is the specification's view of its post. -/
theorem entryView_entry (db : DB) (p : Post) : entryView (db.entry p) = db.view p := by
  unfold entryView DB.entry DB.view
  cases db.user? p.userId <;> rfl

end Feed
