## http.nim: transport-agnostic HTTP/1.1 parsing and response framing.
##
## The io_uring server loop in `server.nim` uses this module, so the request
## parser and the response bytes are pinned in one place. Nothing here touches a
## socket, an event loop or the database: every routine is pure string-in /
## string-out, and the only policy knob it needs (the inbound body cap) is
## passed in by the caller.
##
## Wire contract
## -------------
## * `addResponse` emits the exact bytes the spec requires, body verbatim:
##     HTTP/1.1 <status> <reason>\r\n
##     Content-Type: application/json\r\n
##     Content-Length: <n>\r\n
##     Connection: <keep-alive|close>\r\n
##     \r\n
##     <body>
## * `parseHead` never reads the body; it extracts the request line and the
##   `Authorization` / `Content-Length` / `Connection` headers and returns the
##   framing verdict (`ok` / `bad`). The caller decides how much body to consume.
##
## Keeping all of this in one module keeps the wire bytes independent of the
## transport loop.

import jsonbuf
import ./scan_simd
useSimdHeader()

const
  ## Largest header block (request line + headers) accepted before a request is
  ## treated as malformed. The single transport bounds a hostile header block
  ## here.
  MaxHeader* = 16 * 1024

  ## Server-loop policy used by the io_uring transport.
  ListenBacklog* = 4096
  IdleKeepAlive* = 75.0
  StallTimeout* = 30.0

type
  ## A borrowed byte range inside the caller's request buffer. Parsing never
  ## copies request-line or header-value bytes: every consumer (routing, id
  ## parsing, JWT) reads the span in place. `off` is absolute in the buffer, so
  ## a span stays valid across pipelined requests until the buffer is compacted.
  Span* = object
    off*: int
    len*: int

  ## Parsed request-line and header fields, all borrowed from the caller's
  ## buffer. `ok` covers syntax; `bad` records a framing rejection that must be
  ## answered with 400 rather than retried as a body.
  HeadInfo* = object
    ok*:            bool
    ## Set when the request is syntactically a request but its framing is
    ## non-conforming (bad/conflicting Content-Length, Transfer-Encoding): the
    ## caller answers 400 and closes instead of re-parsing the body as a request.
    bad*:           bool
    httpMethod*:    Span ## request method, without the trailing space
    path*:          Span ## path only; the query string is already removed
    auth*:          Span ## raw Authorization value, if present
    keepAlive*:     bool
    contentLen*:    int
    sawContentLen*: bool

const
  ## `strutils.strip` default trim set; used by the in-place header-value trim.
  HeaderWhitespace = {' ', '\t', '\v', '\r', '\l', '\f'}

proc spanEq*(buf: openArray[char]; s: Span; lit: string): bool {.inline.} =
  ## Exact, case-sensitive compare of a borrowed span against a literal.
  if s.len != lit.len: return false
  for i in 0 ..< lit.len:
    if buf[s.off + i] != lit[i]: return false
  true

proc spanEqIgnoreCase*(buf: openArray[char]; s: Span; lit: string): bool {.inline.} =
  ## ASCII case-insensitive compare (the same mapping `cmpIgnoreCase` uses for
  ## header names).
  if s.len != lit.len: return false
  for i in 0 ..< lit.len:
    var a = buf[s.off + i]
    var b = lit[i]
    if a in {'A'..'Z'}: a = char(ord(a) + 32)
    if b in {'A'..'Z'}: b = char(ord(b) + 32)
    if a != b: return false
  true

proc spanStartsWith*(buf: openArray[char]; s: Span; lit: string): bool {.inline.} =
  ## Exact, case-sensitive prefix test against a literal.
  if s.len < lit.len: return false
  for i in 0 ..< lit.len:
    if buf[s.off + i] != lit[i]: return false
  true

proc spanEndsWith*(buf: openArray[char]; s: Span; lit: string): bool {.inline.} =
  ## Exact, case-sensitive suffix test against a literal.
  if s.len < lit.len: return false
  let base = s.off + s.len - lit.len
  for i in 0 ..< lit.len:
    if buf[base + i] != lit[i]: return false
  true

proc spanFindChar*(buf: openArray[char]; s: Span; c: char; fromRel = 0): int {.inline.} =
  ## Relative index of `c` in the span, or -1. `fromRel` starts the scan.
  var i = fromRel
  while i < s.len:
    if buf[s.off + i] == c: return i
    inc i
  -1

