// $12 Server Challenge: baseline. Single-threaded epoll, hand-rolled HTTP/JSON/JWT, SQLite in-process.
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <ctype.h>
#include <errno.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
#include <emmintrin.h>
#include <linux/io_uring.h>
#include <poll.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include "sqlite3.h"

/* ---------------------------------------------------------------- SHA-256 / HMAC */
typedef struct { uint32_t h[8]; uint8_t b[64]; uint64_t len; size_t bl; } sha_ctx;
static const uint32_t K[64] = {
 0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
 0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
 0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
 0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
 0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
 0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
 0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
 0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2};
static inline uint32_t ror(uint32_t x, int n) { return (x >> n) | (x << (32 - n)); }
static void sha_block(uint32_t h[8], const uint8_t *p) {
  uint32_t w[64];
  for (int i = 0; i < 16; i++)
    w[i] = (uint32_t)p[4*i] << 24 | (uint32_t)p[4*i+1] << 16 | (uint32_t)p[4*i+2] << 8 | p[4*i+3];
  for (int i = 16; i < 64; i++) {
    uint32_t s0 = ror(w[i-15], 7) ^ ror(w[i-15], 18) ^ (w[i-15] >> 3);
    uint32_t s1 = ror(w[i-2], 17) ^ ror(w[i-2], 19) ^ (w[i-2] >> 10);
    w[i] = w[i-16] + s0 + w[i-7] + s1;
  }
  uint32_t a=h[0],b=h[1],c=h[2],d=h[3],e=h[4],f=h[5],g=h[6],hh=h[7];
  for (int i = 0; i < 64; i++) {
    uint32_t S1 = ror(e,6) ^ ror(e,11) ^ ror(e,25), ch = (e & f) ^ (~e & g);
    uint32_t t1 = hh + S1 + ch + K[i] + w[i];
    uint32_t S0 = ror(a,2) ^ ror(a,13) ^ ror(a,22), mj = (a & b) ^ (a & c) ^ (b & c);
    uint32_t t2 = S0 + mj;
    hh = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
  }
  h[0]+=a; h[1]+=b; h[2]+=c; h[3]+=d; h[4]+=e; h[5]+=f; h[6]+=g; h[7]+=hh;
}
static void sha_init(sha_ctx *c) {
  static const uint32_t iv[8] = {0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19};
  memcpy(c->h, iv, sizeof iv); c->len = 0; c->bl = 0;
}
static void sha_update(sha_ctx *c, const uint8_t *p, size_t n) {
  c->len += n;
  if (c->bl) {
    size_t t = 64 - c->bl; if (t > n) t = n;
    memcpy(c->b + c->bl, p, t); c->bl += t; p += t; n -= t;
    if (c->bl < 64) return;
    sha_block(c->h, c->b); c->bl = 0;
  }
  while (n >= 64) { sha_block(c->h, p); p += 64; n -= 64; }
  if (n) { memcpy(c->b, p, n); c->bl = n; }
}
static void sha_final(sha_ctx *c, uint8_t out[32]) {
  uint64_t bits = c->len * 8;
  uint8_t pad[72] = {0x80};
  size_t padn = (c->bl < 56) ? 56 - c->bl : 120 - c->bl;
  for (int i = 0; i < 8; i++) pad[padn + i] = (uint8_t)(bits >> (56 - 8*i));
  sha_update(c, pad, padn + 8);
  for (int i = 0; i < 8; i++) {
    out[4*i] = c->h[i] >> 24; out[4*i+1] = c->h[i] >> 16; out[4*i+2] = c->h[i] >> 8; out[4*i+3] = c->h[i];
  }
}
static sha_ctx hm_in, hm_out;   /* midstates after ipad / opad: one block saved per verification */
static void hmac_init(const uint8_t *key, size_t kl) {
  uint8_t k[64] = {0}, pad[64];
  if (kl > 64) { sha_ctx c; sha_init(&c); sha_update(&c, key, kl); sha_final(&c, k); }
  else memcpy(k, key, kl);
  for (int i = 0; i < 64; i++) pad[i] = k[i] ^ 0x36;
  sha_init(&hm_in); sha_update(&hm_in, pad, 64);
  for (int i = 0; i < 64; i++) pad[i] = k[i] ^ 0x5c;
  sha_init(&hm_out); sha_update(&hm_out, pad, 64);
}
static void hmac(const uint8_t *m, size_t n, uint8_t out[32]) {
  sha_ctx c = hm_in; uint8_t in[32];
  sha_update(&c, m, n); sha_final(&c, in);
  c = hm_out; sha_update(&c, in, 32); sha_final(&c, out);
}

/* ---------------------------------------------------------------- base64url */
static int8_t b64t[256];
static void b64_init(void) {
  memset(b64t, -1, sizeof b64t);
  for (int i = 0; i < 26; i++) { b64t['A'+i] = i; b64t['a'+i] = 26 + i; }
  for (int i = 0; i < 10; i++) b64t['0'+i] = 52 + i;
  b64t['-'] = 62; b64t['_'] = 63;
}
static long b64_dec(const char *s, size_t n, uint8_t *out, size_t cap) {
  if (n % 4 == 1) return -1;
  size_t o = 0; uint32_t acc = 0; int bits = 0;
  for (size_t i = 0; i < n; i++) {
    int v = b64t[(uint8_t)s[i]]; if (v < 0) return -1;
    acc = (acc << 6) | (uint32_t)v; bits += 6;
    if (bits >= 8) { bits -= 8; if (o >= cap) return -1; out[o++] = (uint8_t)(acc >> bits); }
  }
  return (long)o;
}

