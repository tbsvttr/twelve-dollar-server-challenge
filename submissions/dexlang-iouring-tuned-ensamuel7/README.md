# DexLang (generated C, io_uring), tuned

| | |
|---|---|
| **Language** | [DexLang](https://github.com/ensamuel7/dex) `v0.9.26`: statically typed, compiles to C, which `cc` builds into a native binary |
| **Framework** | None. DexLang's own `http` and `db` standard library modules |
| **Server** | The `http` module's io_uring backend (`http.uring()`), with handlers run on the ring's thread |
| **SQL** | Built with [dexqu](https://github.com/ensamuel7/dex-modules/tree/main/dexqu) `v0.1.0` at startup, prepared once; used for every write |
| **Reads** | `btree.c`, about 540 lines of C that read SQLite's B-tree cursors directly and write the JSON, falling back to the SQL whenever it can't answer exactly |
| **SQLite driver** | SQLite 3.54.1, the official amalgamation compiled into the binary by the `db` module (`DEX_SQLITE`), pinned and sha256-checked in `build.sh` |
| **Build toolchain** | Go 1.27.2 to build the compiler, then `cc` (gcc 13) on the C it emits |
| **Nginx or direct** | **Direct**, on `HOST:PORT` (`0.0.0.0:80` on the benchmark box) |

This is the tuned companion to
[`dexlang-iouring-ensamuel7`](../dexlang-iouring-ensamuel7) (#251, 199,000).
That entry is kept close to how a production service would be written. This
one starts from the same program and adds the things a production service
usually wouldn't do, to see how far the same language and runtime go. The
rules are the same: every request reads SQLite, nothing is cached, writes are
committed before their response, and every response is byte for byte what the
other entry sends.

DexLang compiles to C. What runs is one native binary with SQLite compiled in:
no interpreter, no garbage collector, no framework. The program is about 620
lines of DexLang in `server.dx` and `queries.dx` plus the read engine in
`btree.c`; everything below that is the language's standard library,
unmodified for this challenge.

## What this adds to #251

- **Reads go through SQLite's B-tree cursors, not SQL.** `GET /feed`,
  `GET /posts/:id` and the like handler's "does this post exist" check are
  answered by `btree.c`. `build.sh` compiles it in the same translation unit as
  the stock amalgamation, which gives it SQLite's internal B-tree interface.
  SQLite itself is unchanged. The engine opens read-only cursors on the
  program's own connection, inside the transaction the batch already holds,
  and reads the same indexes the SQL plan does:
  - **The feed** walks `posts_created_at_id_idx` from the newest entry. New
    posts get consecutive ids, so the posts cursor steps back one row from the
    last post instead of seeking from the root, and seeks only when an id
    isn't the one before.
  - **The like counts** come from one backwards walk through
    `likes_post_id_idx`: positioned once, the way SQLite's `OP_SeekLE` does,
    then each post continues from where the one before it stopped. A post out
    of descending id order seeks again.
  - **Records are read in place** on their B-tree page, as SQLite's own column
    reads take them. They are copied out only when a row spills onto overflow
    pages.
  - **The engine writes the response body itself**: the JSON `json.encode`
    makes of the same structs, with the same escaping, built straight from the
    records into one reused buffer. Each value is copied once, with no `Post`
    structs or strings in between.

  It checks the schema at startup and the schema cookie on every call. It
  returns "can't answer" (-1) on anything it doesn't expect, and the handler
  then runs #251's SQL. That covers no open transaction, a record of another
  shape, a NUL byte in a text value, and a value bigger than its buffers. A
  post whose author row is missing is skipped, as the SQL's inner join skips
  it. Writes all stay in SQL.
- **No memory map, a 32 MB page cache.** A mapped page read costs a WAL lookup
  plus a fetch and an unfetch per page. The mapped pages also count against the
  box's 2 GB, next to a quarter of a million connections.
- **SQLite options this program doesn't need are compiled out.** A prelude in
  `build.sh` undoes `SECURE_DELETE`, which zeroes freed space on every write,
  and adds `OMIT_DEPRECATED`, `OMIT_SHARED_CACHE`, `OMIT_PROGRESS_CALLBACK` and
  `MAX_EXPR_DEPTH=0`.
Measured locally against #251, under the same think-time load (the k6 user
loop with think times scaled down), on an arm64 VM. Treat these as relative,
not as box numbers:

| | #251 | this entry |
|---|---:|---:|
| user-space instructions per request (callgrind, the same 38k-request run) | 82.8k | **43.0k** |
| 20,000 think-time users, ~41k req/s: server CPU per request, four runs taking turns | 15.1 / 16.6 / 17.1 / 15.9 µs | **14.5 / 16.3 / 13.2 / 14.2 µs** |
| wrk, 1,000 connections, k6-like mix: peak RSS | 201 MB | **85 MB** |

The instruction count is the steadier measure, because it doesn't move with
what else the machine is doing. The CPU-time figures include the kernel's
loopback TCP, which is the same for both and is most of each request here.

Responses were checked against #251's byte for byte: the feed and about 3,000
post lookups, with a logging build counting which path answered each one. The
cases were:
- the seed;
- 3,000 likes on the newest post;
- holes in the id range, with random likes over the newest 50 posts;
- an old post among the newest;
- a post whose author row is missing;
- long UTF-8 bodies, equal `created_at` values, and every escaped character.

The engine answered all of them. It handed only a NUL inside the newest body
back to the SQL, as designed. The entry passes the test suite, 42/42.

**Tried, not kept:**
- `http.batchWindow(1)` (dex v0.9.28 and later), which holds a batch open for
  a millisecond: 14.1–14.5 µs per request under wrk, and no better under
  think-time load.
- Moving to dex v0.9.29 on its own: no difference.

## How it serves

**io_uring, opted into with one call.** `http.uring()` switches the `http`
module from its epoll loop to an io_uring one. Accepts, receives, sends,
shutdowns and closes are queued on one ring and submitted together, so each pass
of the loop is one system call however many connections it served, with up to 64
accepts in flight. The ring is set up with `SINGLE_ISSUER | DEFER_TASKRUN` and
uses raw `io_uring_setup`/`io_uring_enter`, so there is no liburing dependency.
If a machine refuses io_uring (an old kernel, or a container that blocks it), the
server says so and serves the same routes with epoll.

**Several rings of direct descriptors, on one thread.** Accepted sockets go into
a ring's registered file table, which doesn't use the process's descriptors. The
kernel caps one table at the open-file limit, so `http.limits(0, 75, 200000)`
makes the runtime open three rings on the same thread, each with its own 65,535
slots, plus ordinary descriptors once those are full: about 262,000 open
keep-alive connections under `LimitNOFILE=65535` before anything has to
reconnect (it was 131,000 with one ring). The thread sleeps in epoll on the
rings' eventfds when none has work. Past fifteen sixteenths of the limit,
responses carry `Connection: close` so idle users reconnect for their next
request; at the limit, new connections wait in the listen queue instead of
being refused.

**No read buffer per idle connection.** Receives take a buffer from a ring the
kernel fills (`IORING_REGISTER_PBUF_RING`), and the bytes are copied out at
once into a pooled per-request buffer that goes back when the response is
sent. A keep-alive user thinking between requests holds no read buffer, so a
quarter of a million of them do not need half a gigabyte of buffers.

**Handlers run on the ring's thread.** There is no handoff to a pool, no lock
and no wakeup per request. On one vCPU with handlers that only touch an SQLite
file, that is the cheapest shape. Each pass of the loop runs the handlers for
every request that arrived, then the batch hook below, then queues all the
responses.

**The same protections as the default server.** 32 KB header cap (431), 8 MB
body cap (413), and a 75 s idle timeout that shuts a stalled connection down.
Both backends were run under AddressSanitizer and UndefinedBehaviorSanitizer
against slow, oversized, aborted and reset clients, with no findings.

## The database

- **The statements are built once with dexqu** (`queries.dx`) and prepared
  at startup. A request only binds and steps.
- **When the read engine can't answer, the feed falls back to #251's SQL:
  three range reads, not twenty lookups.** The reference query runs a like count and an author join for each of its 20 posts. Here the feed
  reads the 20 newest ids from `posts_created_at_id_idx` (covering, no sort),
  then makes one pass over `likes_post_id_idx` for the like counts and one over
  `posts` (joined to `users`) for the rows, both over the id range the 20
  cover, and puts the rows back in feed order. New posts get consecutive ids,
  so that range is normally the 20 posts and nothing more. Rows in the range
  that are not among the 20 are skipped; if the ids span 256 or more, or one
  of them has no row, the handler runs the reference query instead. The
  answer is always the reference query's: checked byte for byte against it on
  the seed, with likes on the newest posts, with an old post among the newest,
  with a hole in the range, and with a post whose author row is missing.
  Every feed request still runs its queries; nothing is cached.
- **Group commit (`http.afterBatch`), with reads in the same transaction.**
  The first handler in a batch that touches the database opens a transaction
  (`beginBatch`); `commitBatch` commits it once per pass of the loop, and the
  runtime holds every response in that pass until it returns. So a `201` still
  goes out only after its row is committed (rule 6), but under load one commit
  and one WAL write cover all the likes and posts of a pass instead of one
  each, and the reads in the pass share one snapshot instead of taking one per
  statement. A read sees the writes before it in its batch, which is what it
  would see if the requests ran one after another. If the commit fails, the
  runtime answers every request in the batch, reads included,
  `500 {"error":"internal server error"}` rather than what its handler said;
  nothing is acknowledged that is not durable.
- **Every statement is reset as soon as it's read.** A statement left on a row
  keeps the connection's read transaction open, so an `INSERT` on the same
  connection wouldn't commit until the next reset. Resetting first means a 201
  goes out after its row is committed (rule 6), and lets the WAL checkpoint.
- **The request connection is opened with `db.openSingleThreaded`, on the
  `unix-excl` VFS.** Only the ring's thread uses it, so it skips the mutex
  SQLite otherwise takes on every call. `unix-excl` is SQLite's own VFS that
  takes the file lock for this process once and keeps the WAL index in heap
  memory, so no other process can open the database while the server runs,
  and the connections inside it share the index without a mapped `-shm` file.
- **Checkpoints run on their own thread and connection.** The event loop sets
  `wal_autocheckpoint=65536`, so it does not copy the WAL back itself under
  normal load. A thread spawned at startup runs `wal_checkpoint(PASSIVE)`
  every 100 ms: it copies committed frames into the database file and fsyncs
  it without blocking the writer, so the loop never waits on that disk work.
  Once the WAL passes 8,192 frames (32 MB), the thread also runs a `RESTART`
  pass, which waits for the writer between batches and lets the next commit
  start the WAL from the beginning. That is why a batch begins with
  `BEGIN IMMEDIATE`: a transaction that has already read cannot wait for the
  write lock it then needs (SQLite answers BUSY at once), but one that asks
  for it first waits under `busy_timeout`. In local runs at full load the WAL
  stayed under about 50 MB; with passive passes alone it grew to the 256 MB
  ceiling the loop's autocheckpoint sets as a fallback. Durability is
  unchanged: every commit is in the WAL, written with `synchronous=NORMAL`,
  before its response goes out. If the second connection cannot be opened,
  the loop checkpoints as SQLite normally does.
- **`ON CONFLICT DO NOTHING ... RETURNING`** answers "liked now" and "already
  liked" in one statement.
- **SQLite is compiled in, not linked.** `build.sh` downloads the official
  3.54.1 amalgamation, checks its sha256, and dex compiles it with the program
  under the same `-O3 -flto`, so calls into SQLite can be inlined. It is built
  with the db module's defaults, which match Ubuntu's `libsqlite3` (FTS,
  R-tree and so on), less the options listed at the top. It stays thread-safe,
  because the checkpoint thread has a connection of its own.

```
vfs                = unix-excl   one process; WAL index in heap memory
journal_mode       = WAL
synchronous        = NORMAL      rule 6: a commit reaches the WAL before the response
busy_timeout       = 5000
cache_size         = -32768      32 MB of pages
mmap_size          = 0           reads go through the page cache
temp_store         = MEMORY
journal_size_limit = 67108864
wal_autocheckpoint = 65536       a ceiling; the checkpoint thread does the work
```

No response or query result is cached. Every request reads SQLite.

## Responses

Every response body is `json.encode` of a struct or an object literal, so the
wire shapes are written down once and no JSON is assembled by hand:

```dex
let p: Post = Post {}
db.fill(p, stOne)
db.reset(stOne)
return http.response(200, json.encode(PostEnvelope { post: p }), "application/json")
```

`db.fill` reads a row into the struct by column position, and field order is key
order, which is the order the spec fixes. The compiler generates one encoder per
struct: keys are literals, numbers go through an integer writer, and a string
with nothing to escape is copied in one `memcpy`. A 20-post feed page encodes in
about 1.3 µs.

## Auth

HS256 is verified on every request: the MAC is recomputed in base64url and
compared to the signature segment, so there's no decode on the hot path. `alg`
is checked explicitly (a valid HMAC over a header saying `HS512` is the
algorithm-confusion bug), and `exp` is required. A token without it is a 401.

## What the language gained from this challenge

All of it went into DexLang's standard library and compiler, not into this
folder:

- `http.uring()`: the io_uring backend with direct descriptors described above.
- `http.inline()`: handlers on the event-loop thread, for the epoll backend.
- Connection shedding near the open-file limit, `SOMAXCONN` listen queue,
  `accept4` with `SOCK_NONBLOCK | SOCK_CLOEXEC`.
- A thread-safety fix: an `http` server with no `mutex` or `spawn` of its own
  was built single-threaded although its handlers ran on a pool, which corrupted
  the allocator under concurrent requests. Found with ThreadSanitizer.
- Two `json.encode` code-generation fixes (arrays of enums in a struct, and a
  struct literal whose fields call functions in a program that throws).
- Per-request path and query storage instead of 4 KB fixed buffers per
  connection.
- A generated `json.encode` per struct, about 9x faster than the
  field-descriptor encoder it replaces and as fast as writing the bytes by hand,
  with byte-identical output; and a fix for struct literals passed straight to
  it, which leaked the values they created.
- `db.openSingleThreaded`, a connection without SQLite's per-call mutex for
  code that only ever uses it from one thread.
- `DEX_SQLITE`, which compiles a pinned SQLite amalgamation into the binary
  instead of linking the system library.
- `db.reset` clears parameters one at a time instead of with
  `sqlite3_clear_bindings`, which in SQLite 3.54 forces some statements to be
  re-parsed on every use.
- A heap overflow in response building when a handler passed a content type
  longer than about 400 bytes, found while replacing its `snprintf`.
- `req.headers` built the first time a handler uses it, not for every request.
  The map owns a copy of the header lines, so one kept past its request is
  still valid, and it reads the same as parsing up front: the HTTP transcript
  tests' new cases were recorded with the previous runtime and reproduce byte
  for byte. Here only the like and post handlers read a header, so the feed
  and single-post requests no longer build the strings.
- A data race between the thread pool and the idle sweep over a connection's
  state, found with ThreadSanitizer, and a macOS kqueue bug (filter deletes
  dropped after a failed one) that left connections reported twice per wait
  and freed under the event loop. Neither path runs on the benchmark box.
- Several io_uring rings on one thread when `http.limits` asks for more
  connections than one ring's descriptor table holds, receives through a
  kernel buffer ring instead of a buffer per connection, and an idle sweep
  that reads compact per-slot timestamps rather than every connection.
- `http.afterBatch`, the group-commit hook above. Under io_uring a batch is a
  pass of the loop; on epoll and the thread pool it is one request, so code
  written for it is correct on every backend.

## Files

```
server.dx    routes, handlers, auth, response building
queries.dx   the SQL statements, built with dexqu
btree.c      the read engine: /feed, /posts/:id and the like check on B-tree cursors
btree.h      its interface, as server.dx's `external module bt` sees it
dex.mod      module file: dex 0.9.26, dexqu v0.1.0 (pinned in dex.sum)
install.sh   root, once: build-essential, git, pkg-config, libsqlite3-dev,
             libssl-dev, libcurl, and Go 1.27.2 (sha256-checked)
build.sh     builds the dex compiler from the pinned v0.9.26 tag through the Go
             module proxy (checksum-verified), fetches dexqu and the SQLite
             3.54.1 amalgamation (sha256-checked), writes the sqlite3.c that
             includes it and btree.c, compiles server.dx
start.sh     raises the soft open-file limit to the hard one and runs the server
```
