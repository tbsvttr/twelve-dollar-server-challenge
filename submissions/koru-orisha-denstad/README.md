# Koru + Orisha — twelve-dollar server challenge

Language: **Koru** (self-hosted compiler, `koruc` → emitted Zig → native binary)
Framework: **Orisha** (`drive|io-uring` pump — single-issuer io_uring, provided-buffer
ring when the kernel allows, one-shot recv fallback when it doesn't)
Driver: `koru-libs/sqlite3` — pooled per-thread connections, prepared-statement
cache, busy_timeout 5s. WAL mode + `synchronous=NORMAL` come from the seed file
itself (rule 6: durable before respond).

Serving **directly on :80 — no Nginx**. The server holds keep-alive
connections itself; measured 43,843 established connections at ~130 MB RSS
on a fresh cpx12 (stock Ubuntu 24.04, kernel 6.8.0-138 — which refuses
`IORING_REGISTER_PBUF_RING`, so the one-shot path is the measured one).

Optimizations:
- Capability-gated `ConnState` (comptime-dieted per-connection fields — h2/ws/
  send-plan/pool variants are compile-time pruned per build)
- Shrink-on-idle: per-conn buffers release at the quiescent seam
  (3.7 MB RSS after a full drain on real hardware)
- Plain-accept fallback: when the kernel retires the multishot acceptor,
  the worker flips to one-shot accept SQEs instead of going deaf
- `ONESHOT_BUF` 1 KB floor with grow-on-demand for the fallback path
- io_uring `SINGLE_ISSUER|DEFER_TASKRUN`, TCP_NODELAY, keep-alive

Build: `install.sh` fetches zig 0.15.2; `build.sh` clones the pinned
compiler/framework/stdlib hashes as dependencies and compiles the app's own
source (`twelve/main.k`, `handlers.k`, `support.kz` — vendored here) natively.
