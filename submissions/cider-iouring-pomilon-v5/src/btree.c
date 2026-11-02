/*
 * Native B-tree read plans for the Cider server.
 *
 * This file is compiled in the same translation unit as the pinned SQLite
 * amalgamation.  The pager, WAL, locking and page cache are SQLite's; only
 * the VDBE is skipped for the two read plans below.  Writes stay on Cider's
 * ordinary SQL prepared statements.
 *
 * The plans are:
 *   - GET /feed : last 20 posts in rowid order + one likes_post_id_idx scan
 *   - GET /posts/:id : rowid seek + one likes_post_id_idx point lookup
 * Users are looked up by rowid.  Both plans rely on the challenge schema and
 * on posts being append-only (ids dense, created_at nondecreasing in rowid
 * order), which is true for the seed and for this server's inserts.
 */

#define _GNU_SOURCE
#include "../vendor/sqlite-amalgamation-3540100/sqlite3.c"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* BufWriterC layout used by fast.c. */
typedef struct {
    char *buf;
    int len;
    int cap;
} BufWriterB;

extern void fast_append_i64(void *writer, long long value);
extern void fast_append_json_string(void *writer, const char *s, int slen);

typedef struct {
    BtCursor *c;
    u8 *spill;
    u32 spill_cap;
} BtCur;

typedef struct {
    const u8 *p;
    u32 n;
} Rec;

typedef struct {
    u64 t;
    const u8 *p;
} Col;

static sqlite3 *bt_db;
static Btree *bt_bt;
static Pgno bt_posts;
static Pgno bt_users;
static Pgno bt_likes_idx;
static KeyInfo *bt_likes_ki;
static BtCur bt_posts_cur;
static BtCur bt_users_cur;
static BtCur bt_likes_cur;
static int bt_open;

static int bw_put(BufWriterB *w, const char *s, int n) {
    if (n <= 0) {
        return 1;
    }
    if (w->len + n >= w->cap) {
        return 0;
    }
    memcpy(w->buf + w->len, s, (size_t)n);
    w->len += n;
    return 1;
}

static int bw_jstr(BufWriterB *w, const u8 *s, u32 n) {
    int before = w->len;
    fast_append_json_string(w, (const char *)s, (int)n);
    return w->len > before;
}

static int bw_i64(BufWriterB *w, i64 v) {
    int before = w->len;
    fast_append_i64(w, (long long)v);
    return w->len > before;
}

static Pgno bt_rootpage(const char *name) {
    sqlite3_stmt *s = 0;
    if (sqlite3_prepare_v2(bt_db,
            "SELECT rootpage FROM sqlite_schema WHERE name = ?1",
            -1, &s, 0) != SQLITE_OK) {
        return 0;
    }
    sqlite3_bind_text(s, 1, name, -1, SQLITE_STATIC);
    Pgno r = 0;
    if (sqlite3_step(s) == SQLITE_ROW) {
        r = (Pgno)sqlite3_column_int64(s, 0);
    }
    sqlite3_finalize(s);
    return r;
}

static int bt_cursor_open(BtCur *c, Pgno root, KeyInfo *ki) {
    memset(c, 0, sizeof(*c));
    c->c = (BtCursor *)malloc((size_t)sqlite3BtreeCursorSize());
    if (!c->c) {
        return -1;
    }
    sqlite3BtreeCursorZero(c->c);
    if (sqlite3BtreeCursor(bt_bt, root, 0, ki, c->c) != SQLITE_OK) {
        free(c->c);
        c->c = 0;
        return -1;
    }
    return 0;
}

static void bt_cursor_close(BtCur *c) {
    if (c->c) {
        sqlite3BtreeCloseCursor(c->c);
        free(c->c);
        c->c = 0;
    }
    free(c->spill);
    c->spill = 0;
    c->spill_cap = 0;
}

