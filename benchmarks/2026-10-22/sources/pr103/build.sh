#!/usr/bin/env bash
# Builds the server as a normal user. Dependencies are pinned in go.sum.
set -euo pipefail
cd "$(dirname "$0")"
GO=/usr/local/go/bin/go
[ -x "$GO" ] || GO=go
CGO_ENABLED=1 "$GO" build -trimpath -o bin/server .
