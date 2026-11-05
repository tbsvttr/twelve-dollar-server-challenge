/-!
# Characters: UTF-8 and UTF-16

Unicode scalar values, their UTF-8 bytes (RFC 3629) and their UTF-16 code units (RFC 2781), as the
JSON specification (`Feed/Spec/Json.lean`) uses them: JSON texts are UTF-8 (RFC 8259 §8.1), and a
string's `\u` escapes are UTF-16 code units (§7).
-/
namespace Feed.Spec.Json

/-- RFC 3629 §3: the UTF-8 encoding of the code point `c`. -/
def utf8 (c : Nat) : List UInt8 :=
  if c < 0x80 then [c.toUInt8]
  else if c < 0x800 then [(0xc0 + c / 0x40).toUInt8, (0x80 + c % 0x40).toUInt8]
  else if c < 0x10000 then
    [(0xe0 + c / 0x1000).toUInt8, (0x80 + c / 0x40 % 0x40).toUInt8, (0x80 + c % 0x40).toUInt8]
  else
    [(0xf0 + c / 0x40000).toUInt8, (0x80 + c / 0x1000 % 0x40).toUInt8, (0x80 + c / 0x40 % 0x40).toUInt8,
     (0x80 + c % 0x40).toUInt8]

/-- A Unicode scalar value: a code point up to U+10FFFF that is not a surrogate. -/
def IsScalar (c : Nat) : Prop := c ≤ 0x10ffff ∧ (c < 0xd800 ∨ 0xdfff < c)

/-- The UTF-8 text of a list of scalar values. The well-formed UTF-8 of RFC 3629 §4 is exactly the
set of these texts. -/
def encode (cs : List Nat) : List UInt8 := cs.flatMap utf8

/-- RFC 2781 §2.1: the UTF-16 code units of a scalar value. -/
def utf16 (c : Nat) : List Nat :=
  if c < 0x10000 then [c] else [0xd800 + (c - 0x10000) / 0x400, 0xdc00 + (c - 0x10000) % 0x400]

/-- Code units as scalar values: surrogate pairs combined (RFC 2781 §2.2), a surrogate outside a
pair (which RFC 8259 §8.2 lets a JSON string hold) as U+FFFD. -/
def scalars : List Nat → List Nat
  | [] => []
  | [u] => [if 0xd800 ≤ u ∧ u ≤ 0xdfff then 0xfffd else u]
  | u :: v :: rest =>
    if 0xd800 ≤ u ∧ u ≤ 0xdbff ∧ 0xdc00 ≤ v ∧ v ≤ 0xdfff then
      (0x10000 + (u - 0xd800) * 0x400 + (v - 0xdc00)) :: scalars rest
    else (if 0xd800 ≤ u ∧ u ≤ 0xdfff then 0xfffd else u) :: scalars (v :: rest)

end Feed.Spec.Json
