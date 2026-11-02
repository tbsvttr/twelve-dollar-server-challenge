#!/usr/bin/env bash
# Builds bin/server as a normal user. Downloads the pinned SQLite amalgamation and checks its SHA-256.
set -euo pipefail
cd "$(dirname "$0")"
SQ=sqlite-amalgamation-3540100
SQ_SHA=0a9c8e34352dad46006aa82836d5383bff9dc6bc9ce5a60553c05aa30e6ad1f9
mkdir -p build bin
if [ ! -f "build/$SQ/sqlite3.c" ]; then
  [ -f "build/$SQ.zip" ] || curl -fsSL -o "build/$SQ.zip" "https://www.sqlite.org/2026/$SQ.zip"
  echo "$SQ_SHA  build/$SQ.zip" | sha256sum -c -
  (cd build && unzip -q -o "$SQ.zip")
fi
DEFS="-DSQLITE_THREADSAFE=2 -DSQLITE_DEFAULT_MEMSTATUS=0 -DSQLITE_OMIT_DEPRECATED -DSQLITE_OMIT_SHARED_CACHE
  -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_DQS=0 -DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1 -DSQLITE_OMIT_AUTOINIT"
# One translation unit: server.c includes sqlite3.c so it can use SQLite's B-tree functions.
gcc -O2 -march=native -w $DEFS -I"build/$SQ" -o bin/server src/server.c -luring -lm -pthread
