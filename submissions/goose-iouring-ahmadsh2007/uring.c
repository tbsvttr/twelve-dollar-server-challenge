/* uring.c: the kernel side of app.goose's event loop.
 *
 * This file decides nothing. app.goose runs the loop, keeps the connection table and decides
 * what to queue and what each completion means; here are only the things Goose cannot do
 * itself:
 *
 *   - making io_uring instances (each with a sparse table of direct descriptors and a ring of
 *     provided receive buffers) and the listening sockets;
 *   - queueing the operations Goose asks for, entering the kernel, and copying completions out
 *     as flat records into a Goose array;
 *   - owning every byte the kernel reads or writes asynchronously: receive buffers until Goose
 *     has copied a message out, and "byte boxes" (numbered, growable C buffers) that hold
 *     responses while a send is in flight and the rare request that arrives in pieces.
 *
 * Goose only ever sees copies, so no Goose memory is shared with the kernel. */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <liburing.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <unistd.h>
#include "goose.h"

typedef struct { const uint8_t *data; int64_t len; } bytes_t;

/* One completion as Goose reads it (app.goose's struct Cqe). */
#pragma pack(push, 1)
typedef struct { uint64_t ud; int32_t res; uint32_t flags; } cqe_t;
#pragma pack(pop)

#define MAX_RINGS 16
#define RX_COUNT 16384 /* receive buffers per ring (a power of two): a burst after a long pass must not run a ring dry */
#define RX_SIZE 1024 /* a request is a few hundred bytes; a longer one spans buffers */
#define SQ_DEPTH 4096
#define CQ_DEPTH 65536

typedef struct {
  struct io_uring q;
  struct io_uring_buf_ring *rx;
  uint8_t *rxmem;
  unsigned rx_back; /* buffers handed back since the ring's tail last moved */
} ring_t;

static ring_t *rings[MAX_RINGS];
static int nrings;
static int lfd[16];
static int nlisten;

/* ---- byte boxes ---- */

typedef struct { uint32_t len, cap; uint8_t b[]; } box_t;

static box_t **boxes;      /* by handle */
static int32_t *box_free;  /* free handles */
static int32_t nbox, capbox, nfree;
#define BOX_FIRST 4096     /* a new box's capacity: a feed response fits */
#define BOX_KEEP 32768     /* boxes that grew past this are shrunk when freed */

static void oom(void) {
  fputs("out of memory\n", stderr);
  abort();
}

static box_t *box_alloc(uint32_t cap) {
  box_t *x = malloc(sizeof(box_t) + cap);
  if (!x) oom();
  x->len = 0;
  x->cap = cap;
  return x;
}

/* A new, empty box. */
int32_t box_new(void) {
  if (nfree) {
    int32_t h = box_free[--nfree];
    if (!boxes[h]) boxes[h] = box_alloc(BOX_FIRST);
    boxes[h]->len = 0;
    return h;
  }
  if (nbox == capbox) {
    capbox = capbox ? capbox * 2 : 4096;
    boxes = realloc(boxes, (size_t)capbox * sizeof *boxes);
    box_free = realloc(box_free, (size_t)capbox * sizeof *box_free);
    if (!boxes || !box_free) oom();
  }
  boxes[nbox] = box_alloc(BOX_FIRST);
  return nbox++;
}

/* Spare boxes keep their memory, up to BOX_SPARE of them; past that a dropped box's memory goes
 * back to the allocator (its number is reused later), so a burst does not pin memory for good. */
#define BOX_SPARE 8192

void box_drop(int32_t h) {
  if (nfree >= BOX_SPARE || boxes[h]->cap > BOX_KEEP) {
    free(boxes[h]);
    boxes[h] = NULL;
  }
  box_free[nfree++] = h;
}

int64_t box_live(void) { return nbox - nfree; }

static inline uint8_t *box_room(int32_t h, uint64_t n) {
  box_t *x = boxes[h];
  if (x->len + n > x->cap) {
    uint64_t cap = x->cap;
    while (x->len + n > cap) cap *= 2;
    if (cap > UINT32_MAX) oom();
    x = realloc(x, sizeof(box_t) + cap);
    if (!x) oom();
    x->cap = (uint32_t)cap;
    boxes[h] = x;
  }
  uint8_t *p = x->b + x->len;
  x->len += (uint32_t)n;
  return p;
}

