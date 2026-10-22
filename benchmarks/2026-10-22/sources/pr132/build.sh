#!/usr/bin/env bash
# Builds the single hand-written single-threaded HTTP/1.1 server: the io_uring
# transport, compiled from src/server.nim to bin/server. The HTTP parsing and
# response framing live in src/http.nim.
#
# Vendored SQLite (no system libsqlite3)
# -------------------------------------
# The SQLite amalgamation is downloaded from an exact, PINNED URL, its sha256 is
# verified, and `sqlite3.c`/`sqlite3.h` are extracted into `vendor/`. The server
# then compiles that C file straight into the binary via `{.compile.}` in
# `src/sqlite3.nim` with size/speed trims, so it no longer links `-lsqlite3`.
# This removes the last external runtime dependency: a clean benchmark/CI box
# needs no `libsqlite3`/`libsqlite3-dev`, so the build has no missing system
# library to worry about.
#
#   URL:      https://www.sqlite.org/2026/sqlite-amalgamation-3540000.zip
#   sha256:   68e913b0fe8ec6b4e5f391c594a28872884e80d6cd042a1e50c957be46b5aa4d
#
# The download is idempotent: once `vendor/sqlite3.c` exists it is not fetched again.
#
# Profile-guided optimization (PGO)
# ---------------------------------
# By default the server is built with a TWO-PASS PGO, trained on a SHORT
# SYNTHETIC workload that never reads `seed/feed.db` / `seed/tokens.json`:
#
#   pass 1  nim c ... --passC/-fprofile-generate=<pgo-data>   (instrumented, no LTO)
#   train   tools/pgo_train.sh: synthetic DB (tools/gen_synth_db) + a FIXED
#           count of keep-alive GET /health,/feed,/posts/:id and POST /posts,
#           /posts/:id/like on 127.0.0.1:${PGO_TRAIN_PORT:-34999}, then a clean SIGTERM.
#           Fixed count/order/payloads => identical .gcda => identical pass-2
#           binary across clean builds.
#   pass 2  nim c ... --passC/-fprofile-use=<pgo-data> -fprofile-correction
#           (with -d:lto; pass 1 deliberately omits it - see pgo_build)
#
# The PGO path is best-effort: if the generator/shim fail to compile, the
# instrumented build fails, the training server dies, no `.gcda` profile is
# produced, or gcc rejects the profile flags, the script falls back to the
# original plain build and STILL exits 0. Set `PGO=0` to skip PGO entirely.
#
# Two notes on how the profile is located, both verified against gcc 13:
#   * gcc keys each `.gcda` by the ABSOLUTE OBJECT PATH (dir + basename)
#     recorded at compile time. The two passes therefore share ONE nimcache
#     path (`nimcache-pgo`), which is fully `rm -rf`-ed before each pass so no
#     instrumented object can ever be reused by the profile-guided pass. Using
#     two different nimcache directories would make pass 2 silently search for
#     the profile under the wrong path (a `-Wmissing-profile` warning and a
#     non-PGO binary) - the anti-stale-object goal is met by clearing the cache.
#   * the single-process server installs no signal handler, so SIGTERM would
#     kill it WITHOUT flushing the gcov counters. `tools/libpgoflush.so` (an
#     LD_PRELOAD shim, training-only) turns SIGTERM into exit(0) so the profile
#     is written. The shipped server is unaffected.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$PWD"

# ---------------------------------------------------------------------------
# locate a Nim toolchain: on PATH, or under $HOME/.nimble/bin
if ! command -v nim >/dev/null 2>&1; then
  if [ -x "$HOME/.nimble/bin/nim" ]; then
    export PATH="$HOME/.nimble/bin:$PATH"
  fi
fi
if ! command -v nim >/dev/null 2>&1; then
  echo "nim not found on PATH or in \$HOME/.nimble/bin" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# vendor the pinned SQLite amalgamation (idempotent, sha256-verified)
SQLITE_VERSION=3540000
SQLITE_YEAR=2026
SQLITE_URL="https://www.sqlite.org/${SQLITE_YEAR}/sqlite-amalgamation-${SQLITE_VERSION}.zip"
SQLITE_ZIP_SHA256="68e913b0fe8ec6b4e5f391c594a28872884e80d6cd042a1e50c957be46b5aa4d"
SQLITE_DIR="sqlite-amalgamation-${SQLITE_VERSION}"
VENDOR="vendor"

