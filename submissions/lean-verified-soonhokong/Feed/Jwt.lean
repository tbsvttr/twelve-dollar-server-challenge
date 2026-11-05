import Feed.Json
import Feed.Sha256

/-!
# JWT (HS256) verification

`Authorization: Bearer <header>.<payload>.<signature>`, each part base64url without padding
(RFC 7515 §2). A token is accepted when the header is a JSON object with `"alg":"HS256"`, no
`crit` (no extension is understood, RFC 7515 §4.1.11) and no `cty` that names a nested JWT
(RFC 7519 §7.2 step 8), the signature is the base64url HMAC-SHA256 of `<header>.<payload>` under
the secret (compared as text, like the `jws` library does, in constant time), and the payload is
a JSON object whose `exp` is a number greater than the current time, whose `nbf`, if present, is
not, and that has no `aud` (the server has no name to find in one, RFC 7519 §4.1.3). Then `sub`
must be a string holding a positive decimal integer and `username` a string, else the payload is
rejected.
-/
namespace Feed.Jwt
open Json

inductive Result where
  /-- signature, algorithm, expiry or encoding is wrong -/
  | invalid
  /-- a valid token whose `sub` or `username` is not what the API needs -/
  | badPayload
  | ok (uid : Nat) (username : ByteArray)
  deriving Inhabited

/-- The 6-bit value of a base64url character, or 64 for any other byte. -/
def b64Val (c : UInt8) : UInt8 :=
  if 0x41 ≤ c && c ≤ 0x5a then c - 0x41
  else if 0x61 ≤ c && c ≤ 0x7a then c - 0x61 + 26
  else if 0x30 ≤ c && c ≤ 0x39 then c - 0x30 + 52
  else if c == 0x2d then 62
  else if c == 0x5f then 63
  else 64

/-- Decode base64url text `a[lo, hi)`: `none` if a byte is not a base64url character (`=` is
not: no padding), the length is 1 mod 4, or the bits after the last whole byte are not zero
(RFC 4648 §3.5). So the one text that decodes to some bytes is the one `b64Encode` writes. -/
@[extern "feed_b64_decode"]
def b64Decode (a : @& ByteArray) (lo hi : @& Nat) : Option ByteArray :=
  let hi := min hi a.size
  if (hi - lo) % 4 == 1 then none
  else go lo (hi - lo) 0 0 (ByteArray.emptyWithCapacity ((hi - lo) * 3 / 4 + 3))
where
  /-- `acc` holds `nbits` (< 8) pending bits, which must be zero at the end -/
  go (i : Nat) : Nat → UInt32 → UInt32 → ByteArray → Option ByteArray
    | 0, acc, _, out => if acc == 0 then some out else none
    | f + 1, acc, nbits, out =>
      let v := b64Val (a.get! i)
      if v == 64 then none else
        let acc := (acc <<< 6) ||| v.toUInt32
        let nbits := nbits + 6
        if nbits ≥ 8 then
          let nb := nbits - 8
          go (i + 1) f (acc &&& ((1 <<< nb) - 1)) nb (out.push (acc >>> nb).toUInt8)
        else go (i + 1) f acc nbits out

def b64Char (v : UInt32) : UInt8 :=
  if v < 26 then (0x41 + v).toUInt8 else if v < 52 then (0x61 + v - 26).toUInt8
  else if v < 62 then (0x30 + v - 52).toUInt8 else if v == 62 then 0x2d else 0x5f

/-- base64url encoding without padding. -/
@[extern "feed_b64_encode"]
def b64Encode (d : @& ByteArray) : ByteArray :=
  go 0 (d.size / 3 + 1) (ByteArray.emptyWithCapacity (d.size * 4 / 3 + 4))
where
  go (i : Nat) : Nat → ByteArray → ByteArray
    | 0, out => out
    | f + 1, out =>
      if i + 3 ≤ d.size then
        let n := (d.get! i).toUInt32 <<< 16 ||| (d.get! (i + 1)).toUInt32 <<< 8 ||| (d.get! (i + 2)).toUInt32
        go (i + 3) f ((((out.push (b64Char (n >>> 18))).push (b64Char (n >>> 12 &&& 63))).push (b64Char (n >>> 6 &&& 63))).push (b64Char (n &&& 63)))
      else if i + 2 == d.size then
        let n := (d.get! i).toUInt32 <<< 8 ||| (d.get! (i + 1)).toUInt32
        ((out.push (b64Char (n >>> 10))).push (b64Char (n >>> 4 &&& 63))).push (b64Char ((n &&& 15) <<< 2))
      else if i + 1 == d.size then
        let n := (d.get! i).toUInt32
        (out.push (b64Char (n >>> 2))).push (b64Char ((n &&& 3) <<< 4))
      else out

