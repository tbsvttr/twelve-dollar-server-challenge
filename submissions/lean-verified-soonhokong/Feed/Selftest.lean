import Feed.Server
import Feed.Model

/-!
# Self-test

`bin/server --selftest <file>` (run by build.sh after linking) checks the C code that no proof
covers:

* each leaf of `runtime/leaves.c` (byte operations, HTTP framing, HMAC-SHA256, base64url, the
  feed's and a post's responses) against its Lean definition, on random inputs (HTTP framing also
  on their prefixes, and with each byte value in each place of a request where the parser tells
  bytes apart), and the JSON parser on strings with each byte from 0x80 to 0xff where a UTF-8
  sequence starts;
* `Http.parse` against the frames `Feed/Spec/Http.lean` gives a list of inputs, and on random
  inputs against itself: a prefix of an input reads as a wait or as the whole input does (every
  prefix of an input of up to 2,048 bytes), and the input reads the same after other bytes;
* each storage operation of `runtime/db.c` against its meaning in `Feed/Model.lean`, on a random
  database written to `<file>` (ties in `created_at`, gaps in ids, posts whose author row is
  missing, a `users` table of three B-tree levels), before and after random writes; a page is
  compared row by row as the post objects it reads back as;
* one batch of requests through the handler at `IO` and on the model: the same replies;
* the grouped rowid search of `runtime/db.c` against SQLite's own on every key of `users` and
  `posts`, and its in-order passes over the indexes (the feed's order, the like counts) against
  SQLite's cursors, also on trees of three levels;
* a transaction that grows the file and rolls back, and SQLite's integrity check after the writes;
* SHA-256, HMAC-SHA256 and base64url against the published test vectors, the MACs also on
  ranges inside an array, past its end and given backwards;
* `Jwt.verify` on tokens signed with a key: what RFC 7515 and RFC 7519 make invalid although the
  signature is right (`crit`, a nested JWT's `cty`, `aud`, padding, bits after the last byte).
-/
namespace Feed.Selftest
open Bytes

/-! The references: the leaves' Lean bodies and the definitions they use, restated without
`@[extern]` so that they run as Lean. Each is tied to its definition by `rfl`. -/

def refAppendEsc (out src : ByteArray) (lo hi : Nat) : ByteArray := out ++ ⟨(escape (slice src lo hi)).toArray⟩
def refAppendLitEsc (out lit src : ByteArray) (lo hi : Nat) : ByteArray :=
  out ++ lit ++ ⟨(escape (slice src lo hi)).toArray⟩
def refAppendNat (out : ByteArray) (n : Nat) : ByteArray := out ++ (toString n).toUTF8
def refAppendLitNat (out lit : ByteArray) (n : Nat) : ByteArray := out ++ lit ++ (toString n).toUTF8
def refAppendSlice (out src : ByteArray) (lo hi : Nat) : ByteArray := out ++ ⟨(slice src lo hi).toArray⟩
def refAppendAll (out src : ByteArray) : ByteArray := out ++ src
def refFindByte (a : ByteArray) (b : UInt8) (lo hi : Nat) : Nat := findByte.go a b hi lo (min hi a.size - lo)
def refFindHeadEnd (a : ByteArray) (lo hi : Nat) : Nat := findHeadEnd.go a hi lo (min hi a.size + 1 - lo)

example : @appendEsc = @refAppendEsc := rfl
example : @appendLitEsc = @refAppendLitEsc := rfl
example : @appendNat = @refAppendNat := rfl
example : @appendLitNat = @refAppendLitNat := rfl
example : @appendSlice = @refAppendSlice := rfl
example : @appendAll = @refAppendAll := rfl
example : @findByte = @refFindByte := rfl
example : @findHeadEnd = @refFindHeadEnd := rfl

def refMac (key : Hmac.Key) (m : ByteArray) (lo hi : Nat) : ByteArray :=
  let i := Sha256.finish key.inner 64 m lo hi
  Sha256.digest (Sha256.compressW key.outer i.a i.b i.c i.d i.e i.f i.g i.h 0x80000000 0 0 0 0 0 0 768)
def refB64Encode (d : ByteArray) : ByteArray :=
  Jwt.b64Encode.go d 0 (d.size / 3 + 1) (ByteArray.emptyWithCapacity (d.size * 4 / 3 + 4))
def refB64Decode (a : ByteArray) (lo hi : Nat) : Option ByteArray :=
  let hi := min hi a.size
  if (hi - lo) % 4 == 1 then none
  else Jwt.b64Decode.go a lo (hi - lo) 0 0 (ByteArray.emptyWithCapacity ((hi - lo) * 3 / 4 + 3))

def refPostJsonAfter (out start : ByteArray) (id : Nat) (src : ByteArray) (b c e : Nat)
    (names : ByteArray) (ns ne : Nat) (likes : Nat) : ByteArray :=
  let out := refAppendLitNat out start id
  let out := refAppendLitEsc out kBody src b c
  let out := refAppendLitEsc out kCreated src c e
  let out := refAppendLitEsc out kAuthor names ns ne
  let out := refAppendLitNat out kLikes likes
  refAppendAll out kClose

example : @postJsonAfter = @refPostJsonAfter := rfl

/-- `renderPage.go` with the reference post object. -/
def refRenderGo (pg : Page) (limit : Nat) (k : Nat) : Nat → ByteArray → Nat → ByteArray × Nat
  | 0, out, n => (out, n)
  | f + 1, out, n =>
    if n ≥ limit then (out, n) else
    let m := pg.cols
    if m[8 * k + 4]! != 1 then refRenderGo pg limit (k + 1) f out n else
    let out := refPostJsonAfter out (if n == 0 then kId else kCommaId) m[8 * k]! pg.blob m[8 * k + 1]! m[8 * k + 2]!
      m[8 * k + 3]! pg.blob m[8 * k + 5]! m[8 * k + 6]! m[8 * k + 7]!
    refRenderGo pg limit (k + 1) f out (n + 1)

theorem refRenderGo_eq (pg : Page) (limit : Nat) : ∀ f k out n,
    renderPage.go pg limit k f out n = refRenderGo pg limit k f out n := by
  intro f
  induction f with
  | zero => intros; rfl
  | succ f ih => intro k out n; simp only [renderPage.go, refRenderGo, ih]; rfl

def refFeedFromPage (_body : ByteArray) (pg : Page) : ByteArray × Nat × Nat :=
  let (b, n) := refRenderGo pg feedSize 0 (pg.cols.size / 8) (refAppendAll ByteArray.empty kPosts) 0
  (refAppendAll b kPostsEnd, n, pg.cols.size / 8)

example : @feedFromPage = @refFeedFromPage := by
  funext body pg
  simp only [feedFromPage, refFeedFromPage, renderPage, refRenderGo_eq]
  rfl

/-- `route` with the reference byte search. -/
def refRoute (a : ByteArray) (r : Http.Req) : Route :=
  let hi := min r.pathHi a.size
  let lo := min r.pathLo hi
  match r.method with
  | .get =>
    if Http.eqAt a lo hi pFeed then .feed
    else if Http.eqAt a lo hi pHealth then .health
    else if hi - lo > 7 && Http.eqAt a lo (lo + 7) pPostsSlash && refFindByte a 0x2f (lo + 7) hi == hi then
      .post (parseId a (lo + 7) hi)
    else .notFound
  | .post =>
    if Http.eqAt a lo hi pPosts then .create
    else if hi - lo > 12 && Http.eqAt a lo (lo + 7) pPostsSlash && Http.eqAt a (hi - 5) hi pLike
      && refFindByte a 0x2f (lo + 7) (hi - 5) == hi - 5 then .like (parseId a (lo + 7) (hi - 5))
    else .notFound
  | .other => .notFound

example : @route = @refRoute := rfl

/-! HTTP framing: `Http.parse`, its `scan` and its `finish`, with the reference byte search. -/

def refHeadEnd (a : ByteArray) (hi : Nat) (i : Nat) : Nat → Option Nat
  | 0 => none
  | f + 1 =>
    let c := refFindByte a 0x0d i (hi - 3)
    if c + 3 < hi then
      if Http.byte a (c + 1) == 0x0a && Http.byte a (c + 2) == 0x0d && Http.byte a (c + 3) == 0x0a then some c
      else refHeadEnd a hi (c + 1) f
    else none

theorem refHeadEnd_eq (a : ByteArray) (hi : Nat) : ∀ f i, Http.headEnd.go a hi i f = refHeadEnd a hi i f := by
  intro f
  induction f with
  | zero => intros; rfl
  | succ f ih => intro i; simp only [Http.headEnd.go, refHeadEnd, ih]; rfl

def refHasToken (a : ByteArray) (hi : Nat) (tok : ByteArray) (i : Nat) : Nat → Bool
  | 0 => false
  | f + 1 =>
    if i ≥ hi then false else
    let e := refFindByte a 0x2c i hi
    let s := Http.skipL a i e
    Http.eqCI a s (Http.skipR a s e) tok || refHasToken a hi tok (e + 1) f

theorem refHasToken_eq (a : ByteArray) (hi : Nat) (tok : ByteArray) :
    ∀ f i, Http.hasToken.go a hi tok i f = refHasToken a hi tok i f := by
  intro f
  induction f with
  | zero => intros; rfl
  | succ f ih => intro i; simp only [Http.hasToken.go, refHasToken, ih]; rfl

def refField (a : ByteArray) (lo hi vs ve : Nat) (f : Http.Fields) : Http.Fields :=
  if Http.eqCI a lo hi Http.hHost then { f with hosts := f.hosts + 1, hostLo := vs, hostHi := ve }
  else if Http.eqCI a lo hi Http.hContentLength then
    if vs < ve && Http.allDigits a vs ve then
      let z := Http.skipZeros a vs ve
      if !f.hasLen then { f with hasLen := true, lenLo := z, lenHi := ve }
      else if Http.sameBytes a f.lenLo f.lenHi z ve then f else { f with lenBad := true }
    else { f with lenBad := true }
  else if Http.eqCI a lo hi Http.hAuthorization then { f with auths := f.auths + 1, authLo := vs, authHi := ve }
  else if Http.eqCI a lo hi Http.hConnection then
    { f with close := f.close || refHasToken a ve Http.tClose vs (ve - vs + 1),
             keepAlive := f.keepAlive || refHasToken a ve Http.tKeepAlive vs (ve - vs + 1) }
  else if Http.eqCI a lo hi Http.hTransferEncoding then { f with coding := true }
  else f

theorem refField_eq : @Http.field = @refField := by
  funext a lo hi vs ve f
  simp only [Http.field, refField, Http.hasToken, refHasToken_eq]

def refFields (a : ByteArray) (he : Nat) (i : Nat) (f : Http.Fields) : Nat → Http.Fields
  | 0 => { f with bad := true }
  | fuel + 1 =>
    let c := Http.tokenEnd a i he
    if c == i || Http.byte a c != 0x3a then { f with bad := true } else
    let e := Http.valueEnd a (c + 1) he
    if Http.byte a e != 0x0d || Http.byte a (e + 1) != 0x0a then { f with bad := true } else
    let vs := Http.skipL a (c + 1) e
    let f := refField a i c vs (Http.skipR a vs e) f
    if he ≤ e then f else refFields a he (e + 2) f fuel

theorem refFields_eq (a : ByteArray) (he : Nat) :
    ∀ fuel i f, Http.fields a he i f fuel = refFields a he i f fuel := by
  intro fuel
  induction fuel with
  | zero => intros; rfl
  | succ fuel ih => intro i f; simp only [Http.fields, refFields, refField_eq, ih]

def refScan (a : ByteArray) (pos : Nat) : Http.Scan :=
  let lim := min a.size (pos + Http.maxHead + 4)
  let i0 := Http.skipLead a pos
  let m := Http.tokenEnd a i0 lim
  let t := Http.targetEnd a (m + 1) (min lim (m + 2 + Http.maxTarget))
  let sp := i0 < m && Http.byte a m == 0x20
  if sp && t == m + 2 + Http.maxTarget then .bad 414 else
  match refHeadEnd a lim i0 (lim - i0) with
  | none => if pos + Http.maxHead + 4 ≤ a.size then .bad 431 else .incomplete
  | some he =>
    let v := t + 1
    if !(sp && m + 1 < t && Http.byte a t == 0x20 && Http.eqAt a v (v + 7) Http.vHttp1 &&
        Http.digit (Http.byte a (v + 7)) && Http.byte a (v + 8) == 0x0d && Http.byte a (v + 9) == 0x0a) then
      .bad 400 else
    let f := if v + 8 == he then {} else refFields a he (v + 10) {} (he - (v + 10))
    if f.bad then .bad 400 else .head i0 m t (Http.byte a (v + 7) - 0x30).toNat he f

theorem refScan_eq : @Http.scan = @refScan := by
  funext a pos
  simp only [Http.scan, refScan, Http.headEnd, refHeadEnd_eq, refFields_eq]
  rfl

def refIpv4 (a : ByteArray) (lo hi : Nat) : Bool :=
  let d1 := refFindByte a 0x2e lo hi
  let d2 := refFindByte a 0x2e (d1 + 1) hi
  let d3 := refFindByte a 0x2e (d2 + 1) hi
  d3 < hi && Http.decOctet a lo d1 && Http.decOctet a (d1 + 1) d2 && Http.decOctet a (d2 + 1) d3 &&
    Http.decOctet a (d3 + 1) hi

def refGroupsGo (a : ByteArray) (hi : Nat) (v4 : Bool) (i k : Nat) : Nat → Option Nat
  | 0 => none
  | f + 1 =>
    let e := refFindByte a 0x3a i hi
    if e < hi then (if Http.h16 a i e then refGroupsGo a hi v4 (e + 1) (k + 1) f else none)
    else if Http.h16 a i hi then some (k + 1)
    else if v4 && refIpv4 a i hi then some (k + 2)
    else none

theorem refGroupsGo_eq (a : ByteArray) (hi : Nat) (v4 : Bool) :
    ∀ f i k, Http.groups.go a hi v4 i k f = refGroupsGo a hi v4 i k f := by
  intro f
  induction f with
  | zero => intros; rfl
  | succ f ih => intro i k; simp only [Http.groups.go, refGroupsGo, ih]; rfl

def refGroups (a : ByteArray) (lo hi : Nat) (v4 : Bool) : Option Nat :=
  if hi ≤ lo then some 0 else refGroupsGo a hi v4 lo 0 (hi - lo)

def refIpv6 (a : ByteArray) (lo hi : Nat) : Bool :=
  let d := Http.doubleColon a lo hi
  if d < hi then
    match refGroups a lo d false, refGroups a (d + 2) hi true with
    | some i, some j => i + j ≤ 7
    | _, _ => false
  else refGroups a lo hi true == some 8

def refIpFuture (a : ByteArray) (lo hi : Nat) : Bool :=
  let d := refFindByte a 0x2e lo hi
  lo < d && d + 1 < hi && Http.allHex a lo d && Http.allIn Http.userLo Http.userHi a (d + 1) hi

def refIpLiteral (a : ByteArray) (lo hi : Nat) : Bool :=
  if lo < hi && (Http.byte a lo == 0x76 || Http.byte a lo == 0x56) then refIpFuture a (lo + 1) hi else refIpv6 a lo hi

def refHostEnd (a : ByteArray) (lo hi : Nat) : Option Nat :=
  if lo < hi && Http.byte a lo == 0x5b then
    let r := refFindByte a 0x5d lo hi
    if r < hi && refIpLiteral a (lo + 1) r && Http.portOk a (r + 1) hi then some (r + 1) else none
  else
    let c := refFindByte a 0x3a lo hi
    if Http.uriChars Http.regLo Http.regHi a lo c && Http.portOk a c hi then some c else none

def refHostOk (a : ByteArray) (lo hi : Nat) : Bool := (refHostEnd a lo hi).isSome

def refAuthority (a : ByteArray) (lo hi : Nat) : Bool :=
  let at_ := refFindByte a 0x40 lo hi
  if at_ < hi then Http.uriChars Http.userLo Http.userHi a lo at_ && refHostOk a (at_ + 1) hi else refHostOk a lo hi

def refHierPart (a : ByteArray) (lo hi : Nat) : Bool :=
  if lo + 2 ≤ hi && Http.byte a lo == 0x2f && Http.byte a (lo + 1) == 0x2f then
    let e := refFindByte a 0x2f (lo + 2) hi
    refAuthority a (lo + 2) e && Http.uriChars Http.pathLo Http.pathHi a e hi
  else Http.uriChars Http.pathLo Http.pathHi a lo hi

def refOtherScheme (a : ByteArray) (lo hi : Nat) : Bool :=
  let c := refFindByte a 0x3a lo hi
  c < hi && lo < c && Http.alpha (Http.byte a lo) && Http.allIn Http.schemeLo Http.schemeHi a lo c &&
    !Http.eqCI a lo c Http.kHttp && !Http.eqCI a lo c Http.kHttps && refHierPart a (c + 1) hi

def refAbsolutePath (a : ByteArray) (lo hi : Nat) : Option (Nat × Nat) :=
  let s := if lo + 7 ≤ hi && Http.eqCI a lo (lo + 7) Http.kHttpSlashes then lo + 7
    else if lo + 8 ≤ hi && Http.eqCI a lo (lo + 8) Http.kHttpsSlashes then lo + 8 else lo
  if s == lo then none else
  let e := refFindByte a 0x2f s hi
  match refHostEnd a s e with
  | some h => if s < h && Http.uriChars Http.pathLo Http.pathHi a e hi then some (e, hi) else none
  | none => none

def refTarget (a : ByteArray) (lo hi : Nat) : Option (Nat × Nat) :=
  let q := refFindByte a 0x3f lo hi
  let query := hi ≤ q || Http.uriChars Http.queryLo Http.queryHi a (q + 1) hi
  if lo < q && Http.byte a lo == 0x2f then
    if query && Http.uriChars Http.pathLo Http.pathHi a lo q then some (lo, q) else none
  else match (if query then refAbsolutePath a lo q else none) with
    | some p => some p
    | none =>
      if (hi == lo + 1 && Http.byte a lo == 0x2a) ||
          (match refHostEnd a lo hi with | some h => h < hi | none => false) ||
          (query && refOtherScheme a lo q) then some (lo, lo) else none

def refFinish (a : ByteArray) : Http.Scan → Http.Parse
  | .incomplete => .incomplete
  | .bad st => .bad st
  | .head i0 m t minor he f =>
    if f.coding || f.lenBad || f.auths > 1 then .bad 400 else
    if !(if f.hosts == 0 then minor == 0 else f.hosts == 1 && refHostOk a f.hostLo f.hostHi) then .bad 400 else
    match refTarget a (m + 1) t with
    | none => .bad 400
    | some (pathLo, pathHi) =>
      let len := if f.hasLen then Http.lengthOf a f.lenLo f.lenHi else 0
      if len > Http.maxBody then .bad 413 else
      let bodyLo := he + 4
      if bodyLo + len > a.size then .incomplete else
      let head := Http.eqAt a i0 m Http.mHead
      let method :=
        if head || Http.eqAt a i0 m Http.mGet then Http.Method.get
        else if Http.eqAt a i0 m Http.mPost then Http.Method.post else Http.Method.other
      .ok { method, pathLo, pathHi, hasAuth := f.auths == 1, authLo := f.authLo, authHi := f.authHi, bodyLo,
            bodyHi := bodyLo + len, close := f.close || (minor == 0 && !f.keepAlive), next := bodyLo + len, head }

def refParse (a : ByteArray) (pos : Nat) : Http.Parse := refFinish a (refScan a pos)

theorem refIpv6_eq : @Http.ipv6 = @refIpv6 := by
  funext a lo hi
  simp only [Http.ipv6, refIpv6, Http.groups, refGroups, refGroupsGo_eq]
  rfl

theorem refHostEnd_eq : @Http.hostEnd = @refHostEnd := by
  funext a lo hi
  simp only [Http.hostEnd, refHostEnd, Http.ipLiteral, refIpLiteral, refIpv6_eq]
  rfl

theorem refFinish_eq : @Http.finish = @refFinish := by
  funext a s
  simp only [Http.finish, refFinish, Http.hostOk, refHostOk, Http.target, refTarget, Http.absolutePath,
    refAbsolutePath, Http.otherScheme, refOtherScheme, Http.hierPart, refHierPart, Http.authority, refAuthority,
    Http.hostOk, refHostEnd_eq]
  rfl

example : @Http.parse = @refParse := by
  funext a pos
  simp only [Http.parse, refParse, refFinish_eq, refScan_eq]

/-! JSON input: `Json.decodeString` and `Json.parseTop` with the reference byte operations. -/

def refDecodeGo (a : ByteArray) (hi : Nat) (i : Nat) : Nat → ByteArray → ByteArray
  | 0, out => out
  | f + 1, out =>
    if i + 1 ≥ hi then out else
    let b := Json.byte a i
    if b == 0x5c then
      let e := Json.byte a (i + 1)
      if e == 0x75 then
        let c := Json.hex4 a (i + 2)
        if 0xd800 ≤ c && c < 0xdc00 && i + 12 ≤ hi - 1 && Json.byte a (i + 6) == 0x5c && Json.byte a (i + 7) == 0x75 then
          let d := Json.hex4 a (i + 8)
          if 0xdc00 ≤ d && d < 0xe000 then refDecodeGo a hi (i + 12) f (Json.pushUtf8 out (0x10000 + (c - 0xd800) * 1024 + (d - 0xdc00)))
          else refDecodeGo a hi (i + 6) f (Json.pushUtf8 out 0xfffd)
        else if 0xd800 ≤ c && c < 0xe000 then refDecodeGo a hi (i + 6) f (Json.pushUtf8 out 0xfffd)
        else refDecodeGo a hi (i + 6) f (Json.pushUtf8 out c)
      else
        let c : UInt8 := if e == 0x62 then 0x08 else if e == 0x66 then 0x0c else if e == 0x6e then 0x0a
          else if e == 0x72 then 0x0d else if e == 0x74 then 0x09 else e
        refDecodeGo a hi (i + 2) f (out.push c)
    else if b < 0x80 then refDecodeGo a hi (i + 1) f (out.push b)
    else
      let n := if b &&& 0xe0 == 0xc0 then 2 else if b &&& 0xf0 == 0xe0 then 3 else if b &&& 0xf8 == 0xf0 then 4 else 0
      let cont (k : Nat) := k < n → (i + k < hi - 1 && Json.byte a (i + k) &&& 0xc0 == 0x80)
      let ok := n ≥ 2 && cont 1 && (n < 3 || cont 2) && (n < 4 || cont 3)
      if ok then
        let cp := if n == 2 then (b &&& 0x1f).toNat * 64 + (Json.byte a (i + 1) &&& 0x3f).toNat
          else if n == 3 then ((b &&& 0x0f).toNat * 64 + (Json.byte a (i + 1) &&& 0x3f).toNat) * 64 + (Json.byte a (i + 2) &&& 0x3f).toNat
          else (((b &&& 0x07).toNat * 64 + (Json.byte a (i + 1) &&& 0x3f).toNat) * 64 + (Json.byte a (i + 2) &&& 0x3f).toNat) * 64 + (Json.byte a (i + 3) &&& 0x3f).toNat
        let minCp := if n == 2 then 0x80 else if n == 3 then 0x800 else 0x10000
        if cp < minCp || (0xd800 ≤ cp && cp < 0xe000) || cp > 0x10ffff then refDecodeGo a hi (i + 1) f (Json.pushUtf8 out 0xfffd)
        else refDecodeGo a hi (i + n) f (refAppendSlice out a i (i + n))
      else refDecodeGo a hi (i + 1) f (Json.pushUtf8 out 0xfffd)

theorem refDecodeGo_eq (a : ByteArray) (hi : Nat) :
    ∀ f i out, Json.decodeString.go a hi i f out = refDecodeGo a hi i f out := by
  intro f
  induction f with
  | zero => intros; rfl
  | succ f ih => intro i out; simp only [Json.decodeString.go, refDecodeGo, ih]; rfl

def refDecodeString (a : ByteArray) (lo hi : Nat) : ByteArray :=
  let hi := min hi a.size
  refDecodeGo a hi (lo + 1) (hi - lo) (ByteArray.emptyWithCapacity (hi - lo))

theorem decodeString_eq_ref : @Json.decodeString = @refDecodeString := by
  funext a lo hi
  simp only [Json.decodeString, refDecodeString, refDecodeGo_eq]

def refKeyEq (a : ByteArray) (klo khi : Nat) (key : ByteArray) : Bool :=
  if refFindByte a 0x5c klo khi == min khi a.size then Json.spanEq a klo khi key
  else
    let d := refDecodeString a (klo - 1) (khi + 1)
    d.size == key.size && Json.spanEq d 0 d.size key

def refRecordGo (a : ByteArray) (klo khi vlo vhi : Nat) (keys : Array ByteArray) (k : Nat) :
    Nat → Array Json.Field → Array Json.Field
  | 0, fs => fs
  | f + 1, fs =>
    if refKeyEq a klo khi (keys[k]!) then fs.set! k ⟨Json.kindAt a vlo, vlo, vhi⟩ else refRecordGo a klo khi vlo vhi keys (k + 1) f fs

theorem refRecordGo_eq (a : ByteArray) (klo khi vlo vhi : Nat) (keys : Array ByteArray) :
    ∀ f k fs, Json.recordField.go a klo khi vlo vhi keys k f fs = refRecordGo a klo khi vlo vhi keys k f fs := by
  have hk : ∀ key, Json.keyEq a klo khi key = refKeyEq a klo khi key := by
    intro key
    simp only [Json.keyEq, refKeyEq, decodeString_eq_ref]
    rfl
  intro f
  induction f with
  | zero => intros; rfl
  | succ f ih => intro k fs; simp only [Json.recordField.go, refRecordGo, ih, hk]

def refTopMembers (a : ByteArray) (hi : Nat) (keys : Array ByteArray) (i : Nat) (first : Bool) (fs : Array Json.Field) :
    Nat → Option (Nat × Array Json.Field)
  | 0 => none
  | f + 1 =>
    if i ≥ hi then none
    else if first && Json.byte a i == 0x7d then some (i + 1, fs)
    else if Json.byte a i != 0x22 then none
    else do
      let j ← Json.scanString a hi (i + 1)
      let klo := i + 1
      let khi := j - 1
      let j := Json.skipWs a hi j
      if j ≥ hi || Json.byte a j != 0x3a then none
      let vlo := Json.skipWs a hi (j + 1)
      let k ← Json.scanValue a hi vlo f
      let fs := refRecordGo a klo khi vlo k keys 0 keys.size fs
      let k := Json.skipWs a hi k
      if k ≥ hi then none
      else if Json.byte a k == 0x7d then some (k + 1, fs)
      else if Json.byte a k == 0x2c then refTopMembers a hi keys (Json.skipWs a hi (k + 1)) false fs f
      else none

theorem refTopMembers_eq (a : ByteArray) (hi : Nat) (keys : Array ByteArray) :
    ∀ f i first fs, Json.topMembers a hi keys i first fs f = refTopMembers a hi keys i first fs f := by
  intro f
  induction f with
  | zero => intros; rfl
  | succ f ih =>
    intro i first fs
    simp only [Json.topMembers, refTopMembers, ih, Json.recordField, refRecordGo_eq]

def refParseTop (a : ByteArray) (lo hi : Nat) (keys : Array ByteArray) : Json.Top :=
  let hi := min hi a.size
  let i := Json.skipWs a hi lo
  let fuel := hi - lo + 1
  if i < hi && Json.byte a i == 0x7b then
    match refTopMembers a hi keys (Json.skipWs a hi (i + 1)) true (Array.replicate keys.size ⟨.absent, 0, 0⟩) fuel with
    | none => .malformed
    | some (j, fs) => if Json.skipWs a hi j == hi then .object fs else .malformed
  else
    match Json.scanValue a hi i fuel with
    | none => .malformed
    | some j => if Json.skipWs a hi j == hi then .notObject else .malformed

example : @Json.parseTop = @refParseTop := by
  funext a lo hi keys
  simp only [Json.parseTop, refParseTop, refTopMembers_eq]
  rfl

example : @Hmac.mac = @refMac := rfl
example : @Jwt.b64Encode = @refB64Encode := rfl
example : @Jwt.b64Decode = @refB64Decode := rfl

/-! ## Random inputs -/

structure Rng where
  s : UInt64

def Rng.next (g : Rng) : UInt64 × Rng :=
  let x := g.s ^^^ (g.s <<< 13)
  let x := x ^^^ (x >>> 7)
  let x := x ^^^ (x <<< 17)
  (x, ⟨x⟩)

def Rng.below (g : Rng) (n : Nat) : Nat × Rng :=
  let (x, g) := g.next
  (x.toNat % (max n 1), g)

/-- A byte, often one that JSON escapes or HTTP framing looks for. -/
def Rng.byte (g : Rng) : UInt8 × Rng :=
  let (k, g) := g.below 8
  let (x, g) := g.next
  let special : Array UInt8 := #[0x22, 0x5c, 0x00, 0x08, 0x0c, 0x0a, 0x0d, 0x09, 0x1f, 0x7f, 0x80, 0xff, 0x2e, 0x3a, 0x20]
  if k < 3 then (special[x.toNat % special.size]!, g) else (x.toUInt8, g)

def Rng.bytes (g : Rng) (maxLen : Nat) : ByteArray × Rng := Id.run do
  let (n, g0) := g.below (maxLen + 1)
  let mut g := g0
  -- spare capacity varies, so that the C side's reads past the size are exercised
  let (spare, g1) := g.below 64
  g := g1
  let mut a := ByteArray.emptyWithCapacity (n + spare)
  for _ in [0:n] do
    let (b, g') := g.byte
    a := a.push b
    g := g'
  return (a, g)

/-- Bytes of which few need escaping (about one in a hundred): long plain runs, which the leaves
copy 32 bytes at a time. -/
def Rng.plainBytes (g : Rng) (maxLen : Nat) : ByteArray × Rng := Id.run do
  let (n, g0) := g.below (maxLen + 1)
  let mut g := g0
  let (spare, g1) := g.below 64
  g := g1
  let mut a := ByteArray.emptyWithCapacity (n + spare)
  for _ in [0:n] do
    let (k, g2) := g.below 64
    let (x, g3) := g2.next
    let (b, g4) := g3.byte
    a := a.push (if k == 0 then b else x.toUInt8 ||| 0x20)
    g := g4
  return (a, g)

/-- A range bound: usually inside the array, sometimes past it. -/
def Rng.bound (g : Rng) (size : Nat) : Nat × Rng :=
  let (k, g) := g.below 10
  if k == 0 then g.below (size + 100) else g.below (size + 1)

def Rng.nat (g : Rng) : Nat × Rng :=
  let (k, g) := g.below 6
  let (x, g) := g.next
  let (y, g) := g.next
  if k == 0 then (x.toNat * 2 ^ 64 + y.toNat, g)       -- beyond 64 bits
  else if k == 1 then (x.toNat, g)                    -- up to 64 bits
  else if k == 2 then ((x % 10).toNat, g)
  else ((x % 1000000).toNat, g)

/-! ## The checks -/

/-- A copy of `a` that the leaf may update in place, with `spare` bytes of room. -/
def fresh (a : ByteArray) (spare : Nat) : ByteArray :=
  a.foldl (fun b x => b.push x) (ByteArray.emptyWithCapacity (a.size + spare))

def checkLeaves (rounds : Nat) : Except String Unit := Id.run do
  let mut g : Rng := ⟨0x9e3779b97f4a7c15⟩
  for i in [0:rounds] do
    let (out, g1) := g.bytes 40
    let (src, g2) := if i % 2 == 0 then g1.bytes 300 else g1.plainBytes 300
    let (lo, g3) := g2.bound src.size
    let (hi, g4) := g3.bound src.size
    let (n, g5) := g4.nat
    let (b, g6) := g5.byte
    -- room in `out`: usually little, sometimes enough for a leaf to write in place
    let (big, g6) := g6.below 4
    let (spare, g7) := g6.below (if big == 0 then 2400 else 80)
    g := g7
    if appendEsc (fresh out spare) src lo hi != refAppendEsc out src lo hi then
      return .error s!"appendEsc differs (round {i})"
    if appendNat (fresh out spare) n != refAppendNat out n then
      return .error s!"appendNat differs (round {i}, n = {n})"
    if appendAll (fresh out spare) src != refAppendAll out src then
      return .error s!"appendAll differs (round {i})"
    if findByte src b lo hi != refFindByte src b lo hi then
      return .error s!"findByte differs (round {i})"
  return .ok ()

/-- A range of an array of `size` bytes: usually in order inside it, sometimes anywhere (empty,
reversed, past the end, beyond 64 bits). -/
def Rng.range (g : Rng) (size : Nat) : (Nat × Nat) × Rng :=
  let (k, g) := g.below 8
  let (lo, g) := g.bound size
  let (len, g) := g.below (if k == 0 then 600 else 120)
  let (hi, g) := g.bound size
  let (x, g) := g.next
  if k == 1 then ((lo, hi), g)
  else if k == 2 then ((2 ^ 64 + x.toNat, lo), g)
  else if k == 3 then ((lo, 2 ^ 64 + x.toNat), g)
  else ((lo, lo + len), g)

/-- A random page: rows of ranges into the blob (some of them adjacent, as the storage layer lays
them out), found flags mostly 1, numbers of every size, sometimes columns past the last row. The
blob is mostly text without bytes to escape, so both of the leaf's paths run. -/
def Rng.page (g : Rng) : Page × Rng := Id.run do
  let (kind, g) := g.below 4
  let (blob, g) := if kind == 0 then g.bytes 900 else g.plainBytes 900
  -- kinds 2 and 3: no byte to escape, or exactly one, anywhere
  let blob := if kind ≥ 2 then blob.data.foldl (fun a x =>
    a.push (if x == 0x22 || x == 0x5c || x < 0x20 then 0x61 else x)) (ByteArray.emptyWithCapacity (blob.size + blob.size % 37))
    else blob
  let (pos, g) := g.below blob.size
  let (esc, g) := g.below 32
  let blob := if kind == 3 && blob.size > 0 then blob.set! pos (if esc == 0 then 0x22 else if esc == 1 then 0x5c else esc.toUInt8) else blob
  let (rows, g) := g.below 30
  let mut g := g
  let mut cols : Array Nat := #[]
  for _ in [0:rows] do
    let (id, g1) := g.nat
    let ((b, c), g2) := g1.range blob.size
    let (elen, g3) := g2.below 30
    let (f, g4) := g3.below 12
    let (big, g5) := g4.nat
    let ((s, t), g6) := g5.range blob.size
    let (likes, g7) := g6.nat
    g := g7
    let found := if f < 9 then 1 else if f == 9 then 0 else if f == 10 then 2 else 2 ^ 64 + big
    cols := cols ++ #[id, b, c, c + elen, found, s, t, likes]
  let (extra, g8) := g.below 16
  g := g8
  if extra < 8 then
    for j in [0:extra] do cols := cols.push (j + 1)
  return (⟨blob, cols⟩, g)

/-- The page leaf against its Lean definition. -/
def checkPages (rounds : Nat) : Except String Unit := Id.run do
  let mut g : Rng := ⟨0x5851f42d4c957f2d⟩
  for i in [0:rounds] do
    let (pg, g1) := g.page
    let (body, g2) := g1.bytes 40
    let (big, g3) := g2.below 4
    let (spare, g4) := g3.below (if big == 0 then 9000 else 100)
    g := g4
    let want := refFeedFromPage body pg
    if feedFromPage (fresh body spare) pg != want then
      return .error s!"feedFromPage differs (round {i})"
    -- a shared body: the leaf must not write into it
    if feedFromPage body pg != want then
      return .error s!"feedFromPage differs on a shared body (round {i})"
  return .ok ()

/-! ### Responses written in place -/

def refRespond (out : ByteArray) (status : Nat) (body : ByteArray) (close : Bool) : ByteArray :=
  let out := if out.size == 0 then ByteArray.emptyWithCapacity (body.size + 160) else out
  let out := refAppendAll out (statusLine status)
  let out := refAppendNat out body.size
  let out := refAppendAll out (if close then endHeadClose else endHead)
  refAppendAll out body

example : @respond = @refRespond := rfl

theorem feedFromPage_eq_ref : @feedFromPage = @refFeedFromPage := by
  funext body pg
  simp only [feedFromPage, refFeedFromPage, renderPage, refRenderGo_eq]
  rfl

def refRespondFeed (out : ByteArray) (pg : Page) (close : Bool) : ByteArray :=
  refRespond out 200 (refFeedFromPage ByteArray.empty pg).1 close

example : @respondFeed = @refRespondFeed := by
  funext out pg close
  simp only [respondFeed, refRespondFeed, feedFromPage_eq_ref]
  rfl

def refAuthored (pg : Page) (limit : Nat) : Nat := Page.authored.go pg limit 0 (pg.cols.size / 8) 0

example : @Page.authored = @refAuthored := rfl

/-- A page as the storage layer returns them: no byte of the text to escape, numbers below
`2^63`, found flags 0 or 1 (ranges may still lie anywhere). -/
def tamePage (pg : Page) : Page :=
  ⟨pg.blob.data.foldl (fun a x => a.push (if x == 0x22 || x == 0x5c || x < 0x20 then 0x61 else x))
      (ByteArray.emptyWithCapacity (pg.blob.size + pg.blob.size % 37)),
    (pg.cols.zipIdx).map fun (x, j) => if j % 8 == 4 then (if x == 1 then 1 else 0) else x % 2 ^ 63⟩

/-- The feed's response and the count of rows with an author against their Lean definitions, on
random pages (half of them tame), appended to outputs that are empty, shared or not, with room or
without. -/
def checkFeedResponses (rounds : Nat) : Except String Unit := Id.run do
  let mut g : Rng := ⟨0x2b992ddfa23249d6⟩
  for i in [0:rounds] do
    let (pg, g1) := g.page
    let pg := if i % 2 == 0 then tamePage pg else pg
    let (out, g2) := g1.bytes 40
    let (kind, g3) := g2.below 4
    let (spare, g4) := g3.below (if kind == 0 then 9000 else 100)
    let (cl, g5) := g4.below 2
    let (lim, g6) := g5.below 26
    g := g6
    let out := if kind == 1 then ByteArray.empty else out
    let close := cl == 1
    let want := refRespondFeed out pg close
    if respondFeed (fresh out spare) pg close != want then
      return .error s!"respondFeed differs (round {i})"
    -- a shared output: the leaf must not write into it
    let keep := fresh out 0
    if respondFeed out pg close != want then
      return .error s!"respondFeed differs on a shared output (round {i})"
    if out != keep then
      return .error s!"respondFeed wrote into a shared output (round {i})"
    let lim := if lim == 25 then 2 ^ 64 + i else lim
    if pg.authored lim != refAuthored pg lim then
      return .error s!"Page.authored differs (round {i})"
  return .ok ()

def refPostFromPage (scratch : ByteArray) (id : Nat) (pg : Page) : Bool × ByteArray :=
  if pg.cols.size < 8 || pg.cols[4]! != 1 then (false, scratch) else
  let out := refAppendAll ByteArray.empty kPostWrap
  let out := refPostJsonAfter out kId id pg.blob pg.cols[1]! pg.cols[2]! pg.cols[3]! pg.blob pg.cols[5]! pg.cols[6]!
    pg.cols[7]!
  (true, refAppendAll out kWrapEnd)

example : @postFromPage = @refPostFromPage := rfl

def refRespondPost (out : ByteArray) (id : Nat) (pg : Page) (close : Bool) : ByteArray :=
  refRespond out 200 (refPostFromPage ByteArray.empty id pg).2 close

example : @respondPost = @refRespondPost := rfl

/-- A post's response against its Lean definition, on random pages (half of them tame) and ids,
appended to outputs that are empty, shared or not, with room or without. -/
def checkPostResponses (rounds : Nat) : Except String Unit := Id.run do
  let mut g : Rng := ⟨0x7c3f1a9e5b2d4c81⟩
  for i in [0:rounds] do
    let (pg, g1) := g.page
    let pg := if i % 2 == 0 then tamePage pg else pg
    let (id, g2) := g1.nat
    let (out, g3) := g2.bytes 40
    let (kind, g4) := g3.below 4
    let (spare, g5) := g4.below (if kind == 0 then 2000 else 100)
    let (cl, g6) := g5.below 2
    g := g6
    let out := if kind == 1 then ByteArray.empty else out
    let close := cl == 1
    let want := refRespondPost out id pg close
    if respondPost (fresh out spare) id pg close != want then
      return .error s!"respondPost differs (round {i})"
    -- a shared output: the leaf must not write into it
    let keep := fresh out 0
    if respondPost out id pg close != want then
      return .error s!"respondPost differs on a shared output (round {i})"
    if out != keep then
      return .error s!"respondPost wrote into a shared output (round {i})"
  return .ok ()

/-! ### HTTP requests

The C `Http.parse` (`runtime/leaves.c`) is checked against its Lean definition with each byte value
in each place of a request where the parser tells bytes apart, and on random request-like inputs
(after the C1 package's fuzzers): at the start, at the next request, inside, at and past the end,
with room after the input, and on their prefixes. It is checked against the frames
`Feed/Spec/Http.lean` gives a list of inputs, examples of the rules of RFC 9112 and RFC 9110 that it
follows and of each choice listed there (read off the specification, and computed by an executable
reading of it written apart from the parser), at the start of the input and after other bytes.
These compare the C with frames read off the specification; the Lean definition computes the
specification's frames (`Http.parse_view`), so on the random inputs the comparisons with it compare
the C with the specification too. On those it is also checked against itself: a prefix of an input
reads as a wait or as the whole input does (`Spec.Http.frame_append`; every prefix of an input of
up to 2,048 bytes, those of `prefixLengths` of a longer one), and the input reads the same after
other bytes. -/

def parseEq : Http.Parse → Http.Parse → Bool
  | .incomplete, .incomplete => true
  | .bad s, .bad t => s == t
  | .ok r, .ok q =>
    r.method == q.method && r.pathLo == q.pathLo && r.pathHi == q.pathHi && r.hasAuth == q.hasAuth &&
    r.authLo == q.authLo && r.authHi == q.authHi && r.bodyLo == q.bodyLo && r.bodyHi == q.bodyHi &&
    r.close == q.close && r.next == q.next && r.head == q.head
  | _, _ => false

/-- A parse of the input after `d` other bytes, as without them: the request's positions `d` lower. -/
def unshift (d : Nat) : Http.Parse → Http.Parse
  | .ok r =>
    .ok { r with
      pathLo := r.pathLo - d, pathHi := r.pathHi - d, authLo := r.authLo - d, authHi := r.authHi - d,
      bodyLo := r.bodyLo - d, bodyHi := r.bodyHi - d, next := r.next - d }
  | p => p

/-- A frame as the examples write it: method, HEAD, path, Authorization value, content, close, and
the length of the request. -/
inductive Want where
  | wait
  | bad (status : Nat)
  | ok (method : Http.Method) (head : Bool) (path : String) (auth : Option String) (body : String) (close : Bool)
      (len : Nat)

def rep (n : Nat) (s : String) : String := String.join (List.replicate n s)

/-- The inputs and their frames (`Spec.Http.frame`). -/
def httpExamples : Array (String × String × Want) := #[
  ("a request", "GET /feed HTTP/1.1\r\nHost: x\r\n\r\n", .ok .get false "/feed" none "" false 31),
  ("no Host in HTTP/1.1", "GET /feed HTTP/1.1\r\n\r\n", .bad 400),
  ("no Host in HTTP/1.0, which closes", "GET /feed HTTP/1.0\r\n\r\n", .ok .get false "/feed" none "" true 22),
  ("HTTP/1.0 with a bad Host", "GET /feed HTTP/1.0\r\nHost: a b\r\n\r\n", .bad 400),
  ("HTTP/1.0 keep-alive", "GET /feed HTTP/1.0\r\nConnection: keep-alive\r\n\r\n",
    .ok .get false "/feed" none "" false 46),
  ("HTTP/1.0 keep-alive and close", "GET /feed HTTP/1.0\r\nConnection: keep-alive, close\r\n\r\n",
    .ok .get false "/feed" none "" true 53),
  ("close among options, any case", "GET /feed HTTP/1.1\r\nHost: x\r\nConnection: Upgrade, CLOSE\r\n\r\n",
    .ok .get false "/feed" none "" true 59),
  ("two Host lines", "GET /feed HTTP/1.1\r\nHost: x\r\nHost: x\r\n\r\n", .bad 400),
  ("Host: a b", "GET /feed HTTP/1.1\r\nHost: a b\r\n\r\n", .bad 400),
  ("Host: [::1]:3000", "GET /feed HTTP/1.1\r\nHost: [::1]:3000\r\n\r\n", .ok .get false "/feed" none "" false 40),
  ("Host: [v1.x]", "GET /feed HTTP/1.1\r\nHost: [v1.x]\r\n\r\n", .ok .get false "/feed" none "" false 36),
  ("Host: [::ffff:1.2.3.4]", "GET /feed HTTP/1.1\r\nHost: [::ffff:1.2.3.4]\r\n\r\n",
    .ok .get false "/feed" none "" false 46),
  ("Host: [1::2::3]", "GET /feed HTTP/1.1\r\nHost: [1::2::3]\r\n\r\n", .bad 400),
  ("Host: [1:2:3:4:5:6::1.2.3.4]", "GET /feed HTTP/1.1\r\nHost: [1:2:3:4:5:6::1.2.3.4]\r\n\r\n", .bad 400),
  ("Host: u@h", "GET /feed HTTP/1.1\r\nHost: u@h\r\n\r\n", .bad 400),
  ("an empty Host", "GET /feed HTTP/1.1\r\nHost:\r\n\r\n", .ok .get false "/feed" none "" false 29),
  ("Host: sub-delims and unreserved", "GET /feed HTTP/1.1\r\nHost: a!$&'()*+,;=-._~b\r\n\r\n",
    .ok .get false "/feed" none "" false 47),
  ("Host: a percent-encoding", "GET /feed HTTP/1.1\r\nHost: a%2Fb\r\n\r\n", .ok .get false "/feed" none "" false 35),
  ("Host: a bad percent-encoding", "GET /feed HTTP/1.1\r\nHost: a%zz\r\n\r\n", .bad 400),
  ("Host: an empty port", "GET /feed HTTP/1.1\r\nHost: x:\r\n\r\n", .ok .get false "/feed" none "" false 32),
  ("Host: a port with a letter", "GET /feed HTTP/1.1\r\nHost: x:8a\r\n\r\n", .bad 400),
  ("Host: two ports", "GET /feed HTTP/1.1\r\nHost: x:80:80\r\n\r\n", .bad 400),
  ("Host: eight groups", "GET /feed HTTP/1.1\r\nHost: [1:2:3:4:5:6:7:8]\r\n\r\n",
    .ok .get false "/feed" none "" false 47),
  ("Host: seven groups", "GET /feed HTTP/1.1\r\nHost: [1:2:3:4:5:6:7]\r\n\r\n", .bad 400),
  ("Host: nine groups", "GET /feed HTTP/1.1\r\nHost: [1:2:3:4:5:6:7:8:9]\r\n\r\n", .bad 400),
  ("Host: six groups and an IPv4 address", "GET /feed HTTP/1.1\r\nHost: [1:2:3:4:5:6:1.2.3.4]\r\n\r\n",
    .ok .get false "/feed" none "" false 51),
  ("Host: [::]", "GET /feed HTTP/1.1\r\nHost: [::]\r\n\r\n", .ok .get false "/feed" none "" false 34),
  ("Host: seven groups and ::", "GET /feed HTTP/1.1\r\nHost: [1:2:3:4:5:6:7::]\r\n\r\n",
    .ok .get false "/feed" none "" false 47),
  ("Host: eight groups around ::", "GET /feed HTTP/1.1\r\nHost: [1:2:3:4:5:6:7::8]\r\n\r\n", .bad 400),
  ("Host: an IPv4 address before ::", "GET /feed HTTP/1.1\r\nHost: [1.2.3.4::]\r\n\r\n", .bad 400),
  ("Host: [::1.2.3.4]", "GET /feed HTTP/1.1\r\nHost: [::1.2.3.4]\r\n\r\n", .ok .get false "/feed" none "" false 41),
  ("Host: a group of five digits", "GET /feed HTTP/1.1\r\nHost: [12345::]\r\n\r\n", .bad 400),
  ("Host: a group that is not hex", "GET /feed HTTP/1.1\r\nHost: [g::]\r\n\r\n", .bad 400),
  ("Host: a group that is not hex, then a colon", "GET /feed HTTP/1.1\r\nHost: [g:1::]\r\n\r\n", .bad 400),
  ("Host: groups in both cases", "GET /feed HTTP/1.1\r\nHost: [ABCD:abcd::]\r\n\r\n",
    .ok .get false "/feed" none "" false 43),
  ("Host: an octet with a leading zero", "GET /feed HTTP/1.1\r\nHost: [::1.2.3.04]\r\n\r\n", .bad 400),
  ("Host: an octet 00", "GET /feed HTTP/1.1\r\nHost: [::1.2.3.00]\r\n\r\n", .bad 400),
  ("Host: an octet of 256", "GET /feed HTTP/1.1\r\nHost: [::1.2.3.256]\r\n\r\n", .bad 400),
  ("Host: octets of 255 and 0", "GET /feed HTTP/1.1\r\nHost: [::255.0.0.255]\r\n\r\n",
    .ok .get false "/feed" none "" false 45),
  ("Host: an octet of four digits", "GET /feed HTTP/1.1\r\nHost: [::1.2.3.0004]\r\n\r\n", .bad 400),
  ("Host: three octets", "GET /feed HTTP/1.1\r\nHost: [::1.2.3]\r\n\r\n", .bad 400),
  ("Host: five octets", "GET /feed HTTP/1.1\r\nHost: [::1.2.3.4.5]\r\n\r\n", .bad 400),
  ("Host: an empty octet", "GET /feed HTTP/1.1\r\nHost: [::1..3.4]\r\n\r\n", .bad 400),
  ("Host: [V1.x]", "GET /feed HTTP/1.1\r\nHost: [V1.x]\r\n\r\n", .ok .get false "/feed" none "" false 36),
  ("Host: IPvFuture without hex", "GET /feed HTTP/1.1\r\nHost: [v.x]\r\n\r\n", .bad 400),
  ("Host: IPvFuture with nothing after the dot", "GET /feed HTTP/1.1\r\nHost: [v1.]\r\n\r\n", .bad 400),
  ("Host: IPvFuture with no dot", "GET /feed HTTP/1.1\r\nHost: [v1]\r\n\r\n", .bad 400),
  ("Host: IPvFuture that is not hex", "GET /feed HTTP/1.1\r\nHost: [vg.x]\r\n\r\n", .bad 400),
  ("Host: IPvFuture with a colon", "GET /feed HTTP/1.1\r\nHost: [v1.a:b]\r\n\r\n",
    .ok .get false "/feed" none "" false 38),
  ("Host: IPvFuture with a slash", "GET /feed HTTP/1.1\r\nHost: [v1.a/b]\r\n\r\n", .bad 400),
  ("Host: bytes after the bracket", "GET /feed HTTP/1.1\r\nHost: [::1]x\r\n\r\n", .bad 400),
  ("Host: no closing bracket", "GET /feed HTTP/1.1\r\nHost: [::1\r\n\r\n", .bad 400),
  ("Host: []", "GET /feed HTTP/1.1\r\nHost: []\r\n\r\n", .bad 400),
  ("Host: a bracket in a reg-name", "GET /feed HTTP/1.1\r\nHost: a[::1]\r\n\r\n", .bad 400),
  ("whitespace before the colon", "POST /posts HTTP/1.1\r\nHost: x\r\nContent-Length : 5\r\n\r\nhello", .bad 400),
  ("obs-fold", "GET /feed HTTP/1.1\r\nHost: x\r\n x:y\r\n\r\n", .bad 400),
  ("a bare CR", "GET /feed HTTP/1.1\r\nHost: x\r\r\nConnection: close\r\n\r\n", .bad 400),
  ("a bare LF", "GET /feed HTTP/1.1\r\nHost: x\nY: z\r\n\r\n", .bad 400),
  ("NUL in a value", "GET /feed HTTP/1.1\r\nHost: x\r\nConnection: close\x00\r\n\r\n", .bad 400),
  ("DEL in a value", "GET /feed HTTP/1.1\r\nHost: x\r\nX: a\x7fb\r\n\r\n", .bad 400),
  ("obs-text in a value", "GET /feed HTTP/1.1\r\nHost: x\r\nX: café\r\n\r\n", .ok .get false "/feed" none "" false 41),
  ("HTAB inside a value", "GET /feed HTTP/1.1\r\nHost: x\r\nX: a\tb\r\n\r\n", .ok .get false "/feed" none "" false 39),
  ("a field name of tchars", "GET /feed HTTP/1.1\r\nHost: x\r\n!#$%&'*+-.^_`|~: v\r\n\r\n",
    .ok .get false "/feed" none "" false 51),
  ("a field name with (", "GET /feed HTTP/1.1\r\nHost: x\r\nX(: v\r\n\r\n", .bad 400),
  ("an empty field name", "GET /feed HTTP/1.1\r\nHost: x\r\n: v\r\n\r\n", .bad 400),
  ("Content-Length with 16 digits", "POST /posts HTTP/1.1\r\nHost: x\r\nContent-Length: 0000000000000005\r\n\r\nhello",
    .ok .post false "/posts" none "hello" false 72),
  ("Content-Length 5 and 05", "POST /posts HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nContent-Length: 05\r\n\r\n" ++
    "hello",
    .ok .post false "/posts" none "hello" false 77),
  ("Content-Length 5 and 6", "POST /posts HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nContent-Length: 6\r\n\r\nhello",
    .bad 400),
  ("Content-Length 5, 5", "POST /posts HTTP/1.1\r\nHost: x\r\nContent-Length: 5, 5\r\n\r\nhello", .bad 400),
  ("Content-Length over maxBody", "POST /posts HTTP/1.1\r\nHost: x\r\nContent-Length: 16385\r\n\r\n", .bad 413),
  ("Content-Length maxBody, no content yet", "POST /posts HTTP/1.1\r\nHost: x\r\nContent-Length: 16384\r\n\r\n", .wait),
  ("Content-Length of 23 digits, twice", "POST /posts HTTP/1.1\r\nHost: x\r\n" ++
    "Content-Length: 99999999999999999999999\r\nContent-Length: 099999999999999999999999\r\n\r\n",
    .bad 413),
  ("two Content-Length of 23 digits that differ", "POST /posts HTTP/1.1\r\nHost: x\r\n" ++
    "Content-Length: 99999999999999999999999\r\nContent-Length: 99999999999999999999998\r\n\r\n",
    .bad 400),
  ("Content-Length 5a", "POST /posts HTTP/1.1\r\nHost: x\r\nContent-Length: 5a\r\n\r\nhello", .bad 400),
  ("an empty Content-Length", "POST /posts HTTP/1.1\r\nHost: x\r\nContent-Length:\r\n\r\nhello", .bad 400),
  ("absolute-form", "GET http://127.0.0.1:3000/feed HTTP/1.1\r\nHost: 127.0.0.1:3000\r\n\r\n",
    .ok .get false "/feed" none "" false 65),
  ("absolute-form https with a query", "GET https://x/posts/1?a=b HTTP/1.1\r\nHost: x\r\n\r\n",
    .ok .get false "/posts/1" none "" false 47),
  ("absolute-form, the scheme in capitals", "GET HTTP://X/feed HTTP/1.1\r\nHost: x\r\n\r\n",
    .ok .get false "/feed" none "" false 39),
  ("absolute-form with userinfo", "GET http://u@h/feed HTTP/1.1\r\nHost: x\r\n\r\n", .bad 400),
  ("absolute-form with an empty host", "GET http:///feed HTTP/1.1\r\nHost: x\r\n\r\n", .bad 400),
  ("absolute-form with no path", "GET http://x HTTP/1.1\r\nHost: x\r\n\r\n", .ok .get false "" none "" false 34),
  ("absolute-form with a query and no path", "GET http://x?a=b HTTP/1.1\r\nHost: x\r\n\r\n",
    .ok .get false "" none "" false 38),
  ("absolute-form with an IP-literal", "GET http://[::1]:3000/feed HTTP/1.1\r\nHost: x\r\n\r\n",
    .ok .get false "/feed" none "" false 48),
  ("absolute-form with an empty port", "GET http://x:/feed HTTP/1.1\r\nHost: x\r\n\r\n",
    .ok .get false "/feed" none "" false 40),
  ("absolute-form with a bad port", "GET http://x:a/feed HTTP/1.1\r\nHost: x\r\n\r\n", .bad 400),
  ("absolute-form with a bad host", "GET http://[::1/feed HTTP/1.1\r\nHost: x\r\n\r\n", .bad 400),
  ("absolute-form with a fragment", "GET http://x/feed#f HTTP/1.1\r\nHost: x\r\n\r\n", .bad 400),
  ("absolute-form with a bad path", "GET http://x/fe{d HTTP/1.1\r\nHost: x\r\n\r\n", .bad 400),
  ("https without //", "GET https:x HTTP/1.1\r\nHost: x\r\n\r\n", .bad 400),
  ("httpx is another scheme", "GET httpx://x/feed HTTP/1.1\r\nHost: x\r\n\r\n", .ok .get false "" none "" false 40),
  ("another scheme", "GET ftp://x/feed HTTP/1.1\r\nHost: x\r\n\r\n", .ok .get false "" none "" false 38),
  ("asterisk-form", "OPTIONS * HTTP/1.1\r\nHost: x\r\n\r\n", .ok .other false "" none "" false 31),
  ("authority-form", "CONNECT x:80 HTTP/1.1\r\nHost: x\r\n\r\n", .ok .other false "" none "" false 34),
  ("foo:[", "GET foo:[ HTTP/1.1\r\nHost: x\r\n\r\n", .bad 400),
  ("foo://[::1", "GET foo://[::1 HTTP/1.1\r\nHost: x\r\n\r\n", .bad 400),
  ("**", "GET ** HTTP/1.1\r\nHost: x\r\n\r\n", .bad 400),
  ("authority-form with an empty port", "CONNECT x: HTTP/1.1\r\nHost: x\r\n\r\n", .ok .other false "" none "" false 32),
  ("authority-form with an IP-literal", "CONNECT [::1]:80 HTTP/1.1\r\nHost: x\r\n\r\n",
    .ok .other false "" none "" false 38),
  ("a host without a port", "CONNECT x HTTP/1.1\r\nHost: x\r\n\r\n", .bad 400),
  ("another scheme with a path", "GET mailto:a@b HTTP/1.1\r\nHost: x\r\n\r\n", .ok .get false "" none "" false 36),
  ("a scheme with + - .", "GET a+b.c-d:x HTTP/1.1\r\nHost: x\r\n\r\n", .ok .get false "" none "" false 35),
  ("a scheme that starts with a digit", "GET 1a:x HTTP/1.1\r\nHost: x\r\n\r\n", .bad 400),
  ("another scheme with an empty path", "GET foo: HTTP/1.1\r\nHost: x\r\n\r\n", .ok .get false "" none "" false 30),
  ("another scheme with a query", "GET foo:?q HTTP/1.1\r\nHost: x\r\n\r\n", .ok .get false "" none "" false 32),
  ("another scheme with userinfo", "GET foo://u@h/p HTTP/1.1\r\nHost: x\r\n\r\n", .ok .get false "" none "" false 37),
  ("another scheme with a colon in the userinfo", "GET foo://u:p@h/x HTTP/1.1\r\nHost: x\r\n\r\n",
    .ok .get false "" none "" false 39),
  ("another scheme with a bad userinfo", "GET foo://u[@h/p HTTP/1.1\r\nHost: x\r\n\r\n", .bad 400),
  ("another scheme with a bad path after its authority", "GET foo://h/a{b HTTP/1.1\r\nHost: x\r\n\r\n", .bad 400),
  ("another scheme with a bad path", "GET foo:a{b HTTP/1.1\r\nHost: x\r\n\r\n", .bad 400),
  ("two Authorization lines", "GET /feed HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer a\r\n" ++
    "Authorization: Bearer b\r\n\r\n",
    .bad 400),
  ("Authorization with OWS", "POST /posts HTTP/1.1\r\nHost: x\r\nAuthorization:  Bearer abc  \r\n\r\n",
    .ok .post false "/posts" (some "Bearer abc") "" false 63),
  ("HEAD", "HEAD /feed HTTP/1.1\r\nHost: x\r\n\r\n", .ok .get true "/feed" none "" false 32),
  ("leading empty lines", "\r\n\r\nGET /feed HTTP/1.1\r\nHost: x\r\n\r\n", .ok .get false "/feed" none "" false 35),
  ("HTTP/1.2", "GET /feed HTTP/1.2\r\nHost: x\r\n\r\n", .ok .get false "/feed" none "" false 31),
  ("HTTP/1.2 without Host", "GET /feed HTTP/1.2\r\n\r\n", .bad 400),
  ("HTTP/2.0", "GET /feed HTTP/2.0\r\nHost: x\r\n\r\n", .bad 400),
  ("http/1.1", "GET /feed http/1.1\r\nHost: x\r\n\r\n", .bad 400),
  ("HTTP/1.x", "GET /feed HTTP/1.x\r\nHost: x\r\n\r\n", .bad 400),
  ("a space after the version", "GET /feed HTTP/1.1 \r\nHost: x\r\n\r\n", .bad 400),
  ("Transfer-Encoding", "POST /posts HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n",
    .bad 400),
  ("a method that is not a token", "G(T /feed HTTP/1.1\r\nHost: x\r\n\r\n", .bad 400),
  ("a method in lowercase", "get /feed HTTP/1.1\r\nHost: x\r\n\r\n", .ok .other false "/feed" none "" false 31),
  ("post in lowercase", "post /posts HTTP/1.1\r\nHost: x\r\n\r\n", .ok .other false "/posts" none "" false 33),
  ("a fragment", "GET /feed#x HTTP/1.1\r\nHost: x\r\n\r\n", .bad 400),
  ("a byte above 0x7f in the target", "GET /caf\xc3\xa9 HTTP/1.1\r\nHost: x\r\n\r\n", .bad 400),
  ("HTAB in the target", "GET /fe\ted HTTP/1.1\r\nHost: x\r\n\r\n", .bad 400),
  ("an empty target", "GET  HTTP/1.1\r\nHost: x\r\n\r\n", .bad 400),
  ("a query only", "GET ? HTTP/1.1\r\nHost: x\r\n\r\n", .bad 400),
  ("a query", "GET /feed?x=1 HTTP/1.1\r\nHost: x\r\n\r\n", .ok .get false "/feed" none "" false 35),
  ("a bad percent-encoding", "GET /feed?%zz HTTP/1.1\r\nHost: x\r\n\r\n", .bad 400),
  ("a percent-encoding", "GET /posts/%31 HTTP/1.1\r\nHost: x\r\n\r\n", .ok .get false "/posts/%31" none "" false 36),
  ("a target with sub-delims, : and @", "GET /a:b@c;d=e!$&'()*+, HTTP/1.1\r\nHost: x\r\n\r\n",
    .ok .get false "/a:b@c;d=e!$&'()*+," none "" false 45),
  ("a target with a cut percent-encoding", "GET /a%2 HTTP/1.1\r\nHost: x\r\n\r\n", .bad 400),
  ("a target with {", "GET /a{b} HTTP/1.1\r\nHost: x\r\n\r\n", .bad 400),
  ("a query with / ? : @", "GET /feed?a/b?c:@ HTTP/1.1\r\nHost: x\r\n\r\n", .ok .get false "/feed" none "" false 39),
  ("a query with a cut percent-encoding", "GET /feed?a%2 HTTP/1.1\r\nHost: x\r\n\r\n", .bad 400),
  ("an empty query", "GET /feed? HTTP/1.1\r\nHost: x\r\n\r\n", .ok .get false "/feed" none "" false 32),
  ("no empty line yet", "GET /feed HTTP/1.1\r\nHost: x\r\n", .wait),
  ("three bytes of the four", "GET /feed HTTP/1.1\r\nHost: x\r\n\r", .wait),
  ("content not all there", "POST /posts HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhel", .wait),
  ("Expect: 100-continue waits for the content", "POST /posts HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\n" ++
    "Content-Length: 12\r\n\r\n",
    .wait),
  ("two requests", "GET /feed HTTP/1.1\r\nHost: x\r\n\r\nGET /health HTTP/1.1\r\n",
    .ok .get false "/feed" none "" false 31),
  ("HEAD with content too large", "HEAD /feed HTTP/1.1\r\nHost: x\r\nContent-Length: 20000\r\n\r\n", .bad 413),
  ("nothing", "", .wait),
  ("an empty line", "\r\n", .wait),
  ("a 17,000-byte target", "GET /" ++ rep 16999 "a" ++ " HTTP/1.1\r\nHost: x\r\n\r\n", .bad 414),
  ("a target of maxTarget bytes", "GET /" ++ rep 8191 "a" ++ " HTTP/1.1\r\nHost: x\r\n\r\n",
    .ok .get false ("/" ++ rep 8191 "a") none "" false 8218),
  ("a target of maxTarget + 1 bytes", "GET /" ++ rep 8192 "a" ++ " HTTP/1.1\r\nHost: x\r\n\r\n", .bad 414),
  ("maxTarget + 1 bytes of target so far", "GET /" ++ rep 8192 "a", .bad 414),
  ("maxTarget bytes of target so far", "GET /" ++ rep 8191 "a", .wait),
  ("a LF among maxTarget + 1 bytes of target", "GET /" ++ rep 100 "a" ++ "\n" ++ rep 8200 "a", .wait),
  ("a CR among maxTarget + 1 bytes of target", "GET /" ++ rep 100 "a" ++ "\r" ++ rep 8200 "a", .wait),
  ("6,000 empty lines, then a target", rep 6000 "\r\n" ++ "GET /" ++ rep 4383 "a", .bad 431),
  ("6,000 empty lines, then a longer target", rep 6000 "\r\n" ++ "GET /" ++ rep 8192 "a", .bad 431),
  ("a long method, then a target", rep 9000 "A" ++ " /" ++ rep 7386 "a", .bad 431),
  ("a long method, then a longer target", rep 9000 "A" ++ " /" ++ rep 8192 "a", .bad 431),
  ("a head of maxHead + 4 bytes", "GET /feed HTTP/1.1\r\nHost: x\r\nX: " ++ rep 16352 "a" ++ "\r\n\r\n",
    .ok .get false "/feed" none "" false 16388),
  ("the same, one byte short", "GET /feed HTTP/1.1\r\nHost: x\r\nX: " ++ rep 16352 "a" ++ "\r\n\r", .wait),
  ("the same, three bytes short", "GET /feed HTTP/1.1\r\nHost: x\r\nX: " ++ rep 16352 "a" ++ "\r", .wait),
  ("a head of maxHead + 5 bytes", "GET /feed HTTP/1.1\r\nHost: x\r\nX: " ++ rep 16353 "a" ++ "\r\n\r\n", .bad 431),
  ("maxHead + 4 bytes without the end of a head", "GET /feed HTTP/1.1\r\nHost: x\r\nX: " ++ rep 16356 "a", .bad 431),
  ("maxHead + 3 bytes without the end of a head", "GET /feed HTTP/1.1\r\nHost: x\r\nX: " ++ rep 16355 "a", .wait)]

/-- Whether the parse `p` of `a` at `pos` is the frame `w`. -/
def frameIs (a : ByteArray) (pos : Nat) (p : Http.Parse) (w : Want) : Bool :=
  match p, w with
  | .incomplete, .wait => true
  | .bad s, .bad t => s == t
  | .ok r, .ok m head path auth body close len =>
    r.method == m && r.head == head && slice a r.pathLo r.pathHi == bs path.toUTF8 &&
      (if r.hasAuth then some (slice a r.authLo r.authHi) else none) == auth.map (bs ·.toUTF8) &&
      slice a r.bodyLo r.bodyHi == bs body.toUTF8 && r.close == close && r.next == pos + len && r.bodyHi == r.next
  | _, _ => false

def checkHttpExamples : Except String Unit := Id.run do
  for (desc, s, w) in httpExamples do
    let a := s.toUTF8
    if !frameIs a 0 (Http.parse a 0) w then
      return .error s!"Http.parse differs from the specification: {desc}"
    let b := "GET /\r\n".toUTF8 ++ a
    if !frameIs b 7 (Http.parse b 7) w then
      return .error s!"Http.parse differs from the specification after other bytes: {desc}"
  return .ok ()

def Rng.pick {α : Type} [Inhabited α] (g : Rng) (xs : Array α) : α × Rng :=
  let (k, g) := g.below xs.size
  (xs[k]!, g)

/-- `true` `p` times in a hundred. -/
def Rng.chance (g : Rng) (p : Nat) : Bool × Rng :=
  let (k, g) := g.below 100
  (k < p, g)

/-- `n` characters of `cs`. -/
def Rng.chars (g : Rng) (cs : Array Char) (n : Nat) : String × Rng := Id.run do
  let mut g := g
  let mut s := ""
  for _ in [0:n] do
    let (c, g') := g.pick cs
    s := s.push c
    g := g'
  return (s, g)

def Rng.shuffle {α : Type} [Inhabited α] (g : Rng) (xs : Array α) : Array α × Rng := Id.run do
  let mut g := g
  let mut xs := xs
  for j in [0:xs.size] do
    let i := xs.size - 1 - j
    let (k, g') := g.below (i + 1)
    g := g'
    let x := xs[i]!
    xs := (xs.set! i xs[k]!).set! k x
  return (xs, g)

/-! The parts of request-like inputs, after the C1 package's fuzzers (`fuzz.py`): methods, Host
values (the first ten valid), origin-form paths (the first nine valid), schemes, versions, field
lines and line ends. -/

def reqMethods : Array String := #["GET", "GET", "GET", "GET", "GET", "GET", "POST", "POST", "POST", "POST", "HEAD",
  "HEAD", "PUT", "get", "", "G(T", "OPTIONS", "CONNECT", "X-Y"]
def reqHosts : Array String := #["x", "10.0.0.1:3000", "127.0.0.1", "localhost:80", "[::1]", "[::1]:3000",
  "[1:2:3:4:5:6:7:8]", "[::ffff:1.2.3.4]", "[v1.x]", "[V7.a:b]", "", ":80", "a b", "u@h", "[1::2::3]",
  "[1:2:3:4:5:6:7:8:9]", "[1:2:3:4:5:6::1.2.3.4]", "[::1", "x:y", "%41%42", "%4", "ex%zz", "1.2.3.256",
  "[1:2:3:4:5:6:1.2.3.4]", "[::1.2.3.4]", "[1::1.2.3.04]", "[fffff::]", "[v.x]", "[vx.y]", "[v1.]", "h:",
  "x:12345678901234567890"]
def reqPaths : Array String := #["/feed", "/health", "/posts", "/posts/12", "/posts/7/like", "/", "/a/b/c",
  "/x?y=1", "/x?", "/%41", "/%4", "/a%zz", "/a:b@c", "/feed#x", "/caf\xe9", "/a\tb", "/a!$&'()*+,;=", "//x",
  "/?a?b/c"]
def reqSchemes : Array String := #["http", "https", "HTTP", "Https", "ftp", "foo", "a+b.c-d", "1ab", "htt", "httpx"]
def reqVersions : Array String := #["HTTP/1.1", "HTTP/1.1", "HTTP/1.1", "HTTP/1.1", "HTTP/1.1", "HTTP/1.1",
  "HTTP/1.0", "HTTP/1.0", "HTTP/1.0", "HTTP/1.2", "HTTP/1.9", "HTTP/2.0", "HTTP/0.9", "http/1.1", "HTTP/1.",
  "HTTP/1.1 ", " HTTP/1.1", "HTTP/11", "HTTP/1.x"]
def reqSeps : Array String := #["\r\n", "\r\n", "\r\n", "\r\n", "\r\n", "\r\n", "\r\n", "\r\n", "\r\n", "\r\n", "\r\n",
  "\r\n", "\n", "\r", "\r\r\n", "\r\n\r"]
