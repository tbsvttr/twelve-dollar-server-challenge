import Feed.Bytes

/-!
# SHA-256 and HMAC-SHA256 (FIPS 180-4, RFC 2104)

Plain Lean on `UInt32`. The message schedule is a rolling window of sixteen words passed as
arguments, so the compiled loop keeps everything in registers and allocates nothing.
HMAC's inner and outer key blocks are compressed once per key (`Hmac.Key`); that is the key
schedule, every message is still hashed in full. `Feed/Proofs/Sha256.lean` proves `hash` and
`Hmac.mac` equal to FIPS 180-4 and RFC 2104 as `Feed/Spec/Sha256.lean` writes them.
-/
namespace Feed.Sha256

structure State where
  a : UInt32
  b : UInt32
  c : UInt32
  d : UInt32
  e : UInt32
  f : UInt32
  g : UInt32
  h : UInt32
  deriving Inhabited, BEq, Repr

def init : State :=
  ⟨0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19⟩

def K : Array UInt32 := #[
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2]

@[inline] def rotr (x n : UInt32) : UInt32 := (x >>> n) ||| (x <<< (32 - n))
@[inline] def ch (x y z : UInt32) : UInt32 := (x &&& y) ^^^ (~~~x &&& z)
@[inline] def maj (x y z : UInt32) : UInt32 := (x &&& y) ^^^ (x &&& z) ^^^ (y &&& z)
@[inline] def bsig0 (x : UInt32) : UInt32 := rotr x 2 ^^^ rotr x 13 ^^^ rotr x 22
@[inline] def bsig1 (x : UInt32) : UInt32 := rotr x 6 ^^^ rotr x 11 ^^^ rotr x 25
@[inline] def ssig0 (x : UInt32) : UInt32 := rotr x 7 ^^^ rotr x 18 ^^^ (x >>> 3)
@[inline] def ssig1 (x : UInt32) : UInt32 := rotr x 17 ^^^ rotr x 19 ^^^ (x >>> 10)

/-- The big-endian word at byte offset `i`. -/
@[inline] def word (m : ByteArray) (i : Nat) : UInt32 :=
  (m.get! i).toUInt32 <<< 24 ||| (m.get! (i + 1)).toUInt32 <<< 16 ||| (m.get! (i + 2)).toUInt32 <<< 8 ||| (m.get! (i + 3)).toUInt32

/-- Rounds `t .. 63`. `w0` is the schedule word of round `t`, `w1 .. w15` the next fifteen. -/
def rounds (t : Nat) (a b c d e f g h : UInt32)
    (w0 w1 w2 w3 w4 w5 w6 w7 w8 w9 w10 w11 w12 w13 w14 w15 : UInt32) : State :=
  if t < 64 then
    let t1 := h + bsig1 e + ch e f g + K[t]! + w0
    let t2 := bsig0 a + maj a b c
    let wn := ssig1 w14 + w9 + ssig0 w1 + w0
    rounds (t + 1) (t1 + t2) a b c (d + t1) e f g w1 w2 w3 w4 w5 w6 w7 w8 w9 w10 w11 w12 w13 w14 w15 wn
  else ⟨a, b, c, d, e, f, g, h⟩
termination_by 64 - t

/-- The compression function on the block of sixteen big-endian words `w0 .. w15`. -/
@[inline] def compressW (s : State) (w0 w1 w2 w3 w4 w5 w6 w7 w8 w9 w10 w11 w12 w13 w14 w15 : UInt32) : State :=
  let r := rounds 0 s.a s.b s.c s.d s.e s.f s.g s.h w0 w1 w2 w3 w4 w5 w6 w7 w8 w9 w10 w11 w12 w13 w14 w15
  ⟨s.a + r.a, s.b + r.b, s.c + r.c, s.d + r.d, s.e + r.e, s.f + r.f, s.g + r.g, s.h + r.h⟩

/-- The compression function on the 64-byte block at offset `i` of `m`. -/
def compress (s : State) (m : ByteArray) (i : Nat) : State :=
  compressW s (word m i) (word m (i + 4)) (word m (i + 8)) (word m (i + 12)) (word m (i + 16)) (word m (i + 20))
    (word m (i + 24)) (word m (i + 28)) (word m (i + 32)) (word m (i + 36)) (word m (i + 40))
    (word m (i + 44)) (word m (i + 48)) (word m (i + 52)) (word m (i + 56)) (word m (i + 60))

/-- Compress the full blocks of `m[lo, lo + 64 k)` for `k` blocks. -/
def blocks (s : State) (m : ByteArray) (lo : Nat) : Nat → State
  | 0 => s
  | k + 1 => blocks (compress s m lo) m (lo + 64) k

