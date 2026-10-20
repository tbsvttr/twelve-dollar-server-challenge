#!/usr/bin/env bash
# Runtime-only ARM64 setup; submitted application/build scripts remain unchanged.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export PATH=/opt/twelve-rust/cargo/bin:/opt/ruby/bin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export RUSTUP_HOME=/opt/twelve-rust/rustup
# Bound source compiler jobs to the same build CPU budget.
printf '#!/bin/sh\necho 2\n' >/usr/local/bin/nproc
chmod +x /usr/local/bin/nproc
work=$(mktemp -d)
curl -fsSL https://ziglang.org/download/index.json -o "$work/index.json"
python3 - "$work" <<'PYZ'
import json,pathlib,sys
r=pathlib.Path(sys.argv[1]);a=json.loads((r/'index.json').read_text())['0.15.2']['aarch64-linux']
(r/'url').write_text(a['tarball']);(r/'checksum').write_text(a['shasum']+'  '+str(r/'zig.tar.xz')+'\n')
PYZ
curl -fsSL --retry 3 "$(cat "$work/url")" -o "$work/zig.tar.xz"
sha256sum -c "$work/checksum"
mkdir -p /opt/zig-0.15.2
tar -xJf "$work/zig.tar.xz" -C /opt/zig-0.15.2 --strip-components=1
rm -rf "$work"
/opt/zig-0.15.2/zig version
