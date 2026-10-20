#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04: a C toolchain (to compile SQLite from the
# amalgamation) and the pinned OpenJDK 27 GA build in /opt/jdk-27. No other dependency.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends build-essential curl ca-certificates unzip

# OpenJDK 27 GA (build 27+35), the official binary from jdk.java.net/27 with its published SHA-256.
JDK_URL="https://download.java.net/java/GA/jdk27/55ce5470a6294008af0057ff4626d0e5/35/GPL/openjdk-27_linux-aarch64_bin.tar.gz"
JDK_SHA256="da4e9dde1fff90204739e969187bab4751bd59a2a1c479672e1a1810f7dd23ea"

curl -fsSL "$JDK_URL" -o /tmp/jdk.tgz
echo "$JDK_SHA256  /tmp/jdk.tgz" | sha256sum -c -
rm -rf /opt/jdk-27 && mkdir -p /opt/jdk-27
tar -xzf /tmp/jdk.tgz -C /opt/jdk-27 --strip-components=1
rm -f /tmp/jdk.tgz
/opt/jdk-27/bin/java -version
