# Architecture

This document explains how the submission works, in enough depth to read the
code with understanding. See the [README](../README.md) for the quick start.

## Shape of the system

One process. One request thread. One io_uring event loop. One request SQLite
connection, plus one checkpoint connection on a dedicated pthread.
HTTP/1.1 is served directly on `:80`/`:3000` (no reverse proxy) and every read and write goes to
**SQLite** linked in-process. The checkpoint connection runs PASSIVE checkpoints off the request
thread; the request thread never performs checkpoint I/O.

```
        io_uring completion queue
               │
      ┌────────┴────────┐
 listen fd         client fd
 multishot accept  recv / send
 (fixed fds)       (buf pool)
                   │
                   ▼
        http.nim  HTTP/1.1 parse + framing
                   │
                   ▼
        api.nim  routing · auth-before-id · exact errors
          │   │
   jwt.nim│   │jsonbuf.nim  byte-level JSON writer
          ▼   ▼
        db.nim ── sqlite3.nim (raw C API) ── vendored SQLite (WAL, request + checkpoint connections)
                 │
                 ▼
        one SEND per drained output buffer (backpressure / registered-fd send)
```

## Why one request thread

The benchmark box has one vCPU. Extra request threads add context switches, cache
pressure and latency jitter without adding throughput, so the whole server is a
single thread driving 1..5 io_uring rings. This also removes shared state between
request handlers, which is what lets the rest of the code stay simple: no locks,
no per-request object graph, no worker hand-off. More rings add connection
capacity, not CPU parallelism. The request SQLite connection is owned by that same
thread; the checkpoint connection is owned by its own pthread.

## Modules

| File | Responsibility |
|---|---|
| `src/server.nim` | the `io_uring` transport and the socket scaffold: multishot accept/recv, provided-buffer pool, registered fds, group commit, checkpoint worker startup, plus `raiseNofile`, listening-socket setup and the `processRequests` loop |
| `src/http.nim` | transport-agnostic HTTP/1.1 request parsing + response framing |
| `src/iouring.nim` | self-contained raw `io_uring` bindings (no liburing) |
| `src/api.nim` | routing + the five endpoints + exact error semantics |
| `src/db.nim` | all SQL; prepared statements; pragmas; read/write lifecycle; off-loop WAL checkpoint lifecycle |
| `src/sqlite3.nim` | minimal raw `{.importc.}` bindings to the vendored SQLite C API |
| `src/jwt.nim` | base64url + HS256 (nimcrypto), constant-time compare |
| `src/jsonbuf.nim` | byte-level JSON writing and minimal request-body parsing |
| `src/model.nim` | the shared `Post` value type |
| `src/config.nim` | environment-only configuration |

`server.nim` is the only module that knows about sockets, and it uses the HTTP
parsing and response framing in `http.nim`. The fd-limit bump, the
listening-socket setup and the `processRequests` request/response loop live in
the same `server.nim` module. `api.nim` takes plain strings in and returns a
status + body, so the server and the unit tests share one implementation of the
API.

## Request lifecycle

1. **accept**: a multishot accept installs each accepted socket directly into
   the ring's fixed-file table (or, when direct accept is unavailable, into the
   next free slot after an explicit `accept`). The table's full capacity is
   reserved once at startup, but the `Conn` array's length grows lazily as slots
   are first used, so RSS follows live connections.
2. **read**: `recv` until `EAGAIN`. Bytes are appended to the connection's input
   buffer. If unparsed input exceeds `MaxRequest`, the connection is
   served-then-closed (see *Bounds*).
3. **parse**: the buffer is walked with a cursor (no per-request front delete).
   Headers, method, path, `Authorization`, `Content-Length` and `Connection` are
   extracted in place. Malformed or non-conforming framing returns `400` and
   closes.
4. **route + auth**: `api.handleRequest`. On authenticated routes the bearer
   token is verified **before** the id is parsed, so `POST /posts/abc/like`
   without a token is `401`, not `400`.
