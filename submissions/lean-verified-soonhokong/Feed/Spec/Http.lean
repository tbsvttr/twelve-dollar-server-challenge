import Feed.Spec.Uri

/-!
# HTTP/1.1 requests

What RFC 9112 says the bytes of one request are (with RFC 9110 §5 for fields, §6.2 for the
version, §7.2 for Host, §8.6 for Content-Length and §9.3.2 for HEAD), and what the server is to
answer when a connection's unread input does not start with one. `Frames s f` reads the input `s`
as a request and its length, as malformed input with the status answered before the connection
closes, or as a wait for more bytes; `frame s` is that reading. Nothing here runs in the server;
`Feed/Http.lean` is written to it (the last paragraph below).

Where this server departs from the RFCs, or chooses where they leave room:

* any `Transfer-Encoding`, chunked included, is answered 400 and the connection closes
  (`HeadOk.noCoding`); RFC 9112 §6.1 asks a recipient to parse chunked, and suggests 501 for a
  coding it does not understand;
* `Expect: 100-continue` gets no 100 (Continue): the request waits for its content like any other,
  where RFC 9110 §10.1.1 asks an origin server to answer such a head at once;
* responses carry no `Date` field, which RFC 9110 §6.6.1 asks of an origin server with a clock in
  its 2xx, 3xx and 4xx responses;
* the answer to an HTTP/1.0 request with the `keep-alive` option leaves the connection open
  without saying so: HTTP/1.0's keep-alive (RFC 2068 §19.7.1, which RFC 9112 Appendix C.2.2
  cites) has the server answer with that option, and `Spec.response` sends no `Connection` field
  but `Connection: close`;
* a method other than GET, HEAD and POST is read like the others and answered 404 on every path
  (`Spec.route`), where RFC 9110 §9.1 suggests 501;
* a request with more than one `Authorization` line is answered 400 (`HeadOk.oneAuth`), where
  RFC 9110 §5.3 lets a recipient read the lines as one comma-separated value;
* a major version other than 1 is answered 400, where RFC 9110 §6.2 allows 505;
* a `Content-Length` line whose value is a list is answered 400 (`contentLength`), also when the
  list repeats one valid number, such as `5, 5`, where RFC 9112 §6.3 (5) processes the message with
  that number (RFC 9110 §8.6 lets a recipient reject it instead); repeated lines whose values are
  one number are read as that number, as §6.3 (5) reads the list that RFC 9110 §5.3 makes of them;
* the path is matched as sent, without percent-decoding or other normalization (RFC 9110 §4.2.3
  allows either), and an asterisk-form or authority-form target, or an absolute-form one of a
  scheme other than http and https, names nothing here (404).

The Lean definition of `Feed/Http.lean`'s parser computes `frame` on every input, from every
position in it (`Http.parse_view`, `Feed/Proofs/Http.lean`; its byte scan reads the head as this
file does, `Http.scan_spec` in `Feed/Proofs/HttpLines.lean`). The server runs its C version, which
the self-test compares with that definition on random inputs, and with the frames of this file on a
list of inputs (examples of this file's rules and of each choice above, at the start of an input
and after other bytes); on the random inputs it also compares the parser with itself, a prefix
reading as a wait or as the whole input does (every prefix of an input of up to 2,048 bytes).
-/
namespace Feed.Spec.Http

def crlf : Bytes := [0x0d, 0x0a]

/-! ## The head -/

/-- RFC 9110 §5.5 `field-value = *field-content`: field-vchar, SP and HTAB, not starting or ending
with SP or HTAB (so no CR, LF, NUL, other control character or DEL) -/
def FieldValue (v : Bytes) : Prop :=
  (∀ c ∈ v, (isVchar c || isWs c) = true) ∧ (∀ c ∈ v.head?, isWs c = false) ∧
    (∀ c ∈ v.getLast?, isWs c = false)
/-- RFC 9112 §5 `field-line = field-name ":" OWS field-value OWS`, `field-name = token`: no
whitespace before ":" (§5.1) and no line that starts with whitespace (obs-fold, §5.2) -/
def FieldLine (line name value : Bytes) : Prop :=
  IsToken name ∧ FieldValue value ∧ ∃ w₁ w₂, Ows w₁ ∧ Ows w₂ ∧ line = name ++ [0x3a] ++ w₁ ++ value ++ w₂
/-- RFC 9112 §2.3 `HTTP-version = HTTP-name "/" DIGIT "." DIGIT`, case-sensitive -/
def Version (v : Bytes) (major minor : Nat) : Prop :=
  ∃ a b, isDigit a = true ∧ isDigit b = true ∧ v = lit "HTTP/" ++ [a, 0x2e, b] ∧
    major = (a - 0x30).toNat ∧ minor = (b - 0x30).toNat
