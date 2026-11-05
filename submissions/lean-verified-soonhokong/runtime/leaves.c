/* The C leaves: the 15 Lean definitions that carry `@[extern]`. Each function implements the Lean
 * definition its comment names, which is its specification, and `@[extern]` makes the compiled
 * program call this C code instead: the byte operations of Feed/Bytes.lean (appendEsc, appendNat,
 * appendAll, findByte), HTTP framing (Feed.Http.parse), routing (Feed.route), the JSON of bodies and
 * tokens (Feed.Json.parseTop, decodeString), HMAC-SHA256 (Feed.Hmac.mac), base64url
 * (Feed.Jwt.b64Encode, b64Decode), the feed's body (Feed.feedFromPage, Feed.Page.authored) and the
 * responses of the feed and of a post (Feed.respondFeed, Feed.respondPost). The theorems of
 * Feed/Proofs/ use the Lean definitions of all of them. Those of Hmac.mac, Jwt.b64Encode and
 * Jwt.b64Decode are proved equal to HMAC-SHA256 and base64url as Feed/Spec/Sha256.lean and
 * Feed/Spec/Base64.lean write RFC 2104 and RFC 4648, transcriptions that test vectors check
 * (Feed/Proofs/Sha256.lean, Base64.lean), Json.decodeString's to decode strings as
 * Feed/Spec/Json.lean writes RFC 8259's (Feed/Proofs/JsonToken.lean), Json.parseTop's to read
 * RFC 8259's texts as Feed/Spec/Json.lean writes them (Feed/Proofs/JsonValue.lean), and
 * Http.parse's to frame a connection's input as Feed/Spec/Http.lean writes RFC 9112 and RFC 9110
 * (Feed/Proofs/Http.lean). check-docs.sh counts them. `bin/server --selftest`
 * (Feed/Selftest.lean, run by build.sh) compares each leaf with its Lean definition on random
 * inputs. */
#include "rt.h"
#include <immintrin.h>
#include <stdlib.h>

/* Bytes that JSON requires escaping inside a string: '"', '\\' and the controls 0x00-0x1f. */
static inline unsigned esc_mask32(__m256i v) {
  __m256i q = _mm256_cmpeq_epi8(v, _mm256_set1_epi8('"'));
  __m256i b = _mm256_cmpeq_epi8(v, _mm256_set1_epi8('\\'));
  __m256i c = _mm256_cmpeq_epi8(_mm256_max_epu8(v, _mm256_set1_epi8(0x1f)), _mm256_set1_epi8(0x1f));
  return (unsigned)_mm256_movemask_epi8(_mm256_or_si256(_mm256_or_si256(q, b), c));
}

/* Load 32 bytes at s[i..], of which only `rem` (< 32 allowed) are meaningful. Reads past the
 * array's size stay inside its allocation when the capacity allows; otherwise copy. */
static inline __m256i load_tail(const u8_t *s, size_t i, size_t rem, size_t cap) {
  if (rem >= 32 || i + 32 <= cap) return _mm256_loadu_si256((const __m256i *)(s + i));
  u8_t tmp[32] = {0};
  memcpy(tmp, s + i, rem);
  return _mm256_loadu_si256((const __m256i *)tmp);
}

/* escape(src[lo, hi)) appended to out, where room for the plain copy is already reserved;
 * escapes (rare) grow the reservation for the rest of the input. */
static lean_object *esc_append(lean_object *out, b_lean_obj_arg src, u64_t lo, u64_t hi) {
  const u8_t *s = lean_sarray_cptr(src);
  size_t scap = lean_sarray_capacity(src);
  u8_t *d = ba_end(out);
  u8_t *lim = lean_sarray_cptr(out) + lean_sarray_capacity(out);
  size_t i = (size_t)lo;
  while (i < hi) {
    size_t rem = hi - i;
    __m256i v = load_tail(s, i, rem, scap);
    unsigned m = esc_mask32(v);
    if (rem < 32) m &= (1u << rem) - 1;
    _mm256_storeu_si256((__m256i *)d, v);
    if (LIKELY(!m)) {
      size_t k = rem < 32 ? rem : 32;
      d += k; i += k;
      continue;
    }
    unsigned k = (unsigned)__builtin_ctz(m);
    d += k; i += k;
    if ((size_t)(lim - d) < (hi - i) * 6 + 64) {
      lean_to_sarray(out)->m_size = (size_t)(d - lean_sarray_cptr(out));
      out = ba_reserve(out, (hi - i) * 6 + 64);
      d = ba_end(out);
      lim = lean_sarray_cptr(out) + lean_sarray_capacity(out);
    }
    u8_t ch = s[i++];
    *d++ = '\\';
    switch (ch) {
    case '"': *d++ = '"'; break;
    case '\\': *d++ = '\\'; break;
    case '\b': *d++ = 'b'; break;
    case '\f': *d++ = 'f'; break;
    case '\n': *d++ = 'n'; break;
    case '\r': *d++ = 'r'; break;
    case '\t': *d++ = 't'; break;
    default: {
      static const char hx[] = "0123456789abcdef";
      *d++ = 'u'; *d++ = '0'; *d++ = '0'; *d++ = (u8_t)hx[ch >> 4]; *d++ = (u8_t)hx[ch & 15];
    }
    }
  }
  lean_to_sarray(out)->m_size = (size_t)(d - lean_sarray_cptr(out));
  return out;
}
static inline void clamp_range(b_lean_obj_arg src, b_lean_obj_arg lon, b_lean_obj_arg hin, u64_t *lo, u64_t *hi) {
  size_t n = lean_sarray_size(src);
  *lo = nat_u64(lon); *hi = nat_u64(hin);
  if (*hi > n) *hi = n;
  if (*lo > *hi) *lo = *hi;
}

/* Feed.Bytes.appendEsc: out ++ escape(src[lo, hi)) */
LEAN_EXPORT lean_obj_res feed_append_esc(lean_obj_arg out, b_lean_obj_arg src, b_lean_obj_arg lon, b_lean_obj_arg hin) {
  u64_t lo, hi;
  clamp_range(src, lon, hin, &lo, &hi);
  out = ba_reserve(out, (size_t)(hi - lo) + 64);
  return esc_append(out, src, lo, hi);
}

/* Feed.Bytes.appendNat: out ++ decimal digits of n */
static const char dig2[201] =
    "00010203040506070809101112131415161718192021222324252627282930313233343536373839404142434445464748495051525354555657585960616263646566676869707172737475767778798081828384858687888990919293949596979899";
LEAN_EXPORT lean_obj_res feed_append_nat(lean_obj_arg out, b_lean_obj_arg nn) {
  if (UNLIKELY(!lean_is_scalar(nn))) {
    /* numbers this large never occur in responses; render them with Lean's Nat arithmetic */
    size_t cap = 64, k = 0;
    char *buf = malloc(cap);
    lean_inc(nn);
    lean_object *v = nn;
    do {
      lean_object *q = lean_nat_div(v, lean_box(10)), *r = lean_nat_mod(v, lean_box(10));
      if (k == cap) { cap *= 2; buf = realloc(buf, cap); }
      buf[k++] = (char)('0' + lean_unbox(r));
      lean_dec(v);
      v = q;
    } while (!(lean_is_scalar(v) && lean_unbox(v) == 0));
    out = ba_reserve(out, k);
    for (size_t j = 0; j < k; j++) ba_end(out)[j] = (u8_t)buf[k - 1 - j];
    ba_grow(out, k);
    free(buf);
    return out;
  }
  u64_t v = (u64_t)lean_unbox(nn);
  out = ba_reserve(out, 24);
  size_t k = 1;
  for (u64_t t = v; t >= 10; t /= 10) k++;
  u8_t *p = ba_end(out) + k;
  while (v >= 100) { unsigned r = (unsigned)(v % 100); v /= 100; p -= 2; memcpy(p, dig2 + 2 * r, 2); }
  if (v >= 10) { p -= 2; memcpy(p, dig2 + 2 * v, 2); } else *--p = (u8_t)('0' + v);
  ba_grow(out, k);
  return out;
}

/* Feed.Bytes.appendAll: out ++ src */
LEAN_EXPORT lean_obj_res feed_append_all(lean_obj_arg out, b_lean_obj_arg src) {
  size_t len = lean_sarray_size(src);
  out = ba_reserve(out, len + 32);
  copy_small(ba_end(out), lean_sarray_cptr(src), len);
  ba_grow(out, len);
  return out;
}

/* Feed.Bytes.findByte: the first i in [lo, hi) with a[i] = b, else hi (clamped to the size) */
LEAN_EXPORT lean_obj_res feed_find_byte(b_lean_obj_arg a, uint8_t b, b_lean_obj_arg lon, b_lean_obj_arg hin) {
  size_t n = lean_sarray_size(a);
  u64_t lo = nat_u64(lon), hi = nat_u64(hin);
  if (hi > n) hi = n;
  if (lo >= hi) return lean_box((size_t)(lo < hi ? lo : hi));
  const u8_t *p = memchr(lean_sarray_cptr(a) + lo, b, (size_t)(hi - lo));
  return lean_box(p ? (size_t)(p - lean_sarray_cptr(a)) : (size_t)hi);
}

/* ---- HTTP/1.1 framing: Feed.Http.parse ----------------------------------------------------
 * The byte scan of a request's head (Feed.Http.scan), then the checks of what it finds
 * (Feed.Http.finish: the Host value, the request-target, the content's length). Each function
 * below is the one of the same name in Feed/Http.lean, on the raw bytes s[0, n) and machine
 * integers; the self-test compares feed_http_parse with the Lean definition. A search up to hi
 * reads no byte at or past hi, except in loads of 32 bytes inside the array's allocation (cap
 * bytes), where those bytes are masked off. Where a Lean loop carries fuel that never runs out
 * before the bytes do, the C loop has none, and its comment says why. Indices stay below
 * n + 16400, far from overflow. */
/* The classes of Feed/Http.lean's bytes, one bit each: tchar, fieldChar, RFC 3986's sets of a
 * reg-name, a path, a query, userinfo and a scheme (each from Feed/Http.lean's two words of bits,
 * as `inSet` reads them), and hex. */
#define H_TCHAR 1
#define H_VALUE 2
#define H_REG 4
#define H_PATH 8
#define H_QUERY 16
#define H_USER 32
#define H_SCHEME 64
#define H_HEX 128
#define H_IN(lo, hi, c) (unsigned)((c) < 64 ? ((lo) >> ((c) & 63)) & 1 : (c) < 128 ? ((hi) >> ((c) & 63)) & 1 : 0)
#define H_CLASS(c) (H_IN(0x03ff6cfa00000000ull, 0x57ffffffc7fffffeull, c) | \
  (unsigned)((c) == 0x09 || ((c) >= 0x20 && (c) != 0x7f)) << 1 | \
  H_IN(0x2bff7fd200000000ull, 0x47fffffe87fffffeull, c) << 2 | H_IN(0x2fffffd200000000ull, 0x47fffffe87ffffffull, c) << 3 | \
  H_IN(0xafffffd200000000ull, 0x47fffffe87ffffffull, c) << 4 | H_IN(0x2fff7fd200000000ull, 0x47fffffe87fffffeull, c) << 5 | \
  H_IN(0x03ff680000000000ull, 0x07fffffe07fffffeull, c) << 6 | \
  (unsigned)(((c) >= 0x30 && (c) <= 0x39) || ((c) >= 0x41 && (c) <= 0x46) || ((c) >= 0x61 && (c) <= 0x66)) << 7)