/* ---------------------------------------------------------------- JSON (validating, zero-alloc) */
typedef struct { const char *p, *e; } jc;
enum { J_MISSING = 0, J_STR, J_NUM, J_OTHER };
static void jws(jc *c) { while (c->p < c->e && (*c->p == ' ' || *c->p == '\t' || *c->p == '\n' || *c->p == '\r')) c->p++; }
static int jstr(jc *c) {            /* c->p at opening quote */
  c->p++;
  while (c->p < c->e) {
    unsigned char ch = (unsigned char)*c->p;
    if (ch == '"') { c->p++; return 0; }
    if (ch < 0x20) return -1;
    if (ch == '\\') {
      c->p++; if (c->p >= c->e) return -1;
      ch = (unsigned char)*c->p;
      if (ch && strchr("\"\\/bfnrt", ch)) { c->p++; continue; }
      if (ch == 'u') {
        if (c->e - c->p < 5) return -1;
        for (int i = 1; i <= 4; i++) if (!isxdigit((unsigned char)c->p[i])) return -1;
        c->p += 5; continue;
      }
      return -1;
    }
    c->p++;
  }
  return -1;
}
static int jdig(jc *c) { return c->p < c->e && *c->p >= '0' && *c->p <= '9'; }
static int jnum(jc *c) {
  if (*c->p == '-') c->p++;
  if (c->p >= c->e) return -1;
  if (*c->p == '0') c->p++;
  else if (jdig(c)) while (jdig(c)) c->p++;
  else return -1;
  if (c->p < c->e && *c->p == '.') { c->p++; if (!jdig(c)) return -1; while (jdig(c)) c->p++; }
  if (c->p < c->e && (*c->p == 'e' || *c->p == 'E')) {
    c->p++; if (c->p < c->e && (*c->p == '+' || *c->p == '-')) c->p++;
    if (!jdig(c)) return -1;
    while (jdig(c)) c->p++;
  }
  return 0;
}
static int jlit(jc *c, const char *l) {
  size_t n = strlen(l);
  if ((size_t)(c->e - c->p) >= n && !memcmp(c->p, l, n)) { c->p += n; return 0; }
  return -1;
}
static int jval(jc *c, int d) {
  if (d > 32 || c->p >= c->e) return -1;
  switch (*c->p) {
  case '"': return jstr(c);
  case 't': return jlit(c, "true");
  case 'f': return jlit(c, "false");
  case 'n': return jlit(c, "null");
  case '{':
    c->p++; jws(c);
    if (c->p < c->e && *c->p == '}') { c->p++; return 0; }
    for (;;) {
      jws(c); if (c->p >= c->e || *c->p != '"' || jstr(c)) return -1;
      jws(c); if (c->p >= c->e || *c->p != ':') return -1;
      c->p++; jws(c); if (jval(c, d + 1)) return -1;
      jws(c); if (c->p >= c->e) return -1;
      if (*c->p == ',') { c->p++; continue; }
      if (*c->p == '}') { c->p++; return 0; }
      return -1;
    }
  case '[':
    c->p++; jws(c);
    if (c->p < c->e && *c->p == ']') { c->p++; return 0; }
    for (;;) {
      jws(c); if (jval(c, d + 1)) return -1;
      jws(c); if (c->p >= c->e) return -1;
      if (*c->p == ',') { c->p++; continue; }
      if (*c->p == ']') { c->p++; return 0; }
      return -1;
    }
  default: return jnum(c);
  }
}
/* 0 ok, -1 malformed, -2 valid JSON but not an object. Last duplicate key wins. */
static int jget(const char *s, size_t n, const char *key, int *type, const char **v, size_t *vl) {
  jc c = {s, s + n};
  *type = J_MISSING; *v = NULL; *vl = 0;
  jws(&c); if (c.p >= c.e) return -1;
  if (*c.p != '{') { if (jval(&c, 0)) return -1; jws(&c); return c.p == c.e ? -2 : -1; }
  size_t kl = strlen(key);
  c.p++; jws(&c);
  if (c.p < c.e && *c.p == '}') c.p++;
  else for (;;) {
    jws(&c); if (c.p >= c.e || *c.p != '"') return -1;
    const char *ks = c.p + 1; if (jstr(&c)) return -1;
    size_t kn = (size_t)(c.p - 1 - ks);
    jws(&c); if (c.p >= c.e || *c.p != ':') return -1;
    c.p++; jws(&c);
    const char *vs = c.p; if (jval(&c, 1)) return -1;
    size_t vn = (size_t)(c.p - vs);
    if (kn == kl && !memcmp(ks, key, kl)) {
      if (*vs == '"') { *type = J_STR; *v = vs + 1; *vl = vn - 2; }
      else if (*vs == '-' || (*vs >= '0' && *vs <= '9')) { *type = J_NUM; *v = vs; *vl = vn; }
      else { *type = J_OTHER; *v = vs; *vl = vn; }
    }
    jws(&c); if (c.p >= c.e) return -1;
    if (*c.p == ',') { c.p++; continue; }
    if (*c.p == '}') { c.p++; break; }
    return -1;
  }
  jws(&c); return c.p == c.e ? 0 : -1;
}
static int hv(int c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return 0;
}
static uint32_t hex4(const char *s) { return (uint32_t)(hv(s[0]) << 12 | hv(s[1]) << 8 | hv(s[2]) << 4 | hv(s[3])); }
static int u8enc(uint32_t c, char *o) {
  if (c < 0x80) { o[0] = (char)c; return 1; }
  if (c < 0x800) { o[0] = (char)(0xC0 | (c >> 6)); o[1] = (char)(0x80 | (c & 63)); return 2; }
  if (c < 0x10000) { o[0] = (char)(0xE0 | (c >> 12)); o[1] = (char)(0x80 | ((c >> 6) & 63)); o[2] = (char)(0x80 | (c & 63)); return 3; }
  o[0] = (char)(0xF0 | (c >> 18)); o[1] = (char)(0x80 | ((c >> 12) & 63)); o[2] = (char)(0x80 | ((c >> 6) & 63)); o[3] = (char)(0x80 | (c & 63));
  return 4;
}
/* decode a validated JSON string span; output is never longer than input */
static size_t jdec(const char *s, size_t n, char *out) {
  char *o = out; const char *e = s + n;
  while (s < e) {
    unsigned char ch = (unsigned char)*s++;
    if (ch != '\\') { *o++ = (char)ch; continue; }
    ch = (unsigned char)*s++;
    switch (ch) {
    case 'n': *o++ = '\n'; break;
    case 'r': *o++ = '\r'; break;
    case 't': *o++ = '\t'; break;
    case 'b': *o++ = '\b'; break;
    case 'f': *o++ = '\f'; break;
    case 'u': {
      uint32_t cp = hex4(s); s += 4;
      if (cp >= 0xD800 && cp < 0xDC00) {
        if (e - s >= 6 && s[0] == '\\' && s[1] == 'u') {
          uint32_t lo = hex4(s + 2);
          if (lo >= 0xDC00 && lo < 0xE000) { cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00); s += 6; }
          else cp = 0xFFFD;
        } else cp = 0xFFFD;
      } else if (cp >= 0xDC00 && cp < 0xE000) cp = 0xFFFD;
      o += u8enc(cp, o); break;
    }
    default: *o++ = (char)ch; break;   /* " \ / */
    }
  }
  return (size_t)(o - out);
}

/* ---------------------------------------------------------------- output buffers */
typedef struct { char *p; size_t n, cap; } buf;
static buf obuf, body;
static void bres(buf *b, size_t add) {
  if (b->n + add <= b->cap) return;
  size_t nc = b->cap ? b->cap : 4096;
  while (nc < b->n + add) nc *= 2;
  b->p = realloc(b->p, nc); if (!b->p) abort();
  b->cap = nc;
}
static void bput(buf *b, const void *s, size_t n) { bres(b, n); memcpy(b->p + b->n, s, n); b->n += n; }
static void bstr(buf *b, const char *s) { bput(b, s, strlen(s)); }
static void bint(buf *b, long long v) {
  char t[24]; char *e = t + sizeof t, *p = e;
  unsigned long long u = v < 0 ? 0ULL - (unsigned long long)v : (unsigned long long)v;
  do { *--p = (char)('0' + u % 10); u /= 10; } while (u);
  if (v < 0) *--p = '-';
  bput(b, p, (size_t)(e - p));
}
static void besc(buf *b, const char *s, size_t n) {
  static const char hx[] = "0123456789abcdef";
  bres(b, n * 6 + 16);                    /* worst case 6 bytes/char, +16 for the vector store */
  char *o = b->p + b->n;
  const __m128i vq = _mm_set1_epi8('"'), vb = _mm_set1_epi8('\\'), vc = _mm_set1_epi8(0x1f);
  size_t i = 0;
  while (i < n) {
    if (i + 16 <= n) {
      __m128i v = _mm_loadu_si128((const __m128i *)(s + i));
      _mm_storeu_si128((__m128i *)o, v);  /* optimistic copy; only kept if the block is clean */
      __m128i hit = _mm_or_si128(_mm_or_si128(_mm_cmpeq_epi8(v, vq), _mm_cmpeq_epi8(v, vb)),
                                 _mm_cmpeq_epi8(_mm_min_epu8(v, vc), v));   /* byte <= 0x1f */
      unsigned m = (unsigned)_mm_movemask_epi8(hit);
      if (!m) { o += 16; i += 16; continue; }
      unsigned k = (unsigned)__builtin_ctz(m);   /* clean bytes before the first escapable one */
      o += k; i += k;
    }
    unsigned char c = (unsigned char)s[i++];
    if (c == '"') { *o++ = '\\'; *o++ = '"'; }
    else if (c == '\\') { *o++ = '\\'; *o++ = '\\'; }
    else if (c < 0x20) {
      *o++ = '\\';
      switch (c) {
      case '\n': *o++ = 'n'; break;
      case '\r': *o++ = 'r'; break;
      case '\t': *o++ = 't'; break;
      default: *o++ = 'u'; *o++ = '0'; *o++ = '0'; *o++ = hx[c >> 4]; *o++ = hx[c & 15];
      }
    } else *o++ = (char)c;
  }
  b->n = (size_t)(o - b->p);
}

