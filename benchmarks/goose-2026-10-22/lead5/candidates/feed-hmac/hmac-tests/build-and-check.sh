#!/usr/bin/env bash
# Run inside the selected image with the candidates directory at /candidates.
set -euo pipefail
cd /candidates/feed-hmac/hmac-tests
common=(-fPIC -ffunction-sections -fdata-sections -fvisibility=hidden -Wl,--gc-sections
        -I. -I/suite/sources/prgoose/.deps)
gcc -O2 -shared "${common[@]}" -DTEST_REUSE \
    '-DDB_SOURCE="/candidates/feed-hmac/source/db.c"' wrapper.c -lcrypto -o candidate.so
gcc -O2 -shared "${common[@]}" \
    '-DDB_SOURCE="/candidates/combined-like-bound/source/db.c"' wrapper.c -lcrypto -o reference.so
python3 check.py > results.json
gcc -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer "${common[@]}" -DTEST_REUSE \
    '-DDB_SOURCE="/candidates/feed-hmac/source/db.c"' wrapper.c lifecycle.c -lcrypto -o lifecycle
ASAN_OPTIONS=detect_leaks=1:quarantine_size_mb=4 ./lifecycle > sanitizer.log 2>&1
cat sanitizer.log
