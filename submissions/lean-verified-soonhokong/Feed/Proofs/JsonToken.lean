import Feed.Spec.Json
import Feed.Proofs.Utf8
import Feed.Proofs.Slice

/-!
# JSON strings and numbers

`Feed/Json.lean`'s scanners and decoders against RFC 8259's strings, numbers and whitespace
(`Feed/Spec/Json.lean`):

- `skipWs` stops at the end of the longest `Ws` prefix (`skipWs_eq`, `skipWs_spec`).
- `scanString` accepts exactly the strings, with their code units (`scanString_sound`,
  `scanString_complete`), and `scanNumber` exactly the numbers, with their values, before a byte
  that cannot continue one (`scanNumber_sound`, `scanNumber_complete`).
- A string's text determines its code units (`IsString.unique`), which read as scalar values
  (`IsString.isScalar`), and a number's text its sign, digits and exponent (`IsNumber.unique`).
- `decodeString` gives the UTF-8 of a string's characters, a surrogate pair as one scalar value and
  a lone surrogate as U+FFFD (`decodeString_spec`).
- `numGt` compares a number with a natural number exactly (`numGt_spec`).
-/
namespace Feed.Json
open Spec.Json

/-! ## Bytes and ranges -/

theorem isWs_iff (b : UInt8) : isWs b = true ↔ IsWs b := by
  simp [isWs, IsWs, or_assoc]

theorem isDigit_iff (b : UInt8) : isDigit b = true ↔ IsDigit b := by
  simp [isDigit, IsDigit]

theorem isHex_iff (b : UInt8) : isHex b = true ↔ IsHexDig b := by
  simp only [isHex, isDigit, IsHexDig, IsDigit, Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq,
    UInt8.le_iff_toNat_le, UInt8.reduceToNat]
  omega

/-- `takeWhile` of a list that starts with a run of `p` and then a byte that is not. -/
theorem takeWhile_run {p : UInt8 → Bool} {w r : List UInt8} (hw : ∀ b ∈ w, p b = true)
    (hr : ∀ b ∈ r.head?, p b = false) : (w ++ r).takeWhile p = w := by
  rw [List.takeWhile_append_of_pos hw]
  cases r with
  | nil => simp
  | cons b r => simp [hr b rfl]

theorem mem_takeWhile {p : UInt8 → Bool} {l : List UInt8} {b : UInt8} (h : b ∈ l.takeWhile p) : p b = true := by
  have := List.all_takeWhile (p := p) (l := l)
  rw [List.all_eq_true] at this
  exact this b h

theorem slice_nil_iff {a : ByteArray} {i hi : Nat} (hhi : hi ≤ a.size) : slice a i hi = [] ↔ hi ≤ i := by
  rw [← List.length_eq_zero_iff, slice_length a hhi]; omega

/-- What follows a prefix of a range is the rest of the range. -/
theorem slice_append_eq {a : ByteArray} {i hi : Nat} {t r : List UInt8} (hhi : hi ≤ a.size)
    (h : slice a i hi = t ++ r) : slice a (i + t.length) hi = r := by
  have hlen := slice_length a (lo := i) hhi
  rw [h, List.length_append] at hlen
  by_cases ht : t = []
  · subst ht; simpa using h
  · have : i + t.length ≤ hi := by
      have : 0 < t.length := List.length_pos_iff.mpr ht
      omega
    rw [← slice_drop a t.length this, h, List.drop_left]

theorem slice_eq_cons {a : ByteArray} {i hi : Nat} {b : UInt8} {r : List UInt8} (hhi : hi ≤ a.size)
    (h : slice a i hi = b :: r) : i < hi ∧ a.get! i = b ∧ slice a (i + 1) hi = r := by
  have ⟨h1, h2⟩ := get!_of_slice hhi h (k := 0) (by simp)
  simp only [Nat.add_zero, List.getElem_cons_zero] at h1 h2
  exact ⟨h1, h2, slice_append_eq hhi (t := [b]) (by simpa using h)⟩

/-- A prefix of a range is a range. -/
theorem slice_prefix {a : ByteArray} {i hi : Nat} {t r : List UInt8} (hhi : hi ≤ a.size)
    (h : slice a i hi = t ++ r) : slice a i (i + t.length) = t := by
  have hlen := slice_length a (lo := i) hhi
  rw [h, List.length_append] at hlen
  by_cases ht : t = []
  · subst ht; simp [slice_empty]
  · have : i + t.length ≤ hi := by
      have : 0 < t.length := List.length_pos_iff.mpr ht
      omega
    rw [← slice_take a t.length this, h, List.take_left]

theorem slice_split (a : ByteArray) {lo m hi : Nat} (h1 : lo ≤ m) (h2 : m ≤ hi) :
    slice a lo hi = slice a lo m ++ slice a m hi := by
  have e1 := slice_take a (lo := lo) (hi := hi) (m - lo) (by omega)
  have e2 := slice_drop a (lo := lo) (hi := hi) (m - lo) (by omega)
  rw [show lo + (m - lo) = m by omega] at e1 e2
  rw [← e1, ← e2, List.take_append_drop]

theorem slice_one (a : ByteArray) {i : Nat} (h : i < a.size) : slice a i (i + 1) = [a.get! i] := by
  rw [slice_cons a (by omega) (by omega), slice_empty]

/-! ## Whitespace and digits -/