/* ---------------------------------------------------------------- DB */
static sqlite3 *db;
static int g_group, g_tx;                      /* group commit: io_uring mode only */
static sqlite3_stmt *st_feed, *st_one, *st_ins, *st_exists, *st_like, *st_health;
static time_t t_start;
#define POST_SQL "SELECT p.id,p.body,p.created_at,u.username,(SELECT count(*) FROM likes l WHERE l.post_id=p.id) FROM posts p JOIN users u ON u.id=p.user_id "
static sqlite3_stmt *prep(const char *sql) {
  sqlite3_stmt *s;
  if (sqlite3_prepare_v3(db, sql, -1, SQLITE_PREPARE_PERSISTENT, &s, NULL) != SQLITE_OK) {
    fprintf(stderr, "prepare failed: %s\n  %s\n", sqlite3_errmsg(db), sql); exit(1);
  }
  return s;
}
static void db_open(const char *path) {
  if (sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, NULL) != SQLITE_OK) {
    fprintf(stderr, "open %s: %s\n", path, sqlite3_errmsg(db)); exit(1);
  }
  char *em = NULL;
  if (sqlite3_exec(db, "PRAGMA journal_mode=WAL;PRAGMA synchronous=NORMAL;PRAGMA temp_store=MEMORY;"
                       "PRAGMA mmap_size=0;PRAGMA cache_size=-16384;PRAGMA busy_timeout=5000;",
                   NULL, NULL, &em) != SQLITE_OK) { fprintf(stderr, "pragma: %s\n", em); exit(1); }
  sqlite3_exec(db, "PRAGMA wal_autocheckpoint=10000;", NULL, NULL, NULL);   /* keep checkpoints out of the commit path */
  st_feed = prep(POST_SQL "ORDER BY p.created_at DESC, p.id DESC LIMIT 20");
  st_one = prep(POST_SQL "WHERE p.id=?");
  st_ins = prep("INSERT INTO posts(user_id,body) VALUES(?,?) RETURNING id,created_at");
  st_exists = prep("SELECT 1 FROM posts WHERE id=?");
  st_like = prep("INSERT INTO likes(user_id,post_id) VALUES(?,?) ON CONFLICT(user_id,post_id) DO NOTHING");
  st_health = prep("SELECT 1");
}
static void put_post_row(buf *b, sqlite3_stmt *s) {
  bstr(b, "{\"id\":"); bint(b, sqlite3_column_int64(s, 0));
  bstr(b, ",\"body\":\""); besc(b, (const char *)sqlite3_column_text(s, 1), (size_t)sqlite3_column_bytes(s, 1));
  bstr(b, "\",\"created_at\":\""); besc(b, (const char *)sqlite3_column_text(s, 2), (size_t)sqlite3_column_bytes(s, 2));
  bstr(b, "\",\"author\":\""); besc(b, (const char *)sqlite3_column_text(s, 3), (size_t)sqlite3_column_bytes(s, 3));
  bstr(b, "\",\"like_count\":"); bint(b, sqlite3_column_int64(s, 4)); bstr(b, "}");
}

/* ---------------------------------------------------------------- HTTP request parsing */
#define RBUF_SZ 65536
#define MAX_BODY 32768
enum { M_OTHER = 0, M_GET, M_POST };
typedef struct {
  int method; const char *path; size_t plen;
  const char *auth; size_t authlen; const char *body; size_t blen; int close;
} req;
static int ieq(const char *a, size_t n, const char *lit) {
  if (strlen(lit) != n) return 0;
  for (size_t i = 0; i < n; i++) if (tolower((unsigned char)a[i]) != lit[i]) return 0;
  return 1;
}
/* >0 bytes consumed, 0 need more, -1 bad request */
static long parse_req(const char *b, size_t n, req *r) {
  const char *he = memmem(b, n, "\r\n\r\n", 4);
  if (!he) return n > 16384 ? -1 : 0;
  size_t hl = (size_t)(he - b) + 4;
  memset(r, 0, sizeof *r);
  const char *sp1 = memchr(b, ' ', hl); if (!sp1) return -1;
  size_t ml = (size_t)(sp1 - b);
  r->method = (ml == 3 && !memcmp(b, "GET", 3)) ? M_GET : (ml == 4 && !memcmp(b, "POST", 4)) ? M_POST : M_OTHER;
  const char *t = sp1 + 1;
  const char *sp2 = memchr(t, ' ', (size_t)(he - t)); if (!sp2) return -1;
  const char *q = memchr(t, '?', (size_t)(sp2 - t));
  r->path = t; r->plen = (size_t)((q ? q : sp2) - t);
  const char *ln = memchr(sp2, '\n', (size_t)(he - sp2) + 2); if (!ln) return -1;
  const char *p = ln + 1;
  size_t clen = 0;
  while (p < he) {
    const char *eol = memchr(p, '\r', (size_t)(he - p) + 1);
    const char *colon = memchr(p, ':', (size_t)(eol - p));
    if (colon) {
      size_t nl = (size_t)(colon - p);
      const char *v = colon + 1, *ve = eol;
      while (v < ve && (*v == ' ' || *v == '\t')) v++;
      while (ve > v && (ve[-1] == ' ' || ve[-1] == '\t')) ve--;
      size_t vl = (size_t)(ve - v);
      if (ieq(p, nl, "content-length")) {
        if (!vl || vl > 9) return -1;
        clen = 0;
        for (size_t i = 0; i < vl; i++) { if (v[i] < '0' || v[i] > '9') return -1; clen = clen * 10 + (size_t)(v[i] - '0'); }
      } else if (ieq(p, nl, "authorization")) { r->auth = v; r->authlen = vl; }
      else if (ieq(p, nl, "connection")) { if (ieq(v, vl, "close")) r->close = 1; }
      else if (ieq(p, nl, "transfer-encoding")) return -1;
    }
    p = eol + 2;
  }
  if (clen > MAX_BODY || hl + clen > RBUF_SZ) return -1;
  if (n < hl + clen) return 0;
  r->body = b + hl; r->blen = clen;
  return (long)(hl + clen);
}

