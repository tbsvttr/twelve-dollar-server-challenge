// c-rawuring-thehimalayanleo: the feed API on raw io_uring with SQLite compiled in.
//
// One event-loop thread drives several io_uring rings. Each ring has its own SO_REUSEPORT listener and
// its own table of direct descriptors, so the process can hold more connections than LimitNOFILE allows
// for normal fds. Completions are only processed when the thread asks for them (DEFER_TASKRUN), so the
// 1 ms pacing sleep is never cut short. When idle, the thread waits on one eventfd shared by all rings.
//
// Each loop pass is one batch: parse the requests that came in, do every read inside one read
// transaction, then run the writes in the same transaction, COMMIT once, and send all responses.
// Reads run before any write of the batch, so a response never shows data that is not committed.
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <liburing.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <poll.h>
#include <sys/eventfd.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#include "sqlite3.c"

#ifndef NRING
#define NRING 6               // rings (and listeners); each holds up to 65,535 connections
#endif
#define NBUF 1024             // receive buffers per ring
#define BUFSZ 2048
#define CHUNK (1u << 20)      // send arena chunk
#define RESV (160u << 10)     // room kept free for one response (a feed is at most ~64 KB)
#define HDR 128               // room before each body for the status line and headers
#define MAXIN 65536           // largest request we buffer
#define PACE_NS 1000000L      // a busy loop starts a pass at most every 1 ms
#define PASS_CQES 4096        // completions handled per pass; the rest wait in the kernel
#define ACCEPTS 32            // accepts kept armed per ring while the loop keeps up
#define BACKLOG (4096 / NRING) // listen backlog per listener, so all of them hold one listener's worth
#define CKPT_PAGES 1000        // the background checkpoint starts at this many WAL pages
#define CKPT_FINISH 4000       // the main thread finishes a checkpoint at this many

enum { OP_ACCEPT = 1, OP_RECV, OP_SEND, OP_CLOSE, OP_SHUT };
#define UD(op, r, slot, ch) (((uint64_t)(op) << 56) | ((uint64_t)(r) << 48) | ((uint64_t)(ch) << 24) | (uint64_t)(slot))

// ---------------------------------------------------------------- connections and rings

enum { F_OPEN = 1, F_RECV = 2, F_SENDING = 4, F_EOF = 8, F_CLOSEAFTER = 16, F_QUEUED = 32, F_BORROW = 64, F_REARM = 128 };
enum { F2_SHUT = 1 };

typedef struct {
  char *in;            // buffered input that did not fit one receive buffer, or waited for a send
  uint32_t inlen, incap;
  const char *lp;      // this pass's input, copied into the scratch arena (F_BORROW)
  uint32_t blen;
  uint8_t f, f2;
} conn_t;

typedef struct {
  struct io_uring u;
  struct io_uring_buf_ring *br;
  char *bufs;
  conn_t *c;
  int lfd, nslots, nacc, full, dirty;
  uint16_t *rel;       // buffers to hand back at the end of the pass
  int nrel;
  uint32_t *rearm;     // connections whose multishot receive ended
  int nrearm;
} ring_t;

static ring_t R[NRING];
static int nring;

// ---------------------------------------------------------------- per-pass scratch arena

typedef struct blk { struct blk *next; size_t used, cap; char d[]; } blk_t;
static blk_t *scr;

static void *salloc(size_t n) {
  n = (n + 15) & ~(size_t)15;
  if (!scr || scr->used + n > scr->cap) {
    size_t cap = n > (1u << 20) ? n : (1u << 20);
    blk_t *b = malloc(sizeof *b + cap);
    b->next = scr, b->used = 0, b->cap = cap;
    scr = b;
  }
  void *p = scr->d + scr->used;
  scr->used += n;
  return p;
}

static void sreset(void) {
  while (scr && scr->next) { blk_t *n = scr->next; free(scr); scr = n; }
  if (scr) scr->used = 0;
}

// ---------------------------------------------------------------- send arena

typedef struct { char *base; uint32_t pos; int ref; } chunk_t;
static chunk_t *CH;
static int nch, cch, *chfree, nchfree;

static int chunk_get(void) {
  if (nchfree) { int i = chfree[--nchfree]; CH[i].pos = 0; return i; }
  CH = realloc(CH, (size_t)(nch + 1) * sizeof *CH);
  chfree = realloc(chfree, (size_t)(nch + 1) * sizeof *chfree);
  CH[nch].base = malloc(CHUNK), CH[nch].pos = 0, CH[nch].ref = 0;
  return nch++;
}

static void chunk_unref(int i) {
  if (--CH[i].ref == 0 && i != cch) chfree[nchfree++] = i;
}

// ---------------------------------------------------------------- output buffer

typedef struct { char *p; uint32_t len; } ob_t;
#define OB_LIT(o, s) ob_put(o, s, sizeof(s) - 1)

static inline void ob_put(ob_t *o, const char *s, size_t n) { memcpy(o->p + o->len, s, n); o->len += (uint32_t)n; }

static void ob_int(ob_t *o, int64_t v) {
  char t[24];
  int n = 0;
  uint64_t u = v < 0 ? (uint64_t)-v : (uint64_t)v;
  do t[n++] = (char)('0' + u % 10); while (u /= 10);
  if (v < 0) t[n++] = '-';
  while (n) o->p[o->len++] = t[--n];
}

static const char HEX[] = "0123456789abcdef";

// Nonzero if any of the 8 bytes in x is below 0x20, '"' or '\\'. The usual "has zero byte" bit trick:
// it can flag a clean word (the byte loop then checks exactly) but never misses one.
static inline uint64_t needs_esc8(uint64_t x) {
  const uint64_t lo = 0x0101010101010101ull, hi = 0x8080808080808080ull;
  uint64_t q = x ^ (lo * '"'), b = x ^ (lo * '\\');
  return (((x - lo * 0x20) & ~x) | ((q - lo) & ~q) | ((b - lo) & ~b)) & hi;
}

static void ob_str(ob_t *o, const char *s, int n) {
  char *d = o->p + o->len;
  *d++ = '"';
  int i = 0;
  while (i < n) {
    int j = i;
    for (uint64_t x; j + 8 <= n && (memcpy(&x, s + j, 8), !needs_esc8(x)); j += 8) {}
    while (j < n && (unsigned char)s[j] >= 0x20 && s[j] != '"' && s[j] != '\\') j++;
    memcpy(d, s + i, (size_t)(j - i));
    d += j - i;
    if (j == n) break;
    unsigned char c = (unsigned char)s[j];
    *d++ = '\\';
    switch (c) {
      case '"': *d++ = '"'; break;
      case '\\': *d++ = '\\'; break;
      case '\n': *d++ = 'n'; break;
      case '\r': *d++ = 'r'; break;
      case '\t': *d++ = 't'; break;
      case '\b': *d++ = 'b'; break;
      case '\f': *d++ = 'f'; break;
      default: *d++ = 'u', *d++ = '0', *d++ = '0', *d++ = HEX[c >> 4], *d++ = HEX[c & 15];
    }
    i = j + 1;
  }
  *d++ = '"';
  o->len = (uint32_t)(d - o->p);
}

static void ob_post(ob_t *o, int64_t id, const char *b, int bl, const char *cr, int cl, const char *au, int al, int64_t likes) {
  OB_LIT(o, "{\"id\":");
  ob_int(o, id);
  OB_LIT(o, ",\"body\":");
  ob_str(o, b, bl);
  OB_LIT(o, ",\"created_at\":");
  ob_str(o, cr, cl);
  OB_LIT(o, ",\"author\":");
  ob_str(o, au, al);
  OB_LIT(o, ",\"like_count\":");
  ob_int(o, likes);
  OB_LIT(o, "}");
}

