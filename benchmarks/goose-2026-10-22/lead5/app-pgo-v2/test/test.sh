#!/usr/bin/env bash
# The test suite. A submission must pass every check before it is benchmarked.
#
#   bash test/test.sh                        # http://127.0.0.1:3000
#   bash test/test.sh http://127.0.0.1:8080
#
# Run it against a server that was started on a FRESH copy of seed/feed.db: it compares exact
# response bytes with test/golden/*.json, then writes one post and a few likes, so a second run
# against the same database fails the golden checks.
#
# Needs: curl, jq, openssl. JWT_SECRET defaults to the challenge secret.
set -uo pipefail
BASE="${1:-http://127.0.0.1:3000}"
GOLDEN="$(cd "$(dirname "$0")" && pwd)/golden"
JWT_SECRET="${JWT_SECRET:-twelve-dollar-challenge}"
USER_ID=1; USER_NAME=golden_ember_1          # user 1 in the seed
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()  { echo "  ok   $1"; pass=$((pass+1)); }
bad() { echo "  FAIL $1"; [ -n "${2:-}" ] && echo "       $2"; fail=$((fail+1)); }

# req <method> <path> [authorization|-] [raw-body]  ->  STATUS, BODY (one trailing newline stripped), CTYPE
req() {
  local args=(-s -o "$TMP/body" -D "$TMP/headers" -w '%{http_code}' -X "$1" "$BASE$2")
  [ -n "${3:-}" ] && [ "$3" != "-" ] && args+=(-H "Authorization: $3")
  [ -n "${4+x}" ] && args+=(-H 'Content-Type: application/json' --data-binary "$4")
  STATUS="$(curl "${args[@]}")"
  BODY="$(cat "$TMP/body")"
  CTYPE="$(grep -i '^content-type:' "$TMP/headers" | head -1 | cut -d' ' -f2- | tr -d '\r')"
}
# expect <label> <status> <exact body>
expect() {
  if [ "$STATUS" = "$2" ] && [ "$BODY" = "$3" ]; then ok "$1 -> $STATUS"
  else bad "$1" "want $2 $3"$'\n'"       got  $STATUS $BODY"; fi
}
json_ctype() { case "$CTYPE" in application/json*) ok "$1 content-type ($CTYPE)";; *) bad "$1 content-type" "got '$CTYPE'";; esac; }

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
sign() { # sign <json-payload> -> HS256 JWT
  local h p s
  h="$(printf '%s' '{"alg":"HS256","typ":"JWT"}' | b64url)"; p="$(printf '%s' "$1" | b64url)"
  s="$(printf '%s' "$h.$p" | openssl dgst -sha256 -hmac "$JWT_SECRET" -binary | b64url)"
  echo "$h.$p.$s"
}
now=$(date +%s)
TOKEN="$(sign "{\"sub\":\"$USER_ID\",\"username\":\"$USER_NAME\",\"iat\":$now,\"exp\":$((now+3600))}")"

echo "Testing $BASE"

echo "-- golden reads (fresh database)"
req GET /feed;           expect "GET /feed == golden" 200 "$(cat "$GOLDEN/feed.json")"; json_ctype "GET /feed"
for f in "$GOLDEN"/post-*.json; do
  id="$(basename "$f" .json)"; id="${id#post-}"
  req GET "/posts/$id";  expect "GET /posts/$id == golden" 200 "$(cat "$f")"
done
json_ctype "GET /posts/:id"

