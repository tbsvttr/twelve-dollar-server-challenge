#define _GNU_SOURCE
#include "net.h"

#include <arpa/inet.h>
#include <errno.h>
#include <limits.h>
#include <netdb.h>
#include <netinet/tcp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

/* Only HTTP framing and socket ownership live here. Goose owns all API logic. */
typedef bytes NetSlice;
enum { BATCH_SIZE = 64, EVENT_COUNT = 256, MAX_CONNECTIONS = 32768,
       MAX_HEADERS = 32768, MAX_REQUEST = 1024 * 1024,
       IDLE_SECONDS = 125 };

typedef struct Conn Conn;
struct Conn {
    int fd;
    unsigned queued : 1, active : 1, close_after : 1, peer_eof : 1;
    unsigned read_paused : 1, expect_sent : 1;
    uint8_t *rx, *tx;
    size_t rx_len, rx_cap, header_scan, consumed, tx_len, tx_sent, tx_cap;
    uint32_t registered_events;
    NetSlice method, path, auth, body;
    uint64_t activity;
    Conn *all_prev, *all_next, *ready_prev, *ready_next;
};

typedef struct {
    int listener, epoll_fd, count;
    Conn *all, *ready_head, *ready_tail;
    Conn *batch[BATCH_SIZE];
    int batch_count;
    uint64_t last_sweep;
} Server;

static const uint8_t EMPTY[] = "";
static const NetSlice NO_SLICE = { EMPTY, 0 };

static uint64_t now_seconds(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec;
}

static Server *server_from(int64_t handle) {
    return (Server *)(intptr_t)handle;
}

static void ready_remove(Server *s, Conn *c) {
    if (!c->queued) return;
    if (c->ready_prev) c->ready_prev->ready_next = c->ready_next;
    else s->ready_head = c->ready_next;
    if (c->ready_next) c->ready_next->ready_prev = c->ready_prev;
    else s->ready_tail = c->ready_prev;
    c->queued = 0;
    c->ready_prev = c->ready_next = NULL;
}

static void ready_add(Server *s, Conn *c) {
    if (c->queued || c->active || c->tx_len || !c->rx_len) return;
    c->queued = 1;
    c->ready_prev = s->ready_tail;
    c->ready_next = NULL;
    if (s->ready_tail) s->ready_tail->ready_next = c;
    else s->ready_head = c;
    s->ready_tail = c;
}

static void conn_drop(Server *s, Conn *c) {
    ready_remove(s, c);
    epoll_ctl(s->epoll_fd, EPOLL_CTL_DEL, c->fd, NULL);
    close(c->fd);
    if (c->all_prev) c->all_prev->all_next = c->all_next;
    else s->all = c->all_next;
    if (c->all_next) c->all_next->all_prev = c->all_prev;
    --s->count;
    free(c->rx);
    free(c->tx);
    free(c);
}

static int conn_events(Server *s, Conn *c) {
    struct epoll_event e;
    memset(&e, 0, sizeof(e));
    e.events = EPOLLRDHUP;
    if (!c->read_paused && !c->peer_eof) e.events |= EPOLLIN;
    if (c->tx_len) e.events |= EPOLLOUT;
    if (e.events == c->registered_events) return 0;
    e.data.ptr = c;
    int result = epoll_ctl(s->epoll_fd, EPOLL_CTL_MOD, c->fd, &e);
    if (!result) c->registered_events = e.events;
    return result;
}

static const char *status_text(int status) {
    switch (status) {
    case 200: return "OK";
    case 201: return "Created";
    case 204: return "No Content";
    case 400: return "Bad Request";
    case 401: return "Unauthorized";
    case 403: return "Forbidden";
    case 404: return "Not Found";
    case 405: return "Method Not Allowed";
    case 409: return "Conflict";
    case 413: return "Content Too Large";
    case 422: return "Unprocessable Entity";
    case 429: return "Too Many Requests";
    case 500: return "Internal Server Error";
    case 503: return "Service Unavailable";
    default: return "Response";
    }
}

