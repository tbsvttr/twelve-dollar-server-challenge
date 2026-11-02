/* Linux io_uring transport. Included after the shared HTTP/framing helpers.
 * No application, authentication, SQL or JSON-selection logic lives here. */
#include <linux/io_uring.h>
#include <sys/mman.h>
#include <sys/syscall.h>

enum { U_SQ = 4096, U_CQ = 16384, U_NBUFS = 4096, U_BUFSIZE = 2048,
       U_POOL = 256, U_POOL_LIMIT = 16384, U_GROUP = 7,
       U_ACCEPT = 1, U_RECV = 2, U_SEND = 3, U_TIMER = 4, U_IGNORE = 5 };

typedef struct {
    int fd;
    void *sq_map, *cq_map;
    size_t sq_size, cq_size, sqes_size;
    struct io_uring_sqe *sqes;
    uint32_t *sq_head, *sq_tail, *sq_mask, *sq_entries, *sq_flags, *sq_array;
    uint32_t *cq_head, *cq_tail, *cq_mask, *cq_overflow;
    struct io_uring_cqe *cqes;
    uint32_t tail;
} URing;

typedef struct UConn UConn;
struct UConn {
    Conn base; /* Shared HTTP parser and stable response representation. */
    uint32_t slot, generation;
    uint16_t borrowed_bid;
    unsigned borrowed : 1, receiving : 1, sending : 1;
    unsigned closing : 1, cancel_pending : 1;
};

typedef struct {
    Server base; /* Shared ready queue and batch ABI; this must stay first. */
    URing ring;
    struct io_uring_buf_ring *buffers;
    uint8_t *buffer_memory;
    uint8_t held[U_NBUFS];
    uint16_t buffer_tail;
    UConn *slots[MAX_CONNECTIONS];
    uint32_t generations[MAX_CONNECTIONS], free_slots[MAX_CONNECTIONS];
    uint32_t free_count;
    struct { uint8_t *data; size_t cap; } pool[U_POOL];
    uint32_t pool_count, last_completions;
    struct { int64_t seconds, nanos; } timer_value;
    uint64_t now, sweep, accept_retry_at;
    int fatal;
    unsigned accepting : 1, timer_active : 1, stopping : 1, needs_rearm : 1;
} UServer;

static uint32_t u_load(uint32_t *p) { return __atomic_load_n(p, __ATOMIC_ACQUIRE); }
static void u_store(uint32_t *p, uint32_t n) { __atomic_store_n(p, n, __ATOMIC_RELEASE); }
static uint64_t u_tag(unsigned op, uint32_t slot, uint32_t generation) {
    return (uint64_t)op | ((uint64_t)slot << 8) | ((uint64_t)generation << 32);
}

static void u_ring_destroy(URing *r) {
    if (r->fd >= 0) close(r->fd);
    if (r->sqes && r->sqes != MAP_FAILED) munmap(r->sqes, r->sqes_size);
    if (r->cq_map && r->cq_map != MAP_FAILED && r->cq_map != r->sq_map)
        munmap(r->cq_map, r->cq_size);
    if (r->sq_map && r->sq_map != MAP_FAILED) munmap(r->sq_map, r->sq_size);
    r->fd = -1;
}

