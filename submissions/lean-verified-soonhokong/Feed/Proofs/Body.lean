import Feed.Spec.Body
import Feed.Proofs.JsonValue
import Feed.Proofs.Views

/-!
# The post body

`postText` takes a `POST /posts` body as `Spec.Body.accept` does: SPEC.md:67-69, then schema.sql's
CHECK, its errors read as SPEC.md's rows (`postText_spec`). `parseTop_spec` finds the `body`
member, and `decodeString_spec` and `IsString.isScalar` make its string the UTF-8 of scalar values
(`Feed/Proofs/JsonValue.lean`, `Feed/Proofs/JsonToken.lean`). On such bytes:

- `cpAt` at a character's first byte reads the character, and `prevStart` just after a character
  finds its first byte (`cpAt_utf8`, `prevStart_utf8`).
- `trimRange` gives the range that holds the UTF-8 of `Spec.Body.trim` of the characters, whose
  whitespace is what ECMAScript's `String.prototype.trim` removes (`jsSpace_eq`), and `codePoints`
  counts the characters in it (`trimRange_spec`).
- schema.sql's CHECK holds of the UTF-8 of 1 to 500 scalar values exactly when the first is not
  U+0000 (`Spec.Body.schemaOk_iff`), and `postText` answers 500 for a text led by U+0000.
-/
namespace Feed
open Spec Spec.Json

/-! ## The bytes of a character -/

/-- A continuation byte of UTF-8 is one of 0x80 to 0xbf. -/
private theorem cont_iff (b : UInt8) : (b &&& 0xc0 == 0x80) = true ↔ 0x80 ≤ b.toNat ∧ b.toNat < 0xc0 := by
  have hb := UInt8.toNat_lt b
  refine ⟨fun h => Decidable.by_contra fun hn => ?_, fun h => Json.cont_mask ⟨h.1, by omega⟩⟩
  have : (b &&& 0xc0 == 0x80) = false := by
    by_cases h1 : b.toNat < 0x40
    · exact Json.mask_ofNat (lo := 0) (n := 0x40) (Nat.zero_le _) h1
        (P := fun b => (b &&& 0xc0 == 0x80) = false) (by decide)
    by_cases h2 : b.toNat < 0x80
    · exact Json.mask_ofNat (lo := 0x40) (n := 0x40) (by omega) (by omega)
        (P := fun b => (b &&& 0xc0 == 0x80) = false) (by decide)
    · exact Json.mask_ofNat (lo := 0xc0) (n := 0x40) (by omega) (by omega)
        (P := fun b => (b &&& 0xc0 == 0x80) = false) (by decide)
  rw [h] at this; cases this

private theorem not_cont {b : UInt8} (h : b.toNat < 0x80 ∨ 0xc0 ≤ b.toNat) : (b &&& 0xc0 == 0x80) = false := by
  cases hc : (b &&& 0xc0 == 0x80)
  · rfl
  · have := (cont_iff b).mp hc; omega

/-- The UTF-8 of a scalar value: a first byte that is no continuation byte, and is 0 only for
U+0000, then continuation bytes. -/
private theorem utf8_shape {c : Nat} (hc : IsScalar c) : ∃ b r, utf8 c = b :: r ∧
    (b.toNat < 0x80 ∨ 0xc0 ≤ b.toNat) ∧ (b.toNat = 0 ↔ c = 0) ∧ ∀ x ∈ r, 0x80 ≤ x.toNat ∧ x.toNat < 0xc0 := by
  unfold IsScalar at hc
  unfold utf8
  by_cases c1 : c < 0x80
  · rw [ite_eq_left c1]
    refine ⟨_, _, rfl, ?_, ?_, by simp⟩ <;> simp <;> omega
  by_cases c2 : c < 0x800
  · rw [ite_eq_right c1, ite_eq_left c2]
    refine ⟨_, _, rfl, ?_, ?_, ?_⟩ <;> simp <;> omega
  by_cases c3 : c < 0x10000
  · rw [ite_eq_right c1, ite_eq_right c2, ite_eq_left c3]
    refine ⟨_, _, rfl, ?_, ?_, ?_⟩ <;> simp <;> omega
  · rw [ite_eq_right c1, ite_eq_right c2, ite_eq_right c3]
    refine ⟨_, _, rfl, ?_, ?_, ?_⟩ <;> simp <;> omega

