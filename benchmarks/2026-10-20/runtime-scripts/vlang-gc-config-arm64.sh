#!/usr/bin/env bash
# Complete V's existing USE_MUNMAP setting with its required Linux mmap setting.
set -euo pipefail
gcc -O2 -fPIC -DGC_BUILTIN_ATOMIC=1 -DALL_INTERIOR_POINTERS=1 -DGC_THREADS=1 -DTHREAD_LOCAL_ALLOC=1 \
 -DUSE_MMAP=1 -DUSE_MUNMAP=1 -I /opt/vlang/thirdparty/libgc/include \
 -c /opt/vlang/thirdparty/libgc/gc.c -o /opt/vlang/thirdparty/libgc/gc.o
chmod a+r /opt/vlang/thirdparty/libgc/gc.o
rm -rf /home/bench/.cache/v/v1-fallback /opt/vlang/v1_fallback /opt/vlang/v1_fallback.vroot
printf '{"V_COMMIT":"c36172591e766668cf8aa7cc307f05764b6a0d49","VC_COMMIT":"bcfdc7f33e7b7908ee40f76d059c0e2894fb4a3b","TCC_COMMIT":"d6e7ac1b1bcc98aed734a6ecbfa8509f24606c74","native_gc_commit":"c1a45b9ad86f7449509a86360a6c0746615d8c97","native_gc_config":"USE_MMAP=1 plus existing USE_MUNMAP=1"}\n' >/opt/vlang/benchmark-runtime-receipt.json
sha256sum /opt/vlang/v /opt/vlang/thirdparty/libgc/gc.o
