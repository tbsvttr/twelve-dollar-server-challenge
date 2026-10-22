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
native_flags=(-flto=2 -fno-semantic-interposition -fno-plt)
sqlite_defines=(
  -DSQLITE_THREADSAFE=0 -DSQLITE_DEFAULT_MEMSTATUS=0 -DSQLITE_DQS=0
  -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_OMIT_DEPRECATED -DSQLITE_OMIT_SHARED_CACHE
  -DSQLITE_OMIT_PROGRESS_CALLBACK -DSQLITE_LIKE_DOESNT_MATCH_BLOBS -DSQLITE_USE_ALLOCA
  -DHAVE_FDATASYNC=1
)
# One fresh feedback pass and one LTO scope across generated Goose, native
# adapters/transport, and SQLite. No prebuilt object or benchmark seed is used.
command -v python3 >/dev/null || { echo 'Unified PGO training requires python3 (install.sh).' >&2; exit 1; }
profile="$PWD/.build/unified-profile"
app_objects="$PWD/.build/unified-native"
rm -rf "$profile" "$app_objects"
mkdir -p "$profile" "$app_objects"
units=(app net db json_fast sqlite-pgo)
sources=(.build/app.c net.c db.c json_fast.c .deps/sqlite3.c)
objects=("$app_objects/app.o" "$app_objects/net.o" "$app_objects/db.o"
         "$app_objects/json_fast.o" "$PWD/.build/sqlite-pgo.o")

compile_units() {
  local i
  local -a defines
  for i in "${!sources[@]}"; do
    defines=()
    if [[ ${units[$i]} == sqlite-pgo ]]; then defines=("${sqlite_defines[@]}"); fi
    "$cc" "${common[@]}" "${native_flags[@]}" "${defines[@]}" "$@" \
      -c "${sources[$i]}" -o "${objects[$i]}"
  done
}

# Uninstrumented helper is linked only into the training executable. Both
# passes otherwise retain identical source/defines/object paths/LTO options.
"$cc" "${common[@]}" -c bench/app_pgo_exit.c -o .build/app-pgo-exit.o
generate=("-fprofile-generate=$profile" -fprofile-update=atomic)
compile_units "${generate[@]}"
"$cc" "${common[@]}" "${native_flags[@]}" "${generate[@]}" \
  "${objects[@]}" .build/app-pgo-exit.o -lcrypto -lm -pthread -o bin/server
cp bin/server .build/server-unified-profiled
python3 bench/train_app.py .build/server-unified-profiled > .build/unified-pgo-training.json
mapfile -t profiles < <(find "$profile" -type f -name '*.gcda' -print)
[[ ${#profiles[@]} == 5 ]] || { echo 'Unified training requires exactly five fresh profiles.' >&2; exit 1; }
for unit in "${units[@]}"; do
  [[ -n $(find "$profile" -type f -name "$unit.gcda" -print -quit) ]] || {
    echo "Unified PGO training produced no $unit profile." >&2; exit 1;
  }
done
use=("-fprofile-use=$profile" -fprofile-correction -fprofile-partial-training
     -Werror=missing-profile -Werror=coverage-mismatch -Werror=lto-type-mismatch)
compile_units "${use[@]}"
"$cc" "${common[@]}" "${native_flags[@]}" "${use[@]}" \
  "${objects[@]}" -lcrypto -lm -pthread \
  -fopt-info-ipa-optimized=.build/unified-lto-ipa.txt -o bin/server
"$goose_bin" version
"$cc" --version | head -1
sha256sum bin/server
