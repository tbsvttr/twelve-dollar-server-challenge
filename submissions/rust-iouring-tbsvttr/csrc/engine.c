#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "sqlite3.c"

#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

/* =========================================================================
 * 1. Shared Data Structures for Rust FFI
 * ========================================================================= */

#define TVCC_FEED_MAX_ROWS 20
#define TVCC_TEXT_POOL_CAP 24576

#define TVCC_CKPT_FRAMES 4096
#define TVCC_CKPT_FORCE  65536
#define TVCC_HOLD_MAX_MS 250
#define TVCC_CKPT_NICE   19

typedef struct TvccPostRow {
    int64_t id;
    uint32_t body_off;
    uint32_t body_len;
    uint32_t created_off;
    uint32_t created_len;
    uint32_t author_off;
    uint32_t author_len;
    int64_t like_count;
} TvccPostRow;

typedef struct TvccFeedResult {
    uint32_t count;
    uint32_t text_used;
    TvccPostRow rows[TVCC_FEED_MAX_ROWS];
    uint8_t text[TVCC_TEXT_POOL_CAP];
} TvccFeedResult;

typedef struct TvccSinglePostResult {
    int64_t id;
    uint32_t body_len;
    uint32_t created_len;
    uint32_t author_len;
    int64_t like_count;
    uint8_t body[2048];
    uint8_t created_at[64];
    uint8_t author[128];
} TvccSinglePostResult;

enum {
    CK_IDLE = 0,
    CK_BULK = 1,
    CK_BULK_DONE = 2,
    CK_TAIL = 3,
    CK_TAIL_DONE = 4,
    CK_STOP = 5,
};

typedef struct TvccDbEngine {
    sqlite3 *db;
    sqlite3 *ck_db;
    Btree *bt;

    Pgno root_users;
    Pgno root_posts;
    Pgno root_post_likes;
    Pgno root_posts_feed_idx;
    Pgno root_likes_post_idx;

    sqlite3_stmt *stmt_begin;
    sqlite3_stmt *stmt_commit;
    sqlite3_stmt *stmt_rollback;
    sqlite3_stmt *stmt_feed;
    sqlite3_stmt *stmt_get_post;
    sqlite3_stmt *stmt_insert_post;
    sqlite3_stmt *stmt_check_post;
    sqlite3_stmt *stmt_check_liked;
    sqlite3_stmt *stmt_insert_like;
    sqlite3_stmt *stmt_health;

    int read_tx_open;
    int batch_broken;
    int cur_pool_open;
    BtCursor *cur_feed;
    BtCursor *cur_posts;
    BtCursor *cur_users;
    BtCursor *cur_likes;
    KeyInfo *ki_feed;
    KeyInfo *ki_likes;
    UnpackedRecord *probe_feed;
    UnpackedRecord *probe_likes;
    Mem probe_mems[2];
    uint8_t scratch[4096];

    pthread_t ck_thread;
    int ck_thread_started;
    pthread_mutex_t ck_mu;
    pthread_cond_t ck_cv;
    int ck_state;
    int ck_full;
    int wal_frames;
    int writes_held;
    struct timespec hold_t0;
} TvccDbEngine;

/* =========================================================================
 * 2. Record Decoding & B-Tree Cursor Management
 * ========================================================================= */

static inline uint32_t tvcc_serial_byte_len(uint32_t st) {
    if (st >= 12) return (st - 12) >> 1;
    static const uint8_t kLens[12] = {0, 1, 2, 3, 4, 6, 8, 8, 0, 0, 0, 0};
    return kLens[st];
}

