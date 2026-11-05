# Lean 4: the handler the theorems are about is the one that runs

The request handler is Lean, compiled by the Lean compiler, and the theorems in `Feed/Proofs/` are
about its definitions. It is written once, generic in its storage operations: the build checks the
proofs on a model of the tables and compiles the same code against SQLite. Lean runs the control
flow of every batch and every request; C leaves under it do HTTP framing, routing, the JSON of
bodies and tokens, HMAC-SHA256 and base64url, and the bytes of the two read responses. Each leaf is
a Lean definition that `@[extern]` replaces with C in the binary, and the build tests the C against
the definition; the proofs use the definitions of all 15 leaves, and the end-to-end theorems
(below) take no leaf's result as given. The C runtime (SQLite, the storage operations, the leaves,
the io_uring transport) is trusted; the build tests the storage operations against the model and
each leaf against its definition.

| | |
|---|---|
| Language | Lean 4.37.0 nightly 2026-10-30 (handler and proofs), compiled to C by the Lean compiler; that C and the C runtime built by gcc `-O3 -march=native`, profile-guided |
| Framework | none |
| Database | SQLite 3.54.1 amalgamation in-process: reads of its B-tree pages through its pager, writes as prepared SQL |
| Transport | io_uring (Linux ≥ 6.1), one thread, HTTP/1.1 keep-alive, one multishot receive per connection (Linux ≥ 6.8; before 6.8 a poll of its direct descriptor) |
| **Nginx or direct** | **Direct**: serves `HOST:PORT` itself (`0.0.0.0:80`), no Nginx |
| Dependencies | Lean toolchain and SQLite, pinned by version and SHA-256 |

## What this entry contributes

This entry started from lean-derive-hargup #153, the first Lean entry (see Credits). What is new
here is that the handler that runs is compiled Lean, the theorems are about it and about the Lean
definitions of the C leaves it calls, and the build tests each leaf against its definition. The
end-to-end theorem `runBatch_correct` says that on any storage that meets a contract stated in
Lean, a batch's answers are `Spec.batch` of its input bytes, a specification written from SPEC.md,
schema.sql and the RFCs; it takes no statement still to prove.

