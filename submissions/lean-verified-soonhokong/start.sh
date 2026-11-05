#!/usr/bin/env bash
# Runs the server in the foreground; configured by SQLITE_PATH, JWT_SECRET, HOST and PORT.
# The Lean runtime links libuv, which would otherwise open an io_uring with a kernel polling
# thread at startup; the server does not use libuv.
export UV_USE_IO_URING=0
exec "$(dirname "$0")/bin/server"
