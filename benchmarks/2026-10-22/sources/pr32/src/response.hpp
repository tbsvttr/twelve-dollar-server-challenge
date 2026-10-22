#pragma once

#include <EASTL/string_view.h>

#include <cstddef>

namespace srv {

constexpr size_t kMaxHeadBytes = 320;

size_t build_head(char *out, int status, bool keep_alive, size_t body_size, eastl::string_view date);

}