* **Lean on the request path.** Compiled Lean runs `Feed.batch` (`runBatch`: each batch's read
  phase, write phase, commit and replies), `readLoop` (pipelining, HEAD, the rule that a write is
  its connection's first request in a batch, closing, the 400, 413, 414 and 431 answers), `decide`
  (dispatch: the token first, then the id or the body), `authenticate` and `Jwt.verify` (exactly
  two dots, the constant-time comparison `ctEq`, `alg`, `crit` and `cty`, `exp` and `nbf` through
  `numGt`, `aud`, `sub` through `positiveInt`, `username`), `postText` (the field's JSON kind,
  JavaScript's trim, 500 code points, a text led by U+0000), `feedLoop` (when the feed reads
  further), `postFound`, `perform` (the writes and their answers), `respond`/`respondErr` (the
  status line, headers and bodies of errors, writes and `/health`) and, with the idle policy on,
  `Feed.Idle.pick`. The transport calls `Feed.batch`, which is `runBatch` at `IO` by definition.
  The Lean is 1,934 lines (`Feed/` Bytes, Http, Json, Sha256, Jwt, Store, Handler and Server, and
  `Main.lean`), every function total (no `partial`). Part of it serves only as the definition of a
  C leaf: the server runs the C, and the self-test runs the Lean to check it. That part is the
  bodies of the 15 leaves (below) and the Lean only those bodies call, among them `renderPage`,
  `postFromPage`, `postJsonAfter`, `parseId`, `Http.scan`, `Http.finish` and `scanValue`.
* **Theorems about the code that runs.** The handler is generic in `Store m` (nine operations):
  the server runs `Store IO`, C over SQLite, and the proofs run `Store Model`, a state monad over
  the tables of `Feed/Spec.lean`, or any storage in a state monad that meets the contract of
  `Proofs/Store.lean`. 819 `theorem`s in `Feed/Proofs/` (14,767 lines) and the
  `LawfulBEq ByteArray` instance, checked by `lake build` in `build.sh`, cover both reads' complete
  HTTP responses byte for byte, the writes, routing, the token check, the post body, HTTP framing,
  one request (`decide_spec`), a batch (`runBatch_spec`: a serial execution for any choice of the
  batches that may write, so the transport groups commits without a new proof) and the idle policy
  (10 theorems). They tie the leaves' definitions and the handler's checks to specifications in
  `Feed/Spec/` written from SPEC.md, schema.sql and the RFCs: HTTP framing (RFC 9112, RFC 9110),
  the JSON the API reads (RFC 8259), base64url (RFC 4648), SHA-256 and HMAC-SHA256 (FIPS 180-4,
  RFC 2104), the token (SPEC.md, RFC 7515, RFC 7518, RFC 7519) and the post body (SPEC.md,
  schema.sql). The end-to-end theorems (`runBatch_correct`, `readLoop_correct`,
  `runBatch_correct_model`, `decide_correct`) put these together from a batch's input bytes to its
  answers, and `check-docs.sh` checks that they take no statement still to prove. The table below
  says what each states and what it takes as given.
* **C leaves with Lean definitions.** 15 C functions are `@[extern]` on Lean definitions whose
  bodies are their specifications, and the theorems use the definitions of all 15 (`check-docs.sh`
  checks every theorem again with each leaf made opaque). After linking, `build.sh` runs the
  self-test, which compares each leaf with its Lean definition on 20,000 random inputs and the
  storage operations with `Store Model` on a random SQLite file; any difference fails the build.
  The self-test's references are tied to the Lean definitions by 21 `example`s and 15 lemmas in
  `Feed/Selftest.lean`, so the C is compared with the definitions themselves.
* **The idle policy as a Lean definition.** `Feed.Idle.pick` chooses which of the connections the
  transport offers to close, and `Feed/Proofs/Idle.lean` proves 10 theorems about it; the
  transport calls it as compiled Lean. The policy is off by default: it runs only with
  `FEED_CONN_BUDGET` or `FEED_IDLE_MS` set, and `start.sh` sets neither. Closing idle connections
  has prior art (see Credits): c-iouring-moneebullah25 #228 and c-iouring-pavlyhalim #245 close
  keep-alives idle for 60 s and 90 s, #245's memory valve and c-iouring-public #158's memory floors,
  both off by default, close connections when memory runs low, and c-epoll-TheFirstIstari #64
  closes its oldest idle ones under file-descriptor pressure. The Lean definition and its theorems
  are this entry's.
* **Compared with the earlier Lean entries.** lean-derive-hargup #153 and lean-c-iouring-loafecho
  #239 prove read plans against a Lean model, the feed plan under a data invariant the server
  checks; their READMEs say their C is tested and unproved, and neither runs Lean while serving
  (#153 generates its route matcher, error responses and serializers from Lean). This entry runs
  Lean while serving, at the cost of trusting Lean's compiler and runtime, and its theorems also
  cover routing, the response bytes, HTTP framing, the JSON the API reads, the token check and the
  post body (through the leaves' definitions), the writes and the batch from its input bytes.

## What runs and what is proved

`Feed/Handler.lean` and `Feed/Server.lean` are generic in a storage monad (`Feed/Store.lean`):

```lean
class Store (m : Type → Type) where
  begin : m Bool
  feedPage : Nat → m Page   -- the first n posts in (created_at DESC, id DESC) order,
                            -- each with its author's name (if the user exists) and like count
  postPage : Nat → m Page   -- the post with this id, with its author and like count (or no row)
  health : m Bool           -- SELECT 1 succeeded
  endReads : m Unit
  postExists : Nat → m Nat
  insertLike : (uid pid : Nat) → m Nat
  insertPost : (uid : Nat) → (body : ByteArray) → m (ByteArray × Nat)
  commit : m Bool
```

* The server runs `Store IO`: each operation is a C function over SQLite (`runtime/db.c`).
* The proofs run `Store Model`: the same operations on the specification's tables, a state monad
  over lists of rows (`Feed/Model.lean`). Each C function is written to that one-line contract,
  `insertPost` for the bodies `postText` accepts: SQLite's `CHECK (length(body) BETWEEN 1 AND 500)`
  counts the characters before the first NUL, so it refuses a body that starts with U+0000, which
  `postText` answers 500 before any insert. `db.c` takes the time once per write phase, as the
  model gives every insert of a batch the same `clock`. A post whose body or `created_at` is stored
  as a BLOB, which TEXT affinity allows, is left out of the C's pages, and a user whose username is
  a BLOB reads as a missing author, where the model takes their bytes; the seed and the API store
  only TEXT.

A `Page` is one byte array of text and one array of numbers, eight per row; `Page.view` reads a
row back as the post object it renders (none if the author row is missing). A read makes one
storage call, which gets the posts, their authors and their like counts together from the C side,
except that `GET /feed` reads again, twice as far down the order, while fewer than 20 of the posts
read have an author and the page was full (`feedLoop`); a like makes two calls (`postExists`, then
`insertLike`). The Lean side decides when the feed reads further; the response bytes are written by
C leaves (`respondFeed`, `respondPost`) whose Lean definitions say which rows are rendered and how:
the rows with an author, in the page's order, at most 20.

`Feed/Spec.lean` is the part of SPEC.md about the data and the answers, as Lean: tables as lists,
`ORDER BY created_at DESC, id DESC LIMIT 20` as a sort, the join and the like count as list
functions, the routes, the results of the five endpoints, the JSON the API sends and the bytes of
a response. It does not cover how requests are framed, the JSON the API reads, or the rules for
tokens and post bodies; the error messages are stated in `Proofs/Decide.lean` (`bs_err_body`,
`expected`), and the 503 body in no theorem. The specification's functions on the right-hand sides
of the end-to-end theorems (below) unfold to definitions of `Feed/Spec.lean` and `Feed/Spec/`, and
of the code only to the type `Feed.Http.Method` and to `Feed.escape`, `escByte` and `hexDigit`
(`Feed/Bytes.lean`). `viewJson` escapes strings with that `escape`, which is also the Lean body of
the `appendEsc` leaf, so among the theorems only `Escape.decode_escape` (below) checks it
independently; on UTF-8 strings it writes what `JSON.stringify` writes, which no theorem states.

`Feed/Spec/` specifies what `Feed/Spec.lean` leaves out, from SPEC.md, schema.sql and the RFCs:
how requests are framed (`Http.lean`, `Uri.lean`), the JSON the API reads (`Json.lean`,
`Utf8.lean`), base64url (`Base64.lean`), SHA-256 and HMAC (`Sha256.lean`, with the test vectors
in `Sha256Vectors.lean`), the token (`Auth.lean`), the post body (`Body.lean`), SPEC.md's table of
errors (`Errors.lean`) and what a batch answers from the input bytes (`Server.lean`). Theorems
connect them to the code: `Sha256.hash_spec` and `Hmac.mac_spec` (below) say that
`Feed/Sha256.lean` computes `Spec/Sha256.lean`'s SHA-256 and HMAC, `Jwt.b64Encode_spec` and
`Jwt.b64Decode_spec` that `Feed/Jwt.lean`'s codec computes `Spec/Base64.lean`'s base64url,
`Json.decodeString_spec`, `Json.numGt_spec` and the scanners' theorems that `Feed/Json.lean` reads
`Spec/Json.lean`'s strings and numbers, with `Spec/Utf8.lean`'s UTF-8, `Json.parseTop_spec` that
it reads `Spec/Json.lean`'s texts and objects, `Http.parse_view` that `Http.parse` computes
`Spec/Http.lean`'s frame of a connection's input (with `Http.scan_spec` for its byte scan, and
`Http.hostOk_iff` and `Http.target_spec` for its Host and request-target deciders, which decide
`Spec/Uri.lean`'s grammar), `Jwt.verify_spec` and `authenticate_spec` that the token check and
`authenticate` decide what `Spec/Auth.lean` decides, `postText_spec` that `postText` takes a post
body as `Spec/Body.lean` does, and `readLoop_spec` that `readLoop` answers malformed input and HEAD
requests with `Spec/Http.lean`'s `rejectResponse` and `responseHead`. `route_toRequest` reads a
parsed request's method and path through `Spec/Http.lean`'s `Request`, and the other theorems
about them (`padZeros_spec`, `K_eq_cube_roots`, `b64urlDecode_eq_some_iff`, `encode_injective`,
`scalars_isScalar`, `IsObjectText.unique`, `IsText.utf8`, `subjectId_eq_some_iff`, three on
`Spec/Http.lean`'s responses, `frame_append` and more) are about the specification alone. No
statement is left to prove in the module docs of `Feed/Proofs/`. `runBatch_correct`
(`Proofs/EndToEnd.lean`: the batch's answers are `Spec.batch` of the input bytes) takes no
hypothesis about what the parser, the token check or the body check return: it uses
`Http.parse_view`, `Http.parse_sound`, `authenticate_spec` and `postText_spec`, and so do
`readLoop_correct`, `runBatch_correct_model` and `decide_correct` (one request). What `readLoop`
does with the parser's results is proved too (`readLoop_bad`, `readLoop_reply`). The end-to-end
theorems are stated for any storage in a state monad that meets the contract of
`Proofs/Store.lean`. The server's storage runs in `IO`, which no Lean statement relates to the
tables, so the step from them to `Feed.batch` (`runBatch` at `IO`) will stay an assumption.

The theorems (all checked by `lake build` in `build.sh`; no `sorry`; axioms `propext`,
`Classical.choice`, `Quot.sound`):

| Theorem | File | Statement |
|---|---|---|
| `feedResponse_correct` | `Proofs/Plan.lean` | `GET /feed`'s plan (a page of the newest posts with their authors and like counts, reading further down the order while posts lack an author) appends the response whose body is `feedJson db.feed`, byte for byte, and reads only |
| `postResponse_correct` | `Proofs/Plan.lean` | `GET /posts/:id` appends the response with `postJson v` exactly when `db.getPost id = some v`, else "post not found" |
| `feedFromPage_congr`, `respondFeed_congr`, `postFromPage_congr`, `respondPost_congr` | `Proofs/Plan.lean` | the response built from a page, and whether the feed reads further, depend on the page only through `Page.Same` (the rows as post objects), which is what the self-test checks of the C pages |
| `perform_like`, `perform_create` | `Proofs/Write.lean` | a like / a new post answers (status, body) and changes the tables as `DB.like` / `DB.create` |
| `Escape.decode_escape` | `Proofs/Escape.lean` | the JSON string escape is reversible: `Escape.decode` (in the same file: an RFC 8259 string body over bytes, with the escapes `escape` writes) gives back `s` from `escape s`; it does not check UTF-8 |
| `Jwt.verify_ok_sound` | `Proofs/Jwt.lean` | an accepted token's third part is `b64Encode` of `Hmac.mac` of its first two under the key passed to `verify`, its decoded header parses with an `alg` that decodes to `HS256`, and its `exp` is a number that `numGt` puts after now. It is stated in terms of the implementation's `b64Encode`, `b64Decode`, `Hmac.mac`, `parseTop`, `decodeString` and `numGt`, each of which is tied to its standard (`Jwt.b64Encode_spec`, `Jwt.b64Decode_spec`, `Hmac.mac_spec`, `Json.parseTop_spec`, `Json.decodeString_spec`, `Json.numGt_spec`, next rows), and it is soundness only: a check that rejects every token meets it. `Jwt.verify_spec` (`Proofs/Auth.lean`, below) states the whole check |
| `Sha256.hash_spec`, `Hmac.mac_spec`, `Hmac.keyOf_spec` | `Proofs/Sha256.lean` | `Sha256.hash` of every byte array is FIPS 180-4's SHA-256 of its bytes, and under the key schedule `Hmac.Key.of` builds from any key, `Hmac.mac` of any range is RFC 2104's HMAC-SHA256 of the key and the range's bytes (clamped as `slice` clamps a range, so one given backwards is empty), both as `Spec/Sha256.lean` writes the standards. No proof ties that transcription to the standards: `Spec/Sha256Vectors.lean` runs FIPS 180-4's examples and RFC 4231's seven cases on it with `#guard`, and proves its `K` and `H0` from the primes |
| `Spec.b64urlDecode_eq_some_iff`, `Jwt.b64Encode_spec`, `Jwt.b64Decode_spec`, `Jwt.ctEq_iff`, `Jwt.dots_spec` | `Proofs/Base64.lean` | a text decodes to `d` exactly when it is `d`'s base64url as `Spec/Base64.lean` writes RFC 4648 §5 (no '=', zero bits after the last whole byte), and `Jwt.b64Encode` and `Jwt.b64Decode` compute that encoding and that decoding, the decoder on every range of its input; `ctEq` is byte equality (its timing is not proved, below); `verify`'s three `findByte` calls cut a token where `List.splitOn` cuts it at its dots (RFC 7515 §7.1) |
| `Json.decodeString_spec`, `Json.numGt_spec`, `Json.scanString_sound`, `Json.scanString_complete`, `Json.scanNumber_sound`, `Json.scanNumber_complete`, `Json.skipWs_spec` | `Proofs/JsonToken.lean` | as `Spec/Json.lean` writes RFC 8259's strings and numbers: on the bytes of a JSON string, `decodeString` gives the UTF-8 of its characters, a surrogate pair as one scalar value and a lone surrogate as U+FFFD; on those of a JSON number, `numGt` says exactly whether its value is greater than `n`. `scanString` accepts exactly the strings, whose unescaped characters are well-formed UTF-8 (RFC 3629 §4, `utf8Len_spec` in `Proofs/Utf8.lean`), `scanNumber` exactly the numbers before a byte that cannot continue one, and `skipWs` stops at the end of the whitespace. `Json.parseTop_spec` (next row) carries these into `parseTop`, and `Jwt.verify_spec` and `postText_spec` (the two rows after it) into the token check and `postText` |
| `Json.parseTop_spec`, `Json.scanValue_sound`, `Json.scanValue_complete`, `Json.keyEq_iff`, `Json.fields_record`, `Spec.Json.IsObjectText.unique`, `Spec.Json.IsText.utf8` | `Proofs/JsonValue.lean` | as `Spec/Json.lean` writes RFC 8259's texts: `parseTop` says malformed exactly when the bytes are no JSON text, and for a text whose value is an object it reports, for each wanted key (distinct, ASCII), the span of the value of the last member with that name, names compared as code units, and whether that value is a string or a number (`Json.FieldIs`); `notObject` for a text whose value is not an object. The scanners accept only the texts of values, and, given as much fuel as the text is long (which `parseTop` gives), every value before a byte that cannot continue it. An object text has one list of members (so the one `Spec/Auth.lean` and `Spec/Body.lean` pick with `Classical.choose` is it), and a JSON text is UTF-8 (§8.1). `Jwt.verify_spec` and `postText_spec` (the next two rows) carry these into the token check and `postText` |
| `Jwt.verify_spec`, `authenticate_spec`, `Spec.Auth.checkToken_ok`, `Spec.Auth.subjectId_eq_some_iff` | `Proofs/Auth.lean` | under JWT_SECRET's key schedule, `Jwt.verify` of any range of the input is `Spec/Auth.lean`'s `checkToken` of its bytes with HMAC-SHA256 under JWT_SECRET's bytes (`Hmac.macOf`, from `Hmac.mac_spec`): three base64url parts (RFC 7515 §7.1), a header that is a JSON object whose `alg` is the string `HS256`, with no `crit` and no `cty` that names a nested JWT, a third part that decodes to the MAC of the first two, and a payload that is an object with an `exp` after now, no `nbf` that is not a number or is after now, and no `aud`; then "invalid token payload" unless `sub` is a string `subjectId` accepts and `username` a string. `authenticate` answers, as SPEC.md's rows, what `Spec.Auth.authenticate` answers on the request's Authorization value. The code compares the signature before it decodes the header and the payload, the specification after; every failure before `sub` is "invalid or expired token", so the order changes no answer. `subjectId` accepts exactly `String(n)` of an integer `n` with 0 < n < 10¹⁸, and an accepted token is three base64url parts, the third the encoding of the MAC of the first two and the dot between them |
| `postText_spec`, `trimRange_spec`, `Spec.Body.schemaOk_iff` | `Proofs/Body.lean` | `postText` takes a `POST /posts` body as `Spec/Body.lean` writes SPEC.md:67-69 and schema.sql's CHECK (`Spec.Body.accept`), its errors read as SPEC.md's rows: "malformed JSON body" exactly when the bytes are no JSON text; "body is required" when the text's value is not an object, its last `body` member is missing or not a string, or the string's characters are all whitespace; "body must be at most 500 characters" for more than 500 characters once trimmed; 500 for a trimmed text that starts with U+0000, which the CHECK refuses; otherwise the UTF-8 of the trimmed characters, the text that is stored. Characters are scalar values and whitespace is what ECMAScript's `String.prototype.trim` removes: on the UTF-8 of scalar values `trimRange` gives the range of the trimmed ones and `codePoints` counts them, and on the UTF-8 of 1 to 500 scalar values the CHECK holds exactly when the first is not U+0000 |
| `Http.scan_spec`, `Spec.Http.isHead_unique`, `Spec.Http.fieldLine_iff`, `Spec.Http.headLen_head`, `Spec.Http.not_targetTooLong`, `Http.fields_sound`, `Http.fields_complete`, `Http.field_sums` | `Proofs/HttpLines.lean` | the byte scan of `Http.parse` (`Http.scan`) answers 414 exactly when more than 8,192 bytes of request-target have arrived within the first 16,388 bytes of the input (`Spec.Http.TargetTooLong`); 431, or a wait, when no head ends within them; 400 when the bytes up to the first CR LF CR LF after the empty lines are not a head of HTTP/1.x; and otherwise reads that head as `Spec/Http.lean`'s `IsHead`: the request-line's method, target and version, and a record of what the field lines say (how many Host and Authorization lines and the last one's value, whether there is a Transfer-Encoding line, the Connection options `close` and `keep-alive`, the Content-Length values as numbers of any length; `Http.eqCI_iff`, `Http.hasToken_eq` and `Http.lengthOf_eq` read names, options and lengths as RFC 9110 §5.1, §7.6.1 and §8.6 say). A head has its parts in one way only, and so has a field line (a name, ":", a value without OWS); a head's length is where its first CR LF CR LF ends, and one with a target of at most 8,192 bytes is not `TargetTooLong`. `Http.parse_view` (the row after next) carries these into `Http.parse` |
| `Http.hostOk_iff`, `Http.target_spec`, `Spec.Http.targetPath_unique` | `Proofs/Uri.lean` | the deciders that `Http.parse` calls on a Host value and on a request-target decide `Spec/Uri.lean`'s grammar: `hostOk` accepts exactly RFC 9110 §7.2's `uri-host [ ":" port ]` (RFC 3986's IP-literal, IPv6 in each of its forms or IPvFuture, the IPv4address and the reg-name), and `target` gives a path exactly for the request-targets of RFC 9112 §3.2 that `Spec.Http.TargetPath` reads, and that path is the target's (an origin-form's, an http or https absolute-form's, the empty path of the other forms), which is unique. Examples by evaluation: `Http.hostOk_vectors`, `Http.target_vectors`. `Http.parse_view` (next row) carries these into `Http.parse` |
| `Http.parse_view`, `Http.parse_sound`, `Http.parse_complete`, `Http.parse_bad_iff`, `Spec.Http.frames_unique`, `Spec.Http.frames_total`, `Spec.Http.isRequest_unique`, `Spec.Http.frame_append`, `Spec.Http.waiting_bounded` | `Proofs/Http.lean` | `Http.parse` computes `Spec/Http.lean`'s frame of a connection's input from any position in it: the request at the start of the input and its length, malformed input and the status answered before the connection closes (414, 431, 400 or 413), or a wait for more bytes. A request it returns is the specification's request of the bytes from the position to its `next`, where its content ends, and it returns every request that starts there. Of the specification alone: every input has exactly one frame, and two requests at the start of the same bytes are the same request; a frame other than a wait is also the frame of every longer input, so the answer does not depend on how the input was split into reads; and the server waits on fewer than 32,772 bytes. Examples by evaluation: `Http.frame_vectors`, 26 of the inputs on which version 011a111 departed from the RFCs; the other two, a head of 16,388 bytes read in two parts that split its CR LF CR LF and a target of 17,000 bytes, are left to `Spec.Http.frame_append` and `Spec.Http.TargetTooLong`. The theorems are about the Lean definition of `Http.parse`; the binary runs its C version (below) |
| `route_spec` | `Proofs/Route.lean` | routing on byte ranges of the input equals `Spec.route` on the path's bytes (5 endpoints, `:id` a positive integer in one segment) |
| `decide_spec` | `Proofs/Decide.lean` | one request, for any `Req` (parsed or not): the response `expected` gives for `Spec.route` of its method and path bytes, or the write it asks for; the token first, then the id or the body; the snapshot unchanged. Whether the token and the post body are accepted, and the user and the text, are what the handler's own `authenticate` and `postText` return: the theorem takes them as given (`authenticate_spec` and `postText_spec` say what they return, and `decide_correct` uses the two). `/health` is answered as after a `SELECT 1` that succeeded |
| `runBatch_spec` | `Proofs/Batch.lean` | a batch on the model is a serial execution: each connection gets the answers, from the batch's snapshot, to the requests `Http.parse` finds in its input, in order and at most 64 (a HEAD request gets the head of GET's answer; a malformed one gets its error, without content if the input starts with `HEAD `, and ends the input), until a write, a close or an incomplete request, then the answer to its write when the write was its first request and the batch may write; the writes run in connection order, each on the database the earlier ones left, and the database ends as the snapshot with them applied. It states the response bytes and the final database (the input used and the flags the transport acts on are outside it) and takes `Http.parse`, `authenticate` and `postText` as given (`runBatch_correct`, above, takes none of them as given) |
| `pickList_closed`, `count_pickList`, `pickList_longest`, `pickList_expired` | `Proofs/Idle.lean` | which idle connections `Feed.Idle.pick` closes (the transport calls it, below): never a busy one (input not yet answered, an answer being sent); without a timeout none at or below the budget, and the excess over it or every spare one if there are fewer; the longest idle first; with a timeout, every one that is not busy and idle past it |

The theorems hold for every database with fewer than 20·2⁶³ posts: no assumption about ids (the
plans do not rely on rowids being distinct or positive) or about how ids and timestamps relate. In
the model every insert of a batch gets the same `created_at` (`DB.clock`), and `begin`, `commit`
and `SELECT 1` always succeed, so no theorem covers the 500 answers to storage errors or the 503 of
`/health`.

The idle theorems are about the Lean definition, for whatever busy flags and order of candidates
it is given. In the transport the flags come from the C `conn_busy` and the order from the C merge
of the rings' lists, and neither is proved; the transport offers at most 2·`FEED_IDLE_PER_ITER` +
64 candidates per iteration (576 by default), and the theorems are about those.

`runBatch_spec` is about `runBatch` on the model. The transport calls `Feed.batch`, which is
`runBatch` at `IO`: the same definitions, with the C storage operations in place of the model's and
the C leaves in place of their Lean definitions. No theorem relates the two; that they answer alike
is the argument of the trust base below. Within a batch, `runBatch_spec` is what makes group commit
and shared snapshots safe here: a connection's requests are answered in order, a write in a batch
is the first request of its connection in that batch, and nothing after a write is answered in the
same batch. That the order holds across batches, and that no answer leaves before the commit, rest
on the transport (below). `runBatch_spec` holds whether or not the batch may write (`writesOk`),
which is what lets the transport put writes into fewer batches than reads (Design) without a new
proof.

### The trust base

Not proved, and how it is checked instead where it is:

* **The C storage operations** (`runtime/db.c`): each implements the meaning of its `Store Model`
  operation (for rows whose text is stored as TEXT, and `insertPost` for the bodies `postText`
  accepts, above). `build.sh` runs `bin/server --selftest`, which writes a random database (ties in
  `created_at`, gaps in ids, posts whose author row is missing, a `users` table of three B-tree
  levels), runs `feedPage`, `postPage`, `postExists`, `insertLike` and `insertPost` (on random ids
  and bodies, and pages of eleven sizes) before and after random writes, and compares each result
  with the model's: a page by `Page.Same` (as many rows, each reading back as the same post object;
  `respondFeed_congr` and `respondPost_congr` prove that the responses built from such pages, and
  whether the feed reads further, are the same, so the C side may lay the text out in its own
  order). The model gets one clock per write phase, the time of its first post, which must differ
  from the last phase's, and the phase waits 2 ms after that post, so a time taken per insert would
  show; some bodies are at the edges of the `CHECK`, and bodies that start with U+0000 must add no
  row; the database's text is stored as TEXT. It does not run `health`. One batch of requests
  (such bodies, new posts, a like, the feed, a post) goes through `runBatch` at `IO` and on the
  model, with the same replies byte for byte. It also compares the reads over the batch's pages
  below with SQLite's cursors and record decoder (the rowid searches on every key of `users` and
  `posts`, the in-order passes over both indexes, the feed's ids, the like counts, runs of posts
  rows, the posts records' columns), also in a rolled-back copy whose trees have three levels,
  rolls back a transaction that grew the file, and runs SQLite's integrity check. Any difference
  fails the build. What these checks test is written down as a contract in `Proofs/Store.lean`:
  each operation answers as the model's does up to `Page.Same`, and `insertPost` does so for a body
  that is a post's text as `Spec.Body.accept` returns it (the UTF-8 of 1 to 500 characters, no
  whitespace at either end, not led by U+0000), the only bodies the handler inserts. The contract
  needs that premise, since SQLite adds no row for a body the `CHECK` refuses, such as one led by
  U+0000, where the model adds one; and no narrower premise covers what the handler inserts, so it
  asks nothing of db.c about a body it is never given. The self-test's inserts go beyond it (random
  bodies, which may have a space or a tab at an end, and refused ones). `runBatch_sim`
  (`Proofs/EndToEnd.lean`) proves that on any storage whose operations are state transformers
  meeting the contract, `runBatch` returns what it returns on the model, given that `postText`
  accepts no other text, which follows from `postText_spec` (`Proofs/Body.lean`). That db.c, run at
  `IO`, is such a storage is not proved: Lean has no model of `IO`'s effects.
* **The C leaves** (`runtime/leaves.c`): 15 Lean definitions carry `@[extern]`, which makes the
  binary call a C version of each. They are the byte operations of `Feed/Bytes.lean` (`appendEsc`,
  `appendNat`, `appendAll`, `findByte`); HTTP framing (`Http.parse`, `Feed/Http.lean`, whose C
  follows `scan` and `finish` function by function); the JSON of bodies and tokens (`Json.parseTop`,
  `Json.decodeString`); HMAC-SHA256 (`Hmac.mac`, `Feed/Sha256.lean`) and base64url (`Jwt.b64Encode`,
  `Jwt.b64Decode`); and in `Feed/Handler.lean`, routing (`route`), the feed's body (`feedFromPage`,
  `Page.authored`) and the responses of the feed and of a post, written in place after their heads
  (`respondFeed`, `respondPost`). The theorems of `Feed/Proofs/` use the Lean definitions of all of
  them; `check-docs.sh` counts them by checking every theorem again with each leaf made opaque.
  `feedFromPage` runs only inside the C `respondFeed`, for a page with a byte to escape or an id or
  like count of 2⁶³ or more. The self-test compares every leaf with its Lean definition (restated
  without `@[extern]` and tied to it by `rfl` or a proof) on 20,000 random inputs. The C JSON
  scanners carry no fuel, since the Lean scanners' fuel never runs out (a value of n bytes is
  scanned with any fuel of n or more, `Json.scanValue_complete`), and keep nesting on an explicit
  stack; several leaves read past an input's end in loads of 32 bytes that stay inside its
  allocation, which the self-test's inputs with spare capacity exercise; the HMAC uses the SHA
  extensions when the build CPU has them, so the self-test checks whichever path was compiled.
  Mistakes planted in the C make the self-test fail: a flipped bit of the MAC, a wrong padding
  length in SHA-256, a wrong base64url character, a misspelled key of the post object, an off-by-one
  in the rowid search or in the like count, and each of 39 in HTTP framing, among them a CR LF CR LF
  seen across the end of the first 16,388 bytes, 414 a byte early, DEL taken in a field value or `"`
  in a token, and a leading zero allowed in an IPv4 address (two more planted there change no
  answer). `build.sh` checks that the C which Lean emits for the modules of `bin/server`, the
  self-test's excepted, calls no C function besides Lean's runtime and library, the leaves, the
  storage operations and `Main`'s entry points (the list is in `build.sh`).
* **SHA-256 and HMAC** (`Feed/Sha256.lean`): the Lean definitions are proved equal to FIPS 180-4 and
  RFC 2104 as `Feed/Spec/Sha256.lean` writes them (`Sha256.hash_spec`, `Hmac.mac_spec`). That this
  transcription is the standards is checked, not proved: `Feed/Spec/Sha256Vectors.lean` runs FIPS
  180-4's examples and RFC 4231's seven cases on it with `#guard`. The binary runs the C `Hmac.mac`,
  which the self-test compares with the Lean definition on random keys and ranges, and runs, on keys
  from the Lean `Hmac.Key.of`, through RFC 4231's seven cases, on ranges inside an array, past its
  end and given backwards.
* **What the theorems take as given**: for the end-to-end theorems, nothing that the handler's Lean
  functions return. They use `Http.parse_view` and `Http.parse_sound` for HTTP framing (below);
  `authenticate_spec` for the token, which carries `Jwt.verify_spec` (from `Jwt.b64Encode_spec`,
  `Jwt.b64Decode_spec`, `Hmac.keyOf_spec`, `Hmac.mac_spec`, `parseTop_spec`, `decodeString_spec`,
  `numGt_spec` and `Jwt.positiveInt_spec`) into `authenticate`; and `postText_spec` for the post
  body, which carries `parseTop_spec` and `decodeString_spec` into `postText`, with
  `trimRange_spec` for its trimming and its count of characters. The theorems proved before those
  are stated in terms of the functions as they are: `decide_spec` holds for any `Req`, parsed or
  not, and takes `authenticate` and `postText` as given, `runBatch_spec` uses `Http.parse` as it
  is, and `verify_ok_sound` is stated in terms of the JSON, base64url and HMAC-SHA256 functions.
  That `ctEq` compares the signature in constant time (RFC 7518 §3.2) is not proved: it is compiled
  Lean, and its timing is up to the Lean compiler and gcc.
* **HTTP**: the Lean definition of `Http.parse` is proved to compute `Feed/Spec/Http.lean`'s frames
  (RFC 9112 and RFC 9110; `Http.parse_view`, through `Http.scan_spec` for the byte scan and
  `Http.hostOk_iff` and `Http.target_spec` for the deciders it calls on the Host value and the
  request-target, against `Feed/Spec/Uri.lean`). The binary runs its C version, which the self-test
  compares with the Lean definition: with each of the 256 byte values in each of 27 places of a
  request (a method, a path, a field name and value, the forms of a Host value, a scheme, userinfo
  and more), and on random request-like inputs, 20,000 at positions inside, at and past the end and
  with room after the input, and 20,000 more on every prefix (of an input over 2,048 bytes, one in
  fifty, the prefixes around the limits and every 61st). The self-test also checks it against the
  specification's frames of 162 inputs (examples of the rules it follows, each alternative of the
  Host and request-target grammar among them, and of each choice below, at the start of an input and
  after other bytes); mistakes planted in the parser make it fail, such as accepting an IPv6
  address's octet with a leading zero, a port with a letter or an empty field name. The random
  inputs compare the C with the Lean definition, which computes the specification's frames, and
  check that a prefix of an input reads as a wait or as the whole input does and that the input
  reads the same after other bytes. HTTP/1.1 needs one valid `Host`; field names are tokens (no
  whitespace before the `:`, no obs-fold), every CR is followed by LF and there is no other LF,
  field values hold no control character but HTAB and no DEL; `Content-Length` may have any number
  of digits; an `http` or `https` absolute-form target routes on its path; a HEAD request is
  answered as GET without the content, and so is malformed input that starts with `HEAD `; empty
  lines before a request are skipped; HTTP/1.x with x ≥ 1 is HTTP/1.1. A request-target over 8,192
  bytes gets 414 (as soon as they have arrived, within the first 16,388 bytes), a head over 16,388
  bytes 431 and content over 16,384 bytes 413 (SPEC.md puts bodies over 16 KB out of scope). Where
  the server departs from the RFCs, or chooses where they leave room: any `Transfer-Encoding`,
  chunked included, is answered 400 and the connection closed (RFC 9112 §6.1 asks a server to read
  chunked); no response carries a `Date` (RFC 9110 §6.6.1); `Expect: 100-continue` gets no
  `100 Continue` (§10.1.1), the request waits for its content like any other; a method other than
  `GET`, `HEAD` and `POST` gets 404 on every path (§9.1 suggests 501); a request with more than one
  `Authorization` line gets 400; a major version other than 1 gets 400 (§6.2 allows 505); a
  `Content-Length` value that is a list gets 400, also when it repeats one number (`5, 5`), where
  RFC 9112 §6.3 processes the message with that number (RFC 9110 §8.6 lets a recipient reject it
  instead), and repeated lines of one number are read as that number; the path is matched as sent,
  and an asterisk-form or authority-form target, or an absolute-form one of another scheme, names
  nothing here (404); and the answer to an HTTP/1.0 request with `Connection: keep-alive` leaves the
  connection open without saying so: HTTP/1.0's keep-alive (RFC 2068 §19.7.1, which RFC 9112
  Appendix C.2.2 cites) has the server answer with the `keep-alive` option. `Feed/Spec/Http.lean`'s
  module doc lists these departures.
