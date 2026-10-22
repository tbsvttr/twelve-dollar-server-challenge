#include <sqlite3.h>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <random>
#include <string>

namespace {

const char *kSchema =
    "CREATE TABLE users (id INTEGER PRIMARY KEY, username TEXT NOT NULL UNIQUE, created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')));"
    "CREATE TABLE posts (id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL REFERENCES users(id), body TEXT NOT NULL CHECK (length(body) BETWEEN 1 AND 500), created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')));"
    "CREATE TABLE likes (user_id INTEGER NOT NULL REFERENCES users(id), post_id INTEGER NOT NULL REFERENCES posts(id), created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')), PRIMARY KEY (user_id, post_id));"
    "CREATE INDEX posts_created_at_id_idx ON posts (created_at DESC, id DESC);"
    "CREATE INDEX posts_user_id_idx ON posts (user_id);"
    "CREATE INDEX likes_post_id_idx ON likes (post_id);";

const char *kSelect =
    "SELECT p.id, p.body, p.created_at, u.username, (SELECT count(*) FROM likes l WHERE l.post_id = p.id) FROM posts p JOIN users u ON u.id = p.user_id ";

constexpr int kUsers = 20000;
constexpr int kPosts = 100000;
constexpr int kLikes = 400000;

void exec(sqlite3 *db, const char *sql) {
    char *err = nullptr;
    if (sqlite3_exec(db, sql, nullptr, nullptr, &err) != SQLITE_OK) {
        std::fprintf(stderr, "sql error: %s\n", err);
        std::exit(1);
    }
}

sqlite3_stmt *prepare(sqlite3 *db, const std::string &sql) {
    sqlite3_stmt *s = nullptr;
    if (sqlite3_prepare_v3(db, sql.c_str(), -1, SQLITE_PREPARE_PERSISTENT, &s, nullptr) != SQLITE_OK) {
        std::fprintf(stderr, "prepare error: %s\n", sqlite3_errmsg(db));
        std::exit(1);
    }
    return s;
}

void generate(sqlite3 *db) {
    exec(db, kSchema);
    exec(db, "BEGIN");
    std::mt19937_64 rng(1234);
    sqlite3_stmt *s = prepare(db, "INSERT INTO users (id, username) VALUES (?1, ?2)");
    for (int i = 1; i <= kUsers; i++) {
        std::string name = "user_" + std::to_string(i);
        sqlite3_bind_int(s, 1, i);
        sqlite3_bind_text(s, 2, name.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_step(s);
        sqlite3_reset(s);
    }
    sqlite3_finalize(s);
    s = prepare(db, "INSERT INTO posts (id, user_id, body, created_at) VALUES (?1, ?2, ?3, ?4)");
    for (int i = 1; i <= kPosts; i++) {
        std::string body(40 + rng() % 200, 'a');
        for (char &c : body) c = "abcdefghij klmnop"[rng() % 17];
        char stamp[40];
        std::snprintf(stamp, sizeof stamp, "2025-01-%02dT%02d:%02d:%02d.%03dZ", 1 + i / 86400 % 28, i / 3600 % 24, i / 60 % 60, i % 60, static_cast<int>(rng() % 1000));
        sqlite3_bind_int(s, 1, i);
        sqlite3_bind_int(s, 2, 1 + static_cast<int>(rng() % kUsers));
        sqlite3_bind_text(s, 3, body.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(s, 4, stamp, -1, SQLITE_TRANSIENT);
        sqlite3_step(s);
        sqlite3_reset(s);
    }
    sqlite3_finalize(s);
    s = prepare(db, "INSERT OR IGNORE INTO likes (user_id, post_id) VALUES (?1, ?2)");
    for (int i = 0; i < kLikes; i++) {
        sqlite3_bind_int(s, 1, 1 + static_cast<int>(rng() % kUsers));
        sqlite3_bind_int(s, 2, 1 + static_cast<int>(rng() % kPosts));
        sqlite3_step(s);
        sqlite3_reset(s);
    }
    sqlite3_finalize(s);
    exec(db, "COMMIT");
}

uint64_t workload(sqlite3 *db, int iterations) {
    std::string select = kSelect;
    sqlite3_stmt *feed = prepare(db, select + "ORDER BY p.created_at DESC, p.id DESC LIMIT 20");
    sqlite3_stmt *one = prepare(db, select + "WHERE p.id = ?1");
    sqlite3_stmt *like = prepare(db, "INSERT INTO likes (user_id, post_id) SELECT ?1, id FROM posts WHERE id = ?2 ON CONFLICT DO NOTHING");
    sqlite3_stmt *exists = prepare(db, "SELECT 1 FROM posts WHERE id = ?1");
    sqlite3_stmt *create = prepare(db, "INSERT INTO posts (user_id, body) VALUES (?1, ?2) RETURNING id, created_at");
    sqlite3_stmt *ping = prepare(db, "SELECT 1");
    sqlite3_stmt *begin = prepare(db, "BEGIN IMMEDIATE");
    sqlite3_stmt *commit = prepare(db, "COMMIT");
    bool in_transaction = false;
    auto ensure_transaction = [&] {
        if (in_transaction) return;
        sqlite3_step(begin);
        sqlite3_reset(begin);
        in_transaction = true;
    };
    std::mt19937_64 rng(99);
    uint64_t sink = 0;
    const char *body = "golden_ember_1 says hi at 2026-10-10T00:23:45.123Z (VU 1234, iter 5)";
    for (int i = 0; i < iterations; i++) {
        while (sqlite3_step(feed) == SQLITE_ROW) {
            sink += static_cast<uint64_t>(sqlite3_column_int64(feed, 0)) + sqlite3_column_bytes(feed, 1) + sqlite3_column_bytes(feed, 2) + sqlite3_column_bytes(feed, 3) +
                    static_cast<uint64_t>(sqlite3_column_int64(feed, 4));
        }
        sqlite3_reset(feed);
        sqlite3_bind_int64(one, 1, 1 + static_cast<int64_t>(rng() % kPosts));
        while (sqlite3_step(one) == SQLITE_ROW) sink += static_cast<uint64_t>(sqlite3_column_int64(one, 0)) + sqlite3_column_bytes(one, 1);
        sqlite3_reset(one);
        if (rng() % 100 < 15) {
            ensure_transaction();
            int64_t post = 1 + static_cast<int64_t>(rng() % (kPosts + 50));
            sqlite3_bind_int64(like, 1, 1 + static_cast<int64_t>(rng() % kUsers));
            sqlite3_bind_int64(like, 2, post);
            sqlite3_step(like);
            sqlite3_reset(like);
            if (sqlite3_changes(db) == 0) {
                sqlite3_bind_int64(exists, 1, post);
                sink += sqlite3_step(exists) == SQLITE_ROW;
                sqlite3_reset(exists);
            }
        }
        if (rng() % 100 < 2) {
            ensure_transaction();
            sqlite3_bind_int64(create, 1, 1 + static_cast<int64_t>(rng() % kUsers));
            sqlite3_bind_text(create, 2, body, -1, SQLITE_STATIC);
            while (sqlite3_step(create) == SQLITE_ROW) sink += static_cast<uint64_t>(sqlite3_column_int64(create, 0));
            sqlite3_reset(create);
        }
        if (i % 50 == 0) {
            sink += sqlite3_step(ping) == SQLITE_ROW;
            sqlite3_reset(ping);
        }
        if (in_transaction && i % 4 == 3) {
            sqlite3_step(commit);
            sqlite3_reset(commit);
            in_transaction = false;
        }
    }
    if (in_transaction) {
        sqlite3_step(commit);
        sqlite3_reset(commit);
    }
    for (sqlite3_stmt *s : {feed, one, like, exists, create, ping, begin, commit}) sqlite3_finalize(s);
    return sink;
}

}

int main(int argc, char **argv) {
    if (argc < 2) return 2;
    sqlite3_initialize();
    int iterations = argc > 2 ? std::atoi(argv[2]) : 60000;
    sqlite3 *db = nullptr;
    if (sqlite3_open_v2(argv[1], &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nullptr) != SQLITE_OK) return 1;
    exec(db, "PRAGMA locking_mode=EXCLUSIVE; PRAGMA busy_timeout=5000; PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA mmap_size=1073741824; PRAGMA cache_size=-65536; PRAGMA temp_store=MEMORY;");
    generate(db);
    uint64_t sink = workload(db, iterations);
    sqlite3_close(db);
    std::printf("trained on %d iterations (checksum %llu)\n", iterations, static_cast<unsigned long long>(sink));
    return 0;
}