static int u_ring_init(URing *r) {
    memset(r, 0, sizeof(*r)); r->fd = -1;
    struct io_uring_params p;
    memset(&p, 0, sizeof(p));
    p.flags = IORING_SETUP_CQSIZE | IORING_SETUP_COOP_TASKRUN |
              IORING_SETUP_SINGLE_ISSUER | IORING_SETUP_DEFER_TASKRUN;
    p.cq_entries = U_CQ;
    r->fd = (int)syscall(SYS_io_uring_setup, U_SQ, &p);
    if (r->fd < 0) return -1;
    if (!(p.features & IORING_FEAT_NODROP) || !(p.features & IORING_FEAT_EXT_ARG)) {
        errno = ENOTSUP; u_ring_destroy(r); return -1;
    }
    r->sq_size = p.sq_off.array + p.sq_entries * sizeof(uint32_t);
    r->cq_size = p.cq_off.cqes + p.cq_entries * sizeof(struct io_uring_cqe);
    if (p.features & IORING_FEAT_SINGLE_MMAP) {
        if (r->sq_size < r->cq_size) r->sq_size = r->cq_size;
        r->cq_size = r->sq_size;
    }
    r->sq_map = mmap(NULL, r->sq_size, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE,
                     r->fd, IORING_OFF_SQ_RING);
    if (r->sq_map == MAP_FAILED) { u_ring_destroy(r); return -1; }
    if (p.features & IORING_FEAT_SINGLE_MMAP) r->cq_map = r->sq_map;
    else r->cq_map = mmap(NULL, r->cq_size, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE,
                          r->fd, IORING_OFF_CQ_RING);
    if (r->cq_map == MAP_FAILED) { u_ring_destroy(r); return -1; }
    r->sqes_size = p.sq_entries * sizeof(struct io_uring_sqe);
    r->sqes = mmap(NULL, r->sqes_size, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE,
                   r->fd, IORING_OFF_SQES);
    if (r->sqes == MAP_FAILED) { u_ring_destroy(r); return -1; }
    uint8_t *sq = r->sq_map, *cq = r->cq_map;
    r->sq_head = (uint32_t *)(sq + p.sq_off.head);
    r->sq_tail = (uint32_t *)(sq + p.sq_off.tail);
    r->sq_mask = (uint32_t *)(sq + p.sq_off.ring_mask);
    r->sq_entries = (uint32_t *)(sq + p.sq_off.ring_entries);
    r->sq_flags = (uint32_t *)(sq + p.sq_off.flags);
    r->sq_array = (uint32_t *)(sq + p.sq_off.array);
    r->cq_head = (uint32_t *)(cq + p.cq_off.head);
    r->cq_tail = (uint32_t *)(cq + p.cq_off.tail);
    r->cq_mask = (uint32_t *)(cq + p.cq_off.ring_mask);
    r->cq_overflow = (uint32_t *)(cq + p.cq_off.overflow);
    r->cqes = (struct io_uring_cqe *)(cq + p.cq_off.cqes);
    r->tail = u_load(r->sq_tail);
    return 0;
}

static int u_enter(UServer *s, unsigned wait, int short_wait) {
    URing *r = &s->ring;
    if (s->buffers)
        __atomic_store_n(&s->buffers->tail, s->buffer_tail, __ATOMIC_RELEASE);
    u_store(r->sq_tail, r->tail);
    unsigned submit = r->tail - u_load(r->sq_head);
    struct { int64_t seconds, nanos; } timeout = {0, 250000};
    struct io_uring_getevents_arg args;
    memset(&args, 0, sizeof(args));
    unsigned flags = IORING_ENTER_GETEVENTS;
    if (short_wait) { args.ts = (uint64_t)(uintptr_t)&timeout; flags |= IORING_ENTER_EXT_ARG; }
    int n = (int)syscall(SYS_io_uring_enter, r->fd, submit, wait, flags,
                        short_wait ? &args : NULL, short_wait ? sizeof(args) : 0);
    if (n < 0 && errno != EINTR && errno != ETIME && errno != EAGAIN && errno != EBUSY) {
        s->fatal = errno; return -1;
    }
    return 0;
}

static int u_queue(UServer *s, const struct io_uring_sqe *sqe) {
    URing *r = &s->ring;
    if (r->tail - u_load(r->sq_head) >= *r->sq_entries) {
        if (u_enter(s, 0, 0) < 0 || r->tail - u_load(r->sq_head) >= *r->sq_entries) {
            s->fatal = EBUSY; return -1;
        }
    }
    unsigned index = r->tail & *r->sq_mask;
    r->sqes[index] = *sqe;
    r->sq_array[index] = index;
    ++r->tail;
    return 0;
}

