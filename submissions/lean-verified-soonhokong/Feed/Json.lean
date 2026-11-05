import Feed.Bytes

/-!
# JSON input

A validating JSON parser (RFC 8259) for the two places the API reads JSON: the `POST /posts`
body and the JWT header and payload. It works on a byte range of the request buffer and does not
build a tree: it checks the whole text and records, for a few wanted keys of the top-level
object, the span of the last value with that key (like `JSON.parse`, where a later duplicate key
wins). A text must be UTF-8 (RFC 8259 §8.1): a string holding a byte sequence that is not
well-formed UTF-8 (RFC 3629 §4) makes the text malformed. Strings are decoded only when the
handler needs them.
-/
namespace Feed.Json

/-- The kind of a recorded value. -/
inductive Kind where
  | absent | str | num | other
  deriving Inhabited, DecidableEq, Repr

/-- The last value of one wanted key: its kind and the span of its text. -/
structure Field where
  kind : Kind
  lo : Nat
  hi : Nat
  deriving Inhabited, Repr

@[inline] def byte (a : ByteArray) (i : Nat) : UInt8 := a.get! i

def isWs (b : UInt8) : Bool := b == 0x20 || b == 0x09 || b == 0x0a || b == 0x0d
def isDigit (b : UInt8) : Bool := 0x30 ≤ b && b ≤ 0x39
def isHex (b : UInt8) : Bool := isDigit b || (0x61 ≤ b && b ≤ 0x66) || (0x41 ≤ b && b ≤ 0x46)

/-- Skip whitespace. -/
def skipWs (a : ByteArray) (hi : Nat) (i : Nat) : Nat :=
  go i (hi - i)
where
  go (i : Nat) : Nat → Nat
    | 0 => i
    | f + 1 => if i < hi && isWs (byte a i) then go (i + 1) f else i

/-- The length of the well-formed UTF-8 sequence (RFC 3629 §4) that starts at `i` with a byte
of at least 0x80 and ends before `hi`, or 0. -/
def utf8Len (a : ByteArray) (hi i : Nat) : Nat :=
  let b := byte a i
  let t (k : Nat) (l h : UInt8) : Bool := i + k < hi && l ≤ byte a (i + k) && byte a (i + k) ≤ h
  if 0xc2 ≤ b && b ≤ 0xdf then (if t 1 0x80 0xbf then 2 else 0)
  else if 0xe0 ≤ b && b ≤ 0xef then
    (if t 1 (if b == 0xe0 then 0xa0 else 0x80) (if b == 0xed then 0x9f else 0xbf) && t 2 0x80 0xbf then 3 else 0)
  else if 0xf0 ≤ b && b ≤ 0xf4 then
    (if t 1 (if b == 0xf0 then 0x90 else 0x80) (if b == 0xf4 then 0x8f else 0xbf) && t 2 0x80 0xbf && t 3 0x80 0xbf
     then 4 else 0)
  else 0

/-- `i` is just after the opening quote; the index just after the closing quote. A byte of at
least 0x80 must start a well-formed UTF-8 sequence, which is skipped whole. -/
def scanString (a : ByteArray) (hi : Nat) (i : Nat) : Option Nat :=
  go i (hi - i)
where
  go (i : Nat) : Nat → Option Nat
    | 0 => none
    | f + 1 =>
      if i ≥ hi then none else
      let b := byte a i
      if b == 0x22 then some (i + 1)
      else if b < 0x20 then none
      else if b == 0x5c then
        if i + 1 ≥ hi then none else
        let e := byte a (i + 1)
        if e == 0x22 || e == 0x5c || e == 0x2f || e == 0x62 || e == 0x66 || e == 0x6e || e == 0x72 || e == 0x74 then
          match f with
          | 0 => none
          | f' + 1 => go (i + 2) f'
        else if e == 0x75 then
          if i + 6 ≤ hi && isHex (byte a (i + 2)) && isHex (byte a (i + 3)) && isHex (byte a (i + 4)) && isHex (byte a (i + 5)) then
            match f with
            | 0 | 1 | 2 | 3 | 4 => none
            | f' + 5 => go (i + 6) f'
          else none
        else none
      else if b < 0x80 then go (i + 1) f
      else match utf8Len a hi i, f with
        | 2, f' + 1 => go (i + 2) f'
        | 3, f' + 2 => go (i + 3) f'
        | 4, f' + 3 => go (i + 4) f'
        | _, _ => none

