## server.nim: the io_uring HTTP transport (the only one).
##
## Reuses the frozen `api.nim`/`db.nim`/`config.nim` modules unchanged, the raw
## io_uring bindings in `iouring.nim`, and the shared HTTP parser/framing in
## `http.nim`. The socket scaffold - the fd-limit bump, the listening-socket
## setup and the `processRequests` loop - lives in this same module.
##
## Why io_uring here
## -----------------
## The one thing this transport does that a readiness API cannot is *registered
## (fixed) file descriptors*. Accepted connections live in the ring's
## fixed-file table and every subsequent RECV/SEND addresses them by slot index
## with `IOSQE_FIXED_FILE`. The fixed table holds its own reference, so a
## connection no longer consumes a process `RLIMIT_NOFILE` slot. The registered
## table is what the famous 300k-connection C entry rides.
##
## Two io_uring best-practices are layered on top of the basic transport:
##
##  1. **Ring setup flags** (`IORING_SETUP_SINGLE_ISSUER | DEFER_TASKRUN`, plus
##     `COOP_TASKRUN`): the recommended set for a single-threaded, per-thread
##     ring.  Less cross-CPU locking, and completion (task) work is deferred to
##     `io_uring_enter`, which the N=1 loop already calls every pass.  The
##     multi-ring loop instead waits on a shared eventfd and cannot use
##     `DEFER_TASKRUN`: deferred task work is only run by `io_uring_enter`, and
##     the eventfd that should wake that loop is signalled from the completion
##     commit, which is exactly the work being deferred.  N>1 therefore asks
##     for `SINGLE_ISSUER | COOP_TASKRUN` only (see runMultiLoop).  If the
##     kernel rejects a flag set with `-EINVAL` the ring is re-created without
##     the optimisation flags and startup proceeds; the mode is logged.
##
##  2. **Direct multishot accept** (`IORING_ACCEPT_MULTISHOT` with the SQE's
##     `file_index = IORING_FILE_INDEX_ALLOC`): the kernel installs each accepted
##     socket straight into the first free fixed-file slot, so no
##     `IORING_REGISTER_FILES_UPDATE` and no per-accept fd allocation are needed.
##     The accept CQE's `res` is the slot index.  If the kernel rejects the
##     direct variant (`-EINVAL`/`-EOPNOTSUPP`), we transparently fall back to
##     the register-per-accept path.  Closing a connection drops its fixed-file
##     entry with `FILES_UPDATE(-1)` only after every in-flight op on the slot
##     has completed, so the next direct accept can safely reuse it.
##
## Fidelity
## --------
## The HTTP/1.1 parser, response framing, keep-alive, pipelining,
## `Content-Length` handling and malformed-framing policy live in the shared
## `http.nim`, so the emitted bytes are pinned by construction. The socket is
## single-threaded; the event source is the io_uring completion queue.

import std/[posix, os, strutils, times, oserrors]
import posix/epoll

import iouring, config, db, api, http

# ---------------------------------------------------------------------------
# transport-agnostic socket scaffold: the per-process fd-limit bump, the
# listening-socket setup, the optional per-connection TCP tuning, and the HTTP
# request/response loop. Nothing here touches the ring or a connection struct;
# the io_uring loop adapts its own `Conn` to these routines.

# syscall surface std/posix does not expose (or that we want verbatim)
var SOCK_NONBLOCK {.importc, header: "<sys/socket.h>".}: cint
# SO_REUSEPORT lets every ring bind its own listener to the same host:port; the
# kernel then hashes each new connection to one of them (multi-ring accept).
var SO_REUSEPORT {.importc, header: "<sys/socket.h>".}: cint
# TCP_DEFER_ACCEPT (value in seconds) is in <netinet/tcp.h>.
var TCP_DEFER_ACCEPT {.importc, header: "<netinet/tcp.h>".}: cint
# TCP_NODELAY set on the listener is inherited by accepted sockets on Linux, so
# the send path needs no per-connection setsockopt (which would also defeat the
# direct-accept path; see the gate in main).
var TCP_NODELAY {.importc, header: "<netinet/tcp.h>".}: cint
# Per-connection TCP options (applied to an accepted socket; see applyTcpTuning).
var TCP_QUICKACK {.importc, header: "<netinet/tcp.h>".}: cint
var TCP_NOTSENT_LOWAT {.importc, header: "<netinet/tcp.h>".}: cint

proc envIntDef(name: string, dflt: int): int =
  try:
    parseInt(getEnv(name, $dflt))
  except ValueError:
    dflt

proc tcpNotsentLowatBytes*(): int =
  ## TCP_NOTSENT_LOWAT value in bytes; 0 disables it (the default).
  result = envIntDef("TCP_NOTSENT_LOWAT_BYTES", 0)
  if result < 0: result = 0

proc tcpQuickAck*(): bool =
  ## Whether to set TCP_QUICKACK on accepted sockets (default off).
  getEnv("TCP_QUICKACK", "0") == "1"

proc applyTcpTuning*(fd: cint) =
  ## Optional, env-gated per-connection TCP tuning (both default OFF, so the
  ## default build is unchanged):
  ##   * TCP_NOTSENT_LOWAT_BYTES > 0 caps the unsent write queue (lower kernel
  ##     memory per socket and a shorter socket-lock hold under backlog);
  ##   * TCP_QUICKACK=1 disables delayed ACKs (lower latency, more ACK traffic).
  let lowat = tcpNotsentLowatBytes()
  if lowat > 0:
    var v: cint = cint(lowat)
    discard posix.setsockopt(SocketHandle(fd), posix.IPPROTO_TCP,
                             TCP_NOTSENT_LOWAT, addr v, SockLen(sizeof(v)))
  if tcpQuickAck():
    var one: cint = 1
    discard posix.setsockopt(SocketHandle(fd), posix.IPPROTO_TCP,
                             TCP_QUICKACK, addr one, SockLen(sizeof(one)))

# Fixed-file table bound and fd headroom. Declared ahead of `raiseNofile`
# because that probe reports the unlimited hard limit as the table cap plus this
# reserve, and Nim resolves module-level constants in source order.
const
  CAP        = 65536
  FdsReserve = 64

proc raiseNofile*(): int =
  ## Raise this process's soft RLIMIT_NOFILE up to its hard limit and return the
  ## *hard* limit (`rlim_max`) as an `int`. Per-process only (no kernel/sysctl
  ## change), and a no-op when the soft limit already equals the hard limit, which
  ## is the case when started under `ulimit -n N` / `prlimit --nofile=N:N`.
  ##
  ## The return value is the process's real fd ceiling: the caller sizes the
  ## registered fixed-file table from it (the table needs roughly one entry per
  ## connection plus headroom).
  var rl: RLimit
  discard getrlimit(RLIMIT_NOFILE, rl)
  let soft0 = rl.rlim_cur
  let hard = rl.rlim_max
  if soft0 < hard:
    var want: RLimit
    want.rlim_cur = hard
    want.rlim_max = hard
    if setrlimit(RLIMIT_NOFILE, want) == 0:
      var after: RLimit
      discard getrlimit(RLIMIT_NOFILE, after)
      stderr.writeLine("RLIMIT_NOFILE raised: soft " & $soft0 & " -> " &
                       $after.rlim_cur & " (hard " & $after.rlim_max & ")")
    else:
      stderr.writeLine("setrlimit(RLIMIT_NOFILE) failed: errno=" &
                       $(osLastError().int) & " (soft=" & $soft0 &
                       " hard=" & $hard & ")")
  else:
    stderr.writeLine("RLIMIT_NOFILE soft==hard==" & $soft0 & " (nothing to raise)")
  # Report the hard limit both when we raised and when soft==hard. An unlimited
  # hard limit (RLIM_INFINITY) is rlim_t all-ones, which Nim's signed `int`
  # rlim field reads back as negative; returning that would silently size the
  # fixed-file table down to the floor instead of the cap. Report the cap plus
  # the reserved headroom so the caller's min(hardNofile - FdsReserve, CAP)
  # lands exactly on CAP. Finite limits are returned unchanged.
  if hard < 0:
    result = CAP + FdsReserve
  else:
    result = int(hard)

proc setupListenSocket*(host: string; port, backlog, deferSec: int;
                        reusePort = false): cint =
  ## Create, bind and listen a non-blocking IPv4 socket, returning its fd (or -1,
  ## after logging, on any failure). `deferSec > 0` enables TCP_DEFER_ACCEPT
  ## before `listen`: the kernel withholds a completed handshake from `accept`
  ## until the client sends its first byte (HTTP clients send at once, so accept
  ## still fires immediately, but a silent handshake never wakes the loop).
  ## TCP_NODELAY is always set on the listener, which the kernel then inherits
  ## onto every accepted socket, so the send path installs no per-connection
  ## option and the direct-accept fast path stays usable.
  ##
  ## `reusePort` is only set on the multi-ring path: each ring gets its own
  ## listener on the same host:port and the kernel balances new connections
  ## across them. The single-ring call keeps the exact same socket options as
  ## before (SO_REUSEPORT would be a no-op there, but leaving it unset keeps
  ## that path byte-for-byte identical).
  result = cint(posix.socket(posix.AF_INET,
                             posix.SOCK_STREAM or SOCK_NONBLOCK, 0))
  if result < 0:
    stderr.writeLine("socket() failed: " & $(osLastError().int))
    return -1
  var one: cint = 1
  discard posix.setsockopt(SocketHandle(result), posix.SOL_SOCKET,
                           posix.SO_REUSEADDR, addr one, SockLen(sizeof(one)))
  if reusePort:
    discard posix.setsockopt(SocketHandle(result), posix.SOL_SOCKET,
                             SO_REUSEPORT, addr one, SockLen(sizeof(one)))
  # Listener-level send tuning: TCP_NODELAY removes Nagle on each accepted
  # socket (inherited by the kernel at accept time), byte-for-byte the same
  # effect as a per-connection setsockopt without the per-accept syscall.
  discard posix.setsockopt(SocketHandle(result), posix.IPPROTO_TCP,
                           TCP_NODELAY, addr one, SockLen(sizeof(one)))
  if deferSec > 0:
    var dv: cint = cint(deferSec)
    discard posix.setsockopt(SocketHandle(result), posix.IPPROTO_TCP,
                             TCP_DEFER_ACCEPT, addr dv, SockLen(sizeof(dv)))
  var sa: Sockaddr_in
  sa.sin_family = TSa_Family(posix.AF_INET)
  sa.sin_port = posix.htons(uint16(port))
  if posix.inet_pton(posix.AF_INET, host.cstring, addr sa.sin_addr) != 1:
    stderr.writeLine("invalid HOST: " & host)
    discard posix.close(result)
    return -1
  if posix.bindSocket(SocketHandle(result), cast[ptr SockAddr](addr sa),
                      SockLen(sizeof(sa))) != 0:
    stderr.writeLine("bind() failed on " & host & ":" & $port & ": " &
                     $(osLastError().int))
    discard posix.close(result)
    return -1
  if posix.listen(SocketHandle(result), cint(backlog)) != 0:
    stderr.writeLine("listen() failed: " & $(osLastError().int))
    discard posix.close(result)
    return -1

# ---------------------------------------------------------------------------
# request processing (the transport-agnostic core is api.handleRequest)

proc acquireOutBuf(buf: var string; pool: var seq[string])

var
  recvDirectRequests*: uint64
    ## Complete requests parsed and served straight from a receive buffer.
  recvCopiedBuffers*: uint64
    ## Receive buffers whose bytes were copied into `Conn.inbuf`: a carried
    ## partial, an incomplete final request, or an unconsumed tail left by the
    ## output cap.

