# Nim: direct HTTP/1.1 on SQLite (the $12 Server Challenge)

A small Twitter-style API (feed, posts, likes) implemented in **Nim 2.2.12**, built from source,
served **directly** on `:80` with a hand-written, single-request-thread **io_uring** event loop, over
an in-process **SQLite** database.

```bash
sudo bash install.sh                     # root: pinned Nim toolchain -> /opt/nim
bash build.sh                            # user: compile bin/server
SQLITE_PATH=/path/feed.db JWT_SECRET=... HOST=0.0.0.0 PORT=80 bash start.sh
```

Environment: `SQLITE_PATH`, `JWT_SECRET`, `HOST`, `PORT` (defaults `127.0.0.1:3000`). The server is
healthy well within the 60 s the rules allow.

## Stack

| Layer | Choice |
|---|---|
| Language | **Nim 2.2.12**, pinned by `install.sh` |
| HTTP | **no web framework**; hand-written HTTP/1.1 parsing and response framing in `src/http.nim` |
| Database | **SQLite 3.54.0**, vendored amalgamation compiled in-tree through hand-written raw `{.importc.}` bindings in `src/sqlite3.nim`; **no system `libsqlite3`** |
| Serving | the single binary binds **directly on `:80`**; no reverse proxy |

**Architectures:** the official target is Ubuntu 24.04 x86_64. The same source also
builds and runs on ARM64 Linux: `install.sh` selects the matching pinned Nim tarball,
the JSON/header scanners compile to SSE2 on x86_64 and NEON on ARM64 (scalar elsewhere),
and ring publication uses release/acquire stores on ARM64 while keeping x86's plain
loads/stores.

## Documentation

- **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)**: the event loop, modules, request lifecycle, invariants and connection limits.
- **[docs/PERFORMANCE.md](docs/PERFORMANCE.md)**: the current measurements, how to reproduce them, and the honest limitations.
- **[docs/DEPENDENCIES.md](docs/DEPENDENCIES.md)**: every runtime and build dependency, where it comes from, and how it is pinned.
- **[docs/OPTIMIZATIONS.md](docs/OPTIMIZATIONS.md)**: the complete implemented-optimization inventory, including the low-level transport/SQLite/JSON techniques.

## Transport

**Transport: io_uring.** `build.sh` produces a single binary, `bin/server`, from
`src/server.nim`. The HTTP parsing and response framing live in `src/http.nim`.

| Transport | How it is selected | What it adds |
|---|---|---|
| **io_uring** | the build; nothing to select | one request thread, completion-queue driven; provided-buffer receive pool; a fixed-file table sized at startup from `RLIMIT_NOFILE`, so accepted sockets hold no new process fd (the table itself is charged to the limit once, at registration) |

```bash
bash build.sh                            # builds the single bin/server
bash start.sh                            # execs bin/server
```

`start.sh` execs `bin/server` directly. If the `io_uring_setup` syscall (or the fixed-file
registration) is refused at run time, `seccomp` in a container, `kernel.io_uring_disabled`, or no
io_uring in the kernel, the process logs a clear message and exits non-zero.

## Why io_uring

io_uring wins on CPU and latency and it is the transport the official environment runs. Two
structural features matter here:

- **registered (fixed) file descriptors**: accepted connections live in the ring's fixed-file table
  and hold no new process `RLIMIT_NOFILE` slot (the table is sized at startup and charged to the
  limit once, at registration);
- **multishot accept/recv over a shared provided-buffer pool**: idle connections hold no recv
  buffer, so per-connection memory stays tiny; complete requests are parsed in place from the
  provided buffer and only an incomplete request is copied into the connection input buffer.

The pool defaults to 256 buffers of 8 KiB (`IOURING_BUFS`); multi-ring runs split one bounded global
budget across the rings. It keeps CPU low at high user counts with tight p50/p95/p99 tails. A rejected
setup flag, a refused multishot/direct accept and an unavailable buf ring degrade in place without a
restart. Multishot recv is required: a kernel without `IORING_RECV_MULTISHOT` needs the manual
`IOURING_RECV=oneshot` path (there is no runtime recv fallback).

## Toggles

