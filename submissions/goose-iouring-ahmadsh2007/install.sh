#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04: the C toolchain, then the Goose compiler built from
# its pinned source (sha256-checked) into /opt, linked onto the build user's PATH.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
if [[ $(id -u) == 0 ]]; then
  apt-get update
  apt-get install -y --no-install-recommends build-essential cmake ninja-build curl ca-certificates unzip python3
fi
commit=369c7a2cfca74bfcee60379727e8bdfd83da2d75
sha=83dd689acb314930bb8f38a911d9bb9fec00b8dad0d3191eabe1c837d2f33f12
prefix=${GOOSE_PREFIX:-/opt/goose-369c7a2c}
if [[ ! -x $prefix/build/goose ]]; then
  src=$(mktemp)
  trap 'rm -f "$src"' EXIT
  curl -fsSL --retry 3 "https://codeload.github.com/aardappel/goose/tar.gz/$commit" -o "$src"
  printf '%s  %s\n' "$sha" "$src" | sha256sum -c -
  rm -rf "$prefix"
  mkdir -p "$prefix"
  tar -xzf "$src" --strip-components=1 -C "$prefix"
  # The compiler is one large C++20 translation unit. At gcc's defaults it can take more than
  # 1.5 GB, which a 2 GB box does not have to spare; one job at -O2 with a tighter collector
  # (garbage collected more often) keeps it well under. The compiler's own optimization level
  # does not change the C it generates; build.sh compiles that at -O3.
  cmake -S "$prefix" -B "$prefix/build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DGOOSE_BUILTIN_LIBS= \
    "-DCMAKE_CXX_FLAGS_RELEASE=-O2 -DNDEBUG --param ggc-min-expand=5 --param ggc-min-heapsize=16384" \
    "-DCMAKE_C_FLAGS_RELEASE=-O2 -DNDEBUG"
  cmake --build "$prefix/build" --parallel 1
  printf '%s\n' "$commit" > "$prefix/COMMIT"
fi
if [[ $(id -u) == 0 ]]; then ln -sf "$prefix/build/goose" /usr/local/bin/goose; fi
"$prefix/build/goose" version
