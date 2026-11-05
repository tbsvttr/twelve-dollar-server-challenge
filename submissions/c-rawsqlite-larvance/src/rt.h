#ifndef RT_H
#define RT_H

#include <stdint.h>
#include <stddef.h>
#include <string.h>

#ifndef SQLITE_AMALGAMATION
typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef unsigned long long u64;
typedef long long i64;
#endif

#define LIKELY(x) __builtin_expect(!!(x), 1)
#define UNLIKELY(x) __builtin_expect(!!(x), 0)

extern i64 now_s;

enum { M_OTHER = 0, M_GET = 1, M_POST = 2 };

typedef struct {
  u8 method;
  u8 close;
  u8 has_auth;
  const u8 *path; u32 path_len;
  const u8 *auth; u32 auth_len;
  const u8 *body; u32 body_len;
} req_t;

#define HDR_ROOM 96

typedef struct obuf {
  struct obuf *next;
  const u8 *data;
  u32 len;
  u32 cap;
  u8 *mem;
} obuf;

typedef struct {
  u8 *p, *end;
  u8 *start;
  obuf *b;
} out_t;

typedef struct job {
  u8 kind;
  u8 is_write;
  u8 close_after;
  u32 conn;
  u32 gen;
  i64 id;
  i64 uid;
  const u8 *name; u32 name_len;
  u8 *text; u32 text_len;
  obuf *resp;
} job_t;

#endif