static int response_set(Conn *c, int status, const uint8_t *body, size_t length) {
    char header[256];
    if (status < 100 || status > 599) status = 500;
    if (status == 204 || status == 304) length = 0;
    int n = snprintf(header, sizeof(header),
        "HTTP/1.1 %d %s\r\nContent-Type: application/json\r\n"
        "Content-Length: %zu\r\nConnection: %s\r\n\r\n",
        status, status_text(status), length, c->close_after ? "close" : "keep-alive");
    if (n < 0 || (size_t)n >= sizeof(header) || length > SIZE_MAX - (size_t)n)
        return -1;
    size_t required = (size_t)n + length;
    if (required > c->tx_cap) {
        size_t next_cap = c->tx_cap ? c->tx_cap : 256;
        while (next_cap < required && next_cap <= SIZE_MAX / 2) next_cap *= 2;
        if (next_cap < required) next_cap = required;
        uint8_t *next = realloc(c->tx, next_cap);
        if (!next) return -1;
        c->tx = next;
        c->tx_cap = next_cap;
    }
    memcpy(c->tx, header, (size_t)n);
    if (length) memcpy(c->tx + n, body, length);
    c->tx_len = (size_t)n + length;
    c->tx_sent = 0;
    return 0;
}

static int response_error(Conn *c, int status) {
    static const uint8_t malformed[] = "{\"error\":\"Invalid HTTP request\"}";
    static const uint8_t internal[] = "{\"error\":\"internal server error\"}";
    return response_set(c, status, status == 500 ? internal : malformed,
                        status == 500 ? sizeof(internal)-1 : sizeof(malformed)-1);
}

static int conn_write(Server *s, Conn *c) {
    while (c->tx_sent < c->tx_len) {
        ssize_t n = send(c->fd, c->tx + c->tx_sent, c->tx_len - c->tx_sent,
                         MSG_NOSIGNAL);
        if (n > 0) {
            c->tx_sent += (size_t)n;
            c->activity = now_seconds();
        } else if (n < 0 && errno == EINTR) continue;
        else if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
            return conn_events(s, c);
        else return -1;
    }
    c->tx_len = c->tx_sent = 0;
    if (c->close_after || (c->peer_eof && !c->rx_len)) return -1;
    c->read_paused = 0;
    ready_add(s, c);
    return conn_events(s, c);
}

static int conn_read(Server *s, Conn *c) {
    for (;;) {
        if (c->rx_len == c->rx_cap) {
            if (c->rx_cap == MAX_REQUEST) {
                c->read_paused = 1;
                if (conn_events(s, c) < 0) return -1;
                break;
            }
            size_t next_cap = c->rx_cap ? c->rx_cap * 2 : 4096;
            if (next_cap > MAX_REQUEST) next_cap = MAX_REQUEST;
            uint8_t *next = realloc(c->rx, next_cap);
            if (!next) return -1;
            c->rx = next;
            c->rx_cap = next_cap;
        }
        ssize_t n = recv(c->fd, c->rx + c->rx_len, c->rx_cap - c->rx_len, 0);
        if (n > 0) {
            c->rx_len += (size_t)n;
            c->activity = now_seconds();
            /* Level-triggered epoll will report any bytes left in the socket. */
            break;
        } else if (n == 0) {
            c->peer_eof = 1;
            if (!c->rx_len && !c->tx_len) return -1;
            if (conn_events(s, c) < 0) return -1;
            break;
        } else if (errno == EINTR) continue;
        else if (errno == EAGAIN || errno == EWOULDBLOCK) break;
        else return -1;
    }
    ready_add(s, c);
    return 0;
}

static int ascii_equal(const uint8_t *a, size_t n, const char *b) {
    size_t len = strlen(b);
    if (n != len) return 0;
    for (size_t i = 0; i < n; ++i) {
        unsigned ch = a[i];
        if (ch >= 'A' && ch <= 'Z') ch += 'a' - 'A';
        if (ch != (unsigned char)b[i]) return 0;
    }
    return 1;
}

static int contains_token(const uint8_t *v, size_t len, const char *token) {
    size_t at = 0;
    while (at < len) {
        while (at < len && (v[at] == ',' || v[at] == ' ' || v[at] == '\t')) ++at;
        size_t end = at;
        while (end < len && v[end] != ',') ++end;
        size_t trim = end;
        while (trim > at && (v[trim-1] == ' ' || v[trim-1] == '\t')) --trim;
        if (ascii_equal(v + at, trim - at, token)) return 1;
        at = end < len ? end + 1 : len;
    }
    return 0;
}

static uint8_t *crlf(uint8_t *start, uint8_t *end) {
    for (uint8_t *p = start; end - p >= 2; ++p)
        if (p[0] == '\r' && p[1] == '\n') return p;
    return NULL;
}

