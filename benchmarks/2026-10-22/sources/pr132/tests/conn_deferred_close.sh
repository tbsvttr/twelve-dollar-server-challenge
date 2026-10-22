#!/usr/bin/env bash
# conn_deferred_close.sh - black-box regression test for the deferred-SEND close path.
#
# With group commit enabled (the default) a write response produced inside a
# pass is withheld: the SEND is deferred until the pass's COMMIT succeeds (see
# armSendOrDefer / flushDeferredSlots in src/server.nim). This test drives that
# path through the real socket API:
#
#   1. pipeline a `POST /posts` (valid HS256 JWT, Content-Length + JSON body)
#      and a `GET /feed` in ONE write on several fresh connections. The POST
#      opens the pass's write batch, so both responses are buffered and the SEND
#      is deferred until the end-of-pass commit;
#   2. never read from those sockets, wait briefly for the pass to commit and
#      arm the SEND, then close them with SO_LINGER 0 (RST) while the response
#      is queued/in flight - the deferred/close interaction;
#   3. verify the process is still alive, `/health` and a normal `/feed` still
#      return 200, and a fresh pipelined write+read still works (the deferred
#      path must arm only after commit, never send or crash early).
#
# The old hazard: onTimeout's -ENOBUFS retry loop re-armed a SEND for a slot
# whose response was deferred, so flushDeferredSlots could then rewrite the
# buffer (setLen + addResponse(500)) while the SQE still held its address.
# This test fails if the server dies or stops serving after the close storm.
#
#   bash tests/conn_deferred_close.sh             # ~3-5 s
#   PORT=3428 bash tests/conn_deferred_close.sh
#
# Needs: curl, python3, jq, openssl, cmp. Never uses `pkill -f`; cleanup is
# `fuser` + pgrep -P.
set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"          # submissions/nim-io_uring-NioHast
ROOT="$(cd "$DIR/../.." && pwd)"                  # repo root
GOLDEN="$ROOT/test/golden/feed.json"
SEED="$ROOT/seed/feed.db"
BIN="$DIR/bin/server"
PORT="${PORT:-3428}"
HOST="${HOST:-127.0.0.1}"
JWT_SECRET="${JWT_SECRET:-twelve-dollar-challenge}"
USER_ID=1; USER_NAME=golden_ember_1               # user 1 in the seed
CONNS="${DEFERRED_CONNS:-8}"

for t in curl python3 jq openssl cmp; do
  command -v "$t" >/dev/null 2>&1 || { echo "missing required tool: $t" >&2; exit 2; }
done
[ -x "$BIN" ]    || { echo "missing binary: $BIN (run: bash build.sh)" >&2; exit 2; }
[ -f "$SEED" ]   || { echo "missing seed: $SEED (run: bash seed/make-seed.sh)" >&2; exit 2; }
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

# b64url/sign - identical to test/test.sh and tests/feed_equality.sh.
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
sign() {
  local h p s
  h="$(printf '%s' '{"alg":"HS256","typ":"JWT"}' | b64url)"
  p="$(printf '%s' "$1" | b64url)"
  s="$(printf '%s' "$h.$p" | openssl dgst -sha256 -hmac "$JWT_SECRET" -binary | b64url)"
  echo "$h.$p.$s"
}
now=$(date +%s)
TOKEN="$(sign "{\"sub\":\"$USER_ID\",\"username\":\"$USER_NAME\",\"iat\":$now,\"exp\":$((now+3600))}")"
AUTH="Bearer $TOKEN"

# Group commit must be on (default) for the deferred path to exist.
export GROUP_COMMIT="${GROUP_COMMIT:-1}"

cp "$SEED" "$SQLITE_PATH"
export JWT_SECRET HOST PORT SQLITE_PATH
bash "$DIR/start.sh" >"$TMP/server.log" 2>&1 &
SRV_PID=$!

up=0
for _ in $(seq 100); do
  if curl -sf "http://$HOST:$PORT/health" >/dev/null 2>&1; then up=1; break; fi
  kill -0 "$SRV_PID" 2>/dev/null || break
  sleep 0.2
done
if [ "$up" != 1 ]; then
  echo "DEFERRED_CLOSE pass=$pass fail=1"
  echo "server did not become healthy; log:" >&2
  cat "$TMP/server.log" >&2
  exit 1
fi

echo "Deferred close: $CONNS pipelined POST+GET connections, no reads, then RST"
python3 - "$HOST" "$PORT" "$AUTH" "$CONNS" >"$TMP/deferred.log" 2>&1 <<'PY'
import json
import socket
import struct
import sys
import time

host = sys.argv[1]
port = int(sys.argv[2])
auth = sys.argv[3]
conns = int(sys.argv[4])

bodies = ["deferred-close-%d" % i for i in range(conns)]
errors = []


def connect():
    s = socket.create_connection((host, port), timeout=10)
    s.settimeout(10)
    return s


def write_batch(s, body):
    raw = json.dumps({"body": body}).encode()
    req = (b"POST /posts HTTP/1.1\r\n"
           b"Host: deferred\r\n"
           b"Authorization: " + auth.encode() + b"\r\n"
           b"Content-Type: application/json\r\n"
           b"Content-Length: " + str(len(raw)).encode() + b"\r\n"
           b"\r\n" + raw +
           b"GET /feed HTTP/1.1\r\n"
           b"Host: deferred\r\n"
           b"\r\n")
    # One write: the POST opens the pass's write batch and the GET response is
    # appended while that batch is open, so the SEND must be deferred.
    s.sendall(req)


