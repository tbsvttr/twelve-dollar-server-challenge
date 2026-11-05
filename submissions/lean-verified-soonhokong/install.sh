#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04: a C compiler and the Lean toolchain (pinned, checksummed).
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq build-essential curl ca-certificates zstd unzip >/dev/null

LEAN_NIGHTLY=nightly-2026-10-30
LEAN_VERSION=4.37.0-$LEAN_NIGHTLY
case "$(uname -m)" in
  x86_64)  asset=lean-$LEAN_VERSION-linux.tar.zst
           sha=4cdb35bfebccab607403d642081b12fa01c9b2e79b9f9ab323f95803e9b8abc8 ;;
  aarch64) asset=lean-$LEAN_VERSION-linux_aarch64.tar.zst
           sha=056e0dc67a946cc2eca82f96238ee4ea2343ff2054551a3fd186522fad424774 ;;
  *) echo "unsupported architecture $(uname -m)"; exit 1 ;;
esac
dest=/opt/lean-$LEAN_NIGHTLY
if [ ! -x "$dest/bin/lake" ]; then
  tmp="$(mktemp -d)"
  curl -fsSL --retry 3 -o "$tmp/$asset" "https://github.com/leanprover/lean4-nightly/releases/download/$LEAN_NIGHTLY/$asset"
  echo "$sha  $tmp/$asset" | sha256sum -c -
  mkdir -p "$dest"
  tar --zstd -xf "$tmp/$asset" -C "$dest" --strip-components=1
  rm -rf "$tmp"
fi
"$dest/bin/lean" --version
