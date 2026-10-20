set -euo pipefail
# All submitted install.sh packages are in the benchmark base image already.
command -v gcc curl unzip
curl -fsSL --retry 3 https://www.sqlite.org/2026/sqlite-amalgamation-3540000.zip -o /tmp/sqlite-headers.zip
echo '68e913b0fe8ec6b4e5f391c594a28872884e80d6cd042a1e50c957be46b5aa4d  /tmp/sqlite-headers.zip' | sha256sum -c -
mkdir -p /usr/local/include
unzip -p /tmp/sqlite-headers.zip sqlite-amalgamation-3540000/sqlite3.h > /usr/local/include/sqlite3.h
unzip -p /tmp/sqlite-headers.zip sqlite-amalgamation-3540000/sqlite3ext.h > /usr/local/include/sqlite3ext.h
