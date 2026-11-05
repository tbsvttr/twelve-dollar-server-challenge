# Rust + io_uring + SQLite B-Tree Cursor Engine (`rust-iouring-tbsvttr`)

- **Language / Runtime:** Rust `1.94.0` (2024 edition) + C11 FFI (`cc`)
- **HTTP / I/O Engine:** Raw multi-ring `io_uring` (`SINGLE_ISSUER | DEFER_TASKRUN | COOP_TASKRUN | TASKRUN_FLAG`)
- **SQLite Version:** Stock SQLite Amalgamation `3.54.1` (`3540100`), SHA-256 verified in `build.sh`
- **Front:** Direct (`0.0.0.0:80` via 8 `SO_REUSEPORT` TCP listeners)

## Architecture & Key Optimizations

1. **Multi-Ring `io_uring` with `IORING_SETUP_TASKRUN_FLAG`:**
   - Uses two single-issuer `io_uring` rings on the single event-loop thread, each with 4 `SO_REUSEPORT` multishot `AcceptMulti` listeners, a 32,768-slot direct descriptor table (`IOSQE_FIXED_FILE`), and a 2,048-buffer provided buffer ring (`IOSQE_BUFFER_SELECT`).
   - Checks `IORING_SQ_TASKRUN` on the secondary ring to skip `io_uring_enter(GETEVENTS)` syscalls when idle.
   - Includes automatic fallback for the Ubuntu 24.04 kernel `6.8.0-136+` `io_register_pbuf_ring` `resv` check bug (Launchpad #2162843).
   - Uses `SendZc` (zero-copy transmit) for `/feed` responses (`>= 2 KB`) and regular `Send` (`MSG_NOSIGNAL`) for small responses, paired with a bounded read-drain queue (`192` reads per pass) so heavy read bursts cannot starve accept or write completions.

2. **Stock SQLite B-Tree Cursor Read Engine + Group Prefetching:**
   - Compiles unmodified SQLite `3.54.1` in `csrc/engine.c` and drives SQLite's internal B-tree cursor API (`sqlite3BtreeBeginTrans`, `sqlite3BtreeCursor`, `sqlite3BtreeTableMoveto`, `sqlite3BtreeIndexMoveto`, `sqlite3BtreeFirst`, `sqlite3BtreeNext`) inside a shared per-tick read transaction.
   - Sorts `/feed` post IDs ascending before probing `posts` and `likes_post_id_idx` so B-tree cursors walk leaf pages monotonically left-to-right.
   - Resolves unique `users` rows via level-by-level group prefetching (`__builtin_prefetch` on `aCellIdx`) and interpolation-guided binary search over contiguous `user_id` keys.

3. **Custom VFS WAL Write-Coalescer & Fast-Truncate Page Cache Wrapper:**
   - Wraps `unix-excl` via `sqlite3_vfs_register` to coalesce consecutive WAL frame header + page writes into a single `pwrite` syscall when the commit frame (`nTruncate != 0`) arrives.
   - Wraps SQLite's default `pcache1` via `SQLITE_CONFIG_PCACHE2` (`PRAGMA cache_size = -16384`, `PRAGMA mmap_size = 0`) to track the maximum real page number and skip redundant full-cache hash walks on `xTruncate`.

4. **Background `nice(19)` Checkpoint Thread with Pre-Synced WAL Frame 1:**
   - Runs passive WAL checkpoints every 35 ms on a second connection at `nice(19)`.
   - When the WAL reaches a tail reset (`nlog == nckpt`), pre-writes WAL Frame 1 on the `nice(19)` background thread (`PRAGMA user_version`) while writes are held so the WAL header `fdatasync()` never stalls the main `io_uring` event loop.

