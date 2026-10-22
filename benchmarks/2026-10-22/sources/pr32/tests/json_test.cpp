#include <gtest/gtest.h>

#include <deque>
#include <string>

#include "json.hpp"

using srv::JsonFields;
using View = eastl::string_view;

namespace {

bool scan(std::string text, JsonFields &out) {
    static std::deque<std::string> keep;
    keep.push_back(std::move(text));
    const std::string &stored = keep.back();
    return srv::scan_json(View(stored.data(), stored.size()), out);
}

std::string unescape(const std::string &raw) {
    std::string out(raw.size() + 8, '\0');
    out.resize(srv::json_unescape(raw.data(), raw.size(), out.data()));
    return out;
}

}

TEST(Json, ExtractsTheFieldsTheServerNeeds) {
    JsonFields f;
    ASSERT_TRUE(scan(R"({"sub":"42","username":"bob","iat":1,"exp":2106767691,"body":"hi","alg":"HS256"})", f));
    EXPECT_TRUE(f.top_is_object);
    EXPECT_EQ(f.sub.kind, 's');
    EXPECT_TRUE(f.sub.raw() == View("42"));
    EXPECT_TRUE(f.username.raw() == View("bob"));
    EXPECT_EQ(f.exp.kind, 'n');
    EXPECT_TRUE(f.exp.raw() == View("2106767691"));
    EXPECT_TRUE(f.body.raw() == View("hi"));
    EXPECT_TRUE(f.alg.raw() == View("HS256"));
}

TEST(Json, FlagsEscapedStrings) {
    JsonFields f;
    ASSERT_TRUE(scan(R"({"body":"a\nb"})", f));
    EXPECT_TRUE(f.body.escaped);
    ASSERT_TRUE(scan(R"({"body":"plain"})", f));
    EXPECT_FALSE(f.body.escaped);
}

TEST(Json, LastDuplicateKeyWins) {
    JsonFields f;
    ASSERT_TRUE(scan(R"({"body":"a","body":"b"})", f));
    EXPECT_TRUE(f.body.raw() == View("b"));
}

TEST(Json, NestedValuesAreValidatedAndSkipped) {
    JsonFields f;
    ASSERT_TRUE(scan(R"({"x":{"body":"inner","y":[1,2,{"z":null}]},"body":"outer","t":true,"f":false})", f));
    EXPECT_TRUE(f.body.raw() == View("outer"));
}

TEST(Json, ValidNonObjectsAreAcceptedButNotObjects) {
    JsonFields f;
    for (const char *text : {"1", "\"x\"", "null", "true", "[]", "[1,2,3]", " 7 "}) {
        EXPECT_TRUE(scan(text, f)) << text;
        EXPECT_FALSE(f.top_is_object) << text;
    }
    ASSERT_TRUE(scan("{}", f));
    EXPECT_TRUE(f.top_is_object);
}

TEST(Json, AllowsWhitespaceBetweenTokens) {
    JsonFields f;
    ASSERT_TRUE(scan(" \t\r\n{ \"body\" : \"x\" , \"a\" : [ 1 , 2 ] }\n ", f));
    EXPECT_TRUE(f.body.raw() == View("x"));
}

