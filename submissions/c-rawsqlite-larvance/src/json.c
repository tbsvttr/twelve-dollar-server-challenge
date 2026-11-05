#include "rt.h"
#if defined(__x86_64__)
#include <immintrin.h>
#endif

enum { JT_NONE = 0, JT_STRING, JT_NUMBER, JT_OTHER };

static u32 json_unescape(const u8 *s, u32 n, u8 *dst);

typedef struct {
  const char *key; u32 key_len;
  u8 type;
  const u8 *v; u32 v_len;
  u8 escaped;
} jmember;

typedef struct { const u8 *p, *end; int depth; } jscan;

static inline void js_ws(jscan *s) {
  while (s->p < s->end && (*s->p == ' ' || *s->p == '\t' || *s->p == '\n' || *s->p == '\r')) s->p++;
}
static inline int hexv(u8 c) {
  if (c >= '0' && c <= '9') return c - '0';
  c |= 0x20;
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  return -1;
}
static inline int utf8_len(const u8 *p, const u8 *end) {
  u8 c = p[0];
  if (c < 0x80) return 1;
  if (c < 0xC2) return 0;
  if (c < 0xE0) return (end - p >= 2 && (p[1] & 0xC0) == 0x80) ? 2 : 0;
  if (c < 0xF0) {
    if (end - p < 3 || (p[1] & 0xC0) != 0x80 || (p[2] & 0xC0) != 0x80) return 0;
    if (c == 0xE0 && p[1] < 0xA0) return 0;
    if (c == 0xED && p[1] >= 0xA0) return 0;
    return 3;
  }
  if (c < 0xF5) {
    if (end - p < 4 || (p[1] & 0xC0) != 0x80 || (p[2] & 0xC0) != 0x80 || (p[3] & 0xC0) != 0x80) return 0;
    if (c == 0xF0 && p[1] < 0x90) return 0;
    if (c == 0xF4 && p[1] >= 0x90) return 0;
    return 4;
  }
  return 0;
}
static int js_string(jscan *s, const u8 **v, u32 *n, u8 *escaped) {
  const u8 *p = s->p + 1, *start = p;
  u8 esc = 0;
  for (;;) {
#if defined(__x86_64__)
    const __m128i q = _mm_set1_epi8('"');
    const __m128i bs = _mm_set1_epi8('\\');
    const __m128i lim = _mm_set1_epi8(0x1f);
    while (p + 16 <= s->end) {
      __m128i chunk = _mm_loadu_si128((const __m128i *)p);
      __m128i special = _mm_or_si128(
          _mm_or_si128(_mm_cmpeq_epi8(chunk, q), _mm_cmpeq_epi8(chunk, bs)),
          _mm_or_si128(_mm_cmpeq_epi8(_mm_min_epu8(chunk, lim), chunk), chunk));
      int m = _mm_movemask_epi8(special);
      if (m) {
        p += (u32)__builtin_ctz((u32)m);
        break;
      }
      p += 16;
    }
#endif
    if (p >= s->end) return -1;
    u8 c = *p;
    if (c == '"') break;
    if (c == '\\') {
      esc = 1;
      if (p + 1 >= s->end) return -1;
      u8 e = p[1];
      if (e == 'u') {
        if (s->end - p < 6) return -1;
        for (int i = 2; i < 6; i++) if (hexv(p[i]) < 0) return -1;
        p += 6;
      } else if (e == '"' || e == '\\' || e == '/' || e == 'b' || e == 'f' || e == 'n' || e == 'r' || e == 't') {
        p += 2;
      } else return -1;
      continue;
    }
    if (c < 0x20) return -1;
    if (c < 0x80) { p++; continue; }
    int l = utf8_len(p, s->end);
    if (!l) return -1;
    p += l;
  }
  if (v) { *v = start; *n = (u32)(p - start); *escaped = esc; }
  s->p = p + 1;
  return 0;
}
static int js_number(jscan *s) {
  const u8 *p = s->p;
  if (p < s->end && *p == '-') p++;
  if (p >= s->end) return -1;
  if (*p == '0') p++;
  else if (*p >= '1' && *p <= '9') { while (p < s->end && *p >= '0' && *p <= '9') p++; }
  else return -1;
  if (p < s->end && *p == '.') {
    p++;
    if (p >= s->end || *p < '0' || *p > '9') return -1;
    while (p < s->end && *p >= '0' && *p <= '9') p++;
  }
  if (p < s->end && (*p == 'e' || *p == 'E')) {
    p++;
    if (p < s->end && (*p == '+' || *p == '-')) p++;
    if (p >= s->end || *p < '0' || *p > '9') return -1;
    while (p < s->end && *p >= '0' && *p <= '9') p++;
  }
  s->p = p;
  return 0;
}
static int js_value(jscan *s, u8 *type, const u8 **v, u32 *n, u8 *escaped);
static int js_lit(jscan *s, const char *lit, u32 len) {
  if ((u32)(s->end - s->p) < len || memcmp(s->p, lit, len)) return -1;
  s->p += len;
  return 0;
}
static int js_container(jscan *s, int object) {
  if (++s->depth > 64) return -1;
  s->p++;
  js_ws(s);
  u8 close = object ? '}' : ']';
  if (s->p < s->end && *s->p == close) { s->p++; s->depth--; return 0; }
  for (;;) {
    if (object) {
      if (s->p >= s->end || *s->p != '"' || js_string(s, 0, 0, 0)) return -1;
      js_ws(s);
      if (s->p >= s->end || *s->p != ':') return -1;
      s->p++;
      js_ws(s);
    }
    u8 t; const u8 *v; u32 n; u8 e;
    if (js_value(s, &t, &v, &n, &e)) return -1;
    js_ws(s);
    if (s->p >= s->end) return -1;
    if (*s->p == ',') { s->p++; js_ws(s); continue; }
    if (*s->p == close) { s->p++; s->depth--; return 0; }
    return -1;
  }
}
static int js_value(jscan *s, u8 *type, const u8 **v, u32 *n, u8 *escaped) {
  if (s->p >= s->end) return -1;
  u8 c = *s->p;
  const u8 *start = s->p;
  switch (c) {
  case '"': *type = JT_STRING; return js_string(s, v, n, escaped);
  case '{': *type = JT_OTHER; return js_container(s, 1);
  case '[': *type = JT_OTHER; return js_container(s, 0);
  case 't': *type = JT_OTHER; return js_lit(s, "true", 4);
  case 'f': *type = JT_OTHER; return js_lit(s, "false", 5);
  case 'n': *type = JT_OTHER; return js_lit(s, "null", 4);
  default:
    *type = JT_NUMBER;
    if (js_number(s)) return -1;
    *v = start; *n = (u32)(s->p - start);
    return 0;
  }
}
static int json_members(const u8 *p, u32 len, jmember *m, int nm) {
  for (int i = 0; i < nm; i++) m[i].type = JT_NONE;
  jscan s = {p, p + len, 0};
  js_ws(&s);
  if (s.p >= s.end) return -1;
  if (*s.p != '{') {
    u8 t; const u8 *v; u32 n; u8 e;
    if (js_value(&s, &t, &v, &n, &e)) return -1;
    js_ws(&s);
    return s.p == s.end ? 1 : -1;
  }
  s.p++;
  s.depth = 1;
  js_ws(&s);
  if (s.p < s.end && *s.p == '}') { s.p++; goto done; }
  for (;;) {
    const u8 *k; u32 kn; u8 kesc;
    if (s.p >= s.end || *s.p != '"' || js_string(&s, &k, &kn, &kesc)) return -1;
    js_ws(&s);
    if (s.p >= s.end || *s.p != ':') return -1;
    s.p++;
    js_ws(&s);
    u8 t; const u8 *v = 0; u32 n = 0; u8 e = 0;
    if (js_value(&s, &t, &v, &n, &e)) return -1;
    if (!kesc) {
      for (int i = 0; i < nm; i++)
        if (m[i].key_len == kn && !memcmp(m[i].key, k, kn)) { m[i].type = t; m[i].v = v; m[i].v_len = n; m[i].escaped = e; }
    } else {
      u8 tmp[64]; u32 tn = 0;
      if (kn <= sizeof tmp) {
        tn = json_unescape(k, kn, tmp);
        for (int i = 0; i < nm; i++)
          if (m[i].key_len == tn && !memcmp(m[i].key, tmp, tn)) { m[i].type = t; m[i].v = v; m[i].v_len = n; m[i].escaped = e; }
      }
    }
    js_ws(&s);
    if (s.p >= s.end) return -1;
    if (*s.p == ',') { s.p++; js_ws(&s); continue; }
    if (*s.p == '}') { s.p++; break; }
    return -1;
  }
done:
  js_ws(&s);
  return s.p == s.end ? 0 : -1;
}
static inline u8 *put_utf8(u8 *d, u32 cp) {
  if (cp < 0x80) *d++ = (u8)cp;
  else if (cp < 0x800) { *d++ = (u8)(0xC0 | cp >> 6); *d++ = (u8)(0x80 | (cp & 0x3F)); }
  else if (cp < 0x10000) { *d++ = (u8)(0xE0 | cp >> 12); *d++ = (u8)(0x80 | ((cp >> 6) & 0x3F)); *d++ = (u8)(0x80 | (cp & 0x3F)); }
  else { *d++ = (u8)(0xF0 | cp >> 18); *d++ = (u8)(0x80 | ((cp >> 12) & 0x3F)); *d++ = (u8)(0x80 | ((cp >> 6) & 0x3F)); *d++ = (u8)(0x80 | (cp & 0x3F)); }
  return d;
}
static u32 json_unescape(const u8 *s, u32 n, u8 *dst) {
  u8 *d = dst;
  const u8 *end = s + n;
  while (s < end) {
    if (*s != '\\') { *d++ = *s++; continue; }
    u8 e = s[1];
    if (e != 'u') {
      static const u8 map[128] = {['"'] = '"', ['\\'] = '\\', ['/'] = '/', ['b'] = 8, ['f'] = 12, ['n'] = 10, ['r'] = 13, ['t'] = 9};
      *d++ = map[e];
      s += 2;
      continue;
    }
    u32 cp = (u32)(hexv(s[2]) << 12 | hexv(s[3]) << 8 | hexv(s[4]) << 4 | hexv(s[5]));
    s += 6;
    if (cp >= 0xD800 && cp < 0xDC00) {
      if (end - s >= 6 && s[0] == '\\' && s[1] == 'u') {
        u32 lo = (u32)(hexv(s[2]) << 12 | hexv(s[3]) << 8 | hexv(s[4]) << 4 | hexv(s[5]));
        if (lo >= 0xDC00 && lo < 0xE000) { cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00); s += 6; }
        else cp = 0xFFFD;
      } else cp = 0xFFFD;
    } else if (cp >= 0xDC00 && cp < 0xE000) cp = 0xFFFD;
    d = put_utf8(d, cp);
  }
  return (u32)(d - dst);
}
