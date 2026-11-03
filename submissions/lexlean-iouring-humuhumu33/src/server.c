// One event-loop thread over io_uring direct descriptors, one SQLite transaction per batch.
// Compiled as one translation unit with the SQLite amalgamation so reads can use the B-tree layer.
// The cursor seek and record decoding follow lean-derive-hargup (#153, MIT); drain-first batching follows lessons
// published by c-iouring-pavlyhalim (#245, MIT), and the multishot receive by rust-iouring-kensac (#264).
#define _GNU_SOURCE
#include "sqlite3.c"
#include "core.h"
#include <arpa/inet.h>
#include <liburing.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <sys/eventfd.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/socket.h>

#define LIKELY(x) __builtin_expect(!!(x), 1)
#define UNLIKELY(x) __builtin_expect(!!(x), 0)

#define MAX_RINGS 8
#define ACCEPT_LISTENERS 8
// Newer kernels charge ring memory to RLIMIT_MEMLOCK, 8 MiB under systemd: every ring must fit in an eighth of it.
#define RING_ENTRIES 4096
#define RING_COMPLETIONS 16384
#define BUFFER_COUNT 4096
#define BUFFER_SIZE 1024
#define BUFFER_GROUP 1
#define ARENAS 8
#define ARENA_SIZE (2u << 20)
#define RESPONSE_RESERVE (128u << 10)
// A request read out of its socket costs its Request here, one waiting in the socket 3-4 KB of network buffer.
#define MAX_REQUESTS 32768
#define BATCH_ANSWERS 2048
#define HOLD_CAP 8192
#define SPILL_CAP (64u << 10)
#define WAIT_COMPLETIONS 64
#define WAIT_NANOSECONDS 2000000

enum { OP_ACCEPT = 1, OP_RECV, OP_SEND, OP_CLOSE, OP_WAKE, OP_IGNORE };
enum { C_FREE, C_OPEN, C_CLOSING };
enum { ARMED_NOTHING, ARMED_MULTISHOT, ARMED_ONCE };
enum { K_CONST, K_HEALTH, K_FEED, K_POST, K_LIKE, K_CREATE, K_HELD };

typedef struct {
    uint8_t state;
    uint8_t queued;
    uint8_t close_after;
    uint8_t armed;
    uint16_t sends;
    uint16_t generation;
    uint32_t spill_len;
    uint32_t held;
    uint8_t *spill;
} Conn;

typedef struct {
    struct io_uring ring;
    struct io_uring_buf_ring *buffers;
    uint8_t *memory;
    Conn *conns;
    uint32_t *read_queue;
    uint32_t queued;
    uint32_t table;
    uint32_t open;
    uint32_t pending_sqes;
    int ready;
    int accepting;
} Ring;

typedef struct {
    uint8_t *data;
    uint32_t pending;
    uint32_t used;
    uint64_t batch;
} Arena;

typedef struct {
    uint8_t kind;
    uint8_t ring;
    uint8_t close;
    uint8_t failed;
    uint16_t status;
    uint16_t buffer;
    uint16_t generation;
    uint32_t slot;
    uint32_t scratch_end;
    int arena;
    char *owned;
    const char *response;
    uint32_t response_len;
    int64_t id;
    int64_t user;
    const char *username;
    uint32_t username_len;
    const char *text;
    uint32_t text_len;
} Request;

static Ring rings[MAX_RINGS];
static int ring_count;
static Arena arenas[ARENAS];
static int current_arena;
static Request requests[MAX_REQUESTS];
static uint32_t request_head, request_count;
static Request held[HOLD_CAP];
static uint32_t held_count;
static char *scratch;
static uint32_t scratch_write, scratch_tail;
#define SCRATCH_SIZE (8u << 20)
static int listeners[ACCEPT_LISTENERS];
static uint32_t table_size;
static int wake_fd = -1;
static time_t started_at;
static uint64_t now_seconds;

static uint64_t encode(int op, int ring, int arena, uint32_t slot) {
    return (uint64_t)op << 56 | (uint64_t)ring << 48 | (uint64_t)(uint8_t)arena << 40 | slot;
}

static void die(const char *what) {
    fprintf(stderr, "fatal: %s\n", what);
    exit(1);
}

/* ---- SHA-256, HMAC, JWT ---------------------------------------------------------------- */

static const uint32_t K256[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};

#define ROTR(x, n) (((x) >> (n)) | ((x) << (32 - (n))))