def rst(s):
    s.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
    s.close()


socks = []
try:
    for body in bodies:
        s = connect()
        write_batch(s, body)
        socks.append(s)
    # Give the server time to read both pipelined requests, commit the batch and
    # arm the deferred SEND; we deliberately do not read the responses.
    time.sleep(0.8)
finally:
    for s in socks:
        rst(s)

# Allow the close completions and the sweep to run before probing the server.
time.sleep(0.5)
print("rst_closed=%d" % len(socks))
for e in errors[:20]:
    print("ERROR", e)
sys.exit(1 if errors else 0)
PY
client_rc=$?
sed 's/^/        /' "$TMP/deferred.log"
if [ "$client_rc" = 0 ]; then
  ok "pipelined write+read deferred and RST-closed without client errors"
else
  bad "deferred-close client failed" "rc=$client_rc"
fi

if kill -0 "$SRV_PID" 2>/dev/null; then
  ok "server process alive after deferred RST closes"
else
  bad "server process died" "$(tail -20 "$TMP/server.log")"
fi

status="$(curl -s -o "$TMP/health" -w '%{http_code}' "http://$HOST:$PORT/health")"
if [ "$status" = 200 ] && grep -q '"db":"ok"' "$TMP/health"; then
  ok "GET /health after deferred closes (200 $(cat "$TMP/health"))"
else
  bad "GET /health after deferred closes" "status=$status body=$(cat "$TMP/health" 2>/dev/null)"
fi

status="$(curl -s -o "$TMP/feed" -w '%{http_code}' "http://$HOST:$PORT/feed")"
posts="$(jq '.posts | length' "$TMP/feed" 2>/dev/null)"
top="$(jq -r '.posts[0].body' "$TMP/feed" 2>/dev/null)"
if [ "$status" = 200 ] && [ -n "$posts" ] && [ "$posts" -ge 20 ] &&
   [[ "$top" == deferred-close-* ]]; then
  ok "GET /feed after deferred closes (200, $posts posts, top '$top')"
else
  bad "GET /feed after deferred closes" "status=$status posts=$posts top='$top' body=$(head -c 200 "$TMP/feed" 2>/dev/null)"
fi

# A fresh connection must still complete the deferred write+read path and see
# the committed response, with the new post at the top of the feed.
python3 - "$HOST" "$PORT" "$AUTH" >"$TMP/after.log" 2>&1 <<'PY'
import json
import socket
import sys

host = sys.argv[1]
port = int(sys.argv[2])
auth = sys.argv[3]
raw = json.dumps({"body": "deferred-close-after"}).encode()
req = (b"POST /posts HTTP/1.1\r\n"
       b"Host: deferred\r\n"
       b"Authorization: " + auth.encode() + b"\r\n"
       b"Content-Type: application/json\r\n"
       b"Content-Length: " + str(len(raw)).encode() + b"\r\n"
       b"\r\n" + raw +
       b"GET /feed HTTP/1.1\r\n"
       b"Host: deferred\r\n"
       b"\r\n")

s = socket.create_connection((host, port), timeout=10)
s.settimeout(10)
s.sendall(req)
buf = b""


def response():
    global buf
    while b"\r\n\r\n" not in buf:
        b = s.recv(65536)
        if not b:
            raise EOFError("eof")
        buf += b
    head, buf = buf.split(b"\r\n\r\n", 1)
    lines = head.split(b"\r\n")
    status = int(lines[0].split()[1])
    hdrs = {}
    for line in lines[1:]:
        k, _, v = line.partition(b":")
        hdrs[k.strip().lower()] = v.strip()
    n = int(hdrs[b"content-length"])
    while len(buf) < n:
        b = s.recv(65536)
        if not b:
            raise EOFError("eof")
        buf += b
    body, buf = buf[:n], buf[n:]
    return status, body


st1, _ = response()
st2, feed = response()
s.close()
top = json.loads(feed)["posts"][0]["body"]
if st1 != 201:
    print("ERROR create status", st1)
if st2 != 200:
    print("ERROR feed status", st2)
if top != "deferred-close-after":
    print("ERROR top of feed", repr(top))
print("create=%d feed=%d top=%r" % (st1, st2, top))
sys.exit(0 if st1 == 201 and st2 == 200 and top == "deferred-close-after" else 1)
PY
after_rc=$?
sed 's/^/        /' "$TMP/after.log"
if [ "$after_rc" = 0 ]; then
  ok "fresh pipelined POST+GET still returns 201 then 200 after commit"
else
  bad "fresh pipelined POST+GET after deferred closes" "rc=$after_rc"
fi

if grep -q "dispatch error" "$TMP/server.log"; then
  bad "server logged a dispatch error" "$(grep 'dispatch error' "$TMP/server.log")"
else
  ok "no dispatch errors logged"
fi

echo "DEFERRED_CLOSE pass=$pass fail=$fail"
[ "$fail" = 0 ]
