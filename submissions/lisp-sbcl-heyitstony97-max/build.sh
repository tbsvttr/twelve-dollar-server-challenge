#!/usr/bin/env bash
# Builds the server as a normal user:
#   1. fetches the pinned SQLite amalgamation (sha256-checked) into vendor/
#   2. gcc compiles csrc/shim.c (which #includes the unmodified sqlite3.c) into build/shim.so
#   3. SBCL 2.6.10 loads shim.so, compiles src/*.lisp and saves bin/server (a self-contained executable)
set -euo pipefail
cd "$(dirname "$0")"
HERE="$(pwd)"
SQ=sqlite-amalgamation-3540100
SQ_SHA=0a9c8e34352dad46006aa82836d5383bff9dc6bc9ce5a60553c05aa30e6ad1f9
SBCL="${SBCL:-/usr/local/bin/sbcl}"

mkdir -p vendor build bin
if [ ! -f vendor/sqlite3.c ]; then
  curl -fsSL --retry 3 -o vendor/$SQ.zip "https://www.sqlite.org/2026/$SQ.zip"
  echo "$SQ_SHA  vendor/$SQ.zip" | sha256sum -c -
  unzip -qoj vendor/$SQ.zip "$SQ/sqlite3.c" "$SQ/sqlite3.h" -d vendor
  rm -f vendor/$SQ.zip
fi

# THREADSAFE=2: connections are never shared between threads (the loop owns one; M2's checkpoint
# thread owns its own), so SQLite takes no mutexes of its own.
if [ ! -f build/shim.so ] || [ csrc/shim.c -nt build/shim.so ] || [ vendor/sqlite3.c -nt build/shim.so ]; then
  gcc -O3 -march=native -fno-plt -fPIC -shared -w -Ivendor \
    -DSQLITE_THREADSAFE=2 -DSQLITE_DEFAULT_MEMSTATUS=0 -DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1 -DSQLITE_DQS=0 \
    -DSQLITE_LIKE_DOESNT_MATCH_BLOBS -DSQLITE_MAX_EXPR_DEPTH=0 -DSQLITE_OMIT_DEPRECATED \
    -DSQLITE_OMIT_PROGRESS_CALLBACK -DSQLITE_OMIT_SHARED_CACHE -DSQLITE_OMIT_LOAD_EXTENSION \
    -DSQLITE_OMIT_AUTOINIT -DSQLITE_OMIT_UTF16 -DSQLITE_OMIT_TRACE -DSQLITE_OMIT_COMPLETE \
    -DSQLITE_OMIT_GET_TABLE -DSQLITE_OMIT_TCL_VARIABLE -DSQLITE_USE_ALLOCA \
    -DHAVE_FDATASYNC=1 -DHAVE_USLEEP=1 \
    csrc/shim.c -o build/shim.so -lm -lpthread
fi

"$SBCL" --noinform --non-interactive --no-sysinit --no-userinit \
  --eval '(unless (string= (lisp-implementation-version) "2.6.10") (sb-ext:exit :code 1))' \
  || { echo "need SBCL 2.6.10 (set SBCL=/path/to/sbcl)"; exit 1; }

rm -f bin/server
SHIM_SO="$HERE/build/shim.so" BUILD_DIR="$HERE" \
"$SBCL" --noinform --disable-ldb --lose-on-corruption --dynamic-space-size 512MB --control-stack-size 2MB \
  --non-interactive --no-sysinit --no-userinit --load build.lisp
test -x bin/server
echo "built bin/server"