void box_put(int32_t h, bytes_t a) {
  if (a.len > 0) memcpy(box_room(h, (uint64_t)a.len), a.data, (size_t)a.len);
}

/* Two pieces at once: a response's head and body. */
void box_put2(int32_t h, bytes_t a, bytes_t b) {
  uint8_t *p = box_room(h, (uint64_t)(a.len + b.len));
  memcpy(p, a.data, (size_t)a.len);
  memcpy(p + a.len, b.data, (size_t)b.len);
}

int64_t box_len(int32_t h) { return boxes[h]->len; }

void box_cut(int32_t h, int64_t len) {
  if (len >= 0 && len < boxes[h]->len) boxes[h]->len = (uint32_t)len;
}

/* Appends the box's bytes to a Goose buffer. */
void box_read(int32_t h, gs_rref out) { gs_bld_append(out, boxes[h]->b, boxes[h]->len); }

/* ---- rings ---- */

static int add_rx(ring_t *r) {
  struct io_uring_buf_reg reg;
  memset(&reg, 0, sizeof reg);
  reg.ring_addr = (uint64_t)(uintptr_t)r->rx;
  reg.ring_entries = RX_COUNT;
  int rc = io_uring_register_buf_ring(&r->q, &reg, 0);
  /* Ubuntu's 6.8.0-136 and later reject a registration whose reserved words are all zero
   * (Launchpad #2162843); a correct kernel never gets here. */
  if (rc == -EINVAL) {
    reg.resv[0] = 1;
    rc = io_uring_register_buf_ring(&r->q, &reg, 0);
  }
  if (rc < 0) return rc;
  io_uring_buf_ring_init(r->rx);
  for (unsigned i = 0; i < RX_COUNT; i++)
    io_uring_buf_ring_add(r->rx, r->rxmem + (size_t)i * RX_SIZE, RX_SIZE, (unsigned short)i,
                          io_uring_buf_ring_mask(RX_COUNT), (int)i);
  io_uring_buf_ring_advance(r->rx, RX_COUNT);
  return 0;
}