echo "-- health, 404s, id validation"
req GET /health
if [ "$STATUS" = 200 ] && [[ "$BODY" =~ ^\{\"status\":\"ok\",\"db\":\"ok\",\"uptime_s\":[0-9]+\}$ ]]; then ok "GET /health -> 200 $BODY"; else bad "GET /health" "got $STATUS $BODY"; fi
req GET /nope;           expect "GET /nope" 404 '{"error":"not found"}'
for id in 0 -1 abc 1.5; do
  req GET "/posts/$id";  expect "GET /posts/$id" 400 '{"error":"invalid post id"}'
done
req GET /posts/999999999; expect "GET /posts/999999999" 404 '{"error":"post not found"}'

echo "-- auth"
now=$(date +%s)
expired="$(sign "{\"sub\":\"$USER_ID\",\"username\":\"$USER_NAME\",\"iat\":$((now-7200)),\"exp\":$((now-3600))}")"
bad_sub="$(sign "{\"sub\":\"abc\",\"username\":\"$USER_NAME\",\"iat\":$now,\"exp\":$((now+3600))}")"
no_name="$(sign "{\"sub\":\"$USER_ID\",\"iat\":$now,\"exp\":$((now+3600))}")"
none="$(printf '%s' '{"alg":"none","typ":"JWT"}' | b64url).$(echo "$TOKEN" | cut -d. -f2)."
req POST /posts - '{"body":"x"}';                  expect "POST /posts, no token" 401 '{"error":"missing bearer token"}'
req POST /posts "Basic abc" '{"body":"x"}';        expect "POST /posts, Basic auth" 401 '{"error":"missing bearer token"}'
req POST /posts "Bearer abc" '{"body":"x"}';       expect "POST /posts, garbage token" 401 '{"error":"invalid or expired token"}'
req POST /posts "Bearer ${TOKEN%.*}.c2lnbmF0dXJlLWlzLW5vdC12YWxpZC1hdC1hbGwtYXQtYWxsLTEyMzQ" '{"body":"x"}'
                                                   expect "POST /posts, bad signature" 401 '{"error":"invalid or expired token"}'
req POST /posts "Bearer $none" '{"body":"x"}';     expect "POST /posts, alg=none" 401 '{"error":"invalid or expired token"}'
req POST /posts "Bearer $expired" '{"body":"x"}';  expect "POST /posts, expired token" 401 '{"error":"invalid or expired token"}'
req POST /posts "Bearer $bad_sub" '{"body":"x"}';  expect "POST /posts, sub not an integer" 401 '{"error":"invalid token payload"}'
req POST /posts "Bearer $no_name" '{"body":"x"}';  expect "POST /posts, no username" 401 '{"error":"invalid token payload"}'
req POST /posts/abc/like -;                        expect "POST /posts/abc/like, no token (auth before id)" 401 '{"error":"missing bearer token"}'

echo "-- create validation"
A="Bearer $TOKEN"
req POST /posts "$A" '{"body":""}';          expect "empty body" 400 '{"error":"body is required"}'
req POST /posts "$A" '{"body":"   "}';       expect "whitespace body" 400 '{"error":"body is required"}'
req POST /posts "$A" '{"body":123}';         expect "numeric body" 400 '{"error":"body is required"}'
req POST /posts "$A" '{}';                   expect "missing body" 400 '{"error":"body is required"}'
req POST /posts "$A" '{bad json';            expect "malformed JSON" 400 '{"error":"malformed JSON body"}'
req POST /posts "$A" "{\"body\":\"$(printf 'a%.0s' $(seq 501))\"}"
                                             expect "501-char body" 400 '{"error":"body must be at most 500 characters"}'

echo "-- create, like, read back"
req POST /posts "$A" '{"body":"  test: <b>&amp;</b> \"quoted\" / café ✓  "}'
if [ "$STATUS" = 201 ] && [ "$(echo "$BODY" | jq -r '.post.body')" = 'test: <b>&amp;</b> "quoted" / café ✓' ]; then ok "special characters round-trip (trimmed) -> 201"
else bad "special characters round-trip" "got $STATUS $BODY"; fi

BODY500="$(printf 'b%.0s' $(seq 500))"
req POST /posts "$A" "{\"body\":\"  $BODY500 \"}"
NEW_ID="$(echo "$BODY" | jq -r '.post.id' 2>/dev/null)"; CREATED="$(echo "$BODY" | jq -r '.post.created_at' 2>/dev/null)"
expect "create 500-char post" 201 "{\"post\":{\"id\":$NEW_ID,\"body\":\"$BODY500\",\"created_at\":\"$CREATED\",\"author\":\"$USER_NAME\",\"like_count\":0}}"
json_ctype "POST /posts"
[[ "$CREATED" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z$ ]] && ok "created_at format $CREATED" || bad "created_at format" "got '$CREATED'"
created_s="$(date -j -u -f '%Y-%m-%dT%H:%M:%S' "${CREATED%.*}" +%s 2>/dev/null || date -u -d "${CREATED%.*}" +%s 2>/dev/null || echo 0)"
drift=$(( $(date -u +%s) - created_s )); drift=${drift#-}
[ "$drift" -le 60 ] && ok "created_at is now (UTC, ${drift}s)" || bad "created_at is not UTC now" "drift ${drift}s"

req POST "/posts/$NEW_ID/like" "$A";         expect "like (first)" 201 "{\"liked\":true,\"already_liked\":false,\"post_id\":$NEW_ID}"
req POST "/posts/$NEW_ID/like" "$A";         expect "like (repeat)" 200 "{\"liked\":true,\"already_liked\":true,\"post_id\":$NEW_ID}"
req POST /posts/999999999/like "$A";         expect "like missing post" 404 '{"error":"post not found"}'
req POST /posts/abc/like "$A";               expect "like bad id (with token)" 400 '{"error":"invalid post id"}'
req GET "/posts/$NEW_ID";                    expect "read back, like_count 1" 200 "{\"post\":{\"id\":$NEW_ID,\"body\":\"$BODY500\",\"created_at\":\"$CREATED\",\"author\":\"$USER_NAME\",\"like_count\":1}}"
req POST /posts/1/like "$A"
req GET /posts/1
want_likes=$(( $(jq '.post.like_count' "$GOLDEN/post-1.json") + 1 ))
[ "$(echo "$BODY" | jq '.post.like_count')" = "$want_likes" ] && ok "like on a seeded post is counted at once ($want_likes)" || bad "seeded post like_count" "want $want_likes, got $(echo "$BODY" | jq -c '.post.like_count')"
req GET /feed
[ "$(echo "$BODY" | jq '.posts | length')" = 20 ] && ok "feed has 20 posts" || bad "feed length" "$(echo "$BODY" | jq '.posts | length')"
[ "$(echo "$BODY" | jq '.posts[0].id')" = "$NEW_ID" ] && ok "new post is at the top of the feed" || bad "top of feed" "$(echo "$BODY" | jq -c '.posts[0]')"
[ "$(echo "$BODY" | jq -c '.posts[0]')" = "{\"id\":$NEW_ID,\"body\":\"$BODY500\",\"created_at\":\"$CREATED\",\"author\":\"$USER_NAME\",\"like_count\":1}" ] \
  && ok "feed entry matches the post" || bad "feed entry" "$(echo "$BODY" | jq -c '.posts[0]')"

echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
