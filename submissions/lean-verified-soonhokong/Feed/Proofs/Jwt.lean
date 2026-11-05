import Feed.Proofs.Bytes

/-!
# Token checks

What an accepted token satisfies: its signature is the base64url HMAC-SHA256 of its first two
parts under the server's key, its header says `"alg":"HS256"`, its `exp` is after `now`.

`verify` asks `parseTop` for more keys than these statements name (`crit` and `cty` in the
header, `aud` in the payload); `parseTop_keys_append` says the extra keys change nothing about
the first ones.
-/

namespace Feed.Json

theorem extract_set! (fs : Array Field) (k n : Nat) (x : Field) :
    (fs.set! k x).extract 0 n = (fs.extract 0 n).set! k x := by
  apply Array.ext
  · simp [Array.set!_eq_setIfInBounds]
  · intro i h1 h2
    simp only [Array.set!_eq_setIfInBounds, Array.size_extract, Array.size_setIfInBounds] at h1 h2
    simp only [Array.set!_eq_setIfInBounds, Array.getElem_extract, Nat.zero_add]
    rw [Array.getElem_setIfInBounds (by omega), Array.getElem_setIfInBounds (by simp; omega)]
    simp

theorem extract_set!_of_le {fs : Array Field} {k n : Nat} (x : Field) (hk : n ≤ k) :
    (fs.set! k x).extract 0 n = fs.extract 0 n := by
  apply Array.ext
  · simp [Array.set!_eq_setIfInBounds]
  · intro i h1 h2
    simp only [Array.set!_eq_setIfInBounds, Array.size_extract, Array.size_setIfInBounds] at h1 h2
    simp only [Array.set!_eq_setIfInBounds, Array.getElem_extract, Nat.zero_add]
    rw [Array.getElem_setIfInBounds (by omega)]
    simp only [ite_eq_right_iff]
    omega

theorem extract_getElem! (fs : Array Field) {i n : Nat} (h : i < n) : (fs.extract 0 n)[i]! = fs[i]! := by
  simp only [Array.getElem!_eq_getD, Array.getD_eq_getD_getElem?, Array.getElem?_extract, Nat.sub_zero,
    Nat.zero_add]
  split
  · rfl
  · rw [Array.getElem?_eq_none (by omega)]