/* A new ring with `slots` direct descriptors: its index, or a negative errno. */
int32_t ring_add(int64_t slots) {
  if (nrings == MAX_RINGS) return -EMFILE;
  ring_t *r = calloc(1, sizeof *r);
  if (!r) return -ENOMEM;
  struct io_uring_params p;
  memset(&p, 0, sizeof p);
  p.flags = IORING_SETUP_SINGLE_ISSUER | IORING_SETUP_DEFER_TASKRUN | IORING_SETUP_SUBMIT_ALL |
            IORING_SETUP_CQSIZE;
  p.cq_entries = CQ_DEPTH;
  int rc = io_uring_queue_init_params(SQ_DEPTH, &r->q, &p);
  if (rc < 0) { free(r); return rc; }
  rc = io_uring_register_files_sparse(&r->q, (unsigned)slots);
  if (rc >= 0) {
    r->rx = mmap(NULL, RX_COUNT * sizeof(struct io_uring_buf), PROT_READ | PROT_WRITE,
                 MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    r->rxmem = malloc((size_t)RX_COUNT * RX_SIZE);
    rc = (r->rx == MAP_FAILED || !r->rxmem) ? -ENOMEM : add_rx(r);
  }
  if (rc < 0) {
    io_uring_queue_exit(&r->q);
    free(r);
    return rc;
  }
  rings[nrings] = r;
  return nrings++;
}

static struct io_uring_sqe *sqe(ring_t *r) {
  struct io_uring_sqe *s = io_uring_get_sqe(&r->q);
  while (!s) {
    /* The queue is full mid-pass: hand it to the kernel now. */
    int rc = io_uring_submit(&r->q);
    if (rc < 0 && rc != -EBUSY && rc != -EAGAIN) return NULL;
    if (rc <= 0) io_uring_get_events(&r->q);
    s = io_uring_get_sqe(&r->q);
  }
  return s;
}

/* One accept on listener `li`, into a free slot of the ring's table. */
void op_accept(int32_t ri, int32_t li, uint64_t ud) {
  struct io_uring_sqe *s = sqe(rings[ri]);
  if (!s) return;
  io_uring_prep_accept_direct(s, lfd[li], NULL, NULL, 0, IORING_FILE_INDEX_ALLOC);
  io_uring_sqe_set_data64(s, ud);
}

/* A multishot receive on a slot, into the ring's provided buffers. */
void op_recv(int32_t ri, int32_t slot, uint64_t ud) {
  struct io_uring_sqe *s = sqe(rings[ri]);
  if (!s) return;
  io_uring_prep_recv_multishot(s, slot, NULL, 0, 0);
  s->flags |= IOSQE_FIXED_FILE | IOSQE_BUFFER_SELECT;
  s->buf_group = 0;
  io_uring_sqe_set_data64(s, ud);
}

/* Sends box h from byte `from` on. The box must not change until the send completes. */
void op_send(int32_t ri, int32_t slot, int32_t h, int64_t from, uint64_t ud) {
  struct io_uring_sqe *s = sqe(rings[ri]);
  if (!s) return;
  io_uring_prep_send(s, slot, boxes[h]->b + from, boxes[h]->len - (size_t)from, MSG_NOSIGNAL);
  s->flags |= IOSQE_FIXED_FILE;
  io_uring_sqe_set_data64(s, ud);
}

/* Shuts the socket down (ending its multishot receive), then frees the slot. */
void op_close(int32_t ri, int32_t slot, uint64_t ud_shut, uint64_t ud_close) {
  ring_t *r = rings[ri];
  if (io_uring_sq_space_left(&r->q) < 2) io_uring_submit(&r->q); /* keep the pair together */
  struct io_uring_sqe *a = sqe(r), *b;
  if (!a) return;
  io_uring_prep_shutdown(a, slot, SHUT_RDWR);
  a->flags |= IOSQE_FIXED_FILE | IOSQE_IO_HARDLINK;
  io_uring_sqe_set_data64(a, ud_shut);
  if (!(b = sqe(r))) return;
  io_uring_prep_close_direct(b, (unsigned)slot);
  io_uring_sqe_set_data64(b, ud_close);
}

/* Submits the ring's queue and runs its completions; with want > 0 waits for that many or
 * `ns` nanoseconds, whichever comes first. */
void ring_enter(int32_t ri, int32_t want, int64_t ns) {
  ring_t *r = rings[ri];
  int rc;
  if (want > 0) {
    struct __kernel_timespec ts = {.tv_sec = ns / 1000000000, .tv_nsec = ns % 1000000000};
    struct io_uring_cqe *c;
    rc = io_uring_submit_and_wait_timeout(&r->q, &c, (unsigned)want, &ts, NULL);
  } else {
    rc = io_uring_submit_and_get_events(&r->q);
  }
  if (rc < 0 && rc != -ETIME && rc != -EINTR && rc != -EBUSY && rc != -EAGAIN)
    fprintf(stderr, "io_uring_enter: %s\n", strerror(-rc));
}

/* Appends every completion the ring has to `out` (a Goose Cqe[>..]) and consumes them. */
int64_t ring_reap(int32_t ri, gs_rref out) {
  ring_t *r = rings[ri];
  struct io_uring_cqe *c;
  unsigned head, n = 0;
  io_uring_for_each_cqe(&r->q, head, c) {
    cqe_t *o = (cqe_t *)out.stk->top;
    o->ud = c->user_data;
    o->res = c->res;
    o->flags = c->flags;
    out.stk->top += sizeof(cqe_t);
    out.hdr->len++;
    n++;
  }
  io_uring_cq_advance(&r->q, n);
  return n;
}

static inline void rx_back(ring_t *r, int32_t bid) {
  io_uring_buf_ring_add(r->rx, r->rxmem + (size_t)bid * RX_SIZE, RX_SIZE, (unsigned short)bid,
                        io_uring_buf_ring_mask(RX_COUNT), (int)r->rx_back++);
}

/* A received message: copied to a Goose buffer, or to a box, and its buffer handed back. */
void rx_take(int32_t ri, int32_t bid, int32_t len, gs_rref out) {
  ring_t *r = rings[ri];
  gs_bld_append(out, r->rxmem + (size_t)bid * RX_SIZE, len);
  rx_back(r, bid);
}

void rx_to_box(int32_t ri, int32_t bid, int32_t len, int32_t h) {
  ring_t *r = rings[ri];
  memcpy(box_room(h, (uint64_t)len), r->rxmem + (size_t)bid * RX_SIZE, (size_t)len);
  rx_back(r, bid);
}

void rx_drop(int32_t ri, int32_t bid) { rx_back(rings[ri], bid); }

/* Makes the buffers handed back visible to the kernel. */
void rx_publish(void) {
  for (int i = 0; i < nrings; i++) {
    ring_t *r = rings[i];
    if (r->rx_back) {
      io_uring_buf_ring_advance(r->rx, (int)r->rx_back);
      r->rx_back = 0;
    }
  }
}

/* ---- startup ---- */

/* `n` listening sockets sharing HOST:PORT (SO_REUSEPORT); 0 or a negative errno. */
int32_t listen_on(bytes_t host, int64_t port, int32_t n) {
  char h[64];
  struct in_addr ip;
  if (host.len <= 0 || host.len >= (int64_t)sizeof h || n > 16) return -EINVAL;
  memcpy(h, host.data, (size_t)host.len);
  h[host.len] = 0;
  if (inet_pton(AF_INET, h, &ip) != 1) return -EINVAL;
  signal(SIGPIPE, SIG_IGN);
  for (int i = 0; i < n; i++) {
    int fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0), one = 1;
    if (fd < 0) return -errno;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    if (setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof one) < 0) return -errno;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one); /* accepted sockets inherit it */
    struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons((uint16_t)port), .sin_addr = ip};
    if (bind(fd, (struct sockaddr *)&a, sizeof a) < 0 || listen(fd, 65535) < 0) return -errno;
    lfd[nlisten++] = fd;
  }
  return 0;
}

