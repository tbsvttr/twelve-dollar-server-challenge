#include "rt.h"
#include <stdlib.h>
#if defined(__x86_64__)
#include <immintrin.h>
#endif

#define BLOCK 8192
enum { OB_STATIC = 0, OB_BLOCK = 1, OB_HEAP = 2 };

static obuf *obuf_free_list;
static u8 *block_free_list;
static u32 block_free_count;

static inline obuf *obuf_get(void) {
  obuf *b = obuf_free_list;
  if (LIKELY(b != NULL)) obuf_free_list = b->next;
  else if (!(b = malloc(sizeof *b))) abort();
  b->next = 0;
  return b;
}
static inline u8 *block_get(void) {
  u8 *m = block_free_list;
  if (LIKELY(m != NULL)) { block_free_list = *(u8 **)m; block_free_count--; return m; }
  if (!(m = malloc(BLOCK))) abort();
  return m;
}
static inline void block_put(u8 *m) {
  if (UNLIKELY(block_free_count >= 16384)) { free(m); return; }
  *(u8 **)m = block_free_list;
  block_free_list = m;
  block_free_count++;
}
static obuf *obuf_static(const u8 *data, u32 len) {
  obuf *b = obuf_get();
  b->data = data; b->len = len; b->cap = 0; b->mem = 0;
  return b;
}
static void obuf_release(obuf *b) {
  if (b->cap == BLOCK) block_put(b->mem);
  else if (b->cap) free(b->mem);
  b->next = obuf_free_list;
  obuf_free_list = b;
}

static inline void out_begin(out_t *o) {
  obuf *b = o->b = obuf_get();
  b->mem = block_get();
  b->cap = BLOCK;
  o->start = o->p = b->mem + HDR_ROOM;
  o->end = b->mem + BLOCK;
}
static void out_grow(out_t *o, u32 n) {
  u32 used = (u32)(o->p - o->start);
  u32 want = (u32)(o->end - o->start) * 2;
  if (want < used + n) want = used + n;
  u8 *m = malloc(HDR_ROOM + want);
  if (!m) abort();
  memcpy(m + HDR_ROOM, o->start, used);
  if (o->b->cap == BLOCK) block_put(o->b->mem); else free(o->b->mem);
  o->b->mem = m;
  o->b->cap = HDR_ROOM + want;
  o->start = m + HDR_ROOM;
  o->p = o->start + used;
  o->end = m + HDR_ROOM + want;
}
static inline void out_need(out_t *o, u32 n) {
  if (UNLIKELY((u32)(o->end - o->p) < n)) out_grow(o, n);
}
static inline void out_lit(out_t *o, const char *s, u32 n) { memcpy(o->p, s, n); o->p += n; }

static const char DEC_DIGITS[200] =
  "0001020304050607080910111213141516171819"
  "2021222324252627282930313233343536373839"
  "4041424344454647484950515253545556575859"
  "6061626364656667686970717273747576777879"
  "8081828384858687888990919293949596979899";

static inline u32 fmt_u64(u8 *d, u64 v) {
  if (v < 10) {
    d[0] = (u8)('0' + v);
    return 1;
  }
  if (v < 100) {
    memcpy(d, DEC_DIGITS + v * 2, 2);
    return 2;
  }
  u8 b[24];
  u8 *p = b + 24;
  while (v >= 100) {
    u64 q = v / 100;
    u32 r = (u32)(v - q * 100) * 2;
    v = q;
    p -= 2;
    memcpy(p, DEC_DIGITS + r, 2);
  }
  if (v < 10) {
    *--p = (u8)('0' + v);
  } else {
    p -= 2;
    memcpy(p, DEC_DIGITS + v * 2, 2);
  }
  u32 n = (u32)((b + 24) - p);
  memcpy(d, p, n);
  return n;
}

static inline void out_i64(out_t *o, i64 v) {
  if (UNLIKELY(v < 0)) { *o->p++ = '-'; v = -v; }
  o->p += fmt_u64(o->p, (u64)v);
}

