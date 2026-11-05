#ifndef DB_H
#define DB_H

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "sqlite3.h"
#include "http.h"

typedef struct {
    sqlite3 *db;
    sqlite3_stmt *stmt_feed;
    sqlite3_stmt *stmt_post;
    sqlite3_stmt *stmt_post_exists;
    sqlite3_stmt *stmt_post_create;
    sqlite3_stmt *stmt_like;
    sqlite3_stmt *stmt_health;
    sqlite3_stmt *stmt_begin;
    sqlite3_stmt *stmt_commit;
    sqlite3_stmt *stmt_read_begin;
    sqlite3_stmt *stmt_read_commit;
} db_ctx_t;

static db_ctx_t g_db_ctx;

static inline int db_init(const char *path) {
    if (sqlite3_open_v2(path, &g_db_ctx.db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, NULL) != SQLITE_OK) {
        return -1;
    }

    // Modern SQLite Pragmas: 8MB page cache, 0 mmap (low RAM footprint & fast WAL lookups)
    sqlite3_exec(g_db_ctx.db, "PRAGMA journal_mode = WAL;", NULL, NULL, NULL);
    sqlite3_exec(g_db_ctx.db, "PRAGMA synchronous = NORMAL;", NULL, NULL, NULL);
    sqlite3_exec(g_db_ctx.db, "PRAGMA mmap_size = 0;", NULL, NULL, NULL);
    sqlite3_exec(g_db_ctx.db, "PRAGMA cache_size = -8192;", NULL, NULL, NULL);   // 8MB cache
    sqlite3_exec(g_db_ctx.db, "PRAGMA temp_store = MEMORY;", NULL, NULL, NULL);
    sqlite3_exec(g_db_ctx.db, "PRAGMA journal_size_limit = 67108864;", NULL, NULL, NULL);
    sqlite3_exec(g_db_ctx.db, "PRAGMA wal_autocheckpoint = 1000;", NULL, NULL, NULL);
    sqlite3_exec(g_db_ctx.db, "PRAGMA busy_timeout = 5000;", NULL, NULL, NULL);

    // Prepare persistent statements
    const char *sql_feed = "SELECT p.id, p.body, p.created_at, u.username, "
                           "(SELECT count(*) FROM likes l WHERE l.post_id = p.id) "
                           "FROM posts p JOIN users u ON u.id = p.user_id "
                           "ORDER BY p.created_at DESC, p.id DESC LIMIT 20;";
    if (sqlite3_prepare_v3(g_db_ctx.db, sql_feed, -1, SQLITE_PREPARE_PERSISTENT, &g_db_ctx.stmt_feed, NULL) != SQLITE_OK) return -1;

    const char *sql_post = "SELECT p.id, p.body, p.created_at, u.username, "
                           "(SELECT count(*) FROM likes l WHERE l.post_id = p.id) "
                           "FROM posts p JOIN users u ON u.id = p.user_id WHERE p.id = ?;";
    if (sqlite3_prepare_v3(g_db_ctx.db, sql_post, -1, SQLITE_PREPARE_PERSISTENT, &g_db_ctx.stmt_post, NULL) != SQLITE_OK) return -1;

    const char *sql_exists = "SELECT 1 FROM posts WHERE id = ?;";
    if (sqlite3_prepare_v3(g_db_ctx.db, sql_exists, -1, SQLITE_PREPARE_PERSISTENT, &g_db_ctx.stmt_post_exists, NULL) != SQLITE_OK) return -1;

    const char *sql_create = "INSERT INTO posts (user_id, body) VALUES (?, ?) RETURNING id, created_at;";
    if (sqlite3_prepare_v3(g_db_ctx.db, sql_create, -1, SQLITE_PREPARE_PERSISTENT, &g_db_ctx.stmt_post_create, NULL) != SQLITE_OK) return -1;

    const char *sql_like = "INSERT INTO likes (user_id, post_id) VALUES (?, ?) ON CONFLICT (user_id, post_id) DO NOTHING;";
    if (sqlite3_prepare_v3(g_db_ctx.db, sql_like, -1, SQLITE_PREPARE_PERSISTENT, &g_db_ctx.stmt_like, NULL) != SQLITE_OK) return -1;

    const char *sql_health = "SELECT 1;";
    if (sqlite3_prepare_v3(g_db_ctx.db, sql_health, -1, SQLITE_PREPARE_PERSISTENT, &g_db_ctx.stmt_health, NULL) != SQLITE_OK) return -1;

    const char *sql_begin = "BEGIN IMMEDIATE;";
    if (sqlite3_prepare_v3(g_db_ctx.db, sql_begin, -1, SQLITE_PREPARE_PERSISTENT, &g_db_ctx.stmt_begin, NULL) != SQLITE_OK) return -1;

    const char *sql_commit = "COMMIT;";
    if (sqlite3_prepare_v3(g_db_ctx.db, sql_commit, -1, SQLITE_PREPARE_PERSISTENT, &g_db_ctx.stmt_commit, NULL) != SQLITE_OK) return -1;

    const char *sql_read_begin = "BEGIN;";
    if (sqlite3_prepare_v3(g_db_ctx.db, sql_read_begin, -1, SQLITE_PREPARE_PERSISTENT, &g_db_ctx.stmt_read_begin, NULL) != SQLITE_OK) return -1;

    const char *sql_read_commit = "COMMIT;";
    if (sqlite3_prepare_v3(g_db_ctx.db, sql_read_commit, -1, SQLITE_PREPARE_PERSISTENT, &g_db_ctx.stmt_read_commit, NULL) != SQLITE_OK) return -1;

    return 0;
}

