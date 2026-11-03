#!/usr/bin/env bash
# Builds bin/server: SQLite 3.54.1 (official amalgamation) and liburing 2.12, both SHA-256 pinned,
# compiled from source together with the app.
set -euo pipefail
cd "$(dirname "$0")"
SQLITE=sqlite-amalgamation-3540100
SQLITE_SHA=0a9c8e34352dad46006aa82836d5383bff9dc6bc9ce5a60553c05aa30e6ad1f9
URING=liburing-liburing-2.12
URING_SHA=f1d10cb058c97c953b4c0c446b11e9177e8c8b32a5a88b309f23fdd389e26370
mkdir -p bin deps
if [ ! -f deps/$SQLITE/sqlite3.c ]; then
  curl -fsSL -o deps/$SQLITE.zip https://www.sqlite.org/2026/$SQLITE.zip
  echo "$SQLITE_SHA  deps/$SQLITE.zip" | sha256sum -c -
  unzip -qo deps/$SQLITE.zip -d deps
fi
if [ ! -f deps/$URING/src/liburing.a ]; then
  curl -fsSL -o deps/liburing-2.12.tar.gz https://github.com/axboe/liburing/archive/refs/tags/liburing-2.12.tar.gz
  echo "$URING_SHA  deps/liburing-2.12.tar.gz" | sha256sum -c -
  tar -xzf deps/liburing-2.12.tar.gz -C deps
  (cd deps/$URING && ./configure >/dev/null && make -s -C src liburing.a >/dev/null)
fi
MARCH=; [ "$(uname -m)" != x86_64 ] || MARCH=-march=native  # built on the box it runs on
SQLITE_FLAGS="-DSQLITE_THREADSAFE=2 -DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1 -DSQLITE_DEFAULT_MEMSTATUS=0 -DSQLITE_DQS=0 -DSQLITE_OMIT_DEPRECATED
  -DSQLITE_OMIT_SHARED_CACHE -DSQLITE_OMIT_PROGRESS_CALLBACK -DSQLITE_OMIT_AUTOINIT -DSQLITE_OMIT_LOAD_EXTENSION
  -DSQLITE_LIKE_DOESNT_MATCH_BLOBS -DSQLITE_MAX_EXPR_DEPTH=0 -DSQLITE_USE_ALLOCA -DHAVE_USLEEP=1 -DHAVE_FDATASYNC=1"
# Profile-guided build: an instrumented binary serves a request mix against a synthetic database it
# creates (train.c, no challenge data), then the real binary is compiled with that profile.
CC="gcc -O3 $MARCH -flto -fno-plt -w $SQLITE_FLAGS -Ideps/$SQLITE -Ideps/$URING/src/include
  server.c deps/$URING/src/liburing.a -lpthread -lm -o bin/server -fprofile-dir=$PWD/deps/pgo"
rm -rf deps/pgo
$CC -DPGO_TRAIN -fprofile-generate -fprofile-update=single
PGO_TRAIN_DB=deps/train.db bin/server
rm -f deps/train.db*
$CC -fprofile-use -fprofile-partial-training
