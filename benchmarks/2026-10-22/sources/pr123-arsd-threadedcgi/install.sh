# Runs once as root on a clean Ubuntu 24.04: installs the pinned LDC toolchain
# (compiler + DUB) and the SQLite system library arsd.database links against.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends \
    ca-certificates curl xz-utils gcc libc6-dev libsqlite3-dev zlib1g libxml2

LDC_VERSION=1.42.0
LDC_SHA256=a7bc9c956138f558cadf9c962352f59d41c80df6eb3ae3f8039f25be14a69303

curl -fsSL "https://github.com/ldc-developers/ldc/releases/download/v${LDC_VERSION}/ldc2-${LDC_VERSION}-linux-x86_64.tar.xz" -o /tmp/ldc.tar.xz
echo "${LDC_SHA256}  /tmp/ldc.tar.xz" | sha256sum --check --

rm -rf /opt/ldc
mkdir -p /opt/ldc
tar -xJf /tmp/ldc.tar.xz -C /opt/ldc --strip-components=1
rm -f /tmp/ldc.tar.xz

ln -sf /opt/ldc/bin/ldc2 /usr/local/bin/ldc2
ln -sf /opt/ldc/bin/ldmd2 /usr/local/bin/ldmd2
ln -sf /opt/ldc/bin/dub /usr/local/bin/dub

ldc2 --version
dub --version
