#!/usr/bin/env bash
# Builds the server as a normal user. Lean checks every proof while compiling Feed/ to C.
set -euo pipefail
cd "$(dirname "$0")"
LEAN_HOME="${LEAN_HOME:-/opt/lean-nightly-2026-10-30}"
export PATH="$LEAN_HOME/bin:$PATH"
SQLITE=sqlite-amalgamation-3540100
SQLITE_SHA256=0a9c8e34352dad46006aa82836d5383bff9dc6bc9ce5a60553c05aa30e6ad1f9
mkdir -p vendor build bin
if [ ! -f "vendor/$SQLITE/sqlite3.c" ]; then
  curl -fsSL --retry 3 -o "vendor/$SQLITE.zip" "https://sqlite.org/2026/$SQLITE.zip"
  echo "$SQLITE_SHA256  vendor/$SQLITE.zip" | sha256sum -c -
  unzip -q -o "vendor/$SQLITE.zip" -d vendor
fi
LEAN_INC="$(lean --print-prefix)/include"
# lean.h needs FLT_EVAL_METHOD = 0, which gcc changes when the CPU has AVX512-FP16
NOFP16=""; echo "int x;" | cc -mno-avx512fp16 -x c -c -o /dev/null - 2>/dev/null && NOFP16="-mno-avx512fp16"
echo "== lake: check the proofs, compile Feed/ to C"
MODS="Main Feed.Bytes Feed.Json Feed.Sha256 Feed.Jwt Feed.Http Feed.Store Feed.Handler Feed.Server Feed.Spec Feed.Model Feed.Selftest"
lake build Feed $(for m in $MODS; do printf '%s:c ' "$m"; done)
LEAN_LIB="$(lean --print-prefix)/lib"

echo "== IR closure: the C functions that compiled Lean calls"
# Besides Lean's own runtime and library, the C emitted for the modules linked into bin/server, the
# self-test's excepted, calls exactly these C functions: the leaves of runtime/leaves.c, each checked
# by the self-test against its Lean definition; the storage operations of runtime/db.c
# (Feed/Store.lean), checked against the model; and what Main calls to start. The list is exact: the
# build stops at a call to a C function not on it, and at one on it that is no longer called (a
# leaf whose @[extern] was removed).
LEAVES="feed_http_parse feed_route feed_json_parse_top feed_json_decode_string feed_hmac_mac
  feed_b64_encode feed_b64_decode feed_find_byte feed_append_esc feed_append_nat feed_append_all
  feed_feed_from_page feed_page_authored feed_respond_feed feed_respond_post"
STORE="feed_db_begin feed_db_feed_page feed_db_post_page feed_db_health feed_db_end_reads feed_db_post_exists
  feed_db_insert_like feed_db_insert_post feed_db_commit"
START="feed_db_open feed_transport_run feed_train_run"
# cnames <file>: the names that preprocessed C on stdin calls, or makes closures of, inside function
# bodies on the lines from <file>; for a directory <dir>/, the names that its headers declare or
# define outside bodies.
cnames() {
  awk -v src="$1" 'BEGIN { dir = src ~ /\/$/ }
    /^# [0-9]+ "/ { f = substr($3, 2, length($3) - 2); here = dir ? index(f, src) == 1 : f == src; next }
    { s = $0; gsub(/"([^"\\]|\\.)*"/, "\"\"", s); c = s
      if (here && (dir ? depth == 0 : depth > 0)) {
        if (dir) sub(/\{.*/, "", c)
        t = c; while (match(t, /[A-Za-z_][A-Za-z0-9_]*\(/)) { print substr(t, RSTART, RLENGTH - 1); t = substr(t, RSTART + RLENGTH) }
        t = c; while (match(t, /\(void\*\)\([A-Za-z_][A-Za-z0-9_]*\)/)) { print substr(t, RSTART + 8, RLENGTH - 9); t = substr(t, RSTART + RLENGTH) }
      }
      depth += gsub(/\{/, "{", s) - gsub(/\}/, "}", s) }'
}
IRC=build/ir-closure; rm -rf "$IRC"; mkdir -p "$IRC"
# Lean's functions: the toolchain's (lean.h, the runtime, Init) and those the linked modules define
{ nm -g --defined-only "$LEAN_LIB/lean/libleanrt.a" "$LEAN_LIB/lean/libInit.a" 2>/dev/null | awk 'NF == 3 { print $3 }'
  echo '#include <lean/lean.h>' | cc -E -DNDEBUG -DLEAN_EXPORTING -I"$LEAN_INC" -x c - | cnames "$LEAN_INC/lean/"
  for m in $MODS; do sed -nE 's/^[A-Za-z_].*[ *]([A-Za-z_][A-Za-z0-9_]*)\(.*\) ?\{$/\1/p' ".lake/build/ir/${m//.//}.c"; done
} | LC_ALL=C sort -u > "$IRC/lean"
for m in $MODS; do
  [ "$m" = Feed.Selftest ] && continue
  f=".lake/build/ir/${m//.//}.c"
  cc -E -DNDEBUG -DLEAN_EXPORTING -I"$LEAN_INC" "$f" | cnames "$f" | sed "s/^/$m /"
