#!/usr/bin/env bash
# recv_cancel_rearm.sh - regression for the pipelined pause/cancel/re-arm path.
#
# The pre-fix bug: `disarmRecv` cleared `recvArmed` when the CANCEL was QUEUED.
# If the blocked SEND then completed (because the client started draining)
# before the older CANCEL's terminal CQE, `onSend` cleared `readPaused` and
# called `armRecv` while the cancelled recv was still in flight. A second
# multishot recv was submitted on the same slot/user_data. `closeConn` could
# cancel only one of them, so `pending` never reached zero, the fixed-file slot
# was pinned, and the peer never saw EOF while it kept its socket open.
#
# This test forces that interleaving with the documented client pattern:
#   * a tiny client SO_RCVBUF (4 KiB) so the server's SEND blocks early,
#   * REQS pipelined GET requests with ~16 KiB /posts/<junk> paths (each gets a
#     small 400), totalling > MaxRequest (1 MiB + 16 KiB + 4),
#   * the client sends the whole burst but deliberately does NOT read for
#     PIPELINE_DELAY, so the server pauses reading and queues the recv CANCEL
#     while the client still has unsent data (the recv is busy, not idle),
#   * the client then drains. The blocked SEND completes and the older CANCEL
#     terminal follows, which is the ordering the pre-fix state machine got
#     wrong,
#   * an HTTP/1.0 close request must produce a 200 with `Connection: close` and
#     then EOF. A pinned slot never closes, so the EOF wait fails.
#
# IOURING_BUFS=256 (2 MiB of 8 KiB buffers) is needed for the pause to be
# reachable at all: the default 64-buffer pool holds 512 KiB, below MaxRequest,
# so a server on the plain defaults would starve on -ENOBUFS first. This is a
# test-only pool override; the shipped server defaults are unchanged.
#
# Run against the fixed tree:
#   bash tests/recv_cancel_rearm.sh                 # ~5 s
#   ROUNDS=8 PORT=3613 bash tests/recv_cancel_rearm.sh
#
# Run against a pre-fix binary built from 38b8f7d / 8a92553 (must FAIL):
#   SERVER_BIN=/tmp/t44-prefix/submissions/nim-io_uring-NioHast/bin/server \
#   REPO=/path/to/twelve-dollar-server-challenge \
#   bash tests/recv_cancel_rearm.sh
#
# Needs: curl, python3. Never uses `pkill -f`; cleanup is `fuser` + pgrep -P.
set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"          # submissions/nim-io_uring-NioHast
ROOT="$(cd "$DIR/../.." && pwd)"                  # repo root
REPO="${REPO:-$ROOT}"                             # tree that owns seed/feed.db
SEED="${SEED:-$REPO/seed/feed.db}"
BIN="${SERVER_BIN:-$DIR/bin/server}"
PORT="${PORT:-3613}"
HOST="${HOST:-127.0.0.1}"
ROUNDS="${ROUNDS:-8}"
REQS="${REQS:-100}"        # 100 * 16,000 B = 1.60 MB > MaxRequest (1,064,964)
REQ_LEN="${REQ_LEN:-16000}"
PIPELINE_DELAY="${PIPELINE_DELAY:-0.2}"
EOF_TIMEOUT="${EOF_TIMEOUT:-3}"
# Test-only: 256 * 8 KiB = 2 MiB pooled recv budget so unprocessed input can
# exceed MaxRequest. The server's own default stays BufRingDefault (64).
IOURING_BUFS="${IOURING_BUFS:-256}"

for t in curl python3; do
  command -v "$t" >/dev/null 2>&1 || { echo "missing required tool: $t" >&2; exit 2; }
done
[ -x "$BIN" ]   || { echo "missing binary: $BIN (run: bash build.sh)" >&2; exit 2; }
[ -f "$SEED" ]  || { echo "missing seed: $SEED (run: bash seed/make-seed.sh)" >&2; exit 2; }

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
export JWT_SECRET="${JWT_SECRET:-twelve-dollar-challenge}" HOST PORT SQLITE_PATH IOURING_BUFS
echo "server binary: $BIN"
echo "Pipelined pause/cancel/re-arm: $ROUNDS rounds x $REQS x $REQ_LEN B paths (> MaxRequest), IOURING_BUFS=$IOURING_BUFS"
"$BIN" >"$TMP/server.log" 2>&1 &
SRV_PID=$!

up=0
for _ in $(seq 100); do
  if curl -sf "http://$HOST:$PORT/health" >/dev/null 2>&1; then up=1; break; fi
  kill -0 "$SRV_PID" 2>/dev/null || break
  sleep 0.2
done
if [ "$up" != 1 ]; then
  echo "RECV_CANCEL pass=$pass fail=1"
  echo "server did not become healthy; log:" >&2
  cat "$TMP/server.log" >&2
  exit 1
fi

