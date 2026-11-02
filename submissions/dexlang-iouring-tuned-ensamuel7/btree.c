/* The read engine: GET /feed, GET /posts/:id and the like handler's post
 * check, answered through SQLite's own B-tree cursors instead of SQL text.
 *
 * build.sh compiles this in the same translation unit as the stock SQLite
 * 3.54.1 amalgamation (vendor/engine/sqlite3.c #includes both), which is what
 * gives it SQLite's internal B-tree interface. SQLite itself is not changed:
 * the engine opens read-only cursors on the program's connection, inside the
 * transaction the batch already holds, and reads the same records the SQL
 * would. Writes still go through SQL.
 *
 * Whenever it cannot answer exactly as the reference query would, it says so
 * (-1) and server.dx runs the SQL instead. That covers no open transaction,
 * a schema other than the challenge's, a record it does not expect, a text
 * value with a NUL byte in it (which cannot cross into Dex as a C string),
 * and running out of its fixed buffers. */

#include "btree.h"

#define DEXBT_FEED 20
#define DEXBT_INDEX_REC 512     /* largest index record read (created_at, id, rowid) */
#define DEXBT_ROW_REC 16384     /* largest posts or users row read */
#define DEXBT_PAD 16            /* zeroed slack after a record, for varint reads */

typedef struct {
    u32 type;
    const u8* p;
    u32 n;
} DexBtVal;

static sqlite3* dexbt_db;
static int dexbt_capture;
static int dexbt_ready;
static Schema* dexbt_schema;
static int dexbt_cookie;
static Pgno dexbt_posts_root, dexbt_users_root, dexbt_feed_root, dexbt_likes_root;
static KeyInfo* dexbt_feed_key;
static KeyInfo* dexbt_likes_key;
static BtCursor* dexbt_cur[4];

/* The last answer's JSON, kept between calls so a request does not allocate. */
static char* dexbt_out;
static size_t dexbt_out_len, dexbt_out_cap;
static u8 dexbt_ibuf[DEXBT_INDEX_REC + DEXBT_PAD];
static u8 dexbt_rbuf[DEXBT_ROW_REC + DEXBT_PAD];
static u8 dexbt_ubuf[DEXBT_ROW_REC + DEXBT_PAD];

static int dexbt_entry(sqlite3* db, const char** err, const struct sqlite3_api_routines* api) {
    (void)err;
    (void)api;
    if (dexbt_capture) {
        dexbt_db = db;
        dexbt_capture = 0;
    }
    return SQLITE_OK;
}

int dexbt_attach_next(void) {
    dexbt_capture = 1;
    return sqlite3_auto_extension((void (*)(void))dexbt_entry) == SQLITE_OK;
}

static int dexbt_col_is(Table* t, int i, const char* name) {
    return i < t->nCol && sqlite3StrICmp(t->aCol[i].zCnName, name) == 0;
}

static int dexbt_binary(Index* x) {
    for (int i = 0; i < x->nColumn; i++) {
        if (x->azColl[i] != sqlite3StrBINARY) return 0;
    }
    return 1;
}

/* The comparison info SQLite builds for an index (sqlite3KeyInfoOfIndex),
 * for indexes whose columns all use BINARY, so no Parse is needed. */
static KeyInfo* dexbt_key_of(sqlite3* db, Index* x) {
    int nCol = x->nColumn, nKey = x->nKeyCol;
    KeyInfo* k = x->uniqNotNull ? sqlite3KeyInfoAlloc(db, nKey, nCol - nKey) : sqlite3KeyInfoAlloc(db, nCol, 0);
    if (!k) return 0;
    for (int i = 0; i < nCol; i++) {
        k->aColl[i] = 0;
        k->aSortFlags[i] = x->aSortOrder[i];
    }
    return k;
}