/* ---------------------------------------------------------------- JWT */
static char g_uname[1100]; static size_t g_ulen;
/* 0 ok, 1 invalid or expired, 2 invalid payload */
static int jwt_verify(const char *tok, size_t n, long long *uid) {
  const char *d1 = memchr(tok, '.', n); if (!d1) return 1;
  const char *d2 = memchr(d1 + 1, '.', (size_t)(tok + n - (d1 + 1))); if (!d2) return 1;
  if (memchr(d2 + 1, '.', (size_t)(tok + n - (d2 + 1)))) return 1;
  size_t hl = (size_t)(d1 - tok), pl = (size_t)(d2 - d1 - 1), sl = (size_t)(tok + n - d2 - 1);
  if (sl != 43 || hl > 200 || pl > 1000 || !hl || !pl) return 1;
  uint8_t sig[48], mac[32];
  if (b64_dec(d2 + 1, sl, sig, sizeof sig) != 32) return 1;
  hmac((const uint8_t *)tok, (size_t)(d2 - tok), mac);
  uint8_t diff = 0; for (int i = 0; i < 32; i++) diff |= mac[i] ^ sig[i];
  if (diff) return 1;
  char hb[256], pb[1100]; long hn, pn; int ty; const char *v; size_t vl;
  hn = b64_dec(tok, hl, (uint8_t *)hb, 255); if (hn < 0) return 1;
  if (jget(hb, (size_t)hn, "alg", &ty, &v, &vl) != 0 || ty != J_STR || vl != 5 || memcmp(v, "HS256", 5)) return 1;
  pn = b64_dec(d1 + 1, pl, (uint8_t *)pb, 1099); if (pn < 0) return 1;
  pb[pn] = 0;
  if (jget(pb, (size_t)pn, "exp", &ty, &v, &vl) != 0) return 1;
  if (ty != J_NUM) return 1;                      /* missing or non-numeric exp: 401 */
  if (strtod(v, NULL) <= (double)time(NULL)) return 1;
  if (jget(pb, (size_t)pn, "sub", &ty, &v, &vl) != 0 || ty != J_STR) return 2;
  if (!vl || vl > 15) return 2;
  long long id = 0;
  for (size_t i = 0; i < vl; i++) { if (v[i] < '0' || v[i] > '9') return 2; id = id * 10 + (v[i] - '0'); }
  if (id <= 0) return 2;
  if (jget(pb, (size_t)pn, "username", &ty, &v, &vl) != 0 || ty != J_STR) return 2;
  g_ulen = jdec(v, vl, g_uname);
  *uid = id;
  return 0;
}

/* ---------------------------------------------------------------- handlers */
static int err(int st, const char *msg) {
  body.n = 0; bstr(&body, "{\"error\":\""); bstr(&body, msg); bstr(&body, "\"}"); return st;
}
static int do_auth(const req *r, long long *uid) {   /* 0 ok, else error status (body set) */
  if (!r->auth || r->authlen < 7 || memcmp(r->auth, "Bearer ", 7)) return err(401, "missing bearer token");
  int rc = jwt_verify(r->auth + 7, r->authlen - 7, uid);
  if (rc == 1) return err(401, "invalid or expired token");
  if (rc == 2) return err(401, "invalid token payload");
  return 0;
}
/* 0 ok, -1 invalid, -2 positive digits but too large to exist */
static int parse_id(const char *s, size_t n, long long *out) {
  if (!n) return -1;
  for (size_t i = 0; i < n; i++) if (s[i] < '0' || s[i] > '9') return -1;
  size_t i = 0; while (i < n - 1 && s[i] == '0') i++;
  if (n - i > 15) return -2;
  long long v = 0; for (; i < n; i++) v = v * 10 + (s[i] - '0');
  if (v <= 0) return -1;
  *out = v; return 0;
}
static int h_health(void) {
  body.n = 0;
  int rc = sqlite3_step(st_health); sqlite3_reset(st_health);
  if (rc == SQLITE_ROW) {
    bstr(&body, "{\"status\":\"ok\",\"db\":\"ok\",\"uptime_s\":"); bint(&body, (long long)(time(NULL) - t_start)); bstr(&body, "}");
    return 200;
  }
  const char *m = sqlite3_errmsg(db);
  bstr(&body, "{\"status\":\"degraded\",\"db\":\"unreachable\",\"error\":\""); besc(&body, m, strlen(m)); bstr(&body, "\"}");
  return 503;
}
static int h_feed(void) {
  body.n = 0; bstr(&body, "{\"posts\":[");
  int first = 1, rc;
  while ((rc = sqlite3_step(st_feed)) == SQLITE_ROW) {
    if (!first) bstr(&body, ",");
    first = 0;
    put_post_row(&body, st_feed);
  }
  sqlite3_reset(st_feed);
  if (rc != SQLITE_DONE) return err(500, "internal server error");
  bstr(&body, "]}"); return 200;
}
static int id_error(int rc) { return rc == -1 ? err(400, "invalid post id") : err(404, "post not found"); }
static int h_get(const char *s, size_t n) {
  long long id; int rc = parse_id(s, n, &id);
  if (rc) return id_error(rc);
  sqlite3_bind_int64(st_one, 1, id);
  rc = sqlite3_step(st_one);
  int st;
  if (rc == SQLITE_ROW) { body.n = 0; bstr(&body, "{\"post\":"); put_post_row(&body, st_one); bstr(&body, "}"); st = 200; }
  else if (rc == SQLITE_DONE) st = err(404, "post not found");
  else st = err(500, "internal server error");
  sqlite3_reset(st_one);
  return st;
}
static void tx_begin(void) {
  if (g_group && !g_tx && sqlite3_exec(db, "BEGIN", NULL, NULL, NULL) == SQLITE_OK) g_tx = 1;
}
static char dec[RBUF_SZ + 8];
static int h_create(const req *r) {
  long long uid; int s;
  if ((s = do_auth(r, &uid))) return s;
  int ty; const char *v; size_t vl;
  int rc = jget(r->body, r->blen, "body", &ty, &v, &vl);
  if (rc == -1) return err(400, "malformed JSON body");
  if (rc == -2 || ty != J_STR) return err(400, "body is required");
  size_t dn = jdec(v, vl, dec);
  size_t a = 0, e = dn;
  while (a < e && (dec[a] == ' ' || (dec[a] >= 9 && dec[a] <= 13))) a++;
  while (e > a && (dec[e-1] == ' ' || (dec[e-1] >= 9 && dec[e-1] <= 13))) e--;
  if (a == e) return err(400, "body is required");
  size_t chars = 0; for (size_t i = a; i < e; i++) if (((unsigned char)dec[i] & 0xC0) != 0x80) chars++;
  if (chars > 500) return err(400, "body must be at most 500 characters");
  tx_begin();
  sqlite3_bind_int64(st_ins, 1, uid);
  sqlite3_bind_text(st_ins, 2, dec + a, (int)(e - a), SQLITE_STATIC);
  long long id = 0; char ca[48] = {0};
  rc = sqlite3_step(st_ins);
  if (rc == SQLITE_ROW) {
    id = sqlite3_column_int64(st_ins, 0);
    snprintf(ca, sizeof ca, "%s", (const char *)sqlite3_column_text(st_ins, 1));
    rc = sqlite3_step(st_ins);              /* run to DONE: this is the commit */
  }
  sqlite3_reset(st_ins);
  if (rc != SQLITE_DONE) return err(500, "internal server error");
  body.n = 0; bstr(&body, "{\"post\":{\"id\":"); bint(&body, id);
  bstr(&body, ",\"body\":\""); besc(&body, dec + a, e - a);
  bstr(&body, "\",\"created_at\":\""); bstr(&body, ca);
  bstr(&body, "\",\"author\":\""); besc(&body, g_uname, g_ulen);
  bstr(&body, "\",\"like_count\":0}}");
  return 201;
}
static int h_like(const req *r, const char *ids, size_t idn) {
  long long uid, pid; int s;
  if ((s = do_auth(r, &uid))) return s;
  int rc = parse_id(ids, idn, &pid);
  if (rc) return id_error(rc);
  sqlite3_bind_int64(st_exists, 1, pid);
  rc = sqlite3_step(st_exists); sqlite3_reset(st_exists);
  if (rc == SQLITE_DONE) return err(404, "post not found");
  if (rc != SQLITE_ROW) return err(500, "internal server error");
  tx_begin();
  sqlite3_bind_int64(st_like, 1, uid); sqlite3_bind_int64(st_like, 2, pid);
  rc = sqlite3_step(st_like);
  int changed = sqlite3_changes(db);
  sqlite3_reset(st_like);
  if (rc != SQLITE_DONE) return err(500, "internal server error");
  body.n = 0; bstr(&body, "{\"liked\":true,\"already_liked\":"); bstr(&body, changed ? "false" : "true");
  bstr(&body, ",\"post_id\":"); bint(&body, pid); bstr(&body, "}");
  return changed ? 201 : 200;
}
static int handle(const req *r) {
  const char *p = r->path; size_t n = r->plen;
  if (r->method == M_GET && n == 7 && !memcmp(p, "/health", 7)) return h_health();
  if (r->method == M_GET && n == 5 && !memcmp(p, "/feed", 5)) return h_feed();
  if (r->method == M_POST && n == 6 && !memcmp(p, "/posts", 6)) return h_create(r);
  if (n > 7 && !memcmp(p, "/posts/", 7)) {
    const char *id = p + 7; size_t il = n - 7;
    const char *sl = memchr(id, '/', il);
    if (!sl) { if (r->method == M_GET) return h_get(id, il); }
    else if (r->method == M_POST && (size_t)(p + n - sl) == 5 && !memcmp(sl, "/like", 5)) return h_like(r, id, (size_t)(sl - id));
  }
  return err(404, "not found");
}
static void emit(int st, int close_after) {
  const char *t = st == 200 ? "OK" : st == 201 ? "Created" : st == 400 ? "Bad Request" : st == 401 ? "Unauthorized" :
                  st == 404 ? "Not Found" : st == 503 ? "Service Unavailable" : "Internal Server Error";
  bres(&obuf, 256 + body.n);
  char *o = obuf.p + obuf.n;
  memcpy(o, "HTTP/1.1 ", 9); o += 9;
  *o++ = (char)('0' + st / 100); *o++ = (char)('0' + st / 10 % 10); *o++ = (char)('0' + st % 10); *o++ = ' ';
  size_t tl = strlen(t); memcpy(o, t, tl); o += tl;
  static const char H[] = "\r\nContent-Type: application/json\r\nContent-Length: ";
  memcpy(o, H, sizeof H - 1); o += sizeof H - 1;
  char d[24]; char *dp = d + sizeof d; size_t v = body.n;
  do { *--dp = (char)('0' + v % 10); v /= 10; } while (v);
  size_t dl = (size_t)(d + sizeof d - dp); memcpy(o, dp, dl); o += dl;
  if (close_after) { memcpy(o, "\r\nConnection: close", 19); o += 19; }
  memcpy(o, "\r\n\r\n", 4); o += 4;
  memcpy(o, body.p, body.n); o += body.n;
  obuf.n = (size_t)(o - obuf.p);
}

