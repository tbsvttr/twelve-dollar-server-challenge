#!/usr/bin/env bash
# Builds bin/server as a normal user. SwiftPM fetches the versions pinned in Package.resolved and
# links the Swift runtime statically.
set -euo pipefail
cd "$(dirname "$0")"
SWIFT=/opt/swift/usr/bin/swift
[ -x "$SWIFT" ] || SWIFT="$(command -v swift)"

FLAGS=(-c release --static-swift-stdlib --force-resolved-versions)
"$SWIFT" build "${FLAGS[@]}" --product App
mkdir -p bin
cp "$("$SWIFT" build "${FLAGS[@]}" --show-bin-path)/App" bin/server
echo "built bin/server"
