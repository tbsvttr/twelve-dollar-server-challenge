#!/usr/bin/env bash
set -euo pipefail
src=$1
out=$2
cc=$3
cxx=$4
ar=$5
trainer=$6

define=(
    -DSQLITE_THREADSAFE=0 -DSQLITE_MAX_EXPR_DEPTH=0 -DSQLITE_OMIT_AUTOINIT -DSQLITE_DQS=0 -DSQLITE_DEFAULT_MEMSTATUS=0 -DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1
    -DSQLITE_LIKE_DOESNT_MATCH_BLOBS -DSQLITE_OMIT_DEPRECATED -DSQLITE_OMIT_SHARED_CACHE
    -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_OMIT_PROGRESS_CALLBACK -DSQLITE_USE_ALLOCA
)
flags=(-O3 "${SQLITE_ARCH_FLAG:--march=native}" -DNDEBUG)
obj="$out/pgo/sqlite3.o"

mkdir -p "$out/pgo"
rm -f "$out/pgo/"*.gcda "$obj" "$out/libsqlite3_pgo.a"

train() {
    "$cc" "${flags[@]}" "${define[@]}" -fprofile-generate -fprofile-update=single -c "$src/sqlite3.c" -o "$obj" &&
        "$cxx" -O2 -std=c++17 -I"$src" -c "$trainer" -o "$out/train.o" &&
        "$cxx" "$out/train.o" "$obj" -fprofile-generate -lpthread -lm -o "$out/train" &&
        work=$(mktemp -d) &&
        "$out/train" "$work/train.db" 60000 &&
        rm -rf "$work" &&
        compgen -G "$out/pgo/*.gcda" >/dev/null
}

if train; then
    "$cc" "${flags[@]}" "${define[@]}" -fprofile-use -fprofile-correction -Wno-missing-profile -c "$src/sqlite3.c" -o "$obj"
else
    echo "profile training failed; building SQLite without PGO" >&2
    "$cc" "${flags[@]}" "${define[@]}" -c "$src/sqlite3.c" -o "$obj"
fi
"$ar" rcs "$out/libsqlite3_pgo.a" "$obj"
