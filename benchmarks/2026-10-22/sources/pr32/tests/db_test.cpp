#include <gtest/gtest.h>
#include <sqlite3.h>
#include <unistd.h>

#include <cstdio>
#include <string>

#include "db.hpp"
#include "test_util.hpp"

namespace {

class DbTest : public ::testing::Test {
protected:
    void SetUp() override {
        char path[] = "/tmp/srv-db-test-XXXXXX";
        int fd = mkstemp(path);
        ASSERT_GE(fd, 0);
        close(fd);
        path_ = path;
        sqlite3 *raw = nullptr;
        ASSERT_EQ(sqlite3_open(path, &raw), SQLITE_OK);
        ASSERT_EQ(sqlite3_exec(raw, testutil::kTestSchema, nullptr, nullptr, nullptr), SQLITE_OK);
        ASSERT_EQ(sqlite3_exec(raw, "INSERT INTO users (id, username) VALUES (1,'alice'),(2,'bob'); INSERT INTO posts (id, user_id, body) VALUES (1,1,'first');", nullptr, nullptr, nullptr), SQLITE_OK);
        sqlite3_close(raw);
    }

    void TearDown() override {
        std::remove(path_.c_str());
        std::remove((path_ + "-wal").c_str());
        std::remove((path_ + "-shm").c_str());
    }

    long count(const char *table) {
        sqlite3 *raw = nullptr;
        sqlite3_open(path_.c_str(), &raw);
        sqlite3_stmt *s = nullptr;
        sqlite3_prepare_v2(raw, (std::string("SELECT count(*) FROM ") + table).c_str(), -1, &s, nullptr);
        long n = sqlite3_step(s) == SQLITE_ROW ? static_cast<long>(sqlite3_column_int64(s, 0)) : -1;
        sqlite3_finalize(s);
        sqlite3_close(raw);
        return n;
    }

    std::string path_;
};

}

TEST_F(DbTest, WritesShareOneTransactionUntilCommit) {
    srv::Db db;
    ASSERT_TRUE(db.open(path_.c_str()));
    EXPECT_FALSE(db.in_transaction());
    srv::Created created;
    ASSERT_TRUE(db.insert_post(1, "second", created));
    EXPECT_TRUE(db.in_transaction());
    EXPECT_EQ(db.like(2, created.id), srv::LikeResult::Created);
    EXPECT_TRUE(db.in_transaction());
    char buffer[4096];
    srv::Writer out(buffer, sizeof buffer);
    EXPECT_EQ(db.post(created.id, out), srv::Lookup::Found);
    EXPECT_TRUE(db.commit());
    EXPECT_FALSE(db.in_transaction());
}

TEST_F(DbTest, CommittedWritesSurviveReopening) {
    {
        srv::Db db;
        ASSERT_TRUE(db.open(path_.c_str()));
        srv::Created created;
        for (int i = 0; i < 3; ++i) ASSERT_TRUE(db.insert_post(1, "more", created));
        EXPECT_EQ(db.like(2, created.id), srv::LikeResult::Created);
        EXPECT_EQ(db.like(2, created.id), srv::LikeResult::Already);
        EXPECT_EQ(db.like(2, 9999), srv::LikeResult::NoPost);
        ASSERT_TRUE(db.commit());
    }
    EXPECT_EQ(count("posts"), 4);
    EXPECT_EQ(count("likes"), 1);
}

TEST_F(DbTest, UncommittedWritesAreRolledBackWhenTheDatabaseCloses) {
    {
        srv::Db db;
        ASSERT_TRUE(db.open(path_.c_str()));
        srv::Created created;
        ASSERT_TRUE(db.insert_post(1, "never committed", created));
    }
    EXPECT_EQ(count("posts"), 1);
}

TEST_F(DbTest, CommitWithoutATransactionIsANoOp) {
    srv::Db db;
    ASSERT_TRUE(db.open(path_.c_str()));
    EXPECT_TRUE(db.commit());
    EXPECT_TRUE(db.commit());
}

TEST_F(DbTest, AFreshTransactionStartsAfterEachCommit) {
    srv::Db db;
    ASSERT_TRUE(db.open(path_.c_str()));
    srv::Created created;
    ASSERT_TRUE(db.insert_post(1, "a", created));
    ASSERT_TRUE(db.commit());
    EXPECT_FALSE(db.in_transaction());
    ASSERT_TRUE(db.insert_post(1, "b", created));
    EXPECT_TRUE(db.in_transaction());
    ASSERT_TRUE(db.commit());
}

