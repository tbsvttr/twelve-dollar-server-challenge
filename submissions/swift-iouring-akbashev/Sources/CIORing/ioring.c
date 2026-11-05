// io_uring_setup, io_uring_enter and io_uring_register through syscall(2), and the mappings of the rings, as the
// kernel's io_uring documentation lays them out (see ioring.h).
#include "ioring.h"

#include <errno.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <unistd.h>

int ioring_init(struct ioring *ring, unsigned entries, unsigned cq_entries, unsigned flags) {
    memset(ring, 0, sizeof(*ring));
    ring->fd = -1;
    struct io_uring_params p;
    memset(&p, 0, sizeof(p));
    p.flags = flags | IORING_SETUP_CQSIZE;
    p.cq_entries = cq_entries;
    int fd = (int)syscall(__NR_io_uring_setup, entries, &p);
    if (fd < 0) return -errno;

    ring->sq_map_size = p.sq_off.array + p.sq_entries * sizeof(unsigned);
    ring->cq_map_size = p.cq_off.cqes + p.cq_entries * sizeof(struct io_uring_cqe);
    int single = (p.features & IORING_FEAT_SINGLE_MMAP) != 0;
    if (single) {
        if (ring->cq_map_size > ring->sq_map_size) ring->sq_map_size = ring->cq_map_size;
        ring->cq_map_size = ring->sq_map_size;
    }
    void *sq = mmap(NULL, ring->sq_map_size, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE, fd, IORING_OFF_SQ_RING);
    if (sq == MAP_FAILED) goto fail;
    void *cq = sq;
    if (!single) {
        cq = mmap(NULL, ring->cq_map_size, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE, fd, IORING_OFF_CQ_RING);
        if (cq == MAP_FAILED) {
            munmap(sq, ring->sq_map_size);
            goto fail;
        }
    }
    ring->sqes_size = p.sq_entries * sizeof(struct io_uring_sqe);
    void *sqes = mmap(NULL, ring->sqes_size, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE, fd, IORING_OFF_SQES);
    if (sqes == MAP_FAILED) {
        if (!single) munmap(cq, ring->cq_map_size);
        munmap(sq, ring->sq_map_size);
        goto fail;
    }

    char *s = sq;
    char *c = cq;
    ring->fd = fd;
    ring->features = p.features;
    ring->sq_map = sq;
    ring->cq_map = cq;
    ring->sq_khead = (unsigned *)(s + p.sq_off.head);
    ring->sq_ktail = (unsigned *)(s + p.sq_off.tail);
    ring->sq_mask = *(unsigned *)(s + p.sq_off.ring_mask);
    ring->sq_entries = *(unsigned *)(s + p.sq_off.ring_entries);
    ring->sqe_tail = *ring->sq_ktail;
    ring->sqes = sqes;
    if (!(flags & IORING_SETUP_NO_SQARRAY)) {
        // The index array maps each place in the queue to the entry at the same place.
        ring->sq_array = (unsigned *)(s + p.sq_off.array);
        for (unsigned i = 0; i < ring->sq_entries; i++) ring->sq_array[i] = i;
    }
    ring->cq_khead = (unsigned *)(c + p.cq_off.head);
    ring->cq_ktail = (unsigned *)(c + p.cq_off.tail);
    ring->cq_mask = *(unsigned *)(c + p.cq_off.ring_mask);
    ring->cq_entries = *(unsigned *)(c + p.cq_off.ring_entries);
    ring->cq_head = *ring->cq_khead;
    ring->cqes = (struct io_uring_cqe *)(c + p.cq_off.cqes);
    return 0;

fail: {
    int err = errno;
    close(fd);
    return -err;
}
}

void ioring_exit(struct ioring *ring) {
    if (ring->fd < 0) return;
    munmap(ring->sqes, ring->sqes_size);
    if (ring->cq_map != ring->sq_map) munmap(ring->cq_map, ring->cq_map_size);
    munmap(ring->sq_map, ring->sq_map_size);
    close(ring->fd);
    ring->fd = -1;
}