theorem skipWs_go_eq (a : ByteArray) {hi : Nat} (hhi : hi ≤ a.size) :
    ∀ f i, hi - i ≤ f → skipWs.go a hi i f = i + ((slice a i hi).takeWhile isWs).length := by
  intro f
  induction f with
  | zero =>
    intro i hf
    have : slice a i hi = [] := by
      apply List.eq_nil_of_length_eq_zero; rw [slice_length a hhi]; omega
    simp [skipWs.go, this]
  | succ f ih =>
    intro i hf
    unfold skipWs.go
    by_cases hi' : i < hi
    · rw [slice_cons a hi' hhi, List.takeWhile_cons]
      by_cases hw : isWs (a.get! i) = true
      · simp only [byte, hi', decide_true, hw, Bool.and_self, ↓reduceIte, List.length_cons]
        rw [ih (i + 1) (by omega)]; omega
      · simp only [byte, hi', decide_true, Bool.true_and, hw, Bool.false_eq_true, ↓reduceIte, List.length_nil,
          Nat.add_zero]
    · have : slice a i hi = [] := by
        apply List.eq_nil_of_length_eq_zero; rw [slice_length a hhi]; omega
      simp [hi', this]

theorem skipWs_eq_takeWhile (a : ByteArray) {hi : Nat} (hhi : hi ≤ a.size) (i : Nat) :
    skipWs a hi i = i + ((slice a i hi).takeWhile isWs).length :=
  skipWs_go_eq a hhi _ i (Nat.le_refl _)

/-- **`skipWs` stops at the end of the longest whitespace prefix.** -/
theorem skipWs_eq {a : ByteArray} {hi i : Nat} {w r : List UInt8} (hhi : hi ≤ a.size) (h : slice a i hi = w ++ r)
    (hw : Ws w) (hr : ∀ b ∈ r.head?, ¬ IsWs b) : skipWs a hi i = i + w.length := by
  rw [skipWs_eq_takeWhile a hhi, h, takeWhile_run (fun b hb => (isWs_iff b).mpr (hw b hb))
    (fun b hb => by rw [← Bool.not_eq_true, isWs_iff]; exact hr b hb)]

/-- info: 'Feed.Json.skipWs_eq' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Feed.Json.skipWs_eq

/-- `skipWs` ends a whitespace prefix that no whitespace byte follows. -/
theorem skipWs_spec (a : ByteArray) {hi : Nat} (hhi : hi ≤ a.size) (i : Nat) :
    ∃ w r, slice a i hi = w ++ r ∧ Ws w ∧ (∀ b ∈ r.head?, ¬ IsWs b) ∧ skipWs a hi i = i + w.length := by
  refine ⟨(slice a i hi).takeWhile isWs, (slice a i hi).dropWhile isWs, List.takeWhile_append_dropWhile.symm,
    fun b hb => (isWs_iff b).mp (mem_takeWhile hb), fun b hb => ?_, skipWs_eq_takeWhile a hhi i⟩
  have := List.head?_dropWhile_not isWs (slice a i hi)
  rw [hb] at this
  rw [← isWs_iff, Bool.not_eq_true]; exact this

/-- info: 'Feed.Json.skipWs_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Feed.Json.skipWs_spec

theorem scanDigits_go_eq (a : ByteArray) {hi : Nat} (hhi : hi ≤ a.size) :
    ∀ f i, hi - i ≤ f → scanDigits.go a hi i f = i + ((slice a i hi).takeWhile isDigit).length := by
  intro f
  induction f with
  | zero =>
    intro i hf
    have : slice a i hi = [] := by
      apply List.eq_nil_of_length_eq_zero; rw [slice_length a hhi]; omega
    simp [scanDigits.go, this]
  | succ f ih =>
    intro i hf
    unfold scanDigits.go
    by_cases hi' : i < hi
    · rw [slice_cons a hi' hhi, List.takeWhile_cons]
      by_cases hw : isDigit (a.get! i) = true
      · simp only [byte, hi', decide_true, hw, Bool.and_self, ↓reduceIte, List.length_cons]
        rw [ih (i + 1) (by omega)]; omega
      · simp only [byte, hi', decide_true, Bool.true_and, hw, Bool.false_eq_true, ↓reduceIte, List.length_nil,
          Nat.add_zero]
    · have : slice a i hi = [] := by
        apply List.eq_nil_of_length_eq_zero; rw [slice_length a hhi]; omega
      simp [hi', this]

theorem scanDigits_eq_takeWhile (a : ByteArray) {hi : Nat} (hhi : hi ≤ a.size) (i : Nat) :
    scanDigits a hi i = i + ((slice a i hi).takeWhile isDigit).length :=
  scanDigits_go_eq a hhi _ i (Nat.le_refl _)

/-- `scanDigits` stops after a run of digits that no digit follows. -/
theorem scanDigits_eq {a : ByteArray} {hi i : Nat} {ds r : List UInt8} (hhi : hi ≤ a.size) (h : slice a i hi = ds ++ r)
    (hd : ∀ d ∈ ds, IsDigit d) (hr : ∀ b ∈ r.head?, ¬ IsDigit b) : scanDigits a hi i = i + ds.length := by
  rw [scanDigits_eq_takeWhile a hhi, h, takeWhile_run (fun b hb => (isDigit_iff b).mpr (hd b hb))
    (fun b hb => by rw [← Bool.not_eq_true, isDigit_iff]; exact hr b hb)]

/-- `scanDigits` ends a run of digits that no digit follows. -/
theorem scanDigits_spec (a : ByteArray) {hi : Nat} (hhi : hi ≤ a.size) (i : Nat) :
    ∃ ds r, slice a i hi = ds ++ r ∧ (∀ d ∈ ds, IsDigit d) ∧ (∀ b ∈ r.head?, ¬ IsDigit b) ∧
      scanDigits a hi i = i + ds.length := by
  refine ⟨(slice a i hi).takeWhile isDigit, (slice a i hi).dropWhile isDigit, List.takeWhile_append_dropWhile.symm,
    fun b hb => (isDigit_iff b).mp (mem_takeWhile hb), fun b hb => ?_, scanDigits_eq_takeWhile a hhi i⟩
  have := List.head?_dropWhile_not isDigit (slice a i hi)
  rw [hb] at this
  rw [← isDigit_iff, Bool.not_eq_true]; exact this

/-! ## Scanning strings -/

/-- The code unit a two-character escape `\e` stands for. -/
def escUnit (e : UInt8) : Nat :=
  if e = 0x62 then 0x08 else if e = 0x66 then 0x0c else if e = 0x6e then 0x0a else if e = 0x72 then 0x0d
  else if e = 0x74 then 0x09 else e.toNat

theorem simpleEsc_mem {e : UInt8}
    (h : (e == 0x22 || e == 0x5c || e == 0x2f || e == 0x62 || e == 0x66 || e == 0x6e || e == 0x72 ||
      e == 0x74) = true) :
    (e, escUnit e) ∈ [((0x22 : UInt8), (0x22 : Nat)), (0x5c, 0x5c), (0x2f, 0x2f), (0x62, 0x08), (0x66, 0x0c),
      (0x6e, 0x0a), (0x72, 0x0d), (0x74, 0x09)] := by
  simp only [Bool.or_eq_true, beq_iff_eq] at h
  rcases h with ((((((h | h) | h) | h) | h) | h) | h) | h <;> subst h <;> decide

theorem utf8_ascii {b : UInt8} (h : b.toNat < 0x80) : utf8 b.toNat = [b] := by
  unfold utf8; rw [ite_eq_left h]; simp

theorem utf8_lead {c : Nat} (h80 : 0x80 ≤ c) (hc : c ≤ 0x10ffff) : ∃ b r, utf8 c = b :: r ∧ 0xc2 ≤ b.toNat := by
  unfold utf8
  rw [ite_eq_right (by omega)]
  split
  · exact ⟨_, _, rfl, by simp; omega⟩
  split
  · exact ⟨_, _, rfl, by simp; omega⟩
  · exact ⟨_, _, rfl, by simp; omega⟩

/-- Inside a string, `scanString.go` stops only just after the closing quote of a sequence of
characters. -/
theorem scanString_go_sound {a : ByteArray} {hi : Nat} (hhi : hi ≤ a.size) (i f : Nat) :
    ∀ j, scanString.go a hi i f = some j →
      ∃ b us r, slice a i hi = b ++ 0x22 :: r ∧ StrChars b us ∧ j = i + b.length + 1 := by
  fun_induction scanString.go a hi i f
  all_goals intro j h
  all_goals try (simp at h; done)
  case case3 i f hge b hq =>
    simp only [b, byte, beq_iff_eq] at hq
    refine ⟨[], [], slice a (i + 1) hi, ?_, .nil, by simp at h ⊢; omega⟩
    rw [slice_cons a (by omega) hhi, hq]; rfl
  case case7 i hge b h34 h32 h92 hge1 e he f ih =>
    obtain ⟨bs, us, r, hs, hc, rfl⟩ := ih j h
    simp only [b, byte, beq_iff_eq] at h92
    refine ⟨[0x5c, e] ++ bs, [escUnit e] ++ us, r, ?_, .cons (.esc e _ (simpleEsc_mem he)) hc, by simp; omega⟩
    rw [slice_cons a (by omega) hhi, slice_cons a (by omega) hhi, hs, h92]; rfl
  case case13 i hge b h34 h32 h92 hge1 e he hu hx f ih =>
    obtain ⟨bs, us, r, hs, hc, rfl⟩ := ih j h
    simp only [b, e, byte, beq_iff_eq, Bool.and_eq_true, decide_eq_true_eq, isHex_iff] at h92 hu hx
    obtain ⟨⟨⟨⟨h6, x2⟩, x3⟩, x4⟩, x5⟩ := hx
    refine ⟨[0x5c, 0x75, a.get! (i + 2), a.get! (i + 3), a.get! (i + 4), a.get! (i + 5)] ++ bs, _ ++ us, r, ?_,
      .cons (.uesc _ _ _ _ x2 x3 x4 x5) hc, by simp; omega⟩
    rw [slice_cons a (by omega) hhi, slice_cons a (by omega) hhi, slice_cons a (by omega) hhi,
      slice_cons a (by omega) hhi, slice_cons a (by omega) hhi, slice_cons a (by omega) hhi, hs, h92, hu]
    rfl
  case case16 i f hge b h34 h32 h92 h80 ih =>
    obtain ⟨bs, us, r, hs, hc, rfl⟩ := ih j h
    simp only [b, byte, beq_iff_eq, UInt8.lt_iff_toNat_lt, ← UInt8.toNat_inj, UInt8.reduceToNat] at h34 h32 h92 h80
    have hp := StrChars.cons (.plain (a.get! i).toNat (by unfold IsScalar; omega) (by omega) h34 h92) hc
    rw [utf8_ascii h80] at hp
    refine ⟨[a.get! i] ++ bs, _, r, ?_, hp, by simp; omega⟩
    rw [slice_cons a (by omega) hhi, hs]; rfl
  case case17 i hge b h34 h32 h92 h80 f hl ih =>
    obtain ⟨bs, us, r, hs, hc, rfl⟩ := ih j h
    obtain ⟨c, r', hsc, hc80, hsl, hlen⟩ := utf8Len_sound hhi (by omega : utf8Len a hi i ≠ 0)
    have hr' := slice_append_eq hhi hsl
    rw [← hlen, hl, hs] at hr'
    subst hr'
    refine ⟨utf8 c ++ bs, utf16 c ++ us, r, by rw [hsl, List.append_assoc],
      .cons (.plain c hsc (by omega) (by omega) (by omega)) hc, by simp; omega⟩
  case case18 i hge b h34 h32 h92 h80 f hl ih =>
    obtain ⟨bs, us, r, hs, hc, rfl⟩ := ih j h
    obtain ⟨c, r', hsc, hc80, hsl, hlen⟩ := utf8Len_sound hhi (by omega : utf8Len a hi i ≠ 0)
    have hr' := slice_append_eq hhi hsl
    rw [← hlen, hl, hs] at hr'
    subst hr'
    refine ⟨utf8 c ++ bs, utf16 c ++ us, r, by rw [hsl, List.append_assoc],
      .cons (.plain c hsc (by omega) (by omega) (by omega)) hc, by simp; omega⟩
  case case19 i hge b h34 h32 h92 h80 f hl ih =>
    obtain ⟨bs, us, r, hs, hc, rfl⟩ := ih j h
    obtain ⟨c, r', hsc, hc80, hsl, hlen⟩ := utf8Len_sound hhi (by omega : utf8Len a hi i ≠ 0)
    have hr' := slice_append_eq hhi hsl
    rw [← hlen, hl, hs] at hr'
    subst hr'
    refine ⟨utf8 c ++ bs, utf16 c ++ us, r, by rw [hsl, List.append_assoc],
      .cons (.plain c hsc (by omega) (by omega) (by omega)) hc, by simp; omega⟩

/-- Inside a string, `scanString.go` with enough fuel steps over a sequence of characters and
stops just after the quote that closes it. -/
theorem scanString_go_complete {a : ByteArray} {hi : Nat} (hhi : hi ≤ a.size) {b : List UInt8} {us : List Nat}
    (hs : StrChars b us) : ∀ i f r, slice a i hi = b ++ 0x22 :: r → b.length + 1 ≤ f →
      scanString.go a hi i f = some (i + b.length + 1) := by
  induction hs with
  | nil =>
    intro i f r h hf
    obtain ⟨hi', h0, -⟩ := slice_eq_cons hhi h
    obtain ⟨f, rfl⟩ : ∃ f', f = f' + 1 := ⟨f - 1, by simp at hf; omega⟩
    rw [scanString.go.eq_def]
    simp [byte, h0, Nat.not_le.mpr hi']
  | cons hc hts ih =>
    rename_i t u ts us
    intro i f r h hf
    rw [List.append_assoc] at h
    cases hc with
    | plain c hsc h20 h22 h5c =>
      have hsc' := hsc
      unfold IsScalar at hsc'
      by_cases h80 : c < 0x80
      · have hu : utf8 c = [c.toUInt8] := by unfold utf8; rw [ite_eq_left h80]
        rw [hu, List.singleton_append] at h
        obtain ⟨hi', h0, hrest⟩ := slice_eq_cons hhi h
        have hb : (a.get! i).toNat = c := by rw [h0]; simp; omega
        obtain ⟨f, rfl⟩ : ∃ f', f = f' + 1 := ⟨f - 1, by simp [hu] at hf; omega⟩
        rw [scanString.go.eq_def]
        have : ¬ c < 32 := by omega
        simp only [byte, beq_iff_eq, ← UInt8.toNat_inj, UInt8.lt_iff_toNat_lt, UInt8.reduceToNat, hb, h22, h5c,
          this, h80, Nat.not_le.mpr hi', ↓reduceIte]
        rw [ih (i + 1) f r hrest (by simp [hu] at hf; omega), hu]
        simp; omega
      · obtain ⟨b0, r0, hu, hb0⟩ := utf8_lead (by omega) hsc'.1
        have hlen := utf8Len_eq hhi hsc (by omega) h
        have hrest := slice_append_eq hhi h
        have h' := h
        rw [hu, List.cons_append] at h'
        obtain ⟨hi', h0, -⟩ := slice_eq_cons hhi h'
        rw [← h0] at hb0
        simp only [List.length_append] at hf ⊢
        rw [utf8_length] at hlen hrest hf ⊢
        rw [ite_eq_right h80] at hlen hrest hf ⊢
        obtain ⟨f, rfl⟩ : ∃ f', f = f' + 1 := ⟨f - 1, by omega⟩
        rw [scanString.go.eq_def]
        simp only [byte, beq_iff_eq, ← UInt8.toNat_inj, UInt8.lt_iff_toNat_lt, UInt8.reduceToNat,
          Nat.not_le.mpr hi', ↓reduceIte, show ¬ (a.get! i).toNat = 34 by omega, show ¬ (a.get! i).toNat < 32 by omega,
          show ¬ (a.get! i).toNat = 92 by omega, show ¬ (a.get! i).toNat < 128 by omega]
        by_cases c2 : c < 0x800
        · rw [ite_eq_left c2] at hlen hrest hf ⊢
          obtain ⟨f, rfl⟩ : ∃ f', f = f' + 1 := ⟨f - 1, by omega⟩
          rw [hlen]; show scanString.go a hi (i + 2) f = _
          rw [ih (i + 2) f r hrest (by omega), Option.some.injEq]; omega
        rw [ite_eq_right c2] at hlen hrest hf ⊢
        by_cases c3 : c < 0x10000
        · rw [ite_eq_left c3] at hlen hrest hf ⊢
          obtain ⟨f, rfl⟩ : ∃ f', f = f' + 2 := ⟨f - 2, by omega⟩
          rw [hlen]; show scanString.go a hi (i + 3) f = _
          rw [ih (i + 3) f r hrest (by omega), Option.some.injEq]; omega
        · rw [ite_eq_right c3] at hlen hrest hf ⊢
          obtain ⟨f, rfl⟩ : ∃ f', f = f' + 3 := ⟨f - 3, by omega⟩
          rw [hlen]; show scanString.go a hi (i + 4) f = _
          rw [ih (i + 4) f r hrest (by omega), Option.some.injEq]; omega
    | esc e u hm =>
      simp only [List.cons_append, List.nil_append] at h
      obtain ⟨hi', h0, h'⟩ := slice_eq_cons hhi h
      obtain ⟨hi1, h1, hrest⟩ := slice_eq_cons hhi h'
      obtain ⟨f, rfl⟩ : ∃ f', f = f' + 2 := ⟨f - 2, by simp at hf; omega⟩
      rw [scanString.go.eq_def]
      simp only [List.mem_cons, Prod.mk.injEq, List.not_mem_nil, or_false] at hm
      rcases hm with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ |
        ⟨rfl, rfl⟩ <;>
      · simp only [byte, h0, h1, Nat.not_le.mpr hi', Nat.not_le.mpr hi1, ↓reduceIte]
        simp
        rw [ih (i + 2) f r hrest (by simp at hf; omega)]
        simp; omega
    | uesc h1 h2 h3 h4 x1 x2 x3 x4 =>
      simp only [List.cons_append, List.nil_append] at h
      obtain ⟨hi0, g0, h'⟩ := slice_eq_cons hhi h
      obtain ⟨hi1, g1, h'⟩ := slice_eq_cons hhi h'
      obtain ⟨hi2, g2, h'⟩ := slice_eq_cons hhi h'
      obtain ⟨hi3, g3, h'⟩ := slice_eq_cons hhi h'
      obtain ⟨hi4, g4, h'⟩ := slice_eq_cons hhi h'
      obtain ⟨hi5, g5, hrest⟩ := slice_eq_cons hhi h'
      obtain ⟨f, rfl⟩ : ∃ f', f = f' + 6 := ⟨f - 6, by simp at hf; omega⟩
      rw [scanString.go.eq_def]
      rw [← isHex_iff] at x1 x2 x3 x4
      simp [byte, g0, g1, g2, g3, g4, g5, x1, x2, x3, x4, Nat.not_le.mpr hi0, Nat.not_le.mpr hi1,
        show i + 6 ≤ hi by omega]
      rw [ih (i + 6) f r hrest (by simp at hf; omega)]
      simp; omega

/-- **`scanString` accepts only strings**: from the byte after an opening quote at `lo`, the
index it gives ends a JSON string that starts at `lo`. -/
theorem scanString_sound {a : ByteArray} {hi lo j : Nat} (hhi : hi ≤ a.size) (hq : a.get! lo = 0x22)
    (h : scanString a hi (lo + 1) = some j) : lo + 2 ≤ j ∧ j ≤ hi ∧ ∃ us, IsString (slice a lo j) us := by
  obtain ⟨b, us, r, hs, hc, rfl⟩ := scanString_go_sound hhi _ _ j h
  have hlen := slice_length a (lo := lo + 1) hhi
  rw [hs] at hlen; simp at hlen
  refine ⟨by omega, by omega, us, b, ?_, hc⟩
  rw [slice_cons a (by omega) (by omega), hq, show lo + 1 + b.length + 1 = lo + 1 + (b.length + 1) by omega,
    ← slice_take a (lo := lo + 1) (hi := hi) (b.length + 1) (by omega), hs,
    List.take_append, List.take_of_length_le (by omega), show b.length + 1 - b.length = 1 by omega]
  simp

/-- info: 'Feed.Json.scanString_sound' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Feed.Json.scanString_sound

/-- **`scanString` finds every string**: at a JSON string, from the byte after its opening quote,
it gives the index just after its closing quote. -/
theorem scanString_complete {a : ByteArray} {hi lo : Nat} {t r : List UInt8} {us : List Nat} (hhi : hi ≤ a.size)
    (h : slice a lo hi = t ++ r) (ht : IsString t us) : scanString a hi (lo + 1) = some (lo + t.length) := by
  obtain ⟨b, rfl, hc⟩ := ht
  have h' : slice a lo hi = 0x22 :: (b ++ 0x22 :: r) := by rw [h]; simp
  obtain ⟨hlo, -, hrest⟩ := slice_eq_cons hhi h'
  have hlen := slice_length a (lo := lo + 1) hhi
  rw [hrest] at hlen; simp at hlen
  unfold scanString
  rw [scanString_go_complete hhi hc (lo + 1) _ r hrest (by omega)]
  simp; omega

/-- info: 'Feed.Json.scanString_complete' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Feed.Json.scanString_complete

/-! ## A string's characters -/

theorem strChar_ne_nil {t : List UInt8} {u : List Nat} (h : StrChar t u) : t ≠ [] := by
  cases h <;> simp [utf8_ne_nil]

theorem strChars_nil {b : List UInt8} {us : List Nat} (h : StrChars b us) (hb : b = []) : us = [] := by
  cases h with
  | nil => rfl
  | cons hc _ => exact absurd (List.append_eq_nil_iff.mp hb).1 (strChar_ne_nil hc)

theorem strChars_cons {b : List UInt8} {us : List Nat} (h : StrChars b us) (hb : b ≠ []) :
    ∃ t u ts us', b = t ++ ts ∧ us = u ++ us' ∧ StrChar t u ∧ StrChars ts us' := by
  cases h with
  | nil => exact absurd rfl hb
  | cons hc hts => exact ⟨_, _, _, _, rfl, rfl, hc, hts⟩

/-- The text of a character determines it: no character's text starts another's. -/
theorem strChar_det {t t' ts ts' : List UInt8} {u u' : List Nat} (h : StrChar t u) (h' : StrChar t' u')
    (he : t ++ ts = t' ++ ts') : t = t' ∧ u = u' := by
  cases h with
  | plain c hc _ _ h5c =>
    cases h' with
    | plain c' hc' _ _ _ =>
      obtain ⟨rfl, -⟩ := utf8_append_inj hc.1 hc'.1 he
      exact ⟨rfl, rfl⟩
    | esc e u hm =>
      have := (utf8Head_utf8 hc.1 ts).symm.trans (he ▸ rfl : utf8Head (utf8 c ++ ts) = utf8Head ([0x5c, e] ++ ts'))
      simp [utf8Head] at this
      exact absurd this.1 h5c
    | uesc h1 h2 h3 h4 =>
      have := (utf8Head_utf8 hc.1 ts).symm.trans
        (he ▸ rfl : utf8Head (utf8 c ++ ts) = utf8Head ([0x5c, 0x75, h1, h2, h3, h4] ++ ts'))
      simp [utf8Head] at this
      exact absurd this.1 h5c
  | esc e u hm =>
    cases h' with
    | plain c' hc' _ _ h5c =>
      have := (utf8Head_utf8 hc'.1 ts').symm.trans
        (he ▸ rfl : utf8Head (utf8 c' ++ ts') = utf8Head ([0x5c, e] ++ ts))
      simp [utf8Head] at this
      exact absurd this.1 h5c
    | esc e' u' hm' =>
      simp only [List.cons_append, List.nil_append, List.cons.injEq] at he
      obtain ⟨-, rfl, -⟩ := he
      refine ⟨rfl, ?_⟩
      simp only [List.mem_cons, Prod.mk.injEq, List.not_mem_nil, or_false] at hm hm'
      congr 1
      rcases hm with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ |
        ⟨rfl, rfl⟩ <;> simp at hm' <;> omega
    | uesc h1 h2 h3 h4 =>
      simp only [List.cons_append, List.nil_append, List.cons.injEq] at he
      obtain ⟨-, rfl, -⟩ := he
      simp at hm
  | uesc h1 h2 h3 h4 =>
    cases h' with
    | plain c' hc' _ _ h5c =>
      have := (utf8Head_utf8 hc'.1 ts').symm.trans
        (he ▸ rfl : utf8Head (utf8 c' ++ ts') = utf8Head ([0x5c, 0x75, h1, h2, h3, h4] ++ ts))
      simp [utf8Head] at this
      exact absurd this.1 h5c
    | esc e' u' hm' =>
      simp only [List.cons_append, List.nil_append, List.cons.injEq] at he
      obtain ⟨-, rfl, -⟩ := he
      simp at hm'
    | uesc g1 g2 g3 g4 =>
      simp only [List.cons_append, List.nil_append, List.cons.injEq] at he
      obtain ⟨-, -, rfl, rfl, rfl, rfl, -⟩ := he
      exact ⟨rfl, rfl⟩

/-- A sequence of characters has one reading. -/
theorem strChars_unique {b : List UInt8} {us us' : List Nat} (h : StrChars b us) (h' : StrChars b us') :
    us = us' := by
  induction h generalizing us' with
  | nil => exact (strChars_nil h' rfl).symm
  | cons hc hts ih =>
    obtain ⟨t', u', ts', us'', he, rfl, hc', hts'⟩ := strChars_cons h' (by
      intro he; exact strChar_ne_nil hc (List.append_eq_nil_iff.mp he).1)
    obtain ⟨rfl, rfl⟩ := strChar_det hc hc' he
    rw [ih (List.append_cancel_left he ▸ hts')]

/-- **A string has one reading**: its text determines its code units. -/
theorem _root_.Feed.Spec.Json.IsString.unique {t : List UInt8} {us us' : List Nat} (h : IsString t us)
    (h' : IsString t us') : us = us' := by
  obtain ⟨b, rfl, hb⟩ := h
  obtain ⟨b', he, hb'⟩ := h'
  have he' := List.append_cancel_right he
  simp only [List.cons.injEq, true_and] at he'
  subst he'
  exact strChars_unique hb hb'

/-- info: 'Feed.Spec.Json.IsString.unique' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Feed.Spec.Json.IsString.unique

theorem hexVal_lt {b : UInt8} (h : IsHexDig b) : Spec.Json.hexVal b < 16 := by
  unfold IsHexDig IsDigit at h
  unfold Spec.Json.hexVal
  simp only [UInt8.le_iff_toNat_le, UInt8.reduceToNat] at h ⊢
  split <;> (try split) <;> omega

theorem strChar_lt {t : List UInt8} {u : List Nat} (h : StrChar t u) : ∀ v ∈ u, v < 0x10000 := by
  cases h with
  | plain c hc _ _ _ =>
    unfold utf16; unfold IsScalar at hc
    split <;> simp <;> omega
  | esc e u hm =>
    simp only [List.mem_cons, Prod.mk.injEq, List.not_mem_nil, or_false] at hm
    intro v hv; simp at hv; subst hv
    rcases hm with ⟨-, rfl⟩ | ⟨-, rfl⟩ | ⟨-, rfl⟩ | ⟨-, rfl⟩ | ⟨-, rfl⟩ | ⟨-, rfl⟩ | ⟨-, rfl⟩ | ⟨-, rfl⟩ <;> decide
  | uesc h1 h2 h3 h4 x1 x2 x3 x4 =>
    intro v hv; simp at hv; subst hv
    have := hexVal_lt x1; have := hexVal_lt x2; have := hexVal_lt x3; have := hexVal_lt x4
    omega

theorem strChars_lt {b : List UInt8} {us : List Nat} (h : StrChars b us) : ∀ v ∈ us, v < 0x10000 := by
  induction h with
  | nil => simp
  | cons hc _ ih =>
    intro v hv
    rcases List.mem_append.mp hv with hv | hv
    · exact strChar_lt hc v hv
    · exact ih v hv

/-- A string's code units are UTF-16 code units, each below 0x10000. -/
theorem _root_.Feed.Spec.Json.IsString.lt {t : List UInt8} {us : List Nat} (h : IsString t us) :
    ∀ u ∈ us, u < 0x10000 := by
  obtain ⟨b, -, hb⟩ := h
  exact strChars_lt hb

/-- **A string's text is scalar values**: lone surrogates read as U+FFFD, pairs combined. -/
theorem _root_.Feed.Spec.Json.IsString.isScalar {t : List UInt8} {us : List Nat} (h : IsString t us) :
    ∀ c ∈ scalars us, IsScalar c :=
  scalars_isScalar us h.lt

/-- info: 'Feed.Spec.Json.IsString.isScalar' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Feed.Spec.Json.IsString.isScalar

/-- A string starts with a quote. -/
theorem _root_.Feed.Spec.Json.IsString.head {t : List UInt8} {us : List Nat} (h : IsString t us) :
    t.head? = some 0x22 := by
  obtain ⟨b, rfl, -⟩ := h; simp

/-- ASCII bytes are the UTF-8 of their values. -/
theorem encode_ascii {l : List UInt8} (h : ∀ b ∈ l, b < 0x80) : encode (l.map UInt8.toNat) = l := by
  induction l with
  | nil => rfl
  | cons b l ih =>
    rw [List.map_cons, encode_cons, ih (fun x hx => h x (by simp [hx])),
      utf8_ascii (by have := h b (by simp); simpa [UInt8.lt_iff_toNat_lt] using this)]
    rfl

theorem strChar_utf8 {t : List UInt8} {u : List Nat} (h : StrChar t u) :
    ∃ cs, (∀ c ∈ cs, IsScalar c) ∧ t = encode cs := by
  cases h with
  | plain c hc _ _ _ => exact ⟨[c], by simpa using hc, by simp⟩
  | esc e u hm =>
    have he : e < 0x80 := by
      simp only [List.mem_cons, Prod.mk.injEq, List.not_mem_nil, or_false] at hm
      rcases hm with ⟨rfl, -⟩ | ⟨rfl, -⟩ | ⟨rfl, -⟩ | ⟨rfl, -⟩ | ⟨rfl, -⟩ | ⟨rfl, -⟩ | ⟨rfl, -⟩ | ⟨rfl, -⟩ <;> decide
    refine ⟨[0x5c, e].map UInt8.toNat, ?_, (encode_ascii ?_).symm⟩
    · simp only [List.map_cons, List.map_nil, List.mem_cons, List.not_mem_nil, or_false]
      have := UInt8.lt_iff_toNat_lt.mp he
      rintro c (rfl | rfl) <;> unfold IsScalar <;> simp at this ⊢ <;> omega
    · simp only [List.mem_cons, List.not_mem_nil, or_false]; rintro b (rfl | rfl); decide; exact he
  | uesc h1 h2 h3 h4 x1 x2 x3 x4 =>
    have hx : ∀ b, IsHexDig b → b < 0x80 := by
      intro b hb; unfold IsHexDig IsDigit at hb
      simp only [UInt8.le_iff_toNat_le, UInt8.lt_iff_toNat_lt, UInt8.reduceToNat] at hb ⊢; omega
    have hall : ∀ b ∈ [0x5c, 0x75, h1, h2, h3, h4], b < 0x80 := by
      simp only [List.mem_cons, List.not_mem_nil, or_false]
      rintro b (rfl | rfl | rfl | rfl | rfl | rfl)
      · decide
      · decide
      · exact hx _ x1
      · exact hx _ x2
      · exact hx _ x3
      · exact hx _ x4
    refine ⟨[0x5c, 0x75, h1, h2, h3, h4].map UInt8.toNat, ?_, (encode_ascii hall).symm⟩
    intro c hc
    obtain ⟨b, hb, rfl⟩ := List.mem_map.mp hc
    have := UInt8.lt_iff_toNat_lt.mp (hall b hb)
    unfold IsScalar; simp at this; omega

/-- **A string's text is UTF-8** (RFC 8259 §8.1): the UTF-8 of some scalar values. -/
theorem _root_.Feed.Spec.Json.IsString.utf8 {t : List UInt8} {us : List Nat} (h : IsString t us) :
    ∃ cs, (∀ c ∈ cs, IsScalar c) ∧ t = encode cs := by
  obtain ⟨b, rfl, hb⟩ := h
  have : ∃ cs, (∀ c ∈ cs, IsScalar c) ∧ b = encode cs := by
    induction hb with
    | nil => exact ⟨[], by simp, rfl⟩
    | cons hc _ ih =>
      obtain ⟨cs, hcs, rfl⟩ := strChar_utf8 hc
      obtain ⟨ds, hds, rfl⟩ := ih
      exact ⟨cs ++ ds, fun c hc => (List.mem_append.mp hc).elim (hcs c) (hds c), (encode_append cs ds).symm⟩
  obtain ⟨cs, hcs, rfl⟩ := this
  have h22 : Spec.Json.utf8 0x22 = [0x22] := by decide
  refine ⟨0x22 :: cs ++ [0x22], ?_, by simp [encode_append, h22]⟩
  intro c hc
  simp only [List.cons_append, List.mem_cons, List.mem_append, List.not_mem_nil, or_false] at hc
  rcases hc with rfl | hc | rfl
  · unfold IsScalar; omega
  · exact hcs c hc
  · unfold IsScalar; omega

/-- info: 'Feed.Spec.Json.IsString.utf8' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Feed.Spec.Json.IsString.utf8

/-- The characters of a string body without a backslash are scalar values written as UTF-8, and
its code units are their UTF-16. -/
theorem strChars_noEsc {b : List UInt8} {us : List Nat} (h : StrChars b us) (hb : 0x5c ∉ b) :
    ∃ cs, (∀ c ∈ cs, IsScalar c) ∧ b = encode cs ∧ us = cs.flatMap utf16 := by
  induction h with
  | nil => exact ⟨[], by simp, rfl, rfl⟩
  | cons hc _ ih =>
    rename_i t u ts us
    obtain ⟨cs, hcs, rfl, rfl⟩ := ih (fun h => hb (List.mem_append_right _ h))
    cases hc with
    | plain c hsc _ _ _ =>
      exact ⟨c :: cs, fun x hx => (List.mem_cons.mp hx).elim (· ▸ hsc) (hcs x), by simp, by simp⟩
    | esc e u _ => exact absurd (by simp) hb
    | uesc h1 h2 h3 h4 => exact absurd (by simp) hb

/-! ## Decoding strings -/

theorem bs_pushUtf8 (out : ByteArray) (c : Nat) : bs (pushUtf8 out c) = bs out ++ utf8 c := by
  unfold pushUtf8 utf8
  split <;> (try split) <;> (try split) <;> simp

/-- The parser's hex digit values are RFC 5234's. -/
theorem hexVal_eq {b : UInt8} (h : IsHexDig b) : Json.hexVal b = Spec.Json.hexVal b := by
  unfold IsHexDig IsDigit at h
  unfold Json.hexVal Spec.Json.hexVal isDigit
  simp only [UInt8.le_iff_toNat_le, UInt8.reduceToNat, Bool.and_eq_true, decide_eq_true_eq] at h ⊢
  have hb := UInt8.toNat_lt b
  rcases h with h | h | h
  · rw [ite_eq_left h, ite_eq_left (by omega), UInt8.toNat_sub_of_le _ _ (by simp [UInt8.le_iff_toNat_le]; omega)]
    rfl
  · rw [ite_eq_right (by omega), ite_eq_right (by omega), ite_eq_right (by omega), ite_eq_left (by omega)]
    simp only [UInt8.toNat_add,
      UInt8.toNat_sub_of_le _ _ (show (0x41 : UInt8) ≤ b by simp [UInt8.le_iff_toNat_le]; omega)]
    simp; omega
  · rw [ite_eq_right (by omega), ite_eq_left (by omega), ite_eq_right (by omega), ite_eq_right (by omega)]
    simp only [UInt8.toNat_add,
      UInt8.toNat_sub_of_le _ _ (show (0x61 : UInt8) ≤ b by simp [UInt8.le_iff_toNat_le]; omega)]
    simp; omega

/-- A fact about the bytes of a range, checked byte by byte. -/
theorem mask_ofNat {b : UInt8} {lo n : Nat} (hlo : lo ≤ b.toNat) (hn : b.toNat < lo + n) {P : UInt8 → Prop}
    (h : ∀ k : Fin n, P (UInt8.ofNat (lo + k.val))) : P b := by
  have := h ⟨b.toNat - lo, by omega⟩
  simp only at this
  rwa [show lo + (b.toNat - lo) = b.toNat by omega, UInt8.ofNat_toNat] at this

theorem land_63 (x : Nat) : x &&& 63 = x % 64 := Nat.and_two_pow_sub_one_eq_mod x 6
theorem land_31 (x : Nat) : x &&& 31 = x % 32 := Nat.and_two_pow_sub_one_eq_mod x 5
theorem land_15 (x : Nat) : x &&& 15 = x % 16 := Nat.and_two_pow_sub_one_eq_mod x 4
theorem land_7 (x : Nat) : x &&& 7 = x % 8 := Nat.and_two_pow_sub_one_eq_mod x 3

theorem cont_mask {b : UInt8} (h : 0x80 ≤ b.toNat ∧ b.toNat ≤ 0xbf) : (b &&& 0xc0 == 0x80) = true :=
  mask_ofNat (lo := 0x80) (n := 64) h.1 (by omega) (P := fun b => (b &&& 0xc0 == 0x80) = true) (by decide)

theorem lead2_mask {b : UInt8} (h : 0xc2 ≤ b.toNat ∧ b.toNat ≤ 0xdf) : (b &&& 0xe0 == 0xc0) = true :=
  mask_ofNat (lo := 0xc2) (n := 30) h.1 (by omega) (P := fun b => (b &&& 0xe0 == 0xc0) = true) (by decide)

theorem lead3_mask {b : UInt8} (h : 0xe0 ≤ b.toNat ∧ b.toNat ≤ 0xef) :
    (b &&& 0xe0 == 0xc0) = false ∧ (b &&& 0xf0 == 0xe0) = true :=
  mask_ofNat (lo := 0xe0) (n := 16) h.1 (by omega)
    (P := fun b => (b &&& 0xe0 == 0xc0) = false ∧ (b &&& 0xf0 == 0xe0) = true) (by decide)

theorem lead4_mask {b : UInt8} (h : 0xf0 ≤ b.toNat ∧ b.toNat ≤ 0xf4) :
    (b &&& 0xe0 == 0xc0) = false ∧ (b &&& 0xf0 == 0xe0) = false ∧ (b &&& 0xf8 == 0xf0) = true :=
  mask_ofNat (lo := 0xf0) (n := 5) h.1 (by omega)
    (P := fun b => (b &&& 0xe0 == 0xc0) = false ∧ (b &&& 0xf0 == 0xe0) = false ∧ (b &&& 0xf8 == 0xf0) = true)
    (by decide)

/-- `decodeString` copies the UTF-8 of a scalar value of 0x80 or more as it is. -/
theorem decode_utf8 {a : ByteArray} {hi i c f : Nat} {out : ByteArray} {r : List UInt8} (hhi : hi ≤ a.size)
    (hs : slice a i (hi - 1) = utf8 c ++ r) (hc : IsScalar c) (h80 : 0x80 ≤ c) :
    decodeString.go a hi i (f + 1) out =
      decodeString.go a hi (i + (utf8 c).length) f (Bytes.appendSlice out a i (i + (utf8 c).length)) := by
  have hhi' : hi - 1 ≤ a.size := by omega
  have hg := fun k (hk : k < (utf8 c ++ r).length) => get!_of_slice hhi' hs hk
  unfold IsScalar at hc
  rw [decodeString.go.eq_2]
  by_cases c2 : c < 0x800
  · have hu : utf8 c = [(0xc0 + c / 0x40).toUInt8, (0x80 + c % 0x40).toUInt8] := by
      unfold utf8; rw [ite_eq_right (by omega), ite_eq_left c2]
    rw [hu] at hg ⊢
    obtain ⟨_, h0⟩ := hg 0 (by simp)
    obtain ⟨hi1, h1⟩ := hg 1 (by simp)
    simp only [Nat.add_zero, List.cons_append, List.getElem_cons_zero, List.getElem_cons_succ] at h0 h1
    have e0 : (a.get! i).toNat = 0xc0 + c / 0x40 := by rw [h0]; simp; omega
    have e1 : (a.get! (i + 1)).toNat = 0x80 + c % 0x40 := by rw [h1]; simp; omega
    have m0 := lead2_mask (b := a.get! i) (by omega)
    have m1 := cont_mask (b := a.get! (i + 1)) (by omega)
    have n0 : (a.get! i == 92) = false := by simp [← UInt8.toNat_inj, e0]; omega
    have n1 : ¬ a.get! i < 128 := by simp [UInt8.lt_iff_toNat_lt, e0]; omega
    have hcp : ((a.get! i).toNat &&& 31) * 64 + ((a.get! (i + 1)).toNat &&& 63) = c := by
      rw [land_31, land_63, e0, e1]; omega
    simp [byte, n0, n1, m0, m1, show ¬ i + 1 ≥ hi by omega, hi1, hcp, show ¬ c < 128 by omega,
      show ¬ 55296 ≤ c by omega, show ¬ c > 1114111 by omega]
  by_cases c3 : c < 0x10000
  · have hu : utf8 c = [(0xe0 + c / 0x1000).toUInt8, (0x80 + c / 0x40 % 0x40).toUInt8, (0x80 + c % 0x40).toUInt8] := by
      unfold utf8; rw [ite_eq_right (by omega), ite_eq_right c2, ite_eq_left c3]
    rw [hu] at hg ⊢
    obtain ⟨_, h0⟩ := hg 0 (by simp)
    obtain ⟨hi1, h1⟩ := hg 1 (by simp)
    obtain ⟨hi2, h2⟩ := hg 2 (by simp)
    simp only [Nat.add_zero, List.cons_append, List.getElem_cons_zero, List.getElem_cons_succ] at h0 h1 h2
    have e0 : (a.get! i).toNat = 0xe0 + c / 0x1000 := by rw [h0]; simp; omega
    have e1 : (a.get! (i + 1)).toNat = 0x80 + c / 0x40 % 0x40 := by rw [h1]; simp; omega
    have e2 : (a.get! (i + 2)).toNat = 0x80 + c % 0x40 := by rw [h2]; simp; omega
    have m0 := lead3_mask (b := a.get! i) (by omega)
    have m1 := cont_mask (b := a.get! (i + 1)) (by omega)
    have m2 := cont_mask (b := a.get! (i + 2)) (by omega)
    have n0 : (a.get! i == 92) = false := by simp [← UInt8.toNat_inj, e0]; omega
    have n1 : ¬ a.get! i < 128 := by simp [UInt8.lt_iff_toNat_lt, e0]; omega
    have hcp : (((a.get! i).toNat &&& 15) * 64 + ((a.get! (i + 1)).toNat &&& 63)) * 64 +
        ((a.get! (i + 2)).toNat &&& 63) = c := by
      rw [land_15, land_63, land_63, e0, e1, e2]; omega
    simp [byte, n0, n1, m0.1, m0.2, m1, m2, show ¬ i + 1 ≥ hi by omega, hi1, hi2, hcp, show ¬ c < 2048 by omega,
      show ¬ (55296 ≤ c ∧ c < 57344) by omega, show ¬ c > 1114111 by omega]
  · have hu : utf8 c = [(0xf0 + c / 0x40000).toUInt8, (0x80 + c / 0x1000 % 0x40).toUInt8,
        (0x80 + c / 0x40 % 0x40).toUInt8, (0x80 + c % 0x40).toUInt8] := by
      unfold utf8; rw [ite_eq_right (by omega), ite_eq_right c2, ite_eq_right c3]
    rw [hu] at hg ⊢
    obtain ⟨_, h0⟩ := hg 0 (by simp)
    obtain ⟨hi1, h1⟩ := hg 1 (by simp)
    obtain ⟨hi2, h2⟩ := hg 2 (by simp)
    obtain ⟨hi3, h3⟩ := hg 3 (by simp)
    simp only [Nat.add_zero, List.cons_append, List.getElem_cons_zero, List.getElem_cons_succ] at h0 h1 h2 h3
    have e0 : (a.get! i).toNat = 0xf0 + c / 0x40000 := by rw [h0]; simp; omega
    have e1 : (a.get! (i + 1)).toNat = 0x80 + c / 0x1000 % 0x40 := by rw [h1]; simp; omega
    have e2 : (a.get! (i + 2)).toNat = 0x80 + c / 0x40 % 0x40 := by rw [h2]; simp; omega
    have e3 : (a.get! (i + 3)).toNat = 0x80 + c % 0x40 := by rw [h3]; simp; omega
    have m0 := lead4_mask (b := a.get! i) (by omega)
    have m1 := cont_mask (b := a.get! (i + 1)) (by omega)
    have m2 := cont_mask (b := a.get! (i + 2)) (by omega)
    have m3 := cont_mask (b := a.get! (i + 3)) (by omega)
    have n0 : (a.get! i == 92) = false := by simp [← UInt8.toNat_inj, e0]; omega
    have n1 : ¬ a.get! i < 128 := by simp [UInt8.lt_iff_toNat_lt, e0]; omega
    have hcp : ((((a.get! i).toNat &&& 7) * 64 + ((a.get! (i + 1)).toNat &&& 63)) * 64 +
        ((a.get! (i + 2)).toNat &&& 63)) * 64 + ((a.get! (i + 3)).toNat &&& 63) = c := by
      rw [land_7, land_63, land_63, land_63, e0, e1, e2, e3]; omega
    simp [byte, n0, n1, m0.1, m0.2.1, m0.2.2, m1, m2, m3, show ¬ i + 1 ≥ hi by omega, hi1, hi2, hi3, hcp,
      show ¬ c < 65536 by omega, show ¬ c < 57344 by omega, show ¬ c > 1114111 by omega]

theorem hex4_eq {a : ByteArray} {i : Nat} {h1 h2 h3 h4 : UInt8} (g1 : a.get! i = h1) (g2 : a.get! (i + 1) = h2)
    (g3 : a.get! (i + 2) = h3) (g4 : a.get! (i + 3) = h4) (x1 : IsHexDig h1) (x2 : IsHexDig h2)
    (x3 : IsHexDig h3) (x4 : IsHexDig h4) :
    hex4 a i =
      ((Spec.Json.hexVal h1 * 16 + Spec.Json.hexVal h2) * 16 + Spec.Json.hexVal h3) * 16 + Spec.Json.hexVal h4 := by
  unfold hex4
  simp only [byte, g1, g2, g3, g4, hexVal_eq x1, hexVal_eq x2, hexVal_eq x3, hexVal_eq x4]

theorem hex4_slice {a : ByteArray} {i hi : Nat} {h1 h2 h3 h4 : UInt8} {r : List UInt8} (hhi : hi ≤ a.size)
    (hs : slice a i hi = h1 :: h2 :: h3 :: h4 :: r) (x1 : IsHexDig h1) (x2 : IsHexDig h2) (x3 : IsHexDig h3)
    (x4 : IsHexDig h4) :
    hex4 a i =
      ((Spec.Json.hexVal h1 * 16 + Spec.Json.hexVal h2) * 16 + Spec.Json.hexVal h3) * 16 + Spec.Json.hexVal h4 := by
  have g0 := (get!_of_slice hhi hs (k := 0) (by simp)).2
  have g1 := (get!_of_slice hhi hs (k := 1) (by simp)).2
  have g2 := (get!_of_slice hhi hs (k := 2) (by simp)).2
  have g3 := (get!_of_slice hhi hs (k := 3) (by simp)).2
  simp only [Nat.add_zero, List.getElem_cons_zero, List.getElem_cons_succ] at g0 g1 g2 g3
  exact hex4_eq g0 g1 g2 g3 x1 x2 x3 x4

/-- Only a `\u` escape stands for a low surrogate first. -/
theorem strChar_head_not_low {t : List UInt8} {u : List Nat} (h : StrChar t u) (ht : ¬ ∃ r, t = 0x5c :: 0x75 :: r) :
    ∀ v ∈ u.head?, ¬ (0xdc00 ≤ v ∧ v ≤ 0xdfff) := by
  cases h with
  | plain c hc _ _ _ =>
    unfold utf16; unfold IsScalar at hc
    split <;> simp <;> omega
  | esc e u hm =>
    simp only [List.mem_cons, Prod.mk.injEq, List.not_mem_nil, or_false] at hm
    intro v hv; simp at hv; subst hv
    rcases hm with ⟨-, rfl⟩ | ⟨-, rfl⟩ | ⟨-, rfl⟩ | ⟨-, rfl⟩ | ⟨-, rfl⟩ | ⟨-, rfl⟩ | ⟨-, rfl⟩ | ⟨-, rfl⟩ <;> decide
  | uesc h1 h2 h3 h4 => exact absurd ⟨_, rfl⟩ ht

theorem utf8_head_ne {c : Nat} (hc : c ≤ 0x10ffff) (h5c : c ≠ 0x5c) : ∀ b ∈ (utf8 c).head?, b ≠ 0x5c := by
  intro b hb hb5
  subst hb5
  obtain ⟨r, hr⟩ : ∃ r, utf8 c = 0x5c :: r := by
    cases h : utf8 c with
    | nil => exact absurd h (utf8_ne_nil c)
    | cons x r => rw [h] at hb; simp at hb; exact ⟨r, by rw [hb]⟩
  have := utf8Head_utf8 hc []
  rw [List.append_nil, hr] at this
  simp [utf8Head] at this
  exact h5c this.1.symm

/-- `decodeString.go`, at a sequence of characters that ends with the closing quote at `hi - 1`,
appends the UTF-8 of their scalar values. -/
theorem decodeString_go_spec {a : ByteArray} {hi : Nat} (hhi : hi ≤ a.size) :
    ∀ f i out b us, slice a i (hi - 1) = b → StrChars b us → b.length ≤ f →
      bs (decodeString.go a hi i f out) = bs out ++ encode (scalars us) := by
  have hhi' : hi - 1 ≤ a.size := by omega
  intro f
  induction f with
  | zero =>
    intro i out b us hs hc hf
    have hb : b = [] := List.eq_nil_of_length_eq_zero (by omega)
    rw [strChars_nil hc hb, decodeString.go.eq_1]; simp [scalars]
  | succ f ih =>
    intro i out b us hs hc hf
    by_cases hend : i + 1 ≥ hi
    · have hb : b = [] := by rw [← hs]; exact (slice_nil_iff hhi').mpr (by omega)
      rw [strChars_nil hc hb, decodeString.go.eq_2, ite_eq_left hend]; simp [scalars]
    have hne : b ≠ [] := by
      intro hb; rw [hb] at hs; have := (slice_nil_iff hhi').mp hs; omega
    obtain ⟨t, u, ts, us', rfl, rfl, hct, hcts⟩ := strChars_cons hc hne
    have hrest := slice_append_eq hhi' hs
    simp only [List.length_append] at hf
    cases hct with
    | plain c hsc h20 h22 h5c =>
      rw [scalars_utf16 hsc, encode_cons]
      by_cases h80 : c < 0x80
      · have hu : utf8 c = [c.toUInt8] := by unfold utf8; rw [ite_eq_left h80]
        rw [hu] at hs hrest hf ⊢
        obtain ⟨-, h0, -⟩ := slice_eq_cons hhi' hs
        have hb : (a.get! i).toNat = c := by rw [h0]; simp; omega
        have n0 : (a.get! i == 92) = false := by simp [← UInt8.toNat_inj, hb]; omega
        have n1 : a.get! i < 128 := by simp [UInt8.lt_iff_toNat_lt, hb]; omega
        rw [decodeString.go.eq_2, ite_eq_right hend]
        simp only [byte, n0, n1, Bool.false_eq_true, ↓reduceIte]
        rw [ih (i + 1) _ ts us' (by simpa using hrest) hcts (by simp at hf; omega), bs_push, h0]
        simp
      · have hl : 1 ≤ (utf8 c).length := by rw [utf8_length]; split <;> (try split) <;> (try split) <;> omega
        rw [decode_utf8 hhi hs hsc (by omega), ih _ _ ts us' hrest hcts (by omega), bs_appendSlice,
          slice_prefix hhi' hs]
        simp
    | esc e u hm =>
      simp only [List.cons_append, List.nil_append] at hs
      obtain ⟨-, h0, hs'⟩ := slice_eq_cons hhi' hs
      obtain ⟨-, h1, -⟩ := slice_eq_cons hhi' hs'
      rw [decodeString.go.eq_2, ite_eq_right hend]
      simp only [List.mem_cons, Prod.mk.injEq, List.not_mem_nil, or_false] at hm
      rcases hm with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ |
        ⟨rfl, rfl⟩ <;>
      · simp [byte, h0, h1]
        rw [ih (i + 2) _ ts us' (by simpa using hrest) hcts (by simp at hf; omega), bs_push,
          scalars_cons_of_not_surrogate (by decide)]
        simp [utf8]
    | uesc h1 h2 h3 h4 x1 x2 x3 x4 =>
      generalize hcv : ((Spec.Json.hexVal h1 * 16 + Spec.Json.hexVal h2) * 16 + Spec.Json.hexVal h3) * 16 +
        Spec.Json.hexVal h4 = cv
      have hs6 : slice a i (hi - 1) = 0x5c :: 0x75 :: h1 :: h2 :: h3 :: h4 :: ts := by simpa using hs
      have hs2 : slice a (i + 2) (hi - 1) = h1 :: h2 :: h3 :: h4 :: ts := by
        simpa using slice_append_eq hhi' (t := [0x5c, 0x75]) (by simpa using hs)
      have hx := hex4_slice hhi' hs2 x1 x2 x3 x4
      rw [hcv] at hx
      obtain ⟨-, g0, hs'⟩ := slice_eq_cons hhi' hs6
      obtain ⟨-, g1, -⟩ := slice_eq_cons hhi' hs'
      have hts : slice a (i + 6) (hi - 1) = ts := by simpa using hrest
      have hlen := slice_length a (lo := i) hhi'
      rw [hs6] at hlen; simp at hlen
      simp only [List.length_cons, List.length_nil] at hf
      rw [decodeString.go.eq_2, ite_eq_right hend]
      simp only [byte, g0, g1, hx, beq_self_eq_true, ↓reduceIte, List.cons_append, List.nil_append]
      by_cases hh : 0xd800 ≤ cv ∧ cv < 0xdc00
      · by_cases hts0 : ts = []
        · subst hts0
          rw [strChars_nil hcts rfl]
          simp only [List.length_nil, Nat.zero_add] at hlen
          rw [ite_eq_right (by simp; omega), ite_eq_left (by simp; omega),
            ih (i + 6) _ [] [] hts .nil (by simp), bs_pushUtf8, scalars_cons_high (by omega) (by simp)]
          simp [scalars]
        obtain ⟨t2, u2, ts2, us2, rfl, rfl, hc2, hcts2⟩ := strChars_cons hcts hts0
        cases hc2 with
        | uesc k1 k2 k3 k4 y1 y2 y3 y4 =>
          generalize hd : ((Spec.Json.hexVal k1 * 16 + Spec.Json.hexVal k2) * 16 + Spec.Json.hexVal k3) * 16 +
            Spec.Json.hexVal k4 = d
          have ht6 : slice a (i + 6) (hi - 1) = 0x5c :: 0x75 :: k1 :: k2 :: k3 :: k4 :: ts2 := by simpa using hts
          have ht8 : slice a (i + 8) (hi - 1) = k1 :: k2 :: k3 :: k4 :: ts2 := by
            simpa [Nat.add_assoc] using slice_append_eq hhi' (t := [0x5c, 0x75]) (by simpa using ht6)
          have hy := hex4_slice hhi' ht8 y1 y2 y3 y4
          rw [hd] at hy
          obtain ⟨-, k0, ht'⟩ := slice_eq_cons hhi' ht6
          obtain ⟨-, k1', -⟩ := slice_eq_cons hhi' ht'
          have ht12 : slice a (i + 12) (hi - 1) = ts2 := by
            simpa [Nat.add_assoc] using slice_append_eq hhi' (t := [0x5c, 0x75, k1, k2, k3, k4]) (by simpa using ht6)
          have hlen2 := slice_length a (lo := i + 6) hhi'
          rw [ht6] at hlen2; simp at hlen2
          rw [ite_eq_left (by simp [k0, k1', hh.1, hh.2]; omega)]
          simp only [hy]
          by_cases hdl : 0xdc00 ≤ d ∧ d < 0xe000
          · rw [ite_eq_left (by simp [hdl.1, hdl.2]), ih (i + 12) _ ts2 us2 ht12 hcts2 (by simp at hf; omega),
              bs_pushUtf8]
            simp only [List.singleton_append]
            rw [scalars_pair (by omega) (by omega)]
            simp
          · rw [ite_eq_right (by simp; omega), ih (i + 6) _ _ _ hts (.cons (.uesc k1 k2 k3 k4 y1 y2 y3 y4) hcts2)
              (by simp at hf ⊢; omega), bs_pushUtf8, hd]
            simp only [List.singleton_append]
            rw [scalars_cons_high (u := cv) (us := d :: us2) (by omega) (by simp; omega)]
            simp
        | plain c2 hsc2 h202 h222 h5c2 =>
          have hne6 : (a.get! (i + 6) == 92) = false := by
            obtain ⟨b6, r6, hb6⟩ : ∃ b6 r6, utf8 c2 = b6 :: r6 := by
              cases h : utf8 c2 with
              | nil => exact absurd h (utf8_ne_nil c2)
              | cons x r => exact ⟨x, r, rfl⟩
            have hn := utf8_head_ne hsc2.1 h5c2 b6 (by simp [hb6])
            rw [hb6, List.cons_append] at hts
            obtain ⟨-, k0, -⟩ := slice_eq_cons hhi' hts
            simpa [k0] using hn
          rw [ite_eq_right (by simp [hne6]), ite_eq_left (by simp; omega),
            ih (i + 6) _ _ _ hts (.cons (.plain c2 hsc2 h202 h222 h5c2) hcts2) (by simp at hf ⊢; omega), bs_pushUtf8]
          have hnl := strChar_head_not_low (.plain c2 hsc2 h202 h222 h5c2) (by
            rintro ⟨r, hr⟩; exact utf8_head_ne hsc2.1 h5c2 0x5c (by simp [hr]) rfl)
          rw [scalars_cons_high (u := cv) (us := utf16 c2 ++ us2) (by omega) (fun v hv => hnl v (by
            cases h : utf16 c2 with
            | nil => unfold utf16 at h; split at h <;> simp at h
            | cons x r => rw [h] at hv; simpa using hv))]
          simp
        | esc e2 v2 hm2 =>
          have hne7 : (a.get! (i + 7) == 117) = false := by
            have ht7 : slice a (i + 6) (hi - 1) = 0x5c :: e2 :: ts2 := by simpa using hts
            obtain ⟨-, -, ht'⟩ := slice_eq_cons hhi' ht7
            obtain ⟨-, k1', -⟩ := slice_eq_cons hhi' ht'
            simp only [List.mem_cons, Prod.mk.injEq, List.not_mem_nil, or_false] at hm2
            simp only [k1', beq_eq_false_iff_ne]
            rcases hm2 with ⟨rfl, -⟩ | ⟨rfl, -⟩ | ⟨rfl, -⟩ | ⟨rfl, -⟩ | ⟨rfl, -⟩ | ⟨rfl, -⟩ | ⟨rfl, -⟩ |
              ⟨rfl, -⟩ <;> decide
          rw [ite_eq_right (by simp [hne7]), ite_eq_left (by simp; omega),
            ih (i + 6) _ _ _ hts (.cons (.esc e2 v2 hm2) hcts2) (by simp at hf ⊢; omega), bs_pushUtf8]
          have hnl := strChar_head_not_low (.esc e2 v2 hm2) (by
            rintro ⟨r, hr⟩; simp only [List.cons.injEq] at hr; obtain ⟨-, rfl, -⟩ := hr; simp at hm2)
          simp only [List.singleton_append]
          rw [scalars_cons_high (u := cv) (us := v2 :: us2) (by omega) (fun v hv => hnl v (by simpa using hv))]
          simp
      · rw [ite_eq_right (by simp; omega)]
        by_cases hl : 0xdc00 ≤ cv ∧ cv < 0xe000
        · rw [ite_eq_left (by simp; omega), ih (i + 6) _ ts us' hts hcts (by omega), bs_pushUtf8,
            scalars_cons_low (u := cv) (by omega)]
          simp
        · rw [ite_eq_right (by simp; omega), ih (i + 6) _ ts us' hts hcts (by omega), bs_pushUtf8,
            scalars_cons_of_not_surrogate (u := cv) (by omega)]
          simp

/-- **`decodeString` reads a string as RFC 8259 does**: the bytes of a JSON string become the UTF-8
of its characters, a surrogate pair as one scalar value and a lone surrogate as U+FFFD. -/
theorem decodeString_spec {a : ByteArray} {lo hi : Nat} {us : List Nat}
    (h : Spec.Json.IsString (slice a lo hi) us) (hhi : hi ≤ a.size) :
    bs (Json.decodeString a lo hi) = Spec.Json.encode (Spec.Json.scalars us) := by
  obtain ⟨b, hb, hc⟩ := h
  have hlen := slice_length a (lo := lo) hhi
  rw [hb] at hlen; simp at hlen
  have h1 : slice a (lo + 1) hi = b ++ [0x22] := by
    simpa using slice_append_eq hhi (t := [0x22]) (r := b ++ [0x22]) (by simpa using hb)
  have hs : slice a (lo + 1) (hi - 1) = b := by
    rw [show hi - 1 = lo + 1 + b.length by omega,
      ← slice_take a (lo := lo + 1) (hi := hi) b.length (by omega), h1, List.take_left]
  unfold decodeString
  rw [Nat.min_eq_left hhi, decodeString_go_spec hhi _ (lo + 1) _ b us hs hc (by omega)]
  simp

/-- info: 'Feed.Json.decodeString_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Feed.Json.decodeString_spec

/-! ## Scanning numbers -/

/-- The exponent part of `scanNumber` at `i`: the index after it, which is `i` if there is none. -/
def numExp (a : ByteArray) (hi i : Nat) : Option Nat :=
  if i < hi && (byte a i == 0x65 || byte a i == 0x45) then
    let k := if i + 1 < hi && (byte a (i + 1) == 0x2b || byte a (i + 1) == 0x2d) then i + 2 else i + 1
    if scanDigits a hi k == k then none else some (scanDigits a hi k)
  else some i

/-- The fraction and the exponent of `scanNumber` at `i`. -/
def numFrac (a : ByteArray) (hi i : Nat) : Option Nat :=
  if i < hi && byte a i == 0x2e then
    if scanDigits a hi (i + 1) == i + 1 then none else numExp a hi (scanDigits a hi (i + 1))
  else numExp a hi i

/-- The integer, the fraction and the exponent of `scanNumber` at `i`. -/
def numInt (a : ByteArray) (hi i : Nat) : Option Nat :=
  if byte a i == 0x30 then numFrac a hi (i + 1)
  else if isDigit (byte a i) then numFrac a hi (scanDigits a hi i)
  else none

theorem scanNumber_eq (a : ByteArray) (hi i : Nat) :
    scanNumber a hi i =
      let i := if i < hi && byte a i == 0x2d then i + 1 else i
      if i ≥ hi then none else numInt a hi i := rfl

theorem exp_follow {x r : List UInt8} {ex : Int} (hx : x = [] ∧ ex = 0 ∨ IsExp x ex)
    (hr : ∀ b ∈ r.head?, ¬ IsDigit b ∧ b ≠ 0x2e ∧ b ≠ 0x65 ∧ b ≠ 0x45) :
    ∀ b ∈ (x ++ r).head?, ¬ IsDigit b ∧ b ≠ 0x2e := by
  rcases hx with ⟨rfl, -⟩ | ⟨c, s, ds, rfl, hc, -, -⟩
  · intro b hb; exact ⟨(hr b hb).1, (hr b hb).2.1⟩
  · intro b hb
    simp only [List.cons_append, List.head?_cons, Option.mem_def, Option.some.injEq] at hb
    subst hb
    unfold IsDigit
    rcases hc with rfl | rfl <;> decide

theorem frac_follow {f x r fd : List UInt8} {ex : Int} (hf : f = [] ∧ fd = [] ∨ IsFrac f fd)
    (hx : x = [] ∧ ex = 0 ∨ IsExp x ex) (hr : ∀ b ∈ r.head?, ¬ IsDigit b ∧ b ≠ 0x2e ∧ b ≠ 0x65 ∧ b ≠ 0x45) :
    ∀ b ∈ (f ++ x ++ r).head?, ¬ IsDigit b := by
  rcases hf with ⟨rfl, -⟩ | ⟨rfl, -⟩
  · intro b hb; exact (exp_follow hx hr b (by simpa using hb)).1
  · intro b hb
    simp only [List.cons_append, List.head?_cons, Option.mem_def, Option.some.injEq] at hb
    subst hb; unfold IsDigit; decide

theorem numExp_complete {a : ByteArray} {hi i : Nat} {x r : List UInt8} {ex : Int} (hhi : hi ≤ a.size)
    (h : slice a i hi = x ++ r) (hx : x = [] ∧ ex = 0 ∨ IsExp x ex)
    (hr : ∀ b ∈ r.head?, ¬ IsDigit b ∧ b ≠ 0x65 ∧ b ≠ 0x45) : numExp a hi i = some (i + x.length) := by
  unfold numExp
  rcases hx with ⟨rfl, -⟩ | ⟨c, s, ds, rfl, hc, ⟨hne, hds⟩, hs⟩
  · rw [ite_eq_right]
    · simp
    · simp only [List.nil_append] at h
      cases r with
      | nil =>
        have := (slice_nil_iff hhi).mp h
        simp only [Bool.and_eq_true, decide_eq_true_eq, not_and]; intro; omega
      | cons b r =>
        obtain ⟨-, h0, -⟩ := slice_eq_cons hhi h
        obtain ⟨-, h65, h45⟩ := hr b rfl
        simp [byte, h0, h65, h45]
  · simp only [List.cons_append, List.append_assoc] at h
    obtain ⟨hi0, h0, h'⟩ := slice_eq_cons hhi h
    have hc' : (byte a i == 0x65 || byte a i == 0x45) = true := by
      rcases hc with rfl | rfl <;> simp [byte, h0]
    rw [ite_eq_left (by simp [hi0, hc'])]
    -- the sign
    have hk : (if i + 1 < hi && (byte a (i + 1) == 0x2b || byte a (i + 1) == 0x2d) then i + 2 else i + 1) =
        i + 1 + s.length := by
      rcases hs with ⟨rfl, -⟩ | ⟨rfl, -⟩ | ⟨rfl, -⟩
      · obtain ⟨d, ds, rfl⟩ := List.exists_cons_of_ne_nil hne
        obtain ⟨-, h1, -⟩ := slice_eq_cons hhi h'
        have hd := hds d (by simp)
        unfold IsDigit at hd
        rw [ite_eq_right]; · simp
        simp only [byte, h1, Bool.and_eq_true, decide_eq_true_eq, Bool.or_eq_true, beq_iff_eq, not_and]
        intro _; rw [← UInt8.toNat_inj, ← UInt8.toNat_inj]
        simp [UInt8.le_iff_toNat_le] at hd; simp; omega
      · obtain ⟨hi1, h1, -⟩ := slice_eq_cons hhi h'
        rw [ite_eq_left (by simp [byte, h1, hi1])]; simp
      · obtain ⟨hi1, h1, -⟩ := slice_eq_cons hhi h'
        rw [ite_eq_left (by simp [byte, h1, hi1])]; simp
    simp only [hk]
    have hrest := slice_append_eq hhi h'
    rw [scanDigits_eq hhi hrest hds (fun b hb => (hr b hb).1)]
    have hl := List.length_pos_iff.mpr hne
    rw [ite_eq_right (by simp; omega)]
    simp; omega

theorem numExp_sound {a : ByteArray} {hi i j : Nat} (hhi : hi ≤ a.size) (hi' : i ≤ hi)
    (h : numExp a hi i = some j) : i ≤ j ∧ j ≤ hi ∧ ∃ ex, (slice a i j = [] ∧ ex = 0 ∨ IsExp (slice a i j) ex) := by
  unfold numExp at h
  split at h
  · rename_i hc
    simp only [Bool.and_eq_true, decide_eq_true_eq, Bool.or_eq_true, beq_iff_eq, byte] at hc
    obtain ⟨hi0, hc⟩ := hc
    generalize hk : (if (i + 1 < hi && (byte a (i + 1) == 0x2b || byte a (i + 1) == 0x2d)) = true then i + 2
      else i + 1) = k at h
    by_cases hd : scanDigits a hi k = k
    · simp [hd] at h
    rw [ite_eq_right (by simpa using hd)] at h
    cases h
    obtain ⟨ds, r, hsl, hds, -, hsc⟩ := scanDigits_spec a hhi k
    have hne : ds ≠ [] := by intro h; subst h; simp at hsc; exact hd hsc
    have hk0 : k < hi := by
      have h1 := slice_length a (lo := k) hhi
      rw [hsl] at h1; have h2 := List.length_pos_iff.mpr hne; simp at h1; omega
    have hpre := slice_prefix hhi hsl
    rw [← hsc] at hpre
    have hik : i + 1 ≤ k := by split at hk <;> omega
    have hj := slice_split a (lo := i) (m := k) (hi := scanDigits a hi k) (by omega) (by omega)
    rw [hpre] at hj
    refine ⟨by omega, ?_, ?_⟩
    · have h1 := slice_length a (lo := k) hhi; rw [hsl] at h1; simp at h1; omega
    split at hk
    · rename_i hs
      simp only [Bool.and_eq_true, decide_eq_true_eq, Bool.or_eq_true, beq_iff_eq, byte] at hs
      subst hk
      have h2 : slice a i (i + 2) = [a.get! i, a.get! (i + 1)] := by
        rw [slice_cons a (by omega) (by omega), slice_one a (by omega)]
      rw [h2] at hj
      rcases hs.2 with hp | hp
      · exact ⟨decVal ds, Or.inr ⟨a.get! i, [a.get! (i + 1)], ds, by simpa using hj, hc, ⟨hne, hds⟩,
          Or.inr (Or.inl ⟨by rw [hp], rfl⟩)⟩⟩
      · exact ⟨-(decVal ds : Int), Or.inr ⟨a.get! i, [a.get! (i + 1)], ds, by simpa using hj, hc, ⟨hne, hds⟩,
          Or.inr (Or.inr ⟨by rw [hp], rfl⟩)⟩⟩
    · subst hk
      rw [slice_one a (by omega)] at hj
      exact ⟨decVal ds, Or.inr ⟨a.get! i, [], ds, by simpa using hj, hc, ⟨hne, hds⟩, Or.inl ⟨rfl, rfl⟩⟩⟩
  · simp only [Option.some.injEq] at h
    subst h
    exact ⟨Nat.le_refl _, hi', 0, Or.inl ⟨slice_empty a _, rfl⟩⟩

theorem numFrac_complete {a : ByteArray} {hi i : Nat} {f x r fd : List UInt8} {ex : Int} (hhi : hi ≤ a.size)
    (h : slice a i hi = f ++ x ++ r) (hf : f = [] ∧ fd = [] ∨ IsFrac f fd) (hx : x = [] ∧ ex = 0 ∨ IsExp x ex)
    (hr : ∀ b ∈ r.head?, ¬ IsDigit b ∧ b ≠ 0x2e ∧ b ≠ 0x65 ∧ b ≠ 0x45) :
    numFrac a hi i = some (i + f.length + x.length) := by
  have hxr := exp_follow hx hr
  unfold numFrac
  rcases hf with ⟨rfl, -⟩ | ⟨rfl, hne, hds⟩
  · simp only [List.nil_append] at h
    rw [ite_eq_right, numExp_complete hhi h hx (fun b hb => ⟨(hr b hb).1, (hr b hb).2.2⟩)]
    · simp
    · cases hxr' : x ++ r with
      | nil =>
        rw [hxr'] at h
        have := (slice_nil_iff hhi).mp h
        simp only [Bool.and_eq_true, decide_eq_true_eq, not_and]; intro; omega
      | cons b l =>
        rw [hxr'] at h hxr
        obtain ⟨-, h0, -⟩ := slice_eq_cons hhi h
        have := (hxr b rfl).2
        simp [byte, h0, this]
  · simp only [List.cons_append, List.append_assoc] at h
    obtain ⟨hi0, h0, h'⟩ := slice_eq_cons hhi h
    rw [ite_eq_left (by simp [byte, h0, hi0])]
    rw [scanDigits_eq hhi h' hds (fun b hb => (hxr b hb).1)]
    have hl := List.length_pos_iff.mpr hne
    rw [ite_eq_right (by simp; omega)]
    have hrest := slice_append_eq hhi h'
    rw [numExp_complete hhi hrest hx (fun b hb => ⟨(hr b hb).1, (hr b hb).2.2⟩)]
    simp; omega

theorem numFrac_sound {a : ByteArray} {hi i j : Nat} (hhi : hi ≤ a.size) (hi' : i ≤ hi)
    (h : numFrac a hi i = some j) :
    ∃ k, i ≤ k ∧ k ≤ j ∧ j ≤ hi ∧ (∃ fd, slice a i k = [] ∧ fd = [] ∨ IsFrac (slice a i k) fd) ∧
      ∃ ex, (slice a k j = [] ∧ ex = 0 ∨ IsExp (slice a k j) ex) := by
  unfold numFrac at h
  split at h
  · rename_i hc
    simp only [Bool.and_eq_true, decide_eq_true_eq, beq_iff_eq, byte] at hc
    by_cases hd : scanDigits a hi (i + 1) = i + 1
    · simp [hd] at h
    rw [ite_eq_right (by simpa using hd)] at h
    obtain ⟨ds, r, hsl, hds, -, hsc⟩ := scanDigits_spec a hhi (i + 1)
    have hne : ds ≠ [] := by intro h; subst h; simp at hsc; exact hd hsc
    have hl := List.length_pos_iff.mpr hne
    have hlen := slice_length a (lo := i + 1) hhi
    rw [hsl] at hlen; simp at hlen
    obtain ⟨hkj, hj, hx⟩ := numExp_sound hhi (by omega) h
    refine ⟨scanDigits a hi (i + 1), by omega, hkj, hj, ⟨ds, Or.inr ⟨?_, hne, hds⟩⟩, hx⟩
    rw [slice_cons a (by omega) (by omega), hsc, ← hc.2]
    congr 1
    exact slice_prefix hhi hsl
  · obtain ⟨hk, hkj, hx⟩ := numExp_sound hhi hi' h
    exact ⟨i, Nat.le_refl _, hk, hkj, ⟨[], Or.inl ⟨slice_empty a _, rfl⟩⟩, hx⟩

theorem isInt_cons {n : List UInt8} (hn : IsInt n) : ∃ d ds, n = d :: ds ∧ IsDigit d ∧ ∀ x ∈ ds, IsDigit x := by
  rcases hn with rfl | ⟨d, ds, rfl, h1, h2, hds⟩
  · exact ⟨0x30, [], rfl, by unfold IsDigit; decide, by simp⟩
  · exact ⟨d, ds, rfl, ⟨Nat.le_trans (by decide) h1, h2⟩, hds⟩

theorem numInt_complete {a : ByteArray} {hi i : Nat} {n f x r fd : List UInt8} {ex : Int} (hhi : hi ≤ a.size)
    (h : slice a i hi = n ++ f ++ x ++ r) (hn : IsInt n) (hf : f = [] ∧ fd = [] ∨ IsFrac f fd)
    (hx : x = [] ∧ ex = 0 ∨ IsExp x ex) (hr : ∀ b ∈ r.head?, ¬ IsDigit b ∧ b ≠ 0x2e ∧ b ≠ 0x65 ∧ b ≠ 0x45) :
    numInt a hi i = some (i + n.length + f.length + x.length) := by
  unfold numInt
  rcases hn with rfl | ⟨d, ds, rfl, h1, h2, hds⟩
  · simp only [List.cons_append, List.nil_append, List.append_assoc] at h
    obtain ⟨hi0, h0, h'⟩ := slice_eq_cons hhi h
    rw [ite_eq_left (by simp [byte, h0]), numFrac_complete hhi (by simpa using h') hf hx hr]
    simp
  · simp only [List.cons_append, List.append_assoc] at h
    obtain ⟨hi0, h0, -⟩ := slice_eq_cons hhi h
    have hd : IsDigit d := ⟨Nat.le_trans (by decide) h1, h2⟩
    have hne0 : (byte a i == 0x30) = false := by
      simp only [byte, h0, beq_eq_false_iff_ne, ne_eq]
      intro he; subst he; exact absurd h1 (by decide)
    rw [ite_eq_right (by simp [hne0]), ite_eq_left (by simpa [byte, h0] using (isDigit_iff d).mpr hd)]
    have hall : ∀ y ∈ d :: ds, IsDigit y := by
      intro y hy; rcases List.mem_cons.mp hy with rfl | hy; exact hd; exact hds y hy
    have hs : slice a i hi = (d :: ds) ++ (f ++ x ++ r) := by rw [h]; simp
    rw [scanDigits_eq hhi hs hall (frac_follow hf hx hr)]
    rw [numFrac_complete hhi (by simpa using slice_append_eq hhi hs) hf hx hr]

theorem numInt_sound {a : ByteArray} {hi i j : Nat} (hhi : hi ≤ a.size) (hi' : i < hi)
    (h : numInt a hi i = some j) :
    ∃ k l, i < k ∧ k ≤ l ∧ l ≤ j ∧ j ≤ hi ∧ IsInt (slice a i k) ∧
      (∃ fd, slice a k l = [] ∧ fd = [] ∨ IsFrac (slice a k l) fd) ∧
      ∃ ex, (slice a l j = [] ∧ ex = 0 ∨ IsExp (slice a l j) ex) := by
  unfold numInt at h
  split at h
  · rename_i h0
    simp only [byte, beq_iff_eq] at h0
    obtain ⟨l, hkl, hlj, hj, hf, hx⟩ := numFrac_sound hhi (by omega) h
    refine ⟨i + 1, l, by omega, hkl, hlj, hj, Or.inl ?_, hf, hx⟩
    rw [slice_one a (by omega), h0]
  split at h
  · rename_i h0 hd
    simp only [byte, beq_iff_eq] at h0 hd
    rw [isDigit_iff] at hd
    obtain ⟨ds, r, hsl, hds, hrd, hsc⟩ := scanDigits_spec a hhi i
    obtain ⟨d, ds', rfl⟩ : ∃ d ds', ds = d :: ds' := by
      cases ds with
      | cons d ds' => exact ⟨d, ds', rfl⟩
      | nil =>
        simp only [List.nil_append] at hsl
        rw [slice_cons a hi' hhi] at hsl
        exact absurd hd (hrd _ (by rw [← hsl]; rfl))
    obtain ⟨-, hd0, -⟩ := slice_eq_cons hhi (by simpa using hsl)
    have hlen := slice_length a (lo := i) hhi
    rw [hsl] at hlen; simp at hlen
    simp only [List.length_cons] at hsc
    obtain ⟨l, hkl, hlj, hj, hf, hx⟩ := numFrac_sound hhi (by omega) h
    refine ⟨scanDigits a hi i, l, by omega, hkl, hlj, hj, Or.inr ⟨d, ds', ?_, ?_, ?_, ?_⟩, hf, hx⟩
    · rw [hsc]; exact slice_prefix hhi hsl
    · rw [← hd0] at hds ⊢
      have := hds (a.get! i) (by simp)
      unfold IsDigit at this
      have h30 : (a.get! i).toNat ≠ 0x30 := fun he => h0 (UInt8.toNat_inj.mp (by simpa using he))
      simp only [UInt8.le_iff_toNat_le, UInt8.reduceToNat] at this ⊢
      simp at h30; omega
    · exact (hds d (by simp)).2
    · exact fun x hx => hds x (by simp [hx])
  · cases h

/-- **`scanNumber` accepts only numbers**: the bytes from `i` to the index it gives are a JSON
number. -/
theorem scanNumber_sound {a : ByteArray} {hi i j : Nat} (hhi : hi ≤ a.size) (h : scanNumber a hi i = some j) :
    i < j ∧ j ≤ hi ∧ ∃ neg m e, IsNumber (slice a i j) neg m e := by
  rw [scanNumber_eq] at h
  simp only at h
  generalize hi1 : (if (i < hi && byte a i == 0x2d) = true then i + 1 else i) = i1 at h
  split at h
  · cases h
  rename_i hlt
  obtain ⟨k, l, hik, hkl, hlj, hj, hn, ⟨fd, hf⟩, ⟨ex, hx⟩⟩ := numInt_sound hhi (by omega) h
  have hs : ∃ s neg, slice a i i1 = s ∧ (s = [] ∧ neg = false ∨ s = [0x2d] ∧ neg = true) ∧ i ≤ i1 := by
    split at hi1
    · rename_i hc
      simp only [Bool.and_eq_true, decide_eq_true_eq, beq_iff_eq, byte] at hc
      subst hi1
      exact ⟨[0x2d], true, by rw [slice_one a (by omega), hc.2], Or.inr ⟨rfl, rfl⟩, by omega⟩
    · subst hi1
      exact ⟨[], false, slice_empty a i, Or.inl ⟨rfl, rfl⟩, Nat.le_refl _⟩
  obtain ⟨s, neg, hs, hsn, hii⟩ := hs
  refine ⟨by omega, hj, neg, decVal (slice a i1 k ++ fd), ex - fd.length, s, slice a i1 k, slice a k l,
    slice a l j, fd, ex, ?_, hsn, hn, hf, hx, rfl, rfl⟩
  rw [slice_split a hii (by omega : i1 ≤ j), slice_split a (Nat.le_of_lt hik) (by omega : k ≤ j),
    slice_split a hkl hlj, hs]
  simp only [List.append_assoc]

/-- info: 'Feed.Json.scanNumber_sound' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Feed.Json.scanNumber_sound

/-- **`scanNumber` finds every number**: at a JSON number followed by a byte that cannot continue
one (or by nothing), it gives the index just after the number. -/
theorem scanNumber_complete {a : ByteArray} {hi i : Nat} {t r : List UInt8} {neg : Bool} {m : Nat} {e : Int}
    (hhi : hi ≤ a.size) (h : slice a i hi = t ++ r) (ht : IsNumber t neg m e)
    (hr : ∀ b ∈ r.head?, ¬ IsDigit b ∧ b ≠ 0x2e ∧ b ≠ 0x65 ∧ b ≠ 0x45) : scanNumber a hi i = some (i + t.length) := by
  obtain ⟨s, n, f, x, fd, ex, rfl, hs, hn, hf, hx, -, -⟩ := ht
  obtain ⟨d, ds, hnd, hd, -⟩ := isInt_cons hn
  rw [scanNumber_eq]
  simp only
  rcases hs with ⟨rfl, -⟩ | ⟨rfl, -⟩
  · simp only [List.nil_append] at h
    have h' : slice a i hi = d :: (ds ++ f ++ x ++ r) := by rw [h, hnd]; simp
    obtain ⟨hi0, h0, -⟩ := slice_eq_cons hhi h'
    have hd' : (byte a i == 0x2d) = false := by
      simp only [byte, h0, beq_eq_false_iff_ne, ne_eq]
      intro he; subst he; unfold IsDigit at hd; exact absurd hd (by decide)
    have hs1 : (if (i < hi && byte a i == 0x2d) = true then i + 1 else i) = i := by simp [hd']
    rw [hs1, ite_eq_right (by omega), numInt_complete hhi (by simpa using h) hn hf hx hr]
    simp; omega
  · simp only [List.cons_append, List.nil_append, List.append_assoc] at h
    obtain ⟨hi0, h0, h'⟩ := slice_eq_cons hhi h
    have hlen := slice_length a (lo := i + 1) hhi
    rw [h', hnd] at hlen; simp at hlen
    have hs1 : (if (i < hi && byte a i == 0x2d) = true then i + 1 else i) = i + 1 := by simp [byte, h0, hi0]
    rw [hs1, ite_eq_right (by omega), numInt_complete hhi (by simpa using h') hn hf hx hr]
    simp; omega

/-- info: 'Feed.Json.scanNumber_complete' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Feed.Json.scanNumber_complete

/-! ## A number's value -/

theorem digits_takeWhile {ds r : List UInt8} (hd : ∀ d ∈ ds, IsDigit d) (hr : ∀ b ∈ r.head?, ¬ IsDigit b) :
    (ds ++ r).takeWhile isDigit = ds :=
  takeWhile_run (fun b hb => (isDigit_iff b).mpr (hd b hb))
    (fun b hb => by rw [← Bool.not_eq_true, isDigit_iff]; exact hr b hb)

theorem isInt_digits {i : List UInt8} (h : IsInt i) : ∀ d ∈ i, IsDigit d := by
  obtain ⟨d, ds, rfl, hd, hds⟩ := isInt_cons h
  intro y hy; rcases List.mem_cons.mp hy with rfl | hy; exact hd; exact hds y hy

theorem not_digit_2d : ¬ IsDigit 0x2d := by unfold IsDigit; decide

/-- **A number has one reading**: its text determines its sign, digits and exponent. -/
theorem _root_.Feed.Spec.Json.IsNumber.unique {t : List UInt8} {neg neg' : Bool} {m m' : Nat} {e e' : Int}
    (h : IsNumber t neg m e) (h' : IsNumber t neg' m' e') : neg = neg' ∧ m = m' ∧ e = e' := by
  obtain ⟨s, i, f, x, fd, ex, rfl, hs, hi, hf, hx, rfl, rfl⟩ := h
  obtain ⟨s', i', f', x', fd', ex', ht, hs', hi', hf', hx', rfl, rfl⟩ := h'
  obtain ⟨d, ds, rfl, hd, -⟩ := isInt_cons hi
  obtain ⟨d', ds', rfl, hd', -⟩ := isInt_cons hi'
  -- the sign
  have hsn : s = s' ∧ neg = neg' := by
    rcases hs with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ <;> rcases hs' with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩
    · exact ⟨rfl, rfl⟩
    · simp only [List.nil_append, List.cons_append, List.cons.injEq] at ht
      exact absurd (ht.1 ▸ hd) not_digit_2d
    · simp only [List.nil_append, List.cons_append, List.cons.injEq] at ht
      exact absurd (ht.1 ▸ hd') not_digit_2d
    · exact ⟨rfl, rfl⟩
  obtain ⟨rfl, rfl⟩ := hsn
  simp only [List.append_assoc, List.append_cancel_left_eq] at ht
  -- the integer part: the digits up to the first byte that is not one
  have hfx := frac_follow hf hx (r := []) (by simp)
  have hfx' := frac_follow hf' hx' (r := []) (by simp)
  simp only [List.append_nil] at hfx hfx'
  have hii : d :: ds = d' :: ds' := by
    have e1 := digits_takeWhile (isInt_digits hi) hfx
    have e2 := digits_takeWhile (isInt_digits hi') hfx'
    rw [← List.append_assoc, ← List.append_assoc] at ht
    rw [← e1, ← e2, ← List.append_assoc, ← List.append_assoc, ht]
  rw [hii] at ht
  simp only [List.append_cancel_left_eq] at ht
  rw [hii]
  -- the fraction
  have hxf := exp_follow hx (r := []) (by simp)
  have hxf' := exp_follow hx' (r := []) (by simp)
  simp only [List.append_nil] at hxf hxf'
  have hff : f = f' ∧ fd = fd' := by
    rcases hf with ⟨rfl, rfl⟩ | ⟨rfl, hne, hds⟩ <;> rcases hf' with ⟨rfl, rfl⟩ | ⟨rfl, hne', hds'⟩
    · exact ⟨rfl, rfl⟩
    · simp only [List.nil_append] at ht
      exact absurd (hxf 0x2e (by rw [ht]; simp)).2 (by simp)
    · simp only [List.nil_append] at ht
      exact absurd (hxf' 0x2e (by rw [← ht]; simp)).2 (by simp)
    · simp only [List.cons_append, List.cons.injEq, true_and] at ht
      have e1 := digits_takeWhile hds (fun b hb => (hxf b hb).1)
      have e2 := digits_takeWhile hds' (fun b hb => (hxf' b hb).1)
      have : fd = fd' := by rw [← e1, ← e2, ht]
      exact ⟨by rw [this], this⟩
  obtain ⟨rfl, rfl⟩ := hff
  simp only [List.append_cancel_left_eq] at ht
  subst ht
  -- the exponent
  refine ⟨rfl, rfl, ?_⟩
  congr 1
  rcases hx with ⟨rfl, rfl⟩ | ⟨c, sg, es, rfl, hc, ⟨hne, hes⟩, hsg⟩ <;>
    rcases hx' with ⟨hx0, rfl⟩ | ⟨c', sg', es', hx0, hc', ⟨hne', hes'⟩, hsg'⟩
  · rfl
  · simp at hx0
  · simp at hx0
  · simp only [List.cons_append, List.cons.injEq] at hx0
    obtain ⟨rfl, hx0⟩ := hx0
    obtain ⟨e0, es0, rfl⟩ := List.exists_cons_of_ne_nil hne
    obtain ⟨e0', es0', rfl⟩ := List.exists_cons_of_ne_nil hne'
    have he0 := hes e0 (by simp)
    have he0' := hes' e0' (by simp)
    rcases hsg with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ <;>
      rcases hsg' with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ <;>
      simp only [List.nil_append, List.cons_append, List.cons.injEq] at hx0 <;>
      (try obtain ⟨rfl, rfl⟩ := hx0) <;> (try rfl) <;> (unfold IsDigit at he0 he0'; simp_all)

/-- info: 'Feed.Spec.Json.IsNumber.unique' depends on axioms: [propext, Quot.sound] -/
#guard_msgs in #print axioms Feed.Spec.Json.IsNumber.unique

/-- A number starts with `-` or a digit. -/
theorem _root_.Feed.Spec.Json.IsNumber.head {t : List UInt8} {neg : Bool} {m : Nat} {e : Int}
    (h : IsNumber t neg m e) : ∃ b r, t = b :: r ∧ (b = 0x2d ∨ IsDigit b) := by
  obtain ⟨s, i, f, x, fd, ex, rfl, hs, hi, -, -, -, -⟩ := h
  obtain ⟨d, ds, rfl, hd, -⟩ := isInt_cons hi
  rcases hs with ⟨rfl, -⟩ | ⟨rfl, -⟩
  · exact ⟨d, ds ++ f ++ x, by simp, Or.inr hd⟩
  · exact ⟨0x2d, d :: ds ++ f ++ x, by simp, Or.inl rfl⟩

/-- A number's bytes are ASCII. -/
theorem _root_.Feed.Spec.Json.IsNumber.ascii {t : List UInt8} {neg : Bool} {m : Nat} {e : Int}
    (h : IsNumber t neg m e) : ∀ b ∈ t, b < 0x80 := by
  have hd : ∀ b, IsDigit b → b < 0x80 := by
    intro b hb; unfold IsDigit at hb
    simp only [UInt8.le_iff_toNat_le, UInt8.lt_iff_toNat_lt, UInt8.reduceToNat] at hb ⊢; omega
  obtain ⟨s, i, f, x, fd, ex, rfl, hs, hi, hf, hx, -, -⟩ := h
  intro b hb
  simp only [List.mem_append] at hb
  rcases hb with ((hb | hb) | hb) | hb
  · rcases hs with ⟨rfl, -⟩ | ⟨rfl, -⟩ <;> simp at hb; subst hb; decide
  · exact hd b (isInt_digits hi b hb)
  · rcases hf with ⟨rfl, -⟩ | ⟨rfl, -, hds⟩
    · simp at hb
    · rcases List.mem_cons.mp hb with rfl | hb; decide; exact hd b (hds b hb)
  · rcases hx with ⟨rfl, -⟩ | ⟨c, sg, ds, rfl, hc, ⟨-, hds⟩, hsg⟩
    · simp at hb
    · simp only [List.cons_append, List.mem_cons, List.mem_append] at hb
      rcases hb with rfl | hb | hb
      · rcases hc with rfl | rfl <;> decide
      · rcases hsg with ⟨rfl, -⟩ | ⟨rfl, -⟩ | ⟨rfl, -⟩ <;> simp at hb <;> subst hb <;> decide
      · exact hd b (hds b hb)

/-- What `numGt` compares once it has a number's digits `m` and exponent `e`. -/
def numCmp (m : Nat) (e : Int) (n : Nat) : Bool :=
  if m == 0 then false
  else if e ≥ 0 then
    if e.toNat > numDigits n then true else mulPow10 m e.toNat > n
  else
    let d := (-e).toNat
    if d > numDigits m then n == 0 else m > mulPow10 n d

theorem mulPow10_eq (m k : Nat) : mulPow10 m k = m * 10 ^ k := by
  induction k generalizing m with
  | zero => simp [mulPow10]
  | succ k ih => rw [mulPow10, ih, Nat.pow_succ, Nat.mul_assoc, Nat.mul_comm 10]

theorem lt_pow_numDigits (n : Nat) : n < 10 ^ numDigits n :=
  (Nat.length_repr_le_iff (n := n) Nat.length_repr_pos).mp (Nat.le_refl _)

theorem numCmp_spec (m : Nat) (e : Int) (n : Nat) :
    numCmp m e n = true ↔ if 0 ≤ e then n < m * 10 ^ e.toNat else n * 10 ^ (-e).toNat < m := by
  unfold numCmp
  by_cases hm : m = 0
  · subst hm; simp
  rw [ite_eq_right (by simpa using hm)]
  by_cases he : 0 ≤ e
  · rw [ite_eq_left he, ite_eq_left he]
    by_cases hd : e.toNat > numDigits n
    · rw [ite_eq_left hd]
      have h1 := lt_pow_numDigits n
      have h2 : 10 ^ numDigits n ≤ 10 ^ e.toNat := Nat.pow_le_pow_right (by decide) (by omega)
      have h3 : 10 ^ e.toNat ≤ m * 10 ^ e.toNat := Nat.le_mul_of_pos_left _ (by omega)
      simp; omega
    · rw [ite_eq_right hd, mulPow10_eq]; simp
  · rw [ite_eq_right he, ite_eq_right he]
    simp only
    by_cases hd : (-e).toNat > numDigits m
    · rw [ite_eq_left hd]
      have h1 := lt_pow_numDigits m
      have h2 : 10 ^ numDigits m ≤ 10 ^ (-e).toNat := Nat.pow_le_pow_right (by decide) (by omega)
      simp only [beq_iff_eq]
      constructor
      · rintro rfl; simp; omega
      · intro h
        by_cases hn : n = 0
        · exact hn
        · have : 10 ^ (-e).toNat ≤ n * 10 ^ (-e).toNat := Nat.le_mul_of_pos_left _ (by omega)
          omega
    · rw [ite_eq_right hd, mulPow10_eq]; simp

theorem foldl_dec (l : List UInt8) (acc : Nat) :
    l.foldl (fun acc d => acc * 10 + (d.toNat - 0x30)) acc = acc * 10 ^ l.length + decVal l := by
  induction l generalizing acc with
  | nil => simp [decVal]
  | cons d l ih =>
    simp only [List.foldl_cons, decVal] at ih ⊢
    rw [ih, ih (0 * 10 + _), List.length_cons, Nat.pow_succ, Nat.add_mul, Nat.zero_mul, Nat.zero_add,
      Nat.mul_assoc, Nat.mul_comm 10, Nat.add_assoc]

theorem decVal_append (l₁ l₂ : List UInt8) : decVal (l₁ ++ l₂) = decVal l₁ * 10 ^ l₂.length + decVal l₂ := by
  unfold decVal; rw [List.foldl_append, foldl_dec]; rfl

theorem numGt_go_eq (a : ByteArray) {hi : Nat} (hhi : hi ≤ a.size) :
    ∀ f i acc, i + f ≤ hi → (∀ d ∈ slice a i (i + f), IsDigit d) →
      numGt.go a i f acc = (slice a i (i + f)).foldl (fun acc d => acc * 10 + (d.toNat - 0x30)) acc := by
  intro f
  induction f with
  | zero => intro i acc _ _; simp [numGt.go, slice_empty]
  | succ f ih =>
    intro i acc hf hd
    have hs := slice_cons a (i := i) (hi := i + (f + 1)) (by omega) (by omega)
    rw [hs] at hd ⊢
    have h0 := hd (a.get! i) (by simp)
    unfold IsDigit at h0
    rw [numGt.go, List.foldl_cons, show i + (f + 1) = i + 1 + f by omega, ih (i + 1) _ (by omega)
      (fun d h => hd d (by rw [show i + (f + 1) = i + 1 + f by omega]; simp [h])), byte,
      UInt8.toNat_sub_of_le _ _ h0.1]
    rfl

theorem digitsVal_eq {a : ByteArray} {lo hi : Nat} {ds r : List UInt8} (hhi : hi ≤ a.size)
    (h : slice a lo hi = ds ++ r) (hd : ∀ d ∈ ds, IsDigit d) : numGt.digitsVal a lo (lo + ds.length) = decVal ds := by
  by_cases hds : ds = []
  · subst hds; simp [numGt.digitsVal, numGt.go, decVal]
  have hp := slice_prefix hhi h
  have hlen := slice_length a (lo := lo) hhi
  rw [h] at hlen; simp at hlen
  have hl := List.length_pos_iff.mpr hds
  unfold numGt.digitsVal
  rw [show lo + ds.length - lo = ds.length by omega, numGt_go_eq a hhi _ _ _ (by omega) (by rw [hp]; exact hd), hp]
  rfl

/-- `numGt` with its comparison as `numCmp` (definitionally). -/
theorem numGt_eq (a : ByteArray) (lo hi n : Nat) :
    numGt a lo hi n =
      if lo < hi && byte a lo == 0x2d then false
      else
        let ie := scanDigits a hi lo
        let (fracVal, fracLen, j) :=
          if ie < hi && byte a ie == 0x2e then
            let fe := scanDigits a hi (ie + 1)
            (numGt.digitsVal a (ie + 1) fe, fe - (ie + 1), fe)
          else (0, 0, ie)
        let (expNeg, expVal) :=
          if j < hi && (byte a j == 0x65 || byte a j == 0x45) then
            let neg := j + 1 < hi && byte a (j + 1) == 0x2d
            let k := if j + 1 < hi && (byte a (j + 1) == 0x2b || byte a (j + 1) == 0x2d) then j + 2 else j + 1
            (neg, numGt.digitsVal a k (scanDigits a hi k))
          else (false, 0)
        numCmp (mulPow10 (numGt.digitsVal a lo ie) fracLen + fracVal)
          ((if expNeg then -(expVal : Int) else expVal) - fracLen) n := rfl

/-- The sign and value `numGt` reads from a number's exponent part `x` at `j`. -/
theorem numExp_parts {a : ByteArray} {hi j : Nat} {x : List UInt8} {ex : Int} (hhi : hi ≤ a.size)
    (h : slice a j hi = x) (hx : x = [] ∧ ex = 0 ∨ IsExp x ex) :
    ∃ b v, (if j < hi && (byte a j == 0x65 || byte a j == 0x45) then
        let neg := j + 1 < hi && byte a (j + 1) == 0x2d
        let k := if j + 1 < hi && (byte a (j + 1) == 0x2b || byte a (j + 1) == 0x2d) then j + 2 else j + 1
        (neg, numGt.digitsVal a k (scanDigits a hi k))
      else (false, 0)) = (b, v) ∧ (if b then -(v : Int) else v) = ex := by
  rcases hx with ⟨rfl, rfl⟩ | ⟨c, sg, ds, rfl, hc, ⟨hne, hds⟩, hsg⟩
  · have := (slice_nil_iff hhi).mp h
    refine ⟨false, 0, ?_, rfl⟩
    rw [ite_eq_right (by simp; omega)]
  · simp only [List.cons_append] at h
    obtain ⟨hj, h0, h'⟩ := slice_eq_cons hhi h
    have hc' : (byte a j == 0x65 || byte a j == 0x45) = true := by
      rcases hc with rfl | rfl <;> simp [byte, h0]
    rw [ite_eq_left (by simp [hj, hc'])]
    obtain ⟨d0, ds0, rfl⟩ := List.exists_cons_of_ne_nil hne
    have hd0 := hds d0 (by simp)
    rcases hsg with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩
    · simp only [List.nil_append] at h'
      obtain ⟨hj1, h1, -⟩ := slice_eq_cons hhi h'
      have n2d : d0 ≠ 0x2d := fun h => not_digit_2d (h ▸ hd0)
      have n2b : d0 ≠ 0x2b := fun h => by unfold IsDigit at hd0; rw [h] at hd0; exact absurd hd0 (by decide)
      have hsd := scanDigits_eq hhi (r := []) (by simpa using h') hds (by simp)
      have hdv := digitsVal_eq hhi (r := []) (by simpa using h') hds
      refine ⟨false, decVal (d0 :: ds0), ?_, rfl⟩
      have b2d : (d0 == 0x2d) = false := beq_eq_false_iff_ne.mpr n2d
      have b2b : (d0 == 0x2b) = false := beq_eq_false_iff_ne.mpr n2b
      simp only [byte, h1, b2d, b2b, Bool.and_false, Bool.or_false, Bool.false_eq_true, ↓reduceIte, hsd, hdv]
    · simp only [List.cons_append, List.nil_append] at h'
      obtain ⟨hj1, h1, h''⟩ := slice_eq_cons hhi h'
      have h2 : slice a (j + 2) hi = d0 :: ds0 := h''
      have hsd := scanDigits_eq hhi (r := []) (by simpa using h2) hds (by simp)
      have hdv := digitsVal_eq hhi (r := []) (by simpa using h2) hds
      refine ⟨false, decVal (d0 :: ds0), ?_, rfl⟩
      simp only [byte, h1, hj1, decide_true, Bool.true_and]
      simp only [List.length_cons] at hsd hdv
      simp [hsd, hdv]
    · simp only [List.cons_append, List.nil_append] at h'
      obtain ⟨hj1, h1, h''⟩ := slice_eq_cons hhi h'
      have h2 : slice a (j + 2) hi = d0 :: ds0 := h''
      have hsd := scanDigits_eq hhi (r := []) (by simpa using h2) hds (by simp)
      have hdv := digitsVal_eq hhi (r := []) (by simpa using h2) hds
      refine ⟨true, decVal (d0 :: ds0), ?_, rfl⟩
      simp only [byte, h1, hj1, decide_true, Bool.true_and]
      simp only [List.length_cons] at hsd hdv
      simp [hsd, hdv]

/-- The value, length and end `numGt` reads from a number's fraction part `f` at `ie`. -/
theorem numFrac_parts {a : ByteArray} {hi ie : Nat} {f x fd : List UInt8} {ex : Int} (hhi : hi ≤ a.size)
    (h : slice a ie hi = f ++ x) (hf : f = [] ∧ fd = [] ∨ IsFrac f fd) (hx : x = [] ∧ ex = 0 ∨ IsExp x ex) :
    (if ie < hi && byte a ie == 0x2e then
        let fe := scanDigits a hi (ie + 1)
        (numGt.digitsVal a (ie + 1) fe, fe - (ie + 1), fe)
      else (0, 0, ie)) = (decVal fd, fd.length, ie + f.length) := by
  have hxf := exp_follow hx (r := []) (by simp)
  simp only [List.append_nil] at hxf
  rcases hf with ⟨rfl, rfl⟩ | ⟨rfl, hne, hds⟩
  · simp only [List.nil_append] at h
    rw [ite_eq_right]
    · simp [decVal]
    · cases hxs : x with
      | nil =>
        rw [hxs] at h
        have := (slice_nil_iff hhi).mp h
        simp only [Bool.and_eq_true, decide_eq_true_eq, not_and]; intro; omega
      | cons b l =>
        rw [hxs] at h hxf
        obtain ⟨-, h0, -⟩ := slice_eq_cons hhi h
        have := (hxf b rfl).2
        simp [byte, h0, this]
  · simp only [List.cons_append] at h
    obtain ⟨hie, h0, h'⟩ := slice_eq_cons hhi h
    rw [ite_eq_left (by simp [byte, h0, hie])]
    have hsd := scanDigits_eq hhi h' hds (fun b hb => (hxf b hb).1)
    have hdv := digitsVal_eq hhi h' hds
    simp only [hsd, hdv, List.length_cons]
    simp; omega

theorem numGt_eval {a : ByteArray} {lo hi n m : Nat} {e : Int} (hhi : hi ≤ a.size)
    (h : IsNumber (slice a lo hi) false m e) : numGt a lo hi n = numCmp m e n := by
  obtain ⟨s, i, f, x, fd, ex, ht, hs, hn, hf, hx, hm, he⟩ := h
  have hs0 : s = [] := by rcases hs with ⟨h, -⟩ | ⟨-, h⟩; exact h; simp at h
  subst hs0
  simp only [List.nil_append] at ht
  obtain ⟨d, ds, hid, hd, -⟩ := isInt_cons hn
  have ht' : slice a lo hi = d :: (ds ++ f ++ x) := by rw [ht, hid]; simp
  obtain ⟨hlo, h0, -⟩ := slice_eq_cons hhi ht'
  have hc1 : (lo < hi && byte a lo == 0x2d) = false := by
    simp only [byte, h0]
    have : d ≠ 0x2d := fun h => not_digit_2d (h ▸ hd)
    simp [this]
  have hfx := frac_follow hf hx (r := []) (by simp)
  simp only [List.append_nil] at hfx
  have hsi : slice a lo hi = i ++ (f ++ x) := by rw [ht, List.append_assoc]
  have hie := scanDigits_eq hhi hsi (isInt_digits hn) hfx
  have hiv := digitsVal_eq hhi hsi (isInt_digits hn)
  have hfr := numFrac_parts hhi (slice_append_eq hhi hsi) hf hx
  have hxs : slice a (lo + i.length + f.length) hi = x := by
    have := slice_append_eq hhi (t := i ++ f) (r := x) (by rw [hsi, List.append_assoc])
    simpa [Nat.add_assoc] using this
  obtain ⟨b, v, hev, hbv⟩ := numExp_parts hhi hxs hx
  rw [numGt_eq, ite_eq_right (by simp [hc1])]
  dsimp only
  rw [hie, hfr]
  dsimp only
  rw [hev]
  dsimp only
  rw [hiv, hbv, mulPow10_eq, ← decVal_append, ← hm, ← he]

theorem numGt_neg {a : ByteArray} {lo hi n m : Nat} {e : Int} (hhi : hi ≤ a.size)
    (h : IsNumber (slice a lo hi) true m e) : numGt a lo hi n = false := by
  obtain ⟨s, i, f, x, fd, ex, ht, hs, -, -, -, -, -⟩ := h
  have hs0 : s = [0x2d] := by rcases hs with ⟨-, h⟩ | ⟨h, -⟩; simp at h; exact h
  subst hs0
  have ht' : slice a lo hi = 0x2d :: (i ++ f ++ x) := by rw [ht]; simp
  obtain ⟨hlo, h0, -⟩ := slice_eq_cons hhi ht'
  rw [numGt_eq, ite_eq_left (by simp [byte, h0, hlo])]

/-- **`numGt` compares exactly**: on the text of a JSON number, it says whether the number's value
is greater than `n` (what `exp` and `nbf` are checked with). -/
theorem numGt_spec {a : ByteArray} {lo hi n : Nat} {neg : Bool} {m : Nat} {e : Int}
    (h : Spec.Json.IsNumber (slice a lo hi) neg m e) (hhi : hi ≤ a.size) :
    Json.numGt a lo hi n = true ↔ Spec.Json.NumGt (slice a lo hi) n := by
  unfold NumGt
  cases neg with
  | true =>
    rw [numGt_neg hhi h]
    simp only [Bool.false_eq_true, false_iff, not_exists, not_and]
    intro neg' m' e' h' hn
    obtain ⟨hneg, -, -⟩ := IsNumber.unique h h'
    rw [← hneg] at hn
    cases hn
  | false =>
    rw [numGt_eval hhi h, numCmp_spec]
    constructor
    · intro hc; exact ⟨false, m, e, h, rfl, hc⟩
    · rintro ⟨neg', m', e', h', -, hc⟩
      obtain ⟨-, rfl, rfl⟩ := IsNumber.unique h h'
      exact hc

/-- info: 'Feed.Json.numGt_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Feed.Json.numGt_spec

end Feed.Json