python3 - "$HOST" "$PORT" "$ROUNDS" "$REQS" "$REQ_LEN" "$PIPELINE_DELAY" "$EOF_TIMEOUT" >"$TMP/client.log" 2>&1 <<'PY'
import select
import socket
import sys
import threading
import time

host = sys.argv[1]
port = int(sys.argv[2])
rounds = int(sys.argv[3])
reqs = int(sys.argv[4])
req_len = int(sys.argv[5])
pipeline_delay = float(sys.argv[6])
eof_timeout = float(sys.argv[7])

# A syntactically valid request whose path is just under the 16 KiB header cap.
# /posts/<non-digits> yields the small 400 response the pause path needs; the
# request is large, so a 1.6 MB pipeline is only ~100 requests.
PREFIX = b"GET /posts/"
TAIL = b" HTTP/1.1\r\nHost: rc\r\n\r\n"
path_len = req_len - len(PREFIX) - len(TAIL)
REQ = PREFIX + b"a" * path_len + TAIL
assert len(REQ) == req_len, (len(REQ), req_len)
CLOSE = b"GET /health HTTP/1.0\r\nHost: rc\r\n\r\n"


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
        return status, hdrs, body


def connect():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    # Tiny receive window: the server's SEND is blocked while the client
    # pipelines the burst, which is what makes the recv buffer grow past
    # MaxRequest and pauses reading.
    s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
    s.settimeout(30)
    s.connect((host, port))
    return s


def expect_eof(s, deadline):
    while time.time() < deadline:
        r, _, _ = select.select([s], [], [], 0.1)
        if not r:
            continue
        if s.recv(65536) == b"":
            return True
    return False


errors = []
responses = 0
for rnd in range(rounds):
    s = connect()
    rd = Reader(s)
    send_errors = []

    def sender():
        try:
            s.sendall(REQ * reqs)
        except Exception as ex:  # noqa: BLE001 - reported as a test error
            send_errors.append(repr(ex))

    t = threading.Thread(target=sender, daemon=True)
    t.start()
    # Do not read yet: let the server pause its recv and queue the CANCEL while
    # the client still has unsent data, so the recv is busy when the cancel is
    # submitted. Draining then completes the older blocked SEND first.
    time.sleep(pipeline_delay)
    try:
        for i in range(reqs):
            st, _, _ = rd.response()
            if st != 400:
                errors.append("round %d response %d status %d" % (rnd, i, st))
            responses += 1
        t.join(timeout=10)
        if t.is_alive():
            errors.append("round %d sender still blocked" % rnd)
        if send_errors:
            errors.append("round %d sender error %s" % (rnd, send_errors[0]))
        # HTTP/1.0 close: the server must flush the response and close; a
        # pinned recv keeps pending > 0, so maybeFreeSlot never runs.
        s.sendall(CLOSE)
        st, hd, _ = rd.response()
        if st != 200:
            errors.append("round %d close response status %d" % (rnd, st))
        if hd.get(b"connection", b"").lower() != b"close":
            errors.append("round %d close header %r" %
                          (rnd, hd.get(b"connection")))
        if not expect_eof(s, time.time() + eof_timeout):
            errors.append("round %d: no EOF within %.0f s "
                          "(slot not reclaimed / recv still armed)" %
                          (rnd, eof_timeout))
    except Exception as ex:  # noqa: BLE001 - any client failure is a test error
        errors.append("round %d client exception %r" % (rnd, ex))
    finally:
        s.close()

# Fresh connections after the bursts: slots must still be handed out and the
# server must still answer.
s = connect()
rd = Reader(s)
s.sendall(b"GET /health HTTP/1.1\r\nHost: rc\r\n\r\n")
st, _, _ = rd.response()
if st != 200:
    errors.append("post-burst /health status %d" % st)
s.close()

print("responses=%d errors=%d" % (responses, len(errors)))
for e in errors:
    print("ERROR " + e)
sys.exit(0 if not errors else 1)
PY
rc=$?
cat "$TMP/client.log"
if [ "$rc" = 0 ]; then
  ok "every >MaxRequest pause/cancel burst closes (EOF) after draining"
else
  bad "pause/cancel burst did not reclaim the connection" "client rc=$rc"
fi

if kill -0 "$SRV_PID" 2>/dev/null; then
  ok "server process alive after pause/cancel bursts"
else
  bad "server process exited"
fi

H=$(curl -sf "http://$HOST:$PORT/health" || true)
if [ -n "$H" ]; then
  ok "GET /health after bursts (200)"
else
  bad "GET /health after bursts"
fi

if grep -qiE "dispatch error|SQ full|unusable slot|request handler error" "$TMP/server.log"; then
  bad "dispatch errors logged" "$(grep -iE 'dispatch error|SQ full|unusable slot|request handler error' "$TMP/server.log" | head -3)"
else
  ok "no dispatch errors logged"
fi

echo "RECV_CANCEL pass=$pass fail=$fail"
[ "$fail" = 0 ]
