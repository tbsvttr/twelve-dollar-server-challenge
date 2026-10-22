## Off-loop WAL checkpointer, implemented entirely in Nim.
##
## The worker is a raw POSIX thread (`std/posix.pthread_create`), not a Nim
## `createThread`/`spawn` thread: the server stays `--threads:off`, so the Nim
## runtime remains single-threaded.  Consequently the worker is a *foreign
## thread* and may never enter the Nim runtime: it must not allocate, touch a
## `string`/`seq`/`ref`, raise, or execute a checked operation (the checks
## themselves call `raise`).  The whole worker-side region is fenced below with
## `checks: off`, `assertions: off`, `stackTrace: off` and `raises: []`, and is
## restricted to raw ptr/int64, stack `char` arrays, C11 atomics via
## `std/atomics`, libc/POSIX FFI and the SQLite C API.  The worker and the WAL
## hook contain no exception/alloc/check helper calls.
##
## Threading model (also documented in db.nim):
##   * request connection: created by openDb(), used only by the event loop;
##   * checkpoint connection: created inside ckStart(), used only by the
##     worker pthread.
## The request loop never calls into the checkpoint connection.  The only
## coupling is SQLite's own database/WAL state plus an atomic `wanted` flag and
## an eventfd wakeup; `wal_hook` on the request connection performs no SQLite
## call - it raises the flag and writes the eventfd.
##
## A PASSIVE checkpoint copies committed WAL frames into the database and (with
## synchronous=NORMAL) performs the fsync that would otherwise run on the
## request thread.  It runs on the worker, so the request loop keeps draining
## io_uring completions while the copy/fsync is in flight.  RESTART/FULL are
## deliberately absent: both wait for readers and block the writer.

import std/[posix, atomics]

import ./sqlite3

{.passC: "-pthread".}
{.passL: "-pthread".}

const
  CkDefaultIntervalMs = 1000
  CkBusyTimeoutMs = 5000

  ## SQLITE_CHECKPOINT_PASSIVE is 0; FULL is 1. FULL/RESTART wait for readers
  ## and can stall the writer, so only PASSIVE is used while serving.
  SqliteCheckpointPassive = 0
  SqliteBusy = 5

  ## `EFD_CLOEXEC` from <sys/eventfd.h>.  Kept local so the binding does not
  ## depend on a platform constant Nim's posix module may not re-export.
  EfdCloexec = cint(0x80000)

type
  ## Snapshot of the worker's counters.  Filled from atomics while the worker
  ## runs, or by ckStop after the final checkpoint (never read from a freed
  ## context).  A plain Nim value object: db.nim aliases it and copies it by
  ## plain Nim object; no C layout is involved.
  CkStats* = object
    count*: clonglong         ## PASSIVE checkpoints attempted
    totalUs*: clonglong
    maxUs*: clonglong
    lastPnLog*: clonglong     ## pnLog of the most recent checkpoint
    lastPnCkpt*: clonglong    ## pnCkpt of the most recent checkpoint
    busy*: clonglong          ## rc == SQLITE_BUSY only
    errors*: clonglong        ## other non-OK rc, or pnLog < 0
    pollFailures*: clonglong  ## worker poll() failed (checkpointing stopped)
    failed*: cint             ## 1 once the worker stopped on an error

  ## One context owns ONE SQLite connection (opened READWRITE|NOMUTEX) and the
  ## pthread that is the only thread allowed to touch it.  Allocated with
  ## `calloc` and freed with `free`, never by ARC: it crosses the thread
  ## boundary as a bare pointer.
  CkCtx = object
    db: ptr Sqlite3
    efd: cint
    thread: Pthread
    intervalMs: cint
    wanted: Atomic[int32]     ## set by the request thread, consumed by worker
    stop: Atomic[int32]
    started: cint             ## pthread_create succeeded (written before start)
    count: Atomic[int64]
    totalUs: Atomic[int64]
    maxUs: Atomic[int64]
    lastPnLog: Atomic[int64]
    lastPnCkpt: Atomic[int64]
    busyCount: Atomic[int64]  ## rc == SQLITE_BUSY only
    errCount: Atomic[int64]   ## any other non-OK rc, or pnLog < 0
    pollFailures: Atomic[int64]
    failed: Atomic[int32]     ## worker stopped on a poll() error

