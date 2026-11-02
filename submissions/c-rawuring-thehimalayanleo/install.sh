#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04: a C compiler and liburing 2.5 from the Ubuntu archive.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y build-essential liburing-dev curl unzip ca-certificates
