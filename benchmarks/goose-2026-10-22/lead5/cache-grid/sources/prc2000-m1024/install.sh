#!/usr/bin/env bash
set -euo pipefail
# Ubuntu 24.04; run as root. The compiler and all its dependencies build from source.
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends build-essential cmake ninja-build libssl-dev curl ca-certificates
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
  cmake -S "$prefix" -B "$prefix/build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DGOOSE_BUILTIN_LIBS=
  cmake --build "$prefix/build" --parallel "${BUILD_JOBS:-2}"
  printf '%s\n' "$goose_commit" > "$prefix/COMMIT"
fi
ln -sf "$prefix/build/goose" /usr/local/bin/goose
"$prefix/build/goose" version
