#!/usr/bin/env bash
# zerocopy_direct.sh - receive-path lifecycle checks for direct provided-buffer
# parsing.
#
# The server parses complete requests straight from the kernel's provided
# receive buffer and returns that buffer only after every response has been
# appended to the connection output buffer. Input is copied into Conn.inbuf only
# when a request is incomplete (or when an in-flight SEND means parsing must
# wait). This test drives the real socket path and reads the diagnostic
# counters that the server logs once per second when ZEROCOPY_STATS=1:
#
#   direct_requests  complete requests served from a receive buffer in place
#   copied_buffers   receive buffers copied into Conn.inbuf
#
# Scenarios:
#   1. one complete request wholly inside one receive buffer
#   2. one request split across two receive buffers
#   3. two pipelined complete requests in one buffer
#   4. a split request followed by a pipelined complete request
#   5. a partial request followed by close (no response, then EOF)
#   6. a complete request plus a partial tail in one buffer (counter split)
#
#   bash tests/zerocopy_direct.sh
#   PORT=3633 bash tests/zerocopy_direct.sh
#
# Needs: curl, python3. Never uses `pkill -f`; cleanup is `fuser` + pgrep -P.
set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
SEED="$ROOT/seed/feed.db"
BIN="$DIR/bin/server"
PORT="${PORT:-3633}"
HOST="${HOST:-127.0.0.1}"

for t in curl python3; do
  command -v "$t" >/dev/null 2>&1 || { echo "missing required tool: $t" >&2; exit 2; }
done
[ -x "$BIN" ]  || { echo "missing binary: $BIN (run: bash build.sh)" >&2; exit 2; }
[ -f "$SEED" ] || { echo "missing seed: $SEED (run: bash seed/make-seed.sh)" >&2; exit 2; }

TMP="$(mktemp -d)"
SQLITE_PATH="$TMP/feed.db"
SRV_PID=""