/* Answer every complete request in buf[0..total) into obuf. *used = bytes consumed; returns 1 if the connection must close. */
static int run_requests(const char *buf, size_t total, size_t *used) {
  size_t pos = 0; int closing = 0;
  obuf.n = 0;
  while (pos < total) {
    req r; long u = parse_req(buf + pos, total - pos, &r);
    if (u == 0) break;
    if (u < 0) { err(400, "bad request"); emit(400, 1); closing = 1; break; }
    int st = handle(&r); emit(st, r.close); pos += (size_t)u;
    if (r.close) { closing = 1; break; }
  }
  *used = pos;
  return closing;
}

/* ---------------------------------------------------------------- connections / epoll */
typedef struct { char *pend; uint32_t plen; char *wbuf; uint32_t wlen, woff; uint8_t closing; } conn;
static conn *conns; static int maxfd, ep;
static char rbuf[RBUF_SZ];
static void close_conn(int fd) {
  free(conns[fd].pend); free(conns[fd].wbuf); memset(&conns[fd], 0, sizeof(conn)); close(fd);
}
static void set_events(int fd, uint32_t ev) {
  struct epoll_event e = {.events = ev, .data.fd = fd}; epoll_ctl(ep, EPOLL_CTL_MOD, fd, &e);
}
static void on_readable(int fd) {
  conn *c = &conns[fd];
  size_t off = c->plen;
  if (off >= RBUF_SZ) { close_conn(fd); return; }
  if (off) memcpy(rbuf, c->pend, off);
  ssize_t n = read(fd, rbuf + off, RBUF_SZ - off);
  if (n < 0 && (errno == EAGAIN || errno == EINTR)) return;
  if (n <= 0) { close_conn(fd); return; }
  size_t total = off + (size_t)n, pos = 0;
  int closing = run_requests(rbuf, total, &pos);
  if (!closing && pos < total) {
    size_t rem = total - pos;
    c->pend = realloc(c->pend, rem); memcpy(c->pend, rbuf + pos, rem); c->plen = (uint32_t)rem;
  } else { free(c->pend); c->pend = NULL; c->plen = 0; }
  if (!obuf.n) { if (closing) close_conn(fd); return; }
  ssize_t w = send(fd, obuf.p, obuf.n, MSG_NOSIGNAL);
  if (w < 0) { if (errno != EAGAIN && errno != EINTR) { close_conn(fd); return; } w = 0; }
  if ((size_t)w < obuf.n) {
    size_t left = obuf.n - (size_t)w;
    c->wbuf = malloc(left); memcpy(c->wbuf, obuf.p + w, left);
    c->wlen = (uint32_t)left; c->woff = 0; c->closing = (uint8_t)closing;
    set_events(fd, EPOLLOUT); return;
  }
  if (closing) close_conn(fd);
}
static void on_writable(int fd) {
  conn *c = &conns[fd];
  ssize_t w = send(fd, c->wbuf + c->woff, c->wlen - c->woff, MSG_NOSIGNAL);
  if (w < 0) { if (errno == EAGAIN || errno == EINTR) return; close_conn(fd); return; }
  c->woff += (uint32_t)w;
  if (c->woff < c->wlen) return;
  free(c->wbuf); c->wbuf = NULL; c->wlen = c->woff = 0;
  if (c->closing) { close_conn(fd); return; }
  set_events(fd, EPOLLIN);
}

/* ---------------------------------------------------------------- io_uring front end */
#define UR_NB 256                                   /* pooled receive buffers (RBUF_SZ each, touched lazily) */
enum { U_ACCEPT = 1, U_POLL, U_RECV, U_SEND, U_CLOSE, U_CANCEL, U_RINGPOLL };
enum { S_FREE = 0, S_IDLE, S_RECV, S_SEND, S_CLOSING };
/* user_data: type (4 bits) | slot (20 bits) | generation (32 bits); the generation drops late CQEs of a reused slot */
#define UD(t, s, g) ((uint64_t)(t) | ((uint64_t)(s) << 4) | ((uint64_t)(g) << 24))

typedef struct {
  int fd;
  unsigned *sq_head, *sq_tail, *cq_head, *cq_tail;
  unsigned sq_mask, cq_mask, sq_entries, sq_local, to_submit;
  struct io_uring_sqe *sqes; struct io_uring_cqe *cqes;
  int accept_armed, accept_cancel, want_accept, accept_errs; unsigned nconn;
} uring;
typedef struct {
  char *pend, *wbuf; uint32_t plen, wlen, woff, gen, wnext;
  int32_t rb; uint8_t state, closing, ready;
} uconn;

static uring *rg; static int NR; static unsigned NT, NMARGIN;
static uconn *U;
static char rslots[UR_NB][RBUF_SZ];
static int ur_free[UR_NB], ur_nfree;
static uint32_t wq_head, wq_tail;                   /* FIFO of connections waiting for a buffer (global id + 1) */