/-- The UTF-8 of scalar values has one byte that is no continuation byte per value. -/
private theorem count_encode : ∀ {cs : List Nat}, (∀ c ∈ cs, IsScalar c) →
    ((encode cs).filter fun b => Decidable.decide (b &&& 0xc0 ≠ 0x80)).length = cs.length
  | [], _ => rfl
  | c :: cs, hc => by
    obtain ⟨b, r, hu, hb, -, hr⟩ := utf8_shape (hc c (by simp))
    have hr' : r.filter (fun b => Decidable.decide (b &&& 0xc0 ≠ 0x80)) = [] := by
      rw [List.filter_eq_nil_iff]
      intro x hx
      simpa using (cont_iff x).mpr (hr x hx)
    have hb' : Decidable.decide (b &&& 0xc0 ≠ 0x80) = true := by simpa using not_cont hb
    rw [encode_cons, List.filter_append, List.length_append, hu, List.filter_cons, ite_eq_left hb', hr',
      count_encode fun x hx => hc x (by simp [hx])]
    simp; omega

/-- The bytes before the first NUL are the UTF-8 of the scalar values before the first U+0000. -/
private theorem takeWhile_encode : ∀ {cs : List Nat}, (∀ c ∈ cs, IsScalar c) →
    (encode cs).takeWhile (fun x => Decidable.decide (x ≠ 0)) =
      encode (cs.takeWhile fun c => Decidable.decide (c ≠ 0))
  | [], _ => rfl
  | c :: cs, hc => by
    obtain ⟨b, r, hu, -, hb0, hr⟩ := utf8_shape (hc c (by simp))
    rw [encode_cons, hu]
    by_cases h0 : c = 0
    · have : b = 0 := UInt8.toNat_inj.mp (by simpa using hb0.mpr h0)
      subst this h0
      simp
    · have hb : b ≠ 0 := fun h => h0 (hb0.mp (by simp [h]))
      have hall : ∀ x ∈ b :: r, Decidable.decide (x ≠ 0) = true := by
        intro x hx
        rcases List.mem_cons.mp hx with rfl | hx
        · simpa using hb
        · have := (hr x hx).1
          simp only [ne_eq, decide_eq_true_eq]
          intro h; rw [h] at this; simp at this
      rw [List.cons_append, ← List.cons_append, List.takeWhile_append_of_pos hall,
        takeWhile_encode fun x hx => hc x (by simp [hx]), List.takeWhile_cons_of_pos (by simpa using h0),
        encode_cons, hu]

private theorem length_le_encode : ∀ cs : List Nat, cs.length ≤ (encode cs).length
  | [] => Nat.le_refl _
  | c :: cs => by
    have := List.length_pos_iff.mpr (utf8_ne_nil c)
    have := length_le_encode cs
    simp; omega

private theorem encode_eq_nil {cs : List Nat} : encode cs = [] ↔ cs = [] := by
  cases cs with
  | nil => simp
  | cons c cs => simp [utf8_ne_nil]

/-! ## Reading characters back -/

/-- The byte at an offset into a part of the array. -/
private theorem get!_of_bs {s : ByteArray} {l m r : List UInt8} (h : bs s = l ++ m ++ r) {k : Nat}
    (hk : k < m.length) : s.get! (l.length + k) = m[k] := by
  rw [get!_eq, h, List.append_assoc, List.getElem?_append_right (by omega), Nat.add_sub_cancel_left,
    List.getElem?_append_left hk, List.getElem?_eq_getElem hk]
  rfl

/-- A part of the array as a range. -/
private theorem slice_of_bs {s : ByteArray} {l m r : List UInt8} (h : bs s = l ++ m ++ r) :
    slice s l.length (l.length + m.length) = m := by
  unfold slice
  rw [show s.data.toList = l ++ m ++ r from h, List.append_assoc, List.drop_left, Nat.add_sub_cancel_left,
    List.take_left]

