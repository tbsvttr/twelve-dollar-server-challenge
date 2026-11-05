#!/usr/bin/env bash
# Runs the server in the foreground
set -euo pipefail
ulimit -Sn "$(ulimit -Hn)" 2>/dev/null || true
exec "$(dirname "$0")/bin/server"
