#!/usr/bin/env bash
set -euo pipefail
# Ubuntu 24.04; run as root. The compiler and all its dependencies build from source.
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends build-essential cmake ninja-build libssl-dev curl ca-certificates python3
goose_commit=f605b5a07dd2aa3a5cb3f4c9b14002bd3c9d3d1a
goose_sha=86482df9e11ff9472d2214e93a71cd7f22b05d31260f66d7e760d5df784a7e92
prefix=/opt/goose-f605b5a07dd2
if [[ ! -x $prefix/build/goose ]]; then
  source_archive=$(mktemp)
  trap 'rm -f "$source_archive"' EXIT
  curl -fsSL --retry 3 "https://codeload.github.com/aardappel/goose/tar.gz/$goose_commit" -o "$source_archive"
  printf '%s  %s\n' "$goose_sha" "$source_archive" | sha256sum -c -
  mkdir -p "$prefix"
  tar -xzf "$source_archive" --strip-components=1 -C "$prefix"
  # The compiler is one large C++20 translation unit: at gcc's defaults (-O3, default collector) compiling it took
  # more than 1.5 GB and froze the 2 GB box. One job, -O2 and a tighter collector (garbage is collected more
  # often) keep it near 1.2 GB. The compiler's own optimization doesn't change the C it generates; build.sh
  # compiles that at -O3.
  rm -rf "$prefix/build"
  cmake -S "$prefix" -B "$prefix/build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DGOOSE_BUILTIN_LIBS= \
    "-DCMAKE_CXX_FLAGS_RELEASE=-O2 -DNDEBUG --param ggc-min-expand=5 --param ggc-min-heapsize=16384" \
    "-DCMAKE_C_FLAGS_RELEASE=-O2 -DNDEBUG"
  cmake --build "$prefix/build" --parallel "${BUILD_JOBS:-1}"
  printf '%s\n' "$goose_commit" > "$prefix/COMMIT"
fi
ln -sf "$prefix/build/goose" /usr/local/bin/goose
"$prefix/build/goose" version
