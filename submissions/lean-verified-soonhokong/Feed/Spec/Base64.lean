import Feed.Spec

/-!
# base64url

The base64url encoding of RFC 4648 §5 without padding, as JWS uses it (RFC 7515 §2, "Base64url
Encoding"): the three parts of a token are base64url text.
-/
namespace Feed.Spec

/-- RFC 4648 §5, Table 2. -/
def b64urlAlphabet : List UInt8 :=
  lit "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
def b64urlChar (v : Nat) : UInt8 := b64urlAlphabet.getD v 0
/-- The 6-bit value of a character; `none` outside the alphabet ('=' included). -/
def b64urlVal (c : UInt8) : Option Nat := b64urlAlphabet.idxOf? c

/-- BASE64URL (RFC 7515 §2): each 24-bit group as four characters; a final 16 or 8 bits are
filled on the right with zero bits to 18 or 12 bits and written as three or two characters; no '='. -/
def b64urlEncode : List UInt8 → List UInt8
  | x :: y :: z :: rest =>
    let n := x.toNat * 2 ^ 16 + y.toNat * 2 ^ 8 + z.toNat
    [b64urlChar (n / 2 ^ 18), b64urlChar (n / 2 ^ 12 % 64), b64urlChar (n / 2 ^ 6 % 64),
      b64urlChar (n % 64)] ++ b64urlEncode rest
  | [x, y] =>
    let n := (x.toNat * 2 ^ 8 + y.toNat) * 2 ^ 2
    [b64urlChar (n / 2 ^ 12), b64urlChar (n / 2 ^ 6 % 64), b64urlChar (n % 64)]
  | [x] =>
    let n := x.toNat * 2 ^ 4
    [b64urlChar (n / 2 ^ 6), b64urlChar (n % 64)]
  | [] => []

/-- The octets whose BASE64URL is `s`: bytes outside the alphabet, a length of 1 mod 4 and nonzero
pad bits (RFC 4648 §3.5: a decoder MAY reject them) are rejected, so that the decoding of `s` is
`d` exactly when `s` is the encoding of `d` (`b64urlDecode_eq_some_iff` in
`Feed/Proofs/Base64.lean`). -/
def b64urlDecode : List UInt8 → Option (List UInt8)
  | [] => some []
  | [_] => none
  | [c0, c1] => do
    let v0 ← b64urlVal c0; let v1 ← b64urlVal c1
    if v1 % 2 ^ 4 = 0 then some [(v0 * 2 ^ 2 + v1 / 2 ^ 4).toUInt8] else none
  | [c0, c1, c2] => do
    let v0 ← b64urlVal c0; let v1 ← b64urlVal c1; let v2 ← b64urlVal c2
    let n := v0 * 2 ^ 12 + v1 * 2 ^ 6 + v2
    if n % 2 ^ 2 = 0 then some [(n / 2 ^ 10).toUInt8, (n / 2 ^ 2 % 2 ^ 8).toUInt8] else none
  | c0 :: c1 :: c2 :: c3 :: rest => do
    let v0 ← b64urlVal c0; let v1 ← b64urlVal c1; let v2 ← b64urlVal c2; let v3 ← b64urlVal c3
    let n := v0 * 2 ^ 18 + v1 * 2 ^ 12 + v2 * 2 ^ 6 + v3
    let r ← b64urlDecode rest
    some ([(n / 2 ^ 16).toUInt8, (n / 2 ^ 8 % 2 ^ 8).toUInt8, (n % 2 ^ 8).toUInt8] ++ r)

example : b64urlEncode (lit "Hello") = lit "SGVsbG8" := by decide
example : b64urlDecode (lit "SGVsbG8") = some (lit "Hello") := by decide
example : b64urlDecode (lit "SGVsbG8=") = none := by decide
example : b64urlDecode (lit "SGVsbG9") = none := by decide

end Feed.Spec