/-- Byte `j` of the padded tail of a message whose last bytes are `m[tl, hi)`: those bytes, then
0x80, then zeros, and in the last eight of the `len` bytes the big-endian bit length `bits`. -/
@[inline] def padByte (m : ByteArray) (tl hi len : Nat) (bits : UInt64) (j : Nat) : UInt8 :=
  if tl + j < hi then m.get! (tl + j)
  else if tl + j == hi then 0x80
  else if j + 8 < len then 0
  else (bits >>> ((len - 1 - j) * 8).toUInt64).toUInt8

@[inline] def padWord (m : ByteArray) (tl hi len : Nat) (bits : UInt64) (j : Nat) : UInt32 :=
  (padByte m tl hi len bits j).toUInt32 <<< 24 ||| (padByte m tl hi len bits (j + 1)).toUInt32 <<< 16 |||
  (padByte m tl hi len bits (j + 2)).toUInt32 <<< 8 ||| (padByte m tl hi len bits (j + 3)).toUInt32

/-- Compress the padded tail block at offset `o` (0 or 64) of the `len`-byte tail. -/
def tailBlock (s : State) (m : ByteArray) (tl hi len : Nat) (bits : UInt64) (o : Nat) : State :=
  let w := padWord m tl hi len bits
  compressW s (w o) (w (o + 4)) (w (o + 8)) (w (o + 12)) (w (o + 16)) (w (o + 20)) (w (o + 24)) (w (o + 28))
    (w (o + 32)) (w (o + 36)) (w (o + 40)) (w (o + 44)) (w (o + 48)) (w (o + 52)) (w (o + 56)) (w (o + 60))

/-- Append the big-endian bytes of a word. -/
def pushWord (out : ByteArray) (w : UInt32) : ByteArray :=
  (((out.push (w >>> 24).toUInt8).push (w >>> 16).toUInt8).push (w >>> 8).toUInt8).push w.toUInt8

def digest (s : State) : ByteArray :=
  let o := ByteArray.emptyWithCapacity 32
  pushWord (pushWord (pushWord (pushWord (pushWord (pushWord (pushWord (pushWord o s.a) s.b) s.c) s.d) s.e) s.f) s.g) s.h

/-- Finish hashing `m[lo, hi)` from state `s`, where `pre` bytes (a multiple of 64) were already
compressed into `s`: the remaining full blocks, then the padded tail (the last bytes, 0x80, zeros
to 56 mod 64, the 64-bit big-endian bit length), read in place. `hi` is clamped to the array and
`lo` to `hi`, as `slice` reads a range: one given backwards is empty. -/
def finish (s : State) (pre : Nat) (m : ByteArray) (lo hi : Nat) : State :=
  let hi := min hi m.size
  let lo := min lo hi
  let n := hi - lo
  let full := n / 64
  let s := blocks s m lo full
  let tl := lo + full * 64
  let bits := ((pre + n) * 8).toUInt64
  if hi - tl < 56 then tailBlock s m tl hi 64 bits 0
  else tailBlock (tailBlock s m tl hi 128 bits 0) m tl hi 128 bits 64

/-- SHA-256 of `m[lo, hi)`. -/
def hashSlice (m : ByteArray) (lo hi : Nat) : ByteArray := digest (finish init 0 m lo hi)

def hash (m : ByteArray) : ByteArray := hashSlice m 0 m.size

/-- `k` zero bytes appended. -/
def pushZeros (out : ByteArray) : Nat → ByteArray
  | 0 => out
  | k + 1 => pushZeros (out.push 0) k

end Feed.Sha256

namespace Feed.Hmac
open Sha256

/-- The states after compressing the inner and outer key blocks. -/
structure Key where
  inner : State
  outer : State
  deriving Inhabited

def Key.of (secret : ByteArray) : Key :=
  let k := if secret.size > 64 then Sha256.hash secret else secret
  let k := pushZeros k (64 - k.size)
  let pad (c : UInt8) : ByteArray := ⟨k.data.map (· ^^^ c)⟩
  ⟨compress init (pad 0x36) 0, compress init (pad 0x5c) 0⟩

/-- HMAC-SHA256(secret, m[lo, hi)). The outer hash's message is the 32-byte inner digest: one
block, the digest's eight words then the padding for 96 bytes (768 bits). -/
@[extern "feed_hmac_mac"]
def mac (key : @& Key) (m : @& ByteArray) (lo hi : @& Nat) : ByteArray :=
  let i := finish key.inner 64 m lo hi
  digest (compressW key.outer i.a i.b i.c i.d i.e i.f i.g i.h 0x80000000 0 0 0 0 0 0 768)

end Feed.Hmac
