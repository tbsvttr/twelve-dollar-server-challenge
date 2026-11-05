/* sys.h: raw syscalls and the io_uring ABI, no liburing. One ring = one SQ, one CQ, one
 * sparse table of direct descriptors and one provided-buffer ring. */
#ifndef SYS_H
#define SYS_H

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/io_uring.h>
#include <linux/time_types.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <signal.h>
#include <sys/eventfd.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <alloca.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

/* Constants the Ubuntu 24.04 headers have; defined here anyway so an older header still builds. */
#ifndef IORING_SETUP_CQSIZE
#define IORING_SETUP_CQSIZE (1U << 3)
#endif
#ifndef IORING_SETUP_CLAMP
#define IORING_SETUP_CLAMP (1U << 4)
#endif
#ifndef IORING_SETUP_SUBMIT_ALL
#define IORING_SETUP_SUBMIT_ALL (1U << 7)
#endif
#ifndef IORING_SETUP_COOP_TASKRUN
#define IORING_SETUP_COOP_TASKRUN (1U << 8)
#endif
#ifndef IORING_SETUP_SINGLE_ISSUER
#define IORING_SETUP_SINGLE_ISSUER (1U << 12)
#endif
#ifndef IORING_SETUP_DEFER_TASKRUN
#define IORING_SETUP_DEFER_TASKRUN (1U << 13)
#endif
#ifndef IORING_ENTER_GETEVENTS
#define IORING_ENTER_GETEVENTS (1U << 0)
#endif
#ifndef IORING_ENTER_EXT_ARG
#define IORING_ENTER_EXT_ARG (1U << 3)
#endif
#ifndef IORING_FEAT_SINGLE_MMAP
#define IORING_FEAT_SINGLE_MMAP (1U << 0)
#endif
#ifndef IORING_FEAT_EXT_ARG
#define IORING_FEAT_EXT_ARG (1U << 8)
#endif
#ifndef IORING_RECV_MULTISHOT
#define IORING_RECV_MULTISHOT (1U << 1)
#endif
#ifndef IORING_ACCEPT_MULTISHOT
#define IORING_ACCEPT_MULTISHOT (1U << 0)
#endif
#ifndef IORING_FILE_INDEX_ALLOC
#define IORING_FILE_INDEX_ALLOC (~0U)
#endif
#ifndef IORING_REGISTER_FILES2
#define IORING_REGISTER_FILES2 13
#endif
#ifndef IORING_REGISTER_PBUF_RING
#define IORING_REGISTER_PBUF_RING 22
#endif
#ifndef IORING_RSRC_REGISTER_SPARSE
#define IORING_RSRC_REGISTER_SPARSE (1U << 0)
#endif
#ifndef IOSQE_FIXED_FILE
#define IOSQE_FIXED_FILE (1U << 0)
#endif
#ifndef IOSQE_IO_HARDLINK
#define IOSQE_IO_HARDLINK (1U << 3)
#endif
#ifndef POLLRDHUP
#define POLLRDHUP 0x2000
#endif
#ifndef IOSQE_BUFFER_SELECT
#define IOSQE_BUFFER_SELECT (1U << 4)
#endif
#ifndef IOSQE_CQE_SKIP_SUCCESS
#define IOSQE_CQE_SKIP_SUCCESS (1U << 6)
#endif
#ifndef IORING_CQE_F_BUFFER
#define IORING_CQE_F_BUFFER (1U << 0)
#endif
#ifndef IORING_CQE_F_MORE
#define IORING_CQE_F_MORE (1U << 1)
#endif
#ifndef IORING_CQE_BUFFER_SHIFT
#define IORING_CQE_BUFFER_SHIFT 16
#endif
#ifndef IORING_OFF_SQ_RING
#define IORING_OFF_SQ_RING 0ULL
#define IORING_OFF_CQ_RING 0x8000000ULL
#define IORING_OFF_SQES 0x10000000ULL
#endif

#define LOAD_ACQ(p) atomic_load_explicit((_Atomic __typeof__(*(p)) *)(p), memory_order_acquire)
#define STORE_REL(p, v) atomic_store_explicit((_Atomic __typeof__(*(p)) *)(p), (v), memory_order_release)
#define LOAD_RLX(p) atomic_load_explicit((_Atomic __typeof__(*(p)) *)(p), memory_order_relaxed)

