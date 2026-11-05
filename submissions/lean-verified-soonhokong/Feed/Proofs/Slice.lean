import Feed.Proofs.Route

/-!
# Byte ranges

Lemmas on `slice` and on the byte searches of `Feed/Bytes.lean`, shared by the proofs about the
HTTP, JSON and token code (`Feed/Proofs/Route.lean` has the first of them): ranges cut and joined,
and loops that step over a range while each byte passes a test, which stop where the range's
bytes stop passing it (`scan_while`, `run_eq`).
-/
namespace Feed
open Spec

/-- A range with its end clamped to the array has the same bytes. -/
theorem slice_min (a : ByteArray) (lo hi : Nat) : slice a lo (min hi a.size) = slice a lo hi := by
  have hs : a.data.toList.length = a.size := by simp
  apply List.ext_getElem?
  intro k
  simp only [slice, List.getElem?_take, List.getElem?_drop]
  by_cases hk : k < hi - lo
  · by_cases hk2 : k < min hi a.size - lo
    · rw [ite_eq_left hk, ite_eq_left hk2]
    · rw [ite_eq_left hk, ite_eq_right hk2, List.getElem?_eq_none (by omega)]
  · rw [ite_eq_right hk, ite_eq_right (by omega)]

theorem findByte_go_eq (a : ByteArray) (b : UInt8) (hi : Nat) :
    ∀ f i, i + f = min hi a.size →
      Bytes.findByte.go a b hi i f = i + (slice a i (min hi a.size)).findIdx (· == b) := by
  intro f
  induction f with
  | zero => intro i h; simp [Bytes.findByte.go, ← h, slice_empty]
  | succ f ih =>
    intro i h
    rw [slice_cons a (by omega) (Nat.min_le_right _ _), List.findIdx_cons, Bytes.findByte.go]
    by_cases hb : (a.get! i == b) = true
    · rw [ite_eq_left hb, hb]; rfl
    · rw [ite_eq_right hb, ih (i + 1) (by omega)]
      rw [Bool.not_eq_true] at hb
      simp only [hb, Bool.false_eq_true, ↓reduceIte]
      omega

theorem findByte_go_first (a : ByteArray) (b : UInt8) (hi : Nat) :
    ∀ f i, i + f = min hi a.size →
      i ≤ Bytes.findByte.go a b hi i f ∧ Bytes.findByte.go a b hi i f ≤ min hi a.size ∧
      (∀ m, i ≤ m → m < Bytes.findByte.go a b hi i f → a.get! m ≠ b) ∧
      (Bytes.findByte.go a b hi i f < min hi a.size → a.get! (Bytes.findByte.go a b hi i f) = b) := by
  intro f
  induction f with
  | zero =>
    intro i h
    simp only [Bytes.findByte.go]
    exact ⟨by omega, Nat.le_refl _, fun m h1 h2 => by omega, fun h => by omega⟩
  | succ f ih =>
    intro i h
    simp only [Bytes.findByte.go]
    by_cases hb : (a.get! i == b) = true
    · rw [ite_eq_left hb]
      exact ⟨Nat.le_refl _, by omega, fun m h1 h2 => by omega, fun _ => by simpa using hb⟩
    · rw [ite_eq_right hb]
      obtain ⟨h1, h2, h3, h4⟩ := ih (i + 1) (by omega)
      refine ⟨by omega, h2, fun m hm1 hm2 => ?_, h4⟩
      rcases Nat.eq_or_lt_of_le hm1 with rfl | hlt
      · simpa using hb
      · exact h3 m (by omega) hm2

/-- `findByte` stops at the first `b` of the range, or at the range's end (clamped to the array). -/
theorem Bytes.findByte_first (a : ByteArray) (b : UInt8) {lo hi : Nat} (h : lo ≤ min hi a.size) :
    lo ≤ Bytes.findByte a b lo hi ∧ Bytes.findByte a b lo hi ≤ min hi a.size ∧
      (∀ m, lo ≤ m → m < Bytes.findByte a b lo hi → a.get! m ≠ b) ∧
      (Bytes.findByte a b lo hi < min hi a.size → a.get! (Bytes.findByte a b lo hi) = b) :=
  findByte_go_first a b hi _ lo (by omega)

/-- With the range empty, `findByte` is the range's end (clamped to the array). -/
theorem Bytes.findByte_past (a : ByteArray) (b : UInt8) {lo hi : Nat} (h : min hi a.size ≤ lo) :
    Bytes.findByte a b lo hi = min hi a.size := by
  unfold Bytes.findByte
  rw [show min hi a.size - lo = 0 by omega]
  rfl

