# C# on Kestrel, io_uring, plain SQLite (csharp-kestrel-mbobka)

| Item | Value |
|---|---|
| Language | C# 14 on .NET 10 (SDK 10.0.403, pinned in `global.json`), ReadyToRun with tiered PGO |
| Server | Kestrel (ASP.NET Core 10) as the host, with our io_uring transport in its transport slot |
| Database driver | SQLite 3.53.4 from source (SHA-256 checked), profile-guided gcc build, `libsqlite3.so` next to the binary, public C API through `DllImport` |
| JSON | Own writer (`Out.cs`); `System.Text.Json`'s `Utf8JsonReader` for request bodies and JWT claims |
| **Nginx or direct** | **Direct**: the server listens on `HOST:PORT` (`0.0.0.0:80`) itself |

Kestrel starts the server and binds the endpoint. It never sees a connection: its accept stays pending, and `Loop.cs` owns every
socket from accept to close, because handing a connection to Kestrel wakes a thread-pool thread that spins against the loop on
the one core (measured by fsharp-kestrel-delneg).

No SQLite internals here: everything goes through the public API with prepared SQL. The sibling entry
`csharp-kestrel-btree-mbobka` is the same server with reads on SQLite's B-tree cursors and a VFS shim.

## Where this comes from

This isn't written from scratch. It started as a merge of two entries in this repo, then took ideas from the top of the board.
Parts of the code are adapted from these MIT-licensed submissions:

