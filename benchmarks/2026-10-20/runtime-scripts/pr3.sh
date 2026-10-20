set -euo pipefail
archive=$(mktemp)
curl -fsSL --retry 3 https://github.com/oven-sh/bun/releases/download/bun-v1.4.3/bun-linux-aarch64.zip -o "$archive"
echo "efa9813da5ed72423bf847f916e8d2c47c0d776add972354026a75e10da9aa21  $archive" | sha256sum -c -
unzip -q "$archive" -d /tmp/current-bun3
install -m755 /tmp/current-bun3/bun-linux-aarch64/bun /usr/local/bin/bun
rm -rf /tmp/current-bun3 "$archive"
bun --version
