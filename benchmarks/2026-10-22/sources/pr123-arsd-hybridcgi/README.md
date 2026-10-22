# D — arsd.cgi (hybrid) — cyrusmsk

A D implementation of the feed API using [arsd](https://arsd-official.dpldocs.info/)'s
`embedded_httpd_hybrid` server and its SQLite binding, with JWT verification via `jwtlited`.

## Stack and pinned versions

| | |
|---|---|
| Language | D, compiled with **LDC 1.42.0** (release, `-boundscheck=off` by default in release) |
| HTTP server | `arsd-official:cgi` **12.1.2**, `embedded_httpd_hybrid` configuration |
| SQLite driver | `arsd-official:sqlite` **12.1.2** (thin binding over the system `libsqlite3`) |
| JWT | `jwtlited:phobos` **1.4.0** (HS256) |
| System libs | `libsqlite3-dev`, `zlib1g`, `libxml2` (see `install.sh`) |

Dependencies are pinned in `dub.json` and `dub.selections.json`. Nothing is prebuilt; `build.sh`
compiles from source with `dub build --build=release --compiler=ldc2`.

### Server mode

`dub.json` selects the `embedded_httpd_hybrid` configuration: the listener is `fork()`ed and each
process runs an `epoll` event loop that dispatches every request as a fiber over a kernel thread pool
for blocking work. A fiber per connection scales to ~15,000 keep-alive connections on a single core
without a thread per connection.

`embedded_httpd_hybrid` is Linux-only — it relies on `epoll` and `fork()`, and arsd refuses to
compile it elsewhere — so this submission is built for the Linux benchmark host. (The portable
counterpart is the sibling `d-arsd-threadedcgi-cyrusmsk` submission.)

### Nginx or direct

**Direct** — `bin/server` listens on `0.0.0.0:80` (from `HOST`/`PORT`) and handles the connections
itself, saving Nginx's 14–20% CPU. The fiber server is what makes direct mode's ~15,000 connections
viable. It also works unchanged behind the provided Nginx on `127.0.0.1:3000`, because the address is
read from the environment.

## Optimizations

* **Hybrid embedded server + fibers.** `embedded_httpd_hybrid` dispatches each connection as a fiber
  on an `epoll` loop, handling the connection count that would otherwise need a thread each, on a
  single vCPU.
* **One SQLite connection per worker thread, with reused prepared statements.** Every statement
  (`feed`, `post`, `exists`, `insert post`, `insert like`) is prepared once per thread and only
  re-bound per request, so no request pays `sqlite3_prepare`. The connection is opened lazily the
  first time a thread handles a request, i.e. *after* the hybrid listener forks, so children never
  inherit a database handle.
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
dub.json       dependencies + the embedded_httpd_hybrid configuration
install.sh     LDC 1.42.0 + SQLite dev libs (run once as root)
build.sh       dub build --build=release, then copy to bin/server
start.sh       exec bin/server
```
