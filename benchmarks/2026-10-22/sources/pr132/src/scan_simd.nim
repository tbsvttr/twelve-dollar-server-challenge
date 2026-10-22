## Architecture-selected 16-byte scanners for the two hot byte checks.
##
## x86_64 uses SSE2, ARM64 uses NEON, and every other target uses a scalar
## reference implementation. Selection happens at compile time: the x86 build
## never sees NEON/scalar code, and the ARM build never sees SSE2.
##
## The mask representation is intentionally architecture-specific:
##   * x86/scalar: one dense bit per byte, bit k == byte k.
##   * ARM64: four bits per byte (`vshrn` nibble mask); the low nibble belongs
##     to the even byte and the high nibble to the odd byte.
## `firstHit` hides that difference. Callers only check `mask != 0` and ask for
## the first matching byte.

import std/bitops

# Inline scanner bodies are emitted into the caller's C translation unit, so the
# architecture header must be present there too. Callers expand this template at
# top level; it is compile-time only and has no runtime cost.
template useSimdHeader*() =
  when defined(amd64) or defined(i386):
    {.emit: """
      #include <stdint.h>
      #include <emmintrin.h>
    """.}
  elif defined(arm64):
    {.emit: """
      #include <stdint.h>
      #include <arm_neon.h>
    """.}

useSimdHeader()

when defined(amd64) or defined(i386):
  {.emit: """
    #include <stdint.h>
    #include <emmintrin.h>
  """.}

  proc escapeMask16*(p: pointer): uint64 {.inline.} =
    ## Dense 16-bit mask: bit k is set iff byte k is < 0x20, '"' or '\'.
    var m: uint64
    {.emit: """
      {
        __m128i w = _mm_loadu_si128((const __m128i*)`p`);
        __m128i ctrl = _mm_cmpeq_epi8(_mm_min_epu8(w, _mm_set1_epi8(0x1F)), w);
        __m128i quote = _mm_cmpeq_epi8(w, _mm_set1_epi8(0x22));
        __m128i slash = _mm_cmpeq_epi8(w, _mm_set1_epi8(0x5C));
        `m` = (uint64_t)(unsigned)_mm_movemask_epi8(
            _mm_or_si128(ctrl, _mm_or_si128(quote, slash)));
      }
    """.}
    m

  proc crlf4Mask16*(p: pointer): uint64 {.inline.} =
    ## Dense mask: bit k is set iff bytes k..k+3 are "\r\n\r\n".
    var m: uint64
    {.emit: """
      {
        __m128i w = _mm_loadu_si128((const __m128i*)`p`);
        int cr = _mm_movemask_epi8(_mm_cmpeq_epi8(w, _mm_set1_epi8(0x0D)));
        int lf = _mm_movemask_epi8(_mm_cmpeq_epi8(w, _mm_set1_epi8(0x0A)));
        `m` = (uint64_t)(unsigned)(cr & (lf >> 1) & (cr >> 2) & (lf >> 3));
      }
    """.}
    m

elif defined(arm64):
  {.emit: """
    #include <stdint.h>
    #include <arm_neon.h>
  """.}

  proc escapeMask16*(p: pointer): uint64 {.inline.} =
    ## NEON nibble mask: four bits per matching byte.
    var m: uint64
    {.emit: """
      {
        uint8x16_t w = vld1q_u8((const uint8_t*)`p`);
        uint8x16_t ctrl = vcltq_u8(w, vdupq_n_u8(0x20));
        uint8x16_t quote = vceqq_u8(w, vdupq_n_u8(0x22));
        uint8x16_t slash = vceqq_u8(w, vdupq_n_u8(0x5C));
        uint8x16_t hit = vorrq_u8(vorrq_u8(ctrl, quote), slash);
        uint8x8_t nib = vshrn_n_u16(vreinterpretq_u16_u8(hit), 4);
        `m` = vget_lane_u64(vreinterpret_u64_u8(nib), 0);
      }
    """.}
    m

  proc crlf4Mask16*(p: pointer): uint64 {.inline.} =
    ## NEON nibble mask: four bits per start position of "\r\n\r\n".
    var m: uint64
    {.emit: """
      {
        uint8x16_t w = vld1q_u8((const uint8_t*)`p`);
        uint8x8_t crn = vshrn_n_u16(
            vreinterpretq_u16_u8(vceqq_u8(w, vdupq_n_u8(0x0D))), 4);
        uint8x8_t lfn = vshrn_n_u16(
            vreinterpretq_u16_u8(vceqq_u8(w, vdupq_n_u8(0x0A))), 4);
        uint64_t cr = vget_lane_u64(vreinterpret_u64_u8(crn), 0);
        uint64_t lf = vget_lane_u64(vreinterpret_u64_u8(lfn), 0);
        `m` = cr & (lf >> 4) & (cr >> 8) & (lf >> 12);
      }
    """.}
    m

else:
  proc escapeMask16*(p: pointer): uint64 {.inline.} =
    ## Portable dense mask used as the correctness oracle.
    let q = cast[ptr UncheckedArray[char]](p)
    var m: uint64 = 0
    for i in 0 ..< 16:
      let c = q[i]
      if c.ord < 0x20 or c == '"' or c == '\\':
        m = m or (1'u64 shl i)
    m

  proc crlf4Mask16*(p: pointer): uint64 {.inline.} =
    ## Portable dense mask used as the correctness oracle.
    let q = cast[ptr UncheckedArray[char]](p)
    var m: uint64 = 0
    for k in 0 .. 12:
      if q[k] == '\r' and q[k + 1] == '\n' and
         q[k + 2] == '\r' and q[k + 3] == '\n':
        m = m or (1'u64 shl k)
    m

proc firstHit*(mask: uint64): int {.inline.} =
  ## Index of the first matching byte for the mask format selected above.
  when defined(arm64):
    countTrailingZeroBits(mask) shr 2
  else:
    countTrailingZeroBits(mask)