cleanup() {
  if [ -n "$SRV_PID" ]; then
    for c in $(pgrep -P "$SRV_PID" 2>/dev/null || true); do kill "$c" 2>/dev/null || true; done
    kill "$SRV_PID" 2>/dev/null || true
  fi
  fuser -k -TERM "${PORT}/tcp" >/dev/null 2>&1 || true
  sleep 0.2
  fuser -k "${PORT}/tcp" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

pass=0; fail=0
ok()  { echo "  ok    $1"; pass=$((pass+1)); }
bad() { echo "  FAIL  $1"; [ -n "${2:-}" ] && echo "        $2"; fail=$((fail+1)); }

cat >"$TMP/client.py" <<'PY'
import socket
import sys
import time

host, port, scenario = sys.argv[1], int(sys.argv[2]), sys.argv[3]
GET = b"GET /health HTTP/1.1\r\nHost: z\r\n\r\n"


class Reader:
    def __init__(self, s):
        self.s = s
        self.buf = b""

    def response(self):
        while b"\r\n\r\n" not in self.buf:
            b = self.s.recv(65536)
            if not b:
                raise EOFError("eof before response")
            self.buf += b
        head, self.buf = self.buf.split(b"\r\n\r\n", 1)
        lines = head.split(b"\r\n")
        status = int(lines[0].split()[1])
        hdrs = {}
        for line in lines[1:]:
            k, _, v = line.partition(b":")
            hdrs[k.strip().lower()] = v.strip()
        n = int(hdrs[b"content-length"])
        while len(self.buf) < n:
            b = self.s.recv(65536)
            if not b:
                raise EOFError("eof mid-body")
            self.buf += b
        body, self.buf = self.buf[:n], self.buf[n:]
        return status, body


def connect():
    s = socket.create_connection((host, port), timeout=5)
    s.settimeout(5)
    return s


def expect_status(r, want, tag):
    status, body = r.response()
    if status != want:
        raise SystemExit("%s: want %d, got %d (%r)" % (tag, want, status, body[:80]))


if scenario == "complete":
    s = connect()
    s.sendall(GET)
    expect_status(Reader(s), 200, "complete")
    s.close()
elif scenario == "split":
    s = connect()
    s.sendall(b"GET /hea")
    time.sleep(0.25)
    s.sendall(b"lth HTTP/1.1\r\nHost: z\r\n\r\n")
    expect_status(Reader(s), 200, "split")
    s.close()
elif scenario == "pipeline":
    s = connect()
    s.sendall(GET + GET)
    r = Reader(s)
    expect_status(r, 200, "pipeline first")
    expect_status(r, 200, "pipeline second")
    s.close()
elif scenario == "split_pipeline":
    s = connect()
    s.sendall(b"GET /health HTT")
    time.sleep(0.25)
    s.sendall(b"P/1.1\r\nHost: z\r\n\r\n" + GET)
    r = Reader(s)
    expect_status(r, 200, "split_pipeline first")
    expect_status(r, 200, "split_pipeline second")
    s.close()
elif scenario == "partial_close":
    s = connect()
    s.sendall(b"GET /health HTTP/1.1\r\nHost: z\r\n")
    time.sleep(0.25)
    s.shutdown(socket.SHUT_WR)
    got = b""
    while True:
        b = s.recv(65536)
        if not b:
            break
        got += b
    if got:
        raise SystemExit("partial_close: got bytes for an incomplete request: %r" % got[:80])
    s.close()
elif scenario == "complete_plus_partial":
    s = connect()
    s.sendall(GET + b"GET /hea")
    r = Reader(s)
    expect_status(r, 200, "complete_plus_partial first")
    s.sendall(b"lth HTTP/1.1\r\nHost: z\r\n\r\n")
    expect_status(r, 200, "complete_plus_partial second")
    s.close()
else:
    raise SystemExit("unknown scenario " + scenario)
PY

cp "$SEED" "$SQLITE_PATH"
export JWT_SECRET="${JWT_SECRET:-twelve-dollar-challenge}" HOST PORT SQLITE_PATH
export ZEROCOPY_STATS=1
bash "$DIR/start.sh" >"$TMP/server.log" 2>&1 &
SRV_PID=$!

up=0
for _ in $(seq 100); do
  if curl -sf "http://$HOST:$PORT/health" >/dev/null 2>&1; then up=1; break; fi
  kill -0 "$SRV_PID" 2>/dev/null || break
  sleep 0.1
done
if [ "$up" != 1 ]; then
  echo "ZEROCOPY_DIRECT pass=0 fail=1"
  echo "server did not become healthy; log:" >&2
  cat "$TMP/server.log" >&2
  exit 1
fi

# Snapshot the cumulative counters. The tick is 1 s, so 1.25 s guarantees a
# fresh line reflecting everything that happened before the call.
read_stats() {
  local line d c
  line="$(grep -o 'direct_requests=[0-9]* copied_buffers=[0-9]*' "$TMP/server.log" | tail -1)"
  [ -n "$line" ] || { echo "0 0"; return; }
  d="${line#*direct_requests=}"; d="${d%% *}"
  c="${line#*copied_buffers=}"; c="${c%% *}"
  echo "$d $c"
}
snapshot() { sleep 1.25; read_stats; }

run_case() {
  local name="$1" expect_direct="$2" expect_copied="$3" d0 c0 d1 c1 dd dc
  read -r d0 c0 <<<"$(read_stats)"
  if ! python3 "$TMP/client.py" "$HOST" "$PORT" "$name"; then
    bad "$name client"
    return
  fi
  read -r d1 c1 <<<"$(snapshot)"
  dd=$((d1 - d0)); dc=$((c1 - c0))
  if [ "$expect_direct" = "any" ] && [ "$dd" -lt 1 ]; then
    bad "$name direct counter" "delta=$dd want >=1"
  elif [ "$expect_direct" != "any" ] && [ "$dd" -ne "$expect_direct" ]; then
    bad "$name direct counter" "delta=$dd want $expect_direct"
  else
    ok "$name direct counter delta=$dd"
  fi
  if [ "$expect_copied" = "any" ] && [ "$dc" -lt 1 ]; then
    bad "$name copied counter" "delta=$dc want >=1"
  elif [ "$expect_copied" != "any" ] && [ "$dc" -ne "$expect_copied" ]; then
    bad "$name copied counter" "delta=$dc want $expect_copied"
  else
    ok "$name copied counter delta=$dc"
  fi
}

# Wait for the first stats tick, then take a baseline so startup health traffic
# is not attributed to the first scenario.
for _ in $(seq 40); do
  grep -q 'zerocopy stats:' "$TMP/server.log" && break
  sleep 0.1
done
snapshot >/dev/null

echo "Zero-copy receive path: direct provided-buffer parsing and partial carry"
run_case complete 1 0
run_case split 0 2
run_case pipeline 2 0
run_case split_pipeline 0 2
run_case partial_close 0 1
run_case complete_plus_partial 1 2

health="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://$HOST:$PORT/health" 2>/dev/null || true)"
if [ "$health" = 200 ]; then ok "server healthy after partial close"; else bad "health after partial close" "got $health"; fi

echo "ZEROCOPY_DIRECT pass=$pass fail=$fail"
[ "$fail" = 0 ]
