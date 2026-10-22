#!/usr/bin/env bash
# feed_equality.sh - a focused harness for the /feed endpoint.
#
# It proves two things against a FRESH copy of seed/feed.db:
#
#   1. byte_equality : GET /feed returns a body that is BYTE-FOR-BYTE identical
#      to test/golden/feed.json (raw `cmp`, never jq, so whitespace/key order/
#      escaping all count).
#   2. top_of_feed   : after creating exactly one post with a valid HS256 JWT
#      (same signing as test/test.sh: USER_ID=1, USER_NAME=golden_ember_1), the
#      feed still has exactly 20 posts and posts[0] is that new post, byte-exact.
#
# Usage:
#   bash tests/feed_equality.sh                      # starts bin/server via start.sh
#   PORT=3210 bash tests/feed_equality.sh            # pick the port
#   bash tests/feed_equality.sh --negative-control    # PROVE it can fail:
#       # compares /feed against a deliberately wrong golden and must exit
#       # non-zero with a FAIL line (misleading-success guard).
#
# Needs: curl, jq (structural assertions only), openssl, cmp. JWT_SECRET
# defaults to the challenge secret. Never uses `pkill -f`; cleanup is `fuser`
# + `pgrep -P`.
set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"          # submissions/nim-io_uring-NioHast
ROOT="$(cd "$DIR/../.." && pwd)"                  # repo root
GOLDEN="$ROOT/test/golden/feed.json"
SEED="$ROOT/seed/feed.db"
JWT_SECRET="${JWT_SECRET:-twelve-dollar-challenge}"
USER_ID=1; USER_NAME=golden_ember_1               # user 1 in the seed
PORT="${PORT:-3210}"
HOST="${HOST:-127.0.0.1}"
NEGCTL=0

while [ $# -gt 0 ]; do
  case "$1" in
    --negative-control) NEGCTL=1 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

for t in curl jq openssl cmp mktemp; do
  command -v "$t" >/dev/null 2>&1 || { echo "missing required tool: $t" >&2; exit 2; }
done
[ -f "$GOLDEN" ] || { echo "missing golden: $GOLDEN" >&2; exit 2; }
[ -f "$SEED" ]   || { echo "missing seed: $SEED (run: bash seed/make-seed.sh)" >&2; exit 2; }

BIN="$DIR/bin/server"
[ -x "$BIN" ] || { echo "missing binary: $BIN (run: bash build.sh)" >&2; exit 2; }

# ---------------------------------------------------------------------------
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

# A deliberately wrong golden, used only by --negative-control.
if [ "$NEGCTL" = 1 ]; then
  GOLDEN="$TMP/wrong-golden.json"
  printf '{"posts":[]}' > "$GOLDEN"
  echo "NEGATIVE CONTROL: golden overridden with a trivially wrong body (expect failures)"
fi

# b64url/sign - identical to test/test.sh.
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
sign() {
  local h p s
  h="$(printf '%s' '{"alg":"HS256","typ":"JWT"}' | b64url)"
  p="$(printf '%s' "$1" | b64url)"
  s="$(printf '%s' "$h.$p" | openssl dgst -sha256 -hmac "$JWT_SECRET" -binary | b64url)"
  echo "$h.$p.$s"
}

# req <method> <path> [authorization|-] [raw-body]
#   -> STATUS, BODY (string), plus $TMP/body (raw bytes, trailing newline intact)
req() {
  local args=(-s -o "$TMP/body" -w '%{http_code}' -X "$1" "http://$HOST:$PORT$2")
  [ -n "${3:-}" ] && [ "$3" != "-" ] && args+=(-H "Authorization: $3")
  [ -n "${4+x}" ] && args+=(-H 'Content-Type: application/json' --data-binary "$4")
  STATUS="$(curl "${args[@]}")"
  BODY="$(cat "$TMP/body")"
}

# --- fresh seed ------------------------------------------------------------
cp "$SEED" "$SQLITE_PATH"

