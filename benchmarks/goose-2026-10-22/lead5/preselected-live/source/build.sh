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
# SQLite and application receive separate feedback, using the same generated
# application and current database configuration. Both trainers are build-only.
sqlite_pgo_mode=${GOOSE_SQLITE_PGO_MODE:-app}
case "$sqlite_pgo_mode" in
  app|legacy) ;;
  *) echo 'GOOSE_SQLITE_PGO_MODE must be app or legacy.' >&2; exit 1 ;;
esac
profile="$PWD/.build/sqlite-profile"
object="$PWD/.build/sqlite-pgo.o"
trainer="$PWD/.build/sqlite-train"
if [[ -n ${GOOSE_REUSE_SQLITE_PGO_SHA256:-} ]]; then
  # Optional experiment cache: reuse only an explicitly verified native object.
  # A normal source build always generates fresh SQLite profile feedback.
  printf '%s  %s\n' "$GOOSE_REUSE_SQLITE_PGO_SHA256" "$object" | sha256sum -c -
else
  rm -rf "$profile"
  mkdir -p "$profile"
  if [[ $sqlite_pgo_mode == app ]]; then
    command -v python3 >/dev/null || { echo 'SQLite HTTP training requires python3 (install.sh).' >&2; exit 1; }
    "$cc" "${common[@]}" "${sqlite_defines[@]}" "-fprofile-generate=$profile" \
      -fprofile-update=atomic -c .deps/sqlite3.c -o "$object"
    "$cc" "${common[@]}" -c bench/app_pgo_exit.c -o .build/app-pgo-exit.o
    # Explicit libgcov links the instrumented SQLite object without adding
    # profile-generate to the ordinary application/native LTO compilation.
    "$cc" "${common[@]}" "${native_flags[@]}" \
      .build/app.c net.c db.c json_fast.c "$object" .build/app-pgo-exit.o \
      -lcrypto -lm -pthread -lgcov -o bin/server
    cp bin/server .build/server-sqlite-profiled
    python3 bench/train_app.py .build/server-sqlite-profiled > .build/sqlite-app-pgo-training.json
  else
    # Preserve the original credited synthetic SQL trainer for comparison.
    "$cc" "${common[@]}" "${sqlite_defines[@]}" "-fprofile-generate=$profile" \
      -c .deps/sqlite3.c -o "$object"
    "$cc" "${common[@]}" "${sqlite_defines[@]}" "-fprofile-generate=$profile" \
      bench/train_sqlite.c "$object" -lm -o "$trainer"
    "$trainer" "$PWD/.build/training.db"
  fi
  mapfile -t profiles < <(find "$profile" -type f -name '*.gcda' -print)
  [[ ${#profiles[@]} -gt 0 ]] || { echo 'SQLite PGO training produced no profile.' >&2; exit 1; }
  if [[ $sqlite_pgo_mode == app ]]; then
    [[ ${#profiles[@]} == 1 && ${profiles[0]:-} == */sqlite-pgo.gcda ]] || {
      echo 'Expected exactly one freshly trained SQLite profile.' >&2; exit 1;
    }
  fi
  "$cc" "${common[@]}" "${sqlite_defines[@]}" "-fprofile-use=$profile" \
    -fprofile-correction -Werror=missing-profile -Werror=coverage-mismatch \
    -c .deps/sqlite3.c -o "$object"
  rm -f .build/training.db .build/training.db-wal .build/training.db-shm
fi
# Optimize across generated Goose, transport and primitive FFI adapters. SQLite
# keeps its separately trained native PGO object during application training.
if [[ ${GOOSE_APP_PGO:-1} == 1 ]]; then
  command -v python3 >/dev/null || { echo 'Application PGO training requires python3 (install.sh).' >&2; exit 1; }
  app_profile="$PWD/.build/app-profile"
  app_objects="$PWD/.build/app-native"
  rm -rf "$app_profile" "$app_objects"
  mkdir -p "$app_profile" "$app_objects"
  units=(app net db json_fast)
  sources=(.build/app.c net.c db.c json_fast.c)
  objects=()
  for unit in "${units[@]}"; do objects+=("$app_objects/$unit.o"); done
  # The helper is deliberately uninstrumented and absent from production.
  # Application sources/defines and object paths match in both PGO passes.
  "$cc" "${common[@]}" -c bench/app_pgo_exit.c -o .build/app-pgo-exit.o
  generate=("-fprofile-generate=$app_profile" -fprofile-update=atomic)
  for i in "${!sources[@]}"; do
    "$cc" "${common[@]}" "${native_flags[@]}" "${generate[@]}" \
      -c "${sources[$i]}" -o "${objects[$i]}"
  done
  "$cc" "${common[@]}" "${native_flags[@]}" "${generate[@]}" \
    "${objects[@]}" "$object" .build/app-pgo-exit.o -lcrypto -lm -pthread -o bin/server
  cp bin/server .build/server-profiled
  python3 bench/train_app.py .build/server-profiled > .build/app-pgo-training.json
  for unit in "${units[@]}"; do
    [[ -n $(find "$app_profile" -type f -name "$unit.gcda" -print -quit) ]] || {
      echo "Application PGO training produced no $unit profile." >&2; exit 1;
    }
  done
  use=("-fprofile-use=$app_profile" -fprofile-correction -fprofile-partial-training
       -Werror=missing-profile -Werror=coverage-mismatch)
  for i in "${!sources[@]}"; do
    "$cc" "${common[@]}" "${native_flags[@]}" "${use[@]}" \
      -c "${sources[$i]}" -o "${objects[$i]}"
  done
  "$cc" "${common[@]}" "${native_flags[@]}" "${use[@]}" \
    "${objects[@]}" "$object" -lcrypto -lm -pthread -o bin/server
else
  "$cc" "${common[@]}" "${native_flags[@]}" \
    .build/app.c net.c db.c json_fast.c "$object" -lcrypto -lm -pthread -o bin/server
fi
"$goose_bin" version
"$cc" --version | head -1
sha256sum bin/server
