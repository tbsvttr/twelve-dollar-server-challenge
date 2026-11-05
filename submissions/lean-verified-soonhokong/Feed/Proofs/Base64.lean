import Feed.Spec.Base64
import Feed.Proofs.Slice
import Feed.Proofs.Jwt

/-!
# base64url, the signature comparison, the dots

`Feed/Jwt.lean`'s base64url codec computes RFC 4648 §5 as `Feed/Spec/Base64.lean` writes it, and
its comparison and splitting of a token read the token as `Feed/Spec/Auth.lean` does.

* `Spec.b64urlDecode_eq_some_iff`: a text decodes to `d` exactly when it is the encoding of `d`,
  so encoding is injective (`b64urlEncode_injective`) and every other text is rejected: one with
  '=' or another byte outside the alphabet (`b64urlDecode_eq_none_of_mem`,
  `b64urlDecode_eq_none_of_pad`), a length of 1 mod 4, or nonzero bits after the last whole byte
  (`b64urlDecode_eq_none_of_pad_bits`).
* `Jwt.b64Encode_spec`, `Jwt.b64Decode_spec`: the code computes `Spec.b64urlEncode` and
  `Spec.b64urlDecode`, the decoder on every range of its input, so `Jwt.b64Decode` accepts exactly
  the text `Jwt.b64Encode` writes (`b64Decode_eq_some_iff`) and rejects '=' and nonzero pad bits
  (`b64Decode_eq_none_of_pad`, `b64Decode_eq_none_of_pad_bits`).
* `Jwt.ctEq_iff`: the signature comparison is byte equality. Only its value is proved. RFC 7518
  §3.2 asks that it take the same time whatever the bytes; that stays in the trust base, since it
  depends on how Lean and gcc compile `ctEq.go`.
* `Jwt.dots_spec`: the three `findByte` calls of `Jwt.verify` accept a range exactly when it has two
  dots, and cut it where `List.splitOn` does, as `Spec.Auth.checkToken` reads a JWS in the compact
  serialization (RFC 7515 §7.1).

