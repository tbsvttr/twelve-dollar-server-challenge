#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
exec ./target/release/rust-iouring-tbsvttr