static int sys_setup(unsigned n, struct io_uring_params *p) { return (int)syscall(__NR_io_uring_setup, n, p); }
#ifndef IORING_ENTER_EXT_ARG
#define IORING_ENTER_EXT_ARG (1U << 3)
#endif
struct uring_gea { uint64_t sigmask; uint32_t sigmask_sz; uint32_t pad; uint64_t ts; };
static int sys_enter_to(int fd, unsigned submit, unsigned wait, unsigned flags, long ns) {
  struct { int64_t sec; long long nsec; } ts = {0, ns};
  struct uring_gea g = {0, 0, 0, (uint64_t)(uintptr_t)&ts};
  return (int)syscall(__NR_io_uring_enter, fd, submit, wait, flags | IORING_ENTER_EXT_ARG, &g, sizeof g);
}
static int sys_enter(int fd, unsigned submit, unsigned wait, unsigned flags) {
  return (int)syscall(__NR_io_uring_enter, fd, submit, wait, flags, NULL, 0);
}
static int sys_register(int fd, unsigned op, void *arg, unsigned n) { return (int)syscall(__NR_io_uring_register, fd, op, arg, n); }

static int ring_init(uring *r, unsigned sq, unsigned cq, unsigned nslots) {
  struct io_uring_params p; int fd;
  memset(&p, 0, sizeof p);
  p.flags = IORING_SETUP_CQSIZE | IORING_SETUP_SINGLE_ISSUER | IORING_SETUP_COOP_TASKRUN; p.cq_entries = cq;
  fd = sys_setup(sq, &p);
  if (fd < 0) { memset(&p, 0, sizeof p); p.flags = IORING_SETUP_CQSIZE; p.cq_entries = cq; fd = sys_setup(sq, &p); }
  if (fd < 0) return -1;
  if (!(p.features & IORING_FEAT_SINGLE_MMAP) || !(p.features & IORING_FEAT_NODROP)) { close(fd); errno = ENOSYS; return -1; }
  size_t sz = p.sq_off.array + p.sq_entries * sizeof(unsigned);
  size_t cz = p.cq_off.cqes + p.cq_entries * sizeof(struct io_uring_cqe);
  if (cz > sz) sz = cz;
  char *m = mmap(NULL, sz, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE, fd, IORING_OFF_SQ_RING);
  if (m == MAP_FAILED) { int e = errno; close(fd); errno = e; return -1; }
  void *sqes = mmap(NULL, p.sq_entries * sizeof(struct io_uring_sqe), PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE, fd, IORING_OFF_SQES);
  if (sqes == MAP_FAILED) { int e = errno; close(fd); errno = e; return -1; }
  r->fd = fd; r->sqes = sqes; r->sq_entries = p.sq_entries;
  r->sq_head = (unsigned *)(m + p.sq_off.head); r->sq_tail = (unsigned *)(m + p.sq_off.tail);
  r->sq_mask = *(unsigned *)(m + p.sq_off.ring_mask);
  unsigned *arr = (unsigned *)(m + p.sq_off.array);
  for (unsigned i = 0; i < p.sq_entries; i++) arr[i] = i;
  r->cq_head = (unsigned *)(m + p.cq_off.head); r->cq_tail = (unsigned *)(m + p.cq_off.tail);
  r->cq_mask = *(unsigned *)(m + p.cq_off.ring_mask); r->cqes = (struct io_uring_cqe *)(m + p.cq_off.cqes);
  struct io_uring_rsrc_register rr; memset(&rr, 0, sizeof rr);
  rr.nr = nslots; rr.flags = IORING_RSRC_REGISTER_SPARSE;
  if (sys_register(fd, IORING_REGISTER_FILES2, &rr, sizeof rr) < 0) { int e = errno; close(fd); errno = e; return -1; }
  return 0;
}
static void ring_flush(uring *r) {                  /* submit everything queued, without waiting */
  __atomic_store_n(r->sq_tail, r->sq_local, __ATOMIC_RELEASE);
  while (r->to_submit) {
    int n = sys_enter(r->fd, r->to_submit, 0, 0);
    if (n < 0) { if (errno == EINTR) continue; if (errno == EBUSY || errno == EAGAIN) return; perror("io_uring_enter"); exit(1); }
    if (n == 0) return;
    r->to_submit -= (unsigned)n;
  }
}
static struct io_uring_sqe *get_sqe(uring *r) {
  if (r->sq_local - __atomic_load_n(r->sq_head, __ATOMIC_ACQUIRE) >= r->sq_entries) {
    ring_flush(r);
    if (r->sq_local - __atomic_load_n(r->sq_head, __ATOMIC_ACQUIRE) >= r->sq_entries) { fprintf(stderr, "io_uring: submission queue full\n"); exit(1); }
  }
  struct io_uring_sqe *s = &r->sqes[r->sq_local & r->sq_mask];
  memset(s, 0, sizeof *s); r->sq_local++; r->to_submit++;
  return s;
}
static void sq_accept(uring *r, int lfd) {
  struct io_uring_sqe *s = get_sqe(r);
  s->opcode = IORING_OP_ACCEPT; s->fd = lfd; s->ioprio = IORING_ACCEPT_MULTISHOT;
  s->file_index = IORING_FILE_INDEX_ALLOC; s->user_data = UD(U_ACCEPT, 0, 0);
}
static void sq_cancel(uring *r, uint64_t target) {
  struct io_uring_sqe *s = get_sqe(r);
  s->opcode = IORING_OP_ASYNC_CANCEL; s->addr = target; s->user_data = UD(U_CANCEL, 0, 0);
}
static void sq_poll(uring *r, unsigned slot, uint32_t gen) {
  struct io_uring_sqe *s = get_sqe(r);
  s->opcode = IORING_OP_POLL_ADD; s->fd = (int)slot; s->flags = IOSQE_FIXED_FILE;
  s->len = IORING_POLL_ADD_MULTI; s->poll32_events = POLLIN | POLLRDHUP; s->user_data = UD(U_POLL, slot, gen);
}
static void sq_recv(uring *r, unsigned slot, uint32_t gen, char *buf, size_t len) {
  struct io_uring_sqe *s = get_sqe(r);
  s->opcode = IORING_OP_RECV; s->fd = (int)slot; s->flags = IOSQE_FIXED_FILE;
  s->addr = (uint64_t)(uintptr_t)buf; s->len = (uint32_t)len; s->msg_flags = MSG_DONTWAIT; s->user_data = UD(U_RECV, slot, gen);
}
static void sq_send(uring *r, unsigned slot, uint32_t gen, const char *buf, size_t len) {
  struct io_uring_sqe *s = get_sqe(r);
  s->opcode = IORING_OP_SEND; s->fd = (int)slot; s->flags = IOSQE_FIXED_FILE;
  s->addr = (uint64_t)(uintptr_t)buf; s->len = (uint32_t)len; s->msg_flags = MSG_NOSIGNAL; s->user_data = UD(U_SEND, slot, gen);
}

static uconn *uc(int ri, unsigned slot) { return &U[(size_t)ri * NT + slot]; }

