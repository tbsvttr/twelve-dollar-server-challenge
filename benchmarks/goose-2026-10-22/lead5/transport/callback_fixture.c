#include "net.h"
#include <stdlib.h>
#include <string.h>

static uint8_t large[8000000];
static int commit_ok, stop;
void goose_handle_request(int64_t net, int64_t index, bytes method,
                          bytes path, bytes auth, bytes body) {
    (void)method; (void)auth;
    if (path.len == 5 && !memcmp(path.data, "/fail", 5)) commit_ok = 0;
    if (path.len == 5 && !memcmp(path.data, "/stop", 5)) stop = 1;
    if (path.len == 6 && !memcmp(path.data, "/large", 6))
        net_reply(net, index, 200, (bytes){large, sizeof(large)});
    else net_reply(net, index, 200, body);
}
int main(void) {
    memset(large, 'x', sizeof(large));
    int64_t net = net_init((bytes){(const uint8_t *)"127.0.0.1",9},19099);
    if (!net) return 1;
    for (;;) {
        int64_t n = net_poll(net);
        if (n < 0) return 2;
        commit_ok = 1;
        net_dispatch_batch(net);
        net_flush(net, commit_ok);
        if (stop) { net_close(net); return 0; }
    }
}
