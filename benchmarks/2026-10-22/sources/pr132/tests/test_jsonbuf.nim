## test_jsonbuf.nim: byte-exact proof for the SSE2 JSON string escaper.
##
## The production `addEscaped` scans sixteen bytes at a time; the scalar routine
## below is kept here *only* as an oracle. Every case
## compares the production output / wire form against that oracle byte-for-byte:
##
##   * all 256 possible byte values as singleton strings,
##   * the empty string,
##   * every escape trigger at every offset of an 80-byte base (word-boundary
##     and tail coverage),
##   * long (> 64 B) clean, quote, backslash, control and UTF-8 runs,
##   * 1,500 deterministic pseudo-random mixed strings of length 0..200.
##
## Prints "PASS <name>" per case; the first mismatch prints both byte strings
## and exits non-zero.
import std/strutils
import ../src/jsonbuf

const Hex = "0123456789abcdef"

# ---------------------------------------------------------------------------
# Scalar oracle: the per-byte implementation, test-only.
# ---------------------------------------------------------------------------
proc scalarEscaped(s: string): string =
  for c in s:
    case c
    of '"':  result.add "\\\""
    of '\\': result.add "\\\\"
    of '\b': result.add "\\b"
    of '\f': result.add "\\f"
    of '\n': result.add "\\n"
    of '\r': result.add "\\r"
    of '\t': result.add "\\t"
    else:
      if c.ord < 0x20:
        let o = c.ord
        result.add "\\u00"
        result.add Hex[(o shr 4) and 0xF]
        result.add Hex[o and 0xF]
      else:
        result.add c

# ---------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------
var checks = 0
var failures = 0

proc failDetail(name, got, want: string) =
  inc failures
  echo "FAIL ", name
  echo "  want (", want.len, " B): ", escape(want)
  echo "  got  (", got.len, " B): ", escape(got)
  quit(1)

proc compare(name, got, want: string) =
  inc checks
  if got == want:
    echo "PASS ", name
  else:
    failDetail(name, got, want)

proc escaped(s: string): string =
  addEscaped(result, s)

proc jstr(s: string): string =
  addJStr(result, s)

proc compareBoth(name, s: string) =
  let want = scalarEscaped(s)
  compare(name, escaped(s), want)
  compare(name & " [addJStr]", jstr(s), "\"" & want & "\"")

# ---------------------------------------------------------------------------
# Deterministic pseudo-random corpus (LCG; no std/random import needed).
# ---------------------------------------------------------------------------
var rngState = 0x9E3779B97F4A7C15'u64

proc nextRand(): uint64 =
  rngState = rngState * 6364136223846793005'u64 + 1442695040888963407'u64
  rngState

proc randomString(maxLen: int): string =
  let n = int(nextRand() mod uint64(maxLen + 1))
  result = newStringOfCap(n)
  for _ in 0 ..< n:
    let r = nextRand()
    # Mostly printable ASCII (real feed text), with a steady supply of every
    # other byte value: quotes, backslashes, controls and UTF-8 high bytes.
    let b =
      if (r and 7) != 0:
        char(0x20 + int((r shr 8) mod 0x5F))   # 0x20 .. 0x7E
      else:
        char((r shr 16) and 0xFF)              # 0x00 .. 0xFF
    result.add b

proc main() =
  # --- empty ---------------------------------------------------------------
  compareBoth("empty", "")

  # --- every byte value as a singleton ------------------------------------
  for b in 0 .. 255:
    var s = ""
    s.add char(b)
    compareBoth("singleton 0x" & toHex(b, 2), s)

  # --- every trigger at every offset of an 80-byte base --------------------
  # 80 covers full words, a word-boundary hit and the scalar tail.
  let triggers = [
    '"', '\\', '\b', '\f', '\n', '\r', '\t', char(0x00), char(0x01),
    char(0x0B), char(0x1F)
  ]
  for t in triggers:
    for pos in 0 ..< 80:
      var s = 'a'.repeat(80)
      s[pos] = t
      compareBoth("trigger " & toHex(t.ord, 2) & " at " & $pos, s)

  # --- long (> 64 B) homogeneous runs -------------------------------------
  compareBoth("long clean", 'x'.repeat(257))
  compareBoth("long spaces", ' '.repeat(200))
  compareBoth("long quotes", '"'.repeat(193))
  compareBoth("long backslashes", '\\'.repeat(199))
  var controls = ""
  for i in 0 ..< 200:
    controls.add char(i mod 0x20)
  compareBoth("long controls", controls)
  let utf8 = "café ✓ Привет 🌍 日本語"
  compareBoth("utf8", utf8)
  compareBoth("long utf8", utf8.repeat(12))
  compareBoth("clean then escape", 'a'.repeat(64) & "\"b\\c" & 'd'.repeat(64))

  # --- runs of each escape, adjacent and interleaved ----------------------
  compareBoth("adjacent quotes", "\"\"\"\"\"\"\"\"\"\"")
  compareBoth("quote backslash pairs", "\"\\\"\\\"\\\"\\\"\\\"\\")
  compareBoth("mixed escapes", "a\"b\\c\nd\te\rf\bg\fh" & "\x01\x1f")

  # --- 1,500 deterministic mixed strings ----------------------------------
  for i in 0 ..< 1500:
    compareBoth("random " & $i, randomString(200))

  echo "JSONBUF checks=", checks, " failures=", failures
  if failures != 0:
    quit(1)
  echo "JSONBUF PASS"

main()
