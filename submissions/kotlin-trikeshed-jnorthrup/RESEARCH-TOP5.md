# The top five, what we measured, and the KN strategy

This document studies the five leading entries of the Twelve-Dollar Server Challenge. It then records how we measured our own Kotlin/Native (KN) server against them, the strategy we adopted, and two questions: does ngSCTP help the score, and does an io_uring change to SQLite help the score.

Numbers marked "estimate" are not measurements. All other numbers come from a cited README, from LEADERBOARD.md, or from our own runs (STUDIES.md has the methods for those).

## 0. Sources and date

- Leaderboard: upstream `main` at `72e1020` (2026-11-02 08:01 CST, Monday morning). A copy taken Sunday 2026-11-01 at 11:38 gives the Sunday order.
- Sources of the five entries: upstream `main` for four of them; PR #271 head `30d259c` for lean-verified-soonhokong, which is not merged.
- Scored box: a 1 vCPU / 2 GB KVM guest, Xeon Platinum 8260, Ubuntu 24.04, kernel 6.8, no swap, no conntrack. The server runs under systemd as `deploy` with `LimitNOFILE=65535`. Load comes from separate 16-core machines (0.25 ms RTT). The score is the most users that pass a 5-minute hold with p95 < 500 ms, p99 < 1 s and errors < 1%.
- Our scored entry is still the JVM build (PR #128): rank 82 of 172, 71,000 users. The file-descriptor limit stops it (footnote ᶠ), not speed. The KN server is not on the scored path yet.

## 1. The top five

### Monday 2026-11-02 (upstream 72e1020)

| # | Entry | PR | Language | Users | req/s | p95 ms | p99 ms | CPU % | µs/req | RAM MB |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|
| 1 | rust-iouring-kensac | #264 | Rust | 310,000 | 29,284 | 62 | 190 | 82 | 25 | 1,114 |
| 2 | mojo-iouring-oh-meh | #257 | Mojo | 304,000 | 28,705 | 159 | 545 | 82 | 26 | 726 |
| 3 | c-iouring-pavlyhalim | #245 | C | 295,000 | 28,013 | 28 | 117 | 81 | 26 | 1,536 |
| 4 | rust-native-scooter1337 | #267 | Rust | 290,000 | 27,580 | 26.5 | 514 | 80 | 26 | 1,035 |
| 4 | lean-verified-soonhokong | #271 | Lean 4 | 290,000 | 27,560 | 30.7 | 300 | 82 | 27 | 1,107 |

### Sunday 2026-11-01, 11:38

| # | Entry | Users | µs/req |
|---|---|---:|---:|
| 1 | c-iouring-pavlyhalim | 295,000 | 26 |
| 2 | lean-derive-hargup | 280,000 | 31 |
| 2 | mojo-iouring-oh-meh (#224) | 280,000 | 29 |
| 2 | objc-uring-delneg | 280,000 | 27 |
| 5 | c-iouring-shivanshthapliyal | 276,000 | 26 |

In one day, rust-iouring-kensac climbed from 270,000 to first place at 310,000, and two new entries tied for fourth. The top now spans 290,000 to 310,000 users, at 25 to 27 µs of CPU per request and 80 to 82% CPU. The order changes with each re-score; the design does not.

### The shared design

All five entries use the same design. Only the language differs, and so do the choices at the edges.

1. **Reads on SQLite's B-tree cursors.** `GET /feed` and `GET /posts/:id` call SQLite's own B-tree layer (`sqlite3BtreeTableMoveto`, `IndexMoveto`, `Next`) through its pager and WAL. Only the bytecode engine is skipped. The amalgamation is included unmodified. The organizer allowed this reading of rules 3 and 5 for PR #153 on 2026-10-30.
2. **One SQLite transaction per event-loop pass, then group commit.** The reads of a pass share one snapshot. The pass's writes commit once, and every response leaves after that COMMIT (rule 6).
3. **Batches form when the server is busy.** The loop waits for N completions or T µs before it serves: 256 or 1 ms (kensac), 32 or 250 µs (mojo), 64 or 2 ms (pavlyhalim), 2 ms per iteration (lean). One wake, one transaction and one submit then serve more requests.
4. **Connections live outside the fd table.** Accepted sockets are io_uring direct descriptors, in several rings of about 65,000 slots each, with up to eight `SO_REUSEPORT` listeners. Memory per idle connection is kept small.
5. **WAL checkpoints run off the loop.** A second connection on a nice-19 thread runs PASSIVE checkpoints. When the WAL grows too large, writes are held briefly, reads go on, and the log restarts.

All five also turn mmap off (`mmap_size=0`) and use a small page cache. They hash the HMAC key's inner and outer pads once at startup. They escape JSON eight bytes per step. Each one retries the provided-buffer-ring registration with `resv[0]=1`, because Ubuntu's 6.8.0-136 and later kernels refuse a zero reserved field (Launchpad #2162843).

## 2. Each entry, and the character of its choices

### rust-iouring-kensac: the careful generalist (310,000)

- Assumes nothing about the data. The feed walks `posts_created_at_id_idx`, then reads posts in ascending id order. Consecutive ids hit SQLite's next-cell fast path. Likes take one range walk when the ids lie within 512 of each other, and one seek each otherwise. A missing author falls back to SQL. The schema is checked at startup.
- One transaction per pass. Reads that see the pass's own writes wait for COMMIT; other reads do not.
- `unix-excl` VFS: the WAL index lives in heap memory, so no fcntl lock is taken per transaction. mmap is off and the page cache is 64 MB.
- Checkpoints run on a second thread. Writes are held for at most 250 ms when the thread cannot keep up.
- Eight `SO_REUSEPORT` listeners and up to 16 rings. Accepts move to the next ring before a table is full, because an accept with no free slot drops the connection.
- Character: plain and thorough. It wins on many small corrections, not one idea.

### mojo-iouring-oh-meh: the language bet (304,000)

- The author picked Mojo "because nobody had". The hot path is Mojo; C does only the plumbing (liburing helpers, SQLite exports, the checkpoint thread).
- The feed plan assumes dense ids and a `created_at` that never decreases. The server checks this at startup and after every insert; if a check fails, it switches to SQL for good.
- Batch formation (32 completions or 250 µs) cut CPU per request by about 15%. mmap off saved 12% of CPU. The binary's code is locked in RAM, so reclaim cannot stall the loop on page faults.
- It uses the older `PROVIDE_BUFFERS` operation instead of buffer rings, because of the Ubuntu 6.8 kernel bug.
- A guard pauses accepting new connections when `MemAvailable` falls under 160 MB.
- Character: bold in its language and careful in its notes. Its highest p99 (545 ms) is the price of its write holds.

### c-iouring-pavlyhalim: the systems notebook (295,000)

- Raw io_uring syscalls (no liburing), a static build, and PGO trained on a synthetic database. The whole server is one translation unit with the amalgamation.
- An idle connection waits on a multishot **poll**, not a multishot receive. A poll costs 263 bytes of kernel memory against 360. After a stall, multishot receives emptied the buffer ring and caused an `ENOBUFS` storm of up to 700,000 re-arms in 10 s. A read queue absorbs a burst of any size instead.
- Drain first: up to 16,384 reads per batch but only 2,048 answers, so the backlog leaves the kernel's socket buffers quickly.
- The 20 author lookups descend the `users` B-tree level by level together, with prefetch and interpolation search inside a page: 1.25 µs became 0.9 µs per request.
- A VFS shim built only on the public API writes each commit to the WAL with one `pwrite`: 0.24 became 0.095 `pwrite` calls per request. A page-cache wrapper skips a commit-time scan that cost 1.8% of CPU.
- A memory valve exists but is off by default. With it on, the server died at about 59,000 connections; with it off, it held 144,000.
- Character: an engineering diary. Every choice has a measured reason, and the README says where the box really stops: memory, at about 4 KB of kernel memory per connection.

### rust-native-scooter1337: the latency engineer (290,000)

- It credits hargup's #153 for the B-tree plan. It assumes no dense ids, and it walks the posts cursor backward when ids are consecutive.
- **A dedicated SQLite writer thread** has its own connection. Writes gather for 20 ms, then run as one transaction of at most 1,024 requests. Reads are served live on the issuer's connection and never wait for the writer. At 100,000 users, its p99 fell from 250 ms to 69 ms with this change.
- Bounded queues and pooled buffers carry requests between the threads, with a 100 MiB cap on outstanding request bytes.
- Character: it trades a little throughput for a low tail and documents both sides honestly.

### lean-verified-soonhokong: proof and speed together (290,000)

- The handler is Lean 4 and is generic over a `Store` monad. The theorems run on a model of the tables; the server runs the same code against SQLite. `runBatch_spec` proves that a batch is a serial execution: reads from one snapshot, writes in connection order, no answer before the commit.
- **Writes in fewer batches**: a batch may write at most every 10 ms. A write waits for that batch; reads do not. This saves 0.5 log frames per write and 5% of the handler's CPU.
- Overload cap: an iteration serves at most about 6 ms of input. Replies then leave before the client's 40 ms delayed-ACK timer adds a packet per request.
- It also uses poll plus a read queue, the WAL shim, the page-cache wrapper, PGO, and an 8 MB page cache.
- On its own cloud VM it held 340,000 to 350,000 users against pavlyhalim's 333,000. Memory stopped both.
- Character: rigorous, and still among the fastest. It shows that proofs do not cost speed when the proofs cover the handler and the trusted C stays small.

### What the five teach

- **The limit is memory, then CPU.** At about 4 KB of kernel memory per connection, 2 GB stops near 340,000 to 360,000 users. At 25 to 27 µs per request, the CPU reaches about 82% near 300,000 users.
- **Reads never wait behind a long write window.** Some write windows are long (scooter 20 ms, lean 10 ms), but reads do not join them.
- **CPU per request comes from many small cuts.** No single trick gives the 25 µs.

## 3. What we researched, and how

### Method

- **Micro checks on kali** (WSL2, i7-6820HK). The server runs in the box limits on CPU 1, with `wrk` on CPUs 2 and 3 and 1,024 connections. We measure µs of server CPU per request per route (`knee2.sh`), profile with `perf` by symbol, compare every response of two binaries (`difftest.sh`, 757 reads), and count syscalls per request (`sysc.sh`).
- **Test-first C.** Each C helper has a plain C test against a byte-wise reference or SQLite itself, with exact-size buffers, AddressSanitizer, and mutants that must fail.
- **The winners on the same machine.** We built #1 (then pavlyhalim) and shivanshthapliyal from source with their own `build.sh` on kali, and ran the same route matrix, `perf` profiles, a 64,000-user run, and a read-latency check (`mixlat.sh`).
- **RunPod pod** (kernel 6.8.0-147, the box's kernel family; AMD EPYC 7713; the 2 vCPUs are SMT siblings of one core). Our KN server and pavlyhalim were both built from source there (`pod-build.sh`, `pod-bench.sh`); the pod was then restored to its snapshot.
- **Transport benches.** SCTP over UDP against TCP at 32,000 users, with a Mac load client.

### Results, our KN server step by step (kali, µs of server CPU per request)

| Step | Commit | GET /feed | GET /posts/:id |
|---|---|---:|---:|
| Start | 2495dd0 | 57 | 14 |
| Copy and escape text in one C pass | 7fbf26b | 45 | 13 |
| One C call per feed row | 06182a8 | 40 | 12 |
| Reads on B-tree cursors (feedbt.c) | 098ccd1 | 23 | 12 |
| Fill/drain: one read per wake, responses straight to the send arena | 17613be | 23 | 12 |
| Release the read once per wake | 4dc083f | 21 | 10 |

Post went from 74k to 87–92k req/s at the last step. A syscall count found the bug behind that step: `fstat` was 1.02 per request. It is now one per wake (7.7 requests per wake on post, 39 on feed).

### Results on the RunPod pod (4dc083f against pavlyhalim, two passes)

| Route | ours µs/req | pavlyhalim µs/req |
|---|---:|---:|
| health | 13.3 | 11.6 |
| feed | 24.7 | 22.5 |
| post | 16.1 | 13.5 |
| like | 54.8 | 35.3 |
| create | 51.9 | 30.8 |
| k6 mix, weighted | about 23 | about 19 |

On the same machine, our CPU per mix request is about 1.2 times pavlyhalim's. On Sunday, before the B-tree and fill/drain work, it was about 2.1 times (27.0 against 12.6 on kali).

Read latency on the pod, one `GET /feed` connection:

| | Alone, p50 | With 64 connections posting likes, p50 / p99 | The likes |
|---|---|---|---|
| ours | 68 µs | 66.8 ms / 99 ms | 914 req/s, p50 66 ms |
| pavlyhalim | 65 µs | 0.77 ms / 3.7 ms | 11,676 req/s, p50 2.3 ms |

A read alone is as fast as the winner's. The 66 ms comes from our commit window (section 4).

shivanshthapliyal did not start on the pod (`setup_buf_ring: Invalid argument`). This is the Ubuntu 6.8 kernel bug from section 1: its code has no `resv[0]=1` retry. Our `feedc.def` has that retry, and our server ran on the pod.

### Profiles: what is left

- The kernel takes 87% of health, 71% of post and 50% of feed.
- On the write routes, the pure-Kotlin SHA-256 (`Sha256Pure.compress`) is the largest user-space cost: 10.3% of create.
- On the feed: `sqlite3BtreeTableMoveto` 6.6%, `feed_json_text` 5.6%, `memmove` 3.6%, record decoding (`fb_cols`) 3.4%, `fstat` 3.0%, `getPageMMap` 1.8%.

## 4. The adopted strategy, faithful to KN

### Principles

- The server is commonMain Kotlin over TrikeShed's io_uring facade, compiled by Kotlin/Native. Ring operations that the facade lacks go into TrikeShed, not into the server.
- C appears only where we measured that Kotlin/Native loses. It loses on byte loops (Kotlin/Native does not vectorize them; JWT parsing is 246 ns native against 81 ns on the JVM) and on cinterop crossings (about 13 ns each). C is also the only way to reach SQLite's private B-tree layer. `feedc.def` is the interim ring layer until the facade carries its operations.
- SQLite stays stock. `feedbt.c` includes the amalgamation unmodified, as the winners do. Changes are compile options and pragmas only.
- The design is fill/drain: fixed capacity that is filled and drained once per wake, then recycled, with no per-request allocation on the hot path and no hash maps.
- Every change is measured first (micro, then knee), tested in C where C is added, and compared old/new/old/new on an idle box.

### Done (formula 1 and part of formula 2)

- B-tree cursor reads for the feed and a single post. The plan assumes nothing about the data: it takes the 20 first entries of the index, uses range scans when the ids lie within 64, and seeks otherwise. Anything unexpected falls back to SQL.
- One read transaction and its cursors per wake (fill). Responses go straight to the C send arena (drain).

### Next, in order of measured size

1. **Reads must not wait for writes.** Today a write opens a transaction that stays open for 64 ms (`COMMIT_WINDOW_NANOS`), and every response in those 64 ms waits for COMMIT, reads too. The winners' answer, taken from lean and scooter: queue each write request in a fixed ring of slots and do not execute it yet. Reads keep the wake's committed snapshot and leave at once. When the window ends, one pass runs BEGIN, executes the queued writes, runs COMMIT, and then sends the 201s. Rule 6 holds, and reads never see uncommitted rows, so they never wait. Then measure the window knee (64, 16, 10, 4, 2 ms) with `COMMIT_WINDOW_US`: CPU per write against write latency.
2. **mmap off, and checkpoints off the loop.** We run `mmap_size` = 1 GB; all five winners turned mmap off (12% of CPU in mojo; 17.6 to 15.5 µs in pavlyhalim). We set no `wal_autocheckpoint`, so SQLite's checkpoint runs on our one loop with its fsyncs. The fix is a nice-19 thread with its own connection and `unix-excl` (which allows the second connection in the same process). That needs `THREADSAFE=2` instead of `locking_mode=EXCLUSIVE`.
3. **Batch formation.** Wait for N completions or T µs when busy (64 or 2 ms in pavlyhalim). We serve 7.7 requests per wake on post; pavlyhalim served 329 per wake on kali.
4. **HMAC pads once.** Check whether `Sha256Pure` hashes the key pads per request. The winners hash the inner and outer pads once at startup, which is allowed (rule 5 forbids result caches, not a key schedule). Move SHA-256 to C if Kotlin/Native still loses.
5. **Pin once and recycle.** The Poller arrays and `Out` buffers are pinned per call today (`refTo` about 1.6%, GC about 4.2% at 64k users).
6. **Memory discipline for 300,000+ users.** Multishot poll plus a read queue instead of a multishot receive per connection, eight `SO_REUSEPORT` listeners, the binary's code locked in RAM, and a small page cache.
7. **Put KN on the scored path.** `start.sh` still runs the JVM. The KN link needs 1.77 to 1.81 GB of non-cache memory, and the box has 1,967 MB with no swap: it must go under about 1.4 GB.

Estimate, not a measurement: if our mix cost stays 1.2 times pavlyhalim's on the box (26 µs there), ours is about 31 µs. At 81% CPU that is about 26,000 req/s, which is about 276,000 users at the board's 0.0945 req/s per user. Items 1 to 3 close most of the remaining 1.2 times.

## 5. Would ngSCTP be a salient upgrade?

**For the score: no.**

- k6 drives HTTP/1.1 over kernel TCP. The server cannot choose the client's transport, so an SCTP path is never scored.
- Measured on equal terms (32,000 users, same client, same server binary): SCTP over UDP cost 148 µs per request against 60 µs for TCP over io_uring, 2.5 times as much. User space was 3 times as much (107 against 36 µs), because our Kotlin SCTP stack does what the kernel does for TCP: checksums, acknowledgements, retransmit state and reassembly. The kernel part was 1.75 times as much (one datagram path per packet, no batching).
- The hardware CRC32c change (TrikeShed `c2a75c953`) is 28 times faster per 1,452-byte packet on kali. But CRC was only 4.8% of the SCTP profile, so it cannot close a 2.5 times gap.
- ngSCTP was designed for card offload: native SCTP, checksum and segmentation in the NIC. The box gives the server no `CAP_NET_RAW` for native SCTP, and kali's virtual NIC reports SCTP offloads as "off [fixed]". The offload we can use is the CPU's CRC instruction plus kernel UDP batching (`UDP_SEGMENT`, `UDP_GRO`), which is not built yet.

**Where it is salient:** the winners stop at the memory wall of about 4 KB of kernel memory per TCP connection. SCTP over one UDP socket holds every association in user space, at a cost we control. For a client that speaks it, such as the concentric-mesh Kademlia track and server-to-server links, it removes that wall. It stays a bench transport beside the scored TCP path.

## 6. Would io_uring changes to SQLite be a salient upgrade?

**No, for three reasons.**

1. **The rules.** The organizer ruled SQLite source patches out; compile options are allowed. A patched amalgamation cannot be scored. Calling SQLite's private B-tree functions through an unmodified, included amalgamation is allowed (PR #153).
2. **Our measurement.** We patched the amalgamation so that WAL writes became SQEs on the application's ring, linked ahead of the 201 SEND. Syscalls fell from 13,146 to 3,009 for 3,000 commits, but system CPU rose (about 0.05 s against 0.025 s on tmpfs; 0.10 against 0.055 on ext4). The kernel punted the buffered file writes to io-wq workers, with a context switch per write. Syscall count was the wrong metric.
3. **The winners' numbers.** SQLite's file I/O is a small part of the request. pavlyhalim measured 0.23 syscalls per request in total, of which 0.095 were WAL `pwrite`s, after its public-API VFS shim merged each commit into one write. Its largest kernel cost was the socket lookup for each incoming packet (14%), not file I/O. The CPU goes to packets and to page lookups in SQLite's cache, and a ring changes neither.

**What does matter on the SQLite side needs no patch:** mmap off; checkpoints and their fsyncs on a nice-19 thread; `unix-excl` (no fcntl lock per transaction; we get the same today from `locking_mode=EXCLUSIVE`); one `pwrite` per commit through a public-API VFS shim (a measured 0.15 `pwrite` per request saved, small); and the B-tree cursor reads. The ring stays where it pays: sockets, accepts, receives and sends.

## 7. State

- Challenge repo, branch `sctp`, local commits only: 098ccd1, 17613be, 4dc083f, and this document. Push guard on. Nothing pushed.
- TrikeShed: c2a75c953 (hardware CRC32c), local.
- Scripts: skill `twelve-dollar-kali-loadtest`, folder `scripts/` (`knee2.sh`, `difftest.sh`, `sysc.sh`, `mixlat.sh`, `winners.sh`, `pod-build.sh`, `pod-bench.sh`).