Every switch, with its default. When nothing is set, the shipping defaults are used.

Build time (`build.sh`):

| Variable | Default | Effect |
|---|---|---|
| `BUILD_VARIANT` | `danger` | `danger` compiles with `-d:danger`, removing bounds/overflow/range checks and `assert`. `control` opts into `-d:release`, which keeps every runtime check on |
| `PGO` | `1` (on) | `PGO=0` builds without PGO |
| `PGO_TRAIN_ITERS` | `60` | PGO training iterations (larger = more representative profile, slower build) |
| `PGO_TRAIN_PORT` | `34999` | TCP port the PGO training server binds on `127.0.0.1` |
| `NIM_JOBS` | `0` (auto) | value passed to `nim c --parallelBuild`; `0` auto-detects the core count |

Run time (environment for `start.sh`):

| Variable | Default | Effect |
|---|---|---|
| `SQLITE_PATH` | none | path to the SQLite database file |
| `JWT_SECRET` | none | HMAC secret for token verification |
| `HOST` | `127.0.0.1` | bind address |
| `PORT` | `3000` | bind port |
| `IOURING_RECV` | `multishot` | `oneshot` re-arms a one-shot recv (manual path for kernels without multishot recv; no runtime fallback) |
| `IOURING_ACCEPT` | `multishot` | `oneshot` re-arms a one-shot accept (manual; accept also falls back automatically if refused) |
| `IOURING_ACCEPT_DIRECT` | `1` (on) | `0` forces the register-per-accept path instead of direct fixed-slot accept |
| `IOURING_BUFS` | `256` | per-ring provided-buffer pool size (source default); auto-split for multiple rings; rounded down to a power of two, clamped to `[64, 8192]` |
| `IOURING_BUFRING` | `1` (on) | `0` forces the `IORING_OP_PROVIDE_BUFFERS` list instead of the registered buf ring |
| `GROUP_COMMIT` | `1` (on) | `0` disables write group commit (per-request autocommit) |
| `SQLITE_MMAP_SIZE` | `1073741824` | SQLite `mmap_size` in bytes (1 GiB); `0` disables mmap |
| `TCP_NOTSENT_LOWAT_BYTES` | `0` (off) | Cap the unsent write queue per connection (e.g. `131072`); this forces the register-per-accept path |
| `TCP_QUICKACK` | `0` (off) | `1` sets `TCP_QUICKACK` on accepted sockets; this forces the register-per-accept path |
| `NIM_RINGS` | auto | tuning override for the auto-sized ring count (clamped to 1..5); leave unset normally |
| `NIM_SLOTS_PER_RING` | auto | tuning override for each ring's registered-file table size (clamped to 16,384..65,535); leave unset normally |
| `ZEROCOPY_STATS` | `0` (off) | `1` logs the receive-path diagnostic counters (direct requests, copied buffers) once per second |

`NIM_RINGS` and `NIM_SLOTS_PER_RING` only matter when a run genuinely needs more capacity than one
fixed-file table; the auto-sizer picks the ring count from `RLIMIT_NOFILE` and the machine's
conntrack limit.

Everything else is deliberately fixed in code and not tunable at run time: one request thread, one
request SQLite connection plus one checkpoint connection on a dedicated pthread, persistent prepared
statements, WAL + `synchronous=NORMAL`, an off-loop `SQLITE_CHECKPOINT_PASSIVE` driven by the WAL hook,
the 4096 listen backlog, EMFILE backoff, the 1 s idle/stall sweep (75 s idle / 30 s stalled), the 1 s
`TCP_DEFER_ACCEPT` wait (always one second), and the O(n) parser.

## Architecture

One process, **one request thread**, one io_uring event loop, one request SQLite connection, and one
checkpoint connection owned by a dedicated pthread. On a 1 vCPU box more request threads only add
context switches; one loop keeps latency predictable and memory per connection tiny. The request
connection runs all SQL; the checkpoint connection runs PASSIVE checkpoints off the request thread.
`locking_mode=NORMAL` lets both connections open the same database.

