#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>

#include "sys.h"
#include "jwt.h"
#include "http.h"
#include "db.h"

#define NUM_RINGS 8
#define MAX_SLOTS_PER_RING 55000
#define TOTAL_MAX_SLOTS (NUM_RINGS * MAX_SLOTS_PER_RING)
#define PBUF_ENTRIES 2048
#define PBUF_SIZE 1024
#define RESP_POOL_SIZE 2048
#define RESP_BUF_SIZE 8192
#define ACCEPT_NEXT 8192
#define ACCEPT_STOP 4096
#define NLISTEN NUM_RINGS
#define ALL_LISTENERS ((1u << NLISTEN) - 1)

enum {
    OP_ACCEPT = 1,
    OP_POLL = 2,
    OP_RECV = 3,
    OP_SEND = 4,
    OP_CLOSE = 5,
    OP_EVENTFD = 6,
    OP_CANCEL = 7
};

#define MAKE_UD(op, ring, slot, gen) \
    (((uint64_t)(op) << 56) | (((uint64_t)(ring) & 0xFF) << 48) | (((uint64_t)(slot) & 0xFFFFFFFF) << 16) | ((uint64_t)(gen) & 0xFFFF))
#define UD_OP(ud) ((unsigned)((ud) >> 56))
#define UD_RING(ud) ((unsigned)(((ud) >> 48) & 0xFF))
#define UD_SLOT(ud) ((unsigned)(((ud) >> 16) & 0xFFFFFFFF))
#define UD_GEN(ud) ((uint16_t)((ud) & 0xFFFF))

typedef struct {
    uint16_t gen;
    uint8_t open;
    uint8_t keep_alive;
    uint8_t poll_armed;
} conn_t;

static conn_t g_conns[NUM_RINGS][MAX_SLOTS_PER_RING];

/* Response buffer pool */
static char g_resp_pool[RESP_POOL_SIZE][RESP_BUF_SIZE];
static uint16_t g_resp_free_stack[RESP_POOL_SIZE];
static int g_resp_free_top = RESP_POOL_SIZE;

static inline int resp_alloc() {
    if (g_resp_free_top > 0) {
        return (int)g_resp_free_stack[--g_resp_free_top];
    }
    return -1;
}

static inline void resp_free(int idx) {
    if (idx >= 0 && idx < RESP_POOL_SIZE && g_resp_free_top < RESP_POOL_SIZE) {
        g_resp_free_stack[g_resp_free_top++] = (uint16_t)idx;
    }
}

/* Pending writes for group commit */
typedef struct {
    int ring_idx;
    unsigned slot;
    uint16_t gen;
    int is_like; // 0 = post create, 1 = like
    int resp_idx;
    int keep_alive;
    // Post create fields
    int64_t user_id;
    char author[128];
    char body[512];
    size_t body_len;
    // Like fields
    int64_t post_id;
} pending_write_t;

#define MAX_PENDING_WRITES 256
static pending_write_t g_pending_writes[MAX_PENDING_WRITES];
static int g_num_pending_writes = 0;

static time_t g_server_start_time = 0;
static struct ring g_rings[NUM_RINGS];
static int g_listen_fds[NUM_RINGS];
static int g_efds[NUM_RINGS];
static unsigned g_active_conns = 0;
static unsigned g_ring_conns[NUM_RINGS];
static uint8_t g_accept_armed[NUM_RINGS];
static uint8_t g_accept_cancelling[NUM_RINGS];
static unsigned g_slots_per_ring = MAX_SLOTS_PER_RING;

static void arm_accept(int r) {
    for (int l = 0; l < NLISTEN; l++) {
        if (!(g_accept_armed[r] & (1u << l))) {
            sqe_accept_multishot(ring_sqe(&g_rings[r]), g_listen_fds[l], MAKE_UD(OP_ACCEPT, r, l, 0));
            g_accept_armed[r] |= (uint8_t)(1u << l);
            g_accept_cancelling[r] &= (uint8_t)~(1u << l);
        }
    }
}

