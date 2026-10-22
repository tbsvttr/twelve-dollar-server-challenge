## HS256 JWT tests.
##
## Tokens are generated exactly the way the challenge harness does, i.e. via
##   b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
##   h = printf '%s' '{"alg":"HS256","typ":"JWT"}' | b64url
##   p = printf '%s' "$payload" | b64url
##   s = printf '%s' "$h.$p" | openssl dgst -sha256 -hmac "$JWT_SECRET" -binary | b64url
## so the test exercises the same wire format as production tokens.
import std/[osproc, streams, strutils, times]
import ../src/jwt

const JwtSecret = "twelve-dollar-challenge"
const Hs256Header = """{"alg":"HS256","typ":"JWT"}"""

var failures = 0

proc check(name: string; cond: bool) =
  if cond:
    echo "PASS ", name
  else:
    echo "FAIL ", name
    inc failures

proc runStdin(cmd: string; args: openArray[string]; data: string): string =
  let p = startProcess(cmd, args = args, options = {poUsePath, poStdErrToStdOut})
  p.inputStream.write(data)
  p.inputStream.close()
  result = p.outputStream.readAll()
  discard p.waitForExit()
  p.close()

proc b64url(data: string): string =
  ## openssl base64 -A | tr '+/' '-_' | tr -d '='
  let raw = runStdin("openssl", ["base64", "-A"], data)
  raw.replace('+', '-').replace('/', '_').replace("=", "").strip()

proc hmacB64(data, secret: string): string =
  ## openssl dgst -sha256 -hmac "$secret" -binary | b64url
  let raw = runStdin("openssl",
    ["dgst", "-sha256", "-hmac", secret, "-binary"], data)
  b64url(raw)

proc makeToken(payloadJson: string;
               headerJson = Hs256Header;
               secret = JwtSecret): string =
  let h = b64url(headerJson)
  let p = b64url(payloadJson)
  let s = hmacB64(h & "." & p, secret)
  h & "." & p & "." & s

proc escapeJson(s: string): string =
  result = "\""
  for c in s:
    case c
    of '"': result.add "\\\""
    of '\\': result.add "\\\\"
    else: result.add c
  result.add "\""

proc payloadJson(sub, username: string; exp: int): string =
  ## Mirrors the harness printf payload ordering.
  "{\"sub\":" & escapeJson(sub) &
    ",\"username\":" & escapeJson(username) &
    ",\"iat\":" & $exp &
    ",\"exp\":" & $exp & "}"

let now = epochTime().int

# 1. Valid token -> jsOk with parsed userId/username.
block:
  let token = makeToken(payloadJson("1", "golden_ember_1", now + 3600))
  let (status, info) = verifyJwt(token, JwtSecret)
  check("valid", status == jsOk and info.userId == 1 and
                 info.username == "golden_ember_1")

# 2. Bad signature (signed with the wrong secret) -> jsInvalid.
block:
  let token = makeToken(payloadJson("1", "golden_ember_1", now + 3600),
                        secret = "not-the-secret")
  let (status, _) = verifyJwt(token, JwtSecret)
  check("bad-signature", status == jsInvalid)

# 3. alg=none with empty signature -> jsInvalid.
block:
  let h = b64url("""{"alg":"none","typ":"JWT"}""")
  let p = b64url(payloadJson("1", "golden_ember_1", now + 3600))
  let token = h & "." & p & "."
  let (status, _) = verifyJwt(token, JwtSecret)
  check("alg-none", status == jsInvalid)

# 4. Expired token (exp in the past) -> jsInvalid.
block:
  let token = makeToken(payloadJson("1", "golden_ember_1", now - 3600))
  let (status, _) = verifyJwt(token, JwtSecret)
  check("expired", status == jsInvalid)

# 5. sub "abc" with a valid signature -> jsBadPayload.
block:
  let h = b64url(Hs256Header)
  let p = b64url("""{"sub":"abc","username":"golden_ember_1","exp":""" &
                  $(now + 3600) & """}""")
  let token = h & "." & p & "." & hmacB64(h & "." & p, JwtSecret)
  let (status, _) = verifyJwt(token, JwtSecret)
  check("bad-sub", status == jsBadPayload)

