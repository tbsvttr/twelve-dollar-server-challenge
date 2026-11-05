#!/usr/bin/env bash
# Builds the server as a normal user. All sources are pinned hashes.
set -euo pipefail
cd "$(dirname "$0")"
SUB_DIR="$PWD"

KORU_HASH=01b2d5c9bdcdc64573f5da9fd7ecf862cdbc49a5
ORISHA_HASH=6d8502682c5f462e378e5c947d0348d74df82eaa
KORULIBS_HASH=9a60d33452f7f0289375761e393f6f622edb2743

SRC="$PWD/.src"
mkdir -p "$SRC"
clone() {
    local repo=$1 hash=$2 dir=$3
    if [ ! -d "$dir/.git" ]; then
        git clone --quiet "$repo" "$dir"
    fi
    git -C "$dir" checkout --quiet "$hash"
}
clone https://github.com/korulang/koru.git      "$KORU_HASH"     "$SRC/koru"
clone https://github.com/korulang/orisha.git    "$ORISHA_HASH"   "$SRC/orisha"
clone https://github.com/korulang/koru-libs.git "$KORULIBS_HASH" "$SRC/koru-libs"

# Build the koru compiler, then the app through it.
cd "$SRC/koru"
zig build
# koruc resolves its compiler sources at <prefix>/src — zig-out is the prefix.
ln -sfn "$SRC/koru/src" "$SRC/koru/zig-out/src"
ln -sfn "$SRC/koru/koru_std" "$SRC/koru/zig-out/koru_std"
cd "$SUB_DIR/twelve"
export KORU_STDLIB="$SRC/koru/koru_std"
export KORU_PATH="$SRC/koru"
mkdir -p "$SUB_DIR/bin"
"$SRC/koru/zig-out/bin/koruc" main.k --release=fast --build=io-uring -o "$SUB_DIR/bin/server"
