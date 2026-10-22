## Raw C bindings to SQLite.
##
## This module is intentionally bindings-only: no higher-level logic, no SQL
## strings, no connection/statement management. Everything here maps directly
## onto the C API declared in sqlite3.h.
##
## Vendored, not system, SQLite
## ----------------------------
## The SQLite amalgamation is vendored (built from `vendor/sqlite3.c`) instead
## of linking the system `libsqlite3`. This removes the last external runtime
## dependency: the server can never fail to build or start because a machine is
## missing `libsqlite3`/`libsqlite3-dev`. `build.sh` downloads the PINNED amalgamation
##     https://www.sqlite.org/2026/sqlite-amalgamation-3540000.zip
##     sha256(zip) = 68e913b0fe8ec6b4e5f391c594a28872884e80d6cd042a1e50c957be46b5aa4d
## verifies that hash, and extracts sqlite3.c/sqlite3.h into `vendor/`.
##
## The single C translation unit is compiled straight into the binary via
## `{.compile.}` with size/speed trims below.
##
## THREADSAFE=2 (multi-thread mode), not 0:
##   The request loop and the WAL checkpointer each own ONE connection, used
##   only by their own OS thread. With THREADSAFE=0 SQLite omits the
##   global/connection serialisation that makes two connections on two threads
##   legal (and `sqlite3_threadsafe()` reports 0). Mode 2 keeps the
##   per-connection mutexes OUT of the hot path because both connections are
##   opened SQLITE_OPEN_NOMUTEX, while SQLite's internal WAL/index coordination
##   between connections is still compiled in. Each connection is still used by
##   exactly one thread at a time. openDb() verifies
##   `sqlite3_threadsafe() == 2` and refuses to start otherwise.

## Syntax note: Nim 2.2.12 accepts the `compile` pragma as `{.compile(file,
## options).}` where `options` is ONE space-separated string forwarded verbatim
## to gcc for that translation unit -- the colon-plus-varargs form
## (`{.compile: "f", "-O3", ... .}`) is rejected with "invalid pragma: -O3".
## Trim notes (added trims):
##   * SQLITE_USE_ALLOCA=1        - small temp allocations come off the stack
##                                  (alloca) instead of malloc; fewer heap calls
##                                  on the hot step/reset path.
##   * SQLITE_OMIT_DECLTYPE       - drops sqlite3_column_decltype() and the
##                                  decltype bookkeeping; this binding never
##                                  queries a column's declared type.
##   * SQLITE_LIKE_DOESNT_MATCH_BLOBS - the LIKE opcode never matches BLOB and
##                                  takes the fast path; no query here uses LIKE,
##                                  and none must ever match a blob.
##   * SQLITE_OMIT_AUTOINIT       - public API entry points skip the auto-init
##                                  wrapper. The process MUST therefore call
##                                  sqlite3_initialize() exactly once before any
##                                  SQLite API call; openDb() does this (and it is
##                                  the only SQLite entry point in the program).
##   * SQLITE_ENABLE_QPSG         - Query Planner Stability Guarantee: a
##                                  parameterized statement keeps a stable plan
##                                  across re-preparation, so the hot read path
##                                  never re-plans. (added)
## The original flags are all preserved verbatim.
{.compile("../vendor/sqlite3.c",
  "-O3 -DSQLITE_THREADSAFE=2 -DSQLITE_DEFAULT_MEMSTATUS=0 -DSQLITE_OMIT_DEPRECATED -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_OMIT_PROGRESS_CALLBACK -DSQLITE_OMIT_SHARED_CACHE -DSQLITE_DQS=0 -DSQLITE_MAX_EXPR_DEPTH=0 -DSQLITE_TEMP_STORE=3 -DSQLITE_ENABLE_JSON1 -DSQLITE_ENABLE_QPSG -DSQLITE_USE_ALLOCA=1 -DSQLITE_OMIT_DECLTYPE -DSQLITE_LIKE_DOESNT_MATCH_BLOBS -DSQLITE_OMIT_AUTOINIT -DHAVE_FDATASYNC=1").}

type
  Sqlite3* {.incompleteStruct.} = object
    ## opaque `sqlite3`
  Sqlite3Stmt* {.incompleteStruct.} = object
    ## opaque `sqlite3_stmt`

  Sqlite3Destructor* = proc (p: pointer) {.cdecl.}
    ## `sqlite3_destructor_type`

  Sqlite3ExecCallback* = proc (a: pointer, n: cint, vals: ptr cstring,
                               names: ptr cstring): cint {.cdecl.}

  Sqlite3WalHook* = proc (a: pointer, db: ptr Sqlite3, zDb: cstring,
                          nFrame: cint): cint {.cdecl.}
    ## `sqlite3_wal_hook` callback: called after each commit that appends to the
    ## WAL, with the WAL's new total frame count. Must not call back into
    ## SQLite or allocate.

