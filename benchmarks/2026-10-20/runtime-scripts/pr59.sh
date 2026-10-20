#!/usr/bin/env bash
# Runtime-only ARM64 setup; submitted application/build scripts remain unchanged.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export PATH=/opt/twelve-rust/cargo/bin:/opt/ruby/bin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export RUSTUP_HOME=/opt/twelve-rust/rustup
# Bound source compiler jobs to the same build CPU budget.
printf '#!/bin/sh\necho 2\n' >/usr/local/bin/nproc
chmod +x /usr/local/bin/nproc
work=$(mktemp -d)
base=https://github.com/oven-sh/bun/releases/download/bun-v1.3.14
curl -fsSL "$base/bun-linux-aarch64.zip" -o "$work/bun-linux-aarch64.zip"
curl -fsSL "$base/SHASUMS256.txt" -o "$work/SHASUMS256.txt"
(cd "$work" && grep ' bun-linux-aarch64.zip$' SHASUMS256.txt | sha256sum -c -)
unzip -q "$work/bun-linux-aarch64.zip" -d "$work"
install -m 0755 "$work/bun-linux-aarch64/bun" /usr/local/bin/bun
rm -rf "$work"
bun --version
