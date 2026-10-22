# D — arsd.cgi (threaded) — cyrusmsk

A D implementation of the feed API using [arsd](https://arsd-official.dpldocs.info/)'s
`embedded_httpd_threads` server and its SQLite binding, with JWT verification via `jwtlited`.

## Stack and pinned versions

| | |
|---|---|
| Language | D, compiled with **LDC 1.42.0** (release, `-boundscheck=off` by default in release) |
| HTTP server | `arsd-official:cgi` **12.1.2**, `embedded_httpd_threads` configuration |
| SQLite driver | `arsd-official:sqlite` **12.1.2** (thin binding over the system `libsqlite3`) |
| JWT | `jwtlited:phobos` **1.4.0** (HS256) |
| System libs | `libsqlite3-dev`, `zlib1g`, `libxml2` (see `install.sh`) |

Dependencies are pinned in `dub.json` and `dub.selections.json`. Nothing is prebuilt; `build.sh`
compiles from source with `dub build --build=release --compiler=ldc2`.

### Server mode

`dub.json` selects the `embedded_httpd_threads` configuration: a pool of kernel worker threads, each
accepting and servicing one HTTP request at a time. It is portable to every POSIX platform (this is
the configuration used for local testing on macOS) and handles moderate concurrency well. It does not
allocate a thread per connection, so it is not the right mode for tens of thousands of concurrent
keep-alive connections — the sibling `d-arsd-hybridcgi-cyrusmsk` submission covers that case.

### Nginx or direct

**Direct** — `bin/server` listens on `0.0.0.0:80` (from `HOST`/`PORT`) and handles the connections
itself, saving Nginx's 14–20% CPU. It also works unchanged behind the provided Nginx on
`127.0.0.1:3000`, because the address is read from the environment.

## Optimizations

* **Thread-pool embedded server.** `embedded_httpd_threads` binds a pool of worker threads; each one
  handles a request from start to finish, so there is no per-connection fiber bookkeeping.
* **One SQLite connection per worker thread, with reused prepared statements.** Every statement
  (`feed`, `post`, `exists`, `insert post`, `insert like`) is prepared once per thread and only
  re-bound per request, so no request pays `sqlite3_prepare`. Each connection is opened lazily on the
  first request its thread handles.
* **Aggressive but safe SQLite pragmas.** `journal_mode=WAL`, `synchronous=NORMAL` (durable enough in
  WAL, no fsync per write), `busy_timeout=5000`, `cache_size=-65536` (64 MB), `temp_store=MEMORY`,
  `mmap_size=268435456`. WAL lets readers proceed while a writer commits.
* **Hand-written JSON output.** Responses are produced with a tiny serializer (string escaper +
  integer writer) into a reused `Appender`, in the exact byte/key order the spec requires. No
  reflection-based serialization touches the hot path. `std.json` is only used to parse the small
  request bodies and the JWT payload.
* **Single-statement like semantics.** A like is
  `INSERT INTO likes(user_id, post_id) SELECT ?,? WHERE EXISTS(SELECT 1 FROM posts WHERE id=?)
   ON CONFLICT DO NOTHING`, and the response is decided from `sqlite3_changes()`: `1` → 201 created,
  `0` and the post exists → 200 already liked, `0` and it does not → 404.
* **`INSERT ... RETURNING`** for post creation, so the new `id` and `created_at` come back in the same
  statement with no second round trip.
* **`like_count` via an indexed correlated subquery** (`likes(post_id)` index) rather than a join.
* **Compact routing and validation** that avoid allocations: post ids are parsed with a strict
  digits-only scan, body length is measured in UTF-8 code points, and the bearer/`alg`/`exp`/`sub`/
  `username` checks happen before touching the database (auth first, then id validation, as the tests
  require).

## Layout

```
source/app.d   the whole server
dub.json       dependencies + the embedded_httpd_threads configuration
install.sh     LDC 1.42.0 + SQLite dev libs (run once as root)
build.sh       dub build --build=release
start.sh       exec bin/server
```