5. **SQLite**: one prepared statement per query, executed on the single request
   connection. The first read of an event-loop pass opens one `BEGIN DEFERRED`;
   every read in that pass runs inside it, and the server COMMITs it
   (`endRead`) at the pass boundary, after the write batch commit. Individual
   statements are reset after use so none is left active; the reset does not end
   the pass's read transaction. After the pass commit and `endRead`, the request
   loop never checkpoints: the WAL hook wakes the dedicated checkpoint thread,
   which runs PASSIVE checkpoints off-loop.
6. **respond**: the response is appended to the output buffer and a send is
   submitted. `GET /feed` is special: the top-20 ids come from the `created_at`
   index, likes are counted inside that id window, and the rows are fetched with
   a plain rowid range, `id BETWEEN ? AND ?`, with no `ORDER BY` or `INDEXED BY`.
   Each row is written into the reusable `feedScratch` buffer at its feed slot,
   then the slots are reassembled in feed order and copied into the pooled
   output buffer with `copyMem`. The feed body never exists as a separate Nim
   string and no per-row temporary string is built. If the response cannot be
   sent in full, it stays buffered and the send is re-submitted until the socket
   accepts it.
7. **keep-alive**: unless `Connection: close`, the connection stays open; the 1 s
   age-based sweep (idle 75 s / stalled 30 s) manages its lifetime.

## Event-loop invariants

These are the rules that make the completion loop correct:

- **Read to `EAGAIN`.** Multishot recv keeps consuming until `EAGAIN`. The same
  op stays armed across completions (`IORING_CQE_F_MORE`); only the terminal
  completion clears the connection's armed flag, and arming is a no-op while an
  op is already armed, so no readiness edge is lost.
- **Load-adaptive wait for one ring.** The N=1 loop blocks for one completion
  when idle. After a pass that drained at least 8 completions it waits for 8
  completions with a 100 us cap (`IORING_ENTER_EXT_ARG`); queued completions
  count towards the batch, so a backlog is never delayed. A 1 s timeout CQE
  bounds the idle wakeup.
- **Shared wake for more than one ring.** The request thread never enters one
  ring with a blocking wait while another ring could have completions. Each
  ring is entered non-blocking (`min_complete = 0`) and the loop sleeps in one
  `epoll_wait` on a shared eventfd registered on every ring.
- **Off-loop checkpoint.** The WAL hook only raises an atomic flag and writes an
  eventfd; it makes no SQLite call. A dedicated checkpoint connection on its own
  pthread runs `SQLITE_CHECKPOINT_PASSIVE` (coalesced to about once per second).
  PASSIVE does not wait for readers, so the request thread never performs
  checkpoint I/O and cannot be stalled by a checkpoint. The WAL may grow during a
  saturated run; that disk cost is accepted for bounded latency.
- **Backpressure on send.** A partial send keeps the remainder buffered and
  re-submits the send, so an already-writable socket is never missed.
- **Free the fixed-file slot before reusing it**, and guard double-close with an
  `active` flag.
- **Never spin.** Every operation is submitted asynchronously; `EAGAIN` and
  `ENOBUFS` are retried through events, never in a busy loop.
- **Bounded work per event.** Input is capped, so a single connection cannot
  monopolise the loop.

## Connection limits (fd, conntrack)

The practical ceiling on simultaneous connections is set by the kernel, and only part of it is under
the server's control:

- **Process file descriptors.** The service runs with `LimitNOFILE = 65535` on the target box.
  Registering the fixed-file table charges every entry against `RLIMIT_NOFILE`, so each ring's table
  is sized at startup as `min(hard - 64, 65535)`: a 64-fd reserve covers the process's own descriptors
  (stdio, the ring, the database) and `MaxSlotsPerRing = 65535` bounds the table. A 65,535 hard limit
  therefore registers 65,471 slots; slot 0 is the listener, leaving 65,470 slots for accepted sockets.
  Once registered, each accepted socket lives in the table and holds **no** new process fd, so the
  per-connection fd wall is gone; the table size itself is still bounded by the limit. The `Conn` array
  reserves that capacity once but commits its length lazily as slots are used. If the kernel refuses
  the requested size, startup walks the table down in small increments to a floor (`SlotsFloor =
  16384`) instead of exiting.