```
      io_uring completion queue
               │
      ┌────────┴────────┐
 listen fd         client fd
 multishot accept  recv / send
 (registered fds)  (buf pool)
                   │
                   ▼
      http.nim  HTTP/1.1 parse + response framing
                   │
                   ▼
      api.nim   routing · auth-before-id · exact errors
        │   │
 jwt.nim│   │jsonbuf.nim  byte-level JSON writer
        ▼   ▼
      db.nim ── sqlite3.nim (raw C API) ── in-process SQLite (WAL, request + checkpoint connections)
              │
              ▼
      one SEND per drained output buffer  (backpressure / registered-fd send)
```

| File | Responsibility |
|---|---|
| `src/server.nim` | the io_uring loop: multishot accept/recv, provided-buffer pool, registered fds, group commit, checkpoint worker startup; also the socket scaffold (`raiseNofile`, `setupListenSocket`, `processRequests`) |
| `src/http.nim` | transport-agnostic HTTP/1.1 request parsing + response framing |
| `src/iouring.nim` | self-contained raw io_uring bindings (no liburing) |
| `src/api.nim` | routing + the five endpoints + exact error semantics |
| `src/db.nim` | all SQL; prepared statements; pragmas; read/write lifecycle; off-loop WAL checkpoint lifecycle |
| `src/sqlite3.nim` | minimal raw `{.importc.}` bindings to the vendored SQLite C API |
| `src/jwt.nim` | base64url + HS256 HMAC verification (nimcrypto), constant-time compare |
| `src/jsonbuf.nim` | byte-level JSON writing and minimal request-body parsing |
| `src/model.nim`, `src/config.nim` | shared types; env-only configuration |

**Request flow:** an io_uring completion signals a connection, then the loop drains the socket.
`http.nim` parses every complete pipelined request in place, and `api.handleRequest` checks auth
*before* any id parsing; every read hits SQLite. For `/feed`, `db.writeFeedResponse` writes the head
and body straight into the connection's pooled output buffer; every other response is framed into that
buffer by `http.nim`. Sends are submitted until the socket would block; anything left is drained on
the next completion so a slow reader can never stall the loop. At the end of the pass, after the write
batch COMMIT and `endRead`, the request loop never checkpoints: the WAL hook wakes the dedicated
checkpoint thread, which runs PASSIVE checkpoints.

### Event-loop invariants
- **Read to EAGAIN.** Each recv keeps consuming until `EAGAIN`. In multishot mode the same op stays
  armed across completions (`IORING_CQE_F_MORE`); only the terminal completion clears the
  connection's armed flag, and arming is a no-op while an op is already armed.
- **Load-adaptive wait (one ring).** Idle, the loop blocks for one completion. After a pass that
  drained at least 8 completions it waits for 8 completions with a 100 us cap instead, so a sustained
  burst amortises the enter syscall while a partial batch cannot wait longer than the cap. The armed
  1 s timeout CQE still bounds the idle wakeup.
- **Shared wake (more than one ring).** The request thread never enters a ring with a blocking wait
  while another ring could have work: each ring is entered non-blocking and the loop sleeps on one
  shared eventfd in `epoll_wait`, registered on every ring.
- **Never spin.** `recv`/`send`/`accept` are submitted asynchronously; `EAGAIN` and `ENOBUFS` are
  retried through events, never in a busy loop.
- **Backpressure.** Unflushed output stays buffered and its send is re-submitted until the socket
  accepts it, so an already-writable socket is never missed.
- **Off-loop checkpoint.** The WAL hook only raises an atomic flag and writes an eventfd; it makes no
  SQLite call. A dedicated checkpoint connection on its own pthread runs one `SQLITE_CHECKPOINT_PASSIVE`
  per interval. PASSIVE never waits for the request connection's snapshot, so the request thread never
  performs checkpoint I/O. The WAL may grow during a saturated run; that disk cost is preferred over a
  multi-second tail-latency stall.
- **Resource guards.** 16 KiB max header block; 1 MiB max unparsed input; idle 75 s / stalled 30 s.
- **Sparse slot-indexed state.** Per-connection state is a small pooled `Conn` slot, indexed by the
  fixed-file slot the socket occupies. The `Conn` array reserves the table's full capacity at startup
  but commits length only as slots are first used, so RSS follows live connections.

