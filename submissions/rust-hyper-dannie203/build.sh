#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

export PATH="/opt/rust/bin:/usr/local/bin:$HOME/.cargo/bin:$PATH"
export RUSTUP_HOME=/opt/rust
# Use a writable CARGO_HOME for the deploy/build user
export CARGO_HOME="$PWD/.cargo-home"

# Compile with maximum native optimizations and locked dependencies
RUSTFLAGS="-C target-cpu=native" cargo build --release --locked