/* Called by Cider after it has opened a SQL BEGIN for the batch. */
static int bt_begin_batch(void) {
    if (bt_open) {
        return 0;
    }
    if (!bt_bt) {
        return -1;
    }
    if (sqlite3BtreeBeginTrans(bt_bt, 0, 0) != SQLITE_OK) {
        return -1;
    }
    if (bt_cursor_open(&bt_posts_cur, bt_posts, 0) != 0 ||
        bt_cursor_open(&bt_users_cur, bt_users, 0) != 0 ||
        bt_cursor_open(&bt_likes_cur, bt_likes_idx, bt_likes_ki) != 0) {
        bt_cursor_close(&bt_posts_cur);
        bt_cursor_close(&bt_users_cur);
        bt_cursor_close(&bt_likes_cur);
        return -1;
    }
    bt_open = 1;
    return 0;
}

/* Called by Cider once all CQEs in the batch have been handled, before COMMIT. */
void bt_end_batch(void) {
    if (bt_open) {
        bt_cursor_close(&bt_posts_cur);
        bt_cursor_close(&bt_users_cur);
        bt_cursor_close(&bt_likes_cur);
        bt_open = 0;
    }
}

static int bt_record(BtCur *c, Rec *r) {
    u32 total = sqlite3BtreePayloadSize(c->c);
    u32 local = 0;
    const u8 *p = (const u8 *)sqlite3BtreePayloadFetch(c->c, &local);
    if (local == total) {
        r->p = p;
        r->n = total;
        return 0;
    }
    if (total > c->spill_cap) {
        u8 *np = (u8 *)realloc(c->spill, (size_t)total + 4096);
        if (!np) {
            return -1;
        }
        c->spill = np;
        c->spill_cap = total + 4096;
    }
    if (sqlite3BtreePayload(c->c, 0, total, c->spill) != SQLITE_OK) {
        return -1;
    }
    r->p = c->spill;
    r->n = total;
    return 0;
}

static i64 bt_rowid(BtCur *c) {
    return sqlite3BtreeIntegerKey(c->c);
}

static int bt_last(BtCur *c) {
    int empty = 0;
    if (sqlite3BtreeLast(c->c, &empty) != SQLITE_OK) {
        return -1;
    }
    return empty ? 1 : 0;
}

static int bt_prev(BtCur *c) {
    int rc = sqlite3BtreePrevious(c->c, 0);
    return rc == SQLITE_OK ? 0 : rc == SQLITE_DONE ? 1 : -1;
}

static int bt_next(BtCur *c) {
    int rc = sqlite3BtreeNext(c->c, 0);
    return rc == SQLITE_OK ? 0 : rc == SQLITE_DONE ? 1 : -1;
}

static int bt_seek(BtCur *c, i64 rowid) {
    int res = 0;
    if (sqlite3BtreeTableMoveto(c->c, (u64)rowid, 0, &res) != SQLITE_OK) {
        return -1;
    }
    return res == 0 ? 0 : 1;
}

static int bt_idx_seek_ge(BtCur *c, KeyInfo *ki, i64 k) {
    Mem m;
    UnpackedRecord r;
    int res = 0;
    memset(&m, 0, sizeof(m));
    m.flags = MEM_Int;
    m.u.i = k;
    memset(&r, 0, sizeof(r));
    r.pKeyInfo = ki;
    r.aMem = &m;
    r.nField = 1;
    r.default_rc = 1;
    if (sqlite3BtreeIndexMoveto(c->c, &r, &res) != SQLITE_OK) {
        return -1;
    }
    if (res < 0) {
        return bt_next(c);
    }
    return sqlite3BtreeEof(c->c) ? 1 : 0;
}

static const u8 *rd_varint(const u8 *p, const u8 *end, u64 *v) {
    u64 x = 0;
    int i;
    for (i = 0; i < 8; i++) {
        if (p >= end) {
            return 0;
        }
        x = (x << 7) | (u64)(p[0] & 0x7f);
        if (!(*p++ & 0x80)) {
            *v = x;
            return p;
        }
    }
    if (p >= end) {
        return 0;
    }
    *v = (x << 8) | (u64)*p++;
    return p;
}

static u32 serial_len(u64 t) {
    static const u8 n[12] = {0, 1, 2, 3, 4, 6, 8, 8, 0, 0, 0, 0};
    return t < 12 ? n[t] : (u32)((t - 12) / 2);
}