- **Kernel conntrack.** `nf_conntrack_max` is about 64k on the 2 GB droplet and is machine-wide. It is
  **not** lifted by registered fds, or by anything the server can do in-process: it is the practical
  ceiling for simultaneously established connections on the target box. Local loopback tests do not
  engage conntrack, so this figure is argued from the target environment, not demonstrated locally.
- **Auto-sized multi-ring capacity.** The ring count is derived from the fd and conntrack limits:
  `rings = clamp(ceil(target / slotsPerRing), 1, 5)`, where `target = min(conntrackMax - 1024,
  MaxConns)`. At the current 64k conntrack cap the target fits one 65,471-slot table, so the default is
  one ring. When the limits rise, up to 5 rings each register their own table (about 327k fixed slots)
  and each binds its own `SO_REUSEPORT` listener on the same host:port. Every ring has a `RingCtx`,
  and every CQE's `user_data` carries the ring id; slots are per-ring and never cross between rings.
  `NIM_RINGS` and `NIM_SLOTS_PER_RING` are the only tuning overrides (clamped).
- **Large listen backlog** (4096) for reconnect bursts.
- **EMFILE backoff**: on an `accept` failure the acceptor is paused and retried on the next 1 s tick;
  it never accept-spins.
- **io_uring registered fds (default)**: sockets in the fixed-file table hold no new process fd.
- **Provided-buffer receive pool (default)**: multishot recv draws from a shared, lazily-faulted pool
  (256 buffers of 8 KiB by default; `IOURING_BUFS` overrides the size), so idle connections hold no
  recv buffer.
- **Age-based sweep.** A 1 s sweep (driven by the io_uring timeout) closes a connection that has been
  idle for 75 s or stalled mid-request for 30 s, keeping the open-connection count bounded over a long
  run.

The sweep is age-based, not count-based: there is no high-water connection watermark and no RST close.
A connection is closed only when it has been idle past the keep-alive timeout or stalled past the
request timeout.

## Per-connection memory

An idle keep-alive connection is one 80-byte `Conn` slot plus whatever input it is holding. Input
storage is retained only up to `InBufRetainCap = 4 KiB`; after a drained burst an empty buffer larger
than that is freed, and a partial request keeps only its own bytes. There is no per-connection receive
buffer: recv storage comes from the shared provided-buffer pool. Complete requests are parsed and
answered directly from that buffer, and it is returned once processing finishes. Only an incomplete
request, or a tail the output cap cannot process yet, is copied into the input buffer. The `Conn`
table reserves the full fixed-file-table capacity once, but its length grows only as slots are first
used, so RSS follows live connections rather than the table size.

Output storage is pooled as well. A buffer is taken only when a response is being built and returned
to a bounded global pool (128 buffers, up to 64 KiB each) once the SEND that carried it has fully
completed. An idle connection therefore holds no output buffer, and retained output heap is bounded
independently of the connection count.

## Transport

The transport is **io_uring**. It uses multishot accept/recv over a shared
provided-buffer pool, registered (fixed) file descriptors, and compile-time-asserted
ABI structs. `build.sh` produces one binary, `bin/server`, from `src/server.nim`,
and `start.sh` execs it directly. If `io_uring_setup` (or the fixed-file
registration) is refused at run time, the process logs a clear message and exits
non-zero.

The default configuration is one ring with `SINGLE_ISSUER | DEFER_TASKRUN |
COOP_TASKRUN`. When auto-sizing selects more than one ring, each ring gets its
own `SO_REUSEPORT` listener and registered fixed-file table, all created by the
same request thread, and the setup flags drop `DEFER_TASKRUN` (keeping
`SINGLE_ISSUER | COOP_TASKRUN`). Deferred task work only runs inside an
`io_uring_enter`; the multi-ring loop sleeps on the shared eventfd, which is
signalled when a completion commits, so deferring that commit until an enter
would deadlock the wake path. The N>1 loop therefore submits and enters without
blocking and waits in `epoll_wait` on the shared eventfd.