proc processBuffer(data: openArray[char]; outbuf: var string;
                   keepAlive, closing: var bool; outOff: int;
                   batchFrom, batchCount: var int;
                   database: Db; secret: string;
                   maxInBuf, maxOutBuf: int;
                   outPool: ptr seq[string];
                   consumed: var int; countDirect: bool): bool =
  ## Parse and answer every complete pipelined request in `data`, appending the
  ## response bytes to `outbuf`. Returns false when the framing is malformed (or
  ## non-conforming) and the connection must close after flushing.
  ##
  ## `data` is either a borrowed view of the kernel's provided receive buffer or
  ## a view of `Conn.inbuf`; nothing here retains it, and every response is
  ## fully built before the caller may return a provided buffer to the kernel.
  ## `consumed` reports how many leading bytes were processed.
  ##
  ## `maxOutBuf` stops the loop once that many response bytes are buffered,
  ## leaving the remainder for the send-drain to finish.
  ##
  ## `outPool`, when supplied, is the owning ring's output pool: a buffer is
  ## taken from it immediately before the first append to an empty, zero-capacity
  ## `outbuf`, so a partial request never allocates one.
  template ensureOutBuf() =
    if outPool != nil and outbuf.len == 0 and outbuf.capacity == 0:
      acquireOutBuf(outbuf, outPool[])
  #
  # Advance with a local offset and compact once at the end; front-deleting per
  # request was O(n^2) on a large pipelined buffer.
  var pos = 0
  consumed = 0
  while true:
    if outbuf.len - outOff >= maxOutBuf:
      break
    let hend = findHeaderEnd(data, pos)
    if hend < 0:
      if data.len - pos > MaxHeader:
        return false
      break
    if hend - pos > MaxHeader:
      return false

    let head = parseHead(data, pos, hend, maxInBuf)
    if not head.ok:
      return false
    if head.bad:
      # Non-conforming framing (bad/conflicting Content-Length, Transfer-
      # Encoding, ...): answer 400 and close, rather than silently treating it
      # as CL=0 and re-parsing the body as a fresh request.
      ensureOutBuf()
      outbuf.addResponse(400, """{"error":"bad request"}""", false)
      closing = true
      return false
    let totalLen = (hend - pos) + 4 + head.contentLen
    if data.len - pos < totalLen:
      break                  # body not fully arrived
    var rawBody = ""
    if head.contentLen > 0:
      let b = hend + 4
      # The handler consumes the body through a string; this is the only body
      # copy the request path has ever made and is unrelated to `inbuf`.
      rawBody = newString(head.contentLen)
      copyMem(addr rawBody[0], unsafeAddr data[b], head.contentLen)
    pos += totalLen
    if countDirect:
      inc recvDirectRequests

    var resp: ApiResponse
    try:
      resp = handleRequest(database, secret, data, head.httpMethod, head.path,
                           head.auth, rawBody)
    except Exception as ex:
      # Exception covers Defect as well (OverflowDefect, IndexDefect, ...): no
      # request may ever abort the single-threaded process.
      stderr.writeLine("request handler error: " & ex.msg)
      resp = ApiResponse(status: 500, body: """{"error":"internal server error"}""")

    keepAlive = head.keepAlive
    ensureOutBuf()
    let respStart = outbuf.len
    if resp.feedDirect:
      # GET /feed is the one response large enough to justify building its body
      # in place. The writer appends the head and body atomically; if the
      # database raises, roll the partial bytes back and emit the same 500 the
      # generic path would.
      try:
        database.writeFeedResponse(outbuf, head.keepAlive)
      except Exception as ex:
        stderr.writeLine("feed writer error: " & ex.msg)
        outbuf.setLen(respStart)
        outbuf.addResponse(500, """{"error":"internal server error"}""",
                           head.keepAlive)
    else:
      outbuf.addResponse(resp.status, resp.body, head.keepAlive)
    # Record responses produced while a group-commit batch is open: they must not
    # be sent until that batch commits, and become 500 if it fails to commit.
    if database != nil and database.batchOpen():
      if batchCount == 0:
        batchFrom = respStart
      inc batchCount
    if not head.keepAlive:
      closing = true
      break

  consumed = pos
  true

proc processRequests*(inbuf, outbuf: var string; keepAlive, closing: var bool;
                      outOff: int; batchFrom, batchCount: var int;
                      database: Db; secret: string;
                      maxInBuf, maxOutBuf: int;
                      outPool: ptr seq[string] = nil): bool =
  ## Parse from a buffered request string (`Conn.inbuf`). The buffer is compacted
  ## by exactly the consumed prefix; an incomplete tail stays for the next recv.
  if inbuf.len == 0:
    return true
  var consumed = 0
  result = processBuffer(inbuf.toOpenArray(0, inbuf.len - 1), outbuf,
                         keepAlive, closing, outOff, batchFrom, batchCount,
                         database, secret, maxInBuf, maxOutBuf, outPool,
                         consumed, false)
  if consumed > 0:
    inbuf.delete(0 ..< consumed)


# ---------------------------------------------------------------------------
# syscall surface std/posix and iouring.nim do not expose for us
# (raw `syscall`, never liburing)

proc c_syscall(number: clong): clong
  {.importc: "syscall", header: "<unistd.h>", varargs.}
var SYS_io_uring_register {.importc, header: "<sys/syscall.h>".}: clong

# SOCK_NONBLOCK is declared with the socket scaffold above; SOCK_CLOEXEC is
# only needed here.
var SOCK_CLOEXEC  {.importc, header: "<sys/socket.h>".}: cint

# eventfd: the multi-ring wake source (see runMultiLoop). EFD_NONBLOCK makes the
# drain read (which clears the counter) never block; EFD_CLOEXEC is hygiene.
proc c_eventfd(initval: cuint, flags: cint): cint
  {.importc: "eventfd", header: "<sys/eventfd.h>".}
const
  EFD_NONBLOCK = 0x800
  EFD_CLOEXEC  = 0x80000

# ---------------------------------------------------------------------------
# io_uring constants not already exported by iouring.nim (mirrored from
# <linux/io_uring.h>)

const
  IOSQE_FIXED_FILE*        = 1'u8 shl 0

  IORING_OP_TIMEOUT*       = 11'u8
  IORING_OP_ASYNC_CANCEL*  = 14'u8

  IORING_REGISTER_FILES_UPDATE* = 6
  # Register one eventfd on a ring; the kernel bumps it on every completion
  # event for that ring. One fd can be registered on every ring, so the N-ring
  # waiter needs only a single epoll entry. (This only works when the ring does
  # NOT use DEFER_TASKRUN: the signal happens when the CQ is committed, and
  # deferred task work has not committed anything until someone enters.)
  IORING_REGISTER_EVENTFD*      = 4
  IORING_ASYNC_CANCEL_USERDATA  = 1'u32 shl 4

  # user_data operation tags (low 8 bits) + slot (next 24) + generation (high 32)
  TAG_ACCEPT*  = 1'u64
  TAG_RECV*    = 2'u64
  TAG_SEND*    = 3'u64
  TAG_TIMEOUT* = 4'u64
  TAG_CANCEL*  = 5'u64
  TAG_PROVIDE* = 6'u64
  TAG_CLOSE*   = 7'u64

  # ring / table sizing.
  # The registered-file table size is RUNTIME (see `RingCtx.slots`): it is
  # derived from the process fd ceiling at startup instead of a compile-time
  # literal, so a single ring is no longer capped at 32768 connections.
  # `IORING_REGISTER_FILES` checks a table's size against RLIMIT_NOFILE (the
  # check is per registration, not cumulative - verified on this kernel), so the
  # per-ring size is `min(hardLimit - FdsReserve, MaxSlotsPerRing)`:
  # `FdsReserve` reserves headroom for the process's own fds (stdio, the
  # io_uring ring, the listener before it is closed, the sqlite db) - without it,
  # registering 65536 entries fails when RLIMIT_NOFILE==65535.
  #
  # One request thread may own up to `MaxRings` rings after the fd / conntrack
  # limits raise. Because every ring registers its own table, total
  # capacity is rings * slotsPerRing (up to ~5 * 65535 = ~327k fixed slots), even
  # though each individual registration stays under RLIMIT_NOFILE.
  # `SlotsFloor` is the smallest table a ring registers; if the kernel refuses
  # the top size, that ring steps DOWN to the floor instead of exiting.
  RingEntries  = 4096
  MaxRings     = 5
  MaxSlotsPerRing = 65535     # slot16 in user_data, and the registered cap
  MaxConns     = MaxRings * MaxSlotsPerRing
  # Conntrack entries reserved for everything that is not a served connection
  # (the load generator's side of every socket, DNS, the odd tool). Auto-sizing
  # targets `conntrack_max - ConntrackHeadroom`, so the current 64k cap yields
  # target 64512 -> exactly one ring.
  ConntrackHeadroom = 1024
  # Explicit CQ headroom, requested via IORING_SETUP_CQSIZE (see setupQueue).
  # Without CQSIZE the kernel defaults `cq_entries = 2 * sq_entries` (verified
  # on this host: sq=4096 -> cq=8192).  We ask for CqMultiple x so a burst of
  # completions cannot park enough entries on the kernel CQ-overflow list to
  # stall the loop while the live connection count approaches the ~64k
  # conntrack ceiling: 4 * 4096 = 16384 CQEs against 4096 SQEs.  The kernel
  # fills the size it actually allocated into params.cq_entries and the startup
  # log prints it, so the headroom is observed, not assumed.  Submissions stay
  # bounded by RingEntries: getSqe returns nil on a full SQ and mustSqe(r)
  # flushes/waits.
  CqMultiple   = 4
  SlotsFloor   = 16384
  ListenSlot   = 0'i32

  # read/parse limits
  MaxInBuf      = 1024 * 1024
  MaxRequest    = MaxInBuf + MaxHeader + 4
  # Output cap: processing stops once this many response bytes are buffered,
  # which leaves output in flight so the drain path resumes the remaining
  # pipelined requests.  The cap bounds how many *pipelined* responses are
  # queued for one connection, not the size of any single response: a response
  # is appended whole and only the top-of-loop check observes the cap, so a body
  # larger than the cap is still fully buffered and handed to the SEND path
  # (partial sends resume from `outOff` on the next completion).  64 KiB keeps a
  # deep pipeline from pinning a multi-MiB heap buffer per connection while
  # staying far above the largest single response this API returns.
  MaxOutBuf     = 64 * 1024
  TickSeconds   = 1.0

  # Load-adaptive completion wait (runLoop).  The loop always drains the whole
  # CQ ring, so the blocking wait for one completion is already well batched.
  # Under sustained load only, it instead waits for a small batch with a bounded
  # timeout: existing CQEs count towards `min_complete`, so a backlog is never
  # delayed, and the 100 us cap bounds how long a partial batch can wait.  A
  # pass that drained fewer than `BatchMinComplete` completions falls straight
  # back to the blocking single-completion wait, which also bounds the idle
  # wakeup to the armed 1 s tick.
  #
  # A 16/150 us variant was considered and deliberately not taken: min_complete
  # counts queued CQEs, so a pass that drained 8..15 would additionally sleep up
  # to 150 us with that work already available. That is added latency, not just
  # a longer idle wait. The 8/100 us point keeps the N>1 eventfd/epoll path
  # (which does not use this batch wait at all) unchanged as well.
  BatchMinComplete    = 8'u32
  BatchMaxUsec        = 100'u64
  BatchLoadThreshold  = 8

  # -------------------------------------------------------------------------
  # Output-buffer pool.
  #
  # An output buffer used to be kept for the whole life of a keep-alive
  # connection (`outbuf.setLen(0)` after a drained SEND keeps the capacity of
  # the largest response ever sent - ~5.1 KiB for /feed). At 5,000 idle
  # connections that pinned ~25 MiB. Instead, a buffer is taken only while a
  # response is being built and returned once the SEND has fully completed, so
  # an idle connection holds a zero-capacity string. Retention is bounded on
  # both axes: at most OutPoolCap buffers in the ring's pool and only buffers
  # up to MaxRetainedOutCap bytes. Anything larger is freed immediately.
  OutPoolCap        = 128
  MaxRetainedOutCap = 64 * 1024
  OutBufInitCap     = 8 * 1024
  # Empty input buffers up to this capacity are kept (compacting a pipelined
  # buffer is cheap and the connection is likely to read again soon); larger
  # ones are freed once the consumed burst leaves nothing behind.
  InBufRetainCap    = 4 * 1024

  # -------------------------------------------------------------------------
  # Provided-buffer pool ("the turbo").
  #
  # Multishot recv selects its landing buffer from a single SHARED pool instead
  # of every connection owning a private 16 KiB recv buffer. Idle connections
  # therefore hold no recv storage at all (a buffer is taken only while bytes
  # are actually in flight), which is what removes the per-connection RSS that
  # the one-shot design paid at 10k connections.
  #
  # The pool is one lazily-faulted allocation: `alloc` gives untouched pages, so
  # only the buffers the kernel has actually written into become resident. The
  # descriptors live in a page-aligned ring registered once with
  # IORING_REGISTER_PBUF_RING; when the kernel cannot do that we fall back to
  # IORING_OP_PROVIDE_BUFFERS over the exact same buffer memory.
  BufGroup       = 0'u16
  BufSize        = 8 * 1024
  # Default pool 256: the 64k-connection target needs more in-flight receive
  # buffers than the 64-buffer floor; 256 measured lower sys CPU and a much
  # better p99 at 6,800 rps while adding only ~2 MiB of lazily-faulted address
  # space. IOURING_BUFS can tune it up to BufRingMax; both values must be powers
  # of two. BufSize is 8 KiB: requests are well under 4 KiB, so only one page per
  # buffer is ever faulted, and shrinking it cannot lower RSS (page granularity)
  # but would add a CQE per request.
  BufRingDefault = 256
  BufRingMax     = 8192
  # Multi-ring default budget: the ring count is at most MaxRings, so splitting
  # one bounded global budget keeps total provided buffers independent of ring
  # count. The single-ring path uses BufRingDefault.
  MultiBufBudget = 4096

# kernel-side struct for IORING_OP_TIMEOUT
type KernelTimespec {.bycopy.} = object
  tv_sec:  int64
  tv_nsec: int64

# ---------------------------------------------------------------------------
# connection state: one slot per entry in the registered file table

type
  ConnFlag = enum
    ## Per-connection boolean state. Kept in one `set` so the nine one-bit
    ## facts occupy two bytes instead of nine bytes padded out to full
    ## machine words each time they land between the wider fields.
    cfActive, cfKeepAlive, cfClosing, cfReadPaused, cfRecvArmed, cfSendArmed,
    cfWantFree, cfDeferred, cfRecvCancelPending

  Conn = object
    gen:        uint32   ## bumped per reuse so stale CQEs are ignored
    st:         set[ConnFlag]
    inbuf:      string
    outbuf:     string
    outOff:     int
    pending:    int      ## in-flight io_uring ops referencing our buffers
    lastActive: float
    batchFrom:  int      ## outbuf offset where this pass's batch output begins
    batchCount: int      ## responses appended while the pass's batch was open

# `Conn.st` accessors. These are templates so the packed set reads and writes
# exactly like the former per-field booleans did: `c.active` stays a boolean
# expression and `c.active = false` stays an assignment. Each expands inline to
# one bit test / incl / excl, so there is no call on the hot path. A pair is
# provided for both a `Conn` value and a `ptr Conn`, matching the two ways the
# connection is addressed (direct index and `addr r.conns[slot]`).
template active(c: Conn | ptr Conn): bool = cfActive in c.st
template `active=`(c: var Conn | ptr Conn, v: bool) =
  (if v: c.st.incl cfActive else: c.st.excl cfActive)

