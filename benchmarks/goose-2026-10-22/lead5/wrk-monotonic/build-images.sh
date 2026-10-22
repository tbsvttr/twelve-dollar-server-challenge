#!/usr/bin/env bash
# PREPARED ONLY. Do not invoke during another benchmark's sample window.
set -euo pipefail
recipe=$(cd "$(dirname "$0")" && pwd)
expected=sha256:901ab577025cfdcf7abc716fb4158774615b881383529bb77163b5f07f963898
actual=$(docker image inspect --format '{{.Id}}' twelve-unified:2026-10-07)
[[ $actual == "$expected" ]] || { echo "Load base image differs: $actual" >&2; exit 1; }
for variant in stock monotonic; do
  docker build --build-arg WRK_CLOCK_VARIANT="$variant" --build-arg BUILD_CPUSET=3,4 \
    -t "twelve-load-wrk-$variant:2026-10-22" -f "$recipe/Dockerfile" "$recipe"
done
