#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04: the C toolchain, and the Nelua compiler built from a pinned commit
# into /opt/nelua (Nelua has no versioned releases; its last commit is the pin). Idempotent.
set -euo pipefail
NELUA_COMMIT=a58450563e2d2ec49bff499865c8b5cfdf6ff81a   # master, 2025-06-24

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq build-essential git curl unzip ca-certificates >/dev/null

if [ "$(cat /opt/nelua/COMMIT 2>/dev/null)" = "$NELUA_COMMIT" ]; then
  echo "nelua $NELUA_COMMIT already in /opt/nelua"
else
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  git -C "$tmp" init -q
  git -C "$tmp" fetch -q --depth 1 https://github.com/edubart/nelua-lang.git "$NELUA_COMMIT"
  git -C "$tmp" checkout -q FETCH_HEAD
  [ "$(git -C "$tmp" rev-parse HEAD)" = "$NELUA_COMMIT" ]
  rm -rf /opt/nelua
  make -C "$tmp" -s -j"$(nproc)" PREFIX=/opt/nelua install >/dev/null
  echo "$NELUA_COMMIT" > /opt/nelua/COMMIT
fi
/opt/nelua/bin/nelua --version | sed -n 1p   # sed reads it all; with head, nelua could die of SIGPIPE