static void u_recycle(UServer *s, uint16_t bid) {
    if (bid >= U_NBUFS || !s->held[bid]) { s->fatal = EIO; return; }
    s->held[bid] = 0;
    struct io_uring_buf *b = &s->buffers->bufs[s->buffer_tail & (U_NBUFS-1)];
    b->addr = (uint64_t)(uintptr_t)(s->buffer_memory + (size_t)bid * U_BUFSIZE);
    b->len = U_BUFSIZE; b->bid = bid;
    ++s->buffer_tail;
}

static void u_rx_clear(UServer *s, UConn *c, int release_owned) {
    if (c->borrowed) {
        u_recycle(s, c->borrowed_bid);
        c->borrowed = 0;
        c->base.rx = NULL; c->base.rx_cap = 0;
    } else if (release_owned) {
        free(c->base.rx); c->base.rx = NULL; c->base.rx_cap = 0;
    }
    c->base.rx_len = 0;
}

static void u_take_tx(UServer *s, UConn *c) {
    if (!c->base.tx && s->pool_count) {
        --s->pool_count;
        c->base.tx = s->pool[s->pool_count].data;
        c->base.tx_cap = s->pool[s->pool_count].cap;
    }
}

static void u_return_tx(UServer *s, UConn *c) {
    Conn *b = &c->base;
    if (b->tx && b->tx_cap <= U_POOL_LIMIT && s->pool_count < U_POOL) {
        s->pool[s->pool_count].data = b->tx;
        s->pool[s->pool_count++].cap = b->tx_cap;
    } else free(b->tx);
    b->tx = NULL; b->tx_cap = b->tx_len = b->tx_sent = 0;
}

static void u_free(UServer *s, UConn *c) {
    Conn *b = &c->base;
    ready_remove(&s->base, b);
    close(b->fd);
    if (b->all_prev) b->all_prev->all_next = b->all_next;
    else s->base.all = b->all_next;
    if (b->all_next) b->all_next->all_prev = b->all_prev;
    --s->base.count;
    s->slots[c->slot] = NULL;
    s->free_slots[s->free_count++] = c->slot;
    u_rx_clear(s, c, 1); u_return_tx(s, c);
    free(c);
}

static void u_close_client(UServer *s, UConn *c) {
    if (!c->closing) {
        c->closing = 1;
        ready_remove(&s->base, &c->base);
        u_rx_clear(s, c, 1);
        /* Shutdown completes pending recv/send operations; their allocations
         * and connection generation remain alive through their final CQEs. */
        if (c->receiving || c->sending) shutdown(c->base.fd, SHUT_RDWR);
    }
    if (!c->receiving && !c->sending) u_free(s, c);
}

static int u_recv(UServer *s, UConn *c) {
    if (c->receiving || c->closing || c->base.peer_eof || c->base.read_paused) return 0;
    struct io_uring_sqe e;
    memset(&e, 0, sizeof(e));
    e.opcode = IORING_OP_RECV; e.fd = c->base.fd;
    e.flags = IOSQE_BUFFER_SELECT; e.buf_group = U_GROUP;
    e.ioprio = IORING_RECV_MULTISHOT;
    e.user_data = u_tag(U_RECV, c->slot, c->generation);
    if (u_queue(s, &e) < 0) return -1;
    c->receiving = 1;
    return 0;
}

static int u_send(UServer *s, UConn *c) {
    if (c->sending || c->closing || c->base.tx_sent >= c->base.tx_len) return 0;
    struct io_uring_sqe e;
    memset(&e, 0, sizeof(e));
    e.opcode = IORING_OP_SEND; e.fd = c->base.fd;
    e.addr = (uint64_t)(uintptr_t)(c->base.tx + c->base.tx_sent);
    e.len = (uint32_t)(c->base.tx_len - c->base.tx_sent);
    e.msg_flags = MSG_NOSIGNAL;
    e.user_data = u_tag(U_SEND, c->slot, c->generation);
    if (u_queue(s, &e) < 0) return -1;
    c->sending = 1;
    return 0;
}