/-- The first byte of a range. -/
private theorem get!_of_slice_cons {a : ByteArray} {lo hi : Nat} {b : UInt8} {r : List UInt8}
    (h : slice a lo hi = b :: r) : a.get! lo = b := by
  have h0 := congrArg (·[0]?) h
  simp only [slice, List.getElem?_take, List.getElem?_drop, Nat.add_zero, List.getElem?_cons_zero] at h0
  split at h0
  · rw [get!_eq]; simp [bs, h0]
  · cases h0

/-- `cpAt` at the first byte of the UTF-8 of a scalar value reads the value and the length of its
UTF-8. -/
theorem cpAt_utf8 {s : ByteArray} {l r : List UInt8} {c : Nat} (hc : IsScalar c) (h : bs s = l ++ utf8 c ++ r) :
    cpAt s l.length = (c, (utf8 c).length) := by
  have hg := fun k (hk : k < (utf8 c).length) => get!_of_bs h hk
  unfold IsScalar at hc
  unfold cpAt
  by_cases c1 : c < 0x80
  · have hu : utf8 c = [c.toUInt8] := by unfold utf8; rw [ite_eq_left c1]
    rw [hu] at hg ⊢
    have e0 : (s.get! (l.length + 0)).toNat = c := by rw [hg 0 (by simp)]; simp; omega
    simp only [Nat.add_zero] at e0
    simp only [e0, List.length_singleton]
    rw [ite_eq_left (by omega)]
  by_cases c2 : c < 0x800
  · have hu : utf8 c = [(0xc0 + c / 0x40).toUInt8, (0x80 + c % 0x40).toUInt8] := by
      unfold utf8; rw [ite_eq_right c1, ite_eq_left c2]
    rw [hu] at hg ⊢
    have e0 : (s.get! (l.length + 0)).toNat = 0xc0 + c / 0x40 := by rw [hg 0 (by simp)]; simp; omega
    have e1 : (s.get! (l.length + 1)).toNat = 0x80 + c % 0x40 := by rw [hg 1 (by simp)]; simp; omega
    simp only [Nat.add_zero] at e0
    simp only [e0, e1, List.length_cons, List.length_nil]
    rw [ite_eq_right (by omega), ite_eq_left (by omega)]
    simp only [Prod.mk.injEq, and_true]
    omega
  by_cases c3 : c < 0x10000
  · have hu : utf8 c = [(0xe0 + c / 0x1000).toUInt8, (0x80 + c / 0x40 % 0x40).toUInt8,
        (0x80 + c % 0x40).toUInt8] := by
      unfold utf8; rw [ite_eq_right c1, ite_eq_right c2, ite_eq_left c3]
    rw [hu] at hg ⊢
    have e0 : (s.get! (l.length + 0)).toNat = 0xe0 + c / 0x1000 := by rw [hg 0 (by simp)]; simp; omega
    have e1 : (s.get! (l.length + 1)).toNat = 0x80 + c / 0x40 % 0x40 := by rw [hg 1 (by simp)]; simp; omega
    have e2 : (s.get! (l.length + 2)).toNat = 0x80 + c % 0x40 := by rw [hg 2 (by simp)]; simp; omega
    simp only [Nat.add_zero] at e0
    simp only [e0, e1, e2, List.length_cons, List.length_nil]
    rw [ite_eq_right (by omega), ite_eq_right (by omega), ite_eq_left (by omega)]
    simp only [Prod.mk.injEq, and_true]
    omega
  · have hu : utf8 c = [(0xf0 + c / 0x40000).toUInt8, (0x80 + c / 0x1000 % 0x40).toUInt8,
        (0x80 + c / 0x40 % 0x40).toUInt8, (0x80 + c % 0x40).toUInt8] := by
      unfold utf8; rw [ite_eq_right c1, ite_eq_right c2, ite_eq_right c3]
    rw [hu] at hg ⊢
    have e0 : (s.get! (l.length + 0)).toNat = 0xf0 + c / 0x40000 := by rw [hg 0 (by simp)]; simp; omega
    have e1 : (s.get! (l.length + 1)).toNat = 0x80 + c / 0x1000 % 0x40 := by rw [hg 1 (by simp)]; simp; omega
    have e2 : (s.get! (l.length + 2)).toNat = 0x80 + c / 0x40 % 0x40 := by rw [hg 2 (by simp)]; simp; omega
    have e3 : (s.get! (l.length + 3)).toNat = 0x80 + c % 0x40 := by rw [hg 3 (by simp)]; simp; omega
    simp only [Nat.add_zero] at e0
    simp only [e0, e1, e2, e3, List.length_cons, List.length_nil]
    rw [ite_eq_right (by omega), ite_eq_right (by omega), ite_eq_right (by omega)]
    simp only [Prod.mk.injEq, and_true]
    omega

