/-!
# Byte-level leaves

Generic byte operations (append, escape, search); nothing in this file knows the API. Each one
marked `@[extern]` is the specification of a small C function in `runtime/leaves.c`: the Lean
body is what proofs reason about, `@[extern]` makes compiled code call the C version. The others
run as compiled Lean, though no request reaches them: only the Lean bodies of other leaves lead
to them, and the server replaces those by C (`decide`'s `clear` of an empty buffer compiles to the
empty array).
-/
namespace Feed

/-- The bytes `a[lo, hi)`, with both ends clamped to the array. -/
def slice (a : ByteArray) (lo hi : Nat) : List UInt8 := (a.data.toList.drop lo).take (hi - lo)

/-- A lowercase hexadecimal digit. -/
def hexDigit (n : UInt8) : UInt8 := if n < 10 then 48 + n else 87 + n

/-- How `JSON.stringify` writes one byte of a UTF-8 string: `"` `\` and the control characters
are escaped (with the short forms where JSON has them), every other byte is copied. -/
def escByte (b : UInt8) : List UInt8 :=
  if b == 0x22 then [0x5c, 0x22]
  else if b == 0x5c then [0x5c, 0x5c]
  else if b == 0x08 then [0x5c, 0x62]
  else if b == 0x0c then [0x5c, 0x66]
  else if b == 0x0a then [0x5c, 0x6e]
  else if b == 0x0d then [0x5c, 0x72]
  else if b == 0x09 then [0x5c, 0x74]
  else if b < 0x20 then [0x5c, 0x75, 0x30, 0x30, hexDigit (b >>> 4), hexDigit (b &&& 15)]
  else [b]

/-- The JSON string escape of a list of bytes. -/
def escape (l : List UInt8) : List UInt8 := l.flatMap escByte

namespace Bytes

/-- `out` followed by the escape of `src[lo, hi)`. -/
@[extern "feed_append_esc"]
def appendEsc (out : ByteArray) (src : @& ByteArray) (lo hi : @& Nat) : ByteArray :=
  out ++ ⟨(escape (slice src lo hi)).toArray⟩

/-- `out` followed by the decimal digits of `n`. -/
@[extern "feed_append_nat"]
def appendNat (out : ByteArray) (n : @& Nat) : ByteArray :=
  out ++ (toString n).toUTF8

/-- `out` followed by `lit` and the escape of `src[lo, hi)`. -/
def appendLitEsc (out : ByteArray) (lit src : @& ByteArray) (lo hi : @& Nat) : ByteArray :=
  out ++ lit ++ ⟨(escape (slice src lo hi)).toArray⟩

/-- `out` followed by `lit` and the decimal digits of `n`. -/
def appendLitNat (out : ByteArray) (lit : @& ByteArray) (n : @& Nat) : ByteArray :=
  out ++ lit ++ (toString n).toUTF8

/-- `out` followed by `src[lo, hi)`. -/
def appendSlice (out : ByteArray) (src : @& ByteArray) (lo hi : @& Nat) : ByteArray :=
  out ++ ⟨(slice src lo hi).toArray⟩

/-- `out` followed by `src`. -/
@[extern "feed_append_all"]
def appendAll (out : ByteArray) (src : @& ByteArray) : ByteArray :=
  out ++ src

/-- The first `i` in `[lo, min hi a.size)` with `a[i] = b`, else `min hi a.size`. -/
@[extern "feed_find_byte"]
def findByte (a : @& ByteArray) (b : UInt8) (lo hi : @& Nat) : Nat :=
  go lo (min hi a.size - lo)
where
  go (i : Nat) : Nat → Nat
    | 0 => min hi a.size
    | fuel + 1 => if a.get! i == b then i else go (i + 1) fuel

/-- The first `i ≥ lo` with `i + 4 ≤ min hi a.size` where `a[i, i+4)` is `\r\n\r\n`, else
`min hi a.size`: the end of an HTTP head. -/
def findHeadEnd (a : @& ByteArray) (lo hi : @& Nat) : Nat :=
  go lo (min hi a.size + 1 - lo)
where
  go (i : Nat) : Nat → Nat
    | 0 => min hi a.size
    | fuel + 1 =>
      if i + 4 ≤ min hi a.size then
        if a.get! i == 13 && a.get! (i + 1) == 10 && a.get! (i + 2) == 13 && a.get! (i + 3) == 10 then i
        else go (i + 1) fuel
      else min hi a.size

/-- The empty array, in place of a scratch buffer (the C of `feedFromPage` keeps the buffer's
allocation for reuse when it can). -/
def clear (_a : ByteArray) : ByteArray := ByteArray.empty

end Bytes
end Feed
