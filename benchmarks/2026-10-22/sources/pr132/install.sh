#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04 (rule 10).
#
# Installs a PINNED Nim toolchain into /opt/nim and symlinks it onto PATH.
# No submission binary is shipped: everything is built from source by build.sh.
# This script must install EVERY system dependency the build needs, so that a
# clean machine cannot fail with a missing library.
set -euo pipefail

NIM_VERSION=2.2.12
case "$(uname -m)" in
  x86_64|amd64)
    NIM_TARBALL="nim-${NIM_VERSION}-linux_x64.tar.xz"
    NIM_SHA256="7df1611449a6842af69322aa2c1206942982650a5f6bc0d37bc8ec109932f638"
    ;;
  aarch64|arm64)
    NIM_TARBALL="nim-${NIM_VERSION}-linux_arm64.tar.xz"
    NIM_SHA256="3dc04191af72a8310cf1c8ffb6f772cc3716fc5f264bc7c453ab4aecb4085221"
    ;;
  *)
    echo "unsupported architecture: $(uname -m) (expected x86_64 or aarch64)" >&2
    exit 1
    ;;
esac
NIM_URL="https://nim-lang.org/download/${NIM_TARBALL}"
DEST=/opt/nim

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl xz-utils ca-certificates unzip openssl build-essential

if [ ! -x "$DEST/bin/nim" ] || ! "$DEST/bin/nim" --version >/dev/null 2>&1; then
  tmp="$(mktemp -d)"
  echo "downloading Nim ${NIM_VERSION} (${NIM_TARBALL})"
  curl -fsSL -o "$tmp/$NIM_TARBALL" "$NIM_URL"
  echo "${NIM_SHA256}  $tmp/$NIM_TARBALL" | sha256sum -c -
  rm -rf "$DEST"
  mkdir -p "$DEST"
  tar -xJf "$tmp/$NIM_TARBALL" -C "$DEST" --strip-components=1
  rm -rf "$tmp"
fi

ln -sf "$DEST/bin/nim"    /usr/local/bin/nim
ln -sf "$DEST/bin/nimble" /usr/local/bin/nimble
[ -x "$DEST/bin/nimgrep" ] && ln -sf "$DEST/bin/nimgrep" /usr/local/bin/nimgrep || true

echo "installed:"; nim --version | head -1
