#!/usr/bin/env bash
# Runtime-only ARM64 setup; submitted application/build scripts remain unchanged.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export PATH=/opt/twelve-rust/cargo/bin:/opt/ruby/bin:/usr/local/bin:/usr/bin:/bin
export RUSTUP_HOME=/opt/twelve-rust/rustup
# Bound source compiler jobs to the same build CPU budget.
printf '#!/bin/sh\necho 2\n' >/usr/local/bin/nproc
chmod +x /usr/local/bin/nproc
GO_VERSION=1.27.2
archive=$(mktemp)
curl -fsSL --retry 3 "https://go.dev/dl/go${GO_VERSION}.linux-arm64.tar.gz" -o "$archive"
echo "94f3e30b8e374bc285e7dadc11e0865726b9bc6e85b841ccceaabc0214c6b7c8  $archive" | sha256sum -c -
rm -rf /usr/local/go
tar -C /usr/local -xzf "$archive"
rm "$archive"
ln -sf /usr/local/go/bin/go /usr/local/bin/go
ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt
/usr/local/go/bin/go version