// ---------------------------------------------------------------- SQLite

static sqlite3 *db;
static sqlite3_stmt *st_begin, *st_commit, *st_rollback, *st_one, *st_feed, *st_post, *st_exists, *st_ins_post, *st_ins_like;

#include "bt.h"

static int bt_exists(int64_t id) {
  BtCursor *c = bt_cur(C_POSTS);
  if (!c) return -1;
  int res;
  if (sqlite3BtreeTableMoveto(c, id, 0, &res) != SQLITE_OK) return -1;
  return res == 0 && !sqlite3BtreeEof(c);
}

static int step1(sqlite3_stmt *s) {
  int rc = sqlite3_step(s);
  sqlite3_reset(s);
  return rc;
}

// Emits the rows of a post query, comma-separated. Returns the row count, or -1 on an error.
static int sql_posts(ob_t *o, sqlite3_stmt *s) {
  int n = 0, rc;
  while ((rc = sqlite3_step(s)) == SQLITE_ROW) {
    if (n) OB_LIT(o, ",");
    ob_post(o, sqlite3_column_int64(s, 0), (const char *)sqlite3_column_text(s, 1), sqlite3_column_bytes(s, 1),
            (const char *)sqlite3_column_text(s, 2), sqlite3_column_bytes(s, 2), (const char *)sqlite3_column_text(s, 3),
            sqlite3_column_bytes(s, 3), sqlite3_column_int64(s, 4));
    n++;
  }
  sqlite3_reset(s);
  return rc == SQLITE_DONE ? n : -1;
}

// Checkpoints. A thread on its own connection, at low priority, copies WAL frames into the database
// (PASSIVE, so it never blocks the writer). But SQLite restarts the WAL from its start only when a write
// begins after a checkpoint that copied every frame, and this server writes in almost every pass, so
// the thread alone never catches up and the WAL grows without limit. So when the WAL is long and the
// thread is idle, the main thread runs one PASSIVE checkpoint between passes (no transaction open).
// It copies only the few frames written since the thread's last run, and the next write restarts the WAL.
static pthread_mutex_t ck_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t ck_cv = PTHREAD_COND_INITIALIZER;
static int ck_want, wal_pages;

static int wal_hook(void *u, sqlite3 *d, const char *name, int pages) {
  (void)u, (void)d, (void)name;
  wal_pages = pages;
  if (pages >= CKPT_PAGES && pages < CKPT_FINISH && !__atomic_load_n(&ck_want, __ATOMIC_RELAXED)) {
    pthread_mutex_lock(&ck_mu);
    ck_want = 1;
    pthread_cond_signal(&ck_cv);
    pthread_mutex_unlock(&ck_mu);
  }
  return SQLITE_OK;
}

static void *ckpt_main(void *arg) {
  sqlite3 *d = arg;
  setpriority(PRIO_PROCESS, (id_t)gettid(), 15);
  for (;;) {
    pthread_mutex_lock(&ck_mu);
    while (!ck_want) pthread_cond_wait(&ck_cv, &ck_mu);
    pthread_mutex_unlock(&ck_mu);
    sqlite3_wal_checkpoint_v2(d, NULL, SQLITE_CHECKPOINT_PASSIVE, NULL, NULL);
    __atomic_store_n(&ck_want, 0, __ATOMIC_RELAXED);
  }
  return NULL;
}

static void die(const char *m) { fprintf(stderr, "fatal: %s\n", m); exit(1); }

static void prep(sqlite3_stmt **s, const char *sql) {
  if (sqlite3_prepare_v3(db, sql, -1, SQLITE_PREPARE_PERSISTENT, s, NULL) != SQLITE_OK) die(sqlite3_errmsg(db));
}

#define POST_SQL \
  "SELECT p.id, p.body, p.created_at, u.username, (SELECT count(*) FROM likes l WHERE l.post_id = p.id) " \
  "FROM posts p JOIN users u ON u.id = p.user_id "

static sqlite3 *open_db(const char *path) {
  sqlite3 *d;
  if (sqlite3_open_v2(path, &d, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, NULL) != SQLITE_OK) die("open database");
  sqlite3_exec(d,
               "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA busy_timeout=2000;"
               "PRAGMA cache_size=-16384; PRAGMA mmap_size=1073741824; PRAGMA temp_store=MEMORY;",
               NULL, NULL, NULL);
  return d;
}

static void db_init(const char *path) {
  sqlite3_initialize();
  db = open_db(path);
  prep(&st_begin, "BEGIN");
  prep(&st_commit, "COMMIT");
  prep(&st_rollback, "ROLLBACK");
  prep(&st_one, "SELECT 1");
  prep(&st_feed, POST_SQL "ORDER BY p.created_at DESC, p.id DESC LIMIT 20");
  prep(&st_post, POST_SQL "WHERE p.id = ?");
  prep(&st_exists, "SELECT 1 FROM posts WHERE id = ?");
  prep(&st_ins_post, "INSERT INTO posts (user_id, body) VALUES (?, ?) RETURNING id, created_at");
  prep(&st_ins_like, "INSERT INTO likes (user_id, post_id) VALUES (?, ?) ON CONFLICT (user_id, post_id) DO NOTHING");
  if (ENC(db) == SQLITE_UTF8 && !getenv("SQL_READS")) bt_setup(db);
  sqlite3_wal_hook(db, wal_hook, NULL);
  pthread_t t;
  pthread_create(&t, NULL, ckpt_main, open_db(path));
}

// ---------------------------------------------------------------- SHA-256 and HMAC

static const uint32_t SK[64] = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01,
  0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
  0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
  0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116, 0x1e376c08,
  0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};

#define ROR(x, n) (((x) >> (n)) | ((x) << (32 - (n))))

