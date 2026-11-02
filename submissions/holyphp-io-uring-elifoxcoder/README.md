# HolyPHP feed API (twelve-dollar-server-challenge submission)

**Language:** HolyPHP 1.0.2, compiled to C11 by the compiler vendored in `toolchain/`.

**Serving mode: direct** — the server listens on `HOST:PORT` itself (the box sets
`0.0.0.0:80`), with **no Nginx in the request path**. If `:80` is already taken
(for example by Nginx), it falls back to `127.0.0.1:3000` so the service still
comes up behind the proxy. Measured on one vCPU, direct mode is ~50 % faster
than the same server behind Nginx, because the proxy costs about as much CPU as
the app itself.

## What's in here

- `server.hphp` — the entire server: HTTP/1.1 keep-alive loop, request parsing and
  routing, HS256 JWT verification on every request, strict JSON validation for
  POST bodies, all SQL, and the write policy (group commit).
- `toolchain/` — the HolyPHP compiler, vendored. Built from source by `build.sh`.
- `install.sh` / `build.sh` / `start.sh` — standard challenge scripts.

## Server-side optimizations

- **The feed and a single post are read from SQLite's B-tree cursors.** `/feed`
  walks the `posts` rowid index backwards twenty rows while a second cursor
  walks `likes_post_id_idx` in the same order, so each post's likes are the
  next index entries; the authors are twenty rowid seeks in `users`. Records
  are decoded in place (serial types, payload offsets) and escaped straight
  into the response buffer, so a feed row allocates no strings and no arrays.
  `/posts/:id` uses the same cursors and one index range scan for its count.
  This is a generic driver binding (`bt_root` / `bt_open` / `bt_last` / …),
  not challenge logic, and it falls back to the SQL path when the pinned
  SQLite could not be built (the binding is a weak reference).
- **A string builder with a JSON escaper.** `sb_new` / `sb_put` / `sb_int` /
  `sb_json` / `sb_take` append into one buffer; the escaper copies runs of
  ordinary bytes with one `memcpy` and uses a 256-entry table per byte.
- **Group commit.** Writes collected during one poll cycle are applied in a single
  `BEGIN IMMEDIATE … COMMIT`; responses are only sent after `COMMIT` succeeds
  (all flipped to 500 on rollback).
- **WAL + `synchronous=NORMAL`**, `temp_store=MEMORY`, 64 MB page cache, 256 MB
  mmap, prepared statements.
- **One write for small bodies**, header + body written separately for the feed
  (avoids one multi-KB copy).
- **`Content-Encoding: identity`** — compression is optional per SPEC.md, and the
  box is CPU-bound, so the body goes out as-is.
- **TCP_NODELAY**; idle connections held 90 s (spec asks ≥ 65 s).
- **Rate-limited idle sweep.** Idle connections are detected by a cursor that
  advances at most one 2048-entry slice per second (not per loop cycle): at the
  benchmark's spread-out request rate the loop runs ~10k cycles/s, so a per-cycle
  slice walked ~20M entries/s for nothing. A full pass still finishes far inside
  the 90 s window.
- **Connection shedding** just below the usable descriptor table: 61,439 real
  fds in the classic path (the box sets `LimitNOFILE=65535`), or
  `uring_direct_slots() - 1024` with ring-owned descriptors. Shed responses
  carry `Connection: close`, so new users are never refused.
