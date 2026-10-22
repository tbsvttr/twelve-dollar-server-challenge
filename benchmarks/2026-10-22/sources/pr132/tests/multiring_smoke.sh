#!/usr/bin/env bash
# multiring_smoke.sh - regression test for the N>1 completion-wake path and the
# multi-ring mixed write path.
#
# Part 1 (feed load): with more than one ring the request thread waits on one
# shared eventfd (IORING_REGISTER_EVENTFD on every ring) in epoll_wait. If the
# rings are created with IORING_SETUP_DEFER_TASKRUN, the completion that should
# signal that eventfd is parked as task work until an io_uring_enter - and
# nothing enters while the loop is asleep. The loop then drains a small burst
# and hangs in do_epoll_wait forever (measured: ~60-124 requests, no per-ring
# tick logs, /health hangs). This test drives that exact low-load case:
#
#   NIM_RINGS=5 NIM_SLOTS_PER_RING=16384, 500 keep-alive connections,
#   2000 req/s for 10 s, feed mode. A working multi-ring loop completes
#   ~20k requests and stays healthy; the DEFER_TASKRUN stall completes only a
#   few hundred and /health times out. Assert completed > MIN_COMPLETED,
#   errors total=0, then /health returns 200.
#
# Part 2 (mixed write): on the SAME server and fresh DB, pipeline one
# authenticated `POST /posts` and one `GET /feed` in a single socket write.
# Both requests are processed in one multi-ring pass (the write opens the shared
# group-commit batch and the GET joins it), so this must return 201 and 200,
# show the new post at the top of the feed, and leave the row PERSISTED in
# SQLite after the responses arrive. This is the mixed write/read coverage the
# old feed-only smoke lacked.
#
#   LOADGEN=/path/to/loadgen bash tests/multiring_smoke.sh   # ~15 s
#   PORT=3490 LOADGEN=/path/to/loadgen bash tests/multiring_smoke.sh
#   RINGS=2 LOADGEN=/path/to/loadgen bash tests/multiring_smoke.sh  # other count
#
# Needs: curl, python3, openssl, awk. Never uses `pkill -f`; cleanup is
# pgrep -P + fuser.
set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"          # submissions/nim-io_uring-NioHast
ROOT="$(cd "$DIR/../.." && pwd)"                  # repo root
BIN="$DIR/bin/server"
SEED="$ROOT/seed/feed.db"
LOADGEN="${LOADGEN:-}"
PORT="${PORT:-3489}"
HOST="${HOST:-127.0.0.1}"
RINGS="${RINGS:-5}"
SLOTS="${SLOTS:-16384}"
CONNS="${CONNS:-500}"
RATE="${RATE:-2000}"
DURATION="${DURATION:-10}"
MIN_COMPLETED="${MIN_COMPLETED:-5000}"

for t in curl python3 openssl awk; do
  command -v "$t" >/dev/null 2>&1 || { echo "missing required tool: $t" >&2; exit 2; }
done
[ -x "$BIN" ]     || { echo "missing binary: $BIN (run: bash build.sh)" >&2; exit 2; }
[ -f "$SEED" ]    || { echo "missing seed: $SEED (run: bash seed/make-seed.sh)" >&2; exit 2; }
[ -n "$LOADGEN" ] || { echo "LOADGEN is unset; set LOADGEN=/path/to/loadgen" >&2; exit 2; }
[ -x "$LOADGEN" ] || { echo "loadgen is not executable: $LOADGEN" >&2; exit 2; }

TMP="$(mktemp -d)"
SQLITE_PATH="$TMP/feed.db"
SRV_PID=""
LG_PID=""

cleanup() {
  [ -n "$LG_PID" ] && kill "$LG_PID" 2>/dev/null
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

# loadgen always needs a token file even for feed mode; sign one valid HS256
# token exactly like test/test.sh does (the seed token file is not in the repo).
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
now=$(date +%s)
hdr="$(printf '%s' '{"alg":"HS256","typ":"JWT"}' | b64url)"
pld="$(printf '%s' "{\"sub\":\"1\",\"username\":\"golden_ember_1\",\"iat\":$now,\"exp\":$((now+3600))}" | b64url)"
sig="$(printf '%s' "$hdr.$pld" | openssl dgst -sha256 -hmac "${JWT_SECRET:-twelve-dollar-challenge}" -binary | b64url)"
printf '%s.%s.%s\n' "$hdr" "$pld" "$sig" > "$TMP/tokens.txt"

cp "$SEED" "$SQLITE_PATH"
export JWT_SECRET="${JWT_SECRET:-twelve-dollar-challenge}" HOST PORT SQLITE_PATH
export NIM_RINGS="$RINGS" NIM_SLOTS_PER_RING="$SLOTS"
bash "$DIR/start.sh" >"$TMP/server.log" 2>&1 &
SRV_PID=$!

up=0
for _ in $(seq 100); do
  if curl -sf --max-time 1 "http://$HOST:$PORT/health" >/dev/null 2>&1; then up=1; break; fi
  kill -0 "$SRV_PID" 2>/dev/null || break
  sleep 0.1
done
if [ "$up" != 1 ]; then
  echo "MULTIRING pass=0 fail=1"
  echo "server did not become healthy; log:" >&2
  cat "$TMP/server.log" >&2
  exit 1
fi

# ---- part 1: feed load ----------------------------------------------------
echo "Multi-ring feed: rings=$RINGS conns=$CONNS rate=$RATE dur=${DURATION}s mode=feed"
"$LOADGEN" -H "$HOST" -p "$PORT" -c "$CONNS" -r "$RATE" -d "$DURATION" \
  -m feed -T "$TMP/tokens.txt" >"$TMP/lg.out" 2>&1 &
LG_PID=$!
wait "$LG_PID"; LG_RC=$?
LG_PID=

completed="$(grep -o 'completed=[0-9]*' "$TMP/lg.out" | tail -1 | cut -d= -f2)"
completed="${completed:-0}"
errors="$(awk '/^errors[[:space:]]/ {for (i=1;i<=NF;i++) if ($i ~ /^total=/) {sub("total=","",$i); print $i; exit}}' "$TMP/lg.out")"
errors="${errors:-missing}"
health="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 \
          "http://$HOST:$PORT/health" 2>/dev/null || true)"
health="${health:-000}"

if [ "$LG_RC" -ne 0 ]; then
  bad "feed loadgen rc=$LG_RC"
  sed 's/^/        /' "$TMP/lg.out"
else
  ok "feed loadgen exited 0"
fi
if [ "$completed" -gt "$MIN_COMPLETED" ] 2>/dev/null; then
  ok "feed completed=$completed (> $MIN_COMPLETED)"
else
  bad "feed completed=$completed (want > $MIN_COMPLETED; multi-ring wake stalled)"
fi
if [ "$errors" = 0 ]; then
  ok "feed loadgen errors total=0"
else
  bad "feed loadgen errors total=$errors"
fi
if [ "$health" = 200 ]; then
  ok "feed /health -> 200 after the run"
else
  bad "feed /health -> $health after the run (want 200)"
fi

# ---- part 2: pipelined mixed write + read ---------------------------------
echo "Multi-ring mixed: pipelined POST /posts + GET /feed on one connection"
PROBE="multiring-mixed-$$-$now"
if python3 - "$HOST" "$PORT" "$TMP/tokens.txt" "$PROBE" "$SQLITE_PATH" \
     >"$TMP/mixed.log" 2>&1 <<'PY'
import json
import socket
import sqlite3
import sys

host, port, tokenfile, probe, dbpath = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5]
token = open(tokenfile, "rb").read().strip()