/* 1: complete, 0: incomplete, negative: HTTP error. */
static int chunks_scan(Conn *c, size_t start, size_t *consumed, size_t *decoded) {
    size_t at = start, total = 0;
    for (;;) {
        uint8_t *line = crlf(c->rx + at, c->rx + c->rx_len);
        if (!line) return c->rx_len - at > 128 ? -400 : 0;
        size_t end = (size_t)(line - c->rx), count = 0, digits = 0;
        while (at < end && c->rx[at] != ';') {
            unsigned ch = c->rx[at++], d;
            if (ch >= '0' && ch <= '9') d = ch - '0';
            else if (ch >= 'a' && ch <= 'f') d = ch - 'a' + 10;
            else if (ch >= 'A' && ch <= 'F') d = ch - 'A' + 10;
            else return -400;
            if (count > (MAX_REQUEST - d) / 16) return -413;
            count = count * 16 + d;
            ++digits;
        }
        if (!digits) return -400;
        at = end + 2;
        if (!count) {
            size_t trailer_start = at;
            for (;;) {
                line = crlf(c->rx + at, c->rx + c->rx_len);
                if (!line) return c->rx_len - trailer_start > MAX_HEADERS ? -400 : 0;
                end = (size_t)(line - c->rx);
                if (end == at) {
                    *consumed = end + 2;
                    *decoded = total;
                    return 1;
                }
                if (!memchr(c->rx + at, ':', end - at)) return -400;
                at = end + 2;
            }
        }
        if (total > MAX_REQUEST - count) return -413;
        total += count;
        if (count + 2 > c->rx_len - at) return 0;
        if (c->rx[at + count] != '\r' || c->rx[at + count + 1] != '\n') return -400;
        at += count + 2;
    }
}

static void chunks_decode(Conn *c, size_t start) {
    size_t at = start, out = start;
    for (;;) {
        uint8_t *line = crlf(c->rx + at, c->rx + c->rx_len);
        size_t end = (size_t)(line - c->rx), count = 0;
        while (at < end && c->rx[at] != ';') {
            unsigned ch = c->rx[at++];
            unsigned d = ch <= '9' ? ch-'0' : ch <= 'F' ? ch-'A'+10 : ch-'a'+10;
            count = count * 16 + d;
        }
        if (!count) return;
        at = end + 2;
        memmove(c->rx + out, c->rx + at, count);
        out += count;
        at += count + 2;
    }
}

static int request_parse(Conn *c) {
    size_t headers = 0;
    for (size_t i = c->header_scan; i + 3 < c->rx_len; ++i) {
        if (c->rx[i] == '\r' && c->rx[i+1] == '\n' &&
            c->rx[i+2] == '\r' && c->rx[i+3] == '\n') {
            headers = i + 4;
            break;
        }
    }
    if (!headers) {
        c->header_scan = c->rx_len > 3 ? c->rx_len - 3 : 0;
        return c->rx_len >= MAX_HEADERS ? -400 : 0;
    }
    if (headers > MAX_HEADERS) return -400;
    uint8_t *p = c->rx, *end = c->rx + headers, *line = crlf(p, end);
    if (!line) return -400;
    uint8_t *space = memchr(p, ' ', (size_t)(line-p));
    if (!space || space == p || space-p > 32) return -400;
    c->method = (NetSlice){p, space-p};
    p = space + 1;
    space = memchr(p, ' ', (size_t)(line-p));
    if (!space || space == p || *p != '/') return -400;
    c->path = (NetSlice){p, space-p};
    p = space + 1;
    int http10 = line-p == 8 && !memcmp(p, "HTTP/1.0", 8);
    if (!http10 && (line-p != 8 || memcmp(p, "HTTP/1.1", 8))) return -400;
    c->close_after = http10;
    c->auth = NO_SLICE;
    size_t length = 0;
    int has_length = 0, chunked = 0, has_transfer = 0, expect_continue = 0;
    p = line + 2;
    while (p < end - 2) {
        line = crlf(p, end);
        if (!line) return -400;
        uint8_t *colon = memchr(p, ':', (size_t)(line-p));
        if (!colon || colon == p) return -400;
        uint8_t *v = colon + 1, *ve = line;
        while (v < ve && (*v == ' ' || *v == '\t')) ++v;
        while (ve > v && (ve[-1] == ' ' || ve[-1] == '\t')) --ve;
        size_t key_len = (size_t)(colon-p), value_len = (size_t)(ve-v);
        if (ascii_equal(p, key_len, "content-length")) {
            size_t parsed = 0;
            if (!value_len) return -400;
            for (uint8_t *q = v; q < ve; ++q) {
                if (*q < '0' || *q > '9') return -400;
                if (parsed > ((size_t)MAX_REQUEST - (*q-'0')) / 10) return -413;
                parsed = parsed * 10 + *q-'0';
            }
            if (has_length && parsed != length) return -400;
            has_length = 1;
            length = parsed;
        } else if (ascii_equal(p, key_len, "authorization")) {
            if (c->auth.len) return -400;
            c->auth = (NetSlice){v, (int64_t)value_len};
        } else if (ascii_equal(p, key_len, "connection")) {
            if (contains_token(v, value_len, "close")) c->close_after = 1;
            else if (http10 && contains_token(v, value_len, "keep-alive")) c->close_after = 0;
        } else if (ascii_equal(p, key_len, "transfer-encoding")) {
            if (has_transfer || !ascii_equal(v, value_len, "chunked")) return -400;
            has_transfer = chunked = 1;
        } else if (ascii_equal(p, key_len, "expect")) {
            expect_continue = ascii_equal(v, value_len, "100-continue");
        }
        p = line + 2;
    }
    if (chunked && has_length) return -400;
    if (chunked) {
        int result = chunks_scan(c, headers, &c->consumed, &length);
        if (result <= 0) return c->rx_len == MAX_REQUEST ? -413 : result;
        chunks_decode(c, headers);
    } else {
        if (length > MAX_REQUEST - headers) return -413;
        c->consumed = headers + length;
        if (c->rx_len < c->consumed) {
            /* Clients using Expect may wait before sending their body. */
            if (expect_continue && !c->expect_sent) {
                static const char interim[] = "HTTP/1.1 100 Continue\r\n\r\n";
                ssize_t ignored = send(c->fd, interim, sizeof(interim)-1, MSG_NOSIGNAL);
                (void)ignored;
                c->expect_sent = 1;
            }
            return 0;
        }
    }
    c->body = (NetSlice){c->rx + headers, (int64_t)length};
    return 1;
}

