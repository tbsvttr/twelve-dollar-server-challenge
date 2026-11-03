# SQLite in this entry: what we tried, what we kept, and why

Notes for a curious reader, in the order things happened. Each number comes from a study logged in
[STUDIES.md](STUDIES.md) or [RESEARCH-TOP5.md](RESEARCH-TOP5.md). Those name the machine, the method and the commit.

## The rules we work inside

- Rule 2: the database is SQLite, the file at `$SQLITE_PATH`, used in-process.
- Rule 3: the schema and data are fixed. Any SQL against them is allowed.
- Rule 5: no caches. Every request reads SQLite while it is served. SQLite's own page cache and mmap are allowed, and so
  are prepared statements.
- Rule 6: a 201 means the row is committed. WAL with `synchronous=NORMAL` or stronger. Group commit is allowed if each
  response waits for its commit.
- The organizer's ruling on SQLite itself: **no source patches; compile options are allowed.**

Everything below stays inside these. `sqlite3.c` is the 3.54.0 amalgamation exactly as sqlite.org publishes it. The
build downloads it and checks it against the SHA3-256 sqlite.org publishes, and nothing edits it.

## 1. The first driver: the JVM and `java.lang.foreign`

The first entry was the JVM build (now `RUNTIME=graal-jit`). It calls a `libsqlite3.so` that `build.sh` compiles from
the amalgamation, through FFM downcalls, with no JDBC and no JNI.

- **Settings:** `journal_mode=WAL`, `synchronous=NORMAL`, `locking_mode=EXCLUSIVE` (one connection, so the wal-index
  lives in process memory and there is no `-shm` file), `mmap_size` 1 GiB, `cache_size` 16 MiB, `temp_store=MEMORY`.
  Every statement is prepared once with `SQLITE_PREPARE_PERSISTENT` and reused.
- **Compile options**, from sqlite.org's recommended list: `THREADSAFE=0` (one thread owns the connection), `DQS=0`,
  `DEFAULT_MEMSTATUS=0`, `DEFAULT_WAL_SYNCHRONOUS=1`, `LIKE_DOESNT_MATCH_BLOBS`, `MAX_EXPR_DEPTH=0`, `OMIT_DECLTYPE`,
  `OMIT_DEPRECATED`, `OMIT_PROGRESS_CALLBACK`, `OMIT_SHARED_CACHE`, and also `USE_ALLOCA` and `OMIT_LOAD_EXTENSION`.
- **The surprise that added `ENABLE_QPSG`:** SQLite 3.54.0 re-prepared the post-by-id statement every time a different
  id was bound. Under load, that re-prepare took 17% of the server's CPU. The query planner stability guarantee
  (`SQLITE_ENABLE_QPSG`), a compile option, stops it.

## 2. Group commit, and what it costs reads

The first write opens `BEGIN IMMEDIATE`. Later writes join it for up to 64 ms, then one `COMMIT`. Only then do the
responses held during that window leave, so a 201 always follows its commit.

On the JVM build at 64,000 users, the window traded latency for CPU: about 67-70 µs per request with one COMMIT per
loop pass, about 56-59 µs with the 64 ms window.

The cost: while the window is open, every response waits for its COMMIT, reads included. That is why p95 is about
65 ms in every row of [BENCHMARK.md](BENCHMARK.md). The leaders answer reads at once from a committed snapshot and hold
only the writes. That change is the largest open item here.

## 3. Kotlin/Native: SQLite linked in, and C only where Kotlin lost

The Kotlin/Native server links SQLite statically and calls it through cinterop (`feedc.def`). Profiles showed two
places where Kotlin/Native loses: byte loops, which it does not vectorize, and each crossing into C, about 13 ns. So:

- **`feed_json_text`** (7fbf26b) copies a text column and escapes it as JSON in one C pass, testing eight bytes per
  step. The feed went from 57 to 40 µs per request.
- **`feed_row_json`** (06182a8) makes a whole feed row one C call instead of about twelve crossings.

Both are tested in plain C against a byte-wise reference and against SQLite itself (`feedjson_test.c`).

## 4. Reads on SQLite's own B-tree cursors (`feedbt.c`)

All five leading entries skip SQLite's bytecode engine for the two read queries. They read the tables and indexes
through SQLite's own B-tree layer (`sqlite3BtreeTableMoveto`, `IndexMoveto`, `Next`), which still goes through
SQLite's pager, page cache and WAL. Those functions are private to the amalgamation, so each entry compiles its read
code in the same translation unit: it `#include`s the unmodified `sqlite3.c`. The #1 entry (PR #153) does this; it is
merged and scored, and the organizer wrote "this is epic, allowed" on it (2026-10-30).

