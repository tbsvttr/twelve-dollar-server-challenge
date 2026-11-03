#!/usr/bin/env bash
# Runs the server in the foreground. Config: SQLITE_PATH, JWT_SECRET, HOST, PORT.
# RUNTIME picks the build: kn (default, Kotlin/Native over io_uring direct descriptors, what build.sh makes),
# graal-static (GraalVM native image), graal-jit (GraalVM JDK), node (Kotlin/JS on Node.js), wasi (Kotlin/Wasm on
# wasmtime); bench/all1000.sh builds all five. A runtime whose build is missing falls back along kn, graal-static,
# graal-jit. The GraalVM builds serve
# through the io_uring ring (TRANSPORT=ring) unless TRANSPORT says otherwise; Node and wasmtime poll their sockets.
set -euo pipefail
cd "$(dirname "$0")"
KN=server/build/bin/linuxX64/feedReleaseExecutable/feed.kexe
STATIC=server/build/native/feed-static
NODE_MAIN=server/build/dist/node/server.js
WASI_MAIN=server/build/dist/wasi/server.wasm
LIB="$PWD/server/build/sqlite/libsqlite3.so"; [ -f "$LIB" ] || LIB="$PWD/server/build/sqlite/libsqlite3.dylib"
JAVA=/opt/graalvm/bin/java; [ -x "$JAVA" ] || JAVA="${JAVA_HOME:+$JAVA_HOME/bin/}java"
runtime=${RUNTIME:-kn}
[ "$runtime" = kn ] && [ ! -x "$KN" ] && runtime=graal-static
[ "$runtime" = graal-static ] && [ ! -x "$STATIC" ] && runtime=graal-jit
echo "start.sh: RUNTIME=$runtime" >&2
case "$runtime" in
  kn)
    exec "$KN" ;;
  graal-static)
    export TRANSPORT=${TRANSPORT:-ring}
    exec "$STATIC" -Xms384m -Xmx384m -Dsqlite.lib="$LIB" ;;
  graal-jit)
    export TRANSPORT=${TRANSPORT:-ring}
    exec "$JAVA" -XX:+UseSerialGC -Xms384m -Xmx384m -XX:-UsePerfData \
      --enable-native-access=ALL-UNNAMED -Dsqlite.lib="$LIB" \
      -cp "server/build/app/*" borg.trikeshed.feed.MainKt ;;
  node)
    NODE=/opt/node/bin/node; [ -x "$NODE" ] || NODE=node
    exec "$NODE" "$NODE_MAIN" ;;
  wasi)
    # wasmtime 46: the last release with WASI preview 1 sockets (-S preview2=n -S tcplisten; 47 removed them).
    WASMTIME=$(command -v wasmtime) || { echo "start.sh: no wasmtime on PATH" >&2; exit 1; }
    "$WASMTIME" --version | grep -qE '^wasmtime (4[0-6]|[1-3][0-9])\.' ||
      { echo "start.sh: $("$WASMTIME" --version): -S tcplisten needs wasmtime 46 or older" >&2; exit 1; }
    db_dir=$(dirname "$SQLITE_PATH")
    exec "$WASMTIME" run -W gc=y,function-references=y,exceptions=y -S preview2=n \
      -S tcplisten="${HOST:-0.0.0.0}:${PORT:-80}" --dir "$db_dir::$db_dir" \
      --preload sqlite=server/build/dist/wasi/sqlite.wasm --env SQLITE_PATH --env JWT_SECRET "$WASI_MAIN" ;;
  *)
    echo "start.sh: RUNTIME must be kn, graal-static, graal-jit, node or wasi (got $runtime)" >&2; exit 2 ;;
esac
