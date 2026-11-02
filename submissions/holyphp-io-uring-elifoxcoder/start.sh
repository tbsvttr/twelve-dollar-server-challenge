#!/usr/bin/env bash
# Runs the server in the foreground. It reads SQLITE_PATH, JWT_SECRET, HOST and
# PORT from the environment, as required by SPEC.md.
set -euo pipefail
# Ring-owned descriptors (io_uring direct descriptors + multishot recv)
# remove the 65535 real-fd ceiling. The runtime keeps the classic real-fd
# path automatically if registration or the provided-buffer ring fails, and
# HPHP_DIRECT=0 forces it.
export HPHP_DIRECT="${HPHP_DIRECT:-1}"
# Five rings x 65535 direct slots = ~327k tabletops; the runtime falls back
# to one ring (and to the real-fd path) when setup fails.
export HPHP_RINGS="${HPHP_RINGS:-5}"
exec "$(dirname "$0")/bin/server"