proc spanContainsIgnoreCase*(buf: openArray[char]; s: Span; lit: string): bool =
  ## ASCII case-insensitive substring search over the span.
  if lit.len == 0: return true
  if s.len < lit.len: return false
  let last = s.len - lit.len
  var start = 0
  while start <= last:
    var i = 0
    while i < lit.len:
      var a = buf[s.off + start + i]
      var b = lit[i]
      if a in {'A'..'Z'}: a = char(ord(a) + 32)
      if b in {'A'..'Z'}: b = char(ord(b) + 32)
      if a != b: break
      inc i
    if i == lit.len: return true
    inc start
  false

proc trimSpan*(buf: openArray[char]; s: Span): Span {.inline.} =
  ## Equivalent of `strutils.strip` on a borrowed header value.
  var a = 0
  var b = s.len
  while a < b and buf[s.off + a] in HeaderWhitespace: inc a
  while b > a and buf[s.off + b - 1] in HeaderWhitespace: dec b
  Span(off: s.off + a, len: b - a)

proc subSpan*(s: Span; a, b: int): Span {.inline.} =
  ## Relative slice `[a, b)` of `s`; the caller must keep it within bounds.
  Span(off: s.off + a, len: b - a)

proc reasonPhrase*(status: int): string =
  ## Canonical reason phrase for the status codes the API can emit.
  case status
  of 200: "OK"
  of 201: "Created"
  of 400: "Bad Request"
  of 401: "Unauthorized"
  of 404: "Not Found"
  of 500: "Internal Server Error"
  of 503: "Service Unavailable"
  else:   "OK"

const
  ResponseMid = "\r\nContent-Type: application/json\r\nContent-Length: "
  ResponseConn = "\r\nConnection: "
  ResponseEnd = "\r\n\r\n"

proc formatStatusLine(dst: var array[64, char]; status: int): int =
  ## Write `HTTP/1.1 <status> <reason>` into the stack array; returns its length.
  ## `$status` would allocate a temp string, so the digits are written directly,
  ## using uint64 magnitude so `low(int)` cannot overflow.
  var n = 0
  template put(lit: string) =
    for c in lit:
      dst[n] = c
      inc n
  put "HTTP/1.1 "
  let neg = status < 0
  let mag =
    if neg: uint64(-(int64(status) + 1)) + 1'u64
    else:   uint64(status)
  if neg:
    dst[n] = '-'
    inc n
  n += putU64(cast[ptr UncheckedArray[char]](addr dst[n]), mag)
  dst[n] = ' '
  inc n
  put reasonPhrase(status)
  n

proc addResponse*(buf: var string; status: int; body: string; keepAlive: bool) =
  ## Append the exact wire bytes required by the spec to `buf`; the body is
  ## appended verbatim.
  ##
  ## The status line is precomputed before the single `setLen`, the
  ## Content-Length digits are written straight into their final place, and the
  ## head and body share one capacity reservation. No `$status` / `$body.len`
  ## temporary strings are allocated.
  var statusLine: array[64, char]
  let statusLen = formatStatusLine(statusLine, status)
  let conn = if keepAlive: "keep-alive" else: "close"
  let lenDigits = u64Digits(uint64(body.len))
  let headLen = statusLen + ResponseMid.len + lenDigits +
                ResponseConn.len + conn.len + ResponseEnd.len

  let base = buf.len
  buf.setLen(base + headLen + body.len)      # one reservation for head + body

  var pos = base
  copyMem(addr buf[pos], addr statusLine[0], statusLen)
  pos += statusLen
  copyMem(addr buf[pos], cast[pointer](ResponseMid.cstring), ResponseMid.len)
  pos += ResponseMid.len
  pos += putU64(cast[ptr UncheckedArray[char]](addr buf[pos]),
                uint64(body.len))
  copyMem(addr buf[pos], cast[pointer](ResponseConn.cstring), ResponseConn.len)
  pos += ResponseConn.len
  copyMem(addr buf[pos], cast[pointer](conn.cstring), conn.len)
  pos += conn.len
  copyMem(addr buf[pos], cast[pointer](ResponseEnd.cstring), ResponseEnd.len)
  pos += ResponseEnd.len
  if body.len > 0:
    copyMem(addr buf[pos], unsafeAddr body[0], body.len)

## 16-byte header terminator scan. The implementation is selected at compile
## time (SSE2 on x86_64, NEON on ARM64, scalar elsewhere), so the oversized
## pipelined-buffer path does not fall back to a byte loop on either target.