/-- Digits from `i`: the index after the last one. -/
def scanDigits (a : ByteArray) (hi : Nat) (i : Nat) : Nat :=
  go i (hi - i)
where
  go (i : Nat) : Nat → Nat
    | 0 => i
    | f + 1 => if i < hi && isDigit (byte a i) then go (i + 1) f else i

/-- A number starting at `i`: `-? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE] [+-]? [0-9]+)?`. -/
def scanNumber (a : ByteArray) (hi : Nat) (i : Nat) : Option Nat := do
  let i := if i < hi && byte a i == 0x2d then i + 1 else i
  if i ≥ hi then none
  let i ← if byte a i == 0x30 then pure (i + 1)
    else if isDigit (byte a i) then pure (scanDigits a hi i) else none
  let i ← if i < hi && byte a i == 0x2e then
      let j := scanDigits a hi (i + 1)
      if j == i + 1 then none else pure j
    else pure i
  if i < hi && (byte a i == 0x65 || byte a i == 0x45) then
    let k := if i + 1 < hi && (byte a (i + 1) == 0x2b || byte a (i + 1) == 0x2d) then i + 2 else i + 1
    let j := scanDigits a hi k
    if j == k then none else pure j
  else pure i

/-- The literal `lit` at `i`. -/
def scanLit (a : ByteArray) (hi : Nat) (i : Nat) (lit : List UInt8) : Option Nat :=
  match lit with
  | [] => some i
  | c :: cs => if i < hi && byte a i == c then scanLit a hi (i + 1) cs else none

mutual
/-- A value at `i` (after whitespace): the index just after it. `fuel` bounds nesting and length. -/
def scanValue (a : ByteArray) (hi : Nat) (i : Nat) : Nat → Option Nat
  | 0 => none
  | f + 1 =>
    if i ≥ hi then none else
    let b := byte a i
    if b == 0x22 then scanString a hi (i + 1)
    else if b == 0x7b then scanMembers a hi (skipWs a hi (i + 1)) true f
    else if b == 0x5b then scanElems a hi (skipWs a hi (i + 1)) true f
    else if b == 0x74 then scanLit a hi i [0x74, 0x72, 0x75, 0x65]
    else if b == 0x66 then scanLit a hi i [0x66, 0x61, 0x6c, 0x73, 0x65]
    else if b == 0x6e then scanLit a hi i [0x6e, 0x75, 0x6c, 0x6c]
    else scanNumber a hi i

/-- Object members from `i` (whitespace skipped), up to and including `}`. -/
def scanMembers (a : ByteArray) (hi : Nat) (i : Nat) (first : Bool) : Nat → Option Nat
  | 0 => none
  | f + 1 =>
    if i ≥ hi then none
    else if first && byte a i == 0x7d then some (i + 1)
    else if byte a i != 0x22 then none
    else do
      let j ← scanString a hi (i + 1)
      let j := skipWs a hi j
      if j ≥ hi || byte a j != 0x3a then none
      let k ← scanValue a hi (skipWs a hi (j + 1)) f
      let k := skipWs a hi k
      if k ≥ hi then none
      else if byte a k == 0x7d then some (k + 1)
      else if byte a k == 0x2c then scanMembers a hi (skipWs a hi (k + 1)) false f
      else none

