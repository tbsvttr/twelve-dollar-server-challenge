#include <gtest/gtest.h>

#include <random>
#include <string>
#include <vector>

#include "http.hpp"
#include "http_reference.hpp"

namespace {

using srv::ParseStatus;
using srv::Request;

bool same(const Request &a, const Request &b) {
    auto eq = [](eastl::string_view x, eastl::string_view y) { return x.size() == y.size() && (x.empty() || (x.data() == y.data() && x.size() == y.size())); };
    return a.method == b.method && eq(a.path, b.path) && eq(a.authorization, b.authorization) && eq(a.body, b.body) && a.keep_alive == b.keep_alive && a.consumed == b.consumed;
}

const std::vector<std::string> &seeds() {
    static const std::vector<std::string> list = {
        "GET /feed HTTP/1.1\r\nHost: 127.0.0.1:8090\r\nUser-Agent: k6/2.3.0 (https://k6.io/)\r\nAccept-Encoding: gzip, deflate, br\r\n\r\n",
        "GET /posts/1234 HTTP/1.1\r\nHost: x\r\n\r\n",
        "POST /posts HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJlLWlzLW5vdC12YWxpZA\r\nContent-Type: application/json\r\nContent-Length: 15\r\n\r\n{\"body\":\"hello\"}",
        "POST /posts/5/like HTTP/1.1\r\nauthorization:   Bearer x  \r\nCONTENT-LENGTH: 0\r\nConnection: close\r\n\r\n",
        "GET /health?x=1&y=2 HTTP/1.0\r\nConnection: Keep-Alive\r\n\r\n",
        "GET / HTTP/1.1\r\n\r\n",
        "DELETE /x HTTP/1.1\r\nA: b\r\nC: d\r\nE: f\r\nG: h\r\nI: j\r\nK: l\r\nM: n\r\nO: p\r\nQ: r\r\nS: t\r\nU: v\r\nW: x\r\nY: z\r\n\r\n",
    };
    return list;
}

std::string mutate(std::mt19937_64 &rng, std::string s) {
    static const std::string interesting = "\r\n: ?/ HTTP/1.1abcdefghijklmnopqrstuvwxyz0123456789-GETPOST\t\x00\xff";
    int edits = 1 + static_cast<int>(rng() % 3);
    for (int e = 0; e < edits; ++e) {
        if (s.empty()) break;
        size_t at = rng() % s.size();
        switch (rng() % 6) {
            case 0: s[at] = interesting[rng() % interesting.size()]; break;
            case 1: s.insert(s.begin() + static_cast<long>(at), interesting[rng() % interesting.size()]); break;
            case 2: s.erase(at, 1); break;
            case 3: s.resize(at); break;
            case 4: s.insert(at, s.substr(at, 1 + rng() % 12)); break;
            default: s[at] = static_cast<char>(rng()); break;
        }
    }
    return s;
}

}

TEST(HttpFuzz, VectorizedParserMatchesTheScalarReference) {
    std::mt19937_64 rng(0xc0ffee);
    size_t ok = 0, bad = 0, incomplete = 0;
    for (size_t iter = 0; iter < 500000; ++iter) {
        std::string text = seeds()[rng() % seeds().size()];
        if (iter % 8 != 0) text = mutate(rng, text);
        if (iter % 5 == 0 && !text.empty()) text.resize(rng() % (text.size() + 1));
        Request a, b;
        ParseStatus sa = srv::parse_request(text.data(), text.size(), a);
        ParseStatus sb = srv::reference::parse_request(text.data(), text.size(), b);
        ASSERT_EQ(static_cast<int>(sa), static_cast<int>(sb)) << testing::PrintToString(text);
        if (sa == ParseStatus::Ok) {
            ASSERT_TRUE(same(a, b)) << testing::PrintToString(text);
            ++ok;
        } else if (sa == ParseStatus::Bad) {
            ++bad;
        } else {
            ++incomplete;
        }
    }
    EXPECT_GT(ok, 20000u);
    EXPECT_GT(bad, 20000u);
    EXPECT_GT(incomplete, 20000u);
}

TEST(HttpFuzz, ManyHeaderLinesBeyondTheRecordedBatch) {
    for (int lines : {1, 31, 32, 33, 34, 80, 400}) {
        std::string text = "POST /posts HTTP/1.1\r\n";
        for (int i = 0; i < lines; ++i) text += "X-" + std::to_string(i) + ": v\r\n";
        text += "Authorization: Bearer t\r\nContent-Length: 2\r\n\r\nhi";
        Request a, b;
        ASSERT_EQ(static_cast<int>(srv::parse_request(text.data(), text.size(), a)), static_cast<int>(srv::reference::parse_request(text.data(), text.size(), b))) << lines;
        ASSERT_TRUE(same(a, b)) << lines;
        EXPECT_EQ(std::string(a.authorization.data(), a.authorization.size()), "Bearer t") << lines;
    }
}

TEST(HttpFuzz, RandomBytesAgree) {
    std::mt19937_64 rng(5);
    for (size_t iter = 0; iter < 200000; ++iter) {
        std::string text(rng() % 96, '\0');
        for (char &c : text) c = "\r\n: GETPOSTHTTP/1.1abc"[rng() % 22];
        Request a, b;
        ASSERT_EQ(static_cast<int>(srv::parse_request(text.data(), text.size(), a)), static_cast<int>(srv::reference::parse_request(text.data(), text.size(), b))) << testing::PrintToString(text);
    }
}
