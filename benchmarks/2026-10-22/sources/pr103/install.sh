#!/usr/bin/env bash
# Run once as root on a clean Ubuntu 24.04: installs the Go toolchain.
set -euo pipefail
apt-get update && apt-get install -y build-essential curl
curl -fsSL https://go.dev/dl/go1.27.2.linux-amd64.tar.gz | tar -C /usr/local -xz
