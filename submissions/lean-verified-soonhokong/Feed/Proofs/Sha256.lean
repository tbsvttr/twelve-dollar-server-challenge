import Feed.Spec.Sha256Vectors
import Feed.Proofs.Route

/-!
# SHA-256 and HMAC-SHA256

`Feed/Sha256.lean` computes FIPS 180-4's SHA-256 and RFC 2104's HMAC as `Feed/Spec/Sha256.lean`
writes them, for every input:

* `Sha256.hash_spec`: the digest of every byte array is `Spec.SHA256.sha256` of its bytes;
* `Hmac.mac_spec`: under the key schedule of any key, the MAC of any range `m[lo, hi)` is
  `Spec.HMAC.hmacSha256` of the key's bytes and `slice m lo hi` (a range is clamped as `slice`
  clamps it, so one given backwards is the empty message);
* `Hmac.keyOf_spec`: the key schedule holds the hash values after the first block of each of
  RFC 2104's two hashes, `K0 ⊕ ipad` and `K0 ⊕ opad`.

The proofs follow the code: its rolling window of sixteen words is the recurrence of §6.2.2
step 1 (`Spec.SHA256.Wx`), its blocks and its padded tail are read in place (`Sha256.blocks_spec`,
`Sha256.tailBlock_spec`), and `Sha256.finish_spec` is the rest of §6.2 after a prefix of whole
blocks, which is how HMAC's inner hash starts. The test vectors, and `K` and `H0` from the primes,
are in `Feed/Spec/Sha256Vectors.lean`. Two facts about the specification are also proved here:
the padding's zero bits are the fewest that §5.1.1 allows, and a digest is 32 bytes.
-/
namespace Feed.Spec.SHA256

theorem padZeros_spec (ℓ : Nat) :
    (ℓ + 1 + padZeros ℓ) % 512 = 448 ∧ ∀ k, (ℓ + 1 + k) % 512 = 448 → padZeros ℓ ≤ k := by
  unfold padZeros
  constructor
  · omega
  · intro k hk; omega

/-- info: 'Feed.Spec.SHA256.padZeros_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms padZeros_spec

theorem sha256_length (M : List UInt8) : (sha256 M).length = 32 := by
  simp [sha256, wordBytes]

/-- info: 'Feed.Spec.SHA256.sha256_length' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms sha256_length

/-! ## The schedule as a recurrence -/

/-- §6.2.2 step 1's `W_t`, as a recurrence continued past `W_63` (the proofs only use it). -/
def Wx (Mi : List Word) (t : Nat) : Word :=
  if t < 16 then Mi.getD t 0
  else sigma1 (Wx Mi (t - 2)) + Wx Mi (t - 7) + sigma0 (Wx Mi (t - 15)) + Wx Mi (t - 16)
termination_by t
decreasing_by all_goals omega

theorem Wx_lt (Mi : List Word) {t : Nat} (h : t < 16) : Wx Mi t = Mi.getD t 0 := by
  rw [Wx, ite_eq_left h]

theorem Wx_add16 (Mi : List Word) (t : Nat) :
    Wx Mi (t + 16) = sigma1 (Wx Mi (t + 14)) + Wx Mi (t + 9) + sigma0 (Wx Mi (t + 1)) + Wx Mi t := by
  rw [Wx, ite_eq_right (by omega)]
  rw [show t + 16 - 2 = t + 14 by omega, show t + 16 - 7 = t + 9 by omega,
    show t + 16 - 15 = t + 1 by omega, show t + 16 - 16 = t by omega]

/-- One step of `schedule`'s fold. -/
private def schedStep (W : List Word) (t : Nat) : List Word :=
  W ++ [sigma1 (W.getD (t - 2) 0) + W.getD (t - 7) 0 + sigma0 (W.getD (t - 15) 0) + W.getD (t - 16) 0]

