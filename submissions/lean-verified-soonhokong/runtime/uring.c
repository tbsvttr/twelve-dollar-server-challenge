/* io_uring transport: moves bytes between sockets and the Lean request handler, nothing else.
 *
 * One thread drives several rings. Each ring owns a table of direct (fixed) socket descriptors and
 * a ring of provided receive buffers. A ring's descriptor table may not exceed RLIMIT_NOFILE
 * (65,535 on the box), and direct descriptors do not use the process file table, so the rings
 * together hold rings x 65,535 connections. Rings are made as connections fill them and use
 * DEFER_TASKRUN: completions are produced only when this thread enters a ring, once per ring per
 * loop iteration, and once more per round of reads for a ring with connections on its read queue
 * (see "Rings" below), so each iteration collects a batch of input from every connection that has
 * some.
 *
 * Per iteration: reap completions; hand every connection's new input to Lean in one call
 * (Feed.Server.batch), which parses it, answers the complete requests and reports how many bytes
 * it consumed; queue the answers as sends. The transport never parses HTTP. */
#include "rt.h"
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <linux/io_uring.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/epoll.h>
#include <sys/eventfd.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <time.h>
#include <signal.h>
#include <poll.h>
#ifndef POLLRDHUP
#define POLLRDHUP 0x2000
#endif

#define MAX_RINGS 16
#define SQ_ENTRIES 4096
#define CQ_ENTRIES 65536   /* more than a ring's connections: a burst never spills into the kernel's
                              overflow list, which allocates per completion when memory is shortest */
static u32_t NBUF = 512;    /* provided receive buffers per ring (a power of two): reads are issued for at most this many;
                               FEED_NBUF overrides it (for measurements) */
static u32_t BUFSZ = 1024;  /* FEED_BUFSZ overrides it (for measurements) */
#define READ_ROUNDS 8      /* read rounds per iteration (each up to NBUF reads per ring) */
#define CQE_BUDGET 8192    /* completions handled per ring per iteration */
#define MAX_IN 65536       /* a connection's buffered, unanswered input */

enum { OP_ACCEPT = 1, OP_RECV, OP_SEND, OP_CLOSE, OP_SHUTDOWN, OP_PROVIDE, OP_POLL, OP_POLL_REMOVE, OP_FD_INSTALL, OP_CLOSE_FD,
       OP_MRECV, OP_CANCEL,
       OP_IDLE_CLOSE };
enum { C_FREE = 0, C_OPEN, C_CLOSING };
enum { F_POLL = 1, F_SENDING = 2, F_CLOSE_AFTER = 4, F_HELD = 8, F_PEER_EOF = 16, F_SPILL = 32, F_RQ = 64, F_RDHUP = 256,
       F_ARMING = 512, F_TRYCLOSE = 1024, F_MRECV = 2048 };
#define LNIL 0xffffu       /* the end of a ring's list of open connections (slots are below 65,535) */

typedef struct oq { struct oq *next; lean_object *buf; u32_t off, len; } oq;

typedef struct conn {
  u32_t gen;
  u8_t state, _pad;
  u16_t flags;
  u32_t in_len, in_cap;
  i32_t chunk;              /* index in the current batch, or -1 */
  u16_t lprev, lnext;       /* the ring's open connections in order of last activity */
  u8_t *in;                 /* input not yet consumed by the handler */
  lean_object *out;         /* the response being sent (owned reference) */
  u32_t out_off, out_len;
  oq *q;                    /* responses waiting for the in-flight send */
  u32_t active_ms;          /* the loop's clock at the last activity: the accept, or an answer sent */
} conn;

typedef struct ring {
  int fd, idx, reg_idx;
  u32_t *sq_khead, *sq_ktail, *sq_kflags, *sq_array, sq_mask, sq_entries, sq_tail, to_submit;
  struct io_uring_sqe *sqes;
  u32_t *cq_khead, *cq_ktail, cq_mask;
  struct io_uring_cqe *cqes;
  struct io_uring_buf_ring *br;   /* provided buffer ring, or 0 when using PROVIDE_BUFFERS */
  u16_t br_tail;
  u8_t *bufs;
  u32_t nslots, nopen;
  conn *conns;
  u8_t hot, defer;                /* defer: DEFER_TASKRUN (every ring, but only ring 0 with FEED_RINGS_PLAIN) */
  u16_t accept_armed, accept_cancel;   /* listeners with a multishot accept on this ring, and being cancelled */
  u16_t nrecycle;                 /* PROVIDE_BUFFERS mode: buffers to give back */
  u16_t *recycle;
  u32_t *rq, rq_head, nrq;        /* connections reported readable, waiting for a read (FIFO) */
  u32_t reads_out;                /* reads submitted and not completed: each may hold a buffer */
  u16_t lru_head, lru_tail;       /* open connections, least recently active first */
} ring;

static ring rings[MAX_RINGS];
static int nrings, nrings_max;
static u32_t ring_slots;              /* slots per ring */
static int rings_upfront;             /* FEED_RINGS_UPFRONT: the previous design (see "Rings") */
static int rings_plain;               /* FEED_RINGS_PLAIN: rings after ring 0 run their task work as it comes */
static int loop_sleep;                /* the previous loop: every ring entered, then a sleep (FEED_RINGS_SLEEP) */
static int ring_grow_failed;
#define NLISTEN 8                     /* listeners on the port, with rings made as they fill */
static int lfds[MAX_RINGS], nlisten;
static int epfd, evfd;
static u64_t start_s;
static lean_object *g_secret;
static u64_t st_batches, st_reqchunks, st_iters, st_enters, st_sleeps;
static u64_t st_nobufs, st_rearms, st_max_chunks, st_iter_max_ns, st_batch_ns, st_reap_ns, st_overflow, st_pinned;
static u64_t st_idle_closed, st_idle_kept, st_sys, st_uring;
static u32_t loop_ms;   /* milliseconds since the start, read once per loop iteration */
static u32_t ntrying;   /* idle closes submitted and not yet completed */

/* implemented in Lean: Feed.Server.batch */
extern lean_object *feed_batch(lean_object *chunks, uint64_t now, uint64_t uptime, uint8_t writes_ok, lean_object *key);
extern lean_object *feed_make_key(lean_object *secret);

static inline int sys_setup(u32_t e, struct io_uring_params *p) { return (int)syscall(__NR_io_uring_setup, e, p); }
static inline int sys_enter(ring *r, u32_t sub, u32_t minc, u32_t flags) {
  st_sys++;
  st_uring++;
  if (r->reg_idx >= 0) return (int)syscall(__NR_io_uring_enter, r->reg_idx, sub, minc, flags | IORING_ENTER_REGISTERED_RING, NULL, 0);
  return (int)syscall(__NR_io_uring_enter, r->fd, sub, minc, flags, NULL, 0);
}
/* Submit and wait for min completions or until the timeout. */
static inline int sys_enter_wait(ring *r, u32_t sub, u32_t minc, u64_t timeout_ns) {
  struct __kernel_timespec ts = {.tv_sec = (long long)(timeout_ns / 1000000000ull), .tv_nsec = (long long)(timeout_ns % 1000000000ull)};
  struct io_uring_getevents_arg arg;
  memset(&arg, 0, sizeof arg);
  arg.ts = (u64_t)(uintptr_t)&ts;
  u32_t fl = IORING_ENTER_GETEVENTS | IORING_ENTER_EXT_ARG;
  st_sys++;
  st_uring++;
  if (r->reg_idx >= 0) return (int)syscall(__NR_io_uring_enter, r->reg_idx, sub, minc, fl | IORING_ENTER_REGISTERED_RING, &arg, sizeof arg);
  return (int)syscall(__NR_io_uring_enter, r->fd, sub, minc, fl, &arg, sizeof arg);
}
static inline int sys_register(int fd, u32_t op, void *arg, u32_t n) { return (int)syscall(__NR_io_uring_register, fd, op, arg, n); }

static inline u64_t ud(u8_t op, u8_t ri, u32_t gen, u32_t slot) { return (u64_t)op << 56 | (u64_t)ri << 48 | (u64_t)(gen & 0xffff) << 32 | slot; }
static inline u32_t cref(int ri, u32_t slot) { return (u32_t)ri << 16 | slot; }   /* ring << 16 | slot */

static void ring_flush(ring *r) {
  while (r->to_submit) {
    int rc = sys_enter(r, r->to_submit, 0, IORING_ENTER_GETEVENTS);
    if (rc < 0) { if (errno == EINTR) continue; if (errno == EAGAIN || errno == EBUSY) return; perror("io_uring_enter"); exit(1); }
    r->to_submit -= (u32_t)rc;
    if (rc == 0) return;
  }
}
static struct io_uring_sqe *sqe_get(ring *r) {
  u32_t head = __atomic_load_n(r->sq_khead, __ATOMIC_ACQUIRE);
  if (r->sq_tail - head >= r->sq_entries) {
    ring_flush(r);
    head = __atomic_load_n(r->sq_khead, __ATOMIC_ACQUIRE);
    if (r->sq_tail - head >= r->sq_entries) { fprintf(stderr, "fatal: submission queue full\n"); exit(1); }
  }
  struct io_uring_sqe *s = &r->sqes[r->sq_tail & r->sq_mask];
  memset(s, 0, sizeof *s);
  r->sq_tail++;
  r->to_submit++;
  __atomic_store_n(r->sq_ktail, r->sq_tail, __ATOMIC_RELEASE);
  return s;
}

/* ---- buffers ---------------------------------------------------------------------------- */
static inline void buf_recycle(ring *r, u16_t bid) {
  if (r->br) {
    struct io_uring_buf *b = &r->br->bufs[r->br_tail & (NBUF - 1)];
    b->addr = (u64_t)(uintptr_t)(r->bufs + (size_t)bid * BUFSZ);
    b->len = BUFSZ;
    b->bid = bid;
    r->br_tail++;
  } else {
    r->recycle[r->nrecycle++] = bid;
  }
}
static void buf_publish(ring *r) {
  if (r->br) { __atomic_store_n(&r->br->tail, r->br_tail, __ATOMIC_RELEASE); return; }
  /* PROVIDE_BUFFERS: give back runs of consecutive buffer ids */
  u16_t n = r->nrecycle;
  r->nrecycle = 0;
  for (u16_t i = 0; i < n;) {
    u16_t j = i + 1;
    while (j < n && r->recycle[j] == r->recycle[j - 1] + 1) j++;
    struct io_uring_sqe *s = sqe_get(r);
    s->opcode = IORING_OP_PROVIDE_BUFFERS;
    s->fd = (int)(j - i);
    s->addr = (u64_t)(uintptr_t)(r->bufs + (size_t)r->recycle[i] * BUFSZ);
    s->len = BUFSZ;
    s->off = r->recycle[i];
    s->buf_group = 0;
    s->flags = IOSQE_CQE_SKIP_SUCCESS;
    s->user_data = ud(OP_PROVIDE, (u8_t)r->idx, 0, 0);
    i = j;
  }
}