# --- libc / POSIX / SQLite bindings not already in src/sqlite3.nim ---------

proc c_calloc(n, size: csize_t): pointer
  {.importc: "calloc", header: "<stdlib.h>".}
proc c_free(p: pointer)
  {.importc: "free", header: "<stdlib.h>".}
proc c_eventfd(initval: cuint, flags: cint): cint
  {.importc: "eventfd", header: "<sys/eventfd.h>".}
proc c_snprintf(buf: cstring, n: csize_t, fmt: cstring): cint
  {.importc: "snprintf", header: "<stdio.h>", varargs.}

# ===========================================================================
# NO MANAGED TYPES BELOW THIS LINE
#
# Everything from here to the matching {.pop.} runs on the raw pthread, or on
# the request thread inside the SQLite WAL hook.  Neither may enter the Nim
# runtime: only ptr/int/int64, stack char arrays, C11 atomics, libc/POSIX and
# the SQLite C API are allowed.  Forbidden: new/alloc/realloc/dealloc,
# newString/newSeq/string/seq/ref, `$`, echo, raise/try/except, assert/doAssert,
# checked indexing and any std/threads machinery.  The push disables the
# generated checks (which would otherwise call raiseRangeError etc.) and makes
# every call effect-checked as non-raising.
# ===========================================================================
{.push checks: off, assertions: off, stackTrace: off, raises: [].}

proc ckNowUs(): int64 =
  var ts {.noinit.}: Timespec
  discard clock_gettime(CLOCK_MONOTONIC, ts)
  int64(ts.tv_sec) * 1_000_000'i64 + int64(ts.tv_nsec) div 1000'i64

proc ckLog(buf: cstring, len: cint) =
  ## Plain write(2): no stdio buffering, no allocation.
  var r: int
  while true:
    r = posix.write(STDERR_FILENO, cast[pointer](buf), int(len))
    if r >= 0 or errno != EINTR:
      break

