import Feed.Bytes

/-!
# HTTP/1.1 framing

Requests are parsed in place: a request is a set of byte ranges of the connection's input. The
parser is written to `Feed/Spec/Http.lean` (RFC 9112 and RFC 9110, with the choices listed there):
the empty lines before a request are skipped; every line of the head ends in CR LF, and no other
CR or LF is in it; the request-line is a method token, SP, a request-target, SP and `HTTP/1.x`;
a field line is a token, `:` and a value of field-vchar, SP and HTAB. Only what the API needs is
extracted: the method, the path of the request-target (the query is left out), the
`Authorization` value, the content (by `Content-Length`; any `Transfer-Encoding` is answered 400)
and whether the connection closes after the response. HTTP/1.1 needs one valid `Host`. A head that
does not end within `maxHead + 4` bytes is answered 431, a request-target of more than `maxTarget`
bytes 414 (once `maxTarget + 1` of them have arrived within the first `maxHead + 4` bytes), content
of more than `maxBody` bytes 413 (once the head has).

`scan` reads the bytes: the head's lines, the request-line's parts and what the field lines say;
`finish` checks the Host value and the request-target with the deciders below and the content's
length. A HEAD request is parsed as GET with `head` set. That `parse` computes the specification's
frame of the input is proved in `Feed/Proofs/Http.lean` (`Http.parse_view`). The server runs the C
version of `parse` (`runtime/leaves.c`), which follows `scan` and `finish` function by function;
the self-test compares it with this definition.
-/
namespace Feed.Http

def maxHead : Nat := 16384
def maxTarget : Nat := 8192
def maxBody : Nat := 16384

inductive Method where
  | get | post | other
  deriving BEq, Inhabited

structure Req where
  method : Method
  pathLo : Nat
  pathHi : Nat
  hasAuth : Bool
  authLo : Nat
  authHi : Nat
  bodyLo : Nat
  bodyHi : Nat
  /-- close the connection after answering -/
  close : Bool
  /-- where the next request starts -/
  next : Nat
  /-- whether the method was HEAD, which is answered as GET without the content (RFC 9110 §9.3.2) -/
  head : Bool
  deriving Inhabited

inductive Parse where
  /-- more bytes are needed -/
  | incomplete
  /-- the bytes are not a request this server can answer; reply with this status and close -/
  | bad (status : Nat)
  | ok (r : Req)
  deriving Inhabited

@[inline] def byte (a : ByteArray) (i : Nat) : UInt8 := a.get! i

/-- ASCII lowercase. -/
@[inline] def lower (b : UInt8) : UInt8 := if 0x41 ≤ b && b ≤ 0x5a then b + 32 else b

/-- Whether `a[lo, hi)` equals `lit`, ignoring ASCII case (`lit` is lowercase). -/
def eqCI (a : ByteArray) (lo hi : Nat) (lit : ByteArray) : Bool :=
  hi - lo == lit.size && go 0 lit.size
where
  go (k : Nat) : Nat → Bool
    | 0 => true
    | f + 1 => lower (byte a (lo + k)) == lit.get! k && go (k + 1) f

/-- Whether `a[lo, hi)` equals `lit` exactly. -/
def eqAt (a : ByteArray) (lo hi : Nat) (lit : ByteArray) : Bool :=
  hi - lo == lit.size && go 0 lit.size
where
  go (k : Nat) : Nat → Bool
    | 0 => true
    | f + 1 => byte a (lo + k) == lit.get! k && go (k + 1) f

/-! ## Characters

A set of ASCII bytes is two words of bits, for 0x00-0x3f and for 0x40-0x7f. -/

@[inline] def inSet (lo hi : UInt64) (c : UInt8) : Bool :=
  if c < 64 then (lo >>> c.toUInt64) &&& 1 == 1
  else if c < 128 then (hi >>> (c - 64).toUInt64) &&& 1 == 1
  else false