## Performance optimizations

The current 64k and k6 measurements are recorded in
[docs/PERFORMANCE.md](docs/PERFORMANCE.md), together with the limitations of the local test box.

**Transport and architecture**
- **No reverse proxy.** Nginx costs CPU on the single core; serving HTTP directly avoids that overhead.
- **io_uring transport, one request thread.** A single loop over the completion queues; no worker pool, no
  thread handoff, no per-request object graph. Registering fds, multishot accept/recv and a shared
  provided-buffer pool keep CPU low at high user counts with tight tail latency.
- **Runtime-sized fixed-file table.** At startup each table is sized from `RLIMIT_NOFILE` as
  `min(hard - 64, 65535)`, and the size is printed in the startup log rather than hard-coded. On the
  target 65,535 hard limit that registers 65,471 slots; slot 0 is the listener, leaving 65,470 for
  accepted sockets. The `Conn` array reserves that full capacity once, then commits slots lazily as
  they are used. If the kernel refuses the top size, startup steps the table down in small increments
  to a 16,384 floor instead of exiting.
- **Auto-sized multi-ring capacity.** A single ring covers the current ~64k conntrack ceiling, so the
  default is exactly one ring. When the fd or conntrack limits rise, the same request thread can own
  up to 5 rings, each with its own registered table and `SO_REUSEPORT` listener, for about 327k fixed
  slots. Every ring has its own `RingCtx`, and every CQE's `user_data` carries its ring id; slots are
  per-ring. Rings add capacity, not request parallelism: there is still one request thread.
- **CQ headroom and overflow handling.** `IORING_SETUP_CQSIZE` asks for 4x the SQ entries (16384 CQEs
  against 4096 SQEs) so a completion burst near the connection ceiling cannot stall the loop; the
  kernel's reported `cq_entries` is logged. If the CQ still fills, the loop uses
  `IORING_SQ_CQ_OVERFLOW` and re-enters non-blocking to move parked completions back.
- **Provided-buffer receive pool (256 x 8 KiB by default).** Multishot recv draws from one shared,
  lazily-faulted pool, so idle connections hold no recv buffer. `IOURING_BUFS` raises or lowers the
  pool within the clamp. Multi-ring splits a fixed 4,096-buffer global budget across the rings by
  default, instead of multiplying it.
- **One SEND per drained output buffer.** A send carries every response byte currently buffered, so a
  pipelined batch can leave in one call; a partial send re-arms the remainder, and `EAGAIN`/`ENOBUFS`
  are retried rather than dropping the connection. A 64 KiB output cap (`MaxOutBuf`) stops the parser
  once that much is buffered, so a deep pipeline cannot pin a large heap buffer per connection.
- **Load-adaptive completion wait.** After arming the next operations the loop drains the entire
  completion queue in one pass. When a pass drained at least 8 completions it waits for 8
  completions with a 100 us cap (`IORING_ENTER_EXT_ARG`); otherwise it blocks for one completion.
  Completions already queued count towards the batch, so a backlog is never delayed, and the armed
  1 s timeout CQE bounds the idle wakeup. There is no separate adaptive timer.
- **Multi-ring wake path.** With more than one ring the request thread uses a non-blocking
  submit/enter on every ring plus one shared eventfd registered on each ring, waited on in a single
  `epoll_wait`. One ring keeps `DEFER_TASKRUN`; multi-ring drops it because deferred task work needs
  an enter that the eventfd sleep would never issue.
- **Listener-level TCP options.** `TCP_DEFER_ACCEPT` (always 1 s) and `TCP_NODELAY` are set once on
  each listener, so accepted sockets inherit them with no per-connection `setsockopt` and direct
  accept stays enabled.

**Data path**
- **One request connection, statements prepared once.** The request connection runs every query. The
  checkpointer owns a second connection on its own pthread. Statements use `SQLITE_PREPARE_PERSISTENT`;
  SQL never re-parses, and `SQLITE_ENABLE_QPSG` keeps statement behavior stable if a statement is ever
  re-prepared.
