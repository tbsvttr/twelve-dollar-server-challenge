#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

if [ -d "$HOME/.cargo/bin" ]; then
  export PATH="$HOME/.cargo/bin:$PATH"
fi

SQLITE_VERSION="3540100"
SQLITE_YEAR="2026"
SQLITE_SHA256="0a9c8e34352dad46006aa82836d5383bff9dc6bc9ce5a60553c05aa30e6ad1f9"

if [ ! -f "vendor/sqlite3.c" ] || [ ! -f "vendor/sqlite3.h" ]; then
  mkdir -p vendor
  ZIP="vendor/sqlite-amalgamation-${SQLITE_VERSION}.zip"
  curl -fsSL "https://www.sqlite.org/${SQLITE_YEAR}/sqlite-amalgamation-${SQLITE_VERSION}.zip" -o "$ZIP"
  if command -v sha256sum >/dev/null 2>&1; then
    echo "${SQLITE_SHA256}  ${ZIP}" | sha256sum -c -
  else
    echo "${SQLITE_SHA256}  ${ZIP}" | shasum -a 256 -c -
  fi
  unzip -q -o -j "$ZIP" "sqlite-amalgamation-${SQLITE_VERSION}/sqlite3.c" "sqlite-amalgamation-${SQLITE_VERSION}/sqlite3.h" -d vendor
  rm -f "$ZIP"
fi

export RUSTFLAGS="${RUSTFLAGS:--C target-cpu=native}"
if [ -x "/opt/tvcc-rust/cargo/bin/cargo" ]; then
  export RUSTUP_HOME="/opt/tvcc-rust/rustup"
  export CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
  export PATH="/opt/tvcc-rust/cargo/bin:$PATH"
  /opt/tvcc-rust/cargo/bin/cargo +1.94.0 build --release --locked
else
  cargo build --release --locked
fi