static inline int64_t tvcc_decode_be_int(const uint8_t *p, uint32_t st) {
    switch (st) {
        case 1:
            return (int8_t)p[0];
        case 2:
            return (int16_t)(((uint16_t)p[0] << 8) | p[1]);
        case 3: {
            int32_t v = ((int32_t)(int8_t)p[0] << 16) | ((int32_t)p[1] << 8) | (int32_t)p[2];
            return v;
        }
        case 4:
            return (int32_t)(((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
                             ((uint32_t)p[2] << 8) | (uint32_t)p[3]);
        case 5: {
            int64_t hi = (int16_t)(((uint16_t)p[0] << 8) | p[1]);
            uint64_t lo = ((uint64_t)p[2] << 24) | ((uint64_t)p[3] << 16) |
                          ((uint64_t)p[4] << 8) | (uint64_t)p[5];
            return (hi << 32) | (int64_t)lo;
        }
        case 6:
            return (int64_t)(((uint64_t)p[0] << 56) | ((uint64_t)p[1] << 48) |
                             ((uint64_t)p[2] << 40) | ((uint64_t)p[3] << 32) |
                             ((uint64_t)p[4] << 24) | ((uint64_t)p[5] << 16) |
                             ((uint64_t)p[6] << 8) | (uint64_t)p[7]);
        case 8:
            return 0;
        case 9:
            return 1;
        default:
            return 0;
    }
}

static inline const uint8_t *tvcc_fetch_record(TvccDbEngine *eng, BtCursor *cur, uint32_t *out_sz) {
    getCellInfo(cur);
    u32 total = cur->info.nPayload;
    *out_sz = total;
    if (cur->info.nLocal == total) {
        return cur->info.pPayload;
    }
    if (total == 0 || total > sizeof(eng->scratch)) {
        return NULL;
    }
    if (sqlite3BtreePayload(cur, 0, total, eng->scratch) != SQLITE_OK) {
        return NULL;
    }
    return eng->scratch;
}

static KeyInfo *tvcc_alloc_keyinfo(sqlite3 *db, int n_key_fields, const uint8_t *sort_orders) {
    size_t bytes = sizeof(KeyInfo) + (size_t)n_key_fields * sizeof(CollSeq *);
    KeyInfo *ki = (KeyInfo *)sqlite3DbMallocZero(db, (u64)bytes);
    if (!ki) return NULL;
    ki->db = db;
    ki->enc = ENC(db);
    ki->nKeyField = (u16)n_key_fields;
    ki->nAllField = (u16)(n_key_fields + 1);
    ki->nRef = 1;
    ki->aSortFlags = (u8 *)sqlite3DbMallocZero(db, (u64)(n_key_fields + 1));
    if (!ki->aSortFlags) {
        sqlite3DbFree(db, ki);
        return NULL;
    }
    for (int i = 0; i < n_key_fields; i++) {
        ki->aSortFlags[i] = sort_orders[i];
        ki->aColl[i] = db->pDfltColl;
    }
    return ki;
}

static void tvcc_close_cursors(TvccDbEngine *eng) {
    if (!eng->cur_pool_open) return;
    if (eng->cur_likes) sqlite3BtreeCloseCursor(eng->cur_likes);
    if (eng->cur_users) sqlite3BtreeCloseCursor(eng->cur_users);
    if (eng->cur_posts) sqlite3BtreeCloseCursor(eng->cur_posts);
    if (eng->cur_feed) sqlite3BtreeCloseCursor(eng->cur_feed);
    eng->cur_pool_open = 0;
}

static int tvcc_open_cursors(TvccDbEngine *eng) {
    if (eng->cur_pool_open) return SQLITE_OK;
    int sz = sqlite3BtreeCursorSize();
    if (!eng->cur_feed) {
        uint8_t *blk = (uint8_t *)sqlite3_malloc(sz * 4);
        if (!blk) return SQLITE_NOMEM;
        memset(blk, 0, (size_t)(sz * 4));
        eng->cur_feed = (BtCursor *)(blk + sz * 0);
        eng->cur_posts = (BtCursor *)(blk + sz * 1);
        eng->cur_users = (BtCursor *)(blk + sz * 2);
        eng->cur_likes = (BtCursor *)(blk + sz * 3);
    } else {
        sqlite3BtreeCursorZero(eng->cur_feed);
        sqlite3BtreeCursorZero(eng->cur_posts);
        sqlite3BtreeCursorZero(eng->cur_users);
        sqlite3BtreeCursorZero(eng->cur_likes);
    }

    int rc = sqlite3BtreeCursor(eng->bt, eng->root_posts_feed_idx, 0, eng->ki_feed, eng->cur_feed);
    if (rc != SQLITE_OK) return rc;
    rc = sqlite3BtreeCursor(eng->bt, eng->root_posts, 0, NULL, eng->cur_posts);
    if (rc != SQLITE_OK) {
        sqlite3BtreeCloseCursor(eng->cur_feed);
        return rc;
    }
    rc = sqlite3BtreeCursor(eng->bt, eng->root_users, 0, NULL, eng->cur_users);
    if (rc != SQLITE_OK) {
        sqlite3BtreeCloseCursor(eng->cur_posts);
        sqlite3BtreeCloseCursor(eng->cur_feed);
        return rc;
    }
    rc = sqlite3BtreeCursor(eng->bt, eng->root_likes_post_idx, 0, eng->ki_likes, eng->cur_likes);
    if (rc != SQLITE_OK) {
        sqlite3BtreeCloseCursor(eng->cur_users);
        sqlite3BtreeCloseCursor(eng->cur_posts);
        sqlite3BtreeCloseCursor(eng->cur_feed);
        return rc;
    }
    eng->cur_pool_open = 1;
    return SQLITE_OK;
}

static int tvcc_step_reset(sqlite3_stmt *s) {
    int rc = sqlite3_step(s);
    sqlite3_reset(s);
    return rc;
}

static int tvcc_begin_read_tx(TvccDbEngine *eng) {
    if (eng->batch_broken) {
        return SQLITE_ERROR;
    }
    if (eng->read_tx_open) {
        if (sqlite3_get_autocommit(eng->db)) {
            tvcc_close_cursors(eng);
            eng->read_tx_open = 0;
            eng->batch_broken = 1;
            return SQLITE_ERROR;
        }
        if (!eng->cur_pool_open) {
            int rc = tvcc_open_cursors(eng);
            if (rc != SQLITE_OK) {
                tvcc_step_reset(eng->stmt_rollback);
                eng->read_tx_open = 0;
                eng->batch_broken = 1;
                return rc;
            }
        }
        return SQLITE_OK;
    }

    if (tvcc_step_reset(eng->stmt_begin) != SQLITE_DONE) {
        return SQLITE_ERROR;
    }
    int rc = sqlite3BtreeBeginTrans(eng->bt, 0, 0);
    if (rc != SQLITE_OK) {
        tvcc_step_reset(eng->stmt_rollback);
        return rc;
    }
    rc = tvcc_open_cursors(eng);
    if (rc != SQLITE_OK) {
        tvcc_step_reset(eng->stmt_rollback);
        return rc;
    }
    eng->read_tx_open = 1;
    return SQLITE_OK;
}

int tvcc_db_commit_batch(TvccDbEngine *eng) {
    if (!eng) return -1;
    if (eng->batch_broken) {
        eng->batch_broken = 0;
        tvcc_close_cursors(eng);
        if (!sqlite3_get_autocommit(eng->db)) {
            tvcc_step_reset(eng->stmt_rollback);
        }
        return -1;
    }
    if (!eng->read_tx_open) return 0;
    eng->read_tx_open = 0;
    tvcc_close_cursors(eng);
    if (tvcc_step_reset(eng->stmt_commit) != SQLITE_DONE) {
        tvcc_step_reset(eng->stmt_rollback);
        return -1;
    }
    return 0;
}

void tvcc_db_end_read_batch(TvccDbEngine *eng) {
    (void)tvcc_db_commit_batch(eng);
}

/* =========================================================================
 * 5. Monotonic Root-Pinned Cursor Lookup for Users
 *    & Direct Leaf-Cell Scan for Likes Count
 * ========================================================================= */

static int tvcc_lookup_single_user(TvccDbEngine *eng, int64_t uid, uint8_t *dst, uint32_t cap, uint32_t *out_len) {
    int cmp = 0;
    if (sqlite3BtreeTableMoveto(eng->cur_users, uid, 0, &cmp) != SQLITE_OK ||
        cmp != 0 || eng->cur_users->eState != CURSOR_VALID) {
        return 0;
    }
    uint32_t rec_sz = 0;
    const uint8_t *rec = tvcc_fetch_record(eng, eng->cur_users, &rec_sz);
    if (!rec || rec_sz < 2) return 0;
    u32 hdr_sz = 0;
    int pos = getVarint32(rec, hdr_sz);
    u32 st_id = 0, st_u = 0;
    pos += getVarint32(rec + pos, st_id);
    pos += getVarint32(rec + pos, st_u);
    if (st_u < 13 || (st_u & 1) == 0) return 0;
    uint32_t id_len = tvcc_serial_byte_len(st_id);
    uint32_t ulen = (st_u - 13) >> 1;
    if (hdr_sz + id_len + ulen > rec_sz || ulen > cap) return 0;
    memcpy(dst, rec + hdr_sz + id_len, ulen);
    *out_len = ulen;
    return 1;
}

typedef struct TvccUserBatchItem {
    int64_t uid;
    Pgno pgno;
    uint32_t text_off;
    uint32_t text_len;
    int resolved;
} TvccUserBatchItem;

static int tvcc_batch_lookup_users(TvccDbEngine *eng, TvccUserBatchItem *items, int n_items,
                                   uint8_t *text_pool, uint32_t *text_used, uint32_t text_cap) {
    /* Sort unique user_ids ascending so cur_users walks B-tree leaves monotonically
     * while keeping root_users pinned in cur_users->apPage[0]. */
    for (int i = 1; i < n_items; i++) {
        TvccUserBatchItem key = items[i];
        int j = i - 1;
        while (j >= 0 && items[j].uid > key.uid) {
            items[j + 1] = items[j];
            j--;
        }
        items[j + 1] = key;
    }
    for (int i = 0; i < n_items; i++) {
        uint32_t ulen = 0;
        uint32_t rem = text_cap - *text_used;
        if (!tvcc_lookup_single_user(eng, items[i].uid, text_pool + *text_used, rem, &ulen)) {
            return 0;
        }
        items[i].text_off = *text_used;
        items[i].text_len = ulen;
        *text_used += ulen;
        items[i].resolved = 1;
    }
    return 1;
}

static int tvcc_count_likes_range(TvccDbEngine *eng, int64_t lo, int64_t hi, uint32_t *counts);

static int tvcc_count_likes(TvccDbEngine *eng, int64_t post_id, int64_t *out_count) {
    uint32_t fast_cnt = 0;
    if (tvcc_count_likes_range(eng, post_id, post_id, &fast_cnt)) {
        *out_count = (int64_t)fast_cnt;
        return 1;
    }
    eng->probe_mems[0].flags = MEM_Int;
    eng->probe_mems[0].u.i = post_id;
    eng->probe_likes->nField = 1;
    eng->probe_likes->default_rc = +1;

    int cmp = 0;
    int rc = sqlite3BtreeIndexMoveto(eng->cur_likes, eng->probe_likes, &cmp);
    if (rc != SQLITE_OK) return 0;
    if (sqlite3BtreeEof(eng->cur_likes)) {
        *out_count = 0;
        return 1;
    }
    if (cmp < 0) {
        rc = sqlite3BtreeNext(eng->cur_likes, 0);
        if (rc == SQLITE_DONE) {
            *out_count = 0;
            return 1;
        }
        if (rc != SQLITE_OK) return 0;
    }

    int64_t count = 0;
    for (;;) {
        uint32_t rec_sz = 0;
        const uint8_t *rec = tvcc_fetch_record(eng, eng->cur_likes, &rec_sz);
        if (!rec || rec_sz < 2) return 0;
        u32 hdr_sz = 0;
        int hvar = getVarint32(rec, hdr_sz);
        u32 st_pid = 0;
        getVarint32(rec + hvar, st_pid);
        uint32_t plen = tvcc_serial_byte_len(st_pid);
        if (hdr_sz + plen > rec_sz) return 0;
        int64_t cur_pid = tvcc_decode_be_int(rec + hdr_sz, st_pid);
        if (cur_pid != post_id) {
            *out_count = count;
            return 1;
        }
        count++;

        rc = sqlite3BtreeNext(eng->cur_likes, 0);
        if (rc == SQLITE_DONE) {
            *out_count = count;
            return 1;
        }
        if (rc != SQLITE_OK) return 0;
    }
}

#define TVCC_LIKE_RANGE_MAX 512

static int tvcc_count_likes_range(TvccDbEngine *eng, int64_t lo, int64_t hi, uint32_t *counts) {
    eng->probe_mems[0].flags = MEM_Int;
    eng->probe_mems[0].u.i = lo;
    eng->probe_likes->nField = 1;
    eng->probe_likes->default_rc = +1;

    int cmp = 0;
    int rc = sqlite3BtreeIndexMoveto(eng->cur_likes, eng->probe_likes, &cmp);
    if (rc != SQLITE_OK) return 0;
    if (sqlite3BtreeEof(eng->cur_likes)) return 1;
    if (cmp < 0) {
        rc = sqlite3BtreeNext(eng->cur_likes, 0);
        if (rc == SQLITE_DONE) return 1;
        if (rc != SQLITE_OK) return 0;
    }

    for (;;) {
        MemPage *pg = eng->cur_likes->pPage;
        int i = eng->cur_likes->ix;
        int last = pg->leaf ? pg->nCell : i + 1;
        for (; i < last; i++) {
            u8 *cell = findCell(pg, i) + pg->childPtrSize;
            u32 len = cell[0];
            const u8 *p = cell + 1;
            if (len >= 0x80 || len < 3 || p + len > pg->aDataEnd) {
                return 0; /* Fallback to single-post count */
            }
            u32 h = p[0], t = p[1];
            if (h >= len || h < 3 || t >= 0x80) {
                return 0;
            }
            uint32_t plen = tvcc_serial_byte_len(t);
            if (h + plen > len) return 0;
            int64_t cur_pid = tvcc_decode_be_int(p + h, t);
            if (cur_pid > hi) return 1;
            if (cur_pid >= lo) {
                counts[cur_pid - lo]++;
            }
        }
        eng->cur_likes->ix = (u16)(last - 1);
        rc = sqlite3BtreeNext(eng->cur_likes, 0);
        if (rc == SQLITE_DONE) return 1;
        if (rc != SQLITE_OK) return 0;
    }
}

static int tvcc_parse_post_record(const uint8_t *rec, uint32_t rec_sz, int64_t *out_uid,
                                  const uint8_t **out_body, uint32_t *out_body_len,
                                  const uint8_t **out_created, uint32_t *out_created_len) {
    if (!rec || rec_sz < 3) return 0;
    u32 hdr_sz = 0;
    int pos = getVarint32(rec, hdr_sz);
    if (hdr_sz > rec_sz) return 0;

    u32 st_id = 0, st_uid = 0, st_body = 0, st_created = 0;
    pos += getVarint32(rec + pos, st_id);
    pos += getVarint32(rec + pos, st_uid);
    pos += getVarint32(rec + pos, st_body);
    pos += getVarint32(rec + pos, st_created);

    if (st_body < 13 || (st_body & 1) == 0 || st_created < 13 || (st_created & 1) == 0) {
        return 0;
    }
    uint32_t id_len = tvcc_serial_byte_len(st_id);
    uint32_t uid_len = tvcc_serial_byte_len(st_uid);
    uint32_t body_len = (st_body - 13) >> 1;
    uint32_t created_len = (st_created - 13) >> 1;
    if (hdr_sz + id_len + uid_len + body_len + created_len > rec_sz) {
        return 0;
    }

    *out_uid = tvcc_decode_be_int(rec + hdr_sz + id_len, st_uid);
    *out_body = rec + hdr_sz + id_len + uid_len;
    *out_body_len = body_len;
    *out_created = rec + hdr_sz + id_len + uid_len + body_len;
    *out_created_len = created_len;
    return 1;
}

/* =========================================================================
 * 4. Two-Stage Condition-Variable Checkpoint Thread (nice 19, 250ms Hold Cap)
 * ========================================================================= */

static int tvcc_wal_hook(void *arg, sqlite3 *db, const char *zDb, int nFrame) {
    (void)db;
    (void)zDb;
    TvccDbEngine *eng = (TvccDbEngine *)arg;
    eng->wal_frames = nFrame;
    return SQLITE_OK;
}

static void tvcc_ck_set(TvccDbEngine *eng, int st) {
    pthread_mutex_lock(&eng->ck_mu);
    __atomic_store_n(&eng->ck_state, st, __ATOMIC_RELEASE);
    pthread_cond_signal(&eng->ck_cv);
    pthread_mutex_unlock(&eng->ck_mu);
}

static long tvcc_ms_since(const struct timespec *t0) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (t.tv_sec - t0->tv_sec) * 1000L + (t.tv_nsec - t0->tv_nsec) / 1000000L;
}

static void *tvcc_checkpoint_worker(void *arg) {
    TvccDbEngine *eng = (TvccDbEngine *)arg;
#ifdef __linux__
    setpriority(PRIO_PROCESS, (id_t)syscall(SYS_gettid), TVCC_CKPT_NICE);
#else
    int nice_rc = nice(TVCC_CKPT_NICE);
    (void)nice_rc;
#endif

    for (;;) {
        pthread_mutex_lock(&eng->ck_mu);
        while (eng->ck_state != CK_BULK && eng->ck_state != CK_TAIL && eng->ck_state != CK_STOP) {
            pthread_cond_wait(&eng->ck_cv, &eng->ck_mu);
        }
        int st = eng->ck_state;
        pthread_mutex_unlock(&eng->ck_mu);
        if (st == CK_STOP) {
            break;
        }

        int nlog = -1, ndone = -2;
        int rc = sqlite3_wal_checkpoint_v2(
            eng->ck_db, "main", SQLITE_CHECKPOINT_PASSIVE, &nlog, &ndone
        );
        pthread_mutex_lock(&eng->ck_mu);
        eng->ck_full = (rc == SQLITE_OK && nlog == ndone);
        if (eng->ck_state != CK_STOP) {
            __atomic_store_n(&eng->ck_state, st + 1, __ATOMIC_RELEASE);
        }
        pthread_mutex_unlock(&eng->ck_mu);
    }
    return NULL;
}

int tvcc_db_poll_checkpoint(TvccDbEngine *eng, int has_inflight_reads) {
    (void)has_inflight_reads;
    if (!eng) return 0;
    switch (__atomic_load_n(&eng->ck_state, __ATOMIC_ACQUIRE)) {
        case CK_IDLE:
            if (eng->wal_frames >= TVCC_CKPT_FORCE) {
                int nlog = 0, ndone = 0;
                if (sqlite3_wal_checkpoint_v2(
                        eng->db, "main", SQLITE_CHECKPOINT_PASSIVE, &nlog, &ndone
                    ) == SQLITE_OK && nlog == ndone) {
                    eng->wal_frames = 0;
                }
            } else if (eng->wal_frames >= TVCC_CKPT_FRAMES) {
                tvcc_ck_set(eng, CK_BULK);
            }
            break;
        case CK_BULK_DONE:
            eng->writes_held = 1;
            clock_gettime(CLOCK_MONOTONIC, &eng->hold_t0);
            tvcc_ck_set(eng, CK_TAIL);
            break;
        case CK_TAIL_DONE:
            if (eng->ck_full) {
                eng->wal_frames = 0;
            }
            eng->writes_held = 0;
            tvcc_ck_set(eng, CK_IDLE);
            break;
        default:
            if (eng->writes_held && tvcc_ms_since(&eng->hold_t0) > TVCC_HOLD_MAX_MS) {
                eng->writes_held = 0;
            }
            break;
    }
    return eng->writes_held;
}

/* =========================================================================
 * 5. Lifecycle: Open, Warm Cache, Close
 * ========================================================================= */

void tvcc_db_close(TvccDbEngine *eng);

static Pgno tvcc_query_rootpage(sqlite3 *db, const char *name) {
    sqlite3_stmt *st = NULL;
    Pgno root = 0;
    if (sqlite3_prepare_v2(db, "SELECT rootpage FROM sqlite_schema WHERE name = ?1", -1, &st, NULL) == SQLITE_OK) {
        sqlite3_bind_text(st, 1, name, -1, SQLITE_STATIC);
        if (sqlite3_step(st) == SQLITE_ROW) {
            root = (Pgno)sqlite3_column_int(st, 0);
        }
        sqlite3_finalize(st);
    }
    return root;
}

int tvcc_db_open(const char *path, TvccDbEngine **out_eng) {
    if (!path || !out_eng) return -1;
    *out_eng = NULL;

    if (sqlite3_initialize() != SQLITE_OK) {
        return -1;
    }

    TvccDbEngine *eng = (TvccDbEngine *)calloc(1, sizeof(TvccDbEngine));
    if (!eng) return -1;
    pthread_mutex_init(&eng->ck_mu, NULL);
    pthread_cond_init(&eng->ck_cv, NULL);

    const char *vfs_name = sqlite3_vfs_find("unix-excl") ? "unix-excl" : NULL;
    int flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX;
    if (sqlite3_open_v2(path, &eng->db, flags, vfs_name) != SQLITE_OK) {
        tvcc_db_close(eng);
        return -1;
    }

    const char *init_sql =
        "PRAGMA journal_mode = WAL;"
        "PRAGMA synchronous = NORMAL;"
        "PRAGMA cache_size = -65536;"
        "PRAGMA mmap_size = 0;"
        "PRAGMA temp_store = MEMORY;"
        "PRAGMA wal_autocheckpoint = 0;"
        "SELECT count(*) FROM sqlite_schema;";
    if (sqlite3_exec(eng->db, init_sql, NULL, NULL, NULL) != SQLITE_OK) {
        tvcc_db_close(eng);
        return -1;
    }
    sqlite3_wal_hook(eng->db, tvcc_wal_hook, eng);

    /* Warm SQLite page cache with hot interior and leaf pages */
    sqlite3_exec(
        eng->db,
        "SELECT count(*) FROM users;"
        "SELECT id, user_id, body, created_at FROM posts ORDER BY created_at DESC, id DESC LIMIT 20;",
        NULL, NULL, NULL
    );

    eng->bt = eng->db->aDb[0].pBt;
    eng->root_users = tvcc_query_rootpage(eng->db, "users");
    eng->root_posts = tvcc_query_rootpage(eng->db, "posts");
    eng->root_post_likes = tvcc_query_rootpage(eng->db, "likes");
    eng->root_posts_feed_idx = tvcc_query_rootpage(eng->db, "posts_created_at_id_idx");
    eng->root_likes_post_idx = tvcc_query_rootpage(eng->db, "likes_post_id_idx");

    if (!eng->bt || !eng->root_users || !eng->root_posts || !eng->root_posts_feed_idx || !eng->root_likes_post_idx) {
        tvcc_db_close(eng);
        return -1;
    }

    static const uint8_t kFeedSort[2] = {KEYINFO_ORDER_DESC, KEYINFO_ORDER_DESC};
    static const uint8_t kLikesSort[2] = {0, 0};
    eng->ki_feed = tvcc_alloc_keyinfo(eng->db, 2, kFeedSort);
    eng->ki_likes = tvcc_alloc_keyinfo(eng->db, 2, kLikesSort);
    eng->probe_feed = (UnpackedRecord *)sqlite3DbMallocZero(eng->db, sizeof(UnpackedRecord));
    eng->probe_likes = (UnpackedRecord *)sqlite3DbMallocZero(eng->db, sizeof(UnpackedRecord));
    if (!eng->ki_feed || !eng->ki_likes || !eng->probe_feed || !eng->probe_likes) {
        tvcc_db_close(eng);
        return -1;
    }
    eng->probe_feed->pKeyInfo = eng->ki_feed;
    eng->probe_feed->aMem = eng->probe_mems;
    eng->probe_likes->pKeyInfo = eng->ki_likes;
    eng->probe_likes->aMem = eng->probe_mems;

    unsigned int prep_flags = SQLITE_PREPARE_PERSISTENT;
    if (sqlite3_prepare_v3(eng->db, "BEGIN", -1, prep_flags, &eng->stmt_begin, NULL) != SQLITE_OK ||
        sqlite3_prepare_v3(eng->db, "COMMIT", -1, prep_flags, &eng->stmt_commit, NULL) != SQLITE_OK ||
        sqlite3_prepare_v3(eng->db, "ROLLBACK", -1, prep_flags, &eng->stmt_rollback, NULL) != SQLITE_OK) {
        tvcc_db_close(eng);
        return -1;
    }
    if (sqlite3_prepare_v3(
            eng->db,
            "SELECT p.id, p.body, p.created_at, u.username, "
            "(SELECT COUNT(*) FROM likes l WHERE l.post_id = p.id) "
            "FROM posts p JOIN users u ON u.id = p.user_id "
            "ORDER BY p.created_at DESC, p.id DESC LIMIT 20",
            -1, prep_flags, &eng->stmt_feed, NULL) != SQLITE_OK) {
        tvcc_db_close(eng);
        return -1;
    }
    if (sqlite3_prepare_v3(
            eng->db,
            "SELECT p.id, p.body, p.created_at, u.username, "
            "(SELECT COUNT(*) FROM likes l WHERE l.post_id = p.id) "
            "FROM posts p JOIN users u ON u.id = p.user_id WHERE p.id = ?1",
            -1, prep_flags, &eng->stmt_get_post, NULL) != SQLITE_OK) {
        tvcc_db_close(eng);
        return -1;
    }
    if (sqlite3_prepare_v3(
            eng->db,
            "INSERT INTO posts (user_id, body, created_at) VALUES (?1, ?2, ?3)",
            -1, prep_flags, &eng->stmt_insert_post, NULL) != SQLITE_OK) {
        tvcc_db_close(eng);
        return -1;
    }
    if (sqlite3_prepare_v3(
            eng->db,
            "SELECT 1 FROM posts WHERE id = ?1",
            -1, prep_flags, &eng->stmt_check_post, NULL) != SQLITE_OK) {
        tvcc_db_close(eng);
        return -1;
    }
    if (sqlite3_prepare_v3(
            eng->db,
            "SELECT 1 FROM likes WHERE post_id = ?1 AND user_id = ?2",
            -1, prep_flags, &eng->stmt_check_liked, NULL) != SQLITE_OK) {
        tvcc_db_close(eng);
        return -1;
    }
    if (sqlite3_prepare_v3(
            eng->db,
            "INSERT OR IGNORE INTO likes (post_id, user_id) VALUES (?1, ?2)",
            -1, prep_flags, &eng->stmt_insert_like, NULL) != SQLITE_OK) {
        tvcc_db_close(eng);
        return -1;
    }
    if (sqlite3_prepare_v3(
            eng->db, "SELECT 1", -1, prep_flags, &eng->stmt_health, NULL) != SQLITE_OK) {
        tvcc_db_close(eng);
        return -1;
    }

    if (sqlite3_open_v2(path, &eng->ck_db, flags, vfs_name) == SQLITE_OK) {
        sqlite3_exec(
            eng->ck_db,
            "PRAGMA synchronous = NORMAL;"
            "PRAGMA wal_autocheckpoint = 0;"
            "PRAGMA cache_size = 16;",
            NULL, NULL, NULL
        );
        pthread_attr_t attr;
        pthread_attr_init(&attr);
        pthread_attr_setstacksize(&attr, 256 << 10);
        if (pthread_create(&eng->ck_thread, &attr, tvcc_checkpoint_worker, eng) == 0) {
            eng->ck_thread_started = 1;
        }
        pthread_attr_destroy(&attr);
    }

    *out_eng = eng;
    return 0;
}

void tvcc_db_close(TvccDbEngine *eng) {
    if (!eng) return;
    if (eng->ck_thread_started) {
        tvcc_ck_set(eng, CK_STOP);
        pthread_join(eng->ck_thread, NULL);
        eng->ck_thread_started = 0;
    }
    pthread_cond_destroy(&eng->ck_cv);
    pthread_mutex_destroy(&eng->ck_mu);
    tvcc_db_end_read_batch(eng);
    if (eng->cur_feed) {
        sqlite3_free(eng->cur_feed);
        eng->cur_feed = NULL;
    }
    if (eng->stmt_begin) sqlite3_finalize(eng->stmt_begin);
    if (eng->stmt_commit) sqlite3_finalize(eng->stmt_commit);
    if (eng->stmt_rollback) sqlite3_finalize(eng->stmt_rollback);
    if (eng->stmt_feed) sqlite3_finalize(eng->stmt_feed);
    if (eng->stmt_get_post) sqlite3_finalize(eng->stmt_get_post);
    if (eng->stmt_insert_post) sqlite3_finalize(eng->stmt_insert_post);
    if (eng->stmt_check_post) sqlite3_finalize(eng->stmt_check_post);
    if (eng->stmt_check_liked) sqlite3_finalize(eng->stmt_check_liked);
    if (eng->stmt_insert_like) sqlite3_finalize(eng->stmt_insert_like);
    if (eng->stmt_health) sqlite3_finalize(eng->stmt_health);
    if (eng->db) {
        if (eng->probe_feed) sqlite3DbFree(eng->db, eng->probe_feed);
        if (eng->probe_likes) sqlite3DbFree(eng->db, eng->probe_likes);
        if (eng->ki_feed) {
            sqlite3DbFree(eng->db, eng->ki_feed->aSortFlags);
            sqlite3DbFree(eng->db, eng->ki_feed);
        }
        if (eng->ki_likes) {
            sqlite3DbFree(eng->db, eng->ki_likes->aSortFlags);
            sqlite3DbFree(eng->db, eng->ki_likes);
        }
        sqlite3_close(eng->db);
    }
    if (eng->ck_db) {
        sqlite3_close(eng->ck_db);
    }
    free(eng);
}

/* =========================================================================
 * 6. Public Query & Mutation Operations
 * ========================================================================= */

int tvcc_db_health(TvccDbEngine *eng) {
    if (!eng) return -1;
    if (tvcc_begin_read_tx(eng) == SQLITE_OK) {
        return 0;
    }
    sqlite3_reset(eng->stmt_health);
    int rc = sqlite3_step(eng->stmt_health);
    sqlite3_reset(eng->stmt_health);
    return rc == SQLITE_ROW ? 0 : -1;
}

static int tvcc_feed_sql_fallback(TvccDbEngine *eng, TvccFeedResult *out) {
    tvcc_db_end_read_batch(eng);
    sqlite3_reset(eng->stmt_feed);
    out->count = 0;
    out->text_used = 0;

    while (out->count < TVCC_FEED_MAX_ROWS) {
        int rc = sqlite3_step(eng->stmt_feed);
        if (rc == SQLITE_DONE) break;
        if (rc != SQLITE_ROW) {
            sqlite3_reset(eng->stmt_feed);
            return -1;
        }
        const uint8_t *body = sqlite3_column_text(eng->stmt_feed, 1);
        int body_len = sqlite3_column_bytes(eng->stmt_feed, 1);
        const uint8_t *created = sqlite3_column_text(eng->stmt_feed, 2);
        int created_len = sqlite3_column_bytes(eng->stmt_feed, 2);
        const uint8_t *author = sqlite3_column_text(eng->stmt_feed, 3);
        int author_len = sqlite3_column_bytes(eng->stmt_feed, 3);

        if (body_len < 0 || created_len < 0 || author_len < 0) {
            sqlite3_reset(eng->stmt_feed);
            return -1;
        }
        uint32_t need = (uint32_t)(body_len + created_len + author_len);
        if (out->text_used + need > TVCC_TEXT_POOL_CAP) {
            sqlite3_reset(eng->stmt_feed);
            return -1;
        }

        TvccPostRow *row = &out->rows[out->count];
        row->id = sqlite3_column_int64(eng->stmt_feed, 0);
        row->body_off = out->text_used;
        row->body_len = (uint32_t)body_len;
        memcpy(out->text + out->text_used, body, (size_t)body_len);
        out->text_used += (uint32_t)body_len;

        row->created_off = out->text_used;
        row->created_len = (uint32_t)created_len;
        memcpy(out->text + out->text_used, created, (size_t)created_len);
        out->text_used += (uint32_t)created_len;

        row->author_off = out->text_used;
        row->author_len = (uint32_t)author_len;
        memcpy(out->text + out->text_used, author, (size_t)author_len);
        out->text_used += (uint32_t)author_len;

        row->like_count = sqlite3_column_int64(eng->stmt_feed, 4);
        out->count++;
    }
    sqlite3_reset(eng->stmt_feed);
    return 0;
}

int tvcc_db_feed(TvccDbEngine *eng, TvccFeedResult *out) {
    if (!eng || !out) return -1;
    if (tvcc_begin_read_tx(eng) != SQLITE_OK) {
        return tvcc_feed_sql_fallback(eng, out);
    }

    out->count = 0;
    out->text_used = 0;

    int is_empty = 1;
    if (sqlite3BtreeFirst(eng->cur_feed, &is_empty) != SQLITE_OK) {
        return tvcc_feed_sql_fallback(eng, out);
    }
    if (is_empty) {
        return 0;
    }

    int64_t post_ids[TVCC_FEED_MAX_ROWS];
    uint32_t n_rows = 0;
    while (n_rows < TVCC_FEED_MAX_ROWS) {
        uint32_t rec_sz = 0;
        const uint8_t *rec = tvcc_fetch_record(eng, eng->cur_feed, &rec_sz);
        if (!rec || rec_sz < 2) {
            return tvcc_feed_sql_fallback(eng, out);
        }
        u32 hdr_sz = 0;
        int pos = getVarint32(rec, hdr_sz);
        u32 st_created = 0, st_id = 0;
        pos += getVarint32(rec + pos, st_created);
        pos += getVarint32(rec + pos, st_id);
        uint32_t clen = tvcc_serial_byte_len(st_created);
        uint32_t ilen = tvcc_serial_byte_len(st_id);
        if (hdr_sz + clen + ilen > rec_sz) {
            return tvcc_feed_sql_fallback(eng, out);
        }
        post_ids[n_rows] = tvcc_decode_be_int(rec + hdr_sz + clen, st_id);
        out->rows[n_rows].id = post_ids[n_rows];
        n_rows++;

        if (n_rows == TVCC_FEED_MAX_ROWS) break;
        int step_rc = sqlite3BtreeNext(eng->cur_feed, 0);
        if (step_rc == SQLITE_DONE) break;
        if (step_rc != SQLITE_OK) {
            return tvcc_feed_sql_fallback(eng, out);
        }
    }

    /* Sort (post_id, slot) ascending so posts & likes B-tree probes walk monotonically.
     * Newest-first is normally descending id, so reverse order is already ascending. */
    typedef struct {
        int64_t post_id;
        uint32_t slot;
    } TvccOrderPair;
    TvccOrderPair order[TVCC_FEED_MAX_ROWS];
    int sorted = 1;
    for (uint32_t i = 0; i < n_rows; i++) {
        uint32_t rev = n_rows - 1 - i;
        order[i].post_id = post_ids[rev];
        order[i].slot = rev;
        if (i > 0 && order[i - 1].post_id > order[i].post_id) {
            sorted = 0;
        }
    }
    if (!sorted) {
        for (uint32_t i = 1; i < n_rows; i++) {
            TvccOrderPair key = order[i];
            int j = (int)i - 1;
            while (j >= 0 && order[j].post_id > key.post_id) {
                order[j + 1] = order[j];
                j--;
            }
            order[j + 1] = key;
        }
    }

    int64_t slot_uids[TVCC_FEED_MAX_ROWS];
    TvccUserBatchItem uniq_users[TVCC_FEED_MAX_ROWS];
    int n_uniq_users = 0;

    for (uint32_t i = 0; i < n_rows; i++) {
        int64_t pid = order[i].post_id;
        uint32_t slot = order[i].slot;
        int moved = 0;
        if (i > 0 && pid == order[i - 1].post_id + 1 && eng->cur_posts->eState == CURSOR_VALID) {
            if (sqlite3BtreeNext(eng->cur_posts, 0) == SQLITE_OK &&
                eng->cur_posts->eState == CURSOR_VALID &&
                sqlite3BtreeIntegerKey(eng->cur_posts) == pid) {
                moved = 1;
            }
        }
        if (!moved) {
            int cmp = 0;
            if (sqlite3BtreeTableMoveto(eng->cur_posts, pid, 0, &cmp) != SQLITE_OK || cmp != 0) {
                return tvcc_feed_sql_fallback(eng, out);
            }
        }
        uint32_t rec_sz = 0;
        const uint8_t *rec = tvcc_fetch_record(eng, eng->cur_posts, &rec_sz);
        int64_t uid = 0;
        const uint8_t *bptr = NULL, *cptr = NULL;
        uint32_t blen = 0, clen = 0;
        if (!tvcc_parse_post_record(rec, rec_sz, &uid, &bptr, &blen, &cptr, &clen)) {
            return tvcc_feed_sql_fallback(eng, out);
        }
        if (out->text_used + blen + clen > TVCC_TEXT_POOL_CAP) {
            return tvcc_feed_sql_fallback(eng, out);
        }
        TvccPostRow *row = &out->rows[slot];
        row->body_off = out->text_used;
        row->body_len = blen;
        memcpy(out->text + out->text_used, bptr, blen);
        out->text_used += blen;

        row->created_off = out->text_used;
        row->created_len = clen;
        memcpy(out->text + out->text_used, cptr, clen);
        out->text_used += clen;

        slot_uids[slot] = uid;
        int found = 0;
        for (int u = 0; u < n_uniq_users; u++) {
            if (uniq_users[u].uid == uid) {
                found = 1;
                break;
            }
        }
        if (!found) {
            uniq_users[n_uniq_users].uid = uid;
            n_uniq_users++;
        }
    }

    if (!tvcc_batch_lookup_users(eng, uniq_users, n_uniq_users, out->text, &out->text_used, TVCC_TEXT_POOL_CAP)) {
        return tvcc_feed_sql_fallback(eng, out);
    }

    for (uint32_t slot = 0; slot < n_rows; slot++) {
        int64_t uid = slot_uids[slot];
        for (int u = 0; u < n_uniq_users; u++) {
            if (uniq_users[u].uid == uid) {
                out->rows[slot].author_off = uniq_users[u].text_off;
                out->rows[slot].author_len = uniq_users[u].text_len;
                break;
            }
        }
    }

    if (n_rows > 0) {
        int64_t lo = order[0].post_id;
        int64_t hi = order[n_rows - 1].post_id;
        int range_ok = 0;
        if (hi >= lo && (hi - lo) <= TVCC_LIKE_RANGE_MAX) {
            uint32_t counts[TVCC_LIKE_RANGE_MAX + 1];
            memset(counts, 0, (size_t)(hi - lo + 1) * sizeof(uint32_t));
            if (tvcc_count_likes_range(eng, lo, hi, counts)) {
                for (uint32_t i = 0; i < n_rows; i++) {
                    out->rows[order[i].slot].like_count = (int64_t)counts[order[i].post_id - lo];
                }
                range_ok = 1;
            }
        }
        if (!range_ok) {
            for (uint32_t i = 0; i < n_rows; i++) {
                int64_t likes = 0;
                if (!tvcc_count_likes(eng, order[i].post_id, &likes)) {
                    return tvcc_feed_sql_fallback(eng, out);
                }
                out->rows[order[i].slot].like_count = likes;
            }
        }
    }

    out->count = n_rows;
    return 0;
}

static int tvcc_get_post_sql_fallback(TvccDbEngine *eng, int64_t post_id, TvccSinglePostResult *out) {
    tvcc_db_end_read_batch(eng);
    sqlite3_reset(eng->stmt_get_post);
    sqlite3_bind_int64(eng->stmt_get_post, 1, post_id);
    int rc = sqlite3_step(eng->stmt_get_post);
    if (rc == SQLITE_DONE) {
        sqlite3_reset(eng->stmt_get_post);
        return 0;
    }
    if (rc != SQLITE_ROW) {
        sqlite3_reset(eng->stmt_get_post);
        return -1;
    }
    const uint8_t *body = sqlite3_column_text(eng->stmt_get_post, 1);
    int body_len = sqlite3_column_bytes(eng->stmt_get_post, 1);
    const uint8_t *created = sqlite3_column_text(eng->stmt_get_post, 2);
    int created_len = sqlite3_column_bytes(eng->stmt_get_post, 2);
    const uint8_t *author = sqlite3_column_text(eng->stmt_get_post, 3);
    int author_len = sqlite3_column_bytes(eng->stmt_get_post, 3);
    if (body_len < 0 || (size_t)body_len > sizeof(out->body) ||
        created_len < 0 || (size_t)created_len > sizeof(out->created_at) ||
        author_len < 0 || (size_t)author_len > sizeof(out->author)) {
        sqlite3_reset(eng->stmt_get_post);
        return -1;
    }
    out->id = sqlite3_column_int64(eng->stmt_get_post, 0);
    out->body_len = (uint32_t)body_len;
    memcpy(out->body, body, (size_t)body_len);
    out->created_len = (uint32_t)created_len;
    memcpy(out->created_at, created, (size_t)created_len);
    out->author_len = (uint32_t)author_len;
    memcpy(out->author, author, (size_t)author_len);
    out->like_count = sqlite3_column_int64(eng->stmt_get_post, 4);
    sqlite3_reset(eng->stmt_get_post);
    return 1;
}

int tvcc_db_get_post(TvccDbEngine *eng, int64_t post_id, TvccSinglePostResult *out) {
    if (!eng || !out) return -1;
    if (tvcc_begin_read_tx(eng) != SQLITE_OK) {
        return tvcc_get_post_sql_fallback(eng, post_id, out);
    }

    int cmp = 0;
    if (sqlite3BtreeTableMoveto(eng->cur_posts, post_id, 0, &cmp) != SQLITE_OK) {
        return tvcc_get_post_sql_fallback(eng, post_id, out);
    }
    if (cmp != 0) {
        return 0;
    }

    uint32_t rec_sz = 0;
    const uint8_t *rec = tvcc_fetch_record(eng, eng->cur_posts, &rec_sz);
    int64_t uid = 0;
    const uint8_t *bptr = NULL, *cptr = NULL;
    uint32_t blen = 0, clen = 0;
    if (!tvcc_parse_post_record(rec, rec_sz, &uid, &bptr, &blen, &cptr, &clen) ||
        blen > sizeof(out->body) || clen > sizeof(out->created_at)) {
        return tvcc_get_post_sql_fallback(eng, post_id, out);
    }

    out->id = post_id;
    out->body_len = blen;
    memcpy(out->body, bptr, blen);
    out->created_len = clen;
    memcpy(out->created_at, cptr, clen);

    uint32_t ulen = 0;
    if (!tvcc_lookup_single_user(eng, uid, out->author, sizeof(out->author), &ulen)) {
        return tvcc_get_post_sql_fallback(eng, post_id, out);
    }
    out->author_len = ulen;

    int64_t likes = 0;
    if (!tvcc_count_likes(eng, post_id, &likes)) {
        return tvcc_get_post_sql_fallback(eng, post_id, out);
    }
    out->like_count = likes;
    return 1;
}

int tvcc_db_insert_post(TvccDbEngine *eng, int64_t user_id, const uint8_t *body, size_t body_len,
                        const uint8_t *created_at, size_t created_len, int64_t *out_post_id) {
    if (!eng || !body || !created_at || !out_post_id) return -1;
    if (tvcc_begin_read_tx(eng) != SQLITE_OK) return -1;

    sqlite3_reset(eng->stmt_insert_post);
    sqlite3_bind_int64(eng->stmt_insert_post, 1, user_id);
    sqlite3_bind_text(eng->stmt_insert_post, 2, (const char *)body, (int)body_len, SQLITE_STATIC);
    sqlite3_bind_text(eng->stmt_insert_post, 3, (const char *)created_at, (int)created_len, SQLITE_STATIC);

    int rc = sqlite3_step(eng->stmt_insert_post);
    sqlite3_reset(eng->stmt_insert_post);
    if (rc != SQLITE_DONE) {
        if (sqlite3_get_autocommit(eng->db)) {
            tvcc_close_cursors(eng);
            eng->read_tx_open = 0;
            eng->batch_broken = 1;
        }
        return -1;
    }

    *out_post_id = sqlite3_last_insert_rowid(eng->db);
    return 0;
}

/* Returns:
 *   1 -> newly liked (201)
 *   0 -> already liked (200)
 *  -2 -> post not found (404)
 *  -1 -> error (500)
 */
int tvcc_db_like_post(TvccDbEngine *eng, int64_t post_id, int64_t user_id) {
    if (!eng) return -1;
    if (tvcc_begin_read_tx(eng) != SQLITE_OK) return -1;

    int cmp = 0;
    if (sqlite3BtreeTableMoveto(eng->cur_posts, post_id, 0, &cmp) != SQLITE_OK) {
        return -1;
    }
    if (cmp != 0 || eng->cur_posts->eState != CURSOR_VALID) {
        return -2;
    }

    sqlite3_reset(eng->stmt_insert_like);
    sqlite3_bind_int64(eng->stmt_insert_like, 1, post_id);
    sqlite3_bind_int64(eng->stmt_insert_like, 2, user_id);
    int rc = sqlite3_step(eng->stmt_insert_like);
    sqlite3_reset(eng->stmt_insert_like);
    if (rc != SQLITE_DONE) {
        if (sqlite3_get_autocommit(eng->db)) {
            tvcc_close_cursors(eng);
            eng->read_tx_open = 0;
            eng->batch_broken = 1;
        }
        return -1;
    }

    int changed = sqlite3_changes(eng->db);
    if (changed > 0) {
        return 1;
    }
    return 0;
}