The finite facts about the alphabet are checked by `decide +kernel` (the kernel evaluates them;
256 cases are beyond `decide`'s default recursion depth).
-/

namespace Feed.Spec

/-! ## Decoding inverts encoding -/

theorem b64urlVal_char : ∀ v : Fin 64, b64urlVal (b64urlChar v) = some v := by decide +kernel

theorem b64urlVal_char_of_lt {v : Nat} (h : v < 64) : b64urlVal (b64urlChar v) = some v :=
  b64urlVal_char ⟨v, h⟩

theorem b64urlVal_eq_some {c : UInt8} {v : Nat} (h : b64urlVal c = some v) : v < 64 ∧ b64urlChar v = c := by
  obtain ⟨hv, hc, -⟩ := List.idxOf?_eq_some_iff.mp h
  have hlen : b64urlAlphabet.length = 64 := by decide
  refine ⟨hlen ▸ hv, ?_⟩
  rw [b64urlChar, List.getD_eq_getElem?_getD, List.getElem?_eq_getElem hv, Option.getD_some, hc]

theorem toUInt8_eq_of_mod {n : Nat} {x : UInt8} (h : n % 256 = x.toNat) : n.toUInt8 = x :=
  UInt8.toNat_inj.mp (by rw [Nat.toUInt8_eq, UInt8.toNat_ofNat']; exact h)

theorem toNat_toUInt8_of_lt {n : Nat} (h : n < 256) : n.toUInt8.toNat = n := by
  rw [Nat.toUInt8_eq, UInt8.toNat_ofNat']; exact Nat.mod_eq_of_lt h

/-- 24 bits as four groups of six. -/
theorem sextets4 {n : Nat} (_ : n < 2 ^ 24) :
    n / 262144 * 262144 + n / 4096 % 64 * 4096 + n / 64 % 64 * 64 + n % 64 = n := by omega

/-- 18 bits as three groups of six. -/
theorem sextets3 {n : Nat} (_ : n < 2 ^ 18) : n / 4096 * 4096 + n / 64 % 64 * 64 + n % 64 = n := by omega

/-- 24 bits as three bytes. -/
theorem octets3 {n : Nat} (_ : n < 2 ^ 24) : n / 65536 * 65536 + n / 256 % 256 * 256 + n % 256 = n := by omega

/-- Decoding an encoding gives back the bytes. -/
theorem b64urlDecode_encode : ∀ d : List UInt8, b64urlDecode (b64urlEncode d) = some d
  | x :: y :: z :: rest => by
    have hx := x.toNat_lt; have hy := y.toNat_lt; have hz := z.toNat_lt
    simp only [b64urlEncode, List.cons_append, List.nil_append, b64urlDecode]
    rw [b64urlVal_char_of_lt (by omega), b64urlVal_char_of_lt (Nat.mod_lt _ (by decide)),
      b64urlVal_char_of_lt (Nat.mod_lt _ (by decide)), b64urlVal_char_of_lt (Nat.mod_lt _ (by decide)),
      b64urlDecode_encode rest]
    simp only [Nat.reducePow, Option.bind_eq_bind, Option.bind_some, Option.some.injEq, List.cons.injEq, and_true]
    rw [sextets4 (by omega)]
    exact ⟨toUInt8_eq_of_mod (by omega), toUInt8_eq_of_mod (by omega), toUInt8_eq_of_mod (by omega)⟩
  | [x, y] => by
    have hx := x.toNat_lt; have hy := y.toNat_lt
    simp only [b64urlEncode, b64urlDecode]
    rw [b64urlVal_char_of_lt (by omega), b64urlVal_char_of_lt (Nat.mod_lt _ (by decide)),
      b64urlVal_char_of_lt (Nat.mod_lt _ (by decide))]
    simp only [Nat.reducePow, Option.bind_eq_bind, Option.bind_some]
    rw [sextets3 (by omega), ite_eq_left (by omega)]
    simp only [Option.some.injEq, List.cons.injEq, and_true]
    exact ⟨toUInt8_eq_of_mod (by omega), toUInt8_eq_of_mod (by omega)⟩
  | [x] => by
    have hx := x.toNat_lt
    simp only [b64urlEncode, b64urlDecode]
    rw [b64urlVal_char_of_lt (by omega), b64urlVal_char_of_lt (by omega)]
    simp only [Nat.reducePow, Option.bind_eq_bind, Option.bind_some]
    rw [ite_eq_left (by omega)]
    simp only [Option.some.injEq, List.cons.injEq, and_true]
    exact toUInt8_eq_of_mod (by omega)
  | [] => rfl

/-- A text that decodes is the encoding of what it decodes to. -/
theorem b64urlEncode_decode : ∀ (s d : List UInt8), b64urlDecode s = some d → b64urlEncode d = s
  | [], d, h => by
    simp only [b64urlDecode, Option.some.injEq] at h
    subst h; rfl
  | [_], d, h => by simp [b64urlDecode] at h
  | [c0, c1], d, h => by
    simp only [b64urlDecode, Option.bind_eq_bind] at h
    cases h0 : b64urlVal c0 with
    | none => simp [h0] at h
    | some v0 =>
    cases h1 : b64urlVal c1 with
    | none => simp [h0, h1] at h
    | some v1 =>
    obtain ⟨hv0, rfl⟩ := b64urlVal_eq_some h0
    obtain ⟨hv1, rfl⟩ := b64urlVal_eq_some h1
    simp only [h0, h1, Option.bind_some, Nat.reducePow] at h
    split at h
    · simp only [Option.some.injEq] at h
      subst h
      simp only [b64urlEncode, Nat.reducePow]
      rw [toNat_toUInt8_of_lt (by omega)]
      simp only [List.cons.injEq, and_true]
      exact ⟨congrArg _ (by omega), congrArg _ (by omega)⟩
    · cases h
  | [c0, c1, c2], d, h => by
    simp only [b64urlDecode, Option.bind_eq_bind] at h
    cases h0 : b64urlVal c0 with
    | none => simp [h0] at h
    | some v0 =>
    cases h1 : b64urlVal c1 with
    | none => simp [h0, h1] at h
    | some v1 =>
    cases h2 : b64urlVal c2 with
    | none => simp [h0, h1, h2] at h
    | some v2 =>
    obtain ⟨hv0, rfl⟩ := b64urlVal_eq_some h0
    obtain ⟨hv1, rfl⟩ := b64urlVal_eq_some h1
    obtain ⟨hv2, rfl⟩ := b64urlVal_eq_some h2
    simp only [h0, h1, h2, Option.bind_some, Nat.reducePow] at h
    split at h
    · simp only [Option.some.injEq] at h
      subst h
      simp only [b64urlEncode, Nat.reducePow]
      rw [toNat_toUInt8_of_lt (by omega), toNat_toUInt8_of_lt (by omega)]
      simp only [List.cons.injEq, and_true]
      exact ⟨congrArg _ (by omega), congrArg _ (by omega), congrArg _ (by omega)⟩
    · cases h
  | c0 :: c1 :: c2 :: c3 :: rest, d, h => by
    simp only [b64urlDecode, Option.bind_eq_bind] at h
    cases h0 : b64urlVal c0 with
    | none => simp [h0] at h
    | some v0 =>
    cases h1 : b64urlVal c1 with
    | none => simp [h0, h1] at h
    | some v1 =>
    cases h2 : b64urlVal c2 with
    | none => simp [h0, h1, h2] at h
    | some v2 =>
    cases h3 : b64urlVal c3 with
    | none => simp [h0, h1, h2, h3] at h
    | some v3 =>
    cases hr : b64urlDecode rest with
    | none => simp [h0, h1, h2, h3, hr] at h
    | some r =>
    obtain ⟨hv0, rfl⟩ := b64urlVal_eq_some h0
    obtain ⟨hv1, rfl⟩ := b64urlVal_eq_some h1
    obtain ⟨hv2, rfl⟩ := b64urlVal_eq_some h2
    obtain ⟨hv3, rfl⟩ := b64urlVal_eq_some h3
    simp only [h0, h1, h2, h3, hr, Option.bind_some, Nat.reducePow, Option.some.injEq] at h
    subst h
    simp only [List.cons_append, List.nil_append, b64urlEncode, Nat.reducePow, b64urlEncode_decode rest r hr]
    rw [toNat_toUInt8_of_lt (by omega), toNat_toUInt8_of_lt (Nat.mod_lt _ (by decide)),
      toNat_toUInt8_of_lt (Nat.mod_lt _ (by decide)), octets3 (by omega)]
    simp only [List.cons.injEq, and_true]
    exact ⟨congrArg _ (by omega), congrArg _ (by omega), congrArg _ (by omega), congrArg _ (by omega)⟩

/-- **base64url decoding is exact**: a text decodes to `d` exactly when it is the encoding of `d`.
So the decoder rejects every other text: one with '=' or another byte outside the alphabet, a
length of 1 mod 4, nonzero bits after the last whole byte. -/
theorem b64urlDecode_eq_some_iff (s d : List UInt8) : b64urlDecode s = some d ↔ b64urlEncode d = s :=
  ⟨b64urlEncode_decode s d, fun h => h ▸ b64urlDecode_encode d⟩

/-- info: 'Feed.Spec.b64urlDecode_eq_some_iff' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms b64urlDecode_eq_some_iff

/-- Distinct byte strings have distinct encodings. -/
theorem b64urlEncode_injective : Function.Injective b64urlEncode := fun d d' h =>
  Option.some.inj ((b64urlDecode_encode d).symm.trans (h ▸ b64urlDecode_encode d'))

/-- info: 'Feed.Spec.b64urlEncode_injective' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms b64urlEncode_injective

/-! ## The texts that do not decode -/

/-- Every character of an encoding is in the alphabet. -/
theorem b64urlVal_of_mem_encode : ∀ (d : List UInt8) {c : UInt8}, c ∈ b64urlEncode d → ∃ v, b64urlVal c = some v
  | x :: y :: z :: rest, c, h => by
    have hx := x.toNat_lt; have hy := y.toNat_lt; have hz := z.toNat_lt
    simp only [b64urlEncode, List.cons_append, List.nil_append, List.mem_cons] at h
    rcases h with rfl | rfl | rfl | rfl | h
    · exact ⟨_, b64urlVal_char_of_lt (by omega)⟩
    · exact ⟨_, b64urlVal_char_of_lt (Nat.mod_lt _ (by decide))⟩
    · exact ⟨_, b64urlVal_char_of_lt (Nat.mod_lt _ (by decide))⟩
    · exact ⟨_, b64urlVal_char_of_lt (Nat.mod_lt _ (by decide))⟩
    · exact b64urlVal_of_mem_encode rest h
  | [x, y], c, h => by
    have hx := x.toNat_lt; have hy := y.toNat_lt
    simp only [b64urlEncode, List.mem_cons, List.not_mem_nil, or_false] at h
    rcases h with rfl | rfl | rfl
    · exact ⟨_, b64urlVal_char_of_lt (by omega)⟩
    · exact ⟨_, b64urlVal_char_of_lt (Nat.mod_lt _ (by decide))⟩
    · exact ⟨_, b64urlVal_char_of_lt (Nat.mod_lt _ (by decide))⟩
  | [x], c, h => by
    have hx := x.toNat_lt
    simp only [b64urlEncode, List.mem_cons, List.not_mem_nil, or_false] at h
    rcases h with rfl | rfl
    · exact ⟨_, b64urlVal_char_of_lt (by omega)⟩
    · exact ⟨_, b64urlVal_char_of_lt (Nat.mod_lt _ (by decide))⟩
  | [], c, h => by simp [b64urlEncode] at h

theorem b64urlEncode_length_mod : ∀ d : List UInt8, (b64urlEncode d).length % 4 ≠ 1
  | x :: y :: z :: rest => by
    have := b64urlEncode_length_mod rest
    simp only [b64urlEncode, List.cons_append, List.nil_append, List.length_cons]
    omega
  | [_, _] | [_] | [] => by simp only [b64urlEncode, List.length_cons, List.length_nil]; decide

/-- The last character of an encoding of length 2 or 3 mod 4 ends in 4 or 2 zero bits. -/
theorem b64urlEncode_last : ∀ (d : List UInt8) {c : UInt8} {v : Nat}, (b64urlEncode d).getLast? = some c →
    b64urlVal c = some v →
    ((b64urlEncode d).length % 4 = 2 → v % 2 ^ 4 = 0) ∧ ((b64urlEncode d).length % 4 = 3 → v % 2 ^ 2 = 0)
  | x :: y :: z :: rest, c, v, hc, hv => by
    have ih := @b64urlEncode_last rest c v
    simp only [b64urlEncode, List.cons_append, List.nil_append, List.length_cons] at hc ⊢
    cases hr : b64urlEncode rest with
    | nil => simp
    | cons e es =>
      rw [hr] at hc ih
      simp only [List.getLast?_cons_cons] at hc
      have := ih hc hv
      simp only [List.length_cons] at this ⊢
      exact ⟨fun h => this.1 (by omega), fun h => this.2 (by omega)⟩
  | [x, y], c, v, hc, hv => by
    simp only [b64urlEncode, List.getLast?_cons_cons, List.getLast?_singleton, Option.some.injEq] at hc
    subst hc
    rw [b64urlVal_char_of_lt (Nat.mod_lt _ (by decide)), Option.some.injEq] at hv
    subst hv
    simp only [b64urlEncode, List.length_cons, List.length_nil]
    omega
  | [x], c, v, hc, hv => by
    simp only [b64urlEncode, List.getLast?_cons_cons, List.getLast?_singleton, Option.some.injEq] at hc
    subst hc
    rw [b64urlVal_char_of_lt (Nat.mod_lt _ (by decide)), Option.some.injEq] at hv
    subst hv
    simp only [b64urlEncode, List.length_cons, List.length_nil]
    omega
  | [], c, v, hc, hv => by simp [b64urlEncode] at hc

/-- A byte outside the alphabet anywhere: the text is not base64url. -/
theorem b64urlDecode_eq_none_of_mem {s : List UInt8} {c : UInt8} (hc : c ∈ s) (h : b64urlVal c = none) :
    b64urlDecode s = none := by
  cases hd : b64urlDecode s with
  | none => rfl
  | some d =>
    rw [b64urlDecode_eq_some_iff] at hd
    subst hd
    obtain ⟨v, hv⟩ := b64urlVal_of_mem_encode d hc
    rw [hv] at h; cases h

/-- **No padding**: a text with '=' anywhere is not base64url (RFC 7515 §2). -/
theorem b64urlDecode_eq_none_of_pad {s : List UInt8} (h : 0x3d ∈ s) : b64urlDecode s = none :=
  b64urlDecode_eq_none_of_mem h (by decide)

/-- info: 'Feed.Spec.b64urlDecode_eq_none_of_pad' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms b64urlDecode_eq_none_of_pad

theorem b64urlDecode_eq_none_of_length {s : List UInt8} (h : s.length % 4 = 1) : b64urlDecode s = none := by
  cases hd : b64urlDecode s with
  | none => rfl
  | some d =>
    rw [b64urlDecode_eq_some_iff] at hd
    subst hd
    exact absurd h (b64urlEncode_length_mod d)

/-- **Zero pad bits**: the last character of a text of length 2 or 3 mod 4 ends in 4 or 2 bits
after the last whole byte; if they are not zero, the text is not the encoding of anything
(RFC 4648 §3.5). -/
theorem b64urlDecode_eq_none_of_pad_bits {s : List UInt8} {c : UInt8} {v : Nat} (hc : s.getLast? = some c)
    (hv : b64urlVal c = some v) (h : s.length % 4 = 2 ∧ v % 2 ^ 4 ≠ 0 ∨ s.length % 4 = 3 ∧ v % 2 ^ 2 ≠ 0) :
    b64urlDecode s = none := by
  cases hd : b64urlDecode s with
  | none => rfl
  | some d =>
    rw [b64urlDecode_eq_some_iff] at hd
    subst hd
    have := b64urlEncode_last d hc hv
    rcases h with ⟨h1, h2⟩ | ⟨h1, h2⟩
    · exact absurd (this.1 h1) h2
    · exact absurd (this.2 h1) h2

/-- info: 'Feed.Spec.b64urlDecode_eq_none_of_pad_bits' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms b64urlDecode_eq_none_of_pad_bits

end Feed.Spec

namespace Feed.Jwt
open Spec

/-! ## The decoder -/

/-- `b64Val` gives each character of the alphabet its place in it. -/
theorem b64Val_char : ∀ v : Fin 64, b64Val (b64urlChar v) = v.val.toUInt8 := by decide +kernel

/-- A byte to which `b64Val` gives a value is the alphabet's character at that place. -/
theorem b64Val_table : ∀ n : Fin 256, b64Val n.val.toUInt8 ≠ 64 →
    b64urlChar (b64Val n.val.toUInt8).toNat = n.val.toUInt8 := by decide +kernel

/-- `b64Val` is the specification's `b64urlVal`, with 64 for a byte outside the alphabet. -/
theorem b64Val_spec (c : UInt8) : b64urlVal c = if b64Val c = 64 then none else some (b64Val c).toNat := by
  by_cases h : b64Val c = 64
  · rw [ite_eq_left h]
    cases hv : b64urlVal c with
    | none => rfl
    | some v =>
      obtain ⟨hv64, rfl⟩ := b64urlVal_eq_some hv
      have e := congrArg UInt8.toNat ((b64Val_char ⟨v, hv64⟩).symm.trans h)
      rw [toNat_toUInt8_of_lt (by omega), show (64 : UInt8).toNat = 64 from rfl] at e
      exact absurd e (Nat.ne_of_lt hv64)
  · rw [ite_eq_right h]
    have hc : b64urlChar (b64Val c).toNat = c := by simpa using b64Val_table ⟨c.toNat, c.toNat_lt⟩ (by simpa using h)
    have hlt : (b64Val c).toNat < 64 := by
      refine Nat.lt_of_not_le fun hge => h ?_
      have hlen : b64urlAlphabet.length = 64 := by decide
      rw [b64urlChar, List.getD_eq_getElem?_getD, List.getElem?_eq_none (by omega)] at hc
      rw [← hc]; decide
    calc b64urlVal c = b64urlVal (b64urlChar (b64Val c).toNat) := by rw [hc]
      _ = some (b64Val c).toNat := b64urlVal_char_of_lt hlt

theorem b64Val_some {c : UInt8} (h : b64Val c ≠ 64) : b64urlVal c = some (b64Val c).toNat := by
  rw [b64Val_spec, ite_eq_right h]

theorem b64Val_lt {c : UInt8} (h : b64Val c ≠ 64) : (b64Val c).toNat < 64 :=
  (b64urlVal_eq_some (b64Val_some h)).1

/-- A byte outside the alphabet anywhere in the rest of the text: `none`. -/
theorem decode_bad (a : ByteArray) : ∀ f i (acc nbits : UInt32) (out : ByteArray) j, i ≤ j → j < i + f →
    b64Val (a.get! j) = 64 → b64Decode.go a i f acc nbits out = none := by
  intro f
  induction f with
  | zero => intros; omega
  | succ f ih =>
    intro i acc nbits out j h1 h2 hj
    by_cases hi : b64Val (a.get! i) = 64
    · simp [b64Decode.go, hi]
    · have : i ≠ j := fun e => hi (e ▸ hj)
      simp only [b64Decode.go, beq_iff_eq, hi, ite_false]
      split <;> exact ih _ _ _ _ j (by omega) (by omega) hj

theorem toNat_shl_or (m : Nat) (x : UInt32) (hm : m < 64) (hx : x.toNat < 64) :
    (UInt32.ofNat m <<< 6 ||| x).toNat = m * 64 + x.toNat := by
  rw [UInt32.toNat_or, UInt32.toNat_shiftLeft, UInt32.toNat_ofNat']
  simp only [show (6 : UInt32).toNat % 32 = 6 from rfl, Nat.shiftLeft_eq]
  rw [Nat.mod_eq_of_lt (by omega : m < 2 ^ 32), Nat.mod_eq_of_lt (by omega : m * 2 ^ 6 < 2 ^ 32),
    ← Nat.shiftLeft_eq, ← Nat.shiftLeft_add_eq_or_of_lt (by omega), Nat.shiftLeft_eq]

theorem and_ofNat (y : UInt32) (k : Nat) (hk : k ≤ 32) :
    y &&& UInt32.ofNat (2 ^ k - 1) = UInt32.ofNat (y.toNat % 2 ^ k) := by
  apply UInt32.toNat_inj.mp
  have h32 : 2 ^ k ≤ 2 ^ 32 := Nat.pow_le_pow_right (by omega) hk
  have h1 : 2 ^ k - 1 < 2 ^ 32 := by omega
  have h2 : y.toNat % 2 ^ k < 2 ^ 32 := Nat.lt_of_lt_of_le (Nat.mod_lt _ (Nat.two_pow_pos k)) h32
  rw [UInt32.toNat_and, UInt32.toNat_ofNat', UInt32.toNat_ofNat', Nat.mod_eq_of_lt h1, Nat.and_two_pow_sub_one_eq_mod,
    Nat.mod_eq_of_lt h2]

theorem shr_toUInt8 (y : UInt32) (k : Nat) (hk : k < 32) :
    (y >>> UInt32.ofNat k).toUInt8 = UInt8.ofNat (y.toNat / 2 ^ k) := by
  apply UInt8.toNat_inj.mp
  rw [UInt32.toNat_toUInt8, UInt32.toNat_shiftRight, UInt32.toNat_ofNat', UInt8.toNat_ofNat',
    Nat.mod_eq_of_lt (by omega : k < 2 ^ 32), Nat.mod_eq_of_lt hk, Nat.shiftRight_eq_div_pow]

/-- The first character of a group: its six bits wait. -/
theorem decode_step0 (a : ByteArray) (i f : Nat) (out : ByteArray) (h : b64Val (a.get! i) ≠ 64) :
    b64Decode.go a i (f + 1) 0 0 out = b64Decode.go a (i + 1) f (UInt32.ofNat (b64Val (a.get! i)).toNat) 6 out := by
  simp [b64Decode.go, h]

/-- The second: the group's first byte, and four bits wait. -/
theorem decode_step6 (a : ByteArray) (i f m : Nat) (out : ByteArray) (hm : m < 64) (h : b64Val (a.get! i) ≠ 64) :
    b64Decode.go a i (f + 1) (UInt32.ofNat m) 6 out =
      b64Decode.go a (i + 1) f (UInt32.ofNat ((m * 64 + (b64Val (a.get! i)).toNat) % 2 ^ 4)) 4
        (out.push (UInt8.ofNat ((m * 64 + (b64Val (a.get! i)).toNat) / 2 ^ 4))) := by
  have e := toNat_shl_or m (b64Val (a.get! i)).toUInt32 hm (by rw [UInt8.toNat_toUInt32]; exact b64Val_lt h)
  rw [UInt8.toNat_toUInt32] at e
  simp only [b64Decode.go, beq_iff_eq, h, ite_false]
  rw [show (6 : UInt32) + 6 = 12 from rfl, ite_eq_left (by decide), show (12 : UInt32) - 8 = UInt32.ofNat 4 from rfl,
    show (1 : UInt32) <<< UInt32.ofNat 4 - 1 = UInt32.ofNat (2 ^ 4 - 1) from rfl, and_ofNat _ _ (by omega),
    shr_toUInt8 _ _ (by omega), e]
  rfl

/-- The third: the second byte, and two bits wait. -/
theorem decode_step4 (a : ByteArray) (i f m : Nat) (out : ByteArray) (hm : m < 64) (h : b64Val (a.get! i) ≠ 64) :
    b64Decode.go a i (f + 1) (UInt32.ofNat m) 4 out =
      b64Decode.go a (i + 1) f (UInt32.ofNat ((m * 64 + (b64Val (a.get! i)).toNat) % 2 ^ 2)) 2
        (out.push (UInt8.ofNat ((m * 64 + (b64Val (a.get! i)).toNat) / 2 ^ 2))) := by
  have e := toNat_shl_or m (b64Val (a.get! i)).toUInt32 hm (by rw [UInt8.toNat_toUInt32]; exact b64Val_lt h)
  rw [UInt8.toNat_toUInt32] at e
  simp only [b64Decode.go, beq_iff_eq, h, ite_false]
  rw [show (4 : UInt32) + 6 = 10 from rfl, ite_eq_left (by decide), show (10 : UInt32) - 8 = UInt32.ofNat 2 from rfl,
    show (1 : UInt32) <<< UInt32.ofNat 2 - 1 = UInt32.ofNat (2 ^ 2 - 1) from rfl, and_ofNat _ _ (by omega),
    shr_toUInt8 _ _ (by omega), e]
  rfl

/-- The fourth: the third byte, and nothing waits. -/
theorem decode_step2 (a : ByteArray) (i f m : Nat) (out : ByteArray) (hm : m < 64) (h : b64Val (a.get! i) ≠ 64) :
    b64Decode.go a i (f + 1) (UInt32.ofNat m) 2 out =
      b64Decode.go a (i + 1) f 0 0 (out.push (UInt8.ofNat (m * 64 + (b64Val (a.get! i)).toNat))) := by
  have e := toNat_shl_or m (b64Val (a.get! i)).toUInt32 hm (by rw [UInt8.toNat_toUInt32]; exact b64Val_lt h)
  rw [UInt8.toNat_toUInt32] at e
  simp only [b64Decode.go, beq_iff_eq, h, ite_false]
  rw [show (2 : UInt32) + 6 = 8 from rfl, ite_eq_left (by decide), show (8 : UInt32) - 8 = UInt32.ofNat 0 from rfl,
    show (1 : UInt32) <<< UInt32.ofNat 0 - 1 = UInt32.ofNat (2 ^ 0 - 1) from rfl, and_ofNat _ _ (by omega),
    shr_toUInt8 _ _ (by omega), e, Nat.mod_one, Nat.pow_zero, Nat.div_one]
  rfl

/-- The end of the text: the bits that wait must be zero. -/
theorem decode_end (a : ByteArray) (i m : Nat) (nbits : UInt32) (out : ByteArray) (hm : m < 64) :
    b64Decode.go a i 0 (UInt32.ofNat m) nbits out = if m = 0 then some out else none := by
  simp only [b64Decode.go]
  by_cases h0 : m = 0
  · subst h0; rfl
  · have : UInt32.ofNat m ≠ 0 := fun e => h0 (by
      have := congrArg UInt32.toNat e
      rwa [UInt32.toNat_ofNat', Nat.mod_eq_of_lt (by omega)] at this)
    simp [this, h0]

/-- On text of the alphabet whose length is not 1 mod 4, the loop decodes as the specification,
a group of four characters at a time. -/
theorem decode_go (a : ByteArray) (hi : Nat) (hhi : hi ≤ a.size) :
    ∀ n i (out : ByteArray), i + n = hi → n % 4 ≠ 1 → (∀ j, i ≤ j → j < hi → b64Val (a.get! j) ≠ 64) →
      (b64Decode.go a i n 0 0 out).map bs = (b64urlDecode (slice a i hi)).map (bs out ++ ·)
  | 0, i, out, hn, _, _ => by
    rw [show hi = i by omega, slice_empty]
    simp [b64Decode.go, b64urlDecode]
  | 1, _, _, _, h4, _ => absurd rfl h4
  | 2, i, out, hn, _, hv => by
    have h0 := hv i (by omega) (by omega)
    have h1 := hv (i + 1) (by omega) (by omega)
    have l0 := b64Val_lt h0; have l1 := b64Val_lt h1
    rw [slice_cons a (by omega) hhi, slice_cons a (by omega) hhi, show i + 1 + 1 = hi by omega, slice_empty,
      decode_step0 a i _ out h0, decode_step6 a (i + 1) _ _ out l0 h1, decode_end a _ _ _ _ (by omega)]
    simp only [b64urlDecode, b64Val_some h0, b64Val_some h1, Option.bind_eq_bind, Option.bind_some]
    generalize (b64Val (a.get! i)).toNat = v0 at l0 ⊢
    generalize (b64Val (a.get! (i + 1))).toNat = v1 at l1 ⊢
    by_cases hz : v1 % 2 ^ 4 = 0
    · rw [ite_eq_left (by omega), ite_eq_left hz]
      simp only [Option.map_some, bs_push, Nat.toUInt8_eq]
      rw [show (v0 * 64 + v1) / 2 ^ 4 = v0 * 2 ^ 2 + v1 / 2 ^ 4 by omega]
    · rw [ite_eq_right (by omega), ite_eq_right hz]; rfl
  | 3, i, out, hn, _, hv => by
    have h0 := hv i (by omega) (by omega)
    have h1 := hv (i + 1) (by omega) (by omega)
    have h2 := hv (i + 1 + 1) (by omega) (by omega)
    have l0 := b64Val_lt h0; have l1 := b64Val_lt h1; have l2 := b64Val_lt h2
    rw [slice_cons a (by omega) hhi, slice_cons a (by omega) hhi, slice_cons a (by omega) hhi,
      show i + 1 + 1 + 1 = hi by omega, slice_empty, decode_step0 a i _ out h0, decode_step6 a (i + 1) _ _ out l0 h1,
      decode_step4 a (i + 1 + 1) _ _ _ (by omega) h2, decode_end a _ _ _ _ (by omega)]
    simp only [b64urlDecode, b64Val_some h0, b64Val_some h1, b64Val_some h2, Option.bind_eq_bind, Option.bind_some]
    generalize (b64Val (a.get! i)).toNat = v0 at l0 ⊢
    generalize (b64Val (a.get! (i + 1))).toNat = v1 at l1 ⊢
    generalize (b64Val (a.get! (i + 1 + 1))).toNat = v2 at l2 ⊢
    by_cases hz : (v0 * 2 ^ 12 + v1 * 2 ^ 6 + v2) % 2 ^ 2 = 0
    · rw [ite_eq_left (by omega), ite_eq_left hz]
      simp only [Option.map_some, bs_push, Nat.toUInt8_eq, List.append_assoc, List.cons_append, List.nil_append]
      rw [show (v0 * 64 + v1) / 2 ^ 4 = (v0 * 2 ^ 12 + v1 * 2 ^ 6 + v2) / 2 ^ 10 by omega,
        show ((v0 * 64 + v1) % 2 ^ 4 * 64 + v2) / 2 ^ 2 = (v0 * 2 ^ 12 + v1 * 2 ^ 6 + v2) / 2 ^ 2 % 2 ^ 8 by omega]
    · rw [ite_eq_right (by omega), ite_eq_right hz]; rfl
  | m + 4, i, out, hn, _, hv => by
    have h0 := hv i (by omega) (by omega)
    have h1 := hv (i + 1) (by omega) (by omega)
    have h2 := hv (i + 1 + 1) (by omega) (by omega)
    have h3 := hv (i + 1 + 1 + 1) (by omega) (by omega)
    have l0 := b64Val_lt h0; have l1 := b64Val_lt h1; have l2 := b64Val_lt h2; have l3 := b64Val_lt h3
    rw [slice_cons a (by omega) hhi, slice_cons a (by omega) hhi, slice_cons a (by omega) hhi,
      slice_cons a (by omega) hhi, decode_step0 a i _ out h0, decode_step6 a (i + 1) _ _ out l0 h1,
      decode_step4 a (i + 1 + 1) _ _ _ (by omega) h2, decode_step2 a (i + 1 + 1 + 1) _ _ _ (by omega) h3,
      decode_go a hi hhi m (i + 1 + 1 + 1 + 1) _ (by omega) (by omega) (fun j h1 h2 => hv j (by omega) h2)]
    simp only [b64urlDecode, b64Val_some h0, b64Val_some h1, b64Val_some h2, b64Val_some h3, Option.bind_eq_bind,
      Option.bind_some]
    generalize (b64Val (a.get! i)).toNat = v0 at l0 ⊢
    generalize (b64Val (a.get! (i + 1))).toNat = v1 at l1 ⊢
    generalize (b64Val (a.get! (i + 1 + 1))).toNat = v2 at l2 ⊢
    generalize (b64Val (a.get! (i + 1 + 1 + 1))).toNat = v3 at l3 ⊢
    cases b64urlDecode (slice a (i + 1 + 1 + 1 + 1) hi) with
    | none => rfl
    | some r =>
      simp only [Option.map_some, Option.bind_some, bs_push, Nat.toUInt8_eq, List.append_assoc, List.cons_append,
        List.nil_append]
      rw [show (v0 * 64 + v1) / 2 ^ 4 = (v0 * 2 ^ 18 + v1 * 2 ^ 12 + v2 * 2 ^ 6 + v3) / 2 ^ 16 by omega,
        show ((v0 * 64 + v1) % 2 ^ 4 * 64 + v2) / 2 ^ 2 =
          (v0 * 2 ^ 18 + v1 * 2 ^ 12 + v2 * 2 ^ 6 + v3) / 2 ^ 8 % 2 ^ 8 by omega,
        show ((v0 * 64 + v1) % 2 ^ 4 * 64 + v2) % 2 ^ 2 * 64 + v3 =
          (v0 * 2 ^ 18 + v1 * 2 ^ 12 + v2 * 2 ^ 6 + v3) % 2 ^ 8 by omega]

/-- **`b64Decode` decodes base64url**: on every range of the input (clamped to the array, as
`slice` is), it answers what `Spec.b64urlDecode` answers on the range's bytes. -/
theorem b64Decode_spec (a : ByteArray) (lo hi : Nat) :
    (b64Decode a lo hi).map bs = b64urlDecode (slice a lo hi) := by
  rw [slice_clamp]
  unfold b64Decode
  dsimp only
  generalize hm : min hi a.size = m
  have hma : m ≤ a.size := by omega
  by_cases hlo : lo ≤ m
  · rw [Nat.min_eq_left hlo]
    by_cases h4 : (m - lo) % 4 = 1
    · rw [ite_eq_left (by simpa using h4), b64urlDecode_eq_none_of_length (by rw [slice_length a hma]; exact h4)]
      rfl
    · rw [ite_eq_right (by simpa using h4)]
      by_cases hv : ∀ j, lo ≤ j → j < m → b64Val (a.get! j) ≠ 64
      · rw [decode_go a m hma (m - lo) lo _ (by omega) h4 hv]
        simp
      · simp only [Classical.not_forall, Decidable.not_not] at hv
        obtain ⟨j, hj1, hj2, hj⟩ := hv
        have hmem : a.get! j ∈ slice a lo m := by
          have := slice_getElem? a (lo := lo) (hi := m) (k := j - lo) (by omega) hma
          rw [Nat.add_sub_cancel' hj1] at this
          exact List.mem_of_getElem? this
        rw [decode_bad a _ lo 0 0 _ j hj1 (by omega) hj,
          b64urlDecode_eq_none_of_mem hmem (by rw [b64Val_spec, ite_eq_left hj])]
        rfl
  · rw [Nat.min_eq_right (by omega), slice_empty, show m - lo = 0 by omega]
    simp [b64Decode.go, b64urlDecode]

/-- info: 'Feed.Jwt.b64Decode_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms b64Decode_spec

/-- A range decodes to `d` exactly when it is the base64url text of `d`. -/
theorem b64Decode_eq_some_iff (a : ByteArray) (lo hi : Nat) (d : ByteArray) :
    b64Decode a lo hi = some d ↔ b64urlEncode (bs d) = slice a lo hi := by
  rw [← b64urlDecode_eq_some_iff, ← b64Decode_spec]
  constructor
  · intro h; rw [h]; rfl
  · intro h
    cases hd : b64Decode a lo hi with
    | none => rw [hd] at h; cases h
    | some d' =>
      rw [hd] at h
      exact congrArg some (ByteArray.ext (Array.toList_inj.mp (Option.some.inj h)))

/-- `b64Decode` rejects a range with '=' in it (`b64urlDecode_eq_none_of_pad`). -/
theorem b64Decode_eq_none_of_pad {a : ByteArray} {lo hi : Nat} (h : 0x3d ∈ slice a lo hi) :
    b64Decode a lo hi = none := by
  have := b64Decode_spec a lo hi
  rwa [b64urlDecode_eq_none_of_pad h, Option.map_eq_none_iff] at this

/-- `b64Decode` rejects a range whose last character has nonzero bits after the last whole byte
(`b64urlDecode_eq_none_of_pad_bits`). -/
theorem b64Decode_eq_none_of_pad_bits {a : ByteArray} {lo hi : Nat} {c : UInt8} {v : Nat}
    (hc : (slice a lo hi).getLast? = some c) (hv : b64urlVal c = some v)
    (h : (slice a lo hi).length % 4 = 2 ∧ v % 2 ^ 4 ≠ 0 ∨ (slice a lo hi).length % 4 = 3 ∧ v % 2 ^ 2 ≠ 0) :
    b64Decode a lo hi = none := by
  have := b64Decode_spec a lo hi
  rwa [b64urlDecode_eq_none_of_pad_bits hc hv h, Option.map_eq_none_iff] at this

/-! ## The encoder -/

theorem b64Char_table : ∀ v : Fin 64, b64Char v.val.toUInt32 = b64urlChar v.val := by decide +kernel

theorem b64Char_eq (v : UInt32) (h : v.toNat < 64) : b64Char v = b64urlChar v.toNat := by
  simpa using b64Char_table ⟨v.toNat, h⟩

theorem or_add (a b i : Nat) (hb : b < 2 ^ i) : a * 2 ^ i ||| b = a * 2 ^ i + b := by
  rw [← Nat.shiftLeft_eq, Nat.shiftLeft_add_eq_or_of_lt hb]

theorem word3 (x y z : UInt8) :
    (x.toUInt32 <<< 16 ||| y.toUInt32 <<< 8 ||| z.toUInt32).toNat = x.toNat * 2 ^ 16 + y.toNat * 2 ^ 8 + z.toNat := by
  have hx := x.toNat_lt; have hy := y.toNat_lt; have hz := z.toNat_lt
  simp only [UInt32.toNat_or, UInt32.toNat_shiftLeft, UInt8.toNat_toUInt32]
  simp only [show (16 : UInt32).toNat % 32 = 16 from rfl, show (8 : UInt32).toNat % 32 = 8 from rfl, Nat.shiftLeft_eq]
  rw [Nat.mod_eq_of_lt (by omega : x.toNat * 2 ^ 16 < 2 ^ 32), Nat.mod_eq_of_lt (by omega : y.toNat * 2 ^ 8 < 2 ^ 32)]
  rw [Nat.or_assoc, or_add _ _ 8 (by omega), or_add _ _ 16 (by omega)]; omega

theorem word2 (x y : UInt8) :
    (x.toUInt32 <<< 8 ||| y.toUInt32).toNat = x.toNat * 2 ^ 8 + y.toNat := by
  have hx := x.toNat_lt; have hy := y.toNat_lt
  simp only [UInt32.toNat_or, UInt32.toNat_shiftLeft, UInt8.toNat_toUInt32]
  simp only [show (8 : UInt32).toNat % 32 = 8 from rfl, Nat.shiftLeft_eq]
  rw [Nat.mod_eq_of_lt (by omega : x.toNat * 2 ^ 8 < 2 ^ 32), or_add _ _ 8 (by omega)]

theorem shr_toNat (n k : UInt32) (hk : k.toNat < 32) : (n >>> k).toNat = n.toNat / 2 ^ k.toNat := by
  simp [UInt32.toNat_shiftRight, Nat.shiftRight_eq_div_pow, Nat.mod_eq_of_lt hk]

theorem and_toNat (n : UInt32) (k : Nat) (hk : k < 32) :
    (n &&& (2 ^ k - 1 : Nat).toUInt32).toNat = n.toNat % 2 ^ k := by
  rw [UInt32.toNat_and]
  have : ((2 ^ k - 1 : Nat).toUInt32).toNat = 2 ^ k - 1 := by
    rw [Nat.toUInt32_eq, UInt32.toNat_ofNat', Nat.mod_eq_of_lt]
    have : 2 ^ k ≤ 2 ^ 32 := Nat.pow_le_pow_right (by omega) (by omega)
    omega
  rw [this, Nat.and_two_pow_sub_one_eq_mod]

theorem drop_eq3 (d : ByteArray) (i : Nat) (h : i + 3 ≤ d.size) :
    (bs d).drop i = d.get! i :: d.get! (i + 1) :: d.get! (i + 2) :: (bs d).drop (i + 3) := by
  have hl : (bs d).length = d.size := bs_size d
  rw [get!_eq, get!_eq, get!_eq]
  rw [List.drop_eq_getElem_cons (by omega), List.drop_eq_getElem_cons (by omega),
    List.drop_eq_getElem_cons (by omega)]
  simp [List.getElem?_eq_getElem (show i < (bs d).length by omega),
    List.getElem?_eq_getElem (show i + 1 < (bs d).length by omega),
    List.getElem?_eq_getElem (show i + 2 < (bs d).length by omega)]

/-- The loop writes the encoding of the bytes from `i` on, three at a time. -/
theorem encode_go (d : ByteArray) : ∀ f i (out : ByteArray), (d.size - i) / 3 < f →
    bs (b64Encode.go d i f out) = bs out ++ b64urlEncode ((bs d).drop i) := by
  have hl : (bs d).length = d.size := bs_size d
  intro f
  induction f with
  | zero => intro i out h; omega
  | succ f ih =>
    intro i out h
    unfold b64Encode.go
    split
    · rename_i h3
      rw [ih (i + 3) _ (by omega), drop_eq3 d i h3]
      have hw := word3 (d.get! i) (d.get! (i + 1)) (d.get! (i + 2))
      generalize ((d.get! i).toUInt32 <<< 16 ||| (d.get! (i + 1)).toUInt32 <<< 8 ||| (d.get! (i + 2)).toUInt32) = n
        at hw
      have hx := (d.get! i).toNat_lt; have hy := (d.get! (i + 1)).toNat_lt; have hz := (d.get! (i + 2)).toNat_lt
      have c0 : b64Char (n >>> 18) = b64urlChar (n.toNat / 2 ^ 18) := by
        have e : (n >>> 18).toNat = n.toNat / 2 ^ 18 := shr_toNat n 18 (by decide)
        rw [b64Char_eq _ (by omega), e]
      have c1 : b64Char (n >>> 12 &&& 63) = b64urlChar (n.toNat / 2 ^ 12 % 64) := by
        have e : (n >>> 12 &&& 63).toNat = n.toNat / 2 ^ 12 % 64 := by
          rw [show (63 : UInt32) = (2 ^ 6 - 1 : Nat).toUInt32 from rfl, and_toNat _ 6 (by omega),
            shr_toNat n 12 (by decide)]; rfl
        rw [b64Char_eq _ (by omega), e]
      have c2 : b64Char (n >>> 6 &&& 63) = b64urlChar (n.toNat / 2 ^ 6 % 64) := by
        have e : (n >>> 6 &&& 63).toNat = n.toNat / 2 ^ 6 % 64 := by
          rw [show (63 : UInt32) = (2 ^ 6 - 1 : Nat).toUInt32 from rfl, and_toNat _ 6 (by omega),
            shr_toNat n 6 (by decide)]; rfl
        rw [b64Char_eq _ (by omega), e]
      have c3 : b64Char (n &&& 63) = b64urlChar (n.toNat % 64) := by
        have e : (n &&& 63).toNat = n.toNat % 64 := by
          rw [show (63 : UInt32) = (2 ^ 6 - 1 : Nat).toUInt32 from rfl, and_toNat _ 6 (by omega)]
        rw [b64Char_eq _ (by omega), e]
      simp only [bs_push, b64urlEncode, c0, c1, c2, c3, hw]
      simp
    · split
      · rename_i h2
        have h2 : i + 2 = d.size := by simpa using h2
        have hd : (bs d).drop i = [d.get! i, d.get! (i + 1)] := by
          rw [get!_eq, get!_eq, List.drop_eq_getElem_cons (by omega), List.drop_eq_getElem_cons (by omega),
            List.drop_eq_nil_of_le (by omega)]
          simp [List.getElem?_eq_getElem (show i < (bs d).length by omega),
            List.getElem?_eq_getElem (show i + 1 < (bs d).length by omega)]
        rw [hd]
        have hw := word2 (d.get! i) (d.get! (i + 1))
        generalize ((d.get! i).toUInt32 <<< 8 ||| (d.get! (i + 1)).toUInt32) = n at hw
        have hx := (d.get! i).toNat_lt; have hy := (d.get! (i + 1)).toNat_lt
        have e0 : (n >>> 10).toNat = n.toNat / 2 ^ 10 := shr_toNat n 10 (by decide)
        have e1 : (n >>> 4 &&& 63).toNat = n.toNat / 2 ^ 4 % 64 := by
          rw [show (63 : UInt32) = (2 ^ 6 - 1 : Nat).toUInt32 from rfl, and_toNat _ 6 (by omega),
            shr_toNat n 4 (by decide)]; rfl
        have e2 : ((n &&& 15) <<< 2).toNat = n.toNat % 16 * 4 := by
          rw [UInt32.toNat_shiftLeft, show (15 : UInt32) = (2 ^ 4 - 1 : Nat).toUInt32 from rfl,
            and_toNat _ 4 (by omega)]
          simp only [show (2 : UInt32).toNat % 32 = 2 from rfl, Nat.shiftLeft_eq]
          rw [Nat.mod_eq_of_lt (by omega)]
        dsimp only
        rw [b64Char_eq _ (by omega), b64Char_eq _ (by omega), b64Char_eq _ (by omega), e0, e1, e2, hw]
        simp only [bs_push, b64urlEncode, List.append_assoc, List.cons_append, List.nil_append]
        refine congrArg _ (List.cons_eq_cons.mpr ⟨by congr 1; omega,
          List.cons_eq_cons.mpr ⟨by congr 1; omega, by congr 2; omega⟩⟩)
      · split
        · rename_i h1
          have h1 : i + 1 = d.size := by simpa using h1
          have hd : (bs d).drop i = [d.get! i] := by
            rw [get!_eq, List.drop_eq_getElem_cons (by omega), List.drop_eq_nil_of_le (by omega)]
            simp [List.getElem?_eq_getElem (show i < (bs d).length by omega)]
          rw [hd]
          have hx := (d.get! i).toNat_lt
          have e0 : ((d.get! i).toUInt32 >>> 2).toNat = (d.get! i).toNat / 2 ^ 2 := by
            rw [shr_toNat _ 2 (by decide)]; rfl
          have e1 : (((d.get! i).toUInt32 &&& 3) <<< 4).toNat = (d.get! i).toNat % 4 * 16 := by
            rw [UInt32.toNat_shiftLeft, show (3 : UInt32) = (2 ^ 2 - 1 : Nat).toUInt32 from rfl,
              and_toNat _ 2 (by omega)]
            simp only [show (4 : UInt32).toNat % 32 = 4 from rfl, Nat.shiftLeft_eq, UInt8.toNat_toUInt32]
            rw [Nat.mod_eq_of_lt (by omega)]
          dsimp only
          rw [b64Char_eq _ (by omega), b64Char_eq _ (by omega), e0, e1]
          simp only [bs_push, b64urlEncode, List.append_assoc, List.cons_append, List.nil_append]
          refine congrArg _ (List.cons_eq_cons.mpr ⟨by congr 1; omega, by congr 2; omega⟩)
        · rename_i h3 h2 h1
          have : (bs d).drop i = [] := List.drop_eq_nil_of_le (by simp at h3 h2 h1; omega)
          simp [this, b64urlEncode]

/-- **`b64Encode` encodes base64url**: its bytes are `Spec.b64urlEncode` of the input's. -/
theorem b64Encode_spec (d : ByteArray) : bs (b64Encode d) = b64urlEncode (bs d) := by
  unfold b64Encode
  rw [encode_go d _ 0 _ (by omega)]
  simp

/-- info: 'Feed.Jwt.b64Encode_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms b64Encode_spec

/-! ## The signature comparison -/

theorem ctEq_go_eq (x a : ByteArray) (lo : Nat) :
    ∀ f k acc, (∀ j, k ≤ j → j < k + f → x.get! j = a.get! (lo + j)) → ctEq.go x a lo k f acc = acc := by
  intro f
  induction f with
  | zero => intros; rfl
  | succ f ih =>
    intro k acc h
    simp only [ctEq.go]
    rw [ih (k + 1) _ (fun j h1 h2 => h j (by omega) (by omega)), h k (Nat.le_refl _) (by omega), UInt8.xor_self,
      UInt8.or_zero]

/-- **`ctEq` is byte equality**: it holds exactly when the range is `x`. That is all that is proved
of it: that it takes the same time whatever the bytes are (RFC 7518 §3.2) is not a theorem, and
stays in the trust base, since it depends on how Lean and gcc compile `ctEq.go`. -/
theorem ctEq_iff {x a : ByteArray} {lo hi : Nat} (h : lo ≤ hi) (h' : hi ≤ a.size) :
    ctEq x a lo hi = true ↔ slice a lo hi = bs x := by
  rw [slice_eq_iff a h h', ← size_eq_length]
  constructor
  · intro hc
    obtain ⟨hl, hj⟩ := ctEq_spec hc
    exact ⟨hl, fun k hk => by rw [← hj k hk, get!_eq]⟩
  · rintro ⟨hl, hk⟩
    unfold ctEq
    rw [Bool.and_eq_true, beq_iff_eq, beq_iff_eq,
      ctEq_go_eq x a lo x.size 0 0 (fun j _ hj => by rw [hk j (by omega), get!_eq])]
    exact ⟨hl, rfl⟩

/-- info: 'Feed.Jwt.ctEq_iff' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms ctEq_iff

/-! ## The dots -/

theorem mem_slice (a : ByteArray) (b : UInt8) {lo hi : Nat} (h' : hi ≤ a.size) :
    b ∈ slice a lo hi ↔ ∃ j, lo ≤ j ∧ j < hi ∧ a.get! j = b := by
  constructor
  · intro hb
    obtain ⟨k, hk, hkb⟩ := List.getElem_of_mem hb
    have hlen := slice_length a (lo := lo) h'
    have := slice_getElem? a (lo := lo) (hi := hi) (k := k) (by omega) h'
    rw [List.getElem?_eq_getElem hk, hkb] at this
    exact ⟨lo + k, by omega, by omega, (Option.some.inj this).symm⟩
  · rintro ⟨j, h1, h2, hj⟩
    have := slice_getElem? a (lo := lo) (hi := hi) (k := j - lo) (by omega) h'
    rw [Nat.add_sub_cancel' h1, hj] at this
    exact List.mem_of_getElem? this

theorem findByte_go_first (a : ByteArray) (b : UInt8) {hi : Nat} (h' : hi ≤ a.size) :
    ∀ f i, i + f = hi → i ≤ Bytes.findByte.go a b hi i f ∧ Bytes.findByte.go a b hi i f ≤ hi ∧
      (∀ j, i ≤ j → j < Bytes.findByte.go a b hi i f → a.get! j ≠ b) ∧
      (Bytes.findByte.go a b hi i f < hi → a.get! (Bytes.findByte.go a b hi i f) = b) := by
  have hm : min hi a.size = hi := Nat.min_eq_left h'
  intro f
  induction f with
  | zero =>
    intro i hi'
    simp only [Bytes.findByte.go, hm]
    exact ⟨by omega, Nat.le_refl _, fun j h1 h2 => by omega, fun h => by omega⟩
  | succ f ih =>
    intro i hi'
    simp only [Bytes.findByte.go]
    split
    · rename_i hb
      exact ⟨Nat.le_refl _, by omega, fun j h1 h2 => by omega, fun _ => by simpa using hb⟩
    · rename_i hb
      obtain ⟨h1, h2, h3, h4⟩ := ih (i + 1) (by omega)
      refine ⟨by omega, h2, fun j hj1 hj2 => ?_, h4⟩
      rcases Nat.eq_or_lt_of_le hj1 with rfl | hlt
      · simpa using hb
      · exact h3 j (by omega) hj2

/-- `findByte` stops at the first `b`: none before it, and one there unless it is the end. -/
theorem findByte_first (a : ByteArray) (b : UInt8) {lo hi : Nat} (h : lo ≤ hi) (h' : hi ≤ a.size) :
    lo ≤ Bytes.findByte a b lo hi ∧ Bytes.findByte a b lo hi ≤ hi ∧ b ∉ slice a lo (Bytes.findByte a b lo hi) ∧
      (Bytes.findByte a b lo hi < hi → a.get! (Bytes.findByte a b lo hi) = b) := by
  unfold Bytes.findByte
  rw [Nat.min_eq_left h']
  obtain ⟨h1, h2, h3, h4⟩ := findByte_go_first a b h' (hi - lo) lo (by omega)
  refine ⟨h1, h2, fun hb => ?_, h4⟩
  obtain ⟨j, hj1, hj2, hj⟩ := (mem_slice a b (by omega)).mp hb
  exact h3 j hj1 hj2 hj

theorem slice_split (a : ByteArray) {lo m hi : Nat} (h1 : lo ≤ m) (h2 : m < hi) (h' : hi ≤ a.size) :
    slice a lo hi = slice a lo m ++ a.get! m :: slice a (m + 1) hi := by
  have e1 := slice_take a (lo := lo) (hi := hi) (m - lo) (by omega)
  have e2 := slice_drop a (lo := lo) (hi := hi) (m - lo) (by omega)
  rw [Nat.add_sub_cancel' h1] at e1 e2
  rw [← slice_cons a h2 h', ← e1, ← e2, List.take_append_drop]

/-- **The dots**: `verify` cuts a token where `Spec.Auth.checkToken` does. Its three `findByte`
calls accept a range exactly when it has two dots, and the three parts are then the pieces of
`List.splitOn` at the dots (RFC 7515 §7.1). -/
theorem dots_spec (a : ByteArray) {lo hi : Nat} (h : lo ≤ hi) (h' : hi ≤ a.size) :
    let d1 := Bytes.findByte a 0x2e lo hi
    let d2 := Bytes.findByte a 0x2e (d1 + 1) hi
    (if d1 ≥ hi ∨ d2 ≥ hi ∨ Bytes.findByte a 0x2e (d2 + 1) hi ≠ hi then none
     else some (slice a lo d1, slice a (d1 + 1) d2, slice a (d2 + 1) hi)) =
    (match (slice a lo hi).splitOn 0x2e with | [x, y, z] => some (x, y, z) | _ => none) := by
  dsimp only
  obtain ⟨l1, u1, n1, b1⟩ := findByte_first a 0x2e h h'
  generalize Bytes.findByte a 0x2e lo hi = d1 at l1 u1 n1 b1 ⊢
  by_cases e1 : d1 < hi
  · rw [slice_split a l1 e1 h', b1 e1, List.splitOn_append_cons_self_of_not_mem n1]
    obtain ⟨l2, u2, n2, b2⟩ := findByte_first a 0x2e (lo := d1 + 1) (by omega) h'
    generalize Bytes.findByte a 0x2e (d1 + 1) hi = d2 at l2 u2 n2 b2 ⊢
    by_cases e2 : d2 < hi
    · rw [slice_split a l2 e2 h', b2 e2, List.splitOn_append_cons_self_of_not_mem n2]
      obtain ⟨l3, u3, n3, b3⟩ := findByte_first a 0x2e (lo := d2 + 1) (by omega) h'
      generalize Bytes.findByte a 0x2e (d2 + 1) hi = d3 at l3 u3 n3 b3 ⊢
      by_cases e3 : d3 = hi
      · rw [e3] at n3
        rw [List.splitOn_eq_singleton n3]
        simp [e3, Nat.not_le.mpr e1, Nat.not_le.mpr e2]
      · have e3' : d3 < hi := by omega
        rw [slice_split a l3 e3' h', b3 e3', List.splitOn_append_cons_self_of_not_mem n3]
        obtain ⟨w, ws, hw⟩ := List.exists_cons_of_ne_nil (List.splitOn_ne_nil 0x2e (slice a (d3 + 1) hi))
        rw [hw]
        simp [e3]
    · have e2' : d2 = hi := by omega
      rw [e2'] at n2
      rw [List.splitOn_eq_singleton n2]
      simp [e2']
  · have e1' : d1 = hi := by omega
    rw [e1'] at n1
    rw [List.splitOn_eq_singleton n1]
    simp [e1']

/-- info: 'Feed.Jwt.dots_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms dots_spec

end Feed.Jwt