const
  SQLITE_OK* = 0
  SQLITE_BUSY* = 5
  SQLITE_ROW* = 100
  SQLITE_DONE* = 101
  ## `sqlite3_wal_checkpoint_v2` modes. The checkpointer uses only PASSIVE:
  ## it copies as many frames as it can without waiting for readers, so it can
  ## never stall the request thread. FULL/RESTART wait for readers.
  SQLITE_CHECKPOINT_PASSIVE* = 0
  SQLITE_CHECKPOINT_FULL* = 1
  SQLITE_CHECKPOINT_RESTART* = 2
  SQLITE_CHECKPOINT_TRUNCATE* = 3
  SQLITE_OPEN_READWRITE* = 2
  SQLITE_OPEN_CREATE* = 4
  SQLITE_OPEN_NOMUTEX* = 0x8000
  SQLITE_PREPARE_PERSISTENT* = cuint(1)

  ## `SQLITE_TRANSIENT` tells sqlite to make its own copy of bound text.
  SQLITE_TRANSIENT* = cast[Sqlite3Destructor](-1)

## Required exactly once before any other SQLite call when the amalgamation is
## built with SQLITE_OMIT_AUTOINIT (see the compile flags above). openDb() calls
## this before it touches the database. Calling it more than once is safe.
proc sqlite3_initialize*(): cint
  {.importc, header: "vendor/sqlite3.h".}

## Compile-time threading mode: 0=single-thread, 2=multi-thread. openDb()
## requires 2 because the checkpointer owns a second connection on its own
## thread (see the THREADSAFE note at the top of this module).
proc sqlite3_threadsafe*(): cint
  {.importc, header: "vendor/sqlite3.h".}

proc sqlite3_open_v2*(filename: cstring, ppDb: ptr ptr Sqlite3, flags: cint,
                      zVfs: cstring): cint
  {.importc, header: "vendor/sqlite3.h".}

proc sqlite3_prepare_v3*(db: ptr Sqlite3, zSql: cstring, nByte: cint,
                         prepFlags: cuint, ppStmt: ptr ptr Sqlite3Stmt,
                         pzTail: ptr cstring): cint
  {.importc, header: "vendor/sqlite3.h".}

proc sqlite3_bind_int64*(stmt: ptr Sqlite3Stmt, idx: cint, value: int64): cint
  {.importc, header: "vendor/sqlite3.h".}

proc sqlite3_bind_text*(stmt: ptr Sqlite3Stmt, idx: cint, text: cstring,
                        n: cint, destructor: Sqlite3Destructor): cint
  {.importc, header: "vendor/sqlite3.h".}

proc sqlite3_step*(stmt: ptr Sqlite3Stmt): cint
  {.importc, header: "vendor/sqlite3.h".}

proc sqlite3_column_text*(stmt: ptr Sqlite3Stmt, iCol: cint): cstring
  {.importc, header: "vendor/sqlite3.h".}

proc sqlite3_column_bytes*(stmt: ptr Sqlite3Stmt, iCol: cint): cint
  {.importc, header: "vendor/sqlite3.h".}

proc sqlite3_column_int64*(stmt: ptr Sqlite3Stmt, iCol: cint): int64
  {.importc, header: "vendor/sqlite3.h".}

proc sqlite3_reset*(stmt: ptr Sqlite3Stmt): cint
  {.importc, header: "vendor/sqlite3.h".}

## Change the checkpoint connection's busy timeout. The worker uses this to
## bound how long a PASSIVE attempt waits on a lock; the request connection's
## timeout is configured by its PRAGMAs.
proc sqlite3_busy_timeout*(db: ptr Sqlite3, ms: cint): cint
  {.importc, header: "vendor/sqlite3.h".}

proc sqlite3_changes*(db: ptr Sqlite3): cint
  {.importc, header: "vendor/sqlite3.h".}

proc sqlite3_last_insert_rowid*(db: ptr Sqlite3): int64
  {.importc, header: "vendor/sqlite3.h".}

proc sqlite3_finalize*(stmt: ptr Sqlite3Stmt): cint
  {.importc, header: "vendor/sqlite3.h".}

proc sqlite3_close_v2*(db: ptr Sqlite3): cint
  {.importc, header: "vendor/sqlite3.h".}

proc sqlite3_errmsg*(db: ptr Sqlite3): cstring
  {.importc, header: "vendor/sqlite3.h".}

proc sqlite3_errcode*(db: ptr Sqlite3): cint
  {.importc, header: "vendor/sqlite3.h".}

proc sqlite3_exec*(db: ptr Sqlite3, sql: cstring,
                   callback: Sqlite3ExecCallback, arg: pointer,
                   errmsg: ptr cstring): cint
  {.importc, header: "vendor/sqlite3.h".}

## Install (or, with `cb == nil`, uninstall) the WAL hook. The callback runs on
## the thread that commits and must not do SQLite work or allocate.
proc sqlite3_wal_hook*(db: ptr Sqlite3, cb: Sqlite3WalHook, data: pointer): pointer
  {.importc, header: "vendor/sqlite3.h".}

## Run a checkpoint on the connection's own database. `zDb == nil` selects the
## main database. PASSIVE never waits for readers or blocks the writer; it is
## run only by the dedicated checkpoint thread.
proc sqlite3_wal_checkpoint_v2*(db: ptr Sqlite3, zDb: cstring, eMode: cint,
                                pnLog: ptr cint, pnCkpt: ptr cint): cint
  {.importc, header: "vendor/sqlite3.h".}