int dexbt_init(void) {
    sqlite3_cancel_auto_extension((void (*)(void))dexbt_entry);
    dexbt_ready = 0;
    sqlite3* db = dexbt_db;
    if (!db) return 0;
    Db* md = &db->aDb[0];
    if (!md->pBt || !md->pSchema || !DbHasProperty(db, 0, DB_SchemaLoaded)) return 0;
    if (ENC(db) != SQLITE_UTF8) return 0;
    if (md->pSchema->file_format < 4) return 0; /* DESC indexes are stored descending */

    Table* posts = sqlite3FindTable(db, "posts", "main");
    Table* users = sqlite3FindTable(db, "users", "main");
    Table* likes = sqlite3FindTable(db, "likes", "main");
    Index* feed = sqlite3FindIndex(db, "posts_created_at_id_idx", "main");
    Index* byPost = sqlite3FindIndex(db, "likes_post_id_idx", "main");
    if (!posts || !users || !likes || !feed || !byPost) return 0;
    if (!HasRowid(posts) || !HasRowid(users) || posts->iPKey != 0 || users->iPKey != 0) return 0;
    if (posts->nCol != 4 || !dexbt_col_is(posts, 1, "user_id") || !dexbt_col_is(posts, 2, "body") ||
        !dexbt_col_is(posts, 3, "created_at"))
        return 0;
    if (users->nCol != 3 || !dexbt_col_is(users, 1, "username")) return 0;
    if (feed->pTable != posts || feed->nKeyCol != 2 || feed->aiColumn[0] != 3 ||
        feed->aSortOrder[0] != SQLITE_SO_DESC || feed->aSortOrder[1] != SQLITE_SO_DESC || !dexbt_binary(feed))
        return 0;
    if (byPost->pTable != likes || byPost->nKeyCol != 1 || !dexbt_col_is(likes, byPost->aiColumn[0], "post_id") ||
        !dexbt_binary(byPost))
        return 0;

    dexbt_feed_key = dexbt_key_of(db, feed);
    dexbt_likes_key = dexbt_key_of(db, byPost);
    if (!dexbt_feed_key || !dexbt_likes_key) return 0;
    for (int i = 0; i < 4; i++) {
        dexbt_cur[i] = (BtCursor*)sqlite3_malloc(sqlite3BtreeCursorSize());
        if (!dexbt_cur[i]) return 0;
    }
    dexbt_posts_root = posts->tnum;
    dexbt_users_root = users->tnum;
    dexbt_feed_root = feed->tnum;
    dexbt_likes_root = byPost->tnum;
    dexbt_schema = md->pSchema;
    dexbt_cookie = md->pSchema->schema_cookie;
    dexbt_ready = 1;
    return 1;
}

/* The connection's B-tree, if the engine may read it now: the schema is the
 * one it was set up for and the batch's transaction is open. */
static Btree* dexbt_begin(void) {
    if (!dexbt_ready) return 0;
    Db* md = &dexbt_db->aDb[0];
    if (md->pSchema != dexbt_schema || md->pSchema->schema_cookie != dexbt_cookie) {
        dexbt_ready = 0;
        return 0;
    }
    if (sqlite3BtreeTxnState(md->pBt) == SQLITE_TXN_NONE) return 0;
    return md->pBt;
}

static u32 dexbt_serial_len(u32 t) {
    static const u8 fixed[] = {0, 1, 2, 3, 4, 6, 8, 8, 0, 0};
    if (t < 10) return fixed[t];
    return (t - 12) / 2;
}

/* Splits a record (header, then values) into up to max values. The buffer
 * has DEXBT_PAD zeroed bytes after it, so a varint read at the end of a
 * malformed header stays inside it. Returns the number of values, or -1.
 * Varints are read with getVarint32, the macro SQLite's own record code
 * uses: sqlite3GetVarint32 alone assumes the value takes two bytes or more. */
static int dexbt_parse(const u8* rec, u32 n, DexBtVal* out, int max) {
    u32 hdr;
    u32 i = getVarint32(rec, hdr);
    if (hdr < i || hdr > n) return -1;
    u32 off = hdr;
    int f = 0;
    while (i < hdr && f < max) {
        u32 t;
        i += getVarint32(rec + i, t);
        if (t == 10 || t == 11) return -1;
        u32 len = dexbt_serial_len(t);
        if (len > n - off) return -1;
        out[f].type = t;
        out[f].p = rec + off;
        out[f].n = len;
        off += len;
        f++;
    }
    if (i > hdr) return -1;
    return f;
}