- **One read transaction per pass.** The first read of an event-loop pass opens a single
  `BEGIN DEFERRED`; every read in that pass runs inside it, and `endRead` COMMITs at the pass boundary,
  so no stale snapshot survives a pass. The checkpoint worker runs off-loop after the commit.
- **Top-20 feed ids plus rowid range.** The feed first reads the top-20 ids through the `created_at`
  index. Likes are counted inside that id window, and the rows are fetched with a plain rowid range,
  `id BETWEEN ? AND ?`, with no `ORDER BY` or `INDEXED BY`. Each row is written into a reusable
  `feedScratch` buffer at its feed slot, and the slots are reassembled in feed order. A sparse window
  declines to the ordered feed query, so the output stays exact.
- **Direct feed writer, low-allocation JSON.** `src/jsonbuf.nim` writes escaped string runs in bulk
  and integers digit by digit. For `GET /feed`, `db.writeFeedJson` reads SQLite columns into the
  reusable `feedScratch`, and `db.writeFeedResponse` writes the head and body straight into the pooled
  output buffer with a 128-byte head reserve. Segments are copied with `copyMem`. There is no
  `seq[Post]`, no per-row temporary string and no per-feed intermediate body string. Every other
  endpoint builds one body string per response, which `addResponse` appends to the output buffer.
- **Borrowed header spans.** `parseHead` extracts method, path, `Authorization` and headers as
  offsets into the request buffer. It never copies or allocates, and pipelined requests advance a
  cursor instead of front-deleting the buffer.
- **Canonical-body fast path.** A byte scanner decodes the common `{"body":"..."}` payload directly;
  any other shape falls back to `std/json` so the exact semantics are preserved.
- **Fixed stack JWT scratch.** The token is a borrowed span in the request buffer. Header, payload
  and signature decode into a fixed `JwtScratch` sized from the 16 KiB header cap, and HMAC runs over
  the contiguous `header.payload` bytes with no concatenation. The canonical
  `{"alg":"HS256","typ":"JWT"}` header takes a byte-match fast path, and the payload is scanned in
  place. The only heap allocation is the decoded `username`, which is response data.
- **mmap plus a small page cache.** Reads come from the OS page cache (size via `SQLITE_MMAP_SIZE`,
  default 1 GiB); the SQLite page cache is deliberately tiny at `cache_size=-64` (64 KiB).
- **Off-loop WAL checkpoint.** Autocheckpoint is disabled (`wal_autocheckpoint=0`). The request
  connection uses `locking_mode=NORMAL`; the library is compiled `SQLITE_THREADSAFE=2`. The WAL hook
  only raises an atomic flag and writes an eventfd. A separate checkpoint connection on a dedicated
  pthread runs `SQLITE_CHECKPOINT_PASSIVE` (coalesced to about once per second). PASSIVE copies what it
  can without waiting for readers, so it never blocks the writer. The WAL can grow during a saturated
  run (measured 92-104 MiB at 64k); `journal_size_limit=67108864` bounds it at a quiet point. This
  trade is deliberate: bounded request latency over a larger WAL.
- **Write group commit** (default on): writes issued during one event-loop pass share a single
  transaction that commits before any dependent response is sent (`synchronous=NORMAL`, the documented
  floor the rules allow).
- **Compact `Conn`.** Per-connection state is a pooled slot of 80 bytes (the boolean facts are packed
  into one `set[ConnFlag]`), so the slot array stays small.
- **Pooled output buffers, released at idle.** An output buffer is taken from a small bounded pool
  only while a response is being built, and returned once the SEND that carried it has fully
  completed. An idle keep-alive connection holds no output storage; the pool keeps at most 128 buffers
  and retains only buffers up to 64 KiB. Large input buffers are dropped too: after a drained burst an
  idle connection retains at most 4 KiB of input capacity, and anything larger is freed.
- **O(n) request parsing**: the input buffer is walked with a cursor and compacted once per event, so a
  large pipelined buffer is parsed in O(n) rather than O(n^2).

**Build**
- **Danger build by default.** The shipping build is `BUILD_VARIANT=danger` (`-d:danger`), which
  removes Nim bounds, overflow and range checks plus `assert`. The 42-check suite and the 64k load
  test pass. `BUILD_VARIANT=control` opts into `-d:release`, which keeps the checks on.
  Malformed-input fuzzing is still advisable for the unchecked build.
