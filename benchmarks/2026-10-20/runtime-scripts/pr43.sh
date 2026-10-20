#!/usr/bin/env bash
# Runtime-only ARM64 setup; submitted application/build scripts remain unchanged.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export PATH=/opt/twelve-rust/cargo/bin:/opt/ruby/bin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export RUSTUP_HOME=/opt/twelve-rust/rustup
# Bound source compiler jobs to the same build CPU budget.
printf '#!/bin/sh\necho 2\n' >/usr/local/bin/nproc
chmod +x /usr/local/bin/nproc
#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04.
# Installs the pinned Swift 6.2 toolchain and the system SQLite dev library.
set -euo pipefail

ARCH="$(uname -m)"
if [ "$ARCH" != "aarch64" ]; then
    echo "expected aarch64, got $ARCH" >&2
    exit 1
fi

apt-get update
apt-get install -y --no-install-recommends \
    binutils ca-certificates curl git gnupg2 libc6-dev libcurl4-openssl-dev \
    libedit2 libgcc-13-dev libncurses-dev libpython3-dev libsqlite3-0 \
    libsqlite3-dev libstdc++-13-dev libxml2-dev libz3-dev pkg-config tzdata \
    unzip zip zlib1g-dev build-essential

# Swift 6.2.1 toolchain, extracted to a fixed path (build.sh/start.sh reference it).
SWIFT_VERSION=6.2.1
SWIFT_DIR=/opt/swift
if [ ! -x "$SWIFT_DIR/usr/bin/swift" ]; then
    TARBALL="swift-${SWIFT_VERSION}-RELEASE-ubuntu24.04-aarch64.tar.gz"
    URL="https://download.swift.org/swift-${SWIFT_VERSION}-release/ubuntu2404-aarch64/swift-${SWIFT_VERSION}-RELEASE/${TARBALL}"
    echo "downloading $URL"
    curl -fsSL "$URL" -o "/tmp/${TARBALL}"
    mkdir -p "$SWIFT_DIR"
    tar -xzf "/tmp/${TARBALL}" -C "$SWIFT_DIR" --strip-components=1
    rm -f "/tmp/${TARBALL}"
fi

"$SWIFT_DIR/usr/bin/swift" --version