static int dexbt_int(const DexBtVal* v, i64* out) {
    if (v->type == 8) { *out = 0; return 0; }
    if (v->type == 9) { *out = 1; return 0; }
    if (v->type < 1 || v->type > 6) return -1;
    i64 x = (v->p[0] & 0x80) ? -1 : 0;
    for (u32 i = 0; i < v->n; i++) x = (i64)(((u64)x << 8) | v->p[i]);
    *out = x;
    return 0;
}

/* The answer is written as the JSON json.encode makes for the same structs,
 * straight from the records, so a value is copied once. */
static int dexbt_need(size_t n) {
    if (dexbt_out_len + n <= dexbt_out_cap) return 0;
    size_t cap = dexbt_out_cap ? dexbt_out_cap : 16384;
    while (cap < dexbt_out_len + n) cap *= 2;
    char* p = (char*)realloc(dexbt_out, cap);
    if (!p) return -1;
    dexbt_out = p;
    dexbt_out_cap = cap;
    return 0;
}

static int dexbt_raw(const char* s, size_t n) {
    if (dexbt_need(n) < 0) return -1;
    memcpy(dexbt_out + dexbt_out_len, s, n);
    dexbt_out_len += n;
    return 0;
}

static int dexbt_long(i64 v) {
    char d[24];
    int i = 0;
    u64 u = v < 0 ? (u64)0 - (u64)v : (u64)v;
    do { d[i++] = (char)('0' + u % 10); u /= 10; } while (u);
    if (dexbt_need((size_t)i + 1) < 0) return -1;
    if (v < 0) dexbt_out[dexbt_out_len++] = '-';
    while (i) dexbt_out[dexbt_out_len++] = d[--i];
    return 0;
}

/* Bytes that need no escape: none below 0x20, no quote, no backslash. */
static int dexbt_clean(const u8* d, u32 n) {
    const u64 ones = 0x0101010101010101ULL, highs = 0x8080808080808080ULL;
    u32 i = 0;
    for (; i + 8 <= n; i += 8) {
        u64 x;
        memcpy(&x, d + i, 8);
        u64 q = x ^ (ones * '"'), bs = x ^ (ones * '\\');
        u64 hit = ((x - ones * 0x20) & ~x) | ((q - ones) & ~q) | ((bs - ones) & ~bs);
        if (hit & highs) return 0;
    }
    for (; i < n; i++) {
        if (d[i] < 0x20 || d[i] == '"' || d[i] == '\\') return 0;
    }
    return 1;
}

/* A text value as a JSON string, escaped as the runtime's json.encode does.
 * -1 for anything that is not text, or holds a NUL (the SQL path cannot pass
 * one through either, so it answers those). */
static int dexbt_str(const DexBtVal* v) {
    if (v->type < 13 || (v->type & 1) == 0) return -1;
    const u8* d = v->p;
    u32 n = v->n;
    if (dexbt_clean(d, n)) {
        if (dexbt_need((size_t)n + 2) < 0) return -1;
        char* o = dexbt_out + dexbt_out_len;
        o[0] = '"';
        memcpy(o + 1, d, n);
        o[n + 1] = '"';
        dexbt_out_len += (size_t)n + 2;
        return 0;
    }
    if (dexbt_need((size_t)n * 6 + 2) < 0) return -1;
    char* o = dexbt_out + dexbt_out_len;
    size_t k = 0;
    o[k++] = '"';
    for (u32 i = 0; i < n; i++) {
        u8 c = d[i];
        switch (c) {
        case 0: return -1;
        case '"':  o[k++] = '\\'; o[k++] = '"';  break;
        case '\\': o[k++] = '\\'; o[k++] = '\\'; break;
        case '\b': o[k++] = '\\'; o[k++] = 'b';  break;
        case '\f': o[k++] = '\\'; o[k++] = 'f';  break;
        case '\n': o[k++] = '\\'; o[k++] = 'n';  break;
        case '\r': o[k++] = '\\'; o[k++] = 'r';  break;
        case '\t': o[k++] = '\\'; o[k++] = 't';  break;
        default:
            if (c < 0x20) {
                static const char hex[] = "0123456789abcdef";
                o[k++] = '\\'; o[k++] = 'u'; o[k++] = '0'; o[k++] = '0';
                o[k++] = hex[c >> 4];
                o[k++] = hex[c & 0xF];
            } else {
                o[k++] = (char)c;
            }
        }
    }
    o[k++] = '"';
    dexbt_out_len += k;
    return 0;
}