body = json.dumps({"body": probe}, separators=(",", ":")).encode()
post = (b"POST /posts HTTP/1.1\r\nHost: mixed\r\n"
        b"Authorization: Bearer " + token + b"\r\n"
        b"Content-Type: application/json\r\n"
        b"Content-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body)
feed = b"GET /feed HTTP/1.1\r\nHost: mixed\r\n\r\n"

s = socket.create_connection((host, port), timeout=10)
s.settimeout(10)
s.sendall(post + feed)
buf = b""


def response():
    global buf
    while b"\r\n\r\n" not in buf:
        chunk = s.recv(65536)
        if not chunk:
            raise EOFError("connection closed before the response head")
        buf += chunk
    head, buf = buf.split(b"\r\n\r\n", 1)
    lines = head.split(b"\r\n")
    status = int(lines[0].split()[1])
    hdrs = {}
    for line in lines[1:]:
        k, _, v = line.partition(b":")
        hdrs[k.strip().lower()] = v.strip()
    n = int(hdrs[b"content-length"])
    while len(buf) < n:
        chunk = s.recv(65536)
        if not chunk:
            raise EOFError("connection closed before the response body")
        buf += chunk
    b, buf = buf[:n], buf[n:]
    return status, b


st_post, post_body = response()
st_feed, feed_body = response()
s.close()

assert st_post == 201, "POST status %d (want 201): %r" % (st_post, post_body[:200])
assert st_feed == 200, "GET /feed status %d (want 200): %r" % (st_feed, feed_body[:200])

created = json.loads(post_body)["post"]
assert created["body"] == probe, "created body %r != %r" % (created["body"], probe)
pid = created["id"]
assert isinstance(pid, int) and pid > 0, "created id %r" % (pid,)

parsed = json.loads(feed_body)
posts = parsed["posts"]
assert posts, "feed is empty"
assert posts[0]["id"] == pid, "feed top id %r != created id %r" % (posts[0]["id"], pid)
assert posts[0]["body"] == probe, "feed top body %r != %r" % (posts[0]["body"], probe)

# The response is only sent after the pass COMMIT, so the row must be on disk.
con = sqlite3.connect(dbpath, timeout=10)
n = con.execute("SELECT count(*) FROM posts WHERE id = ? AND body = ?", (pid, probe)).fetchone()[0]
con.close()
assert n == 1, "persisted row count %d (want 1)" % n

print("created_id=%d feed_top_id=%d persisted=%d" % (pid, posts[0]["id"], n))
PY
then
  ok "pipelined POST/feed -> 201/200, top of feed, row persisted"
  sed 's/^/        /' "$TMP/mixed.log"
else
  bad "pipelined POST/feed mixed write" "$(cat "$TMP/mixed.log")"
fi

health="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 \
          "http://$HOST:$PORT/health" 2>/dev/null || true)"
health="${health:-000}"
if [ "$health" = 200 ]; then
  ok "/health -> 200 after the mixed write"
else
  bad "/health -> $health after the mixed write (want 200)"
fi

if grep -q "dispatch error" "$TMP/server.log"; then
  bad "server logged a dispatch error" "$(grep 'dispatch error' "$TMP/server.log")"
else
  ok "no dispatch errors logged"
fi

if [ "$fail" -ne 0 ]; then
  echo "---- loadgen ----"; cat "$TMP/lg.out"
  echo "---- mixed ----"; cat "$TMP/mixed.log" 2>/dev/null || true
  echo "---- server log ----"; cat "$TMP/server.log"
  echo "MULTIRING pass=$pass fail=$fail"
  exit 1
fi

grep 'accepted=' "$TMP/server.log" | tail -"$RINGS" | sed 's/^/  per-ring: /'
echo "MULTIRING pass=$pass fail=0"
