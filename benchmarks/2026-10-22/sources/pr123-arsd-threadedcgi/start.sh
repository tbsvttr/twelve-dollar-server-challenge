#!/usr/bin/env bash
# Runs the server in the foreground. Config comes from the SPEC env vars:
# SQLITE_PATH, JWT_SECRET, HOST, PORT.
set -euo pipefail
cd "$(dirname "$0")"
exec bin/server