- **Profile-guided optimization (PGO)**: a two-pass build trained on a short synthetic workload, with a
  plain-build fallback when PGO is unavailable.
- **Native + LTO + SQLite trims**: `-O3 -march=native -fno-semantic-interposition -fno-plt
  --stacktrace:off` and `-d:lto`, with SQLite compiled multi-threaded (`SQLITE_THREADSAFE=2`,
  `HAVE_FDATASYNC=1`) and trimmed (`USE_ALLOCA=1`, `LIKE_DOESNT_MATCH_BLOBS`, `OMIT_DECLTYPE`,
  `OMIT_AUTOINIT`, `OMIT_*`, `DQS=0`, JSON1). See [Build](#build).

**Capacity**
- **Large listen backlog (4096), EMFILE backoff** (the acceptor pauses and retries on the next tick),
  a runtime-sized registered-fd table, auto-sized multi-ring capacity when the limits rise, and a 1 s
  idle/stall sweep (see [Peak connections](#peak-connections-the-real-limit)).

## Peak connections (the real limit)

The score is the number of simultaneous keep-alive connections the server can hold with good tail
latency. Two kernel limits sit under that number, and only one of them is a process limit:

- **Process file descriptors.** The target box gives the service `LimitNOFILE=65535`, which cannot be
  raised from inside the process. Registering the fixed-file table charges its entries against
  `RLIMIT_NOFILE`, so the table is sized `min(hard - 64, 65535)`. On that 65,535 hard limit it
  registers 65,471 slots: slot 0 is the listener, leaving 65,470 slots for accepted sockets. Accepted
  sockets then hold no new process fd: the per-connection fd wall is gone, but the table size is
  still bounded by the limit.
- **Kernel connection tracking (conntrack).** The droplet's `nf_conntrack_max` is about 64k on 2 GB.
  That table is machine-wide and is **not** lifted by registered fds or by anything the server can do
  in-process. It is the practical ceiling for simultaneous established connections as seen from the
  target environment.

Both limits can move up without changing the server: on a host where the fd or conntrack ceiling
exceeds one fixed-file table, the auto-sizer raises the ring count (up to 5 rings, each with its own
`SO_REUSEPORT` listener and registered table, ~327k slots total). The request thread still owns every
ring; rings add capacity, not parallelism.

The loop keeps per-connection cost low so that this ceiling, not memory or CPU, binds first: a shared
provided-buffer receive pool (256 buffers of 8 KiB by default, so idle connections hold no recv
buffer), an 80-byte `Conn` slot, and a slot array that reserves the full table capacity once but
commits slots lazily as they are used. An idle connection also keeps at most 4 KiB of input capacity
(larger input buffers are dropped) and no output buffer, because output storage is pooled and released
after the terminal SEND. The 4096 listen backlog absorbs reconnect bursts and EMFILE backoff pauses the
acceptor (it never spins); a 1 s sweep closes connections that have been idle for 75 s or stalled for
30 s, which also keeps the open-connection count bounded over a long run.

**Honesty about the numbers.** The ~64k conntrack ceiling is argued from the target environment
(`LimitNOFILE=65535`, a 2 GB droplet), not measured here. Local load tests run over **loopback**,
where the kernel's conntrack table is not engaged, so they exercise the socket and memory path but
**not** the conntrack path. A loopback run can therefore hold far more connections than the target box
ever will, and that is a property of loopback, not a promise about the droplet. What the server
controls is a low, bounded per-connection cost and a fixed-file table that keeps held connections
independent of the process fd limit.

This is a general capacity policy (what Nginx does when it runs out of connections), not benchmark
detection.

## Robustness & bounds

The server is built so that a request cannot crash it and every per-event operation is bounded:

- **Handler exceptions become 500.** The request handler is wrapped so that an exception is answered
  with `500` instead of propagating. Request ids are explicitly capped at 19 digits and range-checked
  *before* the multiply, so over-long ids return `400`.
- **Runtime checks.** The shipping `-d:danger` build removes Nim bounds, overflow and range checks and
  `assert`. The 42-check suite and the 64k load test pass with it; malformed-input fuzzing is still
  advisable. `BUILD_VARIANT=control` opts into a checked `-d:release` build.
- **Strict framing.** `Content-Length` must be all digits (no sign, no empty, no conflicting duplicate);
  `Transfer-Encoding` is rejected. Bad framing returns `400` plus close, never a body re-parsed as a
  request.
- **Bounded input.** Buffered *unparsed* input per connection is capped (about 1 MiB plus the header
  block), and every complete request in the buffer is processed each event. A client that pipelines
  more than the cap in a single burst is served up to the cap and then disconnected. Real clients,
  including the benchmark's `load.js`, send one request at a time, so this bound is never reached in
  the scored workload.
- **Bounded output / backpressure.** A response that cannot be sent in full stays buffered and its
  send is re-submitted; a slow reader can never stall the loop or grow memory without bound.
- **Timeouts.** Idle keep-alive 75 s; stalled mid-request 30 s.
- **Linear parsing.** Each event compacts the consumed input prefix once (no per-request front-delete),
  so a large pipelined buffer parses in O(n) rather than O(n^2).

## Durability

`WAL` + `synchronous=NORMAL`. A `201` means the row is committed before the response is written. The
checkpoint worker runs PASSIVE checkpoints off the request thread, so checkpoint I/O never sits between
the pass commit and the next request. `NORMAL` survives a process crash; on power loss the newest
committed transactions may be lost while the database stays uncorrupted. `synchronous=OFF` (which can
corrupt the file) is not used. Durability was verified with a 3,000-post SIGTERM and reopen check.

## Build

- **Toolchain:** pinned Nim `2.2.12` binary tarball (sha256-verified in `install.sh`; x86_64 and ARM64 assets).
- **One binary:** `build.sh` builds `bin/server` from `src/server.nim`. PGO is preferred; a failed PGO
  pass falls back to the plain build, and a genuine compile failure is fatal.
- **SQLite:** the `3.54.0` amalgamation is downloaded by `build.sh` (sha256-verified, `curl --retry 3`)
  and compiled in-tree, so the submission has **no system `libsqlite3` dependency** and builds cleanly
  from source.
- **nimcrypto:** `src/jwt.nim` needs it for HMAC-SHA256. It is vendored the same way (pinned `0.7.3`
  tarball, sha256-verified, extracted into `vendor/nimcrypto`) and `config.nims` adds its path to every
  compile, so the build never depends on anything installed in a user Nimble directory.
- **Nim flags:** `--threads:off --mm:arc -d:danger -d:lto --stacktrace:off` plus
  `--parallelBuild:${NIM_JOBS:-0}` (0 auto-detects the core count), plus
  `--passC:"-O3 -march=native -fno-semantic-interposition -fno-plt"` and `--passL:"-Wl,-O1"`.
  The default `BUILD_VARIANT=danger` removes bounds, overflow and range checks and `assert`; the
  42-check suite and the 64k load test pass, and malformed-input fuzzing is advisable.
  `BUILD_VARIANT=control` uses `-d:release` and keeps the checks on. PGO is on by default and runs
  through the same two-pass pipeline for both variants.
- **SQLite trims:** `-DSQLITE_THREADSAFE=2` (request + checkpoint connections on separate threads),
  `-DHAVE_FDATASYNC=1`, `-DSQLITE_DQS=0`, `-DSQLITE_DEFAULT_MEMSTATUS=0`, `-DSQLITE_USE_ALLOCA=1`,
  `-DSQLITE_LIKE_DOESNT_MATCH_BLOBS`, `-DSQLITE_OMIT_DECLTYPE`, `-DSQLITE_OMIT_AUTOINIT` (with one
  `sqlite3_initialize()` in `openDb`), `-DSQLITE_OMIT_DEPRECATED`, `-DSQLITE_OMIT_LOAD_EXTENSION`,
  `-DSQLITE_OMIT_PROGRESS_CALLBACK`, `-DSQLITE_OMIT_SHARED_CACHE`, `-DSQLITE_MAX_EXPR_DEPTH=0`,
  `-DSQLITE_TEMP_STORE=3`, `-DSQLITE_ENABLE_JSON1`, `-DSQLITE_ENABLE_QPSG`.

## Testing

- `bash test/run.sh submissions/nim-io_uring-NioHast`: the official **42-check** suite, byte-exact.
  It builds `bin/server` and runs it via `start.sh`. All 42 checks pass.
- Unit tests under `tests/`: `test_db.nim` (queries vs the seed DB, plus the off-loop checkpoint unit
  test: worker startup, PASSIVE run, error-free counters, data persistence, worker thread and reopen),
  `test_jwt.nim` (HS256 against `openssl` vectors), `test_iouring.nim` (io_uring ABI + SQE/CQE
  round-trip), `test_body.nim` (request-body parsing and its `std/json` fallback),
  `test_jsonbuf.nim` (JSON writing and escaping), `test_feed_writer.nim` (direct feed serialization,
  byte-for-byte against the golden output), and `test_feed_response.nim` (full feed head+body and
  pipelined framing).
- Harnesses and helpers under `tests/`: `feed_equality.sh` (GET /feed against the golden bytes and the
  top-of-feed after a write, byte-for-byte; **7/7** pass), `bench_escape.nim` (escaping benchmark),
  `conn_churn.sh` (connection churn), `conn_deferred_close.sh` (close with output still buffered),
  `conn_lifetime_soak.sh` (long-lived idle/stalled connection soak), `zerocopy_direct.sh` (direct
  provided-buffer parsing and partial-request carry), `fallback_matrix.sh` (env-forced transport
  variants under the churn/feed harnesses), and `multiring_smoke.sh` (the multi-ring completion-wake
  regression and pipelined mixed write).
- **Durability:** a 3,000-post SIGTERM and reopen check confirmed that committed rows survive the
  restart. The commit-failure harness is not part of this run; the 42-check suite is the CI gate.
- The two correctness gates are the **42/42** official suite and the **7/7** feed-equality harness.

## Compliance (challenge rules)

- **SQLite only**: every read/write is in-process SQLite (rule 2); no in-memory store, no external
  cache. The request thread owns the request connection; a dedicated checkpoint pthread owns the
  second connection, which only runs PASSIVE checkpoints.
- **No caching across requests** (rule 5): no response cache, no query cache, and no in-memory copy
  of any table. Every request reads SQLite; the only state reused across requests is SQLite's own
  page cache (`cache_size=-64`, 64 KiB), the OS page cache through `mmap_size=1 GiB`, and prepared
  statements. JSON and like counts are computed per request.
- **Durable before responding** (rule 6), commit before the response; no `synchronous=OFF`.
- **No hard-coded responses / no benchmark detection** (rule 7), everything derives from SQLite.
- **Nginx optional / direct** (rule 9), direct bind.
- **Built from source, pinned** (rule 10), pinned toolchain and pinned SQLite; nothing prebuilt is
  shipped; no system library beyond a C toolchain and libc is required.
- **No kernel tuning, no pinning** (rule 11), only in-process settings (socket options, SQLite
  pragmas, event loop, `setrlimit` of our own soft limit).

## Repository layout

```
submissions/nim-io_uring-NioHast/
  install.sh  build.sh  start.sh  README.md  .gitignore  config.nims
  docs/   ARCHITECTURE.md  PERFORMANCE.md  DEPENDENCIES.md  OPTIMIZATIONS.md
  src/    server.nim iouring.nim http.nim
          api.nim db.nim sqlite3.nim jwt.nim jsonbuf.nim model.nim config.nim
  tests/  test_db.nim test_jwt.nim test_iouring.nim test_body.nim test_jsonbuf.nim
          test_feed_writer.nim test_feed_response.nim
          bench_escape.nim feed_equality.sh conn_churn.sh conn_deferred_close.sh
          conn_lifetime_soak.sh fallback_matrix.sh multiring_smoke.sh
  tools/  pgo_train.sh pgo_flush.c gen_synth_db.c
  vendor/ (downloaded by build.sh; gitignored)   bin/ nimcache/ (gitignored)
```

## License

MIT, under the repository [license](../../LICENSE).
