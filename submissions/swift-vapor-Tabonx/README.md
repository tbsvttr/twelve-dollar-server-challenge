# Vapor, written the way you'd want to inherit it

| | |
|---|---|
| Language | Swift 6.4.1 in Swift 6 language mode |
| Framework | Vapor 4.122.3 |
| SQLite | GRDB 7.11.1 on the system SQLite (3.45.1 on Ubuntu 24.04) |
| JWT | vapor/jwt 5.2.0, HS256 only |
| Nginx or direct | direct, on `0.0.0.0:80` |

[swift-iouring-Tabonx](https://github.com/arjaythedev/twelve-dollar-server-challenge/tree/main/submissions/swift-iouring-Tabonx)
is what Swift can do if you give up everything pleasant about it. This entry is the opposite
experiment. It is the code I would ship at work: controllers, middleware, a repository, typed
errors, tests, no unsafe pointers on the request path, and async/await the whole way down. It is
tuned only where the tuning doesn't cost readability.

## Why there is no Fluent

Fluent is the first thing a Vapor project reaches for, and I started there. Reading its SQLite
driver changed my mind, for three concrete reasons.

- `maxConnectionsPerEventLoop` is ignored for SQLite. You get one connection per event loop, so
  readers queue behind each other even though WAL lets them run side by side.
- It has no hook for running a `PRAGMA` on each new connection. SQLiteNIO's SQLite isn't built
  with a lower default, so a WAL connection stays at `synchronous=FULL` and fsyncs every commit.
- SQLiteNIO prepares every statement from scratch. There is no statement cache.

Fluent's main gifts are models and migrations, and this schema is fixed. The feed needs raw SQL for
the correlated like count anyway. GRDB gives a real WAL reader pool, a `prepareDatabase` hook and
`cachedStatement`, and it fits inside Vapor without any friction: `configure` opens the pool, the
repository goes into `Application.storage`, and a `LifecycleHandler` closes it on shutdown.

## Why there is no Content

`Content` is the other thing every Vapor tutorial starts with. It encodes through `JSONEncoder`, and
the API's key order is part of its contract. `JSONEncoder` keeps a keyed container in a
`[String: JSONFuture]`, so `id` can land anywhere, and because Swift seeds its hashes per process,
the order can change between two runs of the same binary. The only related option is `.sortedKeys`,
which is alphabetical, and this API isn't. A custom `encode(to:)` doesn't help, because it ends up
in the same dictionary.

So responses conform to `AsyncResponseEncodable` directly and write themselves through a
`JSONWriter` of about 120 lines. A handler still just returns a `PostResponse`, and Vapor doesn't
know the difference.

Requests went the other way and use plain `Decodable`. `CreatePostRequest` swallows type errors in
`body` on purpose, so a `{"body":123}` reaches validation and gets "body is required", while broken
JSON gets "malformed JSON body".

## Things worth stealing

**Auth runs as middleware, before the handler.** `POST /posts/abc/like` must return 401 without a
token and 400 with one, so `BearerTokenAuthenticator` sits on the route group and the id gets parsed
afterwards. Vapor's own `BearerAuthenticator` is built to let anonymous requests through for a
later guard, and this API has three different 401 messages, so it is a small `AsyncMiddleware`.

**jwt-kit doesn't check `alg` for you.** With a single key in the collection, it verifies against
that key whatever the header says, so a token labelled HS512 but signed with the HS256 key gets
through. The middleware reads the header first. There's a test for it.

**Vapor's default error body is the wrong shape.** It answers `{"error":true,"reason":"..."}`.
`configure` replaces the whole middleware stack, and `JSONErrorMiddleware` sits first, so it also
sees the router's 404. Anything it doesn't recognise is logged in full and goes to the client as a
plain 500 with no details.

**Foundation's trim is not JavaScript's trim.** `.whitespacesAndNewlines` strips U+0085 and leaves
U+FEFF, the reverse of what `String.prototype.trim` does. `PostBody` carries the exact set, and it
counts length in Unicode scalars because that is what the schema's `CHECK` counts. `String.count`
counts grapheme clusters, so 300 `é`s written with combining marks are 300 characters to Swift and
600 to SQLite.

**Failing early beats failing later.** A missing `SQLITE_PATH` stops the process at startup with
a message naming the variable, and a path that doesn't exist fails there too. Without that check
SQLite would happily create an empty file, and every request would then fail with "no such table".

**Shutting down is part of the program.** On SIGTERM Vapor stops accepting, and `DatabaseLifecycle`
checkpoints the WAL and closes the pool, so the `-wal` file is empty when the process exits. Closing
alone wasn't enough here: the first version left the log on disk, and I only found out by looking.

## What a framework costs

The profile under load is the interesting part. About a third of the CPU is the kernel, a tenth is
SQLite, and about a tenth is libc. The rest is Swift, and no single function stands out once the
one real hot spot is gone: `JSONWriter.string` copied byte by byte and took 6.5 %, and now it copies
clean runs whole. What remains is spread thin over `swift_retain`, `swift_release`, `malloc`, and
generic metadata lookups. That is the price of `String`, `Array`, existentials and a task hop per
request, and it doesn't come off without writing a different program.

On a Synteq 1 vCPU box it spent about 240 µs per request and held 35,000 users through a five-minute
hold at 90 % CPU, with p95 at 55 ms and p99 at 156 ms. The io_uring sibling spent about 15 µs per
request on the same machine. So the framework, the libraries and `String` cost about 15 times the
CPU. In exchange this version has no unsafe pointers on the request path, and a new endpoint here
takes a few lines in a controller.

Compiling it is not free either. On the 1 vCPU box a clean build takes about 19 minutes and fits in
2 GB without swap, and the binary comes out at 197 MB.

## Where things live

| | |
|---|---|
| `Sources/App/entrypoint.swift`, `configure.swift`, `routes.swift` | the usual Vapor startup |
| `Sources/App/Controllers/` | `PostController`, `HealthController`, id parsing |
| `Sources/App/Auth/` | the bearer middleware, JWT claims, `Identity` |
| `Sources/App/Middleware/` | `APIError` and `JSONErrorMiddleware` |
| `Sources/App/Database/` | the GRDB pool, `FeedRepository` with every SQL statement, `Post` |
| `Sources/App/DTOs/` | request validation and response bodies |
| `Sources/App/JSON/` | `JSONWriter` and `JSONResponse` |
| `Tests/AppTests/` | swift-testing suites through VaporTesting, with golden responses from the seed |
