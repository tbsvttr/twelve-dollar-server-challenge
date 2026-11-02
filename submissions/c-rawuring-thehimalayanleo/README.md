# c-rawuring-thehimalayanleo

A hand-written HTTP/1.1 server in C on raw io_uring, with SQLite compiled into the same translation unit.
One event-loop thread and one low-priority checkpoint thread. **Direct** on `HOST:PORT` (`0.0.0.0:80` on
the box), no Nginx.

| | |
|---|---|
| Language | C (GCC 13 from Ubuntu 24.04, `-O2 -march=native`) |
| Framework | None |
| io_uring | liburing 2.5 (Ubuntu 24.04 package) |
| SQLite | 3.54.1 amalgamation, pinned by SHA-256, compiled in, not patched |
| Front | **Direct** on `HOST:PORT`. No Nginx |

This is a new implementation. It replaces my earlier PR #240, which was built on #230's server and so was
not a separate entry. Only `src/bt.h` (the B-tree reads) comes from #240, and I wrote that file.

## Design

**Several rings, one thread.** `LimitNOFILE=65535` caps the descriptors of one io_uring ring, so the
server opens 6 rings. Each ring has its own `SO_REUSEPORT` listener, its own table of 65,535 direct
descriptors (multishot accept with `IORING_FILE_INDEX_ALLOC`) and its own provided-buffer ring for multishot
receives. The kernel spreads new connections over the 6 listeners. The rings use `DEFER_TASKRUN`, so
completions are only processed when the thread asks for them and nothing interrupts it mid-pass. When idle,
the thread waits on one eventfd that all rings signal.

**One pass = one batch.** A pass reads all completions, then handles every request that came in:

1. `BEGIN`, then one read transaction on the B-tree.
2. Every read (`/feed`, `/posts/:id`, `/health`, the post check of a like) and all request validation
   and JWT checks. Reads finish before any write, so a response never shows data that is not committed.
3. The writes of the batch, in arrival order, then one `COMMIT` (group commit).
4. The write responses.

When the loop is busy, a new pass starts at most every 1 ms, so each kernel entry and each commit serve
many requests. The sends of a pass are submitted together with the next pass's fetch (one
`io_uring_enter` per ring per pass). Together this adds at most about 2 ms of latency. A pass handles at
most 4,096 completions; the rest wait in the kernel for the next pass.

**Accepts follow the loop.** Each ring keeps 32 single-shot accepts armed, and re-arms them only after a
pass that kept up (fewer than 4,096 completions). The six listeners share one listener's backlog (4,096
in total). Without this, under overload the server admitted connections faster than it served them. Each
admitted connection's unread request held about 4 KB of kernel socket memory, which reached 570 MB at
280,000 users in a box-like VM and the OOM killer ended the server. With it, a connection that the loop
cannot serve yet waits in the kernel's connect queue, and socket memory stays under about 30 MB. This is
admission control, not request shedding: no request is refused or answered with an error, and every
connection is accepted as soon as the loop catches up.

**Reads through SQLite's B-tree API** (`src/bt.h`, allowed by Arjay's 2026-10-31 ruling). The feed is the
first 20 entries of `posts_created_at_id_idx`, one range scan of `likes_post_id_idx` for all 20 like counts,
and each post row and author by rowid. Every row comes from SQLite's pages through its pager, WAL and locks,
in the batch's read transaction. Anything unusual (overflow pages, a schema change, an unexpected record)
runs the plain SQL query instead. `SQL_READS=1` turns the B-tree path off; both paths give byte-identical
responses.

**Memory.** A connection is 32 bytes in user space. A request that arrives in one receive is copied into
the pass's scratch arena and its kernel-provided receive buffer goes back to the kernel at once, so the
buffer ring never runs dry under load. Only a request split over several receives (or one that arrives
while a response is still sending) is copied to a heap buffer. Responses go into 1 MB send chunks that are reused when their
sends complete.

**Other parts, all written for this entry:** HTTP parsing, a JSON validator and string decoder,
SHA-256 / HMAC-SHA256 (with the key blocks absorbed once at start) and base64url for the JWT check, and JSON
output with escaping (it scans 8 bytes at a time for characters that need escaping).

