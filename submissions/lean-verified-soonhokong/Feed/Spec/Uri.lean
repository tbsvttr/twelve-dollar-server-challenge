import Feed.Spec

/-!
# Characters, request-targets and Host

The character classes and the URI grammar that `Feed/Spec/Http.lean` is written with: RFC 5234
Appendix B.1, RFC 9110 §5.5 and §5.6 (field values, tokens, whitespace), RFC 3986 §2-4 (URI
characters, hosts, paths, absolute URIs), RFC 9110 §4.2 and §7.2 (http URIs, Host) and RFC 9112
§3.2 (the forms of a request-target). `Feed/Proofs/Uri.lean` proves that the code's deciders
decide `HostPort` and `TargetPath` (`Http.hostOk_iff`, `Http.target_spec`), and that a target has
one path (`targetPath_unique`).
-/
namespace Feed.Spec.Http

abbrev Bytes := List UInt8

/-! ## Characters -/

/-- RFC 5234 B.1 `DIGIT` -/
def isDigit (c : UInt8) : Bool := 0x30 ≤ c && c ≤ 0x39
/-- RFC 5234 B.1 `ALPHA` -/
def isAlpha (c : UInt8) : Bool := (0x41 ≤ c && c ≤ 0x5a) || (0x61 ≤ c && c ≤ 0x7a)
/-- `HEXDIG` (ABNF strings are case-insensitive, RFC 5234 §2.3) -/
def isHex (c : UInt8) : Bool := isDigit c || (0x41 ≤ c && c ≤ 0x46) || (0x61 ≤ c && c ≤ 0x66)
/-- RFC 9110 §5.6.2 `tchar` -/
def isTchar (c : UInt8) : Bool := isDigit c || isAlpha c || (lit "!#$%&'*+-.^_`|~").contains c
/-- SP / HTAB -/
def isWs (c : UInt8) : Bool := c == 0x20 || c == 0x09
/-- RFC 9110 §5.5 `field-vchar = VCHAR / obs-text` -/
def isVchar (c : UInt8) : Bool := (0x21 ≤ c && c ≤ 0x7e) || 0x80 ≤ c
/-- RFC 3986 §2.3 `unreserved` -/
def isUnreserved (c : UInt8) : Bool := isAlpha c || isDigit c || (lit "-._~").contains c
/-- RFC 3986 §2.2 `sub-delims` -/
def isSubDelim (c : UInt8) : Bool := (lit "!$&'()*+,;=").contains c
/-- ASCII case folding (field names, connection options and schemes are case-insensitive) -/
def lower (s : Bytes) : Bytes := s.map fun b => if 0x41 ≤ b ∧ b ≤ 0x5a then b + 32 else b
/-- RFC 9110 §5.6.2 `token = 1*tchar` -/
def IsToken (s : Bytes) : Prop := s ≠ [] ∧ ∀ c ∈ s, isTchar c = true
/-- RFC 9110 §5.6.3 `OWS` -/
def Ows (w : Bytes) : Prop := ∀ c ∈ w, isWs c = true

/-! ## URI components (RFC 3986) -/

/-- `*( unreserved / pct-encoded / sub-delims / extra )` (§2.1-2.3) -/
inductive UriChars (extra : UInt8 → Bool) : Bytes → Prop
  | nil : UriChars extra []
  | char {c : UInt8} {s : Bytes} : (isUnreserved c || isSubDelim c || extra c) = true → UriChars extra s →
      UriChars extra (c :: s)
  | pct {h l : UInt8} {s : Bytes} : isHex h = true → isHex l = true → UriChars extra s →
      UriChars extra (0x25 :: h :: l :: s)

/-- path characters: `pchar` (":" "@") and "/" (§3.3) -/
def PathChars : Bytes → Prop := UriChars fun c => c == 0x3a || c == 0x40 || c == 0x2f
/-- `query = *( pchar / "/" / "?" )` (§3.4) -/
def QueryChars : Bytes → Prop := UriChars fun c => c == 0x3a || c == 0x40 || c == 0x2f || c == 0x3f
/-- `t` is `p` followed by an optional `"?" query` -/
def WithQuery (t p : Bytes) : Prop := t = p ∨ ∃ q, QueryChars q ∧ t = p ++ [0x3f] ++ q
/-- RFC 9112 §3.2.1 `origin-form = absolute-path [ "?" query ]` -/
def OriginForm (t path : Bytes) : Prop := path.head? = some 0x2f ∧ PathChars path ∧ WithQuery t path

/-- `h16 = 1*4HEXDIG` (§3.2.2) -/
def H16 (g : Bytes) : Prop := g ≠ [] ∧ g.length ≤ 4 ∧ ∀ c ∈ g, isHex c = true
/-- `dec-octet`: 0 to 255 without a leading zero (§3.2.2) -/
def DecOctet (d : Bytes) : Prop := ∃ n, n < 256 ∧ d = digits n
/-- `IPv4address = dec-octet "." dec-octet "." dec-octet "." dec-octet` (§3.2.2) -/
def IPv4 (s : Bytes) : Prop :=
  ∃ a b c d, DecOctet a ∧ DecOctet b ∧ DecOctet c ∧ DecOctet d ∧
    s = a ++ [0x2e] ++ b ++ [0x2e] ++ c ++ [0x2e] ++ d
