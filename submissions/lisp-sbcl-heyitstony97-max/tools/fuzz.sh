#!/usr/bin/env bash
# Fuzz gate for the safety-0 build: >=20k malformed requests against one server process.
# Pass: same pid throughout, no 5xx, server still answers afterwards, and 42/42 on a fresh database.
set -uo pipefail
SUB="$(cd "$(dirname "$0")/.." && pwd)"; ROOT="$(cd "$SUB/../.." && pwd)"
export SBCL="${SBCL:-$HOME/.local/opt/sbcl-2.6.10/bin/sbcl}"
export JWT_SECRET=twelve-dollar-challenge HOST=127.0.0.1 PORT="${PORT:-3801}"
D=$(mktemp -d); cp "$ROOT/seed/feed.db" "$D/feed.db"; export SQLITE_PATH="$D/feed.db"
bash "$SUB/start.sh" > "$D/log" 2>&1 &
SP=$!
trap 'kill $SP 2>/dev/null; pkill -P $SP 2>/dev/null' EXIT
for _ in $(seq 120); do curl -sf "http://127.0.0.1:$PORT/health" >/dev/null && break; sleep 0.5; done
PID=$(pgrep -f "$SUB/bin/server" | head -1); echo "server pid $PID"
python3 "$SUB/tools/fuzz.py" "$PORT" "$PID" || { echo "FUZZ FAIL"; tail -5 "$D/log"; exit 1; }
[ "$(pgrep -f "$SUB/bin/server" | head -1)" = "$PID" ] || { echo "pid changed"; exit 1; }
for p in /feed /posts/5 /health; do
  [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT$p")" = 200 ] || { echo "post-fuzz $p not 200"; exit 1; }
done
kill $SP 2>/dev/null; pkill -P $SP 2>/dev/null; sleep 1
PORT=$((PORT+1)) bash "$ROOT/test/run.sh" "$SUB" 2>&1 | grep -E "passed=" | tee "$D/t"; grep -q "passed=42 failed=0" "$D/t" || { echo "42/42 FAILED"; exit 1; }
echo "FUZZ OK pid $PID"
