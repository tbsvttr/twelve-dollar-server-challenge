#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04: a C compiler, curl/unzip/bzip2, and the official
# SBCL 2.6.10 x86-64 Linux binary tarball (sha256-checked twice) installed into /usr/local.
set -euo pipefail
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y build-essential curl ca-certificates unzip bzip2

ARCH="$(uname -m)"
[ "$ARCH" = x86_64 ] || { echo "unsupported architecture $ARCH (x86_64 only)"; exit 1; }

V=2.6.10
PKG="sbcl-$V-x86-64-linux-binary.tar.bz2"
# sha256 of the .tar.bz2 as downloaded (computed from the file SourceForge served on 2026-11-01).
BZ2_SHA=96e26b0be3aa6ca2a3f03dfd5fc117647fffb96790a9c235e8dcf27df2eba726
# sha256 of the decompressed .tar, from SBCL's own release checksum file sbcl-$V-crhodes.asc
# (PGP-signed by Christophe Rhodes, key D6839CA0A67F74D9DFB70922EBD595A9100D63CD).
TAR_SHA=011f411d0a7b4824789776df443434f555ad005dc5dd91eb2ecf8cbc15c663d0

TMP="$(mktemp -d)"
curl -fsSL --retry 3 -o "$TMP/$PKG" "https://downloads.sourceforge.net/project/sbcl/sbcl/$V/$PKG"
echo "$BZ2_SHA  $TMP/$PKG" | sha256sum -c -
bzip2 -dc "$TMP/$PKG" > "$TMP/sbcl.tar"
echo "$TAR_SHA  $TMP/sbcl.tar" | sha256sum -c -
tar -xf "$TMP/sbcl.tar" -C "$TMP"
(cd "$TMP/sbcl-$V-x86-64-linux" && INSTALL_ROOT=/usr/local sh install.sh)
rm -r "$TMP"
sbcl --version