# 6. Missing username with a valid signature -> jsBadPayload.
block:
  let h = b64url(Hs256Header)
  let p = b64url("""{"sub":"2","exp":""" & $(now + 3600) & """}""")
  let token = h & "." & p & "." & hmacB64(h & "." & p, JwtSecret)
  let (status, _) = verifyJwt(token, JwtSecret)
  check("no-username", status == jsBadPayload)

# 7. Non-canonical headers still follow std/json semantics (the fast path only
#    covers the exact official header bytes).
block:
  let p = payloadJson("1", "golden_ember_1", now + 3600)
  check("header-key-order",
        verifyJwt(makeToken(p, headerJson = """{"typ":"JWT","alg":"HS256"}"""),
                  JwtSecret).status == jsOk)
  check("header-whitespace",
        verifyJwt(makeToken(p, headerJson = """{ "alg" : "HS256" , "typ" : "JWT" }"""),
                  JwtSecret).status == jsOk)
  check("header-extra-keys",
        verifyJwt(makeToken(p, headerJson = """{"alg":"HS256","typ":"JWT","kid":"k1"}"""),
                  JwtSecret).status == jsOk)
  check("header-duplicate-alg-last-hs256",
        verifyJwt(makeToken(p, headerJson = """{"alg":"none","alg":"HS256"}"""),
                  JwtSecret).status == jsOk)
  check("header-duplicate-alg-last-none",
        verifyJwt(makeToken(p, headerJson = """{"alg":"HS256","alg":"none"}"""),
                  JwtSecret).status == jsInvalid)

# 8. Escaped sub: \u0031 decodes to "1" and is a valid positive integer.
block:
  let p = """{"sub":"\u0031","username":"golden_ember_1","exp":""" &
          $(now + 3600) & "}"
  let (status, info) = verifyJwt(makeToken(p), JwtSecret)
  check("escaped-sub", status == jsOk and info.userId == 1)

# 9. Unicode username: BMP escape + surrogate pair decode to UTF-8.
block:
  let p = """{"sub":"1","username":"caf\u00e9 \ud83d\ude00","exp":""" &
          $(now + 3600) & "}"
  let (status, info) = verifyJwt(makeToken(p), JwtSecret)
  check("unicode-username", status == jsOk and info.username == "café 😀")

# 10. A lone high surrogate is malformed JSON -> jsInvalid (not jsBadPayload).
block:
  let p = """{"sub":"1","username":"\ud800","exp":""" & $(now + 3600) & "}"
  let token = makeToken(p)
  check("lone-surrogate", verifyJwt(token, JwtSecret).status == jsInvalid)

# 11. exp comparison: epochTime() > exp rejects; equality is accepted. Pass an
#     explicit `now` so the boundary is exact, not wall-clock dependent.
block:
  let fixedNow = 1_700_000_000.0
  let atNow = makeToken("""{"sub":"1","username":"u","exp":1700000000.0}""")
  check("exp-equal-now-float", verifyJwt(atNow, JwtSecret, fixedNow).status == jsOk)
  let atNowInt = makeToken("""{"sub":"1","username":"u","exp":1700000000}""")
  check("exp-equal-now-int", verifyJwt(atNowInt, JwtSecret, fixedNow).status == jsOk)
  let past = makeToken("""{"sub":"1","username":"u","exp":1699999999.999}""")
  check("exp-1ms-past", verifyJwt(past, JwtSecret, fixedNow).status == jsInvalid)

# 12. Signature length != 32 is rejected even before constant-time compare.
block:
  let h = b64url(Hs256Header)
  let p = b64url("""{"sub":"1","username":"u","exp":""" & $(now + 3600) & "}")
  check("sig-31-bytes", verifyJwt(h & "." & p & "." & b64url("x".repeat(31)),
                                  JwtSecret).status == jsInvalid)
  check("sig-33-bytes", verifyJwt(h & "." & p & "." & b64url("y".repeat(33)),
                                  JwtSecret).status == jsInvalid)

if failures > 0:
  echo "FAILURES: ", failures
  quit(1)
