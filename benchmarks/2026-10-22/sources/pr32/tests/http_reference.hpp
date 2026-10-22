#pragma once

#include <algorithm>
#include <cstring>

#include "http.hpp"

namespace srv::reference {

namespace {

using View = eastl::string_view;

inline char lower_ascii(char c) { return c >= 'A' && c <= 'Z' ? static_cast<char>(c + 32) : c; }

inline bool equals_ignore_case(View a, View lower) {
    if (a.size() != lower.size()) return false;
    for (size_t i = 0; i < a.size(); ++i) {
        if (lower_ascii(a[i]) != lower[i]) return false;
    }
    return true;
}

inline bool contains_token(View value, View lower) {
    for (size_t i = 0; i + lower.size() <= value.size(); ++i) {
        if (equals_ignore_case(value.substr(i, lower.size()), lower)) return true;
    }
    return false;
}

inline View trim(View v) {
    while (!v.empty() && (v.front() == ' ' || v.front() == '\t')) v.remove_prefix(1);
    while (!v.empty() && (v.back() == ' ' || v.back() == '\t')) v.remove_suffix(1);
    return v;
}

inline const char *find_crlf(const char *p, const char *e) {
    while (p + 1 < e) {
        const void *hit = memchr(p, '\r', static_cast<size_t>(e - p - 1));
        if (!hit) return nullptr;
        p = static_cast<const char *>(hit);
        if (p[1] == '\n') return p;
        ++p;
    }
    return nullptr;
}

inline bool parse_length(View v, size_t &out) {
    if (v.empty() || v.size() > 9) return false;
    size_t n = 0;
    for (char c : v) {
        if (c < '0' || c > '9') return false;
        n = n * 10 + static_cast<size_t>(c - '0');
    }
    out = n;
    return true;
}

}

inline ParseStatus parse_request(const char *data, size_t n, Request &req) {
    req = Request{};
    size_t window = std::min(n, kMaxHeaderBytes + 4);
    const char *terminator = static_cast<const char *>(memmem(data, window, "\r\n\r\n", 4));
    if (!terminator) return n > kMaxHeaderBytes ? ParseStatus::Bad : ParseStatus::Incomplete;

    const char *head_end = terminator;
    const char *line_end = find_crlf(data, head_end + 2);
    if (!line_end || line_end > head_end) line_end = head_end;

    View line(data, static_cast<size_t>(line_end - data));
    size_t sp1 = line.find(' ');
    if (sp1 == View::npos || sp1 == 0) return ParseStatus::Bad;
    size_t sp2 = line.find(' ', sp1 + 1);
    if (sp2 == View::npos || sp2 == sp1 + 1) return ParseStatus::Bad;
    View method = line.substr(0, sp1);
    View target = line.substr(sp1 + 1, sp2 - sp1 - 1);
    View version = line.substr(sp2 + 1);
    if (target.front() != '/') return ParseStatus::Bad;
    if (version == View("HTTP/1.1")) {
        req.keep_alive = true;
    } else if (version == View("HTTP/1.0")) {
        req.keep_alive = false;
    } else {
        return ParseStatus::Bad;
    }
    req.method = method == View("GET") ? Method::Get : method == View("POST") ? Method::Post : Method::Other;
    size_t query = target.find('?');
    req.path = query == View::npos ? target : target.substr(0, query);

    size_t content_length = 0;
    bool have_length = false;
    const char *p = line_end;
    while (p < head_end) {
        p += 2;
        if (p > head_end) break;
        const char *next = find_crlf(p, head_end + 2);
        if (!next || next > head_end) next = head_end;
        View header(p, static_cast<size_t>(next - p));
        p = next;
        if (header.empty()) continue;
        size_t colon = header.find(':');
        if (colon == View::npos || colon == 0) return ParseStatus::Bad;
        View name = header.substr(0, colon);
        View value = trim(header.substr(colon + 1));
        switch (name.size()) {
            case 10:
                if (equals_ignore_case(name, "connection")) {
                    if (contains_token(value, "close")) {
                        req.keep_alive = false;
                    } else if (contains_token(value, "keep-alive")) {
                        req.keep_alive = true;
                    }
                }
                break;
            case 13:
                if (equals_ignore_case(name, "authorization")) req.authorization = value;
                break;
            case 14:
                if (equals_ignore_case(name, "content-length")) {
                    size_t parsed = 0;
                    if (!parse_length(value, parsed)) return ParseStatus::Bad;
                    if (have_length && parsed != content_length) return ParseStatus::Bad;
                    content_length = parsed;
                    have_length = true;
                }
                break;
            case 17:
                if (equals_ignore_case(name, "transfer-encoding")) return ParseStatus::Bad;
                break;
            default:
                break;
        }
    }

    if (content_length > kMaxBodyBytes) return ParseStatus::Bad;
    size_t head_bytes = static_cast<size_t>(head_end - data) + 4;
    size_t total = head_bytes + content_length;
    if (n < total) return ParseStatus::Incomplete;
    req.body = View(data + head_bytes, content_length);
    req.consumed = total;
    return ParseStatus::Ok;
}

}
