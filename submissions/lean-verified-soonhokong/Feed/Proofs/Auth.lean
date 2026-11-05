import Feed.Spec.Auth
import Feed.Proofs.Sha256
import Feed.Proofs.Base64
import Feed.Proofs.JsonValue
import Feed.Proofs.Views
import Feed.Proofs.Jwt

/-!
# The token and the Authorization field

`Jwt.verify` and `authenticate`, under JWT_SECRET's key schedule, decide what
`Spec.Auth.checkToken` and `Spec.Auth.authenticate` decide with HMAC-SHA256 under JWT_SECRET's
bytes, for every token and every request:

* `Jwt.verify_spec`: `verify` of a range of the input is `Spec.Auth.checkToken` of its bytes, read
  as the code's result (`Jwt.Result.ofSpec`); `Jwt.verify_eq` says it for any key and the MAC it
  computes (`MacOf`), and `Hmac.macOf` that `Hmac.Key.of secret` computes HMAC-SHA256 under
  `secret` (`Hmac.mac_spec`).
* `authenticate_spec`: `authenticate` answers, as SPEC.md's rows, what `Spec.Auth.authenticate`
  answers on the request's Authorization value.
* The code checks the signature first, then decodes the header and the payload; the specification
  decodes all three parts and checks the signature after the header's members. Every one of those
  failures is `invalid`, so the order changes no answer: the signature comparison (`Jwt.ctEq_iff`)
  is exactly that the third part decodes to the MAC of the first two (`b64urlDecode_eq_some_iff`).
* The JSON is read through `Json.parseTop_spec`: `parseTop` says an object exactly when
  `Spec.Auth.objectMembers` gives its members (`Jwt.parseTop_members`), and each field it reports
  is read as the specification reads the member's value: a string by `Json.decodeString_spec`, a
  number by `Json.numGt_spec`, a member's presence by its kind. `cty` is compared in ASCII
  lowercase as `Spec.Auth.nestedCty` compares it (`Jwt.nestedCty_spec`), and `sub` read as
  `Spec.Auth.subjectId` reads it (`Jwt.positiveInt_spec`).

Two facts about the specification alone: `Spec.Auth.subjectId_eq_some_iff` (a `sub` is accepted
exactly when it is `String(n)` of a positive `n` below 10^18), and `Spec.Auth.checkToken_ok` (an
accepted token is three base64url parts, the third the MAC of the first two). `verify_ok_sound`
(`Feed/Proofs/Jwt.lean`) stays as it is.
-/
namespace Feed
open Spec

/-! ## The specification's choices -/

namespace Spec.Auth

/-- `objectMembers` of an object text: its members, which are unique (`IsObjectText.unique`). -/
theorem objectMembers_eq {t : List UInt8} {ms : List (List Nat × List UInt8)} (h : Json.IsObjectText t ms) :
    objectMembers t = some ms := by
  have he : ∃ ms, Json.IsObjectText t ms := ⟨ms, h⟩
  unfold objectMembers
  rw [dite_eq_left he]
  exact congrArg some ((Classical.choose_spec he).unique h)

theorem objectMembers_eq_none {t : List UInt8} (h : ∀ ms, ¬ Json.IsObjectText t ms) : objectMembers t = none := by
  unfold objectMembers
  rw [dite_eq_right (fun ⟨ms, hm⟩ => h ms hm)]

/-- `stringValue` of a string: the UTF-8 of its characters, which are unique (`IsString.unique`). -/
theorem stringValue_eq {v : List UInt8} {us : List Nat} (h : Json.IsString v us) :
    stringValue v = some (Json.encode (Json.scalars us)) := by
  have he : ∃ us, Json.IsString v us := ⟨us, h⟩
  unfold stringValue
  rw [dite_eq_left he, (Classical.choose_spec he).unique h]

theorem stringValue_eq_none {v : List UInt8} (h : ¬ ∃ us, Json.IsString v us) : stringValue v = none := by
  unfold stringValue
  rw [dite_eq_right h]

/-! ### `sub` -/

/-- The digits of the numbers below 10. -/
theorem digits_lt : ∀ d : Fin 10, digits d.val = [d.val.toUInt8 + 0x30] ∧ 0x30 ≤ d.val.toUInt8 + 0x30 ∧
    d.val.toUInt8 + 0x30 ≤ 0x39 ∧ (d.val.toUInt8 + 0x30 - 0x30).toNat = d.val := by
  decide

/-- One more digit (`Nat.toDigits_append_toDigits`). -/
theorem digits_append {n d : Nat} (hn : 0 < n) (hd : d < 10) : digits (10 * n + d) = digits n ++ digits d := by
  simp only [digits, Spec.lit, Nat.toString_eq_ofList_toDigits, String.toUTF8_eq_toByteArray,
    String.toByteArray_ofList]
  rw [← Nat.toDigits_append_toDigits (by decide) hn hd, List.utf8Encode_append, ByteArray.toList_data_append]