mkdir -p "$VENDOR"
if [ ! -f "$VENDOR/sqlite3.c" ] || [ ! -f "$VENDOR/sqlite3.h" ]; then
  echo "== vendoring SQLite ${SQLITE_VERSION}: $SQLITE_URL"

  for tool in curl sha256sum mktemp; do
    command -v "$tool" >/dev/null 2>&1 || { echo "$tool is required to vendor SQLite" >&2; exit 1; }
  done

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  if ! curl -fsSL --retry 3 --retry-delay 2 -o "$tmp/sqlite.zip" "$SQLITE_URL"; then
    echo "download failed: $SQLITE_URL" >&2
    exit 1
  fi
  if ! printf '%s  %s\n' "$SQLITE_ZIP_SHA256" "$tmp/sqlite.zip" | sha256sum -c -; then
    echo "sha256 mismatch for $SQLITE_URL (expected $SQLITE_ZIP_SHA256)" >&2
    exit 1
  fi

  # extract with whatever archive tool the box has (unzip / bsdtar / python3)
  if command -v unzip >/dev/null 2>&1; then
    unzip -o -q "$tmp/sqlite.zip" -d "$tmp/x"
  elif command -v bsdtar >/dev/null 2>&1; then
    mkdir -p "$tmp/x" && bsdtar -xf "$tmp/sqlite.zip" -C "$tmp/x"
  elif command -v python3 >/dev/null 2>&1; then
    python3 -m zipfile -e "$tmp/sqlite.zip" "$tmp/x"
  else
    echo "no zip extractor found (need unzip, bsdtar, or python3)" >&2
    exit 1
  fi

  cp "$tmp/x/$SQLITE_DIR/sqlite3.c" "$VENDOR/sqlite3.c"
  cp "$tmp/x/$SQLITE_DIR/sqlite3.h" "$VENDOR/sqlite3.h"
  rm -rf "$tmp"; trap - EXIT
  echo "== vendored $VENDOR/sqlite3.c + sqlite3.h (sha256 verified)"
else
  echo "== $VENDOR/sqlite3.c present; skipping download (idempotent)"
fi

# ---------------------------------------------------------------------------
# vendor the pinned nimcrypto (pure Nim, no other deps) that jwt.nim imports for
# HMAC-SHA256. Same pattern as SQLite (pinned URL + sha256 + extract). This is
# what makes a CLEAN box (CI, or the organiser's machine) build with nothing
# pre-installed in a user's Nimble directory.
NIMCRYPTO_VERSION=0.7.3
NIMCRYPTO_URL="https://github.com/cheatfate/nimcrypto/archive/refs/tags/v${NIMCRYPTO_VERSION}.tar.gz"
NIMCRYPTO_SHA256="67fe3100593ce1fa89f73b4571241f200e53611401991fa99431c7ce1c80054d"
NIMCRYPTO_DIR="$VENDOR/nimcrypto"

if [ ! -f "$NIMCRYPTO_DIR/nimcrypto.nim" ]; then
  echo "== vendoring nimcrypto ${NIMCRYPTO_VERSION}: $NIMCRYPTO_URL"
  for tool in curl sha256sum mktemp tar; do
    command -v "$tool" >/dev/null 2>&1 || { echo "$tool is required to vendor nimcrypto" >&2; exit 1; }
  done
  tmpc="$(mktemp -d)"
  trap 'rm -rf "$tmpc"' EXIT
  if ! curl -fsSL --retry 3 --retry-delay 2 -o "$tmpc/nimcrypto.tar.gz" "$NIMCRYPTO_URL"; then
    echo "download failed: $NIMCRYPTO_URL" >&2
    exit 1
  fi
  if ! printf '%s  %s\n' "$NIMCRYPTO_SHA256" "$tmpc/nimcrypto.tar.gz" | sha256sum -c -; then
    echo "sha256 mismatch for $NIMCRYPTO_URL (expected $NIMCRYPTO_SHA256)" >&2
    exit 1
  fi
  rm -rf "$NIMCRYPTO_DIR" "$VENDOR/nimcrypto-${NIMCRYPTO_VERSION}"
  tar -xzf "$tmpc/nimcrypto.tar.gz" -C "$VENDOR"
  mv "$VENDOR/nimcrypto-${NIMCRYPTO_VERSION}" "$NIMCRYPTO_DIR"
  rm -rf "$tmpc"; trap - EXIT
  echo "== vendored $NIMCRYPTO_DIR (sha256 verified)"
