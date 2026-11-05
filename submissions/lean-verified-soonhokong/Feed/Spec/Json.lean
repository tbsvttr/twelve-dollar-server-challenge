import Feed.Spec.Utf8

/-!
# JSON texts

RFC 8259 as relations on bytes: `IsText t` says that `t` is a JSON text, `IsObjectText t ms` that
it is one whose value is an object with the members `ms`, each name as its UTF-16 code units and
each value as its text. Texts are UTF-8 (§8.1): outside strings every byte is ASCII, and inside
them every character that is not escaped is the UTF-8 of a scalar value.
-/
namespace Feed.Spec.Json

/-! ## Tokens: whitespace, numbers, strings -/

/-- §2 `ws = *( %x20 / %x09 / %x0A / %x0D )` -/
def IsWs (b : UInt8) : Prop := b = 0x20 ∨ b = 0x09 ∨ b = 0x0a ∨ b = 0x0d
def Ws (w : List UInt8) : Prop := ∀ b ∈ w, IsWs b

def IsDigit (b : UInt8) : Prop := 0x30 ≤ b ∧ b ≤ 0x39
/-- `1*DIGIT` -/
def Digits (ds : List UInt8) : Prop := ds ≠ [] ∧ ∀ d ∈ ds, IsDigit d
def decVal (ds : List UInt8) : Nat := ds.foldl (fun acc d => acc * 10 + (d.toNat - 0x30)) 0

/-- RFC 5234 `HEXDIG`; ABNF literals are case-insensitive, and §7 says so for `\u`. -/
def IsHexDig (b : UInt8) : Prop := IsDigit b ∨ (0x41 ≤ b ∧ b ≤ 0x46) ∨ (0x61 ≤ b ∧ b ≤ 0x66)
def hexVal (b : UInt8) : Nat :=
  if b ≤ 0x39 then b.toNat - 0x30 else if b ≤ 0x46 then b.toNat - 0x41 + 10 else b.toNat - 0x61 + 10

/-- §6 `int = zero / ( digit1-9 *DIGIT )` -/
def IsInt (ds : List UInt8) : Prop :=
  ds = [0x30] ∨ ∃ d ds', ds = d :: ds' ∧ 0x31 ≤ d ∧ d ≤ 0x39 ∧ ∀ x ∈ ds', IsDigit x

/-- §6 `frac = decimal-point 1*DIGIT`, with its digits. -/
def IsFrac (f ds : List UInt8) : Prop := f = 0x2e :: ds ∧ Digits ds

/-- §6 `exp = e [ minus / plus ] 1*DIGIT`, with its value. -/
def IsExp (x : List UInt8) (e : Int) : Prop :=
  ∃ c s ds, x = c :: s ++ ds ∧ (c = 0x65 ∨ c = 0x45) ∧ Digits ds ∧
    (s = [] ∧ e = decVal ds ∨ s = [0x2b] ∧ e = decVal ds ∨ s = [0x2d] ∧ e = -(decVal ds : Int))

/-- §6 `number = [ minus ] int [ frac ] [ exp ]`: `t` is a number whose value is
`(-1)^neg · m · 10^e` exactly (int and frac digits as `m`, the exponent less the frac length). -/
def IsNumber (t : List UInt8) (neg : Bool) (m : Nat) (e : Int) : Prop :=
  ∃ (s i f x fd : List UInt8) (ex : Int),
    t = s ++ i ++ f ++ x ∧
    (s = [] ∧ neg = false ∨ s = [0x2d] ∧ neg = true) ∧ IsInt i ∧
    (f = [] ∧ fd = [] ∨ IsFrac f fd) ∧ (x = [] ∧ ex = 0 ∨ IsExp x ex) ∧
    m = decVal (i ++ fd) ∧ e = ex - fd.length

/-- The number `t` is greater than `n` (RFC 7519 §4.1.4: "the current date/time MUST be before"
`exp`), compared exactly. -/
def NumGt (t : List UInt8) (n : Nat) : Prop :=
  ∃ neg m e, IsNumber t neg m e ∧ neg = false ∧
    if 0 ≤ e then n < m * 10 ^ e.toNat else n * 10 ^ (-e).toNat < m

/-- §7 `char`: the text of one character of a string and the UTF-16 code units it stands for.
Unescaped characters are UTF-8 (§8.1); `\uXXXX` is one code unit (a character outside the BMP is
written as its surrogate pair, §7; an unpaired surrogate is allowed by the grammar, §8.2). -/
inductive StrChar : List UInt8 → List Nat → Prop
  | plain (c : Nat) : IsScalar c → 0x20 ≤ c → c ≠ 0x22 → c ≠ 0x5c → StrChar (utf8 c) (utf16 c)
  | esc (e : UInt8) (u : Nat) :
      (e, u) ∈ [((0x22 : UInt8), (0x22 : Nat)), (0x5c, 0x5c), (0x2f, 0x2f), (0x62, 0x08), (0x66, 0x0c),
        (0x6e, 0x0a), (0x72, 0x0d), (0x74, 0x09)] →
      StrChar [0x5c, e] [u]
  | uesc (h₁ h₂ h₃ h₄ : UInt8) : IsHexDig h₁ → IsHexDig h₂ → IsHexDig h₃ → IsHexDig h₄ →
      StrChar [0x5c, 0x75, h₁, h₂, h₃, h₄] [((hexVal h₁ * 16 + hexVal h₂) * 16 + hexVal h₃) * 16 + hexVal h₄]

