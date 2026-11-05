#include "rt.h"

typedef struct { u32 h[8]; } sha256_state;

static const u32 K256[64] = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};

static inline u32 ror32(u32 x, int n) { return x >> n | x << (32 - n); }

static void sha256_block_soft(sha256_state *s, const u8 *p) {
  u32 w[64];
  for (int i = 0; i < 16; i++) w[i] = (u32)p[4 * i] << 24 | (u32)p[4 * i + 1] << 16 | (u32)p[4 * i + 2] << 8 | p[4 * i + 3];
  for (int i = 16; i < 64; i++) {
    u32 s0 = ror32(w[i - 15], 7) ^ ror32(w[i - 15], 18) ^ (w[i - 15] >> 3);
    u32 s1 = ror32(w[i - 2], 17) ^ ror32(w[i - 2], 19) ^ (w[i - 2] >> 10);
    w[i] = w[i - 16] + s0 + w[i - 7] + s1;
  }
  u32 a = s->h[0], b = s->h[1], c = s->h[2], d = s->h[3], e = s->h[4], f = s->h[5], g = s->h[6], h = s->h[7];
  for (int i = 0; i < 64; i++) {
    u32 t1 = h + (ror32(e, 6) ^ ror32(e, 11) ^ ror32(e, 25)) + ((e & f) ^ (~e & g)) + K256[i] + w[i];
    u32 t2 = (ror32(a, 2) ^ ror32(a, 13) ^ ror32(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
    h = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
  }
  s->h[0] += a; s->h[1] += b; s->h[2] += c; s->h[3] += d; s->h[4] += e; s->h[5] += f; s->h[6] += g; s->h[7] += h;
}

#if defined(__x86_64__)
#include <x86intrin.h>

__attribute__((target("sha,sse4.1")))
static void sha256_process_x86(u32 state[8], const u8 *data, u32 length) {
    __m128i STATE0, STATE1;
    __m128i MSG, TMP;
    __m128i MSG0, MSG1, MSG2, MSG3;
    __m128i ABEF_SAVE, CDGH_SAVE;
    const __m128i MASK = _mm_set_epi64x(0x0c0d0e0f08090a0bULL, 0x0405060700010203ULL);

    TMP = _mm_loadu_si128((const __m128i*) &state[0]);
    STATE1 = _mm_loadu_si128((const __m128i*) &state[4]);

    TMP = _mm_shuffle_epi32(TMP, 0xB1);
    STATE1 = _mm_shuffle_epi32(STATE1, 0x1B);
    STATE0 = _mm_alignr_epi8(TMP, STATE1, 8);
    STATE1 = _mm_blend_epi16(STATE1, TMP, 0xF0);

    while (length >= 64) {
        ABEF_SAVE = STATE0;
        CDGH_SAVE = STATE1;

        MSG = _mm_loadu_si128((const __m128i*) (data+0));
        MSG0 = _mm_shuffle_epi8(MSG, MASK);
        MSG = _mm_add_epi32(MSG0, _mm_set_epi64x(0xE9B5DBA5B5C0FBCFULL, 0x71374491428A2F98ULL));
        STATE1 = _mm_sha256rnds2_epu32(STATE1, STATE0, MSG);
        MSG = _mm_shuffle_epi32(MSG, 0x0E);
        STATE0 = _mm_sha256rnds2_epu32(STATE0, STATE1, MSG);

        MSG1 = _mm_loadu_si128((const __m128i*) (data+16));
        MSG1 = _mm_shuffle_epi8(MSG1, MASK);
        MSG = _mm_add_epi32(MSG1, _mm_set_epi64x(0xAB1C5ED5923F82A4ULL, 0x59F111F13956C25BULL));
        STATE1 = _mm_sha256rnds2_epu32(STATE1, STATE0, MSG);
        MSG = _mm_shuffle_epi32(MSG, 0x0E);
        STATE0 = _mm_sha256rnds2_epu32(STATE0, STATE1, MSG);
        MSG0 = _mm_sha256msg1_epu32(MSG0, MSG1);

        MSG2 = _mm_loadu_si128((const __m128i*) (data+32));
        MSG2 = _mm_shuffle_epi8(MSG2, MASK);
        MSG = _mm_add_epi32(MSG2, _mm_set_epi64x(0x550C7DC3243185BEULL, 0x12835B01D807AA98ULL));
        STATE1 = _mm_sha256rnds2_epu32(STATE1, STATE0, MSG);
        MSG = _mm_shuffle_epi32(MSG, 0x0E);
        STATE0 = _mm_sha256rnds2_epu32(STATE0, STATE1, MSG);
        MSG1 = _mm_sha256msg1_epu32(MSG1, MSG2);

        MSG3 = _mm_loadu_si128((const __m128i*) (data+48));
        MSG3 = _mm_shuffle_epi8(MSG3, MASK);
        MSG = _mm_add_epi32(MSG3, _mm_set_epi64x(0xC19BF1749BDC06A7ULL, 0x80DEB1FE72BE5D74ULL));
        STATE1 = _mm_sha256rnds2_epu32(STATE1, STATE0, MSG);
        TMP = _mm_alignr_epi8(MSG3, MSG2, 4);
        MSG0 = _mm_add_epi32(MSG0, TMP);
        MSG0 = _mm_sha256msg2_epu32(MSG0, MSG3);
        MSG = _mm_shuffle_epi32(MSG, 0x0E);
        STATE0 = _mm_sha256rnds2_epu32(STATE0, STATE1, MSG);
        MSG2 = _mm_sha256msg1_epu32(MSG2, MSG3);

        MSG = _mm_add_epi32(MSG0, _mm_set_epi64x(0x240CA1CC0FC19DC6ULL, 0xEFBE4786E49B69C1ULL));
        STATE1 = _mm_sha256rnds2_epu32(STATE1, STATE0, MSG);
        TMP = _mm_alignr_epi8(MSG0, MSG3, 4);
        MSG1 = _mm_add_epi32(MSG1, TMP);
        MSG1 = _mm_sha256msg2_epu32(MSG1, MSG0);
        MSG = _mm_shuffle_epi32(MSG, 0x0E);
        STATE0 = _mm_sha256rnds2_epu32(STATE0, STATE1, MSG);
        MSG3 = _mm_sha256msg1_epu32(MSG3, MSG0);

        MSG = _mm_add_epi32(MSG1, _mm_set_epi64x(0x76F988DA5CB0A9DCULL, 0x4A7484AA2DE92C6FULL));
        STATE1 = _mm_sha256rnds2_epu32(STATE1, STATE0, MSG);
        TMP = _mm_alignr_epi8(MSG1, MSG0, 4);
        MSG2 = _mm_add_epi32(MSG2, TMP);
        MSG2 = _mm_sha256msg2_epu32(MSG2, MSG1);
        MSG = _mm_shuffle_epi32(MSG, 0x0E);
        STATE0 = _mm_sha256rnds2_epu32(STATE0, STATE1, MSG);
        MSG0 = _mm_sha256msg1_epu32(MSG0, MSG1);

        MSG = _mm_add_epi32(MSG2, _mm_set_epi64x(0xBF597FC7B00327C8ULL, 0xA831C66D983E5152ULL));
        STATE1 = _mm_sha256rnds2_epu32(STATE1, STATE0, MSG);
        TMP = _mm_alignr_epi8(MSG2, MSG1, 4);
        MSG3 = _mm_add_epi32(MSG3, TMP);
        MSG3 = _mm_sha256msg2_epu32(MSG3, MSG2);
        MSG = _mm_shuffle_epi32(MSG, 0x0E);
        STATE0 = _mm_sha256rnds2_epu32(STATE0, STATE1, MSG);
        MSG1 = _mm_sha256msg1_epu32(MSG1, MSG2);

        MSG = _mm_add_epi32(MSG3, _mm_set_epi64x(0x1429296706CA6351ULL, 0xD5A79147C6E00BF3ULL));
        STATE1 = _mm_sha256rnds2_epu32(STATE1, STATE0, MSG);
        TMP = _mm_alignr_epi8(MSG3, MSG2, 4);
        MSG0 = _mm_add_epi32(MSG0, TMP);
        MSG0 = _mm_sha256msg2_epu32(MSG0, MSG3);
        MSG = _mm_shuffle_epi32(MSG, 0x0E);
        STATE0 = _mm_sha256rnds2_epu32(STATE0, STATE1, MSG);
        MSG2 = _mm_sha256msg1_epu32(MSG2, MSG3);

        MSG = _mm_add_epi32(MSG0, _mm_set_epi64x(0x53380D134D2C6DFCULL, 0x2E1B213827B70A85ULL));
        STATE1 = _mm_sha256rnds2_epu32(STATE1, STATE0, MSG);
        TMP = _mm_alignr_epi8(MSG0, MSG3, 4);
        MSG1 = _mm_add_epi32(MSG1, TMP);
        MSG1 = _mm_sha256msg2_epu32(MSG1, MSG0);
        MSG = _mm_shuffle_epi32(MSG, 0x0E);
        STATE0 = _mm_sha256rnds2_epu32(STATE0, STATE1, MSG);
        MSG3 = _mm_sha256msg1_epu32(MSG3, MSG0);

        MSG = _mm_add_epi32(MSG1, _mm_set_epi64x(0x92722C8581C2C92EULL, 0x766A0ABB650A7354ULL));
        STATE1 = _mm_sha256rnds2_epu32(STATE1, STATE0, MSG);
        TMP = _mm_alignr_epi8(MSG1, MSG0, 4);
        MSG2 = _mm_add_epi32(MSG2, TMP);
        MSG2 = _mm_sha256msg2_epu32(MSG2, MSG1);
        MSG = _mm_shuffle_epi32(MSG, 0x0E);
        STATE0 = _mm_sha256rnds2_epu32(STATE0, STATE1, MSG);
        MSG0 = _mm_sha256msg1_epu32(MSG0, MSG1);

        MSG = _mm_add_epi32(MSG2, _mm_set_epi64x(0xC76C51A3C24B8B70ULL, 0xA81A664BA2BFE8A1ULL));
        STATE1 = _mm_sha256rnds2_epu32(STATE1, STATE0, MSG);
        TMP = _mm_alignr_epi8(MSG2, MSG1, 4);
        MSG3 = _mm_add_epi32(MSG3, TMP);
        MSG3 = _mm_sha256msg2_epu32(MSG3, MSG2);
        MSG = _mm_shuffle_epi32(MSG, 0x0E);
        STATE0 = _mm_sha256rnds2_epu32(STATE0, STATE1, MSG);
        MSG1 = _mm_sha256msg1_epu32(MSG1, MSG2);

        MSG = _mm_add_epi32(MSG3, _mm_set_epi64x(0x106AA070F40E3585ULL, 0xD6990624D192E819ULL));
        STATE1 = _mm_sha256rnds2_epu32(STATE1, STATE0, MSG);
        TMP = _mm_alignr_epi8(MSG3, MSG2, 4);
        MSG0 = _mm_add_epi32(MSG0, TMP);
        MSG0 = _mm_sha256msg2_epu32(MSG0, MSG3);
        MSG = _mm_shuffle_epi32(MSG, 0x0E);
        STATE0 = _mm_sha256rnds2_epu32(STATE0, STATE1, MSG);
        MSG2 = _mm_sha256msg1_epu32(MSG2, MSG3);

        MSG = _mm_add_epi32(MSG0, _mm_set_epi64x(0x34B0BCB52748774CULL, 0x1E376C0819A4C116ULL));
        STATE1 = _mm_sha256rnds2_epu32(STATE1, STATE0, MSG);
        TMP = _mm_alignr_epi8(MSG0, MSG3, 4);
        MSG1 = _mm_add_epi32(MSG1, TMP);
        MSG1 = _mm_sha256msg2_epu32(MSG1, MSG0);
        MSG = _mm_shuffle_epi32(MSG, 0x0E);
        STATE0 = _mm_sha256rnds2_epu32(STATE0, STATE1, MSG);
        MSG3 = _mm_sha256msg1_epu32(MSG3, MSG0);

        MSG = _mm_add_epi32(MSG1, _mm_set_epi64x(0x682E6FF35B9CCA4FULL, 0x4ED8AA4A391C0CB3ULL));
        STATE1 = _mm_sha256rnds2_epu32(STATE1, STATE0, MSG);
        TMP = _mm_alignr_epi8(MSG1, MSG0, 4);
        MSG2 = _mm_add_epi32(MSG2, TMP);
        MSG2 = _mm_sha256msg2_epu32(MSG2, MSG1);
        MSG = _mm_shuffle_epi32(MSG, 0x0E);
        STATE0 = _mm_sha256rnds2_epu32(STATE0, STATE1, MSG);

        MSG = _mm_add_epi32(MSG2, _mm_set_epi64x(0x8CC7020884C87814ULL, 0x78A5636F748F82EEULL));
        STATE1 = _mm_sha256rnds2_epu32(STATE1, STATE0, MSG);
        TMP = _mm_alignr_epi8(MSG2, MSG1, 4);
        MSG3 = _mm_add_epi32(MSG3, TMP);
        MSG3 = _mm_sha256msg2_epu32(MSG3, MSG2);
        MSG = _mm_shuffle_epi32(MSG, 0x0E);
        STATE0 = _mm_sha256rnds2_epu32(STATE0, STATE1, MSG);

        MSG = _mm_add_epi32(MSG3, _mm_set_epi64x(0xC67178F2BEF9A3F7ULL, 0xA4506CEB90BEFFFAULL));
        STATE1 = _mm_sha256rnds2_epu32(STATE1, STATE0, MSG);
        MSG = _mm_shuffle_epi32(MSG, 0x0E);
        STATE0 = _mm_sha256rnds2_epu32(STATE0, STATE1, MSG);

        STATE0 = _mm_add_epi32(STATE0, ABEF_SAVE);
        STATE1 = _mm_add_epi32(STATE1, CDGH_SAVE);

        data += 64;
        length -= 64;
    }

    TMP = _mm_shuffle_epi32(STATE0, 0x1B);
    STATE1 = _mm_shuffle_epi32(STATE1, 0xB1);
    STATE0 = _mm_blend_epi16(TMP, STATE1, 0xF0);
    STATE1 = _mm_alignr_epi8(STATE1, TMP, 8);

    _mm_storeu_si128((__m128i*) &state[0], STATE0);
    _mm_storeu_si128((__m128i*) &state[4], STATE1);
}
#endif

static int has_sha_ni = 0;
static const u32 SHA256_IV[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};

static void sha256_finish(sha256_state *s, u64 prefix_bytes, const u8 *msg, size_t n, u8 out[32]) {
  size_t full = n & ~(size_t)63;
#if defined(__x86_64__)
  if (has_sha_ni) {
    if (full) sha256_process_x86(s->h, msg, (u32)full);
    u8 tail[128];
    size_t r = n - full;
    memcpy(tail, msg + full, r);
    tail[r] = 0x80;
    size_t tl = r + 1 + 8 <= 64 ? 64 : 128;
    memset(tail + r + 1, 0, tl - r - 1);
    u64 bits = (prefix_bytes + n) * 8;
    for (int i = 0; i < 8; i++) tail[tl - 1 - i] = (u8)(bits >> (8 * i));
    sha256_process_x86(s->h, tail, (u32)tl);
  } else {
#endif
    for (size_t i = 0; i < full; i += 64) sha256_block_soft(s, msg + i);
    u8 tail[128];
    size_t r = n - full;
    memcpy(tail, msg + full, r);
    tail[r] = 0x80;
    size_t tl = r + 1 + 8 <= 64 ? 64 : 128;
    memset(tail + r + 1, 0, tl - r - 1);
    u64 bits = (prefix_bytes + n) * 8;
    for (int i = 0; i < 8; i++) tail[tl - 1 - i] = (u8)(bits >> (8 * i));
    sha256_block_soft(s, tail);
    if (tl == 128) sha256_block_soft(s, tail + 64);
#if defined(__x86_64__)
  }
#endif
  for (int i = 0; i < 8; i++) {
    out[4 * i]     = (u8)(s->h[i] >> 24);
    out[4 * i + 1] = (u8)(s->h[i] >> 16);
    out[4 * i + 2] = (u8)(s->h[i] >> 8);
    out[4 * i + 3] = (u8)s->h[i];
  }
}

static sha256_state hmac_inner, hmac_outer;

static void hmac_init(const u8 *key, size_t n) {
#if defined(__x86_64__)
  has_sha_ni = __builtin_cpu_supports("sha");
#endif
  u8 k[64] = {0};
  if (n > 64) {
    sha256_state s;
    memcpy(s.h, SHA256_IV, sizeof s.h);
    sha256_finish(&s, 0, key, n, k);
  } else {
    memcpy(k, key, n);
  }
  u8 pad[64];
  for (int i = 0; i < 64; i++) pad[i] = k[i] ^ 0x36;
  memcpy(hmac_inner.h, SHA256_IV, sizeof SHA256_IV);
#if defined(__x86_64__)
  if (has_sha_ni) sha256_process_x86(hmac_inner.h, pad, 64);
  else
#endif
    sha256_block_soft(&hmac_inner, pad);

  for (int i = 0; i < 64; i++) pad[i] = k[i] ^ 0x5c;
  memcpy(hmac_outer.h, SHA256_IV, sizeof SHA256_IV);
#if defined(__x86_64__)
  if (has_sha_ni) sha256_process_x86(hmac_outer.h, pad, 64);
  else
#endif
    sha256_block_soft(&hmac_outer, pad);
}

static void hmac_sha256(const u8 *msg, size_t n, u8 out[32]) {
  u8 ih[32];
  sha256_state s = hmac_inner;
  sha256_finish(&s, 64, msg, n, ih);
  s = hmac_outer;
  sha256_finish(&s, 64, ih, 32, out);
}

static const int8_t B64_TAB[256] = {
  -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
  -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
  -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, 62, -1, -1,
  52, 53, 54, 55, 56, 57, 58, 59, 60, 61, -1, -1, -1, -1, -1, -1,
  -1,  0,  1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11, 12, 13, 14,
  15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, -1, -1, -1, -1, 63,
  -1, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40,
  41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, -1, -1, -1, -1, -1,
  -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
  -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
  -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
  -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
  -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
  -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
  -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
  -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
};

static int b64url_decode(const u8 *s, u32 n, u8 *out, u32 cap) {
  if (n % 4 == 1) return -1;
  u32 o = 0, acc = 0, bits = 0;
  for (u32 i = 0; i < n; i++) {
    int8_t v = B64_TAB[s[i]];
    if (v < 0) return -1;
    acc = acc << 6 | (u32)v;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      if (o >= cap) return -1;
      out[o++] = (u8)(acc >> bits);
    }
  }
  if (bits && (acc & ((1u << bits) - 1))) return -1;
  return (int)o;
}

enum { JWT_OK = 0, JWT_INVALID = 1, JWT_PAYLOAD = 2 };

typedef struct {
  i64 uid;
  u8 name[512]; u32 name_len;
} claims_t;

static int jwt_verify(const u8 *t, u32 n, i64 now, claims_t *c) {
  const u8 *d1 = memchr(t, '.', n);
  if (!d1) return JWT_INVALID;
  const u8 *d2 = memchr(d1 + 1, '.', (size_t)(t + n - d1 - 1));
  if (!d2 || memchr(d2 + 1, '.', (size_t)(t + n - d2 - 1))) return JWT_INVALID;
  u32 hl = (u32)(d1 - t), pl = (u32)(d2 - d1 - 1), sl = (u32)(t + n - d2 - 1);
  if (!hl || !pl || sl != 43 || hl > 512 || pl > 2048) return JWT_INVALID;
  u8 sig[33], mac[32];
  if (b64url_decode(d2 + 1, sl, sig, sizeof sig) != 32) return JWT_INVALID;
  hmac_sha256(t, (size_t)(d2 - t), mac);
  u8 diff = 0;
  for (int i = 0; i < 32; i++) diff |= (u8)(sig[i] ^ mac[i]);
  if (diff) return JWT_INVALID;
  u8 buf[2048];
  int hn = b64url_decode(t, hl, buf, sizeof buf);
  if (hn < 0) return JWT_INVALID;
  jmember hm[1] = {{"alg", 3, 0, 0, 0, 0}};
  if (json_members(buf, (u32)hn, hm, 1) != 0) return JWT_INVALID;
  if (hm[0].type != JT_STRING || hm[0].escaped || hm[0].v_len != 5 || memcmp(hm[0].v, "HS256", 5)) return JWT_INVALID;
  int pn = b64url_decode(d1 + 1, pl, buf, sizeof buf);
  if (pn < 0) return JWT_INVALID;
  jmember pm[3] = {{"exp", 3, 0, 0, 0, 0}, {"sub", 3, 0, 0, 0, 0}, {"username", 8, 0, 0, 0, 0}};
  if (json_members(buf, (u32)pn, pm, 3) != 0) return JWT_INVALID;
  if (pm[0].type != JT_NUMBER) return JWT_INVALID;
  {
    const u8 *p = pm[0].v, *e = p + pm[0].v_len;
    if (*p == '-') return JWT_INVALID;
    i64 v = 0;
    while (p < e && *p >= '0' && *p <= '9') { if (v > (i64)1e15) return JWT_INVALID; v = v * 10 + (*p++ - '0'); }
    int frac = 0;
    if (p < e && *p == '.') { p++; while (p < e && *p >= '0' && *p <= '9') { if (*p != '0') frac = 1; p++; } }
    if (p < e) {
      char tmp[64]; u32 l = pm[0].v_len < 63 ? pm[0].v_len : 63;
      memcpy(tmp, pm[0].v, l); tmp[l] = 0;
      double dv = strtod(tmp, 0);
      if (!(dv > (double)now)) return JWT_INVALID;
    } else if (!(v > now || (v == now && frac))) return JWT_INVALID;
  }
  if (pm[1].type != JT_STRING || pm[1].escaped || pm[1].v_len == 0 || pm[1].v_len > 15) return JWT_PAYLOAD;
  i64 uid = 0;
  for (u32 i = 0; i < pm[1].v_len; i++) {
    u8 ch = pm[1].v[i];
    if (ch < '0' || ch > '9') return JWT_PAYLOAD;
    uid = uid * 10 + (ch - '0');
  }
  if (uid <= 0) return JWT_PAYLOAD;
  if (pm[2].type != JT_STRING || pm[2].v_len > sizeof c->name) return JWT_PAYLOAD;
  c->uid = uid;
  if (pm[2].escaped) c->name_len = json_unescape(pm[2].v, pm[2].v_len, c->name);
  else { memcpy(c->name, pm[2].v, pm[2].v_len); c->name_len = pm[2].v_len; }
  return JWT_OK;
}
