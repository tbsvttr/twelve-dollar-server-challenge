#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$DIR/bin" "$DIR/vendor"

CIDER_BIN="${CIDER_BIN:-/opt/cider/build/cider}"
[[ -x "$CIDER_BIN" ]] || { echo "Cider compiler not found at $CIDER_BIN" >&2; exit 1; }

CIDER_LIB="${CIDER_LIB:-/opt/cider/modules}"
[[ -d "$CIDER_LIB" ]] || { echo "Cider modules not found at $CIDER_LIB" >&2; exit 1; }
export CIDER_LIB

SQLITE_VER=sqlite-amalgamation-3540100
SQLITE_SHA256=0a9c8e34352dad46006aa82836d5383bff9dc6bc9ce5a60553c05aa30e6ad1f9

if [ ! -f "$DIR/vendor/$SQLITE_VER/sqlite3.c" ]; then
  echo "== [SQLite] Downloading official pinned SQLite amalgamation ($SQLITE_VER)..."
  curl -fsSL --retry 3 -o "$DIR/vendor/$SQLITE_VER.zip" "https://sqlite.org/2026/$SQLITE_VER.zip"
  echo "$SQLITE_SHA256  $DIR/vendor/$SQLITE_VER.zip" | sha256sum -c -
  unzip -q -o "$DIR/vendor/$SQLITE_VER.zip" -d "$DIR/vendor"
fi

echo "== [SQLite] Compiling multi-thread SQLite3 + B-tree read plans..."
# btree.c includes the amalgamation so the native read plans can use SQLite's
# internal B-tree API in the same translation unit.  The resulting object
# provides both the SQLite public API and bt_* functions.  THREADSAFE=2 is
# required for the off-loop checkpoint connection.
gcc -O3 -march=native \
    -DSQLITE_THREADSAFE=2 \
    -DSQLITE_DEFAULT_MEMSTATUS=0 \
    -DSQLITE_DQS=0 \
    -DSQLITE_OMIT_LOAD_EXTENSION \
    -DSQLITE_OMIT_DEPRECATED \
    -DSQLITE_OMIT_SHARED_CACHE \
    -DSQLITE_OMIT_PROGRESS_CALLBACK \
    -DSQLITE_USE_ALLOCA \
    -DHAVE_FDATASYNC=1 \
    -c "$DIR/src/btree.c" -o "$DIR/bin/sqlite3.o"

echo "== [Cider] Compiling Cider server.cid..."
"$CIDER_BIN" compile -c "$DIR/src/server.cid" -o "$DIR/src/server.o"
gcc -O3 -march=native -c "$DIR/src/fast.c" -o "$DIR/src/fast.o"

echo "== [Link] Linking bin/server with native SQLite/B-tree, OpenSSL, and Pthreads..."
gcc -nostartfiles "$DIR/src/server.o" "$DIR/src/fast.o" "$DIR/bin/sqlite3.o" -o "$DIR/bin/server" -lcrypto -lpthread -lm -lc

echo "== Build complete: $DIR/bin/server"
