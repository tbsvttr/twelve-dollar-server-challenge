import Feed.Spec.Utf8
import Feed.Json
import Feed.Proofs.Slice

/-!
# UTF-8 and UTF-16

Facts about `Feed/Spec/Utf8.lean`, and the UTF-8 check of `Feed/Json.lean`. Different lists of
scalar values have different UTF-8 texts (`encode_injective`); a string's code units, each below
0x10000, are read as scalar values (`scalars_isScalar`), and the code units of scalar values are
read back as those values (`scalars_flatMap_utf16`). `Json.utf8Len`, with which `Json.scanString`
checks UTF-8, gives at a byte of 0x80 or more the length of the UTF-8 of one scalar value (2, 3
or 4) that starts there and ends before `hi`, and 0 when none does (`utf8Len_spec`).
-/
namespace Feed.Spec.Json

/-! ## UTF-8 -/

/-- The first code point of a UTF-8 text and the bytes after it, read back as `utf8` writes them
(on the UTF-8 of a code point up to U+10FFFF it is the inverse of `utf8`). -/
def utf8Head : List UInt8 → Option (Nat × List UInt8)
  | [] => none
  | b :: r =>
    if b < 0x80 then some (b.toNat, r)
    else if b < 0xe0 then
      match r with
      | b1 :: r => some ((b.toNat - 0xc0) * 0x40 + (b1.toNat - 0x80), r)
      | [] => none
    else if b < 0xf0 then
      match r with
      | b1 :: b2 :: r => some (((b.toNat - 0xe0) * 0x40 + (b1.toNat - 0x80)) * 0x40 + (b2.toNat - 0x80), r)
      | _ => none
    else
      match r with
      | b1 :: b2 :: b3 :: r =>
        some ((((b.toNat - 0xf0) * 0x40 + (b1.toNat - 0x80)) * 0x40 + (b2.toNat - 0x80)) * 0x40 + (b3.toNat - 0x80), r)
      | _ => none