static void accept_policy(void) {
    unsigned lowest = NUM_RINGS;
    for (unsigned i = 0; i < NUM_RINGS; i++) {
        if (g_ring_conns[i] + ACCEPT_STOP < g_slots_per_ring) {
            lowest = i;
            break;
        }
    }
    for (unsigned i = 0; i < NUM_RINGS; i++) {
        int room = g_ring_conns[i] + ACCEPT_STOP < g_slots_per_ring;
        int want = room && (i == lowest || (i == lowest + 1 && lowest + 1 < NUM_RINGS && g_ring_conns[lowest] + ACCEPT_NEXT >= g_slots_per_ring));
        if (want && g_accept_armed[i] != ALL_LISTENERS) {
            arm_accept(i);
        } else if (!room) {
            for (int l = 0; l < NLISTEN; l++) {
                if ((g_accept_armed[i] & ~g_accept_cancelling[i]) & (1u << l)) {
                    sqe_cancel(ring_sqe(&g_rings[i]), MAKE_UD(OP_ACCEPT, i, l, 0), MAKE_UD(OP_CANCEL, i, l, 0));
                    g_accept_cancelling[i] |= (uint8_t)(1u << l);
                }
            }
        }
    }
}

static void close_conn(int ring_idx, unsigned slot, uint16_t gen) {
    if (ring_idx >= NUM_RINGS || slot >= g_slots_per_ring || !g_conns[ring_idx][slot].open || g_conns[ring_idx][slot].gen != gen) return;
    g_conns[ring_idx][slot].open = 0;
    g_conns[ring_idx][slot].poll_armed = 0;
    g_conns[ring_idx][slot].gen++;
    if (g_active_conns > 0) g_active_conns--;
    if (g_ring_conns[ring_idx] > 0) g_ring_conns[ring_idx]--;

    uint64_t poll_ud = MAKE_UD(OP_POLL, ring_idx, slot, gen);
    uint64_t close_ud = MAKE_UD(OP_CLOSE, ring_idx, slot, g_conns[ring_idx][slot].gen);
    sqe_shutdown_close(&g_rings[ring_idx], slot, close_ud, poll_ud, close_ud);
}

