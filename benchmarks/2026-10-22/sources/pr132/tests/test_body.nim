## test_body.nim: differential proof for the direct `parseBody` fast path.
##
## `oracleParseBody` below is the std/json oracle, kept here only for the
## differential check. For every corpus entry we require:
##
##   * fast parseBody == oracleParseBody in both kind and decoded bytes,
##   * canonical entries are actually taken by the fast scanner,
##   * non-canonical / unsupported entries are rejected by the fast scanner, so
##     the std/json fallback is really exercised.
##
## The corpus covers whitespace, every supported escape, \u0000, BMP and
## surrogate-pair code points, raw UTF-8, empty objects/strings, non-string and
## duplicate/extra keys, trailing commas, comments, malformed JSON, the 500/501
## char boundary and whitespace-only bodies. Prints "PASS <name>" per case; the
## first mismatch prints both results and exits non-zero.
import std/[json, strutils]
import ../src/jsonbuf

type Parsed = tuple[kind: BodyKind, body: string]

# ---------------------------------------------------------------------------
# Reference implementation: exactly what parseBody did before the fast path.
# ---------------------------------------------------------------------------
proc oracleParseBody(raw: string): Parsed =
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

# ---------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------
var checks = 0
var fastHits = 0
var failures = 0

proc failDetail(name: string, got, want: Parsed) =
  inc failures
  echo "FAIL ", name
  echo "  want:  kind=", want.kind, " body=", escape(want.body)
  echo "  got:   kind=", got.kind, " body=", escape(got.body)
  quit(1)

proc check(name: string, raw: string, expectFast: bool) =
  inc checks
  let want = oracleParseBody(raw)
  var fastBody = ""
  let fast = parseCanonicalBody(raw, fastBody)
  if fast != expectFast:
    inc failures
    echo "FAIL ", name, " fast-path decision"
    echo "  input: ", escape(raw)
    echo "  want fast=", expectFast, " got fast=", fast
    quit(1)
  if fast:
    if fastBody != want.body or want.kind != bkOk:
      inc failures
      echo "FAIL ", name, " fast decode"
      echo "  input: ", escape(raw)
      echo "  want:  ", escape(want.body)
      echo "  got:   ", escape(fastBody)
      quit(1)
    inc fastHits
  let got = parseBody(raw)
  if got != want:
    failDetail(name, got, want)
  echo "PASS ", name, " (fast=", fast, ")"

let body500 = repeat('b', 500)
let body501 = repeat('c', 501)
let bigEscaped = repeat("\\n\\t\\\"\\\\", 40)  # 320 bytes of raw escape text
let rawUtf8 = "café ✓ 日本語 😀"
let rawUtf8Json = "{\"body\":\"" & rawUtf8 & "\"}"

# --- canonical: must be taken by the fast scanner ---------------------------
check("canonical minimal", """{"body":"x"}""", true)
check("canonical empty string", """{"body":""}""", true)
check("canonical leading space", """ {"body":"x"}""", true)
check("canonical trailing space", """{"body":"x"} """, true)
check("canonical all whitespace tokens", "{\n\t\r \"body\"\t:\n\"x\"\r\n}", true)
check("canonical spaces around colon", """{ "body" : "x" }""", true)
check("canonical escaped quote", """{"body":"a\"b"}""", true)
check("canonical escaped backslash", """{"body":"a\\b"}""", true)
check("canonical escaped slash", """{"body":"a\/b"}""", true)
check("canonical escapes b f n r t", """{"body":"\b\f\n\r\t"}""", true)
check("canonical mixed escapes", """{"body":"\"\\\/\b\f\n\r\t"}""", true)
check("canonical chunked escapes", "{\"body\":\"" & bigEscaped & "\"}", true)
check("canonical u0000", """{"body":"\u0000"}""", true)
check("canonical u0000 inside text", """{"body":"a\u0000b"}""", true)
check("canonical bmp accent", """{"body":"\u00e9"}""", true)
check("canonical bmp euro", """{"body":"\u20ac"}""", true)
check("canonical bmp max", """{"body":"\uFFFF"}""", true)
check("canonical surrogate pair", """{"body":"\ud83d\ude00"}""", true)
check("canonical surrogate pair upper hex", """{"body":"\uD83D\uDE00"}""", true)
check("canonical surrogate pair mid", """{"body":"a\ud83d\ude00b"}""", true)
check("canonical raw utf8", rawUtf8Json, true)
check("canonical whitespace-only body", """{"body":"   "}""", true)
check("canonical 500 ascii", "{\"body\":\"" & body500 & "\"}", true)
check("canonical 501 ascii", "{\"body\":\"" & body501 & "\"}", true)
check("canonical 500 escaped-looking", "{\"body\":\"" & repeat('x', 500) & "\"}", true)
check("canonical newline escaped long", "{\"body\":\"" & repeat("a\\nb", 100) & "\"}", true)

# --- fallback: the scanner must reject and std/json must decide -------------
check("empty input", "", false)
check("whitespace-only input", " \n\t\r ", false)
check("empty object", "{}", false)
check("missing body key", """{"other":"x"}""", false)
check("non-string body int", """{"body":123}""", false)
check("non-string body null", """{"body":null}""", false)
check("non-string body bool", """{"body":true}""", false)
check("non-string body array", """{"body":[]}""", false)
check("non-string body object", """{"body":{}}""", false)
check("duplicate body last wins string", """{"body":"x","body":"y"}""", false)
check("duplicate body first non-string", """{"body":1,"body":"y"}""", false)
check("duplicate body last non-string", """{"body":"x","body":1}""", false)
check("extra key", """{"body":"x","z":1}""", false)
check("extra nested key", """{"body":"x","a":[1,2,{"b":3}]}""", false)
check("trailing comma", """{"body":"x",}""", false)
check("block comment after value", """{"body":"x" /*c*/}""", false)
check("line comment after value", "{\"body\":\"x\" //c\n}", false)
check("comment before value", """{"body" /*c*/ : "x"}""", false)
check("unknown escape", """{"body":"\q"}""", false)
check("escape apostrophe", """{"body":"\'"}""", false)
check("escape v", """{"body":"\v"}""", false)
check("lone high surrogate", """{"body":"\ud83d"}""", false)
check("high surrogate then normal escape", """{"body":"\ud83d\n"}""", false)
check("high surrogate then non-low u", """{"body":"\ud83d\u0041"}""", false)
check("lone low surrogate", """{"body":"\ude00"}""", false)
check("malformed u short", """{"body":"\u12"}""", false)
check("malformed u non-hex", """{"body":"\u12G4"}""", false)
check("raw control byte", "{\"body\":\"a\x01b\"}", false)
check("raw newline in string", "{\"body\":\"a\nb\"}", false)
check("raw tab in string", "{\"body\":\"a\tb\"}", false)
check("escaped key", """{"\u0062ody":"x"}""", false)
check("malformed json", "{bad json", false)
check("unterminated object", """{"body":"x"""", false)
check("unterminated string", """{"body":"x}""", false)
check("trailing text", """{"body":"x"} trailing""", false)
check("two objects", """{"body":"x"}{"body":"y"}""", false)
check("adjacent strings in value", """{"body":"x" "y"}""", false)
check("top-level array", "[]", false)
check("top-level string", "\"body\"", false)
check("top-level number", "1", false)
check("body value with chunk after quote", """{"body":"x" ,}""", false)

echo "passed=", checks, " failed=", failures,
     " fast_path_hits=", fastHits, "/", checks,
     " (", (fastHits * 100 div checks), "%)"