static void sha256_block(uint32_t state[8], const uint8_t *block) {
    uint32_t w[64];
    for (int i = 0; i < 16; i++) w[i] = (uint32_t)block[i * 4] << 24 | (uint32_t)block[i * 4 + 1] << 16 | (uint32_t)block[i * 4 + 2] << 8 | block[i * 4 + 3];
    for (int i = 16; i < 64; i++) {
        uint32_t s0 = ROTR(w[i - 15], 7) ^ ROTR(w[i - 15], 18) ^ (w[i - 15] >> 3);
        uint32_t s1 = ROTR(w[i - 2], 17) ^ ROTR(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    uint32_t a = state[0], b = state[1], c = state[2], d = state[3], e = state[4], f = state[5], g = state[6], h = state[7];
    for (int i = 0; i < 64; i++) {
        uint32_t t1 = h + (ROTR(e, 6) ^ ROTR(e, 11) ^ ROTR(e, 25)) + ((e & f) ^ (~e & g)) + K256[i] + w[i];
        uint32_t t2 = (ROTR(a, 2) ^ ROTR(a, 13) ^ ROTR(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
        h = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
    }
    state[0] += a; state[1] += b; state[2] += c; state[3] += d; state[4] += e; state[5] += f; state[6] += g; state[7] += h;
}

static const uint32_t SHA_INIT[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
static uint32_t hmac_inner[8], hmac_outer[8];

static void sha256_finish(uint32_t state[8], const uint8_t *data, size_t len, uint64_t prefix, uint8_t out[32]) {
    size_t i = 0;
    while (len - i >= 64) {
        sha256_block(state, data + i);
        i += 64;
    }
    uint8_t last[128] = {0};
    size_t rest = len - i;
    memcpy(last, data + i, rest);
    last[rest] = 0x80;
    size_t blocks = rest < 56 ? 64 : 128;
    uint64_t bits = (prefix + len) * 8;
    for (int b = 0; b < 8; b++) last[blocks - 1 - b] = (uint8_t)(bits >> (8 * b));
    sha256_block(state, last);
    if (blocks == 128) sha256_block(state, last + 64);
    for (int b = 0; b < 8; b++) {
        out[b * 4] = (uint8_t)(state[b] >> 24);
        out[b * 4 + 1] = (uint8_t)(state[b] >> 16);
        out[b * 4 + 2] = (uint8_t)(state[b] >> 8);
        out[b * 4 + 3] = (uint8_t)state[b];
    }
}

static void hmac_setup(const char *secret) {
    uint8_t key[64] = {0}, pad[64];
    size_t n = strlen(secret);
    if (n > 64) {
        uint32_t s[8];
        memcpy(s, SHA_INIT, sizeof s);
        sha256_finish(s, (const uint8_t *)secret, n, 0, key);
    } else {
        memcpy(key, secret, n);
    }
    for (int i = 0; i < 64; i++) pad[i] = key[i] ^ 0x36;
    memcpy(hmac_inner, SHA_INIT, sizeof hmac_inner);
    sha256_block(hmac_inner, pad);
    for (int i = 0; i < 64; i++) pad[i] = key[i] ^ 0x5c;
    memcpy(hmac_outer, SHA_INIT, sizeof hmac_outer);
    sha256_block(hmac_outer, pad);
}

static void hmac(const uint8_t *data, size_t len, uint8_t out[32]) {
    uint32_t s[8];
    uint8_t inner[32];
    memcpy(s, hmac_inner, sizeof s);
    sha256_finish(s, data, len, 64, inner);
    memcpy(s, hmac_outer, sizeof s);
    sha256_finish(s, inner, 32, 64, out);
}

static int8_t b64_table[256];

static void b64_setup(void) {
    memset(b64_table, -1, sizeof b64_table);
    const char *alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    for (int i = 0; i < 64; i++) b64_table[(uint8_t)alphabet[i]] = (int8_t)i;
}

static int b64_decode(const char *in, size_t n, uint8_t *out, size_t *out_len) {
    uint32_t acc = 0;
    int bits = 0;
    size_t w = 0;
    for (size_t i = 0; i < n; i++) {
        int8_t v = b64_table[(uint8_t)in[i]];
        if (v < 0) return -1;
        acc = acc << 6 | (uint32_t)v;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            out[w++] = (uint8_t)(acc >> bits);
        }
    }
    *out_len = w;
    return 0;
}

/* ---- JSON input ------------------------------------------------------------------------ */

typedef struct {
    const char *p;
    const char *end;
    int depth;
} Json;

static void j_space(Json *j) {
    while (j->p < j->end && (*j->p == ' ' || *j->p == '\t' || *j->p == '\n' || *j->p == '\r')) j->p++;
}

static int hex4(const char *p, uint32_t *v) {
    uint32_t x = 0;
    for (int i = 0; i < 4; i++) {
        char c = p[i];
        x <<= 4;
        if (c >= '0' && c <= '9') x |= (uint32_t)(c - '0');
        else if (c >= 'a' && c <= 'f') x |= (uint32_t)(c - 'a' + 10);
        else if (c >= 'A' && c <= 'F') x |= (uint32_t)(c - 'A' + 10);
        else return -1;
    }
    *v = x;
    return 0;
}

static char *put_utf8(char *o, uint32_t c) {
    if (c < 0x80) {
        *o++ = (char)c;
    } else if (c < 0x800) {
        *o++ = (char)(0xC0 | c >> 6);
        *o++ = (char)(0x80 | (c & 63));
    } else if (c < 0x10000) {
        *o++ = (char)(0xE0 | c >> 12);
        *o++ = (char)(0x80 | ((c >> 6) & 63));
        *o++ = (char)(0x80 | (c & 63));
    } else {
        *o++ = (char)(0xF0 | c >> 18);
        *o++ = (char)(0x80 | ((c >> 12) & 63));
        *o++ = (char)(0x80 | ((c >> 6) & 63));
        *o++ = (char)(0x80 | (c & 63));
    }
    return o;
}

// Validates a string at p. With out set, also decodes it; out must hold the raw length.
static int j_string(Json *j, char *out, uint32_t *out_len) {
    if (j->p >= j->end || *j->p != '"') return -1;
    j->p++;
    char *o = out;
    while (j->p < j->end) {
        unsigned char c = (unsigned char)*j->p;
        if (c == '"') {
            j->p++;
            if (out) *out_len = (uint32_t)(o - out);
            return 0;
        }
        if (c < 0x20) return -1;
        if (c != '\\') {
            if (o) *o++ = (char)c;
            j->p++;
            continue;
        }
        j->p++;
        if (j->p >= j->end) return -1;
        char e = *j->p++;
        uint32_t v;
        switch (e) {
        case '"': case '\\': case '/': if (o) *o++ = e; break;
        case 'b': if (o) *o++ = '\b'; break;
        case 'f': if (o) *o++ = '\f'; break;
        case 'n': if (o) *o++ = '\n'; break;
        case 'r': if (o) *o++ = '\r'; break;
        case 't': if (o) *o++ = '\t'; break;
        case 'u':
            if (j->end - j->p < 4 || hex4(j->p, &v)) return -1;
            j->p += 4;
            if (v >= 0xD800 && v < 0xDC00 && j->end - j->p >= 6 && j->p[0] == '\\' && j->p[1] == 'u') {
                uint32_t low;
                if (!hex4(j->p + 2, &low) && low >= 0xDC00 && low < 0xE000) {
                    v = 0x10000 + ((v - 0xD800) << 10) + (low - 0xDC00);
                    j->p += 6;
                }
            }
            if (o) o = put_utf8(o, v);
            break;
        default: return -1;
        }
    }
    return -1;
}

static int j_value(Json *j);

static int j_number(Json *j) {
    const char *p = j->p, *e = j->end;
    if (p < e && *p == '-') p++;
    if (p >= e) return -1;
    if (*p == '0') p++;
    else if (*p >= '1' && *p <= '9') while (p < e && *p >= '0' && *p <= '9') p++;
    else return -1;
    if (p < e && *p == '.') {
        p++;
        if (p >= e || *p < '0' || *p > '9') return -1;
        while (p < e && *p >= '0' && *p <= '9') p++;
    }
    if (p < e && (*p == 'e' || *p == 'E')) {
        p++;
        if (p < e && (*p == '+' || *p == '-')) p++;
        if (p >= e || *p < '0' || *p > '9') return -1;
        while (p < e && *p >= '0' && *p <= '9') p++;
    }
    j->p = p;
    return 0;
}

static int j_literal(Json *j, const char *word, size_t n) {
    if ((size_t)(j->end - j->p) < n || memcmp(j->p, word, n)) return -1;
    j->p += n;
    return 0;
}

static int j_value(Json *j) {
    j_space(j);
    if (j->p >= j->end || j->depth > 64) return -1;
    switch (*j->p) {
    case '"': return j_string(j, NULL, NULL);
    case 't': return j_literal(j, "true", 4);
    case 'f': return j_literal(j, "false", 5);
    case 'n': return j_literal(j, "null", 4);
    case '[':
        j->p++;
        j->depth++;
        j_space(j);
        if (j->p < j->end && *j->p == ']') {
            j->p++;
            j->depth--;
            return 0;
        }
        for (;;) {
            if (j_value(j)) return -1;
            j_space(j);
            if (j->p >= j->end) return -1;
            char c = *j->p++;
            if (c == ']') break;
            if (c != ',') return -1;
        }
        j->depth--;
        return 0;
    case '{':
        j->p++;
        j->depth++;
        j_space(j);
        if (j->p < j->end && *j->p == '}') {
            j->p++;
            j->depth--;
            return 0;
        }
        for (;;) {
            j_space(j);
            if (j_string(j, NULL, NULL)) return -1;
            j_space(j);
            if (j->p >= j->end || *j->p++ != ':') return -1;
            if (j_value(j)) return -1;
            j_space(j);
            if (j->p >= j->end) return -1;
            char c = *j->p++;
            if (c == '}') break;
            if (c != ',') return -1;
        }
        j->depth--;
        return 0;
    default: return j_number(j);
    }
}

// Finds a top-level key of a validated object. Returns a Json positioned at its last value.
static int j_find(const char *text, size_t n, const char *key, Json *value) {
    size_t key_len = strlen(key);
    Json j = {text, text + n, 0};
    j_space(&j);
    if (j.p >= j.end || *j.p != '{') return 0;
    j.p++;
    int found = 0;
    j_space(&j);
    if (j.p < j.end && *j.p == '}') return 0;
    for (;;) {
        j_space(&j);
        const char *start = j.p + 1;
        if (j_string(&j, NULL, NULL)) return 0;
        size_t raw = (size_t)(j.p - 1 - start);
        j_space(&j);
        j.p++;
        j_space(&j);
        const char *at = j.p;
        if (j_value(&j)) return 0;
        if (raw == key_len && !memcmp(start, key, raw)) {
            value->p = at;
            value->end = text + n;
            value->depth = 0;
            found = 1;
        }
        j_space(&j);
        if (j.p >= j.end || *j.p++ != ',') break;
    }
    return found;
}

/* ---- SQLite ---------------------------------------------------------------------------- */

static sqlite3 *db;
static Btree *bt;
static sqlite3_stmt *st_begin, *st_commit, *st_rollback, *st_health, *st_insert_post, *st_post_time, *st_like, *st_post_exists;
static Pgno root_posts, root_users, root_time, root_likes;
static KeyInfo *key_time, *key_likes;
static BtCursor *cur_posts, *cur_users, *cur_time, *cur_likes;
static int in_batch, cursors_open;

static sqlite3_stmt *prepare(const char *sql) {
    sqlite3_stmt *s;
    if (sqlite3_prepare_v3(db, sql, -1, SQLITE_PREPARE_PERSISTENT, &s, 0) != SQLITE_OK) {
        fprintf(stderr, "prepare %s: %s\n", sql, sqlite3_errmsg(db));
        exit(1);
    }
    return s;
}

static void exec(const char *sql) {
    char *error = 0;
    if (sqlite3_exec(db, sql, 0, 0, &error) != SQLITE_OK) {
        fprintf(stderr, "%s: %s\n", sql, error);
        exit(1);
    }
}

static Pgno root_page(const char *name) {
    sqlite3_stmt *s = prepare("SELECT rootpage FROM sqlite_schema WHERE name = ?1");
    sqlite3_bind_text(s, 1, name, -1, SQLITE_STATIC);
    Pgno root = sqlite3_step(s) == SQLITE_ROW ? (Pgno)sqlite3_column_int64(s, 0) : 0;
    sqlite3_finalize(s);
    if (!root) die("the schema is not the one this server was written for");
    return root;
}

static KeyInfo *key_info(int keys, int extra) {
    KeyInfo *k = sqlite3KeyInfoAlloc(db, keys, extra);
    if (!k) die("key info");
    for (int i = 0; i < keys + extra; i++) k->aColl[i] = db->pDfltColl;
    return k;
}

static void check_columns(const char *table, const char *expected) {
    char sql[128], got[512] = "";
    snprintf(sql, sizeof sql, "PRAGMA table_info(\"%s\")", table);
    sqlite3_stmt *s = prepare(sql);
    size_t n = 0;
    while (sqlite3_step(s) == SQLITE_ROW && n < sizeof got - 64) n += (size_t)snprintf(got + n, sizeof got - n, "%s%s", n ? "," : "", (const char *)sqlite3_column_text(s, 1));
    sqlite3_finalize(s);
    if (strcmp(got, expected)) die("the schema is not the one this server was written for");
}

/* A second connection runs checkpoints so a slow fsync never stalls responses. A passive checkpoint can't
 * finish while commits keep arriving, and the log only restarts once it has, so under steady writes it grows
 * as dirty memory until the box runs out. Past WAL_GATE_FRAMES writes wait, reads go on, and the log restarts. */
#define CHECKPOINT_FRAMES 1000
#define WAL_GATE_NANOSECONDS 1000000000LL
#define WAL_GATE_FRAMES 4000
#define WAL_INLINE_FRAMES 16384
// On one vCPU a higher priority takes the loop's CPU for the whole pass. Nice 10 lost to nice 19 on CPU and tail in two runs.
#define CHECKPOINT_NICE 19
static sqlite3 *checkpoint_db;
static pthread_mutex_t checkpoint_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t checkpoint_cond = PTHREAD_COND_INITIALIZER;
static int checkpoint_wanted, wal_gate, wal_frames;
static uint64_t commit_number, checkpointed_commit;
static int64_t wal_gate_since;
static uint64_t stat_gates, stat_gate_timeouts, stat_inline, stat_held_most, stat_queue_most, stat_frames_most;
static int stats_on;
static int64_t stat_gate_ns, stat_gate_most_ns, stat_turn_most_ns, stat_off_cpu_most_ns, stat_off_cpu_ns, stat_commit_most_ns;
static int64_t stat_pass_most_ns, stat_passes, stat_checkpoint_cpu_ns;
static uint64_t stat_rearms;

static int64_t monotonic_nanoseconds(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (int64_t)t.tv_sec * 1000000000LL + t.tv_nsec;
}

static int64_t thread_cpu_nanoseconds(void) {
    struct timespec t;
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t);
    return (int64_t)t.tv_sec * 1000000000LL + t.tv_nsec;
}

static int wal_hook(void *arg, sqlite3 *d, const char *name, int frames) {
    (void)arg; (void)d; (void)name;
    wal_frames = frames;
    if ((uint64_t)frames > stat_frames_most) stat_frames_most = (uint64_t)frames;
    __atomic_store_n(&commit_number, commit_number + 1, __ATOMIC_RELEASE);
    if (GATE_NEXT[(wal_gate ? 8 : 0) | (frames >= WAL_GATE_FRAMES ? 4 : 0)] && !wal_gate) {
        wal_gate_since = monotonic_nanoseconds();
        __atomic_store_n(&wal_gate, 1, __ATOMIC_RELEASE);
        stat_gates++;
    }
    if (frames >= CHECKPOINT_FRAMES && !__atomic_load_n(&checkpoint_wanted, __ATOMIC_RELAXED)) {
        pthread_mutex_lock(&checkpoint_lock);
        __atomic_store_n(&checkpoint_wanted, 1, __ATOMIC_RELAXED);
        pthread_cond_signal(&checkpoint_cond);
        pthread_mutex_unlock(&checkpoint_lock);
    }
    return SQLITE_OK;
}

static void *checkpoint_main(void *arg) {
    (void)arg;
    setpriority(PRIO_PROCESS, 0, CHECKPOINT_NICE);
    for (;;) {
        pthread_mutex_lock(&checkpoint_lock);
        while (!checkpoint_wanted) pthread_cond_wait(&checkpoint_cond, &checkpoint_lock);
        __atomic_store_n(&checkpoint_wanted, 0, __ATOMIC_RELAXED);
        pthread_mutex_unlock(&checkpoint_lock);
        uint64_t seen = __atomic_load_n(&commit_number, __ATOMIC_ACQUIRE);
        int log = 0, done = 0;
        int64_t pass_start = monotonic_nanoseconds();
        int rc = sqlite3_wal_checkpoint_v2(checkpoint_db, "main", SQLITE_CHECKPOINT_PASSIVE, &log, &done);
        int64_t pass_ns = monotonic_nanoseconds() - pass_start;
        if (pass_ns > __atomic_load_n(&stat_pass_most_ns, __ATOMIC_RELAXED)) __atomic_store_n(&stat_pass_most_ns, pass_ns, __ATOMIC_RELAXED);
        __atomic_store_n(&stat_passes, stat_passes + 1, __ATOMIC_RELAXED);
        __atomic_store_n(&stat_checkpoint_cpu_ns, thread_cpu_nanoseconds(), __ATOMIC_RELAXED);
        int complete = rc == SQLITE_OK && log == done;
        if (complete) __atomic_store_n(&checkpointed_commit, seen, __ATOMIC_RELEASE);
        // No commit will wake this thread while writes are held.
        if (__atomic_load_n(&wal_gate, __ATOMIC_ACQUIRE) && (!complete || seen != __atomic_load_n(&commit_number, __ATOMIC_ACQUIRE))) {
            pthread_mutex_lock(&checkpoint_lock);
            __atomic_store_n(&checkpoint_wanted, 1, __ATOMIC_RELAXED);
            pthread_mutex_unlock(&checkpoint_lock);
        }
    }
    return 0;
}

// True once writes may go on. Every frame is in the database file, or the wait has gone on too long.
static int wal_gate_opens(void) {
    int copied = __atomic_load_n(&checkpointed_commit, __ATOMIC_ACQUIRE) == commit_number;
    int timed_out = !copied && monotonic_nanoseconds() - wal_gate_since >= WAL_GATE_NANOSECONDS;
    if (timed_out) stat_gate_timeouts++;
    return !GATE_NEXT[8 | (copied ? 2 : 0) | (timed_out ? 1 : 0)];
}

/* SQLite writes each WAL frame as two calls, the 24-byte header and then the page. This keeps the frames of a
 * commit in a buffer and writes them with one pwrite when the page of the commit frame arrives, before SQLite
 * updates the wal-index and before COMMIT returns. Readers find frames only through the wal-index, so none can
 * see a buffered frame. Idea from #245; here unix-excl's own methods are kept and only those a buffered frame
 * can affect are replaced. */
#define WAL_BUFFER_SIZE 0x1ffff // unix-excl passes at most 17 bits of a write's length
#define WAL_FRAME_HEADER 24
typedef struct {
    unsigned char *data;
    int len, commit_next;
    sqlite3_int64 start, end;
} WalBuffer;
static sqlite3_vfs *plain_vfs;
static sqlite3_vfs one_write_vfs;
static sqlite3_io_methods wal_methods;
static const sqlite3_io_methods *plain_methods;

static inline size_t wal_buffer_at(void) {
    return ((size_t)plain_vfs->szOsFile + 7) & ~(size_t)7;
}

static inline WalBuffer *wal_buffer(sqlite3_file *f) {
    return (WalBuffer *)((char *)f + wal_buffer_at());
}

static int wal_flush(sqlite3_file *f) {
    WalBuffer *b = wal_buffer(f);
    if (!b->len) return SQLITE_OK;
    int n = b->len;
    b->len = 0;
    return plain_methods->xWrite(f, b->data, n, b->start);
}

static int wal_write(sqlite3_file *f, const void *data, int n, sqlite3_int64 at) {
    WalBuffer *b = wal_buffer(f);
    int follows = at == b->end;
    b->end = at + n;
    if (n == WAL_FRAME_HEADER) {
        // Bytes 4-7 of a frame header hold the database size on a commit frame and zero on any other.
        const unsigned char *h = data;
        b->commit_next = (h[4] | h[5] | h[6] | h[7]) != 0;
    }
    if (!b->data) b->data = malloc(WAL_BUFFER_SIZE);
    int rc;
    if (!follows || !b->data || n > WAL_BUFFER_SIZE) {
        // The WAL header after a restart, or a frame rewritten in place.
        if ((rc = wal_flush(f))) return rc;
        if (n != WAL_FRAME_HEADER) b->commit_next = 0;
        return plain_methods->xWrite(f, data, n, at);
    }
    if (b->len + n > WAL_BUFFER_SIZE && (rc = wal_flush(f))) return rc;
    if (!b->len) b->start = at;
    memcpy(b->data + b->len, data, (size_t)n);
    b->len += n;
    if (n == WAL_FRAME_HEADER) return SQLITE_OK;
    if (b->commit_next) {
        b->commit_next = 0;
        return wal_flush(f);
    }
    return SQLITE_OK;
}

static int wal_read(sqlite3_file *f, void *data, int n, sqlite3_int64 at) {
    int rc = wal_flush(f);
    return rc ? rc : plain_methods->xRead(f, data, n, at);
}

static int wal_truncate(sqlite3_file *f, sqlite3_int64 size) {
    int rc = wal_flush(f);
    return rc ? rc : plain_methods->xTruncate(f, size);
}

static int wal_sync(sqlite3_file *f, int flags) {
    int rc = wal_flush(f);
    return rc ? rc : plain_methods->xSync(f, flags);
}

static int wal_file_size(sqlite3_file *f, sqlite3_int64 *size) {
    int rc = wal_flush(f);
    return rc ? rc : plain_methods->xFileSize(f, size);
}

static int wal_close(sqlite3_file *f) {
    int rc = wal_flush(f);
    free(wal_buffer(f)->data);
    int closed = plain_methods->xClose(f);
    return rc ? rc : closed;
}

static int one_write_open(sqlite3_vfs *vfs, sqlite3_filename name, sqlite3_file *f, int flags, int *out_flags) {
    (void)vfs;
    // unix-excl recognises itself by the name of the VFS it is given.
    int rc = plain_vfs->xOpen(plain_vfs, name, f, flags, out_flags);
    if (rc != SQLITE_OK || !(flags & SQLITE_OPEN_WAL)) return rc;
    if (!plain_methods) {
        // The main connection's first read gets here, before the checkpoint thread exists.
        plain_methods = f->pMethods;
        wal_methods = *plain_methods;
        wal_methods.xClose = wal_close;
        wal_methods.xRead = wal_read;
        wal_methods.xWrite = wal_write;
        wal_methods.xTruncate = wal_truncate;
        wal_methods.xSync = wal_sync;
        wal_methods.xFileSize = wal_file_size;
    }
    WalBuffer *b = wal_buffer(f);
    memset(b, 0, sizeof *b);
    b->end = -1;
    f->pMethods = &wal_methods;
    return rc;
}

static void one_write_install(void) {
    plain_vfs = sqlite3_vfs_find("unix-excl");
    if (!plain_vfs) die("the unix-excl VFS");
    one_write_vfs = *plain_vfs;
    one_write_vfs.pNext = NULL;
    one_write_vfs.szOsFile = (int)(wal_buffer_at() + sizeof(WalBuffer));
    one_write_vfs.zName = "one-write";
    one_write_vfs.xOpen = one_write_open;
    sqlite3_vfs_register(&one_write_vfs, 0);
}

static void db_open(const char *path) {
    // Only this process opens the file, so no fcntl lock is taken per transaction.
    one_write_install();
    if (sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, "one-write") != SQLITE_OK) die("open the database");
    exec("PRAGMA journal_mode = WAL");
    exec("PRAGMA synchronous = NORMAL");
    exec("PRAGMA temp_store = MEMORY");
    // A page held here needs no WAL-index lookup and no read. 32 MB beat 8 MB on CPU and tail in two runs.
    exec("PRAGMA cache_size = -32768");
    exec("PRAGMA mmap_size = 0");
    check_columns("users", "id,username,created_at");
    check_columns("posts", "id,user_id,body,created_at");
    check_columns("likes", "user_id,post_id,created_at");
    sqlite3_wal_hook(db, wal_hook, 0);
    bt = db->aDb[0].pBt;
    st_begin = prepare("BEGIN");
    st_commit = prepare("COMMIT");
    st_rollback = prepare("ROLLBACK");
    st_health = prepare("SELECT 1");
    st_insert_post = prepare("INSERT INTO posts (user_id, body) VALUES (?1, ?2)");
    st_post_time = prepare("SELECT created_at FROM posts WHERE id = ?1");
    st_like = prepare("INSERT INTO likes (user_id, post_id) SELECT ?1, ?2 WHERE EXISTS (SELECT 1 FROM posts WHERE id = ?2) ON CONFLICT (user_id, post_id) DO NOTHING");
    st_post_exists = prepare("SELECT 1 FROM posts WHERE id = ?1");
    root_posts = root_page("posts");
    root_users = root_page("users");
    root_time = root_page("posts_created_at_id_idx");
    root_likes = root_page("likes_post_id_idx");
    key_time = key_info(2, 1);
    key_likes = key_info(1, 1);
    size_t size = (size_t)sqlite3BtreeCursorSize();
    cur_posts = malloc(size);
    cur_users = malloc(size);
    cur_time = malloc(size);
    cur_likes = malloc(size);
    if (sqlite3_open_v2(path, &checkpoint_db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, "one-write") != SQLITE_OK) die("open the checkpoint connection");
    sqlite3_exec(checkpoint_db, "PRAGMA synchronous = NORMAL", 0, 0, 0);
    pthread_t thread;
    if (pthread_create(&thread, 0, checkpoint_main, 0)) die("checkpoint thread");
    pthread_detach(thread);
}

static int step_reset(sqlite3_stmt *s) {
    int rc = sqlite3_step(s);
    sqlite3_reset(s);
    return rc;
}

static int batch_begin(void) {
    if (in_batch) return 0;
    if (step_reset(st_begin) != SQLITE_DONE) return -1;
    if (sqlite3BtreeBeginTrans(bt, 0, 0) != SQLITE_OK) {
        step_reset(st_rollback);
        return -1;
    }
    in_batch = 1;
    return 0;
}

static int open_cursor(Pgno root, KeyInfo *key, BtCursor *c) {
    sqlite3BtreeCursorZero(c);
    return sqlite3BtreeCursor(bt, root, 0, key, c);
}

static int cursors_begin(void) {
    if (cursors_open) return 0;
    if (open_cursor(root_posts, 0, cur_posts) || open_cursor(root_users, 0, cur_users) || open_cursor(root_time, key_time, cur_time) || open_cursor(root_likes, key_likes, cur_likes)) return -1;
    cursors_open = 1;
    return 0;
}

static void cursors_end(void) {
    if (!cursors_open) return;
    sqlite3BtreeCloseCursor(cur_posts);
    sqlite3BtreeCloseCursor(cur_users);
    sqlite3BtreeCloseCursor(cur_time);
    sqlite3BtreeCloseCursor(cur_likes);
    cursors_open = 0;
}

static int batch_end(void) {
    cursors_end();
    if (!in_batch) return 0;
    in_batch = 0;
    int64_t commit_start = stats_on ? monotonic_nanoseconds() : 0;
    int rc = step_reset(st_commit);
    if (UNLIKELY(stats_on)) {
        int64_t commit_ns = monotonic_nanoseconds() - commit_start;
        if (commit_ns > stat_commit_most_ns) stat_commit_most_ns = commit_ns;
    }
    if (rc == SQLITE_DONE) return 0;
    step_reset(st_rollback);
    return -1;
}

typedef struct { uint64_t type; const uint8_t *p; } RowField;

static inline const uint8_t *read_varint(const uint8_t *p, const uint8_t *end, uint64_t *value) {
    uint64_t x = 0;
    for (int i = 0; i < 8; i++) {
        if (p >= end) return 0;
        x = x << 7 | (*p & 0x7f);
        if (!(*p++ & 0x80)) {
            *value = x;
            return p;
        }
    }
    if (p >= end) return 0;
    *value = x << 8 | *p++;
    return p;
}

static inline uint32_t serial_length(uint64_t type) {
    static const uint8_t lengths[12] = {0, 1, 2, 3, 4, 6, 8, 8, 0, 0, 0, 0};
    return type < 12 ? lengths[type] : (uint32_t)((type - 12) / 2);
}

static inline int decode_record(const uint8_t *record, uint32_t n, int count, RowField *columns) {
    const uint8_t *end = record + n;
    uint64_t header;
    const uint8_t *h = read_varint(record, end, &header);
    if (!h || header > n) return -1;
    const uint8_t *header_end = record + header, *body = header_end;
    for (int i = 0; i < count; i++) {
        if (h >= header_end) return -1;
        h = read_varint(h, header_end, &columns[i].type);
        if (!h) return -1;
        columns[i].p = body;
        body += serial_length(columns[i].type);
    }
    return body <= end ? 0 : -1;
}

static inline int64_t column_int(const RowField *c) {
    const uint8_t *p = c->p;
    switch (c->type) {
    case 1: return (int8_t)p[0];
    case 2: return (int16_t)((uint16_t)p[0] << 8 | p[1]);
    case 3: return (int32_t)((uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8) >> 8;
    case 4: return (int32_t)((uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]);
    case 5: return (int64_t)((uint64_t)(int16_t)((uint16_t)p[0] << 8 | p[1]) << 32 | (uint64_t)((uint32_t)p[2] << 24 | (uint32_t)p[3] << 16 | (uint32_t)p[4] << 8 | p[5]));
    case 6: {
        uint64_t v = 0;
        for (int i = 0; i < 8; i++) v = v << 8 | p[i];
        return (int64_t)v;
    }
    case 9: return 1;
    default: return 0;
    }
}

static uint8_t *spill_record;
static uint32_t spill_record_cap;

static int cursor_record(BtCursor *c, const uint8_t **record, uint32_t *n) {
    uint32_t total = sqlite3BtreePayloadSize(c), local;
    const uint8_t *p = sqlite3BtreePayloadFetch(c, &local);
    if (LIKELY(local == total)) {
        *record = p;
        *n = total;
        return 0;
    }
    if (total > spill_record_cap) {
        free(spill_record);
        spill_record_cap = total + 4096;
        spill_record = malloc(spill_record_cap);
    }
    if (sqlite3BtreePayload(c, 0, total, spill_record) != SQLITE_OK) return -1;
    *record = spill_record;
    *n = total;
    return 0;
}

static int seek_row(BtCursor *c, int64_t rowid) {
    int result;
    if (sqlite3BtreeTableMoveto(c, rowid, 0, &result) != SQLITE_OK) return -1;
    return result == 0 ? 0 : 1;
}

static int index_seek(BtCursor *c, KeyInfo *key, int64_t k) {
    Mem m;
    memset(&m, 0, sizeof m);
    m.flags = MEM_Int;
    m.u.i = k;
    UnpackedRecord r;
    memset(&r, 0, sizeof r);
    r.pKeyInfo = key;
    r.aMem = &m;
    r.nField = 1;
    r.default_rc = +1;
    int result;
    if (sqlite3BtreeIndexMoveto(c, &r, &result) != SQLITE_OK) return -1;
    if (result < 0) {
        int rc = sqlite3BtreeNext(c, 0);
        return rc == SQLITE_OK ? 0 : rc == SQLITE_DONE ? 1 : -1;
    }
    return sqlite3BtreeEof(c) ? 1 : 0;
}

// The like counts of ids[0..count), ascending, by one walk of the index when they lie close together.
static int count_likes(const int64_t *ascending, int count, int64_t *likes) {
    for (int i = 0; i < count; i++) likes[i] = 0;
    int rc = index_seek(cur_likes, key_likes, ascending[0]);
    if (rc < 0) return -1;
    if (rc > 0) return 0;
    int at = 0;
    for (;;) {
        const uint8_t *record;
        uint32_t n;
        if (cursor_record(cur_likes, &record, &n)) return -1;
        RowField column;
        if (decode_record(record, n, 1, &column)) return -1;
        int64_t post = column_int(&column);
        while (at < count && ascending[at] < post) at++;
        if (at == count) return 0;
        if (ascending[at] == post) {
            likes[at]++;
            rc = sqlite3BtreeNext(cur_likes, 0);
            if (rc == SQLITE_DONE) return 0;
            if (rc != SQLITE_OK) return -1;
            continue;
        }
        // Between two wanted posts: seek when the gap is more than the walk is worth.
        rc = index_seek(cur_likes, key_likes, ascending[at]);
        if (rc < 0) return -1;
        if (rc > 0) return 0;
    }
}

/* ---- responses ------------------------------------------------------------------------- */

static char *response_at;

static inline char *put(char *o, const char *s, size_t n) {
    memcpy(o, s, n);
    return o + n;
}
#define PUT(o, literal) put((o), (literal), sizeof(literal) - 1)

static inline char *put_int(char *o, int64_t v) {
    char digits[24];
    int n = 0;
    uint64_t u = v < 0 ? (uint64_t)-v : (uint64_t)v;
    if (v < 0) *o++ = '-';
    do {
        digits[n++] = (char)('0' + u % 10);
        u /= 10;
    } while (u);
    while (n) *o++ = digits[--n];
    return o;
}

static char *put_escaped(char *o, const uint8_t *s, uint32_t n) {
    uint32_t i = 0;
    while (i + 8 <= n) {
        uint64_t word;
        memcpy(&word, s + i, 8);
        if (word_needs_escape(word)) break;
        memcpy(o, &word, 8);
        o += 8;
        i += 8;
    }
    for (; i < n; i++) {
        uint8_t c = s[i];
        switch (ESCAPE_CLASS[c]) {
        case ESCAPE_BACKSLASH:
            *o++ = '\\';
            *o++ = (char)c;
            break;
        case ESCAPE_UNICODE: {
            static const char hex[] = "0123456789abcdef";
            o = PUT(o, "\\u00");
            *o++ = hex[c >> 4];
            *o++ = hex[c & 15];
            break;
        }
        default:
            *o++ = (char)c;
        }
    }
    return o;
}

// Writes the header just before a body already in place, so its length needs no second pass.
static void finish_response(Request *r, int status, char *body, char *end) {
    uint32_t length = (uint32_t)(end - body);
    char head[128];
    char *o = head;
    switch (status) {
    case 200: o = PUT(o, "HTTP/1.1 200 OK\r\n"); break;
    case 201: o = PUT(o, "HTTP/1.1 201 Created\r\n"); break;
    case 503: o = PUT(o, "HTTP/1.1 503 Service Unavailable\r\n"); break;
    default: o = PUT(o, "HTTP/1.1 500 Internal Server Error\r\n");
    }
    o = PUT(o, "Content-Type: application/json\r\nContent-Length: ");
    o = put_int(o, length);
    o = PUT(o, "\r\n\r\n");
    size_t n = (size_t)(o - head);
    char *start = body - n;
    memcpy(start, head, n);
    r->response = start;
    r->response_len = (uint32_t)(end - start);
    arenas[current_arena].used = (uint32_t)(end - (char *)arenas[current_arena].data);
    response_at = end;
}

#define HEADROOM 128

static char *response_body(void) { return response_at + HEADROOM; }

static const char *error_500;
static uint32_t error_500_len;

typedef struct { const char *text; uint32_t len; } Canned;
static Canned canned[E_COUNT];

static void canned_setup(void) {
    static const struct { int status; const char *reason, *message; } table[E_COUNT] = {
        FAILURE_ROW_0, FAILURE_ROW_1, FAILURE_ROW_2, FAILURE_ROW_3, FAILURE_ROW_4,
        FAILURE_ROW_5, FAILURE_ROW_6, FAILURE_ROW_7, FAILURE_ROW_8, FAILURE_ROW_9,
    };
    for (int i = 0; i < E_COUNT; i++) {
        char body[128], *text = malloc(320);
        int b = snprintf(body, sizeof body, "{\"error\":\"%s\"}", table[i].message);
        canned[i].len = (uint32_t)snprintf(text, 320, "HTTP/1.1 %d %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n%s", table[i].status, table[i].reason, b, body);
        canned[i].text = text;
    }
    error_500 = canned[E_INTERNAL].text;
    error_500_len = canned[E_INTERNAL].len;
}

static void respond_error(Request *r, int which) {
    r->kind = K_CONST;
    r->response = canned[which].text;
    r->response_len = canned[which].len;
    r->arena = -1;
}

/* Post object keys in their fixed order. */
static char *put_post(char *o, int64_t id, const RowField *post, const RowField *author, int64_t likes) {
    o = PUT(o, "{\"id\":");
    o = put_int(o, id);
    o = PUT(o, ",\"body\":\"");
    o = put_escaped(o, post[2].p, serial_length(post[2].type));
    o = PUT(o, "\",\"created_at\":\"");
    o = put(o, (const char *)post[3].p, serial_length(post[3].type));
    o = PUT(o, "\",\"author\":\"");
    o = put_escaped(o, author[1].p, serial_length(author[1].type));
    o = PUT(o, "\",\"like_count\":");
    o = put_int(o, likes);
    *o++ = '}';
    return o;
}

static int load_author(int64_t user, RowField *author) {
    if (seek_row(cur_users, user)) return -1;
    const uint8_t *record;
    uint32_t n;
    if (cursor_record(cur_users, &record, &n)) return -1;
    return decode_record(record, n, 2, author);
}

static int run_feed(Request *r) {
    if (batch_begin() || cursors_begin()) return -1;
    int64_t ids[20], likes[20], ascending[20];
    int count = 0, empty;
    if (sqlite3BtreeFirst(cur_time, &empty) != SQLITE_OK) return -1;
    while (!empty && count < 20) {
        const uint8_t *record;
        uint32_t n;
        if (cursor_record(cur_time, &record, &n)) return -1;
        RowField columns[3];
        if (decode_record(record, n, 3, columns)) return -1;
        ids[count++] = column_int(&columns[2]);
        int rc = sqlite3BtreeNext(cur_time, 0);
        if (rc == SQLITE_DONE) break;
        if (rc != SQLITE_OK) return -1;
    }
    for (int i = 0; i < count; i++) {
        int j = i;
        while (j > 0 && ascending[j - 1] > ids[i]) {
            ascending[j] = ascending[j - 1];
            j--;
        }
        ascending[j] = ids[i];
    }
    if (count && count_likes(ascending, count, likes)) return -1;
    char *body = response_body(), *o = body;
    o = PUT(o, "{\"posts\":[");
    int64_t previous = 0;
    for (int i = 0; i < count; i++) {
        int positioned = 0;
        if (previous == ids[i] + 1) {
            int rc = sqlite3BtreePrevious(cur_posts, 0);
            if (rc == SQLITE_OK && sqlite3BtreeIntegerKey(cur_posts) == ids[i]) positioned = 1;
        }
        if (!positioned && seek_row(cur_posts, ids[i])) return -1;
        previous = ids[i];
        const uint8_t *record;
        uint32_t n;
        if (cursor_record(cur_posts, &record, &n)) return -1;
        RowField post[4], author[2];
        if (decode_record(record, n, 4, post) || load_author(column_int(&post[1]), author)) return -1;
        int at = 0;
        while (ascending[at] != ids[i]) at++;
        if (i) *o++ = ',';
        o = put_post(o, ids[i], post, author, likes[at]);
    }
    o = PUT(o, "]}");
    finish_response(r, 200, body, o);
    r->arena = current_arena;
    return 0;
}

static int run_post(Request *r) {
    if (batch_begin() || cursors_begin()) return -1;
    int rc = seek_row(cur_posts, r->id);
    if (rc < 0) return -1;
    if (rc > 0) {
        respond_error(r, E_POST_MISSING);
        return 0;
    }
    const uint8_t *record;
    uint32_t n;
    if (cursor_record(cur_posts, &record, &n)) return -1;
    RowField post[4], author[2];
    if (decode_record(record, n, 4, post) || load_author(column_int(&post[1]), author)) return -1;
    int64_t likes = 0;
    if (count_likes(&r->id, 1, &likes)) return -1;
    char *body = response_body(), *o = body;
    o = PUT(o, "{\"post\":");
    o = put_post(o, r->id, post, author, likes);
    *o++ = '}';
    finish_response(r, 200, body, o);
    r->arena = current_arena;
    return 0;
}

static int run_health(Request *r) {
    char *body = response_body(), *o = body;
    int rc = sqlite3_step(st_health);
    sqlite3_reset(st_health);
    if (rc != SQLITE_ROW) {
        o = PUT(o, "{\"status\":\"degraded\",\"db\":\"unreachable\",\"error\":\"select failed\"}");
        finish_response(r, 503, body, o);
    } else {
        o = PUT(o, "{\"status\":\"ok\",\"db\":\"ok\",\"uptime_s\":");
        o = put_int(o, (int64_t)(time(0) - started_at));
        *o++ = '}';
        finish_response(r, 200, body, o);
    }
    r->arena = current_arena;
    return 0;
}

static int run_create(Request *r) {
    if (batch_begin()) return -1;
    cursors_end();
    sqlite3_bind_int64(st_insert_post, 1, r->user);
    sqlite3_bind_text(st_insert_post, 2, r->text, (int)r->text_len, SQLITE_STATIC);
    int rc = sqlite3_step(st_insert_post);
    sqlite3_reset(st_insert_post);
    if (rc != SQLITE_DONE) return -1;
    int64_t id = sqlite3_last_insert_rowid(db);
    sqlite3_bind_int64(st_post_time, 1, id);
    if (sqlite3_step(st_post_time) != SQLITE_ROW) {
        sqlite3_reset(st_post_time);
        return -1;
    }
    char *body = response_body(), *o = body;
    o = PUT(o, "{\"post\":{\"id\":");
    o = put_int(o, id);
    o = PUT(o, ",\"body\":\"");
    o = put_escaped(o, (const uint8_t *)r->text, r->text_len);
    o = PUT(o, "\",\"created_at\":\"");
    o = put(o, (const char *)sqlite3_column_text(st_post_time, 0), (size_t)sqlite3_column_bytes(st_post_time, 0));
    sqlite3_reset(st_post_time);
    o = PUT(o, "\",\"author\":\"");
    o = put_escaped(o, (const uint8_t *)r->username, r->username_len);
    o = PUT(o, "\",\"like_count\":0}}");
    finish_response(r, 201, body, o);
    r->arena = current_arena;
    return 0;
}

static int run_like(Request *r) {
    if (batch_begin()) return -1;
    cursors_end();
    sqlite3_bind_int64(st_like, 1, r->user);
    sqlite3_bind_int64(st_like, 2, r->id);
    int rc = sqlite3_step(st_like);
    sqlite3_reset(st_like);
    if (rc != SQLITE_DONE) return -1;
    int inserted = sqlite3_changes(db) > 0;
    if (!inserted) {
        sqlite3_bind_int64(st_post_exists, 1, r->id);
        rc = sqlite3_step(st_post_exists);
        sqlite3_reset(st_post_exists);
        if (rc != SQLITE_ROW) {
            respond_error(r, E_POST_MISSING);
            return 0;
        }
    }
    char *body = response_body(), *o = body;
    o = PUT(o, "{\"liked\":true,\"already_liked\":");
    o = inserted ? PUT(o, "false") : PUT(o, "true");
    o = PUT(o, ",\"post_id\":");
    o = put_int(o, r->id);
    *o++ = '}';
    finish_response(r, inserted ? 201 : 200, body, o);
    r->arena = current_arena;
    return 0;
}

/* ---- requests -------------------------------------------------------------------------- */

static int parse_id(const char *p, size_t n, int64_t *id) {
    if (!n || n > 18 || *p == '0') return -1;
    int64_t v = 0;
    for (size_t i = 0; i < n; i++) {
        if (p[i] < '0' || p[i] > '9') return -1;
        v = v * 10 + (p[i] - '0');
    }
    *id = v;
    return 0;
}

// A ring: requests leave the queue in the order they entered, so what they own is freed in that order too.
static char *scratch_alloc(size_t n) {
    uint32_t at = scratch_write;
    if (at >= scratch_tail) {
        if (at + n > SCRATCH_SIZE) {
            if (n >= scratch_tail) return NULL;
            at = 0;
        }
    } else if (at + n >= scratch_tail) {
        return NULL;
    }
    scratch_write = at + (uint32_t)n;
    return scratch + at;
}

// Verifies the signature first, then the claims. Fills the user and username, or names the failure.
static int authenticate(Request *r, const char *header, size_t n) {
    if (!header || n < 7 || memcmp(header, "Bearer ", 7)) return E_NO_BEARER;
    const char *token = header + 7;
    size_t length = n - 7;
    const char *dot1 = memchr(token, '.', length);
    if (!dot1) return E_BAD_TOKEN;
    const char *dot2 = memchr(dot1 + 1, '.', length - (size_t)(dot1 + 1 - token));
    if (!dot2 || length > 4096) return E_BAD_TOKEN;
    uint8_t signature[64], expected[32];
    size_t signature_len;
    size_t signature_text = length - (size_t)(dot2 + 1 - token);
    if (signature_text > 64 || b64_decode(dot2 + 1, signature_text, signature, &signature_len) || signature_len != 32) return E_BAD_TOKEN;
    hmac((const uint8_t *)token, (size_t)(dot2 - token), expected);
    uint8_t difference = 0;
    for (int i = 0; i < 32; i++) difference |= signature[i] ^ expected[i];
    if (difference) return E_BAD_TOKEN;
    char header_json[512];
    size_t header_len;
    if ((size_t)(dot1 - token) > 600 || b64_decode(token, (size_t)(dot1 - token), (uint8_t *)header_json, &header_len)) return E_BAD_TOKEN;
    Json alg;
    Json check = {header_json, header_json + header_len, 0};
    if (j_value(&check)) return E_BAD_TOKEN;
    j_space(&check);
    if (check.p != check.end || !j_find(header_json, header_len, "alg", &alg)) return E_BAD_TOKEN;
    if ((size_t)(alg.end - alg.p) < 7 || memcmp(alg.p, "\"HS256\"", 7)) return E_BAD_TOKEN;
    char payload[4096];
    size_t payload_len;
    if ((size_t)(dot2 - dot1 - 1) > 4096 || b64_decode(dot1 + 1, (size_t)(dot2 - dot1 - 1), (uint8_t *)payload, &payload_len)) return E_BAD_TOKEN;
    check = (Json){payload, payload + payload_len, 0};
    if (j_value(&check)) return E_BAD_TOKEN;
    j_space(&check);
    if (check.p != check.end) return E_BAD_TOKEN;
    Json exp, sub, username;
    if (!j_find(payload, payload_len, "exp", &exp)) return E_BAD_TOKEN;
    char number[32];
    size_t digits = 0;
    while (exp.p + digits < exp.end && digits < 31 && ((exp.p[digits] >= '0' && exp.p[digits] <= '9') || exp.p[digits] == '.' || exp.p[digits] == 'e' || exp.p[digits] == 'E' || exp.p[digits] == '+' || exp.p[digits] == '-')) {
        number[digits] = exp.p[digits];
        digits++;
    }
    number[digits] = 0;
    if (!digits || strtod(number, NULL) <= (double)now_seconds) return E_BAD_TOKEN;
    if (!j_find(payload, payload_len, "sub", &sub) || !j_find(payload, payload_len, "username", &username)) return E_BAD_PAYLOAD;
    char *sub_text = scratch_alloc((size_t)(sub.end - sub.p) + 1);
    uint32_t sub_len;
    if (!sub_text || j_string(&sub, sub_text, &sub_len) || parse_id(sub_text, sub_len, &r->user)) return E_BAD_PAYLOAD;
    char *name = scratch_alloc((size_t)(username.end - username.p) + 1);
    uint32_t name_len;
    if (!name || j_string(&username, name, &name_len)) return E_BAD_PAYLOAD;
    r->username = name;
    r->username_len = name_len;
    return -1;
}

static inline int js_space_at(const char *p, const char *end, int *width) {
    unsigned char c = (unsigned char)*p;
    if (c == ' ' || (c >= 9 && c <= 13)) {
        *width = 1;
        return 1;
    }
    if (c == 0xC2 && end - p >= 2 && (unsigned char)p[1] == 0xA0) {
        *width = 2;
        return 1;
    }
    if (c == 0xEF && end - p >= 3 && (unsigned char)p[1] == 0xBB && (unsigned char)p[2] == 0xBF) {
        *width = 3;
        return 1;
    }
    if (c == 0xE2 && end - p >= 3 && (unsigned char)p[1] == 0x80 && ((unsigned char)p[2] >= 0x80) && ((unsigned char)p[2] <= 0x8A || (unsigned char)p[2] == 0xA8 || (unsigned char)p[2] == 0xA9 || (unsigned char)p[2] == 0xAF)) {
        *width = 3;
        return 1;
    }
    return 0;
}

static int parse_body(Request *r, const char *body, size_t n) {
    Json j = {body, body + n, 0};
    if (j_value(&j)) return E_BAD_JSON;
    j_space(&j);
    if (j.p != j.end) return E_BAD_JSON;
    Json value;
    if (!j_find(body, n, "body", &value)) return E_NO_BODY;
    if (value.p >= value.end || *value.p != '"') return E_NO_BODY;
    char *text = scratch_alloc((size_t)(value.end - value.p) + 8);
    uint32_t length;
    if (!text) return E_INTERNAL;
    if (j_string(&value, text, &length)) return E_NO_BODY;
    const char *start = text, *end = text + length;
    int width;
    while (start < end && js_space_at(start, end, &width)) start += width;
    for (;;) {
        const char *q = end;
        int moved = 0;
        for (int back = 1; back <= 3 && q - back >= start; back++) {
            if (js_space_at(q - back, end, &width) && width == back) {
                end -= back;
                moved = 1;
                break;
            }
        }
        if (!moved) break;
    }
    if (start >= end) return E_NO_BODY;
    uint32_t characters = 0;
    for (const char *p = start; p < end; p++) characters += ((unsigned char)*p & 0xC0) != 0x80;
    if (characters > 500) return E_LONG_BODY;
    r->text = start;
    r->text_len = (uint32_t)(end - start);
    return -1;
}

static const char *find_header(const char *headers, const char *end, const char *name, size_t name_len, size_t *value_len) {
    const char *p = headers;
    while (p < end) {
        const char *line_end = memchr(p, '\n', (size_t)(end - p));
        if (!line_end) return NULL;
        if ((size_t)(line_end - p) > name_len && p[name_len] == ':' && !strncasecmp(p, name, name_len)) {
            const char *v = p + name_len + 1;
            const char *e = line_end;
            if (e > v && e[-1] == '\r') e--;
            while (v < e && (*v == ' ' || *v == '\t')) v++;
            *value_len = (size_t)(e - v);
            return v;
        }
        p = line_end + 1;
    }
    return NULL;
}

static inline int path_shape(const char *path, size_t n) {
    if (n == 5 && !memcmp(path, "/feed", 5)) return SHAPE_FEED;
    if (n == 7 && !memcmp(path, "/health", 7)) return SHAPE_HEALTH;
    if (n == 6 && !memcmp(path, "/posts", 6)) return SHAPE_POSTS;
    if (n > 7 && !memcmp(path, "/posts/", 7)) {
        const char *rest = path + 7;
        size_t rest_len = n - 7;
        if (!memchr(rest, '/', rest_len)) return SHAPE_POST_ID;
        if (rest_len > 5 && !memcmp(rest + rest_len - 5, "/like", 5)) return SHAPE_POST_LIKE;
    }
    return SHAPE_UNKNOWN;
}

// Routes one complete request. Returns its total length, 0 when more bytes are needed.
static uint32_t parse_request(Request *r, const char *data, uint32_t n) {
    const char *end = memmem(data, n, "\r\n\r\n", 4);
    if (!end) return 0;
    const char *headers = memchr(data, '\n', (size_t)(end - data) + 2);
    headers = headers ? headers + 1 : end;
    size_t length_len = 0;
    const char *length_text = find_header(headers, end + 2, "content-length", 14, &length_len);
    uint64_t content = length_text ? strtoul(length_text, NULL, 10) : 0;
    uint64_t total = (uint64_t)(end + 4 - data) + content;
    if (total > n) return 0;
    const char *body = end + 4;
    size_t connection_len = 0;
    const char *connection = find_header(headers, end + 2, "connection", 10, &connection_len);
    r->close = connection && connection_len == 5 && !strncasecmp(connection, "close", 5);
    r->arena = -1;
    r->failed = 0;
    const char *space = memchr(data, ' ', (size_t)(end - data));
    if (!space) {
        respond_error(r, E_NOT_FOUND);
        return total;
    }
    size_t method_len = (size_t)(space - data);
    const char *path = space + 1;
    const char *path_end = memchr(path, ' ', (size_t)(end - path));
    if (!path_end) {
        respond_error(r, E_NOT_FOUND);
        return total;
    }
    const char *query = memchr(path, '?', (size_t)(path_end - path));
    if (query) path_end = query;
    size_t path_len = (size_t)(path_end - path);
    int method = method_len == 3 && !memcmp(data, "GET", 3) ? METHOD_GET : method_len == 4 && !memcmp(data, "POST", 4) ? METHOD_POST : METHOD_OTHER;
    int route = ROUTE_OF[method][path_shape(path, path_len)];
    if (ROUTE_NEEDS_TOKEN[route]) {
        size_t auth_len = 0;
        const char *auth = find_header(headers, end + 2, "authorization", 13, &auth_len);
        int failure = authenticate(r, auth, auth_len);
        if (failure >= 0) {
            respond_error(r, failure);
            return total;
        }
    }
    switch (route) {
    case ROUTE_FEED:
        r->kind = K_FEED;
        break;
    case ROUTE_HEALTH:
        r->kind = K_HEALTH;
        break;
    case ROUTE_POST:
        if (parse_id(path + 7, path_len - 7, &r->id)) respond_error(r, E_BAD_ID);
        else r->kind = K_POST;
        break;
    case ROUTE_LIKE:
        if (parse_id(path + 7, path_len - 12, &r->id)) respond_error(r, E_BAD_ID);
        else r->kind = K_LIKE;
        break;
    case ROUTE_CREATE: {
        int failure = parse_body(r, body, content);
        if (failure >= 0) respond_error(r, failure);
        else r->kind = K_CREATE;
        break;
    }
    default:
        respond_error(r, E_NOT_FOUND);
    }
    return total;
}

/* ---- the ring -------------------------------------------------------------------------- */

static struct io_uring_sqe *next_sqe(Ring *ring) {
    struct io_uring_sqe *s = io_uring_get_sqe(&ring->ring);
    while (UNLIKELY(!s)) {
        io_uring_submit(&ring->ring);
        s = io_uring_get_sqe(&ring->ring);
    }
    ring->pending_sqes++;
    return s;
}

// A ring that can't be made costs the connections it would have held, not the ones already open.
static int ring_setup(int index) {
    Ring *ring = &rings[index];
    struct io_uring_params params;
    memset(&params, 0, sizeof params);
    params.flags = IORING_SETUP_CQSIZE | IORING_SETUP_COOP_TASKRUN | IORING_SETUP_SUBMIT_ALL;
    params.cq_entries = RING_COMPLETIONS;
    int rc = io_uring_queue_init_params(RING_ENTRIES, &ring->ring, &params);
    if (rc < 0) {
        fprintf(stderr, "ring %d, io_uring_queue_init: %s\n", index, strerror(-rc));
        return -1;
    }
    rc = io_uring_register_files_sparse(&ring->ring, table_size);
    if (rc < 0) {
        fprintf(stderr, "ring %d, register_files_sparse(%u): %s\n", index, table_size, strerror(-rc));
        io_uring_queue_exit(&ring->ring);
        return -1;
    }
    ring->buffers = mmap(NULL, BUFFER_COUNT * sizeof(struct io_uring_buf), PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_POPULATE, -1, 0);
    if (ring->buffers == MAP_FAILED) {
        fprintf(stderr, "ring %d, buffer ring memory\n", index);
        io_uring_queue_exit(&ring->ring);
        return -1;
    }
    io_uring_buf_ring_init(ring->buffers);
    struct io_uring_buf_reg registration;
    memset(&registration, 0, sizeof registration);
    registration.ring_addr = (uint64_t)(uintptr_t)ring->buffers;
    registration.ring_entries = BUFFER_COUNT;
    registration.bgid = BUFFER_GROUP;
    rc = io_uring_register_buf_ring(&ring->ring, &registration, 0);
    if (rc == -EINVAL) {
        // Ubuntu's 6.8.0-136 and later invert a reserved-field check (Launchpad #2162843, found by #245).
        registration.resv[0] = 1;
        rc = io_uring_register_buf_ring(&ring->ring, &registration, 0);
    }
    if (rc < 0) {
        fprintf(stderr, "ring %d, buffer ring: %s\n", index, strerror(-rc));
        io_uring_queue_exit(&ring->ring);
        return -1;
    }
    if (index > 0 && io_uring_register_eventfd(&ring->ring, wake_fd) < 0) {
        fprintf(stderr, "ring %d, register eventfd\n", index);
        io_uring_queue_exit(&ring->ring);
        return -1;
    }
    ring->conns = calloc(table_size, sizeof(Conn));
    ring->read_queue = malloc(table_size * sizeof(uint32_t));
    ring->memory = aligned_alloc(4096, BUFFER_COUNT * BUFFER_SIZE);
    if (!ring->conns || !ring->read_queue || !ring->memory) die("ring memory");
    memset(ring->memory, 0, BUFFER_COUNT * BUFFER_SIZE);
    for (int i = 0; i < BUFFER_COUNT; i++) io_uring_buf_ring_add(ring->buffers, ring->memory + i * BUFFER_SIZE, BUFFER_SIZE, (unsigned short)i, BUFFER_COUNT - 1, i);
    io_uring_buf_ring_advance(ring->buffers, BUFFER_COUNT);
    ring->table = table_size;
    ring->ready = 1;
    return 0;
}

static void arm_accepts(int index) {
    Ring *ring = &rings[index];
    for (int i = 0; i < ACCEPT_LISTENERS; i++) {
        struct io_uring_sqe *s = next_sqe(ring);
        io_uring_prep_multishot_accept_direct(s, listeners[i], NULL, NULL, 0);
        io_uring_sqe_set_data64(s, encode(OP_ACCEPT, index, 0, (uint32_t)i));
    }
    ring->accepting = 1;
    fprintf(stderr, "accepting on ring %d\n", index);
}

static void stop_accepts(int index) {
    Ring *ring = &rings[index];
    for (int i = 0; i < ACCEPT_LISTENERS; i++) {
        struct io_uring_sqe *s = next_sqe(ring);
        io_uring_prep_cancel64(s, encode(OP_ACCEPT, index, 0, (uint32_t)i), 0);
        io_uring_sqe_set_data64(s, encode(OP_IGNORE, index, 0, 0));
    }
    ring->accepting = 0;
}

// A completion carries the slot's generation, because it can arrive after the slot has a new connection.
static void arm_recv(int index, uint32_t slot) {
    Ring *ring = &rings[index];
    Conn *c = &ring->conns[slot];
    struct io_uring_sqe *s = next_sqe(ring);
    io_uring_prep_recv_multishot(s, (int)slot, NULL, 0, 0);
    s->flags |= IOSQE_FIXED_FILE | IOSQE_BUFFER_SELECT;
    s->buf_group = BUFFER_GROUP;
    io_uring_sqe_set_data64(s, encode(OP_RECV, index, c->generation, slot));
    c->armed = ARMED_MULTISHOT;
}

static void close_conn(int index, uint32_t slot) {
    Ring *ring = &rings[index];
    Conn *c = &ring->conns[slot];
    if (c->state != C_OPEN) return;
    c->state = C_CLOSING;
    if (c->spill) {
        free(c->spill);
        c->spill = NULL;
        c->spill_len = 0;
    }
    // The shutdown ends the armed receive, which would otherwise keep the socket alive after its slot is closed.
    struct io_uring_sqe *s = next_sqe(ring);
    io_uring_prep_shutdown(s, (int)slot, SHUT_RDWR);
    s->flags |= IOSQE_FIXED_FILE | IOSQE_CQE_SKIP_SUCCESS | IOSQE_IO_LINK | IOSQE_IO_HARDLINK;
    io_uring_sqe_set_data64(s, encode(OP_IGNORE, index, 0, 0));
    s = next_sqe(ring);
    io_uring_prep_close_direct(s, slot);
    io_uring_sqe_set_data64(s, encode(OP_CLOSE, index, 0, slot));
}

static void return_buffer(int index, uint16_t id) {
    Ring *ring = &rings[index];
    io_uring_buf_ring_add(ring->buffers, ring->memory + (size_t)id * BUFFER_SIZE, BUFFER_SIZE, id, BUFFER_COUNT - 1, 0);
    io_uring_buf_ring_advance(ring->buffers, 1);
}

static void queue_read(int index, uint32_t slot) {
    Ring *ring = &rings[index];
    Conn *c = &ring->conns[slot];
    if (c->queued || c->state != C_OPEN) return;
    c->queued = 1;
    ring->read_queue[ring->queued++] = slot;
}

static void take_bytes(int index, uint32_t slot, const char *data, uint32_t n, int buffer);

// Reads what the receives that ended left behind, mostly because the buffers ran out after a stall. Re-arming them all at
// once ran the buffers dry again on a real droplet (#264), so single reads, half the buffers at a time, until each socket
// is empty. Only then is its multishot receive armed again.
static int issue_reads(void) {
    int issued = 0;
    for (int index = 0; index < ring_count; index++) {
        Ring *ring = &rings[index];
        uint32_t n = ring->queued < BUFFER_COUNT / 2 ? ring->queued : BUFFER_COUNT / 2;
        for (uint32_t i = 0; i < n; i++) {
            uint32_t slot = ring->read_queue[i];
            Conn *c = &ring->conns[slot];
            c->queued = 0;
            if (c->state != C_OPEN) continue;
            if (!c->armed) {
                struct io_uring_sqe *s = next_sqe(ring);
                io_uring_prep_recv(s, (int)slot, NULL, BUFFER_SIZE, MSG_DONTWAIT);
                s->flags |= IOSQE_FIXED_FILE | IOSQE_BUFFER_SELECT;
                s->buf_group = BUFFER_GROUP;
                io_uring_sqe_set_data64(s, encode(OP_RECV, index, c->generation, slot));
                c->armed = ARMED_ONCE;
                issued++;
            }
            // Bytes left in a spill when the queue was full wait for no new read.
            if (c->spill) take_bytes(index, slot, (const char *)ring->memory, 0, -1);
        }
        if (n < ring->queued) memmove(ring->read_queue, ring->read_queue + n, (ring->queued - n) * sizeof(uint32_t));
        ring->queued -= n;
    }
    return issued;
}

static void submit_all(void) {
    for (int index = 0; index < ring_count; index++) {
        Ring *ring = &rings[index];
        if (ring->pending_sqes) {
            io_uring_submit(&ring->ring);
            ring->pending_sqes = 0;
        }
    }
}

static int active_ring, out_of_rings;

static void on_accept(int index, struct io_uring_cqe *cqe) {
    Ring *ring = &rings[index];
    if (cqe->res >= 0) {
        uint32_t slot = (uint32_t)cqe->res;
        ring->conns[slot].state = C_OPEN;
        ring->open++;
        arm_recv(index, slot);
        uint32_t margin = ring->table / 8 < 4096 ? ring->table / 8 : 4096;
        if (index == active_ring && ring->open + 2 * margin >= ring->table && active_ring + 1 < MAX_RINGS && !out_of_rings) {
            if (rings[active_ring + 1].ready || ring_setup(active_ring + 1) == 0) {
                if (ring_count < active_ring + 2) ring_count = active_ring + 2;
                active_ring++;
                arm_accepts(active_ring);
            } else {
                out_of_rings = 1;
            }
        }
        if (ring->accepting && ring->open + margin >= ring->table) stop_accepts(index);
    }
    if (!(cqe->flags & IORING_CQE_F_MORE) && ring->accepting) {
        uint32_t listener = (uint32_t)(io_uring_cqe_get_data64(cqe) & 0xffffffff);
        struct io_uring_sqe *s = next_sqe(ring);
        io_uring_prep_multishot_accept_direct(s, listeners[listener], NULL, NULL, 0);
        io_uring_sqe_set_data64(s, encode(OP_ACCEPT, index, 0, listener));
    }
}

static void run_batch(void);

static void take_bytes(int index, uint32_t slot, const char *data, uint32_t n, int buffer) {
    Ring *ring = &rings[index];
    Conn *c = &ring->conns[slot];
    const char *view = data;
    uint32_t have = n;
    if (c->spill) {
        if (c->spill_len + n > SPILL_CAP) {
            if (buffer >= 0) return_buffer(index, (uint16_t)buffer);
            close_conn(index, slot);
            return;
        }
        memcpy(c->spill + c->spill_len, data, n);
        c->spill_len += n;
        view = (const char *)c->spill;
        have = c->spill_len;
    }
    uint32_t at = 0;
    int kept_buffer = 0, stranded = 0;
    while (at < have) {
        // Bytes left in a spill wait for the next read, which never comes if the client is waiting too.
        if (UNLIKELY(request_count == MAX_REQUESTS)) {
            run_batch();
            if (request_head) {
                memmove(requests, requests + request_head, (request_count - request_head) * sizeof(Request));
                request_count -= request_head;
                request_head = 0;
            }
            if (request_count == MAX_REQUESTS) {
                stranded = 1;
                break;
            }
        }
        Request *r = &requests[request_count];
        memset(r, 0, sizeof *r);
        uint32_t used = parse_request(r, view + at, have - at);
        if (!used) break;
        r->ring = (uint8_t)index;
        r->slot = slot;
        r->buffer = 0xffff;
        r->generation = c->generation;
        r->scratch_end = scratch_write;
        request_count++;
        at += used;
        kept_buffer = 1;
    }
    (void)kept_buffer;
    uint32_t left = have - at;
    if (left) {
        if (!c->spill) {
            c->spill = malloc(SPILL_CAP);
            if (!c->spill) die("spill");
            memcpy(c->spill, view + at, left);
        } else if (at) {
            memmove(c->spill, c->spill + at, left);
        }
        c->spill_len = left;
    } else if (c->spill) {
        free(c->spill);
        c->spill = NULL;
        c->spill_len = 0;
    }
    if (buffer >= 0) return_buffer(index, (uint16_t)buffer);
    if (stranded) queue_read(index, slot);
}

static int drain_ring(int index) {
    Ring *ring = &rings[index];
    struct io_uring_cqe *cqe;
    unsigned head, seen = 0;
    io_uring_for_each_cqe(&ring->ring, head, cqe) {
        seen++;
        uint64_t data = io_uring_cqe_get_data64(cqe);
        int op = (int)(data >> 56);
        int arena = (int)(int8_t)(uint8_t)(data >> 40);
        uint32_t slot = (uint32_t)(data & 0xffffffff);
        Conn *c = &ring->conns[slot];
        switch (op) {
        case OP_ACCEPT:
            on_accept(index, cqe);
            break;
        case OP_RECV: {
            int has_buffer = (cqe->flags & IORING_CQE_F_BUFFER) != 0;
            uint16_t id = (uint16_t)(cqe->flags >> IORING_CQE_BUFFER_SHIFT);
            // From a connection this slot no longer holds.
            if (c->state != C_OPEN || (uint8_t)arena != (uint8_t)c->generation) {
                if (has_buffer) return_buffer(index, id);
                break;
            }
            int ended = !(cqe->flags & IORING_CQE_F_MORE);
            int was_single_read = c->armed == ARMED_ONCE;
            if (ended) c->armed = 0;
            if (cqe->res > 0 && has_buffer) {
                take_bytes(index, slot, (const char *)ring->memory + (size_t)id * BUFFER_SIZE, (uint32_t)cqe->res, (int)id);
                if (ended) {
                    if (was_single_read && cqe->res < BUFFER_SIZE) {
                        if (c->state == C_OPEN) arm_recv(index, slot);
                    } else {
                        queue_read(index, slot);
                    }
                }
            } else {
                if (has_buffer) return_buffer(index, id);
                if (cqe->res == -EAGAIN && was_single_read) {
                    arm_recv(index, slot);
                } else if (cqe->res == -ENOBUFS || cqe->res == -EAGAIN) {
                    stat_rearms++;
                    queue_read(index, slot);
                } else {
                    close_conn(index, slot);
                }
            }
            break;
        }
        case OP_SEND:
            if (arena >= 0) arenas[arena].pending--;
            // From a connection this slot no longer holds.
            if ((uint8_t)(data >> 32) != (uint8_t)c->generation) break;
            if (c->sends) c->sends--;
            if (cqe->res < 0 || (c->close_after && !c->sends)) close_conn(index, slot);
            break;
        case OP_CLOSE:
            c->state = C_FREE;
            c->queued = 0;
            c->close_after = 0;
            c->sends = 0;
            c->held = 0;
            c->armed = 0;
            c->generation++;
            if (ring->open) ring->open--;
            break;
        default:
            break;
        }
    }
    io_uring_cq_advance(&ring->ring, seen);
    return (int)seen;
}

static uint64_t batch_number;

// pending only counts sends already prepared, so an arena filled earlier in this batch looks free unless marked.
static int choose_arena(void) {
    if (arenas[current_arena].used + RESPONSE_RESERVE * 2 < ARENA_SIZE) {
        response_at = (char *)arenas[current_arena].data + arenas[current_arena].used;
        arenas[current_arena].batch = batch_number;
        return 1;
    }
    for (int i = 1; i <= ARENAS; i++) {
        int next = (current_arena + i) % ARENAS;
        if (arenas[next].pending == 0 && arenas[next].batch != batch_number) {
            current_arena = next;
            arenas[next].used = 0;
            arenas[next].batch = batch_number;
            response_at = (char *)arenas[next].data;
            return 1;
        }
    }
    return 0;
}

static int response_room(void) {
    if (LIKELY((char *)arenas[current_arena].data + ARENA_SIZE - response_at >= RESPONSE_RESERVE)) return 1;
    return choose_arena();
}

static void prepare_send(Request *r) {
    Ring *ring = &rings[r->ring];
    Conn *c = &ring->conns[r->slot];
    // A request waiting in a queue can outlive its connection, and the slot can already hold a new one.
    if (c->state != C_OPEN || c->generation != r->generation) return;
    struct io_uring_sqe *s = next_sqe(ring);
    io_uring_prep_send(s, (int)r->slot, r->response, r->response_len, MSG_WAITALL | MSG_NOSIGNAL);
    s->flags |= IOSQE_FIXED_FILE;
    io_uring_sqe_set_data64(s, encode(OP_SEND, r->ring, r->arena, r->slot) | (uint64_t)(uint8_t)c->generation << 32);
    if (r->arena >= 0) arenas[r->arena].pending++;
    c->sends++;
    if (r->close) c->close_after = 1;
}

static void hold_request(Request *r) {
    Request *h = &held[held_count++];
    *h = *r;
    // What it owns in the scratch ring would otherwise block everything queued behind it.
    size_t total = (size_t)r->username_len + r->text_len;
    if (total) {
        h->owned = malloc(total);
        if (!h->owned) die("held request");
        if (r->username_len) memcpy(h->owned, r->username, r->username_len);
        if (r->text_len) memcpy(h->owned + r->username_len, r->text, r->text_len);
        if (r->username_len) h->username = h->owned;
        if (r->text_len) h->text = h->owned + r->username_len;
    }
    Conn *c = &rings[r->ring].conns[r->slot];
    if (c->generation == r->generation) c->held++;
    r->kind = K_HELD;
    if (held_count > stat_held_most) stat_held_most = held_count;
}

static inline int should_hold(const Request *r) {
    if (r->kind == K_HELD) return 0;
    const Conn *c = &rings[r->ring].conns[r->slot];
    int room = held_count < HOLD_CAP;
    int gate_closed = __atomic_load_n(&wal_gate, __ATOMIC_RELAXED);
    int write = r->kind == K_CREATE || r->kind == K_LIKE;
    int connection_held = c->held && c->generation == r->generation;
    return SHOULD_HOLD[(room ? 8 : 0) | (gate_closed ? 4 : 0) | (write ? 2 : 0) | (connection_held ? 1 : 0)];
}

static int batch_phase = PHASE_IDLE;

// The certified tables decide what follows each step of a batch, and only their answers lead to a send.
static inline int batch_step(int event) {
    int action = ACTION_OF[batch_phase][event];
    batch_phase = NEXT_PHASE[batch_phase][event];
    return action;
}

// One SQLite transaction: reads from the batch's snapshot, then writes, then COMMIT, then every response.
// When response memory runs out, the requests past that point wait for the next batch, in order.
static uint32_t run_list(Request *list, uint32_t count, int may_hold) {
    uint32_t limit = count;
    batch_step(EVENT_REQUEST);
    for (uint32_t i = 0; i < limit; i++) {
        Request *r = &list[i];
        if (UNLIKELY(may_hold) && should_hold(r)) {
            hold_request(r);
            continue;
        }
        if (UNLIKELY(!response_room())) {
            limit = i;
            break;
        }
        int rc = 0;
        switch (r->kind) {
        case K_FEED: rc = run_feed(r); break;
        case K_POST: rc = run_post(r); break;
        case K_HEALTH: rc = run_health(r); break;
        default: break;
        }
        if (rc) respond_error(r, E_INTERNAL);
    }
    for (uint32_t i = 0; i < limit; i++) {
        Request *r = &list[i];
        // Only a write needs room here. Cutting at a read would throw away what the first pass answered.
        if ((r->kind == K_CREATE || r->kind == K_LIKE) && UNLIKELY(!response_room())) {
            limit = i;
            break;
        }
        int rc = 0;
        switch (r->kind) {
        case K_CREATE: rc = run_create(r); break;
        case K_LIKE: rc = run_like(r); break;
        default: break;
        }
        if (rc) {
            respond_error(r, E_INTERNAL);
            r->failed = 1;
        }
    }
    int commit_failed = batch_step(EVENT_BATCH_END) != ACTION_COMMIT || batch_end();
    int action = batch_step(commit_failed ? EVENT_COMMIT_FAIL : EVENT_COMMIT_OK);
    if (UNLIKELY(action != ACTION_SEND_ALL && action != ACTION_FAIL_ALL)) die("a batch ended without a send or a failure");
    for (uint32_t i = 0; i < limit; i++) {
        Request *r = &list[i];
        if (r->kind == K_HELD) continue;
        if (action == ACTION_FAIL_ALL && r->kind != K_CONST) respond_error(r, E_INTERNAL);
        prepare_send(r);
    }
    return limit;
}

static void run_batch(void) {
    uint32_t queued = request_count - request_head;
    if (!queued && !held_count) return;
    batch_number++;
    if (!choose_arena()) return;
    if (UNLIKELY(wal_gate) && wal_gate_opens()) {
        int64_t gate_ns = monotonic_nanoseconds() - wal_gate_since;
        stat_gate_ns += gate_ns;
        if (gate_ns > stat_gate_most_ns) stat_gate_most_ns = gate_ns;
        __atomic_store_n(&wal_gate, 0, __ATOMIC_RELEASE);
    }
    if (UNLIKELY(wal_frames >= WAL_INLINE_FRAMES)) {
        // Last resort: the checkpoint thread is too far behind for the log to stay in memory.
        sqlite3_wal_checkpoint_v2(db, "main", SQLITE_CHECKPOINT_PASSIVE, NULL, NULL);
        wal_frames = 0;
        stat_inline++;
    }
    if (UNLIKELY(held_count && !wal_gate)) {
        uint32_t done = run_list(held, held_count < BATCH_ANSWERS ? held_count : BATCH_ANSWERS, 0);
        for (uint32_t i = 0; i < done; i++) {
            Conn *c = &rings[held[i].ring].conns[held[i].slot];
            if (c->held && c->generation == held[i].generation) c->held--;
            free(held[i].owned);
        }
        held_count -= done;
        if (held_count) memmove(held, held + done, held_count * sizeof(Request));
        submit_all();
        return;
    }
    if (!queued) return;
    if (queued > stat_queue_most) stat_queue_most = queued;
    uint32_t done = run_list(requests + request_head, queued < BATCH_ANSWERS ? queued : BATCH_ANSWERS, wal_gate || held_count);
    request_head += done;
    if (request_head == request_count) {
        request_head = request_count = 0;
        scratch_write = scratch_tail = 0;
    } else if (done) {
        scratch_tail = requests[request_head - 1].scratch_end;
    }
    submit_all();
}

static void listen_all(const char *host, int port) {
    for (int i = 0; i < ACCEPT_LISTENERS; i++) {
        int fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
        if (fd < 0) die("socket");
        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof one);
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
        struct sockaddr_in address = {.sin_family = AF_INET, .sin_port = htons((uint16_t)port)};
        if (inet_pton(AF_INET, host, &address.sin_addr) != 1) die("HOST is not an IPv4 address");
        if (bind(fd, (struct sockaddr *)&address, sizeof address)) die("bind");
        if (listen(fd, 65535)) die("listen");
        listeners[i] = fd;
    }
}

/* ---- profile training, used only by build.sh ------------------------------------------- */

static void train_database(const char *path) {
    sqlite3 *d;
    if (sqlite3_open(path, &d) != SQLITE_OK) die("training database");
    const char *sql =
        "PRAGMA journal_mode = WAL;"
        "CREATE TABLE users (id INTEGER PRIMARY KEY, username TEXT NOT NULL UNIQUE, created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')));"
        "CREATE TABLE posts (id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL REFERENCES users(id), body TEXT NOT NULL CHECK (length(body) BETWEEN 1 AND 500), created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')));"
        "CREATE TABLE likes (user_id INTEGER NOT NULL REFERENCES users(id), post_id INTEGER NOT NULL REFERENCES posts(id), created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')), PRIMARY KEY (user_id, post_id));"
        "CREATE INDEX posts_created_at_id_idx ON posts (created_at DESC, id DESC);"
        "CREATE INDEX posts_user_id_idx ON posts (user_id);"
        "CREATE INDEX likes_post_id_idx ON likes (post_id);"
        "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 5000) INSERT INTO users (id, username) SELECT i, 'user' || i FROM n;"
        "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 50000) INSERT INTO posts (id, user_id, body, created_at) SELECT i, 1 + i % 5000, 'user' || i || ' says hi at 2026-11-01T21:50:40.123Z (VU ' || i || ', iter 3)', strftime('%Y-%m-%dT%H:%M:%fZ', '2026-01-01', '+' || i || ' seconds') FROM n;"
        "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 200000) INSERT OR IGNORE INTO likes (user_id, post_id) SELECT 1 + i % 5000, 1 + (i * 7919) % 50000 FROM n;"
        "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 3000) INSERT OR IGNORE INTO likes (user_id, post_id) SELECT 1 + i % 5000, 50000 - i % 20 FROM n;";
    char *error = 0;
    if (sqlite3_exec(d, sql, 0, 0, &error) != SQLITE_OK) {
        fprintf(stderr, "training database: %s\n", error);
        exit(1);
    }
    sqlite3_close(d);
}

static size_t b64_encode(const uint8_t *in, size_t n, char *out) {
    const char *alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    size_t w = 0;
    uint32_t acc = 0;
    int bits = 0;
    for (size_t i = 0; i < n; i++) {
        acc = acc << 8 | in[i];
        bits += 8;
        while (bits >= 6) {
            bits -= 6;
            out[w++] = alphabet[(acc >> bits) & 63];
        }
    }
    if (bits) out[w++] = alphabet[(acc << (6 - bits)) & 63];
    return w;
}

static size_t train_token(int user, char *out) {
    const char *head = "{\"alg\":\"HS256\",\"typ\":\"JWT\"}";
    char payload[128];
    int p = snprintf(payload, sizeof payload, "{\"sub\":\"%d\",\"username\":\"user%d\",\"iat\":1700000000,\"exp\":4000000000}", user, user);
    size_t n = b64_encode((const uint8_t *)head, strlen(head), out);
    out[n++] = '.';
    n += b64_encode((const uint8_t *)payload, (size_t)p, out + n);
    uint8_t signature[32];
    hmac((const uint8_t *)out, n, signature);
    out[n++] = '.';
    n += b64_encode(signature, 32, out + n);
    return n;
}

static void train_client(int port, int total) {
    enum { CLIENTS = 256 };
    int fds[CLIENTS];
    static char buffer[262144];
    usleep(200000);
    for (int i = 0; i < CLIENTS; i++) {
        fds[i] = socket(AF_INET, SOCK_STREAM, 0);
        struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons((uint16_t)port), .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
        if (connect(fds[i], (struct sockaddr *)&a, sizeof a)) die("training connect");
    }
    for (int sent = 0; sent < total;) {
        for (int i = 0; i < CLIENTS; i++, sent++) {
            char text[2048], token[512];
            int n, r = sent % 100;
            int post = 1 + (sent * 31) % 50000;
            size_t t;
            const char *common = "Host: bench\r\nUser-Agent: profile-training\r\n";
            if (r < 46) {
                n = snprintf(text, sizeof text, "GET /feed HTTP/1.1\r\n%s\r\n", common);
            } else if (r < 92) {
                n = snprintf(text, sizeof text, "GET /posts/%d HTTP/1.1\r\n%s\r\n", post, common);
            } else if (r < 99) {
                t = train_token(1 + sent % 5000, token);
                n = snprintf(text, sizeof text, "POST /posts/%d/like HTTP/1.1\r\n%sAuthorization: Bearer %.*s\r\nContent-Type: application/json\r\nContent-Length: 0\r\n\r\n", 50000 - sent % 20, common, (int)t, token);
            } else {
                t = train_token(1 + sent % 5000, token);
                char body[128];
                int b = snprintf(body, sizeof body, "{\"body\":\"user says hi at 2026-11-01T21:50:40.123Z (VU %d, iter 1)\"}", sent);
                n = snprintf(text, sizeof text, "POST /posts HTTP/1.1\r\n%sAuthorization: Bearer %.*s\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n%s", common, (int)t, token, b, body);
            }
            if (send(fds[i], text, (size_t)n, MSG_NOSIGNAL) != n) die("training send");
        }
        for (int i = 0; i < CLIENTS; i++) {
            size_t have = 0, need = 0;
            for (;;) {
                ssize_t got = recv(fds[i], buffer + have, sizeof buffer - have, 0);
                if (got <= 0) die("training recv");
                have += (size_t)got;
                char *end = memmem(buffer, have, "\r\n\r\n", 4);
                if (!end) continue;
                size_t length_len;
                const char *length = find_header(buffer, end + 2, "content-length", 14, &length_len);
                need = (size_t)(end + 4 - buffer) + (length ? strtoul(length, NULL, 10) : 0);
                if (have >= need) break;
            }
        }
    }
    kill(getppid(), SIGTERM);
    _exit(0);
}

static void train_stop(int signal_number) {
    (void)signal_number;
    exit(0);
}

// With no swap, file-backed pages are all reclaim can take at the memory wall, and the loop would stall reading
// its own code back from disk. Best effort, since the limit is 8 MiB under systemd.
static void lock_code(void) {
    char exe[512], line[1024];
    ssize_t n = readlink("/proc/self/exe", exe, sizeof exe - 1);
    FILE *maps = fopen("/proc/self/maps", "r");
    if (n <= 0 || !maps) {
        if (maps) fclose(maps);
        return;
    }
    exe[n] = 0;
    while (fgets(line, sizeof line, maps)) {
        unsigned long low, high;
        int at = 0;
        if (sscanf(line, "%lx-%lx %*s %*s %*s %*s %n", &low, &high, &at) < 2 || !at) continue;
        line[strcspn(line, "\n")] = 0;
        if (!strcmp(line + at, exe) && mlock((void *)low, high - low)) fprintf(stderr, "mlock: %s\n", strerror(errno));
    }
    fclose(maps);
}

int main(void) {
    const char *path = getenv("SQLITE_PATH"), *secret = getenv("JWT_SECRET"), *host = getenv("HOST"), *port = getenv("PORT");
    const char *train = getenv("SERVER_PROFILE_TRAINING");
    if (!path || !secret) die("SQLITE_PATH and JWT_SECRET are required");
    if (train) {
        train_database(path);
        signal(SIGTERM, train_stop);
    } else {
        lock_code();
    }
    struct rlimit nofile;
    getrlimit(RLIMIT_NOFILE, &nofile);
    nofile.rlim_cur = nofile.rlim_max;
    setrlimit(RLIMIT_NOFILE, &nofile);
    table_size = nofile.rlim_cur > 65536 ? 65471 : (uint32_t)nofile.rlim_cur - 64;
    started_at = time(0);
    b64_setup();
    hmac_setup(secret);
    canned_setup();
    db_open(path);
    scratch = malloc(SCRATCH_SIZE);
    for (int i = 0; i < ARENAS; i++) {
        arenas[i].data = aligned_alloc(4096, ARENA_SIZE);
        if (!arenas[i].data) die("arena");
        memset(arenas[i].data, 0, ARENA_SIZE);
    }
    response_at = (char *)arenas[0].data;
    listen_all(host ? host : "127.0.0.1", port ? atoi(port) : 3000);
    if (train && fork() == 0) train_client(port ? atoi(port) : 3000, atoi(train));
    wake_fd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
    if (ring_setup(0)) die("the first ring");
    ring_count = 1;
    arm_accepts(0);
    struct io_uring_sqe *wake = next_sqe(&rings[0]);
    io_uring_prep_poll_multishot(wake, wake_fd, POLLIN);
    io_uring_sqe_set_data64(wake, encode(OP_WAKE, 0, 0, 0));
    submit_all();
    fprintf(stderr, "listening, %u connections per ring\n", table_size);
    struct __kernel_timespec timeout = {.tv_sec = 0, .tv_nsec = WAIT_NANOSECONDS};
    uint64_t next_stats = 0;
    stats_on = getenv("SERVER_STATS") != NULL;
    memset(requests, 0, sizeof requests);
    for (;;) {
        struct io_uring_cqe *cqe;
        // A backlog is work already in hand, so there is nothing to wait for.
        io_uring_submit_and_wait_timeout(&rings[0].ring, &cqe, request_count > request_head ? 0 : WAIT_COMPLETIONS, &timeout, NULL);
        rings[0].pending_sqes = 0;
        now_seconds = (uint64_t)time(0);
        if (UNLIKELY(stats_on && now_seconds >= next_stats)) {
            next_stats = now_seconds + 10;
            fprintf(stderr, "STATS gates=%lu gate_timeouts=%lu inline=%lu frames_most=%lu queue_most=%lu held_most=%lu rings=%d rearms=%lu gate_ms=%ld gate_most_ms=%ld turn_most_ms=%ld off_cpu_ms=%ld off_cpu_most_ms=%ld commit_most_ms=%ld passes=%ld pass_most_ms=%ld checkpoint_cpu_ms=%ld\n",
                stat_gates, stat_gate_timeouts, stat_inline, stat_frames_most, stat_queue_most, stat_held_most, ring_count, stat_rearms,
                stat_gate_ns / 1000000, stat_gate_most_ns / 1000000, stat_turn_most_ns / 1000000, stat_off_cpu_ns / 1000000, stat_off_cpu_most_ns / 1000000, stat_commit_most_ns / 1000000,
                (long)__atomic_load_n(&stat_passes, __ATOMIC_RELAXED), (long)__atomic_load_n(&stat_pass_most_ns, __ATOMIC_RELAXED) / 1000000, (long)__atomic_load_n(&stat_checkpoint_cpu_ns, __ATOMIC_RELAXED) / 1000000);
            stat_frames_most = stat_queue_most = stat_held_most = 0;
            stat_gate_ns = stat_gate_most_ns = stat_turn_most_ns = stat_off_cpu_ns = stat_off_cpu_most_ns = stat_commit_most_ns = 0;
            __atomic_store_n(&stat_pass_most_ns, 0, __ATOMIC_RELAXED);
        }
        int64_t turn_start = 0, cpu_start = 0;
        if (UNLIKELY(stats_on)) {
            turn_start = monotonic_nanoseconds();
            cpu_start = thread_cpu_nanoseconds();
        }
        for (int rounds = 0; rounds < 4; rounds++) {
            int seen = 0;
            for (int index = 0; index < ring_count; index++) seen += drain_ring(index);
            int issued = issue_reads();
            submit_all();
            if (!seen && !issued) break;
        }
        run_batch();
        if (UNLIKELY(stats_on)) {
            // Wall time over CPU time: the loop was blocked in the kernel or waiting for the CPU.
            int64_t turn_ns = monotonic_nanoseconds() - turn_start;
            int64_t off_ns = turn_ns - (thread_cpu_nanoseconds() - cpu_start);
            if (turn_ns > stat_turn_most_ns) stat_turn_most_ns = turn_ns;
            if (off_ns > stat_off_cpu_most_ns) stat_off_cpu_most_ns = off_ns;
            stat_off_cpu_ns += off_ns;
        }
    }
}