int ioring_enter(struct ioring *ring, unsigned wait_nr, long long timeout_ns) {
    unsigned submit = ring->sqe_tail - *ring->sq_ktail;
    if (submit) __atomic_store_n(ring->sq_ktail, ring->sqe_tail, __ATOMIC_RELEASE);
    unsigned flags = IORING_ENTER_GETEVENTS;
    struct __kernel_timespec ts;
    struct io_uring_getevents_arg arg;
    void *argp = NULL;
    size_t argsz = 0;
    if (wait_nr > 0 && timeout_ns >= 0) {
        ts.tv_sec = timeout_ns / 1000000000LL;
        ts.tv_nsec = timeout_ns % 1000000000LL;
        memset(&arg, 0, sizeof(arg));
        arg.ts = (uint64_t)(uintptr_t)&ts;
        flags |= IORING_ENTER_EXT_ARG;
        argp = &arg;
        argsz = sizeof(arg);
    }
    long rc = syscall(__NR_io_uring_enter, ring->fd, submit, wait_nr, flags, argp, argsz);
    return rc < 0 ? -errno : (int)rc;
}

int ioring_register_files_sparse(struct ioring *ring, unsigned count) {
    struct io_uring_rsrc_register reg;
    memset(&reg, 0, sizeof(reg));
    reg.nr = count;
    reg.flags = IORING_RSRC_REGISTER_SPARSE;
    long rc = syscall(__NR_io_uring_register, ring->fd, IORING_REGISTER_FILES2, &reg, sizeof(reg));
    return rc < 0 ? -errno : 0;
}

int ioring_bufs_init(struct ioring *ring, struct ioring_bufs *bufs, unsigned count, unsigned size, unsigned short group) {
    memset(bufs, 0, sizeof(*bufs));
    bufs->ring_size = (size_t)count * sizeof(struct io_uring_buf);
    void *mem = mmap(NULL, bufs->ring_size, PROT_READ | PROT_WRITE, MAP_ANONYMOUS | MAP_PRIVATE, -1, 0);
    if (mem == MAP_FAILED) return -errno;
    struct io_uring_buf_reg reg;
    memset(&reg, 0, sizeof(reg));
    reg.ring_addr = (uint64_t)(uintptr_t)mem;
    reg.ring_entries = count;
    reg.bgid = group;
    long rc = syscall(__NR_io_uring_register, ring->fd, IORING_REGISTER_PBUF_RING, &reg, 1);
    if (rc < 0 && errno == EINVAL) {
        // Ubuntu's 6.8.0-136 and later kernels refuse reserved words that are all zero (Launchpad #2162843, an
        // inverted check), and take a nonzero one.
        reg.resv[0] = 1;
        rc = syscall(__NR_io_uring_register, ring->fd, IORING_REGISTER_PBUF_RING, &reg, 1);
    }
    if (rc < 0) {
        int err = errno;
        munmap(mem, bufs->ring_size);
        return -err;
    }
    bufs->base = aligned_alloc(4096, (size_t)count * size);
    if (!bufs->base) return -ENOMEM;
    bufs->ring = mem;
    bufs->count = count;
    bufs->mask = count - 1;
    bufs->size = size;
    bufs->group = group;
    for (unsigned i = 0; i < count; i++) ioring_bufs_recycle(bufs, (unsigned short)i);
    ioring_bufs_publish(bufs);
    return 0;
}

void ioring_bufs_exit(struct ioring *ring, struct ioring_bufs *bufs) {
    if (!bufs->ring) return;
    struct io_uring_buf_reg reg;
    memset(&reg, 0, sizeof(reg));
    reg.bgid = bufs->group;
    syscall(__NR_io_uring_register, ring->fd, IORING_UNREGISTER_PBUF_RING, &reg, 1);
    munmap(bufs->ring, bufs->ring_size);
    free(bufs->base);
    bufs->ring = NULL;
}
