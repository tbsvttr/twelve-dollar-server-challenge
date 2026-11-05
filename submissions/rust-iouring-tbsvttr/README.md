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

2. **Stock SQLite B-Tree Cursor Read Engine, Interpolated Multi-Key Descent & WAL/PCache Plugins:**
   - Compiles unmodified SQLite `3.54.1` in `csrc/engine.c` with:
     - **`SQLITE_CONFIG_PCACHE2` `xTruncate` Max-Key Filter (`tvcc_pcache_install`):** Tracks the highest non-lock-byte page number entering `pcache1` and skips full hash-table walks on `COMMIT` when `n_parked == 0 && max_key < limit` (avoiding the permanent `iMaxKey = 262,145` lock-byte page inflation after B-tree page splits).
     - **WAL Write-Coalescing VFS Shim (`"tvcc-wal"` over `"unix-excl"`):** Buffers consecutive WAL frame header + page appends and flushes each transaction commit in a single `pwrite()` syscall while keeping the WAL index in process heap memory without `fcntl()` lock syscalls.
   - Drives SQLite's B-tree cursor API (`sqlite3BtreeBeginTrans`, `sqlite3BtreeCursor`, `sqlite3BtreeTableMoveto`, `sqlite3BtreeIndexMoveto`, `sqlite3BtreeFirst`, `sqlite3BtreeNext`) inside a shared per-pass transaction.
   - Extracts `created_at` directly from `posts_created_at_id_idx` (`cur_feed`) so `cur_posts` only decodes `(user_id, body)`, reverses descending `/feed` post IDs into ascending order so `sqlite3BtreeTableMoveto`'s internal `nKey + 1 == intKey` fast path steps across consecutive leaf cells in `O(1)`, and counts likes across the 20-post range in a single direct leaf-cell scan (`tvcc_count_likes_range`).
   - Resolves unique `/feed` `user_id`s via level-by-level interpolated B-tree descent (`tvcc_bt_lower_bound` + `__builtin_prefetch`), overlapping L3 cache misses across user leaf pages and finding dense integer user keys in 1–2 probes instead of 7–9 binary search probes.

3. **Two-Stage Condition-Variable `nice(19)` Checkpoint State Machine (`250 ms` Hold Cap):**
   - Tracks exact WAL length via `sqlite3_wal_hook` and wakes the `nice 19` checkpoint thread via `pthread_cond_signal` only between event-loop passes (when no read transaction is open on `db`).
   - **Stage 1 (`CK_BULK` at 4,096 frames):** Runs a `PASSIVE` checkpoint in the background while writes continue unblocked.
   - **Stage 2 (`CK_TAIL`):** Holds incoming `POST` requests between passes only for the tiny remaining WAL tail so the next write resets the WAL to frame 1, enforcing a hard `HOLD_MAX_MS = 250 ms` cap so tail latency (`p99`) never spikes under 1-vCPU saturation.

4. **8 KB Pool-Preserving SIMD (`AVX2` / `SSE2` / `SWAR`) JSON Serializer & Single-Pass HTTP Parser:**
   - `fill_json` reserves `1x` input length (`+ 64` bytes SIMD/escape slack) upfront so `/feed` responses (~3.6 KB) always fit inside the 8 KB (`OUT_CAP = 8192`) pooled `Vec<u8>` buffers with zero `realloc`/`munmap` churn and 100% buffer pool reuse, expanding via `#[cold] fn grow_cold` only if a string contains heavy control-character escaping.
   - Copies and checks string bodies for JSON special characters (`< 0x20`, `'"'`, `'\\'`) 32 bytes at a time with AVX2 (`_mm256_min_epu8` + `_mm256_movemask_epi8`), 16 bytes with SSE2, and 8 bytes with 64-bit SWAR.
   - `parse_http_request` parses the request line and headers in a single `memchr('\n')` pass.