theorem decimal_append : ∀ (s t : List UInt8) (acc : Nat),
    decimal (s ++ t) acc = (decimal s acc).bind fun m => decimal t m
  | [], _, _ => rfl
  | c :: s, t, acc => by
    simp only [List.cons_append, decimal]
    split
    · exact decimal_append s t _
    · rfl

/-- A positive number's digits: no leading zero, read back as the number, as many as it needs. -/
theorem digits_pos (n : Nat) (hn : 0 < n) : ∃ c l, digits n = c :: l ∧ c ≠ 0x30 ∧ decimal (digits n) 0 = some n ∧
    10 ^ (digits n).length ≤ 10 * n ∧ n < 10 ^ (digits n).length := by
  induction n using Nat.base_induction 10 (by decide) with
  | single m hm =>
    obtain ⟨h1, h2, h3, h4⟩ := digits_lt ⟨m, hm⟩
    simp only at h1 h2 h3 h4
    rw [h1]
    refine ⟨_, _, rfl, fun he => ?_, ?_, by simp; omega, by simp; omega⟩
    · rw [he] at h4; simp at h4; omega
    · simp only [decimal, ite_eq_left (show 0x30 ≤ m.toUInt8 + 0x30 ∧ m.toUInt8 + 0x30 ≤ 0x39 from ⟨h2, h3⟩), h4]
      simp
  | digit m k hk hm ih =>
    obtain ⟨c, l, hcl, hc, hdec, hlo, hhi⟩ := ih hm
    obtain ⟨h1, h2, h3, h4⟩ := digits_lt ⟨k, hk⟩
    simp only at h1 h2 h3 h4
    rw [digits_append hm hk, hcl, h1]
    refine ⟨c, l ++ [k.toUInt8 + 0x30], rfl, hc, ?_, ?_, ?_⟩
    · rw [← hcl, decimal_append, hdec, Option.bind_some]
      simp only [decimal, ite_eq_left (show 0x30 ≤ k.toUInt8 + 0x30 ∧ k.toUInt8 + 0x30 ≤ 0x39 from ⟨h2, h3⟩), h4]
      simp; omega
    · rw [hcl] at hlo hhi
      simp only [List.length_append, List.length_cons, List.length_nil, Nat.pow_succ] at hlo hhi ⊢
      omega
    · rw [hcl] at hlo hhi
      simp only [List.length_append, List.length_cons, List.length_nil, Nat.pow_succ] at hlo hhi ⊢
      omega

theorem digit_bytes : ∀ v : Fin 256, 0x30 ≤ v.val.toUInt8 ∧ v.val.toUInt8 ≤ 0x39 →
    (v.val.toUInt8 - 0x30).toNat < 10 ∧ (v.val.toUInt8 - 0x30).toNat.toUInt8 + 0x30 = v.val.toUInt8 := by
  decide +kernel

theorem digit_byte {d : UInt8} (h : 0x30 ≤ d ∧ d ≤ 0x39) :
    (d - 0x30).toNat < 10 ∧ (d - 0x30).toNat.toUInt8 + 0x30 = d := by
  simpa using digit_bytes ⟨d.toNat, d.toNat_lt⟩ (by simpa using h)

/-- Digits without a leading zero, here written backwards, are those of the number they stand
for. -/
theorem eq_digits : ∀ (l : List UInt8) (n : Nat), l ≠ [] → l.reverse.head? ≠ some 0x30 →
    decimal l.reverse 0 = some n → l.reverse = digits n ∧ 0 < n
  | [], _, h, _, _ => absurd rfl h
  | d :: l, n, _, h0, hd => by
    rw [List.reverse_cons, decimal_append] at hd
    cases hm : decimal l.reverse 0 with
    | none => rw [hm] at hd; cases hd
    | some m =>
      rw [hm, Option.bind_some] at hd
      simp only [decimal] at hd
      split at hd
      next hdig =>
        simp only [Option.some.injEq] at hd
        obtain ⟨hv, hvd⟩ := digit_byte hdig
        obtain ⟨hdv, -⟩ := digits_lt ⟨_, hv⟩
        simp only at hdv
        cases l with
        | nil =>
          simp only [List.reverse_nil, decimal, Option.some.injEq] at hm
          subst hm
          have hpos : 0 < (d - 0x30).toNat := by
            refine Nat.pos_of_ne_zero fun h => h0 ?_
            simp only [List.reverse_cons, List.reverse_nil, List.nil_append, List.head?_cons, Option.some.injEq]
            rw [← hvd, h]; rfl
          rw [← hd, Nat.zero_mul, Nat.zero_add, hdv, hvd]
          exact ⟨rfl, hpos⟩
        | cons e l =>
          have h0' : (e :: l).reverse.head? ≠ some 0x30 := by
            obtain ⟨x, xs, hx⟩ := List.exists_cons_of_ne_nil (show (e :: l).reverse ≠ [] by simp)
            rw [List.reverse_cons, hx] at h0
            rw [hx]
            simpa using h0
          obtain ⟨h1, h2⟩ := eq_digits (e :: l) m (by simp) h0' hm
          rw [List.reverse_cons, h1, ← hd, show m * 10 + (d - 0x30).toNat = 10 * m + (d - 0x30).toNat by omega,
            digits_append h2 hv, hdv, hvd]
          exact ⟨rfl, by omega⟩
      next => cases hd

