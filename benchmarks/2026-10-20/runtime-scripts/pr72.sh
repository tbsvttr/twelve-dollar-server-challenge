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
curl -fsSL 'https://go.dev/dl/?mode=json&include=all' -o "$work/versions.json"
python3 - "$work" <<'PYG'
import json,pathlib,sys
r=pathlib.Path(sys.argv[1]);f=next(f for v in json.loads((r/'versions.json').read_text()) if v['version']=='go1.26.3' for f in v['files'] if f['filename']=='go1.26.3.linux-arm64.tar.gz')
(r/'checksum').write_text(f['sha256']+'  '+str(r/'go.tar.gz')+'\n')
PYG
curl -fsSL https://go.dev/dl/go1.26.3.linux-arm64.tar.gz -o "$work/go.tar.gz"
sha256sum -c "$work/checksum"
rm -rf /usr/local/go
tar -xzf "$work/go.tar.gz" -C /usr/local
rm -rf "$work"
ln -sf /usr/local/go/bin/go /usr/local/bin/go
/usr/local/go/bin/go version