template keepAlive(c: Conn | ptr Conn): bool = cfKeepAlive in c.st
template `keepAlive=`(c: var Conn | ptr Conn, v: bool) =
  (if v: c.st.incl cfKeepAlive else: c.st.excl cfKeepAlive)

template closing(c: Conn | ptr Conn): bool = cfClosing in c.st
template `closing=`(c: var Conn | ptr Conn, v: bool) =
  (if v: c.st.incl cfClosing else: c.st.excl cfClosing)

template readPaused(c: Conn | ptr Conn): bool = cfReadPaused in c.st
template `readPaused=`(c: var Conn | ptr Conn, v: bool) =
  (if v: c.st.incl cfReadPaused else: c.st.excl cfReadPaused)

template recvArmed(c: Conn | ptr Conn): bool = cfRecvArmed in c.st
template `recvArmed=`(c: var Conn | ptr Conn, v: bool) =
  (if v: c.st.incl cfRecvArmed else: c.st.excl cfRecvArmed)

template recvCancelPending(c: Conn | ptr Conn): bool = cfRecvCancelPending in c.st
template `recvCancelPending=`(c: var Conn | ptr Conn, v: bool) =
  (if v: c.st.incl cfRecvCancelPending else: c.st.excl cfRecvCancelPending)

template sendArmed(c: Conn | ptr Conn): bool = cfSendArmed in c.st
template `sendArmed=`(c: var Conn | ptr Conn, v: bool) =
  (if v: c.st.incl cfSendArmed else: c.st.excl cfSendArmed)

template wantFree(c: Conn | ptr Conn): bool = cfWantFree in c.st
template `wantFree=`(c: var Conn | ptr Conn, v: bool) =
  (if v: c.st.incl cfWantFree else: c.st.excl cfWantFree)

template deferred(c: Conn | ptr Conn): bool = cfDeferred in c.st
template `deferred=`(c: var Conn | ptr Conn, v: bool) =
  (if v: c.st.incl cfDeferred else: c.st.excl cfDeferred)

type
  SlotRef = tuple
    ## A pending slot reference carrying the connection generation at the time it
    ## was queued. Direct accept aggressively reuses fixed slots, so a bare index
    ## could name a different (reused) connection by the time it is consumed; the
    ## generation lets the consumer skip a stale entry.
    slot: cint
    gen:  uint32

var
  # ---- shared by every ring (one request thread owns all of them) ------------
  gDb:        Db
  gSecret:    string
  gNow:       float          # pass timestamp, refreshed once per completion pass
  gZeroCopyStats: bool       # ZEROCOPY_STATS=1: log the recv fast-path counters

type
  RingCtx = object
    ## Every piece of per-ring state. `gRings` holds 1..MaxRings instances; the
    ## same request thread creates, enters and drains all of them (SINGLE_ISSUER
    ## requires the creating task; DEFER_TASKRUN, N=1 only, additionally binds
    ## task work to it). Procs receive a `var RingCtx`
    ## (a reference in effect); a RingCtx is NEVER copied - its seq/ptr fields
    ## would alias and copying `conns` alone would be a full table copy.
    id:          uint8        # ring id carried in every CQE's user_data
    ring:        Ring
    listenerFd:  cint         # listener registered as fixed-file slot 0
    slots:       int          # registered fixed-file entries in THIS ring
                              # (includes slot 0 = this ring's listener)
    multiRing:   bool         # driven by the shared epoll loop: never block one
                              # ring's enter while another ring has work

    # ---- connection table and slot free list -------------------------------
    conns:        seq[Conn]   # fixed-file slot index; capacity reserved for
                              # `slots`, length grown only as slots are used
    freeSlots:    seq[cint]
    freeTop:      int
    nextSlot:     int         # first never-used slot (high-water mark)
    gen:          uint32      # per-ring generation, bumped on every accept
    accepted:     uint64      # accepted connections (multi-ring fairness log)
    ticks:        uint64      # 1 s ticks observed (multi-ring fairness log)

    # ---- accept state ------------------------------------------------------
    acceptArmed:        bool
    acceptPaused:       bool
    # IOURING_RECV=multishot|oneshot (default multishot) and
    # IOURING_ACCEPT=multishot|oneshot (default multishot). Multishot RECV has
    # no runtime fallback: a kernel without IORING_RECV_MULTISHOT needs the
    # manual IOURING_RECV=oneshot workaround (one-shot recv is re-armed after
    # every CQE). Accept DOES fall back at runtime when the kernel refuses
    # multishot/direct accept; `-ENOBUFS` is handled on the recv path.
    recvMultishot:      bool = true
    acceptMultishot:    bool = true
    acceptMsProven:     bool = false
    # Direct accept: install the accepted socket straight into a fixed slot with
    # IORING_FILE_INDEX_ALLOC (kernel picks the slot; CQE res == slot).
    # IOURING_ACCEPT_DIRECT=0 forces the register-per-accept fallback; it also
    # engages automatically if the kernel rejects the direct variant.
    acceptDirect:       bool = true
    acceptDirectProven: bool = false

    # ---- provided-buffer pool ---------------------------------------------
    bufBase:      ptr UncheckedArray[char]          # bufSlots * BufSize, lazily faulted
    bufRing:      ptr UncheckedArray[BufRingEntry]  # page-aligned descriptor ring
    bufTail:      uint16
    bufTailPending: bool                            # descriptors written, tail not published
    bufSlots:     int = BufRingDefault              # live pool size (IOURING_BUFS, power of 2)
    bufMask:      int = BufRingDefault - 1
    useBufRing:   bool                              # true: registered PBUF_RING; else list
    bufsReady:    int                               # buffers handed to the kernel, not yet seen
    consumedThisPass: int                           # data CQEs that returned a buffer this pass
    recvStarved:  seq[SlotRef]                      # recv ended with -ENOBUFS (slot+gen)
    sendRetry:    seq[SlotRef]                      # send ended with -ENOBUFS (slot+gen)

    # Slots whose SEND was withheld because their responses were produced while
    # a group-commit batch was open. Armed (or rewritten to 500) once the batch
    # has been committed at the end of the completion-queue pass.
    deferredSlots: seq[SlotRef]

    # Bounded per-ring pool of drained output buffers. The one request thread
    # owns the ring (ARC), so no synchronisation is needed; an entry is always a
    # zero-length string whose capacity is <= MaxRetainedOutCap.
    outPool: seq[string]

    # accept scratch (must stay valid until the accept op completes)
    acceptSa:    Sockaddr_in
    acceptSaLen: SockLen

    # timeout scratch (must stay valid until the timeout op completes)
    ts: KernelTimespec

var
  # 1..MaxRings rings, all owned by the single request thread. Exactly one
  # element on the default (64k conntrack) configuration.
  gRings: seq[RingCtx]

# ---------------------------------------------------------------------------
# user_data packing

