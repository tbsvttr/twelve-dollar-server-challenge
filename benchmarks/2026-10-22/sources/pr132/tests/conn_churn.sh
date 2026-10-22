#!/usr/bin/env bash
# conn_churn.sh - black-box churn test for the pooled output buffer + close path.
#
# The server builds a response in a pooled output buffer and returns it only
# after the SEND has completed in full. This test drives that acquire/release
# cycle through the real socket API:
#
#   1. many keep-alive connections, several pipelined GET /feed requests each,
#      then the same connections are reused for more requests (buffer is taken,
#      released, taken again);
#   2. a burst of connections that pipeline many /feed requests and are then
#      RST-closed mid-flight (close while SENDs are queued - exercises
#      closeConn/maybeFreeSlot and slot reuse, not just the happy path);
#   3. fresh connections after the close storm, again byte-exact (direct-accept
#      slot reuse must hand out a clean Conn with no retained buffer).
#
# Every response's status line and body is checked byte-for-byte against
# test/golden/feed.json. The server must still be healthy and byte-exact at the
# end, with no dispatch errors logged.
#
#   bash tests/conn_churn.sh                 # ~5-15 s
#   PORT=3413 bash tests/conn_churn.sh
#
# Needs: curl, python3, cmp. Never uses `pkill -f`; cleanup is `fuser` + pgrep -P.
set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"          # submissions/nim-io_uring-NioHast
ROOT="$(cd "$DIR/../.." && pwd)"                  # repo root
GOLDEN="$ROOT/test/golden/feed.json"
SEED="$ROOT/seed/feed.db"
BIN="$DIR/bin/server"
PORT="${PORT:-3213}"
HOST="${HOST:-127.0.0.1}"
CONNS="${CHURN_CONNS:-64}"
PIPE="${CHURN_PIPE:-4}"
ROUNDS="${CHURN_ROUNDS:-3}"

for t in curl python3 cmp; do
  command -v "$t" >/dev/null 2>&1 || { echo "missing required tool: $t" >&2; exit 2; }
done
[ -x "$BIN" ]   || { echo "missing binary: $BIN (run: bash build.sh)" >&2; exit 2; }
[ -f "$SEED" ]  || { echo "missing seed: $SEED (run: bash seed/make-seed.sh)" >&2; exit 2; }
[ -f "$GOLDEN" ] || { echo "missing golden: $GOLDEN" >&2; exit 2; }

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

cp "$SEED" "$SQLITE_PATH"
export JWT_SECRET="${JWT_SECRET:-twelve-dollar-challenge}" HOST PORT SQLITE_PATH
bash "$DIR/start.sh" >"$TMP/server.log" 2>&1 &
SRV_PID=$!

up=0
for _ in $(seq 100); do
  if curl -sf "http://$HOST:$PORT/health" >/dev/null 2>&1; then up=1; break; fi
  kill -0 "$SRV_PID" 2>/dev/null || break
  sleep 0.2
done
if [ "$up" != 1 ]; then
  echo "CHURN pass=$pass fail=1"
  echo "server did not become healthy; log:" >&2
  cat "$TMP/server.log" >&2
  exit 1
fi

echo "Churn: $CONNS conns x $PIPE pipelined /feed x $ROUNDS rounds + mid-flight RSTs"
python3 - "$HOST" "$PORT" "$GOLDEN" "$CONNS" "$PIPE" "$ROUNDS" >"$TMP/churn.log" 2>&1 <<'PY'
import socket
import struct
import sys
import time

host = sys.argv[1]
port = int(sys.argv[2])
golden = open(sys.argv[3], "rb").read()
conns = int(sys.argv[4])
pipe = int(sys.argv[5])
rounds = int(sys.argv[6])

REQ = b"GET /feed HTTP/1.1\r\nHost: churn\r\n\r\n"
errors = []
checked = 0
reused = 0
rst_closed = 0


def connect():
    s = socket.create_connection((host, port), timeout=10)
    s.settimeout(10)
    return s


class Reader:
    def __init__(self, s):
        self.s = s
        self.buf = b""

    def fill(self):
        b = self.s.recv(65536)
        if not b:
            raise EOFError("eof")
        self.buf += b

    def response(self):
        while b"\r\n\r\n" not in self.buf:
            self.fill()
        head, self.buf = self.buf.split(b"\r\n\r\n", 1)
        lines = head.split(b"\r\n")
        status = int(lines[0].split()[1])
        hdrs = {}
        for line in lines[1:]:
            k, _, v = line.partition(b":")
            hdrs[k.strip().lower()] = v.strip()
        n = int(hdrs[b"content-length"])
        while len(self.buf) < n:
            self.fill()
        body, self.buf = self.buf[:n], self.buf[n:]
        return status, hdrs, body


