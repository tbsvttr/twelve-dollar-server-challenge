import Feed.Proofs.JsonToken

/-!
# JSON values and `parseTop`

`Json.parseTop` against RFC 8259's texts and objects (`Feed/Spec/Json.lean`), from the theorems on
strings, numbers and whitespace in `Feed/Proofs/JsonToken.lean`:

- The scanners accept only JSON, with any fuel: `scanValue` stops just after the text of a value,
  `topMembers` after an object's members and its closing brace, `scanElems` after an array's
  elements and its closing bracket (`scanValue_sound`). With fuel as long as the text they find
  every value (`scanValue_complete`), so `parseTop`'s fuel, one more than the range's length, is
  enough.
- `keyEq` compares a member's name with a key as code units (`keyEq_iff`), and `recordField` keeps,
  for each key, the last member with its name (`fields_record`).
- `parseTop` says malformed exactly when the bytes are no JSON text, and not an object when the
  text's value is another value; for a text whose value is an object it reports, for each wanted
  key (the keys distinct and ASCII), the span of the value of the last member with that name and
  whether that value is a string or a number (`parseTop_spec`).
- An object text has one list of members (`IsObjectText.unique`), so `Spec/Auth.lean`'s
  `objectMembers` and `Spec/Body.lean`'s `postBody`, which choose one, have one to choose; a JSON
  text is UTF-8 (`IsText.utf8`, RFC 8259 §8.1).

`scanString` accepts only UTF-8, as `parseTop_spec` needs: `{"body":"<FF>"}` is malformed to
`parseTop` and no JSON text to the specification.
-/
namespace Feed.Json
open Spec.Json

/-! ## What the parser reports -/

/-- What `parseTop` reports for a wanted key, against the value of the last member with that
name (`none`: no member has it): the span of the value's text, and whether it is a string or a
number. -/
def FieldIs (a : ByteArray) (f : Field) : Option (List UInt8) → Prop
  | none => f.kind = .absent
  | some v => slice a f.lo f.hi = v ∧ f.lo < f.hi ∧ f.hi ≤ a.size ∧ f.kind ≠ .absent ∧
      (f.kind = .str ↔ ∃ us, IsString v us) ∧ (f.kind = .num ↔ ∃ neg m e, IsNumber v neg m e)

/-- The fields `fs` hold, for each key, the last of the members `ms` with its name. -/
def Fields (a : ByteArray) (keys : Array ByteArray) (fs : Array Field) (ms : List (List Nat × List UInt8)) :
    Prop :=
  fs.size = keys.size ∧ ∀ q (hq : q < keys.size), FieldIs a fs[q]! (member ms ((bs keys[q]).map (·.toNat)))

/-- What may follow the text of a value: no byte that would continue a number. -/
def NumEnd (r : List UInt8) : Prop := ∀ b ∈ r.head?, ¬ IsDigit b ∧ b ≠ 0x2e ∧ b ≠ 0x65 ∧ b ≠ 0x45

/-! ## The first byte of a value -/

theorem isDigit_toNat {b : UInt8} (h : IsDigit b) : 0x30 ≤ b.toNat ∧ b.toNat ≤ 0x39 := by
  unfold IsDigit at h; simpa [UInt8.le_iff_toNat_le] using h

/-- The first byte of a value tells its kind. -/
theorem isValue_cases {v : List UInt8} (h : IsValue v) : ∃ b r, v = b :: r ∧
    (b = 0x22 ∧ (∃ us, IsString v us) ∨ (b = 0x2d ∨ IsDigit b) ∧ (∃ neg m e, IsNumber v neg m e) ∨
      b = 0x74 ∧ v = [0x74, 0x72, 0x75, 0x65] ∨ b = 0x66 ∧ v = [0x66, 0x61, 0x6c, 0x73, 0x65] ∨
      b = 0x6e ∧ v = [0x6e, 0x75, 0x6c, 0x6c] ∨ b = 0x7b ∧ (∃ ms, IsObject v ms) ∨ b = 0x5b ∧ IsArray v) := by
  cases h with
  | str hs =>
    obtain ⟨b, rfl, -⟩ := id hs
    exact ⟨_, _, rfl, Or.inl ⟨rfl, _, hs⟩⟩
  | num hn =>
    obtain ⟨b, r, rfl, hb⟩ := hn.head
    exact ⟨_, _, rfl, Or.inr (Or.inl ⟨hb, _, _, _, hn⟩)⟩
  | tru => exact ⟨_, _, rfl, by simp⟩
  | fls => exact ⟨_, _, rfl, by simp⟩
  | null => exact ⟨_, _, rfl, by simp⟩
  | obj ho =>
    cases ho with
    | empty hw =>
      have h' := IsObject.empty hw
      simp only [List.cons_append] at h' ⊢
      exact ⟨_, _, rfl, Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inl ⟨rfl, _, h'⟩)))))⟩
    | members h1 hm h2 =>
      have h' := IsObject.members h1 hm h2
      simp only [List.cons_append] at h' ⊢
      exact ⟨_, _, rfl, Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inl ⟨rfl, _, h'⟩)))))⟩
  | arr ha =>
    cases ha with
    | empty hw =>
      have h' := IsArray.empty hw
      simp only [List.cons_append] at h' ⊢
      exact ⟨_, _, rfl, Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr ⟨rfl, h'⟩)))))⟩
    | elems h1 he h2 =>
      have h' := IsArray.elems h1 he h2
      simp only [List.cons_append] at h' ⊢
      exact ⟨_, _, rfl, Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr ⟨rfl, h'⟩)))))⟩

theorem isWs_toNat {b : UInt8} (h : IsWs b) : b.toNat = 0x20 ∨ b.toNat = 0x09 ∨ b.toNat = 0x0a ∨ b.toNat = 0x0d := by
  unfold IsWs at h; rcases h with rfl | rfl | rfl | rfl <;> simp

/-- A value is not empty, and it starts with none of whitespace, `}`, `]`, `,` or `:`. -/
theorem _root_.Feed.Spec.Json.IsValue.head_ne {v : List UInt8} (h : IsValue v) :
    ∃ b r, v = b :: r ∧ ¬ IsWs b ∧ b ≠ 0x7d ∧ b ≠ 0x5d ∧ b ≠ 0x2c ∧ b ≠ 0x3a := by
  obtain ⟨b, r, rfl, hb⟩ := isValue_cases h
  refine ⟨b, r, rfl, fun hw => ?_, ?_⟩
  · have := isWs_toNat hw
    rcases hb with ⟨rfl, -⟩ | ⟨hb, -⟩ | ⟨rfl, -⟩ | ⟨rfl, -⟩ | ⟨rfl, -⟩ | ⟨rfl, -⟩ | ⟨rfl, -⟩
    all_goals try (simp at this)
    rcases hb with rfl | hb
    · simp at this
    · have := isDigit_toNat hb; omega
  · rcases hb with ⟨rfl, -⟩ | ⟨hb, -⟩ | ⟨rfl, -⟩ | ⟨rfl, -⟩ | ⟨rfl, -⟩ | ⟨rfl, -⟩ | ⟨rfl, -⟩
    all_goals try (refine ⟨?_, ?_, ?_, ?_⟩ <;> decide)
    rcases hb with rfl | hb
    · refine ⟨?_, ?_, ?_, ?_⟩ <;> decide
    · have := isDigit_toNat hb
      refine ⟨?_, ?_, ?_, ?_⟩ <;> (intro h; rw [h] at this; simp at this)

/-- The members of an object start with the quote of the first name. -/
theorem _root_.Feed.Spec.Json.IsMembers.head {m : List UInt8} {ms : List (List Nat × List UInt8)}
    (h : IsMembers m ms) : ∃ r, m = 0x22 :: r := by
  cases h with
  | one hk _ _ _ =>
    obtain ⟨b, rfl, -⟩ := hk; simp only [List.cons_append, List.append_assoc]; exact ⟨_, rfl⟩
  | cons hk _ _ _ _ _ _ =>
    obtain ⟨b, rfl, -⟩ := hk; simp only [List.cons_append, List.append_assoc]; exact ⟨_, rfl⟩

/-- The elements of an array start with a value. -/
theorem _root_.Feed.Spec.Json.IsElems.head_ne {e : List UInt8} (h : IsElems e) :
    ∃ b r, e = b :: r ∧ ¬ IsWs b ∧ b ≠ 0x7d ∧ b ≠ 0x5d ∧ b ≠ 0x2c ∧ b ≠ 0x3a := by
  cases h with
  | one hv => exact hv.head_ne
  | cons hv _ _ _ =>
    obtain ⟨b, r, he, hb⟩ := hv.head_ne
    rw [he]; simp only [List.cons_append, List.append_assoc]
    exact ⟨b, _, rfl, hb⟩

/-! ## Whitespace, literals -/