#define H_C4(c) H_CLASS(c), H_CLASS((c) + 1), H_CLASS((c) + 2), H_CLASS((c) + 3)
#define H_C16(c) H_C4(c), H_C4((c) + 4), H_C4((c) + 8), H_C4((c) + 12)
#define H_C64(c) H_C16(c), H_C16((c) + 16), H_C16((c) + 32), H_C16((c) + 48)
static const u8_t h_class[256] = { H_C64(0), H_C64(64), H_C64(128), H_C64(192) };
#define H_NONE SIZE_MAX
/* `byte a i`: 0 past the end */
static inline u8_t h_byte(const u8_t *s, size_t n, size_t i) { return i < n ? s[i] : 0; }
static inline u8_t h_lower(u8_t b) { return b >= 0x41 && b <= 0x5a ? (u8_t)(b + 32) : b; }
static inline int h_digit(u8_t c) { return c >= 0x30 && c <= 0x39; }
static inline int h_alpha(u8_t c) { return (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a); }
/* eqAt: s[lo, hi) is lit[0, m) (m > 0); lit holds no NUL, so no range reaching past the end is */
static inline int h_eq(const u8_t *s, size_t n, size_t lo, size_t hi, const char *lit, size_t m) {
  return hi - lo == m && lo + m <= n && memcmp(s + lo, lit, m) == 0;
}
/* eqCI: s[lo, hi) is lit[0, m) ignoring ASCII case (lit lowercase, m > 0; lo <= hi <= n) */
static inline int h_eq_ci(const u8_t *s, size_t lo, size_t hi, const char *lit, size_t m) {
  if (hi - lo != m) return 0;
  for (size_t k = 0; k < m; k++) if (h_lower(s[lo + k]) != (u8_t)lit[k]) return 0;
  return 1;
}
/* skipLead: past the empty lines (CR LF) from i on */
static inline size_t h_skip_lead(const u8_t *s, size_t n, size_t i) {
  while (i + 1 < n && s[i] == 0x0d && s[i + 1] == 0x0a) i += 2;
  return i;
}
/* tokenEnd: the first byte from i on that is not a tchar, or hi (hi <= n) */
static inline size_t h_token_end(const u8_t *s, size_t i, size_t hi) {
  while (i < hi && (h_class[s[i]] & H_TCHAR)) i++;
  return i;
}
/* targetEnd: the first SP, CR or LF from i on, or hi (hi <= n); 32 bytes at a time */
static inline size_t h_target_end(const u8_t *s, size_t cap, size_t i, size_t hi) {
  if (i >= hi) return i;
  const __m256i sp = _mm256_set1_epi8(0x20), cr = _mm256_set1_epi8(0x0d), lf = _mm256_set1_epi8(0x0a);
  while (i + 32 <= cap) {
    __m256i v = _mm256_loadu_si256((const __m256i *)(s + i));
    unsigned m = (unsigned)_mm256_movemask_epi8(
        _mm256_or_si256(_mm256_or_si256(_mm256_cmpeq_epi8(v, sp), _mm256_cmpeq_epi8(v, cr)), _mm256_cmpeq_epi8(v, lf)));
    if (hi - i < 32) m &= (1u << (hi - i)) - 1;
    if (m) return i + (size_t)__builtin_ctz(m);
    i += 32;
    if (i >= hi) return hi;
  }
  while (i < hi && s[i] != 0x20 && s[i] != 0x0d && s[i] != 0x0a) i++;
  return i;
}
/* valueEnd: the first byte from i on that is not a fieldChar (a control other than HTAB, or DEL),
 * or hi (hi <= n); 32 bytes at a time */
static inline size_t h_value_end(const u8_t *s, size_t cap, size_t i, size_t hi) {
  if (i >= hi) return i;
  const __m256i c1f = _mm256_set1_epi8(0x1f), tab = _mm256_set1_epi8(0x09), del = _mm256_set1_epi8(0x7f);
  while (i + 32 <= cap) {
    __m256i v = _mm256_loadu_si256((const __m256i *)(s + i));
    __m256i ctl = _mm256_andnot_si256(_mm256_cmpeq_epi8(v, tab), _mm256_cmpeq_epi8(_mm256_max_epu8(v, c1f), c1f));
    unsigned m = (unsigned)_mm256_movemask_epi8(_mm256_or_si256(ctl, _mm256_cmpeq_epi8(v, del)));
    if (hi - i < 32) m &= (1u << (hi - i)) - 1;
    if (m) return i + (size_t)__builtin_ctz(m);
    i += 32;
    if (i >= hi) return hi;
  }
  while (i < hi && (h_class[s[i]] & H_VALUE)) i++;
  return i;
}
/* headEnd: the first i >= lo with i + 4 <= hi where s[i, i + 4) is CR LF CR LF, else H_NONE
 * (hi <= n); 32 candidates at a time while the loads (s[i, i + 35)) stay inside the allocation */
static inline size_t h_head_end(const u8_t *s, size_t cap, size_t lo, size_t hi) {
  size_t i = lo;
  const __m256i cr = _mm256_set1_epi8(0x0d), lf = _mm256_set1_epi8(0x0a);
  while (i + 4 <= hi && i + 35 <= cap) {
    __m256i x = _mm256_and_si256(
        _mm256_and_si256(_mm256_cmpeq_epi8(_mm256_loadu_si256((const __m256i *)(s + i)), cr),
                         _mm256_cmpeq_epi8(_mm256_loadu_si256((const __m256i *)(s + i + 1)), lf)),
        _mm256_and_si256(_mm256_cmpeq_epi8(_mm256_loadu_si256((const __m256i *)(s + i + 2)), cr),
                         _mm256_cmpeq_epi8(_mm256_loadu_si256((const __m256i *)(s + i + 3)), lf)));
    unsigned m = (unsigned)_mm256_movemask_epi8(x);
    size_t left = hi - 3 - i;   /* the candidates i + k with i + k + 4 <= hi */
    if (left < 32) m &= (1u << left) - 1;
    if (m) return i + (size_t)__builtin_ctz(m);
    if (left <= 32) return H_NONE;
    i += 32;
  }
  while (i + 4 <= hi) {
    const u8_t *p = memchr(s + i, 0x0d, hi - 3 - i);
    if (!p) break;
    size_t k = (size_t)(p - s);
    if (p[1] == 0x0a && p[2] == 0x0d && p[3] == 0x0a) return k;
    i = k + 1;
  }
  return H_NONE;
}
/* skipL: past the spaces and tabs from i on, not past e (e <= n) */
static inline size_t h_skip_l(const u8_t *s, size_t i, size_t e) {
  while (i < e && (s[i] == 0x20 || s[i] == 0x09)) i++;
  return i;
}
/* skipR: back over the spaces and tabs before e, not before lo (e <= n) */
static inline size_t h_skip_r(const u8_t *s, size_t lo, size_t e) {
  while (e > lo && (s[e - 1] == 0x20 || s[e - 1] == 0x09)) e--;
  return e;
}
/* Bytes.findByte: the first i in [lo, hi) with s[i] = b, else hi (hi <= n); the ranges are short */
static inline size_t h_find(const u8_t *s, u8_t b, size_t lo, size_t hi) {
  if (lo >= hi) return hi;
  while (lo < hi && s[lo] != b) lo++;
  return lo;
}
/* hasToken: the comma-separated value s[lo, hi) has the token tok (lowercase); hi <= n. The Lean
 * definition's fuel, hi - lo + 1, outlasts the commas. */
static int h_has_token(const u8_t *s, size_t lo, size_t hi, const char *tok, size_t m) {
  for (size_t i = lo; i < hi;) {
    size_t e = h_find(s, 0x2c, i, hi), st = h_skip_l(s, i, e);
    if (h_eq_ci(s, st, h_skip_r(s, st, e), tok, m)) return 1;
    i = e + 1;
  }
  return 0;
}
/* allIn, allHex: every byte of s[i, hi) has the class bit k (hi <= n); allDigits: is a digit */
static inline int h_all_in(const u8_t *s, unsigned k, size_t i, size_t hi) {
  for (; i < hi; i++) if (!(h_class[s[i]] & k)) return 0;
  return 1;
}
static inline int h_all_digits(const u8_t *s, size_t i, size_t hi) {
  for (; i < hi; i++) if (!h_digit(s[i])) return 0;
  return 1;
}
/* skipZeros: the first byte from i on that is not "0", or hi (hi <= n) */
static inline size_t h_skip_zeros(const u8_t *s, size_t i, size_t hi) {
  while (i < hi && s[i] == 0x30) i++;
  return i;
}
/* sameBytes: s[lo, hi) and s[lo2, hi2) are the same bytes (lo <= hi <= n, lo2 <= hi2 <= n) */
static inline int h_same_bytes(const u8_t *s, size_t lo, size_t hi, size_t lo2, size_t hi2) {
  return hi - lo == hi2 - lo2 && memcmp(s + lo, s + lo2, hi - lo) == 0;
}
/* Fields: its Nat fields in declaration order, then its Bool fields */
typedef struct {
  size_t hosts, host_lo, host_hi, auths, auth_lo, auth_hi, len_lo, len_hi;
  u8_t has_len, len_bad, coding, close, keep_alive, bad;
} fields_t;
/* field: the field line with the name s[lo, hi) and the value s[vs, ve), added to f (ve <= n) */
static void h_field(const u8_t *s, size_t lo, size_t hi, size_t vs, size_t ve, fields_t *f) {
  switch (hi - lo) {   /* the names' lengths: at most one can match */
  case 4:
    if (h_eq_ci(s, lo, hi, "host", 4)) { f->hosts++; f->host_lo = vs; f->host_hi = ve; }
    break;
  case 14:
    if (h_eq_ci(s, lo, hi, "content-length", 14)) {
      if (vs < ve && h_all_digits(s, vs, ve)) {
        size_t z = h_skip_zeros(s, vs, ve);
        if (!f->has_len) { f->has_len = 1; f->len_lo = z; f->len_hi = ve; }
        else if (!h_same_bytes(s, f->len_lo, f->len_hi, z, ve)) f->len_bad = 1;
      } else f->len_bad = 1;
    }
    break;
  case 13:
    if (h_eq_ci(s, lo, hi, "authorization", 13)) { f->auths++; f->auth_lo = vs; f->auth_hi = ve; }
    break;
  case 10:
    if (h_eq_ci(s, lo, hi, "connection", 10)) {
      f->close = f->close || h_has_token(s, vs, ve, "close", 5);
      f->keep_alive = f->keep_alive || h_has_token(s, vs, ve, "keep-alive", 10);
    }
    break;
  case 17:
    if (h_eq_ci(s, lo, hi, "transfer-encoding", 17)) f->coding = 1;
    break;
  }
}
/* fields: the field lines from i to the head's end he (he + 4 <= n). A line that does not end the
 * head is followed by another at least four bytes on (a name byte, ":", CR, LF), so the Lean
 * definition's fuel, he - i, lasts until i reaches he, where a line is bad with or without it. */
