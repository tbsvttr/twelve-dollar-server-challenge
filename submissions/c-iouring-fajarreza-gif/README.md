# c-iouring-fajarreza-gif: C + io_uring + Clean Official SQLite

A direct HTTP/1.1 feed API server built in **C11** using Linux **`io_uring`** and **SQLite**, designed for maximum concurrency and sub-millisecond latencies on low-spec hardware without clobbering SQLite's internal codebase.

Unlike submissions that hack private B-tree headers (`sqlite3BtreeCursor`) or compile SQLite with altered internals, this server uses the **official, unmodified SQLite 3.53.2+ amalgamation** solely through its published public C API (`sqlite3.h`).

---

## Technical Specifications

| Component | Choice / Version |
|---|---|
| **Language / Compiler** | C11, GCC 13+ (`-O3 -march=native`) |
| **Event Loop** | 8 io_uring rings (primary + 7 eventfd-multiplexed secondary rings, zero liburing) |
| **Direct Descriptors** | 8 rings × 45,000 slots = **360,000 direct descriptors** (`IORING_FILE_INDEX_ALLOC`) |
| **Kernel Buffers** | `IORING_REGISTER_PBUF_RING` (8 × 1,024 × 2 KB provided buffer rings) |
| **Listen Sockets** | 8 sockets with `SO_REUSEPORT` on port 80 (combined 32,768 listen queue) |
| **Database** | Official unmodified SQLite 3.53.2+ amalgamation compiled to `sqlite3.o` |
| **Database API** | 100% public SQLite C API (`sqlite3.h`), persistent statements, zero B-tree hacks |
| **Memory Footprint** | Measured **4.7 MB RSS** (0 mmap, 8 MB cache, 8.3 MB response pool) |
| **Crypto** | Zero-alloc HMAC-SHA256 with precomputed key schedules (~83 ns / token) |
| **Network Mode** | Direct on `0.0.0.0:80` (or `HOST:PORT`), HTTP/1.1 persistent keep-alive |

---

## Key Optimizations

1. **Persistent Prepared Statements (`SQLITE_PREPARE_PERSISTENT`):**
   Compiled once at startup via `sqlite3_prepare_v3` with `SQLITE_PREPARE_PERSISTENT`. SQLite optimizes the query plan bytecode for infinite reuse. `sqlite3_reset` and `sqlite3_clear_bindings` recycle statement state with zero memory allocations per request.

2. **Ultra-Low Memory Footprint & Focused Page Cache:**
   SQLite `mmap` is disabled (`PRAGMA mmap_size = 0`) to avoid per-fetch WAL-index lookups and eliminate 256 MB of virtual memory. An 8 MB page cache (`PRAGMA cache_size = -8192`) cleanly covers the active ~2 MB working set. Sockets inherit 8 KB buffers via `SO_RCVBUF`/`SO_SNDBUF`, and response pools are compacted to 8.3 MB, keeping overall process RSS under **5 MB**.

3. **Single-Core Zero-Mutex Compilation:**
   Built with `-DSQLITE_THREADSAFE=0`. In a single-threaded `io_uring` event loop, removing all internal POSIX mutexes and atomic memory barriers yields significant speedups on every SQLite invocation.

4. **Group Commit for Durable Writes & Read Transaction Coalescing:**
   All write requests arriving in the same pass are group-committed within one `BEGIN IMMEDIATE` ... `COMMIT` transaction. Simultaneously, reads in a pass execute inside a shared SQLite read transaction, eliminating thousands of per-query lock acquisitions.

5. **8 Rings & 360,000 Direct Descriptors with Safe Margins:**
   8 `io_uring` rings multiplexed by a single thread via `eventfd` and 8 `SO_REUSEPORT` listeners scale connection capacity to 360,000 direct descriptors with a 32,768 SYN backlog. Connections are tracked per ring (`g_ring_conns`) with graceful keep-alive recycling 2,048 slots before ring limit and an accept hold 1,024 slots before limit, preventing `-ENFILE` drops or `ECONNRESET` disconnects during rapid ramp-ups.

6. **Provided Buffer Rings (`IORING_REGISTER_PBUF_RING`):**
   Inbound socket data is placed directly by the kernel into a provided buffer ring. Buffers are returned with an atomic store (`STORE_REL(&br->tail)`), requiring zero system calls for buffer management.

7. **Multishot Polling for Idle Keep-Alive:**
   Connections wait on multishot poll (`IORING_OP_POLL_ADD` with `IORING_POLL_ADD_MULTI`), consuming minimal kernel memory and zero userspace buffers while idle.

8. **SIMD/SWAR 32-Bit HTTP Parsing:**
   Method matching compares a single 32-bit integer against `"GET "` (`0x20544547U`) and `"POST"` (`0x54534f50U`), bypassing character-by-character scanning.

---

## Verification & Benchmarks

* **Functional Test Suite (`test/test.sh`):**
  **42 / 42 passed (100%)**, verifying exact byte-for-byte responses, RFC 8259 compliance, and HTTP status codes.
* **k6 Load Test (`bench/load.js`):**
  * **Checks passed:** 100.00% (0 errors across 2,000+ VUs)
  * **Average latency:** ~340 µs
  * **Median latency:** ~300 µs
  * **p95 latency:** ~590 µs
  * **p99 latency:** ~790 µs

---

## Acknowledgements & Credits

- The low-level `io_uring` direct Linux ABI syscall wrapper (`src/sys.h`) and SHA-256 implementation (`src/sha256.h`) are adapted from and credit the work of **Pavly Halim** ([`c-iouring-pavlyhalim`, PR #245](https://github.com/arjaythedev/twelve-dollar-server-challenge/pull/245)). Server event loop handling, HTTP parser, JWT token verification, and clean SQLite database engine are independent implementations.
