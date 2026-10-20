set -euo pipefail
curl -fsSL --retry 3 https://go.dev/dl/go1.27.2.linux-arm64.tar.gz -o /tmp/go.tgz
echo '94f3e30b8e374bc285e7dadc11e0865726b9bc6e85b841ccceaabc0214c6b7c8  /tmp/go.tgz' | sha256sum -c -
rm -rf /usr/local/go
mkdir -p /usr/local
tar -xzf /tmp/go.tgz -C /usr/local
/usr/local/go/bin/go version
rm /tmp/go.tgz
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends libsqlite3-dev=3.45.1-1ubuntu2.8 libsqlite3-0=3.45.1-1ubuntu2.8
