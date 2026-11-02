#!/usr/bin/env bash
# Builds bin/server as a normal user: downloads the pinned SQLite amalgamation (SHA-256 checked), then Nelua
# compiles src/main.nelua to C and gcc builds that, with SQLite in the same translation unit, into a static binary.
set -euo pipefail
cd "$(dirname "$0")"
SQLITE=sqlite-amalgamation-3540100
SQLITE_SHA256=0a9c8e34352dad46006aa82836d5383bff9dc6bc9ce5a60553c05aa30e6ad1f9
mkdir -p vendor bin build
if [ ! -f "vendor/$SQLITE/sqlite3.c" ]; then
  curl -fsSL --retry 3 -o "vendor/$SQLITE.zip" "https://sqlite.org/2026/$SQLITE.zip"
  echo "$SQLITE_SHA256  vendor/$SQLITE.zip" | sha256sum -c - >/dev/null
  unzip -q -o "vendor/$SQLITE.zip" -d vendor
fi
# SQLite: no mutexes on the request path (THREADSAFE=2, and every connection is opened NOMUTEX: the checkpoint
# thread has its own), no memory statistics, no progress-callback check per opcode, nothing unused.
SQLOPTS="-DSQLITE_THREADSAFE=2 -DSQLITE_DEFAULT_MEMSTATUS=0 -DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1 \
  -DSQLITE_OMIT_PROGRESS_CALLBACK -DSQLITE_OMIT_SHARED_CACHE -DSQLITE_OMIT_DEPRECATED -DSQLITE_OMIT_LOAD_EXTENSION \
  -DSQLITE_OMIT_AUTOINIT -DSQLITE_USE_ALLOCA -DSQLITE_DQS=0 -DSQLITE_LIKE_DOESNT_MATCH_BLOBS \
  -DSQLITE_MAX_EXPR_DEPTH=0 -DSQLITE_OMIT_DECLTYPE -DSQLITE_OMIT_UTF16 -DSQLITE_OMIT_TRACE \
  -DSQLITE_OMIT_GET_TABLE -DSQLITE_OMIT_COMPLETE -DSQLITE_TEMP_STORE=3 -DHAVE_FDATASYNC=1 -DHAVE_USLEEP=1 -DNDEBUG"
case "$(uname -m)" in
  x86_64) ARCH="-march=x86-64-v3 -mtune=cascadelake -mprefer-vector-width=256" ;;
  *) ARCH="-mcpu=native" ;;
esac
CFLAGS="-O3 $ARCH -fno-plt -fno-semantic-interposition -fno-stack-protector -fomit-frame-pointer \
  -Wno-unused-function -Wno-unused-variable -Wno-unused-but-set-variable \
  -I$PWD/src -I$PWD/vendor/$SQLITE $SQLOPTS -static"
/opt/nelua/bin/nelua --release --no-cache --cache-dir build -L src --cflags="$CFLAGS" -o bin/server src/main.nelua
echo "built bin/server ($(stat -c %s bin/server) bytes)"
