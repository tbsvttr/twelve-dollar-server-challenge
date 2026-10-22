#pragma once

#include <EASTL/string_view.h>

#include <cstddef>
#include <cstdint>

namespace srv {

struct JsonValue {
    const char *p = nullptr;
    uint32_t n = 0;
    char kind = 0;
    bool escaped = false;

    eastl::string_view raw() const { return {p, n}; }
};

struct JsonFields {
    JsonValue sub, username, exp, body, alg;
    bool top_is_object = false;
};

bool valid_utf8(const char *p, size_t n);

bool scan_json(eastl::string_view text, JsonFields &out);

size_t json_unescape(const char *p, size_t n, char *out);

}
