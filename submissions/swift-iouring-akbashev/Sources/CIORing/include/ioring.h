// io_uring with the raw system calls: io_uring_setup, io_uring_enter and io_uring_register, the rings mapped with
// mmap, and the head and tail updates with the acquire and release orderings the kernel's ring protocol asks for.
// The hot parts (taking a submission entry, preparing it, reading a completion) are inline; Swift's IORing type
// (IORing.swift) is built on them.
#pragma once

#include <linux/io_uring.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

struct ioring {
    int fd;
    unsigned features;
    // Submission queue: the kernel's head and tail, and the entries. `sqe_tail` runs ahead of the kernel's tail
    // until `ioring_enter` publishes it.
    unsigned *sq_khead;
    unsigned *sq_ktail;
    unsigned *sq_array; // NULL with IORING_SETUP_NO_SQARRAY
    unsigned sq_mask;
    unsigned sq_entries;
    unsigned sqe_tail;
    struct io_uring_sqe *sqes;
    // Completion queue: `cq_head` is ours, published by `ioring_cq_advance`.
    unsigned *cq_khead;
    unsigned *cq_ktail;
    unsigned cq_mask;
    unsigned cq_entries;
    unsigned cq_head;
    struct io_uring_cqe *cqes;
    // The mappings, for `ioring_exit`.
    void *sq_map;
    size_t sq_map_size;
    void *cq_map;
    size_t cq_map_size;
    size_t sqes_size;
};

/// A ring of provided buffers (IORING_REGISTER_PBUF_RING): `count` buffers of `size` bytes, handed back to the kernel
/// with `ioring_bufs_recycle` and `ioring_bufs_publish`.
struct ioring_bufs {
    struct io_uring_buf_ring *ring;
    char *base;
    unsigned count;
    unsigned mask;
    unsigned size;
    unsigned short group;
    unsigned short tail;
    size_t ring_size;
};

/// Sets up a ring of `entries` submission and `cq_entries` completion entries with `flags`; 0 or -errno.
int ioring_init(struct ioring *ring, unsigned entries, unsigned cq_entries, unsigned flags);
void ioring_exit(struct ioring *ring);

/// Submits what was prepared and, with `wait_nr` > 0, waits for that many completions or `timeout_ns` (< 0: no
/// timeout). Always asks for completions (IORING_ENTER_GETEVENTS), which a DEFER_TASKRUN ring posts only then.
/// Returns the number submitted, or -errno (-ETIME when the wait timed out).
int ioring_enter(struct ioring *ring, unsigned wait_nr, long long timeout_ns);

/// A sparse table of `count` direct descriptors.
int ioring_register_files_sparse(struct ioring *ring, unsigned count);

/// Registers `count` (a power of two) buffers of `size` bytes as buffer group `group`, all handed to the kernel.
int ioring_bufs_init(struct ioring *ring, struct ioring_bufs *bufs, unsigned count, unsigned size, unsigned short group);
void ioring_bufs_exit(struct ioring *ring, struct ioring_bufs *bufs);

// ---------- submissions ----------

/// The next free submission entry, zeroed; NULL when the queue is full (submit first).
static inline struct io_uring_sqe *ioring_get_sqe(struct ioring *ring) {
    unsigned head = __atomic_load_n(ring->sq_khead, __ATOMIC_ACQUIRE);
    if (ring->sqe_tail - head >= ring->sq_entries) return NULL;
    struct io_uring_sqe *sqe = &ring->sqes[ring->sqe_tail & ring->sq_mask];
    ring->sqe_tail++;
    memset(sqe, 0, sizeof(*sqe));
    return sqe;
}

/// Free submission entries.
static inline unsigned ioring_sq_space(const struct ioring *ring) {
    return ring->sq_entries - (ring->sqe_tail - __atomic_load_n(ring->sq_khead, __ATOMIC_ACQUIRE));
}

/// Entries prepared and not yet submitted.
static inline unsigned ioring_sq_pending(const struct ioring *ring) {
    return ring->sqe_tail - *ring->sq_ktail;
}

/// A multishot accept on `listener` into the ring's table of direct descriptors (the completion's `res` is the slot).
static inline void ioring_prep_accept_direct_multishot(struct io_uring_sqe *sqe, int listener, uint64_t data) {
    sqe->opcode = IORING_OP_ACCEPT;
    sqe->fd = listener;
    sqe->ioprio = IORING_ACCEPT_MULTISHOT;
    sqe->file_index = IORING_FILE_INDEX_ALLOC;
    sqe->user_data = data;
}

