#include "json.hpp"

#include "simd.hpp"

#include <cstring>

namespace srv {

namespace {

constexpr int kMaxDepth = 64;

bool is_hex(char c) { return (c >= '0' && c <= '9') || ((c | 32) >= 'a' && (c | 32) <= 'f'); }

int hex_value(char c) { return c <= '9' ? c - '0' : (c | 32) - 'a' + 10; }

bool ascii_only(const char *p, size_t n) {
    const char *e = p + n;
    while (e - p >= static_cast<ptrdiff_t>(simd::kWidth)) {
        if (simd::any_high(p)) return false;
        p += simd::kWidth;
    }
    while (p < e) {
        if (static_cast<unsigned char>(*p++) >= 0x80) return false;
    }
    return true;
}

struct Scanner {
    const char *p;
    const char *e;
    JsonFields *f;

    void ws() {
        while (p < e && (*p == ' ' || *p == '\n' || *p == '\r' || *p == '\t')) ++p;
    }

    bool string(JsonValue *out) {
        ++p;
        const char *start = p;
        bool escaped = false;
        for (;;) {
            for (;;) {
                if (e - p >= static_cast<ptrdiff_t>(simd::kWidth)) {
                    if (simd::Mask mask = simd::escape(p)) {
                        p += simd::first(mask);
                        break;
                    }
                    p += simd::kWidth;
                    continue;
                }
                if (p >= e) return false;
                unsigned char c = static_cast<unsigned char>(*p);
                if (c == '"' || c == '\\' || c < 0x20) break;
                ++p;
            }
            unsigned char c = static_cast<unsigned char>(*p);
            if (c == '"') {
                if (out) {
                    out->p = start;
                    out->n = static_cast<uint32_t>(p - start);
                    out->kind = 's';
                    out->escaped = escaped;
                }
                ++p;
                return true;
            }
            if (c != '\\') return false;
            escaped = true;
            ++p;
            if (p >= e) return false;
            switch (*p) {
                case '"':
                case '\\':
                case '/':
                case 'b':
                case 'f':
                case 'n':
                case 'r':
                case 't':
                    ++p;
                    break;
                case 'u':
                    ++p;
                    if (e - p < 4) return false;
                    for (int i = 0; i < 4; i++) {
                        if (!is_hex(p[i])) return false;
                    }
                    p += 4;
                    break;
                default:
                    return false;
            }
        }
    }

    bool digits() {
        const char *s = p;
        while (p < e && *p >= '0' && *p <= '9') ++p;
        return p > s;
    }

    bool number(JsonValue *out) {
        const char *start = p;
        if (p < e && *p == '-') ++p;
        if (p >= e) return false;
        if (*p == '0') {
            ++p;
        } else if (*p >= '1' && *p <= '9') {
            digits();
        } else {
            return false;
        }
        if (p < e && *p == '.') {
            ++p;
            if (!digits()) return false;
        }
        if (p < e && (*p == 'e' || *p == 'E')) {
            ++p;
            if (p < e && (*p == '+' || *p == '-')) ++p;
            if (!digits()) return false;
        }
        if (out) {
            out->p = start;
            out->n = static_cast<uint32_t>(p - start);
            out->kind = 'n';
            out->escaped = false;
        }
        return true;
    }

    bool literal(const char *word, size_t n) {
        if (static_cast<size_t>(e - p) < n || memcmp(p, word, n) != 0) return false;
        p += n;
        return true;
    }

    bool value(int depth, JsonValue *out) {
        if (p >= e || depth > kMaxDepth) return false;
        switch (*p) {
            case '"':
                return string(out);
            case '{':
                if (out) out->kind = 'o';
                return object(depth + 1, false);
            case '[':
                if (out) out->kind = 'o';
                return array(depth + 1);
            case 't':
                if (out) out->kind = 'o';
                return literal("true", 4);
            case 'f':
                if (out) out->kind = 'o';
                return literal("false", 5);
            case 'n':
                if (out) out->kind = 'o';
                return literal("null", 4);
            default:
                return number(out);
        }
    }

    bool array(int depth) {
        ++p;
        ws();
        if (p < e && *p == ']') {
            ++p;
            return true;
        }
        for (;;) {
            ws();
            if (!value(depth, nullptr)) return false;
            ws();
            if (p >= e) return false;
            if (*p == ',') {
                ++p;
                continue;
            }
            if (*p == ']') {
                ++p;
                return true;
            }
            return false;
        }
    }

    JsonValue *slot_for(const JsonValue &key) {
        if (key.escaped) return nullptr;
        if (key.n == 3 && memcmp(key.p, "sub", 3) == 0) return &f->sub;
        if (key.n == 8 && memcmp(key.p, "username", 8) == 0) return &f->username;
        if (key.n == 3 && memcmp(key.p, "exp", 3) == 0) return &f->exp;
        if (key.n == 4 && memcmp(key.p, "body", 4) == 0) return &f->body;
        if (key.n == 3 && memcmp(key.p, "alg", 3) == 0) return &f->alg;
        return nullptr;
    }

