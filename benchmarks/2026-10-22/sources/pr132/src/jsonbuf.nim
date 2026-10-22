## Byte-level JSON writing and minimal request-body parsing.
##
## parseBody has a direct scanner for the canonical `{"body":"..."}` request
## shape and falls back to std/json for everything else, so non-canonical but
## valid JSON keeps std/json's exact semantics. The serializer below writes the
## bytes directly into the caller's buffer so a hot response never builds an
## intermediate per-element string.
import std/[json, bitops]
import ./scan_simd
useSimdHeader()

const HexDigits = "0123456789abcdef"

## Characters that a JSON string must escape. Everything outside this set is
## copied in one run, so ordinary text costs one append per run instead of one
## per byte.
const Escaped = block:
  var s: set[char]
  s.incl '"'
  s.incl '\\'
  for i in 0 ..< 0x20:
    s.incl char(i)
  s

proc addRaw(buf: var string, p: ptr UncheckedArray[char],
            first, last: int) {.inline.} =
  ## Bulk append of the inclusive raw range `p[first .. last]`; the copy source
  ## is a C pointer, so no intermediate Nim string is built.
  let n = last - first + 1
  if n <= 0:
    return
  let base = buf.len
  buf.setLen(base + n)
  copyMem(addr buf[base], addr p[first], n)

## The scanner is selected at compile time: SSE2 on x86_64, NEON on ARM64,
## scalar elsewhere. It finds a clean 16-byte run in one pass; the caller copies
## the run in bulk and only handles the trigger bytes scalar.

proc addEscape(buf: var string, c: char) {.inline.} =
  ## Append the JSON escape for `c`, which must be a member of `Escaped`.
  case c
  of '"':  buf.add "\\\""
  of '\\': buf.add "\\\\"
  of '\b': buf.add "\\b"
  of '\f': buf.add "\\f"
  of '\n': buf.add "\\n"
  of '\r': buf.add "\\r"
  of '\t': buf.add "\\t"
  else:
    let o = c.ord
    buf.add "\\u00"
    buf.add HexDigits[(o shr 4) and 0xF]
    buf.add HexDigits[o and 0xF]

proc addEscapedRaw*(buf: var string, p: ptr UncheckedArray[char], n: int) =
  ## Append the `n` bytes at `p` as the *contents* of a JSON string (no
  ## surrounding quotes). This is the one escaper implementation: it reads the
  ## source in place, so callers that hold column text (valid only until the
  ## next step/reset) never copy it into a temporary string first.
  ##
  ## Clean runs are found 16 bytes at a time with the architecture-selected
  ## scanner, then copied in one bulk append; only the final < 16 bytes and the
  ## bytes following each trigger are scanned scalar. The escape sequences are
  ## byte-for-byte the canonical JSON escapes.
  var runStart = 0
  var i = 0
  if n >= 16:
    let vecEnd = n - 16
    while i <= vecEnd:
      let mask = escapeMask16(addr p[i])
      if mask == 0:
        i += 16
        continue
      let hit = i + firstHit(mask)
      if hit > runStart:
        buf.addRaw(p, runStart, hit - 1)
      buf.addEscape p[hit]
      runStart = hit + 1
      i = hit + 1
  while i < n:
    let c = p[i]
    if c in Escaped:
      if i > runStart:
        buf.addRaw(p, runStart, i - 1)
      buf.addEscape c
      runStart = i + 1
    inc i
  if n > runStart:
    buf.addRaw(p, runStart, n - 1)

proc addEscaped*(buf: var string, s: string) =
  ## Append `s` as the contents of a JSON string; delegates to the raw-span
  ## escaper so there is exactly one escaping implementation.
  if s.len > 0:
    addEscapedRaw(buf, cast[ptr UncheckedArray[char]](unsafeAddr s[0]), s.len)

proc addJStr*(buf: var string, s: string) =
  ## Append `s` as a complete JSON string, including both quotes. The contents
  ## go through `addEscaped`, so callers never need to pre-escape wire text.
  buf.add '"'
  buf.addEscaped s
  buf.add '"'

## Two decimal digits per byte pair, indexed by `value * 2`. Converting a
## magnitude in 2-digit chunks halves the division count of a per-digit loop
## while writing straight into the destination buffer.
const DigitPairs = block:
  var s: array[200, char]
  for i in 0 ..< 100:
    s[i * 2] = char(ord('0') + i div 10)
    s[i * 2 + 1] = char(ord('0') + i mod 10)
  s

