#pragma once

#include <EASTL/intrusive_list.h>

#include <cstdint>

namespace srv {

struct Conn : eastl::intrusive_list_node {
    uint32_t last_active = 0;
    uint32_t in_len = 0;
    uint32_t out_off = 0;
    uint32_t out_len = 0;
    uint32_t gen = 0;
    char *in_block = nullptr;
    char *out_block = nullptr;
    bool open = false;
    bool writing = false;
    bool close_after_flush = false;
    bool served = false;
};

}