/-- RFC 9110 §5.6.2 `tchar` -/
@[inline] def tchar (c : UInt8) : Bool := inSet 0x03ff6cfa00000000 0x57ffffffc7fffffe c
/-- RFC 9110 §5.5: field-vchar (VCHAR, obs-text), SP or HTAB -/
@[inline] def fieldChar (c : UInt8) : Bool := c == 0x09 || (0x20 ≤ c && c != 0x7f)
@[inline] def digit (c : UInt8) : Bool := 0x30 ≤ c && c ≤ 0x39
@[inline] def hex (c : UInt8) : Bool := digit c || (0x41 ≤ c && c ≤ 0x46) || (0x61 ≤ c && c ≤ 0x66)
@[inline] def alpha (c : UInt8) : Bool := (0x41 ≤ c && c ≤ 0x5a) || (0x61 ≤ c && c ≤ 0x7a)

/-! RFC 3986's sets: `unreserved / sub-delims` (a reg-name), with ":" "@" "/" (a path), with
":" "@" "/" "?" (a query), with ":" (userinfo, IPvFuture); a scheme's `ALPHA / DIGIT / "+" / "-" /
"."`. -/

def regLo : UInt64 := 0x2bff7fd200000000
def regHi : UInt64 := 0x47fffffe87fffffe
def pathLo : UInt64 := 0x2fffffd200000000
def pathHi : UInt64 := 0x47fffffe87ffffff
def queryLo : UInt64 := 0xafffffd200000000
def queryHi : UInt64 := 0x47fffffe87ffffff
def userLo : UInt64 := 0x2fff7fd200000000
def userHi : UInt64 := 0x47fffffe87fffffe
def schemeLo : UInt64 := 0x03ff680000000000
def schemeHi : UInt64 := 0x07fffffe07fffffe

/-- Whether every byte of `a[i, hi)` is in the set `(m0, m1)`. -/
def allIn (m0 m1 : UInt64) (a : ByteArray) (i hi : Nat) : Bool := go i (hi - i)
where
  go (i : Nat) : Nat → Bool
    | 0 => true
    | f + 1 => inSet m0 m1 (byte a i) && go (i + 1) f

/-- Whether every byte of `a[i, hi)` is a digit. -/
def allDigits (a : ByteArray) (i hi : Nat) : Bool := go i (hi - i)
where
  go (i : Nat) : Nat → Bool
    | 0 => true
    | f + 1 => digit (byte a i) && go (i + 1) f

/-- Whether every byte of `a[i, hi)` is a hex digit. -/
def allHex (a : ByteArray) (i hi : Nat) : Bool := go i (hi - i)
where
  go (i : Nat) : Nat → Bool
    | 0 => true
    | f + 1 => hex (byte a i) && go (i + 1) f

/-- Whether `a[i, hi)` is `*( c / pct-encoded )`, `c` the bytes of the set `(m0, m1)` (RFC 3986
§2.1: `pct-encoded = "%" HEXDIG HEXDIG`). -/
def uriChars (m0 m1 : UInt64) (a : ByteArray) (i hi : Nat) : Bool := go i (hi - i)
where
  go (i : Nat) : Nat → Bool
    | 0 => true
    | f + 1 =>
      if hi ≤ i then true else
      let c := byte a i
      if inSet m0 m1 c then go (i + 1) f
      else c == 0x25 && i + 3 ≤ hi && hex (byte a (i + 1)) && hex (byte a (i + 2)) && go (i + 3) f

/-- The value of the digits `a[lo, hi)`. -/
def number (a : ByteArray) (lo hi : Nat) : Nat := go lo (hi - lo) 0
where
  go (i : Nat) : Nat → Nat → Nat
    | 0, acc => acc
    | f + 1, acc => go (i + 1) f (acc * 10 + (byte a i - 0x30).toNat)

/-! ## Host and request-targets (RFC 3986 §3, RFC 9110 §4.2 and §7.2, RFC 9112 §3.2)

Deciders for the grammar of `Feed/Spec/Uri.lean`, each on a range of the input; that `hostOk` and
`target` decide it is proved in `Feed/Proofs/Uri.lean` (`Http.hostOk_iff`, `Http.target_spec`). -/

/-- `dec-octet`: 0 to 255, without a leading zero -/
def decOctet (a : ByteArray) (lo hi : Nat) : Bool :=
  lo < hi && hi ≤ lo + 3 && allDigits a lo hi && (hi == lo + 1 || byte a lo != 0x30) && number a lo hi < 256

/-- `IPv4address = dec-octet "." dec-octet "." dec-octet "." dec-octet` -/
def ipv4 (a : ByteArray) (lo hi : Nat) : Bool :=
  let d1 := Bytes.findByte a 0x2e lo hi
  let d2 := Bytes.findByte a 0x2e (d1 + 1) hi
  let d3 := Bytes.findByte a 0x2e (d2 + 1) hi
  d3 < hi && decOctet a lo d1 && decOctet a (d1 + 1) d2 && decOctet a (d2 + 1) d3 && decOctet a (d3 + 1) hi

/-- `h16 = 1*4HEXDIG` -/
def h16 (a : ByteArray) (lo hi : Nat) : Bool := lo < hi && hi ≤ lo + 4 && allHex a lo hi

/-- The number of groups of `a[lo, hi)` if it is `h16` groups joined by ":" (0 for the empty
range); with `v4`, the last may be an IPv4 address, which counts as two. -/
def groups (a : ByteArray) (lo hi : Nat) (v4 : Bool) : Option Nat :=
  if hi ≤ lo then some 0 else go lo 0 (hi - lo)
where
  go (i k : Nat) : Nat → Option Nat
    | 0 => none
    | f + 1 =>
      let e := Bytes.findByte a 0x3a i hi
      if e < hi then (if h16 a i e then go (e + 1) (k + 1) f else none)
      else if h16 a i hi then some (k + 1)
      else if v4 && ipv4 a i hi then some (k + 2)
      else none

/-- The first "::" in `a[lo, hi)`, or `hi`. -/
def doubleColon (a : ByteArray) (lo hi : Nat) : Nat := go lo (hi - lo)
where
  go (i : Nat) : Nat → Nat
    | 0 => hi
    | f + 1 => if hi ≤ i + 1 then hi else if byte a i == 0x3a && byte a (i + 1) == 0x3a then i else go (i + 1) f

/-- `IPv6address`: eight groups (the last two may be an IPv4 address), or at most seven around
one "::". -/
def ipv6 (a : ByteArray) (lo hi : Nat) : Bool :=
  let d := doubleColon a lo hi
  if d < hi then
    match groups a lo d false, groups a (d + 2) hi true with
    | some i, some j => i + j ≤ 7
    | _, _ => false
  else groups a lo hi true == some 8

/-- `IPvFuture` after its "v": `1*HEXDIG "." 1*( unreserved / sub-delims / ":" )` -/
def ipFuture (a : ByteArray) (lo hi : Nat) : Bool :=
  let d := Bytes.findByte a 0x2e lo hi
  lo < d && d + 1 < hi && allHex a lo d && allIn userLo userHi a (d + 1) hi

/-- What is between the brackets of an `IP-literal`: `IPvFuture` or `IPv6address`. -/
def ipLiteral (a : ByteArray) (lo hi : Nat) : Bool :=
  if lo < hi && (byte a lo == 0x76 || byte a lo == 0x56) then ipFuture a (lo + 1) hi else ipv6 a lo hi

/-- `[ ":" port ]` at `i`, `port = *DIGIT` -/
def portOk (a : ByteArray) (i hi : Nat) : Bool := hi ≤ i || (byte a i == 0x3a && allDigits a (i + 1) hi)

/-- The end of the host if `a[lo, hi)` is `uri-host [ ":" port ]`: an IP-literal ends at its
first "]", a reg-name (an IPv4 address is one) at its first ":". -/
def hostEnd (a : ByteArray) (lo hi : Nat) : Option Nat :=
  if lo < hi && byte a lo == 0x5b then
    let r := Bytes.findByte a 0x5d lo hi
    if r < hi && ipLiteral a (lo + 1) r && portOk a (r + 1) hi then some (r + 1) else none
  else
    let c := Bytes.findByte a 0x3a lo hi
    if uriChars regLo regHi a lo c && portOk a c hi then some c else none

/-- Whether `a[lo, hi)` is a Host value, `uri-host [ ":" port ]` (RFC 9110 §7.2). -/
def hostOk (a : ByteArray) (lo hi : Nat) : Bool := (hostEnd a lo hi).isSome

/-- `authority = [ userinfo "@" ] host [ ":" port ]` -/
def authority (a : ByteArray) (lo hi : Nat) : Bool :=
  let at_ := Bytes.findByte a 0x40 lo hi
  if at_ < hi then uriChars userLo userHi a lo at_ && hostOk a (at_ + 1) hi else hostOk a lo hi

/-- `hier-part`: "//" authority and a path that is empty or starts with "/", or a path that
does not start with "//" -/
def hierPart (a : ByteArray) (lo hi : Nat) : Bool :=
  if lo + 2 ≤ hi && byte a lo == 0x2f && byte a (lo + 1) == 0x2f then
    let e := Bytes.findByte a 0x2f (lo + 2) hi
    authority a (lo + 2) e && uriChars pathLo pathHi a e hi
  else uriChars pathLo pathHi a lo hi

def kHttp : ByteArray := "http".toUTF8
def kHttps : ByteArray := "https".toUTF8
def kHttpSlashes : ByteArray := "http://".toUTF8
def kHttpsSlashes : ByteArray := "https://".toUTF8

/-- Whether `a[lo, hi)` is `scheme ":" hier-part` of a scheme other than http and https -/
def otherScheme (a : ByteArray) (lo hi : Nat) : Bool :=
  let c := Bytes.findByte a 0x3a lo hi
  c < hi && lo < c && alpha (byte a lo) && allIn schemeLo schemeHi a lo c && !eqCI a lo c kHttp &&
    !eqCI a lo c kHttps && hierPart a (c + 1) hi

/-- The path of `a[lo, hi)` if it is `"http://" authority path-abempty` or the same with "https"
(the scheme in any case), with a host that is not empty and no userinfo (RFC 9110 §4.2.1-4.2.4). -/
def absolutePath (a : ByteArray) (lo hi : Nat) : Option (Nat × Nat) :=
  let s := if lo + 7 ≤ hi && eqCI a lo (lo + 7) kHttpSlashes then lo + 7
    else if lo + 8 ≤ hi && eqCI a lo (lo + 8) kHttpsSlashes then lo + 8 else lo
  if s == lo then none else
  let e := Bytes.findByte a 0x2f s hi
  match hostEnd a s e with
  | some h => if s < h && uriChars pathLo pathHi a e hi then some (e, hi) else none
  | none => none

/-- The path of the request-target `a[lo, hi)` (`Spec.Http.TargetPath`): an origin-form's
absolute path; an http or https absolute-form's path; an empty range for an asterisk-form, an
authority-form and an absolute URI of another scheme, which name nothing here; none if it is none
of these. The query, after the first "?", is not part of the path. -/
def target (a : ByteArray) (lo hi : Nat) : Option (Nat × Nat) :=
  let q := Bytes.findByte a 0x3f lo hi
  let query := hi ≤ q || uriChars queryLo queryHi a (q + 1) hi
  if lo < q && byte a lo == 0x2f then
    if query && uriChars pathLo pathHi a lo q then some (lo, q) else none
  else match (if query then absolutePath a lo q else none) with
    | some p => some p
    | none =>
      if (hi == lo + 1 && byte a lo == 0x2a) || (match hostEnd a lo hi with | some h => h < hi | none => false) ||
        (query && otherScheme a lo q) then some (lo, lo) else none

/-! ## The head -/

/-- After the empty lines (CR LF) at `i`: RFC 9112 §2.2 asks a server to ignore at least one
before the request-line. -/
def skipLead (a : ByteArray) (i : Nat) : Nat := go i (a.size - i)
where
  go (i : Nat) : Nat → Nat
    | 0 => i
    | f + 1 => if byte a i == 0x0d && byte a (i + 1) == 0x0a then go (i + 2) f else i

/-- The first byte from `i` on that is not a `tchar`, or `hi`. -/
def tokenEnd (a : ByteArray) (i hi : Nat) : Nat := go i (hi - i)
where
  go (i : Nat) : Nat → Nat
    | 0 => i
    | f + 1 => if tchar (byte a i) then go (i + 1) f else i

/-- The first SP, CR or LF from `i` on, or `hi`: the end of a request-target. -/
def targetEnd (a : ByteArray) (i hi : Nat) : Nat := go i (hi - i)
where
  go (i : Nat) : Nat → Nat
    | 0 => i
    | f + 1 => let c := byte a i; if c == 0x20 || c == 0x0d || c == 0x0a then i else go (i + 1) f

/-- The first byte from `i` on that cannot be in a field line's value, or `hi`. -/
def valueEnd (a : ByteArray) (i hi : Nat) : Nat := go i (hi - i)
where
  go (i : Nat) : Nat → Nat
    | 0 => i
    | f + 1 => if fieldChar (byte a i) then go (i + 1) f else i

/-- The first `i ≥ lo` with `i + 4 ≤ hi` where `a[i, i + 4)` is CR LF CR LF: the end of a head. -/
def headEnd (a : ByteArray) (lo hi : Nat) : Option Nat := go lo (hi - lo)
where
  go (i : Nat) : Nat → Option Nat
    | 0 => none
    | f + 1 =>
      let c := Bytes.findByte a 0x0d i (hi - 3)
      if c + 3 < hi then
        if byte a (c + 1) == 0x0a && byte a (c + 2) == 0x0d && byte a (c + 3) == 0x0a then some c else go (c + 1) f
      else none

/-- Skip spaces and tabs forward from `s` (not past `e`). -/
def skipL (a : ByteArray) (s e : Nat) : Nat := go s (e - s)
where
  go (s : Nat) : Nat → Nat
    | 0 => s
    | f + 1 => if byte a s == 0x20 || byte a s == 0x09 then go (s + 1) f else s

/-- Skip spaces and tabs backward from `e` (not before `s`). -/
def skipR (a : ByteArray) (s e : Nat) : Nat := go e (e - s)
where
  go (e : Nat) : Nat → Nat
    | 0 => e
    | f + 1 => if byte a (e - 1) == 0x20 || byte a (e - 1) == 0x09 then go (e - 1) f else e

/-- Whether the comma-separated header value `a[lo, hi)` has the token `tok` (lowercase). -/
def hasToken (a : ByteArray) (lo hi : Nat) (tok : ByteArray) : Bool :=
  go lo (hi - lo + 1)
where
  go (i : Nat) : Nat → Bool
    | 0 => false
    | f + 1 =>
      if i ≥ hi then false else
      let e := Bytes.findByte a 0x2c i hi
      let s := skipL a i e
      eqCI a s (skipR a s e) tok || go (e + 1) f

/-- From `i`, the first byte that is not "0", or `hi`. -/
def skipZeros (a : ByteArray) (i hi : Nat) : Nat := go i (hi - i)
where
  go (i : Nat) : Nat → Nat
    | 0 => i
    | f + 1 => if byte a i == 0x30 then go (i + 1) f else i

/-- Whether `a[lo, hi)` and `a[lo', hi')` are the same bytes. -/
def sameBytes (a : ByteArray) (lo hi lo' hi' : Nat) : Bool :=
  hi - lo == hi' - lo' && go 0 (hi - lo)
where
  go (k : Nat) : Nat → Bool
    | 0 => true
    | f + 1 => byte a (lo + k) == byte a (lo' + k) && go (k + 1) f

/-- The value of the digits `a[lo, hi)`, or `maxBody + 1` if it is more than `maxBody`. -/
def lengthOf (a : ByteArray) (lo hi : Nat) : Nat := go lo (hi - lo) 0
where
  go (i : Nat) : Nat → Nat → Nat
    | 0, acc => acc
    | f + 1, acc =>
      let acc := acc * 10 + (byte a i - 0x30).toNat
      if acc > maxBody then maxBody + 1 else go (i + 1) f acc

def hHost : ByteArray := "host".toUTF8
def hContentLength : ByteArray := "content-length".toUTF8
def hAuthorization : ByteArray := "authorization".toUTF8
def hConnection : ByteArray := "connection".toUTF8
def hTransferEncoding : ByteArray := "transfer-encoding".toUTF8
def tClose : ByteArray := "close".toUTF8
def tKeepAlive : ByteArray := "keep-alive".toUTF8
def mGet : ByteArray := "GET".toUTF8
def mHead : ByteArray := "HEAD".toUTF8
def mPost : ByteArray := "POST".toUTF8
def vHttp1 : ByteArray := "HTTP/1.".toUTF8
def kHeadSp : ByteArray := "HEAD ".toUTF8

/-- What a head's field lines say (RFC 9110 §5): how many `Host` and `Authorization` lines it has
and the last one's value (OWS removed); the digits of the first `Content-Length` value from its
first one that is not 0, and whether some value is not `1*DIGIT` or names another number; whether
it has a `Transfer-Encoding` line; the `Connection` options `close` and `keep-alive`; and whether
a line is not a field line. -/
structure Fields where
  hosts : Nat := 0
  hostLo : Nat := 0
  hostHi : Nat := 0
  auths : Nat := 0
  authLo : Nat := 0
  authHi : Nat := 0
  hasLen : Bool := false
  lenLo : Nat := 0
  lenHi : Nat := 0
  lenBad : Bool := false
  coding : Bool := false
  close : Bool := false
  keepAlive : Bool := false
  bad : Bool := false
  deriving Inhabited

/-- A field line, its name `a[lo, hi)` and its value `a[vs, ve)`, added to `f`. Names are
case-insensitive; a `Content-Length` value is compared with the first one as a number (RFC 9110
§8.6). -/
def field (a : ByteArray) (lo hi vs ve : Nat) (f : Fields) : Fields :=
  if eqCI a lo hi hHost then { f with hosts := f.hosts + 1, hostLo := vs, hostHi := ve }
  else if eqCI a lo hi hContentLength then
    if vs < ve && allDigits a vs ve then
      let z := skipZeros a vs ve
      if !f.hasLen then { f with hasLen := true, lenLo := z, lenHi := ve }
      else if sameBytes a f.lenLo f.lenHi z ve then f else { f with lenBad := true }
    else { f with lenBad := true }
  else if eqCI a lo hi hAuthorization then { f with auths := f.auths + 1, authLo := vs, authHi := ve }
  else if eqCI a lo hi hConnection then
    { f with close := f.close || hasToken a vs ve tClose, keepAlive := f.keepAlive || hasToken a vs ve tKeepAlive }
  else if eqCI a lo hi hTransferEncoding then { f with coding := true }
  else f

/-- The field lines from `i` to the head's end `he`: each a token, ":" and value bytes (RFC 9112
§5, RFC 9110 §5.5), then CR LF. A line that starts with SP or HTAB (obs-fold, §5.2) or has
whitespace before its ":" (§5.1) is not one. -/
def fields (a : ByteArray) (he : Nat) (i : Nat) (f : Fields) : Nat → Fields
  | 0 => { f with bad := true }
  | fuel + 1 =>
    let c := tokenEnd a i he
    if c == i || byte a c != 0x3a then { f with bad := true } else
    let e := valueEnd a (c + 1) he
    if byte a e != 0x0d || byte a (e + 1) != 0x0a then { f with bad := true } else
    let vs := skipL a (c + 1) e
    let f := field a i c vs (skipR a vs e) f
    if he ≤ e then f else fields a he (e + 2) f fuel

/-- What the byte scan of the input at `pos` finds. -/
inductive Scan where
  /-- more bytes are needed -/
  | incomplete
  /-- 414, 431, or 400: the head's lines are not a request-line and field lines -/
  | bad (status : Nat)
  /-- a head that ends with the CR LF CR LF at `he`, its method `a[i0, m)`, its request-target
  `a[m + 1, t)`, its version HTTP/1.`minor`, and what its field lines say -/
  | head (i0 m t minor he : Nat) (f : Fields)
  deriving Inhabited

/-- The bytes of the input at `pos` (`Spec.Http.Frames`): after the empty lines, a method token and
SP; 414 if more than `maxTarget` bytes without SP, CR or LF follow within the first `maxHead + 4`
bytes; without CR LF CR LF in them, 431 once they have all arrived; then the head's lines. -/
def scan (a : @& ByteArray) (pos : @& Nat) : Scan :=
  let lim := min a.size (pos + maxHead + 4)
  let i0 := skipLead a pos
  let m := tokenEnd a i0 lim
  let t := targetEnd a (m + 1) (min lim (m + 2 + maxTarget))
  let sp := i0 < m && byte a m == 0x20
  if sp && t == m + 2 + maxTarget then .bad 414 else
  match headEnd a i0 lim with
  | none => if pos + maxHead + 4 ≤ a.size then .bad 431 else .incomplete
  | some he =>
    -- the request-line: method SP request-target SP HTTP-version CR LF
    let v := t + 1
    if !(sp && m + 1 < t && byte a t == 0x20 && eqAt a v (v + 7) vHttp1 && digit (byte a (v + 7)) &&
        byte a (v + 8) == 0x0d && byte a (v + 9) == 0x0a) then .bad 400 else
    let f := if v + 8 == he then {} else fields a he (v + 10) {} (he - (v + 10))
    if f.bad then .bad 400 else .head i0 m t (byte a (v + 7) - 0x30).toNat he f

/-- The request from the scan (RFC 9112 §3.2, §6.3, §9.3; RFC 9110 §7.2, §8.6): no
`Transfer-Encoding`, at most one `Authorization`, the `Content-Length` values one number; in
HTTP/1.1 one `Host` and in HTTP/1.0 at most one, with a valid value; a valid request-target; then
413 for content over `maxBody`, or a wait for the content, or the request. -/
def finish (a : ByteArray) : Scan → Parse
  | .incomplete => .incomplete
  | .bad st => .bad st
  | .head i0 m t minor he f =>
    if f.coding || f.lenBad || f.auths > 1 then .bad 400 else
    if !(if f.hosts == 0 then minor == 0 else f.hosts == 1 && hostOk a f.hostLo f.hostHi) then .bad 400 else
    match target a (m + 1) t with
    | none => .bad 400
    | some (pathLo, pathHi) =>
      let len := if f.hasLen then lengthOf a f.lenLo f.lenHi else 0
      if len > maxBody then .bad 413 else
      let bodyLo := he + 4
      if bodyLo + len > a.size then .incomplete else
      let head := eqAt a i0 m mHead
      let method :=
        if head || eqAt a i0 m mGet then Method.get else if eqAt a i0 m mPost then Method.post else Method.other
      .ok { method, pathLo, pathHi, hasAuth := f.auths == 1, authLo := f.authLo, authHi := f.authHi, bodyLo,
            bodyHi := bodyLo + len, close := f.close || (minor == 0 && !f.keepAlive), next := bodyLo + len, head }

/-- Parse the request starting at `pos`. The server runs the C version (`runtime/leaves.c`), which
the self-test compares with this definition. -/
@[extern "feed_http_parse"]
def parse (a : @& ByteArray) (pos : @& Nat) : Parse := finish a (scan a pos)

/-- Whether the input at `pos` starts, after its empty lines, with "HEAD ": the answer to it has
no content, whether it is a request or not (`Spec.Http.headRequest`). -/
def headAt (a : ByteArray) (pos : Nat) : Bool := let i := skipLead a pos; eqAt a i (i + 5) kHeadSp

end Feed.Http
