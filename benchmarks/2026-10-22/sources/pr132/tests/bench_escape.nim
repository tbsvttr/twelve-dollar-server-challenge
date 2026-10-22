## bench_escape.nim: same-process throughput comparison for JSON escaping.
##
## The run-based scalar implementation is reproduced here (test-only oracle),
## alongside the production SSE2 `addEscaped`. Both run over the SAME corpus in
## the SAME process, in alternating rounds, so cache/CPU state is shared and the
## ratio is meaningful.
##
## Corpus: 2,048 deterministic strings of 50..200 bytes modelled on the seed
## feed (English words + spaces; the seed has ZERO escapable bytes in 85 MB of
## strings), with a small tail of quote/backslash/control/UTF-8 cases so both
## paths are represented. Bytes are verified equal before timing.
##
## Usage: nim c -r -d:release --passC:"-O3 -march=native" tests/bench_escape.nim [reps]
import std/[monotimes, os, strutils, times]
import ../src/jsonbuf

const Hex = "0123456789abcdef"

# ---------------------------------------------------------------------------
# Scalar baseline for the benchmark: per-byte membership test, bulk copy of
# clean runs. Same logic as the scalar production code.
# ---------------------------------------------------------------------------
const Escaped = block:
  var s: set[char]
  s.incl '"'
  s.incl '\\'
  for i in 0 ..< 0x20:
    s.incl char(i)
  s

proc scalarAddChars(buf: var string, src: openArray[char]) {.inline.} =
  if src.len == 0:
    return
  let base = buf.len
  buf.setLen(base + src.len)
  copyMem(addr buf[base], unsafeAddr src[0], src.len)

proc scalarAddEscaped(buf: var string, s: string) =
  var runStart = 0
  var i = 0
  while i < s.len:
    let c = s[i]
    if c in Escaped:
      if i > runStart:
        buf.scalarAddChars s.toOpenArray(runStart, i - 1)
      case c
      of '"':  buf.add "\\\""
      of '\\': buf.add "\\\\"
      of '\b': buf.add "\\b"
      of '\f': buf.add "\\f"
      of '\n': buf.add "\\n"
      of '\r': buf.add "\\r"
      of '\t': buf.add "\\t"
      else:
        let o = c.ord
        buf.add "\\u00"
        buf.add Hex[(o shr 4) and 0xF]
        buf.add Hex[o and 0xF]
      runStart = i + 1
    inc i
  if s.len > runStart:
    buf.scalarAddChars s.toOpenArray(runStart, s.len - 1)

# ---------------------------------------------------------------------------
# Deterministic corpus
# ---------------------------------------------------------------------------
var rngState = 0xD1B54A32D192ED03'u64

proc nextRand(): uint64 =
  rngState = rngState * 6364136223846793005'u64 + 1442695040888963407'u64
  rngState

