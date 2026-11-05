#!/usr/bin/env bash
# Runs the server in the foreground. Config: SQLITE_PATH, JWT_SECRET, HOST, PORT.
set -euo pipefail
exec "$(cd "$(dirname "$0")" && pwd)/.build/release/Feed"