/-- **`sub` is `String(n)`**: `subjectId` accepts exactly the decimal digits of a positive integer
below 10^18, as JavaScript's `String(n)` writes them (no sign, no leading zero), and gives that
integer. -/
theorem subjectId_eq_some_iff (s : List UInt8) (n : Nat) :
    subjectId s = some n ↔ s = digits n ∧ 0 < n ∧ n < 10 ^ 18 := by
  constructor
  · intro h
    cases s with
    | nil => cases h
    | cons c l =>
      simp only [subjectId] at h
      split at h
      · cases h
      next hc =>
        obtain ⟨h1, h2⟩ := eq_digits (c :: l).reverse n (by simp) (by simpa using fun h => hc (Or.inl h))
          (by simpa using h)
        rw [List.reverse_reverse] at h1
        obtain ⟨-, -, -, -, -, -, hhi⟩ := digits_pos n h2
        refine ⟨h1, h2, ?_⟩
        rw [← h1] at hhi
        have : (c :: l).length ≤ 18 := by simp only [not_or] at hc; omega
        exact Nat.lt_of_lt_of_le hhi (Nat.pow_le_pow_right (by decide) this)
  · rintro ⟨rfl, hn, h18⟩
    obtain ⟨c, l, hcl, hc, hdec, hlo, -⟩ := digits_pos n hn
    rw [hcl] at hdec hlo ⊢
    have : (c :: l).length < 19 :=
      (Nat.pow_lt_pow_iff_right (a := 10) (by decide)).mp (by rw [Nat.pow_succ]; omega)
    simp only [subjectId]
    rw [ite_eq_right (by simp only [not_or]; exact ⟨hc, by omega⟩), hdec]

/-- info: 'Feed.Spec.Auth.subjectId_eq_some_iff' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms subjectId_eq_some_iff

end Spec.Auth

/-! ## What `verify` reads -/

namespace Jwt
open Json Spec.Auth

/-! ### `sub` -/

theorem positiveInt_go (s : ByteArray) : ∀ f i acc, i + f = s.size →
    positiveInt.go s i f acc = decimal ((bs s).drop i) acc := by
  intro f
  induction f with
  | zero =>
    intro i acc h
    rw [List.drop_eq_nil_of_le (by rw [← size_eq_length]; omega)]
    rfl
  | succ f ih =>
    intro i acc h
    have hi : i < (bs s).length := by rw [← size_eq_length]; omega
    rw [List.drop_eq_getElem_cons hi]
    have hc : s.get! i = (bs s)[i] := by rw [get!_eq, List.getElem?_eq_getElem hi]; rfl
    simp only [positiveInt.go, decimal, hc, ih (i + 1) _ (by omega)]
    by_cases hd : 0x30 ≤ (bs s)[i] ∧ (bs s)[i] ≤ 0x39
    · rw [ite_eq_left ((isDigit_iff _).mpr hd), ite_eq_left hd]
    · rw [ite_eq_right (fun h => hd ((isDigit_iff _).mp h)), ite_eq_right hd]

/-- **`sub`**: `positiveInt` reads the decoded `sub` as `Spec.Auth.subjectId` does. -/
theorem positiveInt_spec (s : ByteArray) : Jwt.positiveInt s = Spec.Auth.subjectId (bs s) := by
  rw [positiveInt, positiveInt_go s s.size 0 0 (by omega), List.drop_zero, get!_eq, size_eq_length]
  generalize bs s = l
  cases l with
  | nil => rfl
  | cons c l =>
    simp only [Spec.Auth.subjectId, List.length_cons, List.getElem?_cons_zero, Option.getD_some]
    by_cases h : c = 0x30 ∨ l.length + 1 > 18
    · rw [ite_eq_left (by simpa [or_comm] using h), ite_eq_left h]
    · rw [ite_eq_right (by simpa [or_comm] using h), ite_eq_right h]

/-- info: 'Feed.Jwt.positiveInt_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms positiveInt_spec

/-! ### `cty` -/

theorem lower_eq (b : UInt8) :
    (if (0x41 ≤ b && b ≤ 0x5a) = true then b + 32 else b) = if 0x41 ≤ b ∧ b ≤ 0x5a then b + 32 else b := by
  by_cases h : 0x41 ≤ b ∧ b ≤ 0x5a
  · rw [ite_eq_left (by simpa using h), ite_eq_left h]
  · rw [ite_eq_right (by simpa using h), ite_eq_right h]

