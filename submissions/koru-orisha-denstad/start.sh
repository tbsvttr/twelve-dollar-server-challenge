#!/usr/bin/env bash
# Foreground server on :80, configured only by SPEC env vars.
# SQLITE_PATH / JWT_SECRET / HOST / PORT are provided by the harness.
set -euo pipefail
cd "$(dirname "$0")"
export HOST="${HOST:-0.0.0.0}" PORT="${PORT:-80}"
export SQLITE_PATH="${SQLITE_PATH:-./feed.db}"
export JWT_SECRET="${JWT_SECRET:?JWT_SECRET is required by SPEC.md}"
exec ./bin/server
