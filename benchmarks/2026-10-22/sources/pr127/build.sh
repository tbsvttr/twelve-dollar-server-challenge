#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

if ! command -v node >/dev/null 2>&1; then
  echo "Node.js is not installed."
  echo "Please install Node.js and try again."
  exit 1
fi

if ! command -v pnpm >/dev/null 2>&1; then
  echo "pnpm is not installed."
  echo "Install it with: npm install -g pnpm"
  exit 1
fi

pnpm install
pnpm run build

echo "Build completed successfully."