static void u_pause(UServer *s, UConn *c) {
    c->base.read_paused = 1;
    if (!c->receiving || c->cancel_pending) return;
    struct io_uring_sqe e;
    memset(&e, 0, sizeof(e));
    e.opcode = IORING_OP_ASYNC_CANCEL; e.fd = -1;
    e.addr = u_tag(U_RECV, c->slot, c->generation);
    e.user_data = U_IGNORE; e.flags = IOSQE_CQE_SKIP_SUCCESS;
    if (u_queue(s, &e) == 0) c->cancel_pending = 1;
}

static int u_accept(UServer *s) {
    if (s->accepting || s->stopping || s->now < s->accept_retry_at) return 0;
    struct io_uring_sqe e;
    memset(&e, 0, sizeof(e));
    e.opcode = IORING_OP_ACCEPT; e.fd = s->base.listener;
    e.ioprio = IORING_ACCEPT_MULTISHOT;
    e.accept_flags = SOCK_NONBLOCK | SOCK_CLOEXEC;
    e.user_data = U_ACCEPT;
    if (u_queue(s, &e) < 0) return -1;
    s->accepting = 1;
    return 0;
}

static int u_timer(UServer *s) {
    if (s->timer_active || s->stopping) return 0;
    struct io_uring_sqe e;
    memset(&e, 0, sizeof(e));
    s->timer_value.seconds = 1; s->timer_value.nanos = 0;
    e.opcode = IORING_OP_TIMEOUT; e.fd = -1; e.len = 1;
    e.addr = (uint64_t)(uintptr_t)&s->timer_value;
    e.user_data = U_TIMER;
    if (u_queue(s, &e) < 0) return -1;
    s->timer_active = 1;
    return 0;
}

static int u_append_rx(UServer *s, UConn *c, uint16_t bid, size_t count) {
    Conn *b = &c->base;
    uint8_t *data = s->buffer_memory + (size_t)bid * U_BUFSIZE;
    if (!b->rx_len && !b->rx_cap) {
        b->rx = data; b->rx_len = count; b->rx_cap = U_BUFSIZE;
        c->borrowed = 1; c->borrowed_bid = bid;
        return 0;
    }
    if (count > MAX_REQUEST - b->rx_len) { u_recycle(s, bid); return -1; }
    size_t needed = b->rx_len + count;
    if (c->borrowed || needed > b->rx_cap) {
        size_t cap = c->borrowed ? 4096 : b->rx_cap;
        while (cap < needed) cap *= 2;
        if (cap > MAX_REQUEST) cap = MAX_REQUEST;
        uint8_t *next = c->borrowed ? malloc(cap) : realloc(b->rx, cap);
        if (!next) { u_recycle(s, bid); return -1; }
        if (c->borrowed) {
            memcpy(next, b->rx, b->rx_len);
            u_recycle(s, c->borrowed_bid);
            c->borrowed = 0;
        }
        b->rx = next; b->rx_cap = cap;
    }
    memcpy(b->rx + b->rx_len, data, count);
    b->rx_len += count;
    u_recycle(s, bid);
    return 0;
}

