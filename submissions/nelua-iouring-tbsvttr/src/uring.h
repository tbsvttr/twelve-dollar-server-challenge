/* uring.h: the io_uring ABI by raw system calls (no liburing), for the Nelua code. A ring is one SQ, one CQ and a
 * sparse table of direct descriptors; everything else (what a request is for, connections, batches) is in
 * server.nelua. */
#ifndef TD_URING_H
#define TD_URING_H
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <linux/io_uring.h>
#include <linux/time_types.h>
#include <poll.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/eventfd.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <unistd.h>

#ifndef IORING_SETUP_DEFER_TASKRUN
#error "linux/io_uring.h too old: needs IORING_SETUP_DEFER_TASKRUN (Linux 6.1)"
#endif

typedef struct td_ring {
  int fd, efd;
  unsigned sq_entries, cq_entries, sq_mask, cq_mask, sq_local, nslots;
  unsigned *sq_head, *sq_tail, *sq_flags, *sq_array, *cq_head, *cq_tail;
  struct io_uring_cqe *cqes;
  struct io_uring_sqe *sqes;
} td_ring;

static td_ring *td_ring_new(void) { return calloc(1, sizeof(td_ring)); }

/* Memory the kernel could still hand out, in bytes (-1 if unknown): MemAvailable, or under a cgroup memory limit,
 * the limit less what the cgroup holds plus its inactive file pages. */
static long long td_read_ll(const char *path) {
  char b[64];
  int fd = open(path, O_RDONLY);
  if (fd < 0) return -1;
  ssize_t n = read(fd, b, sizeof b - 1);
  close(fd);
  if (n <= 0 || b[0] < '0' || b[0] > '9') return -1;
  b[n] = 0;
  return strtoll(b, NULL, 10);
}
static long long td_field(const char *buf, const char *name) {
  const char *p = strstr(buf, name);
  return p ? strtoll(p + strlen(name), NULL, 10) : -1;
}
static long long td_mem_avail(void) {
  static long long limit = -2;
  char buf[8192];
  if (limit == -2) limit = td_read_ll("/sys/fs/cgroup/memory.max");
  if (limit > 0) {
    long long cur = td_read_ll("/sys/fs/cgroup/memory.current");
    int fd = open("/sys/fs/cgroup/memory.stat", O_RDONLY);
    if (cur < 0 || fd < 0) { if (fd >= 0) close(fd); return -1; }
    ssize_t n = read(fd, buf, sizeof buf - 1);
    close(fd);
    buf[n > 0 ? n : 0] = 0;
    long long inactive = td_field(buf, "\ninactive_file ");
    return limit - cur + (inactive > 0 ? inactive : 0);
  }
  int fd = open("/proc/meminfo", O_RDONLY);
  if (fd < 0) return -1;
  ssize_t n = read(fd, buf, sizeof buf - 1);
  close(fd);
  if (n <= 0) return -1;
  buf[n] = 0;
  long long avail = td_field(buf, "MemAvailable:");
  return avail < 0 ? -1 : avail * 1024;
}

