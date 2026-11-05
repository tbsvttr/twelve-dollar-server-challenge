# Rust + io_uring + SQLite B-Tree Cursor Engine (`rust-iouring-tbsvttr`)

- **Language / Runtime:** Rust `1.94.0` (2024 edition, zero external crates) + C11 FFI (`cc`)
- **HTTP / I/O Engine:** Raw multi-ring `io_uring` (`SINGLE_ISSUER | DEFER_TASKRUN | TASKRUN_FLAG | SUBMIT_ALL`)
- **SQLite Version:** Stock SQLite Amalgamation `3.54.1` (`3540100`), SHA-256 verified in `build.sh`
- **Front:** Direct (`0.0.0.0:80` via 8 `SO_REUSEPORT` TCP listeners)

## Architecture & Key Optimizations

1. **Dynamic Multi-Ring `io_uring` with Full `RLIMIT_NOFILE` Direct Descriptor Tables:**
   - Raises `RLIMIT_NOFILE` to the hard limit (`1,048,576`) and registers a sparse direct descriptor table of size `slots` (`IORING_RSRC_REGISTER_SPARSE`) on each `io_uring` ring, dynamically spilling to additional rings (up to `MAX_RINGS = 16`) if a ring fills.
   - Uses 1,024-buffer provided buffer rings (`IOSQE_BUFFER_SELECT`, 2 KB stride) with bounded `MSG_DONTWAIT` read rounds (`READS_PER_PASS = 16,384`, `ANSWERS_PER_PASS = 2,048`) so buffers are immediately recycled without `ENOBUFS` churn.
   - Includes automatic fallback for the Ubuntu 24.04 kernel `6.8.0-136+` `io_register_pbuf_ring` `resv` check bug (Launchpad #2162843).

2. **Stock SQLite B-Tree Cursor Read Engine + Monotonic Leaf Walks:**
   - Compiles unmodified SQLite `3.54.1` in `csrc/engine.c` with `"unix-excl"` VFS (heap-resident WAL index shared across the process's connections without `-shm` file lock overhead) and drives SQLite's B-tree cursor API (`sqlite3BtreeBeginTrans`, `sqlite3BtreeCursor`, `sqlite3BtreeTableMoveto`, `sqlite3BtreeIndexMoveto`, `sqlite3BtreeFirst`, `sqlite3BtreeNext`) inside a shared per-pass transaction.
   - Reverses descending `/feed` post IDs into ascending order without sorting when monotonic, stepping `cur_posts` across consecutive IDs via `sqlite3BtreeNext` (`O(1)` leaf step instead of full B-tree binary search) and counting likes across the 20-post range in a single direct leaf-cell scan (`tvcc_count_likes_range`).
   - Deduplicates and sorts unique `user_id`s per `/feed` pass so `cur_users` walks leaf pages monotonically.

3. **Two-Stage Condition-Variable `nice(19)` Checkpoint State Machine (`250 ms` Hold Cap):**
   - Tracks exact WAL length via `sqlite3_wal_hook` and wakes the `nice 19` checkpoint thread via `pthread_cond_signal` only between event-loop passes (when no read transaction is open on `db`).
   - **Stage 1 (`CK_BULK` at 4,096 frames):** Runs a `PASSIVE` checkpoint in the background while writes continue unblocked.
   - **Stage 2 (`CK_TAIL`):** Holds incoming `POST` requests between passes only for the tiny remaining WAL tail so the next write resets the WAL to frame 1, enforcing a hard `HOLD_MAX_MS = 250 ms` cap so tail latency (`p99`) never spikes under 1-vCPU saturation.

4. **Single-Reservation SIMD (`AVX2` / `SSE2` / `SWAR`) JSON Serializer & Single-Pass HTTP Parser:**
   - `fill_json` reserves the worst-case output bound once per response and writes JSON via raw pointer stores, copying and checking string bodies for JSON special characters (`< 0x20`, `'"'`, `'\\'`) 32 bytes at a time with AVX2 (`_mm256_min_epu8` + `_mm256_movemask_epi8`), 16 bytes with SSE2, and 8 bytes with 64-bit SWAR.
   - `parse_http_request` parses the request line and headers in a single `memchr('\n')` pass.


