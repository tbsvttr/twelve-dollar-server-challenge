#!/usr/bin/env bash
# Builds the app as a normal user: a release build with the pinned DUB dependencies.
set -euo pipefail
cd "$(dirname "$0")"
dub build --build=release --compiler=ldc2
