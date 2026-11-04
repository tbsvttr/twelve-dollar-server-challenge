#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# Raise soft open files limit to hard limit (permitted by SPEC.md)
ulimit -n $(ulimit -Hn 2>/dev/null || echo 65535) 2>/dev/null || ulimit -n 65535 2>/dev/null || true

# Start the optimized binary in foreground as required by SPEC.md
exec ./target/release/twelve-dollar-rust
