/* Compile the frozen pre-change formatter as an independent byte oracle. */
#define net_init baseline_net_init
#define net_poll baseline_net_poll
#define net_dispatch_batch baseline_net_dispatch_batch
#define net_method baseline_net_method
#define net_path baseline_net_path
#define net_auth baseline_net_auth
#define net_body baseline_net_body
#define net_reply baseline_net_reply
#define net_flush baseline_net_flush
#define net_close baseline_net_close
#include "/baseline/net_epoll.inc"

int baseline_response(int status, const uint8_t *body, size_t length,
                      int close_after, uint8_t **data, size_t *data_len) {
    Conn c;
    memset(&c, 0, sizeof(c));
    c.close_after = !!close_after;
    int result = response_set(&c, status, body, length);
    *data = c.tx; *data_len = c.tx_len;
    return result;
}
