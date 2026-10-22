#!/usr/bin/env bash
# conn_lifetime_soak.sh - regression soak for the closeConn buffer/slot lifetime.
#
# Opens several connections, pipelines enough GET /feed requests that the
# responses cannot fit in the client receive buffer plus the kernel send buffer,
# and then stops reading. The server's SEND stays armed until the idle/stall
# sweep closes the connection after StallTimeout (30 s). The close path must:
#   * keep outbuf alive until the cancelled SEND has completed (R1), and
#   * keep the fixed-file slot off the free list / kernel allocator until
#     pending == 0 (R2, R3).
# After the stall the server must still be alive and serving normal requests on
# fresh connections.
#
#   bash tests/conn_lifetime_soak.sh            # ~55 s
#   PORT=3212 bash tests/conn_lifetime_soak.sh
#
# Needs: curl, python3, cmp. Never uses `pkill -f`; cleanup is `fuser` + pgrep -P.
set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"          # submissions/nim-io_uring-NioHast
ROOT="$(cd "$DIR/../.." && pwd)"                  # repo root
GOLDEN="$ROOT/test/golden/feed.json"
SEED="$ROOT/seed/feed.db"
BIN="$DIR/bin/server"
PORT="${PORT:-3211}"
HOST="${HOST:-127.0.0.1}"
CONNS="${STALL_CONNS:-4}"
REQS="${STALL_REQS:-3000}"
# StallTimeout is 30 s and the sweep runs on the 1 s tick; wait generously so the
# close has certainly happened before probing.
SETTLE="${STALL_SETTLE:-48}"

for t in curl python3 cmp; do
  command -v "$t" >/dev/null 2>&1 || { echo "missing required tool: $t" >&2; exit 2; }
done
[ -x "$BIN" ]   || { echo "missing binary: $BIN (run: bash build.sh)" >&2; exit 2; }
[ -f "$SEED" ]  || { echo "missing seed: $SEED (run: bash seed/make-seed.sh)" >&2; exit 2; }
[ -f "$GOLDEN" ] || { echo "missing golden: $GOLDEN" >&2; exit 2; }

TMP="$(mktemp -d)"
SQLITE_PATH="$TMP/feed.db"
SRV_PID=""
CLIENT_PID=""

cleanup() {
  [ -n "$CLIENT_PID" ] && kill "$CLIENT_PID" 2>/dev/null || true
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
  echo "SOAK pass=$pass fail=1"
  echo "server did not become healthy; log:" >&2
  cat "$TMP/server.log" >&2
  exit 1
fi

echo "Stalling $CONNS readers with $REQS pipelined /feed requests each (~$SETTLE s)"
python3 - "$HOST" "$PORT" "$CONNS" "$REQS" "$SETTLE" >"$TMP/stall.log" 2>&1 <<'PY' &
import select
import socket
import sys
import time

host = sys.argv[1]
port = int(sys.argv[2])
conns = int(sys.argv[3])
reqs = int(sys.argv[4])
settle = float(sys.argv[5])

# ~5 KiB per /feed response bytes, far more than the socket buffers can hold, so
# the server's SEND stays armed once the client stops reading.
pipeline = b"GET /feed HTTP/1.1\r\nHost: soak\r\n\r\n" * reqs
socks = []
for _ in range(conns):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
    s.connect((host, port))
    s.sendall(pipeline)
    socks.append(s)

time.sleep(settle)

# With the server close complete, the orphaned socket flushes whatever is still
# queued in the kernel send buffer before the FIN; drain until EOF, or until the
# connection goes idle after delivering the whole (finite) response pipeline.
# A connection the sweep missed keeps the pipeline going and then idles WITHOUT
# an EOF, so it is reported as open.
closed = 0
for i, s in enumerate(socks):
    s.setblocking(False)
    total = 0
    eof = False
    deadline = time.time() + 20.0
    while time.time() < deadline and total < 24 * 1024 * 1024:
        r, _, _ = select.select([s], [], [], 1.0)
        if not r:
            break                     # idle: not closed (or fully drained)
        try:
            b = s.recv(65536)
        except OSError:
            eof = True
            break
        if not b:
            eof = True
            break
        total += len(b)
    print("conn %d: eof=%s drained=%d" % (i, eof, total))
    if eof:
        closed += 1
    s.close()

print("closed %d/%d stalled connections" % (closed, conns))
sys.exit(0 if closed == conns else 1)
PY
CLIENT_PID=$!

sleep 2
if kill -0 "$CLIENT_PID" 2>/dev/null; then
  ok "stalled readers connected and idle"
else
  bad "stalled readers died before the stall window" "$(cat "$TMP/stall.log")"
fi

wait "$CLIENT_PID"; client_rc=$?
CLIENT_PID=""
sed 's/^/        /' "$TMP/stall.log"
if [ "$client_rc" = 0 ]; then
  ok "server closed every stalled connection"
else
  bad "a stalled connection survived the sweep" "client rc=$client_rc"
fi

if kill -0 "$SRV_PID" 2>/dev/null; then
  ok "server process alive after close storm"
else
  bad "server process died" "$(tail -20 "$TMP/server.log")"
fi

status="$(curl -s -o "$TMP/health" -w '%{http_code}' "http://$HOST:$PORT/health")"
if [ "$status" = 200 ] && grep -q '"db":"ok"' "$TMP/health"; then
  ok "GET /health after close (200 $(cat "$TMP/health"))"
else
  bad "GET /health after close" "status=$status body=$(cat "$TMP/health" 2>/dev/null)"
fi

status="$(curl -s -o "$TMP/feed" -w '%{http_code}' "http://$HOST:$PORT/feed")"
if [ "$status" = 200 ] && cmp -s "$TMP/feed" "$GOLDEN"; then
  ok "GET /feed byte-identical to golden after close"
else
  bad "GET /feed after close" "status=$status"
fi

if grep -q "dispatch error" "$TMP/server.log"; then
  bad "server logged a dispatch error" "$(grep 'dispatch error' "$TMP/server.log")"
else
  ok "no dispatch errors logged"
fi

echo "SOAK pass=$pass fail=$fail"
[ "$fail" = 0 ]
