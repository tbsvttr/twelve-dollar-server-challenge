#include "response.hpp"

#include <charconv>
#include <cstring>

namespace srv {

namespace {

struct StatusInfo {
    int code;
    eastl::string_view head;
};

constexpr StatusInfo kStatuses[] = {
    {200, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"},
    {201, "HTTP/1.1 201 Created\r\nContent-Type: application/json\r\n"},
    {400, "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\n"},
    {401, "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\n"},
    {404, "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\n"},
    {503, "HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\n"},
    {500, "HTTP/1.1 500 Internal Server Error\r\nContent-Type: application/json\r\n"},
};

eastl::string_view status_head(int code) {
    for (const StatusInfo &s : kStatuses) {
        if (s.code == code) return s.head;
    }
    return kStatuses[sizeof kStatuses / sizeof kStatuses[0] - 1].head;
}

}

size_t build_head(char *out, int status, bool keep_alive, size_t body_size, eastl::string_view date) {
    size_t h = 0;
    eastl::string_view line = status_head(status);
    memcpy(out, line.data(), line.size());
    h += line.size();
    memcpy(out + h, date.data(), date.size());
    h += date.size();
    if (!keep_alive) {
        constexpr eastl::string_view kClose = "Connection: close\r\n";
        memcpy(out + h, kClose.data(), kClose.size());
        h += kClose.size();
    }
    constexpr eastl::string_view kLength = "Content-Length: ";
    memcpy(out + h, kLength.data(), kLength.size());
    h += kLength.size();
    h = static_cast<size_t>(std::to_chars(out + h, out + kMaxHeadBytes - 4, body_size).ptr - out);
    out[h++] = '\r';
    out[h++] = '\n';
    out[h++] = '\r';
    out[h++] = '\n';
    return h;
}

}
