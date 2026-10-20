#!/usr/bin/env bash
set -euo pipefail
apt-get update -qq
apt-get install -y --no-install-recommends liburing-dev
