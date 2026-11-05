#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04: installs build tools
set -euo pipefail
if [ "$(id -u)" -eq 0 ]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends build-essential curl ca-certificates unzip
fi
