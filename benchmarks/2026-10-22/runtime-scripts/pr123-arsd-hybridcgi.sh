# Runs once as root on a clean Ubuntu 24.04: installs the pinned LDC toolchain
# (compiler + DUB) and the SQLite system library arsd.database links against.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends \
    ca-certificates curl xz-utils gcc libc6-dev libsqlite3-dev zlib1g libxml2

LDC_VERSION=1.42.0
LDC_SHA256=687707c3e20ff910528eb2d92f27a98cb0960284de3b026e6bf20284ac1c8511

curl -fsSL "https://github.com/ldc-developers/ldc/releases/download/v${LDC_VERSION}/ldc2-${LDC_VERSION}-linux-aarch64.tar.xz" -o /tmp/ldc.tar.xz
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
