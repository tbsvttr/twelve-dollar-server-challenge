#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
ulimit -Sn "$(ulimit -Hn)"
exec bin/server