static inline void db_begin() {
    sqlite3_step(g_db_ctx.stmt_begin);
    sqlite3_reset(g_db_ctx.stmt_begin);
}

static inline void db_commit() {
    sqlite3_step(g_db_ctx.stmt_commit);
    sqlite3_reset(g_db_ctx.stmt_commit);
}

static inline void db_begin_read() {
    sqlite3_step(g_db_ctx.stmt_read_begin);
    sqlite3_reset(g_db_ctx.stmt_read_begin);
}

static inline void db_commit_read() {
    sqlite3_step(g_db_ctx.stmt_read_commit);
    sqlite3_reset(g_db_ctx.stmt_read_commit);
}

static inline int db_check_post_exists(int64_t post_id) {
    sqlite3_bind_int64(g_db_ctx.stmt_post_exists, 1, post_id);
    int rc = sqlite3_step(g_db_ctx.stmt_post_exists);
    sqlite3_reset(g_db_ctx.stmt_post_exists);
    sqlite3_clear_bindings(g_db_ctx.stmt_post_exists);
    return (rc == SQLITE_ROW);
}

#ifndef USE_FAST_SERIALIZE
#define USE_FAST_SERIALIZE 1
#endif

/* Fast integer-to-string formatters for zero-strlen serialization */
static inline char *fast_u64toa(uint64_t v, char *p) {
    char temp[24];
    int i = 0;
    if (v == 0) { *p++ = '0'; return p; }
    while (v > 0) {
        temp[i++] = (char)('0' + (v % 10));
        v /= 10;
    }
    while (i > 0) {
        *p++ = temp[--i];
    }
    return p;
}

static inline char *fast_i64toa(int64_t v, char *p) {
    if (v < 0) {
        *p++ = '-';
        v = -v;
    }
    return fast_u64toa((uint64_t)v, p);
}

