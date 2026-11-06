#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends build-essential curl ca-certificates unzip xz-utils

RUST_VERSION="1.94.0"
export RUSTUP_HOME="/opt/tvcc-rust/rustup"
export CARGO_HOME="/opt/tvcc-rust/cargo"

if [ ! -x "/opt/tvcc-rust/cargo/bin/rustup" ]; then
  curl -fsSL https://sh.rustup.rs -o /tmp/tvcc-rustup.sh
  sh /tmp/tvcc-rustup.sh -y --profile minimal --default-toolchain "${RUST_VERSION}" --no-modify-path
  rm -f /tmp/tvcc-rustup.sh
fi
/opt/tvcc-rust/cargo/bin/rustup toolchain install "${RUST_VERSION}" --profile minimal
/opt/tvcc-rust/cargo/bin/rustup default "${RUST_VERSION}"
chmod -R a+rX /opt/tvcc-rust
/opt/tvcc-rust/cargo/bin/rustc +1.94.0 --version

