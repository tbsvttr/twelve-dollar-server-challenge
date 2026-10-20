#!/usr/bin/env bash
# Builds the seed database: seed/feed.db (~250 MB, WAL mode) plus seed/tokens.json.
#
#   bash seed/make-seed.sh
#
# Needs: node >= 18 and the sqlite3 CLI (Ubuntu: apt install sqlite3; macOS has it).
# Takes about a minute. The output is deterministic: the check at the end must print OK.
# Never serve feed.db directly — every test or benchmark run starts from a fresh copy of it.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DB="$HERE/feed.db"; TSV="$HERE/tsv"
EXPECTED=738d11ab3164c13177e347f75038d1e80b43c64e754544a42d1c32bd8d7bcf1d  # sha256 of every row, ordered

node "$HERE/generate.mjs" "$TSV"
mv "$TSV/tokens.json" "$HERE/tokens.json"

rm -f "$DB" "$DB-wal" "$DB-shm"
# ascii mode with tab/newline separators: fields are imported verbatim (no CSV quoting).
sqlite3 "$DB" >/dev/null <<SQL
PRAGMA journal_mode = OFF;
PRAGMA synchronous = OFF;
.read $HERE/../schema.sql
.mode ascii
.separator "\t" "\n"
.import $TSV/users.tsv users
.import $TSV/posts.tsv posts
.import $TSV/likes.tsv likes
ANALYZE;
VACUUM;
PRAGMA journal_mode = WAL;
SQL
sqlite3 "$DB" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null
rm -rf "$TSV"

sha() { if command -v sha256sum >/dev/null; then sha256sum; else shasum -a 256; fi; }
sum="$(sqlite3 "$DB" "SELECT * FROM users ORDER BY id; SELECT * FROM posts ORDER BY id; SELECT * FROM likes ORDER BY post_id, user_id;" | sha | cut -d' ' -f1)"
if [ "$sum" = "$EXPECTED" ]; then echo "OK: $DB ($(du -h "$DB" | cut -f1)), content sha256 matches"
else echo "MISMATCH: content sha256 $sum, expected $EXPECTED"; exit 1; fi