proc ckSignal*(c: pointer): cint =
  ## Mark a checkpoint as wanted and wake the worker.  Cheap and idempotent:
  ## the eventfd is written only when the flag transitions 0 -> 1.  Safe from
  ## the request thread, including inside the SQLite WAL hook.
  if c == nil:
    return -1
  let ctx = cast[ptr CkCtx](c)
  if ctx.wanted.load(moRelaxed) != 0:
    return 0
  ctx.wanted.store(1'i32, moRelaxed)
  var one: uint64 = 1
  var r: int
  while true:
    r = posix.write(ctx.efd, addr one, sizeof(one))
    if r >= 0 or errno != EINTR:
      break
  if r == sizeof(one): 0 else: -1

proc ckRunOnce(c: ptr CkCtx) =
  ## One PASSIVE checkpoint on the checkpoint connection.
  var pnLog: cint = -1
  var pnCkpt: cint = -1
  let t0 = ckNowUs()
  let rc = sqlite3_wal_checkpoint_v2(c.db, nil, SqliteCheckpointPassive,
                                     addr pnLog, addr pnCkpt)
  let dur = ckNowUs() - t0

  discard c.count.fetchAdd(1'i64, moRelaxed)
  discard c.totalUs.fetchAdd(dur, moRelaxed)
  c.lastPnLog.store(int64(pnLog), moRelaxed)
  c.lastPnCkpt.store(int64(pnCkpt), moRelaxed)
  var prev = c.maxUs.load(moRelaxed)
  while dur > prev and
      not c.maxUs.compareExchangeWeak(prev, dur, moRelaxed, moRelaxed):
    discard

  # Only SQLITE_BUSY is a "busy" checkpoint: a reader is pinning the WAL,
  # which is normal and retried.  Any other failure (IOERR, READONLY, LOCKED,
  # or a checkpoint that reports pnLog < 0) is an error and is counted and
  # logged, not folded into busy.
  if rc == SqliteBusy:
    discard c.busyCount.fetchAdd(1'i64, moRelaxed)
  elif rc != SQLITE_OK or pnLog < 0:
    discard c.errCount.fetchAdd(1'i64, moRelaxed)
    var err {.noinit.}: array[192, char]
    let en = c_snprintf(cast[cstring](addr err), csize_t(err.len),
                        cstring("db-ckpt: ERROR rc=%d pnLog=%d pnCkpt=%d errmsg=%s\n"),
                        cint(rc), cint(pnLog), cint(pnCkpt),
                        sqlite3_errmsg(c.db))
    if en > 0:
      ckLog(cast[cstring](addr err), if en < cint(err.len): cint(en) else: cint(err.len))

  # One line per checkpoint (~1/s), written with snprintf into a stack buffer.
  var line {.noinit.}: array[192, char]
  let n = c_snprintf(cast[cstring](addr line), csize_t(line.len),
                     cstring("db-ckpt: n=%lld dur_us=%lld pnLog=%d pnCkpt=%d rc=%d busy_total=%lld\n"),
                     clonglong(c.count.load(moRelaxed)), clonglong(dur),
                     cint(pnLog), cint(pnCkpt), cint(rc),
                     clonglong(c.busyCount.load(moRelaxed)))
  if n > 0:
    ckLog(cast[cstring](addr line), if n < cint(line.len): cint(n) else: cint(line.len))

proc ckWalHook(arg: pointer, db: ptr Sqlite3, zdb: cstring,
               nframe: cint): cint {.cdecl.} =
  ## Runs on the request thread right after a commit releases the write lock.
  ## It must not call SQLite, so it only raises the flag and wakes the worker.
  discard ckSignal(arg)
  SQLITE_OK

proc ckWorker(arg: pointer): pointer {.noconv, gcsafe.} =
  let c = cast[ptr CkCtx](arg)
  var pfd {.noinit.}: TPollfd
  pfd.fd = c.efd
  pfd.events = POLLIN
  pfd.revents = 0

  var lastRunUs: int64 = 0 # 0: never run -> first wanted checkpoint runs

  while c.stop.load(moRelaxed) == 0:
    var timeout: cint = c.intervalMs
    if lastRunUs != 0 and c.wanted.load(moRelaxed) != 0:
      let elapsedMs = (ckNowUs() - lastRunUs) div 1000
      let left = int64(c.intervalMs) - elapsedMs
      timeout = cint(if left < 0: 0'i64 else: left)

    let pr = poll(addr pfd, Tnfds(1), timeout)
    if pr < 0:
      if errno == EINTR:
        continue
      # A failed poll means the worker can never checkpoint again.  Record a
      # failed state and leave a trace instead of exiting silently.
      let e = errno
      discard c.pollFailures.fetchAdd(1'i64, moRelaxed)
      c.failed.store(1'i32, moRelaxed)
      var err {.noinit.}: array[160, char]
      let en = c_snprintf(cast[cstring](addr err), csize_t(err.len),
                          cstring("db-ckpt: ERROR poll failed errno=%d; worker stopping\n"),
                          cint(e))
      if en > 0:
        ckLog(cast[cstring](addr err), if en < cint(err.len): cint(en) else: cint(err.len))
      break
    if pr > 0 and (pfd.revents and POLLIN) != 0:
      var v: uint64
      var r: int
      while true:
        r = posix.read(c.efd, addr v, sizeof(v))
        if r >= 0 or errno != EINTR:
          break

    if c.stop.load(moRelaxed) != 0:
      break
    if c.wanted.load(moRelaxed) == 0:
      continue

    # Coalesce: at most one PASSIVE per interval.  A signal that arrived
    # during the previous checkpoint keeps `wanted` set, so the loop sleeps out
    # the remainder of the interval instead of checkpointing again immediately.
    if lastRunUs != 0 and
        (ckNowUs() - lastRunUs) div 1000 < int64(c.intervalMs):
      continue

    if c.wanted.exchange(0'i32, moRelaxed) == 0:
      continue
    ckRunOnce(c)
    lastRunUs = ckNowUs()

  # Shutdown: run a checkpoint that was still wanted so a stop cannot silently
  # drop the last committed frames.
  if c.wanted.exchange(0'i32, moRelaxed) != 0:
    ckRunOnce(c)

  var line {.noinit.}: array[192, char]
  let n = c_snprintf(cast[cstring](addr line), csize_t(line.len),
                     cstring("db-ckpt: summary count=%lld total_us=%lld max_us=%lld busy=%lld errors=%lld poll_failures=%lld failed=%d\n"),
                     clonglong(c.count.load(moRelaxed)),
                     clonglong(c.totalUs.load(moRelaxed)),
                     clonglong(c.maxUs.load(moRelaxed)),
                     clonglong(c.busyCount.load(moRelaxed)),
                     clonglong(c.errCount.load(moRelaxed)),
                     clonglong(c.pollFailures.load(moRelaxed)),
                     cint(c.failed.load(moRelaxed)))
  if n > 0:
    ckLog(cast[cstring](addr line), if n < cint(line.len): cint(n) else: cint(line.len))
  nil

{.pop.}

# --- public API (request thread; same pointer signatures as before) ---------

proc ckStart*(path: cstring, intervalMs: cint): pointer {.raises: [].} =
  ## Open the checkpoint connection, prime it (a one-row schema read, so the
  ## connection actually enters WAL mode), create the eventfd and start the
  ## worker thread.  Returns NULL on any failure.  intervalMs is the minimum
  ## spacing between PASSIVE checkpoints (coalesces signalling bursts).
  let c = cast[ptr CkCtx](c_calloc(1, csize_t(sizeof(CkCtx))))
  if c == nil:
    return nil
  c.intervalMs = if intervalMs > 0: intervalMs else: CkDefaultIntervalMs
  c.wanted.store(0'i32, moRelaxed)
  c.stop.store(0'i32, moRelaxed)
  c.count.store(0'i64, moRelaxed)
  c.totalUs.store(0'i64, moRelaxed)
  c.maxUs.store(0'i64, moRelaxed)
  c.lastPnLog.store(-1'i64, moRelaxed)
  c.lastPnCkpt.store(-1'i64, moRelaxed)
  c.busyCount.store(0'i64, moRelaxed)
  c.errCount.store(0'i64, moRelaxed)
  c.pollFailures.store(0'i64, moRelaxed)
  c.failed.store(0'i32, moRelaxed)

  c.efd = c_eventfd(0, EfdCloexec)
  if c.efd < 0:
    c_free(c)
    return nil

  let rc = sqlite3_open_v2(path, addr c.db,
                           SQLITE_OPEN_READWRITE or SQLITE_OPEN_NOMUTEX, nil)
  if rc != SQLITE_OK:
    if c.db != nil:
      discard sqlite3_close_v2(c.db)
    discard posix.close(c.efd)
    c_free(c)
    return nil

  # This connection is touched by the worker thread only; NOMUTEX is correct
  # because no other thread ever calls into it.
  discard sqlite3_busy_timeout(c.db, CkBusyTimeoutMs)
  # PASSIVE truncates/limits the WAL only when this connection performs the
  # checkpoint, so the WAL bound is set here as well as on the request
  # connection.  It is a connection setting, not a write.
  discard sqlite3_exec(c.db, cstring("PRAGMA journal_size_limit=67108864;"),
                       nil, nil, nil)

  # Prime the connection.  A freshly opened connection that has never read the
  # database does not enter WAL mode lazily, and wal_checkpoint_v2 on it then
  # reports pnLog=-1 and copies nothing (verified with a two-connection probe).
  # One schema read makes the connection attach to the WAL, and it is the only
  # statement this connection ever runs besides the checkpoints.
  if sqlite3_exec(c.db, cstring("SELECT count(*) FROM sqlite_master;"),
                  nil, nil, nil) != SQLITE_OK:
    discard sqlite3_close_v2(c.db)
    discard posix.close(c.efd)
    c_free(c)
    return nil

  if pthread_create(addr c.thread, nil, ckWorker, c) != 0:
    discard sqlite3_close_v2(c.db)
    discard posix.close(c.efd)
    c_free(c)
    return nil
  c.started = 1
  cast[pointer](c)

proc ckInstallHook*(mainDb: pointer, c: pointer) {.raises: [].} =
  ## Install the WAL hook on the REQUEST connection.  The hook only calls
  ## ckSignal(); it performs no SQLite call.
  if mainDb == nil or c == nil:
    return
  discard sqlite3_wal_hook(cast[ptr Sqlite3](mainDb), ckWalHook, c)

proc ckUninstallHook*(mainDb: pointer) {.raises: [].} =
  ## Uninstall the WAL hook from the REQUEST connection.  MUST be called before
  ## ckStop frees the context: otherwise the connection's pWalArg still points
  ## at freed memory and a later COMMIT calls ckSignal() on it (UAF).
  if mainDb == nil:
    return
  discard sqlite3_wal_hook(cast[ptr Sqlite3](mainDb), nil, nil)

proc ckStats*(c: pointer, outStats: ptr CkStats) {.raises: [].} =
  ## Copy the worker's current counters.  Safe while the worker runs (atomics);
  ## `outStats` must be non-NULL.
  if outStats == nil:
    return
  if c == nil:
    outStats.count = 0
    outStats.totalUs = 0
    outStats.maxUs = 0
    outStats.lastPnLog = 0
    outStats.lastPnCkpt = 0
    outStats.busy = 0
    outStats.errors = 0
    outStats.pollFailures = 0
    outStats.failed = 0
    return
  let ctx = cast[ptr CkCtx](c)
  outStats.count = ctx.count.load(moRelaxed)
  outStats.totalUs = ctx.totalUs.load(moRelaxed)
  outStats.maxUs = ctx.maxUs.load(moRelaxed)
  outStats.lastPnLog = ctx.lastPnLog.load(moRelaxed)
  outStats.lastPnCkpt = ctx.lastPnCkpt.load(moRelaxed)
  outStats.busy = ctx.busyCount.load(moRelaxed)
  outStats.errors = ctx.errCount.load(moRelaxed)
  outStats.pollFailures = ctx.pollFailures.load(moRelaxed)
  outStats.failed = ctx.failed.load(moRelaxed)

proc ckStop*(c: pointer, outStats: ptr CkStats) {.raises: [].} =
  ## Run any still-wanted checkpoint, stop and join the worker, copy the FINAL
  ## counters into `outStats` (may be NULL), then close and free the context.
  ## Called at shutdown/tests.  The caller owns the context and must call this
  ## at most once per successful ckStart(); on the Nim side db.ckCtx is cleared
  ## before the call so a second stop is a no-op.
  if c == nil:
    return
  let ctx = cast[ptr CkCtx](c)
  ctx.stop.store(1'i32, moRelaxed)
  # Wake a worker parked in poll(); the eventfd is also what makes the join
  # bounded even when no checkpoint was wanted.
  var one: uint64 = 1
  var r: int
  while true:
    r = posix.write(ctx.efd, addr one, sizeof(one))
    if r >= 0 or errno != EINTR:
      break
  if ctx.started != 0:
    discard pthread_join(ctx.thread, nil)
  # Final counters, read after the shutdown checkpoint and BEFORE the context
  # is freed.  Reading them afterwards would be use-after-free.
  ckStats(c, outStats)
  discard sqlite3_close_v2(ctx.db)
  discard posix.close(ctx.efd)
  c_free(ctx)