/* ---- connections ------------------------------------------------------------------------ */
/* A multishot accept of listener l into ring r's table (the listener's index is the completion's
 * generation field). */
static void arm_accept(ring *r, int l) {
  struct io_uring_sqe *s = sqe_get(r);
  s->opcode = IORING_OP_ACCEPT;
  s->fd = lfds[l];
  s->ioprio = IORING_ACCEPT_MULTISHOT;
  s->file_index = IORING_FILE_INDEX_ALLOC;
  s->user_data = ud(OP_ACCEPT, (u8_t)r->idx, (u32_t)l, 0);
  r->accept_armed |= (u16_t)(1u << l);
}
static void cancel_accept(ring *r, int l) {
  struct io_uring_sqe *s = sqe_get(r);
  s->opcode = IORING_OP_ASYNC_CANCEL;
  s->addr = ud(OP_ACCEPT, (u8_t)r->idx, (u32_t)l, 0);
  s->flags = IOSQE_CQE_SKIP_SUCCESS;
  s->user_data = ud(OP_CANCEL, (u8_t)r->idx, 0, 0);
  r->accept_cancel |= (u16_t)(1u << l);
}
/* Reads. Each connection has one multishot receive into its ring's provided buffers: a request
 * costs one completion (the design of rust-iouring-kensac, #264). A burst can take every buffer of
 * a ring at once; a receive that then ends (ENOBUFS) is not armed again at once, which would only
 * repeat that: its connection joins the ring's read queue, and after the completions of an
 * iteration are in, one non-blocking read is issued per queued connection, never more on a ring
 * than it has buffers, and the reads complete during the submit. A read that fills its buffer
 * queues the connection again; a shorter read, or EAGAIN, shows the socket drained, and the
 * receive is armed again. So a burst of any size waits in the read queue rather than in the
 * kernel's receive path.
 * With FEED_MSRECV=0, and while the idle policy is configured (its race-free close needs the poll,
 * see idle_close), each connection waits on a multishot poll instead: a readiness report puts it on
 * the read queue, and every request costs a report, a submission and a read's completion. An armed
 * receive takes more kernel memory than a poll (its async poll entry, 96 B, beside the 256 B
 * request, and on 6.12 also a 512 B message header) and saved no CPU here, but on a KVM guest like
 * the box with its vCPU's sibling hyperthread busy, polls left 1 to 2 % of requests waiting 1.5 to
 * 3.7 s at 320,000 users where the receive held p99 58 ms.
 *
 * The poll or receive holds its own reference to the socket instead of going through the direct
 * descriptor.
 * Linux up to 6.12 frees a direct descriptor that was closed only once every request issued on its
 * ring before the close has completed (the ring's resource nodes are recycled in order), and a poll
 * on a direct descriptor is such a request for as long as it stays armed: one idle connection kept
 * the socket of every connection closed after it allocated, and those peers waited for our FIN.
 * So a poll is armed on a plain descriptor, made for the slot by IORING_OP_FIXED_FD_INSTALL (6.8)
 * and closed again right after the poll took its reference; only reads and sends, which complete at
 * once, use the direct descriptor. Kernels without the operation poll the direct descriptor.
 * A receive on a plain descriptor takes no resource node either (io_file_get_normal), and its
 * provided buffers are not a resource. */
static int fd_install_ok = 1;
static int mrecv_mode = 1;   /* multishot receives (FEED_MSRECV=0: polls) */
static void poll_on(ring *r, u32_t slot, int fd, int fixed) {
  conn *c = &r->conns[slot];
  struct io_uring_sqe *s = sqe_get(r);
  s->opcode = IORING_OP_POLL_ADD;
  s->fd = fixed ? (int)slot : fd;
  s->flags = fixed ? IOSQE_FIXED_FILE : 0;
  s->len = IORING_POLL_ADD_MULTI;
  s->poll32_events = POLLIN | POLLRDHUP;
  s->user_data = ud(OP_POLL, (u8_t)r->idx, c->gen, slot);
  c->flags |= F_POLL;
  if (fixed) return;
  /* issued after the poll, which has taken its reference to the file by then */
  s = sqe_get(r);
  s->opcode = IORING_OP_CLOSE;
  s->fd = fd;
  s->flags = IOSQE_CQE_SKIP_SUCCESS;
  s->user_data = ud(OP_CLOSE_FD, (u8_t)r->idx, 0, 0);
}
static void mrecv_on(ring *r, u32_t slot, int fd) {
  conn *c = &r->conns[slot];
  struct io_uring_sqe *s = sqe_get(r);
  s->opcode = IORING_OP_RECV;
  s->fd = fd;
  s->flags = IOSQE_BUFFER_SELECT;
  s->ioprio = IORING_RECV_MULTISHOT;
  s->buf_group = 0;
  s->user_data = ud(OP_MRECV, (u8_t)r->idx, c->gen, slot);
  c->flags |= F_MRECV;
  /* issued after the receive, which has taken its reference to the file by then */
  s = sqe_get(r);
  s->opcode = IORING_OP_CLOSE;
  s->fd = fd;
  s->flags = IOSQE_CQE_SKIP_SUCCESS;
  s->user_data = ud(OP_CLOSE_FD, (u8_t)r->idx, 0, 0);
}
/* A poll or a multishot receive for the connection, on a plain descriptor made for its slot. */
static void arm_poll(ring *r, u32_t slot) {
  conn *c = &r->conns[slot];
  if (!fd_install_ok) { poll_on(r, slot, -1, 1); return; }
  struct io_uring_sqe *s = sqe_get(r);
  s->opcode = IORING_OP_FIXED_FD_INSTALL;
  s->fd = (int)slot;
  s->flags = IOSQE_FIXED_FILE;
  s->user_data = ud(OP_FD_INSTALL, (u8_t)r->idx, c->gen, slot);
  c->flags |= F_ARMING;   /* the poll or receive follows when the descriptor is made */
}
/* The queue holds each open connection at most once (F_RQ); a slot closed while queued leaves
 * its entry behind (skipped, or a harmless read for the slot's next connection), so the queue has
 * room for two entries per slot. */
static inline void rq_push(ring *r, u32_t slot) {
  conn *c = &r->conns[slot];
  if ((c->flags & F_RQ) || r->nrq >= 2 * r->nslots) return;
  c->flags |= F_RQ;
  r->rq[(r->rq_head + r->nrq++) % (2 * r->nslots)] = slot;
}
static void submit_read(ring *r, u32_t slot) {
  conn *c = &r->conns[slot];
  struct io_uring_sqe *s = sqe_get(r);
  s->opcode = IORING_OP_RECV;
  s->fd = (int)slot;
  s->flags = IOSQE_FIXED_FILE | IOSQE_BUFFER_SELECT;
  s->buf_group = 0;
  s->len = BUFSZ;
  s->msg_flags = MSG_DONTWAIT;
  s->user_data = ud(OP_RECV, (u8_t)r->idx, c->gen, slot);
  r->reads_out++;
}
/* one read for each queued connection while the ring has buffers; returns how many */
static u32_t issue_reads(ring *r) {
  u32_t n = 0;
  while (r->nrq && r->reads_out < NBUF) {
    u32_t slot = r->rq[r->rq_head];
    r->rq_head = (r->rq_head + 1) % (2 * r->nslots);
    r->nrq--;
    conn *c = &r->conns[slot];
    c->flags &= ~F_RQ;
    if (c->state != C_OPEN) continue;
    submit_read(r, slot);
    n++;
  }
  return n;
}
static void submit_send(ring *r, u32_t slot) {
  conn *c = &r->conns[slot];
  struct io_uring_sqe *s = sqe_get(r);
  s->opcode = IORING_OP_SEND;
  s->fd = (int)slot;
  s->flags = IOSQE_FIXED_FILE;
  s->addr = (u64_t)(uintptr_t)(lean_sarray_cptr(c->out) + c->out_off);
  s->len = c->out_len;
  s->msg_flags = MSG_NOSIGNAL | MSG_WAITALL;
  s->user_data = ud(OP_SEND, (u8_t)r->idx, c->gen, slot);
  c->flags |= F_SENDING;
}
static void conn_release_output(conn *c) {
  if (c->out) { lean_dec(c->out); c->out = 0; }
  for (oq *q = c->q; q;) { oq *n = q->next; lean_dec(q->buf); free(q); q = n; }
  c->q = 0;
}
static void conn_free(ring *r, conn *c);

/* Each ring's open connections in order of their last activity, least recent first: an accept puts
 * a connection at the end, so does the completion of the last send of an answer, and a close takes
 * it out. So the head is the connection idle the longest; the idle policy below walks from there.
 * Nothing of this happens unless FEED_CONN_BUDGET or FEED_IDLE_MS is set (idle_on). The lists are
 * kept only while they may be needed (lru_on: from 7/8 of the budget, or with a timeout); before
 * that only the time is noted, in a line the completion has just touched. */
static int idle_on, lru_on;
static inline void lru_unlink(ring *r, u32_t slot) {
  conn *c = &r->conns[slot];
  if (c->lprev != LNIL) r->conns[c->lprev].lnext = c->lnext; else r->lru_head = c->lnext;
  if (c->lnext != LNIL) r->conns[c->lnext].lprev = c->lprev; else r->lru_tail = c->lprev;
}
static inline void lru_append(ring *r, u32_t slot) {
  conn *c = &r->conns[slot];
  if (!idle_on) return;
  c->active_ms = loop_ms;
  if (!lru_on) return;
  c->lprev = r->lru_tail;
  c->lnext = LNIL;
  if (r->lru_tail != LNIL) r->conns[r->lru_tail].lnext = (u16_t)slot; else r->lru_head = (u16_t)slot;
  r->lru_tail = (u16_t)slot;
}
static inline void lru_touch(ring *r, u32_t slot) {
  if (!idle_on) return;
  if (!lru_on || r->lru_tail == slot) { r->conns[slot].active_ms = loop_ms; return; }
  lru_unlink(r, slot);
  lru_append(r, slot);
}

/* Close: cancel the connection's receive, or remove its poll, first while it is armed (it holds a
 * reference to the socket), then release the direct descriptor. A poll still being set up (F_ARMING) holds no reference yet:
 * the completion of its descriptor finds the connection gone and closes the descriptor. */
