#!/usr/bin/env bash
# Equivalence test for the B-tree read path (PR #153). Starts two servers on identical copies of the
# seed database, one with NO_BTREE=1 (prepared SQL) and one with the B-tree cursors, applies the same
# likes to both, then compares response bytes (status + headers that matter + body) for
# 2,000 random GET /posts/:id and 200 GET /feed requests (with and without a token, varied users).
#   bash tools/equiv.sh [seed.db]        needs curl, openssl, cmp
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SEED="${1:-$HERE/../../seed/feed.db}"
SECRET="${JWT_SECRET:-twelve-dollar-challenge}"
W="$(mktemp -d)"; PA=${PORT_A:-3811}; PB=${PORT_B:-3812}
cleanup() { kill "${PIDA:-}" "${PIDB:-}" 2>/dev/null || true; rm -rf "$W"; }
trap cleanup EXIT
cp "$SEED" "$W/a.db"; cp "$SEED" "$W/b.db"
export JWT_SECRET="$SECRET" HOST=127.0.0.1
PORT=$PA SQLITE_PATH="$W/a.db" NO_BTREE=1 "$HERE/bin/server" >"$W/a.log" 2>&1 & PIDA=$!
PORT=$PB SQLITE_PATH="$W/b.db" "$HERE/bin/server" >"$W/b.log" 2>&1 & PIDB=$!
for p in $PA $PB; do for _ in $(seq 60); do curl -sf "http://127.0.0.1:$p/health" >/dev/null && break; sleep 0.5; done; done
grep -q 'B-tree reads on' "$W/b.log" || { echo "FAIL: B-tree path is not on in server B"; cat "$W/b.log"; exit 1; }
grep -q 'B-tree reads off' "$W/a.log" || { echo "FAIL: server A should be on SQL"; exit 1; }

b64() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
token() { # sub username
  local h p s
  h=$(printf '{"alg":"HS256","typ":"JWT"}' | b64)
  p=$(printf '{"sub":"%s","username":"%s","exp":%s}' "$1" "$2" "$(( $(date +%s) + 3600 ))" | b64)
  s=$(printf '%s' "$h.$p" | openssl dgst -sha256 -hmac "$SECRET" -binary | b64)
  printf '%s.%s.%s' "$h" "$p" "$s"
}
get() { # port path [token] -> status line + body
  local auth=()
  [ -n "${3:-}" ] && auth=(-H "Authorization: Bearer $3")
  curl -s -o - -w '\n%{http_code} %{content_type}\n' "${auth[@]}" "http://127.0.0.1:$1$2"
}
post() { curl -s -o /dev/null -X POST -H "Authorization: Bearer $2" "http://127.0.0.1:$1$3"; }

RANDOM=7
# same writes on both: likes on the 20 newest posts (so counts differ from the seed) and on random ones
for i in $(seq 1 60); do
  u=$(( RANDOM % 50000 + 1 )); id=$(( 500000 - RANDOM % 25 ))
  t=$(token $u "user$u")
  post $PA "$t" "/posts/$id/like"; post $PB "$t" "/posts/$id/like"
done
bad=0; n=0
check() { # path [token]
  get $PA "$1" "${2:-}" >"$W/ra"; get $PB "$1" "${2:-}" >"$W/rb"
  n=$((n+1))
  cmp -s "$W/ra" "$W/rb" || { bad=$((bad+1)); echo "MISMATCH $1"; head -c 300 "$W/ra"; echo; head -c 300 "$W/rb"; echo; }
}
for _ in $(seq 2000); do check "/posts/$(( (RANDOM * 32768 + RANDOM) % 500000 + 1 ))"; done
for id in 0 -1 500000 500001 99999999999 abc 1 2; do check "/posts/$id"; done
for i in $(seq 200); do
  if [ $((i % 2)) = 0 ]; then u=$(( RANDOM % 50000 + 1 )); check /feed "$(token $u "user$u")"; else check /feed; fi
done
echo "compared=$n mismatches=$bad"
[ "$bad" = 0 ]
