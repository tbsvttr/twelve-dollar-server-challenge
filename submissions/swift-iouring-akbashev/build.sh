#!/usr/bin/env bash
# Builds the server -> ./.build/release/Feed. Runs as a normal user: fetches SQLite's amalgamation (pinned,
# sha256-checked) into Sources/CSQLite, then builds everything with SwiftPM.
#   -enforce-exclusivity=unchecked  no dynamic exclusivity checks (the reactor's state is touched by its own thread).
#   --static-swift-stdlib           the Swift runtime linked in: direct calls instead of PLT stubs.
#   -target-cpu <this CPU>          code for the box's own CPU; Swift has no "native", so the toolchain's clang says
#                                   which CPU it detects, and nothing is added if it can't tell. The C targets get
#                                   clang's own -march=native (-mcpu=native on arm64).
set -euo pipefail
cd "$(dirname "$0")"
export PATH="/opt/swift/usr/bin:$PATH"
SQLITE=sqlite-amalgamation-3540100
SQLITE_SHA256=0a9c8e34352dad46006aa82836d5383bff9dc6bc9ce5a60553c05aa30e6ad1f9
if [ ! -f Sources/CSQLite/sqlite3.c ]; then
  mkdir -p .deps Sources/CSQLite/include
  curl -fsSL --retry 3 -o ".deps/$SQLITE.zip" "https://sqlite.org/2026/$SQLITE.zip"
  echo "$SQLITE_SHA256  .deps/$SQLITE.zip" | sha256sum -c -
  unzip -q -o ".deps/$SQLITE.zip" -d .deps
  cp ".deps/$SQLITE/sqlite3.c" Sources/CSQLite/sqlite3.c
  cp ".deps/$SQLITE/sqlite3.h" Sources/CSQLite/include/sqlite3.h
fi
FLAGS=(-c release -Xswiftc -enforce-exclusivity=unchecked)
[ "$(uname -s)" = Linux ] && FLAGS+=(--static-swift-stdlib)
CPU=$(clang -march=native -### -c -x c /dev/null 2>&1 | grep -o '"-target-cpu" "[^"]*"' | cut -d'"' -f4 || true)
if [ -n "$CPU" ] && [ "$CPU" != generic ]; then
  FLAGS+=(-Xswiftc -target-cpu -Xswiftc "$CPU")
fi
# SQLite and the ring code for this CPU too.
case "$(uname -m)" in
  x86_64) FLAGS+=(-Xcc -march=native) ;;
  aarch64) FLAGS+=(-Xcc -mcpu=native) ;;
esac
swift build "${FLAGS[@]}"
echo "built ./.build/release/Feed for ${CPU:-a generic CPU} ($(swift --version 2>&1 | head -1))"
