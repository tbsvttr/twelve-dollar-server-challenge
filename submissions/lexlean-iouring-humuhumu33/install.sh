#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04: a C compiler, liburing, and the Lean that checks the theorems and writes the C.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq build-essential curl ca-certificates unzip zstd liburing-dev=2.5-1build1 > /dev/null
LEAN=lean-4.32.1-linux
LEAN_SHA256=57d5c062a6b4bae6fba511a1704aa124dff461c37d0fc94585637fbb7d951b50
if [ ! -x /opt/lean-4.32.1/bin/lake ]; then
  curl -fsSL --retry 3 -o "/tmp/$LEAN.tar.zst" "https://github.com/leanprover/lean4/releases/download/v4.32.1/$LEAN.tar.zst"
  echo "$LEAN_SHA256  /tmp/$LEAN.tar.zst" | sha256sum -c -
  mkdir -p /opt/lean-4.32.1
  tar --use-compress-program=unzstd -xf "/tmp/$LEAN.tar.zst" -C /opt/lean-4.32.1 --strip-components=1
  rm -f "/tmp/$LEAN.tar.zst"
fi