static void h_fields(const u8_t *s, size_t cap, size_t he, size_t i, fields_t *f) {
  for (;;) {
    size_t c = h_token_end(s, i, he);
    if (c == i || s[c] != 0x3a) { f->bad = 1; return; }
    size_t e = h_value_end(s, cap, c + 1, he);
    if (s[e] != 0x0d || s[e + 1] != 0x0a) { f->bad = 1; return; }
    size_t vs = h_skip_l(s, c + 1, e);
    h_field(s, i, c, vs, h_skip_r(s, vs, e), f);
    if (he <= e) return;
    i = e + 2;
  }
}
/* what scan finds: H_WAIT, a status (400, 414 or 431), or H_HEAD and the head's parts */
#define H_WAIT 0
#define H_HEAD 1
typedef struct {
  size_t i0, m, t, minor, he;
  fields_t f;
} head_t;
/* scan: the bytes of the input at pos (maxHead + 4 = 16388, maxTarget = 8192) */
static unsigned h_scan(const u8_t *s, size_t n, size_t cap, size_t pos, head_t *h) {
  /* at or past the end: no empty line, no method, no head end, fewer than 16,388 bytes */
  if (UNLIKELY(pos >= n)) return H_WAIT;
  size_t lim = n < pos + 16388 ? n : pos + 16388;
  size_t i0 = h_skip_lead(s, n, pos);
  size_t m = h_token_end(s, i0, lim);
  size_t tl = m + 2 + 8192, t = h_target_end(s, cap, m + 1, lim < tl ? lim : tl);
  int sp = i0 < m && h_byte(s, n, m) == 0x20;
  if (sp && t == tl) return 414;
  size_t he = h_head_end(s, cap, i0, lim);
  if (he == H_NONE) return pos + 16388 <= n ? 431 : H_WAIT;
  /* the request-line: method SP request-target SP HTTP-version CR LF */
  size_t v = t + 1;
  u8_t minor = h_byte(s, n, v + 7);
  if (!(sp && m + 1 < t && h_byte(s, n, t) == 0x20 && h_eq(s, n, v, v + 7, "HTTP/1.", 7) && h_digit(minor) &&
        h_byte(s, n, v + 8) == 0x0d && h_byte(s, n, v + 9) == 0x0a))
    return 400;
  memset(&h->f, 0, sizeof h->f);
  if (v + 8 != he) h_fields(s, cap, he, v + 10, &h->f);
  if (h->f.bad) return 400;
  h->i0 = i0; h->m = m; h->t = t; h->minor = (size_t)(minor - 0x30); h->he = he;
  return H_HEAD;
}

/* The Host value and the request-target (Feed.Http.finish and the deciders before it, RFC 3986's
 * grammar), on ranges [lo, hi) with hi <= n, inside which every byte they read lies. */
/* uriChars: s[i, hi) is *( c / pct-encoded ), c of the class bit k; the Lean definition's fuel,
 * hi - i, outlasts the bytes */
static inline int h_uri_chars(const u8_t *s, unsigned k, size_t i, size_t hi) {
  while (i < hi) {
    u8_t c = s[i];
    if (h_class[c] & k) i++;
    else if (c == 0x25 && i + 3 <= hi && (h_class[s[i + 1]] & h_class[s[i + 2]] & H_HEX)) i += 3;
    else return 0;
  }
  return 1;
}
/* decOctet: s[lo, hi) is 0 to 255 without a leading zero */
static int h_dec_octet(const u8_t *s, size_t lo, size_t hi) {
  if (!(lo < hi && hi <= lo + 3 && h_all_digits(s, lo, hi) && (hi == lo + 1 || s[lo] != 0x30))) return 0;
  unsigned v = 0;
  for (size_t i = lo; i < hi; i++) v = v * 10 + (unsigned)(s[i] - 0x30);
  return v < 256;
}
static int h_ipv4(const u8_t *s, size_t lo, size_t hi) {
  size_t d1 = h_find(s, 0x2e, lo, hi), d2 = h_find(s, 0x2e, d1 + 1, hi), d3 = h_find(s, 0x2e, d2 + 1, hi);
  return d3 < hi && h_dec_octet(s, lo, d1) && h_dec_octet(s, d1 + 1, d2) && h_dec_octet(s, d2 + 1, d3) &&
         h_dec_octet(s, d3 + 1, hi);
}
static inline int h_h16(const u8_t *s, size_t lo, size_t hi) {
  return lo < hi && hi <= lo + 4 && h_all_in(s, H_HEX, lo, hi);
}
/* groups: the number of h16 groups joined by ":" in s[lo, hi), the last perhaps an IPv4 address
 * (two) when v4, else H_NONE. A group followed by ":" is followed by the next at least two bytes
 * on, so the Lean definition's fuel, hi - lo, lasts until the next would start at hi, where none
 * is found with or without it. */
static size_t h_groups(const u8_t *s, size_t lo, size_t hi, int v4) {
  if (hi <= lo) return 0;
  for (size_t i = lo, k = 0;; k++) {
    size_t e = h_find(s, 0x3a, i, hi);
    if (e >= hi) return h_h16(s, i, hi) ? k + 1 : v4 && h_ipv4(s, i, hi) ? k + 2 : H_NONE;
    if (!h_h16(s, i, e)) return H_NONE;
    i = e + 1;
  }
}
/* doubleColon: the first "::" in s[lo, hi), else hi; the Lean definition's fuel, hi - lo, lasts
 * past the last place one fits */
static size_t h_double_colon(const u8_t *s, size_t lo, size_t hi) {
  for (size_t i = lo; i + 1 < hi; i++) if (s[i] == 0x3a && s[i + 1] == 0x3a) return i;
  return hi;
}
static int h_ipv6(const u8_t *s, size_t lo, size_t hi) {
  size_t d = h_double_colon(s, lo, hi);
  if (d < hi) {
    size_t i = h_groups(s, lo, d, 0), j = h_groups(s, d + 2, hi, 1);
    return i != H_NONE && j != H_NONE && i + j <= 7;
  }
  return h_groups(s, lo, hi, 1) == 8;
}
static int h_ip_future(const u8_t *s, size_t lo, size_t hi) {
  size_t d = h_find(s, 0x2e, lo, hi);
  return lo < d && d + 1 < hi && h_all_in(s, H_HEX, lo, d) && h_all_in(s, H_USER, d + 1, hi);
}
static int h_ip_literal(const u8_t *s, size_t lo, size_t hi) {
  if (lo < hi && (s[lo] == 0x76 || s[lo] == 0x56)) return h_ip_future(s, lo + 1, hi);
  return h_ipv6(s, lo, hi);
}
static inline int h_port_ok(const u8_t *s, size_t i, size_t hi) {
  return hi <= i || (s[i] == 0x3a && h_all_digits(s, i + 1, hi));
}
/* hostEnd: the end of the host if s[lo, hi) is uri-host [ ":" port ], else H_NONE */
static size_t h_host_end(const u8_t *s, size_t lo, size_t hi) {
  if (lo < hi && s[lo] == 0x5b) {
    size_t r = h_find(s, 0x5d, lo, hi);
    return r < hi && h_ip_literal(s, lo + 1, r) && h_port_ok(s, r + 1, hi) ? r + 1 : H_NONE;
  }
  size_t c = h_find(s, 0x3a, lo, hi);
  return h_uri_chars(s, H_REG, lo, c) && h_port_ok(s, c, hi) ? c : H_NONE;
}
static int h_authority(const u8_t *s, size_t lo, size_t hi) {
  size_t at = h_find(s, 0x40, lo, hi);
  if (at < hi) return h_uri_chars(s, H_USER, lo, at) && h_host_end(s, at + 1, hi) != H_NONE;
  return h_host_end(s, lo, hi) != H_NONE;
}
static int h_hier_part(const u8_t *s, size_t lo, size_t hi) {
  if (lo + 2 <= hi && s[lo] == 0x2f && s[lo + 1] == 0x2f) {
    size_t e = h_find(s, 0x2f, lo + 2, hi);
    return h_authority(s, lo + 2, e) && h_uri_chars(s, H_PATH, e, hi);
  }
  return h_uri_chars(s, H_PATH, lo, hi);
}
static int h_other_scheme(const u8_t *s, size_t lo, size_t hi) {
  size_t c = h_find(s, 0x3a, lo, hi);
  return c < hi && lo < c && h_alpha(s[lo]) && h_all_in(s, H_SCHEME, lo, c) && !h_eq_ci(s, lo, c, "http", 4) &&
         !h_eq_ci(s, lo, c, "https", 5) && h_hier_part(s, c + 1, hi);
}
/* absolutePath: 1 and the path's range if s[lo, hi) is an http or https absolute-form */
static int h_absolute_path(const u8_t *s, size_t lo, size_t hi, size_t *plo, size_t *phi) {
  size_t st = lo + 7 <= hi && h_eq_ci(s, lo, lo + 7, "http://", 7) ? lo + 7
            : lo + 8 <= hi && h_eq_ci(s, lo, lo + 8, "https://", 8) ? lo + 8 : lo;
  if (st == lo) return 0;
  size_t e = h_find(s, 0x2f, st, hi), h = h_host_end(s, st, e);
  if (h == H_NONE || !(st < h && h_uri_chars(s, H_PATH, e, hi))) return 0;
  *plo = e; *phi = hi;
  return 1;
}
/* target: 1 and the path's range if s[lo, hi) is a request-target */
static int h_target(const u8_t *s, size_t lo, size_t hi, size_t *plo, size_t *phi) {
  size_t q = h_find(s, 0x3f, lo, hi);
  int query = hi <= q || h_uri_chars(s, H_QUERY, q + 1, hi);
  if (lo < q && s[lo] == 0x2f) {
    if (!(query && h_uri_chars(s, H_PATH, lo, q))) return 0;
    *plo = lo; *phi = q;
    return 1;
  }
  if (query && h_absolute_path(s, lo, q, plo, phi)) return 1;
  size_t h;
  if ((hi == lo + 1 && s[lo] == 0x2a) || ((h = h_host_end(s, lo, hi)) != H_NONE && h < hi) ||
      (query && h_other_scheme(s, lo, q))) {
    *plo = lo; *phi = lo;
    return 1;
  }
  return 0;
}
/* lengthOf: the value of the digits s[lo, hi), or maxBody + 1 = 16385 if it is more */
static size_t h_length_of(const u8_t *s, size_t lo, size_t hi) {
  size_t acc = 0;
  for (size_t i = lo; i < hi; i++) {
    acc = acc * 10 + (u8_t)(s[i] - 0x30);
    if (acc > 16384) return 16385;
  }
  return acc;
}
static lean_obj_res h_bad(unsigned st) {
  lean_object *o = lean_alloc_ctor(1, 1, 0);
  lean_ctor_set(o, 0, lean_box(st));
  return o;
}
/* finish: the request from the head scan found (maxBody = 16384) */
static lean_obj_res h_finish(const u8_t *s, size_t n, const head_t *h) {
  const fields_t *f = &h->f;
  if (f->coding || f->len_bad || f->auths > 1) return h_bad(400);
  if (!(f->hosts == 0 ? h->minor == 0 : f->hosts == 1 && h_host_end(s, f->host_lo, f->host_hi) != H_NONE))
    return h_bad(400);
  size_t plo, phi;
  if (!h_target(s, h->m + 1, h->t, &plo, &phi)) return h_bad(400);
  size_t len = f->has_len ? h_length_of(s, f->len_lo, f->len_hi) : 0;
  if (len > 16384) return h_bad(413);
  size_t body_lo = h->he + 4;
  if (body_lo + len > n) return lean_box(0);
  u8_t head = (u8_t)h_eq(s, n, h->i0, h->m, "HEAD", 4);
  u8_t method = head || h_eq(s, n, h->i0, h->m, "GET", 3) ? 0 : h_eq(s, n, h->i0, h->m, "POST", 4) ? 1 : 2;
  lean_object *r = lean_alloc_ctor(0, 7, 4);
  lean_ctor_set(r, 0, lean_box(plo));
  lean_ctor_set(r, 1, lean_box(phi));
  lean_ctor_set(r, 2, lean_box(f->auth_lo));
  lean_ctor_set(r, 3, lean_box(f->auth_hi));
  lean_ctor_set(r, 4, lean_box(body_lo));
  lean_ctor_set(r, 5, lean_box(body_lo + len));
  lean_ctor_set(r, 6, lean_box(body_lo + len));
  lean_ctor_set_uint8(r, sizeof(void *) * 7, method);
  lean_ctor_set_uint8(r, sizeof(void *) * 7 + 1, (u8_t)(f->auths == 1));
  lean_ctor_set_uint8(r, sizeof(void *) * 7 + 2, (u8_t)(f->close || (h->minor == 0 && !f->keep_alive)));
  lean_ctor_set_uint8(r, sizeof(void *) * 7 + 3, head);
  lean_object *o = lean_alloc_ctor(2, 1, 0);
  lean_ctor_set(o, 0, r);
  return o;
}
/* Feed.Http.parse: finish of scan; incomplete (box 0), bad status (tag 1) or ok (tag 2) with the
 * Req: its Nat fields in declaration order, then method, hasAuth, close and head as bytes */
