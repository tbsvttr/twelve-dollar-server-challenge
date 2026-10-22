#ifndef GOOSE_NET_H
#define GOOSE_NET_H

#include <stdint.h>
#include "goose.h"

/* Goose's u8[:] ABI: borrowed data followed by its signed length. */
#pragma pack(push, 1)
typedef struct { const uint8_t *data; int64_t len; } bytes;
#pragma pack(pop)

int64_t net_init(bytes host, int64_t port);
int64_t net_poll(int64_t handle);
void net_dispatch_batch(int64_t handle);
void net_method(int64_t handle, int64_t index, gs_rref out);
void net_path(int64_t handle, int64_t index, gs_rref out);
void net_auth(int64_t handle, int64_t index, gs_rref out);
void net_body(int64_t handle, int64_t index, gs_rref out);
void net_reply(int64_t handle, int64_t index, int32_t status, bytes body);
void net_flush(int64_t handle, int32_t commit_ok);
void net_close(int64_t handle);

#endif