static void u_on_accept(UServer *s, int result, uint32_t flags) {
    if (!(flags & IORING_CQE_F_MORE)) s->accepting = 0;
    if (result < 0) {
        switch (-result) {
        case ECANCELED: case ECONNABORTED: case EINTR: case EAGAIN:
        case ENETDOWN: case EPROTO: case ENOPROTOOPT: case EHOSTDOWN:
        case ENONET: case EHOSTUNREACH: case EOPNOTSUPP: case ENETUNREACH:
            break;
        case EMFILE: case ENFILE: case ENOBUFS: case ENOMEM:
            s->accept_retry_at = s->now + 1;
            break;
        default: s->fatal = -result; break;
        }
        return;
    }
    if (s->stopping || !s->free_count) { close(result); return; }
    UConn *c = calloc(1, sizeof(*c));
    if (!c) { close(result); return; }
    c->slot = s->free_slots[--s->free_count];
    c->generation = ++s->generations[c->slot];
    c->base.fd = result; c->base.activity = s->now;
    c->base.all_next = s->base.all;
    if (s->base.all) s->base.all->all_prev = &c->base;
    s->base.all = &c->base; ++s->base.count;
    s->slots[c->slot] = c;
    int one = 1;
    setsockopt(result, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    setsockopt(result, SOL_SOCKET, SO_KEEPALIVE, &one, sizeof(one));
    if (u_recv(s, c) < 0) u_close_client(s, c);
}

static void u_on_recv(UServer *s, UConn *c, int result, uint32_t flags, int has_buffer, uint16_t bid) {
    if (!(flags & IORING_CQE_F_MORE)) { c->receiving = 0; c->cancel_pending = 0; s->needs_rearm = 1; }
    if (c->closing) {
        if (has_buffer) u_recycle(s, bid);
        if (!c->receiving && !c->sending) u_free(s, c);
        return;
    }
    if (result <= 0) {
        if (has_buffer) u_recycle(s, bid);
        if (result == -ENOBUFS || result == -EAGAIN || result == -ECANCELED) return;
        if (result < 0) { u_close_client(s, c); return; }
        c->base.peer_eof = 1;
        if (!c->base.rx_len && !c->base.tx_len) u_close_client(s, c);
        else ready_add(&s->base, &c->base);
        return;
    }
    if (!has_buffer || (unsigned)result > U_BUFSIZE) { s->fatal = EIO; return; }
    c->base.activity = s->now;
    /* A parsed close header can precede an incomplete fixed/chunked body. */
    if (c->base.close_after && (c->base.active || c->base.tx_len)) {
        u_recycle(s, bid); return;
    }
    if (u_append_rx(s, c, bid, (size_t)result) < 0) { u_close_client(s, c); return; }
    ready_add(&s->base, &c->base);
    if (c->base.tx_len && c->base.rx_len >= 65536) u_pause(s, c);
}

static void u_on_send(UServer *s, UConn *c, int result) {
    c->sending = 0;
    if (c->closing) {
        if (!c->receiving) u_free(s, c);
        return;
    }
    if (result <= 0) { u_close_client(s, c); return; }
    c->base.activity = s->now;
    c->base.tx_sent += (size_t)result;
    if (c->base.tx_sent < c->base.tx_len) { u_send(s, c); return; }
    u_return_tx(s, c);
    if (c->base.close_after || (c->base.peer_eof && !c->base.rx_len)) {
        u_close_client(s, c); return;
    }
    c->base.read_paused = 0;
    ready_add(&s->base, &c->base);
    u_recv(s, c);
}

static unsigned u_drain(UServer *s) {
    URing *r = &s->ring;
    unsigned count = 0, head = u_load(r->cq_head), tail = u_load(r->cq_tail);
    while (head != tail && count < U_CQ) {
        struct io_uring_cqe cq = r->cqes[head & *r->cq_mask];
        ++head; ++count;
        /* Batch the ownership publication while leaving space for any enter
         * needed by an unusually large accept/rearm batch. */
        if (!(count & 31)) u_store(r->cq_head, head);
        unsigned op = (unsigned)(cq.user_data & 255);
        uint32_t slot = (uint32_t)(cq.user_data >> 8) & 0xffffff;
        uint32_t generation = (uint32_t)(cq.user_data >> 32);
        int has_buffer = !!(cq.flags & IORING_CQE_F_BUFFER);
        uint16_t bid = (uint16_t)(cq.flags >> IORING_CQE_BUFFER_SHIFT);
        if (has_buffer) {
            if (bid >= U_NBUFS || s->held[bid]) {
                s->fatal = EIO; u_store(r->cq_head, head); return count;
            }
            s->held[bid] = 1;
        }
        if (op == U_ACCEPT) u_on_accept(s, cq.res, cq.flags);
        else if (op == U_TIMER) { s->timer_active = 0; u_timer(s); }
        else if (op == U_RECV || op == U_SEND) {
            UConn *c = slot < MAX_CONNECTIONS ? s->slots[slot] : NULL;
            if (!c || c->generation != generation) {
                if (has_buffer) u_recycle(s, bid);
            } else if (op == U_RECV) u_on_recv(s, c, cq.res, cq.flags, has_buffer, bid);
            else u_on_send(s, c, cq.res);
        } else if (has_buffer) u_recycle(s, bid);
        if (head == tail) tail = u_load(r->cq_tail);
    }
    u_store(r->cq_head, head);
    return count;
}

static void u_rearm(UServer *s) {
    /* Multishot receives normally remain armed. Only starvation/cancellation
     * takes this slow path, bounded by the live connection count. */
    if (s->needs_rearm) {
        s->needs_rearm = 0;
        for (Conn *b = s->base.all; b; b = b->all_next) {
            UConn *c = (UConn *)b;
            if (!c->receiving && !c->closing && !b->peer_eof && !b->read_paused)
                u_recv(s, c);
        }
    }
    if (!s->accepting && !s->stopping) u_accept(s);
}

static void u_sweep(UServer *s) {
    if (s->now < s->sweep + 5) return;
    s->sweep = s->now;
    Conn *b = s->base.all;
    while (b) {
        Conn *next = b->all_next;
        if (!b->active && s->now >= b->activity + IDLE_SECONDS) u_close_client(s, (UConn *)b);
        b = next;
    }
}

static int64_t uring_net_init(bytes host, int64_t port) {
    /* Reuse the exact listener/address checks of the epoll backend. Its
     * temporary epoll descriptor is closed before the ring takes ownership. */
    Server *base = (Server *)(intptr_t)epoll_net_init(host, port);
    if (!base) return 0;
    close(base->epoll_fd); base->epoll_fd = -1;
    UServer *s = calloc(1, sizeof(*s));
    if (!s) { close(base->listener); free(base); return 0; }
    s->base = *base; free(base);
    s->ring.fd = -1;
    size_t descriptor_size = U_NBUFS * sizeof(struct io_uring_buf);
    if (u_ring_init(&s->ring) < 0) goto fail;
    s->buffers = mmap(NULL, descriptor_size, PROT_READ | PROT_WRITE,
                      MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    s->buffer_memory = mmap(NULL, U_NBUFS * U_BUFSIZE, PROT_READ | PROT_WRITE,
                            MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (s->buffers == MAP_FAILED || s->buffer_memory == MAP_FAILED) goto fail;
    struct io_uring_buf_reg reg;
    memset(&reg, 0, sizeof(reg));
    reg.ring_addr = (uint64_t)(uintptr_t)s->buffers;
    reg.ring_entries = U_NBUFS; reg.bgid = U_GROUP;
    if (syscall(SYS_io_uring_register, s->ring.fd, IORING_REGISTER_PBUF_RING, &reg, 1) < 0) goto fail;
    for (unsigned i = 0; i < U_NBUFS; ++i) { s->held[i] = 1; u_recycle(s, (uint16_t)i); }
    for (unsigned i = 0; i < MAX_CONNECTIONS; ++i) s->free_slots[s->free_count++] = i;
    s->now = s->sweep = now_seconds();
    if (u_accept(s) < 0 || u_timer(s) < 0 || u_enter(s, 0, 0) < 0) goto fail;
    fprintf(stderr, "Goose native transport: io_uring multishot, %d receive buffers\n", U_NBUFS);
    return (int64_t)(intptr_t)s;
fail: {
    int saved = errno;
    u_ring_destroy(&s->ring);
    if (s->buffers && s->buffers != MAP_FAILED) munmap(s->buffers, descriptor_size);
    if (s->buffer_memory && s->buffer_memory != MAP_FAILED) munmap(s->buffer_memory, U_NBUFS * U_BUFSIZE);
    close(s->base.listener); free(s); errno = saved; return 0;
    }
}

static int64_t uring_net_poll(int64_t handle) {
    UServer *s = (UServer *)(intptr_t)handle;
    if (!s || s->base.batch_count || s->fatal) return -1;
    for (;;) {
        unsigned pending_cq = u_load(s->ring.cq_tail) - u_load(s->ring.cq_head);
        unsigned wait = s->base.ready_head || pending_cq ? 0 : 1;
        int hot = s->last_completions >= 4;
        if (wait && hot) wait = (unsigned)s->base.count * 2 < 32 ? (unsigned)s->base.count * 2 : 32;
        if (u_enter(s, wait, wait && hot) < 0) return -1;
        s->now = now_seconds();
        s->last_completions = u_drain(s);
        if (s->fatal) { errno = s->fatal; return -1; }
        u_sweep(s);
        while (s->base.ready_head && s->base.batch_count < BATCH_SIZE) {
            UConn *c = (UConn *)s->base.ready_head;
            ready_remove(&s->base, &c->base);
            if (c->closing || c->base.tx_len) continue;
            int parsed = request_parse(&c->base);
            if (parsed > 0) {
                c->base.active = 1;
                s->base.batch[s->base.batch_count++] = &c->base;
            } else if (parsed < 0) {
                c->base.close_after = 1;
                u_rx_clear(s, c, 0); u_take_tx(s, c);
                if (response_error(&c->base, -parsed) < 0 || u_send(s, c) < 0) u_close_client(s, c);
            } else if (c->base.peer_eof) u_close_client(s, c);
        }
        u_rearm(s);
        if (s->fatal) { errno = s->fatal; return -1; }
        if (s->base.batch_count) return s->base.batch_count;
        if (!s->last_completions) return 0;
    }
}

static void uring_net_flush(int64_t handle, int32_t commit_ok) {
    UServer *s = (UServer *)(intptr_t)handle;
    if (!s) return;
    for (int i = 0; i < s->base.batch_count; ++i) {
        UConn *c = (UConn *)s->base.batch[i];
        Conn *b = &c->base;
        if (!commit_ok || !b->tx_len) {
            u_take_tx(s, c);
            if (response_error(b, 500) < 0) { b->active = 0; u_close_client(s, c); continue; }
        }
        if (b->consumed < b->rx_len) {
            memmove(b->rx, b->rx + b->consumed, b->rx_len - b->consumed);
            b->rx_len -= b->consumed;
        } else u_rx_clear(s, c, b->rx_cap > U_POOL_LIMIT);
        b->consumed = b->header_scan = 0; b->expect_sent = 0; b->active = 0;
        /* The stable TX allocation is not reused until its final SEND CQE. */
        if (u_send(s, c) < 0) u_close_client(s, c);
    }
    s->base.batch_count = 0;
}

static void uring_net_close(int64_t handle) {
    UServer *s = (UServer *)(intptr_t)handle;
    if (!s) return;
    s->stopping = 1;
    Conn *b = s->base.all;
    while (b) { Conn *next = b->all_next; u_close_client(s, (UConn *)b); b = next; }
    for (unsigned op = U_ACCEPT; op <= U_TIMER; op += U_TIMER-U_ACCEPT) {
        struct io_uring_sqe e;
        memset(&e, 0, sizeof(e));
        e.opcode = IORING_OP_ASYNC_CANCEL; e.fd = -1; e.addr = op;
        e.user_data = U_IGNORE;
        u_queue(s, &e);
    }
    while (!s->fatal && (s->base.count || s->accepting || s->timer_active)) {
        if (u_enter(s, 1, 1) < 0) break;
        s->now = now_seconds(); u_drain(s);
    }
    /* No referenced connection/buffer allocation is freed before completion. */
    u_ring_destroy(&s->ring);
    while (s->base.all) {
        UConn *c = (UConn *)s->base.all;
        c->receiving = c->sending = 0; u_free(s, c);
    }
    for (unsigned i = 0; i < s->pool_count; ++i) free(s->pool[i].data);
    munmap(s->buffers, U_NBUFS * sizeof(struct io_uring_buf));
    munmap(s->buffer_memory, U_NBUFS * U_BUFSIZE);
    close(s->base.listener); free(s);
}