static void conn_close(ring *r, u32_t slot) {
  conn *c = &r->conns[slot];
  if (c->state != C_OPEN) return;
  if (c->flags & (F_SENDING | F_TRYCLOSE)) { c->flags |= F_CLOSE_AFTER; return; }
  c->state = C_CLOSING;
  struct io_uring_sqe *s;
  if (c->flags & F_MRECV) {
    s = sqe_get(r);
    s->opcode = IORING_OP_ASYNC_CANCEL;
    s->addr = ud(OP_MRECV, (u8_t)r->idx, c->gen, slot);
    s->flags = IOSQE_IO_HARDLINK | IOSQE_CQE_SKIP_SUCCESS;
    s->user_data = ud(OP_CANCEL, (u8_t)r->idx, c->gen, slot);
  } else if (c->flags & F_POLL) {
    s = sqe_get(r);
    s->opcode = IORING_OP_POLL_REMOVE;
    s->addr = ud(OP_POLL, (u8_t)r->idx, c->gen, slot);
    s->flags = IOSQE_IO_HARDLINK | IOSQE_CQE_SKIP_SUCCESS;
    s->user_data = ud(OP_POLL_REMOVE, (u8_t)r->idx, c->gen, slot);
  }
  s = sqe_get(r);
  s->opcode = IORING_OP_CLOSE;
  s->file_index = slot + 1;
  s->flags = IOSQE_CQE_SKIP_SUCCESS;
  s->user_data = ud(OP_CLOSE, (u8_t)r->idx, c->gen, slot);
  /* the slot is reused only after the kernel released it: an accept into it reports the new
   * socket, so freeing the record now is safe (stale completions carry the old generation) */
  conn_free(r, c);
}
static void conn_free(ring *r, conn *c) {
  if (lru_on) lru_unlink(r, (u32_t)(c - r->conns));
  conn_release_output(c);
  free(c->in);
  c->in = 0;
  c->in_len = c->in_cap = 0;
  c->flags = 0;
  c->chunk = -1;
  c->state = C_FREE;
  c->gen++;
  r->nopen--;
}
static void conn_send(ring *r, u32_t slot, lean_object *buf, u32_t off, u32_t len) {
  conn *c = &r->conns[slot];
  if (c->state != C_OPEN || !len) { lean_dec(buf); return; }
  if (!(c->flags & F_SENDING)) {
    c->out = buf; c->out_off = off; c->out_len = len;
    submit_send(r, slot);
    return;
  }
  oq *q = malloc(sizeof *q);
  if (!q) abort();
  q->next = 0; q->buf = buf; q->off = off; q->len = len;
  oq **t = &c->q;
  while (*t) t = &(*t)->next;
  *t = q;
}

/* ---- idle connections under a budget ----------------------------------------------------- */
/* implemented in Lean: Feed.Idle.pick (Feed/Server.lean; its theorems in Feed/Proofs/Idle.lean):
 * for each candidate (idle[i] ms, busy[i]), whether to close it, when `open` connections are
 * open. It consumes its arguments. */
extern lean_object *feed_idle_pick(lean_object *budget, lean_object *min_idle, lean_object *timeout, lean_object *open,
                                   lean_object *idle, lean_object *busy);

/* The policy, a safety valve for memory pressure that is off unless configured (idle_setup).
 * Every open connection costs about 4 KB of kernel memory, used or not, and on a 2 GB machine
 * that can limit the number of users before the CPU does. So while more connections are open than
 * the budget (FEED_CONN_BUDGET), the connections idle the longest are closed, as a keep-alive
 * timeout would; with FEED_IDLE_MS set, so is every connection idle that long. Once per
 * iteration, if there is anything to do, the heads of the rings' lists are merged in order of idle
 * time and offered to Feed.Idle.pick, which never picks a busy one. A connection is busy while it
 * has input not yet answered, an answer being sent or queued, is in the current batch, has no
 * armed poll, or is closing; also, for this iteration, when its ring has completions not yet
 * handled (one may be its input) or no room in the submission queue (a flush there would run
 * completions first). Below 7/8 of the budget nothing is done beyond noting the time of each
 * answer and one comparison per iteration; above, the lists cost two links per answer. */
static u64_t idle_budget, idle_min_ms = 1000, idle_timeout_ms;
static u32_t idle_per_iter = 256;
static long idle_test_delay_us;   /* FEED_IDLE_TEST_DELAY_US, for tests: a pause between deciding closes and submitting them */
static int idle_due;   /* something may be closed in the next iterations: wake up soon when idle */
#define CAND_MAX 4096
static u32_t cand_idle[CAND_MAX];
static u8_t cand_busy[CAND_MAX], cand_pick[CAND_MAX];
static u32_t cand_ref[CAND_MAX];

/* Feed.Idle.pick on the first n candidates, into cand_pick (its result has one entry per
 * candidate: length_pickList). */
static void pick_candidates(u64_t budget, u64_t open, u32_t n) {
  lean_object *idle = lean_alloc_array(n, n), *busy = lean_alloc_array(n, n);
  for (u32_t i = 0; i < n; i++) {
    lean_array_set_core(idle, i, lean_box(cand_idle[i]));
    lean_array_set_core(busy, i, lean_box(cand_busy[i]));
  }
  lean_object *pick = feed_idle_pick(u64_nat(budget), u64_nat(idle_min_ms), u64_nat(idle_timeout_ms), u64_nat(open), idle, busy);
  for (u32_t i = 0; i < n; i++) cand_pick[i] = (u8_t)lean_unbox(lean_array_get_core(pick, i));
  lean_dec(pick);
}

static inline int conn_busy(const conn *c) {
  return c->state != C_OPEN || c->chunk >= 0 || c->in_len || c->out || c->q || !(c->flags & F_POLL) || (c->flags & F_MRECV) ||
         (c->flags & (F_SENDING | F_RQ | F_HELD | F_SPILL | F_ARMING | F_TRYCLOSE | F_PEER_EOF | F_CLOSE_AFTER | F_RDHUP));
}
/* Close an idle connection, unless input reached it first. The poll is removed first, linked to
 * the close: a wakeup pending on the poll (input arrived since the completions were last handled)
 * makes the removal fail with EALREADY, which cancels the close, and the input is then read and
 * answered as usual. The record stays until the close's completion says which happened (or an
 * accept into the same slot shows that the close went through). */
static void idle_close(ring *r, u32_t slot) {
  conn *c = &r->conns[slot];
  c->flags |= F_TRYCLOSE;
  ntrying++;
  struct io_uring_sqe *s = sqe_get(r);
  s->opcode = IORING_OP_POLL_REMOVE;
  s->addr = ud(OP_POLL, (u8_t)r->idx, c->gen, slot);
  /* no IOSQE_CQE_SKIP_SUCCESS here: when a request with it fails, the requests linked to it are
   * cancelled without a completion, and the close's completion is what resolves the attempt */
  s->flags = IOSQE_IO_LINK;
  s->user_data = ud(OP_POLL_REMOVE, (u8_t)r->idx, c->gen, slot);
  s = sqe_get(r);
  s->opcode = IORING_OP_CLOSE;
  s->file_index = slot + 1;
  s->user_data = ud(OP_IDLE_CLOSE, (u8_t)r->idx, c->gen, slot);
}
/* A safety valve for memory pressure, off unless configured. FEED_CONN_BUDGET (unset or 0: none):
 * above that many open connections the longest idle are closed. Each forced close costs about
 * 42 us of a core when its user comes back (the harness at 280,000 users with a budget of 270,000:
 * 4,450 closes a second, +6.3 us per request), so a budget pays only where the alternative is to
 * run out of memory: on a 1,903 MB VM like the box the kernel's slab held 1.48 GB at 350,000
 * connections (about 4.2 KB each) and 370,000 ran out of memory. FEED_IDLE_MS (unset or 0: none)
 * closes every connection idle that long; FEED_IDLE_MIN_MS (1,000) protects connections active
 * since from the budget; FEED_IDLE_PER_ITER (256) bounds the closes of one iteration. */
static void idle_setup(void) {
  const char *e;
  if ((e = getenv("FEED_IDLE_MS"))) idle_timeout_ms = (u64_t)atoll(e);
  if ((e = getenv("FEED_IDLE_MIN_MS"))) idle_min_ms = (u64_t)atoll(e);
  if ((e = getenv("FEED_IDLE_PER_ITER"))) idle_per_iter = (u32_t)atol(e);
  if ((e = getenv("FEED_IDLE_TEST_DELAY_US"))) idle_test_delay_us = atol(e);
  if (idle_per_iter < 1) idle_per_iter = 1;
  if (idle_per_iter > CAND_MAX / 2 - 64) idle_per_iter = CAND_MAX / 2 - 64;
  if ((e = getenv("FEED_CONN_BUDGET"))) idle_budget = (u64_t)atoll(e);
  idle_on = idle_budget || idle_timeout_ms;
  /* Multishot receives unless FEED_MSRECV=0. The idle policy closes a connection only if no input
   * is pending on its poll (idle_close): with it configured, connections wait on polls. */
  e = getenv("FEED_MSRECV");
  mrecv_mode = !(e && strcmp(e, "0") == 0) && !idle_on;
  if (!mrecv_mode) fprintf(stderr, "transport: connections wait on multishot polls%s\n", idle_on ? " (the idle policy)" : " (FEED_MSRECV=0)");
  if (idle_budget)
    fprintf(stderr, "transport: above %llu open connections the longest idle are closed (FEED_CONN_BUDGET)\n", (unsigned long long)idle_budget);
  if (idle_timeout_ms) fprintf(stderr, "transport: connections idle for %llu ms are closed (FEED_IDLE_MS)\n", (unsigned long long)idle_timeout_ms);
}
/* Start keeping the lists: each ring's open connections sorted by the time of their last activity,
 * least recent first (one pass over the slots, once each time the open count reaches 7/8 of the
 * budget). */
