// Feed API: one io_uring event loop, SQLite in-process, group commit per completion batch.
// See README.md for the design. Config comes only from SQLITE_PATH, JWT_SECRET, HOST, PORT.
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <liburing.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <sys/eventfd.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
#include "sqlite3.c"  // one translation unit: reads use its B-tree layer directly

#define MAXREQ (64 * 1024)    // header + body cap per request
#define BATCH_OUT (4 << 20)   // response bytes held per batch until its commit
#define MAXSEG 65536          // responses per batch
#define NBUF 2048             // provided receive buffers per ring: every one gets touched, so they cost RAM
#define BSZ 1024
#ifndef CACHE_KB
#define CACHE_KB 32768        // SQLite page cache
#endif
#define STR2(x) #x
#define STR(x) STR2(x)
#define MAXRINGS 32
#define NLISTEN 8             // SO_REUSEPORT listeners: each has its own accept queue of somaxconn

// A response in flight. who is the connection's receive tag, so a late completion can tell
// whether the connection it belongs to is still the same one.
typedef struct { uint64_t who; uint32_t len, off, cap; char d[]; } sop_t;
typedef struct {
  char *in; uint32_t inlen, incap;  // partial request, or input held while a send is in flight
  sop_t *q;                         // responses queued behind the send in flight
  sop_t *out;                       // the send in flight
  uint32_t gen;
  uint8_t open, closing, sending, eof, sent100, queued, ready;
} conn_t;
// Accepted sockets live in each ring's registered file table, not in the process descriptor table.
// A table can't be larger than RLIMIT_NOFILE, so more rings are added as tables fill up.
typedef struct {
  struct io_uring r;
  conn_t *c; uint32_t n, pend, reads;  // open connections, accepts in flight, single-shot reads in flight
  struct io_uring_buf_ring *br; char *bufs;
} ring_t;
static ring_t R[MAXRINGS];
static int nrings, lfd[NLISTEN];
static uint32_t tsize;  // slots per ring
static sqlite3 *db;
static sqlite3_stmt *st_feed, *st_post, *st_ins, *st_like, *st_one, *st_begin, *st_commit, *st_rollback;
static time_t started, now_s;

// user_data: low 3 bits tag the operation. A send's user_data is its sop_t pointer (tag 0).
enum { T_SEND, T_ACCEPT, T_RECV, T_NOP, T_READ, T_WAL };
#define RECV_UD(k, slot, gen) (T_RECV | (uint64_t)(k) << 3 | (uint64_t)(slot) << 8 | (uint64_t)(gen) << 32)

// Hot regions sit on huge pages where the kernel offers them (Ubuntu's default THP mode is madvise): a TLB miss
// on a VM walks two page tables.
static void *huge_alloc(size_t n) {
  size_t hp = 2u << 20; n = (n + hp - 1) & ~(hp - 1);
  char *p = mmap(NULL, n + hp, PROT_READ | PROT_WRITE, MAP_ANONYMOUS | MAP_PRIVATE, -1, 0);
  if (p == MAP_FAILED) { perror("mmap"); exit(1); }
  char *a = (char *)(((uintptr_t)p + hp - 1) & ~(hp - 1));
  madvise(a, n, MADV_HUGEPAGE);
  return a;
}

// ---------- output: one arena per batch, copied out to sends after COMMIT ----------
static char *arena; static size_t alen;
typedef struct { uint64_t who; uint32_t off, len; } seg_t;
static seg_t segs[MAXSEG]; static int nsegs;
static uint64_t *deferred, *held, *eofs, *limbo; static int ndef, nheld, neof, nlimbo, cap_def, cap_held, cap_eof, cap_limbo;
static int arena_full, in_txn, txn_writes, batch_failed, hold_hit, hold_posts;

static inline void put(const void *p, size_t n) { memcpy(arena + alen, p, n); alen += n; }
#define PUTS(s) put(s, sizeof(s) - 1)
static inline void putu(uint64_t v) {
  char b[24]; int i = 24;
  do { b[--i] = '0' + v % 10; v /= 10; } while (v);
  put(b + i, 24 - i);
}
static const char hexd[] = "0123456789abcdef";
static void putjs(const unsigned char *s, size_t n) {  // JSON string contents, escaped
  size_t i = 0, run = 0;
  // Eight bytes at a time until one needs escaping: almost no text does, so it goes out in one copy.
  #define LO8 0x0101010101010101ULL
  #define HI8 0x8080808080808080ULL
  for (; i + 8 <= n; i += 8) {
    uint64_t v; memcpy(&v, s + i, 8);
    uint64_t q = v ^ (LO8 * '"'), b = v ^ (LO8 * '\\');
    if (((v - LO8 * 0x20) | (q - LO8) | (b - LO8)) & ~v & HI8) break;
  }
  for (; i < n; i++) {
    unsigned char c = s[i];
    if (c >= 0x20 && c != '"' && c != '\\') continue;
    put(s + run, i - run); run = i + 1;
    char e[6] = {'\\', 0};
    switch (c) {
      case '"': e[1] = '"'; put(e, 2); break;
      case '\\': e[1] = '\\'; put(e, 2); break;
      case '\n': e[1] = 'n'; put(e, 2); break;
      case '\r': e[1] = 'r'; put(e, 2); break;
      case '\t': e[1] = 't'; put(e, 2); break;
      default: e[1] = 'u'; e[2] = '0'; e[3] = '0'; e[4] = hexd[c >> 4]; e[5] = hexd[c & 15]; put(e, 6);
    }
  }
  put(s + run, n - run);
}

// response head with a blank Content-Length that finish() fills in
static size_t body_start, cl_pos;
static void begin_resp(int status, int close) {
  switch (status) {
    case 200: PUTS("HTTP/1.1 200 OK\r\n"); break;
    case 201: PUTS("HTTP/1.1 201 Created\r\n"); break;
    case 400: PUTS("HTTP/1.1 400 Bad Request\r\n"); break;
    case 401: PUTS("HTTP/1.1 401 Unauthorized\r\n"); break;
    case 404: PUTS("HTTP/1.1 404 Not Found\r\n"); break;
    case 503: PUTS("HTTP/1.1 503 Service Unavailable\r\n"); break;
    default: PUTS("HTTP/1.1 500 Internal Server Error\r\n"); break;
  }
  if (close) PUTS("Connection: close\r\n");
  PUTS("Content-Type: application/json\r\nContent-Length:       \r\n\r\n");
  cl_pos = alen - 10; body_start = alen;
}
static void finish(void) {
  size_t n = alen - body_start; char *p = arena + cl_pos + 6;
  do { *--p = '0' + n % 10; n /= 10; } while (n);
}
static void err(int status, const char *msg, int close) {
  begin_resp(status, close); PUTS("{\"error\":\""); put(msg, strlen(msg)); PUTS("\"}"); finish();
}

// ---------- SHA-256 / HMAC ----------
typedef struct { uint32_t h[8]; uint64_t n; unsigned char b[64]; uint32_t bl; } sha_t;
static const uint32_t K[64] = {
  0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,
  0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
  0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,
  0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
  0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,
  0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2};
