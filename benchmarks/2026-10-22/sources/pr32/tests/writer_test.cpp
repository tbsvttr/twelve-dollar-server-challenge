#include <gtest/gtest.h>

#include <string>

#include "block_pool.hpp"
#include "writer.hpp"

using View = eastl::string_view;

namespace {

std::string json_quoted(const std::string &raw) {
    static char buf[1 << 16];
    srv::Writer w(buf, sizeof buf);
    w.put_json_string(View(raw.data(), raw.size()));
    return std::string(w.data(), w.size());
}

}

TEST(Writer, EscapesQuotesBackslashesAndControlCharacters) {
    EXPECT_EQ(json_quoted("plain"), "\"plain\"");
    EXPECT_EQ(json_quoted("a\"b"), "\"a\\\"b\"");
    EXPECT_EQ(json_quoted("a\\b"), "\"a\\\\b\"");
    EXPECT_EQ(json_quoted("l1\nl2\r\t"), "\"l1\\nl2\\r\\t\"");
    EXPECT_EQ(json_quoted(std::string("\x01\x1f", 2)), "\"\\u0001\\u001f\"");
    EXPECT_EQ(json_quoted("\b\f"), "\"\\b\\f\"");
    EXPECT_EQ(json_quoted(""), "\"\"");
}

TEST(Writer, PassesUtf8AndSlashesThrough) {
    EXPECT_EQ(json_quoted("caf\xC3\xA9 \xE2\x9C\x93 <b>&amp;</b> /x"), "\"caf\xC3\xA9 \xE2\x9C\x93 <b>&amp;</b> /x\"");
}

TEST(Writer, MatchesAByteWiseReferenceAcrossVectorBoundaries) {
    auto reference = [](const std::string &s) {
        std::string out = "\"";
        for (unsigned char c : s) {
            if (c == '"') out += "\\\"";
            else if (c == '\\') out += "\\\\";
            else if (c == '\n') out += "\\n";
            else if (c == '\r') out += "\\r";
            else if (c == '\t') out += "\\t";
            else if (c == '\b') out += "\\b";
            else if (c == '\f') out += "\\f";
            else if (c < 0x20) { char tmp[8]; snprintf(tmp, sizeof tmp, "\\u%04x", c); out += tmp; }
            else out += static_cast<char>(c);
        }
        return out + "\"";
    };
    const std::string alphabet = std::string("ab\"\\\n\x02") + "\xC3\xA9 z";
    for (size_t n = 0; n < 70; ++n) {
        for (size_t shift = 0; shift < alphabet.size(); ++shift) {
            std::string s;
            for (size_t i = 0; i < n; ++i) s.push_back(alphabet[(i * 7 + shift) % alphabet.size()]);
            ASSERT_EQ(json_quoted(s), reference(s)) << n << "/" << shift;
        }
    }
}

TEST(Writer, FormatsIntegersAndTracksOverflow) {
    char buf[64];
    srv::Writer w(buf, sizeof buf);
    w.put("n=");
    w.put_int(-9223372036854775807LL - 1);
    EXPECT_EQ(std::string(w.data(), w.size()), "n=-9223372036854775808");
    EXPECT_FALSE(w.overflowed());
    char tiny[8];
    srv::Writer small(tiny, sizeof tiny);
    small.put("0123456789");
    EXPECT_TRUE(small.overflowed());
    small.clear();
    EXPECT_FALSE(small.overflowed());
    EXPECT_EQ(small.size(), 0u);
}

TEST(BlockPool, ReusesFreedBlocksAndExhausts) {
    srv::BlockPool pool(3);
    char *a = pool.take();
    char *b = pool.take();
    char *c = pool.take();
    ASSERT_TRUE(a && b && c);
    EXPECT_NE(a, b);
    EXPECT_EQ(pool.take(), nullptr);
    EXPECT_EQ(pool.in_use(), 3u);
    pool.give(b);
    EXPECT_EQ(pool.take(), b);
    a[0] = 'x';
    a[srv::BlockPool::kBlockSize - 1] = 'y';
    EXPECT_EQ(a[0], 'x');
}