/-- Array elements from `i` (whitespace skipped), up to and including `]`. -/
def scanElems (a : ByteArray) (hi : Nat) (i : Nat) (first : Bool) : Nat → Option Nat
  | 0 => none
  | f + 1 =>
    if i ≥ hi then none
    else if first && byte a i == 0x5d then some (i + 1)
    else do
      let k ← scanValue a hi i f
      let k := skipWs a hi k
      if k ≥ hi then none
      else if byte a k == 0x5d then some (k + 1)
      else if byte a k == 0x2c then scanElems a hi (skipWs a hi (k + 1)) false f
      else none
end

/-! ## Decoding strings -/

def hexVal (b : UInt8) : Nat :=
  if isDigit b then (b - 0x30).toNat else if 0x61 ≤ b then (b - 0x61 + 10).toNat else (b - 0x41 + 10).toNat

def hex4 (a : ByteArray) (i : Nat) : Nat :=
  ((hexVal (byte a i) * 16 + hexVal (byte a (i + 1))) * 16 + hexVal (byte a (i + 2))) * 16 + hexVal (byte a (i + 3))

/-- UTF-8 encoding of a code point (surrogates excluded by the caller). -/
def pushUtf8 (out : ByteArray) (c : Nat) : ByteArray :=
  if c < 0x80 then out.push c.toUInt8
  else if c < 0x800 then (out.push (0xc0 + c / 64).toUInt8).push (0x80 + c % 64).toUInt8
  else if c < 0x10000 then ((out.push (0xe0 + c / 4096).toUInt8).push (0x80 + c / 64 % 64).toUInt8).push (0x80 + c % 64).toUInt8
  else (((out.push (0xf0 + c / 262144).toUInt8).push (0x80 + c / 4096 % 64).toUInt8).push (0x80 + c / 64 % 64).toUInt8).push (0x80 + c % 64).toUInt8

/-- Decode the string whose text is `a[lo, hi)` (`lo` at the opening quote, `hi` after the closing
one and clamped to the array; it was validated by `scanString`). Escapes become their characters;
a lone surrogate becomes U+FFFD, as does a byte that is not part of valid UTF-8 (which
`scanString` rejects, so only a range it did not validate has one). The server runs the C version
(`runtime/leaves.c`), which the self-test compares with this definition. -/
@[extern "feed_json_decode_string"]
def decodeString (a : @& ByteArray) (lo hi : @& Nat) : ByteArray :=
  let hi := min hi a.size
  go hi (lo + 1) (hi - lo) (ByteArray.emptyWithCapacity (hi - lo))
where
  go (hi : Nat) (i : Nat) : Nat → ByteArray → ByteArray
    | 0, out => out
    | f + 1, out =>
      if i + 1 ≥ hi then out else
      let b := byte a i
      if b == 0x5c then
        let e := byte a (i + 1)
        if e == 0x75 then
          let c := hex4 a (i + 2)
          if 0xd800 ≤ c && c < 0xdc00 && i + 12 ≤ hi - 1 && byte a (i + 6) == 0x5c && byte a (i + 7) == 0x75 then
            let d := hex4 a (i + 8)
            if 0xdc00 ≤ d && d < 0xe000 then go hi (i + 12) f (pushUtf8 out (0x10000 + (c - 0xd800) * 1024 + (d - 0xdc00)))
            else go hi (i + 6) f (pushUtf8 out 0xfffd)
          else if 0xd800 ≤ c && c < 0xe000 then go hi (i + 6) f (pushUtf8 out 0xfffd)
          else go hi (i + 6) f (pushUtf8 out c)
        else
          let c : UInt8 := if e == 0x62 then 0x08 else if e == 0x66 then 0x0c else if e == 0x6e then 0x0a
            else if e == 0x72 then 0x0d else if e == 0x74 then 0x09 else e
          go hi (i + 2) f (out.push c)
      else if b < 0x80 then go hi (i + 1) f (out.push b)
      else
        -- a UTF-8 sequence: copy it if it is valid, else U+FFFD for its first byte
        let n := if b &&& 0xe0 == 0xc0 then 2 else if b &&& 0xf0 == 0xe0 then 3 else if b &&& 0xf8 == 0xf0 then 4 else 0
        let cont (k : Nat) := k < n → (i + k < hi - 1 && byte a (i + k) &&& 0xc0 == 0x80)
        let ok := n ≥ 2 && cont 1 && (n < 3 || cont 2) && (n < 4 || cont 3)
        if ok then
          let cp := if n == 2 then (b &&& 0x1f).toNat * 64 + (byte a (i + 1) &&& 0x3f).toNat
            else if n == 3 then ((b &&& 0x0f).toNat * 64 + (byte a (i + 1) &&& 0x3f).toNat) * 64 + (byte a (i + 2) &&& 0x3f).toNat
            else (((b &&& 0x07).toNat * 64 + (byte a (i + 1) &&& 0x3f).toNat) * 64 + (byte a (i + 2) &&& 0x3f).toNat) * 64 + (byte a (i + 3) &&& 0x3f).toNat
          let minCp := if n == 2 then 0x80 else if n == 3 then 0x800 else 0x10000
          if cp < minCp || (0xd800 ≤ cp && cp < 0xe000) || cp > 0x10ffff then go hi (i + 1) f (pushUtf8 out 0xfffd)
          else go hi (i + n) f (Bytes.appendSlice out a i (i + n))
        else go hi (i + 1) f (pushUtf8 out 0xfffd)

