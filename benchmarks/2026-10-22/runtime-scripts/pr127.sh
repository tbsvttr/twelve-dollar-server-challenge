#!/usr/bin/env bash
# Supply native Node/npm prerequisites, absent from the unified image. The
# submitted installer and build script run unchanged after this toolchain setup.
set -euo pipefail
NODE_VERSION=24.21.0
name=node-v${NODE_VERSION}-linux-arm64
work=$(mktemp -d)
curl -fsSL --retry 3 "https://nodejs.org/dist/v${NODE_VERSION}/${name}.tar.xz" -o "$work/${name}.tar.xz"
curl -fsSL --retry 3 "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt" -o "$work/SHASUMS256.txt"
(cd "$work" && grep " ${name}.tar.xz$" SHASUMS256.txt | sha256sum -c -)
tar -xJf "$work/${name}.tar.xz" -C /usr/local --strip-components=1
rm -rf "$work"
npm install -g pnpm@10.17.1
node --version
npm --version
pnpm --version
