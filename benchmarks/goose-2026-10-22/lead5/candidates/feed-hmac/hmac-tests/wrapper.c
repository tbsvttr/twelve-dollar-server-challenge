#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <openssl/crypto.h>
#include <openssl/evp.h>
#include <openssl/params.h>

#ifdef TEST_REUSE
static unsigned fault_mask;
static int fault(unsigned bit) {
    int result = (fault_mask & bit) != 0;
    fault_mask &= ~bit;
    return result;
}
static EVP_MAC *checked_fetch(OSSL_LIB_CTX *libctx, const char *name, const char *props) {
    return fault(1) ? NULL : EVP_MAC_fetch(libctx, name, props);
}
static EVP_MAC_CTX *checked_new(EVP_MAC *algorithm) {
    return fault(2) ? NULL : EVP_MAC_CTX_new(algorithm);
}
static void *checked_malloc(size_t size) {
    return fault(4) ? NULL : CRYPTO_malloc(size, __FILE__, __LINE__);
}
static int checked_init(EVP_MAC_CTX *ctx, const unsigned char *key, size_t length, const OSSL_PARAM *params) {
    return fault(8) ? 0 : EVP_MAC_init(ctx, key, length, params);
}
static int checked_update(EVP_MAC_CTX *ctx, const unsigned char *data, size_t length) {
    return fault(16) ? 0 : EVP_MAC_update(ctx, data, length);
}
static int checked_final(EVP_MAC_CTX *ctx, unsigned char *out, size_t *length, size_t capacity) {
    return fault(32) ? 0 : EVP_MAC_final(ctx, out, length, capacity);
}
static int checked_atexit(void (*cleanup)(void)) {
    return fault(64) ? 1 : atexit(cleanup);
}
#define EVP_MAC_fetch checked_fetch
#define EVP_MAC_CTX_new checked_new
#undef OPENSSL_malloc
#define OPENSSL_malloc checked_malloc
#define EVP_MAC_init checked_init
#define EVP_MAC_update checked_update
#define EVP_MAC_final checked_final
#define atexit checked_atexit
#endif

#include DB_SOURCE

__attribute__((visibility("default")))
int test_auth(const uint8_t *token, int64_t token_length,
              const uint8_t *key, int64_t key_length,
              uint8_t *header, int64_t *header_length,
              uint8_t *payload, int64_t *payload_length) {
    crypto_test_builder h = {0}, p = {0};
    int result = auth_decode((bytes){token, token_length}, (bytes){key, key_length}, &h, &p);
    memcpy(header, h.data, (size_t)h.len); *header_length = h.len;
    memcpy(payload, p.data, (size_t)p.len); *payload_length = p.len;
    return result;
}

#ifdef TEST_REUSE
__attribute__((visibility("default")))
void test_fail(unsigned bits) { fault_mask = bits; }
__attribute__((visibility("default")))
void test_forget(void) { auth_hmac_cleanup(); }
__attribute__((visibility("default")))
int test_has_key(void) { return auth_hmac.context != NULL; }
#endif