static int rec_cols(const Rec *r, int ncol, Col *c) {
    const u8 *end = r->p + r->n;
    u64 hsz = 0;
    const u8 *h = rd_varint(r->p, end, &hsz);
    const u8 *hend;
    const u8 *body;
    int i;
    if (!h || hsz > r->n) {
        return -1;
    }
    hend = r->p + hsz;
    body = hend;
    for (i = 0; i < ncol; i++) {
        if (h >= hend) {
            return -1;
        }
        h = rd_varint(h, hend, &c[i].t);
        if (!h) {
            return -1;
        }
        c[i].p = body;
        body += serial_len(c[i].t);
    }
    return body <= end ? 0 : -1;
}

static int col_is_int(const Col *c) {
    return (c->t >= 1 && c->t <= 6) || c->t == 8 || c->t == 9;
}

static int col_is_text(const Col *c) {
    return c->t >= 13 && (c->t & 1);
}

static u32 col_len(const Col *c) {
    return serial_len(c->t);
}

static i64 col_int(const Col *c) {
    const u8 *p = c->p;
    switch (c->t) {
    case 1: return (i64)(int8_t)p[0];
    case 2: return (i64)(int16_t)(((u16)p[0] << 8) | p[1]);
    case 3: return (i64)(int32_t)(((u32)p[0] << 24) | ((u32)p[1] << 16) | ((u32)p[2] << 8)) >> 8;
    case 4: return (i64)(int32_t)(((u32)p[0] << 24) | ((u32)p[1] << 16) | ((u32)p[2] << 8) | p[3]);
    case 5: return (i64)(((u64)(int16_t)(((u16)p[0] << 8) | p[1]) << 32) |
                         (u64)(((u32)p[2] << 24) | ((u32)p[3] << 16) | ((u32)p[4] << 8) | p[5]));
    case 6: {
        u64 v = 0;
        int i;
        for (i = 0; i < 8; i++) {
            v = (v << 8) | p[i];
        }
        return (i64)v;
    }
    case 9: return 1;
    default: return 0;
    }
}

static int user_name(i64 uid, const u8 **author, u32 *author_len) {
    Rec r;
    Col c[3];
    int rc = bt_seek(&bt_users_cur, uid);
    if (rc) {
        return rc;
    }
    if (bt_record(&bt_users_cur, &r) != 0 ||
        rec_cols(&r, 3, c) != 0 ||
        !col_is_text(&c[1])) {
        return -1;
    }
    *author = c[1].p;
    *author_len = col_len(&c[1]);
    return 0;
}

/* Count likes for post ids lo..hi from one scan of likes_post_id_idx. */
static int range_counts(i64 lo, i64 hi, i64 *counts) {
    int rc;
    memset(counts, 0, sizeof(i64) * (size_t)(hi - lo + 1));
    rc = bt_idx_seek_ge(&bt_likes_cur, bt_likes_ki, lo);
    while (rc == 0) {
        Rec r;
        Col c[1];
        i64 pid;
        if (bt_record(&bt_likes_cur, &r) != 0 ||
            rec_cols(&r, 1, c) != 0 ||
            !col_is_int(&c[0])) {
            return -1;
        }
        pid = col_int(&c[0]);
        if (pid > hi) {
            return 0;
        }
        counts[pid - lo]++;
        rc = bt_next(&bt_likes_cur);
    }
    return rc < 0 ? -1 : 0;
}

static int put_post(BufWriterB *w, i64 id, const Col *body, const Col *created,
                    const u8 *author, u32 author_len, i64 likes) {
    if (!bw_put(w, "{\"id\":", 6) || !bw_i64(w, id) ||
        !bw_put(w, ",\"body\":", 8) ||
        !bw_jstr(w, body->p, col_len(body)) ||
        !bw_put(w, ",\"created_at\":", 14) ||
        !bw_jstr(w, created->p, col_len(created)) ||
        !bw_put(w, ",\"author\":", 10) ||
        !bw_jstr(w, author, author_len) ||
        !bw_put(w, ",\"like_count\":", 14) || !bw_i64(w, likes) ||
        !bw_put(w, "}", 1)) {
        return -1;
    }
    return 0;
}

static int bt_error(char *out, int cap, int status) {
    const char *msg = status == 404
        ? "{\"error\":\"post not found\"}"
        : "{\"error\":\"internal server error\"}";
    int n = (int)strlen(msg);
    if (n >= cap) {
        return -1;
    }
    memcpy(out, msg, (size_t)n);
    return n;
}

