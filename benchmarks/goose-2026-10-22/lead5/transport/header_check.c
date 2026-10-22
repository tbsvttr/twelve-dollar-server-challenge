#include "/src/net.c"

extern int baseline_response(int status, const uint8_t *body, size_t length,
                              int close_after, uint8_t **data, size_t *data_len);
void goose_handle_request(int64_t h, int64_t i, bytes m, bytes p, bytes a, bytes b) {
    (void)h; (void)i; (void)m; (void)p; (void)a; (void)b;
    abort();
}
static unsigned checks;
static void compare(int status, const uint8_t *body, size_t length, int closing) {
    Conn c;
    memset(&c, 0, sizeof(c));
    c.close_after = !!closing;
    uint8_t *old = NULL; size_t old_len = 0;
    int before = baseline_response(status, body, length, closing, &old, &old_len);
    int after = response_set(&c, status, body, length);
    if (before != after || (!before && (old_len != c.tx_len || memcmp(old, c.tx, old_len)))) {
        fprintf(stderr, "Header mismatch: status=%d length=%zu closing=%d\n", status, length, closing);
        abort();
    }
    free(old); free(c.tx); ++checks;
}
int main(void) {
    uint8_t *body = malloc(1000000);
    if (!body) return 1;
    memset(body, 'x', 1000000);
    for (int status = 100; status <= 599; ++status)
        for (int close = 0; close < 2; ++close) {
            compare(status, body, 0, close);
            compare(status, body, 1, close);
        }
    int statuses[] = {INT32_MIN,-1,0,99,200,201,204,304,400,500,599,600,INT32_MAX};
    size_t lengths[] = {9,10,99,100,999,1000,9999,10000,65535,65536,999999,1000000};
    for (unsigned i=0; i<sizeof(statuses)/sizeof(statuses[0]); ++i)
        for (unsigned j=0; j<sizeof(lengths)/sizeof(lengths[0]); ++j)
            for (int close=0; close<2; ++close) compare(statuses[i],body,lengths[j],close);
    for (int close=0; close<2; ++close) {
        compare(200,NULL,SIZE_MAX,close);
        compare(200,NULL,SIZE_MAX-1,close);
        compare(204,NULL,SIZE_MAX,close);
        compare(304,NULL,SIZE_MAX,close);
    }
    free(body);
    printf("PASS: %u exact-byte baseline comparisons, all HTTP statuses, invalid statuses, decimal boundaries, 204/304 suppression and size overflow\n", checks);
    return 0;
}