static inline long sys_io_uring_setup(unsigned entries, struct io_uring_params *p) {
  long r = syscall(__NR_io_uring_setup, entries, p);
  return r < 0 ? -errno : r;
}
static inline long sys_io_uring_enter(int fd, unsigned to_submit, unsigned min_complete, unsigned flags,
                                      const void *arg, size_t argsz) {
  long r = syscall(__NR_io_uring_enter, fd, to_submit, min_complete, flags, arg, argsz);
  return r < 0 ? -errno : r;
}
static inline long sys_io_uring_register(int fd, unsigned op, const void *arg, unsigned nr) {
  long r = syscall(__NR_io_uring_register, fd, op, arg, nr);
  return r < 0 ? -errno : r;
}

/* Provided receive buffers: a power-of-two ring of descriptors and the buffer memory behind it. */
#define BUF_GROUP 0

struct ring {
  int fd;
  unsigned sq_entries, cq_entries, sq_mask, cq_mask;
  unsigned sq_local_tail; /* SQEs written but not yet published */
  unsigned *sq_head, *sq_tail, *sq_flags, *sq_array;
  unsigned *cq_head, *cq_tail;
  struct io_uring_cqe *cqes;
  struct io_uring_sqe *sqes;
  void *sq_ptr, *cq_ptr;
  size_t sq_sz, cq_sz, sqes_sz;
  /* provided buffers */
  struct io_uring_buf_ring *br;
  unsigned br_entries, br_mask, br_tail;
  unsigned buf_size;
  uint8_t *bufs;
  unsigned bufs_out; /* buffers currently held by the kernel or by us */
  /* direct descriptor table */
  unsigned nslots;
};

/* `defer`: DEFER_TASKRUN, for the ring the loop waits on. The other rings use ordinary task
 * work, so their completions are posted (and their eventfd signalled) while the loop sleeps
 * in the first ring's wait; with DEFER_TASKRUN that only happens when the ring is entered. */
