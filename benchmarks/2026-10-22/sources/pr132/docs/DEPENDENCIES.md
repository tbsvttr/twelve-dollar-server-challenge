# Dependencies

Everything the submission needs to build and run, where each piece comes from, and
what happens if it is missing. See [README](../README.md) for build/run and
[PERFORMANCE.md](PERFORMANCE.md) for measurement limits.

## Runtime (what the binary needs)

| Dependency | Role | Source | Pinned? |
|---|---|---|---|
| `libc` (glibc) | the only shared library the server links | Ubuntu 24.04 base (x86_64 or arm64) | fixed by the OS release |

`ldd bin/server` shows just `libc.so.6` (plus the loader/vdso): SQLite is compiled
in-tree, the Nim thread runtime is off, there is no `dlopen`, and libm is folded into
glibc. The server runs one request thread plus one raw POSIX checkpoint pthread with
its own SQLite connection; the checkpoint worker is created with `pthread_create`, so
no Nim thread runtime is linked and no extra shared library appears. The binary runs
on Ubuntu 24.04 x86_64 and ARM64.

## Build: pinned downloads (URL + sha256)

| Dependency | Role | Version | Verified |
|---|---|---|---|
| Nim toolchain | compiles the server (`install.sh`, into `/opt/nim`); architecture-matched x86_64/ARM64 tarball | 2.2.12 | sha256 |
| SQLite amalgamation | the database, compiled in-tree by `build.sh` | 3.54.0 | sha256 |
| nimcrypto | HMAC-SHA256 for `src/jwt.nim`, vendored by `build.sh` | 0.7.3 | sha256 |

These are the only things fetched from the network, each from an exact URL and
checked against a recorded sha256; a mismatch aborts the build.

## Build: system tools (from apt on Ubuntu 24.04)

Installed by `install.sh`:

| Tool | Role |
|---|---|
| `build-essential` (gcc, make, `libc6-dev`, `linux-libc-dev`) | compiles the vendored C (SQLite) and the PGO helpers; provides libc headers and the C compiler |
| `curl` | downloads the pinned archives; also drives the server during PGO training |
| `xz-utils`, `ca-certificates` | extract `.tar.xz` and fetch over HTTPS |
| `unzip` | extracts the SQLite `.zip` (fallback: `bsdtar`, then `python3`) |
| `openssl` | mints the synthetic JWT used by PGO training (optional) |

Also assumed present on any Ubuntu 24.04 base: `coreutils` (`sha256sum`,
`mktemp`, `seq`, `tr`), `tar`, `gzip`, `bash`. These are OS-provided and not
individually version-pinned; they are fixed by the Ubuntu 24.04 release.

## Nim packages

There are **no external Nim packages** at build time. Every import other than the
vendored `nimcrypto` is Nim's standard library (`os`, `strutils`, `posix`,
`posix/epoll`, `oserrors`, `times`, `json`, `bitops`, `parseutils`). The unit
tests additionally use `osproc` and `streams` (`tests/test_jwt.nim`); neither is
linked into the server. The build does not use a user Nimble directory;
`config.nims` adds `vendor/nimcrypto` to the search path.

## C headers referenced

`<sys/socket.h>`, `<netinet/tcp.h>`, `<errno.h>`, `<unistd.h>`, `<sys/syscall.h>`,
`<sys/mman.h>`, `<sys/eventfd.h>`, `<poll.h>`, `<emmintrin.h>` (x86_64) or
`<arm_neon.h>` (ARM64), and the vendored `<sqlite3.h>`: all from glibc /
`linux-libc-dev` (part of `build-essential`) and the vendored SQLite. The io_uring structs are hand-mirrored, so
`<linux/io_uring.h>` is not included. No extra packages.

## PGO-specific dependencies and the plain-build safety net

PGO adds: gcc profile flags (`-fprofile-generate` / `-fprofile-use`), a small
LD_PRELOAD shim so the training server flushes `.gcda` on exit, a synthetic-database
generator, and `curl` (plus optional `openssl`) to drive the training workload.

Every PGO step is wrapped so that **any failure falls back to the plain build**:
if the helper or shim fails to compile, the training does not produce profile
data, or gcc rejects the profile flags, `build.sh` builds without PGO and still
exits `0`. PGO therefore can never break the build. `PGO=0` forces the plain build
deliberately.

## Test / CI (challenge side, not shipped)

The repository's CI (`.github/workflows/test.yml`) installs `sqlite3 jq curl
openssl` and then runs `install.sh` and `test/run.sh`. The submission's own unit
tests use only Nim's standard library and the submission's source.

## Residual risks

- Different gcc versions across Ubuntu point releases can change PGO's output, so
  the binary hash can vary between builds. The build still succeeds and passes the
  suite; the source is reproducible even when the optimized binary is not.
- Pinned downloads require network access at build time (present in CI and on the
  organiser's box).
- `-fprofile-use` can silently build non-PGO if a profile is not found (gcc only
  warns `-Wmissing-profile`); the build shares one nimcache and checks for `.gcda`
  to keep the profile locatable.
