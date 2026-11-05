#!/usr/bin/env bash
# Builds bin/server: official SQLite amalgamation compiled from source with the application.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
mkdir -p "$DIR/bin" "$DIR/deps"

SQLITE=sqlite-amalgamation-3530200
SQLITE_SHA=8a310d0a16c7a90cacd4c884e70faa51c902afed2a89f63aaa0126ab83558a32

if [ ! -f "$DIR/deps/$SQLITE/sqlite3.c" ]; then
    if [ -f "$ROOT/vendor/sqlite/sqlite3.c" ]; then
        mkdir -p "$DIR/deps/$SQLITE"
        cp "$ROOT/vendor/sqlite/"* "$DIR/deps/$SQLITE/"
    else
        echo "== [deps] Fetching official SQLite amalgamation $SQLITE..."
        curl -fsSL -o "$DIR/deps/$SQLITE.zip" "https://www.sqlite.org/2026/$SQLITE.zip"
        echo "$SQLITE_SHA  $DIR/deps/$SQLITE.zip" | sha256sum -c -
        unzip -qo "$DIR/deps/$SQLITE.zip" -d "$DIR/deps"
    fi
fi

SQLITE_SRC="$DIR/deps/$SQLITE"
MARCH=; [ "$(uname -m)" != x86_64 ] || MARCH=-march=native

if [ ! -f "$DIR/bin/sqlite3.o" ]; then
    echo "== [SQLite] Compiling official SQLite amalgamation with single-core zero-mutex flags..."
    gcc -O3 $MARCH \
        -DSQLITE_THREADSAFE=0 \
        -DSQLITE_DEFAULT_MEMSTATUS=0 \
        -DSQLITE_DQS=0 \
        -DSQLITE_OMIT_DEPRECATED \
        -DSQLITE_OMIT_LOAD_EXTENSION \
        -DSQLITE_OMIT_PROGRESS_CALLBACK \
        -DSQLITE_USE_ALLOCA \
        -DHAVE_FDATASYNC=1 \
        -c "$SQLITE_SRC/sqlite3.c" -o "$DIR/bin/sqlite3.o"
fi

SERIALIZE_FLAG="-DUSE_FAST_SERIALIZE=${FAST_SERIALIZE:-1}"

echo "== [Server] Compiling c-iouring-fajarreza-gif (FAST_SERIALIZE=${FAST_SERIALIZE:-1})..."
gcc -O3 $MARCH $SERIALIZE_FLAG \
    -I"$DIR/src" \
    -I"$SQLITE_SRC" \
    "$DIR/src/server.c" "$DIR/bin/sqlite3.o" \
    -o "$DIR/bin/server" -lm

echo "== [Build complete] Binary: $DIR/bin/server"