LEAN_EXPORT lean_obj_res feed_http_parse(b_lean_obj_arg a, b_lean_obj_arg posn) {
  const u8_t *s = lean_sarray_cptr(a);
  size_t n = lean_sarray_size(a);
  head_t h;
  unsigned r = lean_is_scalar(posn) ? h_scan(s, n, lean_sarray_capacity(a), lean_unbox(posn), &h) : H_WAIT;
  if (r == H_WAIT) return lean_box(0);
  if (r != H_HEAD) return h_bad(r);
  return h_finish(s, n, &h);
}

/* ---- JSON input: Feed.Json.decodeString and Feed.Json.parseTop ---------------------------
 * The functions of Feed/Json.lean on raw bytes. The Lean scanners carry fuel (hi - lo + 1);
 * it never runs out (a value of n bytes is scanned with any fuel >= n, scanValue_complete in
 * Feed/Proofs/JsonValue.lean: each level of nesting costs two and each earlier element or member
 * one, and each of those has at least as many bytes), so the C versions have none, and nesting
 * is kept on an explicit stack instead of the C stack. */
#define J_NONE SIZE_MAX
static inline int j_ws(u8_t b) { return b == 0x20 || b == 0x09 || b == 0x0a || b == 0x0d; }
static inline int j_digit(u8_t b) { return b >= 0x30 && b <= 0x39; }
static inline int j_hex(u8_t b) { return j_digit(b) || (b >= 0x61 && b <= 0x66) || (b >= 0x41 && b <= 0x46); }
static inline size_t j_skip_ws(const u8_t *s, size_t hi, size_t i) {
  while (i < hi && j_ws(s[i])) i++;
  return i;
}
/* utf8Len: the length of the well-formed UTF-8 sequence that starts at s[i] >= 0x80 and ends
 * before hi, or 0 */
static inline unsigned j_utf8_len(const u8_t *s, size_t hi, size_t i) {
  u8_t b = s[i];
  if (b >= 0xc2 && b <= 0xdf) return i + 1 < hi && s[i + 1] >= 0x80 && s[i + 1] <= 0xbf ? 2 : 0;
  if (b >= 0xe0 && b <= 0xef) {
    u8_t l = b == 0xe0 ? 0xa0 : 0x80, h = b == 0xed ? 0x9f : 0xbf;
    return i + 2 < hi && s[i + 1] >= l && s[i + 1] <= h && s[i + 2] >= 0x80 && s[i + 2] <= 0xbf ? 3 : 0;
  }
  if (b >= 0xf0 && b <= 0xf4) {
    u8_t l = b == 0xf0 ? 0x90 : 0x80, h = b == 0xf4 ? 0x8f : 0xbf;
    return i + 3 < hi && s[i + 1] >= l && s[i + 1] <= h && s[i + 2] >= 0x80 && s[i + 2] <= 0xbf &&
           s[i + 3] >= 0x80 && s[i + 3] <= 0xbf ? 4 : 0;
  }
  return 0;
}
/* scanString: i just after the opening quote; the index after the closing quote */
static size_t j_string(const u8_t *s, size_t hi, size_t i) {
  while (i < hi) {
    /* 32 bytes at a time up to the first quote, backslash, control or byte >= 0x80 */
    while (i + 32 <= hi) {
      __m256i v = _mm256_loadu_si256((const __m256i *)(s + i));
      unsigned m = esc_mask32(v) | (unsigned)_mm256_movemask_epi8(v);
      if (m) { i += (unsigned)__builtin_ctz(m); break; }
      i += 32;
    }
    if (i >= hi) break;
    u8_t b = s[i];
    if (b == 0x22) return i + 1;
    if (b < 0x20) return J_NONE;
    if (b == 0x5c) {
      if (i + 1 >= hi) return J_NONE;
      u8_t e = s[i + 1];
      if (e == 0x22 || e == 0x5c || e == 0x2f || e == 0x62 || e == 0x66 || e == 0x6e || e == 0x72 || e == 0x74) i += 2;
      else if (e == 0x75 && i + 6 <= hi && j_hex(s[i + 2]) && j_hex(s[i + 3]) && j_hex(s[i + 4]) && j_hex(s[i + 5])) i += 6;
      else return J_NONE;
    } else if (b < 0x80) i++;
    else {
      unsigned k = j_utf8_len(s, hi, i);
      if (!k) return J_NONE;
      i += k;
    }
  }
  return J_NONE;
}
static inline size_t j_digits(const u8_t *s, size_t hi, size_t i) {
  while (i < hi && j_digit(s[i])) i++;
  return i;
}
/* scanNumber */
static size_t j_number(const u8_t *s, size_t hi, size_t i) {
  if (i < hi && s[i] == 0x2d) i++;
  if (i >= hi) return J_NONE;
  if (s[i] == 0x30) i++;
  else if (j_digit(s[i])) i = j_digits(s, hi, i);
  else return J_NONE;
  if (i < hi && s[i] == 0x2e) {
    size_t j = j_digits(s, hi, i + 1);
    if (j == i + 1) return J_NONE;
    i = j;
  }
  if (i < hi && (s[i] == 0x65 || s[i] == 0x45)) {
    size_t k = i + 1 < hi && (s[i + 1] == 0x2b || s[i + 1] == 0x2d) ? i + 2 : i + 1;
    size_t j = j_digits(s, hi, k);
    if (j == k) return J_NONE;
    return j;
  }
  return i;
}
static inline size_t j_lit(const u8_t *s, size_t hi, size_t i, const char *lit, size_t m) {
  return i + m <= hi && !memcmp(s + i, lit, m) ? i + m : J_NONE;
}
/* scanValue at i (whitespace skipped): the index after the value */
static size_t j_value(const u8_t *s, size_t hi, size_t i) {
  u8_t small[64], *stk = small;   /* the open containers: '{' or '[' */
  size_t depth = 0, cap = sizeof small;
  for (;;) {
    /* a value at i */
    if (i >= hi) goto fail;
    u8_t b = s[i];
    if (b == 0x7b || b == 0x5b) {
      if (depth == cap) {
        u8_t *n2 = malloc(2 * cap);
        memcpy(n2, stk, cap);
        if (stk != small) free(stk);
        stk = n2; cap *= 2;
      }
      stk[depth++] = b;
      i = j_skip_ws(s, hi, i + 1);
      if (i >= hi) goto fail;
      if (s[i] == b + 2) { i++; depth--; goto after; }   /* '}' is '{' + 2, ']' is '[' + 2 */
      if (b == 0x7b) goto key;
      continue;
    }
    if (b == 0x22) i = j_string(s, hi, i + 1);
    else if (b == 0x74) i = j_lit(s, hi, i, "true", 4);
    else if (b == 0x66) i = j_lit(s, hi, i, "false", 5);
    else if (b == 0x6e) i = j_lit(s, hi, i, "null", 4);
    else i = j_number(s, hi, i);
    if (i == J_NONE) goto fail;
  after:
    /* a value ended at i */
    if (depth == 0) { if (stk != small) free(stk); return i; }
    i = j_skip_ws(s, hi, i);
    if (i >= hi) goto fail;
    if (s[i] == stk[depth - 1] + 2) { i++; depth--; goto after; }
    if (s[i] != 0x2c) goto fail;
    i = j_skip_ws(s, hi, i + 1);
    if (stk[depth - 1] == 0x5b) continue;
  key:
    /* a member at i: key, colon, then its value */
    if (i >= hi || s[i] != 0x22) goto fail;
    i = j_string(s, hi, i + 1);
    if (i == J_NONE) goto fail;
    i = j_skip_ws(s, hi, i);
    if (i >= hi || s[i] != 0x3a) goto fail;
    i = j_skip_ws(s, hi, i + 1);
  }
fail:
  if (stk != small) free(stk);
  return J_NONE;
}
static inline u8_t j_byte(const u8_t *s, size_t n, size_t i) { return i < n ? s[i] : 0; }
/* hexVal, with the wraparound of UInt8 for a byte that is not a hex digit */
static inline unsigned j_hex_val(u8_t b) {
  if (j_digit(b)) return (unsigned)(b - 0x30);
  if (b >= 0x61) return (u8_t)(b - 0x61 + 10);
  return (u8_t)(b - 0x41 + 10);
}
static inline u64_t j_hex4(const u8_t *s, size_t n, size_t i) {
  return (((u64_t)j_hex_val(j_byte(s, n, i)) * 16 + j_hex_val(j_byte(s, n, i + 1))) * 16 + j_hex_val(j_byte(s, n, i + 2))) * 16 +
         j_hex_val(j_byte(s, n, i + 3));
}
/* pushUtf8 at d: the end */
static inline u8_t *j_utf8(u8_t *d, u64_t c) {
  if (c < 0x80) *d++ = (u8_t)c;
  else if (c < 0x800) { *d++ = (u8_t)(0xc0 + c / 64); *d++ = (u8_t)(0x80 + c % 64); }
  else if (c < 0x10000) { *d++ = (u8_t)(0xe0 + c / 4096); *d++ = (u8_t)(0x80 + c / 64 % 64); *d++ = (u8_t)(0x80 + c % 64); }
  else { *d++ = (u8_t)(0xf0 + c / 262144); *d++ = (u8_t)(0x80 + c / 4096 % 64); *d++ = (u8_t)(0x80 + c / 64 % 64); *d++ = (u8_t)(0x80 + c % 64); }
  return d;
}
/* decodeString.go from i to hi into d, which has room for 3 (hi - i) + 4 bytes (no step writes
 * more than three bytes per byte it consumes, a surrogate pair four for twelve): the end */