static inline size_t db_query_feed(char *out, size_t cap) {
#if USE_FAST_SERIALIZE
    if (cap < 16) return 0;
    char *p = out;
    memcpy(p, "{\"posts\":[", 10); p += 10;

    int first = 1;
    char esc_body[3584];
    while (sqlite3_step(g_db_ctx.stmt_feed) == SQLITE_ROW) {
        int64_t id = sqlite3_column_int64(g_db_ctx.stmt_feed, 0);
        const char *body = (const char*)sqlite3_column_text(g_db_ctx.stmt_feed, 1);
        int body_bytes = sqlite3_column_bytes(g_db_ctx.stmt_feed, 1);
        const char *created_at = (const char*)sqlite3_column_text(g_db_ctx.stmt_feed, 2);
        const char *author = (const char*)sqlite3_column_text(g_db_ctx.stmt_feed, 3);
        int author_bytes = sqlite3_column_bytes(g_db_ctx.stmt_feed, 3);
        int64_t likes = sqlite3_column_int64(g_db_ctx.stmt_feed, 4);

        size_t esc_len = json_escape_string(body, (size_t)body_bytes, esc_body, sizeof(esc_body));

        // Ensure post fits within cap before writing
        if ((size_t)(p - out) + esc_len + (size_t)author_bytes + 140 >= cap) {
            break;
        }

        if (!first) *p++ = ',';
        first = 0;

        memcpy(p, "{\"id\":", 6); p += 6;
        p = fast_i64toa(id, p);
        memcpy(p, ",\"body\":\"", 9); p += 9;
        memcpy(p, esc_body, esc_len); p += esc_len;
        memcpy(p, "\",\"created_at\":\"", 16); p += 16;
        memcpy(p, created_at, 24); p += 24;
        memcpy(p, "\",\"author\":\"", 12); p += 12;
        memcpy(p, author, (size_t)author_bytes); p += author_bytes;
        memcpy(p, "\",\"like_count\":", 15); p += 15;
        p = fast_i64toa(likes, p);
        *p++ = '}';
    }
    sqlite3_reset(g_db_ctx.stmt_feed);

    *p++ = ']';
    *p++ = '}';
    return (size_t)(p - out);
#else
    size_t o = 0;
    o += snprintf(out + o, cap - o, "{\"posts\":[");

    int first = 1;
    char esc_body[3584];
    while (sqlite3_step(g_db_ctx.stmt_feed) == SQLITE_ROW) {
        if (!first && o < cap) out[o++] = ',';
        first = 0;

        int64_t id = sqlite3_column_int64(g_db_ctx.stmt_feed, 0);
        const char *body = (const char*)sqlite3_column_text(g_db_ctx.stmt_feed, 1);
        int body_bytes = sqlite3_column_bytes(g_db_ctx.stmt_feed, 1);
        const char *created_at = (const char*)sqlite3_column_text(g_db_ctx.stmt_feed, 2);
        const char *author = (const char*)sqlite3_column_text(g_db_ctx.stmt_feed, 3);
        int64_t likes = sqlite3_column_int64(g_db_ctx.stmt_feed, 4);

        size_t esc_len = json_escape_string(body, (size_t)body_bytes, esc_body, sizeof(esc_body));
        esc_body[esc_len] = '\0';

        o += snprintf(out + o, cap - o,
            "{\"id\":%lld,\"body\":\"%s\",\"created_at\":\"%s\",\"author\":\"%s\",\"like_count\":%lld}",
            (long long)id, esc_body, created_at, author, (long long)likes);
    }
    sqlite3_reset(g_db_ctx.stmt_feed);

    if (o < cap) out[o++] = ']';
    if (o < cap) out[o++] = '}';
    return o;
#endif
}

static inline int db_query_post(int64_t post_id, char *out, size_t cap, size_t *out_len) {
    sqlite3_bind_int64(g_db_ctx.stmt_post, 1, post_id);
    int rc = sqlite3_step(g_db_ctx.stmt_post);
    if (rc != SQLITE_ROW) {
        sqlite3_reset(g_db_ctx.stmt_post);
        sqlite3_clear_bindings(g_db_ctx.stmt_post);
        return 0; // Not found
    }

    int64_t id = sqlite3_column_int64(g_db_ctx.stmt_post, 0);
    const char *body = (const char*)sqlite3_column_text(g_db_ctx.stmt_post, 1);
    int body_bytes = sqlite3_column_bytes(g_db_ctx.stmt_post, 1);
    const char *created_at = (const char*)sqlite3_column_text(g_db_ctx.stmt_post, 2);
    const char *author = (const char*)sqlite3_column_text(g_db_ctx.stmt_post, 3);
    int author_bytes = sqlite3_column_bytes(g_db_ctx.stmt_post, 3);
    int64_t likes = sqlite3_column_int64(g_db_ctx.stmt_post, 4);

    char esc_body[3584];
    size_t esc_len = json_escape_string(body, (size_t)body_bytes, esc_body, sizeof(esc_body));

#if USE_FAST_SERIALIZE
    if (esc_len + (size_t)author_bytes + 140 >= cap) {
        sqlite3_reset(g_db_ctx.stmt_post);
        sqlite3_clear_bindings(g_db_ctx.stmt_post);
        return 0;
    }
    char *p = out;
    memcpy(p, "{\"post\":{\"id\":", 14); p += 14;
    p = fast_i64toa(id, p);
    memcpy(p, ",\"body\":\"", 9); p += 9;
    memcpy(p, esc_body, esc_len); p += esc_len;
    memcpy(p, "\",\"created_at\":\"", 16); p += 16;
    memcpy(p, created_at, 24); p += 24;
    memcpy(p, "\",\"author\":\"", 12); p += 12;
    memcpy(p, author, (size_t)author_bytes); p += author_bytes;
    memcpy(p, "\",\"like_count\":", 15); p += 15;
    p = fast_i64toa(likes, p);
    *p++ = '}';
    *p++ = '}';
    *out_len = (size_t)(p - out);
    sqlite3_reset(g_db_ctx.stmt_post);
    sqlite3_clear_bindings(g_db_ctx.stmt_post);
    return 1;
#else
    esc_body[esc_len] = '\0';
    int written = snprintf(out, cap,
        "{\"post\":{\"id\":%lld,\"body\":\"%s\",\"created_at\":\"%s\",\"author\":\"%s\",\"like_count\":%lld}}",
        (long long)id, esc_body, created_at, author, (long long)likes);

    sqlite3_reset(g_db_ctx.stmt_post);
    sqlite3_clear_bindings(g_db_ctx.stmt_post);

    if (written < 0 || (size_t)written >= cap) return 0;
    *out_len = (size_t)written;
    return 1;
#endif
}