static void accept_connections(Server *s) {
    for (;;) {
        int fd = accept4(s->listener, NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC);
        if (fd < 0) {
            if (errno == EINTR) continue;
            return;
        }
        if (s->count >= MAX_CONNECTIONS) { close(fd); continue; }
        int one = 1;
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
        setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, sizeof(one));
        Conn *c = calloc(1, sizeof(*c));
        if (!c) { close(fd); continue; }
        c->fd = fd;
        c->activity = now_seconds();
        c->all_next = s->all;
        if (s->all) s->all->all_prev = c;
        s->all = c;
        ++s->count;
        struct epoll_event e;
        memset(&e, 0, sizeof(e));
        e.events = EPOLLIN | EPOLLRDHUP;
        c->registered_events = e.events;
        e.data.ptr = c;
        if (epoll_ctl(s->epoll_fd, EPOLL_CTL_ADD, fd, &e) < 0) conn_drop(s, c);
    }
}

int64_t net_init(NetSlice host, int64_t port) {
    if (port < 1 || port > 65535 || host.len < 0 || host.len > 255) return 0;
    char hostname[256], service[16];
    if (host.len) memcpy(hostname, host.data, (size_t)host.len);
    hostname[host.len] = '\0';
    snprintf(service, sizeof(service), "%lld", (long long)port);
    struct addrinfo hints, *addresses = NULL;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags = AI_PASSIVE;
    if (getaddrinfo(host.len ? hostname : NULL, service, &hints, &addresses)) return 0;
    int listener = -1;
    for (struct addrinfo *a = addresses; a; a = a->ai_next) {
        listener = socket(a->ai_family, a->ai_socktype | SOCK_NONBLOCK | SOCK_CLOEXEC, a->ai_protocol);
        if (listener < 0) continue;
        int one = 1;
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
        if (!bind(listener, a->ai_addr, a->ai_addrlen) && !listen(listener, 8192)) break;
        close(listener);
        listener = -1;
    }
    freeaddrinfo(addresses);
    if (listener < 0) return 0;
    Server *s = calloc(1, sizeof(*s));
    if (!s) { close(listener); return 0; }
    s->listener = listener;
    s->epoll_fd = epoll_create1(EPOLL_CLOEXEC);
    if (s->epoll_fd < 0) { close(listener); free(s); return 0; }
    struct epoll_event event;
    memset(&event, 0, sizeof(event));
    event.events = EPOLLIN;
    event.data.ptr = s;
    if (epoll_ctl(s->epoll_fd, EPOLL_CTL_ADD, listener, &event) < 0) {
        close(s->epoll_fd); close(listener); free(s); return 0;
    }
    s->last_sweep = now_seconds();
    return (int64_t)(intptr_t)s;
}

