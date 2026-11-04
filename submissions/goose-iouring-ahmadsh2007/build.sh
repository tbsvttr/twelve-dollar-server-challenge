#!/usr/bin/env bash
# Builds bin/server as a normal user. Downloads the two pinned C dependencies (checksummed),
# compiles app.goose to C with the pinned Goose compiler, and links it with uring.c and sqlite.c.
# Profile-guided: SQLite and the whole program are each trained at build time on a synthetic
# database of their own (never the challenge seed). PGO=0 skips the training.
set -euo pipefail
cd "$(dirname "$0")"

goose_bin=${GOOSE_BIN:-$(command -v goose || true)}
[[ -n $goose_bin && -x $goose_bin ]] || { echo 'goose not found: run install.sh (or set GOOSE_BIN)' >&2; exit 1; }
goose_bin=$(readlink -f "$goose_bin")
want_runtime='runtime 3025e5810379'
[[ $("$goose_bin" version) == *"$want_runtime"* ]] || {
  echo "expected the Goose compiler with $want_runtime (install.sh pins it)" >&2; exit 1; }
goose_src=$(cd "$(dirname "$goose_bin")/.." && pwd)
[[ -f $goose_src/src/runtime/goose.h ]] || { echo 'the Goose source tree must sit beside its build directory' >&2; exit 1; }

mkdir -p .deps .build bin

SQ=sqlite-amalgamation-3540100
SQ_SHA=0a9c8e34352dad46006aa82836d5383bff9dc6bc9ce5a60553c05aa30e6ad1f9
LU=liburing-2.15
LU_SHA=8d052f2622dcb3678cbaee5ff582a87572672a6c0a56533cdda5b65cb636120a
if [[ ! -f .deps/sqlite3.c ]]; then
  curl -fsSL --retry 3 -o .deps/$SQ.zip "https://sqlite.org/2026/$SQ.zip"
  echo "$SQ_SHA  .deps/$SQ.zip" | sha256sum -c -
  unzip -o -j -q .deps/$SQ.zip -d .deps "$SQ/sqlite3.c" "$SQ/sqlite3.h"
fi
if [[ ! -f .deps/liburing/src/liburing.a ]]; then
  curl -fsSL --retry 3 -o .deps/$LU.tar.gz "https://github.com/axboe/liburing/archive/refs/tags/$LU.tar.gz"
  echo "$LU_SHA  .deps/$LU.tar.gz" | sha256sum -c -
  rm -rf .deps/liburing && mkdir -p .deps/liburing
  tar -xzf .deps/$LU.tar.gz -C .deps/liburing --strip-components=1
  (cd .deps/liburing && ./configure && make -C src -j"$(nproc)" liburing.a) > .deps/liburing-build.log 2>&1 \
    || { tail -30 .deps/liburing-build.log; echo 'liburing build failed' >&2; exit 1; }
fi

# Goose -O2 decides Goose's own inlining; the C compiler optimizes the generated C below.
"$goose_bin" -O2 --standalone -o .build/app.c app.goose
cp "$goose_src/src/runtime/goose.h" .build/goose.h

cc=${CC:-gcc}
# x86-64-v3 tuned for the box's Cascade Lake, AVX-512 kept off (on Cascade Lake a 512-bit
# instruction lowers the core's clock for the next ~0.5 ms). -march=native elsewhere.
if [[ $(uname -m) == x86_64 ]]; then
  arch=(-march=x86-64-v3 -mtune=cascadelake -mprefer-vector-width=256 -fcf-protection=none)
else
  arch=(-mcpu=native -mbranch-protection=none)
fi
# Ubuntu's gcc turns on stack protectors, stack-clash probes, _FORTIFY_SOURCE and CET by
# default; none of them earn their cost on this hot path.
common=(-O3 "${arch[@]}" -DNDEBUG -pthread -fno-plt -fno-semantic-interposition
        -fno-stack-protector -fno-stack-clash-protection -U_FORTIFY_SOURCE -fomit-frame-pointer
        -I.build -I.deps -I.deps/liburing/src/include ${EXTRA_CFLAGS:-})
sqlite_defs=(
  -DSQLITE_THREADSAFE=2 -DSQLITE_DEFAULT_MEMSTATUS=0 -DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1
  -DSQLITE_DQS=0 -DSQLITE_LIKE_DOESNT_MATCH_BLOBS -DSQLITE_MAX_EXPR_DEPTH=0 -DSQLITE_USE_ALLOCA
  -DSQLITE_OMIT_DEPRECATED -DSQLITE_OMIT_PROGRESS_CALLBACK -DSQLITE_OMIT_SHARED_CACHE
  -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_OMIT_AUTOINIT -DSQLITE_OMIT_UTF16 -DSQLITE_OMIT_TRACE
  -DSQLITE_OMIT_COMPLETE -DSQLITE_OMIT_GET_TABLE -DSQLITE_OMIT_TCL_VARIABLE
  -DHAVE_FDATASYNC=1 -DHAVE_USLEEP=1
)
libs=(.deps/liburing/src/liburing.a -lm -pthread)
units=(.build/app.c uring.c sqlite.c)

extra_objs=()
compile() { # compile <extra flags...>: every unit, then link
  local objs=()
  for u in "${units[@]}"; do
    local o=.build/$(basename "${u%.c}").o
    local defs=()
    [[ $u == sqlite.c ]] && defs=("${sqlite_defs[@]}")
    "$cc" "${common[@]}" "${defs[@]}" "$@" -c "$u" -o "$o"
    objs+=("$o")
  done
  "$cc" "${common[@]}" "$@" "${objs[@]}" "${extra_objs[@]}" "${libs[@]}" -static -o bin/server
}

if [[ ${PGO:-1} == 1 ]]; then
  prof=$PWD/.build/profile
  rm -rf "$prof"
  # The SIGTERM-to-exit() hook that writes the profile is linked into this build only.
  "$cc" "${common[@]}" -c train/pgo_exit.c -o .build/pgo_exit.o
  extra_objs=(.build/pgo_exit.o)
  compile -fprofile-generate="$prof" -fprofile-update=prefer-atomic
  python3 train/train.py bin/server
  extra_objs=()
  compile -fprofile-use="$prof" -fprofile-correction -fprofile-partial-training -Wno-missing-profile
else
  compile
fi
"$goose_bin" version
"$cc" --version | sed -n 1p
ls -la bin/server