proc makeCorpus(count: int): seq[string] =
  # Vocabulary shaped like the seed feed bodies (single English words).
  const words = [
    "coffee", "definitely", "sometimes", "weekend", "server", "database",
    "branch", "pool", "index", "droplet", "review", "learning", "disk",
    "network", "query", "benchmark", "linux", "debugging", "feature",
    "typescript", "performance", "memory", "cpu", "request", "response",
    "code", "bug", "fix", "test", "deploy", "cache", "thread", "socket"
  ]
  result = newSeqOfCap[string](count)
  for n in 0 ..< count:
    let len = 50 + int(nextRand() mod 151'u64)      # 50 .. 200
    var s = newStringOfCap(len)
    while s.len < len:
      if s.len > 0:
        s.add ' '
      let w = words[int(nextRand() mod uint64(words.len))]
      s.add w
    if s.len > len:
      s.setLen(len)
    # Rare non-clean input (quotes, backslashes, newlines, controls, UTF-8).
    # The real feed corpus has none of these, so keep the density realistic.
    if (n mod 64) == 0:
      let pos = int(nextRand() mod uint64(s.len))
      s[pos] = case (n div 64) mod 6
        of 0: '"'
        of 1: '\\'
        of 2: '\n'
        of 3: '\t'
        of 4: char(0x01)
        else: char(0xFF)
    if (n mod 257) == 0:
      s.add " café ✓"
    result.add s

# ---------------------------------------------------------------------------
# Timing
# ---------------------------------------------------------------------------
proc benchScalar(corpus: seq[string], reps: int): (int64, int) =
  var buf = newStringOfCap(1024)
  var sink = 0
  let t0 = getMonoTime()
  for _ in 0 ..< reps:
    for s in corpus:
      buf.setLen(0)
      buf.scalarAddEscaped s
      sink += buf.len
  let t1 = getMonoTime()
  ((t1 - t0).inNanoseconds, sink)

proc benchSSE2(corpus: seq[string], reps: int): (int64, int) =
  var buf = newStringOfCap(1024)
  var sink = 0
  let t0 = getMonoTime()
  for _ in 0 ..< reps:
    for s in corpus:
      buf.setLen(0)
      addEscaped(buf, s)
      sink += buf.len
  let t1 = getMonoTime()
  ((t1 - t0).inNanoseconds, sink)

proc main() =
  var reps = 400
  if paramCount() >= 1:
    reps = parseInt(paramStr(1))
  let corpus = makeCorpus(2048)
  var totalBytes = 0
  var escapes = 0
  for s in corpus:
    totalBytes += s.len
    for c in s:
      if c in Escaped: inc escapes
  echo "# corpus: ", corpus.len, " strings, ", totalBytes, " bytes, ",
       formatFloat(100.0 * float(escapes) / float(totalBytes), ffDecimal, 2),
       "% escape bytes, avg ", formatFloat(float(totalBytes) / float(corpus.len), ffDecimal, 1), " B"
  echo "# reps: ", reps, " (", totalBytes * reps, " bytes per implementation per round)"

  # Byte-equality guard: timing must compare identical work.
  for idx, s in corpus:
    var a, b: string
    a.scalarAddEscaped s
    addEscaped(b, s)
    doAssert a == b, "byte mismatch at corpus index " & $idx

  # Warm up both implementations.
  discard benchScalar(corpus, 3)
  discard benchSSE2(corpus, 3)

  var bestScalar = high(int64)
  var bestSSE2 = high(int64)
  var sink = 0
  for round in 0 ..< 5:
    # Alternate order so frequency/thermal drift does not systematically favour
    # either implementation.
    let (tScalar, sScalar) = benchScalar(corpus, reps)
    let (tSSE2, sSSE2) = benchSSE2(corpus, reps)
    sink += sScalar + sSSE2
    if tScalar < bestScalar: bestScalar = tScalar
    if tSSE2 < bestSSE2: bestSSE2 = tSSE2
    echo "# round ", round + 1, ": scalar ", tScalar div 1_000_000, " ms, sse2 ",
         tSSE2 div 1_000_000, " ms"

  let calls = float(reps) * float(corpus.len)
  let totalPerRound = float(totalBytes) * float(reps)
  let scalarMBs = totalPerRound * 1000.0 / float(bestScalar)
  let sse2MBs = totalPerRound * 1000.0 / float(bestSSE2)
  let scalarNs = float(bestScalar) / calls
  let sse2Ns = float(bestSSE2) / calls

  echo "scalar: ", formatFloat(scalarMBs, ffDecimal, 1), " MB/s  ",
       formatFloat(scalarNs, ffDecimal, 2), " ns/call"
  echo "sse2  : ", formatFloat(sse2MBs, ffDecimal, 1), " MB/s  ",
       formatFloat(sse2Ns, ffDecimal, 2), " ns/call"
  echo "ratio: ", formatFloat(sse2MBs / scalarMBs, ffDecimal, 2), "x"
  echo "BENCH sink=", sink

main()
