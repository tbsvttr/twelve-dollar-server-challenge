#include <gtest/gtest.h>

#include "conn.hpp"

static_assert(sizeof(srv::Conn) <= 64, "per-connection state must fit in one cache line");

TEST(Server, ConnectionStateIsOneCacheLine) { EXPECT_LE(sizeof(srv::Conn), 64u); }