theorem eqLower_go (s c : ByteArray) : ∀ f k, eqLower.go s c k f = true ↔
    ∀ j, k ≤ j → j < k + f → (if 0x41 ≤ s.get! j ∧ s.get! j ≤ 0x5a then s.get! j + 32 else s.get! j) = c.get! j := by
  intro f
  induction f with
  | zero => intro k; simp only [eqLower.go, true_iff]; intro j h1 h2; omega
  | succ f ih =>
    intro k
    simp only [eqLower.go, lower_eq]
    simp only [Bool.and_eq_true, beq_iff_eq, ih (k + 1)]
    constructor
    · rintro ⟨h0, hr⟩ j h1 h2
      rcases Nat.eq_or_lt_of_le h1 with rfl | hlt
      · exact h0
      · exact hr j (by omega) (by omega)
    · intro h
      exact ⟨h k (Nat.le_refl _) (by omega), fun j h1 h2 => h j (by omega) (by omega)⟩

/-- `eqLower` compares a byte array, in ASCII lowercase, with a literal. -/
theorem eqLower_iff (s c : ByteArray) : eqLower s c = true ↔ Spec.Auth.asciiLower (bs s) = bs c := by
  rw [Spec.Auth.asciiLower, ← slice_all s, map_slice_eq_iff s _ (Nat.le_refl _), eqLower, Bool.and_eq_true,
    beq_iff_eq, eqLower_go, ← size_eq_length]
  constructor
  · rintro ⟨hl, hk⟩
    refine ⟨by omega, fun k hk' => ?_⟩
    rw [Nat.zero_add, hk k (Nat.zero_le _) (by omega), get!_eq]
  · rintro ⟨hl, hk⟩
    refine ⟨by omega, fun j _ hj => ?_⟩
    have := hk j (by omega)
    rwa [Nat.zero_add, ← get!_eq] at this

/-- **A nested JWT's `cty`**: `nestedCty` decides what `Spec.Auth.nestedCty` decides. -/
theorem nestedCty_spec (s : ByteArray) : Jwt.nestedCty s = Spec.Auth.nestedCty (bs s) := by
  have h (c : ByteArray) : eqLower s c = (Spec.Auth.asciiLower (bs s) == bs c) := by
    rw [Bool.eq_iff_iff, eqLower_iff, beq_iff_eq]
  rw [Jwt.nestedCty, Spec.Auth.nestedCty, h, h]
  rfl

/-- info: 'Feed.Jwt.nestedCty_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms nestedCty_spec

/-! ### The header and the claims -/

/-- What `parseTop` answers on a decoded part, as `Spec.Auth.objectMembers` of its bytes: an object
exactly when `objectMembers` gives its members, with each wanted key's field standing for the last
member with that name (`parseTop_spec`). -/
theorem parseTop_members (b : ByteArray) (keys : Array ByteArray) (hd : (keys.toList.map bs).Nodup)
    (ha : ∀ k ∈ keys.toList, ∀ c ∈ bs k, c < 0x80) :
    match parseTop b 0 b.size keys with
    | .object fs => ∃ ms, objectMembers (bs b) = some ms ∧
        ∀ q (hq : q < keys.size), FieldIs b fs[q]! (Spec.Json.member ms ((bs keys[q]).map (·.toNat)))
    | _ => objectMembers (bs b) = none := by
  have h := parseTop_spec b 0 b.size keys hd ha
  rw [slice_all] at h
  cases hp : parseTop b 0 b.size keys with
  | malformed => rw [hp] at h; exact objectMembers_eq_none fun ms hm => h hm.isText
  | notObject => rw [hp] at h; exact objectMembers_eq_none h.2
  | object fs =>
    rw [hp] at h
    obtain ⟨-, ms, hms, hf⟩ := h
    exact ⟨ms, objectMembers_eq hms, hf⟩

/-- A field read as a string, as `verify` reads it: the bytes of the member's string value. -/
theorem fieldIs_str {a : ByteArray} {f : Field} {m : Option (List UInt8)} (h : FieldIs a f m) :
    (if f.kind = .str then some (bs (decodeString a f.lo f.hi)) else none) = m.bind stringValue := by
  cases m with
  | none =>
    have hk : f.kind = .absent := h
    rw [ite_eq_right (by rw [hk]; decide)]
    rfl
  | some v =>
    obtain ⟨rfl, -, hle, -, hstr, -⟩ := h
    by_cases hk : f.kind = .str
    · obtain ⟨us, hus⟩ := hstr.mp hk
      rw [ite_eq_left hk, Option.bind_some, stringValue_eq hus, decodeString_spec hus hle]
    · rw [ite_eq_right hk, Option.bind_some, stringValue_eq_none (fun h => hk (hstr.mpr h))]

theorem bs_inj {x y : ByteArray} : bs x = bs y ↔ x = y :=
  ⟨fun h => ByteArray.ext (Array.toList_inj.mp h), fun h => h ▸ rfl⟩