* **Stored text is UTF-8**: `escape` copies every byte but `"`, `\` and the controls, so a response
  is a JSON text (RFC 8259 §8.1) only if the bodies, timestamps and usernames in it are UTF-8. A
  new post's body is: by `postText_spec` it is the UTF-8 of scalar values. So is a token's
  username: `parseTop` accepts only JSON texts (`parseTop_spec`), which are UTF-8 (`IsText.utf8`),
  so a string that is not UTF-8 is refused (400 for a body, 401 for a token), and
  `Json.decodeString` writes U+FFFD for a lone surrogate escape; the seed's rows are taken as they
  are.
* **The transport** (`runtime/uring.c`): moves bytes between sockets and `Feed.batch` and does not
  parse HTTP. What a client receives also depends on what it does around the batch. It sends a
  batch's replies only after `Feed.batch` returns, and `runBatch` returns after the commit. It keeps
  the input a batch did not use and puts it before the connection's next input; input left behind
  a write or after 64 requests comes back only in a batch that may write, and input that did not
  fit in a capped batch (Overload, below) in a later one. It closes, without an answer, a
  connection whose unanswered input exceeds 64 KiB (`MAX_IN`). A request waits on fewer than
  32,772 bytes (`Spec.Http.waiting_bounded`: a head of at most 16,388 and content of at most 16,384
  bytes, `Http.maxBody`; more content is answered 413 once the head is in), so only a client more
  than 64 KiB ahead of the answers is closed this way: one that sends a request with more than 64
  KiB of content in one burst can be closed before the batch that would answer it 413. After the
  peer's FIN it answers the complete requests it has, drops an unfinished one and closes; a failed
  send closes the connection; a connection closed while its input waited for the batch gets no
  reply. That every complete request is answered in the end rests on it too: held input waits for a
  batch that may write, which comes 10 ms after the last unless writes are paused (at most 300 ms,
  `runtime/db.c`). It chooses the idle connections to close by calling `Feed.Idle.pick`, compiled
  Lean. The WAL shim (`runtime/walvfs.c`) only merges the write calls of one commit; the page cache
  wrapper (`runtime/db.c`) only skips a scan that would find nothing.
* SQLite itself, Lean's compiler, runtime and kernel, gcc, Linux.

## Design

The numbers in this section come from A/B runs made while each change was developed, on the build
of that time; each says where it was taken (the setups are under Measurements).

**Batches.** Each event-loop iteration hands the new input of every connection to Lean in one call
(`Feed.batch`). The batch is one SQLite transaction: all reads use one snapshot, through B-tree
cursors opened once per batch and the batch's pages (Reads, below); the writes follow in connection
order as prepared statements; then one commit. Answers are sent after the commit, so a 201 is always
committed (WAL, `synchronous=NORMAL`: a commit survives a crash of the process, and a power loss or
a crash of the machine can roll back the most recent ones). While busy, after an iteration that
finished early the loop waits until ring 0 has 64 completions or 2 ms have passed since that
iteration began (with `FEED_SPIN_US` it spins meanwhile: The spin, below), so a batch collects
everything that arrived meanwhile (many requests then share one iteration, one transaction, one Lean
call and one burst of sends); under saturation iterations run back to back.

**Writes in fewer batches.** A batch may write at most every 10 ms (`writesOk` is false in the
batches between); a write waits for that batch, reads do not. A commit then carries the writes of
several periods, and the pages they share (the end of `likes`, the start of the feed index, the
recent part of `likes_post_id_idx`) go to the log once per commit instead of once per period. The
window and the checkpoints every 500 frames (Writes, below) are what PR #271's version (30d259c)
used when the box held it at 290,000 users. On the cloud VM at 350,000 users a 50 ms window with
checkpoints every 2,000 frames used 9 % less CPU in the same hold, and disk writes fell from about
2,900 to 2,100 a second (a 10 ms window wrote about 7,400 log frames a second, 30 MB/s); fe89683
and 307205a used those and held 280,000 on the box, where the likes and new posts were the slow
part at the edge. A write waits up to 10 ms for its batch while writes are not paused.

**Overload.** When more input arrives than an iteration can serve in about 6 ms, the batch is
capped: the input that arrived since the last iteration goes first and connections left over
from earlier iterations (a backlog, oldest first) fill the remaining room. The cap follows a
running estimate of the time per connection, so the first batch after a burst is capped too.
New requests are then still answered within an iteration or two, before the kernel's
delayed-ACK timer (40 ms) adds a packet to each of them: a server whose responses take longer
sends two packets per request instead of one. Without a backlog, batches stay below the cap.

**No caching across requests.** Every request reads its rows from SQLite while it is served (the
feed reads the index, the rows, each author and the like counts); every token's signature is
computed.

**Reads.** Over the batch's pages: a page that a read fetches stays referenced until the batch's
reads end, as an open cursor's pages do, so a later read of the batch finds it without the pager;
every read still searches the pages for its own rows. The feed reads the first entries of
`posts_created_at_id_idx` in order, a loop over each page's cells. When their ids are consecutive
(new posts get increasing ids), one descent of `posts` finds the first row and each next row is
the cell before the previous one's, its rowid checked (a leaf boundary or a gap: another descent);
ids that lie close together get one descent per leaf they fall in, spread-out ones the grouped
search (Credits), and the rows of a page of more than 64 posts are read through SQLite's cursor.
The like counts come from one range scan of `likes_post_id_idx` when the ids lie close together,
and each author from a descent of `users` of its own: on an interior page the search starts where
a line through the page's first and last keys puts the key (the line is kept for the next key of
the read that meets the page), and the leaf is entered at the cell where the key would be if its
rowids were dense from the bound the parent's cells give (in `users` they are). Records are read
where their one-byte header varints put the columns. Pages come through SQLite's pager, page cache
and WAL; only the bytecode engine is skipped.

**Writes.** `INSERT OR IGNORE` with `created_at` bound in the schema default's format: for these
values the only constraint that can fail is the like's primary key, which it ignores as
`ON CONFLICT DO NOTHING` would, so no statement can abort halfway and SQLite keeps no statement
journal. A body that starts with U+0000 once trimmed is answered 500 before it is written
(SQLite's `length` stops at the first NUL, so the schema's CHECK would refuse it). The model gives
each write phase one clock reading, so the time is taken once per write phase, at its first
insert: the posts of one batch share their `created_at`, and the feed orders them by id. A new
post's id comes from `sqlite3_last_insert_rowid` instead of `RETURNING`. Checkpoints run on a
second thread with its own connection every 500 frames (passive, so the request thread never
waits on an fsync). SQLite restarts the WAL only when a writer finds it fully checkpointed, which
never happens under constant writes; past 4,096 frames, writes pause (reads go on) until a
checkpoint has copied what is left, at most 300 ms (a few milliseconds on a fast disk; more where
writes per second are limited, as on the cloud VM's volume). A VFS shim (`runtime/walvfs.c`)
issues each commit's WAL frames in writes of up to 64 KiB (one write for a commit of up to 15
frames) instead of two per page.

**Page cache.** SQLite's own (`SQLITE_CONFIG_PCACHE2`), wrapped: at commit SQLite drops cached
pages past the end of the file, and the default cache scans its whole hash table for them once
any key at or past that point was seen. `balance_nonroot` parks a page under the lock-byte page's
number for a moment when it reorders new pages, so after every page split the next commit scanned
the whole cache (16,000 pages in the 64 MB cache this entry used when it was measured). The
wrapper tracks the largest key a page of the cache holds and passes the truncation on only when it
can find something (2.5 % of the handler's CPU in the in-process benchmark). The caches take their
first 2,880 pages from one pool of 12 MB (`SQLITE_CONFIG_PAGECACHE`) in huge pages, faulted in at
startup before the process turns them off, and the rest of the request thread's 48 MB from malloc:
in 4 KB pages the pool would need more TLB entries than there are, so reads of random pages (a
feed's authors, a post's leaves) would walk the page tables (the pool saved 3 % of the handler's
CPU in the in-process benchmark, with the 8 MB cache of the time).

**Compiling.** gcc builds both the C that Lean emits and the C runtime with `-O3 -march=native`,
profile-guided: `build.sh` builds an instrumented binary, runs it on a made-up database and
workload (`runtime/train.c`: its own users and posts, no seed data; the user model of
`bench/load.js` and some rejected requests), then builds the final binary with the profile
(9 % less CPU for the handler than Lean's clang at `-O3`, in the in-process benchmark). If any
step fails it builds without the profile. `-march=native` also decides the SHA-256 compression: it
uses the SHA extensions when the build CPU has them and scalar code otherwise (the box's Cascade
Lake Xeon has none).

**Transport.** Several io_uring rings, each with a table of direct socket descriptors (a ring's
table is limited by `RLIMIT_NOFILE`, so the rings together hold more than 65,535 connections);
eight `SO_REUSEPORT` listeners; multishot accept; `DEFER_TASKRUN` on every ring. Rings are made as
connections fill them (ring 0 at startup, each later one 8,192 connections before the one before
it is full), so only as many are busy as the connection count needs. The loop enters each ring
once per iteration, in #264's order: each other ring submits what the last batch queued and runs
its task work, then ring 0 submits, and the loop waits for 64 completions on it or the rest of its
2 ms period in a timed `io_uring_enter` (with `FEED_SPIN_US` it spins on ring 0's completion queue
instead: The spin, below). Input that reaches another ring during that
wait is read in the next iteration. On the local harness at 280,000 users (`FEED_STATS`, with the
multishot receive below and the timed wait) that made 0.079 calls of `io_uring_enter` per request
against 0.207 for the previous design, and about 540 wakeups of the loop a second against 480.
With `FEED_RINGS_PLAIN` the other rings run their task work as it comes, as in #245, so their
completions are read from shared memory without entering them; that also made 0.079 calls per
request, and each of those rings' completions then woke the loop out of ring 0's wait, about 4,200
wakeups a second. `FEED_RINGS_UPFRONT`, and the idle policy below (whose race-free close was
tested only with that design), keep the previous design: every ring made at startup with a
listener of its own, entered twice per iteration, and a sleep between iterations.

Each connection has one multishot receive into its ring's 512 provided buffers of 1 KB, the design
of rust-iouring-kensac #264: a request costs one completion. A burst that takes every buffer of a
ring ends the receive (`ENOBUFS`); its connection joins the ring's read queue, and after the
iteration's completions are in, the loop issues one non-blocking read per queued connection
(never more on a ring than its buffers), in up to eight rounds while buffers come back, and the
reads complete during the submit. A read that fills its buffer queues the connection again, so a
burst of any size waits in the queue; once a read shows the socket drained, the receive is armed
again. Each round enters the rings with queued connections once more; on the local harness at
280,000 users no receive ended in a whole run. The receive holds its own reference to the socket:
Linux up to 6.12 frees a direct descriptor that was closed only once every request issued on its
ring before the close has completed, and a request on a direct descriptor that stays armed is such
a request for as long as it lasts, so one idle connection kept every socket closed after it (in a
local test with polls on direct descriptors, after 2,000 peers closed their connections the
server's 2,000 sockets stayed in CLOSE-WAIT until the idle connection closed, and at SIGTERM the
process did not exit until killed). So the receive is armed on a plain descriptor that
`IORING_OP_FIXED_FD_INSTALL` (6.8) makes for the slot and that is closed again at once; a receive
there takes no resource node, and provided buffers are not a resource. On kernels before 6.8,
which lack that operation, each connection waits on a poll of its direct descriptor instead, and
one idle connection again keeps every socket closed after it. Reads and sends, which complete at
once, use the direct descriptor. A close cancels the receive first, linked to the close.

With `FEED_MSRECV=0`, and while the idle policy is configured (its race-free close needs a poll to
remove), each connection waits on a multishot poll instead, armed the same way: a readiness report
puts it on the read queue, so every request costs a report, a submission and a read's completion.
The receive saved no CPU beyond the noise: on the local harness (Linux 6.12) 12.43 µs of the core
per request against 12.63 with polls (three and two runs; the server's cgroup alone 11.46 against
11.10), and on the cloud VM (Linux 6.8) at 340,000 users 60.0 % of the CPU against 58.6 %. It
costs memory: an armed receive takes its async poll entry (96 B) beside the 256 B request, and on
6.12 also a 512 B message header; on the cloud VM the slab came to 4.21 to 4.22 KB per connection
against 4.12 to 4.14 KB with polls (90 to 105 B more), and in a local test on 6.12 with 100,000
idle connections 605 B more, none of it charged to the server's memory cgroup. The receive is the
default because of the tail latency with polls: on the KVM guest with its vCPU's sibling
hyperthread at full duty, 2-minute probes at 320,000 users held p99 58 ms at 81 % of the CPU with
the receive, and with polls p95 46 ms but p99 1.9 s at 79 %, where 1 to 2 % of every kind of
request took 1.5 to 3.7 s.

Kernels newer than 6.8 charge ring memory to `RLIMIT_MEMLOCK` (8 MB under systemd); there a ring
that does not fit is made smaller, or the server runs on fewer rings. Input a batch did not consume
waits in a heap buffer only until the next batch; kept for the connection's lifetime (one for every
connection that had ever waited, which includes every writer outside a write window), these
buffers grew the heap by 117 MB during a 2-minute hold at 360,000 users on the local harness. At
SIGTERM every listener closes first, and the signal handler also wakes the loop's idle wait (in a
local test with 2,000 idle connections the process exited after 0.010 s, against 0.51 s before).

**Memory.** The kernel keeps about 4 KB per open connection (TCP socket, inode, file, the armed
receive or poll), most of it outside the server's cgroup on 6.8 (in a local test on 6.12, about 3.9
KB per connection was charged to it), so on a 2 GB machine the connections can set the limit before
the CPU does. On the cloud VM (1,903 MB) they did for PR #271's version: near 350,000 connections
the page cache that was left was too small for the database's working set, and requests started
waiting on disk reads. The box found that version CPU-bound at 290,000 users, and on the KVM guest
(1,968 MB) fe89683's code had 399 MB available at 360,000. The server keeps little memory of its
own, except where a miss would reach the disk: SQLite's cache is 48 MB, enough for the writes'
working set (the likes primary-key index is 29.5 MB in the seed, and each like reads a random leaf
of it). With 8 MB, on the cloud VM at 350,000 users, the end of the ramp evicted the page cache and
the loop read about 1,000 pages a second from disk for 40 s (p99 6 s); with 48 MB it read about 10 a
second and the hold passed with p99 14 ms. The rest is 512 receive buffers of 1 KB per ring,
completion queues larger than a ring's connections (an overflow would allocate per completion when
memory is shortest), and the first 8 MB of the code locked in memory as it first runs (reclaim would
otherwise take the program's own pages back and the loop would stall reading them from disk).
Checkpoints run at nice 10: on one vCPU they get about a tenth of the CPU while the loop is busy and
all of it while the loop waits between batches (at nice 19, the setting before, such a thread
starved on the box once the CPU saturated: Credits, #278), and with `FEED_SPIN_US` the loop does not
spin while one is due or running (The spin). Ubuntu's 6.8 kernels
from 6.8.0-136 on (and the cloud VM's 6.8 kernel) reject the registration of provided-buffer rings
with a zero reserved field (Launchpad #2162843); the server retries with a nonzero one, which those
kernels accept and a correct kernel never sees.

**Idle connections under a budget.** A safety valve for memory pressure, off by default: it runs
only with `FEED_CONN_BUDGET` (above that many open connections, close the longest idle) or
`FEED_IDLE_MS` (close every connection idle that long) set, and `start.sh` sets neither; with both
unset the transport makes one test per iteration and one per accept or answer, and nothing else. A
forced close costs about 42 µs of a core when its user comes back (on the local harness at 280,000
users with a budget of 270,000: 4,450 closes a second, +6.3 µs of the core per request), so a
budget pays only where the alternative is to run out of memory (on the cloud VM, 350,000
connections took 1.48 GB of slab and 370,000 ran out of memory). With the policy on, connections
wait on polls (`FEED_MSRECV` is ignored) and the transport uses the previous ring design. From 7/8
of the budget on (always, with a timeout), each ring keeps its open connections in order of their
last activity, built once by sorting on the time each accept or answer noted, and drops the lists
again below 3/4. Once per iteration, while more connections are open than the budget or a timeout
is set, the transport merges the heads of those lists, longest idle first, up to
2·`FEED_IDLE_PER_ITER` + 64 candidates (576 by default), flags each one busy or not (`conn_busy`:
input not yet answered, an answer being sent or queued, part of the batch, no armed poll, closing;
or its ring has completions not yet handled or no room to submit), and calls `Feed.Idle.pick`,
compiled Lean, whose theorems are above, to choose which to close. A close removes the poll first,
linked to the close, so input that reached the socket before the removal cancels the close and is
answered. Input that arrives between the removal and the close is lost with the connection: in a
local test with requests 990 to 1,010 ms apart around a 1,000 ms timeout, 10 of 30,000 requests got
EOF or a reset, and the client sent them again.

### The spin

With `FEED_SPIN_US` set, the loop keeps the CPU between batches: after an iteration that finished
early it watches ring 0's completion queue and task-work flag until 64 completions are in, the 2 ms
period ends or `FEED_SPIN_US` has passed, and with nothing to do it spins as long before
`epoll_wait`. It issues no PAUSE while it spins (a long run of PAUSEs makes a KVM host see a
spinning vCPU and yield it), and it does not spin while the checkpoint thread wants the CPU (a
checkpoint is due or running). With `FEED_RINGS_UPFRONT` or the idle policy, which keep the
previous ring design, it sleeps between busy iterations. The spin is off by default: 307205a, which
spun for up to 2,000 µs by default, held the same 280,000 users on the box as fe89683 (below).

The spin was an attempt at a difference between the box and the KVM guest (Measurements). On the
guest, fe89683's code used 15 % less CPU per user than #264; on the box it used as much CPU per
request as #264 (25 µs), and it failed 290,000 users on p99 at about 77 % of the CPU, where #264
held 310,000 at 82 %. Models on the guest of the disk, the memory, the caches and the network did
not reproduce that: a 150 ms flush, a limit of 4,000 writes a second, 150 to 450 MB less memory,
two cache-sweeping neighbours on the socket and a busy network path each slowed #264 as much as
fe89683's code, or more. So did a guest CPU without `IA32_ARCH_CAPABILITIES`, whose kernel then
turns on page-table isolation and buffer clearing: in 2-minute probes it added 2.4 % to the CPU of
307205a's code without the spin at 290,000 users and 3.5 % to #264's at 310,000.

One count tracked the box: halts per request, the times the guest's CPU went idle (HLT exits,
counted by the host's KVM) for each request served. In 2-minute probes on the guest, each entry
near its box score:

| Entry (box score) | Users, CPU on the guest | Halts per request | µs per request, box / guest |
|---|---|---|---|
| rust-iouring-kensac #264 (310,000) | 310,000, 79 % | 0.096 | 25 / 23.7 (+5 %) |
| c-iouring-pavlyhalim #245 (295,000) | 300,000, 75 % | 0.093 | 26 / 23.4 (+11 %) |
| PR #271's version, 30d259c (290,000) | 290,000, 71.5 % | 0.142 | 27 / 23.3 (+16 %) |
| fe89683 (280,000) | 290,000, 60 % | 0.24 | 25 / 19.5 (+28 %) |

The two entries that halted most often on the guest are the two that the box charged most above
the guest's CPU per request. A server that does less work per request leaves its CPU idle more
often, and on a host that runs other guests on the same core a halt can cost a wakeup delay and
cold caches.

With the spin, on the guest, halts fell to 0.060 a request at 290,000 users (0.054 at 330,000) at
the same p99 (52 ms at 290,000 with and without the spin; 61 against 64 ms at 330,000), and the
cgroup's CPU read about 90 %, since it counts the spinning. With another task at normal priority on
the vCPU's host CPU, busy 200 µs in every 2 ms, one of ten 2-minute probes at 290,000 users without
the spin failed on p99 (1.8 s at 70 % of the CPU, no errors; the other nine had p99 from 57 to 98
ms), and all eight with the spin passed (p99 from 57 to 97 ms), a difference too small to rest on.
Under the 150 ms flush and beside the two neighbours the spin changed nothing (p99 278 against 280
ms, and 306 against 307 ms).

At 360,000 users, in 5-minute holds on three guests alternating with and without the spin, p99 was
284 to 504 ms in five holds with it and 326 to 371 ms in six without it, at 89 to 90 % of the CPU
against 80 to 81 %. A sixth hold with the spin failed at its end: the five load generators had
started k6 up to 46 s apart, and as the first one's connections closed, the others still sending,
the guest ran out of memory and the kernel killed the server (the first generator's p99 225 ms and
no errors; the other four's 1.6 to 6.5 % errors).

On the box the spin did not raise the ceiling: 307205a held 280,000 users for 5 minutes with p99
188 ms (fe89683: 359 ms), at 93 % of the CPU and 31 µs per request with the spinning counted, and
failed the 2-minute probes at 290,000 and 300,000 on p99 (3.3 s and 4.2 s; fe89683: 1.5 s and 1.9
s). The halts tracked the four entries' box penalty without causing it, or the spin cost as much as
it saved; which, one run on the box cannot say, and the box itself varies by about 8 % in CPU per
request from one day to the next (#245 used 26 µs per request on 1 November, its `db.h` tuning #278
28 µs on 2 November). The difference between the box and the guest remains unexplained.

## Measurements

Each number says where it was taken: the challenge's box, a KVM guest set up like the box, a cloud
VM set up like the box, the local harness, or the in-process benchmark. Only the box's numbers are
box results. Four versions appear: PR #271's version (30d259c); fe89683, which the challenge
scored as PR #286; 307205a, which it scored next; and this version. 307205a's code differs from
fe89683's in HTTP framing, written to `Feed/Spec/Http.lean` (with 414 and HEAD), in the checks the
specifications added (well-formed UTF-8 in JSON, base64url without `=` or nonzero bits after the
last byte, `crit`, `cty` and `aud` in tokens), in one `created_at` per write phase, in the idle
policy run as compiled Lean, and in the spin. This version differs from 307205a in three defaults:
no spin, a 10 ms write window and checkpoints every 500 frames, the last two as in 30d259c
(Design). The C version of the new parser costs about 0.05 µs per request more than the old one:
`Feed.batch` alone, without the transport, on the load mix in batches of 64, takes 2.28 µs per
request at 307205a and 2.23 µs at 6803ea6, fe89683's code (medians of interleaved runs on one core;
2.89 µs while the parser ran as compiled Lean).

### On the challenge's box

The challenge measured fe89683 on 3 November 2026: it held 280,000 users for 5 minutes (26,678
requests a second, p95 44.9 ms, p99 359 ms, no errors) at 74 % of the CPU and 25 µs of CPU per
request (peak memory 1,390 MB). 290,000 and 300,000 failed the 2-minute probe on p99 (1.5 s and 1.9
s, no errors), and 320,000 on p95 (5.2 s, at 93 % of the CPU). At the edge the likes and new posts
were the slow part: in the hold their p99 was about 570 ms, against about 330 ms for reads. It
measured 307205a on 4 November 2026: 280,000 users held for 5 minutes (26,738 requests a second,
p95 40.6 ms, p99 188 ms, no errors) at 93 % of the CPU and 31 µs of CPU per request, the spinning
included (peak memory 1,446 MB); 290,000 and 300,000 failed the 2-minute probe on p99 (3.3 s and 4.2
s). The challenge measured PR #271's version (30d259c), whose code fe89683 builds on, on 2 November
2026: it held 290,000 users for 5 minutes (27,560 requests a second, p95 30.7 ms, p99 300 ms, no
errors) at 82 % of the CPU and 27 µs of CPU per request (peak memory 1,107 MB), and 300,000 failed
the 2-minute probe on p99 (2.1 s). rust-iouring-kensac #264, first at 310,000, used 25 µs per
request at 82 % of the CPU there (p99 190 ms). This version has not been measured on the box.

### On a KVM guest set up like the box

These are the guest's numbers, except those marked as the box's. The guest has 1 vCPU and MemTotal
1,968 MB (the box: 1,967 MB) and runs Ubuntu 24.04 with 6.8.0-117-generic (the box's kernel), with
virtio disk and network, under QEMU with `-cpu host` on a Cascade Lake Xeon host (the box's CPU
generation), its vCPU pinned to one hyperthread at 3.1 GHz. The vCPU's sibling hyperthread runs a
CPU-bound load (stress-ng `matrixprod`) at 65 % duty, chosen to bring #264 at 310,000 users near
the box's 82 % of the CPU (78.1 % in its 5-minute hold below; at 0 % duty it used 56 %, at 25 %
63 %, at 50 % 71 %; at 100 % it saturated). Load: k6 1.3.0 with `bench/load.js` from five load
generators of 16 vCPUs, four k6 processes each (one per server address); 60 s ramp, 5-minute hold,
30 s ramp-down; a fresh copy of the seed for every run. Pass is the leaderboard's thresholds over
the whole run (p95 < 500 ms, p99 < 1 s, under 1 % errors); CPU is the server's cgroup over the
hold, as in the leaderboard's CPU % column. The runs of fe89683's code used the build from before
the receive became the default, with `FEED_MSRECV=1`: the code path fe89683 takes by default.

| Entry (box score) | 5-minute holds on the guest (CPU, p99) | Guest's score |
|---|---|---|
| rust-iouring-kensac #264 (310,000) | 310,000 pass (78.1 %, 77 ms); 320,000 pass (80.8 %, 88 ms); 330,000 fail (p99 1.58 s) | 320,000 |
| mojo-iouring-oh-meh #257 (304,000) | 300,000 pass (76.7 %, 55 ms); 310,000 pass (78.8 %, 602 ms) | 310,000 or more |
| c-iouring-pavlyhalim #245 (295,000) | 290,000 fail (p99 1,006 ms); 300,000 pass (74.3 %, 912 ms) | 300,000 (290,000 failed) |
| PR #271's version, 30d259c (290,000) | 290,000 pass (70.1 %, 20 ms); 300,000 pass (72.9 %, 26 ms) | 300,000 or more |
| fe89683's code (280,000) | 330,000 pass (70.1 %, 163 ms); 340,000 pass (72.8 %, 55 ms); 350,000 pass (75.0 %, 90 ms); 360,000 pass (77.8 %, 125 ms); 370,000 pass (79.7 %, 148 ms, 0.05 % errors) | 370,000 or more |
| 307205a, with the spin (280,000) | 300,000 pass (87.9 %, 55 ms); 330,000 pass (90.1 %, 145 ms); 360,000: six of seven pass (88.7 to 89.9 %, 284 to 842 ms), one fail (the guest ran out of memory at the end: The spin) | 360,000 or more |

The guest scored #264 and #245 2 to 3 % above their box scores and #257 at least 2 % above
(320,000 was not run), and PR #271's version at least one step above its box score: 300,000 passed
there and failed on the box. It also favored that version against #264: on the guest it used 4 %
less CPU per user than #264 (70.1 % at 290,000 against 78.1 % at 310,000), on the box 8 % more per
request (27 against 25 µs). It favored fe89683's code more: there that code used 15 % less CPU per
user than #264 and passed every hold from 330,000 to 370,000, with 399 MB of memory still available
at 360,000, and the box held it at 280,000, at #264's 25 µs per request. Design's "The spin" is
about that difference. This version has not been measured on the guest.

Stand-ins tried before the guest: a 1-vCPU slice of a larger cloud VM with a CPU-bound load on its
sibling hyperthread held PR #271's version at 330,000 (box: 290,000) and #264 at 310,000 (its box
score); with 18 % of its CPU taken away at fine grain it reproduced PR #271's box result (290,000
passed with p99 307 ms, 300,000 failed) but failed #264 at 310,000, and there fe89683's code held
330,000 and failed 340,000 (box: 280,000). The cloud VM below held PR #271's version at 340,000 or
350,000 and #245 at 333,000 (box: 290,000 and 295,000). Box runs vary as well: the same code of
ada-native-visseranalytics held 270,000 in one run and failed 260,000 in another, and
c-iouring-pavlyhalim's #278, a `db.h` tuning of #245 (other code), held 290,000 at 28 µs per
request where #245 had held 295,000 at 26.

### The setups that Design names

* **The cloud VM**: booted with `nr_cpus=1 mem=2048M` (one Xeon vCPU, 1,903 MB, no swap),
  Ubuntu 24.04 with a 6.8 kernel, a network volume limited to 3,000 writes per second, systemd and
  load as above. Its vCPU is faster than the box's: #245 used 15 to 16 µs per request there and
  26 µs on the box.
* **The local harness**: the server in a container pinned to one core of a Sapphire Rapids Xeon
  with a 1.75 GB memory limit, its packets handled on the same core; a C load generator follows
  `bench/load.js` (feed, think 3 to 7 s, post, think 3 to 8 s, 15 % like, 2 % new post, idle 5 to
  15 s) from 32 source addresses, with a 60 s ramp, a 120 s hold and a 30 s ramp-down. Its µs per
  request are of the core at full speed.
* **The in-process benchmark**: the handler and the C runtime driven by synthetic batches of the
  load mix, without the network.

## Credits

### What is ours

The design and the code of this entry are ours, except what the next subsection names.

* **The Lean request path.** The handler as compiled Lean on the request path (batch, request
  loop, dispatch, token checks, body rules, the feed's reads, the writes, the responses), the
  `Store` class with its two instances (C over SQLite for the server, a state monad over the
  specification's tables for the proofs) and its contract (`Proofs/Store.lean`), and
  `Feed/Spec.lean`'s statement of the API down to the response bytes (its tables and reads follow
  #153's `Model.lean`).
* **The specifications in `Feed/Spec/`.** HTTP framing as RFC 9112 and RFC 9110 define it, with
  RFC 3986's grammar of the Host value and the request-target; the JSON the API reads as RFC 8259
  defines it, with RFC 3629's UTF-8; base64url as RFC 4648 defines it; SHA-256 and HMAC-SHA256 as
  FIPS 180-4 and RFC 2104 define them, checked on the test vectors of FIPS 180-4 and RFC 4231; the
  token from SPEC.md and RFC 7515, RFC 7518 and RFC 7519; the post body from SPEC.md and
  schema.sql; SPEC.md's table of errors; and what a batch answers from its input bytes. The choices
  they make where SPEC.md and the RFCs leave room, and the departures, are listed in the trust base.
* **The theorems.** The 819 theorems in `Feed/Proofs/` about those definitions: both reads'
  complete responses byte for byte, the writes, routing, one request (`decide_spec`), the batch as
  a serial execution (`runBatch_spec`), the leaves and the handler's checks against the
  specifications, and the end-to-end theorems (`runBatch_correct`, `readLoop_correct`,
  `runBatch_correct_model`, `decide_correct`), which take no hypothesis about what the parser, the
  token check or the body check return, only the storage contract; apart from the lemma the #153
  bullet names.
* **`check-docs.sh`** (`CheckDocs.lean`), the gate on what the docs say of the proofs: no statement
  left to prove in the module docs, no hypothesis of the end-to-end theorems that does not depend
  on their other arguments, and the leaves whose Lean definitions the theorems use, all 15.
* **C leaves checked against Lean.** Each C leaf is `@[extern]` on its Lean definition, and the
  self-test compares the C with those definitions on random inputs and the storage operations with
  the model on a random database, so the build fails if they differ (testing the grouped search
  against `sqlite3BtreeTableMoveto` is #233's idea); the C of HTTP framing follows the Lean parser
  function by function.
* **The idle policy** as a Lean definition with 10 theorems, which the transport calls as compiled
  Lean (prior art for its two settings is below).
* **In the C runtime.** Polls and receives armed on plain descriptors made by
  `IORING_OP_FIXED_FD_INSTALL`, after we found that Linux up to 6.12 frees a closed direct
  descriptor only once every older request on its ring has completed, so one long-lived poll on a
  direct descriptor kept every later-closed socket; the WAL shim (#158 and #233 have similar ones);
  the page cache wrapper's code; the pool of huge pages for SQLite's cache; the batch's page table;
  the responses written in place after their heads; the overload cap and its delayed-ACK reasoning;
  the write window's size; `INSERT OR IGNORE` without a statement journal; the WAL pause's 300 ms
  limit; the 2 ms iteration period (#233 and #245 also wait up to 2 ms while busy); `train.c`; the
  optional spin between batches without PAUSE, which stops while a checkpoint is due or running.
* **The measurement setup** in Measurements: a KVM guest set up like the box and calibrated
  against three other entries' box scores; the finding there that readiness polls left 1 to 2 % of
  requests at 1.5 to 3.7 s, which made the receive the default; and the count of halts per request,
  which tracked how much more CPU per request the box charged four entries than the guest did and
  led to the spin, which did not raise this entry's score on the box (The spin).

### From other entries

Where an entry's code is not named below, the idea came from its README and the code here is ours.

* **lean-derive-hargup #153**, the first Lean entry, whose runtime and model this one started from.
  Code: `install.sh`; `build.sh`'s SQLite download and first eight `-DSQLITE_` flags; `server.c` as
  one translation unit with the amalgamation; in `db.c` the SQLite helpers, the record decoder,
  `cur_payload`, `likes_seek_ge` (c-iouring-pavlyhalim's `src/btree.h` has the same three; ours
  were in our `db.c` before we read it), the layout check, `db_open`'s order, the batch's `BEGIN`
  plus `sqlite3BtreeBeginTrans` and the checkpoint thread; the skeleton of `uring.c` (ring setup,
  `user_data` tags, submissions and completions, the listener, ring sizes from `RLIMIT_NOFILE`, the
  held-connection list). Designs: `Feed/Json.lean`'s validating scanner that records the spans of a
  few wanted top-level keys, the last duplicate winning (its `runtime/json.c`), and
  `Feed/Http.lean`'s limits and refusals (a 16 KiB head, 400 for a conflicting `Content-Length` or
  any `Transfer-Encoding`, 413, 431; its `runtime/http.c`), which the JSON and HTTP leaves now
  implement in C; `Feed/Jwt.lean`'s three results and the order of its checks (its
  `runtime/jwt.c`); `readLoop`'s rule that a connection's requests after a write wait for the next
  batch (its `runtime/uring.c` `conn_hold`), decided here in Lean. Ideas: B-tree cursor reads with
  SQL writes; a batch as one transaction, reads first, answered after its commit; waiting after a
  light iteration so that the next one serves a batch; a `SO_REUSEPORT` listener per ring (the
  design `FEED_RINGS_UPFRONT` keeps); the words "that is the key schedule" for the HMAC key blocks
  computed once (its README, JWT). Lean: a model of the API over lists of rows with proofs checked
  in `build.sh`; `Feed/Spec.lean`'s tables and reads (`newerEq`, `feed`, `view`, `getPost`,
  `nextPostId`, the like insert) follow its `Model.lean`; the proof of `filterMap_congr_mem`
  follows its `filterMap_congr'`. The summary table and parts of Design paraphrase its README.
