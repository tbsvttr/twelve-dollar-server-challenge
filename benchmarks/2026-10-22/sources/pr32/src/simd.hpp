#pragma once

#include <cstddef>
#include <cstdint>

#if defined(SRV_SIMD_SCALAR)
#elif defined(__SSE2__)
#include <emmintrin.h>
#elif defined(__ARM_NEON)
#include <arm_neon.h>
#else
#define SRV_SIMD_SCALAR 1
#endif

// 16-byte block scans. A Mask is nonzero iff some lane matched, and first()
// gives the lowest matching lane. Lanes are 1 bit on SSE2 and scalar, 4 bits
// on NEON (no movemask there; shrn packs each byte compare into a nibble).
namespace srv::simd {

inline constexpr size_t kWidth = 16;
using Mask = uint64_t;

#if defined(SRV_SIMD_SCALAR)

inline constexpr const char *kBackend = "scalar";

inline Mask find(const char *p, char c) {
    Mask m = 0;
    for (size_t i = 0; i < kWidth; ++i) m |= Mask{p[i] == c} << i;
    return m;
}

inline Mask escape(const char *p) {
    Mask m = 0;
    for (size_t i = 0; i < kWidth; ++i) {
        unsigned char c = static_cast<unsigned char>(p[i]);
        m |= Mask{c == '"' || c == '\\' || c < 0x20} << i;
    }
    return m;
}

inline bool any_high(const char *p) {
    unsigned char acc = 0;
    for (size_t i = 0; i < kWidth; ++i) acc |= static_cast<unsigned char>(p[i]);
    return acc >= 0x80;
}

inline size_t first(Mask m) { return static_cast<size_t>(__builtin_ctzll(m)); }

#elif defined(__SSE2__)

inline constexpr const char *kBackend = "sse2";

inline __m128i load(const char *p) { return _mm_loadu_si128(reinterpret_cast<const __m128i *>(p)); }

inline Mask find(const char *p, char c) {
    return static_cast<unsigned>(_mm_movemask_epi8(_mm_cmpeq_epi8(load(p), _mm_set1_epi8(c))));
}

inline Mask escape(const char *p) {
    __m128i v = load(p);
    __m128i quote = _mm_cmpeq_epi8(v, _mm_set1_epi8('"'));
    __m128i slash = _mm_cmpeq_epi8(v, _mm_set1_epi8('\\'));
    __m128i ctrl = _mm_cmpeq_epi8(_mm_min_epu8(v, _mm_set1_epi8(0x1f)), v);
    return static_cast<unsigned>(_mm_movemask_epi8(_mm_or_si128(_mm_or_si128(quote, slash), ctrl)));
}

inline bool any_high(const char *p) { return _mm_movemask_epi8(load(p)) != 0; }

inline size_t first(Mask m) { return static_cast<size_t>(__builtin_ctzll(m)); }

#else

inline constexpr const char *kBackend = "neon";

inline uint8x16_t load(const char *p) { return vld1q_u8(reinterpret_cast<const uint8_t *>(p)); }

inline Mask pack(uint8x16_t lanes) {
    return vget_lane_u64(vreinterpret_u64_u8(vshrn_n_u16(vreinterpretq_u16_u8(lanes), 4)), 0);
}

inline Mask find(const char *p, char c) { return pack(vceqq_u8(load(p), vdupq_n_u8(static_cast<uint8_t>(c)))); }

inline Mask escape(const char *p) {
    uint8x16_t v = load(p);
    uint8x16_t quote = vceqq_u8(v, vdupq_n_u8('"'));
    uint8x16_t slash = vceqq_u8(v, vdupq_n_u8('\\'));
    uint8x16_t ctrl = vcltq_u8(v, vdupq_n_u8(0x20));
    return pack(vorrq_u8(vorrq_u8(quote, slash), ctrl));
}

inline bool any_high(const char *p) { return vmaxvq_u8(load(p)) >= 0x80; }

inline size_t first(Mask m) { return static_cast<size_t>(__builtin_ctzll(m)) >> 2; }

#endif

}
