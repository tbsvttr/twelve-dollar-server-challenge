#pragma once

#include <EASTL/intrusive_list.h>
#include <liburing.h>

#include <cstddef>
#include <cstdint>
#include <ctime>

#include "app.hpp"
#include "block_pool.hpp"
#include "conn.hpp"
#include "db.hpp"
#include "http.hpp"

namespace srv {

class Server {
public:
    Server(App &app, Db &db, int listen_fd, size_t fd_limit);
    ~Server();

    Server(const Server &) = delete;
    Server &operator=(const Server &) = delete;

    bool init();
    const char *error() const { return error_; }
    // Serves until stop() is called (async-signal-safe), then returns.
    void run();
    static void stop();

private:
    bool process(Conn &c, char *buf, size_t have, bool shared);
    bool respond(Conn &c, const Request &req);
    bool respond_bad_request(Conn &c);
    void prepare_send(Conn &c, char *block, size_t body_size, int status, bool keep_alive);
    void submit_send(Conn &c);
    void commit_group();
    void close_conn(Conn &c);
    Conn *open_conn(int fd);
    void release_conn(Conn &c, bool keep_out_block);
    void touch(Conn &c);
    void evict_one();
    void sweep_idle();
    void refresh_clock();
    bool append_input(Conn &c, const char *data, size_t n);
    size_t id_of(const Conn &c) const { return static_cast<size_t>(&c - conns_); }
    void aim(io_uring_sqe *sqe, size_t id) const;
    eastl::string_view date() const { return {date_, date_len_}; }

    struct Ring {
        io_uring ring{};
        io_uring_buf_ring *buf_ring = nullptr;
        char *buffers = nullptr;
        unsigned recycled = 0;
        size_t reserved = 0;
        bool ready = false;
    };

    bool init_ring(Ring &r, bool first);
    void drain(unsigned index);
    void pull(Ring &r);
    unsigned ring_index(size_t id) const { return id < fd_limit_ ? 0 : static_cast<unsigned>((id - fd_limit_) / slots_per_ring_); }
    Ring &ring_for(size_t id) { return rings_[ring_index(id)]; }
    io_uring_sqe *next_sqe(Ring &r);
    void arm_accept();
    void arm_recv(Conn &c);
    void recycle(Ring &r, uint16_t buffer_id);
    void handle(unsigned index, const io_uring_cqe *cqe);
    void on_accept(unsigned index, const io_uring_cqe *cqe);
    void on_recv(unsigned index, const io_uring_cqe *cqe, uint32_t fd, uint32_t gen);
    void on_send(const io_uring_cqe *cqe);

    static constexpr size_t kMaxDeferred = 512;

    struct Deferred {
        uint32_t fd;
        uint32_t gen;
        char *block;
        bool keep_alive;
    };

    App &app_;
    Db &db_;
    int listen_;
    size_t fd_limit_;
    size_t max_open_;
    size_t slots_per_ring_;
    size_t table_size_;
    bool direct_ok_ = false;
    unsigned ring_count_ = 1;
    unsigned handled_ = 0;
    size_t open_count_ = 0;
    Conn *conns_ = nullptr;
    eastl::intrusive_list<Conn> lru_;
    BlockPool pool_;
    uint32_t tick_ = 0;
    uint32_t last_sweep_ = 0;
    time_t wall_ = 0;
    char date_[48] = {};
    size_t date_len_ = 0;

    static constexpr unsigned kMaxRings = 5;
    Ring rings_[kMaxRings];
    unsigned accept_deficit_ = 0;
    Deferred deferred_[kMaxDeferred];
    size_t deferred_count_ = 0;
    const char *error_ = "";
};

}
