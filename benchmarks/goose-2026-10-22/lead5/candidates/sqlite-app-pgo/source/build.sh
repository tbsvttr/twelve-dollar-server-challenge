#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

goose_bin=${GOOSE_BIN:-$(command -v goose || true)}
if [[ -z $goose_bin || ! -x $goose_bin ]]; then
  echo 'Run install.sh to build the pinned Goose compiler, or set GOOSE_BIN.' >&2
  exit 1
fi
goose_bin=$(readlink -f "$goose_bin")
[[ $("$goose_bin" version) == 'goose runtime df5f78ce88d4' ]] || {
  echo 'Expected Goose runtime df5f78ce88d4 from compiler commit f605b5a07dd2aa3a5cb3f4c9b14002bd3c9d3d1a.' >&2
  exit 1
}

mkdir -p .deps .build bin
sqlite_sha=0e9483900e92cd5de8fd48d16bf9200145a61f7fd5be542a5ac81d8a9516eb9c
if [[ ! -f .deps/sqlite.tar.gz ]]; then
  curl -fsSL --retry 3 https://www.sqlite.org/2026/sqlite-autoconf-3530400.tar.gz -o .deps/sqlite.tar.gz
fi
printf '%s  %s\n' "$sqlite_sha" .deps/sqlite.tar.gz | sha256sum -c -
tar -xzf .deps/sqlite.tar.gz -C .deps --strip-components=1 \
  sqlite-autoconf-3530400/sqlite3.c sqlite-autoconf-3530400/sqlite3.h

# Keep the generated program visible for compiler inspection and reproducibility.
# -O2 controls Goose inlining; GCC -O3 optimizes every generated/native C file.
"$goose_bin" -O2 --standalone -o .build/app.c app.goose
goose_source=$(cd "$(dirname "$goose_bin")/.." && pwd)
[[ -f $goose_source/src/runtime/goose.h ]] || {
  echo 'The Goose compiler source tree is required beside its build directory.' >&2
  exit 1
}
cp "$goose_source/src/runtime/goose.h" .build/goose.h

cc=${CC:-gcc}
common=(-O3 -march=native -DNDEBUG -std=gnu11 -I.deps -I.build -pthread)
sqlite_defines=(
  -DSQLITE_THREADSAFE=0 -DSQLITE_DEFAULT_MEMSTATUS=0 -DSQLITE_DQS=0
  -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_OMIT_DEPRECATED -DSQLITE_OMIT_SHARED_CACHE
  -DSQLITE_OMIT_PROGRESS_CALLBACK -DSQLITE_LIKE_DOESNT_MATCH_BLOBS -DSQLITE_USE_ALLOCA
  -DHAVE_FDATASYNC=1
)
# Isolated experiment: profile SQLite through this application's real queries
# and independent synthetic HTTP databases. Application/native C has ordinary
# O3/native/LTO in both builds, without application PGO. No seed data is read.
profile="$PWD/.build/sqlite-profile"
object="$PWD/.build/sqlite-pgo.o"
native_flags=(-flto=2 -fno-semantic-interposition -fno-plt)
command -v python3 >/dev/null || { echo 'SQLite HTTP training requires python3 (install.sh).' >&2; exit 1; }
rm -rf "$profile"
mkdir -p "$profile"
"$cc" "${common[@]}" "${sqlite_defines[@]}" "-fprofile-generate=$profile" \
  -fprofile-update=atomic -c .deps/sqlite3.c -o "$object"
"$cc" "${common[@]}" -c bench/app_pgo_exit.c -o .build/app-pgo-exit.o
# Link libgcov explicitly, so the LTO application itself is not compiled with
# profile-generate. Only the already compiled SQLite object has counters.
"$cc" "${common[@]}" "${native_flags[@]}" \
  .build/app.c net.c db.c json_fast.c "$object" .build/app-pgo-exit.o \
  -lcrypto -lm -pthread -lgcov -o bin/server
cp bin/server .build/server-sqlite-profiled
python3 bench/train_app.py .build/server-sqlite-profiled > .build/sqlite-app-pgo-training.json
mapfile -t profiles < <(find "$profile" -type f -name '*.gcda' -print)
[[ ${#profiles[@]} == 1 && ${profiles[0]} == */sqlite-pgo.gcda ]] || {
  echo 'Expected exactly one freshly trained SQLite profile, without application profiles.' >&2; exit 1;
}
"$cc" "${common[@]}" "${sqlite_defines[@]}" "-fprofile-use=$profile" \
  -fprofile-correction -Werror=missing-profile -Werror=coverage-mismatch \
  -c .deps/sqlite3.c -o "$object"
# Production is the original ordinary application LTO pipeline. It has neither
# application profile instrumentation nor the training-only poll interposer.
"$cc" "${common[@]}" "${native_flags[@]}" \
  .build/app.c net.c db.c json_fast.c "$object" -lcrypto -lm -pthread -o bin/server
"$goose_bin" version
"$cc" --version | head -1
sha256sum bin/server
