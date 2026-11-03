#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04: PyPy with its headers, a C compiler for the SQLite binding.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends pypy3=7.3.15+dfsg-1build3 pypy3-dev=7.3.15+dfsg-1build3 build-essential curl unzip ca-certificates libssl3t64 linux-libc-dev
pypy3 --version
