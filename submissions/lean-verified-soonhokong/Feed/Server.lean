import Feed.Handler

/-!
# Batches

The transport (`runtime/uring.c`) calls `batch` once per event-loop iteration with the unread
input of every connection that has some. A batch is one SQLite transaction:

1. every complete request is parsed; reads are answered from the transaction's snapshot;
2. each connection stops at its first write (a later request on that connection waits for the
   next batch, so it sees the write), and the writes are then performed in order;
3. the transaction commits; a write's answer is its result if the commit succeeded (a 404, which
   wrote nothing, stands either way), else 500.

No answer leaves before the batch returns, so a 201 is always committed.
-/
namespace Feed

/-- What the transport does with one connection's input. -/
structure Reply where
  /-- bytes to send: `resp[start, size)` -/
  resp : ByteArray
  start : Nat
  /-- input bytes used; the rest is kept for the next batch -/
  consumed : Nat
  /-- bit 0: close after sending; bit 1: requests are pending, present the rest again -/
  flags : Nat
  deriving Inhabited

/-- The read phase of one connection's input: its answers, the bytes used, the flags, and the
write that ended it, if any. -/
structure ChunkOut where
  out : ByteArray
  consumed : Nat
  flags : Nat
  write : Option (Write × Bool)
  deriving Inhabited

def maxPipeline : Nat := 64

/-! ## Answers to malformed input and to HEAD -/

def k414 : ByteArray := lit "HTTP/1.1 414 URI Too Long\r\nContent-Type: application/json\r\nContent-Length: "
def kUriTooLong : ByteArray := lit "{\"error\":\"uri too long\"}"

/-- The body of the answer to malformed input with status `st`. -/
def rejectBody (st : Nat) : ByteArray :=
  if st == 413 then Err.tooLarge.body else if st == 414 then kUriTooLong
  else if st == 431 then Err.headTooLarge.body else Err.badRequest.body

/-- The answer to malformed input with status `st`, which closes the connection, appended to
`out`; to a HEAD request without its content (RFC 9110 §9.3.2). 414 has its own status line. -/
def respondReject (out : ByteArray) (head : Bool) (st : Nat) : ByteArray :=
  let body := rejectBody st
  let out := Bytes.appendAll out (if st == 414 then k414 else statusLine st)
  let out := Bytes.appendNat out body.size
  let out := Bytes.appendAll out endHeadClose
  if head then out else Bytes.appendAll out body

/-- The answer to a HEAD request from the answer GET gets, which `x` ends with from `start`: `x`
up to the end of the first CR LF CR LF from `start` on, which ends the response's head (RFC 9110
§9.3.2; the head keeps GET's `Content-Length`, §8.6). -/
def stripBody (x : ByteArray) (start : Nat) : ByteArray :=
  match Http.headEnd x start x.size with
  | some e => x.extract 0 (e + 4)
  | none => x

/-- The requests of one connection's input from `pos`: answer reads until the input ends, a write
comes, or the connection closes. `n` answers so far, appended to `out`. (The feed and a post are
written straight into `out`; no scratch buffer is passed along.) A HEAD request is answered as GET
without the content. -/
def readLoop [Monad m] [Store m] (env : Env) (a : ByteArray) (pos n : Nat) (out : ByteArray) : Nat → m ChunkOut
  | 0 => return ⟨out, pos, if pos < a.size then 2 else 0, none⟩
  | fuel + 1 => do
    match Http.parse a pos with
    | .incomplete => return ⟨out, pos, 0, none⟩
    | .bad st => return ⟨respondReject out (Http.headAt a pos) st, a.size, 1, none⟩
    | .ok r =>
      let st ← decide env a r out ByteArray.empty
      match st.write with
      | some w =>
        -- a write is performed after this batch's reads; later requests wait for the next batch
        if n == 0 && env.writesOk then
          return ⟨st.out, r.next, if r.next < a.size then 2 else 0, some (w, r.close)⟩
        else return ⟨st.out, pos, 2, none⟩
      | none =>
        let o := if r.head then stripBody st.out out.size else st.out
        if r.close then return ⟨o, r.next, 1, none⟩
        else readLoop env a r.next (n + 1) o fuel

def readPhase [Monad m] [Store m] (env : Env) (a : ByteArray) : m ChunkOut :=
  readLoop env a 0 0 ByteArray.empty maxPipeline

/-- The read phase over all chunks, in order. -/
def readAll [Monad m] [Store m] (env : Env) (chunks : Array ByteArray) (i : Nat) (outs : Array ChunkOut) :
    Nat → m (Array ChunkOut)
  | 0 => return outs
  | fuel + 1 => do
    if h : i < chunks.size then
      let o ← readPhase env chunks[i]
      readAll env chunks (i + 1) (outs.push o) fuel
    else return outs