## Why io_uring

io_uring keeps CPU low at high user counts with tight p50/p95/p99 tails, and it is
what the official environment runs. Registered fds remove the process
`RLIMIT_NOFILE` wall for held connections, and a shared provided-buffer pool keeps
per-connection memory tiny.
A rejected setup flag, a refused multishot/direct accept and an unavailable buf
ring degrade in place without a restart. Multishot recv has no runtime fallback:
on a kernel without `IORING_RECV_MULTISHOT`, run with `IOURING_RECV=oneshot`.

## SQLite integration

- Vendored amalgamation, compiled in-tree (`vendor/sqlite3.c`), so there is no
  system `libsqlite3` dependency.
- **Two connections, two threads.** The request connection serves every request.
  The checkpoint connection is used only by its dedicated pthread. The library is
  compiled `SQLITE_THREADSAFE=2` (multi-thread mode) with `HAVE_FDATASYNC=1`; both
  connections are opened `SQLITE_OPEN_NOMUTEX`, so no per-connection mutex is taken
  on the request path. Statements are prepared once with `SQLITE_PREPARE_PERSISTENT`.
- **`locking_mode=NORMAL`.** The checkpoint connection must be able to open the
  same database while the request connection runs, so the database is not held in
  EXCLUSIVE mode.
- **Feed scan.** `GET /feed` first reads the top-20 ids through the `created_at`
  index (`ORDER BY created_at DESC, id DESC LIMIT 20`). Likes are counted inside
  that id window. Rows are then read with a plain rowid range,
  `id BETWEEN ? AND ?`, with no `ORDER BY` or `INDEXED BY`, and each row is
  written into the reusable `feedScratch` buffer at its feed slot. The slots are
  reassembled in feed order and copied into the response with `copyMem`. A sparse
  id window declines to the ordered feed query, so the output stays exact. This
  is a scan strategy, not a cache: no rows survive the request.
- **No application-level cache.** Every request reads SQLite on the request
  connection. There is no response cache, query cache, or in-memory copy of
  posts, likes, or users; the only state reused across requests is SQLite's page
  cache (`cache_size=-64`, 64 KiB), the OS page cache through `mmap_size=1 GiB`,
  and prepared statements.
- Pragmas on the request connection: `journal_mode=WAL`, `synchronous=NORMAL`,
  `busy_timeout=5000`, `foreign_keys=ON`, `temp_store=MEMORY`,
  `cache_size=-64` (64 KiB), `mmap_size=1 GiB` (`SQLITE_MMAP_SIZE`),
  `wal_autocheckpoint=0`, `journal_size_limit=67108864`, `locking_mode=NORMAL`.
- **Off-loop checkpoint lifecycle.** The request connection's `wal_hook` only raises
  an atomic flag and writes an eventfd; it makes no SQLite call, allocation or
  blocking wakeup. The dedicated checkpoint connection runs one
  `SQLITE_CHECKPOINT_PASSIVE` per coalesced interval (about 1 s). PASSIVE copies
  what it can without waiting for readers, so it cannot block the writer. The WAL
  can grow while the writer is continuously active (measured 92-104 MiB at 64k);
  `journal_size_limit=67108864` bounds it at a quiet point. FULL and TRUNCATE are
  never used under load because they wait for readers.
- **Durability.** A write is committed before its response is sent; `NORMAL`
  survives a process crash and never corrupts the file. A 3,000-post SIGTERM and
  reopen check confirmed that committed rows survive the restart.

## Robustness and bounds

See the "Robustness & bounds" section of the [README](../README.md). In short:
handler exceptions become `500`, framing is strict, input and output are bounded,
and parsing is O(n). The shipping build is `-d:danger`, which removes Nim bounds,
overflow and range checks and `assert`; the 42-check suite and the 64k load test
pass, and malformed-input fuzzing is advisable. `BUILD_VARIANT=control` opts into
a checked `-d:release` build.