TEST(Json, RejectsMalformedDocuments) {
    const char *bad[] = {
        "", " ", "{", "}", "[", "]", "{\"a\"}", "{\"a\":}", "{\"a\" 1}", "{\"a\":1,}", "[1,]", "[,1]", "{,}", "{'a':1}",
        "{\"a\":01}", "{\"a\":1.}", "{\"a\":.5}", "{\"a\":-}", "{\"a\":+1}", "{\"a\":1e}", "{\"a\":1e+}", "{\"a\":0x10}",
        "{\"a\":\"\\x\"}", "{\"a\":\"\\u12\"}", "{\"a\":\"\\u12g4\"}", "{\"a\":\"unterminated}", "{\"a\":\"tab\there\"}",
        "{\"a\":\"nl\nhere\"}", "nul", "tru", "falsey", "{\"a\":1}}", "{\"a\":1} x", "{\"a\":1}{\"b\":2}", "{a:1}", "{\"a\":nan}",
        "{\"a\":Infinity}", "{\"a\":[1 2]}", "{\"a\":{\"b\":1]}", "[\"a\":1]", "{\"a\":1 \"b\":2}", "\"unterminated", "{\"\\ud800\":1",
        "{bad json", "{\"body\":\"x\"", "{\"body\":\"x\"}}", "{\"body\":\"\\q\"}",
    };
    JsonFields f;
    for (const char *text : bad) EXPECT_FALSE(scan(text, f)) << text;
}

TEST(Json, RejectsTooDeepNesting) {
    JsonFields f;
    EXPECT_TRUE(scan(std::string(60, '[') + std::string(60, ']'), f));
    EXPECT_FALSE(scan(std::string(100, '[') + std::string(100, ']'), f));
}

TEST(Json, RejectsInvalidUtf8AndAcceptsValid) {
    JsonFields f;
    EXPECT_TRUE(scan("{\"body\":\"caf\xC3\xA9 \xE2\x9C\x93 \xF0\x9F\x98\x80\"}", f));
    const char *bad[] = {"\xC0\xAF", "\xC1\x80", "\xED\xA0\x80", "\xF5\x80\x80\x80", "\xE0\x80\x80", "\xF0\x80\x80\x80", "\xC3", "\xE2\x9C", "\xFF", "\x80"};
    for (const char *body : bad) EXPECT_FALSE(scan(std::string("{\"body\":\"") + body + "\"}", f));
}

TEST(Json, LongStringsCrossingVectorBoundaries) {
    JsonFields f;
    for (size_t n : {0u, 1u, 15u, 16u, 17u, 31u, 32u, 33u, 500u, 4096u}) {
        std::string text = "{\"body\":\"" + std::string(n, 'a') + "\"}";
        ASSERT_TRUE(scan(text, f)) << n;
        EXPECT_EQ(f.body.n, n);
    }
    std::string quote_late = "{\"body\":\"" + std::string(40, 'a') + "\\\"" + std::string(40, 'b') + "\"}";
    ASSERT_TRUE(scan(quote_late, f));
    EXPECT_TRUE(f.body.escaped);
}

TEST(JsonUnescape, SimpleEscapes) {
    EXPECT_EQ(unescape(R"(a\"b\\c\/d\be\ff\ng\rh\ti)"), "a\"b\\c/d\be\ff\ng\rh\ti");
}

TEST(JsonUnescape, UnicodeEscapes) {
    EXPECT_EQ(unescape(R"(\u00e9)"), "\xC3\xA9");
    EXPECT_EQ(unescape(R"(\u4e2d)"), "\xE4\xB8\xAD");
    EXPECT_EQ(unescape(R"(\ud83d\ude00)"), "\xF0\x9F\x98\x80");
    EXPECT_EQ(unescape(R"(\u0041BC)"), "ABC");
}

TEST(JsonUnescape, LoneSurrogatesBecomeReplacementCharacter) {
    EXPECT_EQ(unescape(R"(\ud800)"), "\xEF\xBF\xBD");
    EXPECT_EQ(unescape(R"(\udc00)"), "\xEF\xBF\xBD");
    EXPECT_EQ(unescape(R"(\ud800x)"), "\xEF\xBF\xBDx");
    EXPECT_EQ(unescape(R"(\ud800\u0041)"), "\xEF\xBF\xBD" "A");
}

TEST(JsonUnescape, PlainRunsAreCopiedUntouched) {
    EXPECT_EQ(unescape("no escapes at all, just a long enough run of text to cross sixteen bytes"), "no escapes at all, just a long enough run of text to cross sixteen bytes");
}
