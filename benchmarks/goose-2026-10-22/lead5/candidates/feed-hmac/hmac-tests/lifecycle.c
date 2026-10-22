#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <openssl/evp.h>
#include <openssl/hmac.h>

int test_auth(const uint8_t *, int64_t, const uint8_t *, int64_t,
              uint8_t *, int64_t *, uint8_t *, int64_t *);
void test_fail(unsigned);
void test_forget(void);
int test_has_key(void);

static void encode(const uint8_t *input, int length, uint8_t *output) {
    int count = EVP_EncodeBlock(output, input, length);
    while (count && output[count-1] == '=') --count;
    for (int i = 0; i < count; ++i) {
        if (output[i] == '+') output[i] = '-';
        if (output[i] == '/') output[i] = '_';
    }
    output[count] = 0;
}

int main(void) {
    static const uint8_t message[] = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0";
    uint8_t keys[4][65] = {{0}, {1}, {2}, {3}};
    int lengths[] = {0, 1, 64, 65};
    uint8_t token[256], digest[32], header[16384], payload[16384];
    for (int round = 0; round < 10000; ++round) {
        int index = (round / 3) % 4;
        unsigned size = 0;
        assert(HMAC(EVP_sha256(), keys[index], lengths[index], message,
                    sizeof(message)-1, digest, &size) && size == 32);
        memcpy(token, message, sizeof(message)-1);
        token[sizeof(message)-1] = '.';
        encode(digest, 32, token + sizeof(message));
        int64_t nh = 0, np = 0;
        int64_t length = (int64_t)strlen((const char *)token);
        assert(test_auth(token, length, keys[index], lengths[index], header, &nh, payload, &np) == 1);
        assert(nh == 15 && memcmp(header, "{\"alg\":\"HS256\"}", 15) == 0);
        assert(np == 11 && memcmp(payload, "{\"sub\":\"1\"}", 11) == 0);
        token[length-2] = token[length-2] == 'A' ? 'B' : 'A';
        assert(test_auth(token, length, keys[index], lengths[index], header, &nh, payload, &np) == 0);
        if (round % 7 == 0) test_forget();
    }
    test_forget();
    assert(!test_has_key());
    /* Leave a live key for the real atexit handler; ASAN leak detection runs
       after that cleanup, covering exit ordering as well as explicit resets. */
    unsigned size = 0;
    assert(HMAC(EVP_sha256(), keys[3], lengths[3], message,
                sizeof(message)-1, digest, &size) && size == 32);
    encode(digest, 32, token + sizeof(message));
    int64_t nh = 0, np = 0;
    assert(test_auth(token, (int64_t)strlen((const char *)token), keys[3], lengths[3],
                     header, &nh, payload, &np) == 1);
    assert(test_has_key());
    puts("PASS: 10000 valid + 10000 invalid signature checks; key replacement/reset and cleanup; ASAN/UBSAN/leak detection");
    return 0;
}