/-- The fold's invariant: after the steps for `16 … s - 1`, the list is `W_0 … W_{s-1}`. -/
private theorem schedStep_fold : ∀ k s (W : List Word), s + k = 64 → 16 ≤ s → W.length = s →
    ∀ Mi, (∀ t < s, W.getD t 0 = Wx Mi t) → ∀ t < 64, ((List.range' s k).foldl schedStep W).getD t 0 = Wx Mi t
  | 0, _, _, h1, _, _, _, hW, t, ht => hW t (by omega)
  | k + 1, s, W, h1, h2, hl, Mi, hW, t, ht => by
    rw [List.range'_succ, List.foldl_cons]
    refine schedStep_fold k (s + 1) _ (by omega) (by omega) (by simp [schedStep, hl]) Mi (fun t ht => ?_) t ht
    rw [schedStep, List.getD_eq_getElem?_getD]
    by_cases h : t < W.length
    · rw [List.getElem?_append_left h, ← List.getD_eq_getElem?_getD]
      exact hW t (by omega)
    · obtain rfl : t = s := by omega
      rw [List.getElem?_append_right (by omega), hl, Nat.sub_self, List.getElem?_cons_zero, Option.getD_some]
      obtain ⟨j, rfl⟩ : ∃ j, t = j + 16 := ⟨t - 16, by omega⟩
      rw [Wx_add16, hW _ (by omega), hW _ (by omega), hW _ (by omega), hW _ (by omega)]
      simp only [show j + 16 - 2 = j + 14 by omega, show j + 16 - 7 = j + 9 by omega,
        show j + 16 - 15 = j + 1 by omega, show j + 16 - 16 = j by omega]

/-- `schedule` computes the recurrence. -/
theorem schedule_getD (Mi : List Word) (hM : Mi.length = 16) {t : Nat} (ht : t < 64) :
    (schedule Mi).getD t 0 = Wx Mi t :=
  schedStep_fold 48 16 Mi rfl (by omega) hM Mi (fun _ h => (Wx_lt Mi h).symm) t ht

/-- A round of §6.2.2 step 3 with the schedule given by the recurrence. -/
def roundWx (Mi : List Word) (v : Hash) (t : Nat) : Hash :=
  let T1 := v.h + Sigma1 v.e + Ch v.e v.f v.g + K.getD t 0 + Wx Mi t
  let T2 := Sigma0 v.a + Maj v.a v.b v.c
  { h := v.g, g := v.f, f := v.e, e := v.d + T1, d := v.c, c := v.b, b := v.a, a := T1 + T2 }

private theorem foldl_congr_mem {α β : Type} : ∀ {l : List β} {f g : α → β → α} (a : α),
    (∀ a b, b ∈ l → f a b = g a b) → l.foldl f a = l.foldl g a
  | [], _, _, _, _ => rfl
  | b :: l, f, g, a, h => by
    simp only [List.foldl_cons]
    rw [h a b (by simp)]
    exact foldl_congr_mem _ (fun a' b' hb => h a' b' (by simp [hb]))

/-- The 64 rounds of §6.2.2, with the schedule's words from the recurrence. -/
theorem rounds_schedule (Mi : List Word) (hM : Mi.length = 16) (H : Hash) :
    (List.range 64).foldl (round (schedule Mi)) H = (List.range' 0 64).foldl (roundWx Mi) H := by
  rw [← List.range_eq_range']
  apply foldl_congr_mem
  intro v t ht
  rw [List.mem_range] at ht
  simp only [round, roundWx, schedule_getD Mi hM ht]

end Feed.Spec.SHA256

namespace Feed
open Spec

/-- The state as the specification's eight words. -/
def Sha256.State.toHash (s : Sha256.State) : SHA256.Hash := ⟨s.a, s.b, s.c, s.d, s.e, s.f, s.g, s.h⟩

namespace Sha256
open Spec.SHA256 (Wx roundWx)

/-! ## The compression function -/

/-- The code's round constants are §4.2.2's. -/
theorem K_getElem! (t : Nat) : K[t]! = SHA256.K.getD t 0 := by
  rw [Array.getElem!_eq_getD, Array.getD_eq_getD_getElem?, List.getD_eq_getElem?_getD,
    ← Array.getElem?_toList]
  rfl

/-- `rounds` with the window `W_t … W_{t+15}` of the recurrence runs rounds `t … 63` of §6.2.2. -/
theorem rounds_eq (Mi : List SHA256.Word) : ∀ n t (v : SHA256.Hash), t + n = 64 →
    rounds t v.a v.b v.c v.d v.e v.f v.g v.h
      (Wx Mi t) (Wx Mi (t+1)) (Wx Mi (t+2)) (Wx Mi (t+3)) (Wx Mi (t+4)) (Wx Mi (t+5)) (Wx Mi (t+6))
      (Wx Mi (t+7)) (Wx Mi (t+8)) (Wx Mi (t+9)) (Wx Mi (t+10)) (Wx Mi (t+11)) (Wx Mi (t+12))
      (Wx Mi (t+13)) (Wx Mi (t+14)) (Wx Mi (t+15)) =
    let r := (List.range' t n).foldl (roundWx Mi) v
    ⟨r.a, r.b, r.c, r.d, r.e, r.f, r.g, r.h⟩ := by
  intro n
  induction n with
  | zero =>
    intro t v _
    rw [rounds, ite_eq_right (by omega)]
    rfl
  | succ n ih =>
    intro t v h
    rw [rounds, ite_eq_left (by omega)]
    have hw : ssig1 (Wx Mi (t + 14)) + Wx Mi (t + 9) + ssig0 (Wx Mi (t + 1)) + Wx Mi t =
        Wx Mi (t + 1 + 15) := by
      rw [show t + 1 + 15 = t + 16 by omega, SHA256.Wx_add16]; rfl
    rw [hw, K_getElem!]
    have := ih (t + 1) (roundWx Mi v t) (by omega)
    simp only [show t + 1 + 1 = t + 2 by omega, show t + 1 + 2 = t + 3 by omega,
      show t + 1 + 3 = t + 4 by omega, show t + 1 + 4 = t + 5 by omega, show t + 1 + 5 = t + 6 by omega,
      show t + 1 + 6 = t + 7 by omega, show t + 1 + 7 = t + 8 by omega, show t + 1 + 8 = t + 9 by omega,
      show t + 1 + 9 = t + 10 by omega, show t + 1 + 10 = t + 11 by omega,
      show t + 1 + 11 = t + 12 by omega, show t + 1 + 12 = t + 13 by omega,
      show t + 1 + 13 = t + 14 by omega, show t + 1 + 14 = t + 15 by omega] at this
    rw [List.range'_succ, List.foldl_cons]
    exact this

/-- **The compression function is §6.2.2's** on the block's words `w0 … w15`. -/
theorem compressW_spec (s : State) (w0 w1 w2 w3 w4 w5 w6 w7 w8 w9 w10 w11 w12 w13 w14 w15 : UInt32) :
    (compressW s w0 w1 w2 w3 w4 w5 w6 w7 w8 w9 w10 w11 w12 w13 w14 w15).toHash =
      SHA256.compress s.toHash [w0, w1, w2, w3, w4, w5, w6, w7, w8, w9, w10, w11, w12, w13, w14, w15] := by
  have e := rounds_eq [w0, w1, w2, w3, w4, w5, w6, w7, w8, w9, w10, w11, w12, w13, w14, w15] 64 0 s.toHash rfl
  simp only [Nat.zero_add, SHA256.Wx_lt _ (show 0 < 16 by decide), SHA256.Wx_lt _ (show 1 < 16 by decide),
    SHA256.Wx_lt _ (show 2 < 16 by decide), SHA256.Wx_lt _ (show 3 < 16 by decide),
    SHA256.Wx_lt _ (show 4 < 16 by decide), SHA256.Wx_lt _ (show 5 < 16 by decide),
    SHA256.Wx_lt _ (show 6 < 16 by decide), SHA256.Wx_lt _ (show 7 < 16 by decide),
    SHA256.Wx_lt _ (show 8 < 16 by decide), SHA256.Wx_lt _ (show 9 < 16 by decide),
    SHA256.Wx_lt _ (show 10 < 16 by decide), SHA256.Wx_lt _ (show 11 < 16 by decide),
    SHA256.Wx_lt _ (show 12 < 16 by decide), SHA256.Wx_lt _ (show 13 < 16 by decide),
    SHA256.Wx_lt _ (show 14 < 16 by decide), SHA256.Wx_lt _ (show 15 < 16 by decide),
    List.getD_cons_zero, List.getD_cons_succ] at e
  have hr := SHA256.rounds_schedule [w0, w1, w2, w3, w4, w5, w6, w7, w8, w9, w10, w11, w12, w13, w14, w15] rfl
  simp only [State.toHash] at e hr
  simp only [compressW, State.toHash, e, SHA256.compress, hr, UInt32.add_comm s.a,
    UInt32.add_comm s.b, UInt32.add_comm s.c, UInt32.add_comm s.d, UInt32.add_comm s.e,
    UInt32.add_comm s.f, UInt32.add_comm s.g, UInt32.add_comm s.h]

/-- info: 'Feed.Sha256.compressW_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms compressW_spec

/-! ## Bytes and words -/

/-- An OR of numbers whose bits do not overlap is their sum. -/
private theorem or_eq_add {a b : Nat} (k : Nat) (ha : a % 2 ^ k = 0) (hb : b < 2 ^ k) : a ||| b = a + b := by
  obtain ⟨q, rfl⟩ : ∃ q, a = q * 2 ^ k := ⟨a / 2 ^ k, by rw [Nat.div_mul_cancel (Nat.dvd_of_mod_eq_zero ha)]⟩
  rw [← Nat.shiftLeft_eq, ← Nat.shiftLeft_add_eq_or_of_lt hb]

/-- The code's big-endian word (shifts and ORs) is §3.1's. -/
theorem word_be32 (b0 b1 b2 b3 : UInt8) :
    (b0.toUInt32 <<< 24 ||| b1.toUInt32 <<< 16 ||| b2.toUInt32 <<< 8 ||| b3.toUInt32) =
      SHA256.be32 b0 b1 b2 b3 := by
  apply UInt32.toNat_inj.mp
  have h0 := b0.toNat_lt; have h1 := b1.toNat_lt; have h2 := b2.toNat_lt; have h3 := b3.toNat_lt
  simp only [SHA256.be32, UInt32.toNat_or, UInt32.toNat_shiftLeft, UInt8.toNat_toUInt32, UInt32.toNat_ofNat',
    show (UInt32.toNat 24) % 32 = 24 from rfl, show (UInt32.toNat 16) % 32 = 16 from rfl,
    show (UInt32.toNat 8) % 32 = 8 from rfl, Nat.shiftLeft_eq]
  generalize b0.toNat = x0 at *; generalize b1.toNat = x1 at *
  generalize b2.toNat = x2 at *; generalize b3.toNat = x3 at *
  have p8 : (2 : Nat) ^ 8 = 256 := rfl
  have p16 : (2 : Nat) ^ 16 = 65536 := rfl
  have p24 : (2 : Nat) ^ 24 = 16777216 := rfl
  have p32 : (2 : Nat) ^ 32 = 4294967296 := rfl
  rw [p8] at h0 h1 h2 h3
  rw [Nat.mod_eq_of_lt (by rw [p24, p32]; omega : x0 * 2 ^ 24 < 2 ^ 32),
    Nat.mod_eq_of_lt (by rw [p16, p32]; omega : x1 * 2 ^ 16 < 2 ^ 32),
    Nat.mod_eq_of_lt (by rw [p8, p32]; omega : x2 * 2 ^ 8 < 2 ^ 32),
    or_eq_add (a := x0 * 2 ^ 24) (b := x1 * 2 ^ 16) 24 (Nat.mul_mod_left _ _) (by rw [p16, p24]; omega),
    or_eq_add (a := x0 * 2 ^ 24 + x1 * 2 ^ 16) (b := x2 * 2 ^ 8) 16 (by rw [p16, p24]; omega)
      (by rw [p8, p16]; omega),
    or_eq_add (a := x0 * 2 ^ 24 + x1 * 2 ^ 16 + x2 * 2 ^ 8) (b := x3) 8 (by rw [p8, p16, p24]; omega)
      (by rw [p8]; omega)]
  rw [p8, p16, p24, p32]
  omega

/-- A word read back from its four bytes, as `wordBytes` gives them. -/
theorem be32_wordBytes (w : UInt32) :
    SHA256.be32 (w.toNat / 2 ^ 24 % 256).toUInt8 (w.toNat / 2 ^ 16 % 256).toUInt8
      (w.toNat / 2 ^ 8 % 256).toUInt8 (w.toNat / 2 ^ 0 % 256).toUInt8 = w := by
  apply UInt32.toNat_inj.mp
  have hw := w.toNat_lt
  simp only [SHA256.be32, UInt32.toNat_ofNat', Nat.toUInt8, UInt8.toNat_ofNat', Nat.pow_zero, Nat.div_one]
  generalize w.toNat = x at *
  -- x = 2^8 A + x % 2^8, A = x / 2^8 = 2^8 B + A % 2^8, B = x / 2^16 = 2^8 C + B % 2^8, C = x / 2^24
  have e1 : x / 2 ^ 16 = x / 2 ^ 8 / 256 := by rw [Nat.div_div_eq_div_mul]
  have e2 : x / 2 ^ 24 = x / 2 ^ 16 / 256 := by rw [Nat.div_div_eq_div_mul]
  have d0 := Nat.div_add_mod x 256
  have d1 := Nat.div_add_mod (x / 2 ^ 8) 256
  have d2 := Nat.div_add_mod (x / 2 ^ 16) 256
  have e0 : x / 2 ^ 8 = x / 256 := rfl
  have h3 : x / 2 ^ 24 < 256 := by rw [Nat.div_lt_iff_lt_mul (by decide)]; exact hw
  rw [← e1, ← e2] at *
  rw [e0] at d1 ⊢
  generalize x / 256 = A at *; generalize x / 2 ^ 16 = B at *; generalize x / 2 ^ 24 = C at *
  have p8 : (2 : Nat) ^ 8 = 256 := rfl
  have p16 : (2 : Nat) ^ 16 = 65536 := rfl
  have p24 : (2 : Nat) ^ 24 = 16777216 := rfl
  have p32 : (2 : Nat) ^ 32 = 4294967296 := rfl
  simp only [p8, p16, p24, p32, Nat.mod_mod] at *
  omega

/-- A byte of a word, as `pushWord` takes it. -/
theorem byte_shift (w k : UInt32) (hk : k.toNat < 32) :
    (w >>> k).toUInt8 = (w.toNat / 2 ^ k.toNat % 256).toUInt8 := by
  apply UInt8.toNat_inj.mp
  simp [UInt32.toNat_shiftRight, UInt32.toNat_toUInt8, Nat.shiftRight_eq_div_pow, Nat.mod_eq_of_lt hk]

theorem byte_low (w : UInt32) : w.toUInt8 = (w.toNat / 2 ^ 0 % 256).toUInt8 := by
  apply UInt8.toNat_inj.mp; simp [UInt32.toNat_toUInt8]

/-! ## The blocks of the message, read in place -/

private theorem slice_getD (m : ByteArray) {lo hi j : Nat} (hj : lo + j < hi) :
    (slice m lo hi).getD j 0 = (bs m).getD (lo + j) 0 := by
  simp only [slice, List.getD_eq_getElem?_getD, List.getElem?_take, List.getElem?_drop]
  rw [ite_eq_left (by omega)]

/-- A word read in place is the word of the block `m[i, i+64)` at its byte `o`. -/
private theorem word_slice (m : ByteArray) (i o : Nat) (ho : o + 4 ≤ 64) :
    word m (i + o) =
      let B := slice m i (i + 64)
      SHA256.be32 (B.getD o 0) (B.getD (o + 1) 0) (B.getD (o + 2) 0) (B.getD (o + 3) 0) := by
  simp only [word, word_be32, get!_eq, ← List.getD_eq_getElem?_getD]
  rw [slice_getD m (by omega : i + o < i + 64), slice_getD m (by omega : i + (o + 1) < i + 64),
    slice_getD m (by omega : i + (o + 2) < i + 64), slice_getD m (by omega : i + (o + 3) < i + 64)]
  simp only [Nat.add_assoc]

/-- The sixteen words of a block, written out. -/
private theorem words_eq (B : List UInt8) : SHA256.words B =
    [SHA256.be32 (B.getD 0 0) (B.getD 1 0) (B.getD 2 0) (B.getD 3 0),
     SHA256.be32 (B.getD 4 0) (B.getD 5 0) (B.getD 6 0) (B.getD 7 0),
     SHA256.be32 (B.getD 8 0) (B.getD 9 0) (B.getD 10 0) (B.getD 11 0),
     SHA256.be32 (B.getD 12 0) (B.getD 13 0) (B.getD 14 0) (B.getD 15 0),
     SHA256.be32 (B.getD 16 0) (B.getD 17 0) (B.getD 18 0) (B.getD 19 0),
     SHA256.be32 (B.getD 20 0) (B.getD 21 0) (B.getD 22 0) (B.getD 23 0),
     SHA256.be32 (B.getD 24 0) (B.getD 25 0) (B.getD 26 0) (B.getD 27 0),
     SHA256.be32 (B.getD 28 0) (B.getD 29 0) (B.getD 30 0) (B.getD 31 0),
     SHA256.be32 (B.getD 32 0) (B.getD 33 0) (B.getD 34 0) (B.getD 35 0),
     SHA256.be32 (B.getD 36 0) (B.getD 37 0) (B.getD 38 0) (B.getD 39 0),
     SHA256.be32 (B.getD 40 0) (B.getD 41 0) (B.getD 42 0) (B.getD 43 0),
     SHA256.be32 (B.getD 44 0) (B.getD 45 0) (B.getD 46 0) (B.getD 47 0),
     SHA256.be32 (B.getD 48 0) (B.getD 49 0) (B.getD 50 0) (B.getD 51 0),
     SHA256.be32 (B.getD 52 0) (B.getD 53 0) (B.getD 54 0) (B.getD 55 0),
     SHA256.be32 (B.getD 56 0) (B.getD 57 0) (B.getD 58 0) (B.getD 59 0),
     SHA256.be32 (B.getD 60 0) (B.getD 61 0) (B.getD 62 0) (B.getD 63 0)] :=
  rfl

/-- **`compress` reads its block in place**: §6.2.2 on the words of `m[i, i+64)`. -/
theorem compress_spec (s : State) (m : ByteArray) (i : Nat) :
    (compress s m i).toHash = SHA256.compress s.toHash (SHA256.words (slice m i (i + 64))) := by
  unfold compress
  have w0 := word_slice m i 0 (by omega)
  simp only [Nat.add_zero] at w0
  rw [w0, word_slice m i 4 (by omega), word_slice m i 8 (by omega), word_slice m i 12 (by omega),
    word_slice m i 16 (by omega), word_slice m i 20 (by omega), word_slice m i 24 (by omega),
    word_slice m i 28 (by omega), word_slice m i 32 (by omega), word_slice m i 36 (by omega),
    word_slice m i 40 (by omega), word_slice m i 44 (by omega), word_slice m i 48 (by omega),
    word_slice m i 52 (by omega), word_slice m i 56 (by omega), word_slice m i 60 (by omega),
    compressW_spec, words_eq]

/-- info: 'Feed.Sha256.compress_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms compress_spec

/-- The step of §6.2's loop over the blocks. -/
abbrev hstep (H : SHA256.Hash) (B : List UInt8) : SHA256.Hash := SHA256.compress H (SHA256.words B)

/-- **`blocks` reads its `k` blocks in place.** -/
theorem blocks_spec (m : ByteArray) : ∀ k (s : State) lo,
    (blocks s m lo k).toHash = (SHA256.blocksOf k (slice m lo (lo + 64 * k))).foldl hstep s.toHash := by
  intro k
  induction k with
  | zero => intro s lo; rfl
  | succ k ih =>
    intro s lo
    rw [blocks, ih, compress_spec, SHA256.blocksOf, List.foldl_cons,
      show lo + 64 * (k + 1) = lo + 64 + 64 * k by omega, slice_take m 64 (by omega),
      slice_drop m 64 (by omega)]

/-- info: 'Feed.Sha256.blocks_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms blocks_spec

/-! ## The padded tail, read in place -/

/-- §5.1.1's padding of a message whose last bytes are `M` and whose length is `L` bytes, in
`len` bytes: `M`, the byte `0x80`, zeros, and the 64-bit length in bits. -/
def tailSpec (M : List UInt8) (L len : Nat) : List UInt8 :=
  M ++ [0x80] ++ List.replicate (len - 9 - M.length) 0 ++ SHA256.be64 (8 * L)

private theorem be64_getD (n i : Nat) (hi : i < 8) :
    (SHA256.be64 n).getD i 0 = (n / 2 ^ (8 * (7 - i)) % 256).toUInt8 := by
  match i, hi with
  | 0, _ | 1, _ | 2, _ | 3, _ | 4, _ | 5, _ | 6, _ | 7, _ => rfl

private theorem byte_of_toUInt64 (x s : Nat) (hs : s ≤ 56) :
    (x.toUInt64 >>> s.toUInt64).toUInt8 = (x / 2 ^ s % 256).toUInt8 := by
  apply UInt8.toNat_inj.mp
  simp only [UInt64.toNat_toUInt8, UInt64.toNat_shiftRight, Nat.toUInt64, UInt64.toNat_ofNat',
    Nat.toUInt8, UInt8.toNat_ofNat', Nat.shiftRight_eq_div_pow]
  rw [Nat.mod_eq_of_lt (a := s) (by omega), Nat.mod_eq_of_lt (a := s) (by omega)]
  apply Nat.eq_of_testBit_eq; intro i
  simp only [Nat.testBit_mod_two_pow, Nat.testBit_div_two_pow, show (256 : Nat) = 2 ^ 8 from rfl]
  by_cases hi : i < 8
  · simp [hi]; omega
  · simp [hi]

private theorem getD_append_lt {α} {l l' : List α} {n : Nat} {d : α} (h : n < l.length) :
    (l ++ l').getD n d = l.getD n d := by
  simp [List.getD_eq_getElem?_getD, List.getElem?_append_left h]

private theorem getD_append_ge {α} {l l' : List α} {n : Nat} {d : α} (h : l.length ≤ n) :
    (l ++ l').getD n d = l'.getD (n - l.length) d := by
  simp [List.getD_eq_getElem?_getD, List.getElem?_append_right h]

private theorem getD_replicate_lt {α} {k n : Nat} {x d : α} (h : n < k) :
    (List.replicate k x).getD n d = x := by
  simp [List.getD_eq_getElem?_getD, h]

/-- `padByte` reads the padded tail in place. -/
private theorem padByte_spec (m : ByteArray) (tl hi len L j : Nat) (h1 : tl ≤ hi) (h2 : hi ≤ m.size)
    (hlen : hi - tl + 9 ≤ len) (hj : j < len) :
    padByte m tl hi len (L * 8).toUInt64 j = (tailSpec (slice m tl hi) L len).getD j 0 := by
  have hs := slice_length m (lo := tl) h2
  unfold padByte tailSpec
  simp only [List.append_assoc]
  by_cases ha : tl + j < hi
  · rw [ite_eq_left ha, get!_eq, ← List.getD_eq_getElem?_getD, getD_append_lt (by omega), slice_getD m ha]
  rw [ite_eq_right ha, getD_append_ge (by omega)]
  by_cases hb : tl + j = hi
  · rw [ite_eq_left (by simp [hb]), show j - (slice m tl hi).length = 0 by omega]; rfl
  rw [ite_eq_right (by simpa using hb), List.singleton_append, show j - (slice m tl hi).length =
    (j - (slice m tl hi).length - 1) + 1 by omega, List.getD_cons_succ]
  by_cases hc : j + 8 < len
  · rw [ite_eq_left hc, getD_append_lt (by simp [hs]; omega), getD_replicate_lt (by omega)]
  rw [ite_eq_right hc, getD_append_ge (by simp [hs]; omega)]
  simp only [List.length_replicate, hs]
  rw [be64_getD _ _ (by omega), Nat.mul_comm L 8,
    show (len - 1 - j) * 8 = 8 * (7 - (j - (hi - tl) - 1 - (len - 9 - (hi - tl)))) by omega]
  exact byte_of_toUInt64 (8 * L) _ (by omega)

private theorem getD_take_drop (T : List UInt8) (o x : Nat) (hx : x < 64) :
    ((T.drop o).take 64).getD x 0 = T.getD (o + x) 0 := by
  simp only [List.getD_eq_getElem?_getD, List.getElem?_take, List.getElem?_drop, ite_eq_left hx]

private theorem padWord_spec (m : ByteArray) (tl hi len L o c : Nat) (h1 : tl ≤ hi) (h2 : hi ≤ m.size)
    (hlen : hi - tl + 9 ≤ len) (ho : o + 64 ≤ len) (hc : c + 4 ≤ 64) :
    padWord m tl hi len (L * 8).toUInt64 (o + c) =
      let B := ((tailSpec (slice m tl hi) L len).drop o).take 64
      SHA256.be32 (B.getD c 0) (B.getD (c + 1) 0) (B.getD (c + 2) 0) (B.getD (c + 3) 0) := by
  simp only [padWord, word_be32]
  rw [padByte_spec m tl hi len L _ h1 h2 hlen (by omega), padByte_spec m tl hi len L _ h1 h2 hlen (by omega),
    padByte_spec m tl hi len L _ h1 h2 hlen (by omega), padByte_spec m tl hi len L _ h1 h2 hlen (by omega),
    getD_take_drop _ _ _ (by omega), getD_take_drop _ _ _ (by omega), getD_take_drop _ _ _ (by omega),
    getD_take_drop _ _ _ (by omega)]
  simp only [Nat.add_assoc]

/-- **`tailBlock` reads a block of the padded tail in place.** -/
theorem tailBlock_spec (s : State) (m : ByteArray) (tl hi len L o : Nat) (h1 : tl ≤ hi) (h2 : hi ≤ m.size)
    (hlen : hi - tl + 9 ≤ len) (ho : o + 64 ≤ len) :
    (tailBlock s m tl hi len (L * 8).toUInt64 o).toHash =
      SHA256.compress s.toHash (SHA256.words (((tailSpec (slice m tl hi) L len).drop o).take 64)) := by
  unfold tailBlock
  have pw := padWord_spec m tl hi len L o
  have w0 := pw 0 h1 h2 hlen ho (by omega)
  simp only [Nat.add_zero] at w0
  simp only []
  rw [w0, pw 4 h1 h2 hlen ho (by omega), pw 8 h1 h2 hlen ho (by omega), pw 12 h1 h2 hlen ho (by omega),
    pw 16 h1 h2 hlen ho (by omega), pw 20 h1 h2 hlen ho (by omega), pw 24 h1 h2 hlen ho (by omega),
    pw 28 h1 h2 hlen ho (by omega), pw 32 h1 h2 hlen ho (by omega), pw 36 h1 h2 hlen ho (by omega),
    pw 40 h1 h2 hlen ho (by omega), pw 44 h1 h2 hlen ho (by omega), pw 48 h1 h2 hlen ho (by omega),
    pw 52 h1 h2 hlen ho (by omega), pw 56 h1 h2 hlen ho (by omega), pw 60 h1 h2 hlen ho (by omega),
    compressW_spec, words_eq]

/-- info: 'Feed.Sha256.tailBlock_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms tailBlock_spec

/-! ## The padded message, `finish` -/

private theorem blocksOf_append : ∀ k (A B : List UInt8), A.length = 64 * k → ∀ k',
    SHA256.blocksOf (k + k') (A ++ B) = SHA256.blocksOf k A ++ SHA256.blocksOf k' B := by
  intro k
  induction k with
  | zero => intro A B h k'; simp at h; subst h; simp [SHA256.blocksOf]
  | succ k ih =>
    intro A B h k'
    rw [show k + 1 + k' = (k + k') + 1 by omega]
    simp only [SHA256.blocksOf]
    rw [List.take_append_of_le_length (by omega), List.drop_append_of_le_length (by omega),
      ih (A.drop 64) B (by simp; omega) k', List.cons_append]

/-- §5.1.1 split where `finish` splits it: a prefix `P` of whole blocks, the full blocks of the
rest `S`, then the padded tail. -/
private theorem pad_split (P S : List UInt8) (hP : P.length % 64 = 0) :
    SHA256.pad (P ++ S) = P ++ S.take (64 * (S.length / 64)) ++
      tailSpec (S.drop (64 * (S.length / 64))) (P.length + S.length)
        (if S.length % 64 < 56 then 64 else 128) := by
  unfold SHA256.pad tailSpec
  dsimp only
  have hl : (S.drop (64 * (S.length / 64))).length = S.length % 64 := by simp; omega
  rw [hl]
  have hz : (SHA256.padZeros (8 * (P ++ S).length) - 7) / 8 =
      (if S.length % 64 < 56 then 64 else 128) - 9 - S.length % 64 := by
    simp only [SHA256.padZeros, List.length_append]
    split <;> omega
  rw [hz, List.length_append]
  simp only [List.append_assoc]
  rw [← List.append_assoc (List.take _ S) (List.drop _ S), List.take_append_drop]

/-- **`finish` is the rest of §6.2 after a prefix `P` of whole blocks**: from the hash value after
`P`, the hash value of `P ++ m[lo, hi)` padded, for every range. -/
theorem finish_spec (P : List UInt8) (hP : P.length % 64 = 0) (s : State)
    (hs : s.toHash = (SHA256.blocks P).foldl hstep SHA256.H0) (m : ByteArray) (lo hi : Nat) :
    (finish s P.length m lo hi).toHash =
      (SHA256.blocks (SHA256.pad (P ++ slice m lo hi))).foldl hstep SHA256.H0 := by
  rw [slice_clamp m lo hi]
  unfold finish
  dsimp only
  generalize hh : min hi m.size = hi' at *
  generalize hl : min lo hi' = lo' at *
  have hle : hi' ≤ m.size := by omega
  have hlo : lo' ≤ hi' := by omega
  have hn := slice_length m (lo := lo') hle
  rw [pad_split P _ hP, hn]
  -- the full blocks of the range, and its tail
  generalize hF : (hi' - lo') / 64 = F
  have hst : (slice m lo' hi').take (64 * F) = slice m lo' (lo' + 64 * F) := slice_take m _ (by omega)
  have hsd : (slice m lo' hi').drop (64 * F) = slice m (lo' + F * 64) hi' := by
    rw [slice_drop m _ (by omega), Nat.mul_comm 64 F]
  rw [hst, hsd]
  have hP' : P.length = 64 * (P.length / 64) := by omega
  have hB : (slice m lo' (lo' + 64 * F)).length = 64 * F := by
    rw [slice_length m (by omega)]; omega
  have hr : (hi' - lo') % 64 = hi' - (lo' + F * 64) := by omega
  rw [hr]
  generalize hT : tailSpec (slice m (lo' + F * 64) hi') (P.length + (hi' - lo')) = T
  -- the padded message's blocks: those of `P`, the full blocks, the tail's one or two
  have hblocks : ∀ len, (T len).length = len →
      SHA256.blocks (P ++ slice m lo' (lo' + 64 * F) ++ T len) =
        SHA256.blocksOf (P.length / 64) P ++ SHA256.blocksOf F (slice m lo' (lo' + 64 * F)) ++
          SHA256.blocksOf (len / 64) (T len) := by
    intro len hTl
    unfold SHA256.blocks
    rw [List.length_append, List.length_append, hB, hTl,
      show (P.length + 64 * F + len) / 64 = P.length / 64 + (F + len / 64) by omega,
      List.append_assoc, blocksOf_append _ _ _ hP', blocksOf_append _ _ _ hB, List.append_assoc]
  have hlenT : ∀ len, hi' - (lo' + F * 64) + 9 ≤ len → (T len).length = len := by
    intro len hl
    simp only [← hT, tailSpec, List.length_append, List.length_replicate, slice_length m hle, SHA256.be64,
      List.length_map, List.length_cons, List.length_nil]
    omega
  have hpre : (SHA256.blocksOf (P.length / 64) P ++ SHA256.blocksOf F (slice m lo' (lo' + 64 * F))).foldl
      hstep SHA256.H0 = (blocks s m lo' F).toHash := by
    rw [List.foldl_append, ← show SHA256.blocks P = SHA256.blocksOf (P.length / 64) P from rfl, ← hs,
      blocks_spec]
  have tb := fun s' len o => tailBlock_spec s' m (lo' + F * 64) hi' len (P.length + (hi' - lo')) o
  rw [hT] at tb
  split
  · rw [hblocks 64 (hlenT 64 (by omega)), List.foldl_append, hpre,
      tb _ 64 0 (by omega) hle (by omega) (by omega)]
    simp only [SHA256.blocksOf, List.foldl_cons, List.foldl_nil, List.drop_zero, hstep,
      show 64 / 64 = 1 from rfl]
  · rw [hblocks 128 (hlenT 128 (by omega)), List.foldl_append, hpre,
      tb _ 128 64 (by omega) hle (by omega) (by omega), tb _ 128 0 (by omega) hle (by omega) (by omega)]
    simp only [SHA256.blocksOf, List.foldl_cons, List.foldl_nil, List.drop_zero, hstep,
      show 128 / 64 = 2 from rfl]

/-- info: 'Feed.Sha256.finish_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms finish_spec

/-! ## The digest -/

private theorem bs_pushWord (out : ByteArray) (w : UInt32) :
    bs (pushWord out w) = bs out ++ SHA256.wordBytes w := by
  simp only [pushWord, bs_push, List.append_assoc, List.cons_append, List.nil_append]
  rw [byte_shift w 24 (by decide), byte_shift w 16 (by decide), byte_shift w 8 (by decide), byte_low]
  rfl

/-- The digest's bytes are `H_0 ‖ … ‖ H_7`, each big-endian. -/
theorem digest_spec (s : State) :
    bs (digest s) = let H := s.toHash; [H.a, H.b, H.c, H.d, H.e, H.f, H.g, H.h].flatMap SHA256.wordBytes := by
  simp only [digest, bs_pushWord, bs_emptyWithCapacity, List.flatMap_cons, List.flatMap_nil, List.append_nil,
    List.nil_append, List.append_assoc]
  rfl

end Sha256

/-- **SHA-256 is FIPS 180-4's**, for every message. -/
theorem Sha256.hash_spec (m : ByteArray) : bs (Sha256.hash m) = Spec.SHA256.sha256 (bs m) := by
  have e := Sha256.finish_spec [] rfl Sha256.init rfl m 0 m.size
  rw [List.nil_append, show slice m 0 m.size = bs m by
    simp only [slice, List.drop_zero, Nat.sub_zero]; exact List.take_of_length_le (by simp)] at e
  unfold Sha256.hash Sha256.hashSlice
  rw [Sha256.digest_spec]
  unfold SHA256.sha256
  rw [← e]
  rfl

/-- info: 'Feed.Sha256.hash_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Sha256.hash_spec

namespace Hmac
open Sha256

private theorem bs_pushZeros (out : ByteArray) :
    ∀ k, bs (pushZeros out k) = bs out ++ List.replicate k 0 := by
  intro k
  induction k generalizing out with
  | zero => simp [pushZeros]
  | succ k ih =>
    simp only [pushZeros, ih, bs_push, List.append_assoc]
    rw [List.replicate_succ]; rfl

private theorem K0_length (key : List UInt8) : (HMAC.K0 key).length = 64 := by
  unfold HMAC.K0 HMAC.B
  split <;> simp [SHA256.sha256_length] <;> omega

private theorem xor_replicate (l : List UInt8) (c : UInt8) :
    HMAC.xor l (List.replicate l.length c) = l.map (· ^^^ c) := by
  induction l with
  | nil => rfl
  | cons x l ih =>
    simp only [HMAC.xor, List.length_cons, List.replicate_succ, List.zipWith_cons_cons, List.map_cons] at ih ⊢
    rw [ih]

private theorem xor_length (key : List UInt8) (c : UInt8) :
    (HMAC.xor (HMAC.K0 key) (List.replicate 64 c)).length = 64 := by
  simp [HMAC.xor, K0_length]

/-- The key block of RFC 2104, `K0 ⊕ c…c`, as `Key.of` builds it. -/
private theorem keyBlock_bs (secret : ByteArray) (c : UInt8) :
    let k := if secret.size > 64 then Sha256.hash secret else secret
    let k := pushZeros k (64 - k.size)
    bs (⟨k.data.map (· ^^^ c)⟩ : ByteArray) = HMAC.xor (HMAC.K0 (bs secret)) (List.replicate 64 c) := by
  intro k k'
  have hk : bs k = if (bs secret).length > 64 then SHA256.sha256 (bs secret) else bs secret := by
    simp only [k, size_eq_length]
    split <;> simp_all [Sha256.hash_spec]
  have hk' : bs k' = HMAC.K0 (bs secret) := by
    simp only [k', bs_pushZeros, hk, HMAC.K0, HMAC.B, size_eq_length k]
    rfl
  have h64 : (bs k').length = 64 := by rw [hk', K0_length]
  show (k'.data.map (· ^^^ c)).toList = _
  rw [Array.toList_map]
  change (bs k').map (· ^^^ c) = _
  rw [← h64, ← xor_replicate, hk']

private theorem slice_zero_of_le (m : ByteArray) (hi : Nat) (h : (bs m).length ≤ hi) :
    slice m 0 hi = bs m := by
  simp only [slice, List.drop_zero, Nat.sub_zero]; exact List.take_of_length_le h

/-- **The key schedule** (`Key.of`): the hash values after the one block `K0 ⊕ ipad`, and after
`K0 ⊕ opad`, of RFC 2104 §2. -/
theorem keyOf_spec (secret : ByteArray) :
    (Key.of secret).inner.toHash =
        SHA256.compress SHA256.H0 (SHA256.words (HMAC.xor (HMAC.K0 (bs secret)) HMAC.ipad)) ∧
      (Key.of secret).outer.toHash =
        SHA256.compress SHA256.H0 (SHA256.words (HMAC.xor (HMAC.K0 (bs secret)) HMAC.opad)) := by
  have h36 := keyBlock_bs secret 0x36
  have h5c := keyBlock_bs secret 0x5c
  dsimp only at h36 h5c
  unfold Key.of
  dsimp only
  constructor
  · rw [compress_spec, Nat.zero_add, slice_zero_of_le _ _ (by rw [h36, xor_length]; exact Nat.le_refl _), h36]
    rfl
  · rw [compress_spec, Nat.zero_add, slice_zero_of_le _ _ (by rw [h5c, xor_length]; exact Nat.le_refl _), h5c]
    rfl

/-- info: 'Feed.Hmac.keyOf_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms keyOf_spec

/-- The big-endian words of a list of bytes, four at a time. -/
private def wordsOf : List UInt8 → List SHA256.Word
  | b0 :: b1 :: b2 :: b3 :: rest => SHA256.be32 b0 b1 b2 b3 :: wordsOf rest
  | _ => []

private theorem words_wordsOf : ∀ n (B : List UInt8), B.length = 4 * n →
    (List.range n).map (fun j => SHA256.be32 (B.getD (4 * j) 0) (B.getD (4 * j + 1) 0)
      (B.getD (4 * j + 2) 0) (B.getD (4 * j + 3) 0)) = wordsOf B
  | 0, B, h => by simp at h; subst h; rfl
  | n + 1, b0 :: b1 :: b2 :: b3 :: rest, h => by
    rw [List.range_succ_eq_map, List.map_cons, List.map_map, wordsOf,
      ← words_wordsOf n rest (by simp at h; omega)]
    simp only [Nat.mul_zero, Nat.zero_add, List.getD_cons_zero, List.getD_cons_succ, Function.comp_def,
      show ∀ j, 4 * (j + 1) = 4 * j + 1 + 1 + 1 + 1 from fun j => by omega]
  | n + 1, [], h | n + 1, [_], h | n + 1, [_, _], h | n + 1, [_, _, _], h => by
    simp only [List.length_cons, List.length_nil] at h; omega

/-- The outer hash's second block: the inner digest, `0x80`, zeros, the bit length 768. -/
private theorem words_outer (w0 w1 w2 w3 w4 w5 w6 w7 : UInt32) :
    SHA256.words (tailSpec ([w0, w1, w2, w3, w4, w5, w6, w7].flatMap SHA256.wordBytes) 96 64) =
      [w0, w1, w2, w3, w4, w5, w6, w7, 0x80000000, 0, 0, 0, 0, 0, 0, 768] := by
  rw [SHA256.words, words_wordsOf 16 _ (by simp [tailSpec, SHA256.wordBytes, SHA256.be64])]
  simp only [tailSpec, List.flatMap_cons, List.flatMap_nil, SHA256.wordBytes, List.map_cons, List.map_nil,
    List.cons_append, List.nil_append, List.append_nil, List.length_cons, List.length_nil, wordsOf,
    be32_wordBytes]
  rfl

end Hmac

/-- **HMAC-SHA256 is RFC 2104's**: under the key schedule of a key, the MAC of `m[lo, hi)` is
`H(K0 ⊕ opad ‖ H(K0 ⊕ ipad ‖ m[lo, hi)))`, for every range. -/
theorem Hmac.mac_spec (secret m : ByteArray) (lo hi : Nat) :
    bs (Hmac.mac (Hmac.Key.of secret) m lo hi) = Spec.HMAC.hmacSha256 (bs secret) (slice m lo hi) := by
  obtain ⟨hin, hout⟩ := keyOf_spec secret
  generalize Key.of secret = key at hin hout
  generalize hIp : HMAC.xor (HMAC.K0 (bs secret)) HMAC.ipad = Ip at hin
  generalize hOp : HMAC.xor (HMAC.K0 (bs secret)) HMAC.opad = Op at hout
  have hPi : Ip.length = 64 := hIp ▸ xor_length _ _
  have hPo : Op.length = 64 := hOp ▸ xor_length _ _
  have hone : ∀ P : List UInt8, P.length = 64 → SHA256.blocks P = [P] := by
    intro P hP
    unfold SHA256.blocks; rw [hP]; simp [SHA256.blocksOf, List.take_of_length_le (Nat.le_of_eq hP)]
  -- the inner hash: the block `K0 ⊕ ipad`, which the key holds, then the message
  have hs : key.inner.toHash = (SHA256.blocks Ip).foldl Sha256.hstep SHA256.H0 := by
    rw [hin, hone _ hPi]; rfl
  have e := Sha256.finish_spec _ (by rw [hPi]) key.inner hs m lo hi
  rw [hPi] at e
  unfold mac
  dsimp only
  generalize Sha256.finish key.inner 64 m lo hi = i at e
  rw [Sha256.digest_spec, Sha256.compressW_spec]
  unfold HMAC.hmacSha256
  rw [hIp, hOp]
  -- the outer hash: the block `K0 ⊕ opad`, which the key holds, then the inner digest padded
  generalize hDD : [i.toHash.a, i.toHash.b, i.toHash.c, i.toHash.d, i.toHash.e, i.toHash.f, i.toHash.g,
    i.toHash.h].flatMap SHA256.wordBytes = D
  have hD : SHA256.sha256 (Ip ++ slice m lo hi) = D := by
    rw [← hDD]; unfold SHA256.sha256; rw [← e]
  have hDl : D.length = 32 := by rw [← hDD]; simp [SHA256.wordBytes]
  rw [hD]
  unfold SHA256.sha256
  rw [Sha256.pad_split _ D (by rw [hPo]), hDl, hPo]
  rw [show (64 + 32 : Nat) = 96 from rfl, show (if 32 % 64 < 56 then 64 else 128 : Nat) = 64 from rfl,
    show 64 * (32 / 64) = 0 from rfl, List.take_zero, List.drop_zero, List.append_nil]
  have hT : (Sha256.tailSpec D 96 64).length = 64 := by simp [Sha256.tailSpec, hDl, SHA256.be64]
  have hb : SHA256.blocks (Op ++ Sha256.tailSpec D 96 64) = [Op, Sha256.tailSpec D 96 64] := by
    unfold SHA256.blocks
    rw [List.length_append, hPo, hT, show (64 + 64) / 64 = 1 + 1 from rfl,
      Sha256.blocksOf_append 1 _ _ (by rw [hPo]) 1]
    simp only [SHA256.blocksOf, List.cons_append, List.nil_append]
    rw [List.take_of_length_le (by rw [hPo]; exact Nat.le_refl _),
      List.take_of_length_le (by rw [hT]; exact Nat.le_refl _)]
  rw [hb]
  simp only [List.foldl_cons, List.foldl_nil, ← hout, ← hDD, words_outer]
  rfl

/-- info: 'Feed.Hmac.mac_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Hmac.mac_spec

end Feed
