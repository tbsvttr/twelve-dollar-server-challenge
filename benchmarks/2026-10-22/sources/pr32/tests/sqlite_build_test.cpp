#include <gtest/gtest.h>
#include <sqlite3.h>

#include <cstring>

namespace {
const int kInitialized = sqlite3_initialize();
}

TEST(SqliteBuild, IsTheSourceBuildNotTheSystemLibrary) {
    EXPECT_EQ(kInitialized, SQLITE_OK);
    EXPECT_STREQ(sqlite3_libversion(), "3.53.4");
    EXPECT_EQ(sqlite3_threadsafe(), 0);
    EXPECT_TRUE(sqlite3_compileoption_used("OMIT_LOAD_EXTENSION"));
    EXPECT_TRUE(sqlite3_compileoption_used("DEFAULT_MEMSTATUS=0"));
    EXPECT_TRUE(sqlite3_compileoption_used("MAX_EXPR_DEPTH=0"));
    EXPECT_TRUE(sqlite3_compileoption_used("OMIT_AUTOINIT"));
}

TEST(SqliteBuild, WorksForTheStatementsTheServerUses) {
    sqlite3 *db = nullptr;
    ASSERT_EQ(sqlite3_open(":memory:", &db), SQLITE_OK);
    ASSERT_EQ(sqlite3_exec(db, "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT); INSERT INTO t (v) VALUES ('a'),('b');", nullptr, nullptr, nullptr), SQLITE_OK);
    sqlite3_stmt *s = nullptr;
    ASSERT_EQ(sqlite3_prepare_v3(db, "INSERT INTO t (v) VALUES (?1) RETURNING id", -1, SQLITE_PREPARE_PERSISTENT, &s, nullptr), SQLITE_OK);
    sqlite3_bind_text(s, 1, "c", -1, SQLITE_STATIC);
    ASSERT_EQ(sqlite3_step(s), SQLITE_ROW);
    EXPECT_EQ(sqlite3_column_int64(s, 0), 3);
    ASSERT_EQ(sqlite3_step(s), SQLITE_DONE);
    sqlite3_finalize(s);
    sqlite3_close(db);
}
