#pragma once

#include <EASTL/string_view.h>

#include <cstddef>
#include <cstdint>

namespace srv {

enum class Method : uint8_t { Get, Post, Other };

struct Request {
    Method method = Method::Other;
    eastl::string_view path;
    eastl::string_view authorization;
    eastl::string_view body;
    bool keep_alive = true;
    size_t consumed = 0;
};

enum class ParseStatus { Incomplete, Ok, Bad };

constexpr size_t kMaxHeaderBytes = 16 * 1024;
constexpr size_t kMaxBodyBytes = 32 * 1024;

ParseStatus parse_request(const char *data, size_t n, Request &req);

}
