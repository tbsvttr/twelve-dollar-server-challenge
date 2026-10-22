#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

apt update
apt install -y --no-install-recommends openjdk-21-jdk maven