/-- Field lines that leave a head valid. -/
def reqGoodHeads : Array String := #["User-Agent: k6/1.3.0 (https://k6.io/)", "Content-Type: application/json",
  "Accept: */*", "Connection: close", "Connection: keep-alive", "connection: Keep-Alive, Upgrade",
  "Connection: ,close ,", "Authorization: Bearer abc.def.ghi", "authorization:   tok  ", "X-Thing:\tvalue\t", "X:",
  "X: a:b:c", "Expect: 100-continue"]
/-- What a few bytes are changed to: bytes the scan looks for, NUL, DEL, 0x80 and 0xff. -/
def reqSpecial : Array UInt8 := "\r\n :,?\t/HhCc0123456789@[]%".toUTF8.data ++ #[0x00, 0x7f, 0x80, 0xff]

/-- Octets of IPv4-like text: from 0 to 1000, with leading zeros, and empty. -/
def reqOctets : Array String := #["", "0", "00", "01", "1", "9", "10", "99", "100", "199", "200", "249", "250", "255",
  "256", "299", "300", "1000"]

/-- IPv4-like text: one to five octets joined by dots. -/
def Rng.ipv4 (g : Rng) : String × Rng := Id.run do
  let (k, g) := g.pick #[4, 4, 4, 4, 3, 5, 1]
  let mut g := g
  let mut s := ""
  for j in [0:k] do
    let (o, g') := g.pick reqOctets
    s := s ++ (if j == 0 then "" else ".") ++ o
    g := g'
  return (s, g)

/-- IPv6-like text: up to nine groups of up to five hex digits (or "x") joined by ":", the last one
sometimes IPv4-like, with one "::" in any place half of the time, rarely a second. -/
def Rng.ipv6 (g : Rng) : String × Rng := Id.run do
  let (k, g) := g.below 10
  let mut g := g
  let mut parts : Array String := #[]
  for _ in [0:k] do
    let (len, g1) := g.pick #[1, 1, 2, 3, 4, 4, 0, 5]
    let (h, g1) := g1.chars "0123456789abcdefABCDEFx".toList.toArray len
    parts := parts.push h
    g := g1
  let (v4, g1) := g.chance 25
  let (ip, g1) := g1.ipv4
  if v4 && k > 0 then parts := parts.set! (k - 1) ip
  let (dc, g1) := g1.chance 50
  let (at_, g1) := g1.below (k + 1)
  let (two, g1) := g1.chance 5
  let s := if dc then ":".intercalate (parts.toList.take at_) ++ "::" ++ ":".intercalate (parts.toList.drop at_)
    else ":".intercalate parts.toList
  return (if two then s ++ "::1" else s, g1)

/-- IPvFuture-like text: "v" (or "V", or neither), up to two hex digits, a dot (mostly), up to
three characters that userinfo may or may not hold. -/
def Rng.ipFuture (g : Rng) : String × Rng :=
  let (v, g) := g.pick #["v", "V", "v", ""]
  let (k, g) := g.below 3
  let (hs, g) := g.chars "0123456789aFx".toList.toArray k
  let (dot, g) := g.chance 85
  let (k', g) := g.below 4
  let (rest, g) := g.chars "a1-._~!$&'()*+,;=:%@/".toList.toArray k'
  (v ++ hs ++ (if dot then "." else "") ++ rest, g)

/-- A Host value, or the host and port of an authority: one of `reqHosts`; an IP-literal of
IPv6-like or IPvFuture-like text; IPv4-like text; a run of characters that a reg-name may or may not
hold; then, two times in five, a port of up to five digits, or not digits. -/
def Rng.host (g : Rng) : String × Rng :=
  let (k, g) := g.below 100
  let (h, g) :=
    if k < 35 then g.pick reqHosts
    else if k < 60 then let (s, g) := g.ipv6; ("[" ++ s ++ "]", g)
    else if k < 70 then let (s, g) := g.ipFuture; ("[" ++ s ++ "]", g)
    else if k < 85 then g.ipv4
    else let (n, g) := g.below 9; g.chars "aZ09-._~!$&'()*+,;=%41:@[]".toList.toArray n
  let (p, g) := g.below 10
  let (port, g) := g.chars "0123456789".toList.toArray (p % 6)
  (if p < 6 then h else if p < 9 then h ++ ":" ++ port else h ++ ":x", g)

/-- A request-target: origin-form; absolute-form of http, https and other schemes (and of
scheme-like text led by any byte), with and without userinfo, with a host and a path; asterisk-form;
authority-form; other bytes. -/
def Rng.target (g : Rng) : String × Rng := Id.run do
  let (k, g) := g.below 100
  if k < 50 then return g.pick reqPaths
  if k < 78 then
    let (any, g) := g.chance 10
    let (lead, g) := g.chars "~{|`zZ@[+0a".toList.toArray 1
    let (sch, g) := if any then (lead ++ "b", g) else g.pick reqSchemes
    let (sep, g) := g.pick #["://", "://", "://", ":", ":/", "//"]
    let (user, g) := g.pick #["", "", "", "u@", "u:p@", "@", "u@@", "u[@", "%zz@", "u%41:x@"]
    let (hk, g) := g.chance 50
    let (host, g) := if hk then g.host else g.pick (reqHosts.filter (!·.contains ' '))
    let (path, g) := g.pick #["", "/feed", "/posts/1", "/x?q=1", "?q", "/a#b", "x"]
    return (sch ++ sep ++ user ++ host ++ path, g)
  if k < 83 then return g.pick #["*", "*?x", "**"]
  if k < 93 then
    let (host, g) := g.host
    let (port, g) := g.pick #["", ":80", ":", "?x"]
    return (host ++ port, g)
  let (n, g) := g.below 7
  return g.chars "/?:@[]%aA0.-*~{".toList.toArray n

/-- A field line: Host; Content-Length in every form (the content's length, with up to 39 zeros
before it, 23 and 40 digits, not digits, a list); Authorization; Connection; Transfer-Encoding;
others; and lines that are not field lines or hold bytes no field value holds. -/
def Rng.header (g : Rng) (len : Nat) : String × Rng := Id.run do
  let (k, g) := g.below 100
  if k < 20 then
    let (host, g) := g.host
    return ("Host: " ++ host, g)
  if k < 35 then
    let (name, g) := g.pick #["Content-Length", "content-length", "CONTENT-LENGTH"]
    let (ows, g) := g.pick #["", " ", "\t"]
    let (zeros, g) := g.below 39
    let (v, g) := g.pick #[toString len, toString len, rep (zeros + 1) "0" ++ toString len, "", "5a", "-1", "5, 5",
      "16385", "16384", "99999999999999999999999", " 7 ", "0", "1" ++ rep 39 "0"]
    return (name ++ ":" ++ ows ++ v, g)
  if k < 45 then
    let (name, g) := g.pick #["Authorization", "authorization"]
    let (ows, g) := g.pick #[" ", "  ", ""]
    let (v, g) := g.pick #["Bearer abc.def.ghi", "Bearer x", "tok", "", "Bearer abc  "]
    return (name ++ ":" ++ ows ++ v, g)
  if k < 55 then
    let (v, g) := g.pick #["close", "keep-alive", "Keep-Alive, Upgrade", ",close ,", "closed", " CLOSE\t,keep-alive",
      ",,", "", "keep-alive, close", "upgrade"]
    return ("Connection: " ++ v, g)
  if k < 60 then return g.pick #["Transfer-Encoding: chunked", "transfer-encoding:", "TE: trailers"]
  if k < 68 then
    return g.pick #["User-Agent: k6/1.3.0 (https://k6.io/)", "Content-Type: application/json", "X: a:b:c",
      "Expect: 100-continue", "X-Thing:\tvalue\t", "Accept: */*", "X:", "X-\xff: y"]
  return g.pick #["NoColonLine", ": empty name", " Content-Length: 5", "Connection : close", "\tX: y", "X: a\x00b",
    "X: a\x7fb", "X: a\x01", "X: \xff\xfe", "X(y): z", "X: a\rb", "X: a\nb", "Host : x", "X\x00: y"]