/// A multishot receive on direct descriptor `slot` into buffers of `group`.
static inline void ioring_prep_recv_multishot(struct io_uring_sqe *sqe, unsigned slot, unsigned short group, uint64_t data) {
    sqe->opcode = IORING_OP_RECV;
    sqe->fd = (int)slot;
    sqe->flags = IOSQE_FIXED_FILE | IOSQE_BUFFER_SELECT;
    sqe->ioprio = IORING_RECV_MULTISHOT;
    sqe->buf_group = group;
    sqe->user_data = data;
}

/// A send of `len` bytes at `buf` on direct descriptor `slot`, all of them (MSG_WAITALL).
static inline void ioring_prep_send(struct io_uring_sqe *sqe, unsigned slot, const void *buf, unsigned len, uint64_t data) {
    sqe->opcode = IORING_OP_SEND;
    sqe->fd = (int)slot;
    sqe->flags = IOSQE_FIXED_FILE;
    sqe->addr = (uint64_t)(uintptr_t)buf;
    sqe->len = len;
    sqe->msg_flags = 0x4000 /* MSG_NOSIGNAL */ | 0x100 /* MSG_WAITALL */;
    sqe->user_data = data;
}

/// A shutdown of direct descriptor `slot` (both directions): it ends the slot's multishot receive, so a close after it
/// releases the socket. `linked`: the next entry runs after this one.
static inline void ioring_prep_shutdown(struct io_uring_sqe *sqe, unsigned slot, int linked, uint64_t data) {
    sqe->opcode = IORING_OP_SHUTDOWN;
    sqe->fd = (int)slot;
    sqe->flags = IOSQE_FIXED_FILE | (linked ? IOSQE_IO_HARDLINK : 0);
    sqe->len = 2; // SHUT_RDWR
    sqe->user_data = data;
}

/// Closes direct descriptor `slot`, freeing it for the next accept.
static inline void ioring_prep_close_direct(struct io_uring_sqe *sqe, unsigned slot, uint64_t data) {
    sqe->opcode = IORING_OP_CLOSE;
    sqe->file_index = slot + 1;
    sqe->user_data = data;
}

/// A read of `len` bytes into `buf` from a plain descriptor (an eventfd), at its current position.
static inline void ioring_prep_read(struct io_uring_sqe *sqe, int fd, void *buf, unsigned len, uint64_t data) {
    sqe->opcode = IORING_OP_READ;
    sqe->fd = fd;
    sqe->addr = (uint64_t)(uintptr_t)buf;
    sqe->len = len;
    sqe->off = (uint64_t)-1;
    sqe->user_data = data;
}

/// Cancels the request submitted with user data `target`.
static inline void ioring_prep_cancel(struct io_uring_sqe *sqe, uint64_t target, uint64_t data) {
    sqe->opcode = IORING_OP_ASYNC_CANCEL;
    sqe->fd = -1;
    sqe->addr = target;
    sqe->user_data = data;
}

// ---------- completions ----------

/// The next completion not yet consumed, or NULL.
static inline const struct io_uring_cqe *ioring_peek_cqe(const struct ioring *ring) {
    unsigned tail = __atomic_load_n(ring->cq_ktail, __ATOMIC_ACQUIRE);
    if (ring->cq_head == tail) return NULL;
    return &ring->cqes[ring->cq_head & ring->cq_mask];
}

/// Consumes the completion `ioring_peek_cqe` returned; the kernel sees it at the next `ioring_cq_publish`.
static inline void ioring_cq_advance(struct ioring *ring) {
    ring->cq_head++;
}

static inline void ioring_cq_publish(struct ioring *ring) {
    __atomic_store_n(ring->cq_khead, ring->cq_head, __ATOMIC_RELEASE);
}

// ---------- provided buffers ----------

static inline char *ioring_buf(const struct ioring_bufs *bufs, unsigned short id) {
    return bufs->base + (size_t)id * bufs->size;
}

/// Hands buffer `id` back to the kernel at the next `ioring_bufs_publish`.
static inline void ioring_bufs_recycle(struct ioring_bufs *bufs, unsigned short id) {
    struct io_uring_buf *buf = &bufs->ring->bufs[bufs->tail & bufs->mask];
    buf->addr = (uint64_t)(uintptr_t)ioring_buf(bufs, id);
    buf->len = bufs->size;
    buf->bid = id;
    bufs->tail++;
}

static inline void ioring_bufs_publish(struct ioring_bufs *bufs) {
    __atomic_store_n(&bufs->ring->tail, bufs->tail, __ATOMIC_RELEASE);
}