/-- `*char` -/
inductive StrChars : List UInt8 → List Nat → Prop
  | nil : StrChars [] []
  | cons {t u ts us} : StrChar t u → StrChars ts us → StrChars (t ++ ts) (u ++ us)

/-- §7 `string = quotation-mark *char quotation-mark`, with its code units. -/
def IsString (t : List UInt8) (us : List Nat) : Prop := ∃ b, t = 0x22 :: b ++ [0x22] ∧ StrChars b us

/-! ## Values -/

mutual
/-- §3 `value`: the text of a value, without whitespace around it. -/
inductive IsValue : List UInt8 → Prop
  | str {t us} : IsString t us → IsValue t
  | num {t neg m e} : IsNumber t neg m e → IsValue t
  | tru : IsValue [0x74, 0x72, 0x75, 0x65]
  | fls : IsValue [0x66, 0x61, 0x6c, 0x73, 0x65]
  | null : IsValue [0x6e, 0x75, 0x6c, 0x6c]
  | obj {t ms} : IsObject t ms → IsValue t
  | arr {t} : IsArray t → IsValue t

/-- §4 `object`: its text and its members in order (each name's code units, its value's text). -/
inductive IsObject : List UInt8 → List (List Nat × List UInt8) → Prop
  | empty {w} : Ws w → IsObject (0x7b :: w ++ [0x7d]) []
  | members {w₁ m w₂ ms} : Ws w₁ → IsMembers m ms → Ws w₂ → IsObject (0x7b :: w₁ ++ m ++ w₂ ++ [0x7d]) ms

/-- `member *( value-separator member )`, `member = string name-separator value` -/
inductive IsMembers : List UInt8 → List (List Nat × List UInt8) → Prop
  | one {k us w₁ w₂ v} : IsString k us → Ws w₁ → Ws w₂ → IsValue v →
      IsMembers (k ++ w₁ ++ [0x3a] ++ w₂ ++ v) [(us, v)]
  | cons {k us w₁ w₂ v w₃ w₄ m ms} : IsString k us → Ws w₁ → Ws w₂ → IsValue v → Ws w₃ → Ws w₄ →
      IsMembers m ms → IsMembers (k ++ w₁ ++ [0x3a] ++ w₂ ++ v ++ w₃ ++ [0x2c] ++ w₄ ++ m) ((us, v) :: ms)

/-- §5 `array` -/
inductive IsArray : List UInt8 → Prop
  | empty {w} : Ws w → IsArray (0x5b :: w ++ [0x5d])
  | elems {w₁ e w₂} : Ws w₁ → IsElems e → Ws w₂ → IsArray (0x5b :: w₁ ++ e ++ w₂ ++ [0x5d])

/-- `value *( value-separator value )` -/
inductive IsElems : List UInt8 → Prop
  | one {v} : IsValue v → IsElems v
  | cons {v w₁ w₂ e} : IsValue v → Ws w₁ → Ws w₂ → IsElems e → IsElems (v ++ w₁ ++ [0x2c] ++ w₂ ++ e)
end

/-- §2 `JSON-text = ws value ws`. Outside strings every byte is ASCII and inside them every
unescaped character is UTF-8, so a text is UTF-8 (§8.1); a byte order mark is not part of it
(§8.1 lets a parser ignore one; this one does not). -/
def IsText (t : List UInt8) : Prop := ∃ w₁ v w₂, t = w₁ ++ v ++ w₂ ∧ Ws w₁ ∧ IsValue v ∧ Ws w₂

/-- A text whose value is an object with these members. -/
def IsObjectText (t : List UInt8) (ms : List (List Nat × List UInt8)) : Prop :=
  ∃ w₁ v w₂, t = w₁ ++ v ++ w₂ ∧ Ws w₁ ∧ IsObject v ms ∧ Ws w₂

/-- The value of the member named `name`, the last if several (§4: "Many implementations report
the last name/value pair only"; RFC 7515 §4 and RFC 7519 §4 allow exactly this for JOSE headers
and claims). Names are compared as code units (§8.3). -/
def member (ms : List (List Nat × List UInt8)) (name : List Nat) : Option (List UInt8) :=
  (ms.reverse.find? (·.1 == name)).map (·.2)

/-- The UTF-8 text of the string value of member `name` (for the token's header and claims). -/
def StrMember (ms : List (List Nat × List UInt8)) (name : List Nat) (s : List UInt8) : Prop :=
  ∃ v us, member ms name = some v ∧ IsString v us ∧ s = encode (scalars us)

end Feed.Spec.Json
