/-!
# SHA-256 (FIPS 180-4) and HMAC (RFC 2104), as the standards write them

For messages of whole bytes. Nothing here runs in the server; `Feed/Sha256.lean` is the code
(proved equal to these definitions in `Feed/Proofs/Sha256.lean`), and the token check
(`Feed/Spec/Auth.lean`) is written with `HMAC.hmacSha256`. `Feed/Spec/Sha256Vectors.lean` checks
these definitions on the published test vectors.
-/
namespace Feed.Spec.SHA256

/-- §2.2.2: a word is 32 bits; `+` is addition modulo 2^32, as on `UInt32`. -/
abbrev Word := UInt32

/-- §3.2 (3): `SHR^n(x) = x >> n`. -/
def SHR (n : UInt32) (x : Word) : Word := x >>> n
/-- §3.2 (4): `ROTR^n(x) = (x >> n) ∨ (x << w - n)`. -/
def ROTR (n : UInt32) (x : Word) : Word := (x >>> n) ||| (x <<< (32 - n))

/-- (4.2) -/ def Ch (x y z : Word) : Word := (x &&& y) ^^^ (~~~x &&& z)
/-- (4.3) -/ def Maj (x y z : Word) : Word := (x &&& y) ^^^ (x &&& z) ^^^ (y &&& z)
/-- (4.4) -/ def Sigma0 (x : Word) : Word := ROTR 2 x ^^^ ROTR 13 x ^^^ ROTR 22 x
/-- (4.5) -/ def Sigma1 (x : Word) : Word := ROTR 6 x ^^^ ROTR 11 x ^^^ ROTR 25 x
/-- (4.6) -/ def sigma0 (x : Word) : Word := ROTR 7 x ^^^ ROTR 18 x ^^^ SHR 3 x
/-- (4.7) -/ def sigma1 (x : Word) : Word := ROTR 17 x ^^^ ROTR 19 x ^^^ SHR 10 x

/-- §4.2.2, as printed. -/
def K : List Word := [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2]

/-- Eight words: a hash value `H_0 … H_7`, or the working variables `a … h`. -/
structure Hash where
  (a b c d e f g h : Word)

/-- §5.3.3, as printed. -/
def H0 : Hash :=
  ⟨0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19⟩

/-- §3.1: big-endian: the word whose bytes, most significant first, are `b0 b1 b2 b3`. -/
def be32 (b0 b1 b2 b3 : UInt8) : Word :=
  UInt32.ofNat (b0.toNat * 2^24 + b1.toNat * 2^16 + b2.toNat * 2^8 + b3.toNat)

/-- The four bytes of a word, most significant first. -/
def wordBytes (w : Word) : List UInt8 :=
  [24, 16, 8, 0].map fun s => (w.toNat / 2 ^ s % 256).toUInt8

/-- The 64-bit binary representation of `n` (`n < 2^64`), as eight bytes, most significant first. -/
def be64 (n : Nat) : List UInt8 :=
  [56, 48, 40, 32, 24, 16, 8, 0].map fun s => (n / 2 ^ s % 256).toUInt8

/-- §5.1.1: the smallest non-negative `k` with `ℓ + 1 + k ≡ 448 (mod 512)`. -/
def padZeros (ℓ : Nat) : Nat := (448 + 512 - (ℓ + 1) % 512) % 512

/-- §5.1.1 for a message of whole bytes, `ℓ = 8 · length` bits: the bit `1` and the first seven of
the `k` zero bits are the byte `0x80`; the other `k - 7` zero bits are `(k - 7) / 8` zero bytes;
then the 64-bit block equal to `ℓ`. -/
def pad (M : List UInt8) : List UInt8 :=
  let ℓ := 8 * M.length
  M ++ [0x80] ++ List.replicate ((padZeros ℓ - 7) / 8) 0 ++ be64 ℓ

/-- §5.2.1: `n` blocks of 512 bits (64 bytes), in order. -/
def blocksOf : Nat → List UInt8 → List (List UInt8)
  | 0, _ => []
  | n + 1, P => P.take 64 :: blocksOf n (P.drop 64)

/-- §5.2.1: the padded message as its `N = length / 64` blocks. -/
def blocks (P : List UInt8) : List (List UInt8) := blocksOf (P.length / 64) P

/-- §5.2.1: the sixteen words `M_0 … M_15` of a block: word `j` is bytes `4j … 4j+3`. -/
def words (B : List UInt8) : List Word :=
  (List.range 16).map fun j => be32 (B.getD (4 * j) 0) (B.getD (4 * j + 1) 0) (B.getD (4 * j + 2) 0) (B.getD (4 * j + 3) 0)

/-- §6.2.2 step 1: the message schedule `W_0 … W_63` of the block's words `Mi`. -/
def schedule (Mi : List Word) : List Word :=
  (List.range' 16 48).foldl (fun W t =>
    W ++ [sigma1 (W.getD (t - 2) 0) + W.getD (t - 7) 0 + sigma0 (W.getD (t - 15) 0) + W.getD (t - 16) 0]) Mi

/-- §6.2.2 step 3: round `t` on the working variables. -/
def round (W : List Word) (v : Hash) (t : Nat) : Hash :=
  let T1 := v.h + Sigma1 v.e + Ch v.e v.f v.g + K.getD t 0 + W.getD t 0
  let T2 := Sigma0 v.a + Maj v.a v.b v.c
  { h := v.g, g := v.f, f := v.e, e := v.d + T1, d := v.c, c := v.b, b := v.a, a := T1 + T2 }

/-- §6.2.2 steps 1 to 4: the hash value after one block, from the previous one `H`. -/
def compress (H : Hash) (Mi : List Word) : Hash :=
  let v := (List.range 64).foldl (round (schedule Mi)) H
  ⟨v.a + H.a, v.b + H.b, v.c + H.c, v.d + H.d, v.e + H.e, v.f + H.f, v.g + H.g, v.h + H.h⟩

/-- §6.2: SHA-256 of a message of whole bytes: the blocks of the padded message, from `H0`; the
digest is `H_0 ‖ H_1 ‖ … ‖ H_7`. -/
def sha256 (M : List UInt8) : List UInt8 :=
  let H := (blocks (pad M)).foldl (fun H B => compress H (words B)) H0
  [H.a, H.b, H.c, H.d, H.e, H.f, H.g, H.h].flatMap wordBytes

end Feed.Spec.SHA256

namespace Feed.Spec.HMAC
open Feed.Spec.SHA256

/-- RFC 2104 §2: the block size `B` of SHA-256, in bytes. -/
def B : Nat := 64

/-- RFC 2104 §2 (and §3: "Applications that use keys longer than B bytes will first hash the key
using H"): the key padded with zeros to `B` bytes. -/
def K0 (key : List UInt8) : List UInt8 :=
  let k := if key.length > B then sha256 key else key
  k ++ List.replicate (B - k.length) 0

def ipad : List UInt8 := List.replicate B 0x36
def opad : List UInt8 := List.replicate B 0x5c

/-- Bytewise XOR. -/
def xor (x y : List UInt8) : List UInt8 := List.zipWith (· ^^^ ·) x y

/-- RFC 2104 §2: `H(K XOR opad, H(K XOR ipad, text))`. -/
def hmacSha256 (key text : List UInt8) : List UInt8 :=
  sha256 (xor (K0 key) opad ++ sha256 (xor (K0 key) ipad ++ text))

end Feed.Spec.HMAC