/-- `alg`: a field that is not the string `s`. -/
theorem str_ne {a : ByteArray} {f : Field} {m : Option (List UInt8)} (h : FieldIs a f m) (s : ByteArray) :
    (f.kind != .str || decodeString a f.lo f.hi != s) = true ↔ m.bind stringValue ≠ some (bs s) := by
  rw [← fieldIs_str h]
  by_cases hk : f.kind = .str
  · rw [ite_eq_left hk, hk]
    simp only [bne_self_eq_false, Bool.false_or, bne_iff_ne, ne_eq, Option.some.injEq, bs_inj]
  · rw [ite_eq_right hk]
    simp [hk]

/-- `crit`, `aud`: a member that is present. -/
theorem absent_iff {a : ByteArray} {f : Field} {m : Option (List UInt8)} (h : FieldIs a f m) :
    (f.kind != .absent) = true ↔ m.isSome = true := by
  cases m with
  | none => have hk : f.kind = .absent := h; simp [hk]
  | some v => obtain ⟨-, -, -, hk, -⟩ := h; simp [hk]

/-- `cty`: a string that names a nested JWT. -/
theorem cty_iff {a : ByteArray} {f : Field} {m : Option (List UInt8)} (h : FieldIs a f m) :
    (f.kind == .str && Jwt.nestedCty (decodeString a f.lo f.hi)) = true ↔
      (m.bind stringValue).any Spec.Auth.nestedCty = true := by
  rw [← fieldIs_str h]
  by_cases hk : f.kind = .str
  · rw [ite_eq_left hk, hk, nestedCty_spec]; simp
  · rw [ite_eq_right hk]; simp [hk]

/-- `exp`: no number after `now`. -/
theorem exp_iff {a : ByteArray} {f : Field} {m : Option (List UInt8)} (h : FieldIs a f m) (now : Nat) :
    (f.kind != .num || !numGt a f.lo f.hi now) = true ↔ ¬ ∃ v, m = some v ∧ Spec.Json.NumGt v now := by
  cases m with
  | none => have hk : f.kind = .absent := h; simp [hk]
  | some v =>
    obtain ⟨rfl, -, hle, -, -, hnum⟩ := h
    by_cases hk : f.kind = .num
    · obtain ⟨neg, mm, e, hn⟩ := hnum.mp hk
      simp only [hk, bne_self_eq_false, Bool.false_or, Bool.not_eq_true', Option.some.injEq, exists_eq_left']
      rw [← numGt_spec hn hle]
      simp
    · have : ¬ Spec.Json.NumGt (slice a f.lo f.hi) now := fun ⟨neg, mm, e, hn, _⟩ => hk (hnum.mpr ⟨neg, mm, e, hn⟩)
      simp [hk, this]

/-- `nbf`: present, and not a number or a number after `now`. -/
theorem nbf_iff {a : ByteArray} {f : Field} {m : Option (List UInt8)} (h : FieldIs a f m) (now : Nat) :
    (f.kind != .absent && (f.kind != .num || numGt a f.lo f.hi now)) = true ↔
      ∃ v, m = some v ∧ (¬ IsNum v ∨ Spec.Json.NumGt v now) := by
  cases m with
  | none => have hk : f.kind = .absent := h; simp [hk]
  | some v =>
    obtain ⟨rfl, -, hle, hab, -, hnum⟩ := h
    by_cases hk : f.kind = .num
    · obtain ⟨neg, mm, e, hn⟩ := hnum.mp hk
      have hisn : IsNum (slice a f.lo f.hi) := ⟨neg, mm, e, hn⟩
      simp only [hk, bne_self_eq_false, Bool.false_or, Option.some.injEq, exists_eq_left', hisn,
        not_true_eq_false, false_or]
      exact numGt_spec hn hle
    · have hisn : ¬ IsNum (slice a f.lo f.hi) := fun ⟨neg, mm, e, hn⟩ => hk (hnum.mpr ⟨neg, mm, e, hn⟩)
      simp [hk, hab, hisn]