/-- A request-like text: one to three requests, sometimes after empty lines; half of the texts well
formed (a Host line nearly always, its value valid seven times in ten, field lines that leave the
head valid, a Content-Length of the content's length, rarely another field line), half made of any
of the parts; then up to two bytes changed, and one text in five cut short. -/
def Rng.request (g : Rng) : ByteArray × Rng := Id.run do
  let (good, g) := g.chance 50
  let (reqs, g) := g.pick #[1, 1, 1, 2, 3]
  let mut g := g
  let mut s := ""
  for _ in [0:reqs] do
    let (lead, g1) := g.chance 10
    let (nl, g1) := g1.below 3
    if lead then s := s ++ rep (nl + 1) "\r\n"
    let (len, g1) := g1.pick #[0, 0, 0, 3, 5, 12]
    g := g1
    if good then
      let (m, g1) := g.pick #["GET", "GET", "POST", "HEAD", "PUT"]
      let (path, g1) := g1.chance 80
      let (t, g1) := if path then g1.pick (reqPaths.extract 0 9) else g1.target
      let (v, g1) := g1.pick #["HTTP/1.1", "HTTP/1.1", "HTTP/1.0", "HTTP/1.2"]
      s := s ++ m ++ " " ++ t ++ " " ++ v ++ "\r\n"
      let (host, g1) := g1.chance 95
      let (valid, g1) := g1.chance 70
      let (h, g1) := if valid then g1.pick (reqHosts.extract 0 10) else g1.host
      let mut hs : Array String := if host then #["Host: " ++ h] else #[]
      let (nh, g1) := g1.below 4
      g := g1
      for _ in [0:nh] do
        let (h, g1) := g.pick reqGoodHeads
        hs := hs.push h
        g := g1
      let (cl, g1) := g.chance 30
      let (zeros, g1) := g1.below 3
      if len > 0 || cl then hs := hs.push ("Content-Length: " ++ rep zeros "0" ++ toString len)
      let (other, g1) := g1.chance 10
      let (h, g1) := g1.header len
      if other then hs := hs.push h
      let (hs', g1) := g1.shuffle hs
      -- at most one Authorization line
      let mut auth := false
      for h in hs' do
        let isAuth := h.startsWith "Authorization" || h.startsWith "authorization"
        if !(isAuth && auth) then s := s ++ h ++ "\r\n"
        auth := auth || isAuth
      s := s ++ "\r\n" ++ rep len "b"
      let (more, g1) := g1.chance 30
      let (extra, g1) := g1.below 6
      if more then s := s ++ rep extra "b"
      g := g1
    else
      let (m, g1) := g.pick reqMethods
      let (sp1, g1) := g1.chance 95
      let (sep1, g1) := if sp1 then (" ", g1) else g1.pick #["  ", "\t", ""]
      let (t, g1) := g1.target
      let (sp2, g1) := g1.chance 95
      let (sep2, g1) := if sp2 then (" ", g1) else g1.pick #["  ", "\t", ""]
      let (v, g1) := g1.pick reqVersions
      let (crlf, g1) := g1.chance 90
      let (eol, g1) := if crlf then ("\r\n", g1) else g1.pick reqSeps
      s := s ++ m ++ sep1 ++ t ++ sep2 ++ v ++ eol
      let (host, g1) := g1.chance 85
      let (h, g1) := g1.pick (reqHosts.extract 0 10)
      if host then s := s ++ "Host: " ++ h ++ "\r\n"
      let (nh, g1) := g1.below 6
      g := g1
      for _ in [0:nh] do
        let (h, g1) := g.header len
        let (crlf, g1) := g1.chance 93
        let (eol, g1) := if crlf then ("\r\n", g1) else g1.pick reqSeps
        s := s ++ h ++ eol
        g := g1
      let (ends, g1) := g.chance 95
      if ends then s := s ++ "\r\n"
      let (blen, g1) := g1.below 17
      s := s ++ rep blen "b"
      g := g1
  let mut a := s.toUTF8
  let (muts, g1) := g.pick #[0, 0, 0, 0, 1, 2]
  g := g1
  for _ in [0:muts] do
    let (p, g1) := g.below a.size
    let (b, g1) := g1.pick reqSpecial
    if a.size > 0 then a := a.set! p b
    g := g1
  let (cut, g1) := g.chance 20
  let (at_, g1) := g1.below (a.size + 1)
  if cut then a := a.extract 0 at_
  return (a, g1)

/-- An input at the limits: a request-target of about `maxTarget` bytes, a head of about `maxHead + 4`
bytes, thousands of empty lines or a method of thousands of bytes before a long target, content of
about `maxBody` bytes, a byte that ends a target (or does not) inside a long one, thousands of empty
lines after a field line. -/
def Rng.big (g : Rng) : ByteArray × Rng := Id.run do
  let (k, g) := g.below 10
  let (x, g) := g.below 1000000
  let (y, g) := g.below 1000000
  let s :=
    if k == 0 then "GET /" ++ rep (8185 + x % 16) "a" ++ " HTTP/1.1\r\nHost: x\r\n\r\n"
    else if k == 1 then "GET /feed HTTP/1.1\r\nHost: x\r\nX: " ++ rep (16340 + x % 21) "a" ++ "\r\n\r\n"
    else if k == 2 then rep (5990 + x % 21) "\r\n" ++ "GET /" ++ rep (4370 + y % 3831) "a"
    else if k == 3 then rep (8190 + x % 911) "A" ++ " /" ++ rep (7380 + y % 21) "a"
    else if k == 4 then "GET /" ++ rep (8180 + x % 21) "a"
    else if k == 5 then rep (16380 + x % 21) "a"
    else if k == 6 then rep (8190 + x % 11) "\r\n"
    else if k == 7 then "POST /posts HTTP/1.1\r\nHost: x\r\nContent-Length: 16384\r\n\r\n" ++ rep (16383 + x % 3) "z"
    else if k == 8 then
      "GET /" ++ rep (100 + x % 8901) "a" ++ #["\x00", "\n", "\r", "\t", "\r\n"][y % 5]! ++ rep (y % 9001) "a" ++
        (if x % 2 == 0 then " HTTP/1.1\r\nHost: x\r\n\r\n" else "")
    else "GET /feed HTTP/1.1\r\nHost: x\r\nX: " ++ rep (8170 + x % 21) "\r\n"
  return (s.toUTF8, g)

/-- A request-like text, one in fifty at the limits. -/
def Rng.input (g : Rng) : ByteArray × Rng :=
  let (big, g) := g.chance 2
  if big then g.big else g.request

/-- The prefixes of `a` to check: every one of an input of up to 2,048 bytes; of a longer one, the
first 64 and the last 8, every 61st, and those around where the scan of the whole input meets a
limit: the request-target's `maxTarget + 1`st byte, the end of the head, the first `maxHead + 4`
bytes, the end of the content. -/
def prefixLengths (a : ByteArray) (whole : Http.Parse) : List Nat :=
  if a.size ≤ 2048 then List.range a.size else
  let lim := min a.size (Http.maxHead + 4)
  let i0 := Http.skipLead a 0
  let m := Http.tokenEnd a i0 lim
  let around (c : Nat) := (List.range 9).map (c + · - 4)
  let edges := around (m + 2 + Http.maxTarget) ++ around lim ++
    (match Http.headEnd a i0 lim with | some he => around (he + 4) | none => []) ++
    (match whole with | .ok r => around r.next | _ => [])
  ((List.range 64 ++ (List.range (a.size / 61)).map (· * 61) ++ (List.range 8).map (a.size - 1 - ·) ++ edges).filter
    (· < a.size))

/-- On random inputs, every prefix of an input (of a long one, those of `prefixLengths`): the C
`Http.parse` gives its Lean definition's result, which is a wait or the whole input's; and the input
reads the same after other bytes. Every kind of frame must come up. -/
def checkHttp (rounds : Nat) : Except String Unit := Id.run do
  let mut g : Rng := ⟨0x14057b7ef767814f⟩
  let mut kinds : Array Nat := #[0, 0, 0, 0, 0, 0]
  for i in [0:rounds] do
    let (a, g1) := g.input
    let (pre, g2) := g1.bytes 6
    g := g2
    let whole := Http.parse a 0
    if !parseEq whole (refParse a 0) then
      return .error s!"Http.parse differs from its Lean definition (round {i})"
    let kind := match whole with
      | .incomplete => 0 | .ok _ => 1 | .bad 400 => 2 | .bad 413 => 3 | .bad 414 => 4 | .bad 431 => 5 | .bad _ => 6
    if kind == 6 then return .error s!"Http.parse gives a status it should not (round {i})"
    kinds := kinds.modify kind (· + 1)
    for k in prefixLengths a whole do
      let b := a.extract 0 k
      let p := Http.parse b 0
      if !parseEq p (refParse b 0) then
        return .error s!"Http.parse differs from its Lean definition on a prefix (round {i}, length {k} of {a.size})"
      if !(parseEq p .incomplete || parseEq p whole) then
        return .error s!"Http.parse of a prefix differs from the whole input's (round {i}, length {k} of {a.size})"
    if !parseEq (unshift pre.size (Http.parse (pre ++ a) pre.size)) whole then
      return .error s!"Http.parse differs after other bytes (round {i})"
  if kinds.any (· == 0) then return .error s!"the random requests miss a kind of frame: {kinds}"
  return .ok ()

/-- Where one byte goes in `checkHttpBytes`: between each pair of texts, a byte of a method, a path,
a query, a field name, a field value, a Host value (a reg-name, IPvFuture, an IPv6 address and its
IPv4 tail, a port), userinfo, a scheme (its first and a later character), the host of an
absolute-form and of an authority-form target, a percent-encoding, a Content-Length value, the
version's minor digit, the end of the request-line, the place of a SP, an empty line before the
request, a Connection option, a field name's first and last letters, and the whitespace around a
field value. -/
def byteSlots : Array (String × String) := #[
  ("G", "T /feed HTTP/1.1\r\nHost: x\r\n\r\n"),
  ("GET /fe", "d HTTP/1.1\r\nHost: x\r\n\r\n"),
  ("GET /feed?a", "b HTTP/1.1\r\nHost: x\r\n\r\n"),
  ("GET /feed HTTP/1.1\r\nHost: x\r\nX", "Y: z\r\n\r\n"),
  ("GET /feed HTTP/1.1\r\nHost: x\r\nX: a", "b\r\n\r\n"),
  ("GET /feed HTTP/1.1\r\nHost: a", "b\r\n\r\n"),
  ("GET /feed HTTP/1.1\r\nHost: [v1.a", "]\r\n\r\n"),
  ("GET /feed HTTP/1.1\r\nHost: [v", ".a]\r\n\r\n"),
  ("GET /feed HTTP/1.1\r\nHost: [::", "]\r\n\r\n"),
  ("GET /feed HTTP/1.1\r\nHost: [::1.2.3.", "]\r\n\r\n"),
  ("GET /feed HTTP/1.1\r\nHost: x:8", "\r\n\r\n"),
  ("GET foo://u", "@h/ HTTP/1.1\r\nHost: x\r\n\r\n"),
  ("GET a", "b:x HTTP/1.1\r\nHost: x\r\n\r\n"),
  ("GET ", "b:x HTTP/1.1\r\nHost: x\r\n\r\n"),
  ("GET http://a", "b/feed HTTP/1.1\r\nHost: x\r\n\r\n"),
  ("CONNECT a", "b:80 HTTP/1.1\r\nHost: x\r\n\r\n"),
  ("GET /a%4", " HTTP/1.1\r\nHost: x\r\n\r\n"),
  ("POST /posts HTTP/1.1\r\nHost: x\r\nContent-Length: 1", "\r\n\r\n0123456789abcdefghij"),
  ("GET /feed HTTP/1.", "\r\nHost: x\r\n\r\n"),
  ("GET /feed HTTP/1.1", "\nHost: x\r\n\r\n"),
  ("GET", "/feed HTTP/1.1\r\nHost: x\r\n\r\n"),
  ("\r", "GET /feed HTTP/1.1\r\nHost: x\r\n\r\n"),
  ("GET /feed HTTP/1.0\r\nConnection: ", "lose\r\n\r\n"),
  ("GET /feed HTTP/1.1\r\n", "ost: x\r\n\r\n"),
  ("GET /feed HTTP/1.1\r\nHost: x\r\nTransfer-Encodin", ": chunked\r\n\r\n"),
  ("GET /feed HTTP/1.1\r\nHost:", "x\r\n\r\n"),
  ("GET /feed HTTP/1.1\r\nHost: x", "\r\n\r\n")]

/-- The C `Http.parse` against its Lean definition with each byte value in each of `byteSlots`, so
that every byte meets each class of bytes the parser tells apart; also with room after the input. -/
def checkHttpBytes : Except String Unit := Id.run do
  for (pre, post) in byteSlots do
    for b in [0:256] do
      let a := (pre.toUTF8.push b.toUInt8) ++ post.toUTF8
      if !parseEq (Http.parse a 0) (refParse a 0) || !parseEq (Http.parse (fresh a 40) 0) (refParse a 0) then
        return .error s!"Http.parse differs from its Lean definition with byte {b} after {pre.quote}"
  return .ok ()

/-- The C `Http.parse` against its Lean definition on random inputs, at the start, at the next
request, inside, at and past the end; and with room after the input, which the C reads 32 bytes at a
time and must not see. -/
def checkParse (rounds : Nat) : Except String Unit := Id.run do
  let mut g : Rng := ⟨0x3c6ef372fe94f82b⟩
  for i in [0:rounds] do
    let (a, g1) := g.input
    let (p, g2) := g1.below (a.size + 1)
    let (spare, g3) := g2.below 80
    g := g3
    let next := match refParse a 0 with
      | .ok r => r.next
      | _ => 0
    for pos in [0, next, p, a.size, a.size + 3, 2 ^ 64] do
      if !parseEq (Http.parse a pos) (refParse a pos) then
        return .error s!"Http.parse differs from its Lean definition (round {i}, position {pos})"
    let b := fresh a spare
    for pos in [0, next, p, a.size] do
      if !parseEq (Http.parse b pos) (refParse a pos) then
        return .error s!"Http.parse differs with room after the input (round {i}, position {pos})"
  return .ok ()

/-! ### JSON texts -/

def fieldEq (a b : Json.Field) : Bool := a.kind == b.kind && a.lo == b.lo && a.hi == b.hi

def topEq : Json.Top → Json.Top → Bool
  | .malformed, .malformed | .notObject, .notObject => true
  | .object fs, .object gs => fs.size == gs.size && (List.range fs.size).all fun k => fieldEq fs[k]! gs[k]!
  | _, _ => false

def bytesOf (l : List Nat) : ByteArray := ⟨(l.map Nat.toUInt8).toArray⟩

/-- Strings (with their quotes): escapes of every kind, surrogates paired and lone, UTF-8 of each
length with the first and last scalar values of the ranges of RFC 3629 §4, and long strings with
an escape or non-ASCII text after their first 32 bytes. -/
def jsonStrs : Array ByteArray := #[
  "\"\"".toUTF8, "\"abc\"".toUTF8, "\"HS256\"".toUTF8, "\"a\\\"b\"".toUTF8, "\"\\\\\"".toUTF8,
  "\"\\/\\b\\f\\n\\r\\t\"".toUTF8, "\"\\u0041\\u00e9\\u4e2d\\u0000\"".toUTF8, "\"\\ud83d\\ude00\"".toUTF8,
  "\"\\ud83d\"".toUTF8, "\"\\ude00x\"".toUTF8, "\"\\ud83d\\u0041\"".toUTF8, "\"\\uD83D\\uDE00\"".toUTF8,
  "\"é中😀\"".toUTF8, bytesOf [0x22, 0xe2, 0x82, 0xac, 0xf0, 0x9f, 0x98, 0x80, 0x22],
  -- U+0080, U+07FF, U+0800, U+0FFF, U+1000, U+CFFF, U+D000, U+D7FF, U+E000, U+FFFF
  bytesOf [0x22, 0xc2, 0x80, 0xdf, 0xbf, 0xe0, 0xa0, 0x80, 0xe0, 0xbf, 0xbf, 0xe1, 0x80, 0x80, 0xec, 0xbf, 0xbf,
    0xed, 0x80, 0x80, 0xed, 0x9f, 0xbf, 0xee, 0x80, 0x80, 0xef, 0xbf, 0xbf, 0x22],
  -- U+10000, U+3FFFF, U+40000, U+FFFFF, U+100000, U+10FFFF
  bytesOf [0x22, 0xf0, 0x90, 0x80, 0x80, 0xf0, 0xbf, 0xbf, 0xbf, 0xf1, 0x80, 0x80, 0x80, 0xf3, 0xbf, 0xbf, 0xbf,
    0xf4, 0x80, 0x80, 0x80, 0xf4, 0x8f, 0xbf, 0xbf, 0x22],
  "\"a long string with no escapes at all, longer than thirty-two bytes\"".toUTF8,
  "\"a long string with one escape \\n after more than thirty-two bytes of text\"".toUTF8,
  "\"a long string with non-ASCII text after thirty-two bytes: café, 中文, 😀\"".toUTF8]

