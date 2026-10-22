#include <gtest/gtest.h>
#include <yyjson.h>

#include <cstdint>
#include <random>
#include <string>
#include <vector>

#include "json.hpp"

using View = eastl::string_view;

namespace {

struct Outcome {
    bool ok = false;
    bool body_is_string = false;
    std::string body;
};

Outcome mine(const std::string &text) {
    Outcome o;
    srv::JsonFields f;
    o.ok = srv::scan_json(View(text.data(), text.size()), f);
    if (o.ok && f.top_is_object && f.body.kind == 's') {
        o.body_is_string = true;
        std::string out(f.body.n + 8, '\0');
        out.resize(f.body.escaped ? srv::json_unescape(f.body.p, f.body.n, out.data()) : (memcpy(out.data(), f.body.p, f.body.n), f.body.n));
        o.body = out;
    }
    return o;
}

Outcome oracle(const std::string &text) {
    Outcome o;
    yyjson_doc *doc = yyjson_read(text.data(), text.size(), 0);
    if (!doc) return o;
    o.ok = true;
    yyjson_val *root = yyjson_doc_get_root(doc);
    if (yyjson_is_obj(root)) {
        yyjson_val *body = yyjson_obj_get(root, "body");
        if (yyjson_is_str(body)) {
            o.body_is_string = true;
            o.body.assign(yyjson_get_str(body), yyjson_get_len(body));
        }
    }
    yyjson_doc_free(doc);
    return o;
}

int max_depth(const std::string &t) {
    int depth = 0, best = 0;
    bool in_string = false;
    for (size_t i = 0; i < t.size(); ++i) {
        char c = t[i];
        if (in_string) {
            if (c == '\\') ++i;
            else if (c == '"') in_string = false;
        } else if (c == '"') in_string = true;
        else if (c == '[' || c == '{') best = std::max(best, ++depth);
        else if (c == ']' || c == '}') --depth;
    }
    return best;
}

bool has_surrogate_escape(const std::string &t) {
    for (size_t i = 0; i + 3 < t.size(); ++i) {
        if (t[i] == '\\' && (t[i + 1] == 'u' || t[i + 1] == 'U') && (t[i + 2] == 'd' || t[i + 2] == 'D')) return true;
    }
    return false;
}

bool has_overflowing_number(const std::string &t) {
    size_t run = 0;
    for (size_t i = 0; i < t.size(); ++i) {
        if (t[i] >= '0' && t[i] <= '9') {
            if (++run > 100) return true;
        } else {
            run = 0;
        }
        if (t[i] == 'e' || t[i] == 'E') {
            size_t j = i + 1;
            if (j < t.size() && (t[j] == '+' || t[j] == '-')) ++j;
            size_t digits = 0;
            while (j < t.size() && t[j] >= '0' && t[j] <= '9') ++j, ++digits;
            if (digits >= 3) return true;
        }
    }
    return false;
}

size_t occurrences(const std::string &t, const std::string &needle) {
    size_t n = 0;
    for (size_t at = t.find(needle); at != std::string::npos; at = t.find(needle, at + 1)) ++n;
    return n;
}

const std::vector<std::string> &seeds() {
    static const std::vector<std::string> list = {
        R"({"alg":"HS256","typ":"JWT"})",
        R"({"sub":"1","username":"golden_ember_1","iat":1791407691,"exp":2106767691})",
        R"j({"body":"golden_ember_1 says hi at 2026-10-10T00:23:45.123Z (VU 1234, iter 5)"})j",
        R"({"body":"quote \" slash \\ nl \n tab \t uni é 中 pair 😀 end"})",
        "{\"body\":\"caf\xC3\xA9 \xE2\x9C\x93 \xF0\x9F\x98\x80\"}",
        R"({"a":[1,2.5,-3e10,true,false,null,{"b":"c"}],"body":"x","n":{"deep":[[],{}]}})",
        R"(  {  "body"  :  "spaced"  ,  "k"  :  [ 1 , 2 ]  }  )",
        R"({"body":"","x":0,"y":-0,"z":1E+5,"w":0.5e-2})",
        R"([1,"two",{"body":"not top"},null])",
        R"("just a string")",
        R"(12345)",
        R"({"body":"a","body":"b"})",
    };
    return list;
}

std::string mutate(std::mt19937_64 &rng, std::string s) {
    static const std::string interesting = "\"\\{}[],:0123456789-+.eE tfnul\x00\x1f\x7f\x80\xc3\xa9\xff\r\n\tu/bcdABCDEF";
    int edits = 1 + static_cast<int>(rng() % 3);
    for (int e = 0; e < edits; ++e) {
        if (s.empty()) break;
        size_t at = rng() % s.size();
        switch (rng() % 7) {
            case 0: s[at] = interesting[rng() % interesting.size()]; break;
            case 1: s.insert(s.begin() + static_cast<long>(at), interesting[rng() % interesting.size()]); break;
            case 2: s.erase(at, 1); break;
            case 3: s.resize(at); break;
            case 4: s.insert(at, s.substr(at, 1 + rng() % 8)); break;
            case 5: std::swap(s[at], s[rng() % s.size()]); break;
            default: s[at] = static_cast<char>(rng()); break;
        }
    }
    return s;
}

}

TEST(JsonFuzz, AgreesWithYyjsonOnMutatedDocuments) {
    std::mt19937_64 rng(0x5eed);
    size_t both_ok = 0, both_bad = 0, skipped = 0;
    for (size_t iter = 0; iter < 400000; ++iter) {
        std::string text = seeds()[rng() % seeds().size()];
        if (iter % 10 != 0) text = mutate(rng, text);
        if (max_depth(text) > 60 || has_surrogate_escape(text) || has_overflowing_number(text) || text.find('\0') != std::string::npos) {
            ++skipped;
            continue;
        }
        Outcome a = mine(text);
        Outcome b = oracle(text);
        ASSERT_EQ(a.ok, b.ok) << "accept/reject disagreement on: " << testing::PrintToString(text);
        (a.ok ? both_ok : both_bad)++;
        if (a.ok && occurrences(text, "\"body\"") <= 1) {
            ASSERT_EQ(a.body_is_string, b.body_is_string) << testing::PrintToString(text);
            ASSERT_EQ(a.body, b.body) << testing::PrintToString(text);
        }
    }
    EXPECT_GT(both_ok, 20000u);
    EXPECT_GT(both_bad, 20000u);
    RecordProperty("accepted", static_cast<int>(both_ok));
    RecordProperty("rejected", static_cast<int>(both_bad));
    RecordProperty("skipped", static_cast<int>(skipped));
}

TEST(JsonFuzz, RandomBytesNeverCrashAndAgree) {
    std::mt19937_64 rng(77);
    for (size_t iter = 0; iter < 200000; ++iter) {
        std::string text(rng() % 64, '\0');
        for (char &c : text) c = static_cast<char>(rng());
        if (text.find('\0') != std::string::npos || has_overflowing_number(text)) continue;
        ASSERT_EQ(mine(text).ok, oracle(text).ok) << testing::PrintToString(text);
    }
}