#define ROR(x, n) (((x) >> (n)) | ((x) << (32 - (n))))
static void sha_block(uint32_t *h, const unsigned char *p) {
  uint32_t w[64], a, b, c, d, e, f, g, k, t1, t2;
  for (int i = 0; i < 16; i++) w[i] = (uint32_t)p[4*i] << 24 | p[4*i+1] << 16 | p[4*i+2] << 8 | p[4*i+3];
  for (int i = 16; i < 64; i++) {
    uint32_t s0 = ROR(w[i-15], 7) ^ ROR(w[i-15], 18) ^ (w[i-15] >> 3), s1 = ROR(w[i-2], 17) ^ ROR(w[i-2], 19) ^ (w[i-2] >> 10);
    w[i] = w[i-16] + s0 + w[i-7] + s1;
  }
  a = h[0]; b = h[1]; c = h[2]; d = h[3]; e = h[4]; f = h[5]; g = h[6]; k = h[7];
  for (int i = 0; i < 64; i++) {
    t1 = k + (ROR(e, 6) ^ ROR(e, 11) ^ ROR(e, 25)) + ((e & f) ^ (~e & g)) + K[i] + w[i];
    t2 = (ROR(a, 2) ^ ROR(a, 13) ^ ROR(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
    k = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
  }
  h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e; h[5] += f; h[6] += g; h[7] += k;
}
static void sha_init(sha_t *s) {
  static const uint32_t iv[8] = {0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19};
  memcpy(s->h, iv, 32); s->n = 0; s->bl = 0;
}
static void sha_upd(sha_t *s, const unsigned char *p, size_t n) {
  s->n += n;
  if (s->bl) { size_t t = 64 - s->bl; if (t > n) t = n; memcpy(s->b + s->bl, p, t); s->bl += t; p += t; n -= t; if (s->bl == 64) { sha_block(s->h, s->b); s->bl = 0; } }
  for (; n >= 64; p += 64, n -= 64) sha_block(s->h, p);
  if (n) { memcpy(s->b, p, n); s->bl = n; }
}
static void sha_fin(sha_t *s, unsigned char *out) {
  uint64_t bits = s->n * 8; unsigned char pad = 0x80, z[64] = {0}, len[8];
  sha_upd(s, &pad, 1);
  sha_upd(s, z, (s->bl <= 56 ? 56 : 120) - s->bl);
  for (int i = 0; i < 8; i++) len[i] = bits >> (56 - 8 * i);
  sha_upd(s, len, 8);
  for (int i = 0; i < 8; i++) { out[4*i] = s->h[i] >> 24; out[4*i+1] = s->h[i] >> 16; out[4*i+2] = s->h[i] >> 8; out[4*i+3] = s->h[i]; }
}
static sha_t hm_in, hm_out;  // HMAC key schedule: hash state after absorbing key^ipad / key^opad
static void hmac_key(const char *key) {
  unsigned char k[64] = {0}, pad[64]; size_t kl = strlen(key);
  if (kl > 64) { sha_t s; sha_init(&s); sha_upd(&s, (const unsigned char *)key, kl); sha_fin(&s, k); } else memcpy(k, key, kl);
  for (int i = 0; i < 64; i++) pad[i] = k[i] ^ 0x36;
  sha_init(&hm_in); sha_upd(&hm_in, pad, 64);
  for (int i = 0; i < 64; i++) pad[i] = k[i] ^ 0x5c;
  sha_init(&hm_out); sha_upd(&hm_out, pad, 64);
}
static void hmac(const unsigned char *m, size_t n, unsigned char *out) {
  sha_t s = hm_in; unsigned char ih[32];
  sha_upd(&s, m, n); sha_fin(&s, ih);
  s = hm_out; sha_upd(&s, ih, 32); sha_fin(&s, out);
}

// ---------- base64url ----------
static signed char b64t[256];
static int b64dec(const char *s, size_t n, unsigned char *out) {  // -1 on bad input
  if (n % 4 == 1) return -1;
  uint32_t acc = 0; int bits = 0, o = 0;
  for (size_t i = 0; i < n; i++) {
    int v = b64t[(unsigned char)s[i]]; if (v < 0) return -1;
    acc = acc << 6 | v; bits += 6;
    if (bits >= 8) { bits -= 8; out[o++] = acc >> bits; }
  }
  return o;
}

// ---------- JSON (strict, RFC 8259) ----------
typedef struct { const char *p, *e; } js_t;
static inline void ws(js_t *j) { while (j->p < j->e && (*j->p == ' ' || *j->p == '\t' || *j->p == '\n' || *j->p == '\r')) j->p++; }
static int hexv(int c) { return c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : c >= 'A' && c <= 'F' ? c - 'A' + 10 : -1; }
static int utf8_len(const unsigned char *p, const unsigned char *e) {  // length of one valid UTF-8 sequence, 0 if invalid
  unsigned c = p[0];
  if (c < 0x80) return 1;
  if (c >= 0xc2 && c <= 0xdf) return e - p >= 2 && (p[1] & 0xc0) == 0x80 ? 2 : 0;
  if (c >= 0xe0 && c <= 0xef) {
    if (e - p < 3 || (p[1] & 0xc0) != 0x80 || (p[2] & 0xc0) != 0x80) return 0;
    if ((c == 0xe0 && p[1] < 0xa0) || (c == 0xed && p[1] > 0x9f)) return 0;
    return 3;
  }
  if (c >= 0xf0 && c <= 0xf4) {
    if (e - p < 4 || (p[1] & 0xc0) != 0x80 || (p[2] & 0xc0) != 0x80 || (p[3] & 0xc0) != 0x80) return 0;
    if ((c == 0xf0 && p[1] < 0x90) || (c == 0xf4 && p[1] > 0x8f)) return 0;
    return 4;
  }
  return 0;
}
// Parses the string at j->p (on its opening quote), decoding UTF-8 into out when out is non-NULL.
// Returns the decoded length, -1 on a syntax error, -2 if it doesn't fit in cap (the string is still validated).
static long jstr(js_t *j, char *out, size_t cap) {
  const unsigned char *p = (const unsigned char *)j->p + 1, *e = (const unsigned char *)j->e; size_t o = 0; int over = 0;
  while (p < e) {
    unsigned c = *p;
    if (c == '"') { j->p = (const char *)p + 1; return over ? -2 : (long)o; }
    if (c < 0x20) return -1;
    if (c == '\\') {
      if (++p >= e) return -1;
      char ch;
      switch (*p) {
        case '"': ch = '"'; break; case '\\': ch = '\\'; break; case '/': ch = '/'; break;
        case 'b': ch = '\b'; break; case 'f': ch = '\f'; break; case 'n': ch = '\n'; break;
        case 'r': ch = '\r'; break; case 't': ch = '\t'; break;
        case 'u': {
          if (e - p < 5) return -1;
          int a = hexv(p[1]), b = hexv(p[2]), c2 = hexv(p[3]), d = hexv(p[4]);
          if ((a | b | c2 | d) < 0) return -1;
          uint32_t cp = a << 12 | b << 8 | c2 << 4 | d; p += 4;
          if (cp >= 0xd800 && cp <= 0xdbff && e - p >= 7 && p[1] == '\\' && p[2] == 'u') {
            int a2 = hexv(p[3]), b2 = hexv(p[4]), c3 = hexv(p[5]), d2 = hexv(p[6]);
            if ((a2 | b2 | c3 | d2) < 0) return -1;
            uint32_t lo = a2 << 12 | b2 << 8 | c3 << 4 | d2;
            if (lo >= 0xdc00 && lo <= 0xdfff) { cp = 0x10000 + ((cp - 0xd800) << 10) + (lo - 0xdc00); p += 6; }
          }
          if (cp >= 0xd800 && cp <= 0xdfff) cp = 0xfffd;  // lone surrogate: U+FFFD, as JS TextEncoder does
          char u[4]; int ul;
          if (cp < 0x80) { u[0] = cp; ul = 1; }
          else if (cp < 0x800) { u[0] = 0xc0 | cp >> 6; u[1] = 0x80 | (cp & 63); ul = 2; }
          else if (cp < 0x10000) { u[0] = 0xe0 | cp >> 12; u[1] = 0x80 | (cp >> 6 & 63); u[2] = 0x80 | (cp & 63); ul = 3; }
          else { u[0] = 0xf0 | cp >> 18; u[1] = 0x80 | (cp >> 12 & 63); u[2] = 0x80 | (cp >> 6 & 63); u[3] = 0x80 | (cp & 63); ul = 4; }
          if (out && o + ul > cap) { out = NULL; over = 1; }
          if (out) memcpy(out + o, u, ul);
          o += ul; p++; continue;
        }
        default: return -1;
      }
      if (out && o >= cap) { out = NULL; over = 1; }
      if (out) out[o] = ch;
      o++; p++; continue;
    }
    int l = utf8_len(p, e); if (!l) return -1;
    if (out && o + l > cap) { out = NULL; over = 1; }
    if (out) memcpy(out + o, p, l);
    o += l; p += l;
  }
  return -1;
}
static int jnumber(js_t *j) {
  const char *p = j->p, *e = j->e;
  if (p < e && *p == '-') p++;
  if (p >= e) return 0;
  if (*p == '0') p++; else if (*p >= '1' && *p <= '9') while (p < e && *p >= '0' && *p <= '9') p++; else return 0;
  if (p < e && *p == '.') { p++; if (p >= e || *p < '0' || *p > '9') return 0; while (p < e && *p >= '0' && *p <= '9') p++; }
  if (p < e && (*p == 'e' || *p == 'E')) { p++; if (p < e && (*p == '+' || *p == '-')) p++; if (p >= e || *p < '0' || *p > '9') return 0; while (p < e && *p >= '0' && *p <= '9') p++; }
  j->p = p; return 1;
}
static int jlit(js_t *j, const char *s, size_t n) { if ((size_t)(j->e - j->p) < n || memcmp(j->p, s, n)) return 0; j->p += n; return 1; }
static int jvalue(js_t *j, int depth) {  // validates and skips one value
  if (depth > 64) return 0;
  ws(j); if (j->p >= j->e) return 0;
  switch (*j->p) {
    case '"': return jstr(j, NULL, 0) >= 0;
    case '{':
      j->p++; ws(j);
      if (j->p < j->e && *j->p == '}') { j->p++; return 1; }
      for (;;) {
        ws(j); if (j->p >= j->e || *j->p != '"' || jstr(j, NULL, 0) < 0) return 0;
        ws(j); if (j->p >= j->e || *j->p++ != ':') return 0;
        if (!jvalue(j, depth + 1)) return 0;
        ws(j); if (j->p >= j->e) return 0;
        if (*j->p == ',') { j->p++; continue; }
        if (*j->p == '}') { j->p++; return 1; }
        return 0;
      }
    case '[':
      j->p++; ws(j);
      if (j->p < j->e && *j->p == ']') { j->p++; return 1; }
      for (;;) {
        if (!jvalue(j, depth + 1)) return 0;
        ws(j); if (j->p >= j->e) return 0;
        if (*j->p == ',') { j->p++; continue; }
        if (*j->p == ']') { j->p++; return 1; }
        return 0;
      }
    case 't': return jlit(j, "true", 4);
    case 'f': return jlit(j, "false", 5);
    case 'n': return jlit(j, "null", 4);
    default: return jnumber(j);
  }
}
// Validates a whole document. For a top-level object it records the raw span of the last value of
// each wanted key (the last duplicate wins, as in JSON.parse). Returns 0 if the document is invalid.
typedef struct { const char *key; const char *v, *ve; } want_t;
static int jdoc(const char *s, size_t n, want_t *w, int nw) {
  js_t j = {s, s + n};
  for (int i = 0; i < nw; i++) w[i].v = NULL;
  ws(&j);
  if (j.p < j.e && *j.p == '{') {
    j.p++; ws(&j);
    if (j.p < j.e && *j.p == '}') j.p++;
    else for (;;) {
      char kb[32]; ws(&j);
      if (j.p >= j.e || *j.p != '"') return 0;
      long kl = jstr(&j, kb, sizeof kb);
      if (kl == -1) return 0;
      ws(&j); if (j.p >= j.e || *j.p++ != ':') return 0;
      ws(&j); const char *vs = j.p;
      if (!jvalue(&j, 1)) return 0;
      if (kl >= 0) for (int i = 0; i < nw; i++) if ((size_t)kl == strlen(w[i].key) && !memcmp(kb, w[i].key, kl)) { w[i].v = vs; w[i].ve = j.p; }
      ws(&j); if (j.p >= j.e) return 0;
      if (*j.p == ',') { j.p++; continue; }
      if (*j.p == '}') { j.p++; break; }
      return 0;
    }
  } else if (!jvalue(&j, 0)) return 0;
  ws(&j);
  return j.p == j.e;
}

// ---------- auth ----------
// Returns NULL and fills uid/uname on success, else the message to send with the 401.
static const char *auth(const char *h, size_t hl, int64_t *uid, char *uname, size_t *unl) {
  static const char *bad = "invalid or expired token", *payload = "invalid token payload";
  if (!h || hl < 7 || memcmp(h, "Bearer ", 7)) return "missing bearer token";
  const char *t = h + 7, *te = h + hl, *d1 = memchr(t, '.', te - t), *d2;
  if (!d1) return bad;
  d2 = memchr(d1 + 1, '.', te - d1 - 1);
  if (!d2 || memchr(d2 + 1, '.', te - d2 - 1)) return bad;
  unsigned char sig[48], mac[32], hdr[512], pl[2048];
  if (te - d2 - 1 != 43 || b64dec(d2 + 1, 43, sig) != 32) return bad;
  hmac((const unsigned char *)t, d2 - t, mac);
  unsigned diff = 0; for (int i = 0; i < 32; i++) diff |= sig[i] ^ mac[i];
  if (diff) return bad;
  if (d1 - t > 680 || d2 - d1 - 1 > 2700) return bad;
  int hn = b64dec(t, d1 - t, hdr), pn = b64dec(d1 + 1, d2 - d1 - 1, pl);
  if (hn < 0 || pn < 0) return bad;
  want_t hw[1] = {{"alg"}};
  if (!jdoc((char *)hdr, hn, hw, 1) || !hw[0].v || *hw[0].v != '"') return bad;
  char alg[8]; js_t aj = {hw[0].v, hw[0].ve}; long al = jstr(&aj, alg, sizeof alg);
  if (al != 5 || memcmp(alg, "HS256", 5)) return bad;
  want_t pw[4] = {{"exp"}, {"nbf"}, {"sub"}, {"username"}};
  if (!jdoc((char *)pl, pn, pw, 4) || !pw[0].v) return bad;  // exp is required
  for (int i = 0; i < 2; i++) if (pw[i].v) {  // exp / nbf must be numbers, checked against now
    if (*pw[i].v != '-' && (*pw[i].v < '0' || *pw[i].v > '9')) return bad;
    char nb[64]; size_t l = pw[i].ve - pw[i].v; if (l >= sizeof nb) return bad;
    memcpy(nb, pw[i].v, l); nb[l] = 0; double v = strtod(nb, NULL);
    if (i == 0 ? (double)now_s >= v : (double)now_s < v) return bad;
  }
  if (!pw[2].v || *pw[2].v != '"' || !pw[3].v || *pw[3].v != '"') return payload;
  char sb[24]; js_t sj = {pw[2].v, pw[2].ve}; long sl = jstr(&sj, sb, sizeof sb);
  if (sl <= 0 || sl > 15) return payload;
  int64_t v = 0; for (long i = 0; i < sl; i++) { if (sb[i] < '0' || sb[i] > '9') return payload; v = v * 10 + sb[i] - '0'; }
  if (v <= 0) return payload;
  js_t uj = {pw[3].v, pw[3].ve}; long ul = jstr(&uj, uname, 1024);
  if (ul < 0) return payload;
  *uid = v; *unl = ul; return NULL;
}

// ---------- database ----------
// Reads walk SQLite's own B-tree cursors, inside the batch's transaction; writes and anything unusual use SQL.
static Btree *bt;
static BtCursor *cur_posts, *cur_users, *cur_feed, *cur_likes;
static Pgno root_posts, root_users, root_feed, root_likes;
static KeyInfo *ki_feed, *ki_likes;
static int bt_ok, cur_open;

static void close_cursors(void) {
  if (!cur_open) return;
  sqlite3BtreeCloseCursor(cur_posts); sqlite3BtreeCloseCursor(cur_users);
  sqlite3BtreeCloseCursor(cur_feed); sqlite3BtreeCloseCursor(cur_likes);
  cur_open = 0;
}
static int open_cursors(void) {
  BtCursor *c[4] = {cur_posts, cur_users, cur_feed, cur_likes};
  Pgno roots[4] = {root_posts, root_users, root_feed, root_likes};
  KeyInfo *ki[4] = {NULL, NULL, ki_feed, ki_likes};
  for (int i = 0; i < 4; i++) {
    sqlite3BtreeCursorZero(c[i]);
    if (sqlite3BtreeCursor(bt, roots[i], 0, ki[i], c[i]) != SQLITE_OK) {
      while (i--) sqlite3BtreeCloseCursor(c[i]);
      return 0;
    }
  }
  return cur_open = 1;
}
static int txn(void) {  // opens the batch transaction on first use
  if (in_txn) return 1;
  int rc = sqlite3_step(st_begin); sqlite3_reset(st_begin);
  if (rc != SQLITE_DONE) return 0;
  if (bt_ok && (sqlite3BtreeBeginTrans(bt, 0, 0) != SQLITE_OK || !open_cursors())) {
    sqlite3_step(st_rollback); sqlite3_reset(st_rollback);
    return 0;
  }
  return in_txn = 1;
}
static int wstep(sqlite3_stmt *s) {  // a write inside the batch transaction
  int rc = sqlite3_step(s);
  if (rc == SQLITE_ROW || rc == SQLITE_DONE) txn_writes = 1;
  return rc;
}
static void db_fail(void) {  // a failed statement may have rolled the whole batch back
  if (in_txn && sqlite3_get_autocommit(db)) { close_cursors(); in_txn = 0; if (txn_writes) batch_failed = 1; txn_writes = 0; }
}
static void put_post_row(sqlite3_stmt *s) {
  PUTS("{\"id\":"); putu(sqlite3_column_int64(s, 0));
  PUTS(",\"body\":\""); putjs(sqlite3_column_text(s, 1), sqlite3_column_bytes(s, 1));
  PUTS("\",\"created_at\":\""); put(sqlite3_column_text(s, 2), sqlite3_column_bytes(s, 2));
  PUTS("\",\"author\":\""); putjs(sqlite3_column_text(s, 3), sqlite3_column_bytes(s, 3));
  PUTS("\",\"like_count\":"); putu(sqlite3_column_int64(s, 4)); PUTS("}");
}

// A record's columns, decoded in place. Anything unexpected makes the caller fall back to SQL.
typedef struct { uint32_t type, len; const unsigned char *d; } col_t;
static inline int rec_parse(const unsigned char *p, const unsigned char *e, col_t *out, int nc) {
  uint32_t hs, t, i = getVarint32(p, hs);
  const unsigned char *d = p + hs;
  if (d > e) return 0;
  for (int k = 0; k < nc; k++) {
    if (i >= hs) return 0;
    i += getVarint32(p + i, t);
    if (t == 10 || t == 11) return 0;
    uint32_t l = t >= 12 ? (t - 12) / 2 : sqlite3SmallTypeSizes[t];
    if (d + l > e) return 0;
    out[k] = (col_t){t, l, d}; d += l;
  }
  return 1;
}
static inline int rec_cols(BtCursor *c, col_t *out, int nc) {
  getCellInfo(c);
  if (c->info.nLocal != c->info.nPayload) return 0;  // spills onto overflow pages
  return rec_parse(c->info.pPayload, c->info.pPayload + c->info.nPayload, out, nc);
}
static inline int col_text(const col_t *c) { return c->type >= 13 && (c->type & 1); }
static inline int col_int(const col_t *c, int64_t *v) {
  if (c->type == 8 || c->type == 9) { *v = c->type - 8; return 1; }
  if (c->type < 1 || c->type > 6) return 0;
  int64_t x = (signed char)c->d[0];
  for (uint32_t i = 1; i < c->len; i++) x = x << 8 | c->d[i];
  *v = x; return 1;
}
// Tallies the likes index entries in cells first..last of a page into n[post_id - lo]. Returns 1 to keep walking,
// 0 on reaching a post past hi, -1 on a cell this code won't decode.
static int tally_cells(MemPage *pg, int first, int last, int64_t lo, int64_t hi, uint32_t *n) {
  for (int i = first; i <= last; i++) {
    const unsigned char *cell = findCell(pg, i) + pg->childPtrSize;
    uint32_t size, skip = getVarint32(cell, size);
    col_t key; int64_t post;
    if (size > pg->maxLocal || cell + skip + size > pg->aDataEnd) return -1;
    if (!rec_parse(cell + skip, cell + skip + size, &key, 1) || !col_int(&key, &post)) return -1;
    if (post > hi) return 0;
    if (post >= lo) n[post - lo]++;
  }
  return 1;
}
// Moves the likes cursor to the first entry for a post at or above lo. 1 on an entry, 0 past the end, -1 on error.
static int likes_from(int64_t lo) {
  Mem key; UnpackedRecord want; int cmp = 0;
  memset(&key, 0, sizeof key); key.flags = MEM_Int; key.u.i = lo;
  memset(&want, 0, sizeof want); want.pKeyInfo = cur_likes->pKeyInfo; want.aMem = &key; want.nField = 1;
  want.default_rc = 1;  // an entry equal on post_id compares above the key, so the seek stops before the first of them
  if (sqlite3BtreeIndexMoveto(cur_likes, &want, &cmp) != SQLITE_OK) return -1;
  if (sqlite3BtreeEof(cur_likes)) return 0;
  if (cmp >= 0) return 1;
  int rc = sqlite3BtreeNext(cur_likes, 0);
  return rc == SQLITE_OK ? 1 : rc == SQLITE_DONE ? 0 : -1;
}
// Likes for posts lo..hi, added to n[post - lo], a page at a time. Returns 1 done, 0 for SQL to answer, -1 on error.
static int count_likes(int64_t lo, int64_t hi, uint32_t *n) {
  int on = likes_from(lo);
  while (on == 1) {
    MemPage *pg = cur_likes->pPage;
    int last = pg->leaf ? pg->nCell - 1 : cur_likes->ix;  // on an interior page the entry under the cursor is one key
    int more = tally_cells(pg, cur_likes->ix, last, lo, hi, n);
    if (more <= 0) return more < 0 ? 0 : 1;
    cur_likes->ix = (u16)last;
    on = sqlite3BtreeNext(cur_likes, 0);
    on = on == SQLITE_OK ? 1 : on == SQLITE_DONE ? 0 : -1;
  }
  return on == 0 ? 1 : -1;
}
static inline int seek_row(BtCursor *c, int64_t id) {  // is rowid id there? -1 if the seek itself failed
  int res = 0;
  if (sqlite3BtreeTableMoveto(c, id, 0, &res) != SQLITE_OK) return -1;
  return res == 0 && c->eState == CURSOR_VALID;
}
static inline void put_row(int64_t id, const col_t *body, const unsigned char *ca, uint32_t cal, const col_t *name, uint32_t likes) {
  PUTS("{\"id\":"); putu(id);
  PUTS(",\"body\":\""); putjs(body->d, body->len);
  PUTS("\",\"created_at\":\""); put(ca, cal);
  PUTS("\",\"author\":\""); putjs(name->d, name->len);
  PUTS("\",\"like_count\":"); putu(likes); PUTS("}");
}
// Author of a post: 1 found, 0 use SQL, -1 error. The cell stays valid while cur_users doesn't move.
static inline int row_author(int64_t uid, col_t *name) {
  int rc = seek_row(cur_users, uid); if (rc <= 0) return rc;
  col_t c[2];
  if (!rec_cols(cur_users, c, 2) || !col_text(&c[1])) return 0;
  *name = c[1]; return 1;
}

#define FEED_N 20
#define FEED_SPAN 512  // ids this close together share one walk of the likes index
// The 20 newest off posts_created_at_id_idx, then the rows in ascending id order (consecutive ids are one step
// along a leaf), then one likes walk. Returns 1 when the feed was written, 0 to use SQL, -1 on a database error.
static int feed_btree(int close) {
  static char tmp[BATCH_OUT];
  if (!bt_ok) return 0;
  int64_t ids[FEED_N]; unsigned char ca[FEED_N][32]; uint32_t cal[FEED_N], likes[FEED_N]; int n = 0, empty = 1, ord[FEED_N];
  if (sqlite3BtreeFirst(cur_feed, &empty) != SQLITE_OK) return -1;
  if (!empty) for (;;) {
    col_t c[3];
    if (!rec_cols(cur_feed, c, 3) || !col_text(&c[0]) || c[0].len > sizeof ca[0] || !col_int(&c[1], &ids[n])) return 0;
    memcpy(ca[n], c[0].d, c[0].len); cal[n] = c[0].len;
    if (++n == FEED_N) break;
    int rc = sqlite3BtreeNext(cur_feed, 0);
    if (rc == SQLITE_DONE) break;
    if (rc != SQLITE_OK) return -1;
  }
  for (int i = 0; i < n; i++) {  // newest first is normally descending id, so this is usually just a reversal
    int j = i, v = n - 1 - i;
    while (j > 0 && ids[ord[j - 1]] > ids[v]) { ord[j] = ord[j - 1]; j--; }
    ord[j] = v;
  }
  memset(likes, 0, sizeof likes);
  if (n) {
    int64_t lo = ids[ord[0]], hi = ids[ord[n - 1]];
    if (hi - lo < FEED_SPAN) {
      uint32_t span[FEED_SPAN]; memset(span, 0, (hi - lo + 1) * sizeof span[0]);
      int rc = count_likes(lo, hi, span); if (rc <= 0) return rc;
      for (int i = 0; i < n; i++) likes[i] = span[ids[i] - lo];
    } else for (int i = 0; i < n; i++) { int rc = count_likes(ids[i], ids[i], &likes[i]); if (rc <= 0) return rc; }
  }
  size_t mark = alen; uint32_t at[FEED_N], len[FEED_N];
  begin_resp(200, close); PUTS("{\"posts\":[");
  size_t rows = alen;
  for (int k = 0; k < n; k++) {
    int i = ord[k], rc = seek_row(cur_posts, ids[i]); col_t c[3], name; int64_t uid;
    if (rc < 0) { alen = mark; return -1; }
    if (!rc || !rec_cols(cur_posts, c, 3) || !col_text(&c[2]) || !col_int(&c[1], &uid)) { alen = mark; return 0; }
    rc = row_author(uid, &name);
    if (rc <= 0) { alen = mark; return rc; }
    at[i] = alen - rows; put_row(ids[i], &c[2], ca[i], cal[i], &name, likes[i]); len[i] = alen - rows - at[i];
  }
  size_t total = alen - rows; memcpy(tmp, arena + rows, total); alen = rows;  // back into feed order
  for (int i = 0; i < n; i++) { if (i) PUTS(","); put(tmp + at[i], len[i]); }
  PUTS("]}"); finish(); return 1;
}
// GET /posts/:id. Returns 1 when written, 0 to use SQL (which also answers a missing post), -1 on a database error.
static int post_btree(int64_t id, int close) {
  if (!bt_ok) return 0;
  int rc = seek_row(cur_posts, id); col_t c[4], name; int64_t uid; uint32_t likes = 0;
  if (rc <= 0) return rc;
  if (!rec_cols(cur_posts, c, 4) || !col_text(&c[2]) || !col_text(&c[3]) || !col_int(&c[1], &uid)) return 0;
  if ((rc = row_author(uid, &name)) <= 0) return rc;
  if ((rc = count_likes(id, id, &likes)) <= 0) return rc;
  begin_resp(200, close); PUTS("{\"post\":"); put_row(id, &c[2], c[3].d, c[3].len, &name, likes); PUTS("}"); finish();
  return 1;
}

// ---------- request handling ----------
static int64_t parse_id(const char *s, size_t n) {  // positive decimal integer, else -1 (huge ids saturate: not found)
  if (!n) return -1;
  int64_t v = 0;
  for (size_t i = 0; i < n; i++) { if (s[i] < '0' || s[i] > '9') return -1; if (v < 100000000000000000LL) v = v * 10 + s[i] - '0'; else v = 0x7fffffffffffffffLL; }
  return v > 0 ? v : -1;
}
static int jsws_at(const unsigned char *p, const unsigned char *e) {  // byte length of JS String.trim whitespace at p, or 0
  if (*p == ' ' || (*p >= 9 && *p <= 13)) return 1;
  if (e - p >= 2 && p[0] == 0xc2 && p[1] == 0xa0) return 2;
  if (e - p >= 3) {
    uint32_t c = p[0] << 16 | p[1] << 8 | p[2];
    if (c == 0xe19a80 || (c >= 0xe28080 && c <= 0xe2808a) || c == 0xe280a8 || c == 0xe280a9 || c == 0xe280af || c == 0xe2819f || c == 0xe38080 || c == 0xefbbbf) return 3;
  }
  return 0;
}
static int jsws_before(const unsigned char *s, const unsigned char *e) {
  if (e[-1] == ' ' || (e[-1] >= 9 && e[-1] <= 13)) return 1;
  if (e - s >= 2 && e[-2] == 0xc2 && e[-1] == 0xa0) return 2;
  if (e - s >= 3 && jsws_at(e - 3, e) == 3) return 3;
  return 0;
}

static void handle(const char *m, size_t ml, const char *path, size_t pl, const char *authh, size_t al,
                   const char *body, size_t bl, int close) {
  const char *q = memchr(path, '?', pl); if (q) pl = q - path;
  int get = ml == 3 && !memcmp(m, "GET", 3), post = ml == 4 && !memcmp(m, "POST", 4);
  int rc;
  if (get && pl == 5 && !memcmp(path, "/feed", 5)) {
    if (!txn()) { err(500, "internal server error", close); return; }
    if ((rc = feed_btree(close))) { if (rc < 0) { db_fail(); err(500, "internal server error", close); } return; }
    size_t mark = alen;
    begin_resp(200, close); PUTS("{\"posts\":[");
    int i = 0;
    while ((rc = sqlite3_step(st_feed)) == SQLITE_ROW) { if (i++) PUTS(","); put_post_row(st_feed); }
    sqlite3_reset(st_feed);
    if (rc != SQLITE_DONE) { db_fail(); alen = mark; err(500, "internal server error", close); return; }
    PUTS("]}"); finish(); return;
  }
  if (pl > 7 && !memcmp(path, "/posts/", 7)) {
    const char *seg = path + 7, *sl = memchr(seg, '/', pl - 7);
    if (get && !sl) {
      int64_t id = parse_id(seg, pl - 7);
      if (id < 0) { err(400, "invalid post id", close); return; }
      if (!txn()) { err(500, "internal server error", close); return; }
      if ((rc = post_btree(id, close))) { if (rc < 0) { db_fail(); err(500, "internal server error", close); } return; }
      sqlite3_bind_int64(st_post, 1, id);
      size_t mark = alen;
      rc = sqlite3_step(st_post);
      if (rc == SQLITE_ROW) { begin_resp(200, close); PUTS("{\"post\":"); put_post_row(st_post); PUTS("}"); finish(); }
      else if (rc == SQLITE_DONE) err(404, "post not found", close);
      else { db_fail(); alen = mark; err(500, "internal server error", close); }
      sqlite3_reset(st_post); return;
    }
    if (post && sl && (size_t)(path + pl - sl) == 5 && !memcmp(sl, "/like", 5)) {
      int64_t uid; char un[1024]; size_t unl;
      const char *e = auth(authh, al, &uid, un, &unl);
      if (e) { err(401, e, close); return; }
      int64_t id = parse_id(seg, sl - seg);
      if (id < 0) { err(400, "invalid post id", close); return; }
      if (!txn()) { err(500, "internal server error", close); return; }
      rc = bt_ok ? seek_row(cur_posts, id) : 1;  // without B-tree reads the statement's own EXISTS decides
      if (rc < 0) { db_fail(); err(500, "internal server error", close); return; }
      if (!rc) { err(404, "post not found", close); return; }
      sqlite3_bind_int64(st_like, 1, uid); sqlite3_bind_int64(st_like, 2, id);
      rc = wstep(st_like); sqlite3_reset(st_like);
      if (rc != SQLITE_DONE) { db_fail(); err(500, "internal server error", close); return; }
      int created = sqlite3_changes(db) > 0;
      if (!created && !bt_ok) {
        sqlite3_bind_int64(st_post, 1, id);
        rc = sqlite3_step(st_post); sqlite3_reset(st_post);
        if (rc == SQLITE_DONE) { err(404, "post not found", close); return; }
        if (rc != SQLITE_ROW) { db_fail(); err(500, "internal server error", close); return; }
      }
      begin_resp(created ? 201 : 200, close);
      PUTS("{\"liked\":true,\"already_liked\":"); if (created) PUTS("false"); else PUTS("true");
      PUTS(",\"post_id\":"); putu(id); PUTS("}"); finish(); return;
    }
  }
  if (post && pl == 6 && !memcmp(path, "/posts", 6)) {
    int64_t uid; char un[1024]; size_t unl;
    const char *e = auth(authh, al, &uid, un, &unl);
    if (e) { err(401, e, close); return; }
    want_t w[1] = {{"body"}};
    if (!jdoc(body, bl, w, 1)) { err(400, "malformed JSON body", close); return; }
    if (!w[0].v || *w[0].v != '"') { err(400, "body is required", close); return; }
    static char txt[MAXREQ]; js_t bj = {w[0].v, w[0].ve};
    long n = jstr(&bj, txt, sizeof txt);
    if (n < 0) { err(400, "malformed JSON body", close); return; }
    const unsigned char *s = (unsigned char *)txt, *se = s + n; int l;
    while (s < se && (l = jsws_at(s, se))) s += l;
    while (se > s && (l = jsws_before(s, se))) se -= l;
    if (s == se || !*s) { err(400, "body is required", close); return; }  // length() stops at a NUL, so the CHECK would fail
    size_t chars = 0; for (const unsigned char *c = s; c < se; c++) chars += (*c & 0xc0) != 0x80;
    if (chars > 500) { err(400, "body must be at most 500 characters", close); return; }
    if (!txn()) { err(500, "internal server error", close); return; }
    sqlite3_bind_int64(st_ins, 1, uid); sqlite3_bind_text(st_ins, 2, (const char *)s, se - s, SQLITE_STATIC);
    rc = wstep(st_ins);
    if (rc != SQLITE_ROW) { sqlite3_reset(st_ins); db_fail(); err(500, "internal server error", close); return; }
    size_t mark = alen;
    begin_resp(201, close);
    PUTS("{\"post\":{\"id\":"); putu(sqlite3_column_int64(st_ins, 0));
    PUTS(",\"body\":\""); putjs(s, se - s);
    PUTS("\",\"created_at\":\""); put(sqlite3_column_text(st_ins, 1), sqlite3_column_bytes(st_ins, 1));
    PUTS("\",\"author\":\""); putjs((unsigned char *)un, unl); PUTS("\",\"like_count\":0}}"); finish();
    rc = sqlite3_step(st_ins); sqlite3_reset(st_ins);  // run RETURNING to completion so the insert finishes
    if (rc != SQLITE_DONE) { db_fail(); alen = mark; err(500, "internal server error", close); }
    return;
  }
  if (get && pl == 7 && !memcmp(path, "/health", 7)) {
    rc = sqlite3_step(st_one); sqlite3_reset(st_one);
    if (rc == SQLITE_ROW) {
      begin_resp(200, close); PUTS("{\"status\":\"ok\",\"db\":\"ok\",\"uptime_s\":"); putu(now_s - started); PUTS("}"); finish();
    } else {
      begin_resp(503, close); PUTS("{\"status\":\"degraded\",\"db\":\"unreachable\",\"error\":\"");
      const char *m2 = sqlite3_errmsg(db); putjs((const unsigned char *)m2, strlen(m2)); PUTS("\"}"); finish();
    }
    return;
  }
  err(404, "not found", close);
}

static uint8_t no_conn, *sent100 = &no_conn;  // the current connection's "100 Continue already sent" flag
static int hdr_is(const char *p, size_t n, const char *name, size_t nl) { return n == nl && !strncasecmp(p, name, nl); }

// Serves every complete request in buf. Returns bytes consumed, or -1 to drop the connection.
static long serve(char *buf, size_t n, int *closing) {
  size_t used = 0;
  while (used < n && !*closing) {
    char *p = buf + used, *e = buf + n;
    if (alen + 2 * MAXREQ > BATCH_OUT || nsegs == MAXSEG) { arena_full = 1; break; }  // the rest waits for the next batch
    if (hold_posts && *p == 'P') { hold_hit = 1; break; }  // a POST waits, unread, while the last of the log is copied back
    char *he = memmem(p, e - p, "\r\n\r\n", 4);
    if (!he) { if ((size_t)(e - p) > MAXREQ) return -1; break; }
    char *le = memchr(p, '\r', he + 2 - p);
    char *m = p, *sp1 = memchr(m, ' ', le - m); if (!sp1) return -1;
    char *path = sp1 + 1, *sp2 = memchr(path, ' ', le - path); if (!sp2) return -1;
    int http10 = le - sp2 - 1 == 8 && !memcmp(sp2 + 1, "HTTP/1.0", 8);
    const char *authh = NULL; size_t al = 0, clen = 0; int close = http10, expect = 0;
    for (char *h = le + 2; h < he + 2;) {
      char *hl = memchr(h, '\r', he + 2 - h), *c;
      if (!hl) return -1;  // a bare CR just before the end of the head
      c = memchr(h, ':', hl - h);
      if (c) {
        char *v = c + 1; while (v < hl && (*v == ' ' || *v == '\t')) v++;
        char *ve = hl; while (ve > v && (ve[-1] == ' ' || ve[-1] == '\t')) ve--;
        size_t kn = c - h;
        if (hdr_is(h, kn, "content-length", 14)) { clen = 0; for (char *d = v; d < ve; d++) { if (*d < '0' || *d > '9') return -1; clen = clen * 10 + *d - '0'; if (clen > MAXREQ) return -1; } }
        else if (hdr_is(h, kn, "authorization", 13)) { authh = v; al = ve - v; }
        else if (hdr_is(h, kn, "connection", 10)) { if (ve - v == 5 && !strncasecmp(v, "close", 5)) close = 1; else if (ve - v == 10 && !strncasecmp(v, "keep-alive", 10)) close = 0; }
        else if (hdr_is(h, kn, "expect", 6)) expect = ve - v == 12 && !strncasecmp(v, "100-continue", 12);
        else if (hdr_is(h, kn, "transfer-encoding", 17)) return -1;  // chunked uploads aren't supported
      }
      h = hl + 2;
    }
    char *body = he + 4;
    if ((size_t)(e - body) < clen) {
      if (expect && body == e && !*sent100) { PUTS("HTTP/1.1 100 Continue\r\n\r\n"); *sent100 = 1; }
      break;
    }
    *sent100 = 0;
    handle(m, sp1 - m, path, sp2 - path, authh, al, body, clen, close);
    if (close) *closing = 1;
    used = body + clen - buf;
  }
  return used;
}

// ---------- connections ----------
#define K(who) ((int)((who) >> 3 & 31))
#define SLOT(who) ((int)((who) >> 8 & 0xffffff))
static conn_t *conn_of(uint64_t who) {  // NULL once that connection has closed
  conn_t *c = &R[K(who)].c[SLOT(who)];
  return c->open && c->gen == (uint32_t)(who >> 32) ? c : NULL;
}
static void push(uint64_t **a, int *n, int *cap, uint64_t v) {
  if (*n == *cap) { *cap = *cap ? *cap * 2 : 1024; *a = realloc(*a, *cap * sizeof **a); }
  (*a)[(*n)++] = v;
}
static struct io_uring_sqe *sqe(int k) {
  struct io_uring_sqe *s;
  while (!(s = io_uring_get_sqe(&R[k].r))) io_uring_submit(&R[k].r);
  return s;
}
typedef struct { uint64_t *a; int head, n, cap; } fifo_t;
static fifo_t readq, readyq;  // connections to read, connections with bytes read and not yet answered
static void conn_close(uint64_t who) {
  int k = K(who), slot = SLOT(who); ring_t *r = &R[k]; conn_t *c = &r->c[slot];
  free(c->in); free(c->q);  // a send still in flight frees its own buffer when it completes
  sop_t *out = c->sending ? c->out : NULL;
  uint32_t g = c->gen + 1; memset(c, 0, sizeof *c); c->gen = g; r->n--;
  if (io_uring_sq_space_left(&r->r) < 3) io_uring_submit(&r->r);  // keep the chain in one submission
  // End the pending receive (and send), then free the slot. They are cancelled by their tags, which the
  // kernel finds in a hash table; cancelling by descriptor would scan every pending operation on the
  // ring, one per open connection.
  struct io_uring_sqe *s = sqe(k);
  io_uring_prep_cancel64(s, who, 0); s->flags |= IOSQE_IO_HARDLINK; s->user_data = T_NOP;
  if (out) { s = sqe(k); io_uring_prep_cancel64(s, (uintptr_t)out, 0); s->flags |= IOSQE_IO_HARDLINK; s->user_data = T_NOP; }
  s = sqe(k); io_uring_prep_close_direct(s, slot); s->user_data = T_NOP;
}
static void queue_read(uint64_t who, conn_t *c) {
  if (!c->queued) { c->queued = 1; push(&readq.a, &readq.n, &readq.cap, who); }
}
static void arm_recv(uint64_t who) {  // multishot: one completion per chunk, into a provided buffer
  struct io_uring_sqe *s = sqe(K(who));
  io_uring_prep_recv_multishot(s, SLOT(who), NULL, 0, 0);
  s->flags |= IOSQE_FIXED_FILE | IOSQE_BUFFER_SELECT; s->buf_group = 0; s->user_data = who;
}
static void send_op(sop_t *o) {
  struct io_uring_sqe *s = sqe(K(o->who));
  io_uring_prep_send(s, SLOT(o->who), o->d + o->off, o->len - o->off, MSG_NOSIGNAL);
  s->flags |= IOSQE_FIXED_FILE; s->user_data = (uintptr_t)o;
}
// One send in flight per connection keeps responses in order; later ones queue behind it.
// Sends finish inline, so a small LIFO pool keeps handing out the buffer most recently written, still in cache.
#define POOL_CAP (8192 - sizeof(sop_t))
#define POOL_MAX 512
static sop_t *pool[POOL_MAX]; static int npool;
static inline sop_t *sop_new(uint32_t n) {
  if (n <= POOL_CAP && npool) return pool[--npool];
  return malloc(sizeof(sop_t) + (n <= POOL_CAP ? POOL_CAP : n));
}
static inline void sop_free(sop_t *o) {
  if (o->cap == POOL_CAP && npool < POOL_MAX) pool[npool++] = o; else free(o);
}
static void send_bytes(uint64_t who, conn_t *c, const char *p, uint32_t n) {
  if (!c->sending) {
    sop_t *o = sop_new(n); *o = (sop_t){who, n, 0, n <= POOL_CAP ? (uint32_t)POOL_CAP : n}; memcpy(o->d, p, n);
    c->sending = 1; c->out = o; send_op(o); return;
  }
  sop_t *q = c->q;
  if (!q || q->cap - q->len < n) {
    uint32_t len = q ? q->len : 0, cap = (len + n) * 2;
    q = realloc(q, sizeof *q + cap); *q = (sop_t){who, len, 0, cap}; c->q = q;
  }
  memcpy(q->d + q->len, p, n); q->len += n;
}

static void process(uint64_t who, conn_t *c, char *buf, size_t n) {
  uint32_t start = alen; int closing = 0; arena_full = hold_hit = 0;
  sent100 = &c->sent100;
  long used = serve(buf, n, &closing);
  if (used < 0) { alen = start; conn_close(who); return; }
  if (alen > start) segs[nsegs++] = (seg_t){who, start, alen - start};
  c->closing = closing;
  size_t left = closing ? 0 : n - used;
  if (left) {
    if (buf != c->in) { c->incap = left + BSZ; c->in = malloc(c->incap); memcpy(c->in, buf + used, left); }
    else if (used) memmove(c->in, c->in + used, left);
    c->inlen = left;
    if (arena_full) push(&deferred, &ndef, &cap_def, who);
    if (hold_hit) push(&held, &nheld, &cap_held, who);
  } else if (c->in) { free(c->in); c->in = NULL; c->inlen = c->incap = 0; }
  if (alen == start && (closing || (c->eof && !c->sending && !arena_full && !hold_hit))) conn_close(who);
}
// After a stall every connection has a request waiting. Letting them sit costs a socket buffer each (3 to 4 KB, toward
// TCP's limit) and answering them all makes one very long pass, so a pass answers ANSWERS and reads READS: the rest
// wait on their connection, in a copy the size of the request, on a first-in, first-out list.
#define ANSWERS 1024
#define READS 4096
static int answers_left = ANSWERS;
static inline uint64_t fifo_pop(fifo_t *f) {
  uint64_t v = f->a[f->head++];
  if (f->head == f->n) f->head = f->n = 0;
  else if (f->head >= 65536 && f->head * 2 >= f->n) { f->n -= f->head; memmove(f->a, f->a + f->head, f->n * sizeof *f->a); f->head = 0; }
  return v;
}
static void on_data(uint64_t who, conn_t *c, const char *p, uint32_t n) {
  if (c->closing) return;  // answering Connection: close, anything after it is ignored
  int later = c->ready || !answers_left;
  if (!later) answers_left--;
  if (!later && !c->inlen && !c->sending) { process(who, c, (char *)p, n); return; }
  if (c->incap - c->inlen < n) { c->incap = (c->inlen + n) * 2; c->in = realloc(c->in, c->incap); }
  memcpy(c->in + c->inlen, p, n); c->inlen += n;
  if (c->inlen > 4 * MAXREQ) { conn_close(who); return; }  // keeps sending but won't read its replies
  if (later) { if (!c->ready) { c->ready = 1; push(&readyq.a, &readyq.n, &readyq.cap, who); } }
  else if (!c->sending) process(who, c, c->in, c->inlen);
}
static void run_ready(void) {  // with the answers this pass has left, what earlier passes read, oldest first
  while (answers_left && readyq.n) {
    uint64_t who = fifo_pop(&readyq); conn_t *c = conn_of(who);
    if (!c) continue;
    c->ready = 0;
    if (c->inlen && !c->sending) { answers_left--; process(who, c, c->in, c->inlen); }
  }
}
static void send_done(sop_t *o, int res) {
  uint64_t who = o->who; conn_t *c = conn_of(who);
  if (c && res > 0 && (o->off += res) < o->len) { send_op(o); return; }  // short send: the rest
  // A closed connection's cancel may still be queued, naming this address: it stays unused until that has gone in.
  if (!c) { push(&limbo, &nlimbo, &cap_limbo, (uintptr_t)o); return; }
  sop_free(o);
  if (res <= 0) { c->sending = 0; conn_close(who); return; }
  if (c->q) { o = c->q; c->q = NULL; c->out = o; send_op(o); return; }
  c->sending = 0;
  if (c->closing) conn_close(who);
  else if (c->inlen) process(who, c, c->in, c->inlen);  // input that arrived while sending
  else if (c->eof) conn_close(who);
}

// Commits the batch, then sends every response produced in it.
static void flush_batch(void) {
  if (in_txn) {
    close_cursors();
    int rc = sqlite3_step(st_commit); sqlite3_reset(st_commit);
    if (rc != SQLITE_DONE) { sqlite3_step(st_rollback); sqlite3_reset(st_rollback); if (txn_writes) batch_failed = 1; }
    in_txn = 0; txn_writes = 0;
  }
  for (int i = 0; i < nsegs; i++) {
    conn_t *c = conn_of(segs[i].who);
    if (!c) continue;
    if (batch_failed) { conn_close(segs[i].who); continue; }  // the batch wasn't committed: never claim it was
    send_bytes(segs[i].who, c, arena + segs[i].off, segs[i].len);
  }
  nsegs = 0; alen = 0; batch_failed = 0;
}

// ---------- rings ----------
// Some Ubuntu 6.8 kernels (0-136 and later, Launchpad #2162843) refuse a registration whose reserved words
// are all zero and accept resv[0] = 1; every other kernel takes the zeroes, so those are tried first.
static struct io_uring_buf_ring *buf_ring(struct io_uring *u) {
  void *p = mmap(NULL, NBUF * sizeof(struct io_uring_buf), PROT_READ | PROT_WRITE, MAP_ANONYMOUS | MAP_PRIVATE, -1, 0);
  if (p == MAP_FAILED) return NULL;
  struct io_uring_buf_reg reg = {.ring_addr = (uintptr_t)p, .ring_entries = NBUF};
  int rc = io_uring_register_buf_ring(u, &reg, 0);
  if (rc == -EINVAL) { reg.resv[0] = 1; rc = io_uring_register_buf_ring(u, &reg, 0); }
  if (rc < 0) { munmap(p, NBUF * sizeof(struct io_uring_buf)); return NULL; }
  io_uring_buf_ring_init(p);
  return p;
}
static int ring_init(int k) {
  ring_t *r = &R[k];
  // DEFER_TASKRUN on every ring: completion work runs when the loop asks, in one batch, never interrupting a pass.
  struct io_uring_params p = {.flags = IORING_SETUP_SUBMIT_ALL | IORING_SETUP_SINGLE_ISSUER | IORING_SETUP_CQSIZE |
                              IORING_SETUP_DEFER_TASKRUN, .cq_entries = 16384};
  if (io_uring_queue_init_params(4096, &r->r, &p) < 0) return -1;
  if (io_uring_register_files_sparse(&r->r, tsize) < 0 || !(r->br = buf_ring(&r->r))) {
    io_uring_queue_exit(&r->r); return -1;
  }
  io_uring_register_ring_fd(&r->r);
  r->c = huge_alloc(tsize * sizeof *r->c); r->bufs = huge_alloc((size_t)NBUF * BSZ);
  for (int i = 0; i < NBUF; i++) io_uring_buf_ring_add(r->br, r->bufs + (size_t)i * BSZ, BSZ, i, NBUF - 1, i);
  io_uring_buf_ring_advance(r->br, NBUF);
  if (k) fprintf(stderr, "%u connections: added ring %d\n", k * (tsize - 16), k);
  nrings = k + 1;
  return 0;
}
// Accepts are single-shot, a few in flight, on the first ring with room. An accept that finds its
// table full has already taken the connection and can only drop it, so tables are never filled to the
// last slot (closes still in flight may hold a few) and a multishot accept can't be stopped in time.
// Each listener keeps its own share armed: connections are hashed to listeners, so a listener with none armed
// would leave its queue waiting while accepts armed on idle listeners never complete.
#define ACCEPTS 64  // per listener, rearmed once per loop pass, so this caps accepts per pass (16 in total held ramps to ~1.7k/s)
static int armed[NLISTEN];
static void arm_accepts(void) {
  for (int l = 0, k = 0; l < NLISTEN; l++) {
    while (armed[l] < ACCEPTS && k < MAXRINGS) {
      if (k == nrings && ring_init(k) < 0) return;  // retried after the next event
      if (R[k].n + R[k].pend + 16 >= tsize) { k++; continue; }
      struct io_uring_sqe *s = sqe(k);
      io_uring_prep_accept_direct(s, lfd[l], NULL, NULL, 0, IORING_FILE_INDEX_ALLOC); s->user_data = T_ACCEPT | (uint64_t)l << 3;
      R[k].pend++; armed[l]++;
    }
  }
}
static uint64_t wal_msg, wal_outcome;
static int wal_replies = -1;
static void arm_wal_msg(void) {  // the worker's reply arrives as a completion on ring 0
  struct io_uring_sqe *s = sqe(0); io_uring_prep_read(s, wal_replies, &wal_msg, 8, 0); s->user_data = T_WAL;
}
static void on_cqe(int k, uint64_t ud, int res, unsigned f) {
  ring_t *r = &R[k]; conn_t *c;
  switch (ud & 7) {
    case T_SEND: send_done((sop_t *)(uintptr_t)ud, res); break;
    case T_ACCEPT:
      r->pend--; armed[ud >> 3]--;
      if (res >= 0) { c = &r->c[res]; c->open = 1; r->n++; arm_recv(RECV_UD(k, res, c->gen)); }
      break;
    case T_RECV:
      c = conn_of(ud);
      if (f & IORING_CQE_F_BUFFER) {
        int bid = f >> IORING_CQE_BUFFER_SHIFT; char *p = r->bufs + (size_t)bid * BSZ;
        if (c && res > 0) on_data(ud, c, p, res);
        io_uring_buf_ring_add(r->br, p, BSZ, bid, NBUF - 1, 0); io_uring_buf_ring_advance(r->br, 1);
      }
      if (!(f & IORING_CQE_F_MORE) && (c = conn_of(ud))) {
        // Out of buffers: rearming every receive at once would repeat that, so the rest is read in bounded rounds.
        if (res > 0 || res == -ENOBUFS) queue_read(ud, c);
        else { c->eof = 1; push(&eofs, &neof, &cap_eof, ud); }  // the same pass may hold this client's last reply
      }
      break;
    case T_WAL: wal_outcome = res == 8 ? wal_msg : 1; arm_wal_msg(); break;
    case T_READ: {
      uint64_t who = (ud & ~7ULL) | T_RECV;
      r->reads--; c = conn_of(who);
      if (f & IORING_CQE_F_BUFFER) {
        int bid = f >> IORING_CQE_BUFFER_SHIFT; char *p = r->bufs + (size_t)bid * BSZ;
        if (c && res > 0) on_data(who, c, p, res);
        io_uring_buf_ring_add(r->br, p, BSZ, bid, NBUF - 1, 0); io_uring_buf_ring_advance(r->br, 1);
      }
      if (!(c = conn_of(who))) break;
      if (res == BSZ || res == -ENOBUFS) queue_read(who, c);  // a full buffer: there may be more
      else if (res > 0 || res == -EAGAIN) arm_recv(who);  // drained: back to the multishot receive
      else { c->eof = 1; push(&eofs, &neof, &cap_eof, who); }
      break;
    }
  }
}
static unsigned drain(int k);
// One MSG_DONTWAIT read per queued connection, never more on a ring than it has buffers. They finish inside the submit.
static unsigned read_rounds(void) {
  unsigned seen = 0;
  for (int budget = READS; budget > 0 && readq.n;) {
    int issued = 0, stop = readq.n - readq.head;
    for (int i = 0; i < stop && issued < budget; i++) {
      uint64_t who = fifo_pop(&readq); conn_t *c = conn_of(who); int k = K(who);
      if (!c) continue;
      if (R[k].reads >= NBUF) { push(&readq.a, &readq.n, &readq.cap, who); continue; }
      c->queued = 0; R[k].reads++; issued++;
      struct io_uring_sqe *s = sqe(k);
      io_uring_prep_recv(s, SLOT(who), NULL, 0, MSG_DONTWAIT);
      s->flags |= IOSQE_FIXED_FILE | IOSQE_BUFFER_SELECT; s->buf_group = 0; s->user_data = (who & ~7ULL) | T_READ;
    }
    if (!issued) break;
    budget -= issued;
    for (int k = 0; k < nrings; k++) { io_uring_submit_and_get_events(&R[k].r); seen += drain(k); }
  }
  return seen;
}
static unsigned drain(int k) {
  struct io_uring_cqe *cqe; unsigned head, n = 0;
  io_uring_for_each_cqe(&R[k].r, head, cqe) { on_cqe(k, cqe->user_data, cqe->res, cqe->flags); n++; }
  io_uring_cq_advance(&R[k].r, n);
  return n;
}

#define WAIT_N 128        // completions a busy pass waits for, shared across the rings
#define WAIT_NS 2000000   // or this long, whichever is first
static int wal_hold_over(void);
static void wal_after_commit(void);
static void run(void) {
  unsigned seen = 0;
  for (;;) {
    arm_accepts();
    uint32_t open = R[0].n;
    for (int k = 1; k < nrings; k++) { open += R[k].n; io_uring_submit_and_get_events(&R[k].r); }
    // Busy, or more than one ring to look at: wait for ring 0's share of a batch or a short timeout, whichever is
    // first. The target is capped by the open connections so a few clients without think time never sit out the timer.
    int rc; struct io_uring_cqe *cq;
    if (readq.n || readyq.n) rc = io_uring_submit_and_get_events(&R[0].r);  // work is waiting here: no sleeping
    else if (seen >= 4 || nrings > 1 || nheld) {
      unsigned want = seen >= 4 ? WAIT_N / nrings + 1 : 1;
      if (want > open / 3 + 1) want = open / 3 + 1;
      struct __kernel_timespec ts = {.tv_nsec = WAIT_NS};
      rc = io_uring_submit_and_wait_timeout(&R[0].r, &cq, want, &ts, NULL);
    } else rc = io_uring_submit_and_wait(&R[0].r, 1);
    for (int i = 0; i < nlimbo; i++) sop_free((sop_t *)(uintptr_t)limbo[i]);  // those cancels are in now
    nlimbo = 0;
    if (rc < 0 && rc != -EINTR && rc != -EBUSY && rc != -ETIME && rc != -EAGAIN) { fprintf(stderr, "io_uring_enter: %s\n", strerror(-rc)); exit(1); }
    now_s = time(NULL); seen = 0;
    answers_left = ANSWERS;
    // Requests that just arrived go first. After a stall the backlog has missed any latency target already; answered
    // first, it would make everything behind it miss too.
    for (int k = 0; k < nrings; k++) seen += drain(k);
    run_ready();
    seen += read_rounds();
    flush_batch();
    if (neof) {  // clients that finished sending: close once what they sent has been answered
      for (int i = 0; i < neof; i++) {
        conn_t *c = conn_of(eofs[i]);
        if (!c || c->sending) continue;  // the send's completion takes it from here
        if (c->inlen) process(eofs[i], c, c->in, c->inlen); else conn_close(eofs[i]);
      }
      neof = 0; flush_batch();
    }
    while (ndef) {  // requests held back by a full arena
      uint64_t *todo = deferred; int n = ndef; deferred = NULL; ndef = cap_def = 0;
      for (int i = 0; i < n; i++) { conn_t *c = conn_of(todo[i]); if (c && c->inlen && !c->sending) process(todo[i], c, c->in, c->inlen); }
      free(todo); flush_batch();
    }
    wal_after_commit();
    if (nheld && wal_hold_over()) {
      uint64_t *todo = held; int n = nheld; held = NULL; nheld = cap_held = 0;
      for (int i = 0; i < n; i++) { conn_t *c = conn_of(todo[i]); if (c && c->inlen && !c->sending) process(todo[i], c, c->in, c->inlen); }
      free(todo); flush_batch();
    }
  }
}

static sqlite3_stmt *prep(const char *sql) {
  sqlite3_stmt *s;
  if (sqlite3_prepare_v3(db, sql, -1, SQLITE_PREPARE_PERSISTENT, &s, NULL) != SQLITE_OK) { fprintf(stderr, "prepare: %s: %s\n", sqlite3_errmsg(db), sql); exit(1); }
  return s;
}
static Pgno rootpage(const char *name) {
  sqlite3_stmt *st; Pgno r = 0;
  if (sqlite3_prepare_v2(db, "SELECT rootpage FROM sqlite_schema WHERE name = ?", -1, &st, NULL) != SQLITE_OK) return 0;
  sqlite3_bind_text(st, 1, name, -1, SQLITE_STATIC);
  if (sqlite3_step(st) == SQLITE_ROW) r = sqlite3_column_int(st, 0);
  sqlite3_finalize(st);
  return r;
}
static int layout_is(const char *sql, const char *want) {  // the decoders assume these exact columns
  sqlite3_stmt *st; int ok = 0;
  if (sqlite3_prepare_v2(db, sql, -1, &st, NULL) != SQLITE_OK) return 0;
  if (sqlite3_step(st) == SQLITE_ROW) { const char *t = (const char *)sqlite3_column_text(st, 0); ok = t && !strcmp(t, want); }
  sqlite3_finalize(st);
  return ok;
}
static KeyInfo *key_info(int nkey, int nextra, int desc) {
  KeyInfo *k = sqlite3KeyInfoAlloc(db, nkey, nextra);
  if (!k) return NULL;
  for (int i = 0; i < nkey + nextra; i++) k->aColl[i] = db->pDfltColl;
  for (int i = 0; i < nkey; i++) k->aSortFlags[i] = desc ? KEYINFO_ORDER_DESC : 0;
  return k;
}
static void btree_setup(void) {  // leaves bt_ok 0 (SQL for every read) on anything unexpected
  bt_ok = ENC(db) == SQLITE_UTF8
    && layout_is("SELECT group_concat(name) FROM pragma_table_info('posts')", "id,user_id,body,created_at")
    && layout_is("SELECT group_concat(name) FROM pragma_table_info('users')", "id,username,created_at")
    && layout_is("SELECT group_concat(name) FROM pragma_index_info('posts_created_at_id_idx')", "created_at,id")
    && layout_is("SELECT group_concat(name) FROM pragma_index_info('likes_post_id_idx')", "post_id")
    && layout_is("SELECT group_concat(\"desc\") FROM pragma_index_xinfo('posts_created_at_id_idx') WHERE key", "1,1")
    && layout_is("SELECT group_concat(\"desc\") FROM pragma_index_xinfo('likes_post_id_idx') WHERE key", "0")
    && (root_posts = rootpage("posts")) && (root_users = rootpage("users"))
    && (root_feed = rootpage("posts_created_at_id_idx")) && (root_likes = rootpage("likes_post_id_idx"))
    && (ki_feed = key_info(2, 1, 1)) && (ki_likes = key_info(1, 1, 0));
  if (!bt_ok) { fprintf(stderr, "unexpected schema: reads use SQL\n"); return; }
  bt = db->aDb[0].pBt;
  cur_posts = malloc(sqlite3BtreeCursorSize()); cur_users = malloc(sqlite3BtreeCursorSize());
  cur_feed = malloc(sqlite3BtreeCursorSize()); cur_likes = malloc(sqlite3BtreeCursorSize());
}

// The log is copied back by a worker thread at low priority, on its own connection, so the loop never waits for an
// fsync. The loop alone decides: it asks for a pass by eventfd and the outcome comes back as a ring completion. A
// log can only restart once all of it is copied, which steady writes prevent, so if frames arrived during a pass the
// loop stops taking POSTs (reads go on) for one more pass. Past WAL_MAX frames it waits for that pass however long it
// takes, because a saturated CPU starves the worker and the log would otherwise grow without bound.
#define WAL_START 8192
#define WAL_MAX (4 * WAL_START)
#define POST_WAIT_NS 250000000LL
enum { WAL_LEFT = 1, WAL_ALL };  // what a pass reports; a counter value, so never 0
static sqlite3 *wal_db;
static int wal_asks, wal_frames, wal_asked_at, wal_busy, wal_last_pass;
static int64_t post_deadline;  // 0: no limit
static int64_t mono_ns(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1000000000LL + t.tv_nsec; }
static int wal_hook(void *u, sqlite3 *d, const char *n, int frames) { wal_frames = frames; return SQLITE_OK; }
static void *wal_worker(void *a) {
  uint64_t go, outcome;
  setpriority(PRIO_PROCESS, (id_t)gettid(), 19);
  while (read(wal_asks, &go, 8) == 8) {
    int log = -1, done = -2, rc = sqlite3_wal_checkpoint_v2(wal_db, "main", SQLITE_CHECKPOINT_PASSIVE, &log, &done);
    outcome = rc == SQLITE_OK && log == done ? WAL_ALL : WAL_LEFT;
    if (write(wal_replies, &outcome, 8) != 8) return NULL;
  }
  return NULL;
}
static void wal_ask(void) { uint64_t one = 1; wal_busy = 1; wal_asked_at = wal_frames; if (write(wal_asks, &one, 8) != 8) wal_busy = 0; }
static void wal_copied(uint64_t outcome) {
  wal_busy = 0;
  // All copied, and nothing committed since the pass was asked for: the next write restarts the log.
  if (outcome == WAL_ALL && wal_frames == wal_asked_at) { wal_frames = 0; wal_last_pass = 0; hold_posts = 0; return; }
  if (wal_last_pass) { wal_last_pass = 0; hold_posts = 0; return; }  // POSTs were let go early, or the pass failed: try again later
  wal_last_pass = 1; hold_posts = 1;
  post_deadline = wal_frames >= WAL_MAX ? 0 : mono_ns() + POST_WAIT_NS;
  wal_ask();
}
// Between batches, with no transaction open: a write only restarts the log from a read transaction begun after the
// last copy, so POSTs can't be let go in the middle of a batch.
static void wal_after_commit(void) {
  if (wal_outcome) { uint64_t o = wal_outcome; wal_outcome = 0; wal_copied(o); }
  if (wal_frames >= WAL_MAX && wal_busy) { hold_posts = 1; post_deadline = 0; }
  else if (!wal_busy && wal_frames >= WAL_START) wal_ask();
}
static int wal_hold_over(void) {
  if (hold_posts && post_deadline && mono_ns() > post_deadline) hold_posts = 0;
  return !hold_posts;
}

static void db_open(const char *path) {
  // unix-excl: one process owns the file, the WAL index lives in its heap, and a transaction takes no file locks.
  int fl = SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX;
  if (sqlite3_open_v2(path, &db, fl, "unix-excl") != SQLITE_OK) { fprintf(stderr, "open %s: %s\n", path, sqlite3_errmsg(db)); exit(1); }
  sqlite3_busy_timeout(db, 5000);
  char *e = NULL;
  if (sqlite3_exec(db, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA mmap_size=0; PRAGMA cache_size=-" STR(CACHE_KB) "; PRAGMA wal_autocheckpoint=0;"
                   "SELECT count(*) FROM users WHERE id = 1;", NULL, NULL, &e) != SQLITE_OK) { fprintf(stderr, "pragma: %s\n", e); exit(1); }
  sqlite3_wal_hook(db, wal_hook, NULL);
  wal_asks = eventfd(0, EFD_CLOEXEC); wal_replies = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
  if (wal_asks < 0 || wal_replies < 0 || sqlite3_open_v2(path, &wal_db, fl, "unix-excl") != SQLITE_OK ||
      sqlite3_exec(wal_db, "PRAGMA synchronous=NORMAL; PRAGMA wal_autocheckpoint=0; PRAGMA cache_size=16;", NULL, NULL, NULL) != SQLITE_OK) { fprintf(stderr, "checkpoint connection failed\n"); exit(1); }
  pthread_t t; pthread_attr_t a; pthread_attr_init(&a); pthread_attr_setstacksize(&a, 256 << 10);
  if (pthread_create(&t, &a, wal_worker, NULL)) { fprintf(stderr, "checkpoint thread failed\n"); exit(1); }
  btree_setup();
  const char *cols = "SELECT p.id, p.body, p.created_at, u.username, (SELECT count(*) FROM likes l WHERE l.post_id = p.id) FROM posts p JOIN users u ON u.id = p.user_id ";
  char sql[512];
  snprintf(sql, sizeof sql, "%sORDER BY p.created_at DESC, p.id DESC LIMIT 20", cols); st_feed = prep(sql);
  snprintf(sql, sizeof sql, "%sWHERE p.id = ?", cols); st_post = prep(sql);
  st_ins = prep("INSERT INTO posts (user_id, body) VALUES (?, ?) RETURNING id, created_at");
  st_like = prep(bt_ok ? "INSERT INTO likes (user_id, post_id) VALUES (?1, ?2) ON CONFLICT (user_id, post_id) DO NOTHING"
                       : "INSERT INTO likes (user_id, post_id) SELECT ?1, ?2 WHERE EXISTS (SELECT 1 FROM posts WHERE id = ?2) ON CONFLICT (user_id, post_id) DO NOTHING");
  st_one = prep("SELECT 1");
  st_begin = prep("BEGIN"); st_commit = prep("COMMIT"); st_rollback = prep("ROLLBACK");
}

#ifdef PGO_TRAIN
#include "train.c"
#endif
int main(int argc, char **argv) {
#ifdef PGO_TRAIN
  train();
#endif
  const char *path = getenv("SQLITE_PATH"), *secret = getenv("JWT_SECRET"), *host = getenv("HOST"), *ports = getenv("PORT");
  if (!path || !secret) { fprintf(stderr, "SQLITE_PATH and JWT_SECRET are required\n"); return 1; }
  { // One contiguous page cache on huge pages instead of a malloc per page.
    int hdr = 0; sqlite3_config(SQLITE_CONFIG_PCACHE_HDRSZ, &hdr);
    int sz = (4096 + hdr + 7) & ~7, npg = CACHE_KB / 4;
    sqlite3_config(SQLITE_CONFIG_PAGECACHE, huge_alloc((size_t)sz * npg), sz, npg);
  }
  sqlite3_initialize();  // built with SQLITE_OMIT_AUTOINIT
  struct rlimit rl; getrlimit(RLIMIT_NOFILE, &rl);
  if (rl.rlim_cur < rl.rlim_max) { rl.rlim_cur = rl.rlim_max; setrlimit(RLIMIT_NOFILE, &rl); }
  tsize = rl.rlim_cur > (1 << 20) ? 1 << 20 : rl.rlim_cur;  // the kernel caps a table at RLIMIT_NOFILE
  memset(b64t, -1, sizeof b64t);
  for (int i = 0; i < 64; i++) b64t[(unsigned char)"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"[i]] = i;
  hmac_key(secret);
  started = now_s = time(NULL);
  db_open(path);

  struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons(ports ? atoi(ports) : 3000)};
  if (inet_pton(AF_INET, host ? host : "0.0.0.0", &a.sin_addr) != 1) { fprintf(stderr, "bad HOST\n"); return 1; }
  for (int i = 0; i < NLISTEN; i++) {
    int one = 1; lfd[i] = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    setsockopt(lfd[i], SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    setsockopt(lfd[i], SOL_SOCKET, SO_REUSEPORT, &one, sizeof one);
    setsockopt(lfd[i], IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);  // accepted sockets inherit it
    if (bind(lfd[i], (struct sockaddr *)&a, sizeof a) || listen(lfd[i], 65535)) { perror("bind/listen"); return 1; }
  }
  arena = huge_alloc(BATCH_OUT);
  if (ring_init(0) < 0) { fprintf(stderr, "io_uring setup failed (needs Linux 6.1+ with io_uring enabled)\n"); return 1; }
  arm_wal_msg();
  run();
}
