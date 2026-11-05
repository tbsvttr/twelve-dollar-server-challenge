import Feed.Spec.Uri
import Feed.Proofs.Slice

/-!
# Request-targets and Host

The deciders `Http.parse` uses for the Host value and the request-target, `Http.hostOk` and
`Http.target` (`Feed/Http.lean`), against the grammar of `Feed/Spec/Uri.lean`:

* `Http.hostOk_iff`: `hostOk` accepts a range exactly when it is a Host value,
  `uri-host [ ":" port ]` (RFC 9110 §7.2, RFC 3986 §3.2.2); `Http.hostEnd_some` and
  `Http.hostEnd_of` say where `hostEnd` ends the host.
* `Http.target_spec`: `target` gives a path for a range exactly when it is a request-target of
  `Spec.Http.TargetPath` (RFC 9112 §3.2), and the path is the target's: an origin-form's absolute
  path, an http or https absolute-form's path, the empty path of the asterisk-form, the
  authority-form and URIs of other schemes. It is `Http.target_some` and `Http.target_complete`
  together.
* `Spec.Http.targetPath_unique`: a target has one path. It follows from `target_complete`, since
  `target` is a function.
* `Http.hostOk_vectors`, `Http.target_vectors`: examples of each form and of values that are none,
  among them RFC 4291's IPv6 addresses, through these theorems and the kernel's evaluation of the
  deciders.

The proofs split where the deciders split, at the grammar's alternatives: `hostEnd` on an
IP-literal or a reg-name, `ipLiteral` on IPvFuture or IPv6, `ipv6` on a "::" or none (`groups`
counts the groups on each side, an IPv4 address as two), and `target` on the origin-form, the
http and https absolute-form (`absolutePath`), then the asterisk-form, the authority-form and the
other schemes (`otherScheme`, `hierPart`, `authority`). Each delimiter that `findByte` finds is the
one where the grammar ends a part, because no part holds a byte that could end it: "]" ends an
IP-literal, ":" a reg-name and a scheme, "@" the userinfo, "/" an authority, "?" what comes before
the query. The code's byte classes, as the masks of `Http.inSet`, and the 256 values of
`dec-octet` are checked by `decide +kernel`.
-/
namespace Feed.Uri
open Spec Spec.Http

/-! ## Byte ranges and lists -/

private theorem slice_nil_of_le (a : ByteArray) {lo hi : Nat} (h : hi ≤ lo) : slice a lo hi = [] := by
  simp [slice, Nat.sub_eq_zero_of_le h]