/-- The write phase: perform the writes in chunk order; their results in that order. -/
def writeAll [Monad m] [Store m] (outs : Array ChunkOut) (i : Nat) (res : Array (Nat × ByteArray)) :
    Nat → m (Array (Nat × ByteArray))
  | 0 => return res
  | fuel + 1 => do
    if h : i < outs.size then
      match outs[i].write with
      | some (w, _) => writeAll outs (i + 1) (res.push (← perform w)) fuel
      | none => writeAll outs (i + 1) res fuel
    else return res

/-- Replies, with each write's answer appended to its connection's output. -/
def replies (committed : Bool) (outs : Array ChunkOut) (results : Array (Nat × ByteArray)) (i wi : Nat)
    (acc : Array Reply) : Nat → Array Reply
  | 0 => acc
  | fuel + 1 =>
    if h : i < outs.size then
      let o := outs[i]
      match o.write with
      | some (_, close) =>
        let (st, body) := results[wi]!
        let (st, body) := if committed || st == 404 then (st, body) else (500, Err.internal.body)
        replies committed outs results (i + 1) (wi + 1)
          (acc.push ⟨respond o.out st body close, 0, o.consumed, o.flags ||| (if close then 1 else 0)⟩) fuel
      | none => replies committed outs results (i + 1) wi (acc.push ⟨o.out, 0, o.consumed, o.flags⟩) fuel
    else acc

/-- One batch: reads from one snapshot, then the writes in order, then the commit. -/
def runBatch [Monad m] [Store m] (env : Env) (chunks : Array ByteArray) : m (Array Reply) := do
  let ok ← Store.begin
  if !ok then
    return chunks.map fun _ => ⟨respondErr ByteArray.empty .internal true, 0, 0, 1⟩
  let outs ← readAll env chunks 0 (Array.mkEmpty chunks.size) chunks.size
  Store.endReads
  let results ← writeAll outs 0 (Array.mkEmpty 0) outs.size
  let committed ← Store.commit
  return replies committed outs results 0 0 (Array.mkEmpty outs.size) outs.size

/-- The HMAC key schedule for `JWT_SECRET`, computed once at startup. -/
@[export feed_make_key]
def makeKey (secret : ByteArray) : Hmac.Key := Hmac.Key.of secret

@[export feed_batch]
def batch (chunks : Array ByteArray) (now uptime : UInt64) (writesOk : UInt8) (key : Hmac.Key) : IO (Array Reply) :=
  runBatch ⟨key, now.toNat, uptime.toNat, writesOk != 0⟩ chunks

/-! ## Idle connections under a budget

Where memory runs out before the CPU does, every open connection costs about 4 KB of kernel
memory whether it is used or not. The transport keeps each ring's open connections in order of
their last activity (an accept, or the end of an answer's send), least recent first, and once per
loop iteration, when more connections are open than the budget or an idle timeout is set, offers
the first ones of those lists, merged longest-idle first, to `Idle.pick`: for each, how long it has
been idle (ms) and whether it is busy (input not yet answered, an answer being sent or queued, part
of the current batch, its poll not armed, or already closing). It closes those `pick` chooses. The
theorems in `Feed/Proofs/Idle.lean`: a busy connection is never closed; without a timeout nothing
is closed at or below the budget and never more than the excess over it; and with the candidates
in that order, every connection closed was idle at least as long as every one that could have been
closed instead. -/
namespace Idle

structure Cfg where
  /-- close idle connections while more than this many are open -/
  budget : Nat
  /-- a connection idle for less than this (ms) is not closed for the budget -/
  minIdle : Nat
  /-- if not 0, a connection idle for this long (ms) is closed whatever the count -/
  timeout : Nat

/-- A connection offered for closing: how long it has been idle (ms), whether it is busy. -/
abbrev Cand := Nat × Bool

/-- It may be closed for the budget: not busy, idle for at least `minIdle`. -/
def Cfg.spare (cfg : Cfg) (c : Cand) : Bool := !c.2 && Decidable.decide (cfg.minIdle ≤ c.1)

/-- It is closed for the timeout: not busy, idle for at least a timeout that is set. -/
def Cfg.expired (cfg : Cfg) (c : Cand) : Bool := !c.2 && Decidable.decide (0 < cfg.timeout) && Decidable.decide (cfg.timeout ≤ c.1)

/-- For each candidate in order, whether to close it, when `n` connections are open. -/
def pickList (cfg : Cfg) : Nat → List Cand → List Bool
  | _, [] => []
  | n, c :: cs =>
    if (Decidable.decide (cfg.budget < n) && cfg.spare c) || cfg.expired c then true :: pickList cfg (n - 1) cs
    else false :: pickList cfg n cs

/-- `pickList` on the candidates `(idle[i], busy[i])`. The transport calls this definition,
compiled (`feed_idle_pick`). -/
@[export feed_idle_pick]
def pick (budget minIdle timeout n : Nat) (idle : Array Nat) (busy : Array Bool) : Array Bool :=
  (pickList ⟨budget, minIdle, timeout⟩ n (idle.toList.zip busy.toList)).toArray

end Idle

end Feed