/-- One check of `verify` against the specification's, each `invalid` when it fails. -/
theorem ofSpec_ite {b : Bool} {c : Prop} {_ : Decidable c} {x : Result} {y : TokenCheck} (hc : b = true ↔ c)
    (h : ¬ c → x = .ofSpec y) : (if b = true then Result.invalid else x) = .ofSpec (if c then .invalid else y) := by
  by_cases hc' : c
  · rw [ite_eq_left (hc.mpr hc'), ite_eq_left hc']; rfl
  · rw [ite_eq_right (fun hb => hc' (hc.mp hb)), ite_eq_right hc']; exact h hc'

end Jwt

/-! ## The token -/

/-- `mac` is what `Hmac.mac` computes under `key`, on every range of every byte array. -/
def MacOf (key : Hmac.Key) (mac : List UInt8 → List UInt8) : Prop :=
  ∀ (a : ByteArray) (lo hi : Nat), bs (Hmac.mac key a lo hi) = mac (slice a lo hi)

/-- **The key schedule of a secret computes HMAC-SHA256 under it** (`Hmac.mac_spec`). -/
theorem Hmac.macOf (secret : ByteArray) : MacOf (Hmac.Key.of secret) (Spec.HMAC.hmacSha256 (bs secret)) :=
  fun a lo hi => Hmac.mac_spec secret a lo hi

/-- info: 'Feed.Hmac.macOf' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Hmac.macOf

namespace Jwt
open Json Spec.Auth

/-- **`verify` is `Spec.Auth.checkToken`**, for any key and the MAC it computes: on every range of
the input, the same token's answer, read as the code's (`Result.ofSpec`). -/
theorem verify_eq {key : Hmac.Key} {mac : List UInt8 → List UInt8} (hm : MacOf key mac) (now : Nat)
    (a : ByteArray) (lo hi : Nat) :
    verify key now a lo hi = .ofSpec (checkToken mac now (slice a lo hi)) := by
  rw [← slice_min a lo hi]
  unfold verify
  dsimp only
  generalize hH : min hi a.size = H
  have hHa : H ≤ a.size := hH ▸ Nat.min_le_right _ _
  by_cases hlo : H < lo
  · -- the range is empty: no dots
    rw [Bytes.findByte_past a 0x2e (by omega), Nat.min_eq_left hHa, ite_eq_left (by simp)]
    rw [show slice a lo H = [] by simp [slice]; omega]
    rfl
  replace hlo : lo ≤ H := by omega
  -- the dots (`dots_spec`)
  have hd := dots_spec a hlo hHa
  dsimp only at hd
  by_cases hc : Bytes.findByte a 0x2e lo H ≥ H ∨ Bytes.findByte a 0x2e (Bytes.findByte a 0x2e lo H + 1) H ≥ H ∨
      Bytes.findByte a 0x2e (Bytes.findByte a 0x2e (Bytes.findByte a 0x2e lo H + 1) H + 1) H ≠ H
  · rw [ite_eq_left (by simpa [or_assoc] using hc)]
    rw [ite_eq_left hc] at hd
    unfold checkToken
    split
    · rename_i hs; rw [hs] at hd; cases hd
    · rfl
  rw [ite_eq_right (by simpa [or_assoc] using hc)]
  rw [ite_eq_right hc] at hd
  simp only [not_or, Nat.not_le, Decidable.not_not] at hc
  obtain ⟨c1, c2, -⟩ := hc
  obtain ⟨l1, -, -, b1⟩ := findByte_first a 0x2e hlo hHa
  generalize Bytes.findByte a 0x2e lo H = d1 at hd c1 c2 l1 b1 ⊢
  obtain ⟨l2, -, -, -⟩ := findByte_first a 0x2e (lo := d1 + 1) (by omega) hHa
  generalize Bytes.findByte a 0x2e (d1 + 1) H = d2 at hd c2 l2 ⊢
  have hsplit : (slice a lo H).splitOn 0x2e = [slice a lo d1, slice a (d1 + 1) d2, slice a (d2 + 1) H] := by
    revert hd
    split
    · intro hd; cases hd; assumption
    · intro hd; cases hd
  unfold checkToken
  rw [hsplit]
  dsimp only
  -- the signature, over the first two parts and the dot between them
  have hmsg : slice a lo d2 = slice a lo d1 ++ [0x2e] ++ slice a (d1 + 1) d2 := by
    rw [Jwt.slice_split a l1 (by omega) (by omega), b1 c1]; simp
  have hsig : ctEq (b64Encode (Hmac.mac key a lo d2)) a (d2 + 1) H = true ↔
      slice a (d2 + 1) H = b64urlEncode (mac (slice a lo d1 ++ [0x2e] ++ slice a (d1 + 1) d2)) := by
    rw [ctEq_iff (by omega) hHa, b64Encode_spec, hm, hmsg]
  by_cases hs : slice a (d2 + 1) H ≠ b64urlEncode (mac (slice a lo d1 ++ [0x2e] ++ slice a (d1 + 1) d2))
  · -- the code stops here; the specification's checks all pass or fail, but the signature fails
    rw [ite_eq_left (by rw [Bool.not_eq_true', Bool.eq_false_iff]; exact fun h => hs (hsig.mp h))]
    symm
    split
    · rename_i sb _ _ hsb
      have hne : sb ≠ mac (slice a lo d1 ++ [0x2e] ++ slice a (d1 + 1) d2) := fun he =>
        hs ((b64urlDecode_eq_some_iff _ _).mp (he ▸ hsb)).symm
      split
      · rw [ite_eq_left hne]
        simp only [ite_self]
        rfl
      · rfl
    · rfl
  rw [Decidable.not_not] at hs
  rw [ite_eq_right (by simp [hsig.mpr hs])]
  -- the header and the payload
  rw [(b64urlDecode_eq_some_iff _ _).mpr hs.symm, ← b64Decode_spec a lo d1, ← b64Decode_spec a (d1 + 1) d2]
  cases b64Decode a lo d1 with
  | none => rfl
  | some h =>
  cases b64Decode a (d1 + 1) d2 with
  | none => rfl
  | some p =>
  simp only [Option.map_some]
  have th := parseTop_members h #[keyAlg, keyCrit, keyCty] (by decide) (by decide)
  have tp := parseTop_members p #[keyExp, keyNbf, keySub, keyUsername, keyAud] (by decide) (by decide)
  generalize parseTop h 0 h.size #[keyAlg, keyCrit, keyCty] = T1 at th ⊢
  generalize parseTop p 0 p.size #[keyExp, keyNbf, keySub, keyUsername, keyAud] = T2 at tp ⊢
  cases T1 with
  | malformed => rw [th]; rfl
  | notObject => rw [th]; rfl
  | object hf =>
  obtain ⟨hdr, hhdr, hfs⟩ := th
  cases T2 with
  | malformed => rw [hhdr, tp]; rfl
  | notObject => rw [hhdr, tp]; rfl
  | object pf =>
  obtain ⟨cl, hcl, pfs⟩ := tp
  rw [hhdr, hcl]
  dsimp only
  have halg : FieldIs h hf[0]! (member hdr (name "alg")) := hfs 0 (by decide)
  have hcrit : FieldIs h hf[1]! (member hdr (name "crit")) := hfs 1 (by decide)
  have hcty : FieldIs h hf[2]! (member hdr (name "cty")) := hfs 2 (by decide)
  have hexp : FieldIs p pf[0]! (member cl (name "exp")) := pfs 0 (by decide)
  have hnbf : FieldIs p pf[1]! (member cl (name "nbf")) := pfs 1 (by decide)
  have hsub : FieldIs p pf[2]! (member cl (name "sub")) := pfs 2 (by decide)
  have huser : FieldIs p pf[3]! (member cl (name "username")) := pfs 3 (by decide)
  have haud : FieldIs p pf[4]! (member cl (name "aud")) := pfs 4 (by decide)
  refine ofSpec_ite (str_ne halg hs256) fun _ => ?_
  refine ofSpec_ite (absent_iff hcrit) fun _ => ?_
  refine ofSpec_ite (cty_iff hcty) fun _ => ?_
  rw [ite_eq_right (fun h : mac _ ≠ mac _ => h rfl)]
  refine ofSpec_ite (exp_iff hexp now) fun _ => ?_
  refine ofSpec_ite (nbf_iff hnbf now) fun _ => ?_
  refine ofSpec_ite (absent_iff haud) fun _ => ?_
  -- `sub` and `username`
  rw [← fieldIs_str hsub, ← fieldIs_str huser]
  by_cases k2 : pf[2]!.kind = .str
  · by_cases k3 : pf[3]!.kind = .str
    · rw [ite_eq_right (by simp [k2, k3]), ite_eq_left k2, ite_eq_left k3]
      dsimp only
      rw [positiveInt_spec]
      cases subjectId (bs (decodeString p pf[2]!.lo pf[2]!.hi)) <;> rfl
    · rw [ite_eq_left (by simp [k3]), ite_eq_left k2, ite_eq_right k3]
      rfl
  · rw [ite_eq_left (by simp [k2]), ite_eq_right k2]
    rfl

/-- info: 'Feed.Jwt.verify_eq' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms verify_eq

end Jwt

/-- **`verify` checks a token as the specification does**, under JWT_SECRET's key schedule:
`Spec.Auth.checkToken` with HMAC-SHA256 under JWT_SECRET's bytes, on every range of the input. -/
theorem Jwt.verify_spec (secret : ByteArray) (now : Nat) (a : ByteArray) (lo hi : Nat) :
    Jwt.verify (Hmac.Key.of secret) now a lo hi =
      .ofSpec (Spec.Auth.checkToken (Spec.HMAC.hmacSha256 (bs secret)) now (slice a lo hi)) :=
  Jwt.verify_eq (Hmac.macOf secret) now a lo hi

/-- info: 'Feed.Jwt.verify_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Jwt.verify_spec

/-- **An accepted token is signed**: three base64url parts, the third the encoding of the MAC of the
first two and the dot between them. -/
theorem Spec.Auth.checkToken_ok {mac : List UInt8 → List UInt8} {now : Nat} {t : List UInt8} {uid : Nat}
    {u : List UInt8} (h : Spec.Auth.checkToken mac now t = .ok uid u) :
    ∃ hb pb, t = b64urlEncode hb ++ [0x2e] ++ b64urlEncode pb ++ [0x2e] ++
      b64urlEncode (mac (b64urlEncode hb ++ [0x2e] ++ b64urlEncode pb)) := by
  unfold Spec.Auth.checkToken at h
  split at h
  next x y z hs =>
    split at h
    next hb pb sb e1 e2 e3 =>
      split at h
      next =>
        have hsb : sb = mac (x ++ [0x2e] ++ y) := by
          by_cases hne : sb = mac (x ++ [0x2e] ++ y)
          · exact hne
          · rw [ite_eq_left hne] at h
            simp only [ite_self] at h
            cases h
        have ht : t = x ++ [0x2e] ++ y ++ [0x2e] ++ z := by
          have := List.intercalate_splitOn (xs := t) (0x2e : UInt8)
          rw [hs] at this
          rw [← this]
          simp [List.intercalate]
        refine ⟨hb, pb, ?_⟩
        rw [ht, (b64urlDecode_eq_some_iff _ _).mp e1, (b64urlDecode_eq_some_iff _ _).mp e2, ← hsb,
          (b64urlDecode_eq_some_iff _ _).mp e3]
      next => cases h
    next => cases h
  next => cases h

/-- info: 'Feed.Spec.Auth.checkToken_ok' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Spec.Auth.checkToken_ok

/-! ## The Authorization field -/

/-- "Bearer " at `lo`: past the array's end `eqAt` reads a zero byte, which "Bearer " has none of,
and the range has fewer than seven bytes. -/
theorem eqAt_bearer (a : ByteArray) (lo : Nat) :
    Http.eqAt a lo (lo + 7) bearer = true ↔ slice a lo (lo + 7) = Spec.lit "Bearer " := by
  by_cases h : lo + 7 ≤ a.size
  · exact eqAt_spec a bearer (by omega) h
  · have hlen : (slice a lo (lo + 7)).length < 7 := by
      rw [← slice_min, slice_length a (Nat.min_le_right _ _)]; omega
    have hne : ∀ j < 7, bearer.get! j ≠ 0 := by decide
    constructor
    · intro he
      rw [Http.eqAt, Bool.and_eq_true, eqAt_go] at he
      have hj := he.2 (a.size - lo) (Nat.zero_le _) (by rw [show bearer.size = 7 from rfl]; omega)
      rw [get!_past a (by omega)] at hj
      exact absurd hj.symm (hne _ (by omega))
    · intro he
      have := congrArg List.length he
      rw [show (Spec.lit "Bearer ").length = 7 from rfl] at this
      omega

/-- **`authenticate` is `Spec.Auth.authenticate`**, for any key and the MAC it computes, on the
request's Authorization value. -/
theorem authenticate_eq {key : Hmac.Key} {mac : List UInt8 → List UInt8} (hm : MacOf key mac) (now : Nat)
    (a : ByteArray) (r : Http.Req) :
    authToSpec (authenticate key now a r) = Spec.Auth.authenticate mac now (r.toRequest a).auth := by
  unfold authenticate Spec.Auth.authenticate Http.Req.toRequest
  dsimp only
  cases r.hasAuth with
  | false => rfl
  | true =>
    simp only [Bool.not_true, Bool.false_or, ↓reduceIte, Option.bind_some, dropPrefix,
      show (Spec.lit "Bearer ").length = 7 from rfl]
    by_cases h7 : r.authHi < r.authLo + 7
    · -- shorter than "Bearer "
      rw [ite_eq_left (by simp [h7])]
      rw [ite_eq_right (fun he => by
        have := congrArg List.length he
        rw [List.length_take, show (Spec.lit "Bearer ").length = 7 from rfl] at this
        have : (slice a r.authLo r.authHi).length ≤ r.authHi - r.authLo := by simp [slice]; omega
        omega)]
      rfl
    · rw [slice_take a 7 (by omega), slice_drop a 7 (by omega)]
      by_cases hb : Http.eqAt a r.authLo (r.authLo + 7) bearer = true
      · rw [ite_eq_right (by simp [h7, hb]), ite_eq_left ((eqAt_bearer a r.authLo).mp hb), Jwt.verify_eq hm]
        dsimp only
        cases Spec.Auth.checkToken mac now (slice a (r.authLo + 7) r.authHi) <;> rfl
      · rw [ite_eq_left (by simp [h7, hb]), ite_eq_right (fun h => hb ((eqAt_bearer a r.authLo).mpr h))]
        rfl

/-- info: 'Feed.authenticate_eq' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms authenticate_eq

/-- **A request is authenticated as the specification says**: under JWT_SECRET's key schedule,
`authenticate` answers, as SPEC.md's rows, what `Spec.Auth.authenticate` answers with HMAC-SHA256
under JWT_SECRET's bytes on the request's Authorization value: the user's id and name, or
"missing bearer token", "invalid or expired token" or "invalid token payload". -/
theorem authenticate_spec (secret : ByteArray) (now : Nat) (a : ByteArray) (r : Http.Req) :
    authToSpec (authenticate (Hmac.Key.of secret) now a r) =
      Spec.Auth.authenticate (Spec.HMAC.hmacSha256 (bs secret)) now (r.toRequest a).auth :=
  authenticate_eq (Hmac.macOf secret) now a r

/-- info: 'Feed.authenticate_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms authenticate_spec

end Feed