static u8_t *j_decode(const u8_t *s, size_t n, size_t i, size_t hi, u8_t *d) {
  while (i + 1 < hi) {
    u8_t b = j_byte(s, n, i);
    if (b == 0x5c) {
      u8_t e = j_byte(s, n, i + 1);
      if (e == 0x75) {
        u64_t c = j_hex4(s, n, i + 2);
        if (c >= 0xd800 && c < 0xdc00 && i + 12 <= hi - 1 && j_byte(s, n, i + 6) == 0x5c && j_byte(s, n, i + 7) == 0x75) {
          u64_t c2 = j_hex4(s, n, i + 8);
          if (c2 >= 0xdc00 && c2 < 0xe000) { d = j_utf8(d, 0x10000 + (c - 0xd800) * 1024 + (c2 - 0xdc00)); i += 12; }
          else { d = j_utf8(d, 0xfffd); i += 6; }
        } else if (c >= 0xd800 && c < 0xe000) { d = j_utf8(d, 0xfffd); i += 6; }
        else { d = j_utf8(d, c); i += 6; }
      } else {
        *d++ = e == 0x62 ? 0x08 : e == 0x66 ? 0x0c : e == 0x6e ? 0x0a : e == 0x72 ? 0x0d : e == 0x74 ? 0x09 : e;
        i += 2;
      }
    } else if (b < 0x80) { *d++ = b; i++; }
    else {
      unsigned k = (b & 0xe0) == 0xc0 ? 2 : (b & 0xf0) == 0xe0 ? 3 : (b & 0xf8) == 0xf0 ? 4 : 0;
      int ok = k >= 2;
      for (unsigned j = 1; ok && j < k; j++) ok = i + j < hi - 1 && (j_byte(s, n, i + j) & 0xc0) == 0x80;
      if (ok) {
        u64_t cp = k == 2 ? (u64_t)(b & 0x1f) * 64 + (j_byte(s, n, i + 1) & 0x3f)
                 : k == 3 ? ((u64_t)(b & 0x0f) * 64 + (j_byte(s, n, i + 1) & 0x3f)) * 64 + (j_byte(s, n, i + 2) & 0x3f)
                 : (((u64_t)(b & 0x07) * 64 + (j_byte(s, n, i + 1) & 0x3f)) * 64 + (j_byte(s, n, i + 2) & 0x3f)) * 64 +
                       (j_byte(s, n, i + 3) & 0x3f);
        u64_t min = k == 2 ? 0x80 : k == 3 ? 0x800 : 0x10000;
        if (cp < min || (cp >= 0xd800 && cp < 0xe000) || cp > 0x10ffff) { d = j_utf8(d, 0xfffd); i++; }
        else { for (unsigned j = 0; j < k; j++) *d++ = j_byte(s, n, i + j); i += k; }
      } else { d = j_utf8(d, 0xfffd); i++; }
    }
  }
  return d;
}
/* Feed.Json.decodeString a lo hi */
LEAN_EXPORT lean_obj_res feed_json_decode_string(b_lean_obj_arg a, b_lean_obj_arg lon, b_lean_obj_arg hin) {
  u64_t lo, hi;
  clamp_range(a, lon, hin, &lo, &hi);
  size_t len = (size_t)(hi - lo);
  lean_object *r = lean_alloc_sarray(1, 0, 3 * len + 8);
  if (len) {
    u8_t *d = j_decode(lean_sarray_cptr(a), lean_sarray_size(a), (size_t)lo + 1, (size_t)hi, lean_sarray_cptr(r));
    lean_to_sarray(r)->m_size = (size_t)(d - lean_sarray_cptr(r));
  }
  return r;
}
/* keyEq: the key whose text is s[klo, khi) is `key` (decoded first when written with escapes) */
static int j_key_eq(const u8_t *s, size_t n, size_t klo, size_t khi, b_lean_obj_arg key) {
  size_t m = lean_sarray_size(key);
  const u8_t *k = lean_sarray_cptr(key);
  if (!memchr(s + klo, 0x5c, khi - klo)) return khi - klo == m && !memcmp(s + klo, k, m);
  size_t room = 3 * (khi - klo + 2) + 8;
  u8_t small[256], *buf = room <= sizeof small ? small : malloc(room);
  size_t dl = (size_t)(j_decode(s, n, klo, khi + 1, buf) - buf);
  int eq = dl == m && !memcmp(buf, k, m);
  if (buf != small) free(buf);
  return eq;
}
static lean_obj_res j_field(u8_t kind, size_t lo, size_t hi) {
  lean_object *f = lean_alloc_ctor(0, 2, 1);
  lean_ctor_set(f, 0, lean_box(lo));
  lean_ctor_set(f, 1, lean_box(hi));
  lean_ctor_set_uint8(f, sizeof(void *) * 2, kind);
  return f;
}
/* Feed.Json.parseTop: malformed (box 0), notObject (box 1), or object (tag 2) with the last value
 * of each wanted key: Field kind (absent 0, str 1, num 2, other 3), lo, hi. */
LEAN_EXPORT lean_obj_res feed_json_parse_top(b_lean_obj_arg a, b_lean_obj_arg lon, b_lean_obj_arg hin, b_lean_obj_arg keys) {
  const u8_t *s = lean_sarray_cptr(a);
  size_t n = lean_sarray_size(a);
  size_t hi = lean_is_scalar(hin) && lean_unbox(hin) < n ? lean_unbox(hin) : n;
  if (!lean_is_scalar(lon) || lean_unbox(lon) >= hi) return lean_box(0);   /* nothing to scan */
  size_t i = j_skip_ws(s, hi, lean_unbox(lon));
  if (!(i < hi && s[i] == 0x7b)) {
    size_t j = j_value(s, hi, i);
    return j != J_NONE && j_skip_ws(s, hi, j) == hi ? lean_box(1) : lean_box(0);
  }
  size_t nk = lean_array_size(keys);
  /* the last value of each key: kind, lo, hi (the handler asks for at most five keys) */
  size_t small[3 * 8], *rec = nk <= 8 ? small : malloc(3 * nk * sizeof(size_t));
  for (size_t k = 0; k < 3 * nk; k++) rec[k] = 0;
  i = j_skip_ws(s, hi, i + 1);
  int first = 1, ok = 0;
  size_t j = 0;
  for (;;) {
    if (i >= hi) break;
    if (first && s[i] == 0x7d) { j = i + 1; ok = 1; break; }
    if (s[i] != 0x22) break;
    size_t klo = i + 1;
    j = j_string(s, hi, i + 1);
    if (j == J_NONE) break;
    size_t khi = j - 1;
    j = j_skip_ws(s, hi, j);
    if (j >= hi || s[j] != 0x3a) break;
    size_t vlo = j_skip_ws(s, hi, j + 1);
    size_t k = j_value(s, hi, vlo);
    if (k == J_NONE) break;
    for (size_t q = 0; q < nk; q++)
      if (j_key_eq(s, n, klo, khi, lean_array_get_core(keys, q))) {
        u8_t b = s[vlo];
        rec[3 * q] = b == 0x22 ? 1 : (b == 0x2d || j_digit(b)) ? 2 : 3;
        rec[3 * q + 1] = vlo; rec[3 * q + 2] = k;
        break;
      }
    k = j_skip_ws(s, hi, k);
    if (k >= hi) break;
    if (s[k] == 0x7d) { j = k + 1; ok = 1; break; }
    if (s[k] != 0x2c) break;
    i = j_skip_ws(s, hi, k + 1);
    first = 0;
  }
  lean_object *res = lean_box(0);
  if (ok && j_skip_ws(s, hi, j) == hi) {
    lean_object *fs = lean_alloc_array(nk, nk);
    for (size_t k = 0; k < nk; k++) lean_array_set_core(fs, k, j_field((u8_t)rec[3 * k], rec[3 * k + 1], rec[3 * k + 2]));
    res = lean_alloc_ctor(2, 1, 0);
    lean_ctor_set(res, 0, fs);
  }
  if (rec != small) free(rec);
  return res;
}

/* ---- Routing: Feed.route ------------------------------------------------------------------ */
/* Feed.parseId: PostId.ok v (tag 0) when s[lo, hi) is a non-empty run of digits of value v > 0,
 * else PostId.invalid (box 1); lo <= hi <= the size. */
static lean_obj_res r_post_id(const u8_t *s, size_t lo, size_t hi) {
  if (lo >= hi) return lean_box(1);
  u64_t v = 0;
  for (size_t i = lo; i < hi; i++) {
    if (s[i] < 0x30 || s[i] > 0x39) return lean_box(1);
    if (i - lo < 19) v = v * 10 + (u64_t)(s[i] - 0x30);
  }
  lean_object *nat;
  if (hi - lo <= 19) {
    if (v == 0) return lean_box(1);
    nat = u64_nat(v);
  } else {
    /* more than 19 digits: Lean's own conversion (a value this large is never a post) */
    char *buf = malloc(hi - lo + 1);
    memcpy(buf, s + lo, hi - lo);
    buf[hi - lo] = 0;
    nat = lean_cstr_to_nat(buf);
    free(buf);
    if (lean_is_scalar(nat) && lean_unbox(nat) == 0) return lean_box(1);
  }
  lean_object *o = lean_alloc_ctor(0, 1, 0);
  lean_ctor_set(o, 0, nat);
  return o;
}
static lean_obj_res r_with_id(unsigned tag, lean_obj_arg id) {
  lean_object *o = lean_alloc_ctor(tag, 1, 0);
  lean_ctor_set(o, 0, id);
  return o;
}
/* Feed.route: the route of a request from its method and the path a[pathLo, pathHi) (both ends
 * clamped): health 0, feed 1, post id (tag 2), create 3, like id (tag 4), notFound 5. */
