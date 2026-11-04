#!/usr/bin/env bash
# Runs the server in the foreground. It reads SQLITE_PATH, JWT_SECRET, HOST and
# PORT from the environment, as required by SPEC.md.
set -euo pipefail
# Ring-owned descriptors (io_uring direct descriptors + multishot recv)
# remove the 65535 real-fd ceiling. The runtime keeps the classic real-fd
# path automatically if registration or the provided-buffer ring fails, and
# HPHP_DIRECT=0 forces it.
export HPHP_DIRECT="${HPHP_DIRECT:-1}"
export HPHP_BG_CHECKPOINT="${HPHP_BG_CHECKPOINT:-1}"
# Store only partial receive buffers in the PHP map; idle sockets need no
# per-connection empty-string entry. Set 0 to compare the legacy layout.
export HPHP_SPARSE_BUFS="${HPHP_SPARSE_BUFS:-1}"
# Six rings x 65535 direct slots = ~393k table slots; the runtime falls back
# to one ring (and to the real-fd path) when setup fails.
export HPHP_RINGS="${HPHP_RINGS:-6}"
# Bounded ring-0 waits and a 512-deep single-shot accept queue are the
# direct-mode defaults. Set HPHP_ACCEPT_DEPTH=0 to use multishot accept.
export HPHP_RING0_WAIT="${HPHP_RING0_WAIT:-1}"
export HPHP_ACCEPT_DEPTH="${HPHP_ACCEPT_DEPTH:-512}"
# Exact-mix high-load WSL A/B favored a 1 ms ceiling over 2 ms at 260k
# configured users; both the CQE target and timeout remain overridable.
case "$HPHP_RINGS" in
  ''|*[!0-9]*) ;;
  *)
    if [ "$HPHP_DIRECT" = "1" ] && [ "$HPHP_RINGS" -gt 1 ] && [ "$HPHP_RING0_WAIT" != "0" ]; then
      export HPHP_BATCH_N="${HPHP_BATCH_N:-64}"
      export HPHP_BATCH_US="${HPHP_BATCH_US:-1000}"
    fi
    ;;
esac
exec "$(dirname "$0")/bin/server"
