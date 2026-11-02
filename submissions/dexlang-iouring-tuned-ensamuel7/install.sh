#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04.
#
# DexLang compiles to C, so this installs a C toolchain and the libraries its
# standard library links, plus a Go toolchain to build the dex compiler itself
# from source.
set -euo pipefail

GO_VERSION=1.27.2
# The benchmark box is x86_64; arm64 is here so the same script builds on an
# arm machine, which is where it gets exercised before submission.
case "$(uname -m)" in
  x86_64|amd64)  GO_ARCH=amd64; GO_SHA256=ecbadb99091a3f46e31f5f934b068b1864eafa7995211b39eaddf76996045fe5 ;;
  aarch64|arm64) GO_ARCH=arm64; GO_SHA256=94f3e30b8e374bc285e7dadc11e0865726b9bc6e85b841ccceaabc0214c6b7c8 ;;
  *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

export DEBIAN_FRONTEND=noninteractive
apt-get update
# pkg-config and libssl-dev are not optional: the dex crypto module detects
# OpenSSL through pkg-config at compile time, and without it HMAC-SHA-256
# compiles to a stub that returns "" — every JWT would then fail to verify.
# libsqlite3-dev is the database, libcurl is what the http module links for its
# client half.
apt-get install -y --no-install-recommends \
  build-essential \
  ca-certificates \
  curl \
  git \
  pkg-config \
  libsqlite3-dev \
  libssl-dev \
  libcurl4-openssl-dev

curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${GO_ARCH}.tar.gz" -o /tmp/go.tar.gz
echo "${GO_SHA256}  /tmp/go.tar.gz" | sha256sum -c -
rm -rf /usr/local/go
tar -C /usr/local -xzf /tmp/go.tar.gz
rm -f /tmp/go.tar.gz

/usr/local/go/bin/go version
cc --version | head -1
pkg-config --modversion sqlite3 openssl