def joinColon : List Bytes → Bytes
  | [] => []
  | [g] => g
  | g :: gs => g ++ [0x3a] ++ joinColon gs
/-- `k` groups joined by ":"; with `v4`, the last two may be one IPv4address (`ls32`) -/
def Groups (v4 : Bool) (k : Nat) (s : Bytes) : Prop :=
  (∃ gs : List Bytes, gs.length = k ∧ (∀ g ∈ gs, H16 g) ∧ s = joinColon gs) ∨
  (v4 = true ∧ ∃ (gs : List Bytes) (t : Bytes), gs.length + 2 = k ∧ (∀ g ∈ gs, H16 g) ∧ IPv4 t ∧
    s = joinColon (gs ++ [t]))
/-- §3.2.2 `IPv6address`: 8 groups, or one "::" with at most 7 groups around it -/
def IPv6 (s : Bytes) : Prop :=
  Groups true 8 s ∨ ∃ l r i j, i + j ≤ 7 ∧ Groups false i l ∧ Groups true j r ∧ s = l ++ lit "::" ++ r
/-- §3.2.2 `IPvFuture = "v" 1*HEXDIG "." 1*( unreserved / sub-delims / ":" )` -/
def IPvFuture (s : Bytes) : Prop :=
  ∃ v h x, lower v = lit "v" ∧ h ≠ [] ∧ (∀ c ∈ h, isHex c = true) ∧ x ≠ [] ∧
    (∀ c ∈ x, (isUnreserved c || isSubDelim c || c == 0x3a) = true) ∧ s = v ++ h ++ [0x2e] ++ x
/-- §3.2.2 `host = IP-literal / IPv4address / reg-name` (an IPv4address is also a reg-name) -/
def UriHost (h : Bytes) : Prop :=
  UriChars (fun _ => false) h ∨ ∃ x, (IPv6 x ∨ IPvFuture x) ∧ h = [0x5b] ++ x ++ [0x5d]
/-- RFC 9110 §7.2 `Host = uri-host [ ":" port ]`, `port = *DIGIT` (RFC 3986 §3.2.3) -/
def HostPort (v host : Bytes) : Prop :=
  UriHost host ∧ (v = host ∨ ∃ p, (∀ c ∈ p, isDigit c = true) ∧ v = host ++ [0x3a] ++ p)
/-- §3.1 `scheme = ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )` -/
def Scheme (s : Bytes) : Prop :=
  s.head?.any isAlpha = true ∧ ∀ c ∈ s, (isAlpha c || isDigit c || (lit "+-.").contains c) = true
/-- §3.2 `authority = [ userinfo "@" ] host [ ":" port ]`, `userinfo = *( unreserved /
pct-encoded / sub-delims / ":" )` -/
def Authority (a : Bytes) : Prop :=
  ∃ u v h, (u = [] ∨ ∃ i, UriChars (· == 0x3a) i ∧ u = i ++ [0x40]) ∧ HostPort v h ∧ a = u ++ v
/-- §3 `hier-part = "//" authority path-abempty / path-absolute / path-rootless / path-empty`; the
last three together are the paths that do not start with "//" -/
def HierPart (h : Bytes) : Prop :=
  (∃ a p, Authority a ∧ (p = [] ∨ p.head? = some 0x2f) ∧ PathChars p ∧ h = lit "//" ++ a ++ p) ∨
    (PathChars h ∧ h.take 2 ≠ lit "//")

/-! ## Request-targets (RFC 9112 §3.2) -/

/-- §3.2.2 absolute-form of an "http" or "https" URI: RFC 9110 §4.2.1 and §4.2.2 (`"//" authority
path-abempty`, a host that is not empty) and §4.2.4 (no userinfo) -/
def AbsoluteForm (t path : Bytes) : Prop :=
  ∃ sch auth host, (lower sch = lit "http" ∨ lower sch = lit "https") ∧ HostPort auth host ∧ host ≠ [] ∧
    (path = [] ∨ path.head? = some 0x2f) ∧ PathChars path ∧ WithQuery t (sch ++ lit "://" ++ auth ++ path)
/-- the other request-targets: asterisk-form (§3.2.4), authority-form (§3.2.3) and the
absolute-form of any other scheme (RFC 3986 §4.3 `absolute-URI = scheme ":" hier-part [ "?" query ]`) -/
def OtherTarget (t : Bytes) : Prop :=
  t = lit "*" ∨ (∃ h p, HostPort (h ++ [0x3a] ++ p) h ∧ t = h ++ [0x3a] ++ p) ∨
  ∃ sch hp, Scheme sch ∧ lower sch ≠ lit "http" ∧ lower sch ≠ lit "https" ∧ HierPart hp ∧
    WithQuery t (sch ++ [0x3a] ++ hp)
/-- The path the API routes on (`Spec.route`); a valid target that names nothing here routes on []. -/
inductive TargetPath : Bytes → Bytes → Prop
  | origin {t p : Bytes} : OriginForm t p → TargetPath t p
  | absolute {t p : Bytes} : AbsoluteForm t p → TargetPath t p
  | other {t : Bytes} : OtherTarget t → TargetPath t []

end Feed.Spec.Http
