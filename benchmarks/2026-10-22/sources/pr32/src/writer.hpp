#pragma once

#include <EASTL/string_view.h>

#include "simd.hpp"

#include <charconv>
#include <cstddef>
#include <cstdint>
#include <cstring>

namespace srv {

class Writer {
public:
    Writer(char *buf, size_t cap) : buf_(buf), cap_(cap) {}

    void clear() {
        len_ = 0;
        overflow_ = false;
    }

    bool overflowed() const { return overflow_; }
    size_t size() const { return len_; }
    const char *data() const { return buf_; }
    eastl::string_view view() const { return {buf_, len_}; }

    void put(char c) {
        if (len_ < cap_) {
            buf_[len_++] = c;
        } else {
            overflow_ = true;
        }
    }

    void put(eastl::string_view s) {
        if (!reserve(s.size())) return;
        memcpy(buf_ + len_, s.data(), s.size());
        len_ += s.size();
    }

    void put_int(int64_t v) {
        if (!reserve(24)) return;
        len_ = static_cast<size_t>(std::to_chars(buf_ + len_, buf_ + len_ + 24, v).ptr - buf_);
    }

    void put_json_string(eastl::string_view s) {
        if (!reserve(s.size() * 6 + 2)) return;
        char *o = buf_ + len_;
        *o++ = '"';
        const char *p = s.data();
        const char *e = p + s.size();
        while (p < e) {
            if (e - p >= static_cast<ptrdiff_t>(simd::kWidth)) {
                simd::Mask mask = simd::escape(p);
                memcpy(o, p, simd::kWidth);
                size_t k = mask ? simd::first(mask) : simd::kWidth;
                o += k;
                p += k;
                if (!mask) continue;
            }
            unsigned char c = static_cast<unsigned char>(*p);
            if (c >= 0x20 && c != '"' && c != '\\') {
                *o++ = *p++;
                continue;
            }
            ++p;
            *o++ = '\\';
            switch (c) {
                case '"':
                    *o++ = '"';
                    break;
                case '\\':
                    *o++ = '\\';
                    break;
                case '\b':
                    *o++ = 'b';
                    break;
                case '\f':
                    *o++ = 'f';
                    break;
                case '\n':
                    *o++ = 'n';
                    break;
                case '\r':
                    *o++ = 'r';
                    break;
                case '\t':
                    *o++ = 't';
                    break;
                default:
                    *o++ = 'u';
                    *o++ = '0';
                    *o++ = '0';
                    *o++ = "0123456789abcdef"[c >> 4];
                    *o++ = "0123456789abcdef"[c & 15];
                    break;
            }
        }
        *o++ = '"';
        len_ = static_cast<size_t>(o - buf_);
    }

private:
    bool reserve(size_t n) {
        if (cap_ - len_ < n) {
            overflow_ = true;
            return false;
        }
        return true;
    }

    char *buf_;
    size_t cap_;
    size_t len_ = 0;
    bool overflow_ = false;
};

}
