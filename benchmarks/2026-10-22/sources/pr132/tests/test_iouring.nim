## test_iouring.nim: standalone proof that the raw io_uring bindings work.
##
## Proves, on the machine it runs on:
##   1. the ABI struct sizes/offsets match the kernel,
##   2. io_uring_setup succeeds (or cleanly SKIPs on ENOSYS/EPERM),
##   3. an IORING_OP_NOP round-trips through SQE -> CQE with res == 0,
##   4. a socketpair SEND/RECV round-trips real bytes (SQE/CQE wiring correct),
##   5. registering a fixed-file set does not grow the process fd table.
##
## Prints one PASS line per step and exits 0.  If io_uring is unavailable the
## test prints a SKIP line and still exits 0.

import std/[posix, os, strutils]
import ../src/iouring

# ---------------------------------------------------------------------------
# tiny test harness
# ---------------------------------------------------------------------------

var checks = 0

proc pass(msg: string) =
  echo "PASS " & msg
  inc checks

proc fail(msg: string) =
  echo "FAIL " & msg
  quit(1)

# ---------------------------------------------------------------------------
# Step 1: ABI layout
# ---------------------------------------------------------------------------

proc checkAbi() =
  if sizeof(Sqe) != 64:
    fail("sizeof(io_uring_sqe) == 64 (got " & $sizeof(Sqe) & ")")
  pass("sizeof(io_uring_sqe) == 64")

  if sizeof(Cqe) != 16:
    fail("sizeof(io_uring_cqe) == 16 (got " & $sizeof(Cqe) & ")")
  pass("sizeof(io_uring_cqe) == 16")

  if sizeof(IoUringParams) != 120:
    fail("sizeof(io_uring_params) == 120 (got " & $sizeof(IoUringParams) & ")")
  pass("sizeof(io_uring_params) == 120")

  let bad =
    (offsetOf(Sqe, opcode) != 0) or (offsetOf(Sqe, flags) != 1) or
    (offsetOf(Sqe, ioprio) != 2) or (offsetOf(Sqe, fd) != 4) or
    (offsetOf(Sqe, off) != 8) or (offsetOf(Sqe, `addr`) != 16) or
    (offsetOf(Sqe, len) != 24) or (offsetOf(Sqe, rw_flags) != 28) or
    (offsetOf(Sqe, user_data) != 32) or (offsetOf(Sqe, buf_index) != 40) or
    (offsetOf(Sqe, personality) != 42) or (offsetOf(Sqe, splice_fd_in) != 44) or
    (offsetOf(Sqe, addr3) != 48) or
    (offsetOf(Cqe, user_data) != 0) or (offsetOf(Cqe, res) != 8) or
    (offsetOf(Cqe, flags) != 12)
  if bad:
    fail("sqe/cqe field offsets do not match kernel ABI")
  pass("sqe field offsets match kernel ABI (opcode/flags/ioprio/fd/off/addr/len/user_data/buf_index)")

# ---------------------------------------------------------------------------
# Step 2: setup
# ---------------------------------------------------------------------------

proc openRing(): Ring =
  try:
    result = setupQueue(64)
  except IoRingError as ex:
    if ex.errno == IOURING_ENOSYS or ex.errno == IOURING_EPERM:
      echo "SKIP: io_uring unavailable (errno=" & $ex.errno & ": " & ex.msg & ")"
      quit(0)
    else:
      fail("setupQueue(64) raised: " & ex.msg)
  pass("setupQueue(64)")

# ---------------------------------------------------------------------------
# Step 3: NOP round-trip
# ---------------------------------------------------------------------------

proc checkNop(r: Ring) =
  const cookie = 0x1111'u64
  let sqe = r.getSqe()
  if sqe.isNil:
    fail("getSqe returned nil for NOP")
  sqe.opcode = IORING_OP_NOP
  sqe.user_data = cookie
  discard r.submitAndWait(1)

  let cqe = r.peekCqe()
  if cqe.isNil:
    fail("no CQE after NOP submit")
  if cqe.res != 0:
    fail("NOP res == 0 (got " & $cqe.res & ")")
  if cqe.user_data != cookie:
    fail("NOP user_data echoed (got 0x" & toHex(cqe.user_data) & ")")
  r.cqeSeen()
  pass("IORING_OP_NOP res == 0 user_data echoed (0x1111)")

# ---------------------------------------------------------------------------
# Step 4: socketpair SEND/RECV
# ---------------------------------------------------------------------------

proc checkSendRecv(r: Ring) =
  var sv: array[2, cint]
  if socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0:
    fail("socketpair() failed")

  var payload = "hello io_uring"
  var rbuf = newString(payload.len)

  let sendSqe = r.getSqe()
  if sendSqe.isNil: fail("getSqe nil for SEND")
  sendSqe.opcode = IORING_OP_SEND
  sendSqe.fd = sv[0]
  sendSqe.`addr` = cast[uint64](addr payload[0])
  sendSqe.len = uint32(payload.len)
  sendSqe.user_data = 1'u64

  let recvSqe = r.getSqe()
  if recvSqe.isNil: fail("getSqe nil for RECV")
  recvSqe.opcode = IORING_OP_RECV
  recvSqe.fd = sv[1]
  recvSqe.`addr` = cast[uint64](addr rbuf[0])
  recvSqe.len = uint32(rbuf.len)
  recvSqe.user_data = 2'u64

  discard r.submitAndWait(2)

  var sent, recvd = false
  var guard = 0
  while (not sent or not recvd) and guard < 1000:
    let cqe = r.peekCqe()
    if cqe.isNil:
      discard r.submitAndWait(1)
    else:
      case cqe.user_data
      of 1'u64:
        if cqe.res != payload.len:
          fail("SEND res == " & $payload.len & " (got " & $cqe.res & ")")
        sent = true
      of 2'u64:
        if cqe.res != payload.len:
          fail("RECV res == " & $payload.len & " (got " & $cqe.res & ")")
        recvd = true
      else:
        discard
      r.cqeSeen()
    inc guard

  if not sent or not recvd:
    fail("did not reap both SEND and RECV CQEs")
  if rbuf != payload:
    fail("received bytes mismatch: got " & rbuf.escape & " want " & payload.escape)

  pass("socketpair SEND/RECV bytes match (" & $payload.len & " bytes)")

  discard close(sv[0])
  discard close(sv[1])

# ---------------------------------------------------------------------------
# Step 5: registered fixed files don't grow the fd table
# ---------------------------------------------------------------------------

proc fdCount(): int =
  result = 0
  for _ in walkDir("/proc/self/fd"):
    inc result

proc checkRegisterFiles(r: Ring) =
  var sv: array[2, cint]
  if socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0:
    fail("socketpair() failed for register test")

  let before = fdCount()
  discard r.registerFiles([sv[0], sv[1]])
  let after = fdCount()

  if after != before:
    fail("registerFiles grew the process fd table (" & $before & " -> " & $after & ")")

  discard r.unregisterFiles()
  let afterUnreg = fdCount()
  if afterUnreg != before:
    fail("unregisterFiles changed the process fd table (" & $before & " -> " & $afterUnreg & ")")

  pass("registered fds do not consume RLIMIT_NOFILE (process fd count stayed " &
       $before & ")")

  discard close(sv[0])
  discard close(sv[1])

# ---------------------------------------------------------------------------

proc main() =
  echo "[test_iouring] raw io_uring bindings"
  checkAbi()
  let ring = openRing()
  checkNop(ring)
  checkSendRecv(ring)
  checkRegisterFiles(ring)
  ring.teardown()
  echo "ALL " & $checks & " CHECKS PASSED"

when isMainModule:
  main()