* **c-iouring-pavlyhalim #233 and #245.** Code: the grouped rowid search (`lookup_many`,
  `page_key`, `page_lower_bound`, `hit_record`) is adapted from `bt_seek_many`, `bt_cell_key`,
  `bt_lower_bound` and `bt_hit_record` (`src/btree.h`, #233, kept in #245). The guess inside a page
  from `bt_lower_bound` (start where a line through the page's first and last keys puts the key,
  try its neighbour, then bisect), which `page_lower_bound` took over, is also used by
  `lookup_sorted`, by `find_rowid` on each level and by `it_lower` in the pages of
  `likes_post_id_idx`; keeping every page a batch's reads fetch referenced until its reads end, the
  direct hit at `k - k0` and computing the guess in integers are ours. `accept_policy` in
  `runtime/uring.c` is adapted from its `accept_policy` (`src/server.c`, #245): rings are made as
  connections fill them (ring 0 at startup, each later one 8,192 connections before the previous
  one is full), and the multishot accepts of eight `SO_REUSEPORT` listeners are armed on the ring
  being filled and cancelled 4,096 slots before a ring is full. `sys_enter_wait`, the timed
  `io_uring_enter` on ring 0, follows its `ring_wait` (`src/sys.h`) and waits for 64 completions as
  its loop does; `FEED_RINGS_PLAIN` runs its other ring design, with ordinary task work on the rings
  after ring 0, for measurements. The buffer-ring retry is from #245's `src/sys.h`
  (fsharp-kestrel-delneg #201 and ada-native-visseranalytics #211 had the same retry earlier).
  Ideas from #233: testing that search against `sqlite3BtreeTableMoveto`, the page cache wrapper,
  the training database's sizes and request mix. From #245's README (Connections, At the memory
  wall, SQLite): reads through a read queue, one non-blocking read per queued connection and never
  more than the ring's buffers (the burst path of the receive, and with polls every read), polls for
  readiness, removing the poll before a close, 65,536-entry completion queues, smaller rings on
  `ENOMEM`, keeping the server's own memory small at the memory wall (the 48 MB cache here came from
  our runs on the cloud VM), checkpoints at a low priority (nice 19 there, nice 10 here, as
  c-iouring-pavlyhalim #278 found), locking the code (c-iouring-public #158 had it
  first), its 90 s keep-alive close, and its memory valve, off by default because it did not pay
  (the idle policy here is off by default too).
* **rust-iouring-kensac #264** (its README, Connections, and the receive, read and pass-loop code
  of its `src/main.rs`). The receive path, the default here: one multishot receive per connection
  into the ring's provided buffers, and after a burst (`ENOBUFS`) the connection is read through the
  read queue until a read shows the socket drained, then the receive is armed again. The order in
  which the loop enters the rings: every other ring submits and runs its deferred task work without
  waiting, then ring 0 submits and waits in a timed `io_uring_enter` (with `FEED_SPIN_US` this
  entry spins there: The spin), where the previous loop entered every ring twice and slept
  between iterations. It also makes rings as they fill. The C is ours, its completion handling
  following that of `src/main.rs`; arming the receive on the `FIXED_FD_INSTALL` descriptor is ours,
  and a close cancels the receive by its `user_data`, hard-linked to the close, as #245's close
  cancels its poll.
* **objc-uring-delneg #154.** Inserts without `RETURNING`: `created_at` formatted and bound by the
  server, the id from `sqlite3_last_insert_rowid` (#233 too); a profile-guided build trained by the
  server's own code on made-up data, with a plain build as fallback (#233 and #228 also use PGO);
  the cause of the page cache's scan, `balance_nonroot` parking a page under the lock-byte page's
  number.
* **mojo-iouring-oh-meh #224.** A read on the checkpoint connection at open (its README: passive
  checkpoints do nothing without one); the `PROVIDE_BUFFERS` fallback (buffers returned in runs,
  completions skipped); the phrases "cursors opened once per batch" and "only the bytecode engine is
  skipped" from its README and "never waits on an fsync" from its `src/shim.c`.
  crystal-epoll-faustinoaq #193 had the checkpoint read and c-iouring-raoz #26 the
  `PROVIDE_BUFFERS` runs earlier.
* **c-iouring-moneebullah25 #228** (first in #156): pausing writes, reads going on, past 8,192 log
  frames (4,096 here) until the log can restart; #153's and #224's READMEs explain why group commit
  needs it. Its README also protects memory by closing keep-alives idle for 60 s and by shedding
  connections near a connection cap, the two settings of the idle policy here (`FEED_IDLE_MS`,
  `FEED_CONN_BUDGET`); the policy's choice, its Lean definition, its theorems and its C are ours.
* **v-epoll-i098 #191.** The feed plan: the newest ids from `posts_created_at_id_idx`, one scan of
  `posts` when they are consecutive, one range scan of `likes_post_id_idx` (#153's `feed_tail` and
  `range_counts` also walk `posts` backward and count likes by one range scan; c-iouring-raoz #26
  and cpp-eastl-io_uring-pgo-hendy643 #32 had the plan earlier). #191 also holds new writes for
  5 ms after a commit so that they share the next one, the same idea as the write window here.
* **c-iouring-public #158**, via #245's README: the measurement that nice 19 came from (#158's
  README: at the memory wall a checkpoint pass of 300 to 430 ms at nice 0 took half the vCPU from
  the loop; 2 of 3 holds at the edge died at nice 0, 3 of 3 held at nice 19). #158's author has
  since withdrawn the nice-19 result (1 of 3 holds on stock SQLite, as c-iouring-pavlyhalim #278
  reports), and #278 found a nice-19 checkpoint thread starved when the CPU saturates: the scheduler
  gives it about 1.4 % of the CPU, where the checkpoint needs about 4.5 % at 300,000 users, and in
  #278's load tests at 300,000 to 310,000 users it barely progressed for the rest of the hold (the
  log grew to 970,000 frames); at nice 10 the log stayed under 4,300 frames at 310,000 users, and
  #278 runs the thread at nice 10, as this entry now does.