/-! ## Numbers -/

/-- Whether `a[lo, hi)` is exactly the bytes of `key`. -/
def spanEq (a : ByteArray) (lo hi : Nat) (key : ByteArray) : Bool :=
  hi - lo == key.size && go 0 key.size
where
  go (k : Nat) : Nat → Bool
    | 0 => true
    | f + 1 => byte a (lo + k) == key.get! k && go (k + 1) f

/-- The kind of the value starting at `i`. -/
def kindAt (a : ByteArray) (i : Nat) : Kind :=
  let b := byte a i
  if b == 0x22 then .str else if b == 0x2d || isDigit b then .num else .other

/-- Whether the key whose text (between the quotes) is `a[klo, khi)` is `key`. A key written with
escapes is decoded first. -/
def keyEq (a : ByteArray) (klo khi : Nat) (key : ByteArray) : Bool :=
  if Bytes.findByte a 0x5c klo khi == min khi a.size then spanEq a klo khi key
  else
    let d := decodeString a (klo - 1) (khi + 1)
    d.size == key.size && spanEq d 0 d.size key

/-- Record the value `a[vlo, vhi)` for the wanted key it belongs to (the last one wins). -/
def recordField (a : ByteArray) (klo khi : Nat) (vlo vhi : Nat) (keys : Array ByteArray) (fs : Array Field) : Array Field :=
  go 0 keys.size fs
where
  go (k : Nat) : Nat → Array Field → Array Field
    | 0, fs => fs
    | f + 1, fs =>
      if keyEq a klo khi (keys[k]!) then fs.set! k ⟨kindAt a vlo, vlo, vhi⟩ else go (k + 1) f fs

/-- Members of the top-level object, recording wanted keys. `i` is after `{` and whitespace. -/
def topMembers (a : ByteArray) (hi : Nat) (keys : Array ByteArray) (i : Nat) (first : Bool) (fs : Array Field) :
    Nat → Option (Nat × Array Field)
  | 0 => none
  | f + 1 =>
    if i ≥ hi then none
    else if first && byte a i == 0x7d then some (i + 1, fs)
    else if byte a i != 0x22 then none
    else do
      let j ← scanString a hi (i + 1)
      let klo := i + 1
      let khi := j - 1
      let j := skipWs a hi j
      if j ≥ hi || byte a j != 0x3a then none
      let vlo := skipWs a hi (j + 1)
      let k ← scanValue a hi vlo f
      let fs := recordField a klo khi vlo k keys fs
      let k := skipWs a hi k
      if k ≥ hi then none
      else if byte a k == 0x7d then some (k + 1, fs)
      else if byte a k == 0x2c then topMembers a hi keys (skipWs a hi (k + 1)) false fs f
      else none

