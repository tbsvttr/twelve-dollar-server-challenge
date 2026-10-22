#!/usr/bin/env bash
# We download anyzig directly into the repo so no need for this root-invoked install.sh script.
# We just make sure curl is available for build.sh.
command -v curl >/dev/null || { apt-get update && apt-get install -y curl ca-certificates; }
command -v pnpm >/dev/null || npm install --global pnpm
pnpm install