static void u_close(int ri, unsigned slot) {
  uring *r = &rg[ri]; uconn *c = uc(ri, slot); uint32_t gen = c->gen;
  free(c->pend); free(c->wbuf); c->pend = c->wbuf = NULL; c->plen = c->wlen = c->woff = 0;
  if (c->rb >= 0) { ur_free[ur_nfree++] = c->rb; c->rb = -1; }
  c->state = S_CLOSING;
  sq_cancel(r, UD(U_POLL, slot, gen));              /* the multishot poll holds a reference to the socket */
  struct io_uring_sqe *s = get_sqe(r);
  s->opcode = IORING_OP_CLOSE; s->file_index = slot + 1; s->user_data = UD(U_CLOSE, slot, gen);
}
static void issue_recv(int ri, unsigned slot) {     /* needs a free buffer; conn is in S_RECV */
  uconn *c = uc(ri, slot);
  int b = ur_free[--ur_nfree]; char *buf = rslots[b]; size_t off = c->plen;
  if (off >= RBUF_SZ) { ur_free[ur_nfree++] = b; u_close(ri, slot); return; }
  if (off) memcpy(buf, c->pend, off);
  c->rb = b;
  sq_recv(&rg[ri], slot, c->gen, buf + off, RBUF_SZ - off);
}
static void start_recv(int ri, unsigned slot) {
  uconn *c = uc(ri, slot);
  c->state = S_RECV; c->ready = 0; c->rb = -1;
  if (ur_nfree) { issue_recv(ri, slot); return; }
  uint32_t g = (uint32_t)((size_t)ri * NT + slot) + 1; c->wnext = 0;
  if (wq_tail) U[wq_tail - 1].wnext = g; else wq_head = g;
  wq_tail = g;
}
static void dispatch_waiters(void) {
  while (wq_head && ur_nfree) {
    uint32_t g = wq_head - 1; uconn *c = &U[g];
    wq_head = c->wnext; if (!wq_head) wq_tail = 0;
    c->wnext = 0;
    issue_recv((int)(g / NT), g % NT);
  }
}

static struct { int ri; unsigned slot, gen; } txp[131072];
static unsigned ntxp;
static void tx_flush(void);
static void tx_hold(int ri, unsigned slot, unsigned gen) {
  if (ntxp == sizeof txp / sizeof *txp) tx_flush();
  if (!g_tx) { sq_send(&rg[ri], slot, gen, uc(ri, slot)->wbuf, uc(ri, slot)->wlen); return; }
  txp[ntxp].ri = ri; txp[ntxp].slot = slot; txp[ntxp].gen = gen; ntxp++;
}
static void on_cqe(int ri, uint64_t ud, int res, unsigned fl) {
  uring *r = &rg[ri];
  unsigned type = (unsigned)(ud & 15), slot = (unsigned)((ud >> 4) & 0xFFFFF); uint32_t gen = (uint32_t)(ud >> 24);
  uconn *c = (type >= U_POLL && type <= U_CLOSE && slot < NT) ? uc(ri, slot) : NULL;
  switch (type) {
  case U_ACCEPT:
    if (res >= 0) {
      slot = (unsigned)res; c = uc(ri, slot);
      uint32_t g = c->gen + 1; memset(c, 0, sizeof *c); c->gen = g; c->rb = -1; c->state = S_IDLE;
      r->nconn++; sq_poll(r, slot, g);
    }
    if (!(fl & IORING_CQE_F_MORE)) {
      r->accept_armed = 0; r->accept_cancel = 0; r->want_accept = 1;
      if (res < 0 && res != -ECANCELED && res != -ENFILE && ++r->accept_errs > 1000) { fprintf(stderr, "io_uring accept failing: %d\n", res); exit(1); }
    }
    break;
  case U_POLL:
    if (c->gen != gen || c->state == S_CLOSING || c->state == S_FREE) break;
    if (res < 0) { if (c->state == S_IDLE) u_close(ri, slot); else c->closing = 1; break; }
    if (!(fl & IORING_CQE_F_MORE)) sq_poll(r, slot, gen);         /* the kernel ended the multishot: re-arm */
    if (c->state == S_IDLE) start_recv(ri, slot); else c->ready = 1;
    break;
  case U_RECV: {
    if (c->gen != gen || c->state != S_RECV || c->rb < 0) break;
    int b = c->rb; char *buf = rslots[b]; size_t off = c->plen;
    if (res <= 0) {
      ur_free[ur_nfree++] = b; c->rb = -1;
      if (res == -EAGAIN || res == -EINTR) { c->state = S_IDLE; if (c->ready) start_recv(ri, slot); }
      else u_close(ri, slot);
      break;
    }
    size_t total = off + (size_t)res, pos = 0;
    int closing = run_requests(buf, total, &pos);
    if ((size_t)res == RBUF_SZ - off) c->ready = 1;                 /* buffer was full: more may be waiting in the socket */
    if (!closing && pos < total) {
      size_t rem = total - pos; c->pend = realloc(c->pend, rem); memcpy(c->pend, buf + pos, rem); c->plen = (uint32_t)rem;
    } else { free(c->pend); c->pend = NULL; c->plen = 0; }
    ur_free[ur_nfree++] = b; c->rb = -1;
    if (obuf.n) {
      c->wbuf = malloc(obuf.n); if (!c->wbuf) abort();
      memcpy(c->wbuf, obuf.p, obuf.n);
      c->wlen = (uint32_t)obuf.n; c->woff = 0; c->closing |= (uint8_t)closing; c->state = S_SEND;
      if (g_tx) tx_hold(ri, slot, gen); else sq_send(r, slot, gen, c->wbuf, c->wlen);
    } else if (closing || c->closing) u_close(ri, slot);
    else { c->state = S_IDLE; if (c->ready) start_recv(ri, slot); }
    break;
  }
  case U_SEND:
    if (c->gen != gen || c->state != S_SEND) break;
    if (res == -EINTR) { sq_send(r, slot, gen, c->wbuf + c->woff, c->wlen - c->woff); break; }
    if (res <= 0) { u_close(ri, slot); break; }
    c->woff += (uint32_t)res;
    if (c->woff < c->wlen) { sq_send(r, slot, gen, c->wbuf + c->woff, c->wlen - c->woff); break; }
    free(c->wbuf); c->wbuf = NULL; c->wlen = c->woff = 0;
    if (c->closing) u_close(ri, slot);
    else { c->state = S_IDLE; if (c->ready) start_recv(ri, slot); }
    break;
  case U_CLOSE:
    r->nconn--; r->want_accept = 1;
    if (c->gen == gen && c->state == S_CLOSING) c->state = S_FREE;
    break;
  case U_RINGPOLL:
    if (!(fl & IORING_CQE_F_MORE)) {
      struct io_uring_sqe *s = get_sqe(&rg[0]);
      s->opcode = IORING_OP_POLL_ADD; s->fd = rg[slot].fd; s->len = IORING_POLL_ADD_MULTI;
      s->poll32_events = POLLIN; s->user_data = UD(U_RINGPOLL, slot, 0);
    }
    break;
  default: break;                                    /* U_CANCEL: nothing to do */
  }
  dispatch_waiters();
}
static void reap(int ri) {
  uring *r = &rg[ri];
  unsigned head = *r->cq_head, tail = __atomic_load_n(r->cq_tail, __ATOMIC_ACQUIRE), n = 0;
  while (head != tail && n < 2048) {
    struct io_uring_cqe e = r->cqes[head & r->cq_mask];
    head++; n++;
    on_cqe(ri, e.user_data, e.res, e.flags);
  }
  __atomic_store_n(r->cq_head, head, __ATOMIC_RELEASE);
}

/* Group commit: one COMMIT per loop pass, then release every held reply. No reply leaves before its commit. */
static void tx_flush(void) {
  int ok = 1;
  if (g_tx) {
    ok = sqlite3_exec(db, "COMMIT", NULL, NULL, NULL) == SQLITE_OK;
    if (!ok) sqlite3_exec(db, "ROLLBACK", NULL, NULL, NULL);
    g_tx = 0;
  }
  for (unsigned i = 0; i < ntxp; i++) {
    int ri = txp[i].ri; unsigned slot = txp[i].slot, gen = txp[i].gen;
    uconn *c = uc(ri, slot);
    if (c->gen != gen || c->state != S_SEND) continue;
    if (ok) sq_send(&rg[ri], slot, gen, c->wbuf, c->wlen); else u_close(ri, slot);
  }
  ntxp = 0;
}

