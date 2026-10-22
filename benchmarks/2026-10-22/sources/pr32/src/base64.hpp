#pragma once

#include <EASTL/array.h>
#include <EASTL/string_view.h>

#include <cstddef>
#include <cstdint>

namespace srv {

inline constexpr eastl::string_view kBase64UrlAlphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

inline constexpr eastl::array<int8_t, 256> kBase64UrlDecode = [] {
    eastl::array<int8_t, 256> table{};
    for (auto &entry : table) entry = -1;
    for (int i = 0; i < 64; ++i) table[static_cast<unsigned char>(kBase64UrlAlphabet[i])] = static_cast<int8_t>(i);
    return table;
}();

inline bool base64url_decode(eastl::string_view in, char *out, size_t cap, size_t &n) {
    n = 0;
    if (in.size() % 4 == 1) return false;
    if ((in.size() * 3) / 4 > cap) return false;
    uint32_t acc = 0;
    int bits = 0;
    for (char ch : in) {
        int v = kBase64UrlDecode[static_cast<unsigned char>(ch)];
        if (v < 0) return false;
        acc = (acc << 6) | static_cast<uint32_t>(v);
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            out[n++] = static_cast<char>((acc >> bits) & 0xFF);
        }
    }
    return true;
}

inline size_t base64url_encode(const unsigned char *in, size_t n, char *out) {
    size_t o = 0;
    uint32_t acc = 0;
    int bits = 0;
    for (size_t i = 0; i < n; ++i) {
        acc = (acc << 8) | in[i];
        bits += 8;
        while (bits >= 6) {
            bits -= 6;
            out[o++] = kBase64UrlAlphabet[(acc >> bits) & 63];
        }
    }
    if (bits > 0) out[o++] = kBase64UrlAlphabet[(acc << (6 - bits)) & 63];
    return o;
}

}
