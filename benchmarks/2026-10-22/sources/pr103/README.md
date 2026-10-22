# Go + Gin

| | |
|---|---|
| Language | Go 1.27.2 (pinned in `install.sh`) |
| Framework | Gin 1.12.0 |
| Server | the standard library `net/http` server that Gin runs on |
| SQLite driver | mattn/go-sqlite3 1.14.52 (CGO; SQLite is compiled into the binary) |
| JSON | the standard library `encoding/json` |
| **Nginx or direct** | **Direct**: serves `0.0.0.0:80` itself |

All dependency versions, transitive ones included, are pinned in `go.sum`.

## Why Gin

[Gin's benchmarks](https://gin-gonic.com/en/docs/benchmarks/) (Gin v1.12.0, March 2026) put it at
the top of the Go router rankings: first place on the GitHub API workload (203 routes, all methods)
at ~10 µs/op with **zero heap allocations per route**, and top-tier on every other routing test.
Zero-alloc routing matters here because the box has one vCPU — routing work never turns into GC
pressure. Gin is also near the top on routing-structure memory (59 KB for 203 routes).

Just as important is what Gin is *not*: a benchmark-only framework. It's a mainstream, batteries-light
framework on top of the standard `net/http` — route groups, middleware, path params, nothing exotic.
The goal was to keep this submission reading like a normal enterprise API you'd maintain at work,
not a hand-tuned benchmark artifact. The speed comes from the database path (prepared statements,
pragmas, hand-verified JWT), not from giving up readability.

## Running it

```bash
sudo bash install.sh   # apt: build-essential, curl; installs Go 1.27.2 to /usr/local
bash build.sh          # CGO build to bin/server, using go.sum
SQLITE_PATH=... JWT_SECRET=... HOST=0.0.0.0 PORT=80 bash start.sh
```

## Optimizations, and why

- **Direct instead of Nginx.** On one vCPU, Nginx's CPU comes straight out of the Go process's
  budget. `net/http` already handles thousands of idle keep-alive connections with goroutines, and
  Gin's default server has no read or idle timeout, so connections are never closed on the client.
- **Prepared statements for every query.** The query plan is built once at startup instead of per
  request (explicitly allowed by rule 5 — every request still reads from SQLite). The feed, post
  lookup, and like insert are each a single statement.
- **Hand-rolled JWT verification** with `crypto/hmac` + `crypto/sha256` on every request: HS256
  pinned, constant-time signature compare, `exp` checked (missing counts as expired). The signature
  is verified before any JSON is parsed, so garbage tokens are rejected with zero allocation. The
  `hash.Hash` comes from a `sync.Pool`, so no JWT library and no per-request hasher allocation. No
  caching of verifications (rule 5).
- **Structs instead of maps** for responses, so the JSON key order is exactly what `SPEC.md`
  requires and encoding is allocation-light. The three 401 error bodies are pre-serialized byte
  slices written directly.
- **Gin in release mode, no middleware but recovery.** No logger means nothing written to stdout
  per request, and trusted proxies are off. Unknown paths hit `NoRoute` and return a real 404.
- **Pragmas**: `journal_mode=WAL`, `synchronous=NORMAL` (rule 6), a 5 s busy timeout,
  and a 64 MiB page cache via mattn/go-sqlite3 DSN keys
  (`_journal_mode`, `_synchronous`, `_busy_timeout`, `_cache_size`), plus
  `temp_store=MEMORY` and a 256 MiB `mmap_size` through a `ConnectHook` so every pooled connection
  gets them. Note the driver has no generic `_pragma=` DSN syntax — that's modernc.org/sqlite.
- **One SQLite connection.** On one vCPU, serializing database work avoids SQLite lock/pool
  contention and measured faster than a 16-connection pool for the mixed workload.
- **`GOGC=300` by default.** A controlled one-core load run reduced garbage-collection work without
  materially increasing RSS; set `GOGC` explicitly to override it.
- **The schema is used exactly as given.** `created_at` comes from the column default
  (`strftime('%Y-%m-%dT%H:%M:%fZ','now')`), read back in the same statement via
  `INSERT ... RETURNING`.

## License

MIT, under the repo's [license](../../LICENSE).