/* The cursor's current record: in place on its page when the page holds all
 * of it, which is how SQLite's own column reads take it, otherwise copied into
 * buf (cap bytes at most). The record is valid until the cursor moves. */
static int dexbt_read(BtCursor* c, u8* buf, u32 cap, const u8** rec, u32* n) {
    u32 size = sqlite3BtreePayloadSize(c);
    u32 local = 0;
    const u8* p = (const u8*)sqlite3BtreePayloadFetch(c, &local);
    if (p && local >= size) {
        *rec = p;
        *n = size;
        return 0;
    }
    if (size > cap) return -1;
    if (sqlite3BtreePayload(c, 0, size, buf) != SQLITE_OK) return -1;
    memset(buf + size, 0, DEXBT_PAD);
    *rec = buf;
    *n = size;
    return 0;
}

/* The post_id of the likes_post_id_idx entry under the cursor. */
static int dexbt_like_post(BtCursor* c, i64* post) {
    const u8* rec;
    u32 size;
    DexBtVal v[1];
    if (dexbt_read(c, dexbt_ibuf, DEXBT_INDEX_REC, &rec, &size) < 0) return -1;
    if (dexbt_parse(rec, size, v, 1) < 1 || dexbt_int(&v[0], post) < 0) return -1;
    return 0;
}

/* Positions the likes cursor the way SQLite's OP_SeekGE (ge) or OP_SeekLE
 * (!ge) does for one post_id. 1 on an entry, 0 none on that side, -1. */
static int dexbt_like_seek(BtCursor* c, i64 post, int ge) {
    UnpackedRecord r;
    Mem key;
    memset(&r, 0, sizeof(r));
    memset(&key, 0, sizeof(key));
    key.flags = MEM_Int;
    key.u.i = post;
    key.db = dexbt_db;
    r.pKeyInfo = dexbt_likes_key;
    r.aMem = &key;
    r.nField = 1;
    r.default_rc = ge ? +1 : -1;
    int res = 0;
    if (sqlite3BtreeIndexMoveto(c, &r, &res) != SQLITE_OK || r.errCode) return -1;
    if (sqlite3BtreeEof(c)) return 0;
    if (ge ? res < 0 : res > 0) {
        int rc = ge ? sqlite3BtreeNext(c, 0) : sqlite3BtreePrevious(c, 0);
        if (rc == SQLITE_DONE) return 0;
        if (rc != SQLITE_OK) return -1;
    }
    return 1;
}

/* Likes of one post, counted like count(*) does: the entries equal to it,
 * from the first one forward. */
static int dexbt_count_likes(BtCursor* c, i64 post, int* out) {
    int at = dexbt_like_seek(c, post, 1);
    if (at < 0) return -1;
    int n = 0;
    while (at) {
        i64 id;
        if (dexbt_like_post(c, &id) < 0) return -1;
        if (id != post) break;
        n++;
        int rc = sqlite3BtreeNext(c, 0);
        if (rc == SQLITE_DONE) break;
        if (rc != SQLITE_OK) return -1;
    }
    *out = n;
    return 0;
}

/* The feed's like counts, for posts asked for in descending id order: one
 * seek, then a walk backwards through the index that each post continues
 * from where the one before it stopped. A post out of that order seeks
 * again. */
typedef struct {
    int state;      /* 0 not positioned, 1 on an entry, 2 no entries left below */
    i64 last;       /* the post counted before */
    i64 at;         /* post_id of the entry under the cursor (state 1) */
} DexBtLikesWalk;