LEAN_EXPORT lean_obj_res feed_route(b_lean_obj_arg a, b_lean_obj_arg r) {
  const u8_t *s = lean_sarray_cptr(a);
  size_t n = lean_sarray_size(a);
  lean_object *plo = lean_ctor_get(r, 0), *phi = lean_ctor_get(r, 1);
  size_t hi = lean_is_scalar(phi) && lean_unbox(phi) < n ? lean_unbox(phi) : n;
  size_t lo = lean_is_scalar(plo) && lean_unbox(plo) < hi ? lean_unbox(plo) : hi;
  size_t len = hi - lo;
  const u8_t *p = s + lo;
  switch (lean_ctor_get_uint8(r, sizeof(void *) * 7)) {
  case 0:   /* GET */
    if (len == 5 && !memcmp(p, "/feed", 5)) return lean_box(1);
    if (len == 7 && !memcmp(p, "/health", 7)) return lean_box(0);
    if (len > 7 && !memcmp(p, "/posts/", 7) && !memchr(p + 7, '/', len - 7)) return r_with_id(2, r_post_id(s, lo + 7, hi));
    return lean_box(5);
  case 1:   /* POST */
    if (len == 6 && !memcmp(p, "/posts", 6)) return lean_box(3);
    if (len > 12 && !memcmp(p, "/posts/", 7) && !memcmp(s + hi - 5, "/like", 5) && !memchr(p + 7, '/', len - 12))
      return r_with_id(4, r_post_id(s, lo + 7, hi - 5));
    return lean_box(5);
  default:
    return lean_box(5);
  }
}

/* ---- SHA-256 (FIPS 180-4), HMAC-SHA256 and base64url, for JWT verification -------------- */
static const u32_t sha_k[64] = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};
#define ROR32(x, n) (((x) >> (n)) | ((x) << (32 - (n))))
#ifdef __SHA__
/* The compression function on the sixteen words w[0, 16) (big-endian words of a block), with
 * the SHA extensions (built when the CPU has them, as -march=native tells): four rounds per pair
 * of sha256rnds2, the message schedule by sha256msg1 and sha256msg2. The state is kept as ABEF
 * and CDGH, the order these instructions use. The SHA instructions have only legacy SSE encodings,
 * which are very slow while the upper halves of the vector registers are in use (here, hundreds
 * of cycles each): so this function clears them first and asks gcc for 128-bit vectors only. */
__attribute__((target("prefer-vector-width=128"), noinline)) static void sha_compress(u32_t h[8], const u32_t *win) {
  _mm256_zeroupper();
  __m128i tmp = _mm_shuffle_epi32(_mm_loadu_si128((const __m128i *)&h[0]), 0xB1);   /* CDAB */
  __m128i st1 = _mm_shuffle_epi32(_mm_loadu_si128((const __m128i *)&h[4]), 0x1B);   /* EFGH */
  __m128i st0 = _mm_alignr_epi8(tmp, st1, 8);                                       /* ABEF */
  st1 = _mm_blend_epi16(st1, tmp, 0xF0);                                            /* CDGH */
  const __m128i abef = st0, cdgh = st1;
  __m128i x[4];
  for (int g = 0; g < 16; g++) {
    __m128i w;
    if (g < 4) w = x[g] = _mm_loadu_si128((const __m128i *)(win + 4 * g));
    else {
      /* W[i] = W[i-16] + s0(W[i-15]) + W[i-7] + s1(W[i-2]) for the four i of group g */
      w = _mm_add_epi32(_mm_sha256msg1_epu32(x[g & 3], x[(g + 1) & 3]), _mm_alignr_epi8(x[(g + 3) & 3], x[(g + 2) & 3], 4));
      w = x[g & 3] = _mm_sha256msg2_epu32(w, x[(g + 3) & 3]);
    }
    __m128i m = _mm_add_epi32(w, _mm_loadu_si128((const __m128i *)(sha_k + 4 * g)));
    st1 = _mm_sha256rnds2_epu32(st1, st0, m);
    st0 = _mm_sha256rnds2_epu32(st0, st1, _mm_shuffle_epi32(m, 0x0E));
  }
  st0 = _mm_add_epi32(st0, abef);
  st1 = _mm_add_epi32(st1, cdgh);
  tmp = _mm_shuffle_epi32(st0, 0x1B);                                               /* FEBA */
  st1 = _mm_shuffle_epi32(st1, 0xB1);                                               /* DCHG */
  _mm_storeu_si128((__m128i *)&h[0], _mm_blend_epi16(tmp, st1, 0xF0));              /* DCBA */
  _mm_storeu_si128((__m128i *)&h[4], _mm_alignr_epi8(st1, tmp, 8));                 /* HGFE */
}
#else
/* The compression function on the sixteen words w[0, 16) (big-endian words of a block). */
static void sha_compress(u32_t h[8], const u32_t *win) {
  u32_t w[64];
  memcpy(w, win, 64);
  for (int i = 16; i < 64; i++) {
    u32_t s0 = ROR32(w[i - 15], 7) ^ ROR32(w[i - 15], 18) ^ (w[i - 15] >> 3);
    u32_t s1 = ROR32(w[i - 2], 17) ^ ROR32(w[i - 2], 19) ^ (w[i - 2] >> 10);
    w[i] = w[i - 16] + s0 + w[i - 7] + s1;
  }
  u32_t a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
#define SHA_ROUND(a, b, c, d, e, f, g, h, i)                                                      \
  do {                                                                                            \
    u32_t t1 = h + (ROR32(e, 6) ^ ROR32(e, 11) ^ ROR32(e, 25)) + ((e & f) ^ (~e & g)) + sha_k[i] + w[i]; \
    u32_t t2 = (ROR32(a, 2) ^ ROR32(a, 13) ^ ROR32(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));      \
    d += t1;                                                                                      \
    h = t1 + t2;                                                                                  \
  } while (0)
  for (int i = 0; i < 64; i += 8) {
    SHA_ROUND(a, b, c, d, e, f, g, hh, i);
    SHA_ROUND(hh, a, b, c, d, e, f, g, i + 1);
    SHA_ROUND(g, hh, a, b, c, d, e, f, i + 2);
    SHA_ROUND(f, g, hh, a, b, c, d, e, i + 3);
    SHA_ROUND(e, f, g, hh, a, b, c, d, i + 4);
    SHA_ROUND(d, e, f, g, hh, a, b, c, i + 5);
    SHA_ROUND(c, d, e, f, g, hh, a, b, i + 6);
    SHA_ROUND(b, c, d, e, f, g, hh, a, i + 7);
  }
#undef SHA_ROUND
  h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
}
#endif
static inline u32_t be32(const u8_t *p) { return (u32_t)p[0] << 24 | (u32_t)p[1] << 16 | (u32_t)p[2] << 8 | p[3]; }
static void sha_block(u32_t h[8], const u8_t *p) {
  u32_t w[16];
  for (int i = 0; i < 16; i++) w[i] = be32(p + 4 * i);
  sha_compress(h, w);
}
static void state_get(b_lean_obj_arg s, u32_t h[8]) { for (int i = 0; i < 8; i++) h[i] = lean_ctor_get_uint32(s, (unsigned)(4 * i)); }

/* Feed.Hmac.mac: HMAC-SHA256 of m[lo, hi) (hi clamped to the size, lo to hi, as Sha256.finish
 * does) under the key's inner and outer states, as Sha256.finish (from the inner state, 64 bytes
 * already hashed) then one outer block. */
LEAN_EXPORT lean_obj_res feed_hmac_mac(b_lean_obj_arg key, b_lean_obj_arg m, b_lean_obj_arg lon, b_lean_obj_arg hin) {
  u32_t h[8];
  state_get(lean_ctor_get(key, 0), h);
  u64_t lo, hi;
  clamp_range(m, lon, hin, &lo, &hi);
  const u8_t *s = lean_sarray_cptr(m);
  u64_t n = hi - lo, full = n / 64;
  for (u64_t k = 0; k < full; k++) sha_block(h, s + lo + 64 * k);
  u64_t tl = lo + 64 * full, rem = hi - tl, bits = (64 + n) * 8;
  size_t len = rem < 56 ? 64 : 128;
  u8_t tail[128];
  memset(tail, 0, len);
  memcpy(tail, s + tl, (size_t)rem);
  tail[rem] = 0x80;
  for (int j = 0; j < 8; j++) tail[len - 1 - (size_t)j] = (u8_t)(bits >> (8 * j));
  sha_block(h, tail);
  if (len == 128) sha_block(h, tail + 64);
  u32_t o[8], w[16] = {0};
  state_get(lean_ctor_get(key, 1), o);
  memcpy(w, h, 32);
  w[8] = 0x80000000u;
  w[15] = 768;
  sha_compress(o, w);
  lean_object *r = lean_alloc_sarray(1, 32, 32);
  u8_t *d = lean_sarray_cptr(r);
  for (int i = 0; i < 8; i++) { d[4 * i] = (u8_t)(o[i] >> 24); d[4 * i + 1] = (u8_t)(o[i] >> 16); d[4 * i + 2] = (u8_t)(o[i] >> 8); d[4 * i + 3] = (u8_t)o[i]; }
  return r;
}