def check(where, status, hdrs, body):
    global checked
    checked += 1
    if status != 200:
        errors.append("%s: status %d" % (where, status))
    if body != golden:
        errors.append("%s: body mismatch (%d vs %d bytes)" %
                      (where, len(body), len(golden)))
    if hdrs.get(b"connection", b"").lower() != b"keep-alive":
        errors.append("%s: connection=%r" % (where, hdrs.get(b"connection")))


# 1. keep-alive reuse: pipeline `pipe` requests, drain, then reuse the socket.
for rnd in range(rounds):
    socks = []
    try:
        for i in range(conns):
            s = connect()
            s.sendall(REQ * pipe)
            socks.append((i, s, Reader(s)))
        for i, s, rd in socks:
            for j in range(pipe):
                st, hd, body = rd.response()
                check("round %d conn %d pipelined %d" % (rnd, i, j), st, hd, body)
        for i, s, rd in socks:
            s.sendall(REQ)
            st, hd, body = rd.response()
            check("round %d conn %d reuse" % (rnd, i), st, hd, body)
            reused += 1
    finally:
        for _, s, _ in socks:
            s.close()

# 2. mid-flight RST: pipeline many responses, then reset without reading them.
#    The server has SENDs queued/armed when the close arrives; closeConn must
#    keep the buffer alive until pending hits zero and then release the slot.
burst = 48
rst_socks = []
for i in range(burst):
    s = connect()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
    s.sendall(REQ * 40)
    rst_socks.append(s)
for s in rst_socks:
    s.close()                    # SO_LINGER 0 -> RST
    rst_closed += 1
time.sleep(1.0)

# 3. fresh connections after the RST storm (direct-accept slot reuse).
socks = []
try:
    for i in range(conns):
        s = connect()
        s.sendall(REQ * 2)
        socks.append((i, s, Reader(s)))
    for i, s, rd in socks:
        for j in range(2):
            st, hd, body = rd.response()
            check("post-rst conn %d req %d" % (i, j), st, hd, body)
finally:
    for _, s, _ in socks:
        s.close()

# 4. connection: close still gets the exact body and an EOF.
s = connect()
s.sendall(b"GET /feed HTTP/1.0\r\nHost: churn\r\n\r\n")
rd = Reader(s)
st, hd, body = rd.response()
checked += 1
if st != 200:
    errors.append("http/1.0 close: status %d" % st)
if body != golden:
    errors.append("http/1.0 close: body mismatch")
if hd.get(b"connection", b"").lower() != b"close":
    errors.append("http/1.0 close: connection=%r" % hd.get(b"connection"))
try:
    if s.recv(1) != b"":
        errors.append("http/1.0 close: trailing bytes after body")
except OSError:
    pass                     # RST/ECONNRESET is acceptable after the response
s.close()

print("responses_checked=%d reused=%d rst_closed=%d errors=%d" %
      (checked, reused, rst_closed, len(errors)))
for e in errors[:20]:
    print("ERROR", e)
sys.exit(1 if errors else 0)
PY
client_rc=$?
sed 's/^/        /' "$TMP/churn.log"
if [ "$client_rc" = 0 ]; then
  ok "every response byte-exact across keep-alive reuse, RST churn and reuse"
else
  bad "response mismatch during churn" "client rc=$client_rc"
fi

if kill -0 "$SRV_PID" 2>/dev/null; then
  ok "server process alive after churn"
else
  bad "server process died" "$(tail -20 "$TMP/server.log")"
fi

status="$(curl -s -o "$TMP/health" -w '%{http_code}' "http://$HOST:$PORT/health")"
if [ "$status" = 200 ] && grep -q '"db":"ok"' "$TMP/health"; then
  ok "GET /health after churn (200 $(cat "$TMP/health"))"
else
  bad "GET /health after churn" "status=$status body=$(cat "$TMP/health" 2>/dev/null)"
fi

status="$(curl -s -o "$TMP/feed" -w '%{http_code}' "http://$HOST:$PORT/feed")"
if [ "$status" = 200 ] && cmp -s "$TMP/feed" "$GOLDEN"; then
  ok "GET /feed byte-identical to golden after churn"
else
  bad "GET /feed after churn" "status=$status"
fi

if grep -q "dispatch error" "$TMP/server.log"; then
  bad "server logged a dispatch error" "$(grep 'dispatch error' "$TMP/server.log")"
else
  ok "no dispatch errors logged"
fi

echo "CHURN pass=$pass fail=$fail"
[ "$fail" = 0 ]
