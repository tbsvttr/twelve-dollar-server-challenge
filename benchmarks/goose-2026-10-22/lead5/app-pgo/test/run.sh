#!/usr/bin/env bash
# Builds a submission, starts it on a fresh copy of the seed database and runs the test suite.
# This is exactly what CI runs on every pull request.
#
#   bash test/run.sh submissions/<your-folder>
#
# Run install.sh yourself first (once, as root). Needs seed/feed.db: bash seed/make-seed.sh
set -euo pipefail
DIR="$(cd "${1:?usage: test/run.sh submissions/<folder>}" && pwd)"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$ROOT/seed/feed.db" ] || { echo "no seed/feed.db — run: bash seed/make-seed.sh"; exit 1; }
for f in build.sh start.sh; do [ -f "$DIR/$f" ] || { echo "missing $DIR/$f"; exit 1; }; done

export JWT_SECRET=twelve-dollar-challenge HOST=127.0.0.1 PORT="${PORT:-3000}"
export SQLITE_PATH="$(mktemp -d)/feed.db"
cp "$ROOT/seed/feed.db" "$SQLITE_PATH"

echo "== build"; bash "$DIR/build.sh"
echo "== start ($SQLITE_PATH)"
bash "$DIR/start.sh" > "$(dirname "$SQLITE_PATH")/server.log" 2>&1 &
PID=$!
cleanup() { pkill -P $PID 2>/dev/null || true; kill $PID 2>/dev/null || true; wait $PID 2>/dev/null || true; rm -rf "$(dirname "$SQLITE_PATH")"; }
trap cleanup EXIT
for _ in $(seq 60); do curl -sf "http://$HOST:$PORT/health" >/dev/null && break; sleep 1; done
curl -sf "http://$HOST:$PORT/health" >/dev/null || { echo "no healthy /health after 60 s"; cat "$(dirname "$SQLITE_PATH")/server.log"; exit 1; }

echo "== test"
rc=0; bash "$ROOT/test/test.sh" "http://$HOST:$PORT" || rc=$?
[ $rc = 0 ] || { echo "== server log (last 30 lines)"; tail -30 "$(dirname "$SQLITE_PATH")/server.log"; }
trap - EXIT; cleanup
exit $rc
