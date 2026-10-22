#include <gtest/gtest.h>

#include <deque>
#include <string>

#include "http.hpp"

using srv::Method;
using srv::ParseStatus;
using srv::Request;
using View = eastl::string_view;

namespace {

ParseStatus parse(std::string text, Request &req) {
    static std::deque<std::string> keep;
    keep.push_back(std::move(text));
    const std::string &stored = keep.back();
    return srv::parse_request(stored.data(), stored.size(), req);
}

bool same(View a, const char *b) { return a == View(b); }

}

TEST(Http, ParsesAGetRequest) {
    std::string text = "GET /feed HTTP/1.1\r\nHost: x\r\n\r\n";
    Request r;
    ASSERT_EQ(parse(text, r), ParseStatus::Ok);
    EXPECT_EQ(r.method, Method::Get);
    EXPECT_TRUE(same(r.path, "/feed"));
    EXPECT_TRUE(r.keep_alive);
    EXPECT_EQ(r.consumed, text.size());
    EXPECT_TRUE(r.body.empty());
}

TEST(Http, ParsesAPostWithBodyAndAuthorization) {
    std::string text = "POST /posts HTTP/1.1\r\nAuthorization: Bearer abc.def.ghi\r\nContent-Type: application/json\r\nContent-Length: 13\r\n\r\n{\"body\":\"hi\"}";
    Request r;
    ASSERT_EQ(parse(text, r), ParseStatus::Ok);
    EXPECT_EQ(r.method, Method::Post);
    EXPECT_TRUE(same(r.authorization, "Bearer abc.def.ghi"));
    EXPECT_TRUE(same(r.body, "{\"body\":\"hi\"}"));
    EXPECT_EQ(r.consumed, text.size());
}

TEST(Http, HeaderNamesAreCaseInsensitiveAndValuesTrimmed) {
    std::string text = "POST /posts HTTP/1.1\r\nAUTHORIZATION:   Bearer x  \r\ncontent-LENGTH: 2\r\n\r\n{}";
    Request r;
    ASSERT_EQ(parse(text, r), ParseStatus::Ok);
    EXPECT_TRUE(same(r.authorization, "Bearer x"));
    EXPECT_TRUE(same(r.body, "{}"));
}

TEST(Http, StripsTheQueryString) {
    Request r;
    ASSERT_EQ(parse("GET /posts/5?x=1&y=2 HTTP/1.1\r\n\r\n", r), ParseStatus::Ok);
    EXPECT_TRUE(same(r.path, "/posts/5"));
}

TEST(Http, UnknownMethodsAreReportedAsOther) {
    Request r;
    ASSERT_EQ(parse("DELETE /feed HTTP/1.1\r\n\r\n", r), ParseStatus::Ok);
    EXPECT_EQ(r.method, Method::Other);
}

TEST(Http, PartialRequestsAreIncomplete) {
    std::string full = "POST /posts HTTP/1.1\r\nContent-Length: 10\r\n\r\n0123456789";
    for (size_t n = 0; n < full.size(); ++n) {
        Request r;
        EXPECT_EQ(srv::parse_request(full.data(), n, r), ParseStatus::Incomplete) << n;
    }
    Request r;
    EXPECT_EQ(srv::parse_request(full.data(), full.size(), r), ParseStatus::Ok);
}

TEST(Http, PipelinedRequestsReportOnlyTheFirstConsumed) {
    std::string first = "GET /feed HTTP/1.1\r\nHost: x\r\n\r\n";
    std::string second = "GET /health HTTP/1.1\r\n\r\n";
    std::string both = first + second;
    Request r;
    ASSERT_EQ(parse(both, r), ParseStatus::Ok);
    EXPECT_EQ(r.consumed, first.size());
    ASSERT_EQ(srv::parse_request(both.data() + r.consumed, both.size() - r.consumed, r), ParseStatus::Ok);
    EXPECT_TRUE(same(r.path, "/health"));
}

TEST(Http, KeepAliveSemantics) {
    Request r;
    ASSERT_EQ(parse("GET / HTTP/1.1\r\nConnection: close\r\n\r\n", r), ParseStatus::Ok);
    EXPECT_FALSE(r.keep_alive);
    ASSERT_EQ(parse("GET / HTTP/1.0\r\n\r\n", r), ParseStatus::Ok);
    EXPECT_FALSE(r.keep_alive);
    ASSERT_EQ(parse("GET / HTTP/1.0\r\nConnection: Keep-Alive\r\n\r\n", r), ParseStatus::Ok);
    EXPECT_TRUE(r.keep_alive);
}

TEST(Http, RejectsMalformedRequests) {
    const char *bad[] = {
        "GET\r\n\r\n", "GET /\r\n\r\n", "GET  HTTP/1.1\r\n\r\n", "GET x HTTP/1.1\r\n\r\n", "GET / HTTP/2\r\n\r\n", "GET / HTTP/1.1x\r\n\r\n",
        "GET / HTTP/1.1\r\nNoColonHere\r\n\r\n", "GET / HTTP/1.1\r\n: empty\r\n\r\n", "POST / HTTP/1.1\r\nContent-Length: abc\r\n\r\n",
        "POST / HTTP/1.1\r\nContent-Length: -1\r\n\r\n", "POST / HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\nxx",
        "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n", "POST / HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n",
    };
    for (const char *text : bad) {
        Request r;
        EXPECT_EQ(parse(text, r), ParseStatus::Bad) << text;
    }
}

TEST(Http, RejectsOversizedHeaders) {
    std::string big = "GET / HTTP/1.1\r\nX: " + std::string(srv::kMaxHeaderBytes + 100, 'a');
    Request r;
    EXPECT_EQ(parse(big, r), ParseStatus::Bad);
}

TEST(Http, DuplicateIdenticalContentLengthIsAccepted) {
    Request r;
    ASSERT_EQ(parse("POST / HTTP/1.1\r\nContent-Length: 2\r\nContent-Length: 2\r\n\r\nxx", r), ParseStatus::Ok);
    EXPECT_TRUE(same(r.body, "xx"));
}
