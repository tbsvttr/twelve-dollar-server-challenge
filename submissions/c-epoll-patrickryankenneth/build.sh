#!/usr/bin/env bash
# Runs as a normal user. Builds SQLite (pinned amalgamation) and the server from source.
set -euo pipefail
cd "$(dirname "$0")"

SQLITE_YEAR=2025
SQLITE_VER=3500400            # SQLite 3.50.4
SQLITE_SHA256="1d3049dd0f830a025a53105fc79fd2ab9431aea99e137809d064d8ee8356b032"

mkdir -p build bin
if [ ! -f build/sqlite3.c ]; then
  curl -fsSL -o build/sqlite.zip "https://www.sqlite.org/${SQLITE_YEAR}/sqlite-amalgamation-${SQLITE_VER}.zip"
  actual=$(sha256sum build/sqlite.zip | cut -d' ' -f1)
  if [ -n "$SQLITE_SHA256" ] && [ "$actual" != "$SQLITE_SHA256" ]; then
    echo "sqlite zip sha256 mismatch: got $actual" >&2; exit 1
  fi
  [ -z "$SQLITE_SHA256" ] && echo "NOTE: pin SQLITE_SHA256=$actual in build.sh"
  unzip -oj build/sqlite.zip '*/sqlite3.c' '*/sqlite3.h' -d build
fi

SQLITE_OPTS="-DSQLITE_THREADSAFE=0 -DSQLITE_DEFAULT_MEMSTATUS=0 -DSQLITE_DQS=0 \
 -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_OMIT_DEPRECATED -DSQLITE_OMIT_SHARED_CACHE \
 -DSQLITE_OMIT_PROGRESS_CALLBACK -DSQLITE_USE_ALLOCA -DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1"

gcc -O2 $SQLITE_OPTS -c build/sqlite3.c -o build/sqlite3.o
gcc -O3 -march=x86-64-v2 -Wall -Wextra -Ibuild server.c build/sqlite3.o -o bin/server -lm
echo "built bin/server"