proc findHeaderEnd*(buf: openArray[char]; start = 0): int =
  ## Index of the terminating CRLFCRLF at or after `start`, or -1 when the
  ## header block is incomplete. Scans 16 bytes at a time with a 3-byte overlap
  ## so a pattern straddling a block boundary is still found; the final < 16
  ## bytes are scalar.
  let n = buf.len
  var i = start
  if n - i >= 16:
    let vecEnd = n - 16
    while i <= vecEnd:
      let m = crlf4Mask16(unsafeAddr buf[i])
      if m != 0:
        return i + firstHit(m)
      i += 13
  while i + 3 < n:
    if buf[i] == '\r' and buf[i+1] == '\n' and
       buf[i+2] == '\r' and buf[i+3] == '\n':
      return i
    inc i
  -1

proc findCrlf(buf: openArray[char]; start: int): int {.inline.} =
  ## Index of the next CRLF at or after `start`, or -1.
  var i = start
  while i + 1 < buf.len:
    if buf[i] == '\r' and buf[i + 1] == '\n': return i
    inc i
  -1

proc strictContentLen(buf: openArray[char]; value: Span; outLen: var int; maxBody: int): bool =
  ## Strict Content-Length: one or more ASCII digits, no sign, no whitespace, no
  ## junk, and small enough to fit the caller's body cap (`maxBody`). Rejects
  ## empty, "5 " (stripped to "5" upstream), "+5", "-5", "0x10", "5,5" and
  ## anything exceeding the cap. Not exported: only `parseHead` consumes it.
  if value.len == 0: return false
  var v: int64 = 0
  for i in 0 ..< value.len:
    let c = buf[value.off + i]
    if c < '0' or c > '9': return false
    v = v * 10 + int64(ord(c) - ord('0'))
    if v > int64(maxBody): return false   # bounds v well before int64 overflow
  outLen = int(v)
  true

proc parseHead*(buf: openArray[char], start, hend, maxBody: int): HeadInfo =
  ## Parse the request line and headers of the request beginning at `start` in
  ## `buf`, whose header block ends at `hend` (index of the terminating
  ## CRLFCRLF). Never reads the body and never allocates: every extracted field
  ## is a borrowed `Span` into `buf`. Taking a start offset lets the caller
  ## advance through a pipelined buffer without front-deleting it per request.
  ## `maxBody` is the caller's inbound body cap, enforced on `Content-Length`.
  result.keepAlive = true
  let lineEnd = findCrlf(buf, start)
  if lineEnd < 0 or lineEnd > hend:
    return
  let line = Span(off: start, len: lineEnd - start)
  let sp1 = spanFindChar(buf, line, ' ')
  if sp1 < 0:
    return
  let sp2 = spanFindChar(buf, line, ' ', sp1 + 1)
  if sp2 < 0:
    return
  result.httpMethod = Span(off: line.off, len: sp1)
  var path = Span(off: line.off + sp1 + 1, len: sp2 - sp1 - 1)
  let version = Span(off: line.off + sp2 + 1, len: line.len - sp2 - 1)
  if version.len == 0:
    return

  # HTTP/1.0 defaults to close; /1.1 defaults to keep-alive.
  if spanEq(buf, version, "HTTP/1.0"):
    result.keepAlive = false

  # Strip query string (keep the fragment-free path only).
  let q = spanFindChar(buf, path, '?')
  if q >= 0:
    path.len = q
  result.path = path

  var i = lineEnd + 2
  while i < hend:
    let e = findCrlf(buf, i)
    if e < 0 or e > hend:
      break
    let h = Span(off: i, len: e - i)
    let colon = spanFindChar(buf, h, ':')
    if colon > 0:
      let name = Span(off: h.off, len: colon)
      let value = trimSpan(buf,
        Span(off: h.off + colon + 1, len: h.len - colon - 1))
      if spanEqIgnoreCase(buf, name, "content-length"):
        var cl = 0
        if not strictContentLen(buf, value, cl, maxBody):
          result.bad = true
        elif result.sawContentLen and cl != result.contentLen:
          result.bad = true                 # duplicate with a conflicting value
        else:
          result.sawContentLen = true
          result.contentLen = cl
      elif spanEqIgnoreCase(buf, name, "transfer-encoding"):
        result.bad = true                   # chunked/any TE is not supported
      elif spanEqIgnoreCase(buf, name, "authorization"):
        result.auth = value
      elif spanEqIgnoreCase(buf, name, "connection"):
        if spanContainsIgnoreCase(buf, value, "close"):
          result.keepAlive = false
        elif spanContainsIgnoreCase(buf, value, "keep-alive"):
          result.keepAlive = true
    i = e + 2

  result.ok = true