/* Feed.Jwt.b64Encode: base64url without padding */
LEAN_EXPORT lean_obj_res feed_b64_encode(b_lean_obj_arg dv) {
  static const char al[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
  size_t n = lean_sarray_size(dv);
  const u8_t *s = lean_sarray_cptr(dv);
  lean_object *r = lean_alloc_sarray(1, 0, n * 4 / 3 + 4);
  u8_t *d = lean_sarray_cptr(r);
  size_t i = 0, k = 0;
  for (; i + 3 <= n; i += 3) {
    u32_t v = (u32_t)s[i] << 16 | (u32_t)s[i + 1] << 8 | s[i + 2];
    d[k++] = (u8_t)al[v >> 18]; d[k++] = (u8_t)al[(v >> 12) & 63]; d[k++] = (u8_t)al[(v >> 6) & 63]; d[k++] = (u8_t)al[v & 63];
  }
  if (i + 2 == n) {
    u32_t v = (u32_t)s[i] << 8 | s[i + 1];
    d[k++] = (u8_t)al[v >> 10]; d[k++] = (u8_t)al[(v >> 4) & 63]; d[k++] = (u8_t)al[(v & 15) << 2];
  } else if (i + 1 == n) {
    u32_t v = s[i];
    d[k++] = (u8_t)al[v >> 2]; d[k++] = (u8_t)al[(v & 3) << 4];
  }
  lean_to_sarray(r)->m_size = k;
  return r;
}

/* Feed.Jwt.b64Decode: base64url text a[lo, hi); none if a character is not base64url ('=' is
 * not: no padding), the length is 1 mod 4, or the bits after the last whole byte are not zero. */
static const u8_t b64v[256] = {
#define X64 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64
  X64, X64,
  64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 62, 64, 64,
  52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 64, 64, 64, 64, 64, 64,
  64, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14,
  15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 64, 64, 64, 64, 63,
  64, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40,
  41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 64, 64, 64, 64, 64,
  X64, X64, X64, X64, X64, X64, X64, X64
#undef X64
};
LEAN_EXPORT lean_obj_res feed_b64_decode(b_lean_obj_arg a, b_lean_obj_arg lon, b_lean_obj_arg hin) {
  size_t size = lean_sarray_size(a);
  const u8_t *s = lean_sarray_cptr(a);
  u64_t lo = nat_u64(lon), hi = nat_u64(hin);
  if (hi > size) hi = size;
  u64_t n = hi > lo ? hi - lo : 0;
  if (n % 4 == 1) return lean_box(0);
  lean_object *r = lean_alloc_sarray(1, 0, n * 3 / 4 + 3);
  u8_t *d = lean_sarray_cptr(r);
  size_t k = 0;
  u32_t acc = 0, nbits = 0;
  for (u64_t i = 0; i < n; i++) {
    u8_t v = b64v[s[lo + i]];
    if (v == 64) { lean_dec(r); return lean_box(0); }
    acc = acc << 6 | v;
    nbits += 6;
    if (nbits >= 8) { nbits -= 8; d[k++] = (u8_t)(acc >> nbits); acc &= (1u << nbits) - 1; }
  }
  if (acc) { lean_dec(r); return lean_box(0); }   /* the nbits (< 8) bits left over are not zero */
  lean_to_sarray(r)->m_size = k;
  lean_object *o = lean_alloc_ctor(1, 1, 0);
  lean_ctor_set(o, 0, r);
  return o;
}

/* Feed.postJsonAfter: out ++ start ++ digits id ++ ",\"body\":\"" ++ escape(src[b, c)) ++
 * "\",\"created_at\":\"" ++ escape(src[c, e)) ++ "\",\"author\":\"" ++ escape(names[s, t)) ++
 * "\",\"like_count\":" ++ digits likes ++ "}" (one post object, as the feed's and a post's
 * responses below write it; the literals are those of Feed/Handler.lean, and the self-test checks
 * those responses against their Lean definitions).
 *
 * The object is written with one reservation: room for every byte escaped to six, so the
 * copies below check no capacity. */
static inline void lit_bytes(lean_object *out, const char *s, size_t n) { memcpy(ba_end(out), s, n); ba_grow(out, n); }

/* The number of decimal digits of v (1 for 0). */
static inline unsigned dec_len(u64_t v) {
  static const u64_t p10[20] = {1ull, 10ull, 100ull, 1000ull, 10000ull, 100000ull, 1000000ull, 10000000ull,
                                100000000ull, 1000000000ull, 10000000000ull, 100000000000ull, 1000000000000ull,
                                10000000000000ull, 100000000000000ull, 1000000000000000ull, 10000000000000000ull,
                                100000000000000000ull, 1000000000000000000ull, 10000000000000000000ull};
  unsigned t = ((64u - (unsigned)__builtin_clzll(v | 1)) * 1233u) >> 12;   /* floor(log10 v) or one more */
  return t + 1 - ((v | 1) < p10[t]);
}
/* The decimal digits of v at d; the end. */
static inline u8_t *put_dec(u8_t *d, u64_t v) {
  u8_t *end = d + dec_len(v), *p = end;
  while (v >= 100) { unsigned r = (unsigned)(v % 100); v /= 100; p -= 2; memcpy(p, dig2 + 2 * r, 2); }
  if (v >= 10) { p -= 2; memcpy(p, dig2 + 2 * v, 2); } else *--p = (u8_t)('0' + v);
  return end;
}
/* escape(s[0, n)) at d, which has room for 6 n + 32 bytes; `sroom` bytes may be read from s
 * (n or more: the rest of the source's allocation). The end. */
static inline u8_t *esc_put(u8_t *d, const u8_t *s, size_t n, size_t sroom) {
  size_t i = 0;
  while (i < n) {
    size_t rem = n - i;
    __m256i v;
    if (LIKELY(rem >= 32 || sroom - i >= 32)) v = _mm256_loadu_si256((const __m256i *)(s + i));
    else {
      u8_t tmp[32] = {0};
      memcpy(tmp, s + i, rem);
      v = _mm256_loadu_si256((const __m256i *)tmp);
    }
    unsigned m = esc_mask32(v);
    if (rem < 32) m &= (1u << rem) - 1;
    _mm256_storeu_si256((__m256i *)d, v);
    if (LIKELY(!m)) {
      size_t k = rem < 32 ? rem : 32;
      d += k; i += k;
      continue;
    }
    unsigned k = (unsigned)__builtin_ctz(m);
    d += k; i += k;
    u8_t ch = s[i++];
    *d++ = '\\';
    switch (ch) {
    case '"': *d++ = '"'; break;
    case '\\': *d++ = '\\'; break;
    case '\b': *d++ = 'b'; break;
    case '\f': *d++ = 'f'; break;
    case '\n': *d++ = 'n'; break;
    case '\r': *d++ = 'r'; break;
    case '\t': *d++ = 't'; break;
    default: {
      static const char hx[] = "0123456789abcdef";
      *d++ = 'u'; *d++ = '0'; *d++ = '0'; *d++ = (u8_t)hx[ch >> 4]; *d++ = (u8_t)hx[ch & 15];
    }
    }
  }
  return d;
}
/* s[0, n) at d, which has room for n + 32 bytes, when no byte of it needs escaping (its escape
 * is itself); `sroom` bytes may be read from s. The end. */
static inline u8_t *raw_put(u8_t *d, const u8_t *s, size_t n, size_t sroom) {
  if (n < 32) {
    if (LIKELY(sroom >= 32)) _mm256_storeu_si256((__m256i *)d, _mm256_loadu_si256((const __m256i *)s));
    else copy_small(d, s, n);
    return d + n;
  }
  size_t i = 0;
  for (; i + 32 < n; i += 32) _mm256_storeu_si256((__m256i *)(d + i), _mm256_loadu_si256((const __m256i *)(s + i)));
  _mm256_storeu_si256((__m256i *)(d + n - 32), _mm256_loadu_si256((const __m256i *)(s + n - 32)));
  return d + n;
}
/* Whether no byte of a needs escaping. */
static int ba_plain(b_lean_obj_arg a) {
  const u8_t *s = lean_sarray_cptr(a);
  size_t n = lean_sarray_size(a), i = 0;
  const __m256i q = _mm256_set1_epi8('"'), bs = _mm256_set1_epi8('\\'), c = _mm256_set1_epi8(0x1f);
#define ESC_V(v) _mm256_or_si256(_mm256_or_si256(_mm256_cmpeq_epi8(v, q), _mm256_cmpeq_epi8(v, bs)), \
                                 _mm256_cmpeq_epi8(_mm256_max_epu8(v, c), c))
  for (; i + 128 <= n; i += 128) {
    __m256i v0 = _mm256_loadu_si256((const __m256i *)(s + i)), v1 = _mm256_loadu_si256((const __m256i *)(s + i + 32));
    __m256i v2 = _mm256_loadu_si256((const __m256i *)(s + i + 64)), v3 = _mm256_loadu_si256((const __m256i *)(s + i + 96));
    __m256i x = _mm256_or_si256(_mm256_or_si256(ESC_V(v0), ESC_V(v1)), _mm256_or_si256(ESC_V(v2), ESC_V(v3)));
    if (!_mm256_testz_si256(x, x)) return 0;
  }
  for (; i + 32 <= n; i += 32) {
    __m256i v = _mm256_loadu_si256((const __m256i *)(s + i)), x = ESC_V(v);
    if (!_mm256_testz_si256(x, x)) return 0;
  }
#undef ESC_V
  for (; i < n; i++) if (s[i] == '"' || s[i] == '\\' || s[i] < 0x20) return 0;
  return 1;
}
/* A Nat as decimal digits at *d, the end of out's bytes (room for 20 digits reserved). A Nat
 * that is not small goes through feed_append_nat, and then `need` bytes are reserved again. */
static inline lean_object *obj_nat(lean_object *out, u8_t **d, b_lean_obj_arg n, size_t need) {
  if (LIKELY(lean_is_scalar(n))) { *d = put_dec(*d, (u64_t)lean_unbox(n)); return out; }
  lean_to_sarray(out)->m_size = (size_t)(*d - lean_sarray_cptr(out));
  out = feed_append_nat(out, n);
  out = ba_reserve(out, need);
  *d = ba_end(out);
  return out;
}
/* One post object after `start` (slen bytes, at most 16): Feed.postJsonAfter, above. `plain`: no
 * byte of src or names needs escaping, so the strings are copied. */
static inline lean_object *post_obj(lean_object *out, const u8_t *start, size_t slen, b_lean_obj_arg idn, b_lean_obj_arg src,
                                    b_lean_obj_arg bn, b_lean_obj_arg cn, b_lean_obj_arg en, b_lean_obj_arg names,
                                    b_lean_obj_arg sn, b_lean_obj_arg tn, b_lean_obj_arg likesn, int plain) {
  static const char kBody[] = ",\"body\":\"", kCreated[] = "\",\"created_at\":\"", kAuthor[] = "\",\"author\":\"",
                    kLikes[] = "\",\"like_count\":";
  u64_t b, c, c2, e, s, t;
  clamp_range(src, bn, cn, &b, &c);
  clamp_range(src, cn, en, &c2, &e);
  clamp_range(names, sn, tn, &s, &t);
  size_t lb = (size_t)(c - b), lc = (size_t)(e - c2), la = (size_t)(t - s);
  /* at most 16 + 19 + 9 + 16 + 12 + 15 + 19 + 1 literal and digit bytes, six per escaped byte
   * (one when plain), and 32 past the end of the last string (strings are stored 32 bytes at a
   * time) */
  size_t need = (plain ? 1 : 6) * (lb + lc + la) + 256;
  out = ba_reserve(out, slen + need);
  u8_t *d = ba_end(out);
  copy_small(d, start, slen);
  d += slen;
  out = obj_nat(out, &d, idn, need);
  memcpy(d, kBody, sizeof kBody - 1);
  d += sizeof kBody - 1;
  const u8_t *sp = lean_sarray_cptr(src), *np = lean_sarray_cptr(names);
  size_t scap = lean_sarray_capacity(src), ncap = lean_sarray_capacity(names);
  if (plain) {
    d = raw_put(d, sp + b, lb, scap - (size_t)b);
    memcpy(d, kCreated, sizeof kCreated - 1);
    d += sizeof kCreated - 1;
    d = raw_put(d, sp + c2, lc, scap - (size_t)c2);
    memcpy(d, kAuthor, sizeof kAuthor - 1);
    d += sizeof kAuthor - 1;
    d = raw_put(d, np + s, la, ncap - (size_t)s);
  } else {
    d = esc_put(d, sp + b, lb, scap - (size_t)b);
    memcpy(d, kCreated, sizeof kCreated - 1);
    d += sizeof kCreated - 1;
    d = esc_put(d, sp + c2, lc, scap - (size_t)c2);
    memcpy(d, kAuthor, sizeof kAuthor - 1);
    d += sizeof kAuthor - 1;
    d = esc_put(d, np + s, la, ncap - (size_t)s);
  }
  memcpy(d, kLikes, sizeof kLikes - 1);
  d += sizeof kLikes - 1;
  out = obj_nat(out, &d, likesn, 64);
  *d++ = '}';
  lean_to_sarray(out)->m_size = (size_t)(d - lean_sarray_cptr(out));
  return out;
}

