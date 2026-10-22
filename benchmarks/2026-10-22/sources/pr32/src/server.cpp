#include "server.hpp"

#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/utsname.h>
#include <unistd.h>

#include <cerrno>
#include <csignal>
#include <cstdio>
#include <cstring>
#include <new>

#include <EASTL/algorithm.h>

#include "response.hpp"
#include "writer.hpp"

namespace srv {

namespace {

volatile sig_atomic_t g_stop = 0;

enum Op : uint64_t { kAccept = 1, kRecv = 2, kSend = 3, kIgnore = 4, kAcceptDirect = 5, kCloseDirect = 6 };

constexpr uint32_t kIdleSeconds = 75;
constexpr size_t kBlockCount = 4096;
constexpr unsigned kSqEntries = 4096;
constexpr unsigned kCqEntries = 16384;
constexpr unsigned kBufCount = 4096;
constexpr unsigned kBufSize = 2048;
constexpr unsigned kBufGroup = 1;
constexpr unsigned kBatch = 256;
constexpr unsigned kAcceptDepth = 256;
constexpr size_t kMaxSlots = 65535;
constexpr unsigned kEvictScan = 8;
constexpr long kIdleManyRingsNanos = 2000000;
constexpr unsigned kBusyCompletions = 4;
constexpr unsigned kWaitCompletions = 128;
// The batch target is capped at 40% of open connections. With few connections in a
// closed loop (wrk -c64) 128 completions never arrive and every pass would sit out
// kWaitNanos (9k req/s instead of 59k); throughput fell off between 50% and 62%.
constexpr size_t kWaitOpenPercent = 40;
constexpr long kWaitNanos = 6000000;
constexpr size_t kHeadRoom = 512;
constexpr uintptr_t kTagMask = 0xfff;

struct SendContext {
    uint32_t fd;
    uint32_t gen;
};

constexpr uint64_t conn_tag(Op op, uint32_t gen, uint32_t fd) {
    return static_cast<uint64_t>(op) | (static_cast<uint64_t>(gen) << 8) | (static_cast<uint64_t>(fd) << 40);
}

bool kernel_at_least(int major, int minor) {
    utsname u{};
    if (uname(&u) != 0) return false;
    int a = 0, b = 0;
    if (sscanf(u.release, "%d.%d", &a, &b) != 2) return false;
    return a > major || (a == major && b >= minor);
}

}

Server::Server(App &app, Db &db, int listen_fd, size_t fd_limit)
    : app_(app),
      db_(db),
      listen_(listen_fd),
      fd_limit_(fd_limit),
      max_open_(fd_limit > 1024 ? fd_limit - kAcceptDepth - 64 : fd_limit / 2),
      slots_per_ring_(fd_limit < kMaxSlots ? fd_limit : kMaxSlots),
      table_size_(fd_limit + kMaxRings * slots_per_ring_),
      pool_(kBlockCount) {
    void *table = mmap(nullptr, table_size_ * sizeof(Conn), PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    conns_ = table == MAP_FAILED ? nullptr : static_cast<Conn *>(table);
    refresh_clock();
}

Server::~Server() {
    for (Ring &r : rings_) {
        if (r.ready) io_uring_queue_exit(&r.ring);
        if (r.buffers) munmap(r.buffers, static_cast<size_t>(kBufCount) * kBufSize);
    }
    if (conns_) munmap(conns_, table_size_ * sizeof(Conn));
}

bool Server::init_ring(Ring &r, bool first) {
    io_uring_params params{};
    params.flags = IORING_SETUP_SINGLE_ISSUER | IORING_SETUP_DEFER_TASKRUN | IORING_SETUP_CQSIZE;
    params.cq_entries = kCqEntries;
    int rc = io_uring_queue_init_params(kSqEntries, &r.ring, &params);
    if (rc < 0) {
        params = io_uring_params{};
        params.flags = IORING_SETUP_CQSIZE | IORING_SETUP_COOP_TASKRUN;
        params.cq_entries = kCqEntries;
        rc = io_uring_queue_init_params(kSqEntries, &r.ring, &params);
    }
    if (rc < 0) {
        if (first) error_ = "io_uring_queue_init failed (is io_uring blocked by seccomp or kernel.io_uring_disabled?)";
        return false;
    }
    r.ready = true;
    int err = 0;
    r.buf_ring = io_uring_setup_buf_ring(&r.ring, kBufCount, kBufGroup, 0, &err);
    if (!r.buf_ring) {
        if (first) error_ = "cannot create the provided buffer ring";
        return false;
    }
    void *mem = mmap(nullptr, static_cast<size_t>(kBufCount) * kBufSize, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (mem == MAP_FAILED) {
        if (first) error_ = "cannot allocate receive buffers";
        return false;
    }
    r.buffers = static_cast<char *>(mem);
    for (unsigned i = 0; i < kBufCount; ++i) {
        io_uring_buf_ring_add(r.buf_ring, r.buffers + static_cast<size_t>(i) * kBufSize, kBufSize, static_cast<unsigned short>(i), io_uring_buf_ring_mask(kBufCount), static_cast<int>(i));
    }
    io_uring_buf_ring_advance(r.buf_ring, kBufCount);
    return true;
}

bool Server::init() {
    if (!conns_) {
        error_ = "cannot allocate the connection table";
        return false;
    }
    if (!kernel_at_least(6, 0)) {
        error_ = "io_uring multishot receive needs Linux 6.0 or newer";
        return false;
    }
    if (!init_ring(rings_[0], true)) return false;

    io_uring_probe *probe = io_uring_get_probe_ring(&rings_[0].ring);
    bool supported = probe && io_uring_opcode_supported(probe, IORING_OP_ACCEPT) && io_uring_opcode_supported(probe, IORING_OP_RECV) &&
                     io_uring_opcode_supported(probe, IORING_OP_SEND) && io_uring_opcode_supported(probe, IORING_OP_ASYNC_CANCEL) &&
                     io_uring_opcode_supported(probe, IORING_OP_CLOSE);
    if (probe) io_uring_free_probe(probe);
    if (!supported) {
        error_ = "the kernel lacks a required io_uring operation";
        return false;
    }

    direct_ok_ = io_uring_register_files_sparse(&rings_[0].ring, static_cast<unsigned>(slots_per_ring_)) == 0;
    if (direct_ok_) {
        ring_count_ = 1;
        while (ring_count_ < kMaxRings && init_ring(rings_[ring_count_], false) &&
               io_uring_register_files_sparse(&rings_[ring_count_].ring, static_cast<unsigned>(slots_per_ring_)) == 0) {
            ++ring_count_;
        }
        for (unsigned i = ring_count_; i < kMaxRings; ++i) {
            if (rings_[i].ready) io_uring_queue_exit(&rings_[i].ring);
            if (rings_[i].buffers) munmap(rings_[i].buffers, static_cast<size_t>(kBufCount) * kBufSize);
            rings_[i] = Ring{};
        }
        size_t capacity = static_cast<size_t>(ring_count_) * slots_per_ring_;
        max_open_ = capacity > 4 * kAcceptDepth ? capacity - 2 * kAcceptDepth : capacity / 2;
    }
    return true;
}

void Server::refresh_clock() {
    timespec ts{};
    clock_gettime(CLOCK_MONOTONIC_COARSE, &ts);
    tick_ = static_cast<uint32_t>(ts.tv_sec);
    clock_gettime(CLOCK_REALTIME_COARSE, &ts);
    if (ts.tv_sec != wall_ || date_len_ == 0) {
        wall_ = ts.tv_sec;
        tm parts{};
        gmtime_r(&wall_, &parts);
        date_len_ = strftime(date_, sizeof date_, "Date: %a, %d %b %Y %H:%M:%S GMT\r\n", &parts);
    }
}

Conn *Server::open_conn(int fd) {
    uint32_t gen = conns_[fd].gen;
    Conn *c = new (&conns_[fd]) Conn();
    c->gen = gen + 1;
    c->open = true;
    c->last_active = tick_;
    lru_.push_front(*c);
    ++open_count_;
    return c;
}

void Server::release_conn(Conn &c, bool keep_out_block) {
    lru_.remove(c);
    if (c.in_block) pool_.give(c.in_block);
    if (c.out_block && !keep_out_block) pool_.give(c.out_block);
    c.in_block = nullptr;
    c.out_block = nullptr;
    c.in_len = 0;
    c.out_off = c.out_len = 0;
    c.open = false;
    c.writing = false;
    c.close_after_flush = false;
    c.served = false;
    --open_count_;
}

void Server::touch(Conn &c) {
    c.last_active = tick_;
    if (&lru_.front() == &c) return;
    lru_.remove(c);
    lru_.push_front(c);
}

void Server::evict_one() {
    if (lru_.empty()) return;
    auto it = lru_.begin();
    for (unsigned i = 0; i < kEvictScan && it != lru_.end(); ++i, ++it) {
        if (it->served && !it->writing && it->in_len == 0) {
            close_conn(*it);
            return;
        }
    }
    close_conn(lru_.back());
}

void Server::sweep_idle() {
    if (tick_ == last_sweep_) return;
    last_sweep_ = tick_;
    while (!lru_.empty() && tick_ - lru_.back().last_active > kIdleSeconds) close_conn(lru_.back());
}

void Server::aim(io_uring_sqe *sqe, size_t id) const {
    if (id < fd_limit_) {
        sqe->fd = static_cast<int>(id);
    } else {
        sqe->fd = static_cast<int>((id - fd_limit_) % slots_per_ring_);
        sqe->flags |= IOSQE_FIXED_FILE;
    }
}

io_uring_sqe *Server::next_sqe(Ring &r) {
    io_uring_sqe *sqe = io_uring_get_sqe(&r.ring);
    if (!sqe) {
        io_uring_submit(&r.ring);
        sqe = io_uring_get_sqe(&r.ring);
    }
    return sqe;
}

void Server::arm_accept() {
    if (!direct_ok_) {
        io_uring_sqe *sqe = next_sqe(rings_[0]);
        io_uring_prep_accept(sqe, listen_, nullptr, nullptr, SOCK_NONBLOCK | SOCK_CLOEXEC);
        io_uring_sqe_set_data64(sqe, conn_tag(kAccept, 0, 0));
        return;
    }
    unsigned index = 0;
    while (index < ring_count_ && rings_[index].reserved >= slots_per_ring_) ++index;
    if (index == ring_count_) {
        ++accept_deficit_;
        return;
    }
    Ring &r = rings_[index];
    ++r.reserved;
    io_uring_sqe *sqe = next_sqe(r);
    io_uring_prep_accept_direct(sqe, listen_, nullptr, nullptr, SOCK_NONBLOCK, IORING_FILE_INDEX_ALLOC);
    io_uring_sqe_set_data64(sqe, conn_tag(kAcceptDirect, 0, 0));
}

void Server::arm_recv(Conn &c) {
    io_uring_sqe *sqe = next_sqe(ring_for(id_of(c)));
    io_uring_prep_recv_multishot(sqe, 0, nullptr, 0, 0);
    aim(sqe, id_of(c));
    sqe->flags |= IOSQE_BUFFER_SELECT;
    sqe->buf_group = kBufGroup;
    io_uring_sqe_set_data64(sqe, conn_tag(kRecv, c.gen, static_cast<uint32_t>(id_of(c))));
}

void Server::recycle(Ring &r, uint16_t buffer_id) {
    io_uring_buf_ring_add(r.buf_ring, r.buffers + static_cast<size_t>(buffer_id) * kBufSize, kBufSize, buffer_id, io_uring_buf_ring_mask(kBufCount), static_cast<int>(r.recycled++));
}

void Server::submit_send(Conn &c) {
    io_uring_sqe *sqe = next_sqe(ring_for(id_of(c)));
    io_uring_prep_send(sqe, 0, c.out_block + c.out_off, c.out_len - c.out_off, MSG_NOSIGNAL);
    aim(sqe, id_of(c));
    io_uring_sqe_set_data64(sqe, reinterpret_cast<uintptr_t>(c.out_block) | kSend);
}

void Server::prepare_send(Conn &c, char *block, size_t body_size, int status, bool keep_alive) {
    char head[kMaxHeadBytes];
    size_t h = build_head(head, status, keep_alive, body_size, date());
    char *start = block + kHeadRoom - h;
    memcpy(start, head, h);
    *reinterpret_cast<SendContext *>(block) = SendContext{static_cast<uint32_t>(id_of(c)), c.gen};
    c.out_block = block;
    c.out_off = static_cast<uint32_t>(start - block);
    c.out_len = static_cast<uint32_t>(kHeadRoom + body_size);
    c.writing = true;
}

void Server::commit_group() {
    if (deferred_count_ == 0 && !db_.in_transaction()) return;
    bool committed = db_.commit();
    for (size_t i = 0; i < deferred_count_; ++i) {
        const Deferred &d = deferred_[i];
        Conn &c = conns_[d.fd];
        if (!c.open || c.gen != d.gen || c.out_block != d.block) {
            pool_.give(d.block);
            continue;
        }
        if (!committed) {
            Writer out(d.block + kHeadRoom, BlockPool::kBlockSize - kHeadRoom);
            out.put("{\"error\":\"internal server error\"}");
            prepare_send(c, d.block, out.size(), 500, d.keep_alive);
        }
        submit_send(c);
    }
    deferred_count_ = 0;
}

bool Server::respond(Conn &c, const Request &req) {
    if (deferred_count_ == kMaxDeferred) commit_group();
    char *block = pool_.take();
    if (!block) {
        close_conn(c);
        return false;
    }
    Writer out(block + kHeadRoom, BlockPool::kBlockSize - kHeadRoom);
    int code = app_.handle(req, out);
    if (out.overflowed()) {
        out.clear();
        out.put("{\"error\":\"internal server error\"}");
        code = 500;
    }
    prepare_send(c, block, out.size(), code, req.keep_alive);
    if (db_.in_transaction()) {
        deferred_[deferred_count_++] = Deferred{static_cast<uint32_t>(id_of(c)), c.gen, block, req.keep_alive};
    } else {
        submit_send(c);
    }
    return true;
}

bool Server::respond_bad_request(Conn &c) {
    char *block = pool_.take();
    if (!block) {
        close_conn(c);
        return false;
    }
    Writer out(block + kHeadRoom, BlockPool::kBlockSize - kHeadRoom);
    out.put("{\"error\":\"bad request\"}");
    prepare_send(c, block, out.size(), 400, false);
    submit_send(c);
    return true;
}

void Server::close_conn(Conn &c) {
    if (!c.open) return;
    size_t id = id_of(c);
    if (id >= fd_limit_) {
        Ring &r = ring_for(id);
        unsigned slot = static_cast<unsigned>((id - fd_limit_) % slots_per_ring_);
        char *pending_send = c.writing ? c.out_block : nullptr;
        uint64_t recv_tag = conn_tag(kRecv, c.gen, static_cast<uint32_t>(id));
        release_conn(c, c.writing);
        io_uring_sqe *sqe = next_sqe(r);
        io_uring_prep_cancel64(sqe, recv_tag, 0);
        io_uring_sqe_set_data64(sqe, conn_tag(kIgnore, 0, 0));
        if (pending_send) {
            sqe = next_sqe(r);
            io_uring_prep_cancel64(sqe, reinterpret_cast<uintptr_t>(pending_send) | kSend, 0);
            io_uring_sqe_set_data64(sqe, conn_tag(kIgnore, 0, 0));
        }
        sqe = next_sqe(r);
        io_uring_prep_close_direct(sqe, slot);
        io_uring_sqe_set_data64(sqe, conn_tag(kCloseDirect, 0, 0));
        return;
    }
    int fd = static_cast<int>(id);
    release_conn(c, c.writing);
    io_uring_submit(&rings_[0].ring);
    shutdown(fd, SHUT_RDWR);
    close(fd);
}

bool Server::process(Conn &c, char *buf, size_t have, bool shared) {
    size_t off = 0;
    while (off < have && !c.writing) {
        Request req;
        ParseStatus status = parse_request(buf + off, have - off, req);
        if (status == ParseStatus::Incomplete) break;
        if (status == ParseStatus::Bad) {
            if (respond_bad_request(c)) {
                if (c.writing) {
                    c.close_after_flush = true;
                } else {
                    close_conn(c);
                }
            }
            return false;
        }
        off += req.consumed;
        if (!respond(c, req)) return false;
        if (!req.keep_alive) {
            if (c.writing) {
                c.close_after_flush = true;
            } else {
                close_conn(c);
            }
            return false;
        }
    }
    size_t left = have - off;
    if (left == 0) {
        if (c.in_block) {
            pool_.give(c.in_block);
            c.in_block = nullptr;
        }
        c.in_len = 0;
        return true;
    }
    if (left > BlockPool::kBlockSize) {
        close_conn(c);
        return false;
    }
    if (shared) {
        char *block = pool_.take();
        if (!block) {
            close_conn(c);
            return false;
        }
        memcpy(block, buf + off, left);
        c.in_block = block;
    } else if (off > 0) {
        memmove(c.in_block, buf + off, left);
    }
    c.in_len = static_cast<uint32_t>(left);
    return true;
}

bool Server::append_input(Conn &c, const char *data, size_t n) {
    if (!c.in_block) {
        c.in_block = pool_.take();
        if (!c.in_block) return false;
        c.in_len = 0;
    }
    if (c.in_len + n > BlockPool::kBlockSize) return false;
    memcpy(c.in_block + c.in_len, data, n);
    c.in_len += static_cast<uint32_t>(n);
    return true;
}

void Server::on_accept(unsigned index, const io_uring_cqe *cqe) {
    int res = cqe->res;
    bool direct = (cqe->user_data & 0xff) == kAcceptDirect;
    if (res >= 0) {
        size_t id = direct ? fd_limit_ + index * slots_per_ring_ + static_cast<size_t>(res) : static_cast<size_t>(res);
        if (id >= table_size_ || (!direct && static_cast<size_t>(res) >= fd_limit_)) {
            if (direct) {
                io_uring_sqe *sqe = next_sqe(rings_[index]);
                io_uring_prep_close_direct(sqe, static_cast<unsigned>(res));
                io_uring_sqe_set_data64(sqe, conn_tag(kCloseDirect, 0, 0));
            } else {
                close(res);
            }
        } else {
            if (open_count_ >= max_open_) evict_one();
            Conn *c = open_conn(static_cast<int>(id));
            arm_recv(*c);
        }
    } else if (direct) {
        --rings_[index].reserved;
        ++accept_deficit_;
        return;
    } else if (res == -EMFILE || res == -ENFILE) {
        if (lru_.empty()) {
            ++accept_deficit_;
            return;
        }
        evict_one();
    } else if (res != -ECONNABORTED && res != -EINTR) {
        ++accept_deficit_;
        return;
    }
    arm_accept();
}

void Server::on_recv(unsigned index, const io_uring_cqe *cqe, uint32_t fd, uint32_t gen) {
    Ring &ring = rings_[index];
    bool has_buffer = cqe->flags & IORING_CQE_F_BUFFER;
    uint16_t buffer_id = static_cast<uint16_t>(cqe->flags >> IORING_CQE_BUFFER_SHIFT);
    const char *data = has_buffer ? ring.buffers + static_cast<size_t>(buffer_id) * kBufSize : nullptr;
    bool more = cqe->flags & IORING_CQE_F_MORE;
    int res = cqe->res;
    if (fd >= table_size_) {
        if (has_buffer) recycle(ring, buffer_id);
        return;
    }
    Conn &c = conns_[fd];
    if (!c.open || c.gen != gen) {
        if (has_buffer) recycle(ring, buffer_id);
        return;
    }
    if (res <= 0) {
        if (has_buffer) recycle(ring, buffer_id);
        if (res == -ENOBUFS || res == -EINTR) {
            if (!more) arm_recv(c);
            return;
        }
        close_conn(c);
        return;
    }
    touch(c);
    if (c.writing || c.in_block) {
        bool stored = append_input(c, data, static_cast<size_t>(res));
        recycle(ring, buffer_id);
        if (!stored) {
            close_conn(c);
            return;
        }
        if (!c.writing) process(c, c.in_block, c.in_len, false);
    } else {
        process(c, const_cast<char *>(data), static_cast<size_t>(res), true);
        recycle(ring, buffer_id);
    }
    if (!more && c.open && c.gen == gen) arm_recv(c);
}

void Server::on_send(const io_uring_cqe *cqe) {
    char *block = reinterpret_cast<char *>(cqe->user_data & ~static_cast<uint64_t>(kTagMask));
    SendContext ctx = *reinterpret_cast<SendContext *>(block);
    int res = cqe->res;
    Conn *c = ctx.fd < table_size_ ? &conns_[ctx.fd] : nullptr;
    if (!c || !c->open || c->gen != ctx.gen || c->out_block != block) {
        pool_.give(block);
        return;
    }
    if (res <= 0) {
        close_conn(*c);
        return;
    }
    c->out_off += static_cast<uint32_t>(res);
    if (c->out_off < c->out_len) {
        submit_send(*c);
        return;
    }
    pool_.give(block);
    c->out_block = nullptr;
    c->out_off = c->out_len = 0;
    c->writing = false;
    c->served = true;
    if (c->close_after_flush) {
        close_conn(*c);
        return;
    }
    touch(*c);
    if (c->in_len > 0) process(*c, c->in_block, c->in_len, false);
}

void Server::handle(unsigned index, const io_uring_cqe *cqe) {
    uint64_t data = cqe->user_data;
    switch (data & 0xff) {
        case kAccept:
        case kAcceptDirect:
            on_accept(index, cqe);
            break;
        case kRecv:
            on_recv(index, cqe, static_cast<uint32_t>(data >> 40), static_cast<uint32_t>(data >> 8));
            break;
        case kSend:
            on_send(cqe);
            break;
        case kCloseDirect:
            --rings_[index].reserved;
            break;
        default:
            break;
    }
}

void Server::pull(Ring &r) {
    __kernel_timespec none{0, 0};
    io_uring_cqe *cqe = nullptr;
    io_uring_submit_and_wait_timeout(&r.ring, &cqe, kBatch, &none, nullptr);
}

void Server::drain(unsigned index) {
    Ring &ring = rings_[index];
    for (;;) {
        unsigned head = 0;
        unsigned seen = 0;
        io_uring_cqe *cqe = nullptr;
        io_uring_for_each_cqe(&ring.ring, head, cqe) {
            handle(index, cqe);
            if (++seen == kBatch) break;
        }
        io_uring_cq_advance(&ring.ring, seen);
        handled_ += seen;
        commit_group();
        if (ring.recycled) {
            io_uring_buf_ring_advance(ring.buf_ring, static_cast<int>(ring.recycled));
            ring.recycled = 0;
        }
        if (seen == 0) break;
        if (index == 0) {
            io_uring_submit(&ring.ring);
        } else {
            pull(ring);
        }
    }
}

void Server::stop() { g_stop = 1; }

void Server::run() {
    for (unsigned i = 0; i < kAcceptDepth; ++i) arm_accept();
    __kernel_timespec idle{1, 0};
    __kernel_timespec idle_many{0, kIdleManyRingsNanos};
    __kernel_timespec batch{0, kWaitNanos};
    io_uring_cqe *first = nullptr;
    while (!g_stop) {
        bool busy = handled_ >= kBusyCompletions;
        unsigned target = static_cast<unsigned>(eastl::clamp<size_t>(open_count_ * kWaitOpenPercent / 100, 1, kWaitCompletions));
        bool many = ring_count_ > 1 && rings_[1].reserved > 0;
        handled_ = 0;
        for (unsigned i = 1; i < ring_count_; ++i) io_uring_submit(&rings_[i].ring);
        io_uring_submit_and_wait_timeout(&rings_[0].ring, &first, busy ? target : 1, busy ? &batch : many ? &idle_many : &idle, nullptr);
        for (unsigned i = 1; i < ring_count_; ++i) pull(rings_[i]);
        refresh_clock();
        for (unsigned n = accept_deficit_; n > 0; --n) {
            --accept_deficit_;
            arm_accept();
        }
        for (unsigned i = 0; i < ring_count_; ++i) drain(i);
        sweep_idle();
    }
}

}