int bt_init(void *dbv) {
    int i;
    bt_db = (sqlite3 *)dbv;
    if (!bt_db) {
        return -1;
    }
    bt_bt = bt_db->aDb[0].pBt;
    if (!bt_bt) {
        return -1;
    }
    bt_posts = bt_rootpage("posts");
    bt_users = bt_rootpage("users");
    bt_likes_idx = bt_rootpage("likes_post_id_idx");
    if (!bt_posts || !bt_users || !bt_likes_idx) {
        return -1;
    }
    bt_likes_ki = sqlite3KeyInfoAlloc(bt_db, 1, 1);
    if (!bt_likes_ki) {
        return -1;
    }
    for (i = 0; i < 2; i++) {
        bt_likes_ki->aColl[i] = bt_db->pDfltColl;
    }
    return 0;
}

/* Returns body length and sets *status; -1 means fall back to SQL. */
int bt_feed_json(char *out, int cap, int *status) {
    BufWriterB w;
    Rec r;
    Col c[4];
    i64 hi, lo, counts[20];
    int n, k, rc;

    if (bt_begin_batch() != 0) {
        return -1;
    }
    w.buf = out;
    w.len = 0;
    w.cap = cap;
    if (!bw_put(&w, "{\"posts\":[", 10)) {
        return -1;
    }

    rc = bt_last(&bt_posts_cur);
    if (rc < 0) {
        return -1;
    }
    if (rc == 0) {
        hi = bt_rowid(&bt_posts_cur);
        lo = hi > 20 ? hi - 19 : 1;
        n = (int)(hi - lo + 1);
        if (n <= 0 || n > 20) {
            return -1;
        }
        if (range_counts(lo, hi, counts) != 0) {
            return -1;
        }
        for (k = 0; k < n; k++) {
            i64 id;
            const u8 *author;
            u32 author_len;
            if (bt_record(&bt_posts_cur, &r) != 0 ||
                rec_cols(&r, 4, c) != 0 ||
                !col_is_int(&c[1]) || !col_is_text(&c[2]) ||
                !col_is_text(&c[3])) {
                return -1;
            }
            id = bt_rowid(&bt_posts_cur);
            if (id != hi - k) {
                return -1;
            }
            if (user_name(col_int(&c[1]), &author, &author_len) != 0) {
                return -1;
            }
            if (k && !bw_put(&w, ",", 1)) {
                return -1;
            }
            if (put_post(&w, id, &c[2], &c[3], author, author_len,
                         counts[id - lo]) != 0) {
                return -1;
            }
            if (k < n - 1 && bt_prev(&bt_posts_cur) != 0) {
                return -1;
            }
        }
    }
    if (!bw_put(&w, "]}", 2) || w.len >= cap) {
        return -1;
    }
    *status = 200;
    return w.len;
}

/* Returns body length and sets *status; -1 means fall back to SQL. */
int bt_post_json(i64 id, char *out, int cap, int *status) {
    BufWriterB w;
    Rec r;
    Col c[4];
    i64 likes = 0;
    const u8 *author;
    u32 author_len;
    int rc;

    if (bt_begin_batch() != 0) {
        return -1;
    }
    rc = bt_seek(&bt_posts_cur, id);
    if (rc < 0) {
        return -1;
    }
    if (rc == 1) {
        int n = bt_error(out, cap, 404);
        if (n < 0) {
            return -1;
        }
        *status = 404;
        return n;
    }
    if (bt_record(&bt_posts_cur, &r) != 0 ||
        rec_cols(&r, 4, c) != 0 ||
        !col_is_int(&c[1]) || !col_is_text(&c[2]) ||
        !col_is_text(&c[3])) {
        return -1;
    }
    if (user_name(col_int(&c[1]), &author, &author_len) != 0) {
        return -1;
    }
    if (range_counts(id, id, &likes) != 0) {
        return -1;
    }

    w.buf = out;
    w.len = 0;
    w.cap = cap;
    if (!bw_put(&w, "{\"post\":", 8) ||
        put_post(&w, id, &c[2], &c[3], author, author_len, likes) != 0 ||
        !bw_put(&w, "}", 1) || w.len >= cap) {
        return -1;
    }
    *status = 200;
    return w.len;
}