int64_t net_poll(int64_t handle) {
    Server *s = server_from(handle);
    if (!s || s->batch_count) return -1;
    /* Buffered pipelined requests do not need another kernel readiness edge. */
    for (;;) {
        while (s->ready_head && s->batch_count < BATCH_SIZE) {
            Conn *c = s->ready_head;
            ready_remove(s, c);
            int parsed = request_parse(c);
            if (parsed > 0) {
                c->active = 1;
                s->batch[s->batch_count++] = c;
            } else if (parsed < 0) {
                c->close_after = 1;
                c->rx_len = 0;
                if (response_error(c, -parsed) < 0 || conn_write(s, c) < 0) conn_drop(s, c);
            } else if (c->peer_eof) conn_drop(s, c);
        }
        if (s->batch_count) return s->batch_count;
        struct epoll_event events[EVENT_COUNT];
        int n = epoll_wait(s->epoll_fd, events, EVENT_COUNT, 1000);
        if (n < 0) { if (errno == EINTR) continue; return -1; }
        for (int i = 0; i < n; ++i) {
            Conn *c = events[i].data.ptr;
            if ((void *)c == (void *)s) { accept_connections(s); continue; }
            uint32_t ev = events[i].events;
            if (ev & EPOLLERR) { conn_drop(s, c); continue; }
            if (ev & (EPOLLIN | EPOLLRDHUP | EPOLLHUP)) {
                if (conn_read(s, c) < 0) { conn_drop(s, c); continue; }
            }
            if (ev & EPOLLOUT) {
                if (conn_write(s, c) < 0) { conn_drop(s, c); continue; }
            }
        }
        uint64_t now = now_seconds();
        if (now >= s->last_sweep + 5) {
            Conn *c = s->all;
            while (c) {
                Conn *next = c->all_next;
                if (!c->active && now >= c->activity + IDLE_SECONDS) conn_drop(s, c);
                c = next;
            }
            s->last_sweep = now;
        }
        if (!n) return 0;
    }
}

static Conn *batch_conn(int64_t handle, int64_t index) {
    Server *s = server_from(handle);
    if (!s || index < 0 || index >= s->batch_count) return NULL;
    return s->batch[index];
}

/* Synchronous exported Goose callback: no native view survives the call. */
extern void goose_handle_request(int64_t handle, int64_t index, bytes method,
                                 bytes path, bytes auth, bytes body);

void net_dispatch_batch(int64_t handle) {
    Server *s = server_from(handle);
    if (!s) return;
    for (int i = 0; i < s->batch_count; ++i) {
        Conn *c = s->batch[i];
        goose_handle_request(handle, i, c->method, c->path, c->auth, c->body);
    }
}

void net_method(int64_t handle, int64_t index, gs_rref out) {
    Conn *c = batch_conn(handle, index);
    if (c) gs_bld_append(out, c->method.data, c->method.len);
}
void net_path(int64_t handle, int64_t index, gs_rref out) {
    Conn *c = batch_conn(handle, index);
    if (c) gs_bld_append(out, c->path.data, c->path.len);
}
void net_auth(int64_t handle, int64_t index, gs_rref out) {
    Conn *c = batch_conn(handle, index);
    if (c) gs_bld_append(out, c->auth.data, c->auth.len);
}
void net_body(int64_t handle, int64_t index, gs_rref out) {
    Conn *c = batch_conn(handle, index);
    if (c) gs_bld_append(out, c->body.data, c->body.len);
}

void net_reply(int64_t handle, int64_t index, int32_t status, NetSlice body) {
    Conn *c = batch_conn(handle, index);
    if (!c) return;
    if (body.len < 0 || (body.len && !body.data) ||
        response_set(c, status, body.data, (size_t)body.len) < 0) {
        c->close_after = 1;
        response_error(c, 500);
    }
}

void net_flush(int64_t handle, int32_t commit_ok) {
    Server *s = server_from(handle);
    if (!s) return;
    for (int i = 0; i < s->batch_count; ++i) {
        Conn *c = s->batch[i];
        if (!commit_ok || !c->tx_len) {
            if (response_error(c, 500) < 0) { conn_drop(s, c); continue; }
        }
        if (c->consumed < c->rx_len)
            memmove(c->rx, c->rx + c->consumed, c->rx_len - c->consumed);
        c->rx_len -= c->consumed;
        c->consumed = c->header_scan = 0;
        c->expect_sent = 0;
        c->active = 0;
        /* Bound each connection to one pending response before reading again. */
        c->read_paused = 1;
        if (conn_write(s, c) < 0) conn_drop(s, c);
    }
    s->batch_count = 0;
}

void net_close(int64_t handle) {
    Server *s = server_from(handle);
    if (!s) return;
    while (s->all) conn_drop(s, s->all);
    close(s->listener);
    close(s->epoll_fd);
    free(s);
}