/* Returns only if io_uring cannot be used (the caller then falls back to epoll). */
static int lf[64];
static int uring_serve(int lfd, unsigned nofile, const char *host, const char *port) {
  const char *e;
  NT = nofile < 400000 ? nofile : 400000; NR = 8;
  if ((e = getenv("URING_SLOTS")) && atoi(e) > 0 && (unsigned)atoi(e) < NT) NT = (unsigned)atoi(e);
  if ((e = getenv("URING_RINGS")) && atoi(e) > 0 && atoi(e) <= 64) NR = atoi(e);
  if (NT < 16) return -1;
  /* accepted-but-unplaceable sockets would be dropped, so stop accepting a ring before its table fills:
     a whole listen backlog can be accepted in one go */
  NMARGIN = NT / 8 > 4608 ? 4608 : NT / 8;
  rg = calloc((size_t)NR, sizeof *rg);
  for (int i = 0; i < NR; i++)
    if (ring_init(&rg[i], 8192, 32768, NT) < 0) { fprintf(stderr, "io_uring unavailable (%s), using epoll\n", strerror(errno)); return -1; }
  U = calloc((size_t)NR * NT, sizeof(uconn));
  if (!U) return -1;
  for (int i = 0; i < UR_NB; i++) ur_free[ur_nfree++] = i;
  for (int i = 0; i < NR; i++) { rg[i].want_accept = 1; }
  for (int i = 0; i < 64; i++) lf[i] = lfd;
  if (!getenv("NO_REUSEPORT")) {                     /* one listener per ring: the kernel hashes flows across them */
    struct sockaddr_in a2; memset(&a2, 0, sizeof a2); a2.sin_family = AF_INET; a2.sin_port = htons((uint16_t)atoi(port));
    if (inet_pton(AF_INET, host, &a2.sin_addr) != 1) a2.sin_addr.s_addr = htonl(INADDR_ANY);
    int ok = 1, o2 = 1;
    for (int i = 1; i < NR && ok; i++) {
      int f = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
      if (f < 0) { ok = 0; break; }
      setsockopt(f, SOL_SOCKET, SO_REUSEADDR, &o2, sizeof o2); setsockopt(f, SOL_SOCKET, SO_REUSEPORT, &o2, sizeof o2);
      if (bind(f, (struct sockaddr *)&a2, sizeof a2) < 0 || listen(f, 65535) < 0) { close(f); ok = 0; break; }
      setsockopt(f, IPPROTO_TCP, TCP_NODELAY, &o2, sizeof o2);
      lf[i] = f;
    }
    if (!ok) { for (int i = 1; i < NR; i++) if (lf[i] != lfd) { close(lf[i]); lf[i] = lfd; } fprintf(stderr, "reuseport listeners unavailable, sharing one\n"); }
  }
  for (int i = 1; i < NR; i++) {                     /* ring 0 sleeps for everyone: it watches the other rings */
    struct io_uring_sqe *s = get_sqe(&rg[0]);
    s->opcode = IORING_OP_POLL_ADD; s->fd = rg[i].fd; s->len = IORING_POLL_ADD_MULTI;
    s->poll32_events = POLLIN; s->user_data = UD(U_RINGPOLL, (unsigned)i, 0);
  }
  fprintf(stderr, "listening on %s:%s io_uring: %d rings of %u direct sockets\n", host, port, NR, NT);
  g_group = !getenv("NO_GROUP_COMMIT");
  for (;;) {
    for (int i = 0; i < NR; i++) {
      uring *r = &rg[i];
      if (!r->accept_armed && r->want_accept && r->nconn + NMARGIN < NT) { sq_accept(r, lf[i]); r->accept_armed = 1; r->want_accept = 0; }
      else if (r->accept_armed && !r->accept_cancel && r->nconn + NMARGIN >= NT) { sq_cancel(r, UD(U_ACCEPT, 0, 0)); r->accept_cancel = 1; }
    }
    for (int i = 1; i < NR; i++) ring_flush(&rg[i]);
    uring *r0 = &rg[0];
    __atomic_store_n(r0->sq_tail, r0->sq_local, __ATOMIC_RELEASE);
    int n = sys_enter_to(r0->fd, r0->to_submit, 1, IORING_ENTER_GETEVENTS, 1000000);
    if (n < 0) { if (errno != EINTR && errno != EBUSY && errno != EAGAIN && errno != ETIME) { perror("io_uring_enter"); exit(1); } }
    else r0->to_submit -= (unsigned)n;
    for (int i = 0; i < NR; i++) reap(i);
    tx_flush();
  }
}

int main(void) {
  signal(SIGPIPE, SIG_IGN);
  const char *path = getenv("SQLITE_PATH"), *secret = getenv("JWT_SECRET");
  const char *host = getenv("HOST"), *port = getenv("PORT");
  if (!path || !secret) { fprintf(stderr, "SQLITE_PATH and JWT_SECRET are required\n"); return 1; }
  if (!host) host = "0.0.0.0";
  if (!port) port = "3000";
  b64_init(); hmac_init((const uint8_t *)secret, strlen(secret));
  t_start = time(NULL);
  db_open(path);

  struct rlimit rl;
  if (getrlimit(RLIMIT_NOFILE, &rl) == 0) { rl.rlim_cur = rl.rlim_max; setrlimit(RLIMIT_NOFILE, &rl); getrlimit(RLIMIT_NOFILE, &rl); }
  maxfd = rl.rlim_cur > 2097152 ? 2097152 : (int)rl.rlim_cur;
  conns = calloc((size_t)maxfd, sizeof(conn));

  int lfd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
  int one = 1; setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one); setsockopt(lfd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof one);
  struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons((uint16_t)atoi(port))};
  if (inet_pton(AF_INET, host, &a.sin_addr) != 1) { fprintf(stderr, "bad HOST\n"); return 1; }
  if (bind(lfd, (struct sockaddr *)&a, sizeof a) < 0) { perror("bind"); return 1; }
  if (listen(lfd, 65535) < 0) { perror("listen"); return 1; }
  setsockopt(lfd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);   /* accepted sockets inherit it */
  if (!getenv("NO_URING")) uring_serve(lfd, (unsigned)rl.rlim_cur, host, port);
  ep = epoll_create1(EPOLL_CLOEXEC);
  struct epoll_event ev = {.events = EPOLLIN, .data.fd = lfd};
  epoll_ctl(ep, EPOLL_CTL_ADD, lfd, &ev);
  fprintf(stderr, "listening on %s:%s (maxfd %d)\n", host, port, maxfd);

  struct epoll_event evs[512];
  for (;;) {
    int n = epoll_wait(ep, evs, 512, -1);
    for (int i = 0; i < n; i++) {
      int fd = evs[i].data.fd;
      if (fd == lfd) {
        for (int k = 0; k < 256; k++) {
          int cfd = accept4(lfd, NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC);
          if (cfd < 0) break;
          if (cfd >= maxfd) { close(cfd); continue; }
          setsockopt(cfd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
          struct epoll_event ce = {.events = EPOLLIN, .data.fd = cfd};
          epoll_ctl(ep, EPOLL_CTL_ADD, cfd, &ce);
        }
        continue;
      }
      if (evs[i].events & (EPOLLERR | EPOLLHUP) && !(evs[i].events & EPOLLIN)) { close_conn(fd); continue; }
      if (evs[i].events & EPOLLOUT) on_writable(fd);
      else if (evs[i].events & EPOLLIN) on_readable(fd);
    }
  }
}
