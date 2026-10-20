set -euo pipefail
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl xz-utils ca-certificates unzip openssl build-essential
curl -fsSL --retry 3 https://nim-lang.org/download/nim-2.2.12.tar.xz -o /tmp/nim.tar.xz
echo '2639a06a5ea7a7fcf57df1e7e1ef4d1b2bee58c7ac9bd00dbd2aa5bea1e5a56a  /tmp/nim.tar.xz' | sha256sum -c -
mkdir -p /opt/nim
tar -xJf /tmp/nim.tar.xz -C /opt/nim --strip-components=1
cd /opt/nim
sh build.sh
ln -sf /opt/nim/bin/nim /usr/local/bin/nim
ln -sf /opt/nim/bin/nimble /usr/local/bin/nimble
nim --version | tee /tmp/nim-version
head -1 /tmp/nim-version | grep -F 'Version 2.2.12'
