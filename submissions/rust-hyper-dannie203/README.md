# Rust / Hyper / SQLite

Direct HTTP/1.1 on $HOST:$PORT. No Nginx, external database, async multi-threaded contention, or ORM. Single-threaded event loop with persistent SQLite read pool and a dedicated write actor.

## Build and run

```bash
sudo bash install.sh
bash build.sh
SQLITE_PATH=/path/to/feed.db JWT_SECRET=twelve-dollar-challenge \
  HOST=0.0.0.0 PORT=80 bash start.sh
```

`start.sh` runs in the foreground using only the four environment variables specified in `SPEC.md`. Direct serving on port 80 avoids reverse-proxy CPU overhead, allocating all cycles to in-process connection management and SQLite operations.

## Implementation

- **Toolchain & Binaries**: Rust 2021, compiled with `-C target-cpu=native`, fat LTO (`lto = "fat"`), single codegen unit (`codegen-units = 1`), `panic = "abort"`, and stripped debug symbols. Dependencies are pinned in `Cargo.toml` and `Cargo.lock`.
- **Event Loop & Server**: Hyper v1 driven by a single-threaded Tokio runtime (`tokio::main(flavor = "current_thread")`). On a 1 vCPU constraint, a single-threaded reactor eliminates thread synchronization, context switching, and cache bouncing across CPU cores.
- **Database Concurrency**:
  - **Readers**: Pool of 16 persistent read-only SQLite connections (`SQLITE_OPEN_READ_ONLY`) holding pre-compiled prepared statements. Avoids `sqlite3_open_v2`, statement compilation, and AST re-parsing on read queries.
  - **Writer**: Single dedicated OS thread fed by a bounded channel (`crossbeam-channel`). Write operations (`POST /posts`, `POST /posts/:id/like`) are dispatched via channel, serializing SQLite transactions and eliminating `SQLITE_BUSY` contention without lock spinning.
  - **Durability**: `PRAGMA journal_mode = WAL;`, `PRAGMA synchronous = NORMAL;`, `PRAGMA busy_timeout = 5000;`. HTTP 201 responses are returned strictly after the write transaction commits to disk.
- **Feed Query**:
  - Uses a set-based Common Table Expression (`WITH recent AS (SELECT ... LIMIT 20)`) to restrict index seek and join operations to the 20 candidate rows before computing like counts.
- **Zero-Allocation Token Verification**:
  - Stack-based Base64URL decoder working entirely in stack registers without heap allocations.
  - HMAC-SHA256 signature calculated directly on the raw `header.payload` byte slice and compared in constant time.
  - Claims (`sub`, `username`, `exp`) extracted directly using fast byte scanners (`memchr`) without allocating a JSON AST.
  - No auth caching across requests: every incoming token is validated dynamically per SPEC.md.
- **Payload Framing & Serialization**:
  - Exact JSON serialization order matching official golden test fixtures (`author`, `body`, `created_at`, `id`, `like_count`).
  - Integer conversions handled via stack formatting (`itoa`), minimizing memory allocation in the critical response path.

## Verification

Runs the official challenge correctness test suite:

```bash
bash test/run.sh submissions/rust-hyper-dannie203
```
