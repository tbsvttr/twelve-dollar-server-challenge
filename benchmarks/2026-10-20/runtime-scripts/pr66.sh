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
url=https://download.oracle.com/graalvm/25/archive/graalvm-jdk-25.0.4_linux-aarch64_bin.tar.gz
curl -fsSL "$url" -o "$work/graal.tar.gz"
curl -fsSL "$url.sha256" -o "$work/sha256"
echo "$(cut -d' ' -f1 "$work/sha256")  $work/graal.tar.gz" | sha256sum -c -
mkdir -p /opt/graalvm
tar -xzf "$work/graal.tar.gz" -C /opt/graalvm --strip-components=1
rm -rf "$work"
/opt/graalvm/bin/java -version
