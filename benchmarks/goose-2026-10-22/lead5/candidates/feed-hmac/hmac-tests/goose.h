#ifndef CRYPTO_TEST_GOOSE_H
#define CRYPTO_TEST_GOOSE_H
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
/* This test isolates db.c crypto; full API tests use the real Goose runtime. */
typedef struct { uint8_t data[16384]; int64_t len; } crypto_test_builder;
typedef crypto_test_builder *gs_rref;
static inline void gs_bld_append(gs_rref out, const void *data, int64_t len) {
    if (len < 0 || out->len + len > (int64_t)sizeof(out->data)) abort();
    memcpy(out->data + out->len, data, (size_t)len);
    out->len += len;
}
#endif
