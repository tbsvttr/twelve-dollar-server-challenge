#!/usr/bin/env bash
# Runtime-only ARM64 setup; submitted application/build scripts remain unchanged.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export PATH=/opt/twelve-rust/cargo/bin:/opt/ruby/bin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export RUSTUP_HOME=/opt/twelve-rust/rustup
# Bound source compiler jobs to the same build CPU budget.
printf '#!/bin/sh\necho 2\n' >/usr/local/bin/nproc
chmod +x /usr/local/bin/nproc
NODE_VERSION=24.21.0
name=node-v${NODE_VERSION}-linux-arm64
work=$(mktemp -d)
curl -fsSL --retry 3 "https://nodejs.org/dist/v${NODE_VERSION}/${name}.tar.xz" -o "$work/${name}.tar.xz"
curl -fsSL --retry 3 "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt" -o "$work/SHASUMS256.txt"
(cd "$work" && grep " ${name}.tar.xz$" SHASUMS256.txt | sha256sum -c -)
tar -xJf "$work/${name}.tar.xz" -C /usr/local --strip-components=1
rm -rf "$work"
node --version
npm install -g pnpm@10.33.0