/-- `prevStart` just after the UTF-8 of a scalar value finds its first byte. -/
theorem prevStart_utf8 {s : ByteArray} {l r : List UInt8} {c : Nat} (hc : IsScalar c)
    (h : bs s = l ++ utf8 c ++ r) : prevStart s (l.length + (utf8 c).length) = l.length := by
  have hg := fun k (hk : k < (utf8 c).length) => get!_of_bs h hk
  obtain ⟨b, rs, hu, hb, -, hrs⟩ := utf8_shape hc
  have m0 := not_cont (b := s.get! l.length)
    (by rw [← Nat.add_zero l.length, hg 0 (by simp [hu])]; simpa [hu] using hb)
  have hm : ∀ k, 0 < k → k < (utf8 c).length → (s.get! (l.length + k) &&& 0xc0 == 0x80) = true := by
    intro k hk0 hk
    rw [hg k hk, cont_iff]
    apply hrs
    obtain ⟨k', rfl⟩ : ∃ k', k = k' + 1 := ⟨k - 1, by omega⟩
    simp only [hu, List.getElem_cons_succ]
    exact List.getElem_mem _
  have hlen : (utf8 c).length ≤ 4 := by rw [utf8_length]; split <;> (try split) <;> (try split) <;> omega
  have hpos : 0 < (utf8 c).length := List.length_pos_iff.mpr (utf8_ne_nil c)
  unfold prevStart
  rcases (by omega : (utf8 c).length = 1 ∨ (utf8 c).length = 2 ∨ (utf8 c).length = 3 ∨ (utf8 c).length = 4)
    with h1 | h1 | h1 | h1 <;> rw [h1]
  · simp [prevStart.go, m0]
  · have m1 := hm 1 (by omega) (by omega)
    simp [prevStart.go, m0, m1]
  · have m1 := hm 1 (by omega) (by omega)
    have m2 := hm 2 (by omega) (by omega)
    simp [prevStart.go, m0, m1, m2]
  · have m1 := hm 1 (by omega) (by omega)
    have m2 := hm 2 (by omega) (by omega)
    have m3 := hm 3 (by omega) (by omega)
    simp [prevStart.go, m1, m2, m3]

/-! ## Trimming -/

/-- `jsSpace` is the specification's whitespace, what ECMAScript's `String.prototype.trim`
removes. -/
theorem jsSpace_eq : jsSpace = Spec.Body.isTrimSpace := rfl

/-- `front`, at the first byte of a character, steps over the whitespace that starts there, one
character at a time. -/
theorem trimRange_front {s : ByteArray} : ∀ (rest pre : List Nat) (i f : Nat), (∀ c ∈ rest, IsScalar c) →
    bs s = encode pre ++ encode rest → i = (encode pre).length → (encode rest).length ≤ f →
    trimRange.front s i f = i + (encode (rest.takeWhile Spec.Body.isTrimSpace)).length
  | [], pre, i, f, _, h, hi, _ => by
    have hs : s.size = i := by rw [size_eq_length, h, hi]; simp
    cases f <;> simp [trimRange.front, hs]
  | c :: rest, pre, i, f, hc, h, hi, hf => by
    have hpos := List.length_pos_iff.mpr (utf8_ne_nil c)
    obtain ⟨f, rfl⟩ : ∃ f', f = f' + 1 := ⟨f - 1, by simp at hf; omega⟩
    have hcp := cpAt_utf8 (hc c (by simp)) (l := encode pre) (r := encode rest) (by rw [h]; simp)
    have hlt : i < s.size := by rw [size_eq_length, h, hi]; simp; omega
    rw [← hi] at hcp
    simp only [trimRange.front, hlt, ↓reduceIte, hcp, jsSpace_eq]
    by_cases hsp : Spec.Body.isTrimSpace c = true
    · rw [ite_eq_left hsp, trimRange_front rest (pre ++ [c]) _ f (fun x hx => hc x (by simp [hx]))
        (by rw [h]; simp [encode_append]) (by simp [encode_append, hi]) (by simp at hf; omega),
        List.takeWhile_cons_of_pos hsp, encode_cons, List.length_append]
      omega
    · rw [ite_eq_right hsp, List.takeWhile_cons_of_neg hsp]
      simp

