#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04: a C compiler (SQLite amalgamation), git (the TrikeShed subrepo),
# Oracle GraalVM 25.4.4.1.1 (JDK 25.0.4.1.1, the latest release on graalvm.org) and Gradle 9.6.1, both from their
# official archives, checked against pinned SHA-256 sums. gds.oracle.com publishes no .sha256 for the GraalVM archive;
# its sum is of the archive as downloaded on 2026-10-16 (384,644,784 bytes).
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends build-essential ca-certificates curl git unzip

fetch() { # fetch <url> <sha256> <file>
  curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 "$1" -o "$3"
  echo "$2  $3" | sha256sum -c -
}

cd "$(mktemp -d)"
# Each toolchain lands under a temporary name and is renamed into place once complete.
if [ ! -x /opt/graalvm-25.4.4.1.1/bin/java ]; then
  fetch https://gds.oracle.com/download/graal/25i4/archive/graalvm-jdk-25i4-25.0.4.1.1_linux-aarch64_bin.tar.gz \
    780d5784d3db9bbcff77775c4d026e4a0e21a041ba9dba7c59135949ea5234a4 graalvm.tar.gz
  rm -rf /opt/graalvm-25.4.4.1.1 /opt/.graalvm-25.4.4.1.1 && mkdir -p /opt/.graalvm-25.4.4.1.1
  tar -xzf graalvm.tar.gz -C /opt/.graalvm-25.4.4.1.1 --strip-components=1
  mv /opt/.graalvm-25.4.4.1.1 /opt/graalvm-25.4.4.1.1
  rm -f graalvm.tar.gz
fi
ln -sfn /opt/graalvm-25.4.4.1.1 /opt/graalvm

if [ ! -x /opt/gradle-9.6.1/bin/gradle ]; then
  fetch https://services.gradle.org/distributions/gradle-9.6.1-bin.zip \
    9c0f7faeeb306cb14e4279a3e084ca6b596894089a0638e68a07c945a32c9e14 gradle.zip
  rm -rf /opt/gradle-9.6.1 /opt/.gradle-unzip && unzip -q gradle.zip -d /opt/.gradle-unzip
  mv /opt/.gradle-unzip/gradle-9.6.1 /opt/gradle-9.6.1 && rmdir /opt/.gradle-unzip
  rm -f gradle.zip
fi
ln -sfn /opt/gradle-9.6.1 /opt/gradle

/opt/graalvm/bin/java -version

cd /suite/sources/pr128
# The GitHub archive omits the gitlink; rebuild only the pinned index entry.
git init -q
git update-index --add --cacheinfo 160000,17c7180dd2303280e5889abb2a3f690064a55bf8,trikeshed/TrikeShed