| From | What |
|---|---|
| `fsharp-kestrel-delneg` (#201) | The architecture: Kestrel as a host, waiting in ring 0, sends with `MSG_DONTWAIT` from the arena, one transaction per pass, the checkpoint thread, write holds, the thread starting the WAL itself, the feed by id range, the PGO training run (`sqlite-train.c`), ReadyToRun with tiered PGO, workstation non-concurrent GC, the `resv[0]=1` retry for Ubuntu's inverted buffer ring check |
| `csharp-epoll-gichamba` (#174) | The C# side: typed structs for the io_uring ABI, API validation (`Api.cs`, which it took from `csharp-aspnetcore-maks-march`, #27), JWT (`Jwt.cs`), the JSON writer |
| `rust-iouring-kensac` (#264), `c-iouring-pavlyhalim` (#245) | Eight `SO_REUSEPORT` listeners, checkpoint thread at nice 19, `unix-excl` VFS, `-mprefer-vector-width=256`, answering less than is read in a pass |
| Not taken from those entries | The hard connection limit with refusal at SYN, connection state in native memory, heads written in front of the body, the extra `io_uring_enter` only on kernels that need it, `journal_size_limit = 0` for the reason below (`c-iouring-public` and `rust-axum-mjc` also set this pragma) |

## Past 320,000 connections, clients are refused

**The server holds at most 320,000 connections and the score can't go above that.** On 2 GB, memory decides the score. What the
kernel keeps per open socket (about 4.4 KB, most of it unreclaimable) can't be changed from inside a process, so the budget starts
there and everything else is cut to fit:

| Memory at the end of a 320,000 hold (measured) | MiB |
|---|---|
| Kernel slab (sockets, files, io_uring requests) | 1,404 |
| This process, anonymous | 139 |
| Page cache (evictable) | 145 |
| Free | 140 |

At the limit the listeners stop listening (`shutdown` on the listening sockets), so the kernel answers a new SYN with a reset and
allocates nothing. Sockets the kernel had already accepted are closed at once: in the run below, open connections peaked at 320,170
for a moment and then stayed at 320,000. Listening resumes once the count falls below 318,976. Five rings of 64,511 slots hold the
connections. The limit looks only at how many connections are open, nothing else.

Each refused connection is a failed request for that user, so a run above the limit fails on `http_req_failed`. That is intended:
the alternative was running out of memory and failing everyone. The limit is a measured choice, not a proof that 320,000 is the
right number on your box.

## What keeps it alive at the wall

A stall of a second or two is where servers die here: every request waiting in its socket holds a 3-4 KB network buffer, and
hundreds of thousands of them run the box out of memory. Each of these came from following one such failure back to its cause:

1. **Hot pages live in SQLite's 64 MB cache,** in anonymous memory, which can't be taken back with no swap. In the kernel's page
   cache they look cold, since SQLite's cache keeps them from being touched. With a 16 MB cache, reclaim evicted them and the
   request thread blocked on a disk read in `pread`.
2. **The WAL is cut to nothing each time it starts again** (`journal_size_limit = 0`). Frames aren't page-aligned, so overwriting
   an evicted WAL page first reads it from disk, inside the COMMIT, on the request thread. Past the end of the file there's
   nothing to read. The kernel also gets the old WAL's page cache back at once.
3. **Reading comes before answering.** A pass answers at most 2,048 requests. Whatever else has arrived is copied straight out of
   the kernel into the connection's own few hundred bytes and answered in a later pass. Reading is far cheaper than answering,
   so the backlog leaves the kernel's buffers at once. The idea is from c-iouring-pavlyhalim.

## How it works

1. **One thread, many rings.** Accepted sockets are direct descriptors in a ring's fixed-file table, so `LimitNOFILE=65535` doesn't
   cap them. Eight `SO_REUSEPORT` listeners give eight accept queues of `somaxconn`.
2. **A pass.** The loop waits in ring 0 for 32 completions or 2 ms, then collects the other rings. Everything answered runs in one
   SQLite transaction. After the COMMIT, each connection with output gets one send, which finishes inside `io_uring_enter`. A
   response always follows the commit of its write (rule 6).
3. **No copy of a response.** The arena is a pinned array. The body is written straight into it after room for the head, and the
   head goes just before the body, so `Content-Length` needs no back-fill and no bytes shift. Sends point into the arena.
4. **Nothing for the GC to do.** Connection state is a 64-byte struct in `mmap`ed memory, not objects and not managed arrays, and
   the request path doesn't allocate.
5. **Checkpoints don't stop requests.** A second connection on a nice-19 thread runs `PASSIVE` checkpoints. At 15,000 WAL frames
   writes are held (reads go on) for up to 500 ms, while the thread copies the rest and starts the WAL itself by writing
   `PRAGMA user_version` with its current value, so the WAL header's `fsync` happens there too. bpftrace over a 5-minute hold shows
   no `fsync` on the request thread.

## ReadyToRun or Native AOT: it hardly matters here

ReadyToRun with tiered PGO is the setting of fsharp-kestrel-delneg; the choice isn't new here. At this load the kernel takes nearly
all the CPU: one `perf` snapshot at 320,000 users (the B-tree sibling, AOT build) listed 63.5 points in the kernel, 7.7 in user code,
about 5 of those in C#. So the compile mode can only move a small share. We tried both and kept ReadyToRun because it came out a
little ahead, on weak evidence:

| 280,000 users, CPU µs per request | ReadyToRun | Native AOT |
|---|---|---|
| This entry, two runs each | 18.06, 17.89 | 18.81, 18.75 |

Peak memory of the app's cgroup was the same within noise (654-712 MB against 653-660 MB). In one overload run each at 340,000 on the
B-tree sibling, the AOT build ran out of memory at about 110 s and ReadyToRun didn't. The host wasn't quiet during that run and we
didn't establish that the compile mode caused it.

## Local measurements (not a score)

Two VMs under QEMU/KVM on an i9-13900K, nested in WSL2: the server on Ubuntu 24.04 with kernel 6.8.0-147, 1 vCPU, 1,967 MiB, no swap,
under systemd with `LimitNOFILE=65535`, disk limited to 3,000 IOPS and 200 MB/s. kload (#87) on 14 vCPUs of a second VM, direct on
port 80, 60 s ramp, 5-minute hold, 30 s ramp-down, the host otherwise idle. This is not your droplet, so compare these numbers
with each other. As a rough control, on this rig `csharp-epoll-gichamba` passed 210,000 (hold 222/350 ms) and `fsharp-kestrel-delneg`
just missed at 247,000 (whole-run p99 1,004 ms), one run each.

One run per row, on the submitted code. Latency in ms, p95/p99. "Whole run" includes the ramps and is what k6's thresholds see.

| Users | Whole run | Hold | Req/s in hold | CPU µs/req | VM busy | Errors | Thresholds |
|---|---|---|---|---|---|---|---|
| 300,000 | 66/518 | 68/659 | 31,681 | 18.49 | 72% | 0 | pass |
| 314,000 | 163/399 | 163/399 | 33,112 | 19.76 | 80% | 0 | pass |
| 320,000 | 465/**1,204** | 436/692 | 33,582 | 20.25 | 84% | 0 | **fail on p99** |
| 340,000 (2-minute hold) | 979/1,597 | 1,004/1,647 | 37,013 | 20.98 | 97% | 7.76% whole run, 10.8% in hold | fail, as intended |

- **So the honest local number for this entry is 314,000.** It passes that once; we did not repeat it enough to call it stable.
- **The ramp-down is a known weak spot.** At 320,000 the hold's p99 is 692 ms, while 10-second windows during the ramp-down reach
  p95 3,162 ms: closing about 10,000 connections per second competes with requests on the one thread. That is what fails the
  whole-run p99.
- **The 340,000 run shows the limit working.** About 490,000 connection attempts were refused, which is what the failed requests
  are. Open connections stayed at 320,000, there was no OOM, and the connected users kept being served at the latencies above.
- The same kind of run varies. Don't read much into a single row.

## Checks

- `test/test.sh`: 42/42, also on a fresh Ubuntu 24.04 container from the tracked files only: `install.sh` as root, `test/run.sh` as
  a normal user.
- HTTP edge cases: 30 pipelined requests, a request sent 7 bytes at a time, `Connection: close`, HTTP/1.0, a bad request line, a 20 KB
  header, chunked bodies, `Expect: 100-continue`, 3,000 feeds pipelined to a slow reader, a half-closed client, a client vanishing
  mid-body, JSON escaping round trips.
- Limit: with `MB_MAX_CONN=2000`, of 2,100 connections 2,000 are answered and the rest refused, and listening comes back once enough
  have closed.
- Durability: 32 clients posting and liking with `MB_HOLD_FRAMES=64`, `kill -9` during the load, 5 rounds on the same files: none of
  60,368 acknowledged posts and 60,320 acknowledged likes lost, `integrity_check` ok. `integrity_check` was also ok after each load run
  from 300,000 to 320,000.

## Rules

- Writes: WAL with `synchronous=NORMAL` on both connections. A response is sent only after the commit of its pass; if a commit fails,
  the connections of that pass are closed without a response.
- No cache: every request reads SQLite. Prepared statements and the HMAC key are all that's kept.
- Nothing detects the load test. The connection limit looks only at how many connections are open.
- `install.sh` (root) installs gcc, libicu, libssl, curl and the .NET SDK from the official tarball with a SHA-512 check.
- `build.sh` (normal user) gets the SQLite source with a SHA-256 check and builds it twice around `sqlite-train.c`. The profile comes
  from that run on a synthetic database during the build; no profile data is committed. NuGet packages come at the versions SDK
  10.0.403 pins.
- `start.sh` sets nothing but the binary. The `MB_*` variables in the source are overrides for the tests above, unset in normal
  running; their defaults are the submitted configuration.
- Nothing on the box is tuned. The process raises its own soft `RLIMIT_NOFILE` to the hard limit.