/-- Texts that start like a string and are not one: ill-formed UTF-8 (a continuation byte with no
lead, a lead cut short, overlong forms, encoded surrogates, values past U+10FFFF, bytes that never
occur), also after a plain run of 32 bytes; a control byte, an unknown escape, bad hex. -/
def jsonNonStrs : Array ByteArray := #[
  bytesOf [0x22, 0x80, 0x41, 0x22], bytesOf [0x22, 0xbf, 0x22], bytesOf [0x22, 0xc3, 0x28, 0x22],
  bytesOf [0x22, 0x61, 0xe2, 0x82, 0x22], bytesOf [0x22, 0xf0, 0x9f, 0x98, 0x22], bytesOf [0x22, 0xc0, 0xaf, 0x22],
  bytesOf [0x22, 0xc1, 0xbf, 0x22], bytesOf [0x22, 0xe0, 0x80, 0x80, 0x22], bytesOf [0x22, 0xe0, 0x9f, 0xbf, 0x22],
  bytesOf [0x22, 0xf0, 0x8f, 0xbf, 0xbf, 0x22], bytesOf [0x22, 0xed, 0xa0, 0x80, 0x22], bytesOf [0x22, 0xed, 0xbf, 0xbf, 0x22],
  bytesOf [0x22, 0xf4, 0x90, 0x80, 0x80, 0x22], bytesOf [0x22, 0xf5, 0x80, 0x80, 0x80, 0x22], bytesOf [0x22, 0xff, 0x22],
  "\"a long string with a stray byte after thirty-two bytes: ".toUTF8 ++ bytesOf [0xff, 0x22],
  "\"a long string with a sequence cut short after thirty-two bytes: ".toUTF8 ++ bytesOf [0xe2, 0x82, 0x22],
  "\"\\uZZZZ\"".toUTF8, "\"\\x\"".toUTF8, "\"\\u12\"".toUTF8, bytesOf [0x22, 0x09, 0x22]]

