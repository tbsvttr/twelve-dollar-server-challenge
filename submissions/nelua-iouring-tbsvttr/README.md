# nelua-iouring-tbsvttr

One thread of [Nelua](https://nelua.io) (Lua's syntax, statically typed, compiled to C) on io_uring, with SQLite
compiled into the same translation unit. Direct on port 80.

| | |
|---|---|
| Language | Nelua, pinned to commit `a58450563e2d` (Nelua has no releases), built from source by `install.sh`; gcc 13 |
| Framework | none: HTTP/1.1, JSON, HS256 and SHA-256 in Nelua |
| io_uring | raw system calls, no liburing (`src/uring.h`); needs Linux 6.1+ |
| Database | SQLite 3.54.1 amalgamation, SHA-256 pinned, downloaded by `build.sh`, unmodified; `unix-excl` VFS |
| Build | `-O3 -march=x86-64-v3 -mtune=cascadelake -mprefer-vector-width=256`, static |
| **Nginx or direct** | **Direct**: serves `HOST:PORT` itself (`0.0.0.0:80` on the box) |

The C is two headers: `src/uring.h` (the io_uring ABI) and `src/sql.h` (SQLite's B-tree calls, the checkpoint
thread). Parsing, auth, JSON, the read plans, the batches and the event loop are Nelua.

The design is the one at the top of the board, and much of it comes from there:
- #245 (c-iouring-pavlyhalim): idle connections on a multishot poll, closing by user data, the checkpoint thread
  at nice 19 with a write gate, the locked code, faulting memory in early.
- #257 (mojo-iouring-oh-meh): every ring deferring its task work, the batching.
- The B-tree read plans: the organizer's ruling on #153.

What this entry adds is below under **Memory**.

## Connections

- Accepted sockets are io_uring direct descriptors, held in a ring's table of slots instead of the process's
  descriptor table, so `LimitNOFILE=65535` caps one ring, not the server.
  - Rings are made as connections need them, up to 8 of 65,471 slots.
  - New connections go to one ring at a time. Before it is full, the ring with the most free slots takes over (or
    a new one is made), so churn doesn't use up rings.
- Eight `SO_REUSEPORT` listening sockets give eight accept queues. `TCP_DEFER_ACCEPT` hands a connection over
  once its first request is there, and the server reads it at once instead of waiting for a poll first.
- An idle connection waits on a multishot poll (POLLIN | POLLRDHUP) and holds no buffer. Its record is 24 bytes.
  - When the poll says readable, the connection goes on a read list.
  - The batch then reads every listed connection once (`MSG_DONTWAIT`, into the batch's input arena); the reads
    complete during the submit.
- Every ring defers its task work (`DEFER_TASKRUN`). The loop waits in the first ring; the others signal an eventfd
  the first ring polls, and the loop enters each ring once per pass.
- Closing removes the connection's poll by its user data, then closes the slot, linked. There is no
  `IORING_OP_SHUTDOWN`: the kernel can't run it inline and hands every one to an io-wq worker. Under many closes
  those queued up, still holding their sockets.

## Memory

On the 2 GB box the kernel's ~4 KB per socket is the wall, and every user holds a socket through its think time.

- **The valve.** When `MemAvailable` falls under 250 MB, a share of responses carries `Connection: close`:
  - The share grows as memory falls, up to 30% at 120 MB.
  - The client then reconnects for its next request instead of keeping a socket through 3–15 s of thinking.
  - The threshold comes from the board: mojo-iouring-oh-meh's guard saw `MemAvailable` under 160 MB at 320,000
    connections. Above 250 MB the valve does nothing.
  - It looks ahead while memory falls (connections arrive faster than closes take effect).
  - It is capped because every close is a reconnect. A larger share would trade the memory wall for a CPU wall,
    and requests queued in the kernel take memory again.
  - `VALVE=0` turns it off.
- **Who closes first.** After a `Connection: close` response the server waits for the client's FIN (at most 2 s)
  before closing, so the TIME_WAIT is the client's, not a socket on the 2 GB box.
- **Nothing to fault in at the wall.** Near the wall a page fault of this process is what the OOM killer answers;
  the kernel's socket memory is throttled instead. So everything is faulted in at startup and never given back:
  - the input arena (8,192 × 1 KB),
  - four 4 MB response arenas,
  - the bookkeeping lists,
  - each ring's table, when the ring is made.

  The binary's code is locked in RAM.
- **Small buffers.** A request that waits (pipelined, or held for the write gate) is kept in a buffer of its own
  size, not a fixed one. The SQLite page cache is 8 MB.

## A batch

Each pass of the loop is a batch:
1. The completions of every ring are handled.
2. The connections that turned readable are read.
3. Up to 2,048 requests are answered in one SQLite transaction (group commit), written into a response arena.
4. After `COMMIT` the responses go out, one send each.

If the commit fails, every response that touched the database becomes a 500. When busy, the loop waits for 64
completions or 2 ms.

## SQLite

- `GET /feed` and `GET /posts/:id` run on SQLite's B-tree cursors (`sqlite3BtreeFirst/Next/TableMoveto/IndexMoveto`)
  inside the batch's transaction, through SQLite's pager, WAL and page cache; only the bytecode engine is skipped.
  - The feed: the 20 newest ids off `posts_created_at_id_idx`, then one range scan of `likes_post_id_idx` for all
    20 counts, one range scan of `posts` for the rows, and each author by rowid.
  - The stored layout is checked against the schema at startup, and a plan that meets anything unexpected gives
    way to the reference SQL.
- Writes are prepared SQL:
  - `INSERT` + `last_insert_rowid` + `SELECT created_at` for a post;
  - `INSERT … SELECT … WHERE EXISTS … ON CONFLICT DO NOTHING` for a like.
- WAL, `synchronous=NORMAL`, `wal_autocheckpoint=0`, `mmap_size=0`. A checkpoint thread on its own connection
  runs PASSIVE checkpoints at nice 19. Past 4,000 frames, writes are held (reads go on) until the log is copied
  back, so the next write restarts it.

## HTTP, JSON, JWT

- Only the request line, `Authorization`, `Content-Length`, `Connection`, `Transfer-Encoding` and `Expect` are
  looked at.
- Request bodies and token parts are fully validated JSON.
- JSON output escapes what JSON requires, checking eight bytes at a time.
- HS256 is verified on every request: SHA-256 with the key's inner and outer states computed once from
  `JWT_SECRET`, the signature compared in constant time, `alg` HS256, `exp` required and in the future. Then `sub`
  must be a positive integer string and `username` a string.

## Rules

1–3. The SQLite file at `$SQLITE_PATH`, in-process, schema untouched. Reads use SQLite's own B-tree cursors through
its pager; writes use SQL.

4. `test/test.sh`: 42/42.

5. No caching across requests. Kept between batches: prepared statements, the table root pages and the HMAC key
schedule.

6. WAL + `synchronous=NORMAL`, group commit, and each response waits for its batch's commit.

7. Nothing detects the load test. The valve looks at the machine's memory only, never at the client, the route or
the request. It never refuses or delays a request and never sends an error; it only asks some clients to reconnect,
as any server may close a keep-alive connection.

8–9. Direct on `0.0.0.0:80`.

10. Built from source; Nelua and SQLite pinned.

11. Nothing on the box is tuned. The process raises its own soft `RLIMIT_NOFILE` to the hard limit and sets options
on its own sockets.

## Measured locally (not a score)

- Docker on an M-series Mac: the server in a container on one CPU and the load generator in another.
- They are connected by a veth pair, not Docker's bridge, so there is no conntrack, as on the box.
- The load generator is c-iouring-meros's replay of `bench/load.js`, over 48 source addresses.
- Full seed, 60 s ramp, 120 s hold.

| 300,000 users, 1,750 MB limit, one session | CPU per request | Memory at the hold's end | Errors |
|---|---:|---:|---:|
| this (a build before the valve's cap and the faulting-in) | 14.5 µs | 1,204 MB | 0 |
| c-iouring-pavlyhalim (#245) | 14.2 µs | 1,234 MB | 0 |
| mojo-iouring-oh-meh (#257) | 15.6 µs | 1,335 MB | 0 |

The submitted build, in a later session:
- At 300,000 users: 15.1 µs per request, 1,218 MB (20 MB more than before: its buffers are faulted in at
  startup), p99 6 ms, 0 errors.
- Under a 1,500 MB limit, the valve held 370,000 users on about 325,000 sockets: p99 10 ms, 0 errors. The eighth
  ring couldn't be made there (`ENOMEM`); new connections went to the ring with the most free slots instead.

These numbers don't show where the box's wall is:
- A container's memory limit lets the kernel charge socket memory past it (throttling instead of failing), so
  #245 held 400,000 users here and 295,000 on the box.
- One vCPU of a Mac in a VM isn't the box's Xeon, and the server's CPU here also pays for the client's receive
  path over the veth link.

## Layout

```
src/main.nelua    environment, start
src/server.nelua  rings, connections, batches, responses, the valve
src/db.nelua      SQLite: transactions, the read plans on B-tree cursors, writes
src/http.nelua    request parsing
src/json.nelua    JSON validation and decoding
src/jwt.nelua     SHA-256, HMAC, token checks
src/out.nelua     response writing, JSON escaping
src/c.nelua       the C functions it calls
src/uring.h       the io_uring ABI
src/sql.h         SQLite (the amalgamation, included), its B-tree calls, the checkpoint thread
```