/* Feed.Bytes.clear: the empty array, keeping the allocation of a when it can be reused */
static lean_object *ba_clear(lean_obj_arg a) {
  if (lean_is_exclusive(a)) { lean_to_sarray(a)->m_size = 0; return a; }
  lean_dec(a);
  return lean_alloc_sarray(1, 0, 4096);
}

/* Feed.feedFromPage: "{\"posts\":[" ++ the post objects of the rows whose author was found (at
 * most 20, separated by commas) ++ "]}" in the cleared body, with the number of objects and the
 * number of rows (renderPage and the literals of Feed/Handler.lean, which the self-test checks
 * this against). When no byte of the page's text needs escaping, which one pass over it tells,
 * its strings are copied. */
LEAN_EXPORT lean_obj_res feed_feed_from_page(lean_obj_arg body, b_lean_obj_arg pg) {
  lean_object *blob = lean_ctor_get(pg, 0), *cols = lean_ctor_get(pg, 1);
  size_t rows = lean_array_size(cols) / 8, n = 0;
  lean_object *out = ba_clear(body);
  out = ba_reserve(out, 64);
  lit_bytes(out, "{\"posts\":[", 10);
  int plain = ba_plain(blob);
  lean_object **m = lean_array_cptr(cols);
  for (size_t k = 0; k < rows && n < 20; k++, m += 8) {
    if (m[4] != lean_box(1)) continue;
    out = post_obj(out, (const u8_t *)",{\"id\":" + (n == 0), n == 0 ? 6 : 7, m[0], blob, m[1], m[2], m[3], blob, m[5],
                   m[6], m[7], plain);
    n++;
  }
  out = ba_reserve(out, 2);
  lit_bytes(out, "]}", 2);
  lean_object *counts = lean_alloc_ctor(0, 2, 0);
  lean_ctor_set(counts, 0, lean_box(n));
  lean_ctor_set(counts, 1, lean_box(rows));
  lean_object *r = lean_alloc_ctor(0, 2, 0);
  lean_ctor_set(r, 0, out);
  lean_ctor_set(r, 1, counts);
  return r;
}

/* ---- Responses written in place: Feed.respondFeed, Feed.Page.authored --------------------- */
/* Feed.Page.authored: the rows k < size / 8 with cols[8k + 4] = 1, counted up to limit */
LEAN_EXPORT lean_obj_res feed_page_authored(b_lean_obj_arg pg, b_lean_obj_arg limitn) {
  lean_object *cols = lean_ctor_get(pg, 1);
  size_t rows = lean_array_size(cols) / 8;
  u64_t limit = nat_u64(limitn), n = 0;
  lean_object **m = lean_array_cptr(cols);
  for (size_t k = 0; k < rows && n < limit; k++) n += m[8 * k + 4] == lean_box(1);
  return lean_box((size_t)n);
}

/* respond's status line for 200 and its two ends of the head (Feed/Handler.lean) */
static const char k_head200[] = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ";
static const char k_end_head[] = "\r\n\r\n", k_end_head_close[] = "\r\nConnection: close\r\n\r\n";
/* out ++ the head of a 200 response with a body of len bytes, with room reserved for the body
 * and 32 bytes more (the copies store 32 bytes at a time) */
static inline __attribute__((always_inline)) lean_object *head_200(lean_object *out, size_t len, int close) {
  size_t el = close ? sizeof k_end_head_close - 1 : sizeof k_end_head - 1;
  out = ba_reserve(out, sizeof k_head200 - 1 + 20 + el + len + 32);
  u8_t *d = ba_end(out);
  memcpy(d, k_head200, sizeof k_head200 - 1);
  d = put_dec(d + sizeof k_head200 - 1, len);
  memcpy(d, close ? k_end_head_close : k_end_head, el);
  lean_to_sarray(out)->m_size = (size_t)(d + el - lean_sarray_cptr(out));
  return out;
}
/* a rendered row of a feed page: id, like count, and the clamped ranges of its strings */
typedef struct { u64_t id, likes, b, lb, c, lc, s, la; } feed_row_t;

/* Feed.respondFeed: respond out 200 (feedFromPage empty pg).1 close. When no byte of the page's
 * text needs escaping and every rendered id and like count is small, the body's length is known
 * from the rows, so the head is written first and the body after it, in place; otherwise the body
 * is rendered by feed_feed_from_page and copied after the head. */
LEAN_EXPORT lean_obj_res feed_respond_feed(lean_obj_arg out, b_lean_obj_arg pg, uint8_t close) {
  lean_object *blob = lean_ctor_get(pg, 0), *cols = lean_ctor_get(pg, 1);
  size_t rows = lean_array_size(cols) / 8, n = 0, len = 12;   /* {"posts":[ and ]} */
  lean_object **m = lean_array_cptr(cols);
  feed_row_t r[20];
  int fast = ba_plain(blob);
  for (size_t k = 0; fast && k < rows && n < 20; k++, m += 8) {
    if (m[4] != lean_box(1)) continue;
    if (UNLIKELY(!lean_is_scalar(m[0]) || !lean_is_scalar(m[7]))) { fast = 0; break; }
    feed_row_t *q = &r[n];
    u64_t b, c, c2, e, s, t;
    clamp_range(blob, m[1], m[2], &b, &c);
    clamp_range(blob, m[2], m[3], &c2, &e);
    clamp_range(blob, m[5], m[6], &s, &t);
    q->id = (u64_t)lean_unbox(m[0]); q->likes = (u64_t)lean_unbox(m[7]);
    q->b = b; q->lb = c - b; q->c = c2; q->lc = e - c2; q->s = s; q->la = t - s;
    /* {"id": (after a comma but for the first) ,"body":" ","created_at":" ","author":" ","like_count": } */
    len += (n ? 7 : 6) + 9 + 16 + 12 + 15 + 1 + dec_len(q->id) + dec_len(q->likes) + q->lb + q->lc + q->la;
    n++;
  }
  if (UNLIKELY(!fast)) {
    lean_object *res = feed_feed_from_page(lean_alloc_sarray(1, 0, 4096), pg);
    lean_object *body = lean_ctor_get(res, 0);
    lean_inc(body);
    lean_dec(res);
    size_t bl = lean_sarray_size(body);
    out = head_200(out, bl, close);
    memcpy(ba_end(out), lean_sarray_cptr(body), bl);
    ba_grow(out, bl);
    lean_dec(body);
    return out;
  }
  out = head_200(out, len, close);
  u8_t *d = ba_end(out);
  const u8_t *sp = lean_sarray_cptr(blob);
  size_t scap = lean_sarray_capacity(blob);
  memcpy(d, "{\"posts\":[", 10);
  d += 10;
  for (size_t j = 0; j < n; j++) {
    const feed_row_t *q = &r[j];
    *d = ',';
    d += j != 0;
    memcpy(d, "{\"id\":", 6);
    d = put_dec(d + 6, q->id);
    memcpy(d, ",\"body\":\"", 9);
    d = raw_put(d + 9, sp + q->b, (size_t)q->lb, scap - (size_t)q->b);
    memcpy(d, "\",\"created_at\":\"", 16);
    d = raw_put(d + 16, sp + q->c, (size_t)q->lc, scap - (size_t)q->c);
    memcpy(d, "\",\"author\":\"", 12);
    d = raw_put(d + 12, sp + q->s, (size_t)q->la, scap - (size_t)q->s);
    memcpy(d, "\",\"like_count\":", 15);
    d = put_dec(d + 15, q->likes);
    *d++ = '}';
  }
  memcpy(d, "]}", 2);
  lean_to_sarray(out)->m_size = (size_t)(d + 2 - lean_sarray_cptr(out));
  return out;
}

/* Feed.respondPost: respond out 200 (postFromPage empty id pg).2 close: the body is empty when
 * the page's first row is missing or has no author; otherwise {"post":…} around the post object
 * of that row with the given id. Written in place after the head when no byte of the text needs
 * escaping and the numbers are small; otherwise rendered by post_obj and copied after the head. */
LEAN_EXPORT lean_obj_res feed_respond_post(lean_obj_arg out, b_lean_obj_arg idn, b_lean_obj_arg pg, uint8_t close) {
  lean_object *blob = lean_ctor_get(pg, 0), *cols = lean_ctor_get(pg, 1);
  lean_object **m = lean_array_cptr(cols);
  if (lean_array_size(cols) < 8 || m[4] != lean_box(1)) return head_200(out, 0, close);
  if (UNLIKELY(!lean_is_scalar(idn) || !lean_is_scalar(m[7]) || !ba_plain(blob))) {
    lean_object *body = lean_alloc_sarray(1, 0, 256);
    lit_bytes(body, "{\"post\":", 8);
    body = post_obj(body, (const u8_t *)"{\"id\":", 6, idn, blob, m[1], m[2], m[3], blob, m[5], m[6], m[7], 0);
    body = ba_reserve(body, 1);
    lit_bytes(body, "}", 1);
    size_t bl = lean_sarray_size(body);
    out = head_200(out, bl, close);
    memcpy(ba_end(out), lean_sarray_cptr(body), bl);
    ba_grow(out, bl);
    lean_dec(body);
    return out;
  }
  u64_t b, c, c2, e, s, t;
  clamp_range(blob, m[1], m[2], &b, &c);
  clamp_range(blob, m[2], m[3], &c2, &e);
  clamp_range(blob, m[5], m[6], &s, &t);
  u64_t id = (u64_t)lean_unbox(idn), likes = (u64_t)lean_unbox(m[7]);
  /* {"post":{"id": ,"body":" ","created_at":" ","author":" ","like_count": }} */
  size_t len = 14 + 9 + 16 + 12 + 15 + 2 + dec_len(id) + dec_len(likes) + (size_t)(c - b) + (size_t)(e - c2) + (size_t)(t - s);
  out = head_200(out, len, close);
  u8_t *d = ba_end(out);
  const u8_t *sp = lean_sarray_cptr(blob);
  size_t scap = lean_sarray_capacity(blob);
  memcpy(d, "{\"post\":{\"id\":", 14);
  d = put_dec(d + 14, id);
  memcpy(d, ",\"body\":\"", 9);
  d = raw_put(d + 9, sp + b, (size_t)(c - b), scap - (size_t)b);
  memcpy(d, "\",\"created_at\":\"", 16);
  d = raw_put(d + 16, sp + c2, (size_t)(e - c2), scap - (size_t)c2);
  memcpy(d, "\",\"author\":\"", 12);
  d = raw_put(d + 12, sp + s, (size_t)(t - s), scap - (size_t)s);
  memcpy(d, "\",\"like_count\":", 15);
  d = put_dec(d + 15, likes);
  memcpy(d, "}}", 2);
  lean_to_sarray(out)->m_size = (size_t)(d + 2 - lean_sarray_cptr(out));
  return out;
}