static int cmp_u64(const void *a, const void *b) {
  u64_t x = *(const u64_t *)a, y = *(const u64_t *)b;
  return x < y ? -1 : x > y;
}
static void lru_build(u64_t open) {
  u64_t *keys = 0;
  u32_t cap = 0;
  for (int i = 0; i < nrings; i++) {
    ring *r = &rings[i];
    if (r->nopen > cap) {
      cap = r->nopen;
      free(keys);
      keys = malloc(cap * sizeof(u64_t));
      if (!keys) abort();
    }
    u32_t n = 0;
    for (u32_t s = 0; s < r->nslots && n < r->nopen; s++) {
      conn *c = &r->conns[s];
      if (c->state != C_OPEN) continue;
      keys[n++] = (u64_t)(0xffffffffu - (loop_ms - c->active_ms)) << 16 | s;   /* the longest idle first */
    }
    qsort(keys, n, sizeof *keys, cmp_u64);
    u16_t prev = LNIL;
    for (u32_t k = 0; k < n; k++) {
      u16_t s = (u16_t)(keys[k] & 0xffff);
      r->conns[s].lprev = prev;
      r->conns[s].lnext = LNIL;
      if (prev != LNIL) r->conns[prev].lnext = s; else r->lru_head = s;
      prev = s;
    }
    if (!n) r->lru_head = LNIL;
    r->lru_tail = prev;
  }
  free(keys);
  lru_on = 1;
  fprintf(stderr, "transport: %llu connections open: keeping them in order of activity\n", (unsigned long long)open);
}
static void idle_check(void) {
  idle_due = 0;
  if (!idle_on) return;
  u64_t open = 0;
  for (int i = 0; i < nrings; i++) open += rings[i].nopen;
  open = open > ntrying ? open - ntrying : 0;
  /* the lists from 7/8 of the budget (always with a timeout), none again below 3/4 */
  if (!lru_on && (idle_timeout_ms || open >= idle_budget - idle_budget / 8)) lru_build(open);
  else if (lru_on && !idle_timeout_ms && open < idle_budget - idle_budget / 4) {
    lru_on = 0;
    fprintf(stderr, "transport: %llu connections open: no longer kept in order\n", (unsigned long long)open);
  }
  u64_t budget = idle_budget ? idle_budget : UINT64_MAX;
  if ((open <= budget && !idle_timeout_ms) || !lru_on) return;   /* within the budget: nothing to do */
  u32_t want = open > budget ? (open - budget > idle_per_iter ? idle_per_iter : (u32_t)(open - budget)) : 0;
  u32_t cur[MAX_RINGS], room[MAX_RINGS];
  for (int i = 0; i < nrings; i++) {
    ring *r = &rings[i];
    cur[i] = r->lru_head;
    u32_t used = r->sq_tail - __atomic_load_n(r->sq_khead, __ATOMIC_ACQUIRE);
    room[i] = r->sq_entries > used + 16 ? (r->sq_entries - used - 16) / 2 : 0;
    if (*r->cq_khead != __atomic_load_n(r->cq_ktail, __ATOMIC_ACQUIRE)) room[i] = 0;
  }
  /* the candidates, longest idle first: for the budget, until `want` of them may be closed or the
   * rest were active within FEED_IDLE_MIN_MS; for the timeout, while they are past it */
  u32_t n = 0, spare = 0;
  while (n < CAND_MAX && n < 2 * idle_per_iter + 64) {
    int best = -1;
    u32_t age = 0;
    for (int i = 0; i < nrings; i++) {
      if (cur[i] == LNIL) continue;
      u32_t a = loop_ms - rings[i].conns[cur[i]].active_ms;
      if (best < 0 || a > age) { best = i; age = a; }
    }
    if (best < 0) break;
    if (!(spare < want && age >= idle_min_ms) && !(idle_timeout_ms && age >= idle_timeout_ms)) break;
    ring *r = &rings[best];
    conn *c = &r->conns[cur[best]];
    cand_idle[n] = age;
    cand_busy[n] = (u8_t)(conn_busy(c) || !room[best]);
    cand_ref[n] = cref(best, cur[best]);
    if (!cand_busy[n] && age >= idle_min_ms) spare++;
    n++;
    cur[best] = c->lnext;
  }
  idle_due = n > 0 || want > 0;
  if (!n) return;
  u32_t k = 0;
  pick_candidates(budget, open, n);
  for (u32_t i = 0; i < n; i++) {
    if (!cand_pick[i]) continue;
    ring *r = &rings[cand_ref[i] >> 16];
    if (!room[r->idx]) continue;   /* cannot happen: such candidates are busy */
    room[r->idx]--;
    idle_close(r, cand_ref[i] & 0xffff);
    k++;
  }
  if (k && idle_test_delay_us) { struct timespec q = {idle_test_delay_us / 1000000, idle_test_delay_us % 1000000 * 1000}; nanosleep(&q, 0); }
}

/* ---- the batch ---------------------------------------------------------------------------- */
#define MAX_CHUNKS 65536
static lean_object *chunk_arr;              /* Array ByteArray being built */
static u32_t chunk_ref[MAX_CHUNKS];         /* ring << 16 | slot */
static u32_t chunk_gen[MAX_CHUNKS];
static u32_t nchunks;
static u32_t *held;                         /* these lists hold each connection at most once: */
static u32_t nheld;
static u32_t *rearm;                        /* sized for every connection slot at startup */
static u32_t nrearm;
/* A batch takes at most max_batch connections; input beyond that waits, in arrival order, for
 * the next iterations. Capping it lower (FEED_MAX_BATCH, for measurements) made a saturated
 * server slower to catch up, so by default max_batch does not limit a batch; under a backlog the
 * cap below (BATCH_TARGET_NS) does. */
static u32_t max_batch = MAX_CHUNKS;
/* Under a backlog a batch is capped so that it takes about BATCH_TARGET_NS: the input that arrived
 * since the last iteration goes first, the backlog (connections that did not fit before, oldest
 * first) fills what is left. New requests are then answered within an iteration or two of a few
 * milliseconds, before the kernel's delayed-ACK timer (40 ms) would add a packet to each of them,
 * so a short overload (the end of a ramp of new users) does not turn into a slower steady state;
 * the backlog drains with the capacity left over. Without a backlog batches are far below the cap.
 * FEED_BATCH_TARGET_US overrides the target (0: no cap). */
static u64_t BATCH_TARGET_NS = 6000000ull;
static u32_t batch_cap = MAX_CHUNKS;
static u64_t per_chunk_ns;   /* running estimate of a batch's time per connection */
static u32_t *spilled, *snap;
static u32_t nspilled;


/* the connection's input for this batch: a Lean ByteArray holding its unconsumed bytes */
static lean_object **chunk_slot(ring *r, u32_t slot) {
  conn *c = &r->conns[slot];
  if (c->chunk < 0) {
    if (nchunks >= batch_cap) return 0;
    lean_object *b = lean_alloc_sarray(1, 0, c->in_len + 512);
    if (c->in_len) { memcpy(lean_sarray_cptr(b), c->in, c->in_len); lean_to_sarray(b)->m_size = c->in_len; }
    /* the buffer only carries input from one batch to the next; kept for the connection's
     * lifetime (one for every connection that ever waited, which includes every writer outside
     * a write window) these buffers grew the heap by about 600 bytes per connection over a run */
    free(c->in);
    c->in = 0;
    c->in_len = c->in_cap = 0;
    chunk_arr = lean_array_push(chunk_arr, b);
    c->chunk = (i32_t)nchunks;
    chunk_ref[nchunks] = cref(r->idx, slot);
    chunk_gen[nchunks] = c->gen;
    nchunks++;
  }
  return &lean_to_array(chunk_arr)->m_data[c->chunk];
}
static void on_data(ring *r, u32_t slot, const u8_t *p, u32_t n) {
  conn *c = &r->conns[slot];
  lean_object **b = chunk_slot(r, slot);
  if (!b) {   /* batch full: keep the bytes for the next one */
    if (c->in_len + n > MAX_IN) { conn_close(r, slot); return; }
    if (c->in_len + n > c->in_cap) {
      u32_t cap = (c->in_len + n) * 2;
      u8_t *m = realloc(c->in, cap);
      if (!m) abort();
      c->in = m; c->in_cap = cap;
    }
    memcpy(c->in + c->in_len, p, n);
    c->in_len += n;
    if (!(c->flags & F_SPILL)) { c->flags |= F_SPILL; spilled[nspilled++] = cref(r->idx, slot); }
    return;
  }
  if (lean_sarray_size(*b) + n > MAX_IN) { conn_close(r, slot); return; }
  *b = ba_reserve(*b, n);
  memcpy(ba_end(*b), p, n);
  ba_grow(*b, n);
}

static void handle_cqe(ring *r, struct io_uring_cqe *e) {
  u64_t u = e->user_data;
  u8_t op = (u8_t)(u >> 56);
  u16_t gen = (u16_t)(u >> 32);
  u32_t slot = (u32_t)u;
  int res = e->res;
  switch (op) {
  case OP_ACCEPT:
    if (res >= 0) {
      if ((u32_t)res >= r->nslots) return;
      conn *c = &r->conns[res];
      if (c->state == C_OPEN && (c->flags & F_TRYCLOSE)) {
        /* the kernel gave the slot to a new connection, so the idle close of the old one went
         * through and its completion is still to come (it will find a newer generation) */
        ntrying--;
        st_idle_closed++;
        conn_free(r, c);
      }
      if (c->state != C_FREE) { /* cannot happen: the kernel allocated a free slot */ }
      c->state = C_OPEN;
      c->flags = 0;
      c->chunk = -1;
      r->nopen++;
      lru_append(r, (u32_t)res);
      arm_poll(r, (u32_t)res);
    } else if (res != -ECANCELED && res != -EINTR) {
      static time_t last;
      if (time(0) != last) { last = time(0); fprintf(stderr, "accept: %s\n", strerror(-res)); }
    }
    if (!(e->flags & IORING_CQE_F_MORE)) { r->accept_armed &= (u16_t)~(1u << gen); r->accept_cancel &= (u16_t)~(1u << gen); }
    return;
  case OP_POLL: {
    conn *c = &r->conns[slot];
    if ((u16_t)c->gen != gen || c->state != C_OPEN) return;
    if (!(e->flags & IORING_CQE_F_MORE)) {   /* the poll ended: arm it again after this batch */
      c->flags &= ~F_POLL;
      if (res != -ECANCELED) rearm[nrearm++] = cref(r->idx, slot);
    }
    if (res > 0) {
      /* the peer finished sending: the read after its last data reports the end */
      if (res & (POLLRDHUP | POLLHUP | POLLERR)) c->flags |= F_RDHUP;
      rq_push(r, slot);
    }
    return;
  }
  case OP_RECV: {
    conn *c = &r->conns[slot];
    int has_buf = (e->flags & IORING_CQE_F_BUFFER) != 0;
    u16_t bid = (u16_t)(e->flags >> IORING_CQE_BUFFER_SHIFT);
    if (r->reads_out) r->reads_out--;
    if ((u16_t)c->gen != gen || c->state != C_OPEN) { if (has_buf) buf_recycle(r, bid); return; }
    if (res > 0) {
      on_data(r, slot, r->bufs + (size_t)bid * BUFSZ, (u32_t)res);
      buf_recycle(r, bid);
      /* a full buffer may have left more in the socket, and after the peer's FIN the next read
       * reports the end: read again; else the socket is drained, and its receive is armed again */
      if ((res == BUFSZ || (c->flags & F_RDHUP)) && c->state == C_OPEN) rq_push(r, slot);
      else if (c->state == C_OPEN && !(c->flags & (F_POLL | F_MRECV | F_ARMING))) { st_rearms++; arm_poll(r, slot); }
    } else {
      if (has_buf) buf_recycle(r, bid);
      if (res == -EAGAIN) {               /* nothing to read after all: the socket is drained */
        if (!(c->flags & (F_POLL | F_MRECV | F_ARMING))) { st_rearms++; arm_poll(r, slot); }
      }
      else if (res == -ENOBUFS) { st_nobufs++; rq_push(r, slot); }
      else if (res == 0) {
        /* the peer finished sending; answer what it sent, then close */
        c->flags |= F_PEER_EOF;
        if (c->chunk < 0 && !(c->flags & F_SENDING) && !c->in_len) conn_close(r, slot);
      } else conn_close(r, slot);
    }
    return;
  }
  case OP_MRECV: {
    conn *c = &r->conns[slot];
    int has_buf = (e->flags & IORING_CQE_F_BUFFER) != 0;
    u16_t bid = (u16_t)(e->flags >> IORING_CQE_BUFFER_SHIFT);
    if ((u16_t)c->gen != gen || c->state != C_OPEN) { if (has_buf) buf_recycle(r, bid); return; }
    int more = (e->flags & IORING_CQE_F_MORE) != 0;
    if (!more) c->flags &= ~F_MRECV;
    if (res > 0) {
      if (has_buf) { on_data(r, slot, r->bufs + (size_t)bid * BUFSZ, (u32_t)res); buf_recycle(r, bid); }
      if (!more && c->state == C_OPEN) rq_push(r, slot);   /* it ended: drain by reads, then arm it again */
    } else {
      if (has_buf) buf_recycle(r, bid);
      if (res == -ENOBUFS) { st_nobufs++; rq_push(r, slot); }   /* a burst took the buffers: the read queue */
      else if (res == 0) {
        c->flags |= F_PEER_EOF;   /* the peer finished sending; answer what it sent, then close */
        if (c->chunk < 0 && !(c->flags & F_SENDING) && !c->in_len) conn_close(r, slot);
      } else if (res != -ECANCELED) conn_close(r, slot);
    }
    return;
  }
  case OP_CANCEL:
    return;
  case OP_SEND: {
    conn *c = &r->conns[slot];
    if ((u16_t)c->gen != gen || c->state == C_FREE) return;
    c->flags &= ~F_SENDING;
    if (res > 0 && (u32_t)res < c->out_len) {   /* short send: continue with the rest */
      c->out_off += (u32_t)res;
      c->out_len -= (u32_t)res;
      submit_send(r, slot);
      return;
    }
    if (c->out) { lean_dec(c->out); c->out = 0; }
    if (res < 0) { conn_release_output(c); c->flags &= ~F_CLOSE_AFTER; conn_close(r, slot); return; }
    if (c->q) {
      oq *q = c->q;
      c->q = q->next;
      c->out = q->buf; c->out_off = q->off; c->out_len = q->len;
      free(q);
      submit_send(r, slot);
      return;
    }
    if (c->state == C_OPEN) lru_touch(r, slot);   /* an answer went out: idle from now */
    if (c->flags & (F_CLOSE_AFTER | F_PEER_EOF)) { c->flags &= ~F_CLOSE_AFTER; if (c->chunk < 0 && !(c->flags & (F_HELD | F_SPILL))) conn_close(r, slot); }
    return;
  }
  case OP_CLOSE: {
    conn *c = &r->conns[slot];
    if ((u16_t)c->gen == gen && c->state == C_CLOSING) conn_free(r, c);
    return;
  }
  case OP_FD_INSTALL: {
    conn *c = &r->conns[slot];
    if ((u16_t)c->gen != gen || c->state != C_OPEN) { if (res >= 0) close(res); return; }
    c->flags &= ~F_ARMING;
    if (res >= 0) { if (mrecv_mode) mrecv_on(r, slot, res); else poll_on(r, slot, res, 0); return; }
    /* no descriptor (a kernel before 6.8, or the descriptor limit): poll the direct descriptor */
    if (res == -EINVAL || res == -EOPNOTSUPP) fd_install_ok = 0;
    st_pinned++;
    poll_on(r, slot, -1, 1);
    return;
  }
  case OP_CLOSE_FD:
    return;
  case OP_IDLE_CLOSE: {
    conn *c = &r->conns[slot];
    /* an accept into the slot may have shown already that the close went through */
    if ((u16_t)c->gen != gen || c->state != C_OPEN || !(c->flags & F_TRYCLOSE)) return;
    ntrying--;
    c->flags &= ~F_TRYCLOSE;
    if (res >= 0) { st_idle_closed++; conn_free(r, c); return; }
    if (res == -ECANCELED) {
      /* the poll had a wakeup pending (input arrived first) or was gone: the connection stays */
      st_idle_kept++;
      if (c->flags & F_CLOSE_AFTER) { c->flags &= ~F_CLOSE_AFTER; conn_close(r, slot); }
      return;
    }
    conn_close(r, slot);   /* the poll is gone but the close failed: close it the usual way */
    return;
  }
  case OP_SHUTDOWN:
  case OP_PROVIDE:
  case OP_POLL_REMOVE:
    return;
  }
}

