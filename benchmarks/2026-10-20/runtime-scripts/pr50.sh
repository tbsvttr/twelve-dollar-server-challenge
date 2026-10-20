#!/usr/bin/env bash
# Runtime-only ARM64 setup; submitted application/build scripts remain unchanged.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export PATH=/opt/twelve-rust/cargo/bin:/opt/ruby/bin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export RUSTUP_HOME=/opt/twelve-rust/rustup
# Bound source compiler jobs to the same build CPU budget.
printf '#!/bin/sh\necho 2\n' >/usr/local/bin/nproc
chmod +x /usr/local/bin/nproc
#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends php8.3-cli php8.3-sqlite3 php8.3-mbstring php8.3-intl php8.3-opcache curl ca-certificates unzip
COMPOSER_VERSION=2.8.12
curl -fsSL "https://getcomposer.org/download/$COMPOSER_VERSION/composer.phar" -o /usr/local/bin/composer
printf '%s  /usr/local/bin/composer\n' 'f446ea719708bb85fcbf4ef18def5d0515f1f9b4d703f6d820c9c1656e10a2f2' | sha256sum -c -
chmod +x /usr/local/bin/composer

# Install the pinned runtime; application code and Composer dependencies build on the box.
work=$(mktemp -d)
base=https://github.com/php/frankenphp/releases/download/v1.13.0
name=frankenphp-linux-aarch64-gnu
curl -fsSL "$base/$name" -o "$work/$name"
echo "4dfbd5bd33bdd96da2cefce55b90aec29483aba5426f733cd3d4a3282c54434f  $work/$name" | sha256sum -c -
# SHA256 from GitHub release asset digest for v1.13.0 native ARM64 GNU build.
install -m 0755 "$work/$name" /usr/local/bin/frankenphp
rm -rf "$work"
