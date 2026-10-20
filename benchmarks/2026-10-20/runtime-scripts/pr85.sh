#!/usr/bin/env bash
# Source installer specifies Java21 minimum; original compact-header flag requires25+.
set -euo pipefail
work=$(mktemp -d)
url=https://github.com/adoptium/temurin25-binaries/releases/download/jdk-25.0.4.1%2B1/OpenJDK25U-jdk_aarch64_linux_hotspot_25.0.4.1_1.tar.gz
curl -fsSL --retry 3 "$url" -o "$work/jdk.tar.gz"
echo "69df11a02cfa3ef7d7ca645e03edce6778ec090e100f6ae2b42097865730ac52  $work/jdk.tar.gz" | sha256sum -c -
mkdir -p /opt/jdk-25
tar -xzf "$work/jdk.tar.gz" -C /opt/jdk-25 --strip-components=1
rm -rf "$work"
for name in java javac jar; do ln -sf /opt/jdk-25/bin/$name /usr/local/bin/$name; done
java -version
java -XX:+UseCompactObjectHeaders -version