/-- Scalar values at the ends of the ranges of RFC 3629 §4. -/
def utf8Edges : Array Nat := #[0x80, 0x7ff, 0x800, 0xfff, 0x1000, 0xcfff, 0xd000, 0xd7ff, 0xe000, 0xffff, 0x10000,
  0x3ffff, 0x40000, 0xfffff, 0x100000, 0x10ffff]
/-- Bytes after a byte from 0x80 to 0xff: the ends of the ranges RFC 3629 §4 allows for the next
byte, and bytes that end a string or start the next character. -/
def utf8Follow : Array UInt8 := #[0x7f, 0x80, 0x8f, 0x90, 0x9f, 0xa0, 0xbf, 0xc0, 0xff, 0x22, 0x5c, 0x41]

/-- A string (with its quotes) of plain runs, which the C side scans 32 bytes at a time, escapes,
and UTF-8 sequences of each length at any offset. Unless `clean`, some sequences are ill-formed:
any byte from 0x80 to 0xff followed by bytes that may not continue it, or a surrogate or a value
past U+10FFFF written in UTF-8's pattern. -/
def Rng.jsonStr (g : Rng) (clean : Bool) : ByteArray × Rng := Id.run do
  let (n, g0) := g.below 6
  let mut g := g0
  let mut out := "\"".toUTF8
  for _ in [0:n] do
    let (k, g1) := g.below 10
    let (x, g2) := g1.next
    let (y, g3) := g2.next
    g := g3
    if k < 4 then
      -- a plain run of up to 40 bytes
      for j in [0:x.toNat % 41] do
        let c := (0x20 + (y.toNat + 37 * j) % 0x5f).toUInt8
        out := out.push (if c == 0x22 || c == 0x5c then 0x2e else c)
    else if k == 4 then
      out := out ++ #["\\n", "\\\"", "\\u00e9", "\\ud83d\\ude00", "\\ud800"][x.toNat % 5]!.toUTF8
    else if k < 8 || clean then
      -- a scalar value at the end of a range, or any
      let c := if y % 2 == 0 then utf8Edges[x.toNat % utf8Edges.size]!
        else let c := 0x80 + x.toNat % (0x110000 - 0x80); if 0xd800 ≤ c && c < 0xe000 then c - 0x800 else c
      out := Json.pushUtf8 out c
    else if k == 8 then
      -- a byte from 0x80 to 0xff and up to three more
      out := out.push (0x80 + x.toNat % 0x80).toUInt8
      for j in [0:y.toNat % 4] do
        out := out.push utf8Follow[((y.toNat / 4) >>> (4 * j)) % utf8Follow.size]!
    else
      -- a surrogate or a value past U+10FFFF, in UTF-8's pattern
      out := Json.pushUtf8 out (if y % 2 == 0 then 0xd800 + x.toNat % 0x800 else 0x110000 + x.toNat % 0x30000)
  return (out.push 0x22, g)

