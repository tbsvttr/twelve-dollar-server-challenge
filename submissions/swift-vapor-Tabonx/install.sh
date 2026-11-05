#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04 x86_64: the Swift toolchain's system packages,
# libsqlite3-dev (GRDB links the system SQLite) and the pinned Swift toolchain, SHA-256 checked.
set -euo pipefail

apt-get update
apt-get install -y --no-install-recommends \
    binutils ca-certificates curl git gnupg2 libc6-dev libcurl4-openssl-dev libedit2 \
    libgcc-13-dev libncurses-dev libpython3-dev libsqlite3-0 libsqlite3-dev libstdc++-13-dev \
    libxml2-dev libz3-dev pkg-config tzdata unzip zlib1g-dev

SWIFT_VERSION=6.4.1
SWIFT_SHA256=7d246c7114077ad01dba4ad897628446ada4c489d6c7dbcf39ae3f25cbe17e8b
SWIFT_DIR=/opt/swift
if [ ! -x "$SWIFT_DIR/usr/bin/swift" ]; then
    [ "$(uname -m)" = x86_64 ] || { echo "expected x86_64, got $(uname -m)" >&2; exit 1; }
    TARBALL="swift-$SWIFT_VERSION-RELEASE-ubuntu24.04.tar.gz"
    URL="https://download.swift.org/swift-$SWIFT_VERSION-release/ubuntu2404/swift-$SWIFT_VERSION-RELEASE/$TARBALL"
    curl -fsSL "$URL" -o "/tmp/$TARBALL"
    echo "$SWIFT_SHA256  /tmp/$TARBALL" | sha256sum -c -
    mkdir -p "$SWIFT_DIR"
    tar -xzf "/tmp/$TARBALL" -C "$SWIFT_DIR" --strip-components=1
    rm -f "/tmp/$TARBALL"
fi
"$SWIFT_DIR/usr/bin/swift" --version