/* Raises the soft descriptor limit to the hard one and returns it: a ring's table of direct
 * descriptors may be that large. GOOSE_SLOTS (test only) asks for smaller tables. */
int64_t slot_limit(void) {
  struct rlimit rl;
  getrlimit(RLIMIT_NOFILE, &rl);
  rl.rlim_cur = rl.rlim_max;
  setrlimit(RLIMIT_NOFILE, &rl);
  getrlimit(RLIMIT_NOFILE, &rl);
  int64_t n = rl.rlim_cur > (1u << 20) ? (1 << 20) : (int64_t)rl.rlim_cur;
  const char *t = getenv("GOOSE_SLOTS");
  if (t && atol(t) >= 256 && atol(t) < n) n = atol(t);
  return n;
}

/* Locks the executable's own code and read-only data in RAM (best effort). With no swap,
 * reclaim near the memory wall evicts file-backed pages first, and the loop must never wait
 * on a major fault for its own code. The binary is static: about 2 MB. */
int64_t lock_code(void) {
  char exe[4096], line[4096 + 256];
  ssize_t n = readlink("/proc/self/exe", exe, sizeof exe - 1);
  FILE *f = n > 0 ? fopen("/proc/self/maps", "r") : NULL;
  int64_t locked = 0;
  if (!f) return 0;
  exe[n] = 0;
  while (fgets(line, sizeof line, f)) {
    unsigned long lo, hi;
    char perm[8];
    int at = 0;
    if (sscanf(line, "%lx-%lx %7s %*s %*s %*s %n", &lo, &hi, perm, &at) < 3 || !at) continue;
    char *path = line + at;
    path[strcspn(path, "\n")] = 0;
    if (perm[0] == 'r' && perm[1] != 'w' && strcmp(path, exe) == 0 && mlock((void *)lo, hi - lo) == 0)
      locked += (int64_t)(hi - lo);
  }
  fclose(f);
  return locked;
}
