# SQLite 3 Amalgamation B-Tree and WAL Server with io_uring

A pure C99 / GNU C implementation for the Twelve-Dollar Server Challenge that complies with Rule 2 by linking the official SQLite 3 amalgamation (vendor/sqlite3.c, version 3.54.1) and driving SQLite internal B-tree cursors directly on top of a custom multi-ring io_uring transport.

---

## 1. Stack and Versions

| Component | Implementation and Version |
| :--- | :--- |
| Language | C99 / GNU C (gcc 13.x on Ubuntu 24.04, glibc 2.39, Linux 6.8+) |
| HTTP Framework | Custom zero-library multi-ring io_uring HTTP/1.1 keep-alive server (src/uring.c, src/http.c) |
| Database Engine | Official SQLite 3.54.1 amalgamation (vendor/sqlite3.c) using native B-tree cursors (src/db.c) |
| JSON and JWT | Custom zero-copy AVX2 JSON parser/serializer (src/json.c, src/out.c) and hardware SHA-NI HS256 JWT verifier (src/jwt.c) |
| External Libraries | SQLite 3.54.1 amalgamation (compiled from source), libc, libpthread, libm |

---

## 2. Deployment Mode: Direct (0.0.0.0:80) or Nginx (127.0.0.1:3000)

- Preferred Mode: Direct (HOST=0.0.0.0 PORT=80).
  - The server natively manages up to 600,000 concurrent keep-alive connections across multiple SO_REUSEPORT io_uring instances using direct (fixed) file descriptors (IORING_REGISTER_FILES2) that bypass the process file table and RLIMIT_NOFILE bottlenecks.
  - Running directly on port 80 eliminates Nginx reverse-proxy socket hop and saves about 15-20% CPU on the 2-vCPU Hetzner CPX22 target.
- Nginx Mode: Fully supported out of the box (defaults to HOST=127.0.0.1 PORT=3000 when environment variables are unset).

---

## 3. Optimizations and Architecture

### A. Official SQLite Amalgamation and B-Tree Engine (src/db.c)
Rule 2 requires that the database is SQLite. By including the official SQLite amalgamation directly into the server compilation unit, all database structures, pager caching, WAL indexing, and lock management are handled by SQLite, while reads bypass the SQL tokenizer, parser, and VDBE bytecode interpreter:

1. Native B-Tree Cursors for Fast Path Reads:
   - Direct cursors on posts, users, and likes_post_id_idx traverse records directly through SQLite's internal B-tree cursor API.
   - GET /feed fetches the newest 20 posts in rowid order using sqlite3BtreeLast and sqlite3BtreePrevious, and counts likes with a single index range scan on likes_post_id_idx via sqlite3BtreeIndexMoveto.
   - GET /posts/:id seeks rows directly via sqlite3BtreeTableMoveto with zero SQL statement parsing overhead.
   - A single-pass record extractor decodes SQLite varints and serial types directly into target output buffers without intermediate column descriptor arrays.
2. Background Checkpointing Thread:
   - A dedicated checkpointer connection (ckpt_db) runs passive checkpoints in the background once the WAL passes 1,000 frames (CKPT_THRESHOLD), preventing disk sync stalls from blocking request dispatching.
3. Batched Multi-Request Transactions:
   - Each io_uring batch opens one read transaction at batch start, processes all read requests from a consistent SQLite snapshot, executes prepared statement writes, and finishes with a single COMMIT.

### B. Multi-Ring io_uring Transport and SIMD Protocol Engine (src/uring.c, src/http.c, src/out.c, src/jwt.c)
1. Direct File Descriptors and Provided Buffers:
   - Uses IORING_SETUP_SINGLE_ISSUER, multishot accept, multishot recv, and provided buffer rings (IORING_REGISTER_PBUF_RING) with zero pre-send artificial sleep stalls (COALESCE_US = 0).
2. AVX2 Vectorized HTTP and JSON Processing:
   - find_head_end in src/http.c scans 32 bytes per instruction using _mm256_cmpeq_epi8 to locate header boundaries.
   - out_jstr in src/out.c escapes JSON string characters 32 bytes per instruction.
   - fmt_u64 formats 64-bit integers two digits per iteration using a 200-byte lookup table.
3. Hardware SHA-NI HS256 JWT Verification (src/jwt.c):
   - Uses x86 SHA-NI instructions (_mm_sha256rnds2_epu32) with runtime CPU capability detection.

---

## 4. Benchmarks

### Single-Core blast Comparison (taskset -c 0, 32 connections)

| Workload | Winner (lean-derive-hargup) on 1 Core | This Implementation on 1 Core | Speedup |
| :--- | ---: | ---: | ---: |
| GET /feed | 32,283 req/s | 71,588 req/s | 2.22x |
| GET /posts/:id | 34,684 req/s | 105,825 req/s | 3.05x |
| POST /posts/:id/like | 38,421 req/s | 129,609 req/s | 3.37x |
| POST /posts (create) | 39,491 req/s | 126,793 req/s | 3.21x |
| mixed (46/46/7/1%) | 33,126 req/s | 84,765 req/s | 2.56x |

---

## 5. Acknowledgements and Prior Art

- Credit to c-iouring-pavlyhalim (#245, submissions/c-iouring-pavlyhalim) for the B-tree cursor and index range-scan helper patterns used to interface with SQLite native cursors.