theorem recordField_go_append (a : ByteArray) (klo khi vlo vhi : Nat) (ks ks' : Array ByteArray) :
    ∀ f k fs, k + f = ks.size + ks'.size →
      (recordField.go a klo khi vlo vhi (ks ++ ks') k f fs).extract 0 ks.size =
        recordField.go a klo khi vlo vhi ks k (ks.size - k) (fs.extract 0 ks.size) := by
  intro f
  induction f with
  | zero =>
    intro k fs h
    rw [show ks.size - k = 0 by omega]
    simp only [recordField.go]
  | succ f ih =>
    intro k fs h
    by_cases hk : k < ks.size
    · rw [show ks.size - k = (ks.size - (k + 1)) + 1 by omega]
      have hkey : (ks ++ ks')[k]! = ks[k]! := by
        simp [Array.getElem!_eq_getD, Array.getD_eq_getD_getElem?, Array.getElem?_append_left hk]
      simp only [recordField.go, hkey]
      split
      · exact extract_set! _ _ _ _
      · exact ih (k + 1) fs (by omega)
    · rw [show ks.size - k = 0 by omega]
      simp only [recordField.go]
      split
      · exact extract_set!_of_le _ (by omega)
      · rw [ih (k + 1) fs (by omega), show ks.size - (k + 1) = 0 by omega]
        simp only [recordField.go]

/-- A member recorded for the keys `ks ++ ks'` is recorded for `ks` alone in the same place. -/
theorem recordField_append (a : ByteArray) (klo khi vlo vhi : Nat) (ks ks' : Array ByteArray) (fs : Array Field) :
    (recordField a klo khi vlo vhi (ks ++ ks') fs).extract 0 ks.size =
      recordField a klo khi vlo vhi ks (fs.extract 0 ks.size) := by
  simp only [recordField]
  rw [recordField_go_append a klo khi vlo vhi ks ks' _ 0 fs (by simp), Nat.sub_zero]

theorem topMembers_append (a : ByteArray) (hi : Nat) (ks ks' : Array ByteArray) :
    ∀ f i first fs, topMembers a hi ks i first (fs.extract 0 ks.size) f =
      (topMembers a hi (ks ++ ks') i first fs f).map fun r => (r.1, r.2.extract 0 ks.size) := by
  intro f
  induction f with
  | zero => intros; rfl
  | succ f ih =>
    intro i first fs
    simp only [topMembers]
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
        · simp [recordField_append]
        split
        · rw [← recordField_append, ih]
        · rfl

/-- `parseTop`'s answer with an object's fields cut to the first `n`. -/
def Top.take (n : Nat) : Top → Top
  | .object fs => .object (fs.extract 0 n)
  | t => t

theorem parseTop_append (a : ByteArray) (lo hi : Nat) (ks ks' : Array ByteArray) :
    parseTop a lo hi ks = (parseTop a lo hi (ks ++ ks')).take ks.size := by
  have hrep : (Array.replicate (ks ++ ks').size (⟨.absent, 0, 0⟩ : Field)).extract 0 ks.size =
      Array.replicate ks.size ⟨.absent, 0, 0⟩ := by
    simp [Array.extract_replicate]
  simp only [parseTop]
  split
  next =>
    rw [← hrep, topMembers_append]
    cases topMembers a (min hi a.size) (ks ++ ks') _ true _ _ with
    | none => rfl
    | some r =>
      obtain ⟨j, fs⟩ := r
      dsimp only [Option.map]
      split <;> rfl
  next => split <;> (try split) <;> rfl

/-- info: 'Feed.Json.parseTop_append' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms parseTop_append

/-- Asking `parseTop` for more keys changes nothing about the first ones: the same answer, and
the fields of the first keys are those it reports with fewer. -/
theorem parseTop_keys_append (a : ByteArray) (lo hi : Nat) (ks ks' : Array ByteArray) :
    match parseTop a lo hi (ks ++ ks'), parseTop a lo hi ks with
    | .object fs, .object gs => gs = fs.extract 0 ks.size
    | .malformed, .malformed => True
    | .notObject, .notObject => True
    | _, _ => False := by
  rw [parseTop_append a lo hi ks ks']
  cases parseTop a lo hi (ks ++ ks') <;> trivial

/-- info: 'Feed.Json.parseTop_keys_append' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms parseTop_keys_append

end Feed.Json

namespace Feed.Jwt
open Json

theorem ctEq_go_zero (x a : ByteArray) (lo : Nat) :
    ∀ f k acc, ctEq.go x a lo k f acc = 0 → acc = 0 ∧ ∀ j, k ≤ j → j < k + f → x.get! j = a.get! (lo + j) := by
  intro f
  induction f with
  | zero => intro k acc h; exact ⟨h, fun j h1 h2 => by omega⟩
  | succ f ih =>
    intro k acc h
    obtain ⟨h0, hrest⟩ := ih (k + 1) _ h
    have hor := h0
    rw [UInt8.or_eq_zero_iff] at hor
    refine ⟨hor.1, fun j h1 h2 => ?_⟩
    rcases Nat.eq_or_lt_of_le h1 with rfl | hlt
    · have := hor.2
      rw [UInt8.xor_eq_zero_iff] at this
      exact this
    · exact hrest j (by omega) (by omega)

/-- `ctEq` holds exactly when every byte matches (and the lengths agree). -/
theorem ctEq_spec {x a : ByteArray} {lo hi : Nat} (h : ctEq x a lo hi = true) :
    hi - lo = x.size ∧ ∀ j < x.size, x.get! j = a.get! (lo + j) := by
  unfold ctEq at h
  simp only [Bool.and_eq_true, beq_iff_eq] at h
  exact ⟨h.1, fun j hj => (ctEq_go_zero x a lo x.size 0 0 h.2).2 j (Nat.zero_le _) (by omega)⟩

/-- **An accepted token was signed with the key**: the bytes after its second dot are the base64url
HMAC-SHA256 of the bytes before it, under `key`; its header names HS256; its `exp` is after `now`. -/
theorem verify_ok_sound {key : Hmac.Key} {now : Nat} {a : ByteArray} {lo hi uid : Nat} {name : ByteArray}
    (h : verify key now a lo hi = .ok uid name) :
    let hi' := min hi a.size
    let d1 := Bytes.findByte a 0x2e lo hi'
    let d2 := Bytes.findByte a 0x2e (d1 + 1) hi'
    let sig := b64Encode (Hmac.mac key a lo d2)
    (hi' - (d2 + 1) = sig.size ∧ ∀ j < sig.size, sig.get! j = a.get! (d2 + 1 + j)) ∧
    (∃ hd pl, b64Decode a lo d1 = some hd ∧ b64Decode a (d1 + 1) d2 = some pl ∧
      (∃ hf, parseTop hd 0 hd.size #[keyAlg] = .object hf ∧ hf[0]!.kind = .str ∧
        decodeString hd hf[0]!.lo hf[0]!.hi = hs256) ∧
      (∃ pf, parseTop pl 0 pl.size #[keyExp, keyNbf, keySub, keyUsername] = .object pf ∧ pf[0]!.kind = .num ∧
        numGt pl pf[0]!.lo pf[0]!.hi now = true)) := by
  intro hi' d1 d2 sig
  unfold verify at h
  simp only at h
  split at h
  · cases h
  split at h
  · cases h
  next hsig =>
  refine ⟨ctEq_spec (by simpa using hsig), ?_⟩
  split at h
  next hd pl hdh hdp =>
    refine ⟨hd, pl, hdh, hdp, ?_⟩
    split at h
    next hf pf hph hpp =>
      split at h
      · cases h
      next halg =>
      split at h
      · cases h
      split at h
      · cases h
      split at h
      · cases h
      next hexp =>
      simp only [Bool.or_eq_true, bne_iff_ne, ne_eq, not_or, Decidable.not_not] at halg hexp
      -- the fields of the keys named here are those `verify` got with `crit`, `cty` and `aud` too
      have hh := parseTop_append hd 0 hd.size #[keyAlg] #[keyCrit, keyCty]
      have hp := parseTop_append pl 0 pl.size #[keyExp, keyNbf, keySub, keyUsername] #[keyAud]
      rw [show #[keyAlg] ++ #[keyCrit, keyCty] = #[keyAlg, keyCrit, keyCty] from rfl, hph] at hh
      rw [show #[keyExp, keyNbf, keySub, keyUsername] ++ #[keyAud] = #[keyExp, keyNbf, keySub, keyUsername, keyAud]
        from rfl, hpp] at hp
      have h0 : (hf.extract 0 1)[0]! = hf[0]! := extract_getElem! hf (by decide)
      have p0 : (pf.extract 0 4)[0]! = pf[0]! := extract_getElem! pf (by decide)
      exact ⟨⟨hf.extract 0 1, hh, h0 ▸ halg⟩, pf.extract 0 4, hp, by simpa [p0] using hexp⟩
    next => cases h
  next => cases h

/-- info: 'Feed.Jwt.verify_ok_sound' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms verify_ok_sound

end Feed.Jwt
