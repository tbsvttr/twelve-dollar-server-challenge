#!/usr/bin/env bash
# Builds bin/server. In the submitted folder, official Lean first checks the theorems and runs the program that writes
# every file here. Then the pinned SQLite amalgamation and the server compile as one translation unit, profile-guided.
#   PGO=0 ./build.sh   plain build
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p vendor bin
if [ -d lean ]; then
  export PATH="/opt/lean-4.32.1/bin:$PATH"
  # Warnings fail the build, so a theorem left as sorry can't pass.
  (cd lean && lake build --wfail)
  rm -rf generated
  (cd lean && lake env lean --run Write.lean ../generated)
  # The readable C here must be exactly what the checked program wrote, or the build stops.
  for name in src/server.c src/core.h src/core_test.c build.sh install.sh start.sh .gitignore README.md; do
    cmp "$name" "generated/$name"
  done
  rm -rf generated
  # The tables as they reached C, against the rules written out independently, for every value.
  gcc -std=gnu11 -o bin/core_test src/core_test.c
  bin/core_test
fi
SQLITE=sqlite-amalgamation-3540100
SQLITE_SHA256=0a9c8e34352dad46006aa82836d5383bff9dc6bc9ce5a60553c05aa30e6ad1f9
if [ ! -f "vendor/$SQLITE/sqlite3.c" ]; then
  curl -fsSL --retry 3 -o "vendor/$SQLITE.zip" "https://sqlite.org/2026/$SQLITE.zip"
  echo "$SQLITE_SHA256  vendor/$SQLITE.zip" | sha256sum -c -
  unzip -q -o "vendor/$SQLITE.zip" -d vendor
fi
FLAGS=(-std=gnu11 -O3 -g -march=x86-64-v3 -mtune=cascadelake -mprefer-vector-width=256 -fno-plt -fomit-frame-pointer
  -fno-stack-protector -fcf-protection=none -fno-stack-clash-protection -U_FORTIFY_SOURCE -pthread
  -DSQLITE_THREADSAFE=2 -DSQLITE_DEFAULT_MEMSTATUS=0 -DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1 -DSQLITE_OMIT_SHARED_CACHE
  -DSQLITE_OMIT_DEPRECATED -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_OMIT_PROGRESS_CALLBACK -DSQLITE_USE_ALLOCA -DSQLITE_DQS=0
  -DSQLITE_TEMP_STORE=3 -DNDEBUG "-Ivendor/$SQLITE")
LINK=(-static -l:liburing.a -lm)
if [ "${PGO:-1}" = 0 ]; then
  gcc "${FLAGS[@]}" -o bin/server src/server.c "${LINK[@]}"
else
  rm -f bin/*.gcda
  gcc "${FLAGS[@]}" -fprofile-generate -fprofile-update=single -o bin/server src/server.c "${LINK[@]}"
  training=$(mktemp -d)
  # A server that stops answering must fail the build, not hang it.
  SERVER_PROFILE_TRAINING=400000 SQLITE_PATH="$training/train.db" JWT_SECRET=profile-training HOST=127.0.0.1 PORT=39871 timeout 300 bin/server
  rm -rf "$training"
  gcc "${FLAGS[@]}" -fprofile-use -fprofile-correction -Wno-missing-profile -o bin/server src/server.c "${LINK[@]}"
fi
echo "built bin/server ($(wc -c < bin/server) bytes)"