**Checkpoints.** The WAL hook wakes a checkpoint thread (its own connection, nice 15) at 1,000 WAL pages. It
runs `PASSIVE` checkpoints, so it never blocks the writer. That alone is not enough: SQLite restarts the WAL
from its start only when a write begins after a checkpoint that copied every frame, and with writes in
almost every pass the thread never catches up (in a first version the WAL reached 1.26 GB in 40 s). So at
4,000 pages, when the thread is idle, the main thread runs one `PASSIVE` checkpoint between passes, with no
transaction open. It copies only the frames written since the thread's last run, and the next write
restarts the WAL. The WAL now stays under about 17 MB.

## Measured

**Box-like VM.** qemu/KVM on the RTX 5090 host, built to match the box: 1 vCPU (pinned), 1,968 MB RAM,
no swap, Ubuntu 24.04 with kernel 6.8.0-117 (the box's), the server started by systemd as user `deploy`
with `LimitNOFILE=65535` on `0.0.0.0:80`. The load generator runs outside the VM: the `bench/load.js`
user model in C (from #moneebullah25's mload, timing each request from after its connection is made, as
k6 does), 60 s ramp, then a 5-minute hold, a fresh database for every run. Pass = p95 < 500 ms,
p99 < 1 s, errors < 1 %, over the whole run including the ramp.

| Users | Passes | Worst p99 of the passes |
|---:|---:|---:|
| 260,000 | 1 / 1 | 13 ms |
| 280,000 | 2 / 2 | 240 ms |
| 300,000 | 4 / 5 | 77 ms |
| 320,000 | 2 / 2 | 271 ms |
| 340,000 | 1 / 1 | 57 ms |
| 360,000 | 0 / 2 | (OOM-killed during the ramp) |
| 380,000 | 0 / 1 | (OOM-killed during the ramp) |

In the same VM, c-iouring-shivanshthapliyal (#230, 270k on the box) passed 260,000 and failed 280,000
(p99 3.4 s). The VM is a model of the box, not the box. The failed 300,000 run fell behind about
70 s into the hold, after all users were connected, and its socket memory then grew until the OOM killer
ended the server. I did not find the cause; the other host jobs on that machine are one candidate. At
saturation about 85 % of the CPU is kernel time (virtio and TCP), and the server's own code about 8 %.

**Per-request CPU.** On a Ryzen 9 9950X3D (kernel 7.0), server pinned to one core and the `bench/load.js` user model on four
others, 30,000 users at 0.06 think-time scale (about 39k req/s). Server CPU per request, interleaved
rounds. The machine had other jobs on it; the numbers compare entries, they are not a user-count score.

| | µs/request (3 rounds) |
|---|---:|
| c-iouring-shivanshthapliyal (#230) | 9.53 ± 0.16 |
| this entry | 9.45 ± 0.13 |

The two are level within noise. At 300,000 connections with the real think times, in a systemd scope
with `MemoryMax=1750M` and `LimitNOFILE=65535` on one pinned core, this entry held all 300,000 with 0
errors at about 1.24 GB (#230: 1.24 GB, also 0 errors). On that machine the connect phase past about 280k
is slow for every server (one machine runs both ends), so the latency of that run means little.

**Kernel note.** Ubuntu kernels 6.8.0-136 and later reject a provided-buffer ring whose reserved field is
zero (`EINVAL`). The box's 6.8.0-117 does not, but the server registers the ring by hand and retries with
the field set, so it also starts on the newer kernels.

Checks: `test/test.sh` 42/42 (also with `SQL_READS=1`); B-tree and SQL responses identical after writes
with escapes and non-ASCII text; 6 rounds of concurrent writes with `SIGKILL` mid-stream lost 0 of 10,024
acknowledged writes.

## Rule notes

- No caches across requests. Kept between batches: prepared statements, table root pages and key infos
  (read at open), and the HMAC key blocks. Every JWT signature is verified on every request.
- Stock SQLite: the amalgamation is unmodified. The B-tree reads call SQLite's own functions.
- WAL with `synchronous=NORMAL`. No response to a write leaves before its batch's `COMMIT` returns.
- No request is refused or answered with an error, and nothing is tuned to the load test. The only
  limit under overload is the accept pacing described above. Configured only by `SQLITE_PATH`, `JWT_SECRET`, `HOST`
  and `PORT` (`SQL_READS=1` only switches the B-tree reads off, for testing).