/-- RFC 9112 §3 `request-line = method SP request-target SP HTTP-version`, `method = token` -/
def RequestLine (line method target : Bytes) (major minor : Nat) : Prop :=
  IsToken method ∧ target ≠ [] ∧ 0x20 ∉ target ∧
    ∃ v, Version v major minor ∧ line = method ++ [0x20] ++ target ++ [0x20] ++ v
/-- `k` empty lines (RFC 9112 §2.2: a server SHOULD ignore at least one), the request-line, the
field lines, the empty line. No line holds a CR or LF: a bare CR or LF makes the head invalid
(§2.2). -/
def HeadLines (h : Bytes) (k : Nat) (line : Bytes) (fls : List Bytes) : Prop :=
  h = (List.replicate k crlf).flatten ++ line ++ crlf ++ (fls.map (· ++ crlf)).flatten ++ crlf ∧
    ∀ l ∈ line :: fls, l ≠ [] ∧ 0x0d ∉ l ∧ 0x0a ∉ l

/-- A head's parts: the empty lines before it, the request-line and its parts, the field lines and
each one's name and value. -/
structure Head where
  k : Nat
  line : Bytes
  method : Bytes
  target : Bytes
  major : Nat
  minor : Nat
  fls : List Bytes
  fs : List (Bytes × Bytes)

/-- `h` is a head (RFC 9112 §2.1, `HTTP-message` up to the message body) with these parts. -/
def IsHead (h : Bytes) (H : Head) : Prop :=
  HeadLines h H.k H.line H.fls ∧ RequestLine H.line H.method H.target H.major H.minor ∧
    H.fls.length = H.fs.length ∧ ∀ p ∈ H.fls.zip H.fs, FieldLine p.1 p.2.1 p.2.2

/-! ## What the head says -/

/-- the values of the field lines with this (lowercase) name, in order -/
def values (fs : List (Bytes × Bytes)) (name : Bytes) : List Bytes :=
  fs.filterMap fun f => if lower f.1 = name then some f.2 else none
/-- the bytes without the OWS at either end -/
def trimOws (s : Bytes) : Bytes := ((s.dropWhile isWs).reverse.dropWhile isWs).reverse
/-- the bytes between the commas -/
def splitComma : Bytes → List Bytes
  | [] => [[]]
  | c :: s =>
    let r := splitComma s
    if c = 0x2c then [] :: r else (c :: r.head!) :: r.tail
/-- the members of a list-based value, empty elements ignored (RFC 9110 §5.6.1.2) -/
def members (v : Bytes) : List Bytes := ((splitComma v).map trimOws).filter (· ≠ [])
/-- RFC 9110 §7.6.1: a connection option, case-insensitive -/
def hasOption (fs : List (Bytes × Bytes)) (opt : Bytes) : Bool :=
  (values fs (lit "connection")).any fun v => (members v).any (lower · == opt)
/-- RFC 9112 §9.3: the connection does not persist after the response -/
def closes (minor : Nat) (fs : List (Bytes × Bytes)) : Bool :=
  hasOption fs (lit "close") || (minor == 0 && !hasOption fs (lit "keep-alive"))
/-- RFC 9112 §6.3 (5)-(7), RFC 9110 §8.6: 0 without Content-Length; `none` when a value is not
1*DIGIT or two values differ. A list value such as "42, 42" is not 1*DIGIT, so it is `none`, where
§6.3 (5) reads it as 42: one of the departures listed at the top of this file. -/
def contentLength (fs : List (Bytes × Bytes)) : Option Nat :=
  match values fs (lit "content-length") with
  | [] => some 0
  | v :: vs =>
    if (v :: vs).all (fun w => !w.isEmpty && w.all isDigit && decimal w 0 == decimal v 0)
    then decimal v 0 else none

/-- limits: RFC 9110 §5.4 (head), RFC 9112 §3 (target), SPEC.md:83 (content) -/
def maxHead : Nat := 16384
def maxTarget : Nat := 8192
def maxBody : Nat := 16384

