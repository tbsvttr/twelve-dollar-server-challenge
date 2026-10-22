## HS256 JWT verification (stdlib + nimcrypto only).
##
## Contract (frozen):
##   jsInvalid    = malformed token / bad signature / expired / alg != HS256
##   jsBadPayload = signature valid but `sub` is not a positive integer string
##                  or `username` is not a JSON string
##
## Allocation policy: the token is a borrowed span inside the request buffer.
## Header, payload and signature are base64-decoded into a fixed `JwtScratch`
## that is sized from the 16 KiB header cap, the HMAC input is the contiguous
## `header.payload` prefix of that buffer (no concatenation), and the payload is
## scanned in place. The only heap allocation is the final `username` string,
## which is response data rather than a token copy.
import std/[json, times, parseutils]
import nimcrypto
import http

type
  ## Final verification result. A bad signature, malformed token or expired
  ## token is `jsInvalid`; only a verified token with unusable claims is
  ## `jsBadPayload`.
  JwtStatus* = enum
    jsOk
    jsInvalid
    jsBadPayload

  ## Authenticated identity extracted from a verified payload.
  JwtInfo* = object
    userId*: int64      ## `sub`, decoded as a positive int64
    username*: string   ## `username`, decoded from its JSON string

const
  ## Base64 of the largest possible token in a 16 KiB header block is
  ## floor(16384 * 6 / 8) = 12,288 bytes. 12,294 is the fixed ceiling
  ## (the same value as 3/4 of a 16 KiB + 8 B block); the real bound is smaller,
  ## so no allocating fallback is needed or provided.
  JwtScratchCap* = 12_294

  ## Header bytes emitted by the official token generator. Matching them
  ## directly skips the std/json header parse on the hot path.
  Hs256Header* = """{"alg":"HS256","typ":"JWT"}"""

  JsonDepthLimit = 1000  ## bound recursive payload scanning to protect the stack

type
  ## Fixed verification workspace for one token. `decoded` is reused for the
  ## header and then the payload, while `sig` holds the decoded HMAC so the two
  ## never overlap. Both are fixed-size, so verification cannot allocate or grow.
  JwtScratch = object
    decoded: array[JwtScratchCap, char]
    sig: array[32, char]

proc b64Value(c: char): int {.inline.} =
  ## Value 0..63 for a base64 char, accepting BOTH URL-safe (-, _) and
  ## standard (+, /) alphabets. Returns -1 for anything else.
  case c
  of 'A'..'Z': ord(c) - ord('A')
  of 'a'..'z': ord(c) - ord('a') + 26
  of '0'..'9': ord(c) - ord('0') + 52
  of '+', '-': 62
  of '/', '_': 63
  else: -1