const Pow10: array[20, uint64] = [
  1'u64, 10'u64, 100'u64, 1_000'u64, 10_000'u64,
  100_000'u64, 1_000_000'u64, 10_000_000'u64, 100_000_000'u64,
  1_000_000_000'u64, 10_000_000_000'u64, 100_000_000_000'u64,
  1_000_000_000_000'u64, 10_000_000_000_000'u64,
  100_000_000_000_000'u64, 1_000_000_000_000_000'u64,
  10_000_000_000_000_000'u64, 100_000_000_000_000_000'u64,
  1_000_000_000_000_000_000'u64, 10_000_000_000_000_000_000'u64]

proc u64Digits*(v: uint64): int {.inline.} =
  ## Decimal digit count of `v` without a division loop. `bits * 1233 >> 12`
  ## is the usual bit-length -> digit-count estimate; at most one correction
  ## against the exact power of ten is needed for 64-bit values.
  if v == 0: return 1
  let bits = 64 - countLeadingZeroBits(v)
  result = ((bits * 1233) shr 12) + 1
  if result > 1 and v < Pow10[result - 1]:
    dec result
  elif result < 20 and v >= Pow10[result]:
    inc result

proc putU64*(dst: ptr UncheckedArray[char]; v: uint64): int {.inline.} =
  ## Write the decimal form of `v` at `dst` and return the digit count. The
  ## caller must have reserved `u64Digits(v)` bytes. Digits are emitted from the
  ## end in two-byte chunks via `DigitPairs`, then the front chunk (if any).
  let nd = u64Digits(v)
  var pos = nd
  var m = v
  if m == 0:
    dst[0] = '0'
  else:
    while m >= 100:
      let pair = int(m mod 100) * 2
      pos -= 2
      dst[pos] = DigitPairs[pair]
      dst[pos + 1] = DigitPairs[pair + 1]
      m = m div 100
    if m >= 10:
      let pair = int(m) * 2
      pos -= 2
      dst[pos] = DigitPairs[pair]
      dst[pos + 1] = DigitPairs[pair + 1]
    else:
      dec pos
      dst[pos] = char(ord('0') + int(m))
  nd

proc addJInt*(buf: var string, v: int64) =
  ## Append the decimal form of `v` by writing the digits straight into `buf`;
  ## no `$v` temp string. The magnitude is taken through uint64 so int64.low
  ## (whose negation overflows int64) still prints correctly.
  let neg = v < 0
  let mag =
    if neg: uint64(-(v + 1)) + 1'u64
    else:   uint64(v)
  let nd = u64Digits(mag)
  let base = buf.len
  buf.setLen(base + nd + (if neg: 1 else: 0))
  var pos = base
  if neg:
    buf[pos] = '-'
    inc pos
  discard putU64(cast[ptr UncheckedArray[char]](addr buf[pos]), mag)

type BodyKind* = enum
  ## Classification returned by `parseBody`; only `bkOk` carries a usable body.
  bkOk        ## valid JSON object with a string `body` member
  bkMalformed ## input is not valid JSON
  bkRequired  ## valid JSON, but no string `body` member

proc hex4(raw: string, i: var int): int =
  ## Parse four hex digits at `i`; advance `i` on success. Returns -1 when the
  ## input ends first or a byte is not a hex digit. A valid `\u0000` returns 0.
  if i + 4 > raw.len:
    return -1
  var v = 0
  for k in 0 ..< 4:
    let c = raw[i + k]
    let d =
      case c
      of '0' .. '9': ord(c) - ord('0')
      of 'a' .. 'f': ord(c) - ord('a') + 10
      of 'A' .. 'F': ord(c) - ord('A') + 10
      else: return -1
    v = (v shl 4) or d
  i += 4
  v