theorem utf8Head_utf8 {c : Nat} (hc : c ≤ 0x10ffff) (r : List UInt8) : utf8Head (utf8 c ++ r) = some (c, r) := by
  unfold utf8
  split
  · simp only [List.cons_append, List.nil_append, utf8Head, Nat.toUInt8_eq, UInt8.lt_iff_toNat_lt, UInt8.toNat_ofNat']
    rw [ite_eq_left (by simp; omega)]
    simp; omega
  split
  · simp only [List.cons_append, List.nil_append, utf8Head, Nat.toUInt8_eq, UInt8.lt_iff_toNat_lt, UInt8.toNat_ofNat']
    rw [ite_eq_right (by simp; omega), ite_eq_left (by simp; omega)]
    simp; omega
  split
  · simp only [List.cons_append, List.nil_append, utf8Head, Nat.toUInt8_eq, UInt8.lt_iff_toNat_lt, UInt8.toNat_ofNat']
    rw [ite_eq_right (by simp; omega), ite_eq_right (by simp; omega), ite_eq_left (by simp; omega)]
    simp; omega
  · simp only [List.cons_append, List.nil_append, utf8Head, Nat.toUInt8_eq, UInt8.lt_iff_toNat_lt, UInt8.toNat_ofNat']
    rw [ite_eq_right (by simp; omega), ite_eq_right (by simp; omega), ite_eq_right (by simp; omega)]
    simp; omega

theorem utf8_ne_nil (c : Nat) : utf8 c ≠ [] := by
  unfold utf8; split <;> (try split) <;> (try split) <;> simp

theorem utf8_length (c : Nat) :
    (utf8 c).length = if c < 0x80 then 1 else if c < 0x800 then 2 else if c < 0x10000 then 3 else 4 := by
  unfold utf8; split <;> (try split) <;> (try split) <;> rfl

/-- The UTF-8 of one code point is never the start of another's: the first bytes of a text tell
which code point it starts with, and where the next one starts. -/
theorem utf8_append_inj {c d : Nat} {r r' : List UInt8} (hc : c ≤ 0x10ffff) (hd : d ≤ 0x10ffff)
    (h : utf8 c ++ r = utf8 d ++ r') : c = d ∧ r = r' := by
  have := (utf8Head_utf8 hc r).symm.trans (h ▸ utf8Head_utf8 hd r')
  simpa using this

/-- **UTF-8 is a code**: different lists of scalar values have different UTF-8 texts. -/
theorem encode_injective {cs ds : List Nat} (hc : ∀ c ∈ cs, IsScalar c) (hd : ∀ d ∈ ds, IsScalar d)
    (h : encode cs = encode ds) : cs = ds := by
  induction cs generalizing ds with
  | nil =>
    cases ds with
    | nil => rfl
    | cons d ds => simp [encode, utf8_ne_nil] at h
  | cons c cs ih =>
    cases ds with
    | nil => simp [encode, utf8_ne_nil] at h
    | cons d ds =>
      simp only [encode, List.flatMap_cons] at h
      obtain ⟨rfl, h'⟩ := utf8_append_inj (hc c (by simp)).1 (hd d (by simp)).1 h
      rw [ih (fun x hx => hc x (by simp [hx])) (fun x hx => hd x (by simp [hx])) h']

/-- info: 'Feed.Spec.Json.encode_injective' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms encode_injective

@[simp] theorem encode_nil : encode [] = [] := rfl
@[simp] theorem encode_cons (c : Nat) (cs : List Nat) : encode (c :: cs) = utf8 c ++ encode cs := by
  simp [encode]
theorem encode_append (cs ds : List Nat) : encode (cs ++ ds) = encode cs ++ encode ds := by
  simp [encode]

/-! ## UTF-16 code units -/

theorem scalars_cons_of_not_surrogate {u : Nat} (hu : u < 0xd800 ∨ 0xdfff < u) (us : List Nat) :
    scalars (u :: us) = u :: scalars us := by
  cases us with
  | nil => simp only [scalars]; rw [ite_eq_right (by omega)]
  | cons v rest => rw [scalars, ite_eq_right (by omega), ite_eq_right (by omega)]

theorem scalars_cons_low {u : Nat} (hu : 0xdc00 ≤ u ∧ u ≤ 0xdfff) (us : List Nat) :
    scalars (u :: us) = 0xfffd :: scalars us := by
  cases us with
  | nil => simp only [scalars]; rw [ite_eq_left (by omega)]
  | cons v rest => rw [scalars, ite_eq_right (by omega), ite_eq_left (by omega)]

theorem scalars_cons_high {u : Nat} (hu : 0xd800 ≤ u ∧ u ≤ 0xdbff) {us : List Nat}
    (hn : ∀ v ∈ us.head?, ¬ (0xdc00 ≤ v ∧ v ≤ 0xdfff)) :
    scalars (u :: us) = 0xfffd :: scalars us := by
  cases us with
  | nil => simp only [scalars]; rw [ite_eq_left (by omega)]
  | cons v rest =>
    have := hn v rfl
    rw [scalars, ite_eq_right (by omega), ite_eq_left (by omega)]

theorem scalars_pair {u v : Nat} (hu : 0xd800 ≤ u ∧ u ≤ 0xdbff) (hv : 0xdc00 ≤ v ∧ v ≤ 0xdfff) (rest : List Nat) :
    scalars (u :: v :: rest) = (0x10000 + (u - 0xd800) * 0x400 + (v - 0xdc00)) :: scalars rest := by
  rw [scalars, ite_eq_left (by omega)]

theorem scalars_utf16 {c : Nat} (hc : IsScalar c) (us : List Nat) : scalars (utf16 c ++ us) = c :: scalars us := by
  unfold utf16
  unfold IsScalar at hc
  split
  · exact scalars_cons_of_not_surrogate (by omega) us
  · rename_i h
    have h1 : 0xd800 ≤ 0xd800 + (c - 0x10000) / 0x400 ∧ 0xd800 + (c - 0x10000) / 0x400 ≤ 0xdbff := by omega
    have h2 : 0xdc00 ≤ 0xdc00 + (c - 0x10000) % 0x400 ∧ 0xdc00 + (c - 0x10000) % 0x400 ≤ 0xdfff := by omega
    have h3 : 0x10000 + (0xd800 + (c - 0x10000) / 0x400 - 0xd800) * 0x400 +
        (0xdc00 + (c - 0x10000) % 0x400 - 0xdc00) = c := by
      omega
    show scalars (_ :: _ :: us) = _
    rw [scalars_pair h1 h2, h3]

theorem scalars_flatMap_utf16 {cs : List Nat} (hc : ∀ c ∈ cs, IsScalar c) : scalars (cs.flatMap utf16) = cs := by
  induction cs with
  | nil => rfl
  | cons c cs ih =>
    rw [List.flatMap_cons, scalars_utf16 (hc c (by simp)), ih (fun x hx => hc x (by simp [hx]))]

theorem scalars_isScalar : ∀ us : List Nat, (∀ u ∈ us, u < 0x10000) → ∀ c ∈ scalars us, IsScalar c
  | [], _, c, h => by simp [scalars] at h
  | [u], hu, c, h => by
    have := hu u (by simp)
    simp only [scalars, List.mem_singleton] at h
    subst h
    unfold IsScalar
    split <;> omega
  | u :: v :: rest, hu, c, h => by
    have hu0 := hu u (by simp)
    unfold scalars at h
    split at h
    · rename_i hp
      rcases List.mem_cons.mp h with hc | h
      · obtain ⟨h1, h2, h3, h4⟩ := hp
        have : c ≤ 0x10ffff ∧ 0xdfff < c := by omega
        exact ⟨this.1, Or.inr this.2⟩
      · exact scalars_isScalar rest (fun x hx => hu x (by simp [hx])) c h
    · rcases List.mem_cons.mp h with hc | h
      · unfold IsScalar; rw [hc]; split <;> omega
      · exact scalars_isScalar (v :: rest) (fun x hx => hu x (List.mem_cons_of_mem _ hx)) c h

/-- info: 'Feed.Spec.Json.scalars_isScalar' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms scalars_isScalar

end Feed.Spec.Json

namespace Feed.Json
open Spec.Json

/-! ## The UTF-8 check of `scanString` -/

/-- The bytes of a range that starts with a list, one by one. -/
theorem get!_of_slice {a : ByteArray} {i hi : Nat} {l : List UInt8} (hhi : hi ≤ a.size) (h : slice a i hi = l)
    {k : Nat} (hk : k < l.length) : i + k < hi ∧ a.get! (i + k) = l[k] := by
  have hlen := slice_length a (lo := i) hhi
  rw [h] at hlen
  have hk' : i + k < hi := by omega
  refine ⟨hk', ?_⟩
  have := slice_getElem? a hk' hhi
  rw [h, List.getElem?_eq_getElem hk] at this
  exact (Option.some.inj this).symm

theorem utf8Len_two {a : ByteArray} {hi i : Nat} (h0 : 0xc2 ≤ (a.get! i).toNat ∧ (a.get! i).toNat ≤ 0xdf) :
    utf8Len a hi i =
      if i + 1 < hi ∧ 0x80 ≤ (a.get! (i + 1)).toNat ∧ (a.get! (i + 1)).toNat ≤ 0xbf then 2 else 0 := by
  unfold utf8Len
  simp only [byte, Bool.and_eq_true, decide_eq_true_eq, UInt8.le_iff_toNat_le, UInt8.reduceToNat]
  rw [ite_eq_left h0]
  simp only [and_assoc]

theorem utf8Len_three {a : ByteArray} {hi i : Nat} (h0 : 0xe0 ≤ (a.get! i).toNat ∧ (a.get! i).toNat ≤ 0xef) :
    utf8Len a hi i =
      if i + 1 < hi ∧ 0x80 ≤ (a.get! (i + 1)).toNat ∧ (a.get! (i + 1)).toNat ≤ 0xbf ∧
          ((a.get! i).toNat = 0xe0 → 0xa0 ≤ (a.get! (i + 1)).toNat) ∧
          ((a.get! i).toNat = 0xed → (a.get! (i + 1)).toNat ≤ 0x9f) ∧
          i + 2 < hi ∧ 0x80 ≤ (a.get! (i + 2)).toNat ∧ (a.get! (i + 2)).toNat ≤ 0xbf then 3 else 0 := by
  unfold utf8Len
  simp only [byte, Bool.and_eq_true, decide_eq_true_eq, UInt8.le_iff_toNat_le, UInt8.reduceToNat, beq_iff_eq,
    apply_ite UInt8.toNat, ← UInt8.toNat_inj]
  rw [ite_eq_right (by omega), ite_eq_left h0]
  apply ite_cond_congr
  apply propext
  split <;> split <;> omega

theorem utf8Len_four {a : ByteArray} {hi i : Nat} (h0 : 0xf0 ≤ (a.get! i).toNat ∧ (a.get! i).toNat ≤ 0xf4) :
    utf8Len a hi i =
      if i + 1 < hi ∧ 0x80 ≤ (a.get! (i + 1)).toNat ∧ (a.get! (i + 1)).toNat ≤ 0xbf ∧
          ((a.get! i).toNat = 0xf0 → 0x90 ≤ (a.get! (i + 1)).toNat) ∧
          ((a.get! i).toNat = 0xf4 → (a.get! (i + 1)).toNat ≤ 0x8f) ∧
          i + 2 < hi ∧ 0x80 ≤ (a.get! (i + 2)).toNat ∧ (a.get! (i + 2)).toNat ≤ 0xbf ∧
          i + 3 < hi ∧ 0x80 ≤ (a.get! (i + 3)).toNat ∧ (a.get! (i + 3)).toNat ≤ 0xbf then 4 else 0 := by
  unfold utf8Len
  simp only [byte, Bool.and_eq_true, decide_eq_true_eq, UInt8.le_iff_toNat_le, UInt8.reduceToNat, beq_iff_eq,
    apply_ite UInt8.toNat, ← UInt8.toNat_inj]
  rw [ite_eq_right (by omega), ite_eq_right (by omega), ite_eq_left h0]
  apply ite_cond_congr
  apply propext
  split <;> split <;> omega

theorem utf8Len_other {a : ByteArray} {hi i : Nat}
    (h0 : ¬ (0xc2 ≤ (a.get! i).toNat ∧ (a.get! i).toNat ≤ 0xdf) ∧
      ¬ (0xe0 ≤ (a.get! i).toNat ∧ (a.get! i).toNat ≤ 0xef) ∧
      ¬ (0xf0 ≤ (a.get! i).toNat ∧ (a.get! i).toNat ≤ 0xf4)) :
    utf8Len a hi i = 0 := by
  unfold utf8Len
  simp only [byte, Bool.and_eq_true, decide_eq_true_eq, UInt8.le_iff_toNat_le, UInt8.reduceToNat]
  rw [ite_eq_right h0.1, ite_eq_right h0.2.1, ite_eq_right h0.2.2]

theorem utf8_two {b0 b1 : UInt8} (h0 : 0xc2 ≤ b0.toNat ∧ b0.toNat ≤ 0xdf) (h1 : 0x80 ≤ b1.toNat ∧ b1.toNat ≤ 0xbf) :
    utf8 ((b0.toNat - 0xc0) * 0x40 + (b1.toNat - 0x80)) = [b0, b1] := by
  unfold utf8
  rw [ite_eq_right (by omega), ite_eq_left (by omega)]
  simp only [List.cons.injEq, and_true, Nat.toUInt8_eq]
  constructor <;> apply UInt8.toNat_inj.mp <;> simp <;> omega

theorem utf8_three {b0 b1 b2 : UInt8} (h0 : 0xe0 ≤ b0.toNat ∧ b0.toNat ≤ 0xef) (h1 : 0x80 ≤ b1.toNat ∧ b1.toNat ≤ 0xbf)
    (h2 : 0x80 ≤ b2.toNat ∧ b2.toNat ≤ 0xbf) (h01 : b0.toNat = 0xe0 → 0xa0 ≤ b1.toNat) :
    utf8 (((b0.toNat - 0xe0) * 0x40 + (b1.toNat - 0x80)) * 0x40 + (b2.toNat - 0x80)) = [b0, b1, b2] := by
  unfold utf8
  rw [ite_eq_right (by omega), ite_eq_right (by omega), ite_eq_left (by omega)]
  simp only [List.cons.injEq, and_true, Nat.toUInt8_eq]
  refine ⟨?_, ?_, ?_⟩ <;> apply UInt8.toNat_inj.mp <;> simp <;> omega

theorem utf8_four {b0 b1 b2 b3 : UInt8} (h0 : 0xf0 ≤ b0.toNat ∧ b0.toNat ≤ 0xf4)
    (h1 : 0x80 ≤ b1.toNat ∧ b1.toNat ≤ 0xbf)
    (h2 : 0x80 ≤ b2.toNat ∧ b2.toNat ≤ 0xbf) (h3 : 0x80 ≤ b3.toNat ∧ b3.toNat ≤ 0xbf)
    (h01 : b0.toNat = 0xf0 → 0x90 ≤ b1.toNat) :
    utf8 ((((b0.toNat - 0xf0) * 0x40 + (b1.toNat - 0x80)) * 0x40 + (b2.toNat - 0x80)) * 0x40 + (b3.toNat - 0x80)) =
      [b0, b1, b2, b3] := by
  unfold utf8
  rw [ite_eq_right (by omega), ite_eq_right (by omega), ite_eq_right (by omega)]
  simp only [List.cons.injEq, and_true, Nat.toUInt8_eq]
  refine ⟨?_, ?_, ?_, ?_⟩ <;> apply UInt8.toNat_inj.mp <;> simp <;> omega

/-- `utf8Len` finds, at a byte of 0x80 or more, the UTF-8 of a scalar value that ends before `hi`. -/
theorem utf8Len_sound {a : ByteArray} {hi i : Nat} (hhi : hi ≤ a.size) (h : utf8Len a hi i ≠ 0) :
    ∃ c r, IsScalar c ∧ 0x80 ≤ c ∧ slice a i hi = utf8 c ++ r ∧ utf8Len a hi i = (utf8 c).length := by
  by_cases h2 : 0xc2 ≤ (a.get! i).toNat ∧ (a.get! i).toNat ≤ 0xdf
  · rw [utf8Len_two h2] at h ⊢
    split at h
    · rename_i ht
      refine ⟨((a.get! i).toNat - 0xc0) * 0x40 + ((a.get! (i + 1)).toNat - 0x80), slice a (i + 2) hi,
        by unfold IsScalar; omega, by omega, ?_, ?_⟩
      · rw [utf8_two h2 ⟨ht.2.1, ht.2.2⟩, slice_cons a (by omega) hhi, slice_cons a (by omega) hhi]; rfl
      · rw [utf8_two h2 ⟨ht.2.1, ht.2.2⟩, ite_eq_left ht]; rfl
    · exact absurd rfl h
  by_cases h3 : 0xe0 ≤ (a.get! i).toNat ∧ (a.get! i).toNat ≤ 0xef
  · rw [utf8Len_three h3] at h ⊢
    split at h
    · rename_i ht
      obtain ⟨_, h1l, h1h, hlo, hhi', _, h2l, h2h⟩ := id ht
      refine ⟨(((a.get! i).toNat - 0xe0) * 0x40 + ((a.get! (i + 1)).toNat - 0x80)) * 0x40 +
        ((a.get! (i + 2)).toNat - 0x80), slice a (i + 3) hi, by unfold IsScalar; omega, by omega, ?_, ?_⟩
      · rw [utf8_three h3 ⟨h1l, h1h⟩ ⟨h2l, h2h⟩ hlo, slice_cons a (by omega) hhi,
          slice_cons a (by omega) hhi, slice_cons a (by omega) hhi]; rfl
      · rw [utf8_three h3 ⟨h1l, h1h⟩ ⟨h2l, h2h⟩ hlo, ite_eq_left ht]; rfl
    · exact absurd rfl h
  by_cases h4 : 0xf0 ≤ (a.get! i).toNat ∧ (a.get! i).toNat ≤ 0xf4
  · rw [utf8Len_four h4] at h ⊢
    split at h
    · rename_i ht
      obtain ⟨_, h1l, h1h, hlo, hhi', _, h2l, h2h, _, h3l, h3h⟩ := id ht
      refine ⟨((((a.get! i).toNat - 0xf0) * 0x40 + ((a.get! (i + 1)).toNat - 0x80)) * 0x40 +
        ((a.get! (i + 2)).toNat - 0x80)) * 0x40 + ((a.get! (i + 3)).toNat - 0x80), slice a (i + 4) hi,
        by unfold IsScalar; omega, by omega, ?_, ?_⟩
      · rw [utf8_four h4 ⟨h1l, h1h⟩ ⟨h2l, h2h⟩ ⟨h3l, h3h⟩ hlo, slice_cons a (by omega) hhi, slice_cons a (by omega) hhi,
          slice_cons a (by omega) hhi, slice_cons a (by omega) hhi]; rfl
      · rw [utf8_four h4 ⟨h1l, h1h⟩ ⟨h2l, h2h⟩ ⟨h3l, h3h⟩ hlo, ite_eq_left ht]; rfl
    · exact absurd rfl h
  · exact absurd (utf8Len_other ⟨h2, h3, h4⟩) h

/-- At the UTF-8 of a scalar value of 0x80 or more that ends before `hi`, `utf8Len` is its length. -/
theorem utf8Len_eq {a : ByteArray} {hi i c : Nat} {r : List UInt8} (hhi : hi ≤ a.size) (hc : IsScalar c)
    (h80 : 0x80 ≤ c) (h : slice a i hi = utf8 c ++ r) : utf8Len a hi i = (utf8 c).length := by
  have hg := fun k (hk : k < (utf8 c ++ r).length) => get!_of_slice hhi h hk
  unfold IsScalar at hc
  by_cases c2 : c < 0x800
  · have hu : utf8 c = [(0xc0 + c / 0x40).toUInt8, (0x80 + c % 0x40).toUInt8] := by
      unfold utf8; rw [ite_eq_right (by omega), ite_eq_left c2]
    rw [hu] at hg ⊢
    obtain ⟨_, h0⟩ := hg 0 (by simp)
    obtain ⟨_, h1⟩ := hg 1 (by simp)
    simp only [Nat.add_zero, List.cons_append, List.getElem_cons_zero, List.getElem_cons_succ] at h0 h1
    have e0 : (a.get! i).toNat = 0xc0 + c / 0x40 := by rw [h0]; simp; omega
    have e1 : (a.get! (i + 1)).toNat = 0x80 + c % 0x40 := by rw [h1]; simp; omega
    rw [utf8Len_two (by omega), ite_eq_left (by omega)]; rfl
  by_cases c3 : c < 0x10000
  · have hu : utf8 c = [(0xe0 + c / 0x1000).toUInt8, (0x80 + c / 0x40 % 0x40).toUInt8, (0x80 + c % 0x40).toUInt8] := by
      unfold utf8; rw [ite_eq_right (by omega), ite_eq_right c2, ite_eq_left c3]
    rw [hu] at hg ⊢
    obtain ⟨_, h0⟩ := hg 0 (by simp)
    obtain ⟨_, h1⟩ := hg 1 (by simp)
    obtain ⟨_, h2⟩ := hg 2 (by simp)
    simp only [Nat.add_zero, List.cons_append, List.getElem_cons_zero, List.getElem_cons_succ] at h0 h1 h2
    have e0 : (a.get! i).toNat = 0xe0 + c / 0x1000 := by rw [h0]; simp; omega
    have e1 : (a.get! (i + 1)).toNat = 0x80 + c / 0x40 % 0x40 := by rw [h1]; simp; omega
    have e2 : (a.get! (i + 2)).toNat = 0x80 + c % 0x40 := by rw [h2]; simp; omega
    rw [utf8Len_three (by omega), ite_eq_left (by omega)]; rfl
  · have hu : utf8 c = [(0xf0 + c / 0x40000).toUInt8, (0x80 + c / 0x1000 % 0x40).toUInt8,
        (0x80 + c / 0x40 % 0x40).toUInt8, (0x80 + c % 0x40).toUInt8] := by
      unfold utf8; rw [ite_eq_right (by omega), ite_eq_right c2, ite_eq_right c3]
    rw [hu] at hg ⊢
    obtain ⟨_, h0⟩ := hg 0 (by simp)
    obtain ⟨_, h1⟩ := hg 1 (by simp)
    obtain ⟨_, h2⟩ := hg 2 (by simp)
    obtain ⟨_, h3⟩ := hg 3 (by simp)
    simp only [Nat.add_zero, List.cons_append, List.getElem_cons_zero, List.getElem_cons_succ] at h0 h1 h2 h3
    have e0 : (a.get! i).toNat = 0xf0 + c / 0x40000 := by rw [h0]; simp; omega
    have e1 : (a.get! (i + 1)).toNat = 0x80 + c / 0x1000 % 0x40 := by rw [h1]; simp; omega
    have e2 : (a.get! (i + 2)).toNat = 0x80 + c / 0x40 % 0x40 := by rw [h2]; simp; omega
    have e3 : (a.get! (i + 3)).toNat = 0x80 + c % 0x40 := by rw [h3]; simp; omega
    rw [utf8Len_four (by omega), ite_eq_left (by omega)]; rfl

/-- **`utf8Len` checks RFC 3629 §4**: at `i` it is 0 exactly when no UTF-8 of a scalar value of
0x80 or more starts there and ends before `hi`, and the length of that UTF-8 when one does. -/
theorem utf8Len_spec {a : ByteArray} {hi i : Nat} (hhi : hi ≤ a.size) :
    (utf8Len a hi i = 0 ↔ ¬ ∃ c r, IsScalar c ∧ 0x80 ≤ c ∧ slice a i hi = utf8 c ++ r) ∧
    ∀ c r, IsScalar c → 0x80 ≤ c → slice a i hi = utf8 c ++ r → utf8Len a hi i = (utf8 c).length := by
  refine ⟨⟨fun h0 ⟨c, r, hc, h80, h⟩ => ?_, fun hn => ?_⟩, fun c r hc h80 h => utf8Len_eq hhi hc h80 h⟩
  · rw [utf8Len_eq hhi hc h80 h] at h0
    exact utf8_ne_nil c (List.eq_nil_of_length_eq_zero h0)
  · by_cases h0 : utf8Len a hi i = 0
    · exact h0
    · obtain ⟨c, r, hc, h80, h, -⟩ := utf8Len_sound hhi h0
      exact absurd ⟨c, r, hc, h80, h⟩ hn

/-- info: 'Feed.Json.utf8Len_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms utf8Len_spec

end Feed.Json