/-- `skipWs` stops in the range, after whitespace, at a byte that is not whitespace. -/
theorem skipWs_facts {a : ByteArray} {hi : Nat} (hhi : hi ≤ a.size) {i : Nat} (hi' : i ≤ hi) :
    i ≤ skipWs a hi i ∧ skipWs a hi i ≤ hi ∧ Ws (slice a i (skipWs a hi i)) ∧
      (skipWs a hi i < hi → ¬ IsWs (a.get! (skipWs a hi i))) := by
  obtain ⟨w, r, hs, hw, hr, he⟩ := skipWs_spec a hhi i
  have hlen := slice_length a (lo := i) hhi
  rw [hs, List.length_append] at hlen
  refine ⟨by omega, by omega, by rw [he, slice_prefix hhi hs]; exact hw, fun hlt => ?_⟩
  have hrest := slice_append_eq hhi hs
  rw [← he] at hrest
  cases r with
  | nil => simp at hlen; omega
  | cons b r =>
    obtain ⟨-, h0, -⟩ := slice_eq_cons hhi hrest
    rw [h0]; exact hr b rfl

theorem scanLit_sound {a : ByteArray} {hi : Nat} (hhi : hi ≤ a.size) :
    ∀ (lit : List UInt8) (i j : Nat), i ≤ hi → scanLit a hi i lit = some j →
      j = i + lit.length ∧ j ≤ hi ∧ slice a i j = lit
  | [], i, j, hi', h => by
    simp only [scanLit, Option.some.injEq] at h; subst h; exact ⟨rfl, hi', slice_empty a i⟩
  | c :: cs, i, j, _, h => by
    simp only [scanLit] at h
    split at h
    · rename_i hc
      simp only [Bool.and_eq_true, decide_eq_true_eq, beq_iff_eq, byte] at hc
      obtain ⟨rfl, hj, hs⟩ := scanLit_sound hhi cs (i + 1) j (by omega) h
      refine ⟨by simp; omega, hj, ?_⟩
      rw [slice_cons a (by omega) (by omega), hc.2, hs]
    · cases h

theorem scanLit_complete {a : ByteArray} {hi : Nat} (hhi : hi ≤ a.size) :
    ∀ (lit : List UInt8) (i : Nat) (r : List UInt8), slice a i hi = lit ++ r →
      scanLit a hi i lit = some (i + lit.length)
  | [], i, r, _ => by simp [scanLit]
  | c :: cs, i, r, h => by
    obtain ⟨hi', h0, hrest⟩ := slice_eq_cons hhi (by simpa using h)
    simp only [scanLit, byte, h0, hi', decide_true, beq_self_eq_true, Bool.and_self, ↓reduceIte]
    rw [scanLit_complete hhi cs (i + 1) r hrest]; simp; omega

theorem slice_snoc (a : ByteArray) {i k : Nat} (hik : i ≤ k) (hk : k < a.size) :
    slice a i (k + 1) = slice a i k ++ [a.get! k] := by
  rw [slice_split a hik (Nat.le_succ k), slice_one a hk]

/-! ## `topMembers` reads as `scanMembers` -/

/-- `topMembers` stops where `scanMembers` does: it only records fields on the way. -/
theorem topMembers_fst (a : ByteArray) (hi : Nat) (keys : Array ByteArray) :
    ∀ f i first fs, (topMembers a hi keys i first fs f).map Prod.fst = scanMembers a hi i first f := by
  intro f
  induction f with
  | zero => intros; rfl
  | succ f ih =>
    intro i first fs
    simp only [topMembers, scanMembers]
    split
    · rfl
    split
    · rfl
    split
    · rfl
    cases scanString a hi (i + 1) with
    | none => rfl
    | some j =>
      dsimp only [bind, Option.bind]
      split
      · rfl
      cases scanValue a hi (skipWs a hi (skipWs a hi j + 1)) f with
      | none => rfl
      | some k =>
        dsimp only
        split
        · rfl
        split
        · rfl
        split
        · exact ih _ _ _
        · rfl

/-- Where `scanMembers` stops, `topMembers` stops, with some fields. -/
theorem scanMembers_some {a : ByteArray} {hi : Nat} (keys : Array ByteArray) {f i : Nat} {first : Bool}
    {j : Nat} (fs : Array Field) (h : scanMembers a hi i first f = some j) :
    ∃ fs', topMembers a hi keys i first fs f = some (j, fs') := by
  rw [← topMembers_fst a hi keys f i first fs] at h
  cases ht : topMembers a hi keys i first fs f with
  | none => rw [ht] at h; cases h
  | some p => rw [ht] at h; cases p; simp only [Option.map_some, Option.some.injEq] at h; subst h; exact ⟨_, rfl⟩

/-- The text of one member and the whitespace after it, as `scanMembers` and `topMembers` read
it: the name's text, whitespace, the colon, whitespace, the value's text, whitespace. -/
theorem member_text {a : ByteArray} {hi : Nat} (hhi : hi ≤ a.size) {i j k : Nat} (hij : i ≤ j) (hj : j ≤ hi)
    (hc : skipWs a hi j < hi) (hc' : a.get! (skipWs a hi j) = 0x3a)
    (hk : skipWs a hi (skipWs a hi j + 1) ≤ k) (hk' : k ≤ hi) :
    skipWs a hi k ≤ hi ∧ ∃ w₁ w₂ w₃, Ws w₁ ∧ Ws w₂ ∧ Ws w₃ ∧
      slice a i (skipWs a hi k) =
        slice a i j ++ w₁ ++ [0x3a] ++ w₂ ++ slice a (skipWs a hi (skipWs a hi j + 1)) k ++ w₃ := by
  obtain ⟨h1, -, hw1, -⟩ := skipWs_facts hhi hj
  obtain ⟨h2, h2', hw2, -⟩ := skipWs_facts hhi (i := skipWs a hi j + 1) (by omega)
  obtain ⟨h3, h3', hw3, -⟩ := skipWs_facts hhi hk'
  refine ⟨h3', _, _, _, hw1, hw2, hw3, ?_⟩
  rw [slice_split a hij (by omega : j ≤ skipWs a hi k), slice_split a h1 (by omega : skipWs a hi j ≤ skipWs a hi k),
    slice_split a (Nat.le_succ (skipWs a hi j)) (by omega : skipWs a hi j + 1 ≤ skipWs a hi k),
    slice_one a (by omega), hc', slice_split a h2 (by omega : skipWs a hi (skipWs a hi j + 1) ≤ skipWs a hi k),
    slice_split a hk h3]
  simp only [List.append_assoc, List.cons_append]

/-! ## Names -/

theorem ascii_isScalar {c : Nat} (h : c < 0x80) : IsScalar c := by unfold IsScalar; omega

/-- Code units below the surrogates are their own scalar values. -/
theorem scalars_of_lt : ∀ {l : List Nat}, (∀ x ∈ l, x < 0xd800) → scalars l = l
  | [], _ => rfl
  | u :: l, h => by
    rw [scalars_cons_of_not_surrogate (Or.inl (h u (by simp))), scalars_of_lt (fun x hx => h x (by simp [hx]))]

/-- Code units whose scalar values are ASCII are those values. -/
theorem eq_of_scalars_ascii : ∀ {us l : List Nat}, scalars us = l → (∀ x ∈ l, x < 0x80) → us = l
  | [], l, h, _ => by simpa [scalars] using h
  | [u], l, h, hl => by
    simp only [scalars] at h
    subst h
    have := hl _ (List.mem_singleton_self _)
    by_cases hs : 0xd800 ≤ u ∧ u ≤ 0xdfff
    · rw [ite_eq_left hs] at this; omega
    · rw [ite_eq_right hs]
  | u :: v :: rest, l, h, hl => by
    rw [scalars] at h
    split at h
    · subst h; have := hl _ (List.mem_cons_self ..); omega
    · subst h
      have h0 := hl _ (List.mem_cons_self ..)
      have hne : ¬ (0xd800 ≤ u ∧ u ≤ 0xdfff) := fun hs => by rw [ite_eq_left hs] at h0; omega
      rw [ite_eq_right hne]
      congr 1
      exact eq_of_scalars_ascii rfl (fun x hx => hl x (List.mem_cons_of_mem _ hx))

theorem flatMap_utf16_of_lt : ∀ {l : List Nat}, (∀ x ∈ l, x < 0x10000) → l.flatMap utf16 = l
  | [], _ => rfl
  | u :: l, h => by
    rw [List.flatMap_cons, flatMap_utf16_of_lt (fun x hx => h x (by simp [hx]))]
    unfold utf16; rw [ite_eq_left (h u (by simp))]; rfl

theorem spanEq_go_iff (a : ByteArray) (lo : Nat) (key : ByteArray) :
    ∀ f k, spanEq.go a lo key k f = true ↔ ∀ j, k ≤ j → j < k + f → a.get! (lo + j) = key.get! j := by
  intro f
  induction f with
  | zero => intro k; simp only [spanEq.go, true_iff]; intro j h1 h2; omega
  | succ f ih =>
    intro k
    simp only [spanEq.go, byte, Bool.and_eq_true, beq_iff_eq, ih]
    constructor
    · rintro ⟨h0, h⟩ j h1 h2
      rcases Nat.eq_or_lt_of_le h1 with rfl | hlt
      · simpa using h0
      · exact h j (by omega) (by omega)
    · intro h
      exact ⟨by simpa using h k (Nat.le_refl _) (by omega), fun j h1 h2 => h j (by omega) (by omega)⟩

/-- `spanEq` compares a range with a key, byte by byte. -/
theorem spanEq_iff {a : ByteArray} {lo hi : Nat} (key : ByteArray) (h : lo ≤ hi) (h' : hi ≤ a.size) :
    spanEq a lo hi key = true ↔ slice a lo hi = bs key := by
  rw [slice_eq_iff a h h', spanEq, Bool.and_eq_true, beq_iff_eq, spanEq_go_iff, bs_size]
  constructor
  · rintro ⟨hl, hk⟩
    exact ⟨hl, fun k hk' => by rw [hk k (Nat.zero_le _) (by omega), get!_eq]⟩
  · rintro ⟨hl, hk⟩
    exact ⟨hl, fun k _ hk' => by rw [hk k (by omega), get!_eq]⟩

theorem slice_all (a : ByteArray) : slice a 0 a.size = bs a := by
  unfold slice
  rw [List.drop_zero, Nat.sub_zero, size_eq_length]
  exact List.take_length

/-- **A name is compared as code units**: `keyEq` on the text between the quotes of a string
is true exactly when the string's code units are the bytes of the (ASCII) key. -/
theorem keyEq_iff {a : ByteArray} {i j : Nat} {us : List Nat} {key : ByteArray} (hj : j ≤ a.size)
    (hs : IsString (slice a i j) us) (hk : ∀ b ∈ bs key, b < 0x80) :
    keyEq a (i + 1) (j - 1) key = true ↔ us = (bs key).map (·.toNat) := by
  have hs' := hs
  obtain ⟨b, hb, hc⟩ := hs'
  have hlen := slice_length a (lo := i) hj
  rw [hb] at hlen; simp at hlen
  have hbody : slice a (i + 1) (j - 1) = b := by
    have h1 : slice a (i + 1) j = b ++ [0x22] := by
      simpa using slice_append_eq hj (t := [0x22]) (r := b ++ [0x22]) (by simpa using hb)
    rw [show j - 1 = i + 1 + b.length by omega, ← slice_take a (lo := i + 1) (hi := j) b.length (by omega), h1,
      List.take_left]
  have hK : ∀ x ∈ (bs key).map (·.toNat), x < 0x80 := by
    intro x hx
    obtain ⟨y, hy, rfl⟩ := List.mem_map.mp hx
    have := hk y hy; simpa [UInt8.lt_iff_toNat_lt] using this
  have hKs : ∀ x ∈ (bs key).map (·.toNat), IsScalar x := fun x hx => ascii_isScalar (hK x hx)
  have henc : encode ((bs key).map (·.toNat)) = bs key := encode_ascii hk
  unfold keyEq
  rw [Nat.min_eq_left (by omega), Bytes.findByte_eq a 0x5c (by omega), hbody]
  by_cases hbs : 0x5c ∈ b
  · -- with an escape: the decoded name against the key
    have hf : b.findIdx (· == 0x5c) ≠ b.length := by
      rw [Ne, List.findIdx_eq_length]; intro h; have := h _ hbs; simp at this
    rw [ite_eq_right (by simp; omega)]
    have hd := decodeString_spec (show IsString (slice a (i + 1 - 1) (j - 1 + 1)) us by
      rw [show i + 1 - 1 = i by omega, show j - 1 + 1 = j by omega]; exact hs) (by omega)
    simp only [Bool.and_eq_true, beq_iff_eq]
    rw [spanEq_iff key (Nat.zero_le _) (Nat.le_refl _), slice_all, hd]
    constructor
    · rintro ⟨-, he⟩
      rw [← henc] at he
      exact eq_of_scalars_ascii (encode_injective hs.isScalar hKs he) hK
    · intro he
      subst he
      rw [scalars_of_lt (fun x hx => by have := hK x hx; omega), henc]
      refine ⟨?_, rfl⟩
      rw [size_eq_length, size_eq_length, hd, scalars_of_lt (fun x hx => by have := hK x hx; omega), henc]
  · -- without one: the bytes of the name against the key
    have hf : b.findIdx (· == 0x5c) = b.length := by
      rw [List.findIdx_eq_length]; intro x hx; simp; rintro rfl; exact hbs hx
    rw [ite_eq_left (by simp; omega), spanEq_iff key (by omega) (by omega), hbody]
    obtain ⟨cs, hcs, rfl, rfl⟩ := strChars_noEsc hc hbs
    constructor
    · intro he
      rw [← henc] at he
      have := encode_injective hcs hKs he
      subst this
      exact flatMap_utf16_of_lt (fun x hx => by have := hK x hx; omega)
    · intro he
      have := scalars_flatMap_utf16 hcs
      rw [he, scalars_of_lt (fun x hx => by have := hK x hx; omega)] at this
      rw [← this, henc]

/-- info: 'Feed.Json.keyEq_iff' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Feed.Json.keyEq_iff

/-! ## Recording the wanted keys -/

/-- The last member with a name, after one more member. -/
theorem member_append (ms : List (List Nat × List UInt8)) (us : List Nat) (v : List UInt8) (name : List Nat) :
    member (ms ++ [(us, v)]) name = if us = name then some v else member ms name := by
  unfold member
  rw [List.reverse_append, List.reverse_singleton, List.singleton_append, List.find?_cons]
  by_cases h : us = name
  · subst h; simp
  · rw [show (us == name) = false from beq_eq_false_iff_ne.mpr h]; simp [h]

/-- The kind `parseTop` records is the value's: a string, a number, or another value. -/
theorem kindAt_spec {a : ByteArray} {i j : Nat} (hj : j ≤ a.size) (hv : IsValue (slice a i j)) :
    kindAt a i ≠ .absent ∧ (kindAt a i = .str ↔ ∃ us, IsString (slice a i j) us) ∧
      (kindAt a i = .num ↔ ∃ neg m e, IsNumber (slice a i j) neg m e) := by
  obtain ⟨b, r, hs, hb⟩ := isValue_cases hv
  obtain ⟨-, h0, -⟩ := slice_eq_cons hj hs
  have hnstr : b ≠ 0x22 → ¬ ∃ us, IsString (slice a i j) us := by
    rintro hb' ⟨us, hu⟩; have := hu.head; rw [hs] at this; simp at this; exact hb' this
  have hnnum : b ≠ 0x2d → ¬ IsDigit b → ¬ ∃ neg m e, IsNumber (slice a i j) neg m e := by
    rintro h1 h2 ⟨neg, m, e, hn⟩
    obtain ⟨b', r', he, hb'⟩ := hn.head
    rw [hs] at he; simp only [List.cons.injEq] at he; rw [← he.1] at hb'
    rcases hb' with h | h; exact h1 h; exact h2 h
  have hdig : ∀ c : UInt8, c.toNat < 0x30 ∨ 0x39 < c.toNat → ¬ IsDigit c := fun c hc hd => by
    have := isDigit_toNat hd; omega
  unfold kindAt
  simp only [byte, h0]
  rcases hb with ⟨rfl, hstr⟩ | ⟨hb, hnum⟩ | ⟨rfl, -⟩ | ⟨rfl, -⟩ | ⟨rfl, -⟩ | ⟨rfl, -⟩ | ⟨rfl, -⟩
  · simp only [beq_self_eq_true, ↓reduceIte, ne_eq, reduceCtorEq, not_false_eq_true, true_and, true_iff,
      false_iff]
    exact ⟨hstr, hnnum (by decide) (hdig _ (by decide))⟩
  · have hb22 : b ≠ 0x22 := by
      rcases hb with rfl | hb; decide; intro h; rw [h] at hb; exact hdig _ (by decide) hb
    have hnum' : (b == 0x2d || isDigit b) = true := by
      rcases hb with rfl | hb; simp; simp [(isDigit_iff b).mpr hb]
    rw [ite_eq_right (by simpa using hb22), ite_eq_left hnum']
    simp only [ne_eq, reduceCtorEq, not_false_eq_true, false_iff, true_and, true_iff]
    exact ⟨hnstr hb22, hnum⟩
  all_goals
    rw [ite_eq_right (by decide), ite_eq_right (by decide)]
    simp only [ne_eq, reduceCtorEq, not_false_eq_true, false_iff, true_and]
    exact ⟨hnstr (by decide), hnnum (by decide) (hdig _ (by decide))⟩

/-- From key `k` on, `recordField.go` sets the field of the key that the member's name matches,
if one does (at most one, by `huniq`). -/
theorem recordField_go_get (a : ByteArray) (klo khi vlo vhi : Nat) (keys : Array ByteArray)
    (huniq : ∀ k k', k < keys.size → k' < keys.size → keyEq a klo khi keys[k]! = true →
      keyEq a klo khi keys[k']! = true → k = k') :
    ∀ f k (fs : Array Field), k + f = keys.size → fs.size = keys.size →
      (recordField.go a klo khi vlo vhi keys k f fs).size = keys.size ∧
      ∀ q, q < keys.size → (recordField.go a klo khi vlo vhi keys k f fs)[q]! =
        if k ≤ q ∧ keyEq a klo khi keys[q]! = true then ⟨kindAt a vlo, vlo, vhi⟩ else fs[q]! := by
  intro f
  induction f with
  | zero =>
    intro k fs hk hs
    refine ⟨hs, fun q hq => ?_⟩
    simp only [recordField.go]
    rw [ite_eq_right (by omega)]
  | succ f ih =>
    intro k fs hk hs
    simp only [recordField.go]
    split
    · rename_i hkey
      refine ⟨by rw [Array.size_set!, hs], fun q hq => ?_⟩
      by_cases hqk : q = k
      · subst hqk
        rw [Array.getElem!_set!_self _ _ _ (by omega), ite_eq_left ⟨Nat.le_refl _, hkey⟩]
      · rw [Array.getElem!_set!_ne _ _ _ _ (Ne.symm hqk), ite_eq_right]
        rintro ⟨-, hq'⟩
        exact hqk (huniq q k hq (by omega) hq' hkey)
    · rename_i hkey
      obtain ⟨h1, h2⟩ := ih (k + 1) fs (by omega) hs
      refine ⟨h1, fun q hq => ?_⟩
      rw [h2 q hq]
      by_cases hqk : q = k
      · subst hqk
        rw [ite_eq_right (by omega), ite_eq_right (by simp only [Bool.not_eq_true] at hkey; simp [hkey])]
      · by_cases hp : k + 1 ≤ q ∧ keyEq a klo khi keys[q]! = true
        · rw [ite_eq_left hp, ite_eq_left ⟨by omega, hp.2⟩]
        · rw [ite_eq_right hp, ite_eq_right (fun h => hp ⟨by omega, h.2⟩)]

/-- **The last member with a wanted name wins**: recording one member keeps `fs` holding, for
each key, the last member with its name (the keys distinct, ASCII). -/
theorem fields_record {a : ByteArray} {keys : Array ByteArray} (hd : (keys.toList.map bs).Nodup)
    (ha : ∀ k ∈ keys.toList, ∀ b ∈ bs k, b < 0x80) {fs : Array Field} {ms : List (List Nat × List UInt8)}
    (hf : Fields a keys fs ms) {i j vlo vhi : Nat} {us : List Nat} (hj : j ≤ a.size)
    (hs : IsString (slice a i j) us) (hv : IsValue (slice a vlo vhi)) (hlt : vlo < vhi) (hvhi : vhi ≤ a.size) :
    Fields a keys (recordField a (i + 1) (j - 1) vlo vhi keys fs) (ms ++ [(us, slice a vlo vhi)]) := by
  obtain ⟨hsize, hfs⟩ := hf
  have hkey : ∀ k (hk : k < keys.size), keyEq a (i + 1) (j - 1) keys[k]! = true ↔
      us = (bs keys[k]).map (·.toNat) := by
    intro k hk
    rw [getElem!_pos keys k hk]
    exact keyEq_iff hj hs (ha _ (Array.getElem_mem_toList hk))
  have huniq : ∀ k k', k < keys.size → k' < keys.size → keyEq a (i + 1) (j - 1) keys[k]! = true →
      keyEq a (i + 1) (j - 1) keys[k']! = true → k = k' := by
    intro k k' hk hk' h h'
    rw [hkey k hk] at h; rw [hkey k' hk'] at h'
    have he : bs keys[k] = bs keys[k'] := (List.map_inj_right (fun x y => UInt8.toNat_inj.mp)).mp (h.symm.trans h')
    refine hd.eq_of_getElem_eq (by simpa using hk) (by simpa using hk') ?_
    simpa using he
  obtain ⟨h1, h2⟩ := recordField_go_get a (i + 1) (j - 1) vlo vhi keys huniq keys.size 0 fs (by omega) hsize
  refine ⟨h1, fun q hq => ?_⟩
  unfold recordField
  rw [h2 q hq, member_append]
  by_cases hq' : us = (bs keys[q]).map (·.toNat)
  · rw [ite_eq_left ⟨Nat.zero_le _, (hkey q hq).mpr hq'⟩, ite_eq_left hq']
    obtain ⟨hk1, hk2, hk3⟩ := kindAt_spec hvhi hv
    exact ⟨rfl, hlt, hvhi, hk1, hk2, hk3⟩
  · rw [ite_eq_right (fun h => hq' ((hkey q hq).mp h.2)), ite_eq_right hq']
    exact hfs q hq

/-- info: 'Feed.Json.fields_record' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Feed.Json.fields_record

/-! ## The scanners accept only JSON -/

/-- **The scanners accept only JSON**, with any fuel: `scanValue` stops after the text of a value,
`topMembers` after members and the brace that closes them (with, for each key, the last of them
with its name recorded), `scanElems` after elements and the bracket that closes them. -/
theorem scanValue_sound {a : ByteArray} {hi : Nat} (hhi : hi ≤ a.size) {keys : Array ByteArray}
    (hd : (keys.toList.map bs).Nodup) (ha : ∀ k ∈ keys.toList, ∀ b ∈ bs k, b < 0x80) : ∀ f,
    (∀ i j, scanValue a hi i f = some j → i < j ∧ j ≤ hi ∧ IsValue (slice a i j)) ∧
    (∀ i first fs j fs', topMembers a hi keys i first fs f = some (j, fs') → i < j ∧ j ≤ hi ∧
      (first = true ∧ slice a i j = [0x7d] ∧ fs' = fs ∨
       ∃ m ms w, IsMembers m ms ∧ Ws w ∧ slice a i j = m ++ w ++ [0x7d] ∧
         ∀ ms₀, Fields a keys fs ms₀ → Fields a keys fs' (ms₀ ++ ms))) ∧
    (∀ i first j, scanElems a hi i first f = some j → i < j ∧ j ≤ hi ∧
      (first = true ∧ slice a i j = [0x5d] ∨ ∃ e w, IsElems e ∧ Ws w ∧ slice a i j = e ++ w ++ [0x5d])) := by
  intro f
  induction f with
  | zero =>
    exact ⟨fun _ _ h => by simp [scanValue] at h, fun _ _ _ _ _ h => by simp [topMembers] at h,
      fun _ _ _ h => by simp [scanElems] at h⟩
  | succ f ih =>
    obtain ⟨ihv, ihm, ihe⟩ := ih
    refine ⟨?_, ?_, ?_⟩
    · -- a value
      intro i j h
      simp only [scanValue] at h
      split at h
      · cases h
      rename_i hge
      have hlt : i < hi := by omega
      split at h
      · rename_i hq
        simp only [byte, beq_iff_eq] at hq
        obtain ⟨h1, h2, us, hs⟩ := scanString_sound hhi hq h
        exact ⟨by omega, h2, .str hs⟩
      split at h
      · rename_i _ hq
        simp only [byte, beq_iff_eq] at hq
        obtain ⟨s1, s2, sw, -⟩ := skipWs_facts hhi (i := i + 1) (by omega)
        obtain ⟨fs', hfs⟩ := scanMembers_some keys #[] h
        obtain ⟨h1, h2, hm⟩ := ihm _ true #[] j fs' hfs
        have hsl : slice a i j =
            0x7b :: slice a (i + 1) (skipWs a hi (i + 1)) ++ slice a (skipWs a hi (i + 1)) j := by
          rw [slice_cons a (by omega : i < j) (by omega), hq, slice_split a s1 (by omega)]; rfl
        refine ⟨by omega, h2, ?_⟩
        rcases hm with ⟨-, hr, -⟩ | ⟨m, ms, w, hm, hw, hr, -⟩
        · rw [hsl, hr]; exact .obj (.empty sw)
        · rw [hsl, hr]; exact .obj (by simpa only [List.append_assoc] using IsObject.members sw hm hw)
      split at h
      · rename_i _ _ hq
        simp only [byte, beq_iff_eq] at hq
        obtain ⟨s1, s2, sw, -⟩ := skipWs_facts hhi (i := i + 1) (by omega)
        obtain ⟨h1, h2, he⟩ := ihe _ true j h
        have hsl : slice a i j =
            0x5b :: slice a (i + 1) (skipWs a hi (i + 1)) ++ slice a (skipWs a hi (i + 1)) j := by
          rw [slice_cons a (by omega : i < j) (by omega), hq, slice_split a s1 (by omega)]; rfl
        refine ⟨by omega, h2, .arr ?_⟩
        rcases he with ⟨-, hr⟩ | ⟨e, w, he, hw, hr⟩
        · rw [hsl, hr]; exact .empty sw
        · rw [hsl, hr]; simpa only [List.append_assoc] using IsArray.elems sw he hw
      split at h
      · obtain ⟨rfl, h2, hs⟩ := scanLit_sound hhi _ i j (by omega) h
        exact ⟨by simp, h2, by rw [hs]; exact .tru⟩
      split at h
      · obtain ⟨rfl, h2, hs⟩ := scanLit_sound hhi _ i j (by omega) h
        exact ⟨by simp, h2, by rw [hs]; exact .fls⟩
      split at h
      · obtain ⟨rfl, h2, hs⟩ := scanLit_sound hhi _ i j (by omega) h
        exact ⟨by simp, h2, by rw [hs]; exact .null⟩
      · obtain ⟨h1, h2, neg, m, e, hn⟩ := scanNumber_sound hhi h
        exact ⟨h1, h2, .num hn⟩
    · -- the members of an object
      intro i first fs j fs' h
      simp only [topMembers] at h
      split at h
      · cases h
      rename_i hge
      have hlt : i < hi := by omega
      split at h
      · rename_i hc
        simp only [Bool.and_eq_true, beq_iff_eq, byte] at hc
        simp only [Option.some.injEq, Prod.mk.injEq] at h
        obtain ⟨rfl, rfl⟩ := h
        exact ⟨by omega, by omega, Or.inl ⟨hc.1, by rw [slice_one a (by omega), hc.2], rfl⟩⟩
      split at h
      · cases h
      rename_i hq
      simp only [bne_iff_ne, ne_eq, Decidable.not_not, byte] at hq
      cases hj1 : scanString a hi (i + 1) with
      | none => rw [hj1] at h; cases h
      | some j1 =>
        rw [hj1] at h
        dsimp only [bind, Option.bind] at h
        obtain ⟨k1a, k1b, us, hus⟩ := scanString_sound hhi hq hj1
        split at h
        · simp at h
        rename_i hcolon
        simp only [Bool.or_eq_true, decide_eq_true_eq, bne_iff_ne, ne_eq, not_or, Decidable.not_not, byte,
          Nat.not_le] at hcolon
        cases hk1 : scanValue a hi (skipWs a hi (skipWs a hi j1 + 1)) f with
        | none => rw [hk1] at h; cases h
        | some k1 =>
          rw [hk1] at h
          dsimp only at h
          obtain ⟨v1, v2, hv⟩ := ihv _ _ hk1
          obtain ⟨u1, u2, -, -⟩ := skipWs_facts hhi k1b
          obtain ⟨u3, u4, -, -⟩ := skipWs_facts hhi (i := skipWs a hi j1 + 1) (by omega)
          obtain ⟨u5, u6, -, -⟩ := skipWs_facts hhi v2
          obtain ⟨hk2, w₁, w₂, w₃, hw₁, hw₂, hw₃, htext⟩ :=
            member_text hhi (i := i) (by omega) k1b hcolon.1 hcolon.2 (by omega) v2
          have hrec : ∀ ms₀, Fields a keys fs ms₀ → Fields a keys
              (recordField a (i + 1) (j1 - 1) (skipWs a hi (skipWs a hi j1 + 1)) k1 keys fs)
              (ms₀ ++ [(us, slice a (skipWs a hi (skipWs a hi j1 + 1)) k1)]) :=
            fun ms₀ h₀ => fields_record hd ha h₀ (by omega) hus hv v1 (by omega)
          split at h
          · cases h
          rename_i hk2'
          split at h
          · rename_i hend
            simp only [byte, beq_iff_eq] at hend
            simp only [Option.some.injEq, Prod.mk.injEq] at h
            obtain ⟨rfl, rfl⟩ := h
            refine ⟨by omega, by omega, Or.inr ⟨_, _, w₃, .one hus hw₁ hw₂ hv, hw₃, ?_, hrec⟩⟩
            rw [slice_snoc a (by omega) (by omega), htext, hend]
          split at h
          · rename_i hcomma
            simp only [byte, beq_iff_eq] at hcomma
            obtain ⟨s1, s2, sw, -⟩ := skipWs_facts hhi (i := skipWs a hi k1 + 1) (by omega)
            obtain ⟨r1, r2, hr⟩ := ihm _ false _ j fs' h
            rcases hr with ⟨hfalse, -⟩ | ⟨m, ms, w, hm, hw, hr, hf⟩
            · cases hfalse
            refine ⟨by omega, r2, Or.inr ⟨_, _, w, .cons hus hw₁ hw₂ hv hw₃ sw hm, hw, ?_, fun ms₀ h₀ => ?_⟩⟩
            · rw [slice_split a (by omega : i ≤ skipWs a hi k1 + 1) (by omega : skipWs a hi k1 + 1 ≤ j),
                slice_snoc a (by omega) (by omega), htext, hcomma, slice_split a s1 (by omega), hr]
              simp only [List.append_assoc, List.cons_append]
            · simpa only [List.append_assoc, List.cons_append, List.nil_append] using hf _ (hrec ms₀ h₀)
          · cases h
    · -- the elements of an array
      intro i first j h
      simp only [scanElems] at h
      split at h
      · cases h
      rename_i hge
      split at h
      · rename_i hc
        simp only [Bool.and_eq_true, beq_iff_eq, byte] at hc
        simp only [Option.some.injEq] at h
        subst h
        exact ⟨by omega, by omega, Or.inl ⟨hc.1, by rw [slice_one a (by omega), hc.2]⟩⟩
      cases hk1 : scanValue a hi i f with
      | none => rw [hk1] at h; cases h
      | some k1 =>
        rw [hk1] at h
        dsimp only [bind, Option.bind] at h
        obtain ⟨v1, v2, hv⟩ := ihv _ _ hk1
        obtain ⟨t1, t2, tw, -⟩ := skipWs_facts hhi v2
        split at h
        · cases h
        split at h
        · rename_i hend
          simp only [byte, beq_iff_eq] at hend
          simp only [Option.some.injEq] at h
          subst h
          refine ⟨by omega, by omega, Or.inr ⟨_, _, .one hv, tw, ?_⟩⟩
          rw [slice_snoc a (by omega) (by omega), slice_split a (Nat.le_of_lt v1) t1, hend]
        split at h
        · rename_i hcomma
          simp only [byte, beq_iff_eq] at hcomma
          obtain ⟨s1, s2, sw, -⟩ := skipWs_facts hhi (i := skipWs a hi k1 + 1) (by omega)
          obtain ⟨r1, r2, hr⟩ := ihe _ false j h
          rcases hr with ⟨hfalse, -⟩ | ⟨e, w, he, hw, hr⟩
          · cases hfalse
          refine ⟨by omega, r2, Or.inr ⟨_, w, .cons hv tw sw he, hw, ?_⟩⟩
          rw [slice_split a (by omega : i ≤ skipWs a hi k1 + 1) (by omega : skipWs a hi k1 + 1 ≤ j),
            slice_snoc a (by omega) (by omega), slice_split a (Nat.le_of_lt v1) t1, hcomma,
            slice_split a s1 (by omega), hr]
          simp only [List.append_assoc, List.cons_append]
        · cases h

/-- info: 'Feed.Json.scanValue_sound' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Feed.Json.scanValue_sound

/-! ## The scanners find all JSON -/

theorem numEnd_ws {w r : List UInt8} (hw : Ws w) (hr : NumEnd r) : NumEnd (w ++ r) := by
  cases w with
  | nil => simpa using hr
  | cons b w =>
    intro c hc
    simp only [List.cons_append, List.head?_cons, Option.mem_def, Option.some.injEq] at hc
    rw [← hc]
    have := isWs_toNat (hw b (by simp))
    refine ⟨fun hd => ?_, ?_, ?_, ?_⟩
    · have := isDigit_toNat hd; omega
    all_goals (intro h; rw [h] at this; simp at this)

theorem numEnd_punct {b : UInt8} {r : List UInt8} (hb : b = 0x7d ∨ b = 0x5d ∨ b = 0x2c) : NumEnd (b :: r) := by
  intro c hc
  simp only [List.head?_cons, Option.mem_def, Option.some.injEq] at hc
  rw [← hc]
  have hb' : b.toNat = 0x7d ∨ b.toNat = 0x5d ∨ b.toNat = 0x2c := by
    rcases hb with rfl | rfl | rfl <;> simp
  refine ⟨fun hd => ?_, ?_, ?_, ?_⟩
  · have := isDigit_toNat hd; omega
  all_goals (intro h; rw [h] at hb'; simp at hb')

theorem numEnd_nil : NumEnd [] := by intro b hb; simp at hb

theorem numEnd_of_ws {w : List UInt8} (hw : Ws w) : NumEnd w := by simpa using numEnd_ws hw numEnd_nil

/-- Whitespace before a byte that is not whitespace: `skipWs` stops at that byte. -/
theorem skipWs_at {a : ByteArray} {hi i : Nat} {w : List UInt8} {b : UInt8} {r : List UInt8} (hhi : hi ≤ a.size)
    (h : slice a i hi = w ++ b :: r) (hw : Ws w) (hb : ¬ IsWs b) : skipWs a hi i = i + w.length :=
  skipWs_eq hhi h hw (fun c hc => by simp at hc; subst hc; exact hb)

theorem not_ws_punct {b : UInt8} (hb : b = 0x7d ∨ b = 0x5d ∨ b = 0x2c ∨ b = 0x3a ∨ b = 0x22) : ¬ IsWs b := by
  intro hw
  have := isWs_toNat hw
  rcases hb with rfl | rfl | rfl | rfl | rfl <;> simp at this

/-- **The scanners find all JSON**, given fuel as long as the text: at the text of a value
followed by a byte that cannot continue a number, `scanValue` stops just after it; at members
or elements, whitespace and the closing brace or bracket, `scanMembers` and `scanElems` stop
just after that. -/
theorem scanValue_complete {a : ByteArray} {hi : Nat} (hhi : hi ≤ a.size) : ∀ f,
    (∀ i v r, IsValue v → slice a i hi = v ++ r → NumEnd r → v.length ≤ f →
      scanValue a hi i f = some (i + v.length)) ∧
    (∀ i first m ms w r, IsMembers m ms → Ws w → slice a i hi = m ++ w ++ 0x7d :: r →
      m.length + w.length + 1 ≤ f → scanMembers a hi i first f = some (i + m.length + w.length + 1)) ∧
    (∀ i first e w r, IsElems e → Ws w → slice a i hi = e ++ w ++ 0x5d :: r →
      e.length + w.length + 1 ≤ f → scanElems a hi i first f = some (i + e.length + w.length + 1)) := by
  intro f
  induction f with
  | zero =>
    refine ⟨fun i v r hv _ _ hl => ?_, fun _ _ _ _ _ _ _ _ _ hl => by omega, fun _ _ _ _ _ _ _ _ hl => by omega⟩
    obtain ⟨b, r', rfl, -⟩ := hv.head_ne
    simp at hl
  | succ f ih =>
    obtain ⟨ihv, ihm, ihe⟩ := ih
    refine ⟨?_, ?_, ?_⟩
    · -- a value
      intro i v r hv h hr hl
      obtain ⟨b, r', hvb, hb⟩ := isValue_cases hv
      have h' : slice a i hi = b :: (r' ++ r) := by rw [h, hvb]; rfl
      obtain ⟨hi0, h0, -⟩ := slice_eq_cons hhi h'
      simp only [scanValue, byte, h0, show ¬ (i ≥ hi) from by omega, ↓reduceIte]
      rcases hb with ⟨rfl, us, hs⟩ | ⟨hb, neg, m, e, hn⟩ | ⟨rfl, hvl⟩ | ⟨rfl, hvl⟩ | ⟨rfl, hvl⟩ | ⟨rfl, ms, ho⟩ |
        ⟨rfl, ha⟩
      · simp only [beq_self_eq_true, ↓reduceIte]
        exact scanString_complete hhi h hs
      · have hd : b.toNat = 0x2d ∨ (0x30 ≤ b.toNat ∧ b.toNat ≤ 0x39) := by
          rcases hb with rfl | hb; · simp
          · exact Or.inr (isDigit_toNat hb)
        have hne : ∀ c : UInt8, c.toNat ≠ b.toNat → (b == c) = false := fun c hc => by
          simp only [beq_eq_false_iff_ne, ne_eq]; rintro rfl; exact hc rfl
        rw [hne 0x22 (by simp; omega), hne 0x7b (by simp; omega), hne 0x5b (by simp; omega),
          hne 0x74 (by simp; omega), hne 0x66 (by simp; omega), hne 0x6e (by simp; omega)]
        simp only [Bool.false_eq_true, ↓reduceIte]
        exact scanNumber_complete hhi h hn hr
      · subst hvl
        rw [ite_eq_right (by decide), ite_eq_right (by decide), ite_eq_right (by decide), ite_eq_left (by decide)]
        exact scanLit_complete hhi _ i r h
      · subst hvl
        rw [ite_eq_right (by decide), ite_eq_right (by decide), ite_eq_right (by decide), ite_eq_right (by decide),
          ite_eq_left (by decide)]
        exact scanLit_complete hhi _ i r h
      · subst hvl
        rw [ite_eq_right (by decide), ite_eq_right (by decide), ite_eq_right (by decide), ite_eq_right (by decide),
          ite_eq_right (by decide), ite_eq_left (by decide)]
        exact scanLit_complete hhi _ i r h
      · -- an object
        rw [ite_eq_right (by decide), ite_eq_left (by decide)]
        cases ho with
        | empty hw =>
          rename_i w
          simp only [List.cons_append, List.cons.injEq] at hvb
          obtain ⟨-, rfl⟩ := hvb
          have h1 : slice a (i + 1) hi = w ++ 0x7d :: r := by
            obtain ⟨-, -, h1⟩ := slice_eq_cons hhi h'; rw [h1]; simp
          rw [skipWs_at hhi h1 hw (not_ws_punct (by simp))]
          obtain ⟨hi1, h01, -⟩ := slice_eq_cons hhi (slice_append_eq hhi h1)
          obtain ⟨f, rfl⟩ : ∃ f', f = f' + 1 := ⟨f - 1, by simp at hl; omega⟩
          simp only [scanMembers, byte, h01, show ¬ (i + 1 + w.length ≥ hi) from by omega, ↓reduceIte,
            Bool.true_and, beq_self_eq_true, List.length_cons, List.length_append, List.length_nil]
          congr 1; omega
        | members hw₁ hm hw₂ =>
          rename_i w₁ m w₂
          simp only [List.cons_append, List.cons.injEq, List.append_assoc] at hvb
          obtain ⟨-, rfl⟩ := hvb
          have h1 : slice a (i + 1) hi = w₁ ++ (m ++ w₂ ++ 0x7d :: r) := by
            obtain ⟨-, -, h1⟩ := slice_eq_cons hhi h'; rw [h1]; simp
          obtain ⟨mr, hmr⟩ := hm.head
          rw [skipWs_at hhi (b := 0x22) (r := mr ++ w₂ ++ 0x7d :: r) (by rw [h1, hmr]; simp) hw₁
            (not_ws_punct (by simp))]
          rw [ihm _ true m _ w₂ r hm hw₂ (slice_append_eq hhi h1) (by simp at hl; omega)]
          simp only [List.length_cons, List.length_append, List.length_nil]
          congr 1; omega
      · -- an array
        rw [ite_eq_right (by decide), ite_eq_right (by decide), ite_eq_left (by decide)]
        cases ha with
        | empty hw =>
          rename_i w
          simp only [List.cons_append, List.cons.injEq] at hvb
          obtain ⟨-, rfl⟩ := hvb
          have h1 : slice a (i + 1) hi = w ++ 0x5d :: r := by
            obtain ⟨-, -, h1⟩ := slice_eq_cons hhi h'; rw [h1]; simp
          rw [skipWs_at hhi h1 hw (not_ws_punct (by simp))]
          obtain ⟨hi1, h01, -⟩ := slice_eq_cons hhi (slice_append_eq hhi h1)
          obtain ⟨f, rfl⟩ : ∃ f', f = f' + 1 := ⟨f - 1, by simp at hl; omega⟩
          simp only [scanElems, byte, h01, show ¬ (i + 1 + w.length ≥ hi) from by omega, ↓reduceIte,
            Bool.true_and, beq_self_eq_true, List.length_cons, List.length_append, List.length_nil]
          congr 1; omega
        | elems hw₁ he hw₂ =>
          rename_i w₁ e w₂
          simp only [List.cons_append, List.cons.injEq, List.append_assoc] at hvb
          obtain ⟨-, rfl⟩ := hvb
          have h1 : slice a (i + 1) hi = w₁ ++ (e ++ w₂ ++ 0x5d :: r) := by
            obtain ⟨-, -, h1⟩ := slice_eq_cons hhi h'; rw [h1]; simp
          obtain ⟨b0, er, her, hb0⟩ := he.head_ne
          rw [skipWs_at hhi (b := b0) (r := er ++ w₂ ++ 0x5d :: r) (by rw [h1, her]; simp) hw₁ hb0.1]
          rw [ihe _ true e w₂ r he hw₂ (slice_append_eq hhi h1) (by simp at hl; omega)]
          simp only [List.length_cons, List.length_append, List.length_nil]
          congr 1; omega
    · -- members
      intro i first m ms w r hm hw h hl
      -- the name, the colon, the value
      have hmem : ∀ {k : List UInt8} {us : List Nat} {w₁ w₂ v rest : List UInt8}, IsString k us → Ws w₁ → Ws w₂ →
          IsValue v → slice a i hi = k ++ w₁ ++ [0x3a] ++ w₂ ++ v ++ rest → NumEnd rest → v.length ≤ f →
          i < hi ∧ a.get! i = 0x22 ∧ scanString a hi (i + 1) = some (i + k.length) ∧
          skipWs a hi (i + k.length) = i + k.length + w₁.length ∧ i + k.length + w₁.length < hi ∧
          a.get! (i + k.length + w₁.length) = 0x3a ∧
          skipWs a hi (i + k.length + w₁.length + 1) = i + k.length + w₁.length + 1 + w₂.length ∧
          scanValue a hi (i + k.length + w₁.length + 1 + w₂.length) f =
            some (i + k.length + w₁.length + 1 + w₂.length + v.length) ∧
          slice a (i + k.length + w₁.length + 1 + w₂.length + v.length) hi = rest := by
        intro k us w₁ w₂ v rest hk hw₁ hw₂ hv h hr hl
        obtain ⟨kb, hkb, -⟩ := id hk
        have hk' : slice a i hi = k ++ (w₁ ++ 0x3a :: (w₂ ++ v ++ rest)) := by rw [h]; simp
        obtain ⟨hi0, h0, -⟩ := slice_eq_cons hhi
          (show slice a i hi = 0x22 :: (kb ++ [0x22] ++ (w₁ ++ 0x3a :: (w₂ ++ v ++ rest))) by rw [hk', hkb]; simp)
        have h1 := slice_append_eq hhi hk'
        have hs1 := skipWs_at hhi h1 hw₁ (not_ws_punct (by simp))
        have h2 := slice_append_eq hhi h1
        obtain ⟨hi2, h02, h3⟩ := slice_eq_cons hhi h2
        obtain ⟨b, vr, hvb, hb⟩ := hv.head_ne
        have hs2 := skipWs_at hhi (b := b) (r := vr ++ rest) (by rw [h3, hvb]; simp) hw₂ hb.1
        have h4 := slice_append_eq hhi (t := w₂) (r := v ++ rest) (by rw [h3]; simp)
        refine ⟨by omega, h0, scanString_complete hhi hk' hk, hs1, hi2, h02, hs2, ?_, ?_⟩
        · rw [ihv _ v rest hv h4 hr hl]
        · exact slice_append_eq hhi h4
      cases hm with
      | one hk hw₁ hw₂ hv =>
        rename_i k us w₁ w₂ v
        obtain ⟨hi0, h0, hs, hs1, hc, hc', hs2, hv', h5⟩ :=
          hmem hk hw₁ hw₂ hv (rest := w ++ 0x7d :: r) (by rw [h]; simp) (numEnd_ws hw (numEnd_punct (by simp)))
            (by simp at hl; omega)
        have hs3 := skipWs_at hhi h5 hw (not_ws_punct (by simp))
        obtain ⟨hi6, h06, -⟩ := slice_eq_cons hhi (slice_append_eq hhi h5)
        simp only [scanMembers]
        rw [ite_eq_right (by omega), ite_eq_right (by simp [byte, h0]), ite_eq_right (by simp [byte, h0]), hs]
        dsimp only [bind, Option.bind]
        rw [hs1, ite_eq_right (by simp [byte, hc']; omega), hs2, hv']
        dsimp only
        rw [hs3, ite_eq_right (by omega), ite_eq_left (by simp [byte, h06])]
        simp only [List.length_append, List.length_cons, List.length_nil]
        congr 1; omega
      | cons hk hw₁ hw₂ hv hw₃ hw₄ hm =>
        rename_i k us w₁ w₂ v w₃ w₄ m' ms'
        obtain ⟨hi0, h0, hs, hs1, hc, hc', hs2, hv', h5⟩ :=
          hmem hk hw₁ hw₂ hv (rest := w₃ ++ 0x2c :: (w₄ ++ m' ++ w ++ 0x7d :: r)) (by rw [h]; simp)
            (numEnd_ws hw₃ (numEnd_punct (by simp))) (by simp at hl; omega)
        have hs3 := skipWs_at hhi (b := 0x2c) (r := w₄ ++ m' ++ w ++ 0x7d :: r)
          (by first | exact h5 | (rw [h5]; simp)) hw₃ (not_ws_punct (by simp))
        have h6 : slice a (i + k.length + w₁.length + 1 + w₂.length + v.length + w₃.length) hi =
            0x2c :: (w₄ ++ (m' ++ w ++ 0x7d :: r)) := by
          have := slice_append_eq hhi (t := w₃) (r := 0x2c :: (w₄ ++ (m' ++ w ++ 0x7d :: r))) (by rw [h5]; simp)
          exact this
        obtain ⟨hi6, h06, h7⟩ := slice_eq_cons hhi h6
        obtain ⟨mr, hmr⟩ := hm.head
        have hs4 := skipWs_at hhi (b := 0x22) (r := mr ++ w ++ 0x7d :: r) (by rw [h7, hmr]; simp) hw₄
          (not_ws_punct (by simp))
        have h8 := slice_append_eq hhi h7
        simp only [scanMembers]
        rw [ite_eq_right (by omega), ite_eq_right (by simp [byte, h0]), ite_eq_right (by simp [byte, h0]), hs]
        dsimp only [bind, Option.bind]
        rw [hs1, ite_eq_right (by simp [byte, hc']; omega), hs2, hv']
        dsimp only
        rw [hs3, ite_eq_right (by omega), ite_eq_right (by simp [byte, h06]), ite_eq_left (by simp [byte, h06]), hs4,
          ihm _ false m' ms' w r hm hw h8 (by simp at hl; omega)]
        simp only [List.length_append, List.length_cons, List.length_nil]
        congr 1; omega
    · -- elements
      intro i first e w r he hw h hl
      cases he with
      | one hv =>
        obtain ⟨b, vr, hvb, hb⟩ := hv.head_ne
        obtain ⟨hi0, h0, -⟩ := slice_eq_cons hhi (show slice a i hi = b :: (vr ++ w ++ 0x5d :: r) by rw [h, hvb]; simp)
        have h1 : slice a i hi = e ++ (w ++ 0x5d :: r) := by rw [h]; simp
        have hv' := ihv _ e _ hv h1 (numEnd_ws hw (numEnd_punct (by simp))) (by simp at hl; omega)
        have h2 := slice_append_eq hhi h1
        have hs3 := skipWs_at hhi h2 hw (not_ws_punct (by simp))
        obtain ⟨hi6, h06, -⟩ := slice_eq_cons hhi (slice_append_eq hhi h2)
        simp only [scanElems]
        rw [ite_eq_right (by omega), ite_eq_right (by simp [byte, h0, hb.2.2.1]), hv']
        dsimp only [bind, Option.bind]
        rw [hs3, ite_eq_right (by omega), ite_eq_left (by simp [byte, h06])]
      | cons hv hw₁ hw₂ he =>
        rename_i v w₁ w₂ e'
        obtain ⟨b, vr, hvb, hb⟩ := hv.head_ne
        obtain ⟨hi0, h0, -⟩ := slice_eq_cons hhi
          (show slice a i hi = b :: (vr ++ w₁ ++ 0x2c :: (w₂ ++ e' ++ w ++ 0x5d :: r)) by rw [h, hvb]; simp)
        have h1 : slice a i hi = v ++ (w₁ ++ 0x2c :: (w₂ ++ e' ++ w ++ 0x5d :: r)) := by rw [h]; simp
        have hv' := ihv _ v _ hv h1 (numEnd_ws hw₁ (numEnd_punct (by simp))) (by simp at hl; omega)
        have h2 := slice_append_eq hhi h1
        have hs3 := skipWs_at hhi h2 hw₁ (not_ws_punct (by simp))
        have h6 := slice_append_eq hhi h2
        obtain ⟨hi6, h06, h7⟩ := slice_eq_cons hhi h6
        obtain ⟨b', er, her, hb'⟩ := he.head_ne
        have hs4 := skipWs_at hhi (b := b') (r := er ++ w ++ 0x5d :: r) (by rw [h7, her]; simp) hw₂ hb'.1
        have h8 := slice_append_eq hhi (t := w₂) (r := e' ++ w ++ 0x5d :: r) (by rw [h7]; simp)
        simp only [scanElems]
        rw [ite_eq_right (by omega), ite_eq_right (by simp [byte, h0, hb.2.2.1]), hv']
        dsimp only [bind, Option.bind]
        rw [hs3, ite_eq_right (by omega), ite_eq_right (by simp [byte, h06]), ite_eq_left (by simp [byte, h06]), hs4,
          ihe _ false e' w r he hw (by first | exact h8 | (rw [h8]; simp)) (by simp at hl; omega)]
        simp only [List.length_append, List.length_cons, List.length_nil]
        congr 1; omega

/-- info: 'Feed.Json.scanValue_complete' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Feed.Json.scanValue_complete

/-! ## `parseTop` -/

/-- Where the value of a JSON text starts and ends. -/
theorem text_value {a : ByteArray} {lo H : Nat} (hH : H ≤ a.size) {w₁ v w₂ : List UInt8}
    (h : slice a lo H = w₁ ++ v ++ w₂) (hw₁ : Ws w₁) (hv : IsValue v) (hw₂ : Ws w₂) :
    skipWs a H lo = lo + w₁.length ∧ slice a (lo + w₁.length) H = v ++ w₂ ∧
      skipWs a H (lo + w₁.length + v.length) = H ∧ v.length ≤ H - lo := by
  have hlen := slice_length a (lo := lo) hH
  rw [h] at hlen; simp only [List.length_append] at hlen
  obtain ⟨b, vr, hvb, hb⟩ := hv.head_ne
  have hv0 : 0 < v.length := by rw [hvb]; simp
  have h1 : slice a lo H = w₁ ++ (v ++ w₂) := by rw [h]; simp
  have h2 := slice_append_eq hH h1
  have h3 := slice_append_eq hH h2
  refine ⟨skipWs_at hH (b := b) (r := vr ++ w₂) (by rw [h1, hvb]; simp) hw₁ hb.1, h2, ?_, by omega⟩
  rw [skipWs_eq hH (w := w₂) (r := []) (by simpa using h3) hw₂ (by simp)]
  omega

/-- At a `{`, `scanValue` scans the members after it. -/
theorem scanValue_open {a : ByteArray} {H i f : Nat} (hi : i < H) (h0 : a.get! i = 0x7b) :
    scanValue a H i (f + 1) = scanMembers a H (skipWs a H (i + 1)) true f := by
  simp only [scanValue, byte, h0, show ¬ (i ≥ H) from by omega, ↓reduceIte]
  rw [ite_eq_right (by decide), ite_eq_left (by decide)]

/-- On a JSON text, `parseTop` finds a value: it says the text is malformed only when it is no
JSON text. -/
theorem parseTop_of_text {a : ByteArray} {lo hi : Nat} (keys : Array ByteArray) (h : IsText (slice a lo hi)) :
    parseTop a lo hi keys ≠ .malformed := by
  rw [← slice_min a lo hi] at h
  have hH : min hi a.size ≤ a.size := Nat.min_le_right _ _
  unfold parseTop
  generalize min hi a.size = H at hH h ⊢
  obtain ⟨w₁, v, w₂, ht, hw₁, hv, hw₂⟩ := h
  obtain ⟨hs, hsl, hend, hlen⟩ := text_value hH ht hw₁ hv hw₂
  obtain ⟨b, vr, hvb, hb⟩ := isValue_cases hv
  obtain ⟨hi0, h0, -⟩ := slice_eq_cons hH
    (show slice a (lo + w₁.length) H = b :: (vr ++ w₂) by rw [hsl, hvb]; simp)
  -- the value is scanned with the fuel `parseTop` gives, and with one more for an object's members
  have hval := fun f (hf : v.length ≤ f) => (scanValue_complete hH f).1 _ v w₂ hv hsl (numEnd_of_ws hw₂) hf
  dsimp only
  rw [hs]
  by_cases hob : b = 0x7b
  · subst hob
    rw [ite_eq_left (by simp [byte, h0, hi0])]
    have hm := hval (H - lo + 1 + 1) (by omega)
    rw [scanValue_open hi0 h0] at hm
    obtain ⟨fs, hfs⟩ := scanMembers_some keys (Array.replicate keys.size ⟨.absent, 0, 0⟩) hm
    rw [hfs]
    dsimp only
    rw [hend, ite_eq_left (by simp)]
    simp
  · rw [ite_eq_right (by simp [byte, h0, hob]), hval (H - lo + 1) (by omega)]
    dsimp only
    rw [hend, ite_eq_left (by simp)]
    simp

/-- Before any member, every key is absent. -/
theorem fields_empty (a : ByteArray) (keys : Array ByteArray) :
    Fields a keys (Array.replicate keys.size ⟨.absent, 0, 0⟩) [] := by
  refine ⟨by simp, fun q hq => ?_⟩
  rw [getElem!_pos _ q (by simpa using hq), Array.getElem_replicate]
  rfl

/-- **`parseTop` is RFC 8259's**: it says malformed exactly when the bytes are no JSON text, and
for a text whose value is an object it reports, for each key (the keys distinct and ASCII), the
last member with that name, compared as code units: the span of its value and whether that is a
string or a number. -/
theorem parseTop_spec (a : ByteArray) (lo hi : Nat) (keys : Array ByteArray)
    (hd : (keys.toList.map bs).Nodup) (ha : ∀ k ∈ keys.toList, ∀ b ∈ bs k, b < 0x80) :
    match parseTop a lo hi keys with
    | .malformed => ¬ IsText (slice a lo hi)
    | .notObject => IsText (slice a lo hi) ∧ ∀ ms, ¬ IsObjectText (slice a lo hi) ms
    | .object fs => fs.size = keys.size ∧ ∃ ms, IsObjectText (slice a lo hi) ms ∧
        ∀ q (hq : q < keys.size), FieldIs a fs[q]! (member ms ((bs keys[q]).map (·.toNat))) := by
  cases hp : parseTop a lo hi keys with
  | malformed => exact fun h => parseTop_of_text keys h hp
  | notObject =>
    dsimp only
    rw [← slice_min a lo hi]
    have hH : min hi a.size ≤ a.size := Nat.min_le_right _ _
    unfold parseTop at hp
    generalize min hi a.size = H at hH hp ⊢
    dsimp only at hp
    split at hp
    · split at hp
      · cases hp
      · split at hp <;> cases hp
    rename_i hob
    split at hp
    · cases hp
    rename_i j hj
    split at hp
    · rename_i hend
      simp only [beq_iff_eq] at hend
      obtain ⟨j0, j1, hv⟩ := (scanValue_sound hH (keys := #[]) (by simp) (by simp) _).1 _ _ hj
      have i0 : lo ≤ skipWs a H lo := by rw [skipWs_eq_takeWhile a hH]; omega
      obtain ⟨-, -, iw, -⟩ := skipWs_facts hH (i := lo) (by omega)
      obtain ⟨-, -, jw, -⟩ := skipWs_facts hH j1
      rw [hend] at jw
      refine ⟨⟨_, _, _, ?_, iw, hv, jw⟩, fun ms ⟨w₁, v, w₂, ht, hw₁, ho, hw₂⟩ => hob ?_⟩
      · rw [slice_split a i0 (by omega : skipWs a H lo ≤ H), slice_split a (Nat.le_of_lt j0) j1]
        simp only [List.append_assoc]
      · obtain ⟨hs, hsl, -, -⟩ := text_value hH ht hw₁ (.obj ho) hw₂
        obtain ⟨b, vr, hvb, hb⟩ := isValue_cases (.obj ho)
        have h0 : b = 0x7b := by
          rcases hb with ⟨rfl, us, hus⟩ | ⟨hb, neg, m, e, hn⟩ | ⟨rfl, hv'⟩ | ⟨rfl, hv'⟩ | ⟨rfl, hv'⟩ | ⟨rfl, -⟩ |
            ⟨rfl, ha'⟩
          · obtain ⟨c, rfl, -⟩ := hus; cases ho <;> simp at hvb
          · obtain ⟨c, r', hc, hc'⟩ := hn.head
            rw [hvb] at hc; simp only [List.cons.injEq] at hc; rw [← hc.1] at hc'
            cases ho <;> simp at hvb <;> (rw [← hvb.1] at hc'; rcases hc' with h | h; · simp at h
                                          · have := isDigit_toNat h; simp at this)
          · subst hv'; cases ho <;> simp at hvb
          · subst hv'; cases ho <;> simp at hvb
          · subst hv'; cases ho <;> simp at hvb
          · rfl
          · cases ho <;> cases ha' <;> simp at hvb
        subst h0
        obtain ⟨hi0, h00, -⟩ := slice_eq_cons hH (show slice a (lo + w₁.length) H = 0x7b :: (vr ++ w₂) by
          rw [hsl, hvb]; simp)
        rw [hs]; simp [byte, h00, hi0]
    · cases hp
  | object fs =>
    dsimp only
    rw [← slice_min a lo hi]
    have hH : min hi a.size ≤ a.size := Nat.min_le_right _ _
    unfold parseTop at hp
    generalize min hi a.size = H at hH hp ⊢
    dsimp only at hp
    split at hp
    · rename_i hob
      simp only [Bool.and_eq_true, decide_eq_true_eq, beq_iff_eq, byte] at hob
      split at hp
      · cases hp
      rename_i j fs₀ hj
      split at hp
      · rename_i hend
        simp only [beq_iff_eq] at hend
        simp only [Top.object.injEq] at hp
        subst hp
        have i0 : lo ≤ skipWs a H lo := by rw [skipWs_eq_takeWhile a hH]; omega
        obtain ⟨-, -, iw, -⟩ := skipWs_facts hH (i := lo) (by omega)
        obtain ⟨s0, s1, sw, -⟩ := skipWs_facts hH (i := skipWs a H lo + 1) (by omega)
        obtain ⟨j0, j1, hm⟩ := (scanValue_sound hH hd ha _).2.1 _ true _ j fs₀ hj
        obtain ⟨-, -, jw, -⟩ := skipWs_facts hH j1
        rw [hend] at jw
        have hsl : slice a lo H = slice a lo (skipWs a H lo) ++
            (0x7b :: slice a (skipWs a H lo + 1) (skipWs a H (skipWs a H lo + 1)) ++
              slice a (skipWs a H (skipWs a H lo + 1)) j) ++ slice a j H := by
          rw [slice_split a i0 (by omega : skipWs a H lo ≤ H),
            slice_split a (by omega : skipWs a H lo ≤ j) j1, slice_cons a (by omega : skipWs a H lo < j) (by omega),
            hob.2, slice_split a s0 (by omega : skipWs a H (skipWs a H lo + 1) ≤ j)]
          simp only [List.cons_append, List.append_assoc]
        rcases hm with ⟨-, hr, rfl⟩ | ⟨m, ms, w, hm, hw, hr, hf⟩
        · refine ⟨by simp, [], ⟨_, _, _, hsl, iw, ?_, jw⟩, (fields_empty a keys).2⟩
          rw [hr]; exact .empty sw
        · have hf' := hf [] (fields_empty a keys)
          refine ⟨hf'.1, ms, ⟨_, _, _, hsl, iw, ?_, jw⟩, hf'.2⟩
          rw [hr]; simpa only [List.append_assoc] using IsObject.members sw hm hw
      · cases hp
    · split at hp
      · cases hp
      · split at hp <;> cases hp

/-- info: 'Feed.Json.parseTop_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Feed.Json.parseTop_spec

/-! ## One reading of a text -/

/-- Whitespace before a byte that is not whitespace is determined. -/
theorem ws_det {w w' r r' : List UInt8} (hw : Ws w) (hw' : Ws w') (hr : ∀ b ∈ r.head?, ¬ IsWs b)
    (hr' : ∀ b ∈ r'.head?, ¬ IsWs b) (h : w ++ r = w' ++ r') : w = w' := by
  have e1 := takeWhile_run (p := isWs) (fun b hb => (isWs_iff b).mpr (hw b hb))
    (fun b hb => by rw [← Bool.not_eq_true, isWs_iff]; exact hr b hb)
  have e2 := takeWhile_run (p := isWs) (fun b hb => (isWs_iff b).mpr (hw' b hb))
    (fun b hb => by rw [← Bool.not_eq_true, isWs_iff]; exact hr' b hb)
  rw [← e1, ← e2, h]

/-- A value's text is determined by what follows it, when that cannot continue a number. -/
theorem value_det {v v' r r' : List UInt8} (hv : IsValue v) (hv' : IsValue v') (hr : NumEnd r) (hr' : NumEnd r')
    (h : v ++ r = v' ++ r') : v = v' := by
  have hs : slice ⟨(v ++ r).toArray⟩ 0 (ByteArray.size ⟨(v ++ r).toArray⟩) = v ++ r := by
    rw [slice_all, bs_mk]
  have e1 := (scanValue_complete (Nat.le_refl _) (v.length + v'.length)).1 0 v r hv hs hr (by omega)
  have e2 := (scanValue_complete (Nat.le_refl _) (v.length + v'.length)).1 0 v' r' hv' (hs.trans h) hr' (by omega)
  rw [e1, Option.some.injEq] at e2
  have := congrArg (List.take v.length) h
  rwa [List.take_left, show v.length = v'.length by omega, List.take_left] at this

/-- A string's text is determined: it ends at the first quote that is not escaped. -/
theorem string_det {k k' r r' : List UInt8} {us us' : List Nat} (hk : IsString k us) (hk' : IsString k' us')
    (h : k ++ r = k' ++ r') : k = k' := by
  have hs : slice ⟨(k ++ r).toArray⟩ 0 (ByteArray.size ⟨(k ++ r).toArray⟩) = k ++ r := by
    rw [slice_all, bs_mk]
  have e1 := scanString_complete (Nat.le_refl _) hs hk
  have e2 := scanString_complete (Nat.le_refl _) (hs.trans h) hk'
  rw [e1, Option.some.injEq] at e2
  have := congrArg (List.take k.length) h
  rwa [List.take_left, show k.length = k'.length by omega, List.take_left] at this

theorem not_ws_head {l t : List UInt8} (h : ∃ b r, l = b :: r ∧ ¬ IsWs b) : ∀ b ∈ (l ++ t).head?, ¬ IsWs b := by
  obtain ⟨b, r, rfl, hb⟩ := h
  intro c hc; simp at hc; rw [← hc]; exact hb

theorem not_ws_cons {b : UInt8} {t : List UInt8} (hb : b = 0x7d ∨ b = 0x5d ∨ b = 0x2c ∨ b = 0x3a ∨ b = 0x22) :
    ∀ c ∈ (b :: t).head?, ¬ IsWs c := by
  intro c hc; simp at hc; rw [← hc]; exact not_ws_punct hb

theorem value_not_ws {v t : List UInt8} (hv : IsValue v) : ∀ b ∈ (v ++ t).head?, ¬ IsWs b := by
  obtain ⟨b, r, hvb, hb⟩ := hv.head_ne
  exact not_ws_head ⟨b, r, hvb, hb.1⟩

theorem members_not_ws {m t : List UInt8} {ms : List (List Nat × List UInt8)} (hm : IsMembers m ms) :
    ∀ b ∈ (m ++ t).head?, ¬ IsWs b := by
  obtain ⟨r, rfl⟩ := hm.head
  exact not_ws_head ⟨0x22, r, rfl, not_ws_punct (by simp)⟩

/-- The first member of an object, and what follows it, has one reading. -/
theorem member_det {k k' w₁ w₁' w₂ w₂' v v' t t' : List UInt8} {us us' : List Nat}
    (hk : IsString k us) (hk' : IsString k' us') (hw₁ : Ws w₁) (hw₁' : Ws w₁') (hw₂ : Ws w₂) (hw₂' : Ws w₂')
    (hv : IsValue v) (hv' : IsValue v') (ht : NumEnd t) (ht' : NumEnd t')
    (h : k ++ w₁ ++ [0x3a] ++ w₂ ++ v ++ t = k' ++ w₁' ++ [0x3a] ++ w₂' ++ v' ++ t') :
    k = k' ∧ us = us' ∧ w₁ = w₁' ∧ w₂ = w₂' ∧ v = v' ∧ t = t' := by
  simp only [List.append_assoc, List.singleton_append] at h
  obtain rfl := string_det hk hk' h
  obtain rfl := hk.unique hk'
  have h := List.append_cancel_left h
  obtain rfl := ws_det hw₁ hw₁' (not_ws_cons (by simp)) (not_ws_cons (by simp)) h
  have h := List.cons.inj (List.append_cancel_left h) |>.2
  obtain rfl := ws_det hw₂ hw₂' (value_not_ws hv) (value_not_ws hv') h
  have h := List.append_cancel_left h
  obtain rfl := value_det hv hv' ht ht' h
  exact ⟨rfl, rfl, rfl, rfl, rfl, List.append_cancel_left h⟩

/-- Members followed by whitespace and a closing brace have one reading. -/
theorem members_det : ∀ {m : List UInt8} {ms : List (List Nat × List UInt8)}, IsMembers m ms →
    ∀ {m' : List UInt8} {ms' : List (List Nat × List UInt8)} {w w' r r' : List UInt8}, IsMembers m' ms' → Ws w →
      Ws w' → m ++ w ++ 0x7d :: r = m' ++ w' ++ 0x7d :: r' → m = m' ∧ ms = ms'
  | _, _, .one hk hw₁ hw₂ hv, _, _, w, w', r, r', hm', hw, hw', h => by
    cases hm' with
    | one hk' hw₁' hw₂' hv' =>
      obtain ⟨rfl, rfl, rfl, rfl, rfl, -⟩ := member_det hk hk' hw₁ hw₁' hw₂ hw₂' hv hv'
        (t := w ++ 0x7d :: r) (t' := w' ++ 0x7d :: r')
        (numEnd_ws hw (numEnd_punct (by simp))) (numEnd_ws hw' (numEnd_punct (by simp)))
        (by simpa only [List.append_assoc] using h)
      exact ⟨rfl, rfl⟩
    | cons hk' hw₁' hw₂' hv' hw₃' hw₄' hm' =>
      rename_i k' us' w₁' w₂' v' w₃' w₄' m' ms'
      obtain ⟨-, -, -, -, -, ht⟩ := member_det hk hk' hw₁ hw₁' hw₂ hw₂' hv hv'
        (t := w ++ 0x7d :: r) (t' := w₃' ++ 0x2c :: (w₄' ++ m' ++ w' ++ 0x7d :: r'))
        (numEnd_ws hw (numEnd_punct (by simp))) (numEnd_ws hw₃' (numEnd_punct (by simp)))
        (by simpa only [List.append_assoc, List.cons_append, List.nil_append] using h)
      obtain rfl := ws_det hw hw₃' (not_ws_cons (by simp)) (not_ws_cons (by simp)) ht
      simp at ht
  | _, _, .cons hk hw₁ hw₂ hv hw₃ hw₄ hm, _, _, w, w', r, r', hm', hw, hw', h => by
    rename_i k us w₁ w₂ v w₃ w₄ m ms _ _
    cases hm' with
    | one hk' hw₁' hw₂' hv' =>
      obtain ⟨-, -, -, -, -, ht⟩ := member_det hk hk' hw₁ hw₁' hw₂ hw₂' hv hv'
        (t := w₃ ++ 0x2c :: (w₄ ++ m ++ w ++ 0x7d :: r)) (t' := w' ++ 0x7d :: r')
        (numEnd_ws hw₃ (numEnd_punct (by simp))) (numEnd_ws hw' (numEnd_punct (by simp)))
        (by simpa only [List.append_assoc, List.cons_append, List.nil_append] using h)
      obtain rfl := ws_det hw₃ hw' (not_ws_cons (by simp)) (not_ws_cons (by simp)) ht
      simp at ht
    | cons hk' hw₁' hw₂' hv' hw₃' hw₄' hm' =>
      rename_i k' us' w₁' w₂' v' w₃' w₄' m' ms'
      obtain ⟨rfl, rfl, rfl, rfl, rfl, ht⟩ := member_det hk hk' hw₁ hw₁' hw₂ hw₂' hv hv'
        (t := w₃ ++ 0x2c :: (w₄ ++ (m ++ (w ++ 0x7d :: r))))
        (t' := w₃' ++ 0x2c :: (w₄' ++ (m' ++ (w' ++ 0x7d :: r'))))
        (numEnd_ws hw₃ (numEnd_punct (by simp))) (numEnd_ws hw₃' (numEnd_punct (by simp)))
        (by simpa only [List.append_assoc, List.cons_append, List.nil_append] using h)
      obtain rfl := ws_det hw₃ hw₃' (not_ws_cons (by simp)) (not_ws_cons (by simp)) ht
      have ht := (List.cons.inj (List.append_cancel_left ht)).2
      obtain rfl := ws_det hw₄ hw₄' (members_not_ws hm) (members_not_ws hm') ht
      obtain ⟨rfl, rfl⟩ := members_det hm hm' hw hw'
        (by simpa only [List.append_assoc] using List.append_cancel_left ht)
      exact ⟨rfl, rfl⟩

/-- An object has one reading. -/
theorem object_det {v v' : List UInt8} {ms ms' : List (List Nat × List UInt8)} (h : IsObject v ms)
    (h' : IsObject v' ms') (he : v = v') : ms = ms' := by
  cases h with
  | empty hw =>
    cases h' with
    | empty => rfl
    | members hw₁ hm hw₂ =>
      rename_i w w₁ m w₂
      simp only [List.cons_append, List.cons.injEq, List.append_assoc, true_and] at he
      obtain rfl := ws_det hw hw₁ (not_ws_cons (by simp)) (members_not_ws hm) he
      obtain ⟨r, rfl⟩ := hm.head
      simp at he
  | members hw₁ hm hw₂ =>
    rename_i w₁ m w₂
    cases h' with
    | empty hw =>
      rename_i w
      simp only [List.cons_append, List.cons.injEq, List.append_assoc, true_and] at he
      obtain rfl := ws_det hw₁ hw (members_not_ws hm) (not_ws_cons (by simp)) he
      obtain ⟨r, rfl⟩ := hm.head
      simp at he
    | members hw₁' hm' hw₂' =>
      rename_i w₁' m' w₂'
      simp only [List.cons_append, List.cons.injEq, List.append_assoc, true_and] at he
      obtain rfl := ws_det hw₁ hw₁' (members_not_ws hm) (members_not_ws hm') he
      exact (members_det hm hm' hw₂ hw₂' (r := []) (r' := [])
        (by simpa only [List.append_assoc] using List.append_cancel_left he)).2

/-- **An object text has one reading**: its text determines its members (names and values, in
order). -/
theorem _root_.Feed.Spec.Json.IsObjectText.unique {t : List UInt8} {ms ms' : List (List Nat × List UInt8)}
    (h : IsObjectText t ms) (h' : IsObjectText t ms') : ms = ms' := by
  obtain ⟨w₁, v, w₂, rfl, hw₁, ho, hw₂⟩ := h
  obtain ⟨w₁', v', w₂', he, hw₁', ho', hw₂'⟩ := h'
  have hv := IsValue.obj ho
  have hv' := IsValue.obj ho'
  simp only [List.append_assoc] at he
  obtain rfl := ws_det hw₁ hw₁' (value_not_ws hv) (value_not_ws hv') he
  exact object_det ho ho' (value_det hv hv' (numEnd_of_ws hw₂) (numEnd_of_ws hw₂') (List.append_cancel_left he))

/-- info: 'Feed.Spec.Json.IsObjectText.unique' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Feed.Spec.Json.IsObjectText.unique

/-- An object text is a JSON text. -/
theorem _root_.Feed.Spec.Json.IsObjectText.isText {t : List UInt8} {ms : List (List Nat × List UInt8)}
    (h : IsObjectText t ms) : IsText t := by
  obtain ⟨w₁, v, w₂, rfl, hw₁, ho, hw₂⟩ := h
  exact ⟨w₁, v, w₂, rfl, hw₁, .obj ho, hw₂⟩

/-! ## A text is UTF-8 -/

/-- The bytes are the UTF-8 of scalar values. -/
def IsUtf8 (t : List UInt8) : Prop := ∃ cs, (∀ c ∈ cs, IsScalar c) ∧ t = encode cs

theorem IsUtf8.append {s t : List UInt8} (hs : IsUtf8 s) (ht : IsUtf8 t) : IsUtf8 (s ++ t) := by
  obtain ⟨cs, hcs, rfl⟩ := hs
  obtain ⟨ds, hds, rfl⟩ := ht
  exact ⟨cs ++ ds, fun c hc => (List.mem_append.mp hc).elim (hcs c) (hds c), (encode_append cs ds).symm⟩

theorem isUtf8_ascii {t : List UInt8} (h : ∀ b ∈ t, b < 0x80) : IsUtf8 t := by
  refine ⟨t.map UInt8.toNat, fun c hc => ?_, (encode_ascii h).symm⟩
  obtain ⟨b, hb, rfl⟩ := List.mem_map.mp hc
  exact ascii_isScalar (by have := h b hb; simpa [UInt8.lt_iff_toNat_lt] using this)

theorem isUtf8_ws {w : List UInt8} (hw : Ws w) : IsUtf8 w :=
  isUtf8_ascii fun b hb => by
    have := isWs_toNat (hw b hb)
    simp only [UInt8.lt_iff_toNat_lt, UInt8.reduceToNat]; omega

mutual
theorem isValue_utf8 : ∀ {v : List UInt8}, IsValue v → IsUtf8 v
  | _, .str h => h.utf8
  | _, .num h => isUtf8_ascii h.ascii
  | _, .tru => isUtf8_ascii (by decide)
  | _, .fls => isUtf8_ascii (by decide)
  | _, .null => isUtf8_ascii (by decide)
  | _, .obj h => isObject_utf8 h
  | _, .arr h => isArray_utf8 h

theorem isObject_utf8 : ∀ {v : List UInt8} {ms : List (List Nat × List UInt8)}, IsObject v ms → IsUtf8 v
  | _, _, .empty hw =>
    ((isUtf8_ascii (by decide) (t := [0x7b])).append (isUtf8_ws hw)).append (isUtf8_ascii (by decide))
  | _, _, .members hw₁ hm hw₂ =>
    ((((isUtf8_ascii (by decide) (t := [0x7b])).append (isUtf8_ws hw₁)).append (isMembers_utf8 hm)).append
      (isUtf8_ws hw₂)).append (isUtf8_ascii (by decide))

theorem isMembers_utf8 : ∀ {m : List UInt8} {ms : List (List Nat × List UInt8)}, IsMembers m ms → IsUtf8 m
  | _, _, .one hk hw₁ hw₂ hv =>
    ((((show IsUtf8 _ from hk.utf8).append (isUtf8_ws hw₁)).append (isUtf8_ascii (by decide))).append
      (isUtf8_ws hw₂)).append (isValue_utf8 hv)
  | _, _, .cons hk hw₁ hw₂ hv hw₃ hw₄ hm =>
    ((((((((show IsUtf8 _ from hk.utf8).append (isUtf8_ws hw₁)).append (isUtf8_ascii (by decide))).append
      (isUtf8_ws hw₂)).append (isValue_utf8 hv)).append (isUtf8_ws hw₃)).append (isUtf8_ascii (by decide))).append
      (isUtf8_ws hw₄)).append (isMembers_utf8 hm)

theorem isArray_utf8 : ∀ {v : List UInt8}, IsArray v → IsUtf8 v
  | _, .empty hw => ((isUtf8_ascii (by decide) (t := [0x5b])).append (isUtf8_ws hw)).append (isUtf8_ascii (by decide))
  | _, .elems hw₁ he hw₂ =>
    ((((isUtf8_ascii (by decide) (t := [0x5b])).append (isUtf8_ws hw₁)).append (isElems_utf8 he)).append
      (isUtf8_ws hw₂)).append (isUtf8_ascii (by decide))

theorem isElems_utf8 : ∀ {e : List UInt8}, IsElems e → IsUtf8 e
  | _, .one hv => isValue_utf8 hv
  | _, .cons hv hw₁ hw₂ he =>
    ((((isValue_utf8 hv).append (isUtf8_ws hw₁)).append (isUtf8_ascii (by decide))).append (isUtf8_ws hw₂)).append
      (isElems_utf8 he)
end

/-- **A JSON text is UTF-8** (RFC 8259 §8.1): the UTF-8 of some scalar values. -/
theorem _root_.Feed.Spec.Json.IsText.utf8 {t : List UInt8} (h : IsText t) :
    ∃ cs, (∀ c ∈ cs, IsScalar c) ∧ t = encode cs := by
  obtain ⟨w₁, v, w₂, rfl, hw₁, hv, hw₂⟩ := h
  exact ((isUtf8_ws hw₁).append (isValue_utf8 hv)).append (isUtf8_ws hw₂)

/-- info: 'Feed.Spec.Json.IsText.utf8' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Feed.Spec.Json.IsText.utf8

end Feed.Json
