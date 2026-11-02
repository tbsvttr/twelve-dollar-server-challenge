#!/usr/bin/env bash
# Runs the server in the foreground, configured only by the environment.
#   SQLITE_PATH  the database to serve
#   JWT_SECRET   HS256 secret
#   HOST, PORT   the interface and port to bind
set -euo pipefail
cd "$(dirname "$0")"
ulimit -n "$(ulimit -Hn)"
exec ./build/server
