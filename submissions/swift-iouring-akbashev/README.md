# swift-iouring-akbashev

| | |
|---|---|
| Language | Swift 6.4.2 (official Ubuntu 24.04 tarball, sha256-checked), Swift 6 language mode |
| Framework | none: its own io_uring layer (raw system calls, no liburing), HTTP/1.1 server, JSON and JWT |
| SQLite | 3.54.1 amalgamation (sha256-checked), compiled into the server as a C target, its B-trees read directly |
| Dependencies | none besides SQLite: the standard library, Synchronization and Glibc; no Foundation, no Dispatch |
| Nginx or direct | **direct**: serves `HOST:PORT` itself (`0.0.0.0:80` on the box) |

## Design

- **io_uring without liburing.** `Sources/CIORing` is one C file and a header: `io_uring_setup`, `io_uring_enter` and
  `io_uring_register` through `syscall(2)`, the rings mapped with `mmap`, head and tail updated with the acquire
  and release orderings the ring protocol asks for. `IORing.swift` is the Swift type over it, shaped like
  swift-system's `IORing` (prepare requests, submit, consume completions) with the socket requests that one doesn't
  have yet: multishot accept into direct descriptors, multishot receive into provided buffers, send, shutdown and
  close. The ring is `SINGLE_ISSUER` and `DEFER_TASKRUN`: one thread submits, and completions are posted when it
  asks, in batches, without interrupts.
- **Connections live in the rings, not the descriptor table.** Each ring has a table of direct descriptors as large
  as the descriptor limit (65,535 on the box), so the limit caps one ring, not the server: when a ring's table is
  within 1,024 slots of full, its accept is cancelled and the next ring (added if needed, up to 16) takes over.
  Receives use provided buffers, so an idle connection holds no receive buffer.
- **One thread, proved by the compiler.** The box has one CPU, and the server is one thread: the target's default
  isolation is `MainActor`, so the server's state belongs to the main thread, and the compiler checks that. The value
  types that hold no shared state (bytes, JSON, HTTP, buffers, the store) are `nonisolated`, so their code carries
  no runtime checks. `main()`
  is synchronous and runs the loop: nothing is scheduled on any executor, there is no `async` on the request path,
  no locks and no atomics. Each pass submits what the last one prepared, waits on ring 0 for 64 completions or 1 ms
  (whichever comes first; with nothing happening, for anything), and takes every ring's completions.
- **The one effect that leaves it is an actor.** A checkpoint's `fsync` would stall the loop, so checkpoints are the
  `Checkpointer`'s: an actor on a thread of its own at nice 19 (on one CPU it runs while the loop waits), with its
  own SQLite connection. The loop starts one without waiting for it (a `Task` with the checkpointer's executor as its
  preference), and learns it finished from an eventfd its ring reads, a completion like any other. Crossing to it is
  the one place the compiler asks for `await` and `Sendable`. The process has two threads: the loop and the
  checkpointer.
- **Writes wait for a checkpoint; reads don't.** A PASSIVE checkpoint can't copy the frames written while it runs,
  and SQLite starts the WAL over only once every frame is copied, so under steady writes it never would: locally the
  WAL reached 767 MB in a minute, and the WAL index SQLite keeps in memory with it. So while a checkpoint runs, a
  write waits (its connection parses nothing further, so responses stay in order) and reads go on; when the
  checkpoint's completion arrives, the held writes run in that pass's transaction and the first of them starts the
  WAL over. A checkpoint that takes longer than 250 ms stops holding writes. (This is rust-iouring-kensac's write
  hold, applied to the whole checkpoint.)
- **Group commit per pass.** Every request of a pass runs inside one SQLite transaction (WAL,
  `synchronous=NORMAL`), and no response of the pass is sent before its `COMMIT` returns (rule 6). If it fails, the
  pass's connections close without an answer, so no response ever claims a write that didn't land.
- **SQLite.** Opened through the `unix-excl` VFS: the process holds the file's lock for its life and the WAL index
  lives in its memory, shared by its two connections (no `-shm` file). The statements are prepared once; 256 MB
  page cache, no mmap. Automatic checkpoints are off: past 1,024 WAL frames the loop starts a PASSIVE checkpoint
  on the checkpointer (`CHECKPOINT_THREAD=0` runs it in the loop instead). Rows are written as JSON straight from
  SQLite's memory.
- **Reads walk SQLite's B-trees.** The feed, a post, and a like's check that its post exists skip SQL: they move
  SQLite's own cursors inside the pass's transaction, as its query plan would, without the bytecode engine.
  `Sources/CSQLite/btree.c` compiles the amalgamation inside it and only moves cursors and hands back each entry's
  record. `Sources/BTree` is the Swift side: a `Cursor` whose moves are `mutating` and whose record is a `Span`
  borrowed from it, so the compiler rules out reading a row after its cursor moved on, and `Record`, which decodes
  SQLite's row format in place. The feed takes its 20 ids off `posts_created_at_id_idx`, counts their likes in one
  walk of `likes_post_id_idx`, then reads each post (a step back from the one before, as the ids go down) and its
  author, writing the JSON as it goes. The schema is checked at startup. A row these reads don't expect (a post
  without its user, a record that spills onto overflow pages) is answered by the SQL statements instead, and so is
  every read when the schema differs. Locally the answers matched SQL's byte for byte, on the seed and on databases
  edited to reach each fallback. (The approach is rust-iouring-kensac's.)
- **Requests parsed in place** in the kernel's receive buffers; a connection keeps bytes only when a request is
  split across receives. **Responses written in place:** the body goes straight into a send buffer taken from a
  pool, after room for the head, which is written once the body's length is known. The buffer is the connection's
  while its one send is in flight, and goes back to the pool, its capacity kept, when the send completes, so in
  steady state no response allocates. Error answers are static strings written the same way.
- **The JSON reader builds nothing.** Request bodies and token claims are checked whole and only the members the
  caller names are kept, as places in the bytes; strings are read in place and copied only when they must outlive
  the request (a new post's text, the token's username, which the response echoes).
- **Half-closed and pipelined requests.** A client that half-closes gets the answers to what it sent before the
  connection closes; pipelined requests are answered in order.
- **Shared with the author's million-users entry**: the HTTP parser, router, JSON, HS256 and buffers, written with
  `~Copyable` buffers and connections, `~Escapable` views with `@_lifetime`, `Span`/`RawSpan`/`OutputSpan` and
  `InlineArray`.

## Running

```bash
sudo ./install.sh   # Swift 6.4.2 -> /opt/swift
./build.sh          # fetches SQLite, -> .build/release/Feed
SQLITE_PATH=seed/feed.db JWT_SECRET=twelve-dollar-challenge HOST=0.0.0.0 PORT=80 ./start.sh
```

Optional, for testing: `RING_FILES` (connections per ring; default the descriptor limit), `MAX_RINGS` (16),
`PASS_BATCH` (64), `PASS_WINDOW_US` (1000) and `BTREE_READS` (1; 0 reads through SQL). io_uring must be allowed:
Docker's default seccomp profile blocks it.