TEST_F(DbTest, ExclusiveLockingKeepsOtherConnectionsOut) {
    srv::Db db;
    ASSERT_TRUE(db.open(path_.c_str()));
    sqlite3 *other = nullptr;
    ASSERT_EQ(sqlite3_open(path_.c_str(), &other), SQLITE_OK);
    EXPECT_EQ(sqlite3_exec(other, "SELECT count(*) FROM posts", nullptr, nullptr, nullptr), SQLITE_BUSY);
    sqlite3_close(other);
}

namespace {

std::string feed_of(srv::Db &db, bool reference) {
    static char buffer[1 << 16];
    srv::Writer out(buffer, sizeof buffer);
    EXPECT_TRUE(reference ? db.feed_reference(out) : db.feed(out));
    return std::string(out.data(), out.size());
}

}

class FeedTest : public DbTest {
protected:
    void run(const std::string &sql) {
        sqlite3 *raw = nullptr;
        ASSERT_EQ(sqlite3_open(path_.c_str(), &raw), SQLITE_OK);
        ASSERT_EQ(sqlite3_exec(raw, sql.c_str(), nullptr, nullptr, nullptr), SQLITE_OK) << sqlite3_errmsg(raw);
        sqlite3_close(raw);
    }

    void fill(int posts, int stride_seconds, bool shuffled) {
        std::string sql = "DELETE FROM likes; DELETE FROM posts;";
        for (int i = 1; i <= posts; ++i) {
            int t = shuffled ? (i * 7919) % posts : i * stride_seconds;
            char ts[40];
            snprintf(ts, sizeof ts, "2026-01-01T00:%02d:%02d.000Z", (t / 60) % 60, t % 60);
            sql += "INSERT INTO posts (id, user_id, body, created_at) VALUES (" + std::to_string(i) + "," + std::to_string(1 + i % 2) + ",'post " + std::to_string(i) + "','" + ts + "');";
        }
        for (int i = 1; i <= posts; ++i) {
            if (i % 3 == 0) continue;
            for (int u = 1; u <= 2; ++u) {
                if ((i + u) % 2 == 0 || i % 5 == 0) sql += "INSERT INTO likes (user_id, post_id) VALUES (" + std::to_string(u) + "," + std::to_string(i) + ");";
            }
        }
        run(sql);
    }

    void expect_same() {
        srv::Db db;
        ASSERT_TRUE(db.open(path_.c_str()));
        EXPECT_EQ(feed_of(db, false), feed_of(db, true));
    }
};

TEST_F(FeedTest, EmptyFeed) {
    run("DELETE FROM posts;");
    srv::Db db;
    ASSERT_TRUE(db.open(path_.c_str()));
    EXPECT_EQ(feed_of(db, false), "{\"posts\":[]}");
    EXPECT_EQ(feed_of(db, true), "{\"posts\":[]}");
}

TEST_F(FeedTest, FewerThanTwentyPosts) {
    for (int n : {1, 2, 5, 19, 20}) {
        fill(n, 1, false);
        expect_same();
    }
}

TEST_F(FeedTest, ManyPostsWithAdjacentIds) {
    fill(300, 1, false);
    expect_same();
}

TEST_F(FeedTest, NewestPostsWithoutLikesAndOldestWithLikes) {
    fill(60, 1, false);
    run("DELETE FROM likes WHERE post_id > 45; INSERT OR IGNORE INTO likes (user_id, post_id) VALUES (1, 41), (2, 41);");
    expect_same();
}

TEST_F(FeedTest, GapInIdsFallsBackToTheReferenceQuery) {
    fill(100, 1, false);
    run("DELETE FROM likes WHERE post_id = 95; DELETE FROM posts WHERE id = 95;");
    expect_same();
}

TEST_F(FeedTest, TimestampOrderDifferentFromIdOrderFallsBack) {
    fill(100, 1, true);
    expect_same();
}

TEST_F(FeedTest, EqualTimestampsOrderByIdDescending) {
    fill(50, 0, false);
    expect_same();
}

TEST_F(FeedTest, SeesRowsWrittenInTheOpenTransaction) {
    fill(30, 1, false);
    srv::Db db;
    ASSERT_TRUE(db.open(path_.c_str()));
    srv::Created created;
    ASSERT_TRUE(db.insert_post(1, "fresh", created));
    ASSERT_EQ(db.like(2, created.id), srv::LikeResult::Created);
    std::string fast = feed_of(db, false);
    EXPECT_EQ(fast, feed_of(db, true));
    EXPECT_NE(fast.find("\"like_count\":1}"), std::string::npos);
    EXPECT_TRUE(db.commit());
}