Our version is `server/src/nativeInterop/feedbt.c` (098ccd1):

- `GET /feed` takes the first 20 entries of `posts_created_at_id_idx` (created_at DESC, id DESC), the same order as
  the SQL. When those ids lie close together, one range scan of `likes_post_id_idx` counts every like and one range
  scan of `posts` reads every row. Otherwise each id is looked up on its own. Authors come from `users` by rowid.
- `GET /posts/:id` seeks the row, its author and its like count the same way.
- **The SQL stays the definition of the answer.** If a row does not look as the schema says, the plan returns -1 and
  the server runs the SQL statement instead. `feedbt_test.c` holds both paths byte-equal.
- Result: the feed went from 40 to 23 µs per request.

Then one read transaction per wake (17613be, 4dc083f): the reads of one event-loop pass share one snapshot and release
it when the pass ends. The feed went to 21 µs and a single post to 10 µs. Rule 5 holds: each request still reads its
rows from SQLite while it is served. The snapshot is SQLite's, not a copy.

## 5. What we tried and did not keep

**SQLite's WAL writes on our io_uring ring.** The idea: hold each WAL write as an SQE on the server's own ring,
linked ahead of the 201's SEND, so one `io_uring_enter` writes the log and answers. We built it as a patched
amalgamation in a scratch copy and measured it (kali, CPU 1, 3,000 commits of 4 rows):

- It was correct: a stock `sqlite3` read the file back, `integrity_check` ok, 12,000 rows.
- System calls fell from 13,146 to 3,009, one per commit.
- **But system CPU rose:** about 0.05 s against 0.025 s on tmpfs, and 0.10 s against 0.055 s on ext4. The kernel handed
  the buffered file writes to io-wq worker threads, one context switch per write.

So it was slower, and a patched `sqlite3.c` breaks the organizer's ruling anyway. It is not in this tree. The lesson:
count CPU time, not system calls.

**A VFS shim that batches each commit's writes into one call** gave no wall-time gain (about 300 ms both ways). One
leader uses such a shim and saved about 0.15 `pwrite` per request. That is small, so we left it out.

## 6. Things we measured and kept

- **`locking_mode=EXCLUSIVE`** removed every POSIX lock call: 18,075 `fcntl` calls in that 3,000-commit run (6 per
  commit) went to 0. It is a pragma, legal and in-process.
- **Checkpoints block the loop.** On ext4, sampling the server thread put 62% of wall time inside `fsync`, from SQLite's
  automatic WAL checkpoint, which runs on the one event-loop thread. The leaders run PASSIVE checkpoints on a second
  connection on a nice-19 thread. We have not built that yet.
- **The cost is not in SQLite's file I/O.** One leader measured 0.23 system calls per request in total, 0.095 of them
  WAL writes. The CPU goes to packets and to page lookups in SQLite's cache. The io_uring ring pays on sockets, accepts,
  receives and sends, and that is where this server uses it.

## 7. SQLite on the other runtimes

| Runtime | SQLite | How it is reached |
|---|---|---|
| kn | 3.54.0, linked into `feed.kexe`, `feedbt.c` read plans | cinterop |
| graal-static, graal-jit | 3.54.0 `libsqlite3.so` from the same options | FFM downcalls; the native image makes its handles at image build time |
| node | Node 24's built-in `node:sqlite` | `DatabaseSync`, the same pragmas and statements |
| wasi | 3.54.0 compiled with wasi-sdk 34 into its own wasm module, `sqlite.wasm` | wasmtime links the server to it (`--preload sqlite=...`); a 27-line C bridge moves bytes between the two modules' memories |

Two WASI details. First, WASI has no shared memory, so `locking_mode=EXCLUSIVE` is set before the first WAL access
and keeps the wal-index on the heap. Second, wasmtime gives the listening socket descriptor 3, ahead of the data
directory, and wasi-libc's own scan stops at it, so no file could open. The bridge registers the directory with
wasi-libc's own `__wasilibc_register_preopened_fd`. SQLite's source is untouched on every runtime.

## 8. Still open

1. Reads must not wait for the commit window: answer them from the committed snapshot and hold only the writes.
2. WAL checkpoints off the event loop, on a second connection.
3. `wal_autocheckpoint` measured on the real server under load.
