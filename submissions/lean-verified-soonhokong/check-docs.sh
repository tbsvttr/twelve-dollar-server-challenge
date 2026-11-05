#!/usr/bin/env bash
# Checks what the docs say of the proofs that no theorem states (CheckDocs.lean): that the
# statements still to prove, in the module docs of Feed/Proofs/, type-check against the code; that
# the end-to-end theorems take none of them, or any closed proposition, as a hypothesis; and which
# leaves' Lean definitions the theorems of Feed/Proofs/ need, as README.md and runtime/leaves.c
# say. Not part of build.sh; lake builds the modules it needs first.
set -euo pipefail
cd "$(dirname "$0")"
LEAN_HOME="${LEAN_HOME:-/opt/lean-nightly-2026-10-30}"
export PATH="$LEAN_HOME/bin:$PATH"
lake lean CheckDocs.lean
