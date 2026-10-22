#include "simd.hpp"

#include <gtest/gtest.h>

#include <cstring>
#include <random>
#include <string>

namespace {

using srv::simd::kWidth;

struct Expected {
    int find = -1;
    int escape = -1;
    bool high = false;
};

Expected naive(const char *p, char needle) {
    Expected r;
    for (int i = 0; i < static_cast<int>(kWidth); ++i) {
        unsigned char c = static_cast<unsigned char>(p[i]);
        if (r.find < 0 && p[i] == needle) r.find = i;
        if (r.escape < 0 && (c == '"' || c == '\\' || c < 0x20)) r.escape = i;
        r.high |= c >= 0x80;
    }
    return r;
}

int lane(srv::simd::Mask m) { return m ? static_cast<int>(srv::simd::first(m)) : -1; }

void check(const char *block, char needle) {
    Expected want = naive(block, needle);
    std::string shown(block, kWidth);
    ASSERT_EQ(lane(srv::simd::find(block, needle)), want.find) << srv::simd::kBackend << " " << testing::PrintToString(shown);
    ASSERT_EQ(lane(srv::simd::escape(block)), want.escape) << srv::simd::kBackend << " " << testing::PrintToString(shown);
    ASSERT_EQ(srv::simd::any_high(block), want.high) << srv::simd::kBackend << " " << testing::PrintToString(shown);
}

TEST(Simd, EveryByteValueInEveryLane) {
    for (int fill : {0x61, 0x7f, 0x80, 0xff}) {
        for (size_t pos = 0; pos < kWidth; ++pos) {
            for (int v = 0; v < 256; ++v) {
                char block[kWidth];
                memset(block, fill, kWidth);
                block[pos] = static_cast<char>(v);
                for (int needle : {0x0d, 0x3a, 0x22, 0x80, 0xff}) check(block, static_cast<char>(needle));
            }
        }
    }
}

TEST(Simd, RandomBlocksMatchTheNaiveScan) {
    std::mt19937 rng(7);
    for (int i = 0; i < 200000; ++i) {
        char block[kWidth];
        // Mostly printable ASCII so later lanes get exercised, with some of every byte.
        for (char &c : block) c = static_cast<char>(rng() % 8 == 0 ? rng() % 256 : 0x20 + rng() % 95);
        check(block, static_cast<char>(rng() % 256));
    }
}

TEST(Simd, UnalignedLoads) {
    alignas(64) char buf[64 + kWidth];
    for (size_t i = 0; i < sizeof buf; ++i) buf[i] = static_cast<char>('A' + i % 26);
    for (size_t off = 0; off < 64; ++off) {
        buf[off + 5] = '"';
        check(buf + off, '"');
        buf[off + 5] = static_cast<char>('A' + (off + 5) % 26);
    }
}

}
