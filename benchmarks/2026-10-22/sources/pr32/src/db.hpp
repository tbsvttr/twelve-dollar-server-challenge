#pragma once

#include <EASTL/fixed_string.h>
#include <EASTL/string_view.h>
#include <sqlite3.h>

#include <cstdint>

#include "writer.hpp"

namespace srv {

enum class Lookup { Found, Missing, Failed };
enum class LikeResult { Created, Already, NoPost, Failed };

struct Created {
    int64_t id = 0;
    eastl::fixed_string<char, 40, false> created_at;
};

class Db {
public:
    Db() = default;
    ~Db();

    Db(const Db &) = delete;
    Db &operator=(const Db &) = delete;

    bool open(const char *path);
    const char *error() const;

    bool ping();
    bool in_transaction() const { return in_txn_ && !sqlite3_get_autocommit(db_); }
    bool commit();
    bool feed(Writer &out);
    bool feed_reference(Writer &out);
    Lookup post(int64_t id, Writer &out);
    bool insert_post(int64_t user_id, eastl::string_view body, Created &out);
    LikeResult like(int64_t user_id, int64_t post_id);

private:
    sqlite3_stmt *prepare(const char *sql);
    bool ensure_transaction();

    sqlite3 *db_ = nullptr;
    sqlite3_stmt *feed_ = nullptr;
    sqlite3_stmt *feed_ids_ = nullptr;
    sqlite3_stmt *feed_likes_ = nullptr;
    sqlite3_stmt *feed_rows_ = nullptr;
    sqlite3_stmt *one_ = nullptr;
    sqlite3_stmt *insert_post_ = nullptr;
    sqlite3_stmt *insert_like_ = nullptr;
    sqlite3_stmt *exists_ = nullptr;
    sqlite3_stmt *ping_ = nullptr;
    sqlite3_stmt *begin_ = nullptr;
    sqlite3_stmt *commit_ = nullptr;
    sqlite3_stmt *rollback_ = nullptr;
    bool in_txn_ = false;
    bool lost_ = false;
};

void write_post(Writer &out, int64_t id, eastl::string_view body, eastl::string_view created_at, eastl::string_view author, int64_t like_count);

}