/-- `back`, just after a character, steps back over the whitespace that ends there, one character
at a time, down to `lo`. -/
theorem trimRange_back {s : ByteArray} {pre : List Nat} :
    ∀ (f : Nat) (mid : List Nat) (r : List UInt8) (lo e : Nat), (∀ c ∈ mid, IsScalar c) →
      bs s = encode pre ++ encode mid ++ r → lo = (encode pre).length → e = lo + (encode mid).length →
      mid.length ≤ f →
      trimRange.back s lo e f = lo + (encode (mid.reverse.dropWhile Spec.Body.isTrimSpace).reverse).length
  | 0, mid, r, lo, e, _, _, _, he, hf => by
    have : mid = [] := List.eq_nil_of_length_eq_zero (by omega)
    subst this
    simp [trimRange.back, he]
  | f + 1, mid, r, lo, e, hc, h, hlo, he, hf => by
    rcases List.eq_nil_or_concat mid with rfl | ⟨mid, c, rfl⟩
    · simp [trimRange.back, he]
    rw [List.concat_eq_append] at hc h he hf ⊢
    have hcs : IsScalar c := hc c (by simp)
    have hl : bs s = (encode pre ++ encode mid) ++ utf8 c ++ r := by rw [h]; simp [encode_append]
    have hpos := List.length_pos_iff.mpr (utf8_ne_nil c)
    have he' : e = (encode pre ++ encode mid).length + (utf8 c).length := by
      rw [he, hlo]; simp [encode_append]; omega
    have hp := prevStart_utf8 hcs hl
    have hcp := cpAt_utf8 hcs hl
    rw [← he'] at hp
    have hgt : e > lo := by rw [he', hlo]; simp; omega
    simp only [trimRange.back, hgt, ↓reduceIte, hp, hcp, jsSpace_eq]
    by_cases hsp : Spec.Body.isTrimSpace c = true
    · rw [ite_eq_left hsp, trimRange_back f mid (utf8 c ++ r) lo _ (fun x hx => hc x (by simp [hx]))
        (by rw [h]; simp [encode_append]) hlo (by simp [hlo]) (by simp at hf; omega)]
      simp [List.reverse_append, List.dropWhile_cons_of_pos hsp]
    · rw [ite_eq_right hsp, he']
      simp [List.reverse_append, List.dropWhile_cons_of_neg hsp, encode_append, hlo]
      omega

/-- `trimRange` of the UTF-8 of scalar values: where the whitespace at the start ends, and where
the rest ends without the whitespace at its end. -/
theorem trimRange_eq {s : ByteArray} {cs : List Nat} (hs : ∀ c ∈ cs, IsScalar c) (h : bs s = encode cs) :
    trimRange s = ((encode (cs.takeWhile Spec.Body.isTrimSpace)).length,
      (encode (cs.takeWhile Spec.Body.isTrimSpace)).length + (encode (Spec.Body.trim cs)).length) := by
  have hsplit : encode cs =
      encode (cs.takeWhile Spec.Body.isTrimSpace) ++ encode (cs.dropWhile Spec.Body.isTrimSpace) := by
    rw [← encode_append, List.takeWhile_append_dropWhile]
  have hsize : s.size = (encode (cs.takeWhile Spec.Body.isTrimSpace)).length +
      (encode (cs.dropWhile Spec.Body.isTrimSpace)).length := by
    rw [size_eq_length, h, hsplit, List.length_append]
  have hfront := trimRange_front cs [] 0 s.size hs (by simpa using h) rfl
    (by rw [size_eq_length, h]; exact Nat.le_refl _)
  have hback := trimRange_back (pre := cs.takeWhile Spec.Body.isTrimSpace) s.size
    (cs.dropWhile Spec.Body.isTrimSpace) [] _ s.size (fun c hc => hs c (List.dropWhile_subset _ hc))
    (by rw [h, hsplit, List.append_nil]) rfl hsize
    (by have := length_le_encode (cs.dropWhile Spec.Body.isTrimSpace); omega)
  simp only [Nat.zero_add] at hfront
  unfold trimRange
  simp only [hfront, hback]
  rfl

/-- `codePoints` counts the bytes of a range that are no continuation bytes. -/
theorem codePoints_go_eq (s : ByteArray) : ∀ (f i n : Nat), i + f ≤ s.size →
    codePoints.go s i f n = n + ((slice s i (i + f)).filter fun b => Decidable.decide (b &&& 0xc0 ≠ 0x80)).length
  | 0, i, n, _ => by simp [codePoints.go, slice_empty]
  | f + 1, i, n, hf => by
    rw [codePoints.go, codePoints_go_eq s f (i + 1) _ (by omega), slice_cons s (by omega) hf,
      show i + 1 + f = i + (f + 1) by omega]
    cases hc : (s.get! i &&& 0xc0 == 0x80)
    · have : Decidable.decide (s.get! i &&& 0xc0 ≠ 0x80) = true := by simpa using hc
      simp only [Bool.false_eq_true, ↓reduceIte, List.filter_cons, this, List.length_cons]
      omega
    · have : Decidable.decide (s.get! i &&& 0xc0 ≠ 0x80) = false := by simpa using hc
      simp only [↓reduceIte, List.filter_cons, this, Bool.false_eq_true]

private theorem trim_isScalar {cs : List Nat} (hs : ∀ c ∈ cs, IsScalar c) : ∀ c ∈ Spec.Body.trim cs, IsScalar c :=
  fun c hc => hs c (by
    unfold Spec.Body.trim at hc
    exact List.dropWhile_subset _ (List.mem_reverse.mp (List.dropWhile_subset _ (List.mem_reverse.mp hc))))

/-- **`trimRange` trims as ECMAScript's `String.prototype.trim` does**: on the UTF-8 of scalar
values, its range holds the UTF-8 of the values `Spec.Body.trim` keeps, `codePoints` counts them,
and the range is empty exactly when none is kept. -/
theorem trimRange_spec {s : ByteArray} {cs : List Nat} (hs : ∀ c ∈ cs, Spec.Json.IsScalar c)
    (h : bs s = Spec.Json.encode cs) :
    slice s (trimRange s).1 (trimRange s).2 = Spec.Json.encode (Spec.Body.trim cs) ∧
    codePoints s (trimRange s).1 (trimRange s).2 = (Spec.Body.trim cs).length ∧
    ((trimRange s).2 ≤ (trimRange s).1 ↔ Spec.Body.trim cs = []) := by
  rw [trimRange_eq hs h]
  -- the bytes are the whitespace at the start, the trimmed text and the whitespace at the end
  obtain ⟨tail, htail⟩ : ∃ tail, bs s = encode (cs.takeWhile Spec.Body.isTrimSpace) ++
      encode (Spec.Body.trim cs) ++ tail := by
    refine ⟨encode ((cs.dropWhile Spec.Body.isTrimSpace).reverse.takeWhile Spec.Body.isTrimSpace).reverse, ?_⟩
    rw [h, ← encode_append, ← encode_append, Spec.Body.trim, List.append_assoc, ← List.reverse_append,
      List.takeWhile_append_dropWhile, List.reverse_reverse, List.takeWhile_append_dropWhile]
  have hsize : (encode (cs.takeWhile Spec.Body.isTrimSpace)).length + (encode (Spec.Body.trim cs)).length ≤
      s.size := by
    rw [size_eq_length, htail]; simp
  have hsl := slice_of_bs htail
  dsimp only
  refine ⟨hsl, ?_, ?_⟩
  · rw [codePoints, codePoints_go_eq s _ _ 0 (by omega), Nat.add_sub_cancel_left, hsl,
      count_encode (trim_isScalar hs), Nat.zero_add]
  · rw [← encode_eq_nil, ← List.length_eq_zero_iff]
    omega

/-- info: 'Feed.trimRange_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms trimRange_spec

/-! ## The schema's CHECK -/

/-- **schema.sql's CHECK on the UTF-8 of 1 to 500 scalar values** holds exactly when the first is
not U+0000: SQLite's `length` counts the characters before the first NUL. -/
theorem Spec.Body.schemaOk_iff {cs : List Nat} (hs : ∀ c ∈ cs, Spec.Json.IsScalar c) (hne : cs ≠ [])
    (h500 : cs.length ≤ 500) : Spec.Body.schemaOk (Spec.Json.encode cs) = true ↔ cs.head? ≠ some 0 := by
  have hlen : Spec.Body.sqlLength (encode cs) = (cs.takeWhile fun c => Decidable.decide (c ≠ 0)).length := by
    unfold Spec.Body.sqlLength
    rw [takeWhile_encode hs, count_encode fun c hc => hs c (List.takeWhile_subset _ hc)]
  unfold Spec.Body.schemaOk
  rw [hlen, decide_eq_true_iff]
  obtain ⟨c, cs', rfl⟩ := List.exists_cons_of_ne_nil hne
  by_cases h0 : c = 0
  · subst h0; simp
  · rw [List.takeWhile_cons_of_pos (by simpa using h0), List.length_cons, List.head?_cons]
    have hle := (List.takeWhile_sublist (l := cs') fun c => Decidable.decide (c ≠ 0)).length_le
    rw [List.length_cons] at h500
    exact iff_of_true ⟨by omega, by omega⟩ (by simpa using h0)

/-- info: 'Feed.Spec.Body.schemaOk_iff' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Spec.Body.schemaOk_iff

/-! ## The body -/

private theorem bs_extract (s : ByteArray) (lo hi : Nat) : bs (s.extract lo hi) = slice s lo hi := by
  simp only [bs, ByteArray.data_extract, Array.toList_extract, List.extract, slice]

/-- **`postText` takes a body as the specification does**: SPEC.md:67-69 (a JSON text whose value
is an object; its `body` member, the last one, a string; its characters, trimmed of ECMAScript's
whitespace, 1 to 500 of them), then schema.sql's CHECK, which refuses a text led by U+0000; with
the handler's errors read as SPEC.md's rows, and the text the UTF-8 of the trimmed characters. -/
theorem postText_spec (a : ByteArray) (r : Http.Req) :
    textToSpec (postText a r) = Spec.Body.accept (r.toRequest a).body := by
  have hp := Json.parseTop_spec a r.bodyLo r.bodyHi #[kBodyKey] (by decide) (by decide)
  have key : (bs (#[kBodyKey][0])).map (·.toNat) = Spec.Body.bodyName := rfl
  simp only [Http.Req.toRequest]
  generalize slice a r.bodyLo r.bodyHi = t at hp
  unfold postText
  split
  · rename_i hpt
    rw [hpt] at hp
    simp [textToSpec, Err.toApi, Spec.Body.accept, Spec.Body.postBody, hp, Except.bind]
  · rename_i hpt
    rw [hpt] at hp
    obtain ⟨htext, hno⟩ := hp
    have hex : ¬ ∃ ms, IsObjectText t ms := fun ⟨ms, h⟩ => hno ms h
    simp [textToSpec, Err.toApi, Spec.Body.accept, Spec.Body.postBody, htext, hex, Except.bind]
  · rename_i fs hpt
    rw [hpt] at hp
    obtain ⟨-, ms, hms, hf⟩ := hp
    have hf0 := hf 0 (by simp)
    rw [key] at hf0
    -- the members the specification chooses are the parser's
    have hex : ∃ ms, IsObjectText t ms := ⟨ms, hms⟩
    have hch : Classical.choose hex = ms := (Classical.choose_spec hex).unique hms
    unfold Spec.Body.accept Spec.Body.postBody
    conv => rhs; rw [ite_eq_right (fun h => h hms.isText), dite_eq_left hex, hch]
    generalize member ms Spec.Body.bodyName = mv at hf0 ⊢
    cases mv with
    | none =>
      have hk : (fs[0]!.kind != Json.Kind.str) = true := by simp [show fs[0]!.kind = .absent from hf0]
      simp only [hk, ↓reduceIte]
      rfl
    | some v =>
      obtain ⟨hsl, -, hhi, -, hstr, -⟩ := hf0
      simp only
      by_cases hk : fs[0]!.kind = .str
      · obtain ⟨us, hus⟩ := hstr.mp hk
        have hex2 : ∃ us, IsString v us := ⟨us, hus⟩
        have hch2 : Classical.choose hex2 = us := (Classical.choose_spec hex2).unique hus
        conv => rhs; rw [dite_eq_left hex2, hch2]
        have hk' : (fs[0]!.kind != Json.Kind.str) = false := by simp [hk]
        simp only [hk', Bool.false_eq_true, ↓reduceIte]
        -- the string's characters, decoded and trimmed
        have hsc := hus.isScalar
        have hds := Json.decodeString_spec (hsl ▸ hus) hhi
        generalize Json.decodeString a fs[0]!.lo fs[0]!.hi = s at hds
        obtain ⟨h1, h2, h3⟩ := trimRange_spec hsc hds
        generalize trimRange s = p at h1 h2 h3
        obtain ⟨lo, hi⟩ := p
        dsimp only at h1 h2 h3 ⊢
        by_cases e1 : lo ≥ hi
        · rw [ite_eq_left e1, ite_eq_left (h3.mp e1)]; rfl
        have hne : Spec.Body.trim (scalars us) ≠ [] := fun h => e1 (h3.mpr h)
        rw [ite_eq_right e1, ite_eq_right hne]
        by_cases e2 : codePoints s lo hi > 500
        · rw [ite_eq_left e2, ite_eq_left (show 500 < (Spec.Body.trim (scalars us)).length by omega)]; rfl
        rw [ite_eq_right e2, ite_eq_right (show ¬ 500 < (Spec.Body.trim (scalars us)).length by omega)]
        -- the CHECK: the first byte is 0 exactly when the first character is U+0000
        have hscal := trim_isScalar hsc
        obtain ⟨c0, cs0, hcs⟩ := List.exists_cons_of_ne_nil hne
        have hok := Spec.Body.schemaOk_iff hscal hne (by omega)
        obtain ⟨b, rr, hu, -, hb0, -⟩ := utf8_shape (hscal c0 (by simp [hcs]))
        have hget : s.get! lo = b :=
          get!_of_slice_cons (r := rr ++ encode cs0) (by rw [h1, hcs, encode_cons, hu]; rfl)
        rw [hget]
        by_cases e3 : c0 = 0
        · have hb : b = 0 := UInt8.toNat_inj.mp (by simpa using hb0.mpr e3)
          have hs' : Spec.Body.schemaOk (encode (Spec.Body.trim (scalars us))) = false := by
            cases h : Spec.Body.schemaOk (encode (Spec.Body.trim (scalars us)))
            · rfl
            · exact absurd (hok.mp h) (by rw [hcs, e3]; simp)
          rw [ite_eq_left (by simp [hb])]
          simp [Except.bind, hs', textToSpec, Err.toApi]
        · have hb : b ≠ 0 := fun h => e3 (hb0.mp (by simp [h]))
          have hs' : Spec.Body.schemaOk (encode (Spec.Body.trim (scalars us))) = true :=
            hok.mpr (by rw [hcs]; simpa using e3)
          rw [ite_eq_right (by simpa using hb)]
          simp [Except.bind, hs', textToSpec, bs_extract, h1]
      · have hk' : (fs[0]!.kind != Json.Kind.str) = true := by simp [hk]
        conv => rhs; rw [dite_eq_right (fun h => hk (hstr.mpr h))]
        simp only [hk', ↓reduceIte]
        rfl

/-- info: 'Feed.postText_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms postText_spec

end Feed
