set -euo pipefail
mkdir -p /usr/local
ln -sfn /opt/twelve-go-1.27.1 /usr/local/go
/usr/local/go/bin/go version