static inline int db_create_post(int64_t user_id, const char *body, size_t body_len,
                                 const char *author, char *out, size_t cap, size_t *out_len) {
    sqlite3_bind_int64(g_db_ctx.stmt_post_create, 1, user_id);
    sqlite3_bind_text(g_db_ctx.stmt_post_create, 2, body, (int)body_len, SQLITE_STATIC);

    int rc = sqlite3_step(g_db_ctx.stmt_post_create);
    if (rc != SQLITE_ROW) {
        sqlite3_reset(g_db_ctx.stmt_post_create);
        sqlite3_clear_bindings(g_db_ctx.stmt_post_create);
        return 0;
    }

    int64_t new_id = sqlite3_column_int64(g_db_ctx.stmt_post_create, 0);
    const char *created_at = (const char*)sqlite3_column_text(g_db_ctx.stmt_post_create, 1);

    char esc_body[3584];
    size_t esc_len = json_escape_string(body, body_len, esc_body, sizeof(esc_body));
    esc_body[esc_len] = '\0';

    int written = snprintf(out, cap,
        "{\"post\":{\"id\":%lld,\"body\":\"%s\",\"created_at\":\"%s\",\"author\":\"%s\",\"like_count\":0}}",
        (long long)new_id, esc_body, created_at, author);

    sqlite3_reset(g_db_ctx.stmt_post_create);
    sqlite3_clear_bindings(g_db_ctx.stmt_post_create);

    if (written < 0 || (size_t)written >= cap) return 0;
    *out_len = (size_t)written;
    return 1;
}

static inline int db_like_post(int64_t user_id, int64_t post_id, int *already_liked,
                               char *out, size_t cap, size_t *out_len) {
    if (!db_check_post_exists(post_id)) {
        return -1; // Post not found
    }

    sqlite3_bind_int64(g_db_ctx.stmt_like, 1, user_id);
    sqlite3_bind_int64(g_db_ctx.stmt_like, 2, post_id);
    sqlite3_step(g_db_ctx.stmt_like);

    int changes = sqlite3_changes(g_db_ctx.db);
    sqlite3_reset(g_db_ctx.stmt_like);
    sqlite3_clear_bindings(g_db_ctx.stmt_like);

    *already_liked = (changes == 0) ? 1 : 0;
    const char *already_liked_str = (*already_liked) ? "true" : "false";

    int written = snprintf(out, cap,
        "{\"liked\":true,\"already_liked\":%s,\"post_id\":%lld}",
        already_liked_str, (long long)post_id);

    if (written < 0 || (size_t)written >= cap) return -2;
    *out_len = (size_t)written;
    return 0;
}

static inline size_t db_health(char *out, size_t cap, int64_t uptime_s) {
    int rc = sqlite3_step(g_db_ctx.stmt_health);
    sqlite3_reset(g_db_ctx.stmt_health);
    if (rc == SQLITE_ROW) {
        return snprintf(out, cap, "{\"status\":\"ok\",\"db\":\"ok\",\"uptime_s\":%lld}", (long long)uptime_s);
    }
    return snprintf(out, cap, "{\"status\":\"degraded\",\"db\":\"unreachable\",\"error\":\"db check failed\"}");
}

#endif
