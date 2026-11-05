#include "rt.h"
#if defined(__x86_64__)
#include <immintrin.h>
#endif

#define MAX_HEAD 16384
#define MAX_BODY 16384

static inline u8 lower(u8 c) { return (u8)(c | 0x20); }

static inline int ci_eq(const u8 *s, const char *lit, u32 n) {
  u32 i = 0;
  while (i + 8 <= n) {
    u64 a, b;
    memcpy(&a, s + i, 8);
    memcpy(&b, lit + i, 8);
    if ((a | 0x2020202020202020ULL) != b) return 0;
    i += 8;
  }
  if (i + 4 <= n) {
    u32 a, b;
    memcpy(&a, s + i, 4);
    memcpy(&b, lit + i, 4);
    if ((a | 0x20202020U) != b) return 0;
    i += 4;
  }
  for (; i < n; i++) {
    if ((u8)(s[i] | 0x20) != (u8)lit[i]) return 0;
  }
  return 1;
}

static u32 find_head_end(const u8 *p, u32 n) {
  u32 i = 0;
#if defined(__AVX2__)
  const __m256i cr256 = _mm256_set1_epi8('\r');
  for (; i + 32 + 3 <= n; i += 32) {
    u32 m = (u32)_mm256_movemask_epi8(_mm256_cmpeq_epi8(_mm256_loadu_si256((const __m256i *)(p + i)), cr256));
    while (m) {
      u32 k = i + (u32)__builtin_ctz(m);
      if (p[k + 1] == '\n' && p[k + 2] == '\r' && p[k + 3] == '\n') return k + 4;
      m &= m - 1;
    }
  }
#endif
#if defined(__x86_64__)
  const __m128i cr = _mm_set1_epi8('\r');
  for (; i + 16 + 3 <= n; i += 16) {
    int m = _mm_movemask_epi8(_mm_cmpeq_epi8(_mm_loadu_si128((const __m128i *)(p + i)), cr));
    while (m) {
      u32 k = i + (u32)__builtin_ctz((u32)m);
      if (p[k + 1] == '\n' && p[k + 2] == '\r' && p[k + 3] == '\n') return k + 4;
      m &= m - 1;
    }
  }
#endif
  for (; i + 3 < n; i++)
    if (p[i] == '\r' && p[i + 1] == '\n' && p[i + 2] == '\r' && p[i + 3] == '\n') return i + 4;
  return 0;
}

static int http_parse(const u8 *p, u32 n, req_t *r) {
  u32 he = find_head_end(p, n < MAX_HEAD ? n : MAX_HEAD);
  if (!he) return n >= MAX_HEAD ? -431 : 0;
  memset(r, 0, sizeof *r);
  const u8 *e = p + he - 2, *q = p;
  if (he >= 5 && !memcmp(p, "GET ", 4)) { r->method = M_GET; q = p + 4; }
  else if (he >= 6 && !memcmp(p, "POST ", 5)) { r->method = M_POST; q = p + 5; }
  else {
    while (q < e && *q != ' ') q++;
    if (q == p || q >= e) return -400;
    q++;
    r->method = M_OTHER;
  }
  const u8 *path = q;
  while (q < e && *q != ' ' && *q != '\r') q++;
  if (q == path || q >= e || *q != ' ') return -400;
  r->path = path;
  r->path_len = (u32)(q - path);
  const u8 *qm = memchr(path, '?', r->path_len);
  if (qm) r->path_len = (u32)(qm - path);
  q++;
  if (e - q < 10 || memcmp(q, "HTTP/1.", 7)) return -400;
  int http10 = q[7] == '0';
  q += 8;
  if (q[0] != '\r' || q[1] != '\n') return -400;
  q += 2;
  int keepalive10 = 0;
  i64 clen = -1;
  int chunked = 0;
  while (q < e) {
    const u8 *ls = q;
    const u8 *le = memchr(q, '\r', (size_t)(e - q + 2));
    if (!le || le[1] != '\n') return -400;
    const u8 *colon = memchr(ls, ':', (size_t)(le - ls));
    if (!colon || colon == ls) return -400;
    u32 nl = (u32)(colon - ls);
    const u8 *v = colon + 1;
    while (v < le && (*v == ' ' || *v == '\t')) v++;
    const u8 *ve = le;
    while (ve > v && (ve[-1] == ' ' || ve[-1] == '\t')) ve--;
    u32 vl = (u32)(ve - v);
    switch (nl) {
    case 13:
      if (ci_eq(ls, "authorization", 13)) { r->auth = v; r->auth_len = vl; r->has_auth = 1; }
      break;
    case 14:
      if (ci_eq(ls, "content-length", 14)) {
        if (!vl || vl > 9) return -400;
        i64 x = 0;
        for (u32 i = 0; i < vl; i++) { if (v[i] < '0' || v[i] > '9') return -400; x = x * 10 + (v[i] - '0'); }
        if (clen >= 0 && clen != x) return -400;
        clen = x;
      }
      break;
    case 10:
      if (ci_eq(ls, "connection", 10)) {
        if (vl == 5 && ci_eq(v, "close", 5)) r->close = 1;
        else if (vl == 10 && ci_eq(v, "keep-alive", 10)) keepalive10 = 1;
      }
      break;
    case 17:
      if (ci_eq(ls, "transfer-encoding", 17)) chunked = 1;
      break;
    }
    q = le + 2;
  }
  if (http10 && !keepalive10) r->close = 1;
  if (chunked) return -400;
  if (clen < 0) clen = 0;
  if (clen > MAX_BODY) return -413;
  if ((u64)he + (u64)clen > n) return 0;
  r->body = p + he;
  r->body_len = (u32)clen;
  return (int)(he + (u32)clen);
}

static inline int path_lit(const u8 **s, const u8 *e, const char *lit, u32 n) {
  if ((u32)(e - *s) < n || memcmp(*s, lit, n)) return 0;
  if (*s + n < e && (*s)[n] != '/') return 0;
  *s += n;
  return 1;
}
static inline int path_param(const u8 **s, const u8 *e, const u8 **v, u32 *vn) {
  if (*s >= e || **s != '/') return 0;
  const u8 *a = *s + 1, *b = a;
  while (b < e && *b != '/') b++;
  if (b == a) return 0;
  *v = a;
  *vn = (u32)(b - a);
  *s = b;
  return 1;
}