done | LC_ALL=C sort -u > "$IRC/calls"
cut -d' ' -f2 "$IRC/calls" | LC_ALL=C sort -u | LC_ALL=C comm -23 - "$IRC/lean" |
  { grep -vxE 'if|for|while|switch|return|sizeof|__[A-Za-z0-9_]*' || true; } > "$IRC/foreign"
printf '%s\n' $LEAVES $STORE $START | LC_ALL=C sort -u > "$IRC/allowed"
if ! cmp -s "$IRC/foreign" "$IRC/allowed"; then
  LC_ALL=C comm -23 "$IRC/foreign" "$IRC/allowed" | while read -r x; do
    echo "compiled Lean calls $x, which is not on the list (in $(awk -v x="$x" '$2 == x { m = m (m ? " " : "") $1 } END { print m }' "$IRC/calls"))"; done
  LC_ALL=C comm -13 "$IRC/foreign" "$IRC/allowed" | while read -r x; do echo "$x is on the list, but compiled Lean does not call it"; done
  exit 1
fi
echo "compiled Lean calls $(wc -l < "$IRC/foreign") C functions, all on the list: $(echo $LEAVES | wc -w) leaves, $(echo $STORE | wc -w) storage operations, $(echo $START | wc -w) entry points"
# gcc compiles both the C that Lean emitted and the C runtime (SQLite, storage, leaves, transport),
# profile-guided: an instrumented build runs a made-up workload (runtime/train.c), then the
# final build uses the profile. Any failure there falls back to the plain build.
CFLAGS="-O3 -march=native $NOFP16 -fno-plt -pthread"
SQLDEFS="-DSQLITE_THREADSAFE=2 -DSQLITE_DEFAULT_MEMSTATUS=0 -DSQLITE_OMIT_DEPRECATED -DSQLITE_OMIT_SHARED_CACHE \
  -DSQLITE_USE_ALLOCA -DSQLITE_DQS=0 -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1 \
  -DSQLITE_OMIT_PROGRESS_CALLBACK -DSQLITE_MAX_EXPR_DEPTH=0 -DSQLITE_LIKE_DOESNT_MATCH_BLOBS"
JOBS="$(nproc)"   # one compiler at a time on the 1-vCPU box: gcc -O3 on SQLite takes most of its memory
compile() {  # compile <extra flags> <binary>
  local pids="" objs="" m o n=0
  cc $CFLAGS $1 -c -o build/server.o $SQLDEFS -I"$LEAN_INC" -Iruntime -I"vendor/$SQLITE" runtime/server.c &
  pids="$!"; n=1
  for m in $MODS; do
    if [ "$n" -ge "$JOBS" ]; then for p in $pids; do wait "$p" || return 1; done; pids=""; n=0; fi
    o="build/ir-$m.o"; objs="$objs $o"
    cc $CFLAGS $1 -w -DNDEBUG -DLEAN_EXPORTING -ffp-contract=off -c -o "$o" -I"$LEAN_INC" ".lake/build/ir/${m//.//}.c" &
    pids="$pids $!"; n=$((n + 1))
  done
  for p in $pids; do wait "$p" || return 1; done
  cc $CFLAGS $1 -o "$2" $objs build/server.o -L"$LEAN_LIB/lean" -Wl,--start-group -lInit -lleanrt -Wl,--end-group -lcadical \
    "$LEAN_LIB/libc++.a" "$LEAN_LIB/libc++abi.a" "$LEAN_LIB/libunwind.a" "$LEAN_LIB/libgmp.a" "$LEAN_LIB/libuv.a" \
    -lpthread -ldl -lrt -lm
}
PGO="$PWD/build/pgo"
pgo() {
  rm -rf "$PGO" build/train && mkdir -p "$PGO" build/train
  echo "== cc: instrumented build"
  compile "-fprofile-generate -fprofile-update=prefer-atomic -fprofile-dir=$PGO" bin/server-train || return 1
  echo "== training run"
  bin/server-train --train build/train || return 1
  echo "== cc: profile-guided build"
  compile "-fprofile-use -fprofile-partial-training -fprofile-dir=$PGO -Wno-missing-profile -Wno-error=coverage-mismatch" bin/server
}
if [ "${PGO_BUILD:-1}" = 1 ] && pgo; then :; else
  echo "== cc: plain build"
  compile "" bin/server
fi
rm -rf bin/server-train build/train

echo "== self-test: the C leaves and storage operations against their Lean definitions"
rm -f build/selftest.db*
bin/server --selftest build/selftest.db
rm -f build/selftest.db*
echo "built bin/server"
