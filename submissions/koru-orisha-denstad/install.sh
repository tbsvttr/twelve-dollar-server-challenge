#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04 box.
set -euo pipefail
apt-get update
apt-get install -y --no-install-recommends \
    build-essential ca-certificates curl git xz-utils \
    libssl-dev zlib1g-dev libsqlite3-dev
# zig 0.15.2 x86_64 — the backend koruc emits and builds
curl -fsSL https://ziglang.org/download/0.15.2/zig-x86_64-linux-0.15.2.tar.xz \
    | tar -xJ -C /usr/local
ln -sf /usr/local/zig-x86_64-linux-0.15.2/zig /usr/local/bin/zig