def jsonKeys : Array String := #["\"alg\"", "\"exp\"", "\"nbf\"", "\"sub\"", "\"username\"", "\"body\"", "\"\\u0061lg\"",
  "\"ex\\u0070\"", "\"bo\\u0064y\"", "\"user\\u006eame\"", "\"x\"", "\"\"", "\"alg \"", "\"ALG\"", "\"b\\\"ody\"",
  "\"café\"", "\"caf\\u00e9\"", "\"\\u00e9\"", "\"é\"", "\"crit\"", "\"cty\"", "\"aud\"", "\"c\\u0074y\"", "\"AUD\""]
/-- Numbers: the first thirteen valid. -/
def jsonNums : Array String := #["0", "-0", "12", "1.5", "1e10", "1E+5", "-1.2e-3", "1700000000", "17000000000000000000000",
  "1e400", "2.0E-2", "9", "-12.50e01", "01", "1.", ".5", "-", "1e", "1e+", "--1"]
def jsonWs : Array String := #["", "", "", " ", "\n", "\t ", "\r\n", "  "]

def Rng.wsBytes (g : Rng) : ByteArray × Rng := let (w, g) := g.pick jsonWs; (w.toUTF8, g)

/-- A member name: usually one of `jsonKeys`, sometimes any string. -/
def Rng.jsonKey (g : Rng) (clean : Bool) : ByteArray × Rng :=
  let (k, g) := g.below 8
  if k == 0 then g.jsonStr clean else let (key, g) := g.pick jsonKeys; (key.toUTF8, g)

