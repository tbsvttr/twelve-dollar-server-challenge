#!/usr/bin/env bash
# Runs the server in the foreground. Config: SQLITE_PATH, JWT_SECRET, HOST, PORT.
set -euo pipefail
ulimit -Sn "$(ulimit -Hn)"
cd "$(dirname "$0")"
exec pypy3 server.py
