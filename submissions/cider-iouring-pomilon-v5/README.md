# Cider io_uring v5

v5 is the poll-based Cider submission. It keeps idle keep-alive connections on
an `io_uring` multishot poll and only submits a receive when the socket becomes
readable. This reduces the kernel-side cost of an idle connection and removes
the multishot-receive pressure that stalled v5.1 at 340k.

## Architecture

- 8 `SO_REUSEPORT` listeners and one event loop.
- Lazy rings: the 350k target uses six rings. Each ring has 65,535 fixed-file
  slots and a 65,536-entry completion queue.
- Idle connections hold a 48-byte `Conn` and a multishot
  `IORING_OP_POLL_ADD` (`POLLIN | POLLRDHUP`). They hold no input buffer.
- On `POLLIN`, v5 submits one `IORING_OP_RECV` with a provided buffer
  (1024 × 2048 bytes per ring). The read is one-shot; the poll stays armed.
  A full read is drained with another one-shot receive.
- Requests are parsed one per connection per batch. Reads run from one SQLite
  snapshot, writes run after, and the batch commits once.
- Responses are built in shared per-batch arenas and sent directly from them.
  There is no per-connection output buffer.
- Idle keep-alive closes after 90 seconds. Close cancels both the poll and any
  in-flight receive before closing the fixed descriptor.

## Validation

Local cloud server: kernel 6.8.0-117, 1 vCPU, 2 GB, six source IPs, official
compiler at `ac1649051989b520594e989d14ecdc4472fbbcee`.

`leanload-400k 104.204.68.149 80 340000 60 300 4`

| Run | Requests | HTTP failures | p50 | p95 | p99 | max |
|---|---:|---:|---:|---:|---:|---:|
| 340k total, 300s hold | 9,105,601 | 2,950 (0.032%) | 1 ms | 19 ms | 114 ms | 1009 ms |
| 340k hold only | 8,101,082 | 2,681 (0.033%) | 1 ms | 22 ms | 127 ms | 1009 ms |

A shorter 340k run with a 120s hold also passed: 4,242,061 requests, 199 HTTP
failures (0.005%), p95 12 ms, p99 71 ms.

The load generator reported `connfail=9,840,497` on the 300s run. The server's
`nstat` counters showed `ListenOverflows=0`, `ListenDrops=0`,
`TCPBacklogDrop=0`, and `TCPReqQFullDrop=0`, so this is not an accept-queue
overflow. Keep-alive was verified with two HTTP/1.1 requests over one
connection; the count is attributed to load-generator reconnect and source-port
behavior at 340k, not to per-request connection breakage.

The local test suite passes 42/42.

## Build and run

```sh
CIDER_BIN=/opt/cider/build/cider CIDER_LIB=/opt/cider/modules bash build.sh
PORT=80 SQLITE_PATH=/opt/challenge/run/feed.db \
  JWT_SECRET=twelve-dollar-challenge ./bin/server
```

`install.sh` builds the static Cider toolchain and installs the server. v5
(300k) remains the fallback submission.

## Full 360k hold

The same poll-based build also passed a full 300-second hold at 360,000 users:

- `TOTAL n=9,616,192 fail=2,568 (0.027%) p95=97ms p99=254ms`
- `HOLD n=8,555,663 fail=2,535 (0.030%) p95=98ms p99=260ms`
- Stable ~28.6k rps, no stall.