static inline void out_raw_jstr(out_t *o, const u8 *s, u32 n) {
  u8 *d = o->p;
  *d++ = '"';
  memcpy(d, s, n);
  d += n;
  *d++ = '"';
  o->p = d;
}

#define JSTR_ROOM(n) (6u * (n) + 34u)
static inline void out_jstr(out_t *o, const u8 *s, u32 n) {
  u8 *d = o->p;
  *d++ = '"';
  u32 i = 0;
  for (;;) {
#if defined(__AVX2__)
    const __m256i q256 = _mm256_set1_epi8('"');
    const __m256i bs256 = _mm256_set1_epi8('\\');
    const __m256i lim256 = _mm256_set1_epi8(0x1f);
    while (i + 32 <= n) {
      __m256i v = _mm256_loadu_si256((const __m256i *)(s + i));
      __m256i bad = _mm256_or_si256(
          _mm256_or_si256(_mm256_cmpeq_epi8(v, q256), _mm256_cmpeq_epi8(v, bs256)),
          _mm256_cmpeq_epi8(_mm256_min_epu8(v, lim256), v));
      _mm256_storeu_si256((__m256i *)d, v);
      u32 m = (u32)_mm256_movemask_epi8(bad);
      if (UNLIKELY(m != 0)) {
        u32 k = (u32)__builtin_ctz(m);
        d += k;
        i += k;
        goto escape;
      }
      d += 32;
      i += 32;
    }
#endif
#if defined(__x86_64__)
    const __m128i q = _mm_set1_epi8('"'), bs = _mm_set1_epi8('\\'), lim = _mm_set1_epi8(0x1f);
    while (i + 16 <= n) {
      __m128i v = _mm_loadu_si128((const __m128i *)(s + i));
      __m128i bad = _mm_or_si128(_mm_or_si128(_mm_cmpeq_epi8(v, q), _mm_cmpeq_epi8(v, bs)),
                                 _mm_cmpeq_epi8(_mm_min_epu8(v, lim), v));
      _mm_storeu_si128((__m128i *)d, v);
      int m = _mm_movemask_epi8(bad);
      if (UNLIKELY(m != 0)) { u32 k = (u32)__builtin_ctz((u32)m); d += k; i += k; goto escape; }
      d += 16; i += 16;
    }
#endif
    for (; i < n; i++) {
      u8 c = s[i];
      if (UNLIKELY(c == '"' || c == '\\' || c < 0x20)) goto escape;
      *d++ = c;
    }
    break;
  escape:;
    u8 c = s[i++];
    *d++ = '\\';
    switch (c) {
    case '"': *d++ = '"'; break;
    case '\\': *d++ = '\\'; break;
    case '\b': *d++ = 'b'; break;
    case '\f': *d++ = 'f'; break;
    case '\n': *d++ = 'n'; break;
    case '\r': *d++ = 'r'; break;
    case '\t': *d++ = 't'; break;
    default:
      *d++ = 'u'; *d++ = '0'; *d++ = '0';
      *d++ = (u8)"0123456789abcdef"[c >> 4]; *d++ = (u8)"0123456789abcdef"[c & 15];
    }
  }
  *d++ = '"';
  o->p = d;
}

static inline obuf *out_finish(out_t *o, const u8 *hdr, u32 hdr_len) {
  u32 body = (u32)(o->p - o->start);
  u8 num[12];
  u32 nl = fmt_u64(num, body);
  u32 total = hdr_len + nl + 4;
  u8 *h = o->start - total;
  memcpy(h, hdr, hdr_len);
  memcpy(h + hdr_len, num, nl);
  memcpy(h + hdr_len + nl, "\r\n\r\n", 4);
  o->b->data = h;
  o->b->len = total + body;
  return o->b;
}

static inline void out_abort(out_t *o) { obuf_release(o->b); o->b = 0; }