/-- `findByte` is the position of the first `b` in the range, or the range's end. -/
theorem Bytes.findByte_eq (a : ByteArray) (b : UInt8) {lo hi : Nat} (h : lo ≤ min hi a.size) :
    Bytes.findByte a b lo hi = lo + (slice a lo hi).findIdx (· == b) := by
  unfold Bytes.findByte
  rw [findByte_go_eq a b hi _ lo (by omega), slice_min]

/-- info: 'Feed.Bytes.findByte_eq' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Bytes.findByte_eq

/-! ## Ranges cut and joined -/

theorem slice_append (a : ByteArray) {lo mid hi : Nat} (h₁ : lo ≤ mid) (h₂ : mid ≤ hi) :
    slice a lo hi = slice a lo mid ++ slice a mid hi := by
  simp only [slice]
  rw [show hi - lo = (mid - lo) + (hi - mid) by omega, List.take_add, List.drop_drop,
    show lo + (mid - lo) = mid by omega]

/-- The bytes of `a` from `i` on, cut as `l ++ r` up to `hi`. -/
theorem slice_cut (a : ByteArray) {i hi : Nat} {l r : List UInt8} (hih : i ≤ hi) (h' : hi ≤ a.size)
    (h : slice a i hi = l ++ r) :
    i + l.length ≤ hi ∧ slice a i (i + l.length) = l ∧ slice a (i + l.length) hi = r := by
  have hlen := slice_length a (lo := i) h'
  rw [h, List.length_append] at hlen
  have hle : i + l.length ≤ hi := by omega
  refine ⟨hle, ?_, ?_⟩
  · rw [← slice_take a (lo := i) (hi := hi) _ hle, h, List.take_left' rfl]
  · rw [← slice_drop a (lo := i) (hi := hi) _ hle, h, List.drop_left' rfl]

theorem drop_eq_slice (a : ByteArray) (pos : Nat) : (bs a).drop pos = slice a pos a.size := by
  simp only [slice, bs]
  rw [List.take_of_length_le]
  simp only [List.length_drop, Array.length_toList]
  have : a.data.size = a.size := rfl
  omega

theorem take_drop_eq_slice (a : ByteArray) (pos n : Nat) : ((bs a).drop pos).take n = slice a pos (pos + n) := by
  simp only [slice, bs]
  rw [show pos + n - pos = n by omega]

theorem get!_past (a : ByteArray) {i : Nat} (h : a.size ≤ i) : a.get! i = 0 := by
  rw [get!_eq, List.getElem?_eq_none (by rw [← size_eq_length]; exact h)]
  rfl

theorem byte_lt {a : ByteArray} {i : Nat} {c : UInt8} (h : a.get! i = c) (hc : c ≠ 0) : i < a.size := by
  by_cases hi : i < a.size
  · exact hi
  · exact absurd (h.symm.trans (get!_past a (by omega))) hc

/-- A byte range, mapped bytewise, equals a list when they have the same length and agree at every
position. -/
theorem map_slice_eq_iff (a : ByteArray) (g : UInt8 → UInt8) {lo hi : Nat} (h' : hi ≤ a.size) (l : List UInt8) :
    (slice a lo hi).map g = l ↔ hi - lo = l.length ∧ ∀ k < l.length, g (a.get! (lo + k)) = l[k]?.getD 0 := by
  constructor
  · rintro rfl
    refine ⟨by rw [List.length_map, slice_length a h'], fun k hk => ?_⟩
    rw [List.length_map, slice_length a h'] at hk
    rw [List.getElem?_map, slice_getElem? a (by omega) h']
    rfl
  · rintro ⟨hlen, hk⟩
    apply List.ext_getElem?
    intro k
    rw [List.getElem?_map]
    by_cases hkl : k < l.length
    · rw [slice_getElem? a (by omega) h', Option.map_some, hk k hkl, List.getElem?_eq_getElem hkl]
      rfl
    · rw [List.getElem?_eq_none (by rw [slice_length a h']; omega), List.getElem?_eq_none (by omega)]
      rfl

/-! ## Runs of a list -/

theorem takeWhile_length_le {α : Type} (p : α → Bool) : ∀ l : List α, (l.takeWhile p).length ≤ l.length
  | [] => Nat.le_refl _
  | x :: l => by
    rw [List.takeWhile_cons]
    split
    · simp only [List.length_cons]; have := takeWhile_length_le p l; omega
    · simp

theorem take_takeWhile {α : Type} (p : α → Bool) : ∀ l : List α, l.take (l.takeWhile p).length = l.takeWhile p
  | [] => rfl
  | x :: l => by
    rw [List.takeWhile_cons]
    split
    · simp only [List.length_cons, List.take_succ_cons, take_takeWhile p l]
    · rfl

theorem drop_takeWhile {α : Type} (p : α → Bool) : ∀ l : List α, l.drop (l.takeWhile p).length = l.dropWhile p
  | [] => rfl
  | x :: l => by
    rw [List.takeWhile_cons, List.dropWhile_cons]
    split
    · simp only [List.length_cons, List.drop_succ_cons, drop_takeWhile p l]
    · rfl

theorem of_mem_takeWhile {α : Type} {p : α → Bool} {x : α} : ∀ {l : List α}, x ∈ l.takeWhile p → p x = true
  | [], h => by simp at h
  | y :: l, h => by
    rw [List.takeWhile_cons] at h
    split at h
    · rename_i hy
      rcases List.mem_cons.mp h with rfl | h
      · exact hy
      · exact of_mem_takeWhile h
    · simp at h

theorem mem_of_mem_dropWhile {α : Type} {p : α → Bool} {x : α} : ∀ {l : List α}, x ∈ l.dropWhile p → x ∈ l
  | [], h => h
  | y :: l, h => by
    rw [List.dropWhile_cons] at h
    split at h
    · exact List.mem_cons_of_mem _ (mem_of_mem_dropWhile h)
    · exact h

theorem dropWhile_of_head {α : Type} {p : α → Bool} : ∀ {l : List α}, (∀ c ∈ l.head?, p c = false) → l.dropWhile p = l
  | [], _ => rfl
  | y :: l, h => by
    rw [List.dropWhile_cons, ite_eq_right (by simp [h y rfl])]

theorem dropWhile_all {α : Type} {p : α → Bool} : ∀ {l : List α}, (∀ c ∈ l, p c = true) → l.dropWhile p = []
  | [], _ => rfl
  | y :: l, h => by
    rw [List.dropWhile_cons, ite_eq_left (h y List.mem_cons_self)]
    exact dropWhile_all fun c hc => h c (List.mem_cons_of_mem _ hc)

theorem head_dropWhile {α : Type} (p : α → Bool) (l : List α) : ∀ c ∈ (l.dropWhile p).head?, p c = false := by
  intro c hc
  have := List.head?_dropWhile_not p l
  rw [Option.mem_def] at hc
  rw [hc] at this
  exact this

/-- Bytes up to a separator that is not among them are cut there in one way only. -/
theorem cancel_sep {x : UInt8} : ∀ {l g X Y : List UInt8}, x ∉ l → x ∉ g → l ++ x :: X = g ++ x :: Y → l = g ∧ X = Y
  | [], [], X, Y, _, _, h => by simp only [List.nil_append, List.cons.injEq, true_and] at h; exact ⟨rfl, h⟩
  | [], c :: g, X, Y, _, hg, h => by
    simp only [List.nil_append, List.cons_append, List.cons.injEq] at h
    exact absurd (h.1 ▸ List.mem_cons_self) hg
  | c :: l, [], X, Y, hl, _, h => by
    simp only [List.nil_append, List.cons_append, List.cons.injEq] at h
    exact absurd (h.1 ▸ List.mem_cons_self) hl
  | c :: l, d :: g, X, Y, hl, hg, h => by
    simp only [List.cons_append, List.cons.injEq] at h
    obtain ⟨rfl, h⟩ := h
    obtain ⟨h1, h2⟩ :=
      cancel_sep (fun hx => hl (List.mem_cons_of_mem _ hx)) (fun hx => hg (List.mem_cons_of_mem _ hx)) h
    exact ⟨by rw [h1], h2⟩

/-! ## Loops over a range -/

/-- A loop that steps forward while the byte at its position passes `p`, for at most `f` bytes,
stops at the first byte that does not. -/
theorem scan_while {a : ByteArray} (p : UInt8 → Bool) (g : Nat → Nat → Nat) (h0 : ∀ i, g i 0 = i)
    (hs : ∀ i f, g i (f + 1) = if p (a.get! i) then g (i + 1) f else i) :
    ∀ f i, i + f ≤ a.size → g i f = i + ((slice a i (i + f)).takeWhile p).length := by
  intro f
  induction f with
  | zero => intro i _; rw [h0, Nat.add_zero, slice_empty]; rfl
  | succ f ih =>
    intro i hf
    rw [hs, slice_cons a (by omega) hf, List.takeWhile_cons]
    by_cases hp : p (a.get! i) = true
    · rw [ite_eq_left hp, ite_eq_left hp, ih (i + 1) (by omega), show i + 1 + f = i + (f + 1) by omega]
      simp only [List.length_cons]
      omega
    · rw [ite_eq_right hp, ite_eq_right hp]
      rfl

/-- `scan_while` on a range: `g i (hi - i)` is `i` plus the length of the run. -/
theorem scan_while_slice {a : ByteArray} (p : UInt8 → Bool) (g : Nat → Nat → Nat) (h0 : ∀ i, g i 0 = i)
    (hs : ∀ i f, g i (f + 1) = if p (a.get! i) then g (i + 1) f else i) {i hi : Nat} (h : hi ≤ a.size) :
    g i (hi - i) = i + ((slice a i hi).takeWhile p).length := by
  by_cases hle : i ≤ hi
  · rw [scan_while p g h0 hs (hi - i) i (by omega), show i + (hi - i) = hi by omega]
  · rw [show hi - i = 0 by omega, h0]
    simp [slice, show hi - i = 0 by omega]

/-- A loop that checks each byte of a range. -/
theorem all_while {a : ByteArray} (p : UInt8 → Bool) (g : Nat → Nat → Bool) (h0 : ∀ i, g i 0 = true)
    (hs : ∀ i f, g i (f + 1) = (p (a.get! i) && g (i + 1) f)) :
    ∀ f i, i + f ≤ a.size → g i f = (slice a i (i + f)).all p := by
  intro f
  induction f with
  | zero => intro i _; rw [h0, Nat.add_zero, slice_empty]; rfl
  | succ f ih =>
    intro i hf
    rw [hs, slice_cons a (by omega) hf, List.all_cons, ih (i + 1) (by omega), show i + 1 + f = i + (f + 1) by omega]

/-- The bytes of a run, and those after it. -/
theorem slice_takeWhile (a : ByteArray) (p : UInt8 → Bool) {i hi : Nat} (h : hi ≤ a.size) :
    slice a i (i + ((slice a i hi).takeWhile p).length) = (slice a i hi).takeWhile p ∧
      slice a (i + ((slice a i hi).takeWhile p).length) hi = (slice a i hi).dropWhile p := by
  by_cases hle : hi ≤ i
  · have he : slice a i hi = [] := by simp [slice, show hi - i = 0 by omega]
    simp [he, slice_empty]
  have hlen := takeWhile_length_le p (slice a i hi)
  have hsl := slice_length a (lo := i) h
  constructor
  · rw [← slice_take a (lo := i) (hi := hi) ((slice a i hi).takeWhile p).length (by omega), take_takeWhile]
  · rw [← slice_drop a (lo := i) (hi := hi) ((slice a i hi).takeWhile p).length (by omega), drop_takeWhile]

/-- The bytes of a run pass the test. -/
theorem run_all (a : ByteArray) (p : UInt8 → Bool) {i hi : Nat} (h : hi ≤ a.size) :
    ∀ c ∈ slice a i (i + ((slice a i hi).takeWhile p).length), p c = true := by
  rw [(slice_takeWhile a p h).1]
  exact fun _ hc => of_mem_takeWhile hc

theorem run_le (a : ByteArray) (p : UInt8 → Bool) {i hi : Nat} (h : hi ≤ a.size) (hle : i ≤ hi) :
    i + ((slice a i hi).takeWhile p).length ≤ hi := by
  have := takeWhile_length_le p (slice a i hi)
  rw [slice_length a h] at this
  omega

/-- A run that passes the test up to `j` and stops there (or at the range's end) ends at `j`. -/
theorem run_eq (a : ByteArray) (p : UInt8 → Bool) {i j hi : Nat} (h : hi ≤ a.size) (hij : i ≤ j) (hj : j ≤ hi)
    (hp : ∀ c ∈ slice a i j, p c = true) (hq : j < hi → p (a.get! j) = false) :
    i + ((slice a i hi).takeWhile p).length = j := by
  rw [slice_append a hij hj, List.takeWhile_append_of_pos hp, List.length_append, slice_length a (by omega)]
  by_cases hlt : j < hi
  · rw [slice_cons a hlt h, List.takeWhile_cons, ite_eq_right (by rw [hq hlt]; decide)]
    simp; omega
  · rw [show hi = j by omega, slice_empty]
    simp; omega

end Feed
