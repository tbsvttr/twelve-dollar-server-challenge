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
url=https://storage.googleapis.com/dart-archive/channels/stable/release/3.13.2/sdk/dartsdk-linux-arm64-release.zip
curl -fsSL "$url" -o "$work/dart.zip"
curl -fsSL "$url.sha256sum" -o "$work/sha256"
echo "$(cut -d' ' -f1 "$work/sha256")  $work/dart.zip" | sha256sum -c -
unzip -q "$work/dart.zip" -d /usr/local
rm -rf "$work"
/usr/local/dart-sdk/bin/dart --version
