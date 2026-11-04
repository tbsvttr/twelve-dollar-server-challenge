# Ruby + io_uring in C + SQLite B-tree reads

So I started reading the code of the other dynamic-language entries, and noticed I'd been limiting
myself by keeping the HTTP layer in pure Ruby. This entry takes a stab at the other split: HTTP and
the connections live in a small server written in C and tuned for this load, and the business logic
stays in Ruby. Let's see how far we can keep the Ruby around.

It's [`ruby-btreereads-cicloid`](../ruby-btreereads-cicloid) with its connection layer moved into
C. Ruby still does routing, JWT verification, body parsing and validation, the writes and group
commit, and decides which transaction the reads use. A second extension, `ext/ring/ring.c`, owns the
sockets, the io_uring rings and the HTTP framing, and calls the app for each request.

A profile of `ruby-btreereads-cicloid` at 120,000 users put about 27% of the CPU in Ruby, and part of
that was `uring.rb` and `uring_server.rb` moving bytes between the rings and the parser. This entry
measures what's left when that part is C.

| | |
|---|---|
| Language | Ruby 4.0.7 with YJIT, built from source with jemalloc and `-march=native` |
| Framework | [async](https://github.com/socketry/async) 2.46.0 reactor on io-event 1.22.1; connections, io_uring and HTTP/1.1 framing in `ext/ring/ring.c` (liburing 2.5 from Ubuntu), driven from `cring_server.rb`, with an epoll fallback in Ruby (`epoll_server.rb`, `epoll.rb`, `http.rb`) |
| SQLite driver | `ext/lite.c`, our own extension, with the SQLite 3.54.0 amalgamation compiled in unmodified, profile-guided on the server's own workload |
| Reads | `GET /feed` and `GET /posts/:id` rendered in `ext/lite.c` from SQLite's B-tree cursor API, as in `ruby-btreereads-cicloid` |
| Writes | SQL: `INSERT ... RETURNING json_object(...)`, group commit |
| JWT | HMAC-SHA256 from libsodium 1.0.22, called through rbnacl 7.1.2's FFI bindings |
| JSON | read documents written by `ext/lite.c`; write documents by SQLite (`json_object`); json 3.1.0 parses request bodies and JWT claims |
| **Nginx or direct** | **Direct**: serves `0.0.0.0:80` itself |

Ruby, SQLite and libsodium are downloaded at pinned versions and checked against their SHA-256 sums.
Every gem, transitive ones included, is pinned with checksums in `Gemfile.lock`.

## Running it

```bash
sudo bash install.sh   # apt build deps, then Ruby, libsodium and the SQLite amalgamation (~10 min on 1 vCPU)
bash build.sh          # gems into vendor/bundle, ext/lite.so (profile-guided, ~3 min), then ext/ring/cring.so
SQLITE_PATH=... JWT_SECRET=... HOST=0.0.0.0 PORT=80 bash start.sh
```

`URING_RINGS` (default 4) sets the number of rings; each holds up to 65,535 connections.
`CONNECTIONS=epoll` forces the Ruby fallback, which the server also takes on its own when the
extension doesn't load or the kernel refuses io_uring.

## What moved into C

`ext/ring/ring.c` does what `uring.rb`, `uring_server.rb` and the request framing in `http.rb` did:

- **Connections** are io_uring direct descriptors (slots in each ring's registered-file table), so
  they don't count against the descriptor limit. Each one has one multishot receive armed for its
  life, fed from a buffer ring. Ubuntu's 6.8.0-136+ kernels refuse the buffer ring's registration
  unless a reserved field is set (Launchpad #2162843), so a refusal is retried with it.
- **Accepts**: eight listening sockets share the port through `SO_REUSEPORT`, and 2,048 accepts stay
  in flight across the rings. With one listener and a few accepts in flight, a burst of new
  connections overflowed the kernel's accept queue (`net.core.somaxconn` is 4,096 on Ubuntu 24.04),
  and clients waited 1, 3, 7 or 15 seconds for their SYN to be retried. Our test VM counted 3 million
  listen-queue drops over the runs before this change and none after.
- **Framing** is `http.rb`'s, byte for byte: the same request-line checks, the same four headers
  (`Content-Length`, `Connection`, `Authorization`, `Transfer-Encoding`), the same 400, 411, 413 and
  431 answers, and the same rule for when a response closes the connection. We checked it against
  the Ruby parser on 31 edge-case requests (pipelined, split, malformed, HTTP/1.0, oversized) with
  both servers on the same database copy.
- **Responses** are copied into shared 1 MB send segments and sent in order, one send in flight per
  connection.

What happens to a request:

1. One Async task per ring waits on the ring's eventfd through the reactor, then calls
   `Cring::Server#process`, which reaps every completion.
2. A `GET` that arrives outside a write batch can't suspend, so C calls `App#call` right there and
   queues the answer. That's about 90% of the load test's requests.
3. Writes, and reads during an open write batch, go back to Ruby as connection ids. Worker fibers
   take each request with `#request`, run it through the app (which may wait for the group commit)
   and hand the answer to `#respond`.
4. The task submits everything queued since the last enter.

The Ruby parser in `http.rb` stays for the epoll fallback and for the warm-up, which runs requests
through the app before the rings start.

## Results on a 1-vCPU test VM

These ran on our Proxmox VM (1 vCPU, 2 GB, Ubuntu 24.04, kernel 6.8.0-147, descriptor limit 65,535,
nothing tuned), with load from `mload` (`bench/mload` in million-users-challenge) on three load VMs,
1 s think time, 5-minute holds, 4 rings.

**120,000 users** (every run saturated the core, so CPU per request is what changes; 0 errors):

| Build | CPU per request | Peak RSS | Objects allocated per request |
|---|---:|---:|---:|
| `ruby-btreereads-cicloid` (#308) | 81.6, 81.9 µs | ~490 MB | 9.1 |
| this entry | 75.6 µs | 376 MB | 6.1 |

About 7.5% less CPU per request and a quarter less memory. The runs were not alternated in one
session, so take the CPU figure as an estimate. The connection layer was a smaller share of the CPU
than the profile suggested: most of the CPU still goes to the kernel's TCP stack and virtio.

**Past the lab's limit**: at 150,000 users this entry served 11,900 requests a second, the most of any
build we tested, with 0.00% errors, but p95 was 6.4 s, so it fails the hold. At 170,000 it still
answered (11,500 requests a second, 0.04% timeouts) and stayed within memory. At 190,000 the kernel's
socket buffers and our heap together outgrew the VM's 2 GB, and the OOM killer stopped the server.
Our VM is slower than the benchmark droplet, so these runs say where the code breaks, not what it
scores.

Test suite: 42/42, on io_uring and on the epoll fallback.

## Trade-offs

- More of the server is C than in `ruby-btreereads-cicloid`: the connection layer and the framing,
  about 840 lines. Ruby still does everything that decides what a response says.
- C calls into Ruby for each read under `rb_protect`. If the app raises, C closes that connection,
  finishes the pass over the ring and then re-raises in Ruby, so the ring's state never goes half
  updated.
- The framing exists twice, in `ring.c` and in `http.rb` for the fallback. They have to change
  together.
- The rest is as in [`ruby-btreereads-cicloid`](../ruby-btreereads-cicloid#trade-offs): Linux only,
  the read path in C tied to the pinned SQLite version and this schema, no idle timeout.

## License

MIT, under the repo's [license](../../LICENSE).