proc makeUd(tag: uint64, ring: uint8, slot: cint, gen: uint32): uint64 {.inline.} =
  ## tag 8 | ring 8 | slot 16 | gen 32. A slot is a fixed-file index within ITS
  ## ring's table, bounded by MaxSlotsPerRing (65,535); the generation
  ## disambiguates reuse. Each CQE is routed to its ring by the ring id, and
  ## dispatch() re-checks it so a mis-routed completion can never touch another
  ## ring's slot table.
  tag or (uint64(ring) shl 8) or
    ((uint64(uint32(slot)) and 0xFFFF'u64) shl 16) or (uint64(gen) shl 32)

proc udTag(ud: uint64): uint64 {.inline.} = ud and 0xFF'u64
proc udRing(ud: uint64): uint8 {.inline.} = uint8((ud shr 8) and 0xFF'u64)
proc udSlot(ud: uint64): cint {.inline.} = cint((ud shr 16) and 0xFFFF'u64)
proc udGen(ud: uint64): uint32 {.inline.} = uint32(ud shr 32)

# ---------------------------------------------------------------------------
# output-buffer pool
#
# `takeOutBuf` is called right before a response is appended; `releaseOutBuf`
# only when the SEND that carried that response has completed in full (or when
# `maybeFreeSlot` has proved `pending == 0`). The pool is deliberately tiny: it
# removes per-request allocation for the common keep-alive reuse while keeping
# the retained heap bounded no matter how many connections exist.

proc takeOutBuf(pool: var seq[string]): string =
  ## A zero-length buffer: a pooled one when available, else 8 KiB fresh.
  if pool.len > 0:
    result = pool.pop()
    result.setLen(0)
  else:
    result = newStringOfCap(OutBufInitCap)

proc releaseOutBuf(pool: var seq[string]; s: var string) =
  ## Give `s` back to the pool when it is within both retention bounds, else
  ## free it. The caller guarantees no in-flight SEND can still reference the
  ## storage. `move` is required: copying a zero-length string loses its
  ## capacity, which would defeat the pool entirely.
  if s.capacity > 0 and s.capacity <= MaxRetainedOutCap and
     pool.len < OutPoolCap:
    s.setLen(0)
    pool.add move(s)
  else:
    s = ""

proc acquireOutBuf(buf: var string; pool: var seq[string]) =
  ## `processRequests` hook: called only when a response is about to be
  ## appended to an empty, zero-capacity buffer.
  buf = takeOutBuf(pool)

proc maybeReleaseOutBuf(r: var RingCtx; c: var Conn) {.inline.} =
  ## Drop a live connection's output buffer once it is fully drained. Guarded so
  ## it can never free storage a deferred/group-commit response, an armed SEND
  ## or the unflushed tail of the current buffer still needs.
  if c.batchCount == 0 and not c.deferred and not c.sendArmed and
     c.outOff >= c.outbuf.len:
    c.outOff = 0
    releaseOutBuf(r.outPool, c.outbuf)

proc releaseConnStorage(r: var RingCtx; c: var Conn) =
  ## Return a dead connection's output buffer to the pool. Only `maybeFreeSlot`
  ## calls this, and only after `pending == 0`, so no kernel SEND or RECV can
  ## reference either buffer. The caller resets the whole `Conn` immediately
  ## afterwards, which drops `inbuf`; retaining it here would be undone by that
  ## reset, so only the pooled output buffer needs an explicit release.
  releaseOutBuf(r.outPool, c.outbuf)

# ---------------------------------------------------------------------------
# HTTP/1.1 parsing and serialisation live in the shared `http` module (imported
# above); this transport only supplies its inbound body cap (MaxInBuf) to
# parseHead.

proc processRequests(r: var RingCtx; c: var Conn): bool {.inline.} =
  ## Thin adapter over the shared request loop above; maxOutBuf caps the
  ## buffered response bytes so a large pipelined burst drains across sends.
  ## keepAlive/closing are now bits in `c.st`, so they are staged through locals
  ## for the `var bool` core and written back; identical in/out semantics.
  ## The core takes an output buffer from the pool only if it actually appends
  ## a response; one that produced no bytes is returned immediately below.
  var ka = c.keepAlive
  var cl = c.closing
  result = processRequests(c.inbuf, c.outbuf, ka, cl, c.outOff,
                           c.batchFrom, c.batchCount, gDb, gSecret, MaxInBuf,
                           MaxOutBuf, addr r.outPool)
  c.keepAlive = ka
  c.closing = cl
  # Consumed pipelined data leaves the request buffer empty; a large one is
  # dropped instead of pinned for the life of the connection. A partial request
  # still buffered is never touched.
  if c.inbuf.len == 0 and c.inbuf.capacity > InBufRetainCap:
    c.inbuf = ""
  maybeReleaseOutBuf(r, c)

proc processRecvDirect(r: var RingCtx; c: var Conn;
                      data: openArray[char]): bool =
  ## Parse one provided receive buffer in place. No request bytes enter
  ## `Conn.inbuf`; only a trailing incomplete request (or the tail left by the
  ## output cap) is copied out, so `data` can be returned to the kernel as soon
  ## as this proc returns. Every response is fully appended to `c.outbuf` here,
  ## and a deferred SEND references only that output buffer.
  var ka = c.keepAlive
  var cl = c.closing
  var consumed = 0
  result = processBuffer(data, c.outbuf, ka, cl, c.outOff,
                         c.batchFrom, c.batchCount, gDb, gSecret, MaxInBuf,
                         MaxOutBuf, addr r.outPool, consumed, true)
  c.keepAlive = ka
  c.closing = cl
  if result and not c.closing and consumed < data.len:
    let rem = data.len - consumed
    c.inbuf.setLen(rem)
    copyMem(addr c.inbuf[0], unsafeAddr data[consumed], rem)
    inc recvCopiedBuffers
  if c.inbuf.len == 0 and c.inbuf.capacity > InBufRetainCap:
    c.inbuf = ""
  maybeReleaseOutBuf(r, c)

proc processRecv(r: var RingCtx; c: var Conn;
                 data: openArray[char]): bool =
  ## Route one receive buffer. With no carried partial the bytes are parsed in
  ## place. When `c.inbuf` already holds an incomplete request the new bytes are
  ## copied behind it, because the two buffers are not contiguous; that is the
  ## only cross-buffer copy on the receive path.
  if c.inbuf.len == 0:
    return processRecvDirect(r, c, data)
  let old = c.inbuf.len
  c.inbuf.setLen(old + data.len)
  copyMem(addr c.inbuf[old], unsafeAddr data[0], data.len)
  inc recvCopiedBuffers
  processRequests(r, c)

# ---------------------------------------------------------------------------
# fixed-file table bookkeeping

proc updateSlotRaw(r: var RingCtx; slot: cint, fd: cint): int =
  ## IORING_REGISTER_FILES_UPDATE: install `fd` (or -1 to clear) at `slot`.
  ## Passing -1 drops the table's reference, which closes the socket once any
  ## in-flight op holding its own reference completes.
  var up: array[4, uint64]
  up[0] = uint64(uint32(slot))          # offset(u32) + resv(u32)
  var tmp = fd
  up[1] = uint64(cast[uint](addr tmp))  # pointer to the fd array
  let ret = c_syscall(SYS_io_uring_register, clong(r.ring.fd),
                      clong(IORING_REGISTER_FILES_UPDATE),
                      clong(cast[uint](addr up[0])), clong(1))
  if ret < 0:
    result = -cint(osLastError().int)
  else:
    result = int(ret)

proc ensureSlot(r: var RingCtx; slot: cint) {.inline.} =
  ## Materialise `r.conns` up to and including `slot`. The full fixed-file table
  ## capacity was reserved once at startup with `newSeqOfCap`, so growing the
  ## length here only zero-fills the newly committed payload: the allocation is
  ## never reallocated and every `addr r.conns[i]` handed out earlier stays valid.
  if int(slot) >= r.conns.len:
    assert slot >= 0 and int(slot) < r.slots
    r.conns.setLen(int(slot) + 1)
    # Invaluable invariant: a setLen above the reserved capacity would realloc
    # and silently invalidate live `ptr Conn`s held by in-flight completions.
    assert r.conns.capacity >= r.slots

proc allocSlot(r: var RingCtx): cint =
  ## Pop a released slot first; otherwise commit the next never-used slot. The
  ## slot's Conn is materialised by ensureSlot before the caller touches it.
  if r.freeTop > 0:
    dec r.freeTop
    return r.freeSlots[r.freeTop]
  if r.nextSlot >= r.slots:
    return -1
  result = cint(r.nextSlot)
  inc r.nextSlot
  ensureSlot(r, result)

proc releaseSlot(r: var RingCtx; slot: cint) =
  ## Recv storage is pooled (not per-connection), so returning a slot is just
  ## bookkeeping: no buffer to free, only flags and the free-list push.
  ## In direct-accept mode the *kernel* owns slot allocation (FILES_UPDATE(-1) in
  ## maybeFreeSlot already frees the slot), so we must NOT also push it onto the
  ## userspace free list - doing so would double-count and could overflow it.
  r.conns[int(slot)].wantFree = false
  if r.acceptDirect:
    return
  r.freeSlots[r.freeTop] = slot
  inc r.freeTop

proc rebuildFreeList(r: var RingCtx) =
  ## Used only when a ring downgrades from direct accept before any direct
  ## accept has succeeded. The kernel therefore never installed a slot and the
  ## userspace list was never consumed; keep the never-used range in nextSlot
  ## and leave the free list empty.
  r.freeTop = 0
  r.nextSlot = r.conns.len

# Queued by maybeFreeSlot; defined with the other submission helpers below.
proc submitClose(r: var RingCtx; slot: cint; gen: uint32): bool

proc maybeFreeSlot(r: var RingCtx; slot: cint) =
  ## Release a closed connection's slot once its last in-flight op has completed.
  ## This is the ONLY place the socket's fixed-file entry is dropped and the
  ## slot becomes reusable, so a new connection can never overwrite a slot while
  ## a SEND still points at the old `outbuf`.
  if slot < 0:
    return
  var c = addr r.conns[int(slot)]
  if c.active or not c.wantFree or c.pending != 0:
    return
  let gen = c.gen
  # No op can reference this connection any more: release its pooled output
  # buffer and reset the whole Conn BEFORE dropping the kernel's file reference.
  # The reset drops `inbuf` (including any retained capacity), so a direct
  # accept that immediately reuses this slot finds a clean Conn with no storage.
  releaseConnStorage(r, c[])
  r.conns[int(slot)] = Conn()
  if r.acceptDirect:
    # Direct descriptors are allocated and freed by the kernel. Closing via
    # IORING_OP_CLOSE (fixed file_index) frees the slot in the kernel's bitmap
    # as the op executes, so a direct accept cannot receive the slot before
    # that point: no userspace free-list entry is involved. A failed close
    # still posts an error CQE (success is skipped) and is recovered in
    # onClose; if the SQE cannot be reserved at all, drop the entry with the
    # register-update fallback so the slot is never leaked.
    if not submitClose(r, slot, gen):
      discard updateSlotRaw(r, slot, -1'i32)
  else:
    # Register-per-accept: the slot is userspace-owned and goes straight back
    # on the free list below, so it must be dropped *now*; a deferred close op
    # could otherwise close a freshly registered socket.
    discard updateSlotRaw(r, slot, -1'i32)
  releaseSlot(r, slot)

# ---------------------------------------------------------------------------
# submission helpers

proc flushBufTail(r: var RingCtx) {.inline.} =
  ## Publish the provided-buffer producer tail after all descriptors pushed
  ## during this pass. poolPush only writes descriptors and bumps bufTail; the
  ## single tail store happens here, before the next enter can submit a recv.
  if r.useBufRing and r.bufTailPending:
    # Publish the descriptor tail after all descriptor writes. x86 gets this
    # ordering from TSO; ARM64 uses a release store.
    storeReleaseU16(addr r.bufRing[0].resv, r.bufTail)
    r.bufTailPending = false

proc mustSqe(r: var RingCtx): ptr Sqe =
  ## Reserve an SQE, flushing (and, if needed, waiting for a completion) when
  ## the submission queue is momentarily full.
  ##
  ## In multi-ring mode the fallback wait is deliberately NOT used: the one
  ## request thread must never block inside one ring's enter while another ring
  ## already has completions waiting. A non-blocking submit() has always freed
  ## the SQ on this kernel (the enter consumes every reserved SQE before it
  ## returns), so the second getSqe is the only wait-free retry needed. The
  ## final case is therefore unreachable in practice; it logs and skips the
  ## arm rather than risking every other ring's completions behind this enter.
  result = r.ring.getSqe()
  if result.isNil:
    # The batch of buffer descriptors written so far must be published before
    # this enter lets the kernel run the recvs armed earlier in the pass.
    flushBufTail(r)
    discard r.ring.submit()
    result = r.ring.getSqe()
  if result.isNil:
    if r.multiRing:
      stderr.writeLine("io_uring ring " & $r.id & ": SQ full after submit; arm skipped")
      return nil
    flushBufTail(r)
    discard r.ring.submitAndWait(1)
    result = r.ring.getSqe()

proc submitClose(r: var RingCtx; slot: cint; gen: uint32): bool =
  ## Queue IORING_OP_CLOSE for a direct (fixed) descriptor and skip its success
  ## CQE. The kernel clears the slot's bitmap as the op executes, so a direct
  ## accept cannot hand the slot out before the close has run; the userspace
  ## Conn was already reset and pending was zero. A close failure still posts a
  ## CQE (IOSQE_CQE_SKIP_SUCCESS skips only success) and is recovered by onClose.
  let sqe = mustSqe(r)
  if sqe.isNil:
    return false
  sqe.opcode = IORING_OP_CLOSE
  # `file_index` (the splice_fd_in union) selects a fixed descriptor; 0 would
  # mean a process fd, hence slot + 1. IOSQE_FIXED_FILE is deliberately NOT
  # set: the kernel rejects a close sqe that uses it.
  sqe.fd = 0'i32
  sqe.splice_fd_in = int32(slot + 1)
  sqe.flags = IOSQE_CQE_SKIP_SUCCESS
  sqe.user_data = makeUd(TAG_CLOSE, r.id, slot, gen)
  true

# ---------------------------------------------------------------------------
# provided-buffer pool
#
# Buffer `bid` always lives at `r.bufBase[bid * BufSize]`; the id is the index,
# so a returned buffer is simply re-published with that same id and no
# allocation bookkeeping is needed at all on the hot path.

proc poolPush(r: var RingCtx; bid: int) =
  ## Hand buffer `bid` back to the kernel. With a registered buf ring this is
  ## pure userspace bookkeeping (write the descriptor, bump the producer tail);
  ## flushBufTail publishes the tail once per pass. The fallback submits one
  ## fire-and-forget IORING_OP_PROVIDE_BUFFERS per buffer (success CQE skipped;
  ## an error CQE is handled in dispatch).
  if r.useBufRing:
    let idx = int(r.bufTail) and r.bufMask
    let e = addr r.bufRing[idx]
    e.`addr` = cast[uint64](addr r.bufBase[bid * BufSize])
    e.len = uint32(BufSize)
    e.bid = uint16(bid)
    r.bufTail = r.bufTail + 1'u16
    r.bufTailPending = true
  else:
    let sqe = mustSqe(r)
    if sqe.isNil:
      return
    prepProvideBuffers(sqe, cast[uint64](addr r.bufBase[bid * BufSize]),
                       uint32(BufSize), 1'u32, uint16(bid), BufGroup)
    sqe.flags = IOSQE_CQE_SKIP_SUCCESS
    # gen=1 marks a single-buffer provide (gen=0 is the bulk init provide), so a
    # failed provide can undo exactly one bufsReady count.
    sqe.user_data = makeUd(TAG_PROVIDE, r.id, 0, 1)
  inc r.bufsReady

proc poolConsume(r: var RingCtx) {.inline.} =
  dec r.bufsReady
  inc r.consumedThisPass

proc armAccept(r: var RingCtx) =
  ## Arm accept. With IORING_ACCEPT_MULTISHOT one SQE serves every pending
  ## connection until the kernel reports it can no longer continue
  ## (IORING_CQE_F_MORE clears); otherwise it is re-armed per completion.
  if r.acceptArmed:
    return
  let sqe = mustSqe(r)
  if sqe.isNil:
    return
  r.acceptSaLen = SockLen(sizeof(r.acceptSa))
  sqe.opcode = IORING_OP_ACCEPT
  sqe.flags = IOSQE_FIXED_FILE
  sqe.fd = ListenSlot
  sqe.`addr` = cast[uint64](addr r.acceptSa)
  sqe.off = cast[uint64](addr r.acceptSaLen)
  if r.acceptDirect and r.acceptMultishot:
    # Direct descriptor: the kernel installs the accepted socket into the first
    # free registered-file slot and returns that SLOT in the CQE's `res` (field
    # is the splice_fd_in/file_index union at Sqe offset 44). SOCK_CLOEXEC is
    # rejected (-EINVAL) here because a fixed descriptor has no process fd, so
    # only SOCK_NONBLOCK is requested; the non-direct path keeps both.
    sqe.rw_flags = uint32(SOCK_NONBLOCK)
    sqe.splice_fd_in = cast[int32](IORING_FILE_INDEX_ALLOC)
  else:
    sqe.rw_flags = uint32(SOCK_NONBLOCK or SOCK_CLOEXEC)
  if r.acceptMultishot:
    sqe.ioprio = uint16(IORING_ACCEPT_MULTISHOT)
  sqe.user_data = makeUd(TAG_ACCEPT, r.id, 0, 0)
  r.acceptArmed = true

proc armRecv(r: var RingCtx; slot: cint) =
  ## Arm (or, in multishot mode, leave armed) a recv that selects its landing
  ## buffer from the shared provided-buffer pool. `IOSQE_BUFFER_SELECT` makes
  ## the kernel pick a buffer; the CQE then carries its id in the high 16 bits
  ## of cqe->flags.
  ##
  ## `recvArmed` is held until the recv's terminal CQE, and a pending CANCEL is
  ## serialized in front of any new recv: until that CANCEL's terminal arrives
  ## the old op still owns the user_data it shares with the slot, so arming a
  ## second multishot recv here would alias two kernel ops onto one cancel.
  if slot < 0:
    return
  var c = addr r.conns[int(slot)]
  if not c.active or c.closing or c.recvArmed or c.recvCancelPending:
    return
  let sqe = mustSqe(r)
  if sqe.isNil:
    return
  sqe.opcode = IORING_OP_RECV
  sqe.flags = IOSQE_FIXED_FILE or IOSQE_BUFFER_SELECT
  sqe.fd = slot
  sqe.buf_index = BufGroup
  sqe.len = uint32(BufSize)
  if r.recvMultishot:
    sqe.ioprio = uint16(IORING_RECV_MULTISHOT)
  sqe.user_data = makeUd(TAG_RECV, r.id, slot, c.gen)
  c.recvArmed = true
  inc c.pending

proc rearmStarved(r: var RingCtx) =
  ## Re-arm every recv that ended with -ENOBUFS, now that buffers have returned.
  ## Only called when at least one buffer is available (r.bufsReady > 0), so it
  ## cannot spin on a still-empty pool.
  if r.recvStarved.len == 0:
    return
  let starved = r.recvStarved
  r.recvStarved.setLen(0)
  for sr in starved:
    let slot = sr.slot
    if slot < 0 or int(slot) >= r.conns.len:
      continue
    var c = addr r.conns[int(slot)]
    if c.gen != sr.gen:
      continue                      # slot reused by another connection: stale
    if c.active and not c.closing and not c.recvArmed and not c.readPaused:
      armRecv(r, slot)

proc armSend(r: var RingCtx; slot: cint) =
  if slot < 0:
    return
  var c = addr r.conns[int(slot)]
  if not c.active or c.sendArmed:
    return
  if c.outOff >= c.outbuf.len:
    return
  let sqe = mustSqe(r)
  if sqe.isNil:
    return
  sqe.opcode = IORING_OP_SEND
  sqe.flags = IOSQE_FIXED_FILE
  sqe.fd = slot
  sqe.`addr` = cast[uint64](addr c.outbuf[c.outOff])
  sqe.len = uint32(c.outbuf.len - c.outOff)
  sqe.rw_flags = uint32(MSG_NOSIGNAL)
  sqe.user_data = makeUd(TAG_SEND, r.id, slot, c.gen)
  c.sendArmed = true
  inc c.pending

proc armSendOrDefer(r: var RingCtx; slot: cint) =
  ## Arm a SEND for freshly produced output, unless that output was produced
  ## while a group-commit batch is open: then the response must wait for COMMIT,
  ## so remember the slot and let `flushDeferredSlots` arm the send afterwards.
  if slot < 0:
    return
  var c = addr r.conns[int(slot)]
  if not c.active or c.sendArmed:
    return
  if c.outOff >= c.outbuf.len:
    return
  if gDb != nil and gDb.batchOpen() and c.batchCount > 0:
    if not c.deferred:
      c.deferred = true
      r.deferredSlots.add (slot: slot, gen: c.gen)
    return
  armSend(r, slot)

proc cancelOp(r: var RingCtx; slot: cint, tag: uint64, gen: uint32): bool =
  ## Cancel an in-flight op by its user_data so the socket's last reference can
  ## be dropped and the fixed slot reused. Returns false when the SQE could not
  ## be reserved; `disarmRecv` then leaves the op armed so a later disarm or
  ## close can retry the cancel.
  let sqe = mustSqe(r)
  if sqe.isNil:
    return false
  sqe.opcode = IORING_OP_ASYNC_CANCEL
  sqe.`addr` = makeUd(tag, r.id, slot, gen)
  sqe.rw_flags = IORING_ASYNC_CANCEL_USERDATA
  sqe.flags = IOSQE_CQE_SKIP_SUCCESS   # fire-and-forget: the target's CQE retires it
  sqe.user_data = makeUd(TAG_CANCEL, r.id, 0, 0)
  return true

proc disarmRecv(r: var RingCtx; slot: cint) =
  ## Stop a still-armed (multishot) recv so it cannot keep delivering data after
  ## the connection paused reading or decided to close. `recvArmed` stays set and
  ## `recvCancelPending` is raised until the recv op's terminal CQE arrives
  ## (`!more`; `-ECANCELED` when the cancel hits). Only then may `armRecv`
  ## submit the next recv. Both ops would otherwise share the slot's user_data
  ## and one `closeConn` cancel could leave the other multishot recv holding the
  ## fixed-file reference. The op stays counted in `pending` until that terminal
  ## completion.
  if slot < 0 or int(slot) >= r.conns.len:
    return
  var c = addr r.conns[int(slot)]
  if c.recvArmed and not c.recvCancelPending:
    if cancelOp(r, slot, TAG_RECV, c.gen):
      c.recvCancelPending = true

proc armTimeout(r: var RingCtx) =
  let sqe = mustSqe(r)
  if sqe.isNil:
    return
  r.ts.tv_sec = int64(TickSeconds)
  r.ts.tv_nsec = 0
  sqe.opcode = IORING_OP_TIMEOUT
  sqe.fd = -1'i32
  sqe.`addr` = cast[uint64](addr r.ts)
  sqe.len = 1'u32
  sqe.off = 0
  sqe.user_data = makeUd(TAG_TIMEOUT, r.id, 0, 0)

# ---------------------------------------------------------------------------
# connection lifecycle

proc closeConn(r: var RingCtx; slot: cint) =
  if slot < 0 or int(slot) >= r.conns.len:
    return
  var c = addr r.conns[int(slot)]
  if not c.active:
    return
  let gen = c.gen
  # Mark the connection dead but KEEP gen, pending, inbuf and outbuf: a SEND
  # cancelled below is only queued for cancellation, so the kernel may still
  # dereference `addr c.outbuf[c.outOff]` until its completion arrives. Keep the
  # slot off the free list (wantFree) until pending hits zero; maybeFreeSlot
  # then resets the Conn and drops the fixed-file entry in one place.
  c.active = false
  c.closing = true
  c.wantFree = true
  # A recv cancel may already be in flight from `disarmRecv`; the pending flag
  # makes this a single cancel for the slot. `recvArmed` stays set until that
  # CANCEL's terminal CQE, so pending cannot be left with an untracked op.
  if c.recvArmed and not c.recvCancelPending:
    if cancelOp(r, slot, TAG_RECV, gen):
      c.recvCancelPending = true
  if c.sendArmed:
    discard cancelOp(r, slot, TAG_SEND, gen)
  maybeFreeSlot(r, slot)

proc finalizeConn(r: var RingCtx; slot: cint) =
  if slot < 0:
    return
  var c = addr r.conns[int(slot)]
  if not c.active:
    return
  if c.closing and not c.sendArmed and c.outOff >= c.outbuf.len:
    closeConn(r, slot)

# ---------------------------------------------------------------------------
# completion handlers

proc initAcceptedSlot(r: var RingCtx; slot: cint) =
  ## Bring a freshly acquired fixed-file slot into service.  Recv storage is
  ## pooled, so there is nothing per-connection to allocate here; the slot's
  ## Conn may still be above the committed length (direct accept), so
  ## materialise it first.
  ensureSlot(r, slot)
  inc r.gen
  r.conns[int(slot)] = Conn(gen: r.gen, st: {cfActive, cfKeepAlive},
                          lastActive: gNow)

proc onAccept(r: var RingCtx; res: cint, more: bool) =
  ## `more` mirrors IORING_CQE_F_MORE: while set, a multishot accept is still
  ## armed and must NOT be re-submitted.  On success `res` is either an OS fd
  ## (register-per-accept path) or a fixed-file SLOT index (direct path).
  if not more:
    r.acceptArmed = false
  if res >= 0:
    var slot: cint
    if r.acceptDirect:
      # Direct accept: the kernel already installed the socket into a free
      # fixed-file slot, and `res` IS that slot. No allocSlot(r), no
      # FILES_UPDATE, no per-accept fd to close. The slot can be beyond the
      # current `r.conns` length, so validate against the TABLE size and commit
      # the slot before reading its Conn.
      slot = cint(res)
      if slot <= 0 or int(slot) >= r.slots:
        stderr.writeLine("io_uring: direct accept returned unusable slot " & $slot)
        if not more:
          armAccept(r)
        return
      ensureSlot(r, slot)
      if r.conns[int(slot)].active:
        stderr.writeLine("io_uring: direct accept returned unusable slot " & $slot)
        discard updateSlotRaw(r, slot, -1'i32)   # drop the kernel-installed file
        if not more:
          armAccept(r)
        return
      r.acceptDirectProven = true
    else:
      slot = allocSlot(r)
      if slot < 0:
        discard posix.close(res)
        r.acceptPaused = true          # retry on the next tick
        return
      if updateSlotRaw(r, slot, res) < 0:
        stderr.writeLine("io_uring: register update failed; dropping accept")
        discard posix.close(res)
        r.freeSlots[r.freeTop] = slot; inc r.freeTop
        if not more:
          armAccept(r)
        return
      # Registered: the fixed table now holds its own reference, so release the
      # process fd immediately (this is the RLIMIT_NOFILE bypass).
      applyTcpTuning(res)
      discard posix.close(res)

    r.acceptMsProven = true
    inc r.accepted
    initAcceptedSlot(r, slot)
    armRecv(r, slot)
    if not more:
      armAccept(r)
  else:
    if res == -EAGAIN or res == -EINTR:
      armAccept(r)
    elif res == -EINVAL or res == -EOPNOTSUPP:
      if r.acceptDirect and r.acceptMultishot and not r.acceptDirectProven:
        # Kernel refuses IORING_FILE_INDEX_ALLOC direct accept: keep multishot
        # but go back to registering each accepted fd into a free slot.
        r.acceptDirect = false
        rebuildFreeList(r)
        stderr.writeLine("io_uring: direct accept (FILE_INDEX_ALLOC) unsupported (" &
                         $res & "); falling back to register-per-accept")
        armAccept(r)
      elif r.acceptMultishot and not r.acceptMsProven:
        # Kernel refuses IORING_ACCEPT_MULTISHOT: degrade to a re-armed one-shot
        # accept. This is the only way to detect it (accept flags are not
        # covered by IORING_REGISTER_PROBE).
        r.acceptMultishot = false
        r.acceptDirect = false
        stderr.writeLine("io_uring: multishot accept unsupported (" & $res &
                         "); falling back to re-armed accept")
        armAccept(r)
      else:
        r.acceptPaused = true
    elif res == -ECANCELED:
      discard
    else:
      # EMFILE/ENFILE/ECONNABORTED/... : back off; the tick revives the accept.
      r.acceptPaused = true

proc onRecv(r: var RingCtx; slot: cint, gen: uint32, res: cint, cflags: uint32) =
  ## One recv completion. In multishot mode the same SQE yields many of these
  ## (each with IORING_CQE_F_MORE); only the terminal one clears `pending`. In
  ## both modes the data lives in a provided buffer whose id is in the high 16
  ## bits of `cflags`, and which is returned to the pool before we leave.
  if slot < 0 or int(slot) >= r.conns.len:
    return
  let hasBuf = (cflags and IORING_CQE_F_BUFFER) != 0'u32
  let more   = (cflags and IORING_CQE_F_MORE) != 0'u32
  var bid = -1
  if hasBuf:
    bid = int((cflags shr uint32(IORING_CQE_BUFFER_SHIFT)) and 0xFFFF'u32)
    poolConsume(r)

  if r.conns[int(slot)].gen != gen:
    # Stale completion for a reused slot: only the buffer needs returning.
    if bid >= 0: poolPush(r, bid)
    return

  var c = addr r.conns[int(slot)]
  if not more:
    # Terminal completion: this recv op is no longer armed and any CANCEL that
    # was serialized in front of a new arm has now reached its terminal state.
    c.recvArmed = false
    c.recvCancelPending = false
    dec c.pending

  if not c.active:
    if bid >= 0: poolPush(r, bid)
    maybeFreeSlot(r, slot)
    return
  c.lastActive = gNow

  if res > 0:
    if c.closing:
      if bid >= 0: poolPush(r, bid)      # discard data for a closing conn
      return
    let n = int(res)
    if bid < 0:
      # IOSQE_BUFFER_SELECT always reports a buffer for data. If it did not,
      # the bytes have no readable source; close instead of pretending.
      c.closing = true
    elif not c.sendArmed:
      # Parse and serve straight from the provided buffer, then return it. The
      # parser borrows only this call's data and every response is already
      # appended to `outbuf`, so nothing outlives the poolPush below.
      let base = cast[ptr UncheckedArray[char]](addr r.bufBase[bid * BufSize])
      let ok = processRecv(r, c[], toOpenArray(base, 0, n - 1))
      poolPush(r, bid)
      if not ok:
        c.closing = true
    else:
      # A SEND is in flight. Touching `outbuf` now could move storage under the
      # kernel's SQE, so carry these bytes in `inbuf` and let onSend parse them
      # once the buffer is drained.
      let old = c.inbuf.len
      c.inbuf.setLen(old + n)
      copyMem(addr c.inbuf[old], addr r.bufBase[bid * BufSize], n)
      inc recvCopiedBuffers
      poolPush(r, bid)
    # Stop reading (do not close) once the buffered remainder passes the request
    # cap so a pipelined burst drains; only a lone oversized request/header is
    # rejected.
    if c.inbuf.len > MaxRequest:
      if findHeaderEnd(c.inbuf) >= 0:
        c.readPaused = true
      else:
        c.closing = true
    if not c.sendArmed:
      if c.inbuf.len <= MaxRequest:
        c.readPaused = false
      # Defer the SEND when this pass opened a write batch (see armSendOrDefer).
      # This must also run for a closing connection: a `Connection: close`
      # request, a malformed request (400) or a partial request followed by EOF
      # still has output that must be flushed before the close.
      armSendOrDefer(r, slot)
    if not c.closing and not c.readPaused:
      armRecv(r, slot)          # no-op while a multishot op is still armed
    elif c.recvArmed:
      disarmRecv(r, slot)
    finalizeConn(r, slot)
    return

  # Non-data completion.
  if bid >= 0: poolPush(r, bid)
  if res == 0:
    # Peer closed its write side: flush what we have, then close. Defer the send
    # if this pass opened a write batch, so the response still waits for COMMIT.
    c.closing = true
    if not c.sendArmed:
      armSendOrDefer(r, slot)
    finalizeConn(r, slot)
    return
  # res < 0
  if res == -ENOBUFS:
    # The pool is momentarily empty. If a buffer is already available, re-arm
    # now; otherwise remember the slot and re-arm once buffers return (end of
    # pass / tick), which prevents a submit-and-immediately-ENOBUFS spin.
    if r.bufsReady > 0:
      armRecv(r, slot)
    else:
      r.recvStarved.add (slot: slot, gen: c.gen)
    return
  if res == -EAGAIN or res == -EINTR:
    armRecv(r, slot)
    return
  if res == -ECANCELED or res == -ENOENT:
    # -ECANCELED is the serialized recv CANCEL's terminal; the `!more` branch
    # above has already cleared recvArmed/recvCancelPending and decremented
    # pending. A cancel MISS is reported as -ENOENT on the TAG_CANCEL
    # completion, and TAG_CANCEL is discarded in dispatch, so -ENOENT on the
    # recv itself is defensive rather than the miss signal. In both cases resume
    # reading only for a live, non-closing connection that is not paused; a
    # paused connection is re-armed by the resume path (onSend) once readPaused
    # clears.
    if c.active and not c.closing and not c.readPaused:
      armRecv(r, slot)
    return
  c.closing = true
  if not c.sendArmed:
    armSendOrDefer(r, slot)   # wait for COMMIT if a write batch is open
  finalizeConn(r, slot)

proc onSend(r: var RingCtx; slot: cint, gen: uint32, res: cint) =
  if slot < 0 or int(slot) >= r.conns.len:
    return
  if r.conns[int(slot)].gen != gen:
    return
  dec r.conns[int(slot)].pending
  if not r.conns[int(slot)].active:
    maybeFreeSlot(r, slot)
    return
  var c = addr r.conns[int(slot)]
  c.sendArmed = false
  c.lastActive = gNow

  if res > 0:
    c.outOff += int(res)
  else:
    if res == -EAGAIN:
      armSend(r, slot)
      return
    if res == -ENOBUFS:
      # Transient kernel allocation failure: retry on the next tick rather than
      # spin, so the response is recovered instead of the connection dropped.
      c.sendArmed = false
      r.sendRetry.add (slot: slot, gen: c.gen)
      return
    if res == -ECANCELED or res == -ENOENT:
      return
    closeConn(r, slot)
    return

  if c.outOff >= c.outbuf.len:
    # Answer any request that arrived while the previous response was in flight.
    # `processRequests` may append to (and reuse) the buffer already owned here,
    # so the buffer is only dropped after that.
    if not c.closing and c.inbuf.len > 0:
      if not processRequests(r, c[]):
        c.closing = true
      if c.inbuf.len <= MaxRequest:
        c.readPaused = false
      # Defer the SEND when this pass opened a write batch (see armSendOrDefer).
      armSendOrDefer(r, slot)
    if c.closing and not c.sendArmed and c.outOff >= c.outbuf.len:
      closeConn(r, slot)
      return
    # Fully drained and nothing new was queued: return the buffer to the pool
    # (guarded against a deferred/batched response or an armed SEND).
    maybeReleaseOutBuf(r, c[])
    if not c.closing and not c.readPaused:
      armRecv(r, slot)
  else:
    armSend(r, slot)   # partial send: push the remainder

proc sweep(r: var RingCtx)   # forward declaration (defined below)

proc onTimeout(r: var RingCtx) =
  # Idle/stall sweep moved here from the per-pass hot path: walking every
  # registered slot on each completion batch was pure overhead; the 1 s timer
  # is the natural sweep cadence.
  sweep(r)
  if gZeroCopyStats:
    # Diagnostic only, once per 1 s tick (never on the recv fast path), so the
    # counters are observable without an allocation per request or an endpoint.
    stderr.writeLine("zerocopy stats: direct_requests=" & $recvDirectRequests &
                     " copied_buffers=" & $recvCopiedBuffers)
  # Retry sends that hit a transient -ENOBUFS (never dropped, never spun on).
  # A deferred slot is deliberately excluded: its output contains a response
  # produced by an open group-commit batch, and the only safe arming point is
  # `flushDeferredSlots` after COMMIT. Arming it here would either put
  # uncommitted success bytes on the wire or let a failed commit rewrite the
  # buffer (`setLen`/`addResponse`) while the SQE holds `addr c.outbuf[c.outOff]`.
  if r.sendRetry.len > 0:
    let pend = r.sendRetry
    r.sendRetry.setLen(0)
    for sr in pend:
      let slot = sr.slot
      if slot >= 0 and int(slot) < r.conns.len:
        var c = addr r.conns[int(slot)]
        if c.gen == sr.gen and c.active and not c.sendArmed and
           not c.deferred and c.outOff < c.outbuf.len:
          armSend(r, slot)
  # Re-arm recvs starved of provided buffers.
  if r.recvStarved.len > 0 and r.bufsReady > 0:
    rearmStarved(r)
  if r.acceptPaused:
    r.acceptPaused = false
    armAccept(r)
  elif not r.acceptArmed:
    armAccept(r)
  armTimeout(r)
  # Multi-ring fairness is measured, not predicted: SO_REUSEPORT hashes each
  # connection by 4-tuple, so the split can be uneven. One cheap line per ring
  # every 10 ticks (10 s) is the whole cost, and only on the N>1 path.
  if r.multiRing:
    inc r.ticks
    if r.ticks mod 10 == 0:
      var live = 0
      for i in 1 ..< r.conns.len:
        if r.conns[i].active: inc live
      stderr.writeLine("io_uring ring " & $r.id & ": accepted=" & $r.accepted &
                       " live=" & $live & " slots=" & $r.slots)

# ---------------------------------------------------------------------------
# idle / stall sweep

proc sweep(r: var RingCtx) =
  ## Slots at or above `r.conns.len` were never handed out, so they cannot hold a
  ## live connection and need no work. Slot 0 is the listener, never a Conn.
  for slot in 1 ..< r.conns.len:
    if r.conns[slot].active:
      let pendingOut = r.conns[slot].sendArmed or
                       r.conns[slot].outOff < r.conns[slot].outbuf.len
      let midReq = r.conns[slot].inbuf.len > 0
      let limit = if pendingOut or midReq: StallTimeout else: IdleKeepAlive
      if gNow - r.conns[slot].lastActive > limit:
        closeConn(r, cint(slot))

# ---------------------------------------------------------------------------
# reaping

proc onClose(r: var RingCtx; slot: cint; res: cint) =
  ## Only failures reach here: a successful fixed CLOSE carries
  ## IOSQE_CQE_SKIP_SUCCESS. The kernel did not free the slot, so drop the
  ## still-registered descriptor with the register-update fallback; otherwise a
  ## direct accept could never reuse it.
  if res >= 0 or slot < 0 or int(slot) >= r.slots:
    return
  let rc = updateSlotRaw(r, slot, -1'i32)
  stderr.writeLine("io_uring: fixed close failed for slot " & $slot &
                   " res=" & $res & " (fallback rc=" & $rc & ")")

proc onProvide(r: var RingCtx; gen: uint32; res: cint) =
  ## Only failures reach here: a successful PROVIDE_BUFFERS is skipped. The
  ## buffer(s) never entered the kernel's buffer group, so undo the optimistic
  ## `bufsReady` count (gen=1: one buffer from poolPush; gen=0: the bulk fill).
  if res >= 0:
    return
  if gen == 1'u32:
    if r.bufsReady > 0: dec r.bufsReady
  else:
    r.bufsReady = 0
  stderr.writeLine("io_uring: PROVIDE_BUFFERS failed res=" & $res)

proc dispatch(r: var RingCtx; ud: uint64, res: cint, cflags: uint32) =
  ## A ring only ever sees completions for its own submissions, but the ring id
  ## is explicit in user_data so a mis-routed CQE can never touch another ring's
  ## slot table (dispatch routes by this field).
  if udRing(ud) != r.id:
    return
  case udTag(ud)
  of TAG_ACCEPT:  onAccept(r, res, (cflags and IORING_CQE_F_MORE) != 0'u32)
  of TAG_RECV:    onRecv(r, udSlot(ud), udGen(ud), res, cflags)
  of TAG_SEND:    onSend(r, udSlot(ud), udGen(ud), res)
  of TAG_TIMEOUT: onTimeout(r)
  of TAG_CLOSE:   onClose(r, udSlot(ud), res)
  of TAG_PROVIDE: onProvide(r, udGen(ud), res)
  of TAG_CANCEL:
    # Success is skipped. -ENOENT is a normal miss (the target already
    # completed); anything else is worth surfacing.
    if res != 0 and res != -ENOENT:
      stderr.writeLine("io_uring: async cancel failed res=" & $res)
  else:           discard

proc flushDeferredSlots(r: var RingCtx; commitOk: bool) =
  ## Release the SENDs withheld during this pass, once the pass's batch has been
  ## committed (or has failed). On a failed COMMIT every response produced against
  ## the rolled-back batch is replaced by a 500, so no success byte for an
  ## uncommitted write can reach the socket.
  for sr in r.deferredSlots:
    let slot = sr.slot
    if slot < 0 or int(slot) >= r.conns.len:
      continue
    var c = addr r.conns[int(slot)]
    if c.gen != sr.gen:
      continue                      # slot reused by another connection: stale
    c.deferred = false
    if not c.active:
      continue
    if not commitOk and c.batchCount > 0:
      # Never touch outbuf while a SEND is in flight: the kernel holds
      # `addr c.outbuf[c.outOff]`, so setLen/add would reallocate the storage out
      # from under the op (use-after-free). A deferred slot is only queued while
      # no send is armed, so the UAF cannot occur here.
      c.outbuf.setLen(c.batchFrom)
      for _ in 0 ..< c.batchCount:
        c.outbuf.addResponse(500, """{"error":"internal server error"}""",
                             c.keepAlive)
      c.closing = true
    c.batchFrom = 0
    c.batchCount = 0
    if c.outOff < c.outbuf.len:
      armSend(r, slot)
    if c.closing and not c.sendArmed and c.outOff >= c.outbuf.len:
      closeConn(r, slot)
  r.deferredSlots.setLen(0)

proc drainCompletions(r: var RingCtx): int =
  ## Drain the *entire* completion queue of one ring and return how many CQEs
  ## were handled. Never blocks. If the kernel reports IORING_SQ_CQ_OVERFLOW it
  ## parked completions that did not fit in the CQ ring on its internal overflow
  ## list; re-enter (non-blocking GETEVENTS) to move them into the space we just
  ## freed, then drain again, until the flag clears. The flag is only set when
  ## the CQ actually filled, so the common case costs one `sqOverflowed()` read.
  result = 0
  while true:
    # Consume kernel-visible CQEs with a local cursor and publish the advanced
    # head ONCE per drained batch. The kernel cannot overwrite an entry until
    # head passes it, so the cursor is safe for the whole batch (and a handler
    # that enters mid-batch only makes the tail advance).
    let start = r.ring.cqHead()
    var head = start
    while true:
      let tail = r.ring.cqTail()
      if head == tail:
        break
      let cqe = r.ring.cqeAt(head)
      let ud = cqe.user_data
      let res = cqe.res
      let fl = cqe.flags
      inc head
      inc result
      try:
        dispatch(r, ud, res, fl)
      except IoRingError as ex:
        # `mustSqe` inside a handler can fail (e.g. a transient enter error).
        # That must not take the whole transport down: the ring itself is still
        # usable, so log the failed operation and keep draining.
        stderr.writeLine("io_uring dispatch error: " & ex.msg)
    if head != start:
      r.ring.cqeSeenMany(head - start)
    # Publish buffers returned during this batch before anything can enter.
    flushBufTail(r)
    if not r.ring.sqOverflowed():
      break
    # CQ overflowed: nudge the kernel to flush the overflow list into the
    # CQ space freed above, then drain those completions too.
    try:
      discard r.ring.enterGetEvents()
    except IoRingError as ex:
      if ex.errCode == EINTR:
        continue
      stderr.writeLine("io_uring_enter failed: " & ex.msg)
      quit(1)

proc runLoop(r: var RingCtx) =
  ## One thread, one ring. Per pass we drain the *entire* completion queue in a
  ## single loop, do the send-side work, then loop. The end-of-pass submit is
  ## deliberately omitted: the wait at the top of the next iteration flushes
  ## every SQE reserved during the drain, so the steady-state hot loop costs
  ## exactly ONE io_uring_enter per pass (plus whatever `mustSqe(r)` is forced to
  ## flush if the SQ genuinely fills mid-drain).
  ##
  ## The wait is the blocking GETEVENTS enter, so the loop sleeps until a
  ## completion is ready.  Under sustained load (the previous pass drained at
  ## least `BatchLoadThreshold` completions) it waits for a small batch with a
  ## 100 us cap instead, which amortises the enter syscall without delaying a
  ## backlog: `min_complete` counts CQEs already in the ring, and an already
  ## queued completion is drained on the immediate single-completion path.  The
  ## armed 1 s tick CQE still bounds the idle wakeup, and the completion queue is
  ## drained whole, so the tick CQE is processed exactly as before and the
  ## idle/stall sweep keeps its cadence.
  ##
  ## This is the N=1 path; `runMultiLoop` is the only other waiter, and it
  ## never calls into this proc.
  var batchLoaded = false   # previous pass drained a sustained load batch
  armAccept(r)
  armTimeout(r)

  while true:
    try:
      if batchLoaded and r.ring.peekCqe().isNil:
        # Sustained load: collect a small batch (bounded by 100 us).  If a
        # backlog is already queued, `min_complete` is satisfied by those CQEs
        # and the enter returns without sleeping.
        discard r.ring.submitAndWaitBatch(BatchMinComplete, BatchMaxUsec)
      else:
        # Idle (or completions already waiting): block for one completion.
        discard r.ring.submitAndWait(1)   # flush reserved SQEs + block for >=1 CQE
    except IoRingError as ex:
      if ex.errCode == EINTR:
        continue
      stderr.writeLine("io_uring_enter failed: " & ex.msg)
      quit(1)

    gNow = epochTime()
    r.consumedThisPass = 0
    let drained = drainCompletions(r)

    # A pass that drained a real batch means demand is sustained, so the next
    # wait may collect a batch; a light or empty pass returns to the blocking
    # single-completion wait immediately (including the 1 s tick wakeup).
    batchLoaded = drained >= BatchLoadThreshold

    # End of one completion-queue pass: commit the pass's write batch (if any)
    # and only then arm the SENDs withheld for it (rule 6: durable before send).
    if gDb != nil and gDb.batchOpen():
      flushDeferredSlots(r, gDb.commitBatch())

    # End the pass's read snapshot HERE: after the write commit (which already
    # ended it for a read->write pass). A read transaction must never survive a
    # pass, otherwise the connection would keep reading a stale snapshot and the
    # checkpointer could not backfill the frames it still covers.
    #
    # The WAL checkpoint is NOT run here. It lives on its own connection/thread
    # (started below) and is driven by the WAL hook, so this loop never performs
    # checkpoint I/O: no page copy and no fsync on the request thread.
    if gDb != nil and not gDb.endRead():
      stderr.writeLine("db: COMMIT of the pass read transaction failed")

    # Buffers returned during this pass may have un-starved recvs that hit
    # -ENOBUFS earlier in the same pass.
    if r.recvStarved.len > 0 and r.consumedThisPass > 0 and r.bufsReady > 0:
      rearmStarved(r)

# ---------------------------------------------------------------------------
# setup

proc groupCommitEnabled(): bool =
  ## GROUP_COMMIT defaults ON; only "0" (or unparseable -> default) is treated
  ## as a disable request, matching envIntDef semantics.
  try:
    result = parseInt(getEnv("GROUP_COMMIT", "1")) != 0
  except ValueError:
    result = true

proc envIsOneshot(name: string): bool =
  ## IOURING_RECV / IOURING_ACCEPT: default "multishot"; anything else (notably
  ## "oneshot") selects the conservative one-shot path.
  getEnv(name, "multishot").toLowerAscii == "oneshot"

proc initPool(r: var RingCtx; defaultSlots: int) =
  ## Allocate this ring's provided-buffer pool and publish it to the kernel.
  ## The data region is one lazily-faulted `alloc`: untouched pages stay out of
  ## RSS, and because buffers are only taken while bytes are in flight, the
  ## resident cost tracks peak concurrent receives rather than connection count.
  # Live pool size (IOURING_BUFS, default `defaultSlots`): rounded down to a
  # power of two and clamped, so the buf-ring requirement always holds. Exposed
  # so the -ENOBUFS path can be exercised (a tiny pool) without a rebuild. The
  # caller passes BufRingDefault for one ring and the per-ring share of
  # MultiBufBudget for N rings.
  var want = defaultSlots
  try:
    want = parseInt(getEnv("IOURING_BUFS", $defaultSlots))
  except ValueError:
    want = defaultSlots
  if want < 64: want = 64
  if want > BufRingMax: want = BufRingMax
  var p2 = 1
  while p2 * 2 <= want: p2 *= 2
  r.bufSlots = p2
  r.bufMask = p2 - 1

  let bytes = r.bufSlots * BufSize
  r.bufBase = cast[ptr UncheckedArray[char]](alloc(bytes))
  if r.bufBase.isNil:
    stderr.writeLine("io_uring: buffer pool alloc failed (" & $bytes & " bytes)")
    quit(1)

  # The descriptor ring must be page aligned; mmap gives us that for free.
  let ringBytes = r.bufSlots * sizeof(BufRingEntry)
  let p = posix.mmap(nil, ringBytes, PROT_READ or PROT_WRITE,
                     MAP_PRIVATE or MAP_ANONYMOUS, -1, Off(0))
  if p.isNil or p == MAP_FAILED:
    stderr.writeLine("io_uring: buf-ring mmap failed (" & $ringBytes & " bytes)")
    quit(1)
  r.bufRing = cast[ptr UncheckedArray[BufRingEntry]](p)

  # IOURING_BUFRING=0 forces the IORING_OP_PROVIDE_BUFFERS path (for testing the
  # degradation); otherwise we try the registered ring and fall back on failure.
  if getEnv("IOURING_BUFRING", "1") == "0":
    r.useBufRing = false
    stderr.writeLine("io_uring: IOURING_BUFRING=0; using IORING_OP_PROVIDE_BUFFERS")
  else:
    try:
      discard r.ring.registerBufRing(p, uint32(r.bufSlots), BufGroup)
      r.useBufRing = true
    except IoRingError as ex:
      r.useBufRing = false
      stderr.writeLine("io_uring: PBUF_RING unavailable (" & ex.msg &
                       "); falling back to IORING_OP_PROVIDE_BUFFERS")

  r.bufTail = 0
  r.bufTailPending = false
  r.bufsReady = 0
  if r.useBufRing:
    for bid in 0 ..< r.bufSlots:
      poolPush(r, bid)
    flushBufTail(r)               # one tail publish for the whole initial fill
  else:
    # One SQE hands the whole list to buffer group BufGroup, ids 0..N-1.
    let sqe = mustSqe(r)
    if sqe.isNil:
      stderr.writeLine("io_uring: could not submit PROVIDE_BUFFERS")
      quit(1)
    prepProvideBuffers(sqe, cast[uint64](addr r.bufBase[0]), uint32(BufSize),
                       uint32(r.bufSlots), 0'u16, BufGroup)
    sqe.flags = IOSQE_CQE_SKIP_SUCCESS
    # gen=0 marks the bulk provide (poolPush uses gen=1 for a single buffer).
    sqe.user_data = makeUd(TAG_PROVIDE, r.id, 0, 0)
    r.bufsReady = r.bufSlots
    discard r.ring.submit()

  stderr.writeLine((if r.multiRing: "[ring " & $r.id & "] " else: "") &
                   "io_uring pool: " & $r.bufSlots & " x " & $BufSize &
                   " B (" & $(bytes div (1024 * 1024)) & " MiB, " &
                   (if r.useBufRing: "registered buf_ring"
                    else: "provide_buffers list") & ")")

# ---------------------------------------------------------------------------
# Startup failure policy.
#
# A rejected setup-flag set, a refused multishot/direct accept and an
# unavailable buf_ring degrade in place with the server staying up. Multishot
# recv is different: it has no runtime fallback. A kernel without
# IORING_RECV_MULTISHOT fails the recv, which reaches onRecv's terminal-error
# path (the connection is closed); the operator must start with
# IOURING_RECV=oneshot on such a kernel. The only unrecoverable case is a
# failure that leaves the transport itself unavailable:
# `io_uring_setup` rejecting the ring (-ENOSYS on a kernel/VM without io_uring,
# -EPERM under seccomp, -ENOMEM for the ring) or the fixed-file registration
# being refused even at the floor. There is exactly one transport, so there is
# no alternative to hand off to: log a clear message and exit non-zero, so the
# failure is immediate and observable rather than a silently degraded server.
proc hardFail(reason: string) {.noreturn.} =
  stderr.writeLine("fatal: io_uring transport unavailable (" & reason &
                   "); no fallback transport is built in")
  quit(1)

# ---------------------------------------------------------------------------
# multi-ring event loop (N > 1)
#
# One request thread owns every ring, so SINGLE_ISSUER / COOP_TASKRUN stay
# valid (they bind a ring to its creating task, not to one ring per process).
# No ring is ever entered with a blocking wait while another ring could have
# completions.
#
# DEFER_TASKRUN is deliberately NOT requested for N>1. Deferred task work only
# runs inside io_uring_enter, and the wake source this loop has to sleep on is
# the shared eventfd (one IORING_REGISTER_EVENTFD per ring, one epoll set over
# the fd). That eventfd is signalled from the completion commit, which under
# DEFER_TASKRUN is precisely the work parked until someone enters: at low load
# the loop drained the counter, slept in epoll_wait(-1), and nothing ever
# entered again. The first ring's completions could be parked with cq head ==
# tail and no eventfd signal, so neither the armed 1 s tick nor a new request
# woke the loop (measured: ~60-124 requests then do_epoll_wait forever;
# /health hung). Without DEFER_TASKRUN completions commit (and signal the eventfd)
# from the context that completes them, so the wait is self-sustaining. N=1
# keeps DEFER_TASKRUN: its loop calls submitAndWait itself, which is the enter
# that runs the deferred work. If the kernel rejects the multi flags,
# setupQueue's existing bare retry applies.
#
# On every wake the loop drains the eventfd counter, then runs a non-blocking
# io_uring_enter(GETEVENTS, min_complete=0) on EVERY ring to flush reserved
# SQEs and any CQ overflow, then drainCompletions walks each ring. No busy-spin:
# with no work the only wake is each ring's own 1 s tick, and a completion that
# lands after the counter read bumps the eventfd again and wakes the next
# epoll_wait.
proc runMultiLoop(rings: var seq[RingCtx]) =
  let ep = epoll_create1(0)
  if ep < 0:
    hardFail("epoll_create1 failed: errno=" & $(osLastError().int))

  # One shared eventfd, registered on every ring. The kernel bumps its counter
  # once per completion event; a single read both observes and clears it.
  var wakeFd = c_eventfd(0'u32, cint(EFD_NONBLOCK or EFD_CLOEXEC))
  if wakeFd < 0:
    hardFail("eventfd failed: errno=" & $(osLastError().int))
  for i in 0 ..< rings.len:
    let rc = c_syscall(SYS_io_uring_register, clong(rings[i].ring.fd),
                       clong(IORING_REGISTER_EVENTFD),
                       clong(cast[uint](addr wakeFd)), clong(1))
    if rc < 0:
      hardFail("IORING_REGISTER_EVENTFD ring " & $i & " failed: errno=" &
               $(osLastError().int))
    armAccept(rings[i])
    armTimeout(rings[i])

  var ev: EpollEvent
  ev.events = EPOLLIN
  ev.data.fd = wakeFd
  if epoll_ctl(ep, EPOLL_CTL_ADD, wakeFd, addr ev) != 0:
    hardFail("epoll_ctl(ADD) eventfd failed: errno=" & $(osLastError().int))

  var event: EpollEvent
  while true:
    # Flush SQEs reserved during the previous drain. submit() is the
    # non-blocking enter (min_complete=0) and cannot stall another ring.
    for i in 0 ..< rings.len:
      if rings[i].ring.toSubmit > 0:
        try:
          discard rings[i].ring.submit()
        except IoRingError as ex:
          if ex.errCode == EINTR:
            continue
          stderr.writeLine("io_uring_enter failed: " & ex.msg)
          quit(1)

    let n = epoll_wait(ep, addr event, 1, -1)
    if n < 0 and osLastError().int != EINTR:
      stderr.writeLine("epoll_wait failed: errno=" & $(osLastError().int))
      quit(1)

    # Clear the shared counter. A completion that lands after this read bumps
    # it again and wakes the next epoll_wait, so the wake is never lost.
    var counter: uint64
    while posix.read(wakeFd, addr counter, 8) == 8:
      discard

    # Run deferred task work / flush reservations on every ring. This is a
    # non-blocking enter: min_complete == 0, so a ring with nothing ready
    # returns immediately and the pass drains all rings in a fixed order.
    for i in 0 ..< rings.len:
      try:
        discard rings[i].ring.enterGetEvents()
      except IoRingError as ex:
        if ex.errCode == EINTR:
          continue
        stderr.writeLine("io_uring_enter failed: " & ex.msg)
        quit(1)

    gNow = epochTime()
    for i in 0 ..< rings.len:
      rings[i].consumedThisPass = 0
      discard drainCompletions(rings[i])

    # ONE pass boundary for the whole process: the group-commit batch opened by
    # any ring's request is committed once, then every ring's deferred SENDs
    # are armed with the same commit result (rule 6: durable before send). A
    # read transaction opened by any ring also ends here, exactly like N=1.
    if gDb != nil and gDb.batchOpen():
      let commitOk = gDb.commitBatch()
      for i in 0 ..< rings.len:
        flushDeferredSlots(rings[i], commitOk)
    if gDb != nil and not gDb.endRead():
      stderr.writeLine("db: COMMIT of the pass read transaction failed")

    # The checkpointer runs on its own connection/thread; the process-wide
    # pass boundary performs no checkpoint I/O.
    # Buffers returned during this pass may have un-starved recvs that hit
    # -ENOBUFS earlier in the same pass. Per ring: the pools are not shared.
    for i in 0 ..< rings.len:
      if rings[i].recvStarved.len > 0 and rings[i].consumedThisPass > 0 and
         rings[i].bufsReady > 0:
        rearmStarved(rings[i])

# ---------------------------------------------------------------------------
# ring sizing

proc readConntrackMax(): int =
  ## /proc/sys/net/netfilter/nf_conntrack_max, or 0 when conntrack is not
  ## available. 0 means "cannot prove capacity beyond one ring", so auto-size
  ## stays at one ring.
  try:
    result = parseInt(readFile("/proc/sys/net/netfilter/nf_conntrack_max").strip())
    if result < 0: result = 0
  except CatchableError:
    result = 0

proc autoBufferSlots(rings: int): int =
  ## Per-ring share of the bounded global provided-buffer budget, rounded down
  ## to a power of two. initPool clamps it to [64, BufRingMax] afterwards. N=1
  ## uses BufRingDefault for the single-ring path.
  if rings <= 1:
    return BufRingDefault
  var want = MultiBufBudget div rings
  if want < 64: want = 64
  result = 1
  while result * 2 <= want:
    result *= 2

proc planRings(hardNofile: int):
    tuple[rings, slotsPerRing, conntrackMax: int;
          slotsForced, ringsForced: bool] =
  ##   slotsPerRing = min(hardNofile - FdsReserve, 65,535)
  ##   target       = min(conntrackMax - ConntrackHeadroom, MaxConns)
  ##   rings        = clamp(ceil(target / slotsPerRing), 1, 5)
  ##
  ## With the current 64k conntrack cap the target (64,512) fits in one
  ## 65,535-slot table, so the default configuration is exactly one ring.
  ## NIM_SLOTS_PER_RING / NIM_RINGS are the only overrides (used by the
  ## multi-ring smoke test); they are clamped, and each falls back to its
  ## automatic value when unset/bad.
  var slots = min(hardNofile - FdsReserve, MaxSlotsPerRing)
  if slots < SlotsFloor:
    slots = SlotsFloor
  let envSlots = envIntDef("NIM_SLOTS_PER_RING", 0)
  result.slotsForced = envSlots > 0
  if result.slotsForced:
    slots = min(max(envSlots, SlotsFloor), MaxSlotsPerRing)
  result.slotsPerRing = slots

  let ct = readConntrackMax()
  result.conntrackMax = ct
  let envRings = envIntDef("NIM_RINGS", 0)
  result.ringsForced = envRings > 0
  if result.ringsForced:
    result.rings = min(max(envRings, 1), MaxRings)
  else:
    let target =
      if ct > 0: min(max(ct - ConntrackHeadroom, 0), MaxConns)
      else: slots
    let want = if target <= 0: 1 else: (target + slots - 1) div slots
    result.rings = min(max(want, 1), MaxRings)

const
  # SINGLE_ISSUER | DEFER_TASKRUN | COOP_TASKRUN | NO_SQARRAY: the recommended
  # setup for a single-threaded, per-thread ring. Completion (task) work is
  # deferred to io_uring_enter, which runLoop calls every pass; NO_SQARRAY drops
  # the sq_array indirection (SQE index == tail & mask). A kernel that rejects
  # NO_SQARRAY loses only that flag (setupQueue strips it first); any remaining
  # rejected flag set is retried bare, so startup never fails on a hint.
  #
  # The N>1 loop must NOT defer task work: its only wake source is the shared
  # eventfd, which is signalled when a completion is committed - the very work
  # DEFER_TASKRUN parks until an enter that will never happen. Multi rings
  # therefore keep SINGLE_ISSUER | COOP_TASKRUN (plus NO_SQARRAY) and drop
  # DEFER_TASKRUN; every ring is still created and entered by the same request
  # thread.
  SingleRingSetupFlags = IORING_SETUP_SINGLE_ISSUER or
                         IORING_SETUP_DEFER_TASKRUN or
                         IORING_SETUP_COOP_TASKRUN or
                         IORING_SETUP_NO_SQARRAY
  MultiRingSetupFlags  = IORING_SETUP_SINGLE_ISSUER or
                         IORING_SETUP_COOP_TASKRUN or
                         IORING_SETUP_NO_SQARRAY

proc setupFlagNames(flags: uint32): string =
  var parts: seq[string]
  if (flags and IORING_SETUP_SINGLE_ISSUER) != 0'u32: parts.add "SINGLE_ISSUER"
  if (flags and IORING_SETUP_DEFER_TASKRUN) != 0'u32: parts.add "DEFER_TASKRUN"
  if (flags and IORING_SETUP_COOP_TASKRUN) != 0'u32: parts.add "COOP_TASKRUN"
  if (flags and IORING_SETUP_NO_SQARRAY) != 0'u32: parts.add "NO_SQARRAY"
  if parts.len == 0: "bare" else: parts.join("|")

proc setupRingRetry(flags: uint32): Ring =
  ## io_uring_setup allocates the SQE/CQ pages in the kernel; under transient
  ## host memory pressure it can return -ENOMEM even though the same request
  ## succeeds moments later. Retry briefly so a startup that races a co-tenant
  ## build does not abort. Any other errno, or sustained ENOMEM, is still fatal
  ## (the caller hard-fails, exactly as before).
  var tries = 0
  while true:
    try:
      return setupQueue(RingEntries, flags,
                        cuint(RingEntries * CqMultiple))
    except IoRingError as ex:
      if ex.errCode == ENOMEM and tries < 40:
        inc tries
        sleep(50)
        continue
      raise

proc main() =
  let cfg = loadConfig()
  gSecret = cfg.jwtSecret
  gZeroCopyStats = getEnv("ZEROCOPY_STATS", "0") == "1"

  discard posix.signal(SIGPIPE, SIG_IGN)

  # Turbo toggles are identical for every ring: multishot by default, one env
  # var away from the safe path. Direct accept (kernel-installed fixed slots)
  # defaults ON; IOURING_ACCEPT_DIRECT=0 forces register-per-accept.
  let recvMultishot = not envIsOneshot("IOURING_RECV")
  let acceptMultishot = not envIsOneshot("IOURING_ACCEPT")
  var acceptDirect = getEnv("IOURING_ACCEPT_DIRECT", "1") != "0"
  # Direct accept installs the socket kernel-side, so no userspace fd exists to
  # run applyTcpTuning on it. If per-connection TCP tuning is requested, fall
  # back to register-per-accept so the accepted fd is available.
  if not acceptMultishot or tcpNotsentLowatBytes() > 0 or tcpQuickAck():
    acceptDirect = false

  # Raise the fd ceiling BEFORE registering any fixed-file table (see
  # raiseNofile). The hard limit it returns sizes each ring's table below.
  let hardNofile = raiseNofile()
  let plan = planRings(hardNofile)
  stderr.writeLine("io_uring sizing: hard_nofile=" & $hardNofile &
                   " conntrack_max=" & $plan.conntrackMax &
                   " slots_per_ring=" & $plan.slotsPerRing &
                   " rings=" & $plan.rings &
                   (if plan.slotsForced: " (NIM_SLOTS_PER_RING)" else: "") &
                   (if plan.ringsForced: " (NIM_RINGS)" else: ""))

  # ---- rings --------------------------------------------------------------
  # Every ring is created by THIS thread: SINGLE_ISSUER (and, for N=1,
  # DEFER_TASKRUN) bind a ring to its creating task, and multi-ring mode
  # deliberately stays one request thread (the benchmark box is 1 vCPU; rings
  # add connection capacity, not CPU parallelism).
  gRings = newSeq[RingCtx](plan.rings)
  let multi = plan.rings > 1
  # N=1 keeps DEFER_TASKRUN (runLoop enters to run the deferred work); N>1
  # drops it because runMultiLoop waits on an eventfd that only the completion
  # commit can signal (see runMultiLoop).
  let setupFlags = if multi: MultiRingSetupFlags else: SingleRingSetupFlags
  let bufSlots = autoBufferSlots(plan.rings)
  for i in 0 ..< gRings.len:
    let pfx = if multi: "[ring " & $i & "] " else: ""
    gRings[i].id = uint8(i)
    gRings[i].slots = plan.slotsPerRing
    gRings[i].multiRing = multi
    gRings[i].recvMultishot = recvMultishot
    gRings[i].acceptMultishot = acceptMultishot
    gRings[i].acceptDirect = acceptDirect

    try:
      gRings[i].ring = setupRingRetry(setupFlags)
    except IoRingError as ex:
      # Unrecoverable: the ring itself is unavailable.
      hardFail(ex.msg)
    if gRings[i].ring.flagsDropped:
      stderr.writeLine(pfx & "io_uring setup: flags 0x" &
                       toHex(gRings[i].ring.requestedFlags) &
                       " rejected; running WITHOUT optimisation flags (bare)")
    else:
      if (gRings[i].ring.requestedFlags and IORING_SETUP_NO_SQARRAY) != 0'u32 and
         (gRings[i].ring.usedFlags and IORING_SETUP_NO_SQARRAY) == 0'u32:
        stderr.writeLine(pfx & "io_uring setup: NO_SQARRAY rejected; using sq_array")
      stderr.writeLine(pfx & "io_uring setup: flags 0x" &
                       toHex(gRings[i].ring.usedFlags) & " in effect (" &
                       setupFlagNames(gRings[i].ring.usedFlags) & ")")

    # CQ headroom, observed from the kernel (not assumed): the params the kernel
    # filled in report the SQ/CQ ring sizes it actually allocated.
    stderr.writeLine(pfx & "io_uring ring: sq_entries=" &
                     $gRings[i].ring.params.sq_entries &
                     " cq_entries=" & $gRings[i].ring.params.cq_entries &
                     " (CQSIZE request=" & $(RingEntries * CqMultiple) &
                     ", kernel default=2x sq=" & $(RingEntries * 2) & ")")

    # ---- the provided-buffer pool -----------------------------------------
    initPool(gRings[i], bufSlots)

    # ---- listener ---------------------------------------------------------
    # deferSec=1 enables TCP_DEFER_ACCEPT: the kernel holds a completed
    # handshake back from accept until the client's first byte arrives, so a
    # silent/impatient connect never wakes the loop. In multi-ring mode every
    # ring gets its own SO_REUSEPORT listener on the same host:port; the kernel
    # spreads new connections across them.
    gRings[i].listenerFd = setupListenSocket(cfg.host, cfg.port, ListenBacklog,
                                             1, reusePort = multi)
    if gRings[i].listenerFd < 0:
      quit(1)

    # ---- register the fixed-file table: slot 0 = listener, rest empty ------
    # `slots` was sized from RLIMIT_NOFILE above, but the kernel can still
    # refuse the top value (e.g. -EMFILE/-EINVAL). Do NOT quit at the first
    # failure and do NOT halve (halving is how you land back on the removed
    # 32768 cap): walk the size DOWN in small steps until the kernel accepts it,
    # never below `SlotsFloor`. Only if even the floor is refused is the
    # transport unusable. Each ring shrinks independently: total capacity is
    # the sum of the tables that were actually accepted.
    while true:
      var fds = newSeq[cint](gRings[i].slots)
      for j in 0 ..< gRings[i].slots:
        fds[j] = -1'i32
      fds[0] = gRings[i].listenerFd
      try:
        discard gRings[i].ring.registerFiles(fds)
        stderr.writeLine(pfx & "fixed-file table registered: fixed_file_slots=" &
                         $gRings[i].slots)
        break
      except IoRingError as ex:
        stderr.writeLine(pfx & "IORING_REGISTER_FILES(" & $gRings[i].slots &
                         ") failed: " & ex.msg)
        if gRings[i].slots <= SlotsFloor:
          # Nothing left to give up; the fixed-file transport is unusable here.
          hardFail("IORING_REGISTER_FILES failed at floor " & $SlotsFloor)
        # Small step DOWN (~1.5% or 1024 entries, whichever shrinks more).
        let shrink = max(gRings[i].slots div 64, 1024)
        gRings[i].slots = max(SlotsFloor, gRings[i].slots - shrink)
    # The registered reference keeps the listening socket alive, so the process
    # fd can be released: accepts then address it as fixed slot 0.
    discard posix.close(gRings[i].listenerFd)

    # ---- slot pools -------------------------------------------------------
    # Reserve the full fixed-file-table capacity once, but commit length only
    # as slots are actually used: RSS follows live connections instead of
    # paying the whole slots * sizeof(Conn) at startup. Slot 0 is the listener
    # and is never a Conn, so the length starts at 1 and nextSlot at 1.
    gRings[i].conns = newSeqOfCap[Conn](gRings[i].slots)
    gRings[i].conns.setLen(1)
    assert gRings[i].conns.capacity >= gRings[i].slots
    gRings[i].nextSlot = 1
    # The free list starts empty: releaseSlot refills it as connections close,
    # and until then allocSlot commits fresh slots through nextSlot.
    gRings[i].freeSlots = newSeq[cint](gRings[i].slots - 1)
    gRings[i].freeTop = 0

  # ---- database -----------------------------------------------------------
  # One request connection owned by the request thread, plus the dedicated
  # checkpoint connection/thread. From here on every commit raises the WAL
  # hook's atomic flag and the worker runs PASSIVE checkpoints; the request
  # loop never checkpoints.
  gDb = openDb(cfg.sqlitePath)
  # Write batching across one completion-queue pass; GROUP_COMMIT=0 restores
  # autocommit. Default ON.
  gDb.setGroupCommit(groupCommitEnabled())
  gDb.startCheckpointer()
  markStart()

  let recvStr = if recvMultishot: "multishot" else: "oneshot"
  let acceptStr =
    if not acceptMultishot: "oneshot"
    elif acceptDirect: "multishot+direct"
    else: "multishot"
  if not multi:
    stderr.writeLine("io_uring transport: entries=" & $RingEntries &
                     " fixed_file_slots=" & $gRings[0].slots &
                     " recv=" & recvStr & " accept=" & acceptStr)
    stderr.writeLine("slot array: sizeof(conn)=" & $sizeof(Conn) &
                     " slots=" & $gRings[0].slots &
                     " bytes=" & $(gRings[0].slots * sizeof(Conn)))
  else:
    var totalSlots = 0
    var slotLst = ""
    for i in 0 ..< gRings.len:
      totalSlots += gRings[i].slots
      if i > 0: slotLst.add ","
      slotLst.add $gRings[i].slots
    stderr.writeLine("io_uring multi-ring transport: entries=" & $RingEntries &
                     " rings=" & $gRings.len &
                     " slots_per_ring=[" & slotLst & "]" &
                     " total_fixed_file_slots=" & $totalSlots &
                     " recv=" & recvStr & " accept=" & acceptStr)
    stderr.writeLine("slot array: sizeof(conn)=" & $sizeof(Conn) &
                     " total_slots=" & $totalSlots &
                     " bytes=" & $(totalSlots * sizeof(Conn)))

  if gRings.len == 1:
    runLoop(gRings[0])
  else:
    runMultiLoop(gRings)

main()