static int ring_init(struct ring *r, unsigned sq_entries, unsigned cq_entries, unsigned nslots,
                     unsigned nbufs, unsigned buf_size, int defer, const char **err) {
  memset(r, 0, sizeof *r);
  struct io_uring_params p;
  memset(&p, 0, sizeof p);
  p.flags = IORING_SETUP_CQSIZE | IORING_SETUP_CLAMP | IORING_SETUP_SUBMIT_ALL | IORING_SETUP_SINGLE_ISSUER |
            (defer ? IORING_SETUP_DEFER_TASKRUN : 0);
  p.cq_entries = cq_entries;
  long fd = sys_io_uring_setup(sq_entries, &p);
  if (fd == -EINVAL && defer) { /* older kernel: fall back to cooperative task running */
    memset(&p, 0, sizeof p);
    p.flags = IORING_SETUP_CQSIZE | IORING_SETUP_CLAMP | IORING_SETUP_SUBMIT_ALL | IORING_SETUP_SINGLE_ISSUER |
              IORING_SETUP_COOP_TASKRUN;
    p.cq_entries = cq_entries;
    fd = sys_io_uring_setup(sq_entries, &p);
  }
  if (fd < 0) { *err = "io_uring_setup"; errno = (int)-fd; return -1; }
  if (!(p.features & IORING_FEAT_SINGLE_MMAP) || !(p.features & IORING_FEAT_EXT_ARG)) {
    *err = "io_uring: kernel too old (needs SINGLE_MMAP and EXT_ARG)"; errno = ENOSYS; return -1;
  }
  r->fd = (int)fd;
  r->sq_entries = p.sq_entries;
  r->cq_entries = p.cq_entries;
  r->sq_sz = p.sq_off.array + p.sq_entries * sizeof(unsigned);
  r->cq_sz = p.cq_off.cqes + p.cq_entries * sizeof(struct io_uring_cqe);
  if (r->cq_sz > r->sq_sz) r->sq_sz = r->cq_sz;
  r->sq_ptr = mmap(NULL, r->sq_sz, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE, r->fd, IORING_OFF_SQ_RING);
  if (r->sq_ptr == MAP_FAILED) { *err = "mmap sq"; return -1; }
  r->cq_ptr = r->sq_ptr;
  r->sqes_sz = p.sq_entries * sizeof(struct io_uring_sqe);
  r->sqes = mmap(NULL, r->sqes_sz, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE, r->fd, IORING_OFF_SQES);
  if (r->sqes == MAP_FAILED) { *err = "mmap sqes"; return -1; }
  uint8_t *sq = r->sq_ptr, *cq = r->cq_ptr;
  r->sq_head = (unsigned *)(sq + p.sq_off.head);
  r->sq_tail = (unsigned *)(sq + p.sq_off.tail);
  r->sq_mask = *(unsigned *)(sq + p.sq_off.ring_mask);
  r->sq_flags = (unsigned *)(sq + p.sq_off.flags);
  r->sq_array = (unsigned *)(sq + p.sq_off.array);
  r->cq_head = (unsigned *)(cq + p.cq_off.head);
  r->cq_tail = (unsigned *)(cq + p.cq_off.tail);
  r->cq_mask = *(unsigned *)(cq + p.cq_off.ring_mask);
  r->cqes = (struct io_uring_cqe *)(cq + p.cq_off.cqes);
  for (unsigned i = 0; i < r->sq_entries; i++) r->sq_array[i] = i; /* identity: sqe i is slot i */
  r->sq_local_tail = *r->sq_tail;

  /* sparse direct-descriptor table */
  struct io_uring_rsrc_register reg;
  memset(&reg, 0, sizeof reg);
  reg.nr = nslots;
  reg.flags = IORING_RSRC_REGISTER_SPARSE;
  long rc = sys_io_uring_register(r->fd, IORING_REGISTER_FILES2, &reg, sizeof reg);
  if (rc < 0) { *err = "register files"; errno = (int)-rc; return -1; }
  r->nslots = nslots;

  /* provided buffer ring */
  r->br_entries = nbufs;
  r->br_mask = nbufs - 1;
  r->buf_size = buf_size;
  size_t ring_bytes = (size_t)nbufs * sizeof(struct io_uring_buf);
  r->br = mmap(NULL, ring_bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_POPULATE, -1, 0);
  if (r->br == MAP_FAILED) { *err = "mmap buf ring"; return -1; }
  r->bufs = mmap(NULL, (size_t)nbufs * buf_size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (r->bufs == MAP_FAILED) { *err = "mmap bufs"; return -1; }
  struct io_uring_buf_reg breg;
  memset(&breg, 0, sizeof breg);
  breg.ring_addr = (uint64_t)(uintptr_t)r->br;
  breg.ring_entries = nbufs;
  breg.bgid = BUF_GROUP;
  rc = sys_io_uring_register(r->fd, IORING_REGISTER_PBUF_RING, &breg, 1);
  if (rc == -EINVAL) {
    /* Ubuntu 6.8.0-136..147 (LP #2162843) inverted the reserved-field check; those kernels accept a
     * nonzero reserved byte and a correct kernel never gets here. */
    breg.resv[0] = 1;
    rc = sys_io_uring_register(r->fd, IORING_REGISTER_PBUF_RING, &breg, 1);
  }
  if (rc < 0) { *err = "register buf ring"; errno = (int)-rc; return -1; }
  for (unsigned i = 0; i < nbufs; i++) {
    r->br->bufs[i].addr = (uint64_t)(uintptr_t)(r->bufs + (size_t)i * buf_size);
    r->br->bufs[i].len = buf_size;
    r->br->bufs[i].bid = (uint16_t)i;
  }
  r->br_tail = nbufs;
  STORE_REL(&r->br->tail, (uint16_t)r->br_tail);
  r->bufs_out = 0;
  return 0;
}

/* An eventfd the kernel signals whenever this ring has completions (including deferred task
 * work under DEFER_TASKRUN), so another ring can wait on it. */
static int ring_register_eventfd(struct ring *r) {
  int efd = (int)syscall(__NR_eventfd2, 0, EFD_NONBLOCK | EFD_CLOEXEC);
  if (efd < 0) return -1;
  long rc = sys_io_uring_register(r->fd, IORING_REGISTER_EVENTFD, &efd, 1);
  if (rc < 0) { close(efd); errno = (int)-rc; return -1; }
  return efd;
}

/* Give buffer `bid` back to the kernel. */
static inline void ring_buf_return(struct ring *r, unsigned bid) {
  struct io_uring_buf *b = &r->br->bufs[r->br_tail & r->br_mask];
  b->addr = (uint64_t)(uintptr_t)(r->bufs + (size_t)bid * r->buf_size);
  b->len = r->buf_size;
  b->bid = (uint16_t)bid;
  r->br_tail++;
  r->bufs_out--;
}
static inline void ring_buf_publish(struct ring *r) { STORE_REL(&r->br->tail, (uint16_t)r->br_tail); }
static inline uint8_t *ring_buf_ptr(struct ring *r, unsigned bid) { return r->bufs + (size_t)bid * r->buf_size; }

/* Publish the SQEs written so far and (optionally) wait. Returns the enter() result. */
static inline long ring_submit(struct ring *r, unsigned min_complete, unsigned flags, const void *arg, size_t argsz) {
  unsigned to_submit = r->sq_local_tail - LOAD_RLX(r->sq_tail);
  STORE_REL(r->sq_tail, r->sq_local_tail);
  return sys_io_uring_enter(r->fd, to_submit, min_complete, flags, arg, argsz);
}

static inline struct io_uring_sqe *ring_sqe(struct ring *r) {
  if (r->sq_local_tail - LOAD_ACQ(r->sq_head) >= r->sq_entries) {
    /* SQ full: push what we have without waiting */
    ring_submit(r, 0, 0, NULL, 0);
    while (r->sq_local_tail - LOAD_ACQ(r->sq_head) >= r->sq_entries) ring_submit(r, 0, IORING_ENTER_GETEVENTS, NULL, 0);
  }
  struct io_uring_sqe *s = &r->sqes[r->sq_local_tail & r->sq_mask];
  r->sq_local_tail++;
  memset(s, 0, sizeof *s);
  return s;
}

static inline unsigned ring_pending_submit(struct ring *r) { return r->sq_local_tail - LOAD_RLX(r->sq_tail); }

/* Wait for completions: at least `min` or until `ms` milliseconds pass. */
static inline long ring_wait(struct ring *r, unsigned min, unsigned ms) {
  struct __kernel_timespec ts = {.tv_sec = ms / 1000, .tv_nsec = (long)(ms % 1000) * 1000000L};
  struct io_uring_getevents_arg arg;
  memset(&arg, 0, sizeof arg);
  arg.ts = (uint64_t)(uintptr_t)&ts;
  return ring_submit(r, min, IORING_ENTER_GETEVENTS | IORING_ENTER_EXT_ARG, &arg, sizeof arg);
}

static inline long ring_poll(struct ring *r) { return ring_submit(r, 0, IORING_ENTER_GETEVENTS, NULL, 0); }

/* ---- SQE builders ---- */
static inline void sqe_accept_multishot(struct io_uring_sqe *s, int listen_fd, uint64_t ud) {
  s->opcode = IORING_OP_ACCEPT;
  s->fd = listen_fd;
  s->ioprio = IORING_ACCEPT_MULTISHOT;
  s->file_index = IORING_FILE_INDEX_ALLOC; /* allocate a direct descriptor per accepted socket */
  s->user_data = ud;
}
/* A connection waits on a multishot poll: it holds no buffer, so a burst can never end it, and it
 * costs one request (256 B) where a multishot recv also holds an async-poll entry (96 B more). */
static inline void sqe_poll_conn(struct io_uring_sqe *s, unsigned slot, uint64_t ud) {
  s->opcode = IORING_OP_POLL_ADD;
  s->fd = (int)slot;
  s->flags = IOSQE_FIXED_FILE;
  s->len = IORING_POLL_ADD_MULTI;
  s->poll32_events = POLLIN | POLLRDHUP;
  s->user_data = ud;
}
/* One read of a connection the poll reported readable, into a buffer the kernel picks from the ring.
 * MSG_DONTWAIT: if the data is already gone it completes with -EAGAIN instead of arming a wait. */
static inline void sqe_recv_once(struct io_uring_sqe *s, unsigned slot, uint64_t ud) {
  s->opcode = IORING_OP_RECV;
  s->fd = (int)slot;
  s->flags = IOSQE_FIXED_FILE | IOSQE_BUFFER_SELECT;
  s->buf_group = BUF_GROUP;
  s->msg_flags = MSG_DONTWAIT;
  s->user_data = ud;
}
static inline void sqe_send(struct io_uring_sqe *s, unsigned slot, const void *p, unsigned n, uint64_t ud) {
  s->opcode = IORING_OP_SEND;
  s->fd = (int)slot;
  s->flags = IOSQE_FIXED_FILE;
  s->addr = (uint64_t)(uintptr_t)p;
  s->len = n;
  s->msg_flags = MSG_NOSIGNAL | MSG_WAITALL;
  s->user_data = ud;
}
/* Cancel the request whose user_data is `target`. */
static inline void sqe_cancel(struct io_uring_sqe *s, uint64_t target, uint64_t ud) {
  s->opcode = IORING_OP_ASYNC_CANCEL;
  s->fd = -1;
  s->addr = target;
  s->user_data = ud;
}
/* A multishot poll for readability of an ordinary fd (the other rings' eventfds). */
static inline void sqe_poll_multishot(struct io_uring_sqe *s, int fd, uint64_t ud) {
  s->opcode = IORING_OP_POLL_ADD;
  s->fd = fd;
  s->len = IORING_POLL_ADD_MULTI;
  s->poll32_events = POLLIN;
  s->user_data = ud;
}
/* Cancel the connection's poll, then shutdown(RDWR), then close, hard-linked. The poll must go: a
 * request on a direct descriptor keeps its file, and so the socket, alive after the slot is closed.
 * It is cancelled by its user_data, a hash lookup: cancelling by descriptor walks every armed poll
 * on the ring (160k), and at thousands of closes a second that stopped the loop (30 s of ramp-down
 * closed 10k of 160k connections). Reads never wait (MSG_DONTWAIT) and the shutdown fails a send
 * that does, so the poll is the only request that can be left. */
static inline void sqe_shutdown_close(struct ring *r, unsigned slot, uint64_t ud, uint64_t poll_ud, uint64_t cancel_ud) {
  struct io_uring_sqe *s = ring_sqe(r);
  s->opcode = IORING_OP_ASYNC_CANCEL;
  s->fd = -1;
  s->addr = poll_ud;
  s->flags = IOSQE_IO_HARDLINK | IOSQE_CQE_SKIP_SUCCESS;
  s->user_data = cancel_ud; /* only seen if nothing was left to cancel; ignored */
  s = ring_sqe(r);
  s->opcode = IORING_OP_SHUTDOWN;
  s->fd = (int)slot;
  s->flags = IOSQE_FIXED_FILE | IOSQE_IO_HARDLINK | IOSQE_CQE_SKIP_SUCCESS;
  s->len = SHUT_RDWR;
  s->user_data = ud; /* only seen if the shutdown fails; ignored */
  s = ring_sqe(r);
  s->opcode = IORING_OP_CLOSE;
  s->file_index = slot + 1;
  s->flags = IOSQE_CQE_SKIP_SUCCESS;
  s->user_data = ud;
}

/* ---- sockets ---- */
static int listen_socket(const char *host, int port, int backlog, const char **err) {
  int fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (fd < 0) { *err = "socket"; return -1; }
  int one = 1;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
  setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof one);
  setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one); /* inherited by accepted sockets */
  struct sockaddr_in a;
  memset(&a, 0, sizeof a);
  a.sin_family = AF_INET;
  a.sin_port = htons((uint16_t)port);
  if (inet_pton(AF_INET, host, &a.sin_addr) != 1) { *err = "HOST must be an IPv4 address"; close(fd); return -1; }
  /* The previous instance may still be releasing the port: retry for up to 30 s. */
  for (int i = 0;; i++) {
    if (bind(fd, (struct sockaddr *)&a, sizeof a) == 0) break;
    if (errno != EADDRINUSE || i >= 300) { *err = "bind"; close(fd); return -1; }
    usleep(100000);
  }
  if (listen(fd, backlog) < 0) { *err = "listen"; close(fd); return -1; }
  return fd;
}

static inline uint64_t now_ns(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

/* Memory the server will need, made to exist while memory is still plentiful. At the memory wall a
 * first touch means a page allocation, which can mean direct reclaim on the event loop, the stall
 * that lets requests pile up in the kernel. */
#ifndef MADV_POPULATE_WRITE
#define MADV_POPULATE_WRITE 23
#endif
static void prefault(void *p, size_t n) { /* p page-aligned */
  if (madvise(p, n, MADV_POPULATE_WRITE) == 0) return;
  for (size_t i = 0; i < n; i += 4096) ((volatile uint8_t *)p)[i] = ((volatile uint8_t *)p)[i];
}
/* the calling thread's stack, n bytes below the caller (stack pages are never given back) */
static __attribute__((noinline)) void prefault_stack(size_t n) {
  volatile uint8_t *p = alloca(n);
  for (size_t i = 0; i < n; i += 4096) p[i] = 0;
}

#endif
