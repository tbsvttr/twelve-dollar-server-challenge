#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends build-essential ca-certificates curl

TOOLCHAIN="1.90.0"
export RUSTUP_HOME=/opt/rust
export CARGO_HOME=/opt/rust

# Install pinned rust toolchain system-wide if not matching
if ! /opt/rust/bin/rustc --version 2>/dev/null | grep -q "$TOOLCHAIN"; then
    installer=$(mktemp)
    trap 'rm -f "$installer"' EXIT
    curl -fsSL --retry 3 https://sh.rustup.rs -o "$installer"
    sh "$installer" -y --no-modify-path --profile minimal --default-toolchain "$TOOLCHAIN"
    chmod -R a+rX /opt/rust
fi

# Wrapper scripts in /usr/local/bin (do NOT force CARGO_HOME so unprivileged users can use their own)
for tool in cargo rustc; do
    printf '#!/bin/sh\nexport RUSTUP_HOME=/opt/rust\nexec /opt/rust/bin/%s "$@"\n' "$tool" > "/usr/local/bin/$tool"
    chmod 755 "/usr/local/bin/$tool"
done
