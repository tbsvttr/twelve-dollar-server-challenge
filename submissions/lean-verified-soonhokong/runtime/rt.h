/* Shared definitions for the C runtime. The runtime is one translation unit (server.c) that
 * includes the SQLite amalgamation, so the storage primitives can call SQLite's B-tree layer. */
#pragma once
#include <lean/lean.h>
#include <stdint.h>
#include <string.h>

typedef uint8_t u8_t;
typedef uint16_t u16_t;
typedef uint32_t u32_t;
typedef uint64_t u64_t;
typedef int64_t i64_t;
typedef int32_t i32_t;

#define LIKELY(x) __builtin_expect(!!(x), 1)
#define UNLIKELY(x) __builtin_expect(!!(x), 0)

/* A Lean Nat argument as a C integer. Values that are not small (never produced by the
 * application, which only handles ids below 2^63) map to UINT64_MAX. */
static inline u64_t nat_u64(b_lean_obj_arg n) { return lean_is_scalar(n) ? (u64_t)lean_unbox(n) : UINT64_MAX; }
static inline lean_obj_res u64_nat(u64_t v) { return v <= LEAN_MAX_SMALL_NAT ? lean_box((size_t)v) : lean_uint64_to_nat(v); }

/* A ByteArray with room for at least `extra` more bytes (exclusive, so it can be written in place). */
static inline lean_obj_res ba_reserve(lean_obj_arg a, size_t extra) {
  size_t sz = lean_sarray_size(a);
  if (LIKELY(lean_is_exclusive(a) && lean_sarray_capacity(a) >= sz + extra)) return a;
  size_t cap = sz + extra;
  if (cap < 2 * lean_sarray_capacity(a)) cap = 2 * lean_sarray_capacity(a);
  if (cap < 64) cap = 64;
  lean_object *r = lean_alloc_sarray(1, sz, cap);
  memcpy(lean_sarray_cptr(r), lean_sarray_cptr(a), sz);
  lean_dec(a);
  return r;
}
/* Copy n bytes with a few overlapping word moves when n is small (no call into libc). */
static inline void copy_small(u8_t *d, const u8_t *s, size_t n) {
  if (n <= 16) {
    if (n >= 8) { u64_t a, b; memcpy(&a, s, 8); memcpy(&b, s + n - 8, 8); memcpy(d, &a, 8); memcpy(d + n - 8, &b, 8); }
    else if (n >= 4) { u32_t a, b; memcpy(&a, s, 4); memcpy(&b, s + n - 4, 4); memcpy(d, &a, 4); memcpy(d + n - 4, &b, 4); }
    else if (n) { d[0] = s[0]; d[n / 2] = s[n / 2]; d[n - 1] = s[n - 1]; }
  } else if (n <= 32) {
    u64_t a[2], b[2];
    memcpy(a, s, 16); memcpy(b, s + n - 16, 16); memcpy(d, a, 16); memcpy(d + n - 16, b, 16);
  } else memcpy(d, s, n);
}
static inline u8_t *ba_end(lean_object *a) { return lean_sarray_cptr(a) + lean_sarray_size(a); }
static inline void ba_grow(lean_object *a, size_t n) { lean_to_sarray(a)->m_size += n; }
