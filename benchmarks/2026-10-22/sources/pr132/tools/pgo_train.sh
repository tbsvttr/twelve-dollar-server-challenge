#!/usr/bin/env bash
# PGO training driver.
#
# Starts the *instrumented* server on a throwaway SYNTHETIC database (never
# `seed/feed.db`, never `seed/tokens.json`) on a private port, drives a FIXED,
# DETERMINISTIC mixed keep-alive GET/POST workload through it, then stops it
# cleanly so the gcov profile is flushed.
#
# Determinism (required so two clean builds produce a byte-identical binary):
#   * the loop runs a FIXED iteration count (`$3`), never a wall-clock window;
#   * the requests are issued one at a time, in a fixed order (curl is
#     synchronous: the server has fully processed each request before the next);
#   * the JWT is built from a FIXED payload (fixed iat/exp/sub/username), not a
#     `date +%s` timestamp, and the POST body is a FIXED string;
#   * the database is regenerated from scratch with deterministic rows each run
#     (tools/gen_synth_db.c uses fixed ids/timestamps and no randomness).
# Because profile counters are per-branch execution *counts*, a fixed request
# sequence yields identical .gcda data and therefore an identical pass-2 binary.
#
# The server installs no signal handler in single-process mode, so a plain
# SIGTERM would kill it without running gcov's exit handler and no .gcda would
# be written (verified: SIGTERM alone yields zero profile files). We therefore
# LD_PRELOAD `tools/libpgoflush.so`, whose constructor turns SIGTERM/SIGINT into
# exit(0), which runs the gcov exit handler. This touches neither the server
# source nor any response byte: it is loaded only for this training run.
#
# Usage: pgo_train.sh <server-binary> [port] [iterations]
#   exits 0 only if the server came up, served exactly <iterations> workloads,
#   and exited cleanly.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVER="${1:-$ROOT/bin/server}"
PORT="${2:-34999}"
ITERS="${3:-60}"
HOST=127.0.0.1
# A secret that is NOT the challenge seed secret; the server is launched with it.
SECRET="pgo-training-secret-not-the-seed"

GEN="$ROOT/tools/gen_synth_db"
SHIM="$ROOT/tools/libpgoflush.so"

[ -x "$SERVER" ] || { echo "pgo_train: no server at $SERVER" >&2; exit 1; }
[ -x "$GEN" ]    || { echo "pgo_train: no generator at $GEN" >&2; exit 1; }
[ -f "$SHIM" ]   || { echo "pgo_train: no flush shim at $SHIM" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "pgo_train: curl is required" >&2; exit 1; }
case "$ITERS" in ''|*[!0-9]*) echo "pgo_train: iterations must be a positive integer, got '$ITERS'" >&2; exit 1;; esac
[ "$ITERS" -ge 1 ] || { echo "pgo_train: iterations must be >= 1" >&2; exit 1; }

WORK="$(mktemp -d)"
SRV_PID=""
cleanup() {
  if [ -n "$SRV_PID" ]; then
    kill -TERM "$SRV_PID" 2>/dev/null || true
    wait "$SRV_PID" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

# --- 1. synthetic database -------------------------------------------------
"$GEN" "$WORK/train.db" >/dev/null 2>"$WORK/gen.log" || {
  echo "pgo_train: synthetic DB generation failed" >&2; cat "$WORK/gen.log" >&2; exit 1; }

# --- 2. start the instrumented server --------------------------------------
SQLITE_PATH="$WORK/train.db" \
JWT_SECRET="$SECRET" \
HOST="$HOST" PORT="$PORT" \
GROUP_COMMIT=1 \
LD_PRELOAD="$SHIM" \
  "$SERVER" >"$WORK/server.log" 2>&1 &
SRV_PID=$!

up=0
for _ in $(seq 100); do
  if curl -s --max-time 1 -o /dev/null "http://$HOST:$PORT/health"; then up=1; break; fi
  if ! kill -0 "$SRV_PID" 2>/dev/null; then
    echo "pgo_train: server exited during startup" >&2; tail -20 "$WORK/server.log" >&2; exit 1
  fi
  sleep 0.05
done
[ "$up" = 1 ] || { echo "pgo_train: server never became healthy" >&2; tail -20 "$WORK/server.log" >&2; exit 1; }

# --- 3. mint an HS256 token for the synthetic secret (openssl), if available -
# FIXED claims: `exp` is a far-future constant (2100-01-01), `iat` and the
# identity are constants too, so the token is byte-identical on every run.
TOKEN=""
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
if command -v openssl >/dev/null 2>&1; then
  const_iat=1700000000
  const_exp=4102444800
  h="$(printf '%s' '{"alg":"HS256","typ":"JWT"}' | b64url)"
  p="$(printf '%s' "{\"sub\":\"1\",\"username\":\"pgo_trainer\",\"iat\":$const_iat,\"exp\":$const_exp}" | b64url)"
  s="$(printf '%s' "$h.$p" | openssl dgst -sha256 -hmac "$SECRET" -binary | b64url)"
  TOKEN="$h.$p.$s"
fi

# --- 4. deterministic training workload: fixed count, fixed order ----------
# Per iteration (one reused keep-alive connection for the GET burst):
#   GET /health  /feed  /posts/1  /posts/2  /posts/999999999   (200/200/200/200/404)
#   POST /posts                       (create, authed)
#   POST /posts/<n%20+1>/like         (like, authed)
# The body is a constant, so the whole request sequence is fixed.
n=0
while [ "$n" -lt "$ITERS" ]; do
  curl -s --max-time 2 \
    "http://$HOST:$PORT/health" \
    "http://$HOST:$PORT/feed" \
    "http://$HOST:$PORT/posts/1" \
    "http://$HOST:$PORT/posts/2" \
    "http://$HOST:$PORT/posts/999999999" >/dev/null 2>&1 || true
  if [ -n "$TOKEN" ]; then
    curl -s --max-time 2 -o /dev/null -X POST \
      -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
      --data-binary '{"body":"pgo synthetic training post"}' \
      "http://$HOST:$PORT/posts" || true
    curl -s --max-time 2 -o /dev/null -X POST \
      -H "Authorization: Bearer $TOKEN" \
      "http://$HOST:$PORT/posts/$(( n % 20 + 1 ))/like" || true
  fi
  n=$((n + 1))
done

# --- 5. stop the server cleanly (shim => exit(0) => gcov flush) -------------
kill -TERM "$SRV_PID" 2>/dev/null
wait "$SRV_PID"; rc=$?
SRV_PID=""
if [ "$rc" != 0 ]; then
  echo "pgo_train: training server exited $rc" >&2; tail -20 "$WORK/server.log" >&2; exit 1
fi
echo "pgo_train: $n fixed workload iterations served"
exit 0
