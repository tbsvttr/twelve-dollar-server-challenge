#!/usr/bin/env bash
# install-extra.sh: as root, after install.sh: the node and wasi runtimes, fetched like install.sh fetches (aria2c with
# 16 connections, curl if aria2c fails), checked against the sha256 in DEPS.tsv, unpacked under /opt, linked onto PATH.
set -euo pipefail
DEPS=${DEPS:-$(dirname "$0")/DEPS.tsv}
fetch() { # fetch <url> <file>
  local sha; sha=$(awk -F'\t' -v u="$1" '$1==u {print $2}' "$DEPS")
  aria2c -q -x16 -s16 -k1M --max-tries=5 --retry-wait=3 --allow-overwrite=true -d . -o "$2" "$1" ||
    { rm -f "$2" "$2.aria2"; curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 "$1" -o "$2"; }
  echo "$sha  $2" | sha256sum -c -
}
cd "$(mktemp -d)"
fetch https://nodejs.org/dist/v24.21.0/node-v24.21.0-linux-x64.tar.xz node.tar.xz
mkdir -p /opt/node && tar -xJf node.tar.xz -C /opt/node --strip-components=1 && rm node.tar.xz
fetch https://github.com/bytecodealliance/wasmtime/releases/download/v46.0.3/wasmtime-v46.0.3-x86_64-linux.tar.xz wasmtime.tar.xz
mkdir -p /opt/wasmtime && tar -xJf wasmtime.tar.xz -C /opt/wasmtime --strip-components=1 && rm wasmtime.tar.xz
fetch https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-34/wasi-sdk-34.0-x86_64-linux.tar.gz wasi-sdk.tar.gz
mkdir -p /opt/wasi-sdk && tar -xzf wasi-sdk.tar.gz -C /opt/wasi-sdk --strip-components=1 && rm wasi-sdk.tar.gz
ln -sfn /opt/node/bin/node /usr/local/bin/node
ln -sfn /opt/wasmtime/wasmtime /usr/local/bin/wasmtime
ln -sfn /opt/wasi-sdk/bin/wasm32-wasip1-clang /usr/local/bin/wasm32-wasip1-clang
