#!/usr/bin/env bash
# Architecture adaptation only: same Boehm GC commit/configuration as pinned x86 TCC bundle.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends git autoconf automake libtool libatomic-ops-dev
expected=c1a45b9ad86f7449509a86360a6c0746615d8c97
actual=$(cat /opt/vlang/thirdparty/tcc/lib/libgc_build_source_hash.txt)
[ "$actual" = "$expected" ]
work=$(mktemp -d)
git init -q "$work/bdwgc"
git -C "$work/bdwgc" remote add origin https://github.com/ivmai/bdwgc.git
git -C "$work/bdwgc" fetch -q --depth 1 origin "$expected"
git -C "$work/bdwgc" checkout -q FETCH_HEAD
[ "$(git -C "$work/bdwgc" rev-parse HEAD)" = "$expected" ]
cd "$work/bdwgc"
./autogen.sh
CC=gcc CFLAGS='-Os -mtune=generic -fPIC' LDFLAGS='-Os -fPIC' ./configure \
 --disable-dependency-tracking --disable-docs --enable-handle-fork=yes --enable-rwlock \
 --enable-threads=pthreads --enable-static --enable-shared=no --enable-parallel-mark \
 --enable-single-obj-compilation --enable-gc-debug --with-libatomic-ops=yes --enable-sigrt-signals
make -j2
cp .libs/libgc.a /opt/vlang/thirdparty/tcc/lib/libgc.a
ar p .libs/libgc.a gc.o > "$work/native-gc.o"
readelf -h "$work/native-gc.o"
readelf -h "$work/native-gc.o" | grep -q AArch64
printf 'Native ARM64 Boehm GC rebuilt at exact bundled commit %s\n' "$expected"
sha256sum /opt/vlang/thirdparty/tcc/lib/libgc.a
rm -rf "$work"
