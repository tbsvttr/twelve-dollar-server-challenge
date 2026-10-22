# Goose / native HTTP / SQLite

A local challenge implementation in [Goose](https://github.com/aardappel/goose),
pinned to compiler commit `f605b5a07dd2aa3a5cb3f4c9b14002bd3c9d3d1a`.
It serves HTTP/1.1 directly on `HOST:PORT`.

`app.goose` owns routing, JWT algorithm/claim validation, request JSON parsing,
Unicode trimming and character limits, SQL selection, database row traversal,
and response object/array construction. `net.c` and its included backends own
Linux sockets and HTTP framing. `db.c` adapts SQLite, environment/time and
OpenSSL HMAC. `json_fast.c` is a generic JSON string quoting primitive with
bounded ARM NEON/SSE2 scanning. These native helpers contain no application
route handlers, SQL selection or response-data caches.

## Build and run

```sh
sudo bash install.sh
bash build.sh
SQLITE_PATH=/path/to/feed.db JWT_SECRET=twelve-dollar-challenge \
  HOST=0.0.0.0 PORT=80 bash start.sh
```

The source installer checks the pinned compiler archive. The build checks the
SQLite 3.53.4 archive, emits standalone C with Goose `-O2`, and uses GCC `-O3
-march=native` with LTO for the application and native helpers. SQLite and the
application receive separate profile-guided optimization. The application
trainer exercises real HTTP requests against disposable, independently
generated dense, sparse and empty databases, including writes and error paths.
Its profile-dump helper is absent from the production executable. Challenge
seed data is never used for compiler training. Version pins and checksums are
in the scripts. `GOOSE_APP_PGO=0 bash build.sh` disables application PGO for
comparisons.

`GOOSE_IO_BACKEND=epoll|uring|auto` selects the transport; epoll is the default
selected by the local comparison. The automatic path
attempts io_uring and falls back to epoll when the kernel denies or lacks the
required facilities. Forced `uring` fails explicitly if initialization is
unsupported. The io_uring path needs Linux io_uring enabled by the host's
security policy. The epoll path does not need it.

## Request processing

One event loop and one SQLite connection process batches of up to 64 requests.
A deferred transaction spans each ready batch, and writes commit before any
batch response is sent. SQLite uses WAL/NORMAL, foreign keys, exclusive locking,
persistent prepared statements, an 8 MiB page cache and mmap disabled.
`GOOSE_SQLITE_CACHE_KIB` (1–524288 KiB) and `GOOSE_SQLITE_MMAP_MIB` (0–4096 MiB)
override those memory settings; invalid values fail startup. A RESTART
checkpoint follows committed batches when the WAL reaches 4096 frames.

The feed discovers the current newest 20 IDs on every request. Compact live ID
ranges use three scans and restore timestamp/ID order; sparse ranges use the
ordinary query. SQLite groups the bounded live likes scan by post ID and returns
one count per post, reducing repeated SQLite/Goose calls. No result data survives
a request. This follows the pinned Rust
leader's query strategy without assuming seed IDs. Every JWT signature is
checked, and Goose validates complete JSON documents in one pass, including
escaped keys and values and unknown nested members.

The single application thread reuses OpenSSL HMAC/SHA-256 key setup. Every
token still computes and compares a fresh MAC and runs all Goose algorithm,
expiration and claim checks. Secret changes create fresh keyed state; failed
cryptographic operations invalidate it. Owned secret bytes are cleansed on
replacement or release.

C synchronously calls the exported Goose handler with borrowed request slices.
Those views remain valid only during that callback. Initialization builders end
before the event loop starts; only scalar locals remain live across callbacks,
so callback scratch cannot overwrite a suspended Goose builder. SQLite strings
are quoted directly into the response builder without an intermediate copy.
The final response is copied into stable transport storage for asynchronous I/O.

Both transports share the HTTP parser and support fragmented requests,
pipelining, chunked bodies and partial writes. io_uring uses multishot
accept/receive, provided receive buffers and batched sends. Complete requests
can borrow receive buffers; fragmented requests retain owned storage. Connection
and response buffers are reused as storage, never as cached application data.
Idle keep-alive connections remain open for at least 125 seconds.
Response headers use fixed fragments and decimal length formatting. Socket
activity uses monotonic time refreshed per readiness and flush batch, including
after database commit.

## Local measurements

The original prototype, first PGO follow-up, and subsequent optimization
experiments are preserved under `results/goose-2026-10-22/`. The optimization
index records selected binaries, source hashes, profiles, every attempt and the
unchanged Rust control. These compare complete implementations on local Linux
ARM64; they do not establish the official x86-64 k6 capacity or an isolated
language-speed effect.