private theorem slice_append (a : ByteArray) {lo m hi : Nat} (h₁ : lo ≤ m) (h₂ : m ≤ hi) :
    slice a lo hi = slice a lo m ++ slice a m hi := by
  have ht := slice_take a (lo := lo) (hi := hi) (m - lo) (by omega)
  have hd := slice_drop a (lo := lo) (hi := hi) (m - lo) (by omega)
  rw [Nat.add_sub_cancel' h₁] at ht hd
  rw [← ht, ← hd, List.take_append_drop]

private theorem slice_cons_iff (a : ByteArray) {i hi : Nat} (h' : hi ≤ a.size) {c : UInt8} {r : List UInt8} :
    slice a i hi = c :: r ↔ i < hi ∧ a.get! i = c ∧ slice a (i + 1) hi = r := by
  constructor
  · intro hs
    have hi' : i < hi := by
      refine Nat.lt_of_not_le fun hn => ?_
      rw [slice_nil_of_le a hn] at hs
      exact List.cons_ne_nil _ _ hs.symm
    rw [slice_cons a hi' h'] at hs
    exact ⟨hi', (List.cons.inj hs).1, (List.cons.inj hs).2⟩
  · rintro ⟨hi', rfl, rfl⟩
    exact slice_cons a hi' h'

private theorem slice_append_iff (a : ByteArray) {i hi : Nat} (h : i ≤ hi) (h' : hi ≤ a.size)
    {x y : List UInt8} :
    slice a i hi = x ++ y ↔ i + x.length ≤ hi ∧ slice a i (i + x.length) = x ∧ slice a (i + x.length) hi = y := by
  constructor
  · intro hs
    have hl := slice_length a (lo := i) h'
    rw [hs, List.length_append] at hl
    refine ⟨by omega, ?_, ?_⟩
    · rw [← slice_take a (lo := i) (hi := hi) x.length (by omega), hs, List.take_left]
    · rw [← slice_drop a (lo := i) (hi := hi) x.length (by omega), hs, List.drop_left]
  · rintro ⟨hl, hx, hy⟩
    rw [slice_append a (m := i + x.length) (by omega) hl, hx, hy]

/-- A range ends with the first `b` after `lo`, or at `hi` when there is none. -/
private theorem findByte_cut (a : ByteArray) (b : UInt8) {lo hi : Nat} (h : lo ≤ hi) (h' : hi ≤ a.size) :
    lo ≤ Bytes.findByte a b lo hi ∧ Bytes.findByte a b lo hi ≤ hi ∧ b ∉ slice a lo (Bytes.findByte a b lo hi) ∧
      (Bytes.findByte a b lo hi < hi → a.get! (Bytes.findByte a b lo hi) = b) := by
  have hm : min hi a.size = hi := Nat.min_eq_left h'
  obtain ⟨h1, h2, h3, h4⟩ := Bytes.findByte_first a b (lo := lo) (hi := hi) (by omega)
  rw [hm] at h2 h4
  refine ⟨h1, h2, fun hb => ?_, h4⟩
  obtain ⟨k, hk, hkb⟩ := List.getElem_of_mem hb
  rw [slice_length a (by omega)] at hk
  have := slice_getElem? a (lo := lo) (hi := Bytes.findByte a b lo hi) (k := k) (by omega) (by omega)
  rw [List.getElem?_eq_getElem (by rw [slice_length a (by omega)]; omega), hkb] at this
  exact h3 (lo + k) (by omega) (by omega) (Option.some.inj this).symm

/-- `findByte` finds the first `b`. -/
private theorem findByte_of_eq (a : ByteArray) (b : UInt8) {lo hi : Nat} (h : lo ≤ hi) (h' : hi ≤ a.size)
    {x y : List UInt8} (hs : slice a lo hi = x ++ b :: y) (hx : b ∉ x) :
    Bytes.findByte a b lo hi = lo + x.length := by
  obtain ⟨h1, h2, h3, h4⟩ := findByte_cut a b h h'
  obtain ⟨hl, hsx, hsy⟩ := (slice_append_iff a h h').mp hs
  obtain ⟨hlt, hb, -⟩ := (slice_cons_iff a h').mp hsy
  generalize Bytes.findByte a b lo hi = e at h1 h2 h3 h4
  rcases Nat.lt_trichotomy e (lo + x.length) with he | he | he
  · rw [← hsx, slice_append a h1 (Nat.le_of_lt he)] at hx
    have := (slice_cons_iff a (by omega) (c := a.get! e) (r := slice a (e + 1) (lo + x.length))).mpr
      ⟨he, rfl, rfl⟩
    rw [this, h4 (by omega)] at hx
    exact absurd (List.mem_append_right _ List.mem_cons_self) hx
  · exact he
  · rw [slice_append a (m := lo + x.length) (by omega) (by omega), slice_cons a he (by omega), hb] at h3
    exact absurd (List.mem_append_right _ List.mem_cons_self) h3

/-- `findByte` reaches the end of a range without `b`. -/
private theorem findByte_of_not_mem (a : ByteArray) (b : UInt8) {lo hi : Nat} (h : lo ≤ hi) (h' : hi ≤ a.size)
    (hb : b ∉ slice a lo hi) : Bytes.findByte a b lo hi = hi :=
  (findByte_spec a b h h').mpr hb

/-- Two lists cut where `b` first occurs, or where they end. -/
private theorem cut_unique {b : UInt8} : ∀ {x x' y y' : List UInt8}, x ++ y = x' ++ y' → b ∉ x → b ∉ x' →
    (y = [] ∨ y.head? = some b) → (y' = [] ∨ y'.head? = some b) → x = x' ∧ y = y'
  | [], [], _, _, h, _, _, _, _ => ⟨rfl, by simpa using h⟩
  | [], c :: x', y, y', h, _, hx', hy, _ => by
    simp only [List.nil_append, List.cons_append] at h
    subst h
    rcases hy with hy | hy
    · exact absurd hy (List.cons_ne_nil _ _)
    · simp only [List.head?_cons, Option.some.injEq] at hy
      exact absurd (hy ▸ List.mem_cons_self) hx'
  | c :: x, [], y, y', h, hx, _, _, hy' => by
    simp only [List.nil_append, List.cons_append] at h
    subst h
    rcases hy' with hy' | hy'
    · exact absurd hy' (List.cons_ne_nil _ _)
    · simp only [List.head?_cons, Option.some.injEq] at hy'
      exact absurd (hy' ▸ List.mem_cons_self) hx
  | c :: x, c' :: x', y, y', h, hx, hx', hy, hy' => by
    simp only [List.cons_append, List.cons.injEq] at h
    obtain ⟨rfl, h⟩ := h
    obtain ⟨rfl, rfl⟩ := cut_unique h (fun hm => hx (List.mem_cons_of_mem _ hm))
      (fun hm => hx' (List.mem_cons_of_mem _ hm)) hy hy'
    exact ⟨rfl, rfl⟩

/-- The same, at an occurrence of `b`. -/
private theorem cut_unique' {b : UInt8} {x x' y y' : List UInt8} (h : x ++ b :: y = x' ++ b :: y') (hx : b ∉ x)
    (hx' : b ∉ x') : x = x' ∧ y = y' := by
  obtain ⟨h1, h2⟩ := cut_unique h hx hx' (Or.inr rfl) (Or.inr rfl)
  exact ⟨h1, (List.cons.inj h2).2⟩

/-! ## Characters

The byte classes of the code, as the masks of `Http.inSet` and the tests on one byte, are those of
`Feed/Spec/Uri.lean`; the kernel checks all 256 bytes. -/

private theorem reg_set : ∀ c : UInt8,
    Http.inSet Http.regLo Http.regHi c = (isUnreserved c || isSubDelim c || false) := by decide +kernel
private theorem path_set : ∀ c : UInt8, Http.inSet Http.pathLo Http.pathHi c =
    (isUnreserved c || isSubDelim c || (c == 0x3a || c == 0x40 || c == 0x2f)) := by decide +kernel
private theorem query_set : ∀ c : UInt8, Http.inSet Http.queryLo Http.queryHi c =
    (isUnreserved c || isSubDelim c || (c == 0x3a || c == 0x40 || c == 0x2f || c == 0x3f)) := by decide +kernel
private theorem user_set : ∀ c : UInt8,
    Http.inSet Http.userLo Http.userHi c = (isUnreserved c || isSubDelim c || c == 0x3a) := by decide +kernel
private theorem scheme_set : ∀ c : UInt8, Http.inSet Http.schemeLo Http.schemeHi c =
    (isAlpha c || isDigit c || (Spec.lit "+-.").contains c) := by decide +kernel
private theorem hex_eq : ∀ c : UInt8, Http.hex c = isHex c := by decide +kernel
private theorem digit_eq : ∀ c : UInt8, Http.digit c = isDigit c := by decide +kernel
private theorem alpha_eq : ∀ c : UInt8, Http.alpha c = isAlpha c := by decide +kernel
private theorem lower_eq : ∀ c : UInt8, Http.lower c = if 0x41 ≤ c ∧ c ≤ 0x5a then c + 32 else c := by
  decide +kernel

/-! ## The loops over a range -/

private theorem allIn_go (m0 m1 : UInt64) (a : ByteArray) : ∀ f i, i + f ≤ a.size →
    (Http.allIn.go m0 m1 a i f = true ↔ ∀ c ∈ slice a i (i + f), Http.inSet m0 m1 c = true) := by
  intro f
  induction f with
  | zero => intro i _; simp [Http.allIn.go, slice_empty]
  | succ f ih =>
    intro i h
    rw [Http.allIn.go, slice_cons a (by omega) h, Bool.and_eq_true, ih (i + 1) (by omega),
      show i + 1 + f = i + (f + 1) by omega, List.forall_mem_cons]
    rfl

private theorem allIn_iff (m0 m1 : UInt64) (a : ByteArray) {i hi : Nat} (h' : hi ≤ a.size) :
    Http.allIn m0 m1 a i hi = true ↔ ∀ c ∈ slice a i hi, Http.inSet m0 m1 c = true := by
  unfold Http.allIn
  by_cases h : i ≤ hi
  · rw [allIn_go m0 m1 a _ i (by omega), Nat.add_sub_cancel' h]
  · rw [show hi - i = 0 by omega, slice_nil_of_le a (by omega)]
    simp [Http.allIn.go]

private theorem allDigits_go (a : ByteArray) : ∀ f i, i + f ≤ a.size →
    (Http.allDigits.go a i f = true ↔ ∀ c ∈ slice a i (i + f), isDigit c = true) := by
  intro f
  induction f with
  | zero => intro i _; simp [Http.allDigits.go, slice_empty]
  | succ f ih =>
    intro i h
    rw [Http.allDigits.go, slice_cons a (by omega) h, Bool.and_eq_true, ih (i + 1) (by omega),
      show i + 1 + f = i + (f + 1) by omega, List.forall_mem_cons, Http.byte, digit_eq]

private theorem allDigits_iff (a : ByteArray) {i hi : Nat} (h' : hi ≤ a.size) :
    Http.allDigits a i hi = true ↔ ∀ c ∈ slice a i hi, isDigit c = true := by
  unfold Http.allDigits
  by_cases h : i ≤ hi
  · rw [allDigits_go a _ i (by omega), Nat.add_sub_cancel' h]
  · rw [show hi - i = 0 by omega, slice_nil_of_le a (by omega)]
    simp [Http.allDigits.go]

private theorem allHex_go (a : ByteArray) : ∀ f i, i + f ≤ a.size →
    (Http.allHex.go a i f = true ↔ ∀ c ∈ slice a i (i + f), isHex c = true) := by
  intro f
  induction f with
  | zero => intro i _; simp [Http.allHex.go, slice_empty]
  | succ f ih =>
    intro i h
    rw [Http.allHex.go, slice_cons a (by omega) h, Bool.and_eq_true, ih (i + 1) (by omega),
      show i + 1 + f = i + (f + 1) by omega, List.forall_mem_cons, Http.byte, hex_eq]

private theorem allHex_iff (a : ByteArray) {i hi : Nat} (h' : hi ≤ a.size) :
    Http.allHex a i hi = true ↔ ∀ c ∈ slice a i hi, isHex c = true := by
  unfold Http.allHex
  by_cases h : i ≤ hi
  · rw [allHex_go a _ i (by omega), Nat.add_sub_cancel' h]
  · rw [show hi - i = 0 by omega, slice_nil_of_le a (by omega)]
    simp [Http.allHex.go]

/-- `uriChars` decides `UriChars` for the set of its masks, `%` left out. -/
private theorem uriChars_go (m0 m1 : UInt64) (extra : UInt8 → Bool)
    (hset : ∀ c, Http.inSet m0 m1 c = (isUnreserved c || isSubDelim c || extra c)) (hpct : extra 0x25 = false)
    (a : ByteArray) {hi : Nat} (h' : hi ≤ a.size) :
    ∀ f i, hi - i ≤ f → (Http.uriChars.go m0 m1 a hi i f = true ↔ UriChars extra (slice a i hi)) := by
  have h37 : Http.inSet m0 m1 0x25 = false := by rw [hset, hpct]; rfl
  intro f
  induction f with
  | zero =>
    intro i hf
    rw [slice_nil_of_le a (by omega)]
    exact ⟨fun _ => .nil, fun _ => rfl⟩
  | succ f ih =>
    intro i hf
    dsimp only [Http.uriChars.go, Http.byte]
    by_cases hle : hi ≤ i
    · rw [ite_eq_left hle, slice_nil_of_le a hle]
      exact ⟨fun _ => .nil, fun _ => rfl⟩
    have hlt : i < hi := Nat.lt_of_not_le hle
    rw [ite_eq_right hle]
    by_cases hin : Http.inSet m0 m1 (a.get! i) = true
    · rw [ite_eq_left hin, ih (i + 1) (by omega), slice_cons a hlt h']
      constructor
      · exact fun hr => .char (by rw [← hset]; exact hin) hr
      · intro hu
        generalize a.get! i = c at hu hin
        generalize slice a (i + 1) hi = r at hu ⊢
        cases hu with
        | char _ hr => exact hr
        | pct _ _ _ => rw [h37] at hin; exact absurd hin Bool.false_ne_true
    · rw [ite_eq_right hin, slice_cons a hlt h']
      constructor
      · intro hp
        simp only [Bool.and_eq_true, beq_iff_eq, decide_eq_true_eq] at hp
        obtain ⟨⟨⟨⟨hc, h3⟩, hh⟩, hl⟩, hr⟩ := hp
        rw [ih (i + 3) (by omega)] at hr
        rw [hex_eq] at hh hl
        rw [slice_cons a (by omega) h', slice_cons a (by omega) h', hc]
        exact .pct hh hl hr
      · intro hu
        generalize hc : a.get! i = c at hu hin
        generalize hr : slice a (i + 1) hi = r at hu
        cases hu with
        | char hch _ => exact absurd (by rw [hset]; exact hch) hin
        | @pct h l s hh hl hs =>
          obtain ⟨hlt1, hg1, hr1⟩ := (slice_cons_iff a h').mp hr
          obtain ⟨hlt2, hg2, hr2⟩ := (slice_cons_iff a h').mp hr1
          rw [show i + 1 + 1 = i + 2 by omega] at hlt2 hg2 hr2
          rw [show i + 2 + 1 = i + 3 by omega] at hr2
          simp only [Bool.and_eq_true, beq_iff_eq, decide_eq_true_eq]
          refine ⟨⟨⟨⟨trivial, by omega⟩, by rw [hex_eq, hg1]; exact hh⟩, by rw [hex_eq, hg2]; exact hl⟩, ?_⟩
          rw [ih (i + 3) (by omega), hr2]
          exact hs

private theorem uriChars_iff (m0 m1 : UInt64) (extra : UInt8 → Bool)
    (hset : ∀ c, Http.inSet m0 m1 c = (isUnreserved c || isSubDelim c || extra c)) (hpct : extra 0x25 = false)
    (a : ByteArray) {i hi : Nat} (h' : hi ≤ a.size) :
    Http.uriChars m0 m1 a i hi = true ↔ UriChars extra (slice a i hi) :=
  uriChars_go m0 m1 extra hset hpct a h' _ i (Nat.le_refl _)

private theorem number_go (a : ByteArray) : ∀ f i acc, i + f ≤ a.size → (∀ c ∈ slice a i (i + f), isDigit c = true) →
    decimal (slice a i (i + f)) acc = some (Http.number.go a i f acc) := by
  intro f
  induction f with
  | zero => intro i acc _ _; simp [Http.number.go, slice_empty, decimal]
  | succ f ih =>
    intro i acc h hd
    rw [slice_cons a (by omega) h] at hd ⊢
    have hd0 := hd _ List.mem_cons_self
    simp only [isDigit, Bool.and_eq_true, decide_eq_true_eq] at hd0
    rw [decimal, ite_eq_left hd0, Http.number.go, Http.byte, show i + (f + 1) = i + 1 + f by omega]
    exact ih (i + 1) _ (by omega) (fun c hc => hd c (List.mem_cons_of_mem _ (by
      rw [show i + (f + 1) = i + 1 + f by omega]; exact hc)))

/-- The value of a range of digits. -/
private theorem number_eq (a : ByteArray) {lo hi : Nat} (h : lo ≤ hi) (h' : hi ≤ a.size)
    (hd : ∀ c ∈ slice a lo hi, isDigit c = true) : decimal (slice a lo hi) 0 = some (Http.number a lo hi) := by
  have := number_go a (hi - lo) lo 0 (by omega) (by rwa [Nat.add_sub_cancel' h])
  rwa [Nat.add_sub_cancel' h] at this

private theorem eqCI_go (a lit : ByteArray) (lo : Nat) :
    ∀ f k, Http.eqCI.go a lo lit k f = true ↔ ∀ j, k ≤ j → j < k + f → Http.lower (a.get! (lo + j)) = lit.get! j := by
  intro f
  induction f with
  | zero => intro k; simp [Http.eqCI.go]; intro j h1 h2; omega
  | succ f ih =>
    intro k
    simp only [Http.eqCI.go, Bool.and_eq_true, beq_iff_eq, Http.byte, ih (k + 1)]
    constructor
    · rintro ⟨h0, hr⟩ j h1 h2
      rcases Nat.eq_or_lt_of_le h1 with rfl | hlt
      · exact h0
      · exact hr j (by omega) (by omega)
    · intro h
      exact ⟨h k (Nat.le_refl _) (by omega), fun j h1 h2 => h j (by omega) (by omega)⟩

/-- `eqCI` compares a range, ASCII-lowercased, with a literal. -/
private theorem eqCI_iff (a lit : ByteArray) {lo hi : Nat} (h : lo ≤ hi) (h' : hi ≤ a.size) :
    Http.eqCI a lo hi lit = true ↔ Spec.Http.lower (slice a lo hi) = bs lit := by
  rw [Http.eqCI, Bool.and_eq_true, beq_iff_eq, eqCI_go]
  have hl := slice_length a (lo := lo) h'
  constructor
  · rintro ⟨hn, hk⟩
    apply List.ext_getElem?
    intro k
    rw [Spec.Http.lower, List.getElem?_map]
    by_cases hkl : k < lit.size
    · rw [slice_getElem? a (by omega) h', Option.map_some, ← lower_eq, hk k (Nat.zero_le _) (by omega), get!_eq]
      rw [List.getElem?_eq_getElem (by rw [← size_eq_length]; exact hkl)]
      rfl
    · rw [List.getElem?_eq_none (by rw [hl]; omega), List.getElem?_eq_none (by rw [← size_eq_length]; omega)]
      rfl
  · intro he
    have hlen := congrArg List.length he
    rw [Spec.Http.lower, List.length_map, hl, ← size_eq_length] at hlen
    refine ⟨hlen, fun j _ hj => ?_⟩
    have hk := congrArg (·[j]?) he
    simp only [Spec.Http.lower, List.getElem?_map] at hk
    rw [slice_getElem? a (by omega) h', Option.map_some, ← lower_eq,
      List.getElem?_eq_getElem (by rw [← size_eq_length]; omega)] at hk
    rw [show lit.get! j = (bs lit)[j]'(by rw [← size_eq_length]; omega) by
      rw [get!_eq, List.getElem?_eq_getElem (by rw [← size_eq_length]; omega)]; rfl]
    exact Option.some.inj hk

/-! ## The grammar's pieces -/

private theorem hex_unreserved : ∀ c : UInt8, isHex c = true → isUnreserved c = true := by decide +kernel

/-- The bytes of `*( unreserved / pct-encoded / sub-delims / extra )`. -/
private theorem uriChars_mem {extra : UInt8 → Bool} {s : List UInt8} (h : UriChars extra s) :
    ∀ c ∈ s, (isUnreserved c || isSubDelim c || extra c || c == 0x25) = true := by
  induction h with
  | nil => intro c hc; exact absurd hc List.not_mem_nil
  | char hc _ ih =>
    intro c' hm
    rcases List.mem_cons.mp hm with rfl | hm
    · rw [hc]; rfl
    · exact ih c' hm
  | pct hh hl _ ih =>
    intro c' hm
    simp only [List.mem_cons] at hm
    rcases hm with rfl | rfl | rfl | hm
    · simp
    · rw [hex_unreserved _ hh]; rfl
    · rw [hex_unreserved _ hl]; rfl
    · exact ih c' hm

private theorem isDigit_toNat {c : UInt8} : isDigit c = true ↔ 48 ≤ c.toNat ∧ c.toNat ≤ 57 := by
  simp only [isDigit, Bool.and_eq_true, decide_eq_true_eq, UInt8.le_iff_toNat_le]; rfl

private theorem decimal_cons_digit {c : UInt8} (cs : List UInt8) (acc : Nat) (h : isDigit c = true) :
    decimal (c :: cs) acc = decimal cs (acc * 10 + (c.toNat - 48)) := by
  have h' := isDigit_toNat.mp h
  rw [decimal, ite_eq_left (by simpa [isDigit] using h), UInt8.toNat_sub_of_le _ _ (by
    rw [UInt8.le_iff_toNat_le]; exact h'.1)]
  rfl

private theorem toUInt8_of_toNat {n : Nat} {x : UInt8} (h : n = x.toNat) : n.toUInt8 = x :=
  UInt8.toNat_inj.mp (by rw [Nat.toUInt8_eq, UInt8.toNat_ofNat']; have := x.toNat_lt; omega)

/-- The digits of a number below 256. -/
private def octetDigits (n : Nat) : List UInt8 :=
  if n < 10 then [(48 + n).toUInt8]
  else if n < 100 then [(48 + n / 10).toUInt8, (48 + n % 10).toUInt8]
  else [(48 + n / 100).toUInt8, (48 + n / 10 % 10).toUInt8, (48 + n % 10).toUInt8]

private theorem digits_octet : ∀ n, n < 256 → digits n = octetDigits n := by decide +kernel

private theorem digits_octet_ok : ∀ n, n < 256 →
    digits n ≠ [] ∧ (digits n).length ≤ 3 ∧ (digits n).all isDigit = true ∧
      ((digits n).length = 1 ∨ (digits n).head? ≠ some 0x30) ∧ decimal (digits n) 0 = some n := by
  decide +kernel

/-- `dec-octet`, as the code checks it: one to three digits, no leading zero, below 256. -/
private theorem decOctet_list (d : List UInt8) :
    DecOctet d ↔ d ≠ [] ∧ d.length ≤ 3 ∧ (∀ c ∈ d, isDigit c = true) ∧ (d.length = 1 ∨ d.head? ≠ some 0x30) ∧
      ∃ n, decimal d 0 = some n ∧ n < 256 := by
  constructor
  · rintro ⟨n, hn, rfl⟩
    obtain ⟨h1, h2, h3, h4, h5⟩ := digits_octet_ok n hn
    exact ⟨h1, h2, List.all_eq_true.mp h3, h4, n, h5, hn⟩
  · rintro ⟨hne, hlen, hdig, hz, n, hv, hn⟩
    refine ⟨n, hn, ?_⟩
    rw [digits_octet n hn]
    match d, hne, hlen, hdig, hz, hv with
    | [x], _, _, hdig, _, hv =>
      have hx := isDigit_toNat.mp (hdig x (by simp))
      rw [decimal_cons_digit _ _ (hdig x (by simp))] at hv
      simp only [decimal, Option.some.injEq] at hv
      have : n < 10 := by omega
      simp only [octetDigits, this, ↓reduceIte, List.cons.injEq, and_true]
      exact (toUInt8_of_toNat (by omega)).symm
    | [x, y], _, _, hdig, hz, hv =>
      have hx := isDigit_toNat.mp (hdig x (by simp))
      have hy := isDigit_toNat.mp (hdig y (by simp))
      have hx0 : x.toNat ≠ 48 := fun he => by
        rcases hz with hz | hz
        · simp at hz
        · exact hz (by simp only [List.head?_cons, Option.some.injEq]; exact UInt8.toNat_inj.mp he)
      rw [decimal_cons_digit _ _ (hdig x (by simp)), decimal_cons_digit _ _ (hdig y (by simp))] at hv
      simp only [decimal, Option.some.injEq] at hv
      have h10 : ¬ n < 10 := by omega
      have h100 : n < 100 := by omega
      simp only [octetDigits, h10, h100, ↓reduceIte, List.cons.injEq, and_true]
      exact ⟨(toUInt8_of_toNat (by omega)).symm, (toUInt8_of_toNat (by omega)).symm⟩
    | [x, y, z], _, _, hdig, hz, hv =>
      have hx := isDigit_toNat.mp (hdig x (by simp))
      have hy := isDigit_toNat.mp (hdig y (by simp))
      have hz' := isDigit_toNat.mp (hdig z (by simp))
      have hx0 : x.toNat ≠ 48 := fun he => by
        rcases hz with hz | hz
        · simp at hz
        · exact hz (by simp only [List.head?_cons, Option.some.injEq]; exact UInt8.toNat_inj.mp he)
      rw [decimal_cons_digit _ _ (hdig x (by simp)), decimal_cons_digit _ _ (hdig y (by simp)),
        decimal_cons_digit _ _ (hdig z (by simp))] at hv
      simp only [decimal, Option.some.injEq] at hv
      have h10 : ¬ n < 10 := by omega
      have h100 : ¬ n < 100 := by omega
      simp only [octetDigits, h10, h100, ↓reduceIte, List.cons.injEq, and_true]
      exact ⟨(toUInt8_of_toNat (by omega)).symm, (toUInt8_of_toNat (by omega)).symm,
        (toUInt8_of_toNat (by omega)).symm⟩
    | [], hne, _, _, _, _ => exact absurd rfl hne
    | _ :: _ :: _ :: _ :: _, _, hlen, _, _, _ => simp at hlen

private theorem decOctet_mem {d : List UInt8} (h : DecOctet d) : ∀ c ∈ d, isDigit c = true :=
  ((decOctet_list d).mp h).2.2.1

private theorem digit_ne : ∀ c : UInt8, isDigit c = true → c ≠ 0x2e ∧ c ≠ 0x3a ∧ isHex c = true := by
  decide +kernel

/-- The bytes of an IPv4 address: digits and dots. -/
private theorem ipv4_mem {s : List UInt8} (h : IPv4 s) : ∀ c ∈ s, isDigit c = true ∨ c = 0x2e := by
  obtain ⟨a, b, c, d, ha, hb, hc, hd, rfl⟩ := h
  intro x hx
  simp only [List.mem_append, List.mem_singleton] at hx
  rcases hx with ((((((hx | hx) | hx) | hx) | hx) | hx) | hx)
  · exact .inl (decOctet_mem ha x hx)
  · exact .inr hx
  · exact .inl (decOctet_mem hb x hx)
  · exact .inr hx
  · exact .inl (decOctet_mem hc x hx)
  · exact .inr hx
  · exact .inl (decOctet_mem hd x hx)

private theorem ipv4_ne_nil {s : List UInt8} (h : IPv4 s) : s ≠ [] := by
  obtain ⟨a, b, c, d, -, -, -, -, rfl⟩ := h
  simp

private theorem ipv4_dot {s : List UInt8} (h : IPv4 s) : 0x2e ∈ s := by
  obtain ⟨a, b, c, d, -, -, -, -, rfl⟩ := h
  simp

private theorem ipv4_colon {s : List UInt8} (h : IPv4 s) : 0x3a ∉ s := fun hm => by
  rcases ipv4_mem h _ hm with hd | hd
  · exact (digit_ne _ hd).2.1 rfl
  · exact absurd hd (by decide)

private theorem h16_colon {g : List UInt8} (h : H16 g) : 0x3a ∉ g := fun hm => absurd (h.2.2 _ hm) (by decide)

private theorem h16_dot {g : List UInt8} (h : H16 g) : 0x2e ∉ g := fun hm => absurd (h.2.2 _ hm) (by decide)

private theorem h16_not_ipv4 {g : List UInt8} (h : H16 g) : ¬ IPv4 g := fun h4 => h16_dot h (ipv4_dot h4)

/-! ### Groups joined by ":" -/

private theorem joinColon_cons (g : List UInt8) {gs : List (List UInt8)} (h : gs ≠ []) :
    joinColon (g :: gs) = g ++ 0x3a :: joinColon gs := by
  match gs, h with
  | _ :: _, _ => simp [joinColon]

private theorem joinColon_prefix : ∀ (g : List UInt8) (gs : List (List UInt8)), ∃ t, joinColon (g :: gs) = g ++ t
  | g, [] => ⟨[], by simp [joinColon]⟩
  | g, _ :: _ => ⟨_, joinColon_cons g (List.cons_ne_nil _ _)⟩

private theorem mem_joinColon {c : UInt8} : ∀ {gs : List (List UInt8)}, c ∈ joinColon gs → c = 0x3a ∨ ∃ g ∈ gs, c ∈ g
  | [], h => absurd h List.not_mem_nil
  | [g], h => .inr ⟨g, List.mem_singleton_self _, h⟩
  | g :: g' :: gs, h => by
    rw [joinColon_cons g (List.cons_ne_nil _ _)] at h
    rcases List.mem_append.mp h with h | h
    · exact .inr ⟨g, List.mem_cons_self, h⟩
    · rcases List.mem_cons.mp h with h | h
      · exact .inl h
      · rcases mem_joinColon h with h | ⟨g'', hg, hc⟩
        · exact .inl h
        · exact .inr ⟨g'', List.mem_cons_of_mem _ hg, hc⟩

private theorem joinColon_ne_nil {gs : List (List UInt8)} (hg : ∀ g ∈ gs, g ≠ []) (h : gs ≠ []) :
    joinColon gs ≠ [] := by
  obtain ⟨g, gs', rfl⟩ := List.exists_cons_of_ne_nil h
  obtain ⟨t, ht⟩ := joinColon_prefix g gs'
  rw [ht]
  exact fun he => hg g List.mem_cons_self (List.append_eq_nil_iff.mp he).1

private theorem groups_nil {v4 : Bool} {k : Nat} : Groups v4 k [] ↔ k = 0 := by
  constructor
  · rintro (⟨gs, hk, hg, hs⟩ | ⟨-, gs, t, -, hg, ht, hs⟩)
    · by_cases hn : gs = []
      · subst hn; exact hk.symm
      · exact absurd hs.symm (joinColon_ne_nil (fun g hm => (hg g hm).1) hn)
    · exact absurd hs.symm (joinColon_ne_nil (by
        intro g hm
        rcases List.mem_append.mp hm with hm | hm
        · exact (hg g hm).1
        · rw [List.mem_singleton.mp hm]; exact ipv4_ne_nil ht) (by simp))
  · rintro rfl
    exact .inl ⟨[], rfl, fun _ h => absurd h List.not_mem_nil, rfl⟩

/-- A range without ":" is one group, or with `v4` an IPv4 address, which counts as two. -/
private theorem groups_nocolon {v4 : Bool} {k : Nat} {s : List UInt8} (hs : s ≠ []) (hc : 0x3a ∉ s) :
    Groups v4 k s ↔ (k = 1 ∧ H16 s) ∨ (v4 = true ∧ k = 2 ∧ IPv4 s) := by
  constructor
  · rintro (⟨gs, hk, hg, rfl⟩ | ⟨hv, gs, t, hk, hg, ht, rfl⟩)
    · match gs, hk, hg, hs, hc with
      | [], _, _, hs, _ => exact absurd rfl hs
      | [g], hk, hg, _, _ => exact .inl ⟨hk.symm, hg g (List.mem_singleton_self _)⟩
      | g :: g' :: gs, _, _, _, hc =>
        rw [joinColon_cons g (List.cons_ne_nil _ _)] at hc
        exact absurd (List.mem_append_right _ List.mem_cons_self) hc
    · match gs, hk, hg, hs, hc with
      | [], hk, _, _, _ => exact .inr ⟨hv, by simpa using hk.symm, by simpa [joinColon] using ht⟩
      | g :: gs, _, _, _, hc =>
        rw [List.cons_append, joinColon_cons g (by simp)] at hc
        exact absurd (List.mem_append_right _ List.mem_cons_self) hc
  · rintro (⟨rfl, hh⟩ | ⟨hv, rfl, h4⟩)
    · exact .inl ⟨[s], rfl, fun g hm => by rw [List.mem_singleton.mp hm]; exact hh, rfl⟩
    · exact .inr ⟨hv, [], s, rfl, fun _ h => absurd h List.not_mem_nil, h4, rfl⟩

/-- Up to its first ":", a range of groups is one group; the rest is the other groups. -/
private theorem groups_colon {v4 : Bool} {k : Nat} {g r : List UInt8} (hg : 0x3a ∉ g) :
    Groups v4 k (g ++ 0x3a :: r) ↔ H16 g ∧ ∃ m, k = m + 1 ∧ Groups v4 m r ∧ r ≠ [] := by
  have hmem : (0x3a : UInt8) ∈ g ++ 0x3a :: r := List.mem_append_right _ List.mem_cons_self
  constructor
  · rintro (⟨gs, hk, hgs, hs⟩ | ⟨hv, gs, t, hk, hgs, ht, hs⟩)
    · match gs, hk, hgs, hs with
      | [], _, _, hs => exact absurd hs (by simp [joinColon])
      | [g1], _, hgs, hs =>
        rw [hs] at hmem
        exact absurd hmem (h16_colon (hgs g1 (List.mem_singleton_self _)))
      | g1 :: g2 :: gs', hk, hgs, hs =>
        rw [joinColon_cons g1 (List.cons_ne_nil _ _)] at hs
        obtain ⟨rfl, rfl⟩ := cut_unique' hs hg (h16_colon (hgs g1 List.mem_cons_self))
        refine ⟨hgs _ List.mem_cons_self, (g2 :: gs').length, by simpa using hk.symm,
          .inl ⟨g2 :: gs', rfl, fun x hx => hgs x (List.mem_cons_of_mem _ hx), rfl⟩, ?_⟩
        exact joinColon_ne_nil (fun x hx => (hgs x (List.mem_cons_of_mem _ hx)).1) (List.cons_ne_nil _ _)
    · match gs, hk, hgs, hs with
      | [], _, _, hs =>
        rw [hs] at hmem
        exact absurd (by simpa [joinColon] using hmem) (ipv4_colon ht)
      | g1 :: gs', hk, hgs, hs =>
        rw [List.cons_append, joinColon_cons g1 (by simp)] at hs
        obtain ⟨rfl, rfl⟩ := cut_unique' hs hg (h16_colon (hgs g1 List.mem_cons_self))
        refine ⟨hgs _ List.mem_cons_self, gs'.length + 2, by simp at hk; omega,
          .inr ⟨hv, gs', t, rfl, fun x hx => hgs x (List.mem_cons_of_mem _ hx), ht, rfl⟩, ?_⟩
        refine joinColon_ne_nil (fun x hx => ?_) (by simp)
        rcases List.mem_append.mp hx with hx | hx
        · exact (hgs x (List.mem_cons_of_mem _ hx)).1
        · rw [List.mem_singleton.mp hx]; exact ipv4_ne_nil ht
  · rintro ⟨hh, m, rfl, (⟨gs, hk, hgs, rfl⟩ | ⟨hv, gs, t, hk, hgs, ht, rfl⟩), hr⟩
    · have hn : gs ≠ [] := fun h => hr (by rw [h]; rfl)
      refine .inl ⟨g :: gs, by simp [hk], fun x hx => ?_, (joinColon_cons g hn).symm⟩
      rcases List.mem_cons.mp hx with rfl | hx
      · exact hh
      · exact hgs x hx
    · refine .inr ⟨hv, g :: gs, t, by simp; omega, fun x hx => ?_, ht, ?_⟩
      · rcases List.mem_cons.mp hx with rfl | hx
        · exact hh
        · exact hgs x hx
      · rw [List.cons_append, joinColon_cons g (by simp)]

/-- The bytes of groups: hex digits, ":" and "." -/
private theorem groups_mem {v4 : Bool} {k : Nat} {s : List UInt8} (h : Groups v4 k s) :
    ∀ c ∈ s, (isHex c || c == 0x3a || c == 0x2e) = true := by
  have hx : ∀ c : UInt8, isHex c = true → (isHex c || c == 0x3a || c == 0x2e) = true := by decide +kernel
  have hd : ∀ c : UInt8, isDigit c = true ∨ c = 0x2e → (isHex c || c == 0x3a || c == 0x2e) = true := by
    decide +kernel
  rcases h with ⟨gs, -, hg, rfl⟩ | ⟨-, gs, t, -, hg, ht, rfl⟩
  · intro c hc
    rcases mem_joinColon hc with rfl | ⟨g, hm, hcg⟩
    · rfl
    · exact hx c ((hg g hm).2.2 c hcg)
  · intro c hc
    rcases mem_joinColon hc with rfl | ⟨g, hm, hcg⟩
    · rfl
    · rcases List.mem_append.mp hm with hm | hm
      · exact hx c ((hg g hm).2.2 c hcg)
      · rw [List.mem_singleton.mp hm] at hcg
        exact hd c (ipv4_mem ht c hcg)

private theorem ipv6_mem {s : List UInt8} (h : IPv6 s) : ∀ c ∈ s, (isHex c || c == 0x3a || c == 0x2e) = true := by
  rcases h with h | ⟨l, r, i, j, -, hl, hr, rfl⟩
  · exact groups_mem h
  · intro c hc
    simp only [List.mem_append] at hc
    rcases hc with (hc | hc) | hc
    · exact groups_mem hl c hc
    · rw [show Spec.lit "::" = [0x3a, 0x3a] from rfl, List.mem_cons, List.mem_singleton, or_self] at hc
      rw [hc]; rfl
    · exact groups_mem hr c hc

/-! ### The first "::" -/

/-- Where the first "::" of a list starts, or its length if it has none. -/
private def dcIdx : List UInt8 → Nat
  | x :: y :: s => if x = 0x3a ∧ y = 0x3a then 0 else dcIdx (y :: s) + 1
  | s => s.length

private theorem dcIdx_cons_ne {c : UInt8} (t : List UInt8) (hc : c ≠ 0x3a) : dcIdx (c :: t) = dcIdx t + 1 := by
  match t with
  | [] => rfl
  | y :: s => rw [dcIdx, ite_eq_right (fun h => hc h.1)]

private theorem dcIdx_append_free : ∀ (g t : List UInt8), 0x3a ∉ g → dcIdx (g ++ t) = g.length + dcIdx t
  | [], t, _ => by simp
  | c :: g, t, hg => by
    rw [List.cons_append, dcIdx_cons_ne _ (fun h => hg (h ▸ List.mem_cons_self)),
      dcIdx_append_free g t (fun h => hg (List.mem_cons_of_mem _ h)), List.length_cons]
    omega

private theorem dcIdx_joinColon : ∀ (gs : List (List UInt8)), (∀ g ∈ gs, g ≠ [] ∧ 0x3a ∉ g) → ∀ t,
    dcIdx (joinColon gs ++ t) = (joinColon gs).length + dcIdx t
  | [], _, t => by simp [joinColon]
  | [g], hg, t => dcIdx_append_free g t (hg g (List.mem_singleton_self _)).2
  | g :: g' :: gs, hg, t => by
    have hgs : ∀ x ∈ g' :: gs, x ≠ [] ∧ 0x3a ∉ x := fun x hx => hg x (List.mem_cons_of_mem _ hx)
    obtain ⟨w, hw⟩ := joinColon_prefix g' gs
    obtain ⟨x, g'', rfl⟩ := List.exists_cons_of_ne_nil (hgs _ List.mem_cons_self).1
    have hx : x ≠ 0x3a := fun h => (hgs _ List.mem_cons_self).2 (h ▸ List.mem_cons_self)
    rw [joinColon_cons g (List.cons_ne_nil _ _), List.append_assoc, List.cons_append,
      dcIdx_append_free g _ (hg g List.mem_cons_self).2, hw, List.cons_append, List.cons_append,
      dcIdx, ite_eq_right (fun h => hx h.2), ← List.cons_append, ← List.cons_append, ← hw,
      dcIdx_joinColon ((x :: g'') :: gs) hgs t]
    simp only [List.length_append, List.length_cons]
    omega

/-- Groups have no "::". -/
private theorem groups_dcIdx {v4 : Bool} {k : Nat} {s : List UInt8} (h : Groups v4 k s) : dcIdx s = s.length := by
  rcases h with ⟨gs, -, hg, rfl⟩ | ⟨-, gs, t, -, hg, ht, rfl⟩
  · have := dcIdx_joinColon gs (fun g hm => ⟨(hg g hm).1, h16_colon (hg g hm)⟩) []
    rwa [List.append_nil] at this
  · have := dcIdx_joinColon (gs ++ [t]) (fun g hm => by
      rcases List.mem_append.mp hm with hm | hm
      · exact ⟨(hg g hm).1, h16_colon (hg g hm)⟩
      · rw [List.mem_singleton.mp hm]; exact ⟨ipv4_ne_nil ht, ipv4_colon ht⟩) []
    rwa [List.append_nil] at this

/-- The first "::" after groups without an IPv4 address is right after them. -/
private theorem groups_dcIdx_append {k : Nat} {l : List UInt8} (h : Groups false k l) (r : List UInt8) :
    dcIdx (l ++ 0x3a :: 0x3a :: r) = l.length := by
  rcases h with ⟨gs, -, hg, rfl⟩ | ⟨h, -⟩
  · rw [dcIdx_joinColon gs (fun g hm => ⟨(hg g hm).1, h16_colon (hg g hm)⟩), dcIdx, ite_eq_left ⟨rfl, rfl⟩]
    rfl
  · exact absurd h Bool.false_ne_true

private theorem dcIdx_le : ∀ s : List UInt8, dcIdx s ≤ s.length
  | x :: y :: s => by
    rw [dcIdx]
    split
    · exact Nat.zero_le _
    · have := dcIdx_le (y :: s); simp only [List.length_cons] at this ⊢; omega
  | [] => Nat.le_refl _
  | [_] => Nat.le_refl _

private theorem dcIdx_split : ∀ s : List UInt8, dcIdx s < s.length →
    ∃ l r, s = l ++ 0x3a :: 0x3a :: r ∧ l.length = dcIdx s
  | x :: y :: s, h => by
    by_cases hxy : x = 0x3a ∧ y = 0x3a
    · obtain ⟨rfl, rfl⟩ := hxy
      exact ⟨[], s, rfl, by rw [dcIdx, ite_eq_left ⟨rfl, rfl⟩]; rfl⟩
    · have he : dcIdx (x :: y :: s) = dcIdx (y :: s) + 1 := by rw [dcIdx, ite_eq_right hxy]
      rw [he] at h
      obtain ⟨l, r, hs, hl⟩ := dcIdx_split (y :: s) (by simp only [List.length_cons] at h ⊢; omega)
      exact ⟨x :: l, r, by rw [hs]; rfl, by rw [he, List.length_cons, hl]⟩
  | [], h => absurd h (Nat.lt_irrefl _)
  | [_], h => absurd h (Nat.lt_irrefl _)

/-! ## The searches -/

/-- What `findByte` found, as a cut of the range. -/
private theorem cut_found (a : ByteArray) (b : UInt8) {lo hi : Nat} (h : lo ≤ hi) (h' : hi ≤ a.size)
    (hlt : Bytes.findByte a b lo hi < hi) :
    lo ≤ Bytes.findByte a b lo hi ∧ b ∉ slice a lo (Bytes.findByte a b lo hi) ∧
      slice a lo hi = slice a lo (Bytes.findByte a b lo hi) ++ b :: slice a (Bytes.findByte a b lo hi + 1) hi := by
  obtain ⟨h1, -, h3, h4⟩ := findByte_cut a b h h'
  refine ⟨h1, h3, ?_⟩
  rw [slice_append a h1 (Nat.le_of_lt hlt), slice_cons a hlt h', h4 hlt]

/-- Where `findByte` stops on a range cut at its first `b`. -/
private theorem cut_at (a : ByteArray) (b : UInt8) {lo hi : Nat} (h : lo ≤ hi) (h' : hi ≤ a.size)
    {x y : List UInt8} (hs : slice a lo hi = x ++ b :: y) (hx : b ∉ x) :
    Bytes.findByte a b lo hi = lo + x.length ∧ lo + x.length < hi ∧ slice a lo (lo + x.length) = x ∧
      slice a (lo + x.length + 1) hi = y := by
  obtain ⟨hl, hsx, hsy⟩ := (slice_append_iff a h h').mp hs
  obtain ⟨hlt, -, hy⟩ := (slice_cons_iff a h').mp hsy
  exact ⟨findByte_of_eq a b h h' hs hx, hlt, hsx, hy⟩

/-- A search that starts past the range's end stops at the end. -/
private theorem findByte_ge (a : ByteArray) (b : UInt8) {x hi : Nat} (h' : hi ≤ a.size)
    (hlt : Bytes.findByte a b x hi < hi) : x ≤ Bytes.findByte a b x hi := by
  by_cases hx : x ≤ hi
  · exact (findByte_cut a b hx h').1
  · rw [Bytes.findByte_past a b (by omega), Nat.min_eq_left h'] at hlt
    exact absurd hlt (Nat.lt_irrefl _)

/-! ## Host (RFC 3986 §3.2.2, RFC 9110 §7.2) -/

private theorem h16_iff (a : ByteArray) {lo hi : Nat} (h : lo ≤ hi) (h' : hi ≤ a.size) :
    Http.h16 a lo hi = true ↔ H16 (slice a lo hi) := by
  have hl := slice_length a (lo := lo) h'
  simp only [Http.h16, Bool.and_eq_true, decide_eq_true_eq, allHex_iff a h', H16]
  constructor
  · rintro ⟨⟨h1, h2⟩, h3⟩
    exact ⟨fun he => by rw [he] at hl; simp at hl; omega, by omega, h3⟩
  · rintro ⟨h1, h2, h3⟩
    exact ⟨⟨Nat.lt_of_le_of_ne h (fun he => h1 (by rw [he, slice_empty])), by omega⟩, h3⟩

private theorem decOctet_iff (a : ByteArray) {lo hi : Nat} (h : lo ≤ hi) (h' : hi ≤ a.size) :
    Http.decOctet a lo hi = true ↔ DecOctet (slice a lo hi) := by
  rw [decOctet_list]
  have hl := slice_length a (lo := lo) h'
  simp only [Http.decOctet, Bool.and_eq_true, decide_eq_true_eq, Bool.or_eq_true, beq_iff_eq, bne_iff_ne, ne_eq,
    allDigits_iff a h', Http.byte]
  constructor
  · rintro ⟨⟨⟨⟨h1, h2⟩, h3⟩, h4⟩, h5⟩
    refine ⟨fun he => by rw [he] at hl; simp at hl; omega, by omega, h3, ?_, Http.number a lo hi,
      number_eq a h h' h3, h5⟩
    rcases h4 with h4 | h4
    · left; omega
    · right; rw [slice_cons a h1 h']; simpa using h4
  · rintro ⟨hne, hlen, hdig, hz, n, hn, hn256⟩
    have h1 : lo < hi := Nat.lt_of_le_of_ne h (fun he => hne (by rw [he, slice_empty]))
    rw [number_eq a h h' hdig, Option.some.injEq] at hn
    refine ⟨⟨⟨⟨h1, by omega⟩, hdig⟩, ?_⟩, hn ▸ hn256⟩
    rcases hz with hz | hz
    · left; omega
    · right; rw [slice_cons a h1 h'] at hz; simpa using hz

private theorem ipv4_iff (a : ByteArray) {lo hi : Nat} (h : lo ≤ hi) (h' : hi ≤ a.size) :
    Http.ipv4 a lo hi = true ↔ IPv4 (slice a lo hi) := by
  simp only [Http.ipv4, Bool.and_eq_true, decide_eq_true_eq]
  constructor
  · rintro ⟨⟨⟨⟨h3, o1⟩, o2⟩, o3⟩, o4⟩
    have g3 := findByte_ge a 0x2e h' h3
    have hlt2 : Bytes.findByte a 0x2e (Bytes.findByte a 0x2e lo hi + 1) hi < hi := by omega
    have g2 := findByte_ge a 0x2e h' hlt2
    have hlt1 : Bytes.findByte a 0x2e lo hi < hi := by omega
    obtain ⟨g1, -, c1⟩ := cut_found a 0x2e h h' hlt1
    obtain ⟨-, -, c2⟩ := cut_found a 0x2e (by omega) h' hlt2
    obtain ⟨-, -, c3⟩ := cut_found a 0x2e (by omega) h' h3
    generalize Bytes.findByte a 0x2e lo hi = d1 at *
    generalize Bytes.findByte a 0x2e (d1 + 1) hi = d2 at *
    generalize Bytes.findByte a 0x2e (d2 + 1) hi = d3 at *
    refine ⟨_, _, _, _, (decOctet_iff a (by omega) (by omega)).mp o1, (decOctet_iff a (by omega) (by omega)).mp o2,
      (decOctet_iff a (by omega) (by omega)).mp o3, (decOctet_iff a (by omega) h').mp o4, ?_⟩
    rw [c1, c2, c3]
    simp only [List.append_assoc, List.cons_append, List.nil_append]
  · rintro ⟨A, B, C, D, hA, hB, hC, hD, hs⟩
    have nd : ∀ {x}, DecOctet x → 0x2e ∉ x := fun hx hm => (digit_ne _ (decOctet_mem hx _ hm)).1 rfl
    simp only [List.append_assoc, List.cons_append] at hs
    obtain ⟨e1, l1, s1, r1⟩ := cut_at a 0x2e h h' hs (nd hA)
    obtain ⟨e2, l2, s2, r2⟩ := cut_at a 0x2e (by omega) h' r1 (nd hB)
    obtain ⟨e3, l3, s3, r3⟩ := cut_at a 0x2e (by omega) h' r2 (nd hC)
    rw [e1, e2, e3]
    refine ⟨⟨⟨⟨by omega, (decOctet_iff a (by omega) (by omega)).mpr (by rw [s1]; exact hA)⟩,
      (decOctet_iff a (by omega) (by omega)).mpr (by rw [s2]; exact hB)⟩,
      (decOctet_iff a (by omega) (by omega)).mpr (by rw [s3]; exact hC)⟩,
      (decOctet_iff a (by omega) h').mpr (by rw [r3]; exact hD)⟩

private theorem groups_go (a : ByteArray) (v4 : Bool) {hi : Nat} (h' : hi ≤ a.size) :
    ∀ f i k n, i ≤ hi → hi - i ≤ f →
      (Http.groups.go a hi v4 i k f = some n ↔ ∃ m, n = k + m ∧ Groups v4 m (slice a i hi) ∧ slice a i hi ≠ []) := by
  intro f
  induction f with
  | zero =>
    intro i k n hi' hf
    rw [show i = hi by omega, slice_empty]
    simp [Http.groups.go]
  | succ f ih =>
    intro i k n hi' hf
    simp only [Http.groups.go]
    by_cases hlt : Bytes.findByte a 0x3a i hi < hi
    · rw [ite_eq_left hlt]
      obtain ⟨hle, hnot, hs⟩ := cut_found a 0x3a hi' h' hlt
      generalize Bytes.findByte a 0x3a i hi = e at hle hnot hs hlt
      rw [hs]
      simp only [groups_colon hnot]
      by_cases h16 : Http.h16 a i e = true
      · rw [ite_eq_left h16]
        have hg := (h16_iff a hle (by omega)).mp h16
        have he : i < e := by
          refine Nat.lt_of_le_of_ne hle (fun he => hg.1 ?_)
          rw [he, slice_empty]
        rw [ih (e + 1) (k + 1) n (by omega) (by omega)]
        constructor
        · rintro ⟨m, rfl, hm, hr⟩
          exact ⟨m + 1, by omega, ⟨hg, m, rfl, hm, hr⟩, by simp⟩
        · rintro ⟨_, rfl, ⟨-, m, rfl, hm, hr⟩, -⟩
          exact ⟨m, by omega, hm, hr⟩
      · rw [ite_eq_right h16]
        simp only [reduceCtorEq, false_iff, not_exists, not_and]
        intro m _ hm
        exact absurd ((h16_iff a hle (by omega)).mpr hm.1) h16
    · rw [ite_eq_right hlt]
      have he : Bytes.findByte a 0x3a i hi = hi := by have := (findByte_cut a 0x3a hi' h').2.1; omega
      have hnot := (findByte_spec a 0x3a hi' h').mp he
      by_cases hne : slice a i hi = []
      · have hih : hi ≤ i := by
          have := slice_length a (lo := i) h'; rw [hne] at this; simp at this; omega
        have h16f : Http.h16 a i hi = false := by simp [Http.h16]; omega
        have h4f : Http.ipv4 a i hi = false := by
          rw [Bool.eq_false_iff]; intro h4
          exact ipv4_ne_nil ((ipv4_iff a hi' h').mp h4) hne
        rw [h16f, h4f]
        simp [hne]
      · rw [show (∃ m, n = k + m ∧ Groups v4 m (slice a i hi) ∧ slice a i hi ≠ []) ↔
            (∃ m, n = k + m ∧ ((m = 1 ∧ H16 (slice a i hi)) ∨ (v4 = true ∧ m = 2 ∧ IPv4 (slice a i hi)))) from
          ⟨fun ⟨m, h1, h2, _⟩ => ⟨m, h1, (groups_nocolon hne hnot).mp h2⟩,
            fun ⟨m, h1, h2⟩ => ⟨m, h1, (groups_nocolon hne hnot).mpr h2, hne⟩⟩]
        by_cases h16 : Http.h16 a i hi = true
        · have hg := (h16_iff a hi' h').mp h16
          rw [ite_eq_left h16, Option.some.injEq]
          constructor
          · rintro rfl; exact ⟨1, rfl, .inl ⟨rfl, hg⟩⟩
          · rintro ⟨m, rfl, (⟨rfl, -⟩ | ⟨-, -, h4⟩)⟩
            · rfl
            · exact absurd h4 (h16_not_ipv4 hg)
        · rw [ite_eq_right h16]
          have hg : ¬ H16 (slice a i hi) := fun hg => h16 ((h16_iff a hi' h').mpr hg)
          by_cases h4 : (v4 && Http.ipv4 a i hi) = true
          · rw [ite_eq_left h4, Option.some.injEq]
            simp only [Bool.and_eq_true] at h4
            constructor
            · rintro rfl; exact ⟨2, rfl, .inr ⟨h4.1, rfl, (ipv4_iff a hi' h').mp h4.2⟩⟩
            · rintro ⟨m, rfl, (⟨-, hg'⟩ | ⟨-, rfl, -⟩)⟩
              · exact absurd hg' hg
              · rfl
          · rw [ite_eq_right h4]
            simp only [reduceCtorEq, false_iff, not_exists, not_and]
            rintro m - (⟨-, hg'⟩ | ⟨hv, -, h4'⟩)
            · exact hg hg'
            · exact h4 (by rw [hv, (ipv4_iff a hi' h').mpr h4']; rfl)

private theorem groups_iff (a : ByteArray) (v4 : Bool) {lo hi : Nat} (h : lo ≤ hi) (h' : hi ≤ a.size) (k : Nat) :
    Http.groups a lo hi v4 = some k ↔ Groups v4 k (slice a lo hi) := by
  unfold Http.groups
  by_cases hle : hi ≤ lo
  · rw [ite_eq_left hle, show lo = hi by omega, slice_empty, groups_nil, Option.some.injEq]
    exact eq_comm
  · rw [ite_eq_right hle, groups_go a v4 h' _ lo 0 k h (Nat.le_refl _)]
    have hne : slice a lo hi ≠ [] := fun he => by
      have := slice_length a (lo := lo) h'; rw [he] at this; simp at this; omega
    exact ⟨fun ⟨m, h1, h2, _⟩ => by rw [h1, Nat.zero_add]; exact h2, fun h2 => ⟨k, by omega, h2, hne⟩⟩

private theorem doubleColon_go (a : ByteArray) {hi : Nat} (h' : hi ≤ a.size) :
    ∀ f i, i ≤ hi → hi - i ≤ f → Http.doubleColon.go a hi i f = i + dcIdx (slice a i hi) := by
  intro f
  induction f with
  | zero => intro i h1 h2; rw [show i = hi by omega, slice_empty]; rfl
  | succ f ih =>
    intro i h1 h2
    rw [Http.doubleColon.go]
    by_cases hn : hi ≤ i + 1
    · rw [ite_eq_left hn]
      rcases Nat.lt_or_ge i hi with hlt | hge
      · rw [slice_cons a hlt h', show i + 1 = hi by omega, slice_empty, show dcIdx [a.get! i] = 1 from rfl]
        omega
      · rw [show i = hi by omega, slice_empty]; rfl
    · rw [ite_eq_right hn, slice_cons a (by omega) h', slice_cons a (by omega : i + 1 < hi) h']
      by_cases hc : (Http.byte a i == 0x3a && Http.byte a (i + 1) == 0x3a) = true
      · rw [ite_eq_left hc]
        simp only [Bool.and_eq_true, beq_iff_eq, Http.byte] at hc
        rw [dcIdx, ite_eq_left hc]
        rfl
      · rw [ite_eq_right hc, ih (i + 1) (by omega) (by omega), slice_cons a (by omega : i + 1 < hi) h']
        rw [dcIdx, ite_eq_right (by simpa [Http.byte] using hc)]
        omega

private theorem doubleColon_eq (a : ByteArray) {lo hi : Nat} (h : lo ≤ hi) (h' : hi ≤ a.size) :
    Http.doubleColon a lo hi = lo + dcIdx (slice a lo hi) :=
  doubleColon_go a h' _ lo h (Nat.le_refl _)

private theorem ipv6_iff (a : ByteArray) {lo hi : Nat} (h : lo ≤ hi) (h' : hi ≤ a.size) :
    Http.ipv6 a lo hi = true ↔ IPv6 (slice a lo hi) := by
  have hl := slice_length a (lo := lo) h'
  have hdc : Spec.lit "::" = [0x3a, 0x3a] := rfl
  unfold Http.ipv6
  rw [doubleColon_eq a h h']
  by_cases hd : lo + dcIdx (slice a lo hi) < hi
  · rw [ite_eq_left hd]
    obtain ⟨l, r, hs, hll⟩ := dcIdx_split (slice a lo hi) (by omega)
    obtain ⟨hlen, hsl, hsr⟩ := (slice_append_iff a h h').mp hs
    obtain ⟨-, -, hr1⟩ := (slice_cons_iff a h').mp hsr
    obtain ⟨-, -, hr2⟩ := (slice_cons_iff a h').mp hr1
    have hlen2 : lo + l.length + 2 ≤ hi := by
      have := congrArg List.length hs; simp only [List.length_append, List.length_cons] at this; omega
    rw [← hll]
    rw [show lo + l.length + 1 + 1 = lo + l.length + 2 by omega] at hr2
    have gl := groups_iff a false (lo := lo) (hi := lo + l.length) (by omega) (by omega)
    have gr := groups_iff a true (lo := lo + l.length + 2) (hi := hi) (by omega) h'
    rw [hsl] at gl; rw [hr2] at gr
    constructor
    · intro hm
      split at hm
      · rename_i i j hi hj
        exact .inr ⟨l, r, i, j, of_decide_eq_true hm, (gl i).mp hi, (gr j).mp hj, by rw [hs, hdc]; simp⟩
      · exact absurd hm Bool.false_ne_true
    · rintro (h8 | ⟨l', r', i, j, hij, hl', hr', hs'⟩)
      · rw [groups_dcIdx h8] at hd; omega
      · rw [hdc, show l' ++ [0x3a, 0x3a] ++ r' = l' ++ 0x3a :: 0x3a :: r' by simp] at hs'
        have hd' := groups_dcIdx_append hl' r'
        rw [← hs', ← hll] at hd'
        obtain ⟨rfl, hrr⟩ := List.append_inj (hs.symm.trans hs') hd'
        obtain rfl : r = r' := by simpa using hrr
        rw [(gl i).mpr hl', (gr j).mpr hr']
        exact decide_eq_true hij
  · rw [ite_eq_right hd]
    have hfull : dcIdx (slice a lo hi) = (slice a lo hi).length := by have := dcIdx_le (slice a lo hi); omega
    rw [beq_iff_eq, groups_iff a true h h' 8]
    constructor
    · exact .inl
    · rintro (h8 | ⟨l', r', i, j, -, hl', -, hs'⟩)
      · exact h8
      · rw [hs', hdc, show l' ++ [0x3a, 0x3a] ++ r' = l' ++ 0x3a :: 0x3a :: r' by simp,
          groups_dcIdx_append hl' r'] at hfull
        simp at hfull

private theorem lower_v {v : List UInt8} (h : Spec.Http.lower v = Spec.lit "v") : v = [0x76] ∨ v = [0x56] := by
  have key : ∀ b : UInt8, (if 0x41 ≤ b ∧ b ≤ 0x5a then b + 32 else b) = 0x76 → b = 0x76 ∨ b = 0x56 := by
    decide +kernel
  rw [show Spec.lit "v" = [0x76] from rfl] at h
  match v, h with
  | [b], h =>
    simp only [Spec.Http.lower, List.map_cons, List.map_nil, List.cons.injEq, and_true] at h
    rcases key b h with rfl | rfl
    · exact .inl rfl
    · exact .inr rfl
  | [], h => simp [Spec.Http.lower] at h
  | _ :: _ :: _, h => simp [Spec.Http.lower] at h

/-- An `IPvFuture` starts with "v" or "V", then hex digits, ".", and the rest. -/
private theorem ipvFuture_iff {b : UInt8} {r : List UInt8} :
    IPvFuture (b :: r) ↔ (b = 0x76 ∨ b = 0x56) ∧ ∃ hx x, hx ≠ [] ∧ (∀ c ∈ hx, isHex c = true) ∧ x ≠ [] ∧
      (∀ c ∈ x, (isUnreserved c || isSubDelim c || c == 0x3a) = true) ∧ r = hx ++ 0x2e :: x := by
  constructor
  · rintro ⟨v, hx, x, hv, h1, h2, h3, h4, hs⟩
    rcases lower_v hv with rfl | rfl <;> simp only [List.cons_append, List.cons.injEq,
      List.append_assoc] at hs <;> obtain ⟨rfl, rfl⟩ := hs
    · exact ⟨.inl rfl, hx, x, h1, h2, h3, h4, rfl⟩
    · exact ⟨.inr rfl, hx, x, h1, h2, h3, h4, rfl⟩
  · rintro ⟨hb, hx, x, h1, h2, h3, h4, rfl⟩
    refine ⟨[b], hx, x, ?_, h1, h2, h3, h4, by simp⟩
    rcases hb with rfl | rfl <;> rfl

private theorem ipvFuture_mem {x : List UInt8} (h : IPvFuture x) :
    ∀ c ∈ x, (isUnreserved c || isSubDelim c || c == 0x3a) = true := by
  match x, h with
  | [], h => obtain ⟨v, hx, y, hv, -, -, -, -, hs⟩ := h; simp at hs
  | b :: r, h =>
    obtain ⟨hb, hx, y, -, h2, -, h4, rfl⟩ := ipvFuture_iff.mp h
    intro c hc
    simp only [List.mem_cons, List.mem_append] at hc
    rcases hc with rfl | hc | rfl | hc
    · rcases hb with rfl | rfl <;> rfl
    · rw [hex_unreserved c (h2 c hc)]; rfl
    · rfl
    · exact h4 c hc

private theorem ipFuture_iff (a : ByteArray) {lo hi : Nat} (h : lo ≤ hi) (h' : hi ≤ a.size) :
    Http.ipFuture a lo hi = true ↔ ∃ hx x, hx ≠ [] ∧ (∀ c ∈ hx, isHex c = true) ∧ x ≠ [] ∧
      (∀ c ∈ x, (isUnreserved c || isSubDelim c || c == 0x3a) = true) ∧ slice a lo hi = hx ++ 0x2e :: x := by
  simp only [Http.ipFuture, Bool.and_eq_true, decide_eq_true_eq]
  constructor
  · rintro ⟨⟨⟨h1, h2⟩, h3⟩, h4⟩
    obtain ⟨-, -, hs⟩ := cut_found a 0x2e h h' (by omega)
    generalize Bytes.findByte a 0x2e lo hi = d at *
    refine ⟨_, _, fun he => ?_, (allHex_iff a (by omega)).mp h3, fun he => ?_, fun c hc => ?_, hs⟩
    · have := slice_length a (lo := lo) (hi := d) (by omega); rw [he] at this; simp at this; omega
    · have := slice_length a (lo := d + 1) (hi := hi) h'; rw [he] at this; simp at this; omega
    · rw [← user_set]; exact (allIn_iff _ _ a h').mp h4 c hc
  · rintro ⟨hx, x, h1, h2, h3, h4, hs⟩
    obtain ⟨e, hlt, hsx, hsy⟩ := cut_at a 0x2e h h' hs (fun hm => absurd (h2 _ hm) (by decide))
    rw [e]
    refine ⟨⟨⟨?_, ?_⟩, (allHex_iff a (by omega)).mpr (by rw [hsx]; exact h2)⟩,
      (allIn_iff _ _ a h').mpr (by rw [hsy]; intro c hc; rw [user_set]; exact h4 c hc)⟩
    · have : hx.length ≠ 0 := fun h0 => h1 (List.eq_nil_of_length_eq_zero h0)
      omega
    · have := congrArg List.length hsy
      rw [slice_length a h'] at this
      have : x.length ≠ 0 := fun h0 => h3 (List.eq_nil_of_length_eq_zero h0)
      omega

private theorem ipLiteral_iff (a : ByteArray) {lo hi : Nat} (h : lo ≤ hi) (h' : hi ≤ a.size) :
    Http.ipLiteral a lo hi = true ↔ IPv6 (slice a lo hi) ∨ IPvFuture (slice a lo hi) := by
  have nv : ∀ c : UInt8, c = 0x76 ∨ c = 0x56 → (isHex c || c == 0x3a || c == 0x2e) = false := by decide +kernel
  unfold Http.ipLiteral
  by_cases hc : (lo < hi && (Http.byte a lo == 0x76 || Http.byte a lo == 0x56)) = true
  · rw [ite_eq_left hc]
    simp only [Bool.and_eq_true, decide_eq_true_eq, Bool.or_eq_true, beq_iff_eq, Http.byte] at hc
    obtain ⟨hlt, hb⟩ := hc
    rw [ipFuture_iff a hlt h', slice_cons a hlt h', ipvFuture_iff]
    constructor
    · exact fun hf => .inr ⟨hb, hf⟩
    · rintro (h6 | ⟨-, hf⟩)
      · exact absurd (ipv6_mem h6 _ List.mem_cons_self) (by rw [nv _ hb]; exact Bool.false_ne_true)
      · exact hf
  · rw [ite_eq_right hc, ipv6_iff a h h']
    constructor
    · exact .inl
    · rintro (h6 | hf)
      · exact h6
      · exfalso
        by_cases hlt : lo < hi
        · rw [slice_cons a hlt h'] at hf
          exact hc (by simp [Http.byte, hlt, (ipvFuture_iff.mp hf).1])
        · rw [slice_nil_of_le a (by omega)] at hf
          obtain ⟨v, hx, y, -, -, -, -, -, hs⟩ := hf
          simp at hs

private theorem portOk_iff (a : ByteArray) {i hi : Nat} (h' : hi ≤ a.size) :
    Http.portOk a i hi = true ↔ slice a i hi = [] ∨ ∃ p, (∀ c ∈ p, isDigit c = true) ∧ slice a i hi = 0x3a :: p := by
  unfold Http.portOk
  by_cases hle : hi ≤ i
  · rw [slice_nil_of_le a hle]; simp [hle]
  · have hlt : i < hi := Nat.lt_of_not_le hle
    rw [slice_cons a hlt h']
    simp only [Bool.or_eq_true, decide_eq_true_eq, hle, false_or, Bool.and_eq_true, beq_iff_eq, Http.byte,
      allDigits_iff a h', reduceCtorEq, List.cons.injEq]
    constructor
    · rintro ⟨h1, h2⟩; exact ⟨_, h2, h1, rfl⟩
    · rintro ⟨p, hp, h1, rfl⟩; exact ⟨h1, hp⟩

private theorem regName_mem {h : List UInt8} (hr : UriChars (fun _ => false) h) :
    ∀ c ∈ h, c ≠ 0x3a ∧ c ≠ 0x5b ∧ c ≠ 0x5d ∧ c ≠ 0x40 ∧ c ≠ 0x2f ∧ c ≠ 0x3f := by
  have key : ∀ c : UInt8, (isUnreserved c || isSubDelim c || false || c == 0x25) = true →
      c ≠ 0x3a ∧ c ≠ 0x5b ∧ c ≠ 0x5d ∧ c ≠ 0x40 ∧ c ≠ 0x2f ∧ c ≠ 0x3f := by decide +kernel
  exact fun c hc => key c (uriChars_mem hr c hc)

private theorem ipLit_mem {x : List UInt8} (h : IPv6 x ∨ IPvFuture x) :
    ∀ c ∈ x, c ≠ 0x5d ∧ c ≠ 0x5b ∧ c ≠ 0x40 ∧ c ≠ 0x2f ∧ c ≠ 0x3f := by
  have k6 : ∀ c : UInt8, (isHex c || c == 0x3a || c == 0x2e) = true →
      c ≠ 0x5d ∧ c ≠ 0x5b ∧ c ≠ 0x40 ∧ c ≠ 0x2f ∧ c ≠ 0x3f := by decide +kernel
  have kf : ∀ c : UInt8, (isUnreserved c || isSubDelim c || c == 0x3a) = true →
      c ≠ 0x5d ∧ c ≠ 0x5b ∧ c ≠ 0x40 ∧ c ≠ 0x2f ∧ c ≠ 0x3f := by decide +kernel
  rcases h with h | h
  · exact fun c hc => k6 c (ipv6_mem h c hc)
  · exact fun c hc => kf c (ipvFuture_mem h c hc)

/-- A Host value is its host, then nothing or ":" and digits. -/
private theorem hostPort_parts {v host : List UInt8} :
    HostPort v host ↔ UriHost host ∧ ∃ rest, v = host ++ rest ∧
      (rest = [] ∨ ∃ p, (∀ c ∈ p, isDigit c = true) ∧ rest = 0x3a :: p) := by
  constructor
  · rintro ⟨hh, rfl | ⟨p, hp, rfl⟩⟩
    · exact ⟨hh, [], by simp, .inl rfl⟩
    · exact ⟨hh, 0x3a :: p, by simp, .inr ⟨p, hp, rfl⟩⟩
  · rintro ⟨hh, rest, rfl, rfl | ⟨p, hp, rfl⟩⟩
    · exact ⟨hh, .inl (by simp)⟩
    · exact ⟨hh, .inr ⟨p, hp, by simp⟩⟩

private theorem uriHost_mem {h : List UInt8} (hh : UriHost h) : ∀ c ∈ h, c ≠ 0x40 ∧ c ≠ 0x2f ∧ c ≠ 0x3f := by
  rcases hh with hr | ⟨x, hx, rfl⟩
  · exact fun c hc => let k := regName_mem hr c hc; ⟨k.2.2.2.1, k.2.2.2.2.1, k.2.2.2.2.2⟩
  · intro c hc
    simp only [List.mem_append, List.mem_singleton] at hc
    rcases hc with (rfl | hc) | rfl
    · decide
    · exact let k := ipLit_mem hx c hc; ⟨k.2.2.1, k.2.2.2.1, k.2.2.2.2⟩
    · decide

/-- No "@", "/" or "?" in a Host value. -/
private theorem hostPort_mem {v h : List UInt8} (hp : HostPort v h) : ∀ c ∈ v, c ≠ 0x40 ∧ c ≠ 0x2f ∧ c ≠ 0x3f := by
  have hd : ∀ c : UInt8, isDigit c = true → c ≠ 0x40 ∧ c ≠ 0x2f ∧ c ≠ 0x3f := by decide +kernel
  obtain ⟨hh, rest, rfl, hr⟩ := hostPort_parts.mp hp
  intro c hc
  rcases List.mem_append.mp hc with hc | hc
  · exact uriHost_mem hh c hc
  · rcases hr with rfl | ⟨p, hpd, rfl⟩
    · exact absurd hc List.not_mem_nil
    · rcases List.mem_cons.mp hc with rfl | hc
      · decide
      · exact hd c (hpd c hc)

/-- **Where `hostEnd` stops is the end of a Host value's host**: the range is `uri-host [ ":" port ]`
with that host. -/
theorem _root_.Feed.Http.hostEnd_some {a : ByteArray} {lo hi e : Nat} (h : lo ≤ hi) (h' : hi ≤ a.size)
    (he : Http.hostEnd a lo hi = some e) : lo ≤ e ∧ e ≤ hi ∧ HostPort (slice a lo hi) (slice a lo e) := by
  unfold Http.hostEnd at he
  split at he
  · rename_i hb
    simp only [Bool.and_eq_true, decide_eq_true_eq, beq_iff_eq, Http.byte] at hb
    dsimp only at he
    split at he
    · rename_i hc
      rw [Option.some.injEq] at he; subst he
      simp only [Bool.and_eq_true, decide_eq_true_eq] at hc
      obtain ⟨⟨hr, hlit⟩, hport⟩ := hc
      obtain ⟨h1, -, -, hget⟩ := findByte_cut a 0x5d h h'
      have hget' := hget hr
      generalize Bytes.findByte a 0x5d lo hi = r at *
      have hr0 : lo < r := by
        refine Nat.lt_of_le_of_ne h1 (fun he => ?_)
        subst he
        rw [hb.2] at hget'
        exact absurd hget' (by decide)
      have hx := (ipLiteral_iff a (by omega) (by omega)).mp hlit
      have hhost : slice a lo (r + 1) = [0x5b] ++ slice a (lo + 1) r ++ [0x5d] := by
        rw [slice_append a (m := r) h1 (by omega), slice_cons a hr0 (by omega), hb.2,
          slice_cons a (by omega : r < r + 1) (by omega), slice_empty, hget']
        rfl
      exact ⟨by omega, by omega, hostPort_parts.mpr ⟨.inr ⟨_, hx, hhost⟩, slice a (r + 1) hi,
        slice_append a (by omega) (by omega), (portOk_iff a h').mp hport⟩⟩
    · exact absurd he (by simp)
  · dsimp only at he
    split at he
    · rename_i hc
      rw [Option.some.injEq] at he; subst he
      simp only [Bool.and_eq_true] at hc
      obtain ⟨hreg, hport⟩ := hc
      obtain ⟨h1, h2, -, -⟩ := findByte_cut a 0x3a h h'
      exact ⟨h1, h2, hostPort_parts.mpr ⟨.inl ((uriChars_iff _ _ (fun _ => false) reg_set rfl a (by omega)).mp hreg),
        _, slice_append a h1 h2, (portOk_iff a h').mp hport⟩⟩
    · exact absurd he (by simp)

/-- info: 'Feed.Http.hostEnd_some' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Http.hostEnd_some

/-- **`hostEnd` finds the host of every Host value.** -/
theorem _root_.Feed.Http.hostEnd_of {a : ByteArray} {lo hi : Nat} (h : lo ≤ hi) (h' : hi ≤ a.size)
    {host : List UInt8} (hp : HostPort (slice a lo hi) host) : Http.hostEnd a lo hi = some (lo + host.length) := by
  obtain ⟨hh, rest, hv, hrest⟩ := hostPort_parts.mp hp
  obtain ⟨hlen, hsl, hsr⟩ := (slice_append_iff a h h').mp hv
  unfold Http.hostEnd
  rcases hh with hreg | ⟨x, hx, rfl⟩
  · have hcond : ¬ (lo < hi && Http.byte a lo == 0x5b) = true := by
      simp only [Bool.and_eq_true, decide_eq_true_eq, beq_iff_eq, Http.byte, not_and]
      intro hlt hb
      rw [slice_cons a hlt h', hb] at hv
      match host, hreg, hv with
      | c :: host, hreg, hv =>
        rw [List.cons_append, List.cons.injEq] at hv
        exact (regName_mem hreg c List.mem_cons_self).2.1 hv.1.symm
      | [], _, hv =>
        rw [List.nil_append] at hv
        rcases hrest with rfl | ⟨p, -, rfl⟩
        · exact List.cons_ne_nil _ _ hv
        · exact absurd (List.cons.inj hv).1 (by decide)
    rw [ite_eq_right hcond]
    dsimp only
    have hc : Bytes.findByte a 0x3a lo hi = lo + host.length := by
      rcases hrest with rfl | ⟨p, -, rfl⟩
      · rw [List.append_nil] at hv
        rw [findByte_of_not_mem a 0x3a h h' (by rw [hv]; exact fun hm => (regName_mem hreg _ hm).1 rfl)]
        have := slice_length a (lo := lo) h'; rw [hv] at this; omega
      · exact findByte_of_eq a 0x3a h h' hv (fun hm => (regName_mem hreg _ hm).1 rfl)
    rw [hc, ite_eq_left]
    simp only [Bool.and_eq_true]
    exact ⟨(uriChars_iff _ _ (fun _ => false) reg_set rfl a (by omega)).mpr (by rw [hsl]; exact hreg),
      (portOk_iff a h').mpr (by rw [hsr]; exact hrest)⟩
  · have hlt : lo < hi := by simp at hlen; omega
    have hb : a.get! lo = 0x5b := by
      rw [slice_cons a hlt h'] at hv; simp only [List.append_assoc, List.cons_append] at hv
      exact (List.cons.inj hv).1
    rw [ite_eq_left (by simp [Http.byte, hlt, hb])]
    dsimp only
    have hs : slice a lo hi = (0x5b :: x) ++ 0x5d :: rest := by rw [hv]; simp
    have hnot : (0x5d : UInt8) ∉ 0x5b :: x := by
      intro hm
      rcases List.mem_cons.mp hm with hm | hm
      · exact absurd hm (by decide)
      · exact (ipLit_mem hx _ hm).1 rfl
    obtain ⟨e, he, hsx, hsy⟩ := cut_at a 0x5d h h' hs hnot
    simp only [List.length_cons] at e he hsx hsy
    obtain ⟨-, -, hxs⟩ := (slice_cons_iff a (by omega)).mp hsx
    have hcond : (Decidable.decide (lo + (x.length + 1) < hi) && Http.ipLiteral a (lo + 1) (lo + (x.length + 1)) &&
        Http.portOk a (lo + (x.length + 1) + 1) hi) = true := by
      simp only [Bool.and_eq_true, decide_eq_true_eq]
      exact ⟨⟨he, (ipLiteral_iff a (by omega) (by omega)).mpr (by rw [hxs]; exact hx)⟩,
        (portOk_iff a h').mpr (by rw [hsy]; exact hrest)⟩
    rw [e, ite_eq_left hcond, show ([0x5b] ++ x ++ [0x5d] : List UInt8).length = x.length + 2 by simp]
    congr 1

/-- info: 'Feed.Http.hostEnd_of' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Http.hostEnd_of

/-- **The Host value**: `hostOk` accepts a range exactly when it is RFC 9110 §7.2's
`uri-host [ ":" port ]` (`Spec.Http.HostPort`, with RFC 3986's IP-literal, IPv4address and
reg-name). -/
theorem _root_.Feed.Http.hostOk_iff (a : ByteArray) {lo hi : Nat} (h : lo ≤ hi) (h' : hi ≤ a.size) :
    Http.hostOk a lo hi = true ↔ ∃ host, Spec.Http.HostPort (slice a lo hi) host := by
  unfold Http.hostOk
  constructor
  · intro hs
    obtain ⟨e, he⟩ := Option.isSome_iff_exists.mp hs
    exact ⟨_, (Http.hostEnd_some h h' he).2.2⟩
  · rintro ⟨host, hp⟩
    rw [Http.hostEnd_of h h' hp]
    rfl

/-- info: 'Feed.Http.hostOk_iff' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Http.hostOk_iff

/-! ## Request-targets (RFC 9112 §3.2, RFC 3986 §3 and §4.3) -/

private theorem userinfo_mem {i : List UInt8} (h : UriChars (· == 0x3a) i) :
    ∀ c ∈ i, c ≠ 0x40 ∧ c ≠ 0x2f ∧ c ≠ 0x3f := by
  have key : ∀ c : UInt8, (isUnreserved c || isSubDelim c || c == 0x3a || c == 0x25) = true →
      c ≠ 0x40 ∧ c ≠ 0x2f ∧ c ≠ 0x3f := by decide +kernel
  exact fun c hc => key c (uriChars_mem h c hc)

private theorem authority_iff (a : ByteArray) {lo hi : Nat} (h : lo ≤ hi) (h' : hi ≤ a.size) :
    Http.authority a lo hi = true ↔ Authority (slice a lo hi) := by
  unfold Http.authority
  dsimp only
  by_cases hat : Bytes.findByte a 0x40 lo hi < hi
  · rw [ite_eq_left hat]
    obtain ⟨h1, hnot, hs⟩ := cut_found a 0x40 h h' hat
    generalize Bytes.findByte a 0x40 lo hi = e at *
    rw [Bool.and_eq_true, uriChars_iff _ _ (· == 0x3a) user_set rfl a (by omega), Http.hostOk_iff a (by omega) h']
    constructor
    · rintro ⟨hu, host, hp⟩
      exact ⟨slice a lo e ++ [0x40], slice a (e + 1) hi, host, .inr ⟨_, hu, rfl⟩, hp, by rw [hs]; simp⟩
    · rintro ⟨u, v, host, hu, hp, hs'⟩
      rcases hu with rfl | ⟨i, hi', rfl⟩
      · rw [List.nil_append] at hs'
        exact absurd rfl (hostPort_mem hp 0x40 (by rw [← hs', hs]; simp)).1
      · rw [hs, List.append_assoc, List.singleton_append] at hs'
        obtain ⟨rfl, rfl⟩ := cut_unique' hs' hnot (fun hm => (userinfo_mem hi' _ hm).1 rfl)
        exact ⟨hi', host, hp⟩
  · rw [ite_eq_right hat, Http.hostOk_iff a h h']
    have he : Bytes.findByte a 0x40 lo hi = hi := by have := (findByte_cut a 0x40 h h').2.1; omega
    have hnot := (findByte_spec a 0x40 h h').mp he
    constructor
    · rintro ⟨host, hp⟩; exact ⟨[], _, host, .inl rfl, hp, rfl⟩
    · rintro ⟨u, v, host, hu, hp, hs'⟩
      rcases hu with rfl | ⟨i, -, rfl⟩
      · rw [List.nil_append] at hs'; exact ⟨host, hs' ▸ hp⟩
      · exact absurd (by rw [hs']; simp) hnot

/-- No "/" or "?" in an authority. -/
private theorem authority_mem {s : List UInt8} (h : Authority s) : ∀ c ∈ s, c ≠ 0x2f ∧ c ≠ 0x3f := by
  obtain ⟨u, v, host, hu, hp, rfl⟩ := h
  intro c hm
  rcases List.mem_append.mp hm with hm | hm
  · rcases hu with rfl | ⟨i, hi, rfl⟩
    · exact absurd hm List.not_mem_nil
    · rcases List.mem_append.mp hm with hm | hm
      · exact ⟨(userinfo_mem hi _ hm).2.1, (userinfo_mem hi _ hm).2.2⟩
      · rw [List.mem_singleton.mp hm]; decide
  · exact ⟨(hostPort_mem hp _ hm).2.1, (hostPort_mem hp _ hm).2.2⟩

private theorem pathChars_mem {p : List UInt8} (h : PathChars p) : 0x3f ∉ p := fun hm =>
  absurd (uriChars_mem h _ hm) (by decide)

/-- A range starts with "//". -/
private theorem slice_take2 (a : ByteArray) {lo hi : Nat} (h' : hi ≤ a.size) :
    (slice a lo hi).take 2 = [0x2f, 0x2f] ↔ lo + 2 ≤ hi ∧ a.get! lo = 0x2f ∧ a.get! (lo + 1) = 0x2f := by
  constructor
  · intro ht
    have hl := congrArg List.length ht
    rw [List.length_take, slice_length a h'] at hl
    have h2 : lo + 2 ≤ hi := by simp at hl; omega
    rw [slice_cons a (by omega) h', slice_cons a (by omega) h'] at ht
    simp only [List.take_succ_cons, List.take_zero, List.cons.injEq] at ht
    exact ⟨h2, ht.1, ht.2.1⟩
  · rintro ⟨h2, h0, h1⟩
    rw [slice_cons a (by omega) h', slice_cons a (by omega) h', h0, h1]
    rfl

private theorem hierPart_iff (a : ByteArray) {lo hi : Nat} (h' : hi ≤ a.size) :
    Http.hierPart a lo hi = true ↔ HierPart (slice a lo hi) := by
  have hsl : Spec.lit "//" = [0x2f, 0x2f] := rfl
  unfold Http.hierPart
  by_cases hc : (Decidable.decide (lo + 2 ≤ hi) && Http.byte a lo == 0x2f && Http.byte a (lo + 1) == 0x2f) = true
  · rw [ite_eq_left hc]
    dsimp only
    simp only [Bool.and_eq_true, decide_eq_true_eq, beq_iff_eq, Http.byte] at hc
    obtain ⟨⟨h2, hb0⟩, hb1⟩ := hc
    have hs : slice a lo hi = [0x2f, 0x2f] ++ slice a (lo + 2) hi := by
      rw [slice_cons a (by omega) h', slice_cons a (by omega) h', hb0, hb1]; rfl
    obtain ⟨h1, h2', hnot, hget⟩ := findByte_cut a 0x2f (lo := lo + 2) h2 h'
    generalize Bytes.findByte a 0x2f (lo + 2) hi = e at *
    have hp0 : slice a e hi = [] ∨ (slice a e hi).head? = some 0x2f := by
      by_cases he : e < hi
      · right; rw [slice_cons a he h', hget he]; rfl
      · left; exact slice_nil_of_le a (by omega)
    rw [Bool.and_eq_true, authority_iff a h1 (by omega), uriChars_iff _ _ _ path_set rfl a h']
    constructor
    · rintro ⟨ha, hp⟩
      refine .inl ⟨slice a (lo + 2) e, slice a e hi, ha, hp0, hp, ?_⟩
      rw [hs, hsl, slice_append a h1 h2', List.append_assoc]
    · rintro (⟨A, P, ha, hP0, hp, hs'⟩ | ⟨-, hn⟩)
      · rw [hs, hsl, List.append_assoc] at hs'
        have hs'' := List.append_cancel_left hs'
        rw [slice_append a h1 h2'] at hs''
        obtain ⟨rfl, rfl⟩ := cut_unique hs'' hnot (fun hm => (authority_mem ha _ hm).1 rfl) hp0 hP0
        exact ⟨ha, hp⟩
      · exact absurd (by rw [hs]; rfl) hn
  · rw [ite_eq_right hc, uriChars_iff _ _ _ path_set rfl a h']
    have hn : (slice a lo hi).take 2 ≠ Spec.lit "//" := fun ht => by
      rw [hsl, slice_take2 a h'] at ht
      exact hc (by simp [Http.byte, ht.1, ht.2.1, ht.2.2])
    constructor
    · exact fun hp => .inr ⟨hp, hn⟩
    · rintro (⟨A, P, -, -, -, hs'⟩ | ⟨hp, -⟩)
      · exact absurd (by rw [hs']; simp [hsl]) hn
      · exact hp

private theorem scheme_colon {s : List UInt8} (h : Scheme s) : 0x3a ∉ s := fun hm => absurd (h.2 _ hm) (by decide)

private theorem scheme_mem {s : List UInt8} (h : Scheme s) : ∀ c ∈ s, c ≠ 0x3f ∧ c ≠ 0x2f := by
  have key : ∀ c : UInt8, (isAlpha c || isDigit c || (Spec.lit "+-.").contains c) = true → c ≠ 0x3f ∧ c ≠ 0x2f := by
    decide +kernel
  exact fun c hc => key c (h.2 c hc)

private theorem otherScheme_iff (a : ByteArray) {lo hi : Nat} (h : lo ≤ hi) (h' : hi ≤ a.size) :
    Http.otherScheme a lo hi = true ↔ ∃ sch hp, Scheme sch ∧ Spec.Http.lower sch ≠ Spec.lit "http" ∧
      Spec.Http.lower sch ≠ Spec.lit "https" ∧ HierPart hp ∧ slice a lo hi = sch ++ [0x3a] ++ hp := by
  have k1 : bs Http.kHttp = Spec.lit "http" := rfl
  have k2 : bs Http.kHttps = Spec.lit "https" := rfl
  unfold Http.otherScheme
  dsimp only
  simp only [Bool.and_eq_true, decide_eq_true_eq, Bool.not_eq_true']
  constructor
  · rintro ⟨⟨⟨⟨⟨⟨hc, hlo⟩, hal⟩, hset⟩, h1⟩, h2⟩, hh⟩
    obtain ⟨-, -, hs⟩ := cut_found a 0x3a h h' hc
    generalize Bytes.findByte a 0x3a lo hi = c at *
    refine ⟨slice a lo c, slice a (c + 1) hi, ⟨?_, fun x hx => ?_⟩, fun he => ?_, fun he => ?_,
      (hierPart_iff a h').mp hh, by rw [hs]; simp⟩
    · rw [slice_cons a hlo (by omega)]; simpa [Http.byte, alpha_eq] using hal
    · rw [← scheme_set]; exact (allIn_iff _ _ a (by omega)).mp hset x hx
    · rw [← k1, ← eqCI_iff a _ (by omega) (by omega)] at he; rw [he] at h1; exact Bool.noConfusion h1
    · rw [← k2, ← eqCI_iff a _ (by omega) (by omega)] at he; rw [he] at h2; exact Bool.noConfusion h2
  · rintro ⟨sch, hp, hsch, n1, n2, hh, hs⟩
    rw [List.append_assoc, List.singleton_append] at hs
    obtain ⟨e, hlt, hsx, hsy⟩ := cut_at a 0x3a h h' hs (scheme_colon hsch)
    rw [e]
    have hne : sch ≠ [] := fun h0 => by have := hsch.1; rw [h0] at this; exact Bool.noConfusion this
    have hlo : lo < lo + sch.length := by
      have : sch.length ≠ 0 := fun h0 => hne (List.eq_nil_of_length_eq_zero h0)
      omega
    refine ⟨⟨⟨⟨⟨⟨hlt, hlo⟩, ?_⟩, (allIn_iff _ _ a (by omega)).mpr (fun x hx => ?_)⟩, ?_⟩, ?_⟩,
      (hierPart_iff a h').mpr (by rw [hsy]; exact hh)⟩
    · obtain ⟨x, sch', rfl⟩ := List.exists_cons_of_ne_nil hne
      rw [slice_cons a hlo (by omega), List.cons.injEq] at hsx
      have := hsch.1
      simp only [List.head?_cons, Option.any_some] at this
      rw [Http.byte, alpha_eq, hsx.1]; exact this
    · rw [scheme_set]; rw [hsx] at hx; exact hsch.2 x hx
    · rw [Bool.eq_false_iff]; intro he
      rw [eqCI_iff a _ (by omega) (by omega), hsx, k1] at he; exact n1 he
    · rw [Bool.eq_false_iff]; intro he
      rw [eqCI_iff a _ (by omega) (by omega), hsx, k2] at he; exact n2 he

/-! ### The absolute-form of http and https (RFC 9110 §4.2) -/

/-- An http or https absolute-form without its query: the scheme, "://", the authority, which has a
host and no userinfo, and the path (`Spec.Http.AbsoluteForm`). -/
private def AbsPart (x path : List UInt8) : Prop :=
  ∃ sch auth host, (Spec.Http.lower sch = Spec.lit "http" ∨ Spec.Http.lower sch = Spec.lit "https") ∧
    HostPort auth host ∧ host ≠ [] ∧ (path = [] ∨ path.head? = some 0x2f) ∧ PathChars path ∧
    x = sch ++ Spec.lit "://" ++ auth ++ path

private def lowerB (c : UInt8) : UInt8 := if 0x41 ≤ c ∧ c ≤ 0x5a then c + 32 else c

private theorem lower_eq_map (x : List UInt8) : Spec.Http.lower x = x.map lowerB := rfl

private theorem lower_sep {y : List UInt8} (h : Spec.Http.lower y = Spec.lit "://") : y = Spec.lit "://" := by
  have k1 : ∀ c : UInt8, lowerB c = 0x3a → c = 0x3a := by decide +kernel
  have k2 : ∀ c : UInt8, lowerB c = 0x2f → c = 0x2f := by decide +kernel
  rw [lower_eq_map] at h
  rw [show Spec.lit "://" = [0x3a, 0x2f, 0x2f] from rfl] at h ⊢
  match y, h with
  | [x, y, z], h =>
    simp only [List.map_cons, List.map_nil, List.cons.injEq, and_true] at h
    rw [k1 x h.1, k2 y h.2.1, k2 z h.2.2]
  | [], h | [_], h | [_, _], h | _ :: _ :: _ :: _ :: _, h => simp at h

/-- The bytes of "http" and "https" in any case: no ":", "/" or "?", and an "h" first. -/
private theorem httpScheme_mem {sch : List UInt8}
    (h : Spec.Http.lower sch = Spec.lit "http" ∨ Spec.Http.lower sch = Spec.lit "https") :
    (∀ c ∈ sch, c ≠ 0x3a ∧ c ≠ 0x2f ∧ c ≠ 0x3f) ∧ ∃ c r, sch = c :: r ∧ (c = 0x68 ∨ c = 0x48) := by
  have k : ∀ c : UInt8, c = 0x3a ∨ c = 0x2f ∨ c = 0x3f → lowerB c = c := by decide +kernel
  have kh : ∀ c : UInt8, lowerB c = 0x68 → c = 0x68 ∨ c = 0x48 := by decide +kernel
  have hlow : ∀ c ∈ Spec.Http.lower sch, c ≠ 0x3a ∧ c ≠ 0x2f ∧ c ≠ 0x3f := by
    rcases h with h | h <;> rw [h] <;> decide
  refine ⟨fun c hc => ?_, ?_⟩
  · refine ⟨fun he => ?_, fun he => ?_, fun he => ?_⟩
    · have := List.mem_map_of_mem (f := lowerB) hc
      rw [k c (.inl he), ← lower_eq_map] at this
      exact (hlow c this).1 he
    · have := List.mem_map_of_mem (f := lowerB) hc
      rw [k c (.inr (.inl he)), ← lower_eq_map] at this
      exact (hlow c this).2.1 he
    · have := List.mem_map_of_mem (f := lowerB) hc
      rw [k c (.inr (.inr he)), ← lower_eq_map] at this
      exact (hlow c this).2.2 he
  · match sch, h with
    | c :: r, h =>
      refine ⟨c, r, rfl, kh c ?_⟩
      rcases h with h | h <;> rw [lower_eq_map, List.map_cons] at h <;> exact (List.cons.inj h).1
    | [], h => rcases h with h | h <;> exact absurd h (by decide)

/-- What follows the scheme in `absolutePath`: the authority up to the first "/", and the path. -/
private def absRest (a : ByteArray) (s hi : Nat) : Option (Nat × Nat) :=
  match Http.hostEnd a s (Bytes.findByte a 0x2f s hi) with
  | some h => if s < h && Http.uriChars Http.pathLo Http.pathHi a (Bytes.findByte a 0x2f s hi) hi then
      some (Bytes.findByte a 0x2f s hi, hi) else none
  | none => none

private theorem absolutePath_eq (a : ByteArray) (lo hi : Nat) : Http.absolutePath a lo hi =
    if (if lo + 7 ≤ hi && Http.eqCI a lo (lo + 7) Http.kHttpSlashes then lo + 7
      else if lo + 8 ≤ hi && Http.eqCI a lo (lo + 8) Http.kHttpsSlashes then lo + 8 else lo) == lo then none
    else absRest a (if lo + 7 ≤ hi && Http.eqCI a lo (lo + 7) Http.kHttpSlashes then lo + 7
      else if lo + 8 ≤ hi && Http.eqCI a lo (lo + 8) Http.kHttpsSlashes then lo + 8 else lo) hi := rfl

private theorem absRest_some {a : ByteArray} {s hi plo phi : Nat} (h : s ≤ hi) (h' : hi ≤ a.size)
    (he : absRest a s hi = some (plo, phi)) :
    s ≤ plo ∧ plo ≤ hi ∧ phi = hi ∧ ∃ host, HostPort (slice a s plo) host ∧ host ≠ [] ∧
      (slice a plo hi = [] ∨ (slice a plo hi).head? = some 0x2f) ∧ PathChars (slice a plo hi) := by
  obtain ⟨h1, h2, -, hget⟩ := findByte_cut a 0x2f h h'
  unfold absRest at he
  generalize Bytes.findByte a 0x2f s hi = e at *
  split at he
  · rename_i hh hhe
    split at he
    · rename_i hc
      simp only [Option.some.injEq, Prod.mk.injEq] at he
      obtain ⟨he1, he2⟩ := he
      subst he1 he2
      simp only [Bool.and_eq_true, decide_eq_true_eq] at hc
      obtain ⟨hlt, hp⟩ := hc
      obtain ⟨-, hh2, hport⟩ := Http.hostEnd_some h1 (by omega) hhe
      refine ⟨h1, h2, rfl, slice a s hh, hport, fun he => ?_, ?_,
        (uriChars_iff _ _ _ path_set rfl a h').mp hp⟩
      · have := slice_length a (lo := s) (hi := hh) (by omega); rw [he] at this; simp at this; omega
      · by_cases hlt' : e < hi
        · right; rw [slice_cons a hlt' h', hget hlt']; rfl
        · left; exact slice_nil_of_le a (by omega)
    · exact absurd he (by simp)
  · exact absurd he (by simp)

private theorem absRest_of {a : ByteArray} {s hi : Nat} (h : s ≤ hi) (h' : hi ≤ a.size)
    {auth host path : List UInt8} (hs : slice a s hi = auth ++ path) (hp : HostPort auth host) (hne : host ≠ [])
    (hp0 : path = [] ∨ path.head? = some 0x2f) (hpc : PathChars path) :
    absRest a s hi = some (s + auth.length, hi) ∧ slice a (s + auth.length) hi = path := by
  obtain ⟨hl, hsa, hsp⟩ := (slice_append_iff a h h').mp hs
  have he : Bytes.findByte a 0x2f s hi = s + auth.length := by
    rcases hp0 with rfl | hp0
    · rw [List.append_nil] at hs
      rw [findByte_of_not_mem a 0x2f h h' (by rw [hs]; exact fun hm => (hostPort_mem hp _ hm).2.1 rfl)]
      have := slice_length a (lo := s) h'; rw [hs] at this; omega
    · obtain ⟨x, r, rfl⟩ : ∃ x r, path = x :: r := by
        match path, hp0 with
        | x :: r, _ => exact ⟨x, r, rfl⟩
      simp only [List.head?_cons, Option.some.injEq] at hp0
      subst hp0
      exact findByte_of_eq a 0x2f h h' hs (fun hm => (hostPort_mem hp _ hm).2.1 rfl)
  refine ⟨?_, hsp⟩
  unfold absRest
  rw [he, Http.hostEnd_of (by omega) (by omega) (by rw [hsa]; exact hp)]
  dsimp only
  rw [ite_eq_left]
  simp only [Bool.and_eq_true, decide_eq_true_eq]
  refine ⟨?_, (uriChars_iff _ _ _ path_set rfl a h').mpr (by rw [hsp]; exact hpc)⟩
  have : host.length ≠ 0 := fun h0 => hne (List.eq_nil_of_length_eq_zero h0)
  omega

/-- The scheme of an absolute-form, as `absolutePath` checks it. -/
private theorem scheme_cut (a : ByteArray) {lo hi : Nat} (h' : hi ≤ a.size) (n : Nat) (hn : lo + n + 3 ≤ hi)
    {lit : List UInt8} (hl : lit.length = n)
    (he : Spec.Http.lower (slice a lo (lo + n + 3)) = lit ++ Spec.lit "://") :
    Spec.Http.lower (slice a lo (lo + n)) = lit ∧ slice a lo hi = slice a lo (lo + n) ++ Spec.lit "://" ++
      slice a (lo + n + 3) hi := by
  rw [slice_append a (m := lo + n) (by omega) (by omega), lower_eq_map, List.map_append, ← lower_eq_map,
    ← lower_eq_map] at he
  obtain ⟨h1, h2⟩ := List.append_inj he (by rw [lower_eq_map, List.length_map, slice_length a (by omega), hl]; omega)
  refine ⟨h1, ?_⟩
  rw [← lower_sep h2, slice_append a (m := lo + n + 3) (by omega) hn,
    slice_append a (lo := lo) (m := lo + n) (by omega) (by omega)]

private theorem absolutePath_some {a : ByteArray} {lo hi plo phi : Nat} (h : lo ≤ hi) (h' : hi ≤ a.size)
    (he : Http.absolutePath a lo hi = some (plo, phi)) :
    lo ≤ plo ∧ plo ≤ phi ∧ phi = hi ∧ AbsPart (slice a lo hi) (slice a plo phi) := by
  have k7 : bs Http.kHttpSlashes = Spec.lit "http" ++ Spec.lit "://" := rfl
  have k8 : bs Http.kHttpsSlashes = Spec.lit "https" ++ Spec.lit "://" := rfl
  rw [absolutePath_eq] at he
  have key : ∀ n, lo + n + 3 ≤ hi → ∀ lit : List UInt8, lit.length = n →
      (lit = Spec.lit "http" ∨ lit = Spec.lit "https") →
      Spec.Http.lower (slice a lo (lo + n + 3)) = lit ++ Spec.lit "://" → absRest a (lo + n + 3) hi = some (plo, phi) →
      lo ≤ plo ∧ plo ≤ phi ∧ phi = hi ∧ AbsPart (slice a lo hi) (slice a plo phi) := by
    intro n hn lit hl hlit hlow hr
    obtain ⟨hs1, hs2⟩ := scheme_cut a h' n hn hl hlow
    obtain ⟨g1, g2, rfl, host, hp, hne, hp0, hpc⟩ := absRest_some hn h' hr
    refine ⟨by omega, g2, rfl, slice a lo (lo + n), slice a (lo + n + 3) plo, host, ?_, hp, hne, hp0, hpc, ?_⟩
    · rw [hs1]; exact hlit
    · rw [hs2, slice_append a (lo := lo + n + 3) (m := plo) g1 g2]; simp
  split at he
  · rename_i h7
    simp only [Bool.and_eq_true, decide_eq_true_eq] at h7
    rw [ite_eq_right (by simp)] at he
    exact key 4 h7.1 _ rfl (.inl rfl) (by rw [← k7, ← eqCI_iff a _ (by omega) (by omega)]; exact h7.2) he
  · split at he
    · rename_i _ h8
      simp only [Bool.and_eq_true, decide_eq_true_eq] at h8
      rw [ite_eq_right (by simp)] at he
      exact key 5 h8.1 _ rfl (.inr rfl) (by rw [← k8, ← eqCI_iff a _ (by omega) (by omega)]; exact h8.2) he
    · exact absurd he (by simp)

private theorem absolutePath_of {a : ByteArray} {lo hi : Nat} (h : lo ≤ hi) (h' : hi ≤ a.size)
    {path : List UInt8} (hp : AbsPart (slice a lo hi) path) :
    ∃ plo, Http.absolutePath a lo hi = some (plo, hi) ∧ slice a plo hi = path := by
  have k7 : bs Http.kHttpSlashes = Spec.lit "http" ++ Spec.lit "://" := rfl
  have k8 : bs Http.kHttpsSlashes = Spec.lit "https" ++ Spec.lit "://" := rfl
  have h3 : (Spec.lit "://").length = 3 := rfl
  obtain ⟨sch, auth, host, hsch, hhp, hne, hp0, hpc, hs⟩ := hp
  have hlen := congrArg List.length hs
  rw [slice_length a h'] at hlen
  simp only [List.length_append, h3] at hlen
  rw [List.append_assoc, List.append_assoc] at hs
  obtain ⟨-, hsch', hrest⟩ := (slice_append_iff a h h').mp hs
  obtain ⟨-, hsep, hrest'⟩ := (slice_append_iff a (by omega) h').mp hrest
  rw [h3] at hsep hrest'
  have hpre : Spec.Http.lower (slice a lo (lo + sch.length + 3)) = Spec.Http.lower sch ++ Spec.lit "://" := by
    rw [slice_append a (m := lo + sch.length) (by omega) (by omega), lower_eq_map, List.map_append, ← lower_eq_map,
      ← lower_eq_map, hsch', hsep]
    rfl
  have hsl : (Spec.Http.lower sch).length = sch.length := by rw [lower_eq_map, List.length_map]
  rw [absolutePath_eq]
  rcases hsch with h4 | h5
  · have hn : sch.length = 4 := by rw [← hsl, h4]; rfl
    have hc7 : (Decidable.decide (lo + 7 ≤ hi) && Http.eqCI a lo (lo + 7) Http.kHttpSlashes) = true := by
      simp only [Bool.and_eq_true, decide_eq_true_eq]
      refine ⟨by omega, (eqCI_iff a _ (by omega) (by omega)).mpr ?_⟩
      rw [k7, ← h4, show lo + 7 = lo + sch.length + 3 by omega, hpre]
    rw [ite_eq_left hc7, ite_eq_right (by simp)]
    obtain ⟨hr, hpath⟩ := absRest_of (s := lo + 7) (by omega) h'
      (by rw [show lo + 7 = lo + sch.length + 3 by omega]; exact hrest') hhp hne hp0 hpc
    exact ⟨_, hr, hpath⟩
  · have hn : sch.length = 5 := by rw [← hsl, h5]; rfl
    have hc7 : ¬ (Decidable.decide (lo + 7 ≤ hi) && Http.eqCI a lo (lo + 7) Http.kHttpSlashes) = true := by
      simp only [Bool.and_eq_true, decide_eq_true_eq, not_and]
      intro _ he
      rw [eqCI_iff a _ (by omega) (by omega), k7] at he
      have h5' := congrArg (List.take 5) he
      rw [lower_eq_map, ← List.map_take, slice_take a 5 (by omega), ← lower_eq_map] at h5'
      rw [hn] at hsch'
      rw [hsch', h5] at h5'
      exact absurd h5' (by decide)
    have hc8 : (Decidable.decide (lo + 8 ≤ hi) && Http.eqCI a lo (lo + 8) Http.kHttpsSlashes) = true := by
      simp only [Bool.and_eq_true, decide_eq_true_eq]
      refine ⟨by omega, (eqCI_iff a _ (by omega) (by omega)).mpr ?_⟩
      rw [k8, ← h5, show lo + 8 = lo + sch.length + 3 by omega, hpre]
    rw [ite_eq_right hc7, ite_eq_left hc8, ite_eq_right (by simp)]
    obtain ⟨hr, hpath⟩ := absRest_of (s := lo + 8) (by omega) h'
      (by rw [show lo + 8 = lo + sch.length + 3 by omega]; exact hrest') hhp hne hp0 hpc
    exact ⟨_, hr, hpath⟩

/-! ### The target -/

/-- The query: a target is its part before the first "?", then nothing or "?" and the query. -/
private theorem withQuery_iff (a : ByteArray) {lo hi : Nat} (h : lo ≤ hi) (h' : hi ≤ a.size) {p : List UInt8}
    (hp : 0x3f ∉ p) :
    WithQuery (slice a lo hi) p ↔ p = slice a lo (Bytes.findByte a 0x3f lo hi) ∧
      (Decidable.decide (hi ≤ Bytes.findByte a 0x3f lo hi) ||
        Http.uriChars Http.queryLo Http.queryHi a (Bytes.findByte a 0x3f lo hi + 1) hi) = true := by
  obtain ⟨h1, h2, -, hget⟩ := findByte_cut a 0x3f h h'
  constructor
  · rintro (hs | ⟨q, hq, hs⟩)
    · rw [findByte_of_not_mem a 0x3f h h' (by rw [hs]; exact hp)]
      exact ⟨hs.symm, by simp⟩
    · rw [List.append_assoc, List.singleton_append] at hs
      obtain ⟨e, -, hsx, hsy⟩ := cut_at a 0x3f h h' hs hp
      rw [e]
      refine ⟨hsx.symm, ?_⟩
      simp only [Bool.or_eq_true, decide_eq_true_eq]
      exact .inr ((uriChars_iff _ _ _ query_set rfl a h').mpr (by rw [hsy]; exact hq))
  · rintro ⟨rfl, hq⟩
    simp only [Bool.or_eq_true, decide_eq_true_eq] at hq
    generalize Bytes.findByte a 0x3f lo hi = q at *
    by_cases hlt : q < hi
    · rcases hq with hq | hq
      · omega
      · refine .inr ⟨_, (uriChars_iff _ _ _ query_set rfl a h').mp hq, ?_⟩
        rw [slice_append a h1 (Nat.le_of_lt hlt), slice_cons a hlt h', hget hlt]; simp
    · exact .inl (by rw [show q = hi by omega])

private theorem hierPart_mem {h : List UInt8} (hh : HierPart h) : 0x3f ∉ h := by
  rcases hh with ⟨A, P, ha, -, hp, rfl⟩ | ⟨hp, -⟩
  · intro hm
    simp only [List.mem_append] at hm
    rcases hm with (hm | hm) | hm
    · exact absurd hm (by decide)
    · exact (authority_mem ha _ hm).2 rfl
    · exact pathChars_mem hp hm
  · exact pathChars_mem hp

/-- An http or https absolute-form starts with its scheme and ":", then "/". -/
private theorem absPart_cut {x p : List UInt8} (h : AbsPart x p) :
    ∃ sch rest, x = sch ++ 0x3a :: rest ∧ 0x3a ∉ sch ∧
      (Spec.Http.lower sch = Spec.lit "http" ∨ Spec.Http.lower sch = Spec.lit "https") ∧
      rest.head? = some 0x2f ∧ (∃ c r, sch = c :: r ∧ (c = 0x68 ∨ c = 0x48)) ∧ 0x3f ∉ x := by
  obtain ⟨sch, auth, host, hsch, hhp, -, -, hpc, rfl⟩ := h
  obtain ⟨hm, hc⟩ := httpScheme_mem hsch
  refine ⟨sch, 0x2f :: 0x2f :: (auth ++ p), by simp [show Spec.lit "://" = [0x3a, 0x2f, 0x2f] from rfl],
    fun hc' => (hm _ hc').1 rfl, hsch, rfl, hc, fun hq => ?_⟩
  simp only [List.mem_append] at hq
  rcases hq with ((hq | hq) | hq) | hq
  · exact (hm _ hq).2.2 rfl
  · exact absurd hq (by decide)
  · exact (hostPort_mem hhp _ hq).2.2 rfl
  · exact pathChars_mem hpc hq

/-- The authority-form, from `hostEnd`. -/
private theorem authForm_of {a : ByteArray} {lo hi e : Nat} (h : lo ≤ hi) (h' : hi ≤ a.size)
    (he : Http.hostEnd a lo hi = some e) (hlt : e < hi) :
    ∃ hh p, HostPort (hh ++ [0x3a] ++ p) hh ∧ slice a lo hi = hh ++ [0x3a] ++ p := by
  obtain ⟨h1, -, hp⟩ := Http.hostEnd_some h h' he
  obtain ⟨hh, rest, hv, hr⟩ := hostPort_parts.mp hp
  rcases hr with rfl | ⟨p, hpd, rfl⟩
  · rw [List.append_nil] at hv
    have := slice_length a (lo := lo) (hi := e) (by omega)
    rw [← hv, slice_length a h'] at this
    omega
  · have hv' : slice a lo hi = slice a lo e ++ [0x3a] ++ p := by rw [hv]; simp
    exact ⟨_, p, hostPort_parts.mpr ⟨hh, 0x3a :: p, by simp, .inr ⟨p, hpd, rfl⟩⟩, hv'⟩

private theorem hostEnd_of_authForm {a : ByteArray} {lo hi : Nat} (h : lo ≤ hi) (h' : hi ≤ a.size)
    {hh p : List UInt8} (hp : HostPort (hh ++ [0x3a] ++ p) hh) (hs : slice a lo hi = hh ++ [0x3a] ++ p) :
    Http.hostEnd a lo hi = some (lo + hh.length) ∧ lo + hh.length < hi := by
  refine ⟨Http.hostEnd_of h h' (by rw [hs]; exact hp), ?_⟩
  have := congrArg List.length hs
  rw [slice_length a h'] at this
  simp only [List.length_append, List.length_singleton] at this
  omega

/-- No target but an origin-form starts with "/". -/
private theorem other_head {t : List UInt8} (ho : OtherTarget t) : t.head? ≠ some 0x2f := by
  rcases ho with rfl | ⟨hh, p, hp, rfl⟩ | ⟨sch, hp, hsch, -, -, -, hw⟩
  · decide
  · obtain ⟨hhost, -⟩ := hostPort_parts.mp hp
    match hh, hhost with
    | [], _ => simp
    | c :: r, hhost => simp only [List.cons_append, List.head?_cons, ne_eq, Option.some.injEq]
                       exact (uriHost_mem hhost c List.mem_cons_self).2.1
  · have hne : sch ≠ [] := fun h0 => by have := hsch.1; rw [h0] at this; exact Bool.noConfusion this
    obtain ⟨c, r, rfl⟩ := List.exists_cons_of_ne_nil hne
    have hc : c ≠ 0x2f := (scheme_mem hsch c List.mem_cons_self).2
    rcases hw with rfl | ⟨q, -, rfl⟩ <;> simpa using hc

/-- The http and https absolute-form is no other form; `x` is the target `t` up to its first "?". -/
private theorem absPart_not_other {t x p : List UInt8} (ha : AbsPart x p) (hqi : 0x3f ∉ t → x = t)
    (wq : ∀ y, 0x3f ∉ y → WithQuery t y → y = x) : ¬ OtherTarget t := by
  obtain ⟨sch, rest, hx, hc, hsch, hr, ⟨c0, r0, hc0, hh0⟩, -⟩ := absPart_cut ha
  obtain ⟨r1, rest', rfl⟩ : ∃ r1 rest', rest = r1 :: rest' := by
    match rest, hr with
    | r1 :: rest', _ => exact ⟨r1, rest', rfl⟩
  simp only [List.head?_cons, Option.some.injEq] at hr
  subst hr
  rintro (ht | ⟨hh, p', hp, ht⟩ | ⟨sch', hp', hsch', n1, n2, hhp, hw⟩)
  · rw [hqi (by rw [ht]; decide), ht, show Spec.lit "*" = [0x2a] from rfl] at hx
    have := congrArg List.length hx
    simp at this
    omega
  · rw [hqi (by rw [ht]; exact fun hm => (hostPort_mem hp _ hm).2.2 rfl), ht] at hx
    obtain ⟨hhost, rest2, hv, hr2⟩ := hostPort_parts.mp hp
    rcases hhost with hreg | ⟨y, -, rfl⟩
    · rw [List.append_assoc, List.singleton_append] at hx
      obtain ⟨rfl, rfl⟩ := cut_unique' hx (fun hm => (regName_mem hreg _ hm).1 rfl) hc
      rw [List.append_assoc, List.singleton_append] at hv
      have hv' := List.append_cancel_left hv
      rcases hr2 with rfl | ⟨p2, hp2, rfl⟩
      · exact List.cons_ne_nil _ _ hv'
      · rw [List.cons.injEq] at hv'
        exact absurd (hp2 0x2f (by rw [← hv'.2]; exact List.mem_cons_self)) (by decide)
    · rw [hc0] at hx
      simp only [List.append_assoc, List.cons_append, List.cons.injEq] at hx
      rw [← hx.1] at hh0
      rcases hh0 with h1 | h1 <;> exact absurd h1 (by decide)
  · have hx' := wq _ (fun hm => by
      simp only [List.mem_append, List.mem_singleton] at hm
      rcases hm with (hm | hm) | hm
      · exact (scheme_mem hsch' _ hm).1 rfl
      · exact absurd hm (by decide)
      · exact hierPart_mem hhp hm) hw
    rw [hx, List.append_assoc, List.singleton_append] at hx'
    obtain ⟨rfl, -⟩ := cut_unique' hx' (scheme_colon hsch') hc
    rcases hsch with h | h
    · exact n1 h
    · exact n2 h

/-- The target's part before its first "?". -/
private theorem target_cut (a : ByteArray) {lo hi : Nat} (h : lo ≤ hi) (h' : hi ≤ a.size) :
    let q := Bytes.findByte a 0x3f lo hi
    lo ≤ q ∧ q ≤ hi ∧ (0x3f ∉ slice a lo hi → q = hi) ∧ (∀ c ∈ slice a lo q, c ≠ 0x3f) := by
  obtain ⟨h1, h2, hn, hg⟩ := findByte_cut a 0x3f h h'
  refine ⟨h1, h2, fun hm => Nat.le_antisymm h2 (Nat.le_of_not_lt fun hlt => hm ?_), fun c hc he => hn (he ▸ hc)⟩
  rw [slice_append a h1 (Nat.le_of_lt hlt), slice_cons a hlt h', hg hlt]
  exact List.mem_append_right _ List.mem_cons_self

/-- **The path `target` gives is the target's**: in the origin-form, the absolute path; in an http
or https absolute-form, the path after the authority; in the other forms, the empty range. -/
theorem _root_.Feed.Http.target_some {a : ByteArray} {lo hi plo phi : Nat} (h : lo ≤ hi) (h' : hi ≤ a.size)
    (ht : Http.target a lo hi = some (plo, phi)) :
    lo ≤ plo ∧ plo ≤ phi ∧ phi ≤ hi ∧ TargetPath (slice a lo hi) (slice a plo phi) := by
  obtain ⟨hq1, hq2, -, hqn⟩ := target_cut a h h'
  have wq := fun p (hp : 0x3f ∉ p) => withQuery_iff a h h' (p := p) hp
  unfold Http.target at ht
  dsimp only at ht
  generalize (Decidable.decide (hi ≤ Bytes.findByte a 0x3f lo hi) ||
    Http.uriChars Http.queryLo Http.queryHi a (Bytes.findByte a 0x3f lo hi + 1) hi) = query at wq ht
  generalize Bytes.findByte a 0x3f lo hi = q at *
  split at ht
  · rename_i hor
    split at ht
    · rename_i hc
      rw [Option.some.injEq, Prod.mk.injEq] at ht
      obtain ⟨h1, h2⟩ := ht
      subst h1 h2
      simp only [Bool.and_eq_true, decide_eq_true_eq, beq_iff_eq, Http.byte] at hor hc
      have hpc := (uriChars_iff _ _ _ path_set rfl a (by omega)).mp hc.2
      refine ⟨Nat.le_refl _, hq1, hq2, .origin ⟨?_, hpc, (wq _ (pathChars_mem hpc)).mpr ⟨rfl, hc.1⟩⟩⟩
      rw [slice_cons a hor.1 (by omega), hor.2]; rfl
    · exact absurd ht (by simp)
  · rename_i hor
    split at ht
    · rename_i _ p0 hm
      rw [Option.some.injEq] at ht
      subst ht
      cases hqt : query
      · rw [hqt] at hm; simp at hm
      · rw [hqt, ite_eq_left rfl] at hm
        rw [hqt] at wq
        obtain ⟨g1, g2, rfl, hab⟩ := absolutePath_some hq1 (by omega) hm
        obtain ⟨sch, auth, host, hsch, hhp, hne, hp0, hpc, hx⟩ := hab
        refine ⟨g1, g2, hq2, .absolute ⟨sch, auth, host, hsch, hhp, hne, hp0, hpc, (wq _ ?_).mpr ⟨hx.symm, rfl⟩⟩⟩
        rw [← hx]; exact fun hm => hqn _ hm rfl
    · rename_i _ hm
      have hfin : ∀ b : Bool,
          (b = true → ∃ hh p, HostPort (hh ++ [0x3a] ++ p) hh ∧ slice a lo hi = hh ++ [0x3a] ++ p) →
          (if (hi == lo + 1 && Http.byte a lo == 0x2a || b || query && Http.otherScheme a lo q) = true then
            some (lo, lo) else none) = some (plo, phi) →
          lo ≤ plo ∧ plo ≤ phi ∧ phi ≤ hi ∧ TargetPath (slice a lo hi) (slice a plo phi) := by
        intro b hb ht
        split at ht
        · rename_i hc
          rw [Option.some.injEq, Prod.mk.injEq] at ht
          obtain ⟨h1, h2⟩ := ht
          subst h1 h2
          refine ⟨Nat.le_refl _, Nat.le_refl _, h, ?_⟩
          rw [slice_empty]
          refine .other ?_
          simp only [Bool.or_eq_true, Bool.and_eq_true, beq_iff_eq, Http.byte] at hc
          rcases hc with (⟨hl, hs⟩ | hc) | ⟨hqt, ho⟩
          · left
            rw [hl, slice_cons a (by omega) (by omega), hs, slice_empty]; rfl
          · exact .inr (.inl (hb hc))
          · right; right
            obtain ⟨sch, hp, hsch, n1, n2, hhp, hx⟩ := (otherScheme_iff a hq1 (by omega)).mp ho
            refine ⟨sch, hp, hsch, n1, n2, hhp, (wq _ ?_).mpr ⟨hx.symm, hqt⟩⟩
            rw [← hx]; exact fun hm => hqn _ hm rfl
        · exact absurd ht (by simp)
      split at ht
      · rename_i e he
        exact hfin _ (fun hc => authForm_of h h' he (of_decide_eq_true hc)) ht
      · exact hfin false (fun hc => absurd hc Bool.false_ne_true) ht

/-- info: 'Feed.Http.target_some' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Http.target_some

/-- **`target` finds every request-target, and its path.** -/
theorem _root_.Feed.Http.target_complete {a : ByteArray} {lo hi : Nat} (h : lo ≤ hi) (h' : hi ≤ a.size)
    {p : List UInt8} (hp : TargetPath (slice a lo hi) p) :
    ∃ plo phi, Http.target a lo hi = some (plo, phi) ∧ slice a plo phi = p := by
  obtain ⟨hq1, hq2, hqi, hqn⟩ := target_cut a h h'
  have wq := fun p (hp : 0x3f ∉ p) => withQuery_iff a h h' (p := p) hp
  unfold Http.target
  dsimp only
  generalize (Decidable.decide (hi ≤ Bytes.findByte a 0x3f lo hi) ||
    Http.uriChars Http.queryLo Http.queryHi a (Bytes.findByte a 0x3f lo hi + 1) hi) = query at wq ⊢
  generalize Bytes.findByte a 0x3f lo hi = q at *
  have hhead : (Decidable.decide (lo < q) && Http.byte a lo == 0x2f) = true ↔ (slice a lo q).head? = some 0x2f := by
    simp only [Bool.and_eq_true, decide_eq_true_eq, beq_iff_eq, Http.byte]
    constructor
    · rintro ⟨hlt, hb⟩; rw [slice_cons a hlt (by omega), hb]; rfl
    · intro hh
      have hlt : lo < q := Nat.lt_of_not_le fun hle => by rw [slice_nil_of_le a hle] at hh; simp at hh
      rw [slice_cons a hlt (by omega)] at hh
      exact ⟨hlt, by simpa using hh⟩
  have hpre : slice a lo hi = slice a lo q ++ slice a q hi := slice_append a hq1 hq2
  have hnoq : 0x3f ∉ slice a lo q := fun hm => hqn _ hm rfl
  cases hp with
  | origin ho =>
    obtain ⟨hh, hpc, hw⟩ := ho
    obtain ⟨rfl, hqt⟩ := (wq _ (pathChars_mem hpc)).mp hw
    rw [ite_eq_left (hhead.mpr hh), ite_eq_left (by
      rw [hqt, Bool.true_and]; exact (uriChars_iff _ _ _ path_set rfl a (by omega)).mpr hpc)]
    exact ⟨lo, q, rfl, rfl⟩
  | absolute ha =>
    obtain ⟨sch, auth, host, hsch, hhp, hne, hp0, hpc, hw⟩ := ha
    have hab0 : AbsPart (sch ++ Spec.lit "://" ++ auth ++ p) p := ⟨sch, auth, host, hsch, hhp, hne, hp0, hpc, rfl⟩
    obtain ⟨-, -, -, -, -, -, -, hnq⟩ := absPart_cut hab0
    obtain ⟨hxe, hqt⟩ := (wq _ hnq).mp hw
    have hab : AbsPart (slice a lo q) p := hxe ▸ hab0
    obtain ⟨sch', rest, hx, -, -, -, ⟨c0, r0, hc0, hh0⟩, -⟩ := absPart_cut hab
    have hor : ¬ (Decidable.decide (lo < q) && Http.byte a lo == 0x2f) = true := by
      rw [hhead, hx, hc0]
      simp only [List.cons_append, List.head?_cons, Option.some.injEq]
      rcases hh0 with rfl | rfl <;> decide
    rw [ite_eq_right hor, hqt, ite_eq_left rfl]
    obtain ⟨plo, hap, hsp⟩ := absolutePath_of hq1 (by omega) hab
    rw [hap]
    exact ⟨plo, q, rfl, hsp⟩
  | other ho =>
    have hor : ¬ (Decidable.decide (lo < q) && Http.byte a lo == 0x2f) = true := by
      rw [hhead]
      intro hh
      apply other_head ho
      rw [hpre]
      match hs : slice a lo q, hh with
      | c :: r, hh => simpa using hh
    rw [ite_eq_right hor]
    have hnone : (if query = true then Http.absolutePath a lo q else none) = none := by
      cases hqt : query
      · rfl
      · rw [ite_eq_left rfl]
        cases hap : Http.absolutePath a lo q with
        | none => rfl
        | some r =>
          obtain ⟨-, -, -, hab⟩ := absolutePath_some hq1 (by omega) hap
          rw [hqt] at wq
          exact absurd ho (absPart_not_other hab (fun hn => by rw [hqi hn]) (fun y hy hw => ((wq y hy).mp hw).1))
    rw [hnone]
    dsimp only
    refine ⟨lo, lo, ?_, slice_empty a lo⟩
    have hfin : ∀ b : Bool,
        ((∃ hh p, HostPort (hh ++ [0x3a] ++ p) hh ∧ slice a lo hi = hh ++ [0x3a] ++ p) → b = true) →
        (if (hi == lo + 1 && Http.byte a lo == 0x2a || b || query && Http.otherScheme a lo q) = true then
          some (lo, lo) else none) = some (lo, lo) := by
      intro b hb
      rw [ite_eq_left]
      simp only [Bool.or_eq_true, Bool.and_eq_true, beq_iff_eq, Http.byte]
      rcases ho with ht | hauth | ⟨sch, hp', hsch, n1, n2, hhp, hw⟩
      · have hl := congrArg List.length ht
        rw [slice_length a h', show Spec.lit "*" = [0x2a] from rfl] at hl
        rw [show Spec.lit "*" = [0x2a] from rfl, slice_cons a (by simp at hl; omega) h'] at ht
        exact .inl (.inl ⟨by simp at hl; omega, (List.cons.inj ht).1⟩)
      · exact .inl (.inr (hb hauth))
      · have hnq : 0x3f ∉ sch ++ [0x3a] ++ hp' := fun hm => by
          simp only [List.mem_append, List.mem_singleton] at hm
          rcases hm with (hm | hm) | hm
          · exact (scheme_mem hsch _ hm).1 rfl
          · exact absurd hm (by decide)
          · exact hierPart_mem hhp hm
        obtain ⟨hxe, hqt⟩ := (wq _ hnq).mp hw
        exact .inr ⟨hqt, (otherScheme_iff a hq1 (by omega)).mpr ⟨sch, hp', hsch, n1, n2, hhp, hxe.symm⟩⟩
    split
    · rename_i e he
      exact hfin _ (fun ⟨hh, p', hp', ht⟩ => by
        obtain ⟨he', hlt⟩ := hostEnd_of_authForm h h' hp' ht
        rw [he', Option.some.injEq] at he
        rw [← he]; exact decide_eq_true hlt)
    · rename_i he
      exact hfin false (fun ⟨hh, p', hp', ht⟩ => by
        obtain ⟨he', -⟩ := hostEnd_of_authForm h h' hp' ht
        rw [he'] at he; exact absurd he (by simp))

/-- info: 'Feed.Http.target_complete' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Http.target_complete

/-- **The request-target**: `target` gives a path for a range exactly when it is a request-target
this server reads (RFC 9112 §3.2, `Spec.Http.TargetPath`), and the path it gives is the target's;
for any other range it gives none. -/
theorem _root_.Feed.Http.target_spec (a : ByteArray) {lo hi : Nat} (h : lo ≤ hi) (h' : hi ≤ a.size) :
    match Http.target a lo hi with
    | some (plo, phi) => lo ≤ plo ∧ plo ≤ phi ∧ phi ≤ hi ∧ Spec.Http.TargetPath (slice a lo hi) (slice a plo phi)
    | none => ∀ p, ¬ Spec.Http.TargetPath (slice a lo hi) p := by
  split
  · rename_i plo phi ht
    exact Http.target_some h h' ht
  · rename_i ht
    intro p hp
    obtain ⟨plo, phi, ht', -⟩ := Http.target_complete h h' hp
    rw [ht] at ht'
    exact absurd ht' (by simp)

/-- info: 'Feed.Http.target_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Http.target_spec

/-- **A request-target has one path**: `Spec.Http.TargetPath` is a function of the target (its forms
do not overlap, and each fixes its path). `target` computes it, so this follows from
`Http.target_complete`. -/
theorem _root_.Feed.Spec.Http.targetPath_unique {t p p' : List UInt8} (h : Spec.Http.TargetPath t p)
    (h' : Spec.Http.TargetPath t p') : p = p' := by
  have hs : slice ⟨t.toArray⟩ 0 t.length = t := by simp [slice]
  rw [← hs] at h h'
  obtain ⟨plo, phi, ht, hp⟩ := Http.target_complete (Nat.zero_le _) (Nat.le_refl _) h
  obtain ⟨plo', phi', ht', hp'⟩ := Http.target_complete (Nat.zero_le _) (Nat.le_refl _) h'
  rw [ht, Option.some.injEq, Prod.mk.injEq] at ht'
  obtain ⟨rfl, rfl⟩ := ht'
  rw [← hp, ← hp']

/-- info: 'Feed.Spec.Http.targetPath_unique' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Spec.Http.targetPath_unique

/-! ## Vectors

Through the theorems above and the kernel's evaluation of the deciders on the literals. -/

private theorem slice_all (s : String) : slice s.toUTF8 0 s.toUTF8.size = Spec.lit s := by
  rw [slice, List.drop_zero, Nat.sub_zero,
    List.take_of_length_le (by rw [Array.length_toList]; exact Nat.le_refl _)]
  rfl

private theorem host_yes (s : String) (h : Http.hostOk s.toUTF8 0 s.toUTF8.size = true) :
    ∃ host, HostPort (Spec.lit s) host := by
  rw [← slice_all]; exact (Http.hostOk_iff _ (Nat.zero_le _) (Nat.le_refl _)).mp h

private theorem host_no (s : String) (h : Http.hostOk s.toUTF8 0 s.toUTF8.size = false) :
    ¬ ∃ host, HostPort (Spec.lit s) host := by
  rw [← slice_all, ← Http.hostOk_iff _ (Nat.zero_le _) (Nat.le_refl _), h]; exact Bool.false_ne_true

private theorem target_yes (s p : String) (plo phi : Nat)
    (h : Http.target s.toUTF8 0 s.toUTF8.size = some (plo, phi)) (hp : slice s.toUTF8 plo phi = Spec.lit p) :
    TargetPath (Spec.lit s) (Spec.lit p) := by
  have := Http.target_spec s.toUTF8 (Nat.zero_le _) (Nat.le_refl _)
  rw [h] at this
  rw [← slice_all, ← hp]; exact this.2.2.2

private theorem target_no (s : String) (h : Http.target s.toUTF8 0 s.toUTF8.size = none) :
    ∀ p, ¬ TargetPath (Spec.lit s) p := by
  have := Http.target_spec s.toUTF8 (Nat.zero_le _) (Nat.le_refl _)
  rw [h] at this
  rw [← slice_all]; exact this

/-- Host values: the IPv6 addresses of RFC 4291 §2.2's examples, which RFC 3986 §3.2.2 refers to
(eight groups, "::" in the middle, at the end, alone and before an IPv4 tail), others with a
port, IPvFuture in either case, an IPv4 address with a port, the empty value; and values that
are none: two "::", nine groups, seven groups and an IPv4 tail, an octet with a leading zero in an
IPv4 tail, a space, userinfo. -/
theorem _root_.Feed.Http.hostOk_vectors :
    (∃ host, HostPort (Spec.lit "[2001:DB8:0:0:8:800:200C:417A]") host) ∧
    (∃ host, HostPort (Spec.lit "[2001:DB8::8:800:200C:417A]") host) ∧
    (∃ host, HostPort (Spec.lit "[FF01::101]") host) ∧ (∃ host, HostPort (Spec.lit "[::1]") host) ∧
    (∃ host, HostPort (Spec.lit "[::]") host) ∧ (∃ host, HostPort (Spec.lit "[::13.1.68.3]") host) ∧
    (∃ host, HostPort (Spec.lit "[::FFFF:129.144.52.38]:3000") host) ∧
    (∃ host, HostPort (Spec.lit "[1:2:3:4:5:6:7:8]") host) ∧ (∃ host, HostPort (Spec.lit "[v1.x]") host) ∧
    (∃ host, HostPort (Spec.lit "[V7.a:b]") host) ∧ (∃ host, HostPort (Spec.lit "127.0.0.1:3000") host) ∧
    (∃ host, HostPort (Spec.lit "") host) ∧
    (¬ ∃ host, HostPort (Spec.lit "[1::2::3]") host) ∧ (¬ ∃ host, HostPort (Spec.lit "[1:2:3:4:5:6:7:8:9]") host) ∧
    (¬ ∃ host, HostPort (Spec.lit "[1:2:3:4:5:6::1.2.3.4]") host) ∧
    (¬ ∃ host, HostPort (Spec.lit "[::e15:255.00.255.255]") host) ∧ (¬ ∃ host, HostPort (Spec.lit "a b") host) ∧
    (¬ ∃ host, HostPort (Spec.lit "u@h") host) :=
  ⟨host_yes _ (by decide), host_yes _ (by decide), host_yes _ (by decide), host_yes _ (by decide),
    host_yes _ (by decide), host_yes _ (by decide), host_yes _ (by decide), host_yes _ (by decide),
    host_yes _ (by decide), host_yes _ (by decide), host_yes _ (by decide), host_yes _ (by decide),
    host_no _ (by decide), host_no _ (by decide), host_no _ (by decide), host_no _ (by decide),
    host_no _ (by decide), host_no _ (by decide)⟩

/-- info: 'Feed.Http.hostOk_vectors' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Http.hostOk_vectors

/-- Request-targets: the path of an origin-form and of http and https absolute-forms (the scheme in
any case, an IPv6 host, a port, no path), the empty path of the asterisk-form, an authority-form
and a URI of another scheme; and targets that are none: userinfo, an empty host, a bad IPv6
address, brackets outside an IP-literal, a space. -/
theorem _root_.Feed.Http.target_vectors :
    TargetPath (Spec.lit "/feed?limit=20") (Spec.lit "/feed") ∧
    TargetPath (Spec.lit "http://example.com/feed?x=1") (Spec.lit "/feed") ∧
    TargetPath (Spec.lit "HTTPS://[::1]:3000/posts/1/like") (Spec.lit "/posts/1/like") ∧
    TargetPath (Spec.lit "http://example.com") [] ∧ TargetPath (Spec.lit "*") [] ∧
    TargetPath (Spec.lit "example.com:443") [] ∧ TargetPath (Spec.lit "urn:example:x") [] ∧
    (∀ p, ¬ TargetPath (Spec.lit "http://u@h/feed") p) ∧ (∀ p, ¬ TargetPath (Spec.lit "http:///feed") p) ∧
    (∀ p, ¬ TargetPath (Spec.lit "http://[1::2::3]/") p) ∧ (∀ p, ¬ TargetPath (Spec.lit "foo:[") p) ∧
    (∀ p, ¬ TargetPath (Spec.lit "foo://[::1") p) ∧ (∀ p, ¬ TargetPath (Spec.lit "/a b") p) :=
  ⟨target_yes _ _ 0 5 (by decide) (by decide), target_yes _ _ 18 23 (by decide) (by decide),
    target_yes _ _ 18 31 (by decide) (by decide), target_yes _ "" 18 18 (by decide) (by decide),
    target_yes _ "" 0 0 (by decide) (by decide), target_yes _ "" 0 0 (by decide) (by decide),
    target_yes _ "" 0 0 (by decide) (by decide), target_no _ (by decide), target_no _ (by decide),
    target_no _ (by decide), target_no _ (by decide), target_no _ (by decide), target_no _ (by decide)⟩

/-- info: 'Feed.Http.target_vectors' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Http.target_vectors

end Feed.Uri
