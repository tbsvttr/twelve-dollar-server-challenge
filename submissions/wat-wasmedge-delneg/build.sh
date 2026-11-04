#!/usr/bin/env bash
# Builds as a normal user into ./build (toolchain from install.sh in /opt/wat-tdsc):
#   1. src/sqlite_glue.c, which #includes the SQLite 3.54.1 amalgamation (pinned sha256) -> sq.wasm (wasi-sdk clang, WASI reactor)
#   2. src/app.wat -> app.wasm (wat2wasm)
#   3. wasm-merge sq.wasm + app.wasm -> merged.wasm; wasm-opt -O3; `wasmedge compile` -> app.so (AOT native code)
#   4. src/host.c -> host (gcc, links libwasmedge)
set -euo pipefail
cd "$(dirname "$0")"
T=${WAT_TDSC_TOOLS:-/opt/wat-tdsc}; WS=$T/wasi-sdk; WE=$T/wasmedge
SQ=sqlite-amalgamation-3540100; SQ_SHA=0a9c8e34352dad46006aa82836d5383bff9dc6bc9ce5a60553c05aa30e6ad1f9
mkdir -p build; cd build
if [ ! -f $SQ/sqlite3.c ]; then
  curl -fsSL https://www.sqlite.org/2026/$SQ.zip -o sqlite.zip
  echo "$SQ_SHA  sqlite.zip" | sha256sum -c - >/dev/null
  unzip -qo sqlite.zip && rm sqlite.zip
fi
# USE_PREAD: positioned reads/writes (fd_pread/fd_pwrite) instead of a seek before each, one syscall less per page
F="-O2 -D_GNU_SOURCE -DSQLITE_THREADSAFE=0 -DSQLITE_DEFAULT_MEMSTATUS=0 -DSQLITE_OMIT_LOAD_EXTENSION -DUSE_PREAD"
# exports: every function app.wat imports from "sq", and the function table (app.wat adds its callbacks to it)
EX="-Wl,--export=ckpt_main $(sed -n 's/^ *(import "sq" "\([a-z0-9_]*\)" (func.*/-Wl,--export=\1/p' ../src/app.wat)"
$WS/bin/clang --target=wasm32-wasip1 $F -I$SQ -mexec-model=reactor $EX -Wl,--export-table -Wl,--growable-table \
  -Wl,-z,stack-size=1048576 -Wl,--global-base=16777216 -o sq.wasm ../src/sqlite_glue.c   # it #includes $SQ/sqlite3.c
$T/wabt/bin/wat2wasm --enable-all ../src/app.wat -o app.wasm
$T/binaryen/bin/wasm-merge --enable-simd --enable-bulk-memory --enable-reference-types sq.wasm sq app.wasm app -o merged.wasm
$T/binaryen/bin/wasm-opt -O3 --enable-simd --enable-bulk-memory --enable-reference-types merged.wasm -o merged.opt.wasm
LD_LIBRARY_PATH=$WE/lib $WE/bin/wasmedge compile --optimize=3 merged.opt.wasm app.so >/dev/null
gcc -O2 -o host ../src/host.c -I$WE/include -L$WE/lib -lwasmedge -Wl,-rpath,$WE/lib
echo "built build/app.so and build/host"
