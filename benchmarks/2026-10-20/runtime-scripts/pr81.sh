#!/usr/bin/env bash
# Runtime-only ARM64 setup; submitted application/build scripts remain unchanged.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export PATH=/opt/twelve-rust/cargo/bin:/opt/ruby/bin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export RUSTUP_HOME=/opt/twelve-rust/rustup
# Bound source compiler jobs to the same build CPU budget.
printf '#!/bin/sh\necho 2\n' >/usr/local/bin/nproc
chmod +x /usr/local/bin/nproc
work=$(mktemp -d)
jdk=https://github.com/adoptium/temurin26-binaries/releases/download/jdk-26.0.2.1%2B1/OpenJDK26U-jdk_aarch64_linux_hotspot_26.0.2.1_1.tar.gz
maven=https://repo1.maven.org/maven2/org/apache/maven/apache-maven/3.10.0/apache-maven-3.10.0-bin.tar.gz
curl -fsSL "$jdk" -o "$work/jdk.tar.gz"
curl -fsSL "$jdk.sha256.txt" -o "$work/jdk.sha256"
echo "$(cut -d' ' -f1 "$work/jdk.sha256")  $work/jdk.tar.gz" | sha256sum -c -
curl -fsSL "$maven" -o "$work/maven.tar.gz"
curl -fsSL "$maven.sha512" -o "$work/maven.sha512"
echo "$(cut -d' ' -f1 "$work/maven.sha512")  $work/maven.tar.gz" | sha512sum -c -
mkdir -p /opt/jdk-26 /opt/maven
tar -xzf "$work/jdk.tar.gz" -C /opt/jdk-26 --strip-components=1
tar -xzf "$work/maven.tar.gz" -C /opt/maven --strip-components=1
rm -rf "$work"
/opt/jdk-26/bin/java -version