static int reap(ring *r) {
  u32_t head = *r->cq_khead, tail = __atomic_load_n(r->cq_ktail, __ATOMIC_ACQUIRE);
  int n = 0;
  while (head != tail && n < CQE_BUDGET) {
    handle_cqe(r, &r->cqes[head & r->cq_mask]);
    head++;
    n++;
    if (head == tail) tail = __atomic_load_n(r->cq_ktail, __ATOMIC_ACQUIRE);
  }
  __atomic_store_n(r->cq_khead, head, __ATOMIC_RELEASE);
  return n;
}

/* ---- setup ---------------------------------------------------------------------------------- */
static int listen_socket(const char *host, int port) {
  struct sockaddr_storage ss;
  socklen_t sl;
  memset(&ss, 0, sizeof ss);
  struct sockaddr_in *a4 = (struct sockaddr_in *)&ss;
  struct sockaddr_in6 *a6 = (struct sockaddr_in6 *)&ss;
  int fam;
  if (inet_pton(AF_INET, host, &a4->sin_addr) == 1) { fam = AF_INET; a4->sin_family = AF_INET; a4->sin_port = htons((u16_t)port); sl = sizeof *a4; }
  else if (inet_pton(AF_INET6, host, &a6->sin6_addr) == 1) { fam = AF_INET6; a6->sin6_family = AF_INET6; a6->sin6_port = htons((u16_t)port); sl = sizeof *a6; }
  else if (!strcmp(host, "localhost")) { fam = AF_INET; a4->sin_family = AF_INET; a4->sin_port = htons((u16_t)port); a4->sin_addr.s_addr = htonl(INADDR_LOOPBACK); sl = sizeof *a4; }
  else { fprintf(stderr, "fatal: HOST %s is not an IP address\n", host); exit(1); }
  int fd = socket(fam, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (fd < 0) { perror("socket"); exit(1); }
  int one = 1;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
  setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof one);
  setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);   /* inherited by accepted sockets */
  if (bind(fd, (struct sockaddr *)&ss, sl) < 0) { perror("bind"); exit(1); }
  if (listen(fd, 65535) < 0) { perror("listen"); exit(1); }
  return fd;
}

/* Kernels newer than the box's 6.8 charge ring memory to RLIMIT_MEMLOCK (8 MB under systemd and
 * on CI runners), where eight rings of this size do not fit: on ENOMEM a ring is made with half
 * the entries, down to an eighth, and if a later ring cannot be made at all the server runs on the
 * rings it has. Returns 0, or -1 when this ring could not be made. */