proc parseCanonicalBody*(raw: string, body: var string): bool =
  ## Fast path for the canonical request body: optional JSON whitespace, `{`,
  ## `"body"`, `:`, a JSON string, `}`, and end of input. Returns true and
  ## decodes the string into `body` (sized once to the raw input, so the value
  ## costs a single allocation) when the whole input matches. Anything else -
  ## extra/duplicate keys, comments, trailing commas, unknown escapes, raw
  ## control bytes, lone or malformed surrogates, trailing data - returns false
  ## so the caller can run the std/json path and keep its exact semantics.
  const Ws = {' ', '\t', '\n', '\r'}
  template skipWs() =
    while i < n and raw[i] in Ws: inc i
  template putRune(cp: int) =
    ## Same UTF-8 bytes as std/unicode.toUTF8 for 0 .. 0x10FFFF.
    if cp <= 0x7F:
      body[o] = char(cp)
      inc o
    elif cp <= 0x7FF:
      body[o] = char(0xC0 or (cp shr 6))
      body[o + 1] = char(0x80 or (cp and 0x3F))
      o += 2
    elif cp <= 0xFFFF:
      body[o] = char(0xE0 or (cp shr 12))
      body[o + 1] = char(0x80 or ((cp shr 6) and 0x3F))
      body[o + 2] = char(0x80 or (cp and 0x3F))
      o += 3
    else:
      body[o] = char(0xF0 or (cp shr 18))
      body[o + 1] = char(0x80 or ((cp shr 12) and 0x3F))
      body[o + 2] = char(0x80 or ((cp shr 6) and 0x3F))
      body[o + 3] = char(0x80 or (cp and 0x3F))
      o += 4

  let n = raw.len
  var i = 0
  skipWs()
  if i >= n or raw[i] != '{': return false
  inc i
  skipWs()
  if i + 6 > n: return false
  if raw[i] != '"' or raw[i+1] != 'b' or raw[i+2] != 'o' or
     raw[i+3] != 'd' or raw[i+4] != 'y' or raw[i+5] != '"':
    return false
  i += 6
  skipWs()
  if i >= n or raw[i] != ':': return false
  inc i
  skipWs()
  if i >= n or raw[i] != '"': return false
  inc i

  let start = i
  body.setLen(n - start)      # upper bound: every escape decodes to <= its bytes
  var o = 0
  while true:
    if i >= n: return false
    let c = raw[i]
    if c == '"':
      inc i
      break
    elif c == '\\':
      inc i
      if i >= n: return false
      case raw[i]
      of '"':  body[o] = '"';  inc o; inc i
      of '\\': body[o] = '\\'; inc o; inc i
      of '/':  body[o] = '/';  inc o; inc i
      of 'b':  body[o] = '\b'; inc o; inc i
      of 'f':  body[o] = '\f'; inc o; inc i
      of 'n':  body[o] = '\n'; inc o; inc i
      of 'r':  body[o] = '\r'; inc o; inc i
      of 't':  body[o] = '\t'; inc o; inc i
      of 'u':
        inc i
        var cp = hex4(raw, i)
        if cp < 0: return false
        if cp >= 0xD800 and cp <= 0xDBFF:
          # std/json requires the immediately following \uDC00..\uDFFF.
          if i + 1 >= n or raw[i] != '\\' or raw[i+1] != 'u': return false
          i += 2
          let lo = hex4(raw, i)
          if lo < 0xDC00 or lo > 0xDFFF: return false
          cp = 0x10000 + ((cp - 0xD800) shl 10) + (lo - 0xDC00)
          putRune(cp)
        elif cp >= 0xDC00 and cp <= 0xDFFF:
          # std/json encodes a lone low surrogate as 3 bytes; let it.
          return false
        else:
          putRune(cp)
      else:
        return false
    elif c.ord < 0x20:
      # std/json passes raw control bytes through; do not guess at them here.
      return false
    else:
      body[o] = c
      inc o
      inc i
  body.setLen(o)
  skipWs()
  if i >= n or raw[i] != '}': return false
  inc i
  skipWs()
  i == n

proc parseBody*(raw: string): tuple[kind: BodyKind, body: string] =
  ## Parse the request body without changing the frozen wire semantics.
  ##
  ## The canonical `{"body":"..."}` shape is handled by the in-place scanner;
  ## every other valid JSON document is parsed with std/json, so duplicate keys,
  ## comments, trailing data and number/string edge cases keep std/json's exact
  ## verdict. The returned body is decoded but untrimmed; length and emptiness
  ## checks belong to the API layer.
  if parseCanonicalBody(raw, result.body):
    result.kind = bkOk
    return result
  var node: JsonNode
  try:
    node = parseJson(raw)
  except CatchableError:
    return (bkMalformed, "")
  if node.kind != JObject or not node.hasKey("body"):
    return (bkRequired, "")
  let b = node["body"]
  if b.kind != JString:
    return (bkRequired, "")
  (bkOk, b.getStr)
