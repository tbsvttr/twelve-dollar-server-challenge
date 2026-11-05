import Feed.Bytes

/-!
# JSON string escaping

`Feed.escape` (what every string field of a response goes through) produces the body of a JSON
string literal (RFC 8259 §7) that decodes back to the original bytes: no raw quote, backslash or
control byte is left, and each escape is one of the forms the RFC defines.
-/
namespace Feed.Escape

def isHexDigit (b : UInt8) : Bool := (0x30 ≤ b && b ≤ 0x39) || (0x61 ≤ b && b ≤ 0x66)

def hexVal (b : UInt8) : Nat := if b ≤ 0x39 then (b - 0x30).toNat else (b - 0x61 + 10).toNat

/-- The byte a two-character escape `\e` stands for. -/
def simpleEscape (e : UInt8) : Option UInt8 :=
  if e == 0x22 then some 0x22 else if e == 0x5c then some 0x5c else if e == 0x2f then some 0x2f
  else if e == 0x62 then some 0x08 else if e == 0x66 then some 0x0c else if e == 0x6e then some 0x0a
  else if e == 0x72 then some 0x0d else if e == 0x74 then some 0x09 else none

/-- RFC 8259 string body decoding (of the escapes this server produces: the two-character ones
and `\u00XX`): `none` if the text is not a well-formed string body. -/
def decode : List UInt8 → Option (List UInt8)
  | [] => some []
  | b :: rest =>
    if b == 0x5c then
      match rest with
      | e :: rest =>
        match simpleEscape e with
        | some c => (decode rest).map (c :: ·)
        | none =>
          if e == 0x75 then
            match rest with
            | z1 :: z2 :: h1 :: h2 :: rest' =>
              if z1 == 0x30 && z2 == 0x30 && isHexDigit h1 && isHexDigit h2 then
                (decode rest').map ((hexVal h1 * 16 + hexVal h2).toUInt8 :: ·)
              else none
            | _ => none
          else none
      | [] => none
    else if b < 0x20 || b == 0x22 then none
    else (decode rest).map (b :: ·)

/-- The `\u00XX` escape of a control byte reads back as that byte. -/
theorem ctrl_roundtrip : ∀ b : UInt8, b < 0x20 →
    isHexDigit (hexDigit (b >>> 4)) = true ∧ isHexDigit (hexDigit (b &&& 15)) = true ∧
    (hexVal (hexDigit (b >>> 4)) * 16 + hexVal (hexDigit (b &&& 15))).toUInt8 = b := by
  have : ∀ k : Fin 32, isHexDigit (hexDigit (UInt8.ofFin (k.castLE (by decide)) >>> 4)) = true ∧
      isHexDigit (hexDigit (UInt8.ofFin (k.castLE (by decide)) &&& 15)) = true ∧
      (hexVal (hexDigit (UInt8.ofFin (k.castLE (by decide)) >>> 4)) * 16 +
        hexVal (hexDigit (UInt8.ofFin (k.castLE (by decide)) &&& 15))).toUInt8 = UInt8.ofFin (k.castLE (by decide)) := by
    decide
  intro b hb
  have hlt : b.toNat < 32 := by simpa [UInt8.lt_iff_toNat_lt] using hb
  have := this ⟨b.toNat, hlt⟩
  have hb' : UInt8.ofFin ((⟨b.toNat, hlt⟩ : Fin 32).castLE (by decide)) = b := by
    apply UInt8.toNat_inj.mp; simp
  rwa [hb'] at this

theorem decode_escByte (b : UInt8) (rest : List UInt8) :
    decode (escByte b ++ rest) = (decode rest).map (b :: ·) := by
  unfold escByte
  by_cases h22 : b = 0x22
  · subst h22; rw [decode.eq_def]; simp [simpleEscape]
  by_cases h5c : b = 0x5c
  · subst h5c; rw [decode.eq_def]; simp [simpleEscape]
  by_cases h08 : b = 0x08
  · subst h08; rw [decode.eq_def]; simp [simpleEscape]
  by_cases h0c : b = 0x0c
  · subst h0c; rw [decode.eq_def]; simp [simpleEscape]
  by_cases h0a : b = 0x0a
  · subst h0a; rw [decode.eq_def]; simp [simpleEscape]
  by_cases h0d : b = 0x0d
  · subst h0d; rw [decode.eq_def]; simp [simpleEscape]
  by_cases h09 : b = 0x09
  · subst h09; rw [decode.eq_def]; simp [simpleEscape]
  simp only [beq_iff_eq, h22, h5c, h08, h0c, h0a, h0d, h09, ↓reduceIte]
  by_cases hlt : b < 0x20
  · obtain ⟨h1, h2, h3⟩ := ctrl_roundtrip b hlt
    simp only [hlt, ↓reduceIte, List.cons_append, List.nil_append]
    rw [decode.eq_def]; simp [simpleEscape, h1, h2, h3]
  · simp only [hlt, ↓reduceIte, List.cons_append, List.nil_append]
    rw [decode.eq_def]; simp [hlt, h22, h5c]

/-- **Escaping round-trips**: the escaped bytes are a well-formed JSON string body that decodes to
exactly the original bytes. -/
theorem decode_escape (s : List UInt8) : decode (escape s) = some s := by
  induction s with
  | nil => rfl
  | cons b bs ih =>
    have : escape (b :: bs) = escByte b ++ escape bs := by simp [escape]
    rw [this, decode_escByte, ih]; rfl

/-- info: 'Feed.Escape.decode_escape' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms decode_escape

end Feed.Escape
