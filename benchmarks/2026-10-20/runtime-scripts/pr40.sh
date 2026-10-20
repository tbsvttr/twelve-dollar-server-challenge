set -euo pipefail
curl -fsSL --retry 3 -o /usr/local/bin/frankenphp https://github.com/php/frankenphp/releases/download/v1.13.0/frankenphp-linux-aarch64-gnu
echo '4dfbd5bd33bdd96da2cefce55b90aec29483aba5426f733cd3d4a3282c54434f  /usr/local/bin/frankenphp' | sha256sum -c -
chmod 755 /usr/local/bin/frankenphp
COMPOSER_VERSION=2.10.3
COMPOSER_SHA256=7a2d379d5b8ffdaa028580ef26494c36d2feef4b178d3dd1473a4dbc5e17c8d6
mkdir -p /usr/local/lib/composer
curl -fsSL -o /usr/local/lib/composer/composer.phar \
  "https://getcomposer.org/download/${COMPOSER_VERSION}/composer.phar"
echo "${COMPOSER_SHA256}  /usr/local/lib/composer/composer.phar" | sha256sum -c -
cat > /usr/local/lib/composer/run.php <<'PHP'
<?php
// `frankenphp php-cli` puts the binary in $argv[0] and the script in $argv[1]; Composer expects
// $argv[0] to be the script. Shift once, then hand over to the pinned composer.phar.
$_SERVER['argv'] = array_slice($_SERVER['argv'], 1);
$_SERVER['argc'] = count($_SERVER['argv']);
$argv = $_SERVER['argv'];
$argc = $_SERVER['argc'];
require __DIR__.'/composer.phar';
PHP
cat > /usr/local/bin/composer <<'SH'
#!/usr/bin/env bash
exec /usr/local/bin/frankenphp php-cli /usr/local/lib/composer/run.php "$@"
SH
chmod 0755 /usr/local/bin/composer

frankenphp version
composer --version
