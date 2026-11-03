# Python on PyPy, raw io_uring, SQLite's B-tree cursors

| | |
|---|---|
| Language | Python (3.9 dialect) on **PyPy 7.3.15** |
| Framework | none: HTTP/1.1 and the io_uring rings are Python in `server.py` |
| SQLite | unmodified 3.54.1 amalgamation, SHA-256 pinned, built into a cffi module by `build.sh` |
| **Nginx or direct** | **Direct** |
| Needs | Linux 6.4+ with io_uring enabled |

## Optimizations

- **io_uring from Python.** Completions are handled in batches, with one `io_uring_enter` per batch, so a request costs
  far fewer syscalls than with epoll.
- **Direct descriptors.** Sockets live in fixed-file tables across up to 8 rings, so `LimitNOFILE` doesn't force
  connections to be recycled.
- **No per-connection objects.** Multishot accept and receive with provided buffers keep idle connections cheap.
- **B-tree cursor reads.** `/feed` and `/posts/:id` skip the bytecode interpreter. `/feed` uses one range scan each for
  likes and posts. Unexpected records fall back to SQL.
- **Group commit.** Writes in a batch share a transaction, and each response is sent after the commit.

Nothing is cached across requests, and every token's signature and `exp` are checked on every request.

The C in the process is SQLite, OpenSSL's `HMAC()`, cffi's generated wrappers, and a few hand-written syscall wrappers
and accessors in `build_sqlite.py`.

## Results

Measured on an arm64 Mac over loopback with #84's load generator, so these aren't comparable with the leaderboard.
5-minute hold, server limited to one CPU and 2 GB:

| Submission | Users | req/s | p95 | p99 | Errors |
|---|---:|---:|---:|---:|---:|
| this submission | 250,000 | 26,338 | 140 ms | 308 ms | 0 |
| python-pypy-epoll (#84) | 150,000 | 15,790 | 60 ms | 611 ms | 24 |

## Credits

- [python-pypy-epoll-pranavds-codes](../python-pypy-epoll-pranavds-codes) (#84): HTTP parsing, strict JSON loading, JWT
  checks and SQL statements are adapted from it. Its load generator and edge-case tests were used for testing.
- [c-iouring-pavlyhalim](../c-iouring-pavlyhalim) (#245): the B-tree read plan, ring and listener layout, and the
  provided-buffer retry for Ubuntu's 6.8.0-136+ kernels.

MIT, under the repo's [license](../../LICENSE).
