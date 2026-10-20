set -euo pipefail
curl -fsSL --retry 3 https://go.dev/dl/go1.24.4.linux-arm64.tar.gz -o /tmp/go.tgz
echo 'd5501ee5aca0f258d5fe9bfaed401958445014495dc115f202d43d5210b45241  /tmp/go.tgz' | sha256sum -c -
rm -rf /usr/local/go
mkdir -p /usr/local
tar -xzf /tmp/go.tgz -C /usr/local
/usr/local/go/bin/go version
rm /tmp/go.tgz
