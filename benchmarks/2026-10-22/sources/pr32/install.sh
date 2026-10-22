#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends gcc g++ cmake ninja-build git ca-certificates \
  libssl-dev libgtest-dev liburing-dev
g++ --version