Related, and not a source as far as we know: c-epoll-TheFirstIstari #64 closes its oldest idle
keep-alive connections under file-descriptor pressure, as the idle policy here does under a
budget; c-iouring-public #158's memory floors, off by default, close keep-alives idle for 20 s
or more when less than 120 MB is available; and rust-epoll-scooter1337 #82's epoll path, with
`--spin-us` (off by default), polls without sleeping for that long after events arrive, as the
loop here spins between batches with `FEED_SPIN_US` (its README says earlier busy-poll tests showed
no reliable gain).

## Build and run

* `install.sh` (root, once): build-essential, curl, ca-certificates, unzip, zstd; Lean
  `nightly-2026-10-30` from the official nightly release, checked against its SHA-256.
* `build.sh` (user): downloads the pinned SQLite amalgamation (SHA-256 checked); `lake build`, which
  checks every proof and compiles `Feed/` to C; checks which C functions that C calls (the leaves,
  the storage operations and `Main`'s entry points); gcc builds that C with the C runtime, an
  instrumented binary first, its training run, then the profile-guided `bin/server`; runs the
  self-test. From a clean tree it took about 510 s on a KVM guest with one vCPU and 2 GB (1,968 MB,
  Ubuntu 24.04, Linux 6.8.0-117-generic); sampled every second, the largest `lean` process held
  747 MB resident, `lake` 668 MB and gcc's `cc1` 505 MB.
* `start.sh`: `bin/server` in the foreground, configured by `SQLITE_PATH`, `JWT_SECRET`, `HOST`,
  `PORT`; it sets `UV_USE_IO_URING=0`, so the Lean runtime's libuv opens no io_uring of its own.
  The `FEED_*` environment variables override defaults for measurements, turn on the spin
  (`FEED_SPIN_US`) or turn on the idle policy; `start.sh` sets none of them.
* `check-docs.sh` (not run by `build.sh`): `CheckDocs.lean` checks what the docs say of the proofs
  that no theorem states. The statements still to prove, in the module docs of `Feed/Proofs/`,
  must type-check against the code, and one the code has as a theorem must be out of the doc (none
  is left); the end-to-end theorems must take no such statement, nor any other hypothesis that does
  not depend on their other arguments; the leaves whose Lean definitions the theorems use must be
  the ones this README names, all 15.