proc b64DecodeSpan(src: openArray[char]; s: Span; outBytes: var openArray[char];
                   outLen: var int): bool =
  ## Strict base64/base64url decode without requiring padding. Padding '=' is
  ## tolerated and ignored. Leftover bits must be zero (canonical encoding).
  ## Writes into the caller's fixed buffer and fails if the decoded form does
  ## not fit; no heap fallback by design.
  outLen = 0
  var acc = 0'u32
  var bits = 0
  for i in 0 ..< s.len:
    let c = src[s.off + i]
    if c == '=' or c == '\n' or c == '\r':
      continue
    let v = b64Value(c)
    if v < 0: return false
    acc = (acc shl 6) or uint32(v)
    bits += 6
    if bits >= 8:
      bits -= 8
      if outLen >= outBytes.len: return false
      outBytes[outLen] = char((acc shr bits) and 0xFF'u32)
      inc outLen
  if bits >= 6: return false
  if bits > 0 and (acc and ((1'u32 shl bits) - 1'u32)) != 0'u32:
    return false
  true

proc constantTimeEq32(mac: openArray[byte]; sig: openArray[char]): bool =
  ## XOR-accumulate compare of the fixed 32-byte SHA-256 digest; no early
  ## return inside the loop. A non-32-byte signature is rejected (invalid).
  if sig.len != 32: return false
  var diff = 0'u8
  for i in 0 ..< 32:
    diff = diff or (mac[i] xor byte(sig[i]))
  diff == 0'u8

proc parseHeaderFallback(dec: openArray[char]; n: int): bool =
  ## Non-canonical header (key order/whitespace/extra keys/duplicate alg):
  ## fall back to std/json so the accept semantics stay identical. This path is
  ## never reached by an official token.
  var s = newString(n)
  for i in 0 ..< n:
    s[i] = dec[i]
  var node: JsonNode
  try:
    node = parseJson(s)
  except CatchableError:
    return false
  if node.kind != JObject: return false
  if not node.hasKey("alg"): return false
  if node["alg"].kind != JString or node["alg"].getStr != "HS256": return false
  true

proc headerIsCanonical(dec: openArray[char]; n: int): bool {.inline.} =
  ## Byte-exact fast path for the header emitted by the official generator.
  ## Any other valid header shape (key order, whitespace, extra keys) is left to
  ## `parseHeaderFallback`, so acceptance stays identical to std/json.
  if n != Hs256Header.len: return false
  for i in 0 ..< n:
    if dec[i] != Hs256Header[i]: return false
  true

# ---------------------------------------------------------------------------
# In-place JSON payload scanner with std/json-compatible semantics.
#
# The payload is already valid JSON text in the scratch buffer. The scanner
# mirrors `std/parsejson` (the parser behind `std/json.parseJson`) closely
# enough that every accepted/rejected construct in the reachable surface has the
# same verdict, while extracting `exp`/`sub`/`username` with last-key-wins.

type
  ## Cursor over the decoded payload. The buffer is borrowed from `JwtScratch`;
  ## `err` is sticky so callers can check it once after a recursive descent.
  JsonScan = object
    buf: ptr UncheckedArray[char]
    len: int
    pos: int
    err: bool

  ## JSON categories that matter when extracting `exp`, `sub` and `username`.
  ## Numbers that std/json would keep as a raw string are `vkOther`.
  ValKind = enum vkOther, vkInt, vkFloat, vkString

  ## One scanned value. `i`/`f` are valid only for the matching kind; strings
  ## carry their raw (still escaped) span so the caller can decode or compare it.
  ValInfo = object
    kind: ValKind
    i: int64
    f: float
    sStart: int
    sEnd: int

  ## Captured claim type. `fkOther` means the key was present with an unusable
  ## JSON type; `fkMissing` means it was never seen.
  FieldKind = enum fkMissing, fkInt, fkFloat, fkString, fkOther

  ## Last-key-wins claim state built while scanning the top-level object.
  PayloadState = object
    expKind: FieldKind
    expVal: float
    subKind: FieldKind
    subOk: bool          ## `sub` decoded to a positive int64 digit string
    subVal: int64
    userKind: FieldKind
    userStart: int       ## raw span of the `username` JSON string
    userEnd: int

proc emitChar(outBuf: ptr UncheckedArray[char]; outCap: int;
              outLen: var int; c: char) {.inline.} =
  ## Append one decoded byte when there is room, but always count it. The count
  ## can therefore exceed `outCap`; `scanObject` uses that to recognize a key
  ## longer than its fixed scratch buffer without allocating.
  if outLen < outCap:
    outBuf[outLen] = c
  inc outLen

proc hexValue(c: char): int {.inline.} =
  case c
  of '0'..'9': ord(c) - ord('0')
  of 'a'..'f': ord(c) - ord('a') + 10
  of 'A'..'F': ord(c) - ord('A') + 10
  else: -1

proc parseHex4(js: var JsonScan): int =
  ## 4 hex digits -> UTF-16 code unit; -1 (and js.err) when malformed.
  if js.pos + 4 > js.len:
    js.err = true
    return -1
  var r = 0
  for _ in 0 ..< 4:
    let v = hexValue(js.buf[js.pos])
    if v < 0:
      js.err = true
      return -1
    r = (r shl 4) or v
    inc js.pos
  r

proc emitRune(outBuf: ptr UncheckedArray[char]; outCap: int;
              outLen: var int; r: int) =
  ## UTF-8 encoding identical to `unicode.toUTF8` for the code points a JSON
  ## \u escape can produce (including lone surrogates, which std/json accepts
  ## and encodes as 3 bytes).
  if r <= 0x7F:
    emitChar(outBuf, outCap, outLen, char(r))
  elif r <= 0x7FF:
    emitChar(outBuf, outCap, outLen, char(0xC0 or (r shr 6)))
    emitChar(outBuf, outCap, outLen, char(0x80 or (r and 0x3F)))
  elif r <= 0xFFFF:
    emitChar(outBuf, outCap, outLen, char(0xE0 or (r shr 12)))
    emitChar(outBuf, outCap, outLen, char(0x80 or ((r shr 6) and 0x3F)))
    emitChar(outBuf, outCap, outLen, char(0x80 or (r and 0x3F)))
  else:
    emitChar(outBuf, outCap, outLen, char(0xF0 or (r shr 18)))
    emitChar(outBuf, outCap, outLen, char(0x80 or ((r shr 12) and 0x3F)))
    emitChar(outBuf, outCap, outLen, char(0x80 or ((r shr 6) and 0x3F)))
    emitChar(outBuf, outCap, outLen, char(0x80 or (r and 0x3F)))

proc scString(js: var JsonScan; outBuf: ptr UncheckedArray[char]; outCap: int;
              outLen: var int; rawStart, rawEnd: var int) =
  ## Parse a JSON string starting at the opening quote. Validates exactly like
  ## `std/parsejson` (simple/unknown escapes, \u escapes, surrogate pairs, raw
  ## CR/LF normalisation) and optionally decodes into `outBuf`.
  inc js.pos
  rawStart = js.pos
  outLen = 0
  while true:
    if js.pos >= js.len:
      js.err = true
      return
    let c = js.buf[js.pos]
    if c == '"':
      rawEnd = js.pos
      inc js.pos
      return
    elif c == '\0':
      js.err = true                       # std/json treats a raw NUL as EOF
      return
    elif c == '\\':
      inc js.pos
      if js.pos >= js.len:
        js.err = true
        return
      let e = js.buf[js.pos]
      case e
      of '\\', '"', '\'', '/':
        emitChar(outBuf, outCap, outLen, e)
        inc js.pos
      of 'b':
        emitChar(outBuf, outCap, outLen, '\b')
        inc js.pos
      of 'f':
        emitChar(outBuf, outCap, outLen, '\f')
        inc js.pos
      of 'n':
        emitChar(outBuf, outCap, outLen, '\n')
        inc js.pos
      of 'r':
        emitChar(outBuf, outCap, outLen, '\r')
        inc js.pos
      of 't':
        emitChar(outBuf, outCap, outLen, '\t')
        inc js.pos
      of 'v':
        emitChar(outBuf, outCap, outLen, '\v')
        inc js.pos
      of 'u':
        inc js.pos
        var cp = parseHex4(js)
        if cp < 0: return
        if (cp and 0xfc00) == 0xd800:
          if js.pos + 1 >= js.len or js.buf[js.pos] != '\\' or
             js.buf[js.pos + 1] != 'u':
            js.err = true
            return
          inc js.pos, 2
          let s = parseHex4(js)
          if s < 0: return
          if (s and 0xfc00) == 0xdc00 and s > 0:
            cp = 0x10000 + (((cp - 0xd800) shl 10) or (s - 0xdc00))
          else:
            js.err = true
            return
        emitRune(outBuf, outCap, outLen, cp)
      else:
        # std/json keeps the backslash and reprocesses the current char.
        emitChar(outBuf, outCap, outLen, '\\')
    elif c == '\r':
      emitChar(outBuf, outCap, outLen, '\r')
      inc js.pos
      if js.pos < js.len and js.buf[js.pos] == '\n': inc js.pos
    elif c == '\n':
      emitChar(outBuf, outCap, outLen, '\n')
      inc js.pos
    else:
      emitChar(outBuf, outCap, outLen, c)
      inc js.pos

proc scSkip(js: var JsonScan) =
  ## Whitespace and comments, matching `std/parsejson.skip`.
  while js.pos < js.len:
    case js.buf[js.pos]
    of ' ', '\t', '\r', '\n':
      inc js.pos
    of '/':
      if js.pos + 1 < js.len and js.buf[js.pos + 1] == '/':
        inc js.pos, 2
        while js.pos < js.len and js.buf[js.pos] notin {'\r', '\n', '\0'}:
          inc js.pos
      elif js.pos + 1 < js.len and js.buf[js.pos + 1] == '*':
        inc js.pos, 2
        var closed = false
        while js.pos + 1 < js.len:
          if js.buf[js.pos] == '*' and js.buf[js.pos + 1] == '/':
            inc js.pos, 2
            closed = true
            break
          inc js.pos
        if not closed:
          js.err = true
          return
      else:
        return
    else:
      return

# These three procs are mutually recursive: `scanValue` dispatches on the first
# byte, and container values recurse through `scanObject`/`scanArray`. `depth`
# is the current nesting level; `capture` is true only for the top-level object.
proc scanValue(js: var JsonScan; depth: int): ValInfo

proc scanObject(js: var JsonScan; depth: int; st: var PayloadState;
                capture: bool)

proc scanArray(js: var JsonScan; depth: int) =
  ## Validate an array and discard its values. Arrays cannot supply claims, but
  ## their contents still have to be parsed to find the closing bracket.
  inc js.pos
  js.scSkip
  if js.err: return
  if js.pos < js.len and js.buf[js.pos] == ']':
    inc js.pos
    return
  while true:
    js.scSkip
    if js.err: return
    # std/json accepts a trailing comma: after consuming ',' the next token may
    # be the closing bracket.
    if js.pos < js.len and js.buf[js.pos] == ']':
      inc js.pos
      return
    discard scanValue(js, depth + 1)
    if js.err: return
    js.scSkip
    if js.err: return
    if js.pos >= js.len:
      js.err = true
      return
    case js.buf[js.pos]
    of ',':
      inc js.pos
    of ']':
      inc js.pos
      return
    else:
      js.err = true
      return

proc scanNumber(js: var JsonScan): ValInfo =
  ## Consume one JSON number token using std/json's permissive grammar, then
  ## require the whole token to convert. Overflowing or otherwise non-numeric
  ## tokens still validate as `vkOther`, matching std/json's raw-string fallback.
  let start = js.pos
  if js.pos < js.len and js.buf[js.pos] == '-': inc js.pos
  var isFloat = false
  if js.pos < js.len and js.buf[js.pos] == '.':
    isFloat = true
    inc js.pos
    while js.pos < js.len and js.buf[js.pos] in {'0'..'9'}: inc js.pos
  else:
    while js.pos < js.len and js.buf[js.pos] in {'0'..'9'}: inc js.pos
    if js.pos < js.len and js.buf[js.pos] == '.':
      isFloat = true
      inc js.pos
      while js.pos < js.len and js.buf[js.pos] in {'0'..'9'}: inc js.pos
  if js.pos < js.len and js.buf[js.pos] in {'e', 'E'}:
    isFloat = true
    inc js.pos
    if js.pos < js.len and js.buf[js.pos] in {'+', '-'}: inc js.pos
    while js.pos < js.len and js.buf[js.pos] in {'0'..'9'}: inc js.pos

  let tokLen = js.pos - start
  if isFloat:
    var f = 0.0
    var n = 0
    try:
      n = parseutils.parseFloat(js.buf.toOpenArray(start, js.pos - 1), f)
    except ValueError:
      n = 0
    if n == 0 or n != tokLen:
      result.kind = vkOther             # std/json falls back to a raw JString
    else:
      result.kind = vkFloat
      result.f = f
  else:
    var v: int64
    var n = 0
    try:
      n = parseutils.parseBiggestInt(js.buf.toOpenArray(start, js.pos - 1), v)
    except ValueError:
      n = 0
    if n == 0 or n != tokLen:
      result.kind = vkOther
    else:
      result.kind = vkInt
      result.i = v

proc feedDigit(v: var int64; c: char; ok: var bool) {.inline.} =
  ## Append one decimal digit, clearing `ok` instead of overflowing int64.
  let d = int64(ord(c) - ord('0'))
  if v > (9_223_372_036_854_775_807'i64 - d) div 10:
    ok = false
  else:
    v = v * 10 + d

const SimpleEscape = {'b', 'f', 'n', 'r', 't', 'v', '\\', '"', '\'', '/'}

proc decodeSub(js: var JsonScan; a, b: int; value: var int64): bool =
  ## Decode an already-validated JSON string raw span and accept it only if the
  ## decoded form is one-or-more ASCII digits fitting int64. Escaped digits
  ## (\u0031) count; escapes that produce any other char make the sub invalid.
  value = 0
  var seen = false
  var i = a
  while i < b:
    let c = js.buf[i]
    if c == '\\':
      inc i
      if i >= b: return false
      let e = js.buf[i]
      if e == 'u':
        inc i
        var r = 0
        for _ in 0 ..< 4:
          if i >= b: return false
          let hv = hexValue(js.buf[i])
          if hv < 0: return false
          r = (r shl 4) or hv
          inc i
        if (r and 0xfc00) == 0xd800:
          if i + 1 >= b or js.buf[i] != '\\' or js.buf[i + 1] != 'u':
            return false
          inc i, 2
          var lo = 0
          for _ in 0 ..< 4:
            if i >= b: return false
            let hv = hexValue(js.buf[i])
            if hv < 0: return false
            lo = (lo shl 4) or hv
            inc i
          r = 0x10000 + (((r - 0xd800) shl 10) or (lo - 0xdc00))
        if r > 0x7F: return false
        let ch = char(r)
        if ch < '0' or ch > '9': return false
        var ok = true
        feedDigit(value, ch, ok)
        if not ok: return false
      elif e in SimpleEscape:
        return false                     # none of these decode to a digit
      else:
        return false                     # std/json emits '\' + char
    else:
      if c < '0' or c > '9': return false
      var ok = true
      feedDigit(value, c, ok)
      if not ok: return false
      inc i
    seen = true
  seen and value > 0

proc decodeStringAlloc(js: var JsonScan; a, b: int): string =
  ## Decode a validated JSON string raw span into the final result string.
  ## Allocates exactly once, sized to the raw span (decoding never grows it).
  result = newString(b - a)
  var n = 0
  var i = a
  while i < b:
    let c = js.buf[i]
    if c == '\\':
      inc i
      let e = js.buf[i]
      case e
      of '\\', '"', '\'', '/':
        result[n] = e
        inc n
        inc i
      of 'b':
        result[n] = '\b'; inc n; inc i
      of 'f':
        result[n] = '\f'; inc n; inc i
      of 'n':
        result[n] = '\n'; inc n; inc i
      of 'r':
        result[n] = '\r'; inc n; inc i
      of 't':
        result[n] = '\t'; inc n; inc i
      of 'v':
        result[n] = '\v'; inc n; inc i
      of 'u':
        inc i
        var r = 0
        for _ in 0 ..< 4:
          r = (r shl 4) or hexValue(js.buf[i])
          inc i
        if (r and 0xfc00) == 0xd800:
          inc i, 2
          var lo = 0
          for _ in 0 ..< 4:
            lo = (lo shl 4) or hexValue(js.buf[i])
            inc i
          r = 0x10000 + (((r - 0xd800) shl 10) or (lo - 0xdc00))
        var tmp: array[4, char]
        var tn = 0
        emitRune(cast[ptr UncheckedArray[char]](addr tmp[0]), 4, tn, r)
        for k in 0 ..< tn:
          result[n] = tmp[k]
          inc n
      else:
        result[n] = '\\'
        inc n
        # leave `i` so the next iteration copies the char itself
    elif c == '\r':
      result[n] = '\r'; inc n; inc i
      if i < b and js.buf[i] == '\n': inc i
    elif c == '\n':
      result[n] = '\n'; inc n; inc i
    else:
      result[n] = c; inc n; inc i
  result.setLen(n)

proc scanObject(js: var JsonScan; depth: int; st: var PayloadState;
                capture: bool) =
  ## Validate an object and, when `capture` is true, record `exp`, `sub` and
  ## `username`. Keys are decoded into a small fixed buffer; only exact short
  ## names are recognized, so an arbitrarily long key is validated but ignored.
  ## A repeated key overwrites the earlier value, matching std/json's
  ## last-key-wins lookup.
  inc js.pos
  js.scSkip
  if js.err: return
  if js.pos < js.len and js.buf[js.pos] == '}':
    inc js.pos
    return
  var keyBuf: array[32, char]
  while true:
    js.scSkip
    if js.err: return
    # std/json accepts a trailing comma in objects; after ',' a '}' closes.
    if js.pos < js.len and js.buf[js.pos] == '}':
      inc js.pos
      return
    if js.pos >= js.len or js.buf[js.pos] != '"':
      js.err = true
      return
    var keyStart, keyEnd: int
    var keyLen = 0
    scString(js, cast[ptr UncheckedArray[char]](addr keyBuf[0]), keyBuf.len,
             keyLen, keyStart, keyEnd)
    if js.err: return
    js.scSkip
    if js.err: return
    if js.pos >= js.len or js.buf[js.pos] != ':':
      js.err = true
      return
    inc js.pos
    let vi = scanValue(js, depth + 1)
    if js.err: return
    if capture:
      let isExp = keyLen == 3 and keyBuf[0] == 'e' and keyBuf[1] == 'x' and keyBuf[2] == 'p'
      let isSub = keyLen == 3 and keyBuf[0] == 's' and keyBuf[1] == 'u' and keyBuf[2] == 'b'
      let isUser = keyLen == 8 and keyBuf[0] == 'u' and keyBuf[1] == 's' and
                   keyBuf[2] == 'e' and keyBuf[3] == 'r' and keyBuf[4] == 'n' and
                   keyBuf[5] == 'a' and keyBuf[6] == 'm' and keyBuf[7] == 'e'
      if isExp:
        case vi.kind
        of vkInt:
          st.expKind = fkInt
          st.expVal = float(vi.i)
        of vkFloat:
          st.expKind = fkFloat
          st.expVal = vi.f
        else:
          st.expKind = fkOther
      elif isSub:
        if vi.kind == vkString:
          st.subKind = fkString
          st.subOk = decodeSub(js, vi.sStart, vi.sEnd, st.subVal)
        else:
          st.subKind = fkOther
      elif isUser:
        if vi.kind == vkString:
          st.userKind = fkString
          st.userStart = vi.sStart
          st.userEnd = vi.sEnd
        else:
          st.userKind = fkOther
    js.scSkip
    if js.err: return
    if js.pos >= js.len:
      js.err = true
      return
    case js.buf[js.pos]
    of ',':
      inc js.pos
    of '}':
      inc js.pos
      return
    else:
      js.err = true
      return

proc scanValue(js: var JsonScan; depth: int): ValInfo =
  ## Validate one JSON value. A string returns its raw escaped span; objects and
  ## arrays are recursively validated but their contents are never captured.
  ## `depth` bounds recursion so a malicious payload cannot exhaust the stack.
  js.scSkip
  if js.err or js.pos >= js.len:
    js.err = true
    return
  let c = js.buf[js.pos]
  case c
  of '"':
    var rs, re: int
    var discardLen = 0
    scString(js, nil, 0, discardLen, rs, re)
    if js.err: return
    result.kind = vkString
    result.sStart = rs
    result.sEnd = re
  of '{':
    if depth > JsonDepthLimit:
      js.err = true
      return
    var dummy: PayloadState
    scanObject(js, depth, dummy, false)
  of '[':
    if depth > JsonDepthLimit:
      js.err = true
      return
    scanArray(js, depth)
  of '-', '.', '0'..'9':
    result = scanNumber(js)
  of 't':
    if js.pos + 4 <= js.len and js.buf[js.pos+1] == 'r' and
       js.buf[js.pos+2] == 'u' and js.buf[js.pos+3] == 'e':
      inc js.pos, 4
    else:
      js.err = true
  of 'f':
    if js.pos + 5 <= js.len and js.buf[js.pos+1] == 'a' and
       js.buf[js.pos+2] == 'l' and js.buf[js.pos+3] == 's' and
       js.buf[js.pos+4] == 'e':
      inc js.pos, 5
    else:
      js.err = true
  of 'n':
    if js.pos + 4 <= js.len and js.buf[js.pos+1] == 'u' and
       js.buf[js.pos+2] == 'l' and js.buf[js.pos+3] == 'l':
      inc js.pos, 4
    else:
      js.err = true
  else:
    js.err = true

proc scanPayload(buf: ptr UncheckedArray[char]; n: int;
                 st: var PayloadState): bool =
  ## Scan a decoded payload and capture its claims. The top level must be an
  ## object. Comments, trailing commas and a trailing NUL are accepted exactly
  ## where std/json accepts them; anything else after the object is invalid.
  var js = JsonScan(buf: buf, len: n, pos: 0)
  js.scSkip
  if js.err or js.pos >= js.len or js.buf[js.pos] != '{':
    return false
  scanObject(js, 0, st, true)
  if js.err: return false
  js.scSkip
  if js.err: return false
  # std/json's lexer treats a raw NUL as EOF; a NUL after a complete value is
  # therefore accepted and anything after it is ignored.
  if js.pos < js.len and js.buf[js.pos] == '\0':
    return true
  js.pos == js.len

proc verifyJwtImpl(buf: openArray[char]; token: Span; secret: string;
                   now: float): tuple[status: JwtStatus, info: JwtInfo] =
  ## Verify a compact HS256 token borrowed from `buf`.
  ##
  ## Structural, encoding, signature and expiry failures are `jsInvalid`. Once
  ## the signature is known good, only unusable `sub`/`username` claims produce
  ## `jsBadPayload`, so the caller can return the frozen 401 bodies distinctly.
  result = (jsInvalid, JwtInfo())

  # 1. Exactly three dot-separated segments.
  let tokenEnd = token.off + token.len
  var firstDot = -1
  var secondDot = -1
  var i = token.off
  while i < tokenEnd:
    if buf[i] == '.':
      if firstDot < 0:
        firstDot = i
      elif secondDot < 0:
        secondDot = i
      else:
        return
    inc i
  if firstDot < 0 or secondDot < 0: return

  let headerB64 = Span(off: token.off, len: firstDot - token.off)
  let payloadB64 = Span(off: firstDot + 1, len: secondDot - firstDot - 1)
  let sigB64 = Span(off: secondDot + 1, len: tokenEnd - secondDot - 1)

  var scratch {.noinit.}: JwtScratch

  # 2. Header must be JSON with alg == "HS256". The official header bytes take
  #    the allocation-free path; anything else falls back to std/json.
  var headerLen = 0
  if not b64DecodeSpan(buf, headerB64, scratch.decoded, headerLen): return
  if not headerIsCanonical(scratch.decoded, headerLen):
    if not parseHeaderFallback(scratch.decoded, headerLen): return

  # 3. Recompute HMAC-SHA256 over the contiguous "header.payload" prefix of the
  #    request buffer and compare against the decoded signature in constant
  #    time. No concatenation, no intermediate string.
  var sigLen = 0
  if not b64DecodeSpan(buf, sigB64, scratch.sig, sigLen): return
  if sigLen != 32: return
  let mac = sha256.hmac(secret, buf.toOpenArray(token.off, secondDot - 1))
  if not constantTimeEq32(mac.data, scratch.sig): return

  # 4. Payload must be a JSON object with a numeric, non-expired exp.
  var payloadLen = 0
  if not b64DecodeSpan(buf, payloadB64, scratch.decoded, payloadLen): return
  var st: PayloadState
  let decPtr = cast[ptr UncheckedArray[char]](addr scratch.decoded[0])
  if not scanPayload(decPtr, payloadLen, st): return
  if st.expKind notin {fkInt, fkFloat}: return
  if now > st.expVal: return

  # 5. Signature is valid: `sub` must be a positive-integer digit string and
  #    `username` must be a JSON string, otherwise jsBadPayload.
  if st.subKind != fkString or not st.subOk:
    result.status = jsBadPayload
    return
  if st.userKind != fkString:
    result.status = jsBadPayload
    return

  result.status = jsOk
  result.info.userId = st.subVal
  var js = JsonScan(buf: decPtr, len: payloadLen, pos: 0)
  result.info.username = decodeStringAlloc(js, st.userStart, st.userEnd)

proc verifyJwt*(buf: openArray[char]; token: Span; secret: string;
                now: float = epochTime()): tuple[status: JwtStatus, info: JwtInfo] {.inline.} =
  ## Span-based entry point used by the request path: the token is borrowed from
  ## the request buffer, so no substring is allocated before verification.
  verifyJwtImpl(buf, token, secret, now)

proc verifyJwt*(token, secret: string;
                now: float = epochTime()): tuple[status: JwtStatus, info: JwtInfo] {.inline.} =
  ## String convenience entry point (tests/tools): wraps the token in a Span
  ## without copying it.
  verifyJwtImpl(token, Span(off: 0, len: token.len), secret, now)
