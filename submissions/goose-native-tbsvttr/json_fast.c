/* SIMD scanning/escaping of one JSON string. Goose chooses every JSON field,
   object, array and database row; this primitive only quotes arbitrary bytes. */
#include "json_fast.h"

#if defined(__aarch64__)
#include <arm_neon.h>
#elif defined(__SSE2__)
#include <emmintrin.h>
#endif

int64_t json_plain_prefix(bytes text) {
    int64_t i = 0;
#if defined(__aarch64__)
    const uint8x16_t quote = vdupq_n_u8('"');
    const uint8x16_t slash = vdupq_n_u8('\\');
    const uint8x16_t space = vdupq_n_u8(0x20);
    while (text.len - i >= 16) {
        uint8x16_t value = vld1q_u8(text.data + i);
        uint8x16_t special = vorrq_u8(vorrq_u8(vceqq_u8(value, quote),
                                               vceqq_u8(value, slash)),
                                      vcltq_u8(value, space));
        if (vmaxvq_u8(special)) break;
        i += 16;
    }
#elif defined(__SSE2__)
    const __m128i quote = _mm_set1_epi8('"');
    const __m128i slash = _mm_set1_epi8('\\');
    const __m128i control = _mm_set1_epi8(0x1f);
    while (text.len - i >= 16) {
        __m128i value = _mm_loadu_si128((const __m128i *)(text.data + i));
        __m128i special = _mm_or_si128(_mm_or_si128(_mm_cmpeq_epi8(value, quote),
                                                   _mm_cmpeq_epi8(value, slash)),
                                      _mm_cmpeq_epi8(_mm_min_epu8(value, control), value));
        if (_mm_movemask_epi8(special)) break;
        i += 16;
    }
#endif
    while (i < text.len) {
        uint8_t value = text.data[i];
        if (value < 0x20 || value == '"' || value == '\\') break;
        i++;
    }
    return i;
}

void json_append_string(bytes text, gs_rref output) {
    static const char hex[] = "0123456789abcdef";
    gs_bld_append(output, "\"", 1);
    int64_t at = 0;
    while (at < text.len) {
        bytes remaining = {text.data + at, text.len - at};
        int64_t count = json_plain_prefix(remaining);
        if (count) gs_bld_append(output, remaining.data, count);
        at += count;
        if (at == text.len) break;
        uint8_t value = text.data[at++];
        char escape[6] = {'\\', 0, 0, 0, 0, 0};
        int length = 2;
        switch (value) {
            case '"': escape[1] = '"'; break;
            case '\\': escape[1] = '\\'; break;
            case '\n': escape[1] = 'n'; break;
            case '\r': escape[1] = 'r'; break;
            case '\t': escape[1] = 't'; break;
            case '\b': escape[1] = 'b'; break;
            case '\f': escape[1] = 'f'; break;
            default:
                escape[1] = 'u'; escape[2] = '0'; escape[3] = '0';
                escape[4] = hex[value >> 4]; escape[5] = hex[value & 15];
                length = 6;
                break;
        }
        gs_bld_append(output, escape, length);
    }
    gs_bld_append(output, "\"", 1);
}
