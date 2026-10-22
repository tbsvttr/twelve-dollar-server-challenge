#!/usr/bin/env bash
# fallback_matrix.sh - the transport-fallback matrix.
#
# Every env-forced non-default transport variant must still serve real traffic byte-exactly.
# For each env variant this script starts a FRESH server/DB through the existing
# churn and feed harnesses, which assert every response, /health == 200 and the
# absence of dispatch errors:
#
#   IOURING_RECV=oneshot        one-shot recv re-arm path
#   IOURING_ACCEPT=oneshot      one-shot accept re-arm path
#   IOURING_ACCEPT_DIRECT=0     register-per-accept instead of DIRECT/FILE_INDEX_ALLOC
#   IOURING_BUFRING=0           PROVIDE_BUFFERS list instead of the registered buf ring
#
# Each variant runs conn_churn.sh (keep-alive reuse, pipelined /feed, mid-flight
# RSTs, slot reuse) and feed_equality.sh (golden byte equality + POST/feed),
# on separate ports and separate fresh seed copies.
#
#   bash tests/fallback_matrix.sh          # ~60-90 s
#
# Needs: what conn_churn.sh and feed_equality.sh need (curl, python3, jq,
# openssl, cmp). Never uses `pkill -f`.
set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"          # submissions/nim-io_uring-NioHast
BASE_PORT="${BASE_PORT:-3510}"
HOST="${HOST:-127.0.0.1}"
MATRIX_CHURN_CONNS="${MATRIX_CHURN_CONNS:-48}"
MATRIX_CHURN_PIPE="${MATRIX_CHURN_PIPE:-3}"
MATRIX_CHURN_ROUNDS="${MATRIX_CHURN_ROUNDS:-2}"

[ -x "$DIR/bin/server" ] || { echo "missing binary: $DIR/bin/server (run: bash build.sh)" >&2; exit 2; }
for t in curl python3 jq openssl cmp; do
  command -v "$t" >/dev/null 2>&1 || { echo "missing required tool: $t" >&2; exit 2; }
done

VARIANTS=(
  "IOURING_RECV=oneshot"
  "IOURING_ACCEPT=oneshot"
  "IOURING_ACCEPT_DIRECT=0"
  "IOURING_BUFRING=0"
)

pass=0; fail=0
ok()  { echo "  ok    $1"; pass=$((pass+1)); }
bad() { echo "  FAIL  $1"; fail=$((fail+1)); }

i=0
for spec in "${VARIANTS[@]}"; do
  churn_port=$((BASE_PORT + 2 * i))
  feed_port=$((BASE_PORT + 2 * i + 1))
  i=$((i + 1))
  echo "== $spec : churn PORT=$churn_port"
  if env "$spec" PORT="$churn_port" HOST="$HOST" \
       CHURN_CONNS="$MATRIX_CHURN_CONNS" CHURN_PIPE="$MATRIX_CHURN_PIPE" \
       CHURN_ROUNDS="$MATRIX_CHURN_ROUNDS" \
       bash "$DIR/tests/conn_churn.sh"; then
    ok "$spec churn (0 errors, health 200, byte-exact)"
  else
    bad "$spec churn"
  fi

  echo "== $spec : feed PORT=$feed_port"
  if env "$spec" PORT="$feed_port" HOST="$HOST" \
       bash "$DIR/tests/feed_equality.sh"; then
    ok "$spec feed (golden bytes, POST/feed, health 200)"
  else
    bad "$spec feed"
  fi
done

echo "FALLBACK_MATRIX pass=$pass fail=$fail"
[ "$fail" = 0 ]