- A strict RFC 8259 parser for POST bodies (the runtime's `json_decode` is lenient).

## Runtime/compiler work (generic, no challenge logic)

The server is plain HolyPHP, but the language implementation was made fast and
allocation-stable for a long-running server. All of this is generic:

- **epoll readiness.** `epoll_add` / `epoll_del` / `epoll_wait_into` let the loop
  wait on thousands of client sockets in O(1); `stream_ready` (poll) is O(n).
- **O(1) socket state.** The runtime used a linear scan over every open socket on
  each `recv`/`send`; it is now indexed by descriptor.
- **Interned string literals.** Codegen emits `hp_str_intern("...")`; the runtime
  caches one `hstr` per literal address instead of allocating a copy per use.
- **Request-scope arena.** `scope_begin()` / `scope_end()` bracket a poll cycle;
  every string allocated in between is released in one shot. `str_persist()`
  copies a value out, `str_free()` / `arr_free()` / `arr_clear()` release heap
  values early. Without this the server leaked ~7.5 KB per request (3 GB in 20 s).
- **No redundant clone for array literals** (`$r = [];` used to allocate three
  arrays).
- **`stream_ready_into`** reuses the caller's array and the pollfd buffer.
- A plain SQLite binding (`sqlite_open`/`prepare`/`bind_*`/`step`/`column_*`/…),
  `stream_set_nodelay`, a JSON string-encoder fix, and `signal(SIGPIPE, SIG_IGN)`.
- **B-tree cursor binding.** `toolchain/src/hp_btree.c` is appended to the pinned
  amalgamation by `build.sh` (it needs SQLite's internals) and exports
  `hp_bt_*_impl`: root page by table/index name, cursor open with the index's
  `KeyInfo`, `first`/`last`/`next`/`prev`/`seek`, rowid and payload. The runtime
  declares those as weak references, so a build against the system library still
  links and the server uses its SQL path.
- **Pointer arithmetic and typed dereference** in the compiler (`ptr + int`,
  `*u8` reads one byte), and a cache key that includes `HPHP_SQLITE_LIB` (a
  cached binary must not silently switch SQLite builds).
- **io_uring backend behind the network primitives.** When the kernel can
  create a ring, one `io_uring_enter` per poll cycle replaces `epoll_wait` plus
  the per-request `recv`/`send` pair: each connection rides one armed
  `IORING_OP_RECV` with a recycled buffer, listeners ride `IORING_OP_POLL`,
  responses flush from owned chunks on the next cycle, and per-fd epochs drop
  completions that arrive after a close. Ring-full pushes park their fd in a
  retry ring; a queued send defers the close until the kernel has taken the
  bytes (the `Connection: close` shed path). Because the kernel caps the SQ
  ring at 32768 entries, the server sizes its keep-alive table to the ring
  (`uring_active()`): above ~28k live connections the surplus users reconnect
  per request instead of waiting for an armed-recv slot. If the kernel
  refuses the ring, every primitive falls back to the plain epoll path;
  `HPHP_URING=0` forces it.
- **Ring-owned descriptors, multishot recv, several rings.** With
  `HPHP_DIRECT=1` (default in `start.sh`), each ring registers a sparse
  65535-slot file table (`IORING_REGISTER_FILES2` +
  `IORING_RSRC_REGISTER_SPARSE`, clamped to `RLIMIT_NOFILE`) and accepts
  straight into it with one multishot accept. Connections then use multishot
  recv over a provided-buffer ring (one SQE for the connection's lifetime,
  data copied into the connection's own buffer, buffer id returned at once),
  fixed-file sends, and ring CLOSE. Direct handles live above every real fd,
  so the 65535 fd limit no longer caps held connections. `HPHP_RINGS`
  (default 5) creates five rings, each with its own sparse table and buffer
  ring: ~327k direct slots. A registered eventfd per ring keeps CQ wakeups
  reliable with `DEFER_TASKRUN`; wait/retry/close paths are ring-aware, and a
  full ring disables only its own accept. Locally: 42/42 with five rings,
  80,000 concurrent connections from eight parallel clients with
  `arm_fail=0`/`parked=0`, and 42/42 on the classic real-fd path.
  `HPHP_DIRECT=0` forces that path; a failed registration falls back
  automatically.

There is no challenge-specific C code: the backend is generic runtime code the
same way epoll and the SQLite binding are.

## Requirements

- `build-essential`, `curl`, `unzip`, `libsqlite3-dev`.
- `build.sh` builds the pinned SQLite amalgamation (3.46.1, sha256-checked) with
  `-DSQLITE_THREADSAFE=0`: the server is single-threaded, so the serialized
  build only pays mutex overhead on every step/column call. If the download or
  the build fails, it falls back to the system library, so an offline box still
  produces a working server. JSON1 and `INSERT … RETURNING` need SQLite ≥ 3.38.

## Run

```bash
bash install.sh   # as root, once
bash build.sh     # as the build user
SQLITE_PATH=/path/to/feed.db JWT_SECRET=twelve-dollar-challenge HOST=0.0.0.0 PORT=80 ./bin/server
```

## Measurements

**On the challenge box** (benchmark agent, direct on :80, 5-minute hold):

| commit | users held 5 min | req/s | app CPU | µs/req | errors |
|---|---:|---:|---:|---:|---:|
| `96aa4f5` (B-tree feed) | 110,000 | 10,637 | 83 % | 73 | 0 |
| `8ee9c5a` (send-path fix) | 130,000 | 12,618 | 93 % | 69 | 0 |
| `7a3f61e` (sweep rate-limit, `str_to_int`) | 135,000 | 13,117 | 92 % | 65 | 0 |
| `1569472` (io_uring backend + ring-scale fixes) | **145,000** | 14,093 | 91 % | 60 | 0 |
| `d75dd29` (allocation-free request path) | box run requested | — | — | — | — |

### The allocation round (`2f8507b` … `d75dd29`)

Instrumentation first: `runtime_stats()` exposes generic runtime counters
(ring enters, SQEs/CQEs per op kind, send copies, hstr allocations, poll
cycles); `server.hphp` mirrors them at `/stats` when the operator sets
`HPHP_STATS=1` — bench requests pay nothing for it (the run scripts never set
the env).

Then three measured fixes on the request path, each one attributing its cost
with the counters (or gdb sampling under load) before touching it:

| counter per `/health` request | before | after |
|---|---:|---:|
| hstr allocations (`str_new`) | 7.01 | **0.02** |
| send-payload copies (`send_chunk`) | 1.00 | **0.00** |
| ring `io_uring_enter` | 1.11 | **0.97** |

- `c10afad`: `strpos` scanned by *copying the tail into a throwaway string*
  first (gdb sampling: 3 of 5 allocations per request); it now scans in place
  from the offset. The hot `/health` response is built straight into one
  buffer and handed to the ring send chunk (`stream_send_sb(self-fd, sb)` —
  the builder buffer *becomes* the send chunk, zero payload copies; generics:
  `int_digits`, the SB flow). The parse loop skips the pipelining-`substr`
  for single-request packets.
- `d75dd29`: the recv handout is a pointer, not a copy — with the ring active
  each connection owns one long-lived hstr block the kernel writes into;
  `stream_recv` returns it directly (`HP_F_SCOPED` so retain paths copy and
  close frees it; a caller asking for fewer bytes than arrived still gets the
  classic copy).

Local (WSL microbenchmarks — my machine, not box numbers): a minimal C epoll
server on the same stack costs 54.1 µs/req; this build is at 57.4 µs/req.
Attribution of the remaining gap, measured by removing one piece at a time:
SQLite health check 0.7 µs, response builder 0.2 µs, the rest is the
interpreter/parse and the ring's two completions per request. `/health` is at
0 strings and 0 payload copies per request; p95 1.11 ms → 691 µs, median
436 µs → 359 µs. The box run for `d75dd29` (or later) is requested upstream
with `HPHP_STATS=1` so the same counter split can be read from the $12 box.

#### Leak fixes found by the counters (`06c6b17`)

`runtime_stats()` now also reports `live_allocs`, which turned two silent
leaks into measurements:

- `stream_send_sb` consumed the builder's payload buffer but never freed the
  builder handle: **~55 B leaked per `/health` request** (+14.8 MB RSS over
  270k requests). The handle is freed now; the buffer still becomes the ring
  send chunk (zero copies unchanged).
- the io_uring EOF path set the ring's own EOF flag but not the app-side
  socket record, and `stream_eof()` consults the latter — a client disconnect
  was never noticed. Measured: 21 closed clients left 21 fds open and the
  close counter at 0. The EOF completion now mirrors into the socket record:
  fds return to baseline and `close` equals `accept`.

After both: RSS flat at 14.6 MB over 810k requests (three 30 s windows at
9k rps), `live_allocs` flat, `str_new` 0.02/req, `send_chunk` 0.00/req,
`enter` 0.95/req, 42/42 tests green.

#### Shed-path crash and stall found by ASAN + load (`524fa14`)

The shed regime (above the ring's 28k connection cap) is the churn regime:
every response says `Connection: close`, so the server accepts and closes a
connection per request. Two runtime bugs only showed up there:

- **heap corruption**: `unset()` on an empty map computed `len - 1` and
  touched one element before `keys[]`. The index could hold a duplicate
  entry (inserted twice when a rebuild ran during the add) that survived a
  delete and pointed past the live range. Fixed, plus index maintenance in
  `array_pop`/`array_shift`.
- **infinite loop**: the open-addressing probe loops had no termination
  condition. Once churn left the table without a single empty slot, a lookup
  spun at 100 % CPU and the server stopped answering (measured: 137 of
  26,855 requests, then dead). Probe loops are bounded now and deletes count
  their tombstones against the rebuild budget.
- **the enter timeout never applied**: `IORING_ENTER_EXT_ARG` expects a
  `struct io_uring_getevents_arg`, not a bare `timespec`; the kernel answered
  EINVAL and the fallback ran an unbounded enter (blocks forever when nothing
  is pending). Fixed, with a poll-based fallback for old kernels.

Also: the zero-copy recv re-arm is deferred to the next wait cycle so the
kernel cannot overwrite the buffer while the handler parses it.

Evidence: ASAN build under churn (3 × 20 s at 3000 req/s, shed threshold 32):
before, 3/3 runs died; after, 3/3 alive with zero ASAN reports. 9k rps
keep-alive: 26,855 requests, 0 % errors, server healthy after the run.
42/42 tests green.

#### This round: 60k connections, native auth, one-buffer feed

- **28,000 → 60,000 held connections.** The kernel caps the io_uring SQ ring
  at 32768 entries and the server parks one armed recv per connection, so it
  used to shed everything above 28k; those users paid a TCP handshake plus
  accept/close for every request. Connections beyond the ring cap now
  register in an epoll set (the ring still carries the sends), so the server
  holds up to the descriptor limit. Verified with `HPHP_RING_MAX=10` and 1500
  connections: 45,000 requests, 0 % errors, and the ring counters show only
  the 10 ring connections produced recv completions.
- **native HS256 `jwt_verify`**: split, alg, constant-time signature compare
  and exp in C. The PHP version allocated ~20 strings per authenticated
  request; the like path now allocates 13 per request, down from 29.
- **in-place header parsing** (`str_pos_ci`, `str_int_range`,
  `str_trim_range`): no `strtolower($head)`, no header copy, no
  Content-Length substring.
- **SQLite record decoder** (`bt_cols`): the feed decodes a row's header once
  in C instead of walking varints byte by byte in the application loop.
- **feed response from one buffer**: header prepended into the builder and the
  buffer becomes the ring send chunk (no body copy, no header concatenations).
- **1 KB recv buffer** (was 4 KB): 60 MB instead of 240 MB at 60k connections.
  A controlled alternating A/B on one binary measured 77.3 vs 74.6 µs/req
  (about 3 %) -- a noisy back-to-back comparison had suggested much more, so
  the number here is the conservative one.

Local numbers (WSL, my machine, not box numbers): like 151 → 136 µs cold and
61.5 µs at 4k rps; the user-model mix 76.1 → 74.9 µs at 200 VUs. The box run
is what counts.

#### The wakeup round (`abf7a6d`): one `io_uring_enter` serves many requests

Measured on one machine against the C submission (`c-iouring-public`, #2),
same seed, same user model, alternating runs:

| | C submission | HolyPHP before | HolyPHP after |
|---|---:|---:|---:|
| `/health` µs/req | 40.8 / 39.8 | 98.8 / 100.8 | **40.5 / 41.0** |
| user-model mix µs/req | 40.5 / 40.3 | 129.6 / 194.5 | **47.6 / 45.3** |
| `io_uring_enter` per request | — | 1.63 | **0.14** |

The gap was not the generated code: the C submission's loop waits for up to
128 completions or 2 ms while it has work, so one wakeup serves a batch of
requests. Ours waited for exactly one completion per cycle. `hp_uring_wait`
now does the same (64 completions / 2 ms while busy, block for the first
completion when idle), and `hp_uring_enter` takes microseconds.

That took the trivial path to parity with C and the mix from 1.8× to
1.12–1.18×. The batching costs latency: median 2.5 ms, p95 4.6 ms, p99
6.3 ms locally — far inside the box's p95 < 500 ms.

#### The box said no to the epoll-hold round: back to park-and-retry

The box scored the branch at `56b5187` at **100,000 users** — below the
merged 145,000, and with CPU per request up from 60 to 76 µs. That branch's
connection-cap round had replaced the proven overflow behavior: connections
beyond the ring cap had been parked in the retry ring and re-armed after the
next drain (`1569472`, which scored 145k at 60 µs/req); the hold round routed
them into an epoll set instead. Its first box-scale run carried up to ~32k
epoll-held connections and those requests paid a recv syscall plus epoll
add/del per request. Local tests at 2500 connections pinned to one core
showed the epoll-hold path at 57 µs/req vs 31 µs/req for arm-retry, and the
box confirmed the direction: 76 µs/req where park-and-retry scored 60.

The runtime is back on park-and-retry by default (`HPHP_OVERFLOW=1` opts
into the epoll set for measurement), and the server sheds again at the
ring's armed-recv capacity (28000 under uring), which is exactly the regime
the merged 145k run used: keep-alive up to the ring cap, accept/close churn
beyond it. Batched wakeups, the taskrun flags, the native auth/feed work and
the 1 KB buffers stay.

Rest of the story continues below.





The 64,000 at `c935dfe` was a bug (EAGAIN treated as fatal in the non-blocking
send path), fixed in `8ee9c5a`. `30d155b` rate-limits the idle sweep to one
slice per second. `1569472` puts the network primitives on io_uring and fixes
the scale-time paths (deferred close for shed responses, bounded retry drain,
keep-alive table sized to the ring, `accept4`, listener `TCP_NODELAY`); the
ring is worth about 5 µs/req. Above 145k the search fails on CPU: 150k ran at
93 % CPU with p95 567 ms. The numbers above are what count; the local figures
below are a proxy.

On a VPS shaped like the box (1 vCPU, 2 GB), fresh seed, `wrk`, measuring the
server's own CPU from `/proc`:

| Endpoint | before this round | now |
|---|---:|---:|
| `GET /feed` (5.1 KB seed) | 32.1 µs | **17.9 µs** |
| `GET /posts/:id` | 13.8 µs | **6.4 µs** |
| `POST /posts/:id/like` | 83 µs | **54 µs** |
| `POST /posts` | 83 µs | **62 µs** |

The local proxy reads ~3.2× faster than the box, so it is useful for comparing
builds, not for predicting the score. The steady-state feed is ~3.5 KB (the
twenty newest posts are the ones the load test created), smaller than the 5.1 KB
golden seed.

`bash test/test.sh` → `passed=42 failed=0`, also on the box and in a 1 vCPU /
2 GB KVM VM (Ubuntu 24.04).