static int dexbt_count_likes_desc(BtCursor* c, DexBtLikesWalk* w, i64 post, int* out) {
    if (w->state == 0 || post >= w->last || (w->state == 1 && w->at > post)) {
        int at = dexbt_like_seek(c, post, 0);
        if (at < 0) return -1;
        w->state = at ? 1 : 2;
        if (at && dexbt_like_post(c, &w->at) < 0) return -1;
    }
    w->last = post;
    int n = 0;
    while (w->state == 1 && w->at == post) {
        n++;
        int rc = sqlite3BtreePrevious(c, 0);
        if (rc == SQLITE_DONE) { w->state = 2; break; }
        if (rc != SQLITE_OK) return -1;
        if (dexbt_like_post(c, &w->at) < 0) return -1;
    }
    *out = n;
    return 0;
}

/* One post object, after a comma unless it is the first, with the posts
 * cursor on the post's row. The likes are counted by the feed's walk when
 * there is one (w), else on their own. 1 written, 0 the post has no author
 * row (the reference JOIN drops it, so nothing is written), -1. */
static int dexbt_fill(int first, i64 id, BtCursor* pc, BtCursor* uc, BtCursor* lc, DexBtLikesWalk* w) {
    const u8* rec;
    u32 size;
    DexBtVal f[4];
    i64 author;
    int res = 0;
    if (dexbt_read(pc, dexbt_rbuf, DEXBT_ROW_REC, &rec, &size) < 0) return -1;
    if (dexbt_parse(rec, size, f, 4) != 4 || dexbt_int(&f[1], &author) < 0) return -1;

    /* The post's record stays where it is (its page, or dexbt_rbuf) while
     * the users row goes to its own buffer. */
    if (sqlite3BtreeTableMoveto(uc, author, 0, &res) != SQLITE_OK) return -1;
    if (res != 0 || sqlite3BtreeEof(uc)) return 0;
    DexBtVal u[2];
    if (dexbt_read(uc, dexbt_ubuf, DEXBT_ROW_REC, &rec, &size) < 0) return -1;
    if (dexbt_parse(rec, size, u, 2) != 2) return -1;

    int likes;
    if ((w ? dexbt_count_likes_desc(lc, w, id, &likes) : dexbt_count_likes(lc, id, &likes)) < 0) return -1;

    if (dexbt_raw(first ? "{\"id\":" : ",{\"id\":", first ? 6 : 7) < 0 || dexbt_long(id) < 0 ||
        dexbt_raw(",\"body\":", 8) < 0 || dexbt_str(&f[2]) < 0 ||
        dexbt_raw(",\"created_at\":", 14) < 0 || dexbt_str(&f[3]) < 0 ||
        dexbt_raw(",\"author\":", 10) < 0 || dexbt_str(&u[1]) < 0 ||
        dexbt_raw(",\"like_count\":", 14) < 0 || dexbt_long(likes) < 0 || dexbt_raw("}", 1) < 0)
        return -1;
    return 1;
}

static void dexbt_close(int n) {
    for (int i = 0; i < n; i++) sqlite3BtreeCloseCursor(dexbt_cur[i]);
}

/* Opens the posts, users and likes_post_id_idx cursors, and the feed index
 * one when feed is set. The number opened, all of which the caller closes;
 * fewer than asked means one failed. */
static int dexbt_open(Btree* p, int feed) {
    Pgno roots[4] = {dexbt_posts_root, dexbt_users_root, dexbt_likes_root, dexbt_feed_root};
    KeyInfo* keys[4] = {0, 0, dexbt_likes_key, dexbt_feed_key};
    int want = feed ? 4 : 3;
    for (int i = 0; i < want; i++) {
        sqlite3BtreeCursorZero(dexbt_cur[i]);
        if (sqlite3BtreeCursor(p, roots[i], 0, keys[i], dexbt_cur[i]) != SQLITE_OK) return i;
    }
    return want;
}

