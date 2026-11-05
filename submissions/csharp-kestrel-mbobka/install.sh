#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04 x86-64: the .NET SDK (official tarball, pinned, SHA-512 checked),
# libicu (the SDK needs it), libssl (HMAC) and gcc (SQLite is compiled from source).
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get -o DPkg::Lock::Timeout=600 update
apt-get -o DPkg::Lock::Timeout=600 install -y --no-install-recommends ca-certificates curl gcc libc6-dev libicu74 libssl3t64
SDK=10.0.403
SHA512=b7b3d8461cf98b07d2552ce9199702fa3ad010ac2671a5f8cd5136f7534e50f6855ba7bbb02b11494563f1d04156276a31cda1103b900e5eecd0d9473dc7b9c5
if [ ! -d "/usr/share/dotnet/sdk/$SDK" ]; then
  curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 -o /tmp/dotnet-sdk.tar.gz \
    "https://builds.dotnet.microsoft.com/dotnet/Sdk/$SDK/dotnet-sdk-$SDK-linux-x64.tar.gz"
  echo "$SHA512  /tmp/dotnet-sdk.tar.gz" | sha512sum -c -
  mkdir -p /usr/share/dotnet
  tar -xzf /tmp/dotnet-sdk.tar.gz -C /usr/share/dotnet
  rm /tmp/dotnet-sdk.tar.gz
fi
ln -sf /usr/share/dotnet/dotnet /usr/local/bin/dotnet
DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 dotnet --list-sdks
