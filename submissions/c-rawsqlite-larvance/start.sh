#!/usr/bin/env bash
ulimit -n 1048576 2>/dev/null || true
exec "$(dirname "$0")/bin/server"