static void sha_block(uint32_t h[8], const uint8_t *p) {
  uint32_t w[64];
  for (int i = 0; i < 16; i++) w[i] = (uint32_t)p[4 * i] << 24 | (uint32_t)p[4 * i + 1] << 16 | (uint32_t)p[4 * i + 2] << 8 | p[4 * i + 3];
  for (int i = 16; i < 64; i++) {
    uint32_t s0 = ROR(w[i - 15], 7) ^ ROR(w[i - 15], 18) ^ (w[i - 15] >> 3);
    uint32_t s1 = ROR(w[i - 2], 17) ^ ROR(w[i - 2], 19) ^ (w[i - 2] >> 10);
    w[i] = w[i - 16] + s0 + w[i - 7] + s1;
  }
  uint32_t a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], k = h[7];
  for (int i = 0; i < 64; i++) {
    uint32_t t1 = k + (ROR(e, 6) ^ ROR(e, 11) ^ ROR(e, 25)) + ((e & f) ^ (~e & g)) + SK[i] + w[i];
    uint32_t t2 = (ROR(a, 2) ^ ROR(a, 13) ^ ROR(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
    k = g, g = f, f = e, e = d + t1, d = c, c = b, b = a, a = t1 + t2;
  }
  h[0] += a, h[1] += b, h[2] += c, h[3] += d, h[4] += e, h[5] += f, h[6] += g, h[7] += k;
}

// Hashes msg after a state that has already absorbed `pre` bytes (one 64-byte key block).
static void sha_finish(const uint32_t st[8], const uint8_t *msg, size_t n, uint8_t out[32]) {
  uint32_t h[8];
  memcpy(h, st, sizeof h);
  size_t total = 64 + n, i = 0;
  for (; i + 64 <= n; i += 64) sha_block(h, msg + i);
  uint8_t t[128] = {0};
  size_t r = n - i;
  memcpy(t, msg + i, r);
  t[r] = 0x80;
  size_t tl = r + 1 + 8 <= 64 ? 64 : 128;
  uint64_t bits = (uint64_t)total * 8;
  for (int j = 0; j < 8; j++) t[tl - 1 - j] = (uint8_t)(bits >> (8 * j));
  sha_block(h, t);
  if (tl == 128) sha_block(h, t + 64);
  for (int j = 0; j < 8; j++) out[4 * j] = (uint8_t)(h[j] >> 24), out[4 * j + 1] = (uint8_t)(h[j] >> 16), out[4 * j + 2] = (uint8_t)(h[j] >> 8), out[4 * j + 3] = (uint8_t)h[j];
}

static uint32_t hm_in[8], hm_out[8];  // SHA-256 state after the ipad and opad key blocks

static void hmac_init(const char *key) {
  static const uint32_t IV[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
  uint8_t k[64] = {0}, b[64];
  size_t kl = strlen(key);
  if (kl > 64) {  // a key longer than one block is replaced by its SHA-256
    uint32_t h[8];
    memcpy(h, IV, sizeof h);
    uint8_t t[128] = {0};
    size_t i = 0;
    for (; i + 64 <= kl; i += 64) sha_block(h, (const uint8_t *)key + i);
    size_t r = kl - i;
    memcpy(t, key + i, r);
    t[r] = 0x80;
    size_t tl = r + 9 <= 64 ? 64 : 128;
    uint64_t bits = (uint64_t)kl * 8;
    for (int j = 0; j < 8; j++) t[tl - 1 - j] = (uint8_t)(bits >> (8 * j));
    sha_block(h, t);
    if (tl == 128) sha_block(h, t + 64);
    for (int j = 0; j < 8; j++) k[4 * j] = (uint8_t)(h[j] >> 24), k[4 * j + 1] = (uint8_t)(h[j] >> 16), k[4 * j + 2] = (uint8_t)(h[j] >> 8), k[4 * j + 3] = (uint8_t)h[j];
  } else {
    memcpy(k, key, kl);
  }
  memcpy(hm_in, IV, sizeof hm_in);
  memcpy(hm_out, IV, sizeof hm_out);
  for (int i = 0; i < 64; i++) b[i] = k[i] ^ 0x36;
  sha_block(hm_in, b);
  for (int i = 0; i < 64; i++) b[i] = k[i] ^ 0x5c;
  sha_block(hm_out, b);
}

static void hmac(const char *m, size_t n, uint8_t out[32]) {
  uint8_t in[32];
  sha_finish(hm_in, (const uint8_t *)m, n, in);
  sha_finish(hm_out, in, 32, out);
}

// ---------------------------------------------------------------- JSON

static const char *jws(const char *p, const char *e) {
  while (p < e && (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r')) p++;
  return p;
}

static int hexv(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  c |= 32;
  return c >= 'a' && c <= 'f' ? c - 'a' + 10 : -1;
}

// p at the opening quote. Returns the position after the closing quote, or NULL.
static const char *jstr_skip(const char *p, const char *e) {
  for (p++; p < e; p++) {
    unsigned char c = (unsigned char)*p;
    if (c == '"') return p + 1;
    if (c < 0x20) return NULL;
    if (c == '\\') {
      if (++p >= e) return NULL;
      switch (*p) {
        case '"': case '\\': case '/': case 'b': case 'f': case 'n': case 'r': case 't': break;
        case 'u':
          if (e - p < 5) return NULL;
          for (int i = 1; i <= 4; i++)
            if (hexv(p[i]) < 0) return NULL;
          p += 4;
          break;
        default: return NULL;
      }
    }
  }
  return NULL;
}

static const char *jval(const char *p, const char *e, int depth);

static const char *jnum(const char *p, const char *e) {
  if (p < e && *p == '-') p++;
  if (p >= e) return NULL;
  if (*p == '0') p++;
  else if (*p >= '1' && *p <= '9') while (p < e && *p >= '0' && *p <= '9') p++;
  else return NULL;
  if (p < e && *p == '.') {
    p++;
    if (p >= e || *p < '0' || *p > '9') return NULL;
    while (p < e && *p >= '0' && *p <= '9') p++;
  }
  if (p < e && (*p == 'e' || *p == 'E')) {
    p++;
    if (p < e && (*p == '+' || *p == '-')) p++;
    if (p >= e || *p < '0' || *p > '9') return NULL;
    while (p < e && *p >= '0' && *p <= '9') p++;
  }
  return p;
}

static const char *jlit(const char *p, const char *e, const char *w, size_t n) {
  return (size_t)(e - p) >= n && !memcmp(p, w, n) ? p + n : NULL;
}

static const char *jcont(const char *p, const char *e, int depth, char close) {
  if (depth > 64) return NULL;
  p = jws(p + 1, e);
  if (p < e && *p == close) return p + 1;
  for (;;) {
    if (close == '}') {
      if (p >= e || *p != '"' || !(p = jstr_skip(p, e))) return NULL;
      p = jws(p, e);
      if (p >= e || *p != ':') return NULL;
      p = jws(p + 1, e);
    }
    if (!(p = jval(p, e, depth + 1))) return NULL;
    p = jws(p, e);
    if (p >= e) return NULL;
    if (*p == close) return p + 1;
    if (*p != ',') return NULL;
    p = jws(p + 1, e);
  }
}

static const char *jval(const char *p, const char *e, int depth) {
  if (p >= e) return NULL;
  switch (*p) {
    case '"': return jstr_skip(p, e);
    case '{': return jcont(p, e, depth, '}');
    case '[': return jcont(p, e, depth, ']');
    case 't': return jlit(p, e, "true", 4);
    case 'f': return jlit(p, e, "false", 5);
    case 'n': return jlit(p, e, "null", 4);
    default: return jnum(p, e);
  }
}

static char *utf8(char *d, uint32_t c) {
  if (c < 0x80) *d++ = (char)c;
  else if (c < 0x800) *d++ = (char)(0xC0 | c >> 6), *d++ = (char)(0x80 | (c & 63));
  else if (c < 0x10000) *d++ = (char)(0xE0 | c >> 12), *d++ = (char)(0x80 | (c >> 6 & 63)), *d++ = (char)(0x80 | (c & 63));
  else *d++ = (char)(0xF0 | c >> 18), *d++ = (char)(0x80 | (c >> 12 & 63)), *d++ = (char)(0x80 | (c >> 6 & 63)), *d++ = (char)(0x80 | (c & 63));
  return d;
}

static uint32_t hex4(const char *p) { return (uint32_t)(hexv(p[0]) << 12 | hexv(p[1]) << 8 | hexv(p[2]) << 4 | hexv(p[3])); }

// Decodes a validated JSON string (p at the opening quote) into d. d needs as many bytes as the raw string.
static int jstr_dec(const char *p, char *d0) {
  char *d = d0;
  for (p++; *p != '"'; p++) {
    if (*p != '\\') { *d++ = *p; continue; }
    switch (*++p) {
      case 'b': *d++ = '\b'; break;
      case 'f': *d++ = '\f'; break;
      case 'n': *d++ = '\n'; break;
      case 'r': *d++ = '\r'; break;
      case 't': *d++ = '\t'; break;
      case 'u': {
        uint32_t c = hex4(p + 1);
        p += 4;
        if (c >= 0xD800 && c < 0xDC00 && p[1] == '\\' && p[2] == 'u') {
          uint32_t c2 = hex4(p + 3);
          if (c2 >= 0xDC00 && c2 < 0xE000) { c = 0x10000 + ((c - 0xD800) << 10) + (c2 - 0xDC00); p += 6; }
        }
        if (c >= 0xD800 && c < 0xE000) c = 0xFFFD;  // a lone surrogate has no UTF-8 form
        d = utf8(d, c);
        break;
      }
      default: *d++ = *p;
    }
  }
  return (int)(d - d0);
}

typedef struct { const char *k; const char *v; } jkey_t;  // v: start of the value, NULL if absent

// Validates one JSON document. If it is an object, sets v for the named top-level keys (last one wins).
// Returns -1 if the text is not JSON, 1 for an object, 0 for any other value.
static int jdoc(const char *p, const char *e, jkey_t *ks, int nk) {
  for (int i = 0; i < nk; i++) ks[i].v = NULL;
  p = jws(p, e);
  int obj = p < e && *p == '{';
  if (!obj) {
    p = jval(p, e, 0);
    return p && jws(p, e) == e ? 0 : -1;
  }
  p = jws(p + 1, e);
  if (p < e && *p == '}') return jws(p + 1, e) == e ? 1 : -1;
  for (;;) {
    if (p >= e || *p != '"') return -1;
    const char *k = p, *ke = jstr_skip(p, e);
    if (!ke) return -1;
    p = jws(ke, e);
    if (p >= e || *p != ':') return -1;
    p = jws(p + 1, e);
    const char *v = p;
    if (!(p = jval(p, e, 1))) return -1;
    for (int i = 0; i < nk; i++) {
      size_t kl = strlen(ks[i].k);
      if ((size_t)(ke - k - 2) == kl && !memcmp(k + 1, ks[i].k, kl)) ks[i].v = v;
      else if (memchr(k, '\\', (size_t)(ke - k))) {  // an escaped key: compare decoded
        char t[256];
        if (ke - k < (long)sizeof t && jstr_dec(k, t) == (int)kl && !memcmp(t, ks[i].k, kl)) ks[i].v = v;
      }
    }
    p = jws(p, e);
    if (p >= e) return -1;
    if (*p == '}') return jws(p + 1, e) == e ? 1 : -1;
    if (*p != ',') return -1;
    p = jws(p + 1, e);
  }
}

// ---------------------------------------------------------------- JWT

static int8_t B64[256];

static int b64url(const char *s, int n, uint8_t *d) {
  uint32_t acc = 0;
  int bits = 0, o = 0;
  if (n % 4 == 1) return -1;
  for (int i = 0; i < n; i++) {
    int v = B64[(unsigned char)s[i]];
    if (v < 0) return -1;
    acc = acc << 6 | (uint32_t)v;
    if ((bits += 6) >= 8) bits -= 8, d[o++] = (uint8_t)(acc >> bits);
  }
  return o;
}

enum { A_OK, A_MISSING, A_INVALID, A_PAYLOAD };
static int64_t now_s;

static int auth(const char *h, int hl, int64_t *uid, char **un, int *unl) {
  if (!h || hl < 7 || memcmp(h, "Bearer ", 7)) return A_MISSING;
  const char *t = h + 7, *e = h + hl;
  const char *d1 = memchr(t, '.', (size_t)(e - t));
  if (!d1) return A_INVALID;
  const char *d2 = memchr(d1 + 1, '.', (size_t)(e - d1 - 1));
  if (!d2 || memchr(d2 + 1, '.', (size_t)(e - d2 - 1))) return A_INVALID;
  uint8_t sig[64], mac[32];
  if (e - d2 - 1 > 64 || b64url(d2 + 1, (int)(e - d2 - 1), sig) != 32) return A_INVALID;
  hmac(t, (size_t)(d2 - t), mac);
  uint8_t diff = 0;
  for (int i = 0; i < 32; i++) diff |= mac[i] ^ sig[i];
  if (diff) return A_INVALID;

  char *hd = salloc((size_t)(d1 - t)), *pl = salloc((size_t)(d2 - d1));
  int hn = b64url(t, (int)(d1 - t), (uint8_t *)hd), pn = b64url(d1 + 1, (int)(d2 - d1 - 1), (uint8_t *)pl);
  if (hn < 0 || pn < 0) return A_INVALID;
  jkey_t hk[1] = {{"alg", 0}};
  if (jdoc(hd, hd + hn, hk, 1) != 1 || !hk[0].v || memcmp(hk[0].v, "\"HS256\"", 7)) return A_INVALID;
  jkey_t pk[3] = {{"exp", 0}, {"sub", 0}, {"username", 0}};
  if (jdoc(pl, pl + pn, pk, 3) != 1) return A_INVALID;
  const char *x = pk[0].v;
  if (!x || !(*x == '-' || (*x >= '0' && *x <= '9'))) return A_INVALID;
  if (strtod(x, NULL) <= (double)now_s) return A_INVALID;
  if (!pk[1].v || *pk[1].v != '"' || !pk[2].v || *pk[2].v != '"') return A_PAYLOAD;
  char sub[32];
  const char *se = jstr_skip(pk[1].v, pl + pn);
  if (se - pk[1].v > (long)sizeof sub) return A_PAYLOAD;
  int sl = jstr_dec(pk[1].v, sub);
  int64_t v = 0;
  if (sl < 1 || sl > 18) return A_PAYLOAD;
  for (int i = 0; i < sl; i++) {
    if (sub[i] < '0' || sub[i] > '9') return A_PAYLOAD;
    v = v * 10 + (sub[i] - '0');
  }
  if (v <= 0) return A_PAYLOAD;
  const char *ue = jstr_skip(pk[2].v, pl + pn);
  *un = salloc((size_t)(ue - pk[2].v));
  *unl = jstr_dec(pk[2].v, *un);
  *uid = v;
  return A_OK;
}

// ---------------------------------------------------------------- io_uring plumbing

static struct io_uring_sqe *sqe_get(ring_t *r) {
  struct io_uring_sqe *s = io_uring_get_sqe(&r->u);
  if (!s) {
    io_uring_submit(&r->u);
    s = io_uring_get_sqe(&r->u);
  }
  r->dirty = 1;
  return s;
}

static void arm_accept(int ri) {
  ring_t *r = &R[ri];
  struct io_uring_sqe *s = sqe_get(r);
  io_uring_prep_accept_direct(s, r->lfd, NULL, NULL, 0, IORING_FILE_INDEX_ALLOC);
  s->user_data = UD(OP_ACCEPT, ri, 0, 0);
  r->nacc++;
}

static void arm_recv(int ri, uint32_t slot) {
  struct io_uring_sqe *s = sqe_get(&R[ri]);
  io_uring_prep_recv_multishot(s, (int)slot, NULL, 0, 0);
  s->flags |= IOSQE_FIXED_FILE | IOSQE_BUFFER_SELECT;
  s->buf_group = 0;
  s->user_data = UD(OP_RECV, ri, slot, 0);
  R[ri].c[slot].f |= F_RECV;
}

static inline char *rbuf(ring_t *r, uint16_t bid) { return r->bufs + (size_t)bid * BUFSZ; }
static inline void rbuf_release(ring_t *r, uint16_t bid) { r->rel[r->nrel++] = bid; }

// Ends the connection's receive side; its multishot receive then completes and the slot is closed.
static void conn_shut(int ri, uint32_t slot) {
  conn_t *c = &R[ri].c[slot];
  if (c->f2 & F2_SHUT) return;
  c->f2 |= F2_SHUT;
  struct io_uring_sqe *s = sqe_get(&R[ri]);
  io_uring_prep_shutdown(s, (int)slot, SHUT_RDWR);
  s->flags |= IOSQE_FIXED_FILE;
  s->user_data = UD(OP_SHUT, ri, slot, 0);
}

static void maybe_close(int ri, uint32_t slot) {
  ring_t *r = &R[ri];
  conn_t *c = &r->c[slot];
  if (!(c->f & F_OPEN) || !(c->f & F_EOF) || (c->f & (F_RECV | F_SENDING | F_QUEUED))) return;
  free(c->in);
  memset(c, 0, sizeof *c);
  r->full = 0;
  struct io_uring_sqe *s = sqe_get(r);
  io_uring_prep_close_direct(s, slot);
  s->user_data = UD(OP_CLOSE, ri, slot, 0);
}

static int in_append(conn_t *c, const char *p, uint32_t n) {
  if (c->inlen + n > MAXIN) return -1;
  if (c->inlen + n > c->incap) {
    uint32_t cap = c->incap ? c->incap : 1024;
    while (cap < c->inlen + n) cap *= 2;
    c->in = realloc(c->in, cap);
    c->incap = cap;
  }
  memcpy(c->in + c->inlen, p, n);
  c->inlen += n;
  return 0;
}

// Moves this pass's input from the scratch arena into the connection's own input buffer.
static int unborrow(conn_t *c, uint32_t from) {
  int rc = 0;
  if (c->f & F_BORROW) {
    if (c->blen > from) rc = in_append(c, c->lp + from, c->blen - from);
    c->f &= (uint8_t)~F_BORROW;
  }
  return rc;
}

static uint32_t *queue;
static int nq, qcap;

static void enqueue(int ri, uint32_t slot) {
  conn_t *c = &R[ri].c[slot];
  if (c->f & (F_QUEUED | F_SENDING)) return;
  c->f |= F_QUEUED;
  if (nq == qcap) queue = realloc(queue, (size_t)(qcap = qcap ? qcap * 2 : 4096) * sizeof *queue);
  queue[nq++] = (uint32_t)ri << 24 | slot;
}

// The receive buffer goes back to the kernel after this batch of completions, so a busy pass never
// runs the ring out of buffers. The usual request (one receive, nothing pending) is copied into the
// pass's scratch arena; anything else goes to the connection's own buffer.
static void on_data(int ri, uint32_t slot, uint16_t bid, uint32_t n) {
  ring_t *r = &R[ri];
  conn_t *c = &r->c[slot];
  const char *src = rbuf(r, bid);
  int bad = 0;
  if (!(c->f & (F_BORROW | F_SENDING)) && !c->inlen) {
    char *d = salloc(n);
    memcpy(d, src, n);
    c->f |= F_BORROW, c->lp = d, c->blen = n;
  } else {
    bad = unborrow(c, 0) || in_append(c, src, n);
  }
  rbuf_release(r, bid);
  if (bad) { c->f |= F_EOF; conn_shut(ri, slot); return; }
  enqueue(ri, slot);
}

static void on_cqe(int ri, struct io_uring_cqe *q) {
  ring_t *r = &R[ri];
  int op = (int)(q->user_data >> 56), res = q->res;
  uint32_t slot = (uint32_t)(q->user_data & 0xFFFFFF);
  int more = q->flags & IORING_CQE_F_MORE;
  switch (op) {
    case OP_ACCEPT:
      if (res >= 0 && res < r->nslots) {
        memset(&r->c[res], 0, sizeof(conn_t));
        r->c[res].f = F_OPEN;
        arm_recv(ri, (uint32_t)res);
      }
      r->nacc--;
      if (res == -ENFILE) r->full = 1;  // no free slot: accept again after a close
      break;
    case OP_RECV: {
      conn_t *c = &r->c[slot];
      if (res > 0) on_data(ri, slot, (uint16_t)(q->flags >> IORING_CQE_BUFFER_SHIFT), (uint32_t)res);
      if (!more) {
        c->f &= (uint8_t)~F_RECV;
        if ((res > 0 || res == -ENOBUFS) && !(c->f & F_EOF) && !(c->f2 & F2_SHUT)) {
          if (!(c->f & F_REARM)) c->f |= F_REARM, r->rearm[r->nrearm++] = slot;
        } else {
          c->f |= F_EOF;
          maybe_close(ri, slot);
        }
      }
      break;
    }
    case OP_SEND: {
      chunk_unref((int)((q->user_data >> 24) & 0xFFFFFF));
      conn_t *c = &r->c[slot];
      c->f &= (uint8_t)~F_SENDING;
      if (res < 0 || (c->f & F_CLOSEAFTER)) {
        c->f |= F_EOF;
        conn_shut(ri, slot);
      } else if (c->inlen) {
        enqueue(ri, slot);
      }
      maybe_close(ri, slot);
      break;
    }
    default: break;
  }
}

// ---------------------------------------------------------------- responses

static const char *status_line(int st) {
  switch (st) {
    case 200: return "200 OK";
    case 201: return "201 Created";
    case 400: return "400 Bad Request";
    case 401: return "401 Unauthorized";
    case 404: return "404 Not Found";
    case 503: return "503 Service Unavailable";
    default: return "500 Internal Server Error";
  }
}

static ob_t resp_begin(void) {
  if (CH[cch].pos + RESV > CHUNK) {
    int old = cch;
    cch = chunk_get();
    if (CH[old].ref == 0) chfree[nchfree++] = old;
  }
  return (ob_t){CH[cch].base + CH[cch].pos + HDR, 0};
}

static void resp_send(int ri, uint32_t slot, int st, ob_t *o) {
  conn_t *c = &R[ri].c[slot];
  char h[HDR];
  int hl = snprintf(h, sizeof h, "HTTP/1.1 %s\r\nContent-Type: application/json\r\nContent-Length: %u\r\n%s\r\n",
                    status_line(st), o->len, (c->f & F_CLOSEAFTER) ? "Connection: close\r\n" : "");
  char *start = o->p - hl;
  memcpy(start, h, (size_t)hl);
  CH[cch].pos += (HDR + o->len + 63) & ~63u;
  CH[cch].ref++;
  c->f |= F_SENDING;
  struct io_uring_sqe *s = sqe_get(&R[ri]);
  io_uring_prep_send(s, (int)slot, start, (size_t)hl + o->len, MSG_WAITALL | MSG_NOSIGNAL);
  s->flags |= IOSQE_FIXED_FILE;
  s->user_data = UD(OP_SEND, ri, slot, cch);
}

static void resp_err(int ri, uint32_t slot, int st, const char *msg) {
  ob_t o = resp_begin();
  OB_LIT(&o, "{\"error\":\"");
  ob_put(&o, msg, strlen(msg));
  OB_LIT(&o, "\"}");
  resp_send(ri, slot, st, &o);
}

// ---------------------------------------------------------------- request handling

enum { W_POST = 1, W_LIKE };
typedef struct {
  uint32_t ref;
  uint8_t kind;
  int st;
  int64_t uid, pid, newid;
  char *body, *un;
  int bl, unl, crl;
  char cr[40];
} wr_t;

static wr_t *wq;
static int nw, wcap;
static int bt_live;
static int64_t t_start;

static wr_t *wq_add(int ri, uint32_t slot, int kind) {
  if (nw == wcap) wq = realloc(wq, (size_t)(wcap = wcap ? wcap * 2 : 1024) * sizeof *wq);
  wr_t *w = &wq[nw++];
  memset(w, 0, sizeof *w);
  w->ref = (uint32_t)ri << 24 | slot, w->kind = (uint8_t)kind;
  R[ri].c[slot].f |= F_SENDING;  // the response is sent after COMMIT
  return w;
}

static int64_t parse_id(const char *s, int n) {
  if (n < 1 || n > 18) return -1;
  int64_t v = 0;
  for (int i = 0; i < n; i++) {
    if (s[i] < '0' || s[i] > '9') return -1;
    v = v * 10 + (s[i] - '0');
  }
  return v > 0 ? v : -1;
}

static void do_health(int ri, uint32_t slot) {
  ob_t o = resp_begin();
  int rc = step1(st_one);
  if (rc == SQLITE_ROW) {
    OB_LIT(&o, "{\"status\":\"ok\",\"db\":\"ok\",\"uptime_s\":");
    ob_int(&o, now_s - t_start);
    OB_LIT(&o, "}");
    resp_send(ri, slot, 200, &o);
  } else {
    const char *m = sqlite3_errmsg(db);
    OB_LIT(&o, "{\"status\":\"degraded\",\"db\":\"unreachable\",\"error\":");
    ob_str(&o, m, (int)strlen(m));
    OB_LIT(&o, "}");
    resp_send(ri, slot, 503, &o);
  }
}

static void do_feed(int ri, uint32_t slot) {
  ob_t o = resp_begin();
  if (!bt_live || bt_feed(&o) < 0) {
    o.len = 0;
    OB_LIT(&o, "{\"posts\":[");
    if (sql_posts(&o, st_feed) < 0) { resp_err(ri, slot, 500, "internal server error"); return; }
    OB_LIT(&o, "]}");
  }
  resp_send(ri, slot, 200, &o);
}

static void do_post(int ri, uint32_t slot, int64_t id) {
  ob_t o = resp_begin();
  int r = bt_live ? bt_post(&o, id) : -1;
  if (r < 0) {
    o.len = 0;
    OB_LIT(&o, "{\"post\":");
    sqlite3_bind_int64(st_post, 1, id);
    int n = sql_posts(&o, st_post);
    if (n < 0) { resp_err(ri, slot, 500, "internal server error"); return; }
    OB_LIT(&o, "}");
    r = n > 0;
  }
  if (!r) { resp_err(ri, slot, 404, "post not found"); return; }
  resp_send(ri, slot, 200, &o);
}

static int post_exists(int64_t id) {
  int r = bt_live ? bt_exists(id) : -1;
  if (r < 0) {
    sqlite3_bind_int64(st_exists, 1, id);
    int rc = step1(st_exists);
    r = rc == SQLITE_ROW ? 1 : rc == SQLITE_DONE ? 0 : -1;
  }
  return r;
}

static int is_trim(const unsigned char *p, const unsigned char *e, int *n) {
  if (*p == ' ' || (*p >= '\t' && *p <= '\r')) return *n = 1;
  if (e - p >= 2 && p[0] == 0xC2 && p[1] == 0xA0) return *n = 2;                    // U+00A0
  if (e - p >= 3 && p[0] == 0xEF && p[1] == 0xBB && p[2] == 0xBF) return *n = 3;    // U+FEFF
  return 0;
}

static void do_create(int ri, uint32_t slot, int64_t uid, char *un, int unl, const char *b, int bl) {
  jkey_t k[1] = {{"body", 0}};
  int d = jdoc(b, b + bl, k, 1);
  if (d < 0) { resp_err(ri, slot, 400, "malformed JSON body"); return; }
  if (d != 1 || !k[0].v || *k[0].v != '"') { resp_err(ri, slot, 400, "body is required"); return; }
  const char *ve = jstr_skip(k[0].v, b + bl);
  char *s = salloc((size_t)(ve - k[0].v));
  int n = jstr_dec(k[0].v, s), t;
  unsigned char *p = (unsigned char *)s, *e = p + n;
  while (p < e && is_trim(p, e, &t)) p += t;
  for (;;) {  // trailing: step back over one whitespace character at a time
    if (p < e && (e[-1] == ' ' || (e[-1] >= '\t' && e[-1] <= '\r'))) e--;
    else if (e - p >= 2 && e[-2] == 0xC2 && e[-1] == 0xA0) e -= 2;
    else if (e - p >= 3 && e[-3] == 0xEF && e[-2] == 0xBB && e[-1] == 0xBF) e -= 3;
    else break;
  }
  if (p == e) { resp_err(ri, slot, 400, "body is required"); return; }
  int chars = 0;
  for (unsigned char *q = p; q < e; q++) chars += (*q & 0xC0) != 0x80;
  if (chars > 500) { resp_err(ri, slot, 400, "body must be at most 500 characters"); return; }
  wr_t *w = wq_add(ri, slot, W_POST);
  w->uid = uid, w->un = un, w->unl = unl, w->body = (char *)p, w->bl = (int)(e - p);
}

// Parses and handles one request at p. Returns the bytes used, 0 if the request is not complete yet.
static uint32_t handle(int ri, uint32_t slot, const char *p, uint32_t len) {
  conn_t *c = &R[ri].c[slot];
  const char *he = memmem(p, len, "\r\n\r\n", 4);
  if (!he) {
    if (len >= 16384) { c->f |= F_CLOSEAFTER; resp_err(ri, slot, 400, "bad request"); return len; }
    return 0;
  }
  uint32_t hl = (uint32_t)(he + 4 - p);
  const char *le = memchr(p, '\r', hl);
  const char *sp1 = memchr(p, ' ', (size_t)(le - p));
  const char *sp2 = sp1 ? memchr(sp1 + 1, ' ', (size_t)(le - sp1 - 1)) : NULL;
  if (!sp2) { c->f |= F_CLOSEAFTER; resp_err(ri, slot, 400, "bad request"); return len; }

  long clen = 0;
  const char *ah = NULL;
  int al = 0;
  for (const char *l = le + 2; l < he;) {
    const char *nl = memchr(l, '\r', (size_t)(he + 2 - l));
    size_t ll = (size_t)(nl - l);
    if (ll > 15 && !strncasecmp(l, "content-length:", 15)) {
      const char *v = l + 15;
      while (*v == ' ') v++;
      clen = 0;
      for (; v < nl && *v >= '0' && *v <= '9'; v++) clen = clen * 10 + (*v - '0');
    } else if (ll > 14 && !strncasecmp(l, "authorization:", 14)) {
      const char *v = l + 14;
      while (*v == ' ') v++;
      const char *ve = nl;
      while (ve > v && ve[-1] == ' ') ve--;
      ah = v, al = (int)(ve - v);
    } else if (ll > 11 && !strncasecmp(l, "connection:", 11)) {
      const char *v = l + 11;
      while (*v == ' ') v++;
      if ((size_t)(nl - v) >= 5 && !strncasecmp(v, "close", 5)) c->f |= F_CLOSEAFTER;
    }
    l = nl + 2;
  }
  if (clen > MAXIN - (long)hl) { c->f |= F_CLOSEAFTER; resp_err(ri, slot, 400, "bad request"); return len; }
  if (hl + (uint32_t)clen > len) return 0;
  uint32_t used = hl + (uint32_t)clen;

  const char *path = sp1 + 1, *pe = sp2;
  const char *qm = memchr(path, '?', (size_t)(pe - path));
  if (qm) pe = qm;
  size_t pl = (size_t)(pe - path);
  int get = sp1 - p == 3 && !memcmp(p, "GET", 3), post = sp1 - p == 4 && !memcmp(p, "POST", 4);

  if (pl == 5 && !memcmp(path, "/feed", 5) && get) { do_feed(ri, slot); return used; }
  if (pl == 7 && !memcmp(path, "/health", 7) && get) { do_health(ri, slot); return used; }
  if (pl >= 6 && !memcmp(path, "/posts", 6)) {
    if (pl == 6 && post) {
      int64_t uid;
      char *un;
      int unl;
      int a = auth(ah, al, &uid, &un, &unl);
      if (a == A_MISSING) resp_err(ri, slot, 401, "missing bearer token");
      else if (a == A_INVALID) resp_err(ri, slot, 401, "invalid or expired token");
      else if (a == A_PAYLOAD) resp_err(ri, slot, 401, "invalid token payload");
      else do_create(ri, slot, uid, un, unl, p + hl, (int)clen);
      return used;
    }
    if (path[6] == '/') {
      const char *id = path + 7, *ie = memchr(id, '/', (size_t)(pe - id));
      if (!ie) ie = pe;
      size_t rest = (size_t)(pe - ie);
      if (!rest && get) {
        int64_t v = parse_id(id, (int)(ie - id));
        if (v < 0) resp_err(ri, slot, 400, "invalid post id");
        else do_post(ri, slot, v);
        return used;
      }
      if (rest == 5 && !memcmp(ie, "/like", 5) && post) {
        int64_t uid;
        char *un;
        int unl;
        int a = auth(ah, al, &uid, &un, &unl);
        if (a == A_MISSING) { resp_err(ri, slot, 401, "missing bearer token"); return used; }
        if (a == A_INVALID) { resp_err(ri, slot, 401, "invalid or expired token"); return used; }
        if (a == A_PAYLOAD) { resp_err(ri, slot, 401, "invalid token payload"); return used; }
        int64_t v = parse_id(id, (int)(ie - id));
        if (v < 0) { resp_err(ri, slot, 400, "invalid post id"); return used; }
        int ex = post_exists(v);
        if (ex < 0) resp_err(ri, slot, 500, "internal server error");
        else if (!ex) resp_err(ri, slot, 404, "post not found");
        else { wr_t *w = wq_add(ri, slot, W_LIKE); w->uid = uid, w->pid = v; }
        return used;
      }
    }
  }
  resp_err(ri, slot, 404, "not found");
  return used;
}

static void process(int ri, uint32_t slot) {
  ring_t *r = &R[ri];
  conn_t *c = &r->c[slot];
  c->f &= (uint8_t)~F_QUEUED;
  if (!(c->f & F_SENDING)) {
    int lent = (c->f & F_BORROW) != 0;
    const char *p = lent ? c->lp : c->in;
    uint32_t n = lent ? c->blen : c->inlen;
    uint32_t k = n ? handle(ri, slot, p, n) : 0;
    if (lent) {
      if (unborrow(c, k)) c->f |= F_EOF, conn_shut(ri, slot);
    } else if (k) {
      memmove(c->in, c->in + k, c->inlen - k);
      if (!(c->inlen -= k)) { free(c->in); c->in = NULL; c->incap = 0; }
    }
  }
  maybe_close(ri, slot);
}

static void run_writes(void) {
  for (int i = 0; i < nw; i++) {
    wr_t *w = &wq[i];
    if (w->kind == W_POST) {
      sqlite3_bind_int64(st_ins_post, 1, w->uid);
      sqlite3_bind_text(st_ins_post, 2, w->body, w->bl, SQLITE_STATIC);
      if (sqlite3_step(st_ins_post) == SQLITE_ROW) {
        w->newid = sqlite3_column_int64(st_ins_post, 0);
        int n = sqlite3_column_bytes(st_ins_post, 1);
        if (n > (int)sizeof w->cr) n = sizeof w->cr;
        memcpy(w->cr, sqlite3_column_text(st_ins_post, 1), (size_t)n);
        w->crl = n;
        w->st = sqlite3_step(st_ins_post) == SQLITE_DONE ? 201 : 500;
      } else {
        w->st = 500;
      }
      sqlite3_reset(st_ins_post);
    } else {
      sqlite3_bind_int64(st_ins_like, 1, w->uid);
      sqlite3_bind_int64(st_ins_like, 2, w->pid);
      int rc = step1(st_ins_like);
      w->st = rc != SQLITE_DONE ? 500 : sqlite3_changes(db) ? 201 : 200;
    }
  }
}

static void send_writes(void) {
  for (int i = 0; i < nw; i++) {
    wr_t *w = &wq[i];
    int ri = (int)(w->ref >> 24);
    uint32_t slot = w->ref & 0xFFFFFF;
    R[ri].c[slot].f &= (uint8_t)~F_SENDING;
    if (w->st == 500) { resp_err(ri, slot, 500, "internal server error"); continue; }
    ob_t o = resp_begin();
    if (w->kind == W_POST) {
      OB_LIT(&o, "{\"post\":");
      ob_post(&o, w->newid, w->body, w->bl, w->cr, w->crl, w->un, w->unl, 0);
      OB_LIT(&o, "}");
    } else {
      OB_LIT(&o, "{\"liked\":true,\"already_liked\":");
      if (w->st == 201) OB_LIT(&o, "false");
      else OB_LIT(&o, "true");
      OB_LIT(&o, ",\"post_id\":");
      ob_int(&o, w->pid);
      OB_LIT(&o, "}");
    }
    resp_send(ri, slot, w->st, &o);
  }
}

static void run_batch(void) {
  now_s = time(NULL);
  if (step1(st_begin) != SQLITE_DONE) {
    step1(st_rollback);
    step1(st_begin);
  }
  bt_live = bt_begin() == 0;
  for (int i = 0; i < nq; i++) process((int)(queue[i] >> 24), queue[i] & 0xFFFFFF);
  nq = 0;
  bt_close();
  if (nw) run_writes();
  if (step1(st_commit) != SQLITE_DONE) {
    step1(st_rollback);
    for (int i = 0; i < nw; i++) wq[i].st = 500;
  }
  if (B.bt && sqlite3BtreeTxnState(B.bt) != SQLITE_TXN_NONE) sqlite3BtreeCommit(B.bt);
  if (wal_pages >= CKPT_FINISH && !__atomic_load_n(&ck_want, __ATOMIC_RELAXED)) {
    int nlog = 0, ncopied = 0;
    if (sqlite3_wal_checkpoint_v2(db, NULL, SQLITE_CHECKPOINT_PASSIVE, &nlog, &ncopied) == SQLITE_OK && ncopied == nlog)
      wal_pages = 0;  // all copied: the next write restarts the WAL
  }
  send_writes();
  nw = 0;
  sreset();
}

// ---------------------------------------------------------------- setup and loop

static int listener(const char *host, int port) {
  int fd = socket(AF_INET, SOCK_STREAM, 0), one = 1;
  if (fd < 0) die("socket");
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
  setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof one);
  setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
  struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons((uint16_t)port)};
  if (inet_pton(AF_INET, host, &a.sin_addr) != 1) die("bad HOST");
  if (bind(fd, (struct sockaddr *)&a, sizeof a) < 0) die("bind");
  if (listen(fd, BACKLOG) < 0) die("listen");
  return fd;
}

static void ring_init(int ri, int lfd, int slots) {
  ring_t *r = &R[ri];
  struct io_uring_params p = {0};
  p.flags = IORING_SETUP_CQSIZE | IORING_SETUP_SUBMIT_ALL | IORING_SETUP_SINGLE_ISSUER | IORING_SETUP_DEFER_TASKRUN |
            IORING_SETUP_TASKRUN_FLAG;
  p.cq_entries = 8192;
  // Ring memory counts against RLIMIT_MEMLOCK until the kernel frees it, which can be a moment after
  // the previous process exits. Keep the rings small, and retry for a while on a fast restart.
  int rc;
  for (int tries = 0; (rc = io_uring_queue_init_params(1024, &r->u, &p)) == -ENOMEM && tries < 200; tries++) usleep(50000);
  if (rc < 0) { fprintf(stderr, "io_uring_queue_init: %s\n", strerror(-rc)); exit(1); }
  if ((rc = io_uring_register_files_sparse(&r->u, (unsigned)slots)) < 0) { fprintf(stderr, "register files: %s\n", strerror(-rc)); exit(1); }
  // Register the buffer ring by hand: Ubuntu kernels 6.8.0-136 and later (LP #2162843) reject a zero
  // reserved field with EINVAL and accept a nonzero one. A correct kernel takes the first call.
  r->br = mmap(NULL, NBUF * sizeof(struct io_uring_buf), PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_POPULATE, -1, 0);
  if (r->br == MAP_FAILED) die("mmap buf ring");
  io_uring_buf_ring_init(r->br);
  struct io_uring_buf_reg reg = {.ring_addr = (uint64_t)(uintptr_t)r->br, .ring_entries = NBUF, .bgid = 0};
  if ((rc = io_uring_register_buf_ring(&r->u, &reg, 0)) == -EINVAL) {
    reg.resv[0] = 1;
    rc = io_uring_register_buf_ring(&r->u, &reg, 0);
  }
  if (rc < 0) { fprintf(stderr, "buf ring %d: %s\n", ri, strerror(-rc)); exit(1); }
  r->bufs = malloc((size_t)NBUF * BUFSZ);
  for (int i = 0; i < NBUF; i++) io_uring_buf_ring_add(r->br, rbuf(r, (uint16_t)i), BUFSZ, (unsigned short)i, io_uring_buf_ring_mask(NBUF), i);
  io_uring_buf_ring_advance(r->br, NBUF);
  r->c = calloc((size_t)slots, sizeof(conn_t));
  r->rel = malloc(NBUF * sizeof *r->rel);
  r->rearm = malloc((size_t)slots * sizeof *r->rearm);
  r->nslots = slots;
  r->lfd = lfd;
  while (r->nacc < ACCEPTS) arm_accept(ri);
}

static void rbuf_flush(ring_t *r) {
  if (!r->nrel) return;
  for (int i = 0; i < r->nrel; i++)
    io_uring_buf_ring_add(r->br, rbuf(r, r->rel[i]), BUFSZ, r->rel[i], io_uring_buf_ring_mask(NBUF), i);
  io_uring_buf_ring_advance(r->br, r->nrel);
  r->nrel = 0;
}

// Admission control: new connections are accepted only after a pass that kept up (handled fewer
// than PASS_CQES completions). When the loop falls behind, the listen queues fill and the kernel
// holds further connection attempts, so requests do not pile up unread in admitted sockets.
static void end_pass(int behind) {
  for (int ri = 0; ri < nring; ri++) {
    ring_t *r = &R[ri];
    for (int i = 0; i < r->nrearm; i++) {
      uint32_t slot = r->rearm[i];
      conn_t *c = &r->c[slot];
      c->f &= (uint8_t)~F_REARM;
      if ((c->f & F_OPEN) && !(c->f & (F_EOF | F_RECV))) arm_recv(ri, slot);
    }
    r->nrearm = 0;
    if (!behind && !r->full)
      while (r->nacc < ACCEPTS) arm_accept(ri);
  }
}

static void submit_all(void) {
  for (int ri = 0; ri < nring; ri++)
    if (R[ri].dirty) { R[ri].dirty = 0; io_uring_submit(&R[ri].u); }
}

static inline int ring_pending(ring_t *r) {
  return (IO_URING_READ_ONCE(*r->u.sq.kflags) & (IORING_SQ_TASKRUN | IORING_SQ_CQ_OVERFLOW)) != 0;
}

// Runs the ring's deferred task work and handles its completions. Newer kernels run only about 20
// task-work items per enter, so enter again while the kernel still flags pending work. At most
// `budget` completions: under overload a pass stays short, so its responses go out (and their send
// memory is freed) before more requests are read.
static int drain(int ri, int budget) {
  ring_t *r = &R[ri];
  int n = 0;
  for (int k = 0; k < 64 && n < budget; k++) {
    int pend = ring_pending(r);
    if (r->dirty) { r->dirty = 0; io_uring_submit_and_get_events(&r->u); pend = 1; }  // last pass's sends too
    else if (pend) io_uring_get_events(&r->u);
    else if (!io_uring_cq_ready(&r->u)) break;
    unsigned head, c = 0;
    struct io_uring_cqe *q;
    io_uring_for_each_cqe(&r->u, head, q) {
      on_cqe(ri, q);
      if (n + (int)++c >= budget) break;
    }
    io_uring_cq_advance(&r->u, c);
    rbuf_flush(r);
    n += (int)c;
    if (!c && !pend) break;
  }
  return n;
}

static int64_t mono_ns(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (int64_t)t.tv_sec * 1000000000 + t.tv_nsec;
}

int main(void) {
  const char *path = getenv("SQLITE_PATH"), *secret = getenv("JWT_SECRET"), *host = getenv("HOST"), *ps = getenv("PORT");
  if (!path) die("SQLITE_PATH is not set");
  hmac_init(secret ? secret : "");
  memset(B64, -1, sizeof B64);
  const char *al = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
  for (int i = 0; i < 64; i++) B64[(unsigned char)al[i]] = (int8_t)i;
  t_start = time(NULL);
  db_init(path);

  struct rlimit rl;
  getrlimit(RLIMIT_NOFILE, &rl);
  rl.rlim_cur = rl.rlim_max;
  setrlimit(RLIMIT_NOFILE, &rl);
  int slots = rl.rlim_cur > 65535 ? 65535 : (int)rl.rlim_cur - 64;
  if (slots < 64) slots = 64;

  cch = chunk_get();
  int efd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
  nring = NRING;
  for (int ri = 0; ri < nring; ri++) {
    ring_init(ri, listener(host ? host : "0.0.0.0", ps ? atoi(ps) : 3000), slots);
    if (io_uring_register_eventfd(&R[ri].u, efd) < 0) die("register eventfd");
    io_uring_cq_eventfd_toggle(&R[ri].u, false);
    io_uring_submit(&R[ri].u);
  }
  fprintf(stderr, "listening on %s:%s with %d rings x %d slots\n", host ? host : "0.0.0.0", ps ? ps : "3000", nring, slots);

  int first = 0;
  for (;;) {
    int64_t t0 = mono_ns();
    int got = 0;
    // The budget is shared; the first ring rotates so no ring always gets the rest.
    for (int i = 0; i < nring && got < PASS_CQES; i++) got += drain((first + i) % nring, PASS_CQES - got);
    first = (first + 1) % nring;
    if (nq) run_batch();
    end_pass(got >= PASS_CQES);
    if (!got) {
      submit_all();
      // Idle. Let the rings signal the eventfd, look once more, then wait. The kernel signals it when
      // task work is first queued on a ring; the timeout is only a safety net.
      int ready = 0;
      for (int ri = 0; ri < nring; ri++) io_uring_cq_eventfd_toggle(&R[ri].u, true);
      for (int ri = 0; ri < nring; ri++) ready |= ring_pending(&R[ri]) || io_uring_cq_ready(&R[ri].u);
      if (!ready) {
        struct pollfd pf = {.fd = efd, .events = POLLIN};
        poll(&pf, 1, 100);
      }
      uint64_t v;
      if (read(efd, &v, sizeof v) < 0) v = 0;
      for (int ri = 0; ri < nring; ri++) io_uring_cq_eventfd_toggle(&R[ri].u, false);
      continue;
    }
    int64_t left = PACE_NS - (mono_ns() - t0);
    if (left > 0 && got < PASS_CQES) {
      struct timespec ts = {0, left};
      nanosleep(&ts, NULL);
    }
  }
}