/-- What `parseTop` finds in `a[lo, hi)`: no JSON text, a JSON text whose value is not an object,
or an object with the last value of each key in `keys` (absent if none), as `parseTop_spec`
(`Feed/Proofs/JsonValue.lean`) states. -/
inductive Top where
  | malformed
  | notObject
  | object (fields : Array Field)

/-- The server runs the C version (`runtime/leaves.c`), which the self-test compares with this
definition. -/
@[extern "feed_json_parse_top"]
def parseTop (a : @& ByteArray) (lo hi : @& Nat) (keys : @& Array ByteArray) : Top :=
  let hi := min hi a.size
  let i := skipWs a hi lo
  let fuel := hi - lo + 1
  if i < hi && byte a i == 0x7b then
    match topMembers a hi keys (skipWs a hi (i + 1)) true (Array.replicate keys.size ⟨.absent, 0, 0⟩) fuel with
    | none => .malformed
    | some (j, fs) => if skipWs a hi j == hi then .object fs else .malformed
  else
    match scanValue a hi i fuel with
    | none => .malformed
    | some j => if skipWs a hi j == hi then .notObject else .malformed

/-- `m * 10 ^ k`, by repeated multiplication (`Nat.pow` goes through GMP). -/
def mulPow10 (m : Nat) : Nat → Nat
  | 0 => m
  | k + 1 => mulPow10 (m * 10) k

/-- The number of decimal digits of `n` (1 for 0). -/
def numDigits (n : Nat) : Nat := (toString n).length

/-- The value of a validated number text `a[lo, hi)` compared with a natural number `n`: whether
it is strictly greater (what `exp > now` computes on the parsed number in JS, but exact). -/
def numGt (a : ByteArray) (lo hi : Nat) (n : Nat) : Bool :=
  if lo < hi && byte a lo == 0x2d then false   -- negative (or -0): not greater than any natural
  else
    let ie := scanDigits a hi lo
    let intVal := digitsVal lo ie
    let (fracVal, fracLen, j) :=
      if ie < hi && byte a ie == 0x2e then
        let fe := scanDigits a hi (ie + 1)
        (digitsVal (ie + 1) fe, fe - (ie + 1), fe)
      else (0, 0, ie)
    let (expNeg, expVal) :=
      if j < hi && (byte a j == 0x65 || byte a j == 0x45) then
        let neg := j + 1 < hi && byte a (j + 1) == 0x2d
        let k := if j + 1 < hi && (byte a (j + 1) == 0x2b || byte a (j + 1) == 0x2d) then j + 2 else j + 1
        (neg, digitsVal k (scanDigits a hi k))
      else (false, 0)
    -- value = m * 10^e with m = intVal * 10^fracLen + fracVal and e = ±expVal - fracLen
    let m := mulPow10 intVal fracLen + fracVal
    let e : Int := (if expNeg then -(expVal : Int) else expVal) - fracLen
    if m == 0 then false
    else if e ≥ 0 then
      -- 10^e alone exceeds n once e has more digits than n
      if e.toNat > numDigits n then true else mulPow10 m e.toNat > n
    else
      let d := (-e).toNat
      -- m * 10^-d < 1 ≤ n once d exceeds the digits of m (for n ≥ 1); for n = 0 any m > 0 wins
      if d > numDigits m then n == 0 else m > mulPow10 n d
where
  digitsVal (lo hi : Nat) : Nat := go lo (hi - lo) 0
  go (i : Nat) : Nat → Nat → Nat
    | 0, acc => acc
    | f + 1, acc => go (i + 1) f (acc * 10 + (byte a i - 0x30).toNat)

end Feed.Json