else
  echo "== $NIMCRYPTO_DIR present; skipping download (idempotent)"
fi

# ---------------------------------------------------------------------------
# compile the server. The shipping default is BUILD_VARIANT=danger:
# -d:danger removes Nim runtime bounds/overflow/range checks and `assert`.
# The 42-check suite and the 64k load test pass with it. Use
# BUILD_VARIANT=control for a checked build when debugging or testing.
# Both variants use the same two-pass PGO pipeline; pgo_build clears
# pgo-data/ + nimcache-pgo before pass 1, so a profile is never reused across
# variants.
# -fno-semantic-interposition and -march=native are used for native code
# generation in every build.
#
# --nimcache keeps the object cache inside the submission (gitignored) so the
# documented clean state `rm -rf bin nimcache vendor` really is clean; the
# default cache lives in ~/.cache/nim and would silently survive it.
mkdir -p bin

# -fno-plt: call external functions through the GOT directly instead of via a
# PLT stub. Combined with -fno-semantic-interposition + LTO this removes a
# per-call indirection (~1 load + jump) on the hot path; folded into PASS_C_BASE
# so the plain build, both PGO passes and the io_uring build all inherit it.
#
# BUILD VARIANTS:
#   danger (default) -d:danger: removes runtime bounds/overflow/range checks
#                    and `assert`; fastest, with the safety trade documented.
#   control          -d:release: keeps all runtime checks on; use for checked
#                    builds, debugging, and differential tests.
# Both variants run through the same two-pass PGO pipeline.
BUILD_VARIANT="${BUILD_VARIANT:-danger}"
case "$BUILD_VARIANT" in
  control) VARIANT_NIM=(-d:release) ;;
  danger)  VARIANT_NIM=(-d:danger) ;;
  *) echo "unknown BUILD_VARIANT '$BUILD_VARIANT' (expected control|danger)" >&2; exit 1 ;;
esac
PASS_C_BASE="-O3 -march=native -fno-semantic-interposition -fno-plt"
PASS_L_BASE="-Wl,-O1"

# --stacktrace:off drops the runtime stack-trace machinery from exception
# raising. -d:release (control) keeps ALL runtime checks ON; -d:danger removes
# bounds/overflow/range checks. Every build below uses the same selector so a
# variant is identical in shape across the PGO passes.
NIM_FLAGS_COMMON=(--threads:off --mm:arc "${VARIANT_NIM[@]}" --hints:off --stacktrace:off)

# The plain (no PGO) build. $1 = source, $2 = output.
build_plain() {
  local src="$1" out="$2"
  echo "== plain build: nim c $src -> $out"
  nim c "${NIM_FLAGS_COMMON[@]}" -d:lto \
    --parallelBuild:${NIM_JOBS:-0} \
    --nimcache:nimcache \
    --passC:"$PASS_C_BASE" \
    --passC:"-I$ROOT" \
    --passL:"$PASS_L_BASE" \
    -o:"$out" "$src"
}

# PGO paths. `nimcache-pgo` is shared by both passes and cleared before each
# (see the note at the top of the file); `pgo-data` holds the .gcda profile.
PGODIR="$ROOT/pgo-data"
PGOCACHE="$ROOT/nimcache-pgo"

