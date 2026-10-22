#include "db.hpp"

#include <cstdio>

namespace srv {

namespace {

constexpr const char *kPostSelect =
    "SELECT p.id, p.body, p.created_at, u.username,"
    " (SELECT count(*) FROM likes l WHERE l.post_id = p.id)"
    " FROM posts p JOIN users u ON u.id = p.user_id ";

eastl::string_view column_text(sqlite3_stmt *s, int i) {
    return {reinterpret_cast<const char *>(sqlite3_column_text(s, i)), static_cast<size_t>(sqlite3_column_bytes(s, i))};
}

void write_row(Writer &out, sqlite3_stmt *s) {
    write_post(out, sqlite3_column_int64(s, 0), column_text(s, 1), column_text(s, 2), column_text(s, 3), sqlite3_column_int64(s, 4));
}

struct Reset {
    sqlite3_stmt *s;
    ~Reset() { sqlite3_reset(s); }
};

}

void write_post(Writer &out, int64_t id, eastl::string_view body, eastl::string_view created_at, eastl::string_view author, int64_t like_count) {
    out.put("{\"id\":");
    out.put_int(id);
    out.put(",\"body\":");
    out.put_json_string(body);
    out.put(",\"created_at\":");
    out.put_json_string(created_at);
    out.put(",\"author\":");
    out.put_json_string(author);
    out.put(",\"like_count\":");
    out.put_int(like_count);
    out.put('}');
}

Db::~Db() {
    if (in_txn_ && db_ && !sqlite3_get_autocommit(db_)) sqlite3_exec(db_, "ROLLBACK", nullptr, nullptr, nullptr);
    for (sqlite3_stmt *s : {feed_, feed_ids_, feed_likes_, feed_rows_, one_, insert_post_, insert_like_, exists_, ping_, begin_, commit_, rollback_}) sqlite3_finalize(s);
    sqlite3_close(db_);
}

const char *Db::error() const { return db_ ? sqlite3_errmsg(db_) : "database not open"; }

sqlite3_stmt *Db::prepare(const char *sql) {
    sqlite3_stmt *s = nullptr;
    if (sqlite3_prepare_v3(db_, sql, -1, SQLITE_PREPARE_PERSISTENT, &s, nullptr) != SQLITE_OK) return nullptr;
    return s;
}

bool Db::open(const char *path) {
    if (sqlite3_initialize() != SQLITE_OK) return false;
    if (sqlite3_open_v2(path, &db_, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, nullptr) != SQLITE_OK) return false;
    if (sqlite3_exec(db_,
                     "PRAGMA locking_mode=EXCLUSIVE; PRAGMA busy_timeout=5000; PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;"
                     " PRAGMA mmap_size=1073741824; PRAGMA cache_size=-65536; PRAGMA temp_store=MEMORY;",
                     nullptr, nullptr, nullptr) != SQLITE_OK)
        return false;
    char sql[512];
    snprintf(sql, sizeof sql, "%sORDER BY p.created_at DESC, p.id DESC LIMIT 20", kPostSelect);
    feed_ = prepare(sql);
    feed_ids_ = prepare("SELECT id FROM posts ORDER BY created_at DESC, id DESC LIMIT 20");
    feed_likes_ = prepare("SELECT post_id, count(*) FROM likes WHERE post_id BETWEEN ?1 AND ?2 GROUP BY post_id ORDER BY post_id DESC");
    feed_rows_ = prepare(
        "SELECT p.id, p.body, p.created_at, u.username FROM posts p CROSS JOIN users u ON u.id = p.user_id"
        " WHERE p.id BETWEEN ?1 AND ?2 ORDER BY p.id DESC");
    snprintf(sql, sizeof sql, "%sWHERE p.id = ?1", kPostSelect);
    one_ = prepare(sql);
    insert_post_ = prepare("INSERT INTO posts (user_id, body) VALUES (?1, ?2) RETURNING id, created_at");
    insert_like_ = prepare("INSERT INTO likes (user_id, post_id) SELECT ?1, id FROM posts WHERE id = ?2 ON CONFLICT DO NOTHING");
    exists_ = prepare("SELECT 1 FROM posts WHERE id = ?1");
    ping_ = prepare("SELECT 1");
    begin_ = prepare("BEGIN IMMEDIATE");
    commit_ = prepare("COMMIT");
    rollback_ = prepare("ROLLBACK");
    return feed_ && feed_ids_ && feed_likes_ && feed_rows_ && one_ && insert_post_ && insert_like_ && exists_ && ping_ && begin_ && commit_ && rollback_;
}

bool Db::ensure_transaction() {
    if (in_txn_) {
        if (!sqlite3_get_autocommit(db_)) return true;
        lost_ = true;
        in_txn_ = false;
    }
    Reset reset{begin_};
    if (sqlite3_step(begin_) != SQLITE_DONE) return false;
    in_txn_ = true;
    return true;
}

bool Db::commit() {
    bool ok = !lost_;
    lost_ = false;
    if (!in_txn_) return ok;
    in_txn_ = false;
    if (sqlite3_get_autocommit(db_)) return false;
    {
        Reset reset{commit_};
        if (sqlite3_step(commit_) == SQLITE_DONE) return ok;
    }
    Reset reset{rollback_};
    sqlite3_step(rollback_);
    return false;
}

bool Db::ping() {
    Reset reset{ping_};
    return sqlite3_step(ping_) == SQLITE_ROW;
}

bool Db::feed(Writer &out) {
    constexpr int kFeedSize = 20;
    int64_t ids[kFeedSize];
    int n = 0;
    {
        Reset reset{feed_ids_};
        int rc;
        while ((rc = sqlite3_step(feed_ids_)) == SQLITE_ROW && n < kFeedSize) ids[n++] = sqlite3_column_int64(feed_ids_, 0);
        if (rc != SQLITE_ROW && rc != SQLITE_DONE) return false;
    }
    if (n == 0) {
        out.put("{\"posts\":[]}");
        return true;
    }
    for (int i = 1; i < n; ++i) {
        if (ids[i] != ids[0] - i) return feed_reference(out);
    }
    {
        Reset reset{feed_likes_};
        sqlite3_bind_int64(feed_likes_, 1, ids[n - 1]);
        sqlite3_bind_int64(feed_likes_, 2, ids[0]);
        Reset rows_reset{feed_rows_};
        sqlite3_bind_int64(feed_rows_, 1, ids[n - 1]);
        sqlite3_bind_int64(feed_rows_, 2, ids[0]);
        int like_rc = sqlite3_step(feed_likes_);
        out.put("{\"posts\":[");
        int rc;
        bool first = true;
        while ((rc = sqlite3_step(feed_rows_)) == SQLITE_ROW) {
            int64_t id = sqlite3_column_int64(feed_rows_, 0);
            while (like_rc == SQLITE_ROW && sqlite3_column_int64(feed_likes_, 0) > id) like_rc = sqlite3_step(feed_likes_);
            int64_t likes = 0;
            if (like_rc == SQLITE_ROW && sqlite3_column_int64(feed_likes_, 0) == id) likes = sqlite3_column_int64(feed_likes_, 1);
            if (!first) out.put(',');
            first = false;
            write_post(out, id, column_text(feed_rows_, 1), column_text(feed_rows_, 2), column_text(feed_rows_, 3), likes);
        }
        out.put("]}");
        return rc == SQLITE_DONE && (like_rc == SQLITE_ROW || like_rc == SQLITE_DONE);
    }
}

bool Db::feed_reference(Writer &out) {
    Reset reset{feed_};
    out.put("{\"posts\":[");
    int rc;
    bool first = true;
    while ((rc = sqlite3_step(feed_)) == SQLITE_ROW) {
        if (!first) out.put(',');
        first = false;
        write_row(out, feed_);
    }
    out.put("]}");
    return rc == SQLITE_DONE;
}

Lookup Db::post(int64_t id, Writer &out) {
    Reset reset{one_};
    sqlite3_bind_int64(one_, 1, id);
    int rc = sqlite3_step(one_);
    if (rc == SQLITE_DONE) return Lookup::Missing;
    if (rc != SQLITE_ROW) return Lookup::Failed;
    out.put("{\"post\":");
    write_row(out, one_);
    out.put('}');
    return Lookup::Found;
}

bool Db::insert_post(int64_t user_id, eastl::string_view body, Created &out) {
    if (!ensure_transaction()) return false;
    Reset reset{insert_post_};
    sqlite3_bind_int64(insert_post_, 1, user_id);
    sqlite3_bind_text(insert_post_, 2, body.data(), static_cast<int>(body.size()), SQLITE_STATIC);
    if (sqlite3_step(insert_post_) != SQLITE_ROW) return false;
    out.id = sqlite3_column_int64(insert_post_, 0);
    eastl::string_view created = column_text(insert_post_, 1);
    if (created.size() > out.created_at.capacity()) return false;
    out.created_at.assign(created.data(), created.size());
    return sqlite3_step(insert_post_) == SQLITE_DONE;
}

LikeResult Db::like(int64_t user_id, int64_t post_id) {
    if (!ensure_transaction()) return LikeResult::Failed;
    {
        Reset reset{insert_like_};
        sqlite3_bind_int64(insert_like_, 1, user_id);
        sqlite3_bind_int64(insert_like_, 2, post_id);
        if (sqlite3_step(insert_like_) != SQLITE_DONE) return LikeResult::Failed;
    }
    if (sqlite3_changes(db_) > 0) return LikeResult::Created;
    Reset reset{exists_};
    sqlite3_bind_int64(exists_, 1, post_id);
    int rc = sqlite3_step(exists_);
    if (rc == SQLITE_ROW) return LikeResult::Already;
    return rc == SQLITE_DONE ? LikeResult::NoPost : LikeResult::Failed;
}

}
