# D — vibe.d (vibe-http) — cyrusmsk

A D implementation of the feed API using [vibe.d](https://vibed.org/)'s `vibe-http` server and the
`d2sqlite3` driver, with declarative JSON via `asdf` and JWT verification via `jwtlited`.

## Stack and pinned versions

| | |
|---|---|
| Language | D, compiled with **LDC 1.42.0** (`--build=release`) |
| HTTP server | `vibe-http` **1.5.1** (on `vibe-core` **2.14.0** / `eventcore` **0.9.39**) |
| SQLite driver | `d2sqlite3` **1.0.0** (`with-lib` configuration) |
| JSON | `asdf` **0.8.0** (`serializeToJson` / `deserialize`) |
| JWT | `jwtlited:phobos` **1.4.0** (HS256) |
| TLS stream | `vibe-stream:tls` **1.4.1** with the `notls` configuration |
| System libs | `libsqlite3-dev`, `libssl-dev`, `zlib1g`, `libxml2`, `liblzma5` (see `install.sh`) |

Dependencies are pinned in `dub.json` and `dub.selections.json`. Nothing is prebuilt; `build.sh`
compiles from source with `dub build --build=release --compiler=ldc2`.

### Server model

`vibe-http` runs an asynchronous, fiber-based server on top of `eventcore`'s `epoll` event loop, so a
single thread drives many connections at once without a thread per connection. HTTP keep-alive works
out of the box.

### Nginx or direct

**Direct** — `bin/server` listens on `0.0.0.0:80` (from `HOST`/`PORT`) and handles the connections
itself, saving Nginx's 14–20% CPU. It also works unchanged behind the provided Nginx on
`127.0.0.1:3000`, because the bind address is read from the environment.

## Build-time optimizations

* `-flto=full` — full link-time optimization across `vibe-http`, `vibe-core`, `eventcore`,
  `d2sqlite3`, `asdf` and `jwtlited`, so cross-module calls get inlined.
* `-mcpu=native` — generate code tuned for the build machine's CPU.
* `versions: VibeManualMemoryManagement` — vibe's manual (malloc/`freeList`) memory management to
  keep the GC out of the connection hot path.
* `versions: VibeHighEventPriority` — run the event loop with high scheduling priority.
* `versions: VibeDisableCommandLineParsing` — skip vibe's argument parser at startup.
* `subConfigurations: d2sqlite3=with-lib` — build and statically link the bundled SQLite C library.
* `subConfigurations: vibe-stream:tls=notls` — drop TLS support, since the endpoint is plain HTTP.

## Runtime optimizations

* **Aggressive but safe SQLite pragmas** (set once at startup): `journal_mode=WAL` (readers don't
  block the writer), `synchronous=NORMAL` (no fsync per commit in WAL), `busy_timeout=5000`,
  `cache_size=-65536` (64 MB page cache), `temp_store=MEMORY`, `mmap_size=268435456`.
* **Prepared statements** for every query (`db.prepare(...)`), including `INSERT ... RETURNING` for
  post creation so the new `id` and `created_at` come back in the same round trip.
* **Single-statement like semantics**: `INSERT INTO likes(user_id, post_id) SELECT ?,? WHERE
  EXISTS(SELECT 1 FROM posts WHERE id=?) ON CONFLICT DO NOTHING`, then read `SELECT changes()`:
  `1` → 201 created, `0` and the post exists → 200 already liked, `0` and it does not → 404.
* **`like_count` via an indexed correlated subquery** on the `likes(post_id)` index, using the
  `JOIN` to `users` only for the author name.
* **Declarative JSON** with `asdf`: plain structs (`Post`, `FeedEnvelope`, `LikeResponse`, …) are
  serialized/deserialized directly, keeping the response shapes and key order in one place.
* **Auth first**: the bearer/`alg`/`exp`/`sub`/`username` checks run before any database work, as the
  tests require (e.g. `POST /posts/abc/like` returns 401, not 400, without a token).
* Body length is measured in **UTF-8 code points** (`byCodePoint`) to match SQLite's `length()`.

## Layout

```
source/app.d   the whole server (routing, auth, SQL, JSON)
dub.json       dependencies, versions and build flags
install.sh     LDC 1.42.0 + SQLite/OpenSSL dev libs (run once as root)
build.sh       dub build --build=release
start.sh       exec bin/server
```
