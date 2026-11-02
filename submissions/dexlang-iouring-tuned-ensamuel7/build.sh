#!/usr/bin/env bash
# Runs as a normal user. Builds the dex compiler from a pinned source revision,
# then compiles server.dx with it.
set -euo pipefail
cd "$(dirname "$0")"

# The compiler revision this submission was written and tested against.
DEX_VERSION="${DEX_VERSION:-v0.9.26}"

# DEX_BIN points at an already-built compiler, which is what the local test
# loop uses. CI and the benchmark box leave it unset and build from the pinned
# revision below.
if [ -n "${DEX_BIN:-}" ]; then
  DEX="$DEX_BIN"
else
  export PATH="/usr/local/go/bin:$PATH"
  export GOBIN="$PWD/.bin"
  # GOPATH and GOCACHE are left at their defaults on purpose: pinning them
  # inside this folder makes Go re-download the toolchain and the module cache
  # for every submission built on the same box, which is several minutes of
  # nothing. Only the binary lands here.

  # Resolved through the module proxy, so the revision is checksum-verified
  # against the Go checksum database rather than taken on trust from a clone.
  go install "github.com/ensamuel7/dex@${DEX_VERSION}"
  DEX="$GOBIN/dex"
fi

SQLITE_TARBALL=sqlite-autoconf-3540100
SQLITE_SHA256=926ef8d3eab93fbf6e06011901273eec076b25594a4e1cdadd50c987f4f6d64e
mkdir -p vendor
if ! echo "$SQLITE_SHA256  vendor/$SQLITE_TARBALL.tar.gz" | sha256sum -c - >/dev/null 2>&1; then
  curl -fsSL "https://www.sqlite.org/2026/$SQLITE_TARBALL.tar.gz" -o "vendor/$SQLITE_TARBALL.tar.gz"
fi
echo "$SQLITE_SHA256  vendor/$SQLITE_TARBALL.tar.gz" | sha256sum -c -
rm -rf "vendor/$SQLITE_TARBALL"
tar -C vendor -xzf "vendor/$SQLITE_TARBALL.tar.gz"

# dex emits C and then invokes cc on it, so the build needs the C toolchain
# install.sh put there, not just Go.
"$DEX" version
"$DEX" mod download

# The read engine (btree.c) uses SQLite's internal B-tree interface, so it is
# compiled in the same translation unit as the amalgamation: a sqlite3.c that
# includes the stock, unmodified SQLite source and then the engine. The db
# module compiles whatever DEX_SQLITE names in place of SQLite itself.
case "$PWD" in *'"'*|*'\\'*) echo "build.sh: the folder path cannot contain a quote or backslash" >&2; exit 1 ;; esac
mkdir -p vendor/engine
cp "vendor/$SQLITE_TARBALL/sqlite3.h" vendor/engine/
# The prelude drops options this server never uses from the db module's
# defaults: secure delete zeroes freed pages on every write, and the others
# compile out checks on paths the program does not take.
printf '#undef SQLITE_SECURE_DELETE\n#define SQLITE_OMIT_DEPRECATED 1\n#define SQLITE_OMIT_SHARED_CACHE 1\n#define SQLITE_OMIT_PROGRESS_CALLBACK 1\n#define SQLITE_MAX_EXPR_DEPTH 0\n#include "%s"\n#include "%s"\n' "$PWD/vendor/$SQLITE_TARBALL/sqlite3.c" "$PWD/btree.c" > vendor/engine/sqlite3.c
DEX_SQLITE="vendor/engine/sqlite3.c" "$DEX" build server.dx

test -x build/server
echo "built build/server"