static int dexbt_feed_locked(Btree* p) {
    int opened = dexbt_open(p, 1);
    int n = -1;
    if (opened < 4) goto done;
    BtCursor *pc = dexbt_cur[0], *uc = dexbt_cur[1], *lc = dexbt_cur[2], *fc = dexbt_cur[3];
    int res = 0, found = 0;
    i64 prev = 0;
    DexBtLikesWalk walk = {0, 0, 0};
    if (sqlite3BtreeFirst(fc, &res) != SQLITE_OK) goto done;
    while (res == 0 && found < DEXBT_FEED) {
        const u8* rec;
        u32 size;
        DexBtVal v[3];
        i64 id;
        if (dexbt_read(fc, dexbt_ibuf, DEXBT_INDEX_REC, &rec, &size) < 0) goto done;
        int nv = dexbt_parse(rec, size, v, 3);
        if (nv != 3 || dexbt_int(&v[2], &id) < 0) goto done; /* the last value is the rowid */
        /* New posts get consecutive ids, so the next row is usually the one
         * before the last: a step back instead of a seek from the root. */
        int stepped = 0;
        if (prev && id == prev - 1 && sqlite3BtreeCursorIsValidNN(pc)) {
            int rc = sqlite3BtreePrevious(pc, 0);
            if (rc != SQLITE_OK && rc != SQLITE_DONE) goto done;
            stepped = rc == SQLITE_OK && sqlite3BtreeIntegerKey(pc) == id;
        }
        if (!stepped) {
            int at = 0;
            if (sqlite3BtreeTableMoveto(pc, id, 0, &at) != SQLITE_OK || at != 0 || sqlite3BtreeEof(pc)) goto done;
        }
        prev = id;
        int got = dexbt_fill(found == 0, id, pc, uc, lc, &walk);
        if (got < 0) goto done;
        found += got;
        int rc = sqlite3BtreeNext(fc, 0);
        if (rc == SQLITE_DONE) break;
        if (rc != SQLITE_OK) goto done;
    }
    n = found;
done:
    dexbt_close(opened);
    return n;
}

/* GET /feed as {"posts":[...]}: the number of posts, or -1. */
int dexbt_feed(void) {
    Btree* p = dexbt_begin();
    dexbt_out_len = 0;
    if (!p) return -1;
    int n = -1;
    if (dexbt_raw("{\"posts\":[", 10) == 0) {
        sqlite3BtreeEnter(p);
        n = dexbt_feed_locked(p);
        sqlite3BtreeLeave(p);
    }
    if (n >= 0 && dexbt_raw("]}", 2) < 0) n = -1;
    if (n < 0) dexbt_out_len = 0;
    return n;
}

static int dexbt_post_locked(Btree* p, i64 id, int fill) {
    int opened = dexbt_open(p, 0);
    int r = -1;
    if (opened < 3) goto done;
    int at = 0;
    if (sqlite3BtreeTableMoveto(dexbt_cur[0], id, 0, &at) != SQLITE_OK) goto done;
    if (at != 0 || sqlite3BtreeEof(dexbt_cur[0])) {
        r = 0;
        goto done;
    }
    r = fill ? dexbt_fill(1, id, dexbt_cur[0], dexbt_cur[1], dexbt_cur[2], 0) : 1;
done:
    dexbt_close(opened);
    return r;
}

/* GET /posts/:id as {"post":{...}}: 1, 0 for no such post, or -1. */
int dexbt_post(long id) {
    Btree* p = dexbt_begin();
    dexbt_out_len = 0;
    if (!p) return -1;
    int r = -1;
    if (dexbt_raw("{\"post\":", 8) == 0) {
        sqlite3BtreeEnter(p);
        r = dexbt_post_locked(p, (i64)id, 1);
        sqlite3BtreeLeave(p);
    }
    if (r == 1 && dexbt_raw("}", 1) < 0) r = -1;
    if (r != 1) dexbt_out_len = 0;
    return r;
}

int dexbt_exists(long id) {
    Btree* p = dexbt_begin();
    if (!p) return -1;
    sqlite3BtreeEnter(p);
    int r = dexbt_post_locked(p, (i64)id, 0);
    sqlite3BtreeLeave(p);
    return r;
}

const char* dexbt_json(void) {
    if (!dexbt_out_len || dexbt_need(1) < 0) return "";
    dexbt_out[dexbt_out_len] = 0;
    return dexbt_out;
}