/-- What the API needs of a head, and RFC 9112's rules on it. -/
structure HeadOk (H : Head) (path : Bytes) (len : Nat) : Prop where
  /-- HTTP/1.x; a minor version above 1 is processed as 1.1 (RFC 9110 §6.2) -/
  version : H.major = 1
  target : TargetPath H.target path
  short : H.target.length ≤ maxTarget
  /-- RFC 9112 §3.2: one Host line with a valid value, or none in HTTP/1.0 -/
  host : match values H.fs (lit "host") with
    | [] => H.minor = 0
    | [v] => ∃ h, HostPort v h
    | _ => False
  /-- no transfer coding is decoded (a stated non-conformance with RFC 9112 §6.1) -/
  noCoding : values H.fs (lit "transfer-encoding") = []
  /-- at most one Authorization line: this server's choice. The field is a singleton (RFC 9110
  §11.6.2), which a sender must not repeat (§5.3). §5.3 also lets a recipient combine repeated
  lines into one value, comma-separated: read so, `Bearer x` and then `Bearer y` are the value
  `Bearer x, Bearer y`, a malformed token, which SPEC.md:65 answers 401. This server answers 400. -/
  oneAuth : (values H.fs (lit "authorization")).length ≤ 1
  length : contentLength H.fs = some len

/-- One request, as the API reads it. -/
structure Request where
  /-- the method the API routes on: GET for GET and HEAD -/
  method : Feed.Http.Method
  /-- HEAD: answered as GET without the content (RFC 9110 §9.3.2) -/
  head : Bool
  /-- the target URI's path -/
  path : Bytes
  /-- the Authorization field value (OWS removed) -/
  auth : Option Bytes
  /-- the content: exactly Content-Length bytes -/
  body : Bytes
  /-- the connection closes after the answer (RFC 9112 §9.3, §9.6) -/
  close : Bool

def methodOf (m : Bytes) : Feed.Http.Method :=
  if m = lit "GET" ∨ m = lit "HEAD" then .get else if m = lit "POST" then .post else .other

/-- The bytes of one request this server answers, meaning `q`. -/
def IsRequest (s : Bytes) (q : Request) : Prop :=
  ∃ h H path, s = h ++ q.body ∧ IsHead h H ∧ h.length ≤ maxHead + 4 ∧ HeadOk H path q.body.length ∧
    q.body.length ≤ maxBody ∧ q.method = methodOf H.method ∧
    q.head = Decidable.decide (H.method = lit "HEAD") ∧ q.path = path ∧
    q.auth = (values H.fs (lit "authorization")).head? ∧ q.close = closes H.minor H.fs

/-! ## Framing the input -/

/-- the number of leading empty lines -/
def lead : Bytes → Nat
  | a :: b :: s => if a = 0x0d ∧ b = 0x0a then lead s + 1 else 0
  | _ => 0
/-- the head's length: through the first CRLF CRLF after the leading empty lines -/
def headLen (s : Bytes) : Option Nat :=
  let t := s.drop (2 * lead s)
  ((List.range t.length).find? fun i => (t.drop i).take 4 == crlf ++ crlf).map (2 * lead s + · + 4)
/-- More than `maxTarget` bytes of request-target have arrived, within the first `maxHead + 4`
bytes of the input. Only those bytes count, because an unfinished head is answered 431 once they
have arrived; so 414 and 431 do not depend on how the input was split into reads. The Lean parser
and the C scan are to check the same bound. -/
def TargetTooLong (s : Bytes) : Prop :=
  ∃ m t rest, s.drop (2 * lead s) = m ++ [0x20] ++ t ++ rest ∧ IsToken m ∧ t.length = maxTarget + 1 ∧
    (∀ c ∈ t, c ≠ 0x20 ∧ c ≠ 0x0d ∧ c ≠ 0x0a) ∧ 2 * lead s + m.length + 1 + t.length ≤ maxHead + 4
def ValidHead (h : Bytes) (len : Nat) : Prop := ∃ H path, IsHead h H ∧ HeadOk H path len

/-- Malformed input and the status answered before closing: 414 (RFC 9112 §3), 431 (RFC 9110 §5.4,
RFC 6585 §5), 400 (RFC 9112 §2.2, §3.2, §5.1, §5.2, §6.3, and the choices listed above), 413
(RFC 9110 §15.5.14) -/
inductive Malformed : Bytes → Nat → Prop
  | uriTooLong {s : Bytes} : TargetTooLong s → Malformed s 414
  | headTooLarge {s : Bytes} : ¬ TargetTooLong s → (∀ n, headLen s = some n → maxHead + 4 < n) →
      maxHead + 4 ≤ s.length → Malformed s 431
  | invalid {s : Bytes} {n : Nat} : ¬ TargetTooLong s → headLen s = some n → n ≤ maxHead + 4 →
      (¬ ∃ len, ValidHead (s.take n) len) → Malformed s 400
  | tooLarge {s : Bytes} {n len : Nat} : headLen s = some n → n ≤ maxHead + 4 →
      ValidHead (s.take n) len → maxBody < len → Malformed s 413

