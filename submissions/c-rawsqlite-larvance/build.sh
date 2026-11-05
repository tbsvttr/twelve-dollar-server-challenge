#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p vendor bin
if [ ! -f "vendor/sqlite3.c" ]; then
  curl -fsSL --retry 3 -o vendor/sqlite.zip https://sqlite.org/2026/sqlite-amalgamation-3540100.zip
  echo "0a9c8e34352dad46006aa82836d5383bff9dc6bc9ce5a60553c05aa30e6ad1f9  vendor/sqlite.zip" | sha256sum -c -
  unzip -q -o vendor/sqlite.zip -d vendor
  mv vendor/sqlite-amalgamation-3540100/* vendor/
  rm -rf vendor/sqlite.zip vendor/sqlite-amalgamation-3540100
fi
gcc -O3 -march=native -fno-plt -flto=auto -pthread -o bin/server \
  -DSQLITE_THREADSAFE=2 -DSQLITE_DEFAULT_MEMSTATUS=0 -DSQLITE_OMIT_DEPRECATED -DSQLITE_OMIT_SHARED_CACHE \
  -DSQLITE_USE_ALLOCA -DSQLITE_DQS=0 -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1 \
  -Isrc -I. -Ivendor src/server.c -lm