/-- Scalars, empty containers and broken bits of JSON. -/
def Rng.jsonScalar (g : Rng) (clean : Bool) : ByteArray × Rng :=
  let (k, g) := g.below 8
  if k < 3 then let (n, g) := g.below (if clean then 13 else jsonNums.size); (jsonNums[n]!.toUTF8, g)
  else if k < 5 then
    let (x, g) := g.below (if clean then jsonStrs.size else jsonStrs.size + jsonNonStrs.size)
    (if x < jsonStrs.size then jsonStrs[x]! else jsonNonStrs[x - jsonStrs.size]!, g)
  else if k == 5 then g.jsonStr clean
  else if k == 6 then let (l, g) := g.below (if clean then 3 else 6); (#["true", "false", "null", "nul", "tru", "fals"][l]!.toUTF8, g)
  else let (l, g) := g.below (if clean then 4 else 11)
    (#["{}", "[]", "{ }", "[ ]", "{,}", "[,]", "[1,]", "{\"a\":}", "{\"a\" 1}", "}", "]"][l]!.toUTF8, g)

/-- A JSON-like value of nesting depth below `d`. -/
def Rng.json (g : Rng) (clean : Bool) : Nat → ByteArray × Rng
  | 0 => g.jsonScalar clean
  | d + 1 =>
    let (k, g) := g.below 10
    if k < 5 then g.jsonScalar clean
    else if k < 7 then Id.run do
      let (n, g0) := g.below 5
      let mut g := g0
      let mut out := "[".toUTF8
      for j in [0:n] do
        let (v, g1) := g.json clean d
        let (w1, g2) := g1.wsBytes
        let (w2, g3) := g2.wsBytes
        out := out ++ (if j == 0 then ByteArray.empty else ",".toUTF8) ++ w1 ++ v ++ w2
        g := g3
      return (out ++ "]".toUTF8, g)
    else Id.run do
      let (n, g0) := g.below 5
      let mut g := g0
      let mut out := "{".toUTF8
      for j in [0:n] do
        let (key, g1) := g.jsonKey clean
        let (v, g2) := g1.json clean d
        let (w1, g3) := g2.wsBytes
        let (w2, g4) := g3.wsBytes
        out := out ++ (if j == 0 then ByteArray.empty else ",".toUTF8) ++ w1 ++ key ++ w2 ++ ":".toUTF8 ++ w1 ++ v
        g := g4
      return (out ++ "}".toUTF8, g)

/-- A JSON text: mostly an object with wanted keys, sometimes another value, deep nesting, a few
changed bytes, or a cut. -/
def Rng.jsonText (g : Rng) : ByteArray × Rng := Id.run do
  let (k, g0) := g.below 20
  -- half of the texts have valid scalars only
  let (c, g0) := g0.below 2
  let clean := c == 0
  let mut g := g0
  let (w1, g1) := g.wsBytes
  let (w2, g2) := g1.wsBytes
  g := g2
  let (v, g3) :=
    if k == 0 then
      let (d, g') := g.below 3000
      (String.ofList (List.replicate d '[') ++ String.ofList (List.replicate d ']')).toUTF8 |> fun x => (x, g')
    else if k == 1 then
      let (d, g') := g.below 3000
      (String.ofList (List.replicate d '[') ++ "0" ++ String.ofList (List.replicate (d - d % 2) ']')).toUTF8 |> fun x => (x, g')
    else if k < 6 then g.json clean 3
    else Id.run do
      -- a top-level object, as in tokens and post bodies
      let (n, g0) := g.below 6
      let mut g := g0
      let mut out := "{".toUTF8
      for j in [0:n] do
        let (key, g1) := g.jsonKey clean
        let (v, g2) := g1.json clean 2
        let (w, g3) := g2.wsBytes
        out := out ++ (if j == 0 then ByteArray.empty else ",".toUTF8) ++ w ++ key ++ ":".toUTF8 ++ w ++ v
        g := g3
      return (out ++ "}".toUTF8, g)
  g := g3
  let mut a := w1 ++ v ++ w2
  let (m, g4) := g.below (if clean then 12 else 6)
  g := g4
  if m == 0 && a.size > 0 then
    let (p, g5) := g.below a.size
    let (x, g6) := g5.byte
    a := a.set! p x
    g := g6
  if m == 1 then
    let (p, g5) := g.below (a.size + 1)
    a := a.extract 0 p
    g := g5
  return (a, g)

def jsonKeySets : Array (Array ByteArray) := #[#[Jwt.keyAlg, Jwt.keyCrit, Jwt.keyCty],
  #[Jwt.keyExp, Jwt.keyNbf, Jwt.keySub, Jwt.keyUsername, Jwt.keyAud], #[kBodyKey], #[],
  #["a".toUTF8, Jwt.keyAlg, Jwt.keyAlg, "x".toUTF8, Jwt.keyExp, Jwt.keyNbf, Jwt.keySub, Jwt.keyUsername,
    kBodyKey, "".toUTF8, "café".toUTF8, "é".toUTF8, Jwt.keyCrit, Jwt.keyCty, Jwt.keyAud]]

/-- `Json.parseTop` and `Json.decodeString` against their Lean definitions: whole texts and
ranges inside and past them; every string the parser recorded and random ranges decoded, some
ending past the array (up to 2^64). -/
def checkJson (rounds : Nat) : Except String Unit := Id.run do
  let mut g : Rng := ⟨0x1b873593cc9e2d51⟩
  for i in [0:rounds] do
    let (a, g1) := g.jsonText
    let (ks, g2) := g1.below jsonKeySets.size
    let (lo, g3) := g2.below (a.size + 3)
    let (hi, g4) := g3.below (a.size + 3)
    let (dlo, g5) := g4.below (a.size + 2)
    let (dhi, g6) := g5.below (a.size + 4)
    g := g6
    let keys := jsonKeySets[ks]!
    for (l, h) in [(0, a.size), (0, a.size + 5), (lo, hi), (lo, a.size), (2 ^ 64, a.size), (0, 2 ^ 64)] do
      let t := Json.parseTop a l h keys
      if !topEq t (refParseTop a l h keys) then
        return .error s!"Json.parseTop differs (round {i}, range {l} {h})"
      if let .object fs := t then
        for f in fs do
          if f.kind == .str && Json.decodeString a f.lo f.hi != refDecodeString a f.lo f.hi then
            return .error s!"Json.decodeString differs (round {i}, range {f.lo} {f.hi})"
    for (l, h) in [(dlo, dhi), (dlo, a.size + 1000), (dlo, 2 ^ 63 - 1), (dlo, 2 ^ 63), (dlo, 2 ^ 64), (2 ^ 64, 2 ^ 64)] do
      if Json.decodeString a l h != refDecodeString a l h then
        return .error s!"Json.decodeString differs (round {i}, range {l} {h})"
  return .ok ()

/-- Each byte from 0x80 to 0xff at the start of a sequence, before bytes at the ends of the ranges
RFC 3629 §4 allows after it: in a member's value (also after 31 and 32 plain bytes, so that the C
side meets it inside its 32-byte scan and after one), in a member name, as a whole text and cut
off by the end of the text. `Json.parseTop` and `Json.decodeString` against their Lean
definitions, the latter on the recorded value and on the whole text. -/
def checkUtf8 : Except String Unit := Id.run do
  let seconds : List Nat := [0x7f, 0x80, 0x8f, 0x90, 0x9f, 0xa0, 0xbf, 0xc0]
  let tails : List (List Nat) :=
    [[], [0x7f], [0x80], [0xbf], [0xc0], [0x80, 0x80], [0x80, 0xbf], [0xbf, 0x7f], [0x80, 0xc0], [0xc0, 0x80], [0xbf, 0xbf]]
  for b in [0x80:0x100] do
    for c in seconds do
      for t in tails do
        let s := b :: c :: t
        let values := [0, 31, 32].map fun n =>
          [0x7b, 0x22, 0x62, 0x6f, 0x64, 0x79, 0x22, 0x3a, 0x22] ++ List.replicate n 0x61 ++ s ++ [0x22, 0x7d]
        for l in values ++ [[0x7b, 0x22] ++ s ++ [0x22, 0x3a, 0x30, 0x7d], [0x22] ++ s ++ [0x22], 0x22 :: s] do
          let a := bytesOf l
          let top := Json.parseTop a 0 a.size #[kBodyKey]
          if !topEq top (refParseTop a 0 a.size #[kBodyKey]) then
            return .error s!"Json.parseTop differs on {l}"
          if let .object fs := top then
            for f in fs do
              if f.kind == .str && Json.decodeString a f.lo f.hi != refDecodeString a f.lo f.hi then
                return .error s!"Json.decodeString differs on {l} (range {f.lo} {f.hi})"
          if Json.decodeString a 0 a.size != refDecodeString a 0 a.size then
            return .error s!"Json.decodeString differs on {l}"
  return .ok ()

/-! ### Routes -/

def postIdEq : PostId → PostId → Bool
  | .ok m, .ok n => m == n
  | .invalid, .invalid => true
  | _, _ => false

def routeEq : Route → Route → Bool
  | .health, .health | .feed, .feed | .create, .create | .notFound, .notFound => true
  | .post i, .post j | .like i, .like j => postIdEq i j
  | _, _ => false

def routePaths : Array String := #["/feed", "/health", "/posts", "/posts/", "/posts/123", "/posts/1", "/posts/0", "/posts/007",
  "/posts/000", "/posts/12a", "/posts/-1", "/posts/1/like", "/posts/0/like", "/posts//like", "/posts/1/likes",
  "/posts/like", "/posts/12/like/", "/posts/1/2/like", "/posts/9223372036854775807", "/posts/9223372036854775808",
  "/posts/18446744073709551616/like", "/posts/12345678901234567890123", "/posts/00000000000000000000001",
  "/posts/00000000000000000000000/like", "/feed/", "/FEED", "/Posts/1", "", "/", "/posts/1/2", "/healthz", "/post/1/like"]

/-- `route` against its Lean definition: paths inside other bytes, with the range sometimes
off by one, reversed or past the end, for every method. -/
def checkRoutes (rounds : Nat) : Except String Unit := Id.run do
  let mut g : Rng := ⟨0x3c6ef372fe94f82b⟩
  for i in [0:rounds] do
    let (path, g1) := g.pick routePaths
    let (pre, g2) := g1.bytes 6
    let (post, g3) := g2.bytes 6
    let (m, g4) := g3.below 3
    let (k, g5) := g4.below 12
    let (x, g6) := g5.below 4
    let (y, g7) := g6.next
    let (hd, g8) := g7.below 2
    g := g8
    let p := path.toUTF8
    let a := pre ++ p ++ post
    let (lo, hi) :=
      if k == 0 then (pre.size + x, pre.size + p.size)
      else if k == 1 then (pre.size, pre.size + p.size + x)
      else if k == 2 then (pre.size + p.size, pre.size)
      else if k == 3 then (pre.size, 2 ^ 64 + y.toNat)
      else if k == 4 then (2 ^ 64 + y.toNat, pre.size + p.size)
      else if k == 5 then (y.toNat % (a.size + 2), y.toNat / 7 % (a.size + 2))
      else (pre.size, pre.size + p.size)
    let method : Http.Method := if m == 0 then .get else if m == 1 then .post else .other
    -- method, pathLo, pathHi, hasAuth, authLo, authHi, bodyLo, bodyHi, close, next, head
    let r : Http.Req := ⟨method, lo, hi, false, 0, 0, 0, 0, false, 0, hd == 1⟩
    if !routeEq (route a r) (refRoute a r) then
      return .error s!"route differs (round {i}, path {path})"
  return .ok ()

/-- Text that is mostly base64url: random characters (sometimes another byte or `=`), or the
encoding of random bytes, the one text that decodes to them, sometimes with its last character
changed (which mostly sets bits after the last byte); then sometimes `=` padding. -/
def Rng.b64Text (g : Rng) (maxLen : Nat) : ByteArray × Rng := Id.run do
  let alphabet := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".toUTF8
  let (kind, g0) := g.below 2
  let (n, g0) := g0.below (maxLen + 1)
  let mut g := g0
  let mut a := ByteArray.emptyWithCapacity (n + 2)
  if kind == 0 then
    for _ in [0:n] do
      let (k, g1) := g.below 100
      let (x, g2) := g1.next
      a := a.push (if k == 0 then x.toUInt8 else if k == 1 then 0x3d else alphabet.get! (x.toNat % 64))
      g := g2
  else
    let (d, g1) := g.bytes (maxLen * 3 / 4)
    let (k, g2) := g1.below 2
    let (x, g3) := g2.next
    g := g3
    a := refB64Encode d
    if k == 0 && a.size > 0 then a := a.set! (a.size - 1) (alphabet.get! (x.toNat % 64))
  let (pad, g4) := g.below 8
  if pad == 1 then a := a.push 0x3d
  if pad == 2 then a := (a.push 0x3d).push 0x3d
  return (a, g4)

/-- The JWT leaves (HMAC-SHA256, base64url) against their Lean definitions. -/
def checkCrypto (rounds : Nat) : Except String Unit := Id.run do
  let mut g : Rng := ⟨0x2545f4914f6cdd1d⟩
  for i in [0:rounds] do
    let (secret, g1) := g.bytes 140
    let (m, g2) := g1.bytes 300
    let (lo, g3) := g2.bound m.size
    let (hi, g4) := g3.bound m.size
    let (t, g5) := g4.b64Text 120
    let (tlo, g6) := g5.bound t.size
    let (thi, g7) := g6.bound t.size
    g := g7
    let key := Hmac.Key.of secret
    if Hmac.mac key m lo hi != refMac key m lo hi then
      return .error s!"Hmac.mac differs (round {i})"
    if Hmac.mac key m 0 m.size != refMac key m 0 m.size then
      return .error s!"Hmac.mac differs on a whole message (round {i})"
    if Jwt.b64Encode m != refB64Encode m then
      return .error s!"b64Encode differs (round {i})"
    if Jwt.b64Decode t tlo thi != refB64Decode t tlo thi then
      return .error s!"b64Decode differs (round {i})"
    if Jwt.b64Decode t 0 t.size != refB64Decode t 0 t.size then
      return .error s!"b64Decode differs on a whole text (round {i})"
  return .ok ()

def hex (b : ByteArray) : String :=
  b.foldl (fun s x => s ++ (if x < 16 then "0" else "") ++ String.ofList (Nat.toDigits 16 x.toNat)) ""

/-- FIPS 180-4 and RFC 4231 test vectors (`Feed/Spec/Sha256Vectors.lean` checks the same ones
on the specification): SHA-256 through `Sha256.hash`, HMAC-SHA256 through the C `Hmac.mac` on keys
from `Hmac.Key.of`. Each MAC is taken of the message as a whole, as a range inside a longer array,
and as a range whose end is past the array's (at 2^64 too); the empty message also as ranges
given backwards or past the end, which `Hmac.mac` clamps to an empty one. -/
def checkSha : Except String Unit := do
  let rep (c : Char) (n : Nat) : ByteArray := (String.ofList (List.replicate n c)).toUTF8
  let cases : List (ByteArray × String) := [
    ("abc".toUTF8, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
    ("".toUTF8, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
    ("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".toUTF8,
      "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"),
    ("abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu".toUTF8,
      "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1"),
    (rep 'a' 1000, "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")]
  for (m, want) in cases do
    if hex (Sha256.hash m) != want then throw s!"SHA-256 differs on a {m.size}-byte message"
  let bytes (b : UInt8) (n : Nat) : ByteArray := ⟨Array.replicate n b⟩
  -- RFC 4231 §4's seven cases (case 5 truncated to 128 bits, as printed), then the empty message
  -- under the keys of cases 2 and 6 (the MACs OpenSSL gives)
  let macs : List (ByteArray × ByteArray × String) := [
    (bytes 0x0b 20, "Hi There".toUTF8, "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"),
    ("Jefe".toUTF8, "what do ya want for nothing?".toUTF8,
      "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"),
    (bytes 0xaa 20, bytes 0xdd 50, "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe"),
    (⟨(Array.range 25).map (·.toUInt8 + 1)⟩, bytes 0xcd 50,
      "82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b"),
    (bytes 0x0c 20, "Test With Truncation".toUTF8, "a3b6167473100ee06e0c796c2955552b"),
    (bytes 0xaa 131, "Test Using Larger Than Block-Size Key - Hash Key First".toUTF8,
      "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54"),
    (bytes 0xaa 131, ("This is a test using a larger than block-size key and a larger than block-size data. " ++
      "The key needs to be hashed before being used by the HMAC algorithm.").toUTF8,
      "9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2"),
    ("Jefe".toUTF8, ByteArray.empty, "923598ca6d64af2a5dba79dcd021a8a0fe5c5f557519adaaf0ad532d4506dd30"),
    (bytes 0xaa 131, ByteArray.empty, "44b545def5b97eb719d856a15e327833e520e4770619c0e3eefbde24b71285a7")]
  for (k, m, want) in macs do
    let key := Hmac.Key.of k
    let n := m.size
    let w := "ab".toUTF8 ++ m ++ "cde".toUTF8   -- m is w[2, 2 + n)
    let e := "ab".toUTF8 ++ m                   -- and e[2, ∞)
    let mut ranges : List (ByteArray × Nat × Nat) := [(m, 0, n), (w, 2, 2 + n), (e, 2, n + 100), (e, 2, 2 ^ 64)]
    if n == 0 then ranges := ranges ++ [(w, 4, 1), (w, 2 ^ 64, 3), (w, 6, 2 ^ 64 + 1), (w, 9, 20)]
    for (a, lo, hi) in ranges do
      let mac := Hmac.mac key a lo hi
      if mac.size != 32 || hex (mac.extract 0 (want.length / 2)) != want then
        throw s!"HMAC-SHA256 differs on a {n}-byte message, as the range [{lo}, {hi}) of {a.size} bytes"

/-- RFC 4648 §10's vectors in base64url without padding, each of which decodes; with their
padding, with bits set after the last byte, or of a length 1 mod 4, none does. -/
def checkB64 : Except String Unit := do
  let vectors : List (String × String) := [("", ""), ("f", "Zg"), ("fo", "Zm8"), ("foo", "Zm9v"),
    ("foob", "Zm9vYg"), ("fooba", "Zm9vYmE"), ("foobar", "Zm9vYmFy")]
  for (d, s) in vectors do
    let t := s.toUTF8
    if Jwt.b64Decode t 0 t.size != some d.toUTF8 then throw s!"base64url differs on {s}"
  for s in ["Zg==", "Zm8=", "Zm9vYg==", "Zm9vYmE=", "Zg=", "Zm9v=", "Zh", "Zm9", "Zm9vYh", "Zm9vYmF", "Z", "Zm9vY"] do
    let t := s.toUTF8
    if Jwt.b64Decode t 0 t.size != none then throw s!"base64url decodes {s}"

def resultEq : Jwt.Result → Jwt.Result → Bool
  | .invalid, .invalid | .badPayload, .badPayload => true
  | .ok u n, .ok v m => u == v && n == m
  | _, _ => false

/-- The token `h.p.<signature>` for base64url parts `h` and `p`, signed with `key`. -/
def signParts (key : Hmac.Key) (h p : ByteArray) : ByteArray :=
  let hp := h ++ ".".toUTF8 ++ p
  hp ++ ".".toUTF8 ++ Jwt.b64Encode (Hmac.mac key hp 0 hp.size)

/-- `Jwt.verify` on tokens signed here: valid ones (whose payloads end in groups of each length),
and what RFC 7515 and RFC 7519 make invalid although the signature is right: `crit`, a `cty` of a
nested JWT, `aud` (before a bad `sub` is looked at), padding, bits set after the last byte. -/
def checkTokens : Except String Unit := do
  let key := Hmac.Key.of "twelve-dollar-challenge".toUTF8
  let enc (s : String) : ByteArray := Jwt.b64Encode s.toUTF8
  let sign (h p : String) : ByteArray := signParts key (enc h) (enc p)
  let hdr := "{\"alg\":\"HS256\",\"typ\":\"JWT\"}"
  -- 51, 52 and 53 bytes: no padding, two '=' and one '=' in base64
  let pay := "{\"sub\":\"7\",\"username\":\"u\",\"iat\":1,\"exp\":2000000000}"
  let pay2 := "{\"sub\":\"7\",\"username\":\"uv\",\"iat\":1,\"exp\":2000000000}"
  let pay3 := "{\"sub\":\"7\",\"username\":\"uvw\",\"iat\":1,\"exp\":2000000000}"
  let p2 := enc pay2
  let p3 := enc pay3
  let ok : Jwt.Result := .ok 7 "u".toUTF8
  let cases : List (String × ByteArray × Jwt.Result) := [
    ("a valid token", sign hdr pay, ok),
    ("a valid token, two characters in its last group", sign hdr pay2, .ok 7 "uv".toUTF8),
    ("a valid token, three characters in its last group", sign hdr pay3, .ok 7 "uvw".toUTF8),
    ("crit", sign "{\"alg\":\"HS256\",\"crit\":[\"x\"],\"x\":1}" pay, .invalid),
    ("an empty crit", sign "{\"alg\":\"HS256\",\"crit\":[]}" pay, .invalid),
    ("cty JWT", sign "{\"alg\":\"HS256\",\"cty\":\"JWT\"}" pay, .invalid),
    ("cty application/jwt", sign "{\"alg\":\"HS256\",\"cty\":\"Application/JWT\"}" pay, .invalid),
    ("cty JWT, escaped", sign "{\"alg\":\"HS256\",\"cty\":\"\\u004aWT\"}" pay, .invalid),
    ("another cty", sign "{\"alg\":\"HS256\",\"cty\":\"jwt+json\"}" pay, ok),
    ("a cty that is not a string", sign "{\"alg\":\"HS256\",\"cty\":1}" pay, ok),
    ("aud", sign hdr "{\"sub\":\"7\",\"username\":\"u\",\"exp\":2000000000,\"aud\":\"another-service\"}", .invalid),
    ("aud and a bad sub", sign hdr "{\"sub\":\"x\",\"username\":\"u\",\"exp\":2000000000,\"aud\":[]}", .invalid),
    ("padding", signParts key (enc hdr) (p2 ++ "==".toUTF8), .invalid),
    ("one '=' of padding", signParts key (enc hdr) (p3 ++ "=".toUTF8), .invalid),
    ("a set bit after the last byte", signParts key (enc hdr) (p2.set! (p2.size - 1) (p2.get! (p2.size - 1) + 1)), .invalid),
    ("a set bit after the last two bytes", signParts key (enc hdr) (p3.set! (p3.size - 1) (p3.get! (p3.size - 1) + 1)),
      .invalid)]
  for (what, t, want) in cases do
    if !resultEq (Jwt.verify key 1700000000 t 0 t.size) want then throw s!"Jwt.verify differs on {what}"

/-! ## Storage operations against the model -/

open Spec

@[extern "feed_db_create"] opaque dbCreate (path script : @& String) : IO Bool
@[extern "feed_db_open"] opaque dbOpen (path : @& String) : IO Unit
/-- The grouped rowid search of `runtime/db.c` against SQLite's own, on every key of `users`. -/
@[extern "feed_db_check_lookups"] opaque checkLookups : IO Bool
/-- The reads of `runtime/db.c` over the batch's pages against SQLite's cursors: the in-order pass
over both indexes, the like counts of every post id and of random windows of ids, the grouped rowid
search on `posts`; on the test database and, rolled back after, on one whose trees have three levels. -/
@[extern "feed_db_check_index"] opaque checkIndexes : IO Bool
/-- A rolled-back transaction that grew the file, through the page cache wrapper of `runtime/db.c`. -/
@[extern "feed_db_check_rollback"] opaque checkRollback : IO Bool
/-- `PRAGMA integrity_check` says ok. -/
@[extern "feed_db_integrity"] opaque integrityOk : IO Bool

def hexOf (l : List UInt8) : String :=
  String.join (l.map fun x => (if x < 16 then "0" else "") ++ String.ofList (Nat.toDigits 16 x.toNat))

def textLit (l : List UInt8) : String := s!"CAST(X'{hexOf l}' AS TEXT)"

def schema : String :=
  "PRAGMA journal_mode = WAL;
CREATE TABLE users (id INTEGER PRIMARY KEY, username TEXT NOT NULL UNIQUE,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')));
CREATE TABLE posts (id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL REFERENCES users(id),
  body TEXT NOT NULL CHECK (length(body) BETWEEN 1 AND 500),
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')));
CREATE TABLE likes (user_id INTEGER NOT NULL REFERENCES users(id), post_id INTEGER NOT NULL REFERENCES posts(id),
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')), PRIMARY KEY (user_id, post_id));
CREATE INDEX posts_created_at_id_idx ON posts (created_at DESC, id DESC);
CREATE INDEX posts_user_id_idx ON posts (user_id);
CREATE INDEX likes_post_id_idx ON likes (post_id);
"

def Rng.text (g : Rng) (lo hi : Nat) (alphabet : Array UInt8) : List UInt8 × Rng := Id.run do
  let (n, g0) := g.below (hi - lo + 1)
  let mut g := g0
  let mut out : List UInt8 := []
  for _ in [0:lo + n] do
    let (k, g') := g.below alphabet.size
    out := alphabet[k]! :: out
    g := g'
  return (out, g)

def bodyChars : Array UInt8 := "abc xyz\"\\\t/0189".toUTF8.data
/-- Few distinct timestamps, so that many posts tie on `created_at`. -/
def stamps : Array String := #["2025-01-01T00:00:00.000Z", "2025-06-30T12:00:00.000Z", "2025-12-31T23:59:59.999Z",
  "2026-01-01T00:00:00.000Z", "2025-06-30T12:00:00.001Z"]

/-- The number of user ids: enough users that the `users` table is a B-tree of three levels. -/
def nUserIds : Nat := 60000

/-- A random database: user ids with gaps, posts with ids out of `created_at` order and with ties,
posts whose author row is missing, likes. -/
def randomDb (g : Rng) : DB × Rng := Id.run do
  let mut g := g
  let mut users : List User := []
  for i in [1:nUserIds] do
    let (k, g') := g.below 5
    g := g'
    if k != 0 then users := ⟨i, Spec.lit s!"user_{i}"⟩ :: users
  users := users.reverse
  let mut posts : List Post := []
  let mut id := 1
  for _ in [0:400] do
    let (gap, g1) := g.below 4
    let (k, g2) := g1.below 3
    let (uid, g2) := if k == 0 then g2.below 130 else g2.below (nUserIds + 10)
    let (st, g3) := g2.below stamps.size
    let (body, g4) := g3.text 1 40 bodyChars
    g := g4
    id := id + (if gap == 0 then 3 else 1)
    posts := ⟨id, uid + 1, body, Spec.lit stamps[st]!⟩ :: posts
  posts := posts.reverse
  let mut likes : List Like := []
  for _ in [0:1500] do
    let (uid, g1) := g.below 130
    let (pk, g2) := g1.below posts.length
    g := g2
    let pid := posts[pk]!.id
    unless likes.any (fun l => l.userId == uid + 1 && l.postId == pid) do
      likes := likes ++ [⟨uid + 1, pid⟩]
  return (⟨users, posts, likes, Spec.lit "2026-01-01T00:00:00.000Z"⟩, g)

def script (db : DB) : String := Id.run do
  let mut s := schema ++ "BEGIN;\n"
  for u in db.users do
    s := s ++ s!"INSERT INTO users (id, username) VALUES ({u.id}, {textLit u.name});\n"
  for p in db.posts do
    s := s ++ s!"INSERT INTO posts (id, user_id, body, created_at) VALUES ({p.id}, {p.userId}, {textLit p.body}, {textLit p.createdAt});\n"
  for l in db.likes do
    s := s ++ s!"INSERT INTO likes (user_id, post_id) VALUES ({l.userId}, {l.postId});\n"
  return s ++ "COMMIT;\n"

/-- `Page.Same`: as many columns, and every row reads back as the same post object (the text may
lie in the blob in another order). By `feedFromPage_congr` and `postFromPage_congr` the handler
answers the same from either page. -/
def samePage (a b : Page) : Bool :=
  a.cols.size == b.cols.size && (List.range (a.cols.size / 8)).all fun k => a.view k == b.view k

def Rng.ids (g : Rng) (n bound : Nat) : Array Nat × Rng := Id.run do
  let mut g := g
  let mut out := #[]
  for _ in [0:n] do
    let (k, g1) := g.below 20
    let (x, g2) := g1.below bound
    g := g2
    out := out.push (if k == 0 then 2 ^ 70 + x else if k == 1 then 0 else x)
  return (out, g)

/-- Every read operation, on random arguments, in one read phase. -/
def checkReads (db : DB) (g : Rng) : IO Rng := do
  let mut g := g
  unless ← Store.begin (m := IO) do throw (IO.userError "begin failed")
  for n in [0, 1, 2, 5, 20, 21, 40, 64, 65, 100, 100000] do
    unless samePage (← Store.feedPage (m := IO) n) ((Store.feedPage (m := Model) n).run db).1 do
      throw (IO.userError s!"feedPage {n} differs from the model")
  let maxId := (db.posts.map (·.id)).foldl max 0
  let (ids, g1) := g.ids 600 (maxId + 10)
  g := g1
  for id in ids ++ #[0, 1, maxId, maxId + 1, 2 ^ 63 - 1, 2 ^ 63, 2 ^ 64] do
    unless samePage (← Store.postPage (m := IO) id) ((Store.postPage (m := Model) id).run db).1 do
      throw (IO.userError s!"postPage {id} differs from the model")
  Store.endReads (m := IO)
  unless ← Store.commit (m := IO) do throw (IO.userError "commit failed")
  return g

/-- Bodies `postText` lets through at the edges of schema.sql's `CHECK (length(body) BETWEEN 1 AND
500)`, where SQLite's `length` counts the characters before the first NUL: 500 characters of one,
two, three and four bytes, a NUL after the first character, a NUL as the 500th. -/
def edgeBodies : Array (List UInt8) :=
  let rep (s : String) (n : Nat) : List UInt8 := (List.replicate n (Spec.lit s)).flatten
  #[rep "x" 500, rep "é" 500, rep "中" 500, rep "😀" 500, [0x78, 0], [0x78, 0] ++ rep "y" 498, rep "é" 499 ++ [0]]

/-- Random writes in one write phase, each compared with the model; the model after them. The
model gives the phase one clock reading: every post gets the `created_at` of the phase's first,
which differs from the last phase's, and the phase waits 2 ms after that one, so that a time taken
per insert would differ. Some bodies are at the edges of the schema's CHECK; some start with
U+0000, which the CHECK refuses (`postText` answers them 500): no row, id 0. -/
def checkWrites (db : DB) (g : Rng) : IO (DB × Rng) := do
  let mut g := g
  let mut db := db
  let mut timed := false
  unless ← Store.begin (m := IO) do throw (IO.userError "begin failed")
  Store.endReads (m := IO)
  let maxId := (db.posts.map (·.id)).foldl max 0
  for _ in [0:60] do
    let (k, g1) := g.below 3
    let (uid, g2) := g1.below (nUserIds + 10)
    let (pid, g3) := g2.below (maxId + 20)
    let (body, g4) := g3.text 1 30 bodyChars
    let (e, g5) := g4.below 8
    let (edge, g6) := g5.below edgeBodies.size
    g := g6
    if k == 0 then
      let got ← Store.postExists (m := IO) pid
      let (want, _) := (Store.postExists (m := Model) pid).run db
      unless got == want do throw (IO.userError s!"postExists {pid} differs from the model")
    else if k == 1 then
      let got ← Store.insertLike (m := IO) (uid + 1) pid
      let (want, db') := (Store.insertLike (m := Model) (uid + 1) pid).run db
      unless got == want do throw (IO.userError s!"insertLike {uid + 1} {pid} differs from the model")
      db := db'
    else if e == 0 then
      let (created, id) ← Store.insertPost (m := IO) (uid + 1) ⟨(0 :: body).toArray⟩
      unless id == 0 && created.size == 0 do
        throw (IO.userError s!"insertPost of a body that starts with U+0000 added a row (id {id})")
    else
      let body := if e == 1 then edgeBodies[edge]! else body
      let (created, id) ← Store.insertPost (m := IO) (uid + 1) ⟨body.toArray⟩
      unless timed do
        -- the time is taken anew: the last phase's first post is at least 2 ms older
        if bs created == db.clock then throw (IO.userError "a write phase kept the last phase's created_at")
        db := { db with clock := bs created }
        timed := true
        IO.sleep 2
      let ((created', id'), db') := (Store.insertPost (m := Model) (uid + 1) ⟨body.toArray⟩).run db
      unless id == id' && created.data == created'.data do
        throw (IO.userError s!"insertPost differs from the model (id {id} vs {id'}, created_at {(String.fromUTF8? created).getD ""} vs {(String.fromUTF8? created').getD ""})")
      db := db'
  unless ← Store.commit (m := IO) do throw (IO.userError "commit failed")
  return (db, g)

/-! ## One batch through the handler, at `IO` and on the model -/

/-- A token for user `uid` named `name`, signed with `key`, that expires at `exp`. -/
def token (key : Hmac.Key) (uid : Nat) (name : String) (exp : Nat) : ByteArray :=
  let hp := Jwt.b64Encode "{\"alg\":\"HS256\",\"typ\":\"JWT\"}".toUTF8 ++ ".".toUTF8 ++
    Jwt.b64Encode ("{\"sub\":\"" ++ toString uid ++ "\",\"username\":\"" ++ name ++ "\",\"exp\":" ++ toString exp ++ "}").toUTF8
  hp ++ ".".toUTF8 ++ Jwt.b64Encode (Hmac.mac key hp 0 hp.size)

/-- A request with the token and a body (`head` is the method and the path). -/
def request (head : String) (tok : ByteArray) (body : String) : ByteArray :=
  head.toUTF8 ++ " HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer ".toUTF8 ++ tok ++
    s!"\r\nContent-Length: {body.toUTF8.size}\r\n\r\n{body}".toUTF8

/-- `POST /posts` bodies: texts that start with U+0000 once trimmed, which the schema's CHECK
refuses (500, no row), and four new posts. -/
def batchBodies : Array String := #["{\"body\":\"\\u0000x\"}", "{\"body\":\"first\"}", "{\"body\":\"  \\u0000\"}",
  "{\"body\":\"x\\u0000y\"}", "{\"body\":\"\\u0000\"}", "{\"body\":\" second \"}", "{\"body\":\"\\u2028\\u0000x\"}",
  "{\"body\":\"third\"}"]

/-- The `created_at` of the first post object in a response, if it has one. -/
def createdIn (b : ByteArray) : Option (List UInt8) :=
  (List.range b.size).findSome? fun i =>
    if slice b i (i + kCreated.size) == bs kCreated then some (slice b (i + kCreated.size) (i + kCreated.size + 24))
    else none

def replyEq (a b : Reply) : Bool := a.resp == b.resp && a.start == b.start && a.consumed == b.consumed && a.flags == b.flags

/-- One batch, a request per connection (the bodies above, a like, the feed, and the post the
batch inserts first, not found in the batch's snapshot), through `runBatch` at `IO` (the C storage
on the test database, the C leaves) and on the model, whose clock is the `created_at` of the
batch's first new post: the same replies, byte for byte. So the bodies that start with U+0000 get
500 and add no row (`checkReads` after it compares the tables), and the four new posts share
their `created_at`. The model after it. -/
def checkBatch (db : DB) : IO DB := do
  let key := Hmac.Key.of "selftest".toUTF8
  let tok := token key 1 "user_1" 2000
  let pid := (db.posts.head?.map (·.id)).getD 1
  let chunks := batchBodies.map (request "POST /posts" tok) ++ #[request s!"POST /posts/{pid}/like" tok "",
    request "GET /feed" tok "", request s!"GET /posts/{db.nextPostId}" tok ""]
  let env : Env := { key, now := 1000, uptime := 7, writesOk := true }
  let got ← runBatch (m := IO) env chunks
  let clock := (got.toList.findSome? fun r =>
    if (bs r.resp).take 12 == Spec.lit "HTTP/1.1 201" then createdIn r.resp else none).getD []
  let (want, db') := (runBatch (m := Model) env chunks).run { db with clock }
  unless got.size == want.size && (List.range got.size).all fun i => replyEq got[i]! want[i]! do
    throw (IO.userError "a batch through the handler at IO differs from the model")
  return db'

def checkStorage (path : String) : IO Unit := do
  let (db, g) := randomDb ⟨0x2545f4914f6cdd1d⟩
  unless ← dbCreate path (script db) do throw (IO.userError "could not create the test database")
  dbOpen path
  unless ← checkLookups do throw (IO.userError "the grouped rowid search differs from SQLite's")
  unless ← checkIndexes do throw (IO.userError "the index passes, like counts or rowid search differ from SQLite's cursors")
  unless ← checkRollback do throw (IO.userError "a rolled-back transaction left the database wrong")
  let mut g ← checkReads db g
  let mut db := db
  for _ in [0:5] do
    let (db', g') ← checkWrites db g
    db := db'
    g ← checkReads db g'
  db ← checkBatch db
  let _ ← checkReads db g
  unless ← integrityOk do throw (IO.userError "the database fails SQLite's integrity check after the writes")

def run (path : String) : IO UInt32 := do
  match checkLeaves 20000 with
  | .error e => IO.eprintln s!"selftest: {e}"; return 1
  | .ok () => pure ()
  match checkPages 20000 with
  | .error e => IO.eprintln s!"selftest: {e}"; return 1
  | .ok () => pure ()
  match checkFeedResponses 20000 with
  | .error e => IO.eprintln s!"selftest: {e}"; return 1
  | .ok () => pure ()
  match checkPostResponses 20000 with
  | .error e => IO.eprintln s!"selftest: {e}"; return 1
  | .ok () => pure ()
  match checkHttpExamples with
  | .error e => IO.eprintln s!"selftest: {e}"; return 1
  | .ok () => pure ()
  match checkHttpBytes with
  | .error e => IO.eprintln s!"selftest: {e}"; return 1
  | .ok () => pure ()
  match checkParse 20000 with
  | .error e => IO.eprintln s!"selftest: {e}"; return 1
  | .ok () => pure ()
  match checkHttp 20000 with
  | .error e => IO.eprintln s!"selftest: {e}"; return 1
  | .ok () => pure ()
  match checkRoutes 20000 with
  | .error e => IO.eprintln s!"selftest: {e}"; return 1
  | .ok () => pure ()
  match checkJson 20000 with
  | .error e => IO.eprintln s!"selftest: {e}"; return 1
  | .ok () => pure ()
  match checkUtf8 with
  | .error e => IO.eprintln s!"selftest: {e}"; return 1
  | .ok () => pure ()
  match checkSha with
  | .error e => IO.eprintln s!"selftest: {e}"; return 1
  | .ok () => pure ()
  match checkB64 with
  | .error e => IO.eprintln s!"selftest: {e}"; return 1
  | .ok () => pure ()
  match checkTokens with
  | .error e => IO.eprintln s!"selftest: {e}"; return 1
  | .ok () => pure ()
  match checkCrypto 20000 with
  | .error e => IO.eprintln s!"selftest: {e}"; return 1
  | .ok () => pure ()
  try checkStorage path
  catch e => IO.eprintln s!"selftest: {e}"; return 1
  IO.println s!"selftest: the C leaves (bytes, HTTP framing, HMAC-SHA256, base64url, feed pages, the feed's and a post's responses, routes, JSON input) agree with their Lean definitions on 20000 random inputs, HTTP framing also with each byte in {byteSlots.size} places of a request and on the prefixes of 20000 more, and on JSON strings with each byte from 0x80 to 0xff; HTTP framing gives the specification's frames of {httpExamples.size} inputs at the start of the input and after other bytes, and each checked prefix of the 20000 more is a wait or reads as the whole input; the storage operations and a batch through the handler with the model on a random database; the grouped rowid search and the index pass with SQLite's; a rollback and the integrity check; SHA-256, HMAC and base64url with the test vectors; the token checks on signed tokens"
  return 0

end Feed.Selftest