/-- more bytes are needed: an unfinished head within the limits, or content not all there (a head
with `Expect: 100-continue` waits for its content like any other) -/
inductive Undecided : Bytes → Prop
  | head {s : Bytes} : ¬ TargetTooLong s → headLen s = none → s.length < maxHead + 4 → Undecided s
  | body {s : Bytes} {n len : Nat} : headLen s = some n → n ≤ maxHead + 4 → ValidHead (s.take n) len →
      len ≤ maxBody → s.length < n + len → Undecided s

inductive Frame where
  | incomplete
  | bad (status : Nat)
  | ok (q : Request) (len : Nat)
  deriving Inhabited

/-- the specification's reading of a connection's unread input -/
inductive Frames (s : Bytes) : Frame → Prop
  | ok {q : Request} {n : Nat} : n ≤ s.length → IsRequest (s.take n) q → Frames s (.ok q n)
  | bad {st : Nat} : Malformed s st → Frames s (.bad st)
  | wait : Undecided s → Frames s .incomplete

open Classical in
/-- the frame of `s` (`frames_total` and `frames_unique` show there is exactly one) -/
noncomputable def frame (s : Bytes) : Frame :=
  if h : ∃ f, Frames s f then Classical.choose h else .incomplete

/-- the input starts, after its leading empty lines, with the method HEAD and a space: the answer
to it carries no content, whether the rest is a request or not (RFC 9110 §9.3.2) -/
def headRequest (s : Bytes) : Bool := (s.drop (2 * lead s)).take 5 == lit "HEAD "

/-! ## Answers -/

/-- the bodies of the malformed-input answers (`rejectBody`, Server.lean:46-48) -/
def badBody : Nat → Bytes
  | 413 => errJson "request too large"
  | 414 => errJson "uri too long"
  | 431 => errJson "request header too large"
  | _ => errJson "bad request"

/-- the status line's code and reason phrase of a malformed-input answer: 414 has its own, and
`Spec.statusPhrase` (which answers 414 as 500) is unchanged -/
def rejectPhrase (st : Nat) : String := if st = 414 then "414 URI Too Long" else statusPhrase st

/-- the head of the answer to malformed input, which closes the connection -/
def rejectHead (st : Nat) : Bytes :=
  lit ("HTTP/1.1 " ++ rejectPhrase st ++ "\r\nContent-Type: application/json\r\nContent-Length: ") ++
    digits (badBody st).length ++ lit "\r\nConnection: close\r\n\r\n"

/-- The answer to malformed input; to a HEAD request (`headRequest`) the head only (RFC 9110
§9.3.2), with the Content-Length of the body it leaves out (§8.6). -/
def rejectResponse (head : Bool) (st : Nat) : Bytes :=
  if head then rejectHead st else rejectHead st ++ badBody st

/-- the head of `response`, for HEAD (RFC 9110 §9.3.2; §8.6: the Content-Length GET would send) -/
def responseHead (status : Nat) (body : Bytes) (close : Bool) : Bytes :=
  lit ("HTTP/1.1 " ++ statusPhrase status ++ "\r\nContent-Type: application/json\r\nContent-Length: ") ++
    digits body.length ++ lit (if close then "\r\nConnection: close\r\n\r\n" else "\r\n\r\n")

theorem response_eq_head (status : Nat) (body : Bytes) (close : Bool) :
    response status body close = responseHead status body close ++ body := by
  simp [response, responseHead, List.append_assoc]

/-- info: 'Feed.Spec.Http.response_eq_head' depends on axioms: [propext] -/
#guard_msgs in #print axioms response_eq_head

/-- Apart from 414, the answer to malformed input is the response with its body. -/
theorem rejectResponse_false {st : Nat} (h : st ≠ 414) :
    rejectResponse false st = response st (badBody st) true := by
  simp [rejectResponse, rejectHead, rejectPhrase, h, response, List.append_assoc]

/-- info: 'Feed.Spec.Http.rejectResponse_false' depends on axioms: [propext] -/
#guard_msgs in #print axioms rejectResponse_false

theorem rejectResponse_eq_head (st : Nat) : rejectResponse false st = rejectResponse true st ++ badBody st := rfl

/-- info: 'Feed.Spec.Http.rejectResponse_eq_head' depends on axioms: [propext] -/
#guard_msgs in #print axioms rejectResponse_eq_head

end Feed.Spec.Http