/-- Constant-time equality of `x` and `a[lo, hi)`. -/
def ctEq (x : ByteArray) (a : ByteArray) (lo hi : Nat) : Bool :=
  hi - lo == x.size && go 0 x.size 0 == 0
where
  go (k : Nat) : Nat → UInt8 → UInt8
    | 0, acc => acc
    | f + 1, acc => go (k + 1) f (acc ||| (x.get! k ^^^ a.get! (lo + k)))

def keyAlg : ByteArray := "alg".toUTF8
def keyCrit : ByteArray := "crit".toUTF8
def keyCty : ByteArray := "cty".toUTF8
def keyExp : ByteArray := "exp".toUTF8
def keyNbf : ByteArray := "nbf".toUTF8
def keySub : ByteArray := "sub".toUTF8
def keyUsername : ByteArray := "username".toUTF8
def keyAud : ByteArray := "aud".toUTF8
def hs256 : ByteArray := "HS256".toUTF8
def ctyJwt : ByteArray := "jwt".toUTF8
def ctyAppJwt : ByteArray := "application/jwt".toUTF8

/-- Whether `s` is `lit` (lowercase), ignoring ASCII case. -/
def eqLower (s lit : ByteArray) : Bool :=
  s.size == lit.size && go 0 lit.size
where
  go (k : Nat) : Nat → Bool
    | 0 => true
    | f + 1 =>
      let b := s.get! k
      (if 0x41 ≤ b && b ≤ 0x5a then b + 32 else b) == lit.get! k && go (k + 1) f

/-- Whether a `cty` value names a nested JWT: `JWT` or `application/jwt`, in any ASCII case (a
media type, with `application/` implied when there is no `/`, RFC 7515 §4.1.10). -/
def nestedCty (s : ByteArray) : Bool := eqLower s ctyJwt || eqLower s ctyAppJwt

/-- Whether the decoded bytes are a positive decimal integer without sign or leading zero, and
its value. -/
def positiveInt (s : ByteArray) : Option Nat :=
  if s.size == 0 || s.size > 18 || s.get! 0 == 0x30 then none
  else go 0 s.size 0
where
  go (i : Nat) : Nat → Nat → Option Nat
    | 0, acc => some acc
    | f + 1, acc =>
      let c := s.get! i
      if isDigit c then go (i + 1) f (acc * 10 + (c - 0x30).toNat) else none

/-- Verify the token `a[lo, hi)` at time `now` (seconds). -/
def verify (key : Hmac.Key) (now : Nat) (a : ByteArray) (lo hi : Nat) : Result :=
  let hi := min hi a.size
  let d1 := Bytes.findByte a 0x2e lo hi
  let d2 := Bytes.findByte a 0x2e (d1 + 1) hi
  if d1 ≥ hi || d2 ≥ hi || Bytes.findByte a 0x2e (d2 + 1) hi != hi then .invalid
  else
  -- signature over "<header>.<payload>", compared as base64url text
  if !ctEq (b64Encode (Hmac.mac key a lo d2)) a (d2 + 1) hi then .invalid
  else
  match b64Decode a lo d1, b64Decode a (d1 + 1) d2 with
  | some h, some p =>
    match parseTop h 0 h.size #[keyAlg, keyCrit, keyCty], parseTop p 0 p.size #[keyExp, keyNbf, keySub, keyUsername, keyAud] with
    | .object hf, .object pf =>
      let alg := hf[0]!
      let cty := hf[2]!
      if alg.kind != .str || decodeString h alg.lo alg.hi != hs256 then .invalid
      else if hf[1]!.kind != .absent then .invalid
      else if cty.kind == .str && nestedCty (decodeString h cty.lo cty.hi) then .invalid
      else
      let exp := pf[0]!
      let nbf := pf[1]!
      if exp.kind != .num || !numGt p exp.lo exp.hi now then .invalid
      else if nbf.kind != .absent && (nbf.kind != .num || numGt p nbf.lo nbf.hi now) then .invalid
      -- `aud` before `sub` and `username`: a token for another audience is invalid, whatever its payload
      else if pf[4]!.kind != .absent then .invalid
      else
      let sub := pf[2]!
      let user := pf[3]!
      if sub.kind != .str || user.kind != .str then .badPayload
      else match positiveInt (decodeString p sub.lo sub.hi) with
        | none => .badPayload
        | some uid => .ok uid (decodeString p user.lo user.hi)
    | _, _ => .invalid
  | _, _ => .invalid

end Feed.Jwt