# Two-pass PGO. Returns non-zero on the FIRST failure so the caller can fall
# back to build_plain(). $1 = source, $2 = output.
pgo_build() {
  local src="$1" out="$2"

  # 0. training helpers: synthetic-DB generator + gcov flush shim. Both are
  #    source-only; the binaries land in tools/ and are gitignored.
  #    The generator is compiled at -O0 on purpose: it runs ONCE per build to
  #    write a sub-millisecond synthetic DB, so optimization is worthless, while
  #    -O2 on the 9 MB SQLite amalgamation costs ~60 s of the clean build.
  echo "== PGO: compiling training helpers (synthetic DB + gcov flush shim)"
  gcc -O0 -DSQLITE_THREADSAFE=0 -DSQLITE_OMIT_LOAD_EXTENSION -I "$ROOT/vendor" \
    -o "$ROOT/tools/gen_synth_db" "$ROOT/tools/gen_synth_db.c" \
    "$ROOT/vendor/sqlite3.c" -lm || return 1
  gcc -O2 -shared -fPIC -o "$ROOT/tools/libpgoflush.so" \
    "$ROOT/tools/pgo_flush.c" || return 1

  # 1. instrumented build. NO -d:lto here: the only thing pass 1 must produce is
  #    gcov counters, and instrumentation is a compile-time transform that does
  #    not need cross-TU LTO. Dropping it removes a full LTO link of the vendored
  #    SQLite amalgamation from the critical path; LTO is applied only in pass 2,
  #    where it actually shapes the shipped binary. (Verified: pass 2 still finds
  #    and consumes the profile - no -Wmissing-profile, profile-guided vs plain
  #    binaries differ.)
  echo "== PGO pass 1/2: instrumented build (no LTO) -> $out (profile dir $PGODIR)"
  rm -rf "$PGODIR" "$PGOCACHE"
  mkdir -p "$PGODIR" bin
  nim c "${NIM_FLAGS_COMMON[@]}" \
    --parallelBuild:${NIM_JOBS:-0} \
    --nimcache:"$PGOCACHE" \
    --passC:"$PASS_C_BASE -fprofile-generate=$PGODIR" \
    --passC:"-I$ROOT" \
    --passL:"$PASS_L_BASE -fprofile-generate=$PGODIR" \
    -o:"$out" "$src" || return 1

  # 2. training run: synthetic DB, private port, FIXED iteration count, clean stop.
  #    A fixed count (never a wall-clock window) is what makes two builds differ
  #    by zero bytes: the .gcda counters are a pure function of the request
  #    sequence, so pass 2 sees an identical profile every time.
  local iters="${PGO_TRAIN_ITERS:-60}"
  local train_port="${PGO_TRAIN_PORT:-34999}"
  echo "== PGO training: $iters fixed synthetic iterations on 127.0.0.1:$train_port"
  bash "$ROOT/tools/pgo_train.sh" "$ROOT/$out" "$train_port" "$iters" || return 1

  # 3. require profile data before spending another LTO pass.
  if ! find "$PGODIR" -name '*.gcda' -print -quit 2>/dev/null | grep -q .; then
    echo "PGO: training produced no .gcda profile data" >&2
    return 1
  fi

  # 4. profile-guided build. Clear the shared nimcache so pass-1 instrumented
  #    objects are never reused.
  echo "== PGO pass 2/2: profile-guided build -> $out"
  rm -rf "$PGOCACHE"
  nim c "${NIM_FLAGS_COMMON[@]}" -d:lto \
    --parallelBuild:${NIM_JOBS:-0} \
    --nimcache:"$PGOCACHE" \
    --passC:"$PASS_C_BASE -fprofile-use=$PGODIR -fprofile-correction" \
    --passC:"-I$ROOT" \
    --passL:"$PASS_L_BASE -fprofile-use=$PGODIR -fprofile-correction" \
    -o:"$out" "$src" || return 1

  return 0
}

# Build $1 -> $2, preferring PGO but never failing because of it. Returns the
# build status EXPLICITLY: the call sites below use the return value, and a
# trailing `echo` would otherwise mask a failed plain build as success.
build_one() {
  local src="$1" out="$2"
  echo "== BUILD_VARIANT=$BUILD_VARIANT (nim: ${VARIANT_NIM[*]})"
  if [ "${PGO:-1}" != "1" ]; then
    echo "== PGO disabled (PGO=0); plain build"
    build_plain "$src" "$out"
    return $?
  fi
  if pgo_build "$src" "$out"; then
    echo "== PGO build succeeded: $out"
    return 0
  fi
  echo "== PGO build failed; falling back to plain build of $out" >&2
  if build_plain "$src" "$out"; then
    echo "== fallback plain build complete: $out"
    return 0
  fi
  echo "== plain build also failed: $out" >&2
  return 1
}

# The single server binary, built from src/server.nim. PGO is preferred; if any
# PGO step fails, build_one falls back to the plain build, so a PGO problem
# never fails the build. A genuine compile failure is fatal: it must not be
# shipped as a silently missing or stale bin/server.
build_one src/server.nim bin/server