/* Anonymous memory: pages are taken when first touched, and td_unpages gives them back. */
static void *td_pages(size_t n) {
  void *p = mmap(NULL, n, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  return p == MAP_FAILED ? NULL : p;
}
static void td_unpages(void *p, size_t n) {
  uintptr_t a = ((uintptr_t)p + 4095) & ~(uintptr_t)4095, b = ((uintptr_t)p + n) & ~(uintptr_t)4095;
  if (b > a) madvise((void *)a, b - a, MADV_DONTNEED);
}

static inline long td_sys_enter(int fd, unsigned n, unsigned min, unsigned flags, const void *arg, size_t sz) {
  long r = syscall(__NR_io_uring_enter, fd, n, min, flags, arg, sz);
  return r < 0 ? -errno : r;
}
static inline long td_sys_register(int fd, unsigned op, const void *arg, unsigned n) {
  long r = syscall(__NR_io_uring_register, fd, op, arg, n);
  return r < 0 ? -errno : r;
}

/* 0, or -errno. Every ring defers its task work (DEFER_TASKRUN): completions are posted when the loop enters the
 * ring, in a batch. The loop waits in the first ring; another ring's eventfd (td_ring_eventfd), which the kernel
 * signals once when work starts waiting there, wakes it, and TASKRUN_FLAG says which rings to enter. */
static int td_ring_init(td_ring *r, unsigned sq, unsigned cq, unsigned nslots, int primary) {
  (void)primary;
  memset(r, 0, sizeof *r);
  r->efd = -1;
  struct io_uring_params p;
  long fd = -EINVAL;
  for (; cq >= 4096; cq /= 2) { /* newer kernels charge rings to RLIMIT_MEMLOCK: shrink until it fits */
    memset(&p, 0, sizeof p);
    p.flags = IORING_SETUP_CQSIZE | IORING_SETUP_CLAMP | IORING_SETUP_SUBMIT_ALL | IORING_SETUP_SINGLE_ISSUER |
              IORING_SETUP_DEFER_TASKRUN | IORING_SETUP_TASKRUN_FLAG;
    p.cq_entries = cq;
    fd = syscall(__NR_io_uring_setup, sq, &p);
    fd = fd < 0 ? -errno : fd;
    if (fd != -ENOMEM) break;
  }
  if (fd < 0) return (int)fd;
  if (!(p.features & IORING_FEAT_SINGLE_MMAP) || !(p.features & IORING_FEAT_EXT_ARG)) { close((int)fd); return -ENOSYS; }
  r->fd = (int)fd;
  r->sq_entries = p.sq_entries;
  r->cq_entries = p.cq_entries;
  size_t sq_sz = p.sq_off.array + p.sq_entries * sizeof(unsigned);
  size_t cq_sz = p.cq_off.cqes + p.cq_entries * sizeof(struct io_uring_cqe);
  if (cq_sz > sq_sz) sq_sz = cq_sz;
  uint8_t *ring = mmap(NULL, sq_sz, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE, r->fd, IORING_OFF_SQ_RING);
  if (ring == MAP_FAILED) return -errno;
  r->sqes = mmap(NULL, p.sq_entries * sizeof(struct io_uring_sqe), PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE,
                 r->fd, IORING_OFF_SQES);
  if (r->sqes == MAP_FAILED) return -errno;
  r->sq_head = (unsigned *)(ring + p.sq_off.head);
  r->sq_tail = (unsigned *)(ring + p.sq_off.tail);
  r->sq_mask = *(unsigned *)(ring + p.sq_off.ring_mask);
  r->sq_flags = (unsigned *)(ring + p.sq_off.flags);
  r->sq_array = (unsigned *)(ring + p.sq_off.array);
  r->cq_head = (unsigned *)(ring + p.cq_off.head);
  r->cq_tail = (unsigned *)(ring + p.cq_off.tail);
  r->cq_mask = *(unsigned *)(ring + p.cq_off.ring_mask);
  r->cqes = (struct io_uring_cqe *)(ring + p.cq_off.cqes);
  for (unsigned i = 0; i < r->sq_entries; i++) r->sq_array[i] = i;
  r->sq_local = *r->sq_tail;
  struct io_uring_rsrc_register reg;
  memset(&reg, 0, sizeof reg);
  reg.nr = nslots;
  reg.flags = IORING_RSRC_REGISTER_SPARSE;
  long rc = td_sys_register(r->fd, IORING_REGISTER_FILES2, &reg, sizeof reg);
  if (rc < 0) return (int)rc;
  r->nslots = nslots;
  return 0;
}

/* An eventfd the kernel signals when this ring posts completions; the primary ring polls it. */
static int td_ring_eventfd(td_ring *r) {
  int efd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
  if (efd < 0) return -errno;
  long rc = td_sys_register(r->fd, IORING_REGISTER_EVENTFD, &efd, 1);
  if (rc < 0) { close(efd); return (int)rc; }
  r->efd = efd;
  return efd;
}

/* Publishes the SQEs written so far; with `wait`, also waits for `min` completions or `timeout_us`. */
static inline long td_enter(td_ring *r, int wait, unsigned min, long long timeout_us) {
  unsigned n = r->sq_local - *r->sq_tail;
  atomic_store_explicit((_Atomic unsigned *)r->sq_tail, r->sq_local, memory_order_release);
  if (!wait) return n ? td_sys_enter(r->fd, n, 0, 0, NULL, 0) : 0;
  struct __kernel_timespec ts = {.tv_sec = timeout_us / 1000000, .tv_nsec = (timeout_us % 1000000) * 1000};
  struct io_uring_getevents_arg arg;
  memset(&arg, 0, sizeof arg);
  arg.ts = (uint64_t)(uintptr_t)&ts;
  return td_sys_enter(r->fd, n, min, IORING_ENTER_GETEVENTS | IORING_ENTER_EXT_ARG, &arg, sizeof arg);
}
static inline unsigned td_pending(td_ring *r) { return r->sq_local - *r->sq_tail; }
/* Has task work waiting to post completions, or SQEs to submit: worth entering. */
static inline int td_has_work(td_ring *r) {
  return r->sq_local != *r->sq_tail ||
         (atomic_load_explicit((_Atomic unsigned *)r->sq_flags, memory_order_relaxed) & IORING_SQ_TASKRUN) != 0;
}

static inline struct io_uring_sqe *td_sqe(td_ring *r) {
  while (r->sq_local - atomic_load_explicit((_Atomic unsigned *)r->sq_head, memory_order_acquire) >= r->sq_entries)
    td_enter(r, 1, 0, 0); /* full: submit, and let the kernel run what it can */
  struct io_uring_sqe *s = &r->sqes[r->sq_local & r->sq_mask];
  r->sq_local++;
  memset(s, 0, sizeof *s);
  return s;
}

/* Completions: how many are ready, the i-th of them, and consuming n. */
static inline unsigned td_cq_ready(td_ring *r) {
  return atomic_load_explicit((_Atomic unsigned *)r->cq_tail, memory_order_acquire) - *r->cq_head;
}
static inline struct io_uring_cqe *td_cqe(td_ring *r, unsigned i) { return &r->cqes[(*r->cq_head + i) & r->cq_mask]; }
static inline void td_cq_advance(td_ring *r, unsigned n) {
  atomic_store_explicit((_Atomic unsigned *)r->cq_head, *r->cq_head + n, memory_order_release);
}
static inline uint64_t td_cqe_ud(struct io_uring_cqe *c) { return c->user_data; }
static inline int32_t td_cqe_res(struct io_uring_cqe *c) { return c->res; }
static inline int td_cqe_more(struct io_uring_cqe *c) { return (c->flags & IORING_CQE_F_MORE) != 0; }

/* The requests the server makes. Connections are direct descriptors: `slot` indexes the ring's table. */
static inline void td_accept(td_ring *r, int listen_fd, uint64_t ud) {
  struct io_uring_sqe *s = td_sqe(r);
  s->opcode = IORING_OP_ACCEPT;
  s->fd = listen_fd;
  s->ioprio = IORING_ACCEPT_MULTISHOT;
  s->file_index = IORING_FILE_INDEX_ALLOC;
  s->user_data = ud;
}
/* An idle connection waits on a multishot poll: no buffer, and a smaller kernel request than a multishot recv. */
static inline void td_poll(td_ring *r, unsigned slot, uint64_t ud) {
  struct io_uring_sqe *s = td_sqe(r);
  s->opcode = IORING_OP_POLL_ADD;
  s->fd = (int)slot;
  s->flags = IOSQE_FIXED_FILE;
  s->len = IORING_POLL_ADD_MULTI;
  s->poll32_events = POLLIN | POLLRDHUP;
  s->user_data = ud;
}
static inline void td_poll_fd(td_ring *r, int fd, uint64_t ud) {
  struct io_uring_sqe *s = td_sqe(r);
  s->opcode = IORING_OP_POLL_ADD;
  s->fd = fd;
  s->len = IORING_POLL_ADD_MULTI;
  s->poll32_events = POLLIN;
  s->user_data = ud;
}
/* One read of a connection its poll reported readable. MSG_DONTWAIT: it completes during the submit, with the data
 * or -EAGAIN, and never arms a wait of its own. */
static inline void td_recv(td_ring *r, unsigned slot, void *buf, unsigned len, uint64_t ud) {
  struct io_uring_sqe *s = td_sqe(r);
  s->opcode = IORING_OP_RECV;
  s->fd = (int)slot;
  s->flags = IOSQE_FIXED_FILE;
  s->addr = (uint64_t)(uintptr_t)buf;
  s->len = len;
  s->msg_flags = MSG_DONTWAIT;
  s->user_data = ud;
}
static inline void td_send(td_ring *r, unsigned slot, const void *buf, unsigned len, uint64_t ud) {
  struct io_uring_sqe *s = td_sqe(r);
  s->opcode = IORING_OP_SEND;
  s->fd = (int)slot;
  s->flags = IOSQE_FIXED_FILE;
  s->addr = (uint64_t)(uintptr_t)buf;
  s->len = len;
  s->msg_flags = MSG_NOSIGNAL;
  s->user_data = ud;
}
/* Closing: the poll goes first (removed by its user data, a hash lookup; by descriptor the kernel would walk every
 * armed poll of the ring), then the slot is closed, linked so they run in order. With the poll gone nothing else
 * holds the socket, so closing the slot closes it. (No IORING_OP_SHUTDOWN: it can't run inline, the kernel hands
 * every one to an io-wq worker, and under many closes those queue up holding their sockets.) The removal posts a
 * completion (with skip_ud) only if it fails; the close always does (with ud). */
static inline void td_close(td_ring *r, unsigned slot, uint64_t poll_ud, int has_poll, uint64_t skip_ud, uint64_t ud) {
  struct io_uring_sqe *s;
  if (has_poll) {
    s = td_sqe(r);
    s->opcode = IORING_OP_POLL_REMOVE;
    s->addr = poll_ud;
    s->flags = IOSQE_IO_HARDLINK | IOSQE_CQE_SKIP_SUCCESS;
    s->user_data = skip_ud;
  }
  s = td_sqe(r);
  s->opcode = IORING_OP_CLOSE;
  s->file_index = slot + 1;
  s->user_data = ud;
}
static inline void td_cancel(td_ring *r, uint64_t target, uint64_t ud) {
  struct io_uring_sqe *s = td_sqe(r);
  s->opcode = IORING_OP_ASYNC_CANCEL;
  s->addr = target;
  s->flags = IOSQE_CQE_SKIP_SUCCESS;
  s->user_data = ud;
}
#endif