export JWT_SECRET HOST PORT SQLITE_PATH
echo "Testing http://$HOST:$PORT  (fresh seed copy)"
bash "$DIR/start.sh" >"$TMP/server.log" 2>&1 &
SRV_PID=$!

up=0
for _ in $(seq 60); do
  if curl -sf "http://$HOST:$PORT/health" >/dev/null 2>&1; then up=1; break; fi
  kill -0 "$SRV_PID" 2>/dev/null || break
  sleep 0.5
done
if [ "$up" != 1 ]; then
  echo "FEED_EQUALITY pass=0 fail=1"
  echo "server did not become healthy; log:" >&2
  cat "$TMP/server.log" >&2
  exit 1
fi

now=$(date +%s)
TOKEN="$(sign "{\"sub\":\"$USER_ID\",\"username\":\"$USER_NAME\",\"iat\":$now,\"exp\":$((now+3600))}")"
AUTH="Bearer $TOKEN"

# --- 1. byte equality vs golden --------------------------------------------
echo "-- golden byte equality"
req GET /feed
if [ "$STATUS" = 200 ]; then ok "GET /feed -> 200"; else bad "GET /feed status" "got $STATUS"; fi
if cmp -s "$TMP/body" "$GOLDEN"; then
  ok "GET /feed body == golden (raw cmp, $(wc -c < "$TMP/body") bytes)"
else
  bad "GET /feed body != golden" "cmp: $(cmp "$TMP/body" "$GOLDEN" 2>&1 | head -1)"
fi

# --- 2. top-of-feed scenario ----------------------------------------------
echo "-- top-of-feed after one write"
PBODY="top-of-feed probe body"
req POST /posts "$AUTH" "{\"body\":\"$PBODY\"}"
CREATE_RESP="$BODY"
NEW_ID="$(printf '%s' "$BODY" | jq -r '.post.id' 2>/dev/null)"
CREATED="$(printf '%s' "$BODY" | jq -r '.post.created_at' 2>/dev/null)"
if [ "$STATUS" = 201 ] && [ -n "$NEW_ID" ] && [ "$NEW_ID" != "null" ]; then
  ok "POST /posts -> 201 (id=$NEW_ID)"
else
  bad "POST /posts" "got $STATUS $BODY"
fi

req GET /feed
FEED_LEN="$(printf '%s' "$BODY" | jq '.posts | length' 2>/dev/null)"
if [ "$FEED_LEN" = 20 ]; then ok "feed has exactly 20 posts"; else bad "feed length" "got $FEED_LEN"; fi

EXPECT0="{\"id\":$NEW_ID,\"body\":\"$PBODY\",\"created_at\":\"$CREATED\",\"author\":\"$USER_NAME\",\"like_count\":0}"
FEED0="$(printf '%s' "$BODY" | jq -c '.posts[0]' 2>/dev/null)"
if [ "$(printf '%s' "$BODY" | jq -r '.posts[0].id' 2>/dev/null)" = "$NEW_ID" ]; then
  ok "posts[0].id is the new post ($NEW_ID)"
else
  bad "posts[0].id" "got $(printf '%s' "$BODY" | jq -c '.posts[0]' 2>/dev/null)"
fi
if [ "$FEED0" = "$EXPECT0" ]; then
  ok "posts[0] byte-exact JSON"
else
  bad "posts[0] JSON" "want $EXPECT0"$'\n'"        got  $FEED0"
fi

CREATE_POST_JSON="$(printf '%s' "$CREATE_RESP" | jq -c '.post' 2>/dev/null)"
if [ -n "$CREATE_POST_JSON" ] && [ "$FEED0" = "$CREATE_POST_JSON" ]; then
  ok "feed entry matches the created post"
else
  bad "feed entry vs created post" "created $CREATE_POST_JSON"$'\n'"        feed    $FEED0"
fi

echo "FEED_EQUALITY pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
