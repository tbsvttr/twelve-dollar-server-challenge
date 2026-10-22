#define _GNU_SOURCE
#include "net.h"

/* Keep one HTTP parser, response formatter, and Goose callback ABI. */
#define net_init epoll_net_init
#define net_poll epoll_net_poll
#define net_dispatch_batch epoll_net_dispatch_batch
#define net_method epoll_net_method
#define net_path epoll_net_path
#define net_auth epoll_net_auth
#define net_body epoll_net_body
#define net_reply epoll_net_reply
#define net_flush epoll_net_flush
#define net_close epoll_net_close
#include "net_epoll.inc"
#undef net_init
#undef net_poll
#undef net_dispatch_batch
#undef net_method
#undef net_path
#undef net_auth
#undef net_body
#undef net_reply
#undef net_flush
#undef net_close

#include "net_uring.inc"

/* Allocation alignment leaves the low bit free to identify the backend. */
static int64_t net_raw_handle(int64_t handle) { return handle & ~INT64_C(1); }
static int net_is_uring(int64_t handle) { return (int)(handle & 1); }

int64_t net_init(bytes host, int64_t port) {
    const char *backend = getenv("GOOSE_IO_BACKEND");
    if (!backend || !*backend) backend = "epoll";
    if (!strcmp(backend, "epoll")) {
        fprintf(stderr, "Goose native transport: epoll\n");
        return epoll_net_init(host, port);
    }
    if (strcmp(backend, "auto") && strcmp(backend, "uring")) {
        fprintf(stderr, "Invalid GOOSE_IO_BACKEND: expected epoll, uring, or auto\n");
        errno = EINVAL; return 0;
    }
    int64_t h = uring_net_init(host, port);
    if (h) return h | 1;
    int error = errno;
    if (!strcmp(backend, "uring")) {
        fprintf(stderr, "io_uring initialization failed: %s\n", strerror(error));
        return 0;
    }
    if (error != ENOSYS && error != EOPNOTSUPP && error != EINVAL && error != EPERM && error != EACCES) {
        errno = error; return 0;
    }
    fprintf(stderr, "io_uring unavailable (%s); using epoll\n", strerror(error));
    return epoll_net_init(host, port);
}

int64_t net_poll(int64_t handle) {
    return net_is_uring(handle) ? uring_net_poll(net_raw_handle(handle)) : epoll_net_poll(handle);
}

void net_dispatch_batch(int64_t handle) {
    Server *s = server_from(net_raw_handle(handle));
    if (!s) return;
    for (int i = 0; i < s->batch_count; ++i) {
        Conn *c = s->batch[i];
        goose_handle_request(handle, i, c->method, c->path, c->auth, c->body);
    }
}

void net_method(int64_t h, int64_t i, gs_rref out) { epoll_net_method(net_raw_handle(h), i, out); }
void net_path(int64_t h, int64_t i, gs_rref out) { epoll_net_path(net_raw_handle(h), i, out); }
void net_auth(int64_t h, int64_t i, gs_rref out) { epoll_net_auth(net_raw_handle(h), i, out); }
void net_body(int64_t h, int64_t i, gs_rref out) { epoll_net_body(net_raw_handle(h), i, out); }

void net_reply(int64_t h, int64_t i, int32_t status, bytes body) {
    int64_t raw = net_raw_handle(h);
    if (net_is_uring(h)) {
        UServer *s = (UServer *)(intptr_t)raw;
        Conn *c = batch_conn(raw, i);
        if (c) u_take_tx(s, (UConn *)c);
    }
    epoll_net_reply(raw, i, status, body);
}

void net_flush(int64_t h, int32_t ok) {
    if (net_is_uring(h)) uring_net_flush(net_raw_handle(h), ok);
    else epoll_net_flush(h, ok);
}

void net_close(int64_t h) {
    if (net_is_uring(h)) uring_net_close(net_raw_handle(h));
    else epoll_net_close(h);
}
