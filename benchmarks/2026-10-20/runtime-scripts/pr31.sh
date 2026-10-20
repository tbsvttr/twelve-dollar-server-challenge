#!/usr/bin/env bash
# Native libraries required by the submitted pinned Posit R packages.
# This supplies OS runtime dependencies without changing application sources.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
if ! command -v Rscript >/dev/null; then
  bash /suite/sources/pr31/install.sh
fi
apt-get update
apt-get install -y --no-install-recommends libwebpmux3 libuv1t64