int main() {
    signal(SIGPIPE, SIG_IGN);
    g_server_start_time = time(NULL);

    struct rlimit rl;
    if (getrlimit(RLIMIT_NOFILE, &rl) == 0) {
        if (rl.rlim_cur < rl.rlim_max) {
            rl.rlim_cur = rl.rlim_max;
            setrlimit(RLIMIT_NOFILE, &rl);
        }
    }
    getrlimit(RLIMIT_NOFILE, &rl);
    g_slots_per_ring = (rl.rlim_cur < MAX_SLOTS_PER_RING) ? (unsigned)rl.rlim_cur : MAX_SLOTS_PER_RING;

    const char *sqlite_path = getenv("SQLITE_PATH");
    if (!sqlite_path) sqlite_path = "feed.db";

    const char *jwt_secret = getenv("JWT_SECRET");
    if (!jwt_secret) jwt_secret = "twelve-dollar-challenge";

    const char *host = getenv("HOST");
    if (!host) host = "0.0.0.0";

    const char *port_str = getenv("PORT");
    int port = port_str ? atoi(port_str) : 80;

    printf("Starting c-iouring-fajarreza-gif (%d rings, %u slots/ring, %u total) on %s:%d\n",
           NUM_RINGS, g_slots_per_ring, g_slots_per_ring * NUM_RINGS, host, port);
    printf("SQLite DB: %s\n", sqlite_path);

    jwt_init(jwt_secret);

    if (db_init(sqlite_path) != 0) {
        fprintf(stderr, "Failed to initialize SQLite at %s\n", sqlite_path);
        return 1;
    }

    // Initialize response buffer pool free stack
    for (int i = 0; i < RESP_POOL_SIZE; i++) {
        g_resp_free_stack[i] = (uint16_t)i;
    }

    // Setup 6 io_uring rings
    for (int i = 0; i < NUM_RINGS; i++) {
        int defer = (i == 0) ? 1 : 0;
        const char *err = NULL;
        unsigned cq = 8192;
        while (ring_init(&g_rings[i], 2048, cq, g_slots_per_ring, PBUF_ENTRIES, PBUF_SIZE, defer, &err) != 0) {
            if (cq <= 2048) {
                fprintf(stderr, "Failed to initialize io_uring ring %d: %s (errno %d: %s)\n",
                        i, err ? err : "unknown", errno, strerror(errno));
                return 1;
            }
            cq /= 2;
        }
        if (i > 0) {
            g_efds[i] = ring_register_eventfd(&g_rings[i]);
            if (g_efds[i] < 0) {
                fprintf(stderr, "Failed to register eventfd for ring %d: %s\n", i, strerror(errno));
                return 1;
            }
            sqe_poll_multishot(ring_sqe(&g_rings[0]), g_efds[i], MAKE_UD(OP_EVENTFD, i, 0, 0));
        }
    }

    // Setup listening sockets with SO_REUSEPORT
    struct sockaddr_in sin;
    memset(&sin, 0, sizeof(sin));
    sin.sin_family = AF_INET;
    sin.sin_port = htons((uint16_t)port);
    inet_pton(AF_INET, host, &sin.sin_addr);

    for (int i = 0; i < NLISTEN; i++) {
        int listen_fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0);
        if (listen_fd < 0) { perror("socket"); return 1; }
        g_listen_fds[i] = listen_fd;

        int opt = 1;
        setsockopt(listen_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
        setsockopt(listen_fd, SOL_SOCKET, SO_REUSEPORT, &opt, sizeof(opt));
        setsockopt(listen_fd, IPPROTO_TCP, TCP_NODELAY, &opt, sizeof(opt));

        if (bind(listen_fd, (struct sockaddr*)&sin, sizeof(sin)) != 0) {
            perror("bind");
            return 1;
        }
        if (listen(listen_fd, 4096) != 0) {
            perror("listen");
            return 1;
        }
    }

    // Initial accept arming via policy
    accept_policy();
    ring_submit(&g_rings[0], 0, 0, NULL, 0);

    printf("Listening on %s:%d (%d io_uring rings ready)\n", host, port, NUM_RINGS);

    // Event loop
    while (1) {
        // Submit pending SQEs on secondary rings before waiting
        for (int r = 1; r < NUM_RINGS; r++) {
            if (ring_pending_submit(&g_rings[r]) > 0) {
                ring_submit(&g_rings[r], 0, 0, NULL, 0);
            }
        }

        long ret = ring_wait(&g_rings[0], 1, 50);
        if (ret < 0 && ret != -EINTR && ret != -ETIME) {
            fprintf(stderr, "ring_wait error: %ld\n", ret);
            break;
        }

        g_num_pending_writes = 0;
        int read_trans_open = 0;

        for (int r = 0; r < NUM_RINGS; r++) {
            struct ring *ring = &g_rings[r];
            unsigned head = *ring->cq_head;
            unsigned tail = LOAD_ACQ(ring->cq_tail);
            unsigned count = 0;

            while (head != tail) {
                struct io_uring_cqe *cqe = &ring->cqes[head & ring->cq_mask];
                uint64_t ud = cqe->user_data;
                unsigned op = UD_OP(ud);
                unsigned ring_idx = UD_RING(ud);
                unsigned slot = UD_SLOT(ud);
                uint16_t gen = UD_GEN(ud);
                int res = cqe->res;
                unsigned flags = cqe->flags;

                head++;
                count++;
                if ((count & 63) == 0) {
                    STORE_REL(ring->cq_head, head);
                }

                switch (op) {
                    case OP_ACCEPT: {
                        unsigned l = slot;
                        if (!(flags & IORING_CQE_F_MORE)) {
                            uint8_t bit = (uint8_t)(1u << l);
                            g_accept_armed[ring_idx] &= (uint8_t)~bit;
                            g_accept_cancelling[ring_idx] &= (uint8_t)~bit;
                        }
                        if (res >= 0) {
                            unsigned new_slot = (unsigned)res;
                            if (new_slot < g_slots_per_ring) {
                                g_conns[ring_idx][new_slot].gen++;
                                g_conns[ring_idx][new_slot].open = 1;
                                g_conns[ring_idx][new_slot].keep_alive = 1;
                                g_conns[ring_idx][new_slot].poll_armed = 1;
                                g_active_conns++;
                                g_ring_conns[ring_idx]++;
                                sqe_poll_conn(ring_sqe(ring), new_slot, MAKE_UD(OP_POLL, ring_idx, new_slot, g_conns[ring_idx][new_slot].gen));
                            }
                        }
                        break;
                    }

                    case OP_CANCEL: {
                        unsigned l = slot;
                        g_accept_cancelling[ring_idx] &= (uint8_t)~(1u << l);
                        break;
                    }

                    case OP_EVENTFD: {
                        if (!(flags & IORING_CQE_F_MORE)) {
                            sqe_poll_multishot(ring_sqe(&g_rings[0]), g_efds[ring_idx], MAKE_UD(OP_EVENTFD, ring_idx, 0, 0));
                        }
                        break;
                    }

                    case OP_POLL: {
                        if (slot < g_slots_per_ring && g_conns[ring_idx][slot].open && g_conns[ring_idx][slot].gen == gen) {
                            if (!(flags & IORING_CQE_F_MORE)) {
                                g_conns[ring_idx][slot].poll_armed = 0;
                            }
                            if (res <= 0 || (res & (POLLERR | POLLHUP | POLLRDHUP))) {
                                close_conn(ring_idx, slot, gen);
                            } else if (res & POLLIN) {
                                sqe_recv_once(ring_sqe(ring), slot, MAKE_UD(OP_RECV, ring_idx, slot, gen));
                            }
                        }
                        break;
                    }

                    case OP_RECV: {
                        if (slot < g_slots_per_ring && g_conns[ring_idx][slot].open && g_conns[ring_idx][slot].gen == gen) {
                            if (res <= 0) {
                                if (res != -EAGAIN) {
                                    close_conn(ring_idx, slot, gen);
                                }
                            } else {
                                unsigned bid = flags >> 16;
                                const char *req_buf = (const char*)ring_buf_ptr(ring, bid);
                                size_t req_len = (size_t)res;

                                http_request_t req;
                                int parse_rc = http_parse_request(req_buf, req_len, &req);

                                int resp_idx = resp_alloc();
                                if (resp_idx < 0) {
                                    ring_buf_return(ring, bid);
                                    close_conn(ring_idx, slot, gen);
                                    break;
                                }

                                char *resp = g_resp_pool[resp_idx];
                                size_t resp_len = 0;

                                int keep_alive = req.keep_alive;
                                g_conns[ring_idx][slot].keep_alive = keep_alive;

                                if (parse_rc != 0) {
                                    keep_alive = 0;
                                    g_conns[ring_idx][slot].keep_alive = 0;
                                    resp_len = format_error(resp, RESP_BUF_SIZE, 400, "Bad Request", "malformed request", 0);
                                } else if (req.method == METHOD_GET && req.path_len == 7 && memcmp(req.path, "/health", 7) == 0) {
                                    char body[256];
                                    int64_t uptime = (int64_t)(time(NULL) - g_server_start_time);
                                    size_t blen = db_health(body, sizeof(body), uptime);
                                    resp_len = format_response(resp, RESP_BUF_SIZE, 200, "OK", body, blen, keep_alive);
                                } else if (req.method == METHOD_GET && req.path_len == 5 && memcmp(req.path, "/feed", 5) == 0) {
                                    if (!read_trans_open) { db_begin_read(); read_trans_open = 1; }
                                    char body[RESP_BUF_SIZE - 256];
                                    size_t blen = db_query_feed(body, sizeof(body));
                                    resp_len = format_response(resp, RESP_BUF_SIZE, 200, "OK", body, blen, keep_alive);
                                } else if (req.method == METHOD_GET && req.path_len > 7 && memcmp(req.path, "/posts/", 7) == 0) {
                                    const char *id_str = req.path + 7;
                                    size_t id_len = req.path_len - 7;
                                    int valid_id = (id_len > 0);
                                    for (size_t i = 0; i < id_len; i++) {
                                        if (id_str[i] < '0' || id_str[i] > '9') { valid_id = 0; break; }
                                    }
                                    if (id_str[0] == '0') valid_id = 0; // positive integer only

                                    if (!valid_id) {
                                        resp_len = format_error(resp, RESP_BUF_SIZE, 400, "Bad Request", "invalid post id", keep_alive);
                                    } else {
                                        int64_t post_id = strtoll(id_str, NULL, 10);
                                        char body[RESP_BUF_SIZE - 256];
                                        size_t blen = 0;
                                        if (!read_trans_open) { db_begin_read(); read_trans_open = 1; }
                                        if (!db_query_post(post_id, body, sizeof(body), &blen)) {
                                            resp_len = format_error(resp, RESP_BUF_SIZE, 404, "Not Found", "post not found", keep_alive);
                                        } else {
                                            resp_len = format_response(resp, RESP_BUF_SIZE, 200, "OK", body, blen, keep_alive);
                                        }
                                    }
                                } else if (req.method == METHOD_POST && req.path_len == 6 && memcmp(req.path, "/posts", 6) == 0) {
                                    // Auth check first
                                    if (!req.has_auth_header || !req.is_bearer) {
                                        resp_len = format_error(resp, RESP_BUF_SIZE, 401, "Unauthorized", "missing bearer token", keep_alive);
                                    } else {
                                        int64_t user_id = 0;
                                        char username[128] = {0};
                                        int vrc = jwt_verify(req.auth_token, req.auth_token_len, (int64_t)time(NULL), &user_id, username, sizeof(username));
                                        if (vrc == JWT_ERR_INVALID) {
                                            resp_len = format_error(resp, RESP_BUF_SIZE, 401, "Unauthorized", "invalid or expired token", keep_alive);
                                        } else if (vrc == JWT_ERR_PAYLOAD) {
                                            resp_len = format_error(resp, RESP_BUF_SIZE, 401, "Unauthorized", "invalid token payload", keep_alive);
                                        } else {
                                            // Body parsing
                                            char body_trimmed[512];
                                            size_t body_trimmed_len = 0;
                                            int prc = parse_post_body(req.body, req.body_len, body_trimmed, sizeof(body_trimmed), &body_trimmed_len);
                                            if (prc == POST_BODY_MALFORMED) {
                                                resp_len = format_error(resp, RESP_BUF_SIZE, 400, "Bad Request", "malformed JSON body", keep_alive);
                                            } else if (prc == POST_BODY_REQUIRED) {
                                                resp_len = format_error(resp, RESP_BUF_SIZE, 400, "Bad Request", "body is required", keep_alive);
                                            } else if (prc == POST_BODY_TOO_LONG) {
                                                resp_len = format_error(resp, RESP_BUF_SIZE, 400, "Bad Request", "body must be at most 500 characters", keep_alive);
                                            } else {
                                                // Queue write for group commit
                                                if (g_num_pending_writes < MAX_PENDING_WRITES) {
                                                    pending_write_t *pw = &g_pending_writes[g_num_pending_writes++];
                                                    pw->ring_idx = ring_idx;
                                                    pw->slot = slot;
                                                    pw->gen = gen;
                                                    pw->is_like = 0;
                                                    pw->resp_idx = resp_idx;
                                                    pw->keep_alive = keep_alive;
                                                    pw->user_id = user_id;
                                                    memcpy(pw->author, username, sizeof(pw->author));
                                                    memcpy(pw->body, body_trimmed, body_trimmed_len);
                                                    pw->body[body_trimmed_len] = '\0';
                                                    pw->body_len = body_trimmed_len;
                                                    resp_idx = -1; // Don't send now, queued
                                                } else {
                                                    // Batch full: execute immediately
                                                    char res_body[1024];
                                                    size_t res_len = 0;
                                                    db_create_post(user_id, body_trimmed, body_trimmed_len, username, res_body, sizeof(res_body), &res_len);
                                                    resp_len = format_response(resp, RESP_BUF_SIZE, 201, "Created", res_body, res_len, keep_alive);
                                                }
                                            }
                                        }
                                    }
                                } else if (req.method == METHOD_POST && req.path_len > 12 &&
                                           memcmp(req.path, "/posts/", 7) == 0 &&
                                           memcmp(req.path + req.path_len - 5, "/like", 5) == 0) {
                                    // Auth check FIRST (before id check!)
                                    if (!req.has_auth_header || !req.is_bearer) {
                                        resp_len = format_error(resp, RESP_BUF_SIZE, 401, "Unauthorized", "missing bearer token", keep_alive);
                                    } else {
                                        int64_t user_id = 0;
                                        char username[128] = {0};
                                        int vrc = jwt_verify(req.auth_token, req.auth_token_len, (int64_t)time(NULL), &user_id, username, sizeof(username));
                                        if (vrc == JWT_ERR_INVALID) {
                                            resp_len = format_error(resp, RESP_BUF_SIZE, 401, "Unauthorized", "invalid or expired token", keep_alive);
                                        } else if (vrc == JWT_ERR_PAYLOAD) {
                                            resp_len = format_error(resp, RESP_BUF_SIZE, 401, "Unauthorized", "invalid token payload", keep_alive);
                                        } else {
                                            // Now validate post id
                                            const char *id_str = req.path + 7;
                                            size_t id_len = req.path_len - 12;
                                            int valid_id = (id_len > 0);
                                            for (size_t i = 0; i < id_len; i++) {
                                                if (id_str[i] < '0' || id_str[i] > '9') { valid_id = 0; break; }
                                            }
                                            if (id_str[0] == '0') valid_id = 0;

                                            if (!valid_id) {
                                                resp_len = format_error(resp, RESP_BUF_SIZE, 400, "Bad Request", "invalid post id", keep_alive);
                                            } else {
                                                int64_t post_id = strtoll(id_str, NULL, 10);
                                                if (!read_trans_open) { db_begin_read(); read_trans_open = 1; }
                                                if (!db_check_post_exists(post_id)) {
                                                    resp_len = format_error(resp, RESP_BUF_SIZE, 404, "Not Found", "post not found", keep_alive);
                                                } else {
                                                    // Queue like for group commit
                                                    if (g_num_pending_writes < MAX_PENDING_WRITES) {
                                                        pending_write_t *pw = &g_pending_writes[g_num_pending_writes++];
                                                        pw->ring_idx = ring_idx;
                                                        pw->slot = slot;
                                                        pw->gen = gen;
                                                        pw->is_like = 1;
                                                        pw->resp_idx = resp_idx;
                                                        pw->keep_alive = keep_alive;
                                                        pw->user_id = user_id;
                                                        pw->post_id = post_id;
                                                        resp_idx = -1; // Queued
                                                    } else {
                                                        int already_liked = 0;
                                                        char res_body[256];
                                                        size_t res_len = 0;
                                                        db_like_post(user_id, post_id, &already_liked, res_body, sizeof(res_body), &res_len);
                                                        int st = already_liked ? 200 : 201;
                                                        const char *st_str = already_liked ? "OK" : "Created";
                                                        resp_len = format_response(resp, RESP_BUF_SIZE, st, st_str, res_body, res_len, keep_alive);
                                                    }
                                                }
                                            }
                                        }
                                    }
                                } else {
                                    resp_len = format_error(resp, RESP_BUF_SIZE, 404, "Not Found", "not found", keep_alive);
                                }

                                // Return received buffer back to provided buffer ring
                                ring_buf_return(ring, bid);

                                // Send response if not queued
                                if (resp_idx >= 0) {
                                    uint64_t send_ud = MAKE_UD(OP_SEND, ring_idx, slot, (uint16_t)resp_idx);
                                    sqe_send(ring_sqe(ring), slot, resp, (unsigned)resp_len, send_ud);
                                }

                                // If poll was un-armed and connection is keep-alive, re-arm
                                if (!g_conns[ring_idx][slot].poll_armed && g_conns[ring_idx][slot].keep_alive) {
                                    g_conns[ring_idx][slot].poll_armed = 1;
                                    sqe_poll_conn(ring_sqe(ring), slot, MAKE_UD(OP_POLL, ring_idx, slot, gen));
                                }
                            }
                        }
                        break;
                    }

                    case OP_SEND: {
                        // Free response buffer
                        int resp_idx = (int)gen;
                        resp_free(resp_idx);
                        if (slot < g_slots_per_ring && g_conns[ring_idx][slot].open) {
                            if (!g_conns[ring_idx][slot].keep_alive) {
                                close_conn(ring_idx, slot, g_conns[ring_idx][slot].gen);
                            }
                        }
                        break;
                    }

                    case OP_CLOSE: {
                        break;
                    }
                }
            } // end while (head != tail)

            // Commit pending CQEs for this ring
            if (count > 0) {
                STORE_REL(ring->cq_head, head);
            }
        } // end for (int r = 0; r < NUM_RINGS; r++)

        if (read_trans_open) {
            db_commit_read();
        }

        // Process group commit for pending writes
        if (g_num_pending_writes > 0) {
            db_begin();
            for (int i = 0; i < g_num_pending_writes; i++) {
                pending_write_t *pw = &g_pending_writes[i];
                char *resp = g_resp_pool[pw->resp_idx];
                size_t resp_len = 0;

                if (pw->is_like == 0) {
                    char res_body[1024];
                    size_t res_len = 0;
                    db_create_post(pw->user_id, pw->body, pw->body_len, pw->author, res_body, sizeof(res_body), &res_len);
                    resp_len = format_response(resp, RESP_BUF_SIZE, 201, "Created", res_body, res_len, pw->keep_alive);
                } else {
                    int already_liked = 0;
                    char res_body[256];
                    size_t res_len = 0;
                    db_like_post(pw->user_id, pw->post_id, &already_liked, res_body, sizeof(res_body), &res_len);
                    int st = already_liked ? 200 : 201;
                    const char *st_str = already_liked ? "OK" : "Created";
                    resp_len = format_response(resp, RESP_BUF_SIZE, st, st_str, res_body, res_len, pw->keep_alive);
                }

                // Send response
                uint64_t send_ud = MAKE_UD(OP_SEND, pw->ring_idx, pw->slot, (uint16_t)pw->resp_idx);
                sqe_send(ring_sqe(&g_rings[pw->ring_idx]), pw->slot, resp, (unsigned)resp_len, send_ud);
            }
            db_commit();
        }

        // Maintain accept policy across all rings
        accept_policy();

        // Publish returned buffers and flush pending submissions across all rings
        for (int r = 0; r < NUM_RINGS; r++) {
            ring_buf_publish(&g_rings[r]);
            if (ring_pending_submit(&g_rings[r]) > 0) {
                ring_submit(&g_rings[r], 0, 0, NULL, 0);
            }
        }
    }

    return 0;
}