static int ring_init(ring *r, int idx, u32_t slots, int defer) {
  struct io_uring_params p;
  int fd = -1;
  for (u32_t div = 1; div <= 8 && fd < 0; div *= 2) {
    memset(&p, 0, sizeof p);
    p.flags = IORING_SETUP_SINGLE_ISSUER | IORING_SETUP_CQSIZE | IORING_SETUP_SUBMIT_ALL |
              (defer ? IORING_SETUP_DEFER_TASKRUN | IORING_SETUP_TASKRUN_FLAG : 0);
    p.cq_entries = CQ_ENTRIES / div;
    fd = sys_setup(SQ_ENTRIES / div, &p);
    if (fd < 0 && errno != ENOMEM) break;
  }
  if (fd < 0) {
    if (idx == 0) { perror("io_uring_setup"); exit(1); }
    fprintf(stderr, "transport: ring %d not made (%s); serving on %d rings\n", idx, strerror(errno), idx);
    return -1;
  }
  r->fd = fd;
  r->idx = idx;
  r->reg_idx = -1;
  r->defer = (u8_t)defer;
  size_t sq_sz = p.sq_off.array + p.sq_entries * sizeof(u32_t);
  size_t cq_sz = p.cq_off.cqes + p.cq_entries * sizeof(struct io_uring_cqe);
  if (cq_sz > sq_sz) sq_sz = cq_sz;
  u8_t *m = mmap(0, sq_sz, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE, fd, IORING_OFF_SQ_RING);
  if (m == MAP_FAILED) { perror("mmap sq"); if (idx == 0) exit(1); close(fd); return -1; }
  r->sq_khead = (u32_t *)(m + p.sq_off.head);
  r->sq_ktail = (u32_t *)(m + p.sq_off.tail);
  r->sq_kflags = (u32_t *)(m + p.sq_off.flags);
  r->sq_mask = *(u32_t *)(m + p.sq_off.ring_mask);
  r->sq_entries = *(u32_t *)(m + p.sq_off.ring_entries);
  r->sq_array = (u32_t *)(m + p.sq_off.array);
  for (u32_t i = 0; i < r->sq_entries; i++) r->sq_array[i] = i;
  r->sq_tail = *r->sq_ktail;
  r->cq_khead = (u32_t *)(m + p.cq_off.head);
  r->cq_ktail = (u32_t *)(m + p.cq_off.tail);
  r->cq_mask = *(u32_t *)(m + p.cq_off.ring_mask);
  r->cqes = (struct io_uring_cqe *)(m + p.cq_off.cqes);
  r->sqes = mmap(0, p.sq_entries * sizeof(struct io_uring_sqe), PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE, fd, IORING_OFF_SQES);
  if (r->sqes == MAP_FAILED) { perror("mmap sqes"); if (idx == 0) exit(1); munmap(m, sq_sz); close(fd); return -1; }
  /* use a registered ring descriptor for io_uring_enter */
  struct io_uring_rsrc_update up = {.offset = -1U, .data = (u64_t)fd};
  if (getenv("FEED_REG_RING") && sys_register(fd, IORING_REGISTER_RING_FDS, &up, 1) == 1) r->reg_idx = (int)up.offset;
  /* direct descriptor table */
  struct io_uring_rsrc_register rr;
  memset(&rr, 0, sizeof rr);
  rr.nr = slots;
  rr.flags = IORING_RSRC_REGISTER_SPARSE;
  if (sys_register(fd, IORING_REGISTER_FILES2, &rr, sizeof rr) < 0) {
    perror("register files");
    if (idx == 0) exit(1);
    munmap(r->sqes, p.sq_entries * sizeof(struct io_uring_sqe)); munmap(m, sq_sz); close(fd);
    return -1;
  }
  r->nslots = slots;
  /* zeroed pages, touched only by connections that take a slot (an accept sets its slot up) */
  r->conns = calloc(slots, sizeof(conn));
  r->rq = malloc(2 * slots * sizeof(u32_t));
  if (!r->conns || !r->rq) abort();
  /* receive buffers: a provided-buffer ring, else the older PROVIDE_BUFFERS operation */
  r->bufs = mmap(0, (size_t)NBUF * BUFSZ, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (r->bufs == MAP_FAILED) { perror("mmap bufs"); exit(1); }
  r->br = mmap(0, NBUF * sizeof(struct io_uring_buf), PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (r->br == MAP_FAILED) { perror("mmap buf ring"); exit(1); }
  struct io_uring_buf_reg reg;
  memset(&reg, 0, sizeof reg);
  reg.ring_addr = (u64_t)(uintptr_t)r->br;
  reg.ring_entries = NBUF;
  reg.bgid = 0;
  int brc = getenv("FEED_NO_PBUF") ? (errno = ENOSYS, -1) : sys_register(fd, IORING_REGISTER_PBUF_RING, &reg, 1);   /* FEED_NO_PBUF: for measurements */
  if (brc < 0 && errno == EINVAL) {
    /* Ubuntu's 6.8 kernels from 6.8.0-136 (and a cloud VM's 6.8 kernel) invert the check of the
     * reserved fields and reject zero ones (Launchpad #2162843); they accept a nonzero reserved
     * byte, and a correct kernel never gets here. The retry is c-iouring-pavlyhalim #245's
     * (src/sys.h); fsharp-kestrel-delneg #201 and ada-native-visseranalytics #211 had it earlier. */
    reg.resv[0] = 1;
    brc = sys_register(fd, IORING_REGISTER_PBUF_RING, &reg, 1);
  }
  if (brc < 0) {
    munmap(r->br, NBUF * sizeof(struct io_uring_buf));
    r->br = 0;
    r->recycle = malloc(sizeof(u16_t) * NBUF);
    if (!r->recycle) abort();
    if (idx == 0) fprintf(stderr, "transport: provided-buffer rings unavailable (%s), using PROVIDE_BUFFERS\n", strerror(errno));
  }
  r->br_tail = 0;
  for (u32_t i = 0; i < NBUF; i++) buf_recycle(r, (u16_t)i);
  buf_publish(r);
  /* one eventfd for all rings: it fires when a deferring ring gets work, and when another ring
   * posts completions, so the idle wait ends on either */
  if (sys_register(fd, IORING_REGISTER_EVENTFD, &evfd, 1) < 0) { perror("register eventfd"); exit(1); }
  r->hot = 1;
  r->lru_head = r->lru_tail = LNIL;
  return 0;
}

/* Termination. A listener with an accept still pending in a ring can outlive the process on some
 * kernels and keep taking connections from the next instance (SO_REUSEPORT), so on SIGTERM/SIGINT
 * the listeners are shut down and every connection closed before exiting. The signal can be
 * delivered to another thread (the checkpoint thread), which leaves the loop's idle wait running
 * until its timeout, so the handler also wakes it through the eventfd. */
static volatile sig_atomic_t stop_requested;
static void on_stop(int sig) {
  (void)sig;
  stop_requested = 1;
  int saved = errno;
  u64_t one = 1;
  if (write(evfd, &one, sizeof one) < 0) {}
  errno = saved;
}
static void transport_shutdown(void) {
  /* every listener first: an unregister below waits for the requests in flight on its ring */
  for (int l = 0; l < nlisten; l++) {
    shutdown(lfds[l], SHUT_RDWR);
    close(lfds[l]);
  }
  for (int i = 0; i < nrings; i++) sys_register(rings[i].fd, IORING_UNREGISTER_FILES, 0, 0);
  fprintf(stderr, "transport: stopped\n");
}

static inline int ring_pending(ring *r) {
  return r->to_submit || r->hot || r->nrq ||
         (__atomic_load_n(r->sq_kflags, __ATOMIC_ACQUIRE) & (IORING_SQ_TASKRUN | IORING_SQ_CQ_OVERFLOW)) ||
         *r->cq_khead != __atomic_load_n(r->cq_ktail, __ATOMIC_ACQUIRE);
}

/* Rings. Rings are made as connections fill them, as c-iouring-pavlyhalim (#245) and
 * rust-iouring-kensac (#264) do, so only as many are busy as the connection count needs, and the
 * loop enters each ring once per iteration, in #264's order: each other ring submits what the last
 * batch queued and runs its task work (posting its completions), then ring 0 submits and waits, in
 * a timed io_uring_enter, for WAIT_MIN completions or the rest of the period. Input that reaches
 * another ring during that wait is read in the next iteration. Each round of reads (with polls, or
 * after a burst ended receives) enters the rings with queued connections once more. The idle wait
 * (epoll on the eventfd every ring signals when it gets work) ends on a completion anywhere. There
 * are NLISTEN listeners on the port (each with its own accept queue of somaxconn, 4,096 on the
 * box); their multishot accepts are armed on the ring being filled, and also on the next one once
 * the first is within ACCEPT_NEXT slots of full; a ring's accepts are cancelled ACCEPT_STOP slots
 * before its table is full, because an accept that finds the table full makes the kernel reset
 * that client (accept_policy is adapted from #245's, in its src/server.c).
 * Switches, for measurements: FEED_RINGS_PLAIN gives the rings after ring 0 ordinary task work, as
 * #245 does, so their completions are posted without entering them (each then wakes the loop out
 * of ring 0's wait); FEED_RINGS_SLEEP keeps the previous loop (every ring with work entered after
 * the wait and again to submit, a sleep between iterations) with rings made as they fill; and
 * FEED_RINGS_UPFRONT, also chosen by the idle policy (its race-free close was tested only with this
 * design, see idle_close), keeps the previous design: every ring made at startup with a listener of
 * its own, and the previous loop. */
#define ACCEPT_NEXT 8192
#define ACCEPT_STOP 4096
static u32_t WAIT_MIN = 64;   /* FEED_WAIT_MIN overrides it (for measurements) */
static void accept_policy(void) {
  if (rings_upfront) {
    for (int i = 0; i < nrings; i++) {
      ring *r = &rings[i];
      if (r->nopen + 16 >= r->nslots) continue;   /* table nearly full: accept again after closes */
      for (int l = i; l < nlisten; l += nrings) if (!(r->accept_armed & (1u << l))) arm_accept(r, l);
    }
    return;
  }
  ring *last = &rings[nrings - 1];
  if (nrings < nrings_max && !ring_grow_failed && last->nopen + ACCEPT_NEXT >= last->nslots) {
    if (ring_init(&rings[nrings], nrings, ring_slots, !rings_plain) == 0) {
      fprintf(stderr, "transport: ring %d made (%u open on ring %d)\n", nrings, last->nopen, nrings - 1);
      nrings++;
    } else ring_grow_failed = 1;   /* stay at these rings: the last one's accepts stop ACCEPT_STOP short of full */
  }
  int lowest = -1;
  for (int i = 0; i < nrings; i++)
    if (rings[i].nopen + ACCEPT_STOP < rings[i].nslots) { lowest = i; break; }
  for (int i = 0; i < nrings; i++) {
    ring *r = &rings[i];
    int room = r->nopen + ACCEPT_STOP < r->nslots;
    int want = room && lowest >= 0 &&
               (i == lowest || (i == lowest + 1 && rings[lowest].nopen + ACCEPT_NEXT >= rings[lowest].nslots));
    for (int l = 0; l < nlisten; l++) {
      u16_t bit = (u16_t)(1u << l);
      if (want && !(r->accept_armed & bit)) arm_accept(r, l);
      else if (!room && (r->accept_armed & bit) && !(r->accept_cancel & bit)) cancel_accept(r, l);
    }
  }
}

static u64_t now_unix(void) {
  struct timespec ts;
  clock_gettime(CLOCK_REALTIME, &ts);
  return (u64_t)ts.tv_sec;
}
static u64_t mono_ns(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (u64_t)ts.tv_sec * 1000000000ull + (u64_t)ts.tv_nsec;
}
static int writes_ok = 1;

/* Hand the batch to Lean and deliver its replies. */
static void run_batch(void) {
  if (!nchunks) return;
  u64_t now = now_unix();
  lean_object *arr = chunk_arr;
  chunk_arr = lean_alloc_array(0, 256);
  lean_inc(g_secret);
  lean_inc(arr);   /* read below, after the handler consumed its reference */
  lean_object *res = feed_batch(arr, now, now - start_s, (uint8_t)writes_ok, g_secret);
  if (!lean_io_result_is_ok(res)) { lean_io_result_show_error(res); exit(1); }
  lean_object *replies = lean_io_result_get_value(res);
  st_batches++;
  st_reqchunks += nchunks;
  if (nchunks > st_max_chunks) st_max_chunks = nchunks;
  size_t nrep = lean_array_size(replies);
  for (u32_t i = 0; i < nchunks; i++) {
    ring *r = &rings[chunk_ref[i] >> 16];
    u32_t slot = chunk_ref[i] & 0xffff;
    conn *c = &r->conns[slot];
    if (c->gen != chunk_gen[i] || c->state != C_OPEN) continue;
    c->chunk = -1;
    if (i >= nrep) { conn_close(r, slot); continue; }
    lean_object *rep = lean_array_get_core(replies, i);
    lean_object *buf = lean_ctor_get(rep, 0);
    u64_t start = nat_u64(lean_ctor_get(rep, 1)), consumed = nat_u64(lean_ctor_get(rep, 2)), flags = nat_u64(lean_ctor_get(rep, 3));
    lean_object *input = lean_array_get_core(arr, i);
    size_t ilen = lean_sarray_size(input);
    if (consumed > ilen) consumed = ilen;
    /* keep what the handler did not consume */
    size_t rest = ilen - (size_t)consumed;
    if (rest) {
      if (rest > MAX_IN) { conn_close(r, slot); continue; }
      if (rest > c->in_cap) { u8_t *m = realloc(c->in, rest + 256); if (!m) abort(); c->in = m; c->in_cap = (u32_t)rest + 256; }
      memcpy(c->in, lean_sarray_cptr(input) + consumed, rest);
      c->in_len = (u32_t)rest;
    }
    size_t blen = lean_sarray_size(buf);
    if (start < blen) { lean_inc(buf); conn_send(r, slot, buf, (u32_t)start, (u32_t)(blen - start)); }
    if (flags & 1) { conn_close(r, slot); continue; }
    if ((flags & 2) && !(c->flags & F_HELD)) { c->flags |= F_HELD; held[nheld++] = cref(r->idx, slot); }
    if ((c->flags & F_PEER_EOF) && !(c->flags & (F_HELD | F_SPILL | F_SENDING))) conn_close(r, slot);
  }
  lean_dec(res);
  lean_dec(arr);
  nchunks = 0;
}

/* Connections whose input did not fit in the previous batch come first in this one. */
static void present_spill(void) {
  u32_t n = nspilled;
  memcpy(snap, spilled, n * sizeof(u32_t));
  nspilled = 0;
  for (u32_t i = 0; i < n; i++) {
    ring *r = &rings[snap[i] >> 16];
    u32_t slot = snap[i] & 0xffff;
    conn *c = &r->conns[slot];
    if (c->state != C_OPEN || !(c->flags & F_SPILL)) continue;
    if (nchunks >= batch_cap) { spilled[nspilled++] = snap[i]; continue; }
    c->flags &= ~F_SPILL;
    if (c->in_len) chunk_slot(r, slot);
  }
}

/* Connections whose handler deferred complete requests (they follow a write in the same input)
 * get their remaining input again in the next batch, after the write committed. */
static void present_held(void) {
  if (!writes_ok) return;   /* held requests wait for writes to resume */
  u32_t n = nheld;
  memcpy(snap, held, n * sizeof(u32_t));
  nheld = 0;
  for (u32_t i = 0; i < n; i++) {
    ring *r = &rings[snap[i] >> 16];
    u32_t slot = snap[i] & 0xffff;
    conn *c = &r->conns[slot];
    if (c->state != C_OPEN || !(c->flags & F_HELD)) continue;
    c->flags &= ~F_HELD;
    /* no room in this batch (a capped batch under backlog): stay held for the next one */
    if (c->in_len && !chunk_slot(r, slot)) { c->flags |= F_HELD; held[nheld++] = snap[i]; }
  }
}

/* Batching: while busy, after an iteration that finished early the loop waits on ring 0 until it
 * has WAIT_MIN completions or period_us has passed since the iteration began (with
 * FEED_RINGS_UPFRONT or FEED_RINGS_SLEEP it sleeps for the rest of the period), so that the next
 * one serves a batch (one wakeup, one transaction, one Lean call and one burst of sends for many
 * requests). An iteration that took longer than the period continues at once, so no time is lost
 * when the CPU is saturated. FEED_PERIOD_US overrides it (for measurements). */
static long period_us = 2000;

/* Spinning instead of halting, off by default. With FEED_SPIN_US set, between batches the loop
 * keeps the CPU: it watches ring 0's completion queue and task-work flag for up to spin_us (and at
 * most the rest of the period) before it sleeps, and the idle wait spins that long before
 * epoll_wait. A guest whose CPU has nothing to run halts and gives its core back to the host. On a
 * KVM guest set up like the box this server halted 0.24 times a request at 290,000 users against
 * 0.10 for rust-iouring-kensac #264 at 310,000, and 2,000 µs of spinning brought it to 0.06 at the
 * same latency there. On the box it did not move the ceiling: 307205a, which spun by default, held
 * 280,000 users as fe89683 did (README, "The spin"). Not while the checkpoint thread wants the CPU
 * (ckpt_wanted): the loop then sleeps, so the thread gets the idle time. */
static long spin_us;
static u64_t st_spins;
static inline u32_t cq_ready(ring *r) { return __atomic_load_n(r->cq_ktail, __ATOMIC_ACQUIRE) - *r->cq_khead; }

/* Writes go in at most one batch every write_window_us: a write waits for that batch (reads do
 * not), so a commit carries the writes of several periods and the pages they share (the tail of
 * likes, the head of the feed index, the recent part of likes_post_id_idx) go to the log once
 * instead of once per period. 10 ms, with checkpoints every 500 frames (db.c), is what PR #271's
 * version (30d259c) used when the box held it at 290,000 users. On the cloud VM at 350,000 users
 * 50 ms with checkpoints every 2,000 frames used 9 % less CPU, and disk writes fell from about
 * 2,900 to 2,100 a second; fe89683 and 307205a, which used them, held 280,000 on the box, where the
 * likes and new posts were the slow part at the edge. A write waits up to 10 ms for its batch.
 * FEED_WRITE_WINDOW_US overrides it. */
static long write_window_us = 10000;
static u64_t last_write_batch;

static void stats_tick(void) {
  static u64_t last;
  static int every = -1;
  if (every < 0) { const char *e = getenv("FEED_STATS"); every = e ? atoi(e) : 0; }
  if (!every) return;
  u64_t now = now_unix();
  if (now - last < (u64_t)every) return;
  static long last_nvcsw;
  struct rusage ru;
  getrusage(RUSAGE_SELF, &ru);   /* voluntary context switches: the times the loop slept and was woken */
  if (last) {
    u64_t open = 0;
    for (int i = 0; i < nrings; i++) open += rings[i].nopen;
    fprintf(stderr, "stats: open %llu batches %llu chunks/batch %.1f max %llu iters %llu enters %llu sleeps %llu wal %d pauses %llu"
            " (timeouts %llu) spill %u | iter max %.1f ms, batch %.0f ms, reap %.0f ms, nobufs %llu rearms %llu overflow %llu pinned %llu"
            " | idle closed %llu kept %llu | rings %d syscalls/iter %.1f io_uring_enter %llu wakeups %ld spins %llu\n", (unsigned long long)open,
            (unsigned long long)st_batches, st_batches ? (double)st_reqchunks / (double)st_batches : 0, (unsigned long long)st_max_chunks,
            (unsigned long long)st_iters, (unsigned long long)st_enters, (unsigned long long)st_sleeps, wal_frames,
            (unsigned long long)st_pauses, (unsigned long long)st_pause_timeouts, nspilled, (double)st_iter_max_ns / 1e6, (double)st_batch_ns / 1e6, (double)st_reap_ns / 1e6,
            (unsigned long long)st_nobufs, (unsigned long long)st_rearms, (unsigned long long)st_overflow, (unsigned long long)st_pinned,
            (unsigned long long)st_idle_closed, (unsigned long long)st_idle_kept, nrings,
            st_iters ? (double)st_sys / (double)st_iters : 0.0, (unsigned long long)st_uring, ru.ru_nvcsw - last_nvcsw, (unsigned long long)st_spins);
  }
  last = now;
  st_batches = st_reqchunks = st_iters = st_enters = st_sleeps = 0;
  st_nobufs = st_rearms = st_max_chunks = st_iter_max_ns = st_batch_ns = st_reap_ns = st_overflow = st_pinned = 0;
  st_idle_closed = st_idle_kept = st_sys = st_uring = 0;
  last_nvcsw = ru.ru_nvcsw;
}

/* At the memory wall of a 2 GB machine without swap, reclaim takes file-backed pages, the
 * program's own code among them, and the loop then stalls reading its code back from disk.
 * So as much of the code as RLIMIT_MEMLOCK allows (8 MB under systemd) is locked, from its
 * start, where the profile-guided build puts the handler, SQLite and the transport (the Lean
 * runtime follows). MLOCK_ONFAULT locks a page when it first runs, so code that never runs
 * takes no memory. Called after the rings are made: newer kernels charge them to the limit. */
#ifndef MLOCK_ONFAULT
#define MLOCK_ONFAULT 0x01
#endif
static void lock_code(void) {
  struct rlimit rl;
  if (getenv("FEED_NO_LOCK") || getrlimit(RLIMIT_MEMLOCK, &rl)) return;   /* FEED_NO_LOCK: for measurements */
  char exe[512], line[1024];
  ssize_t n = readlink("/proc/self/exe", exe, sizeof exe - 1);
  if (n <= 0) return;
  exe[n] = 0;
  FILE *f = fopen("/proc/self/maps", "r");
  if (!f) return;
  unsigned long a = 0, b = 0;
  while (fgets(line, sizeof line, f)) {
    unsigned long s, e;
    char perm[8];
    if (sscanf(line, "%lx-%lx %7s", &s, &e, perm) == 3 && perm[2] == 'x' && strstr(line, exe)) { a = s; b = e; break; }
  }
  fclose(f);
  if (!a) return;
  unsigned long len = b - a;
  if (rl.rlim_cur != RLIM_INFINITY && len > rl.rlim_cur) len = rl.rlim_cur;
  for (; len >= (1ul << 20); len /= 2)
    if (syscall(SYS_mlock2, (void *)a, len & ~4095ul, MLOCK_ONFAULT) == 0) {
      fprintf(stderr, "transport: the first %lu KB of the code (of %lu KB) are locked as they run\n", len >> 10, (b - a) >> 10);
      return;
    }
  fprintf(stderr, "transport: code not locked (%s)\n", strerror(errno));
}

LEAN_EXPORT lean_obj_res feed_transport_run(b_lean_obj_arg secret) {

  lean_inc(secret);
  g_secret = feed_make_key(secret);   /* the HMAC key schedule (Feed.makeKey) */
  const char *host = getenv("HOST"), *ps = getenv("PORT");
  if (!host || !*host) host = "127.0.0.1";   /* the deployment sets HOST (0.0.0.0 on the box) */
  int port = ps && *ps ? atoi(ps) : 3000;
  start_s = now_unix();
  struct rlimit rl;
  getrlimit(RLIMIT_NOFILE, &rl);
  rl.rlim_cur = rl.rlim_max;
  setrlimit(RLIMIT_NOFILE, &rl);
  getrlimit(RLIMIT_NOFILE, &rl);
  /* A registered table may not exceed RLIMIT_NOFILE; leave room for ordinary descriptors. */
  u64_t per = rl.rlim_cur > 65536 ? 65536 : rl.rlim_cur;
  if (per > 1024) per -= 64;
  if (per > 65535) per = 65535;
  if (getenv("FEED_PERIOD_US")) period_us = atol(getenv("FEED_PERIOD_US"));
  if (getenv("FEED_SPIN_US")) spin_us = atol(getenv("FEED_SPIN_US"));
  if (getenv("FEED_NBUF")) { u32_t n = (u32_t)atol(getenv("FEED_NBUF")); if (n >= 64 && n <= 32768 && !(n & (n - 1))) NBUF = n; }
  if (getenv("FEED_BUFSZ")) { u32_t n = (u32_t)atol(getenv("FEED_BUFSZ")); if (n >= 512 && n <= 65536) BUFSZ = n; }
  if (getenv("FEED_WAIT_MIN")) { u32_t n = (u32_t)atol(getenv("FEED_WAIT_MIN")); if (n >= 1 && n <= 4096) WAIT_MIN = n; }
  if (getenv("FEED_WRITE_WINDOW_US")) write_window_us = atol(getenv("FEED_WRITE_WINDOW_US"));
  if (getenv("FEED_BATCH_TARGET_US")) BATCH_TARGET_NS = (u64_t)atoll(getenv("FEED_BATCH_TARGET_US")) * 1000ull;
  if (getenv("FEED_MAX_BATCH")) max_batch = (u32_t)atol(getenv("FEED_MAX_BATCH"));
  if (max_batch < 1 || max_batch > MAX_CHUNKS) max_batch = MAX_CHUNKS;
  const char *want_s = getenv("FEED_MAX_CONNS");
  u64_t want = want_s ? (u64_t)atoll(want_s) : 500000;
  nrings_max = (int)((want + per - 1) / per);
  if (nrings_max < 1) nrings_max = 1;
  if (nrings_max > MAX_RINGS) nrings_max = MAX_RINGS;
  ring_slots = (u32_t)per;
  idle_setup();
  rings_upfront = getenv("FEED_RINGS_UPFRONT") || idle_on;
  rings_plain = !rings_upfront && getenv("FEED_RINGS_PLAIN");
  loop_sleep = rings_upfront || (!rings_plain && getenv("FEED_RINGS_SLEEP"));
  evfd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
  epfd = epoll_create1(EPOLL_CLOEXEC);
  struct epoll_event ev = {.events = EPOLLIN, .data.u32 = 0};
  epoll_ctl(epfd, EPOLL_CTL_ADD, evfd, &ev);
  nlisten = rings_upfront ? nrings_max : NLISTEN;
  for (int l = 0; l < nlisten; l++) lfds[l] = listen_socket(host, port);
  chunk_arr = lean_alloc_array(0, 256);
  struct sigaction sa;
  memset(&sa, 0, sizeof sa);
  sa.sa_handler = on_stop;
  sigaction(SIGTERM, &sa, 0);
  sigaction(SIGINT, &sa, 0);
  signal(SIGPIPE, SIG_IGN);
  nrings = 0;
  for (int i = 0; i < (rings_upfront ? nrings_max : 1); i++)
    if (ring_init(&rings[i], i, (u32_t)per, 1) == 0) nrings = i + 1;
    else break;
  if (rings_upfront && nrings < nrings_max) {
    /* rings that could not be made: their listeners go to the rings there are */
    nrings_max = nrings;
  }
  accept_policy();
  size_t slots = (size_t)nrings_max * per;
  held = malloc(slots * sizeof(u32_t));
  rearm = malloc(slots * sizeof(u32_t));
  spilled = malloc(slots * sizeof(u32_t));
  snap = malloc(slots * sizeof(u32_t));
  if (!held || !rearm || !spilled || !snap) abort();
  fprintf(stderr, "transport: %d of up to %d rings x %llu direct descriptors on %s:%d (%s)\n", nrings, nrings_max,
          (unsigned long long)per, host, port, rings_upfront ? "every ring at startup, all deferring" :
          rings_plain ? "rings as they fill, ring 0 deferring" : "rings as they fill, all deferring, waiting on ring 0");
  lock_code();
  u64_t loop_t0 = mono_ns(), last_start = loop_t0;
  int was_busy = 0;
  for (;;) {
    if (stop_requested) { transport_shutdown(); exit(0); }
    if (!loop_sleep) {
      /* One entry per ring per iteration, in the order of #264: each other ring submits what the
       * last batch queued and runs its task work (posting its completions), then ring 0 submits
       * and, after a busy iteration, waits for WAIT_MIN completions or the rest of the period.
       * Input that reaches another ring during that wait is read in the next iteration. */
      for (int i = 1; i < nrings; i++) {
        ring *r = &rings[i];
        u32_t kf = __atomic_load_n(r->sq_kflags, __ATOMIC_ACQUIRE);
        if (!(r->to_submit || r->hot || r->nrq || (kf & (IORING_SQ_TASKRUN | IORING_SQ_CQ_OVERFLOW)))) continue;
        int rc;
        do rc = sys_enter(r, r->to_submit, 0, IORING_ENTER_GETEVENTS);
        while (rc < 0 && errno == EINTR);
        if (rc < 0 && errno != EAGAIN && errno != EBUSY) { perror("io_uring_enter"); exit(1); }
        st_enters++;
        if (rc > 0) r->to_submit -= (u32_t)rc;
        r->hot = 0;
      }
      ring *r0 = &rings[0];
      u64_t since = mono_ns() - last_start, period = (u64_t)period_us * 1000;
      u32_t kf0 = __atomic_load_n(r0->sq_kflags, __ATOMIC_ACQUIRE);
      int rc = 0;
      if (was_busy && !nspilled && since < period && spin_us && !__atomic_load_n(&ckpt_wanted, __ATOMIC_ACQUIRE)) {
        /* submit, then spin until WAIT_MIN completions or the period's end; sleep for the rest once
         * spin_us is spent or the checkpoint thread wants the CPU */
        do rc = sys_enter(r0, r0->to_submit, 0, IORING_ENTER_GETEVENTS);
        while (rc < 0 && errno == EINTR);
        if (rc < 0 && errno != EAGAIN && errno != EBUSY) { perror("io_uring_enter"); exit(1); }
        st_enters++;
        if (rc > 0) r0->to_submit -= (u32_t)rc;
        rc = 0;
        st_spins++;
        u64_t t = mono_ns(), end = last_start + period, cap = t + (u64_t)spin_us * 1000;
        while (t < end && cq_ready(r0) < WAIT_MIN) {
          if (t >= cap || __atomic_load_n(&ckpt_wanted, __ATOMIC_ACQUIRE)) {
            int w;
            do w = sys_enter_wait(r0, 0, WAIT_MIN, end - t);
            while (w < 0 && errno == EINTR);
            if (w < 0 && errno != ETIME && errno != EAGAIN && errno != EBUSY) { perror("io_uring_enter"); exit(1); }
            st_sleeps++;
            break;
          }
          if (__atomic_load_n(r0->sq_kflags, __ATOMIC_ACQUIRE) & IORING_SQ_TASKRUN) {
            int w;
            do w = sys_enter(r0, 0, 0, IORING_ENTER_GETEVENTS);
            while (w < 0 && errno == EINTR);
            st_enters++;
          }
          t = mono_ns();   /* no PAUSE: a long run of PAUSEs makes a KVM host see a spinning vCPU and yield it */
        }
      } else if (was_busy && !nspilled && since < period) {
        do rc = sys_enter_wait(r0, r0->to_submit, WAIT_MIN, period - since);
        while (rc < 0 && errno == EINTR);
        if (rc < 0 && errno != ETIME && errno != EAGAIN && errno != EBUSY) { perror("io_uring_enter"); exit(1); }
        st_sleeps++;
      } else if (r0->to_submit || r0->hot || r0->nrq || (kf0 & (IORING_SQ_TASKRUN | IORING_SQ_CQ_OVERFLOW))) {
        do rc = sys_enter(r0, r0->to_submit, 0, IORING_ENTER_GETEVENTS);
        while (rc < 0 && errno == EINTR);
        if (rc < 0 && errno != EAGAIN && errno != EBUSY) { perror("io_uring_enter"); exit(1); }
        st_enters++;
      }
      if (rc > 0) r0->to_submit -= (u32_t)rc;
      r0->hot = 0;
    }
    u64_t iter_start = mono_ns();
    last_start = iter_start;
    loop_ms = (u32_t)((iter_start - loop_t0) / 1000000);
    int got = 0;
    st_iters++;
    for (int i = 0; i < nrings; i++) {
      ring *r = &rings[i];
      if (loop_sleep && ring_pending(r)) {   /* the previous loop: every ring with work is entered here */
        int rc;
        do rc = sys_enter(r, r->to_submit, 0, IORING_ENTER_GETEVENTS);
        while (rc < 0 && errno == EINTR);
        if (rc < 0 && errno != EAGAIN && errno != EBUSY) { perror("io_uring_enter"); exit(1); }
        st_enters++;
        if (rc > 0) r->to_submit -= (u32_t)rc;
        r->hot = 0;
      }
      if (__atomic_load_n(r->sq_kflags, __ATOMIC_RELAXED) & IORING_SQ_CQ_OVERFLOW) st_overflow++;
      u64_t t0 = mono_ns();
      got += reap(r);
      st_reap_ns += mono_ns() - t0;
    }
    /* reads for the connections reported readable, in rounds while their buffers come back */
    for (int round = 0; round < READ_ROUNDS; round++) {
      int issued = 0;
      for (int i = 0; i < nrings; i++) {
        ring *r = &rings[i];
        if (!r->nrq) continue;
        buf_publish(r);   /* the buffers given back so far, before the reads that take them */
        if (!issue_reads(r)) continue;
        issued = 1;
        int rc;
        do rc = sys_enter(r, r->to_submit, 0, IORING_ENTER_GETEVENTS);
        while (rc < 0 && errno == EINTR);
        if (rc < 0 && errno != EAGAIN && errno != EBUSY) { perror("io_uring_enter"); exit(1); }
        st_enters++;
        if (rc > 0) r->to_submit -= (u32_t)rc;
        got += reap(r);
      }
      if (!issued) break;
    }
    accept_policy();
    {
      u64_t t = mono_ns();
      writes_ok = (t - last_write_batch >= (u64_t)write_window_us * 1000) && db_writes_ok(t);
      if (writes_ok) last_write_batch = t;
    }
    present_held();
    present_spill();   /* after this iteration's input and the held writes: the backlog takes what room is left */
    u64_t tb = mono_ns();
    u32_t nb = nchunks;
    run_batch();
    u64_t bt = mono_ns() - tb;
    st_batch_ns += bt;
    if (BATCH_TARGET_NS && nb >= 32 && bt > 0) {
      /* the cap follows a running estimate of the time per connection, so that the first batch
       * after a burst (a stall elsewhere, a wave of new connections) is capped too */
      u64_t per = bt / nb;
      per_chunk_ns = per_chunk_ns ? (7 * per_chunk_ns + per) / 8 : per;
      u64_t c = per_chunk_ns ? BATCH_TARGET_NS / per_chunk_ns : max_batch;
      batch_cap = (u32_t)(c < 256 ? 256 : c > max_batch ? max_batch : c);
    }
    st_rearms += nrearm;
    for (u32_t i = 0; i < nrearm; i++) {
      ring *r = &rings[rearm[i] >> 16];
      u32_t slot = rearm[i] & 0xffff;
      conn *c = &r->conns[slot];
      if (c->state == C_OPEN && !(c->flags & (F_POLL | F_ARMING))) arm_poll(r, slot);
    }
    nrearm = 0;
    for (int i = 0; i < nrings; i++) buf_publish(&rings[i]);
    idle_check();   /* last: its closes go out with the next submit, before any completion */
    stats_tick();
    if (got || nheld || nspilled) {
      was_busy = 1;
      u64_t spent = mono_ns() - iter_start, period = (u64_t)period_us * 1000;
      if (spent > st_iter_max_ns) st_iter_max_ns = spent;
      if (!loop_sleep) continue;   /* the next iteration's entries submit this batch's sends at once */
      if (spent < period && !nspilled) {
        for (int i = 0; i < nrings; i++) if (rings[i].to_submit) ring_flush(&rings[i]);
        struct timespec q = {0, (long)(period - spent)};
        st_sys++;
        nanosleep(&q, 0);
        st_sleeps++;
      }
      continue;
    }
    was_busy = 0;
    /* idle: submit what is queued, then sleep until some ring has work */
    for (int i = 0; i < nrings; i++) if (rings[i].to_submit) ring_flush(&rings[i]);
    int any = 0;
    for (int i = 0; i < nrings; i++) if (ring_pending(&rings[i])) any = 1;
    if (any) continue;
    if (spin_us && !__atomic_load_n(&ckpt_wanted, __ATOMIC_ACQUIRE)) {
      /* spin before the idle wait: new work in any ring ends it */
      st_spins++;
      u64_t t = mono_ns(), cap = t + (u64_t)spin_us * 1000;
      while (t < cap && !__atomic_load_n(&ckpt_wanted, __ATOMIC_ACQUIRE)) {
        for (int i = 0; i < nrings && !any; i++) if (ring_pending(&rings[i])) any = 1;
        if (any) break;
        t = mono_ns();
      }
      if (any) continue;
    }
    struct epoll_event evs[4];
    int n;
    do n = epoll_wait(epfd, evs, 4, idle_due || idle_timeout_ms ? 100 : 1000);
    while (n < 0 && errno == EINTR && !stop_requested);   /* SIGTERM: stop now, not at the timeout */
    u64_t v;
    st_sys += 2;
    if (read(evfd, &v, sizeof v) < 0) {}
    for (int i = 0; i < nrings; i++) if (rings[i].defer) rings[i].hot = 1;   /* the others posted on their own */
  }
  return lean_io_result_mk_ok(lean_box(0));
}