    bool object(int depth, bool top) {
        ++p;
        ws();
        if (p < e && *p == '}') {
            ++p;
            return true;
        }
        for (;;) {
            ws();
            if (p >= e || *p != '"') return false;
            JsonValue key;
            if (!string(&key)) return false;
            ws();
            if (p >= e || *p != ':') return false;
            ++p;
            ws();
            JsonValue *slot = top ? slot_for(key) : nullptr;
            if (slot) *slot = JsonValue{};
            if (!value(depth, slot)) return false;
            ws();
            if (p >= e) return false;
            if (*p == ',') {
                ++p;
                continue;
            }
            if (*p == '}') {
                ++p;
                return true;
            }
            return false;
        }
    }

    bool run() {
        ws();
        if (p >= e) return false;
        if (*p == '{') {
            f->top_is_object = true;
            if (!object(1, true)) return false;
        } else if (!value(1, nullptr)) {
            return false;
        }
        ws();
        return p == e;
    }
};

}

bool valid_utf8(const char *s, size_t n) {
    const unsigned char *p = reinterpret_cast<const unsigned char *>(s);
    const unsigned char *e = p + n;
    while (p < e) {
        if (e - p >= static_cast<ptrdiff_t>(simd::kWidth) && !simd::any_high(reinterpret_cast<const char *>(p))) {
            p += simd::kWidth;
            continue;
        }
        unsigned char c = *p;
        if (c < 0x80) {
            ++p;
            continue;
        }
        size_t len;
        uint32_t cp;
        if (c >= 0xC2 && c <= 0xDF) {
            len = 2;
            cp = c & 0x1F;
        } else if (c >= 0xE0 && c <= 0xEF) {
            len = 3;
            cp = c & 0x0F;
        } else if (c >= 0xF0 && c <= 0xF4) {
            len = 4;
            cp = c & 0x07;
        } else {
            return false;
        }
        if (static_cast<size_t>(e - p) < len) return false;
        for (size_t i = 1; i < len; i++) {
            if ((p[i] & 0xC0) != 0x80) return false;
            cp = (cp << 6) | (p[i] & 0x3F);
        }
        if (len == 3 && (cp < 0x800 || (cp >= 0xD800 && cp <= 0xDFFF))) return false;
        if (len == 4 && (cp < 0x10000 || cp > 0x10FFFF)) return false;
        p += len;
    }
    return true;
}

bool scan_json(eastl::string_view text, JsonFields &out) {
    out = JsonFields{};
    Scanner scanner{text.data(), text.data() + text.size(), &out};
    if (!scanner.run()) return false;
    return ascii_only(text.data(), text.size()) || valid_utf8(text.data(), text.size());
}

size_t json_unescape(const char *p, size_t n, char *out) {
    char *o = out;
    const char *e = p + n;
    auto put = [&o](uint32_t c) {
        if (c < 0x80) {
            *o++ = static_cast<char>(c);
        } else if (c < 0x800) {
            *o++ = static_cast<char>(0xC0 | (c >> 6));
            *o++ = static_cast<char>(0x80 | (c & 63));
        } else if (c < 0x10000) {
            *o++ = static_cast<char>(0xE0 | (c >> 12));
            *o++ = static_cast<char>(0x80 | ((c >> 6) & 63));
            *o++ = static_cast<char>(0x80 | (c & 63));
        } else {
            *o++ = static_cast<char>(0xF0 | (c >> 18));
            *o++ = static_cast<char>(0x80 | ((c >> 12) & 63));
            *o++ = static_cast<char>(0x80 | ((c >> 6) & 63));
            *o++ = static_cast<char>(0x80 | (c & 63));
        }
    };
    auto read_u = [](const char *q) {
        return static_cast<uint32_t>(hex_value(q[0]) << 12 | hex_value(q[1]) << 8 | hex_value(q[2]) << 4 | hex_value(q[3]));
    };
    while (p < e) {
        if (*p != '\\') {
            const char *run = p;
            while (p < e && *p != '\\') ++p;
            memcpy(o, run, static_cast<size_t>(p - run));
            o += p - run;
            continue;
        }
        ++p;
        switch (*p) {
            case 'b':
                *o++ = '\b';
                ++p;
                break;
            case 'f':
                *o++ = '\f';
                ++p;
                break;
            case 'n':
                *o++ = '\n';
                ++p;
                break;
            case 'r':
                *o++ = '\r';
                ++p;
                break;
            case 't':
                *o++ = '\t';
                ++p;
                break;
            case 'u': {
                uint32_t c = read_u(p + 1);
                p += 5;
                if (c >= 0xD800 && c <= 0xDBFF) {
                    if (e - p >= 6 && p[0] == '\\' && p[1] == 'u') {
                        uint32_t d = read_u(p + 2);
                        if (d >= 0xDC00 && d <= 0xDFFF) {
                            p += 6;
                            c = 0x10000 + ((c - 0xD800) << 10) + (d - 0xDC00);
                        } else {
                            c = 0xFFFD;
                        }
                    } else {
                        c = 0xFFFD;
                    }
                } else if (c >= 0xDC00 && c <= 0xDFFF) {
                    c = 0xFFFD;
                }
                put(c);
                break;
            }
            default:
                *o++ = *p++;
                break;
        }
    }
    return static_cast<size_t>(o - out);
}

}
