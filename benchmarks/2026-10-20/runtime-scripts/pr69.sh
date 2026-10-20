#!/usr/bin/env bash
# Runtime-only ARM64 setup; submitted application/build scripts remain unchanged.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export PATH=/opt/twelve-rust/cargo/bin:/opt/ruby/bin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export RUSTUP_HOME=/opt/twelve-rust/rustup
# Bound source compiler jobs to the same build CPU budget.
printf '#!/bin/sh\necho 2\n' >/usr/local/bin/nproc
chmod +x /usr/local/bin/nproc
if [ -f /opt/vlang/benchmark-runtime-receipt.json ]; then
  cat /opt/vlang/benchmark-runtime-receipt.json
  /opt/vlang/v version
  exit 0
fi
#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends build-essential ca-certificates curl git libsqlite3-dev pkg-config

# Pin both repositories: V's default Makefile otherwise pulls a moving vc branch.
V_COMMIT=c36172591e766668cf8aa7cc307f05764b6a0d49
VC_COMMIT=bcfdc7f33e7b7908ee40f76d059c0e2894fb4a3b
TCC_COMMIT=d6e7ac1b1bcc98aed734a6ecbfa8509f24606c74
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL "https://github.com/vlang/v/archive/${V_COMMIT}.tar.gz" | tar -xz -C "$tmp"
mv "$tmp/v-${V_COMMIT}" /opt/vlang
# V 0.5.2's V3 module cache drops the field name when a C union member has
# the same name as its type. These unused aliases preserve the C ABI and let
# the generated cache parse correctly.
sed -i 's/^\([[:space:]]*\)u32 u32$/\1u32_value u32/; s/^\([[:space:]]*\)u64 u64$/\1u64_value u64/' /opt/vlang/vlib/fasthttp/fasthttp_linux.c.v
# The challenge's headers are small and the largest seeded feed JSON is about
# 5 KiB. fasthttp grows these buffers when needed, so smaller initial capacities
# reduce memory held by idle keep-alive connections.
fasthttp_linux=/opt/vlang/vlib/fasthttp/fasthttp_linux.v
grep -qFx 'const read_buf_cap = 8 * 1024' "$fasthttp_linux"
grep -qFx 'const write_buf_cap = 16 * 1024' "$fasthttp_linux"
sed -i 's/^const read_buf_cap = 8 \* 1024$/const read_buf_cap = 1024/; s/^const write_buf_cap = 16 \* 1024$/const write_buf_cap = 8 * 1024/' "$fasthttp_linux"
grep -qFx 'const read_buf_cap = 1024' "$fasthttp_linux"
grep -qFx 'const write_buf_cap = 8 * 1024' "$fasthttp_linux"
curl -fsSL "https://github.com/vlang/vc/archive/${VC_COMMIT}.tar.gz" | tar -xz -C "$tmp"
mv "$tmp/vc-${VC_COMMIT}" /opt/vlang/vc
curl -fsSL "https://github.com/vlang/tccbin/archive/${TCC_COMMIT}.tar.gz" | tar -xz -C "$tmp"
mkdir -p /opt/vlang/thirdparty
mv "$tmp/tccbin-${TCC_COMMIT}" /opt/vlang/thirdparty/tcc
bash /evidence/runtime-scripts/vlang-gc-arm64.sh
VJOBS=1 make -f Makefile -C /opt/vlang v
ln -sf /opt/vlang/v /usr/local/bin/v
v version

bash /evidence/runtime-scripts/vlang-gc-config-arm64.sh
