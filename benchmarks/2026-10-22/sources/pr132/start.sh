#!/usr/bin/env bash
# Starts the server in the foreground. Configuration is environment-only.
#
# There is a single transport (io_uring) and a single binary, bin/server. The
# process execs it directly so the server owns the PID and receives signals
# (SIGTERM on shutdown) as normal.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

# 256 is the shipping default; the env var remains available for tuning.
export IOURING_BUFS="${IOURING_BUFS:-256}"

exec "$DIR/bin/server"
