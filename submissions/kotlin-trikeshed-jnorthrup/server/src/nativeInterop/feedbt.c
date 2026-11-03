/*
 * feedbt.c: GET /feed and GET /posts/:id on SQLite's own B-tree cursors. This file includes the amalgamation as published
 * (sqlite3.c is not patched), because the B-tree functions are private to it; sqliteArchive compiles this file instead of
 * sqlite3.c, so libsqlite3.a holds SQLite plus these plans. Every page is still read through SQLite's pager, WAL and page
 * cache; only the bytecode engine is skipped, for the two read queries the API fixes. Whenever a row does not look as the
 * schema says, a plan returns -1 and the caller runs the SQL statement, which stays the definition of the answer.
 *
 * The feed takes the 20 first entries of posts_created_at_id_idx (created_at DESC, id DESC): that is the ORDER BY of the
 * SQL feed, so no assumption about the ids is needed. When those ids lie within FEEDBT_SPAN of each other (ids and
 * timestamps grow together), one range scan of likes_post_id_idx counts every like and one range scan of posts reads every
 * row; otherwise each id is sought on its own. Either way the authors are sought by rowid in users.
 * The JSON is the SQL path's: feed_json_text and feed_i64 (below) write both, and feedc.def's feed_row_json calls them
 * for the SQL path. feedbt_test.c holds both paths equal; feedjson_test.c holds the writers to byte-wise references.
 */
#include "sqlite3.c"
#include "feedbt.h"

/* BEGIN feed_json_text */
/*
 * One text column as the body of a JSON string: quote and backslash get a backslash, \b \f \n \r \t keep their letters, the
 * other bytes below 0x20 become \u00XX, everything else (UTF-8 included) is copied. A run with nothing to escape moves
 * whole: eight bytes are tested per step, then one memcpy. dst has room for 6 bytes per source byte; the result is the
 * count written. feedjson_test.c holds this function to a byte-wise reference. Defined here, in libsqlite3.a, for the plans below and for feedc.def.
 */
int feed_json_text(const unsigned char *src, int n, char *dst) {
  static const char hex[] = "0123456789abcdef";
  int r = 0, w = 0;
  while (r < n) {
    int s = r;
    while (r + 8 <= n) {
      unsigned long long x, q, b;
      memcpy(&x, src + r, 8);
      q = x ^ 0x2222222222222222ULL;
      b = x ^ 0x5C5C5C5C5C5C5C5CULL;
      if ((((x - 0x2020202020202020ULL) & ~x) | ((q - 0x0101010101010101ULL) & ~q) | ((b - 0x0101010101010101ULL) & ~b)) & 0x8080808080808080ULL) break;
      r += 8;
    }
    while (r < n && src[r] >= 0x20 && src[r] != '"' && src[r] != '\\') r++;
    memcpy(dst + w, src + s, (size_t)(r - s));
    w += r - s;
    if (r < n) {
      unsigned c = src[r++];
      dst[w++] = '\\';
      switch (c) {
        case '"': dst[w++] = '"'; break;
        case '\\': dst[w++] = '\\'; break;
        case 0x08: dst[w++] = 'b'; break;
        case 0x0C: dst[w++] = 'f'; break;
        case 0x0A: dst[w++] = 'n'; break;
        case 0x0D: dst[w++] = 'r'; break;
        case 0x09: dst[w++] = 't'; break;
        default: dst[w++] = 'u'; dst[w++] = '0'; dst[w++] = '0'; dst[w++] = hex[c >> 4]; dst[w++] = hex[c & 15];
      }
    }
  }
  return w;
}

/* The decimal digits of v at dst; the count written. Defined here, in libsqlite3.a, for the plans below and for feedc.def. */
int feed_i64(char *dst, long long v) {
  char t[24];
  int n = 0, w = 0;
  unsigned long long u = v < 0 ? 0ULL - (unsigned long long)v : (unsigned long long)v;
  if (v < 0) dst[w++] = '-';
  do { t[n++] = (char)('0' + u % 10); u /= 10; } while (u);
  while (n) dst[w++] = t[--n];
  return w;
}
/* END feed_json_text */

#define FEEDBT_N 20
#define FEEDBT_SPAN 64
#define FEEDBT_STAGE 4096 /* one post's body and created_at, copied out of its page; a longer row goes to SQL */

typedef struct FeedBtRow { i64 id, user, likes; u32 bodyLen, createdLen, nameLen; u8 bytes[FEEDBT_STAGE]; } FeedBtRow;

static struct {
  sqlite3 *db;
  Btree *bt;
  Pgno rootPosts, rootUsers, rootLikesIdx, rootPostsIdx;
  KeyInfo *kiLikes, *kiPosts;
  BtCursor *posts, *users, *likes, *postsIdx;
  int ok;
  int held; /* a read transaction and its cursors are open for this wake */
  u8 *spill;
  u32 spillCap;
  FeedBtRow rows[FEEDBT_N];
} B;

/* ---- setup: the schema the plans read, checked once ---- */

static Pgno fb_root(const char *name) {
  sqlite3_stmt *s;
  Pgno root = 0;
  if (sqlite3_prepare_v2(B.db, "SELECT rootpage FROM sqlite_schema WHERE name = ?1", -1, &s, NULL) != SQLITE_OK) return 0;
  sqlite3_bind_text(s, 1, name, -1, SQLITE_STATIC);
  if (sqlite3_step(s) == SQLITE_ROW) root = (Pgno)sqlite3_column_int64(s, 0);
  sqlite3_finalize(s);
  return root;
}

/* The pragma's rows as "a:b:c,..." from the given columns, compared with what the plans were written for. */
static int fb_layout(const char *pragma, const char *name, int c1, int c2, int c3, int keyOnly, const char *want) {
  char sql[160], got[512];
  sqlite3_stmt *s;
  size_t n = 0;
  snprintf(sql, sizeof sql, "PRAGMA %s(\"%s\")", pragma, name);
  if (sqlite3_prepare_v2(B.db, sql, -1, &s, NULL) != SQLITE_OK) return 0;
  got[0] = 0;
  while (sqlite3_step(s) == SQLITE_ROW && n < sizeof got - 64) {
    if (keyOnly && !sqlite3_column_int(s, 5)) continue;
    const char *a = (const char *)sqlite3_column_text(s, c1), *b = (const char *)sqlite3_column_text(s, c2);
    n += (size_t)snprintf(got + n, sizeof got - n, "%s%s:%s", n ? "," : "", a ? a : "", b ? b : "");
    if (c3 >= 0) n += (size_t)snprintf(got + n, sizeof got - n, ":%d", sqlite3_column_int(s, c3));
  }
  sqlite3_finalize(s);
  return strcmp(got, want) == 0;
}

static KeyInfo *fb_keyinfo(int nKey, int desc) {
  KeyInfo *k = sqlite3KeyInfoAlloc(B.db, nKey, 1);
  if (!k) return NULL;
  for (int i = 0; i <= nKey; i++) {
    k->aColl[i] = B.db->pDfltColl;
    if (desc && i < nKey) k->aSortFlags[i] = KEYINFO_ORDER_DESC;
  }
  return k;
}

int feedbt_init(sqlite3 *db) {
  memset(&B, 0, sizeof B);
  B.db = db;
  B.bt = db->aDb[0].pBt;
  int layout =
      fb_layout("table_info", "users", 1, 2, 5, 0, "id:INTEGER:1,username:TEXT:0,created_at:TEXT:0") &&
      fb_layout("table_info", "posts", 1, 2, 5, 0, "id:INTEGER:1,user_id:INTEGER:0,body:TEXT:0,created_at:TEXT:0") &&
      fb_layout("table_info", "likes", 1, 2, 5, 0, "user_id:INTEGER:1,post_id:INTEGER:2,created_at:TEXT:0") &&
      fb_layout("index_xinfo", "likes_post_id_idx", 2, 3, -1, 1, "post_id:0") &&
      fb_layout("index_xinfo", "posts_created_at_id_idx", 2, 3, -1, 1, "created_at:1,id:1");
  B.rootPosts = fb_root("posts");
  B.rootUsers = fb_root("users");
  B.rootLikesIdx = fb_root("likes_post_id_idx");
  B.rootPostsIdx = fb_root("posts_created_at_id_idx");
  if (!layout || !B.rootPosts || !B.rootUsers || !B.rootLikesIdx || !B.rootPostsIdx) return 0;
  B.kiLikes = fb_keyinfo(1, 0);
  B.kiPosts = fb_keyinfo(2, 1);
  size_t size = (size_t)sqlite3BtreeCursorSize();
  B.posts = malloc(size); B.users = malloc(size); B.likes = malloc(size); B.postsIdx = malloc(size);
  if (!B.kiLikes || !B.kiPosts || !B.posts || !B.users || !B.likes || !B.postsIdx) return 0;
  B.ok = 1;
  return 1;
}

static int fb_cursors(void);

/* Cursors for one call. Inside the connection's open write transaction they are opened for the call and read it (as the
 * SQL path does). Otherwise one read transaction and its cursors are filled on the first read of a wake and held for every
 * read after it, until feedbt_release drains them: at the end of the wake, and before any SQL statement steps. */
static int fb_open(int *began) {
  *began = 0;
  if (B.held) return 0;
  if (sqlite3BtreeTxnState(B.bt) == SQLITE_TXN_NONE) {
    if (sqlite3BtreeBeginTrans(B.bt, 0, 0) != SQLITE_OK) return -1;
    B.held = 1;
    if (fb_cursors()) { feedbt_release(); return -1; } /* closes what it opened (zeroed cursors close as no-ops) */
    return 0;
  }
  return fb_cursors();
}

void feedbt_release(void) {
  if (!B.held) return;
  B.held = 0;
  sqlite3BtreeCloseCursor(B.posts); sqlite3BtreeCloseCursor(B.users);
  sqlite3BtreeCloseCursor(B.likes); sqlite3BtreeCloseCursor(B.postsIdx);
  sqlite3BtreeCommit(B.bt);
}

static int fb_cursors(void) {
  sqlite3BtreeCursorZero(B.posts); sqlite3BtreeCursorZero(B.users);
  sqlite3BtreeCursorZero(B.likes); sqlite3BtreeCursorZero(B.postsIdx);
  if (sqlite3BtreeCursor(B.bt, B.rootPosts, 0, NULL, B.posts) != SQLITE_OK ||
      sqlite3BtreeCursor(B.bt, B.rootUsers, 0, NULL, B.users) != SQLITE_OK ||
      sqlite3BtreeCursor(B.bt, B.rootLikesIdx, 0, B.kiLikes, B.likes) != SQLITE_OK ||
      sqlite3BtreeCursor(B.bt, B.rootPostsIdx, 0, B.kiPosts, B.postsIdx) != SQLITE_OK) return -1;
  return 0;
}

/* Per-call cursors (inside a write transaction) are closed; held ones stay for the wake. */
static void fb_close(int began) {
  (void)began;
  if (B.held) return;
  sqlite3BtreeCloseCursor(B.posts); sqlite3BtreeCloseCursor(B.users);
  sqlite3BtreeCloseCursor(B.likes); sqlite3BtreeCloseCursor(B.postsIdx);
}

/* ---- records (https://sqlite.org/fileformat2.html#record_format) ---- */

typedef struct FbCol { u64 type; const u8 *p; } FbCol;

/* The cursor's record: its bytes on the page, or copied whole when it spills onto overflow pages. */
static int fb_record(BtCursor *c, const u8 **p, u32 *n) {
  u32 total = sqlite3BtreePayloadSize(c), local;
  const u8 *at = sqlite3BtreePayloadFetch(c, &local);
  if (local >= total) { *p = at; *n = total; return 0; }
  if (total > B.spillCap) {
    u8 *grown = realloc(B.spill, total + 4096);
    if (!grown) return -1;
    B.spill = grown;
    B.spillCap = total + 4096;
  }
  if (sqlite3BtreePayload(c, 0, total, B.spill) != SQLITE_OK) return -1;
  *p = B.spill; *n = total;
  return 0;
}

static const u8 *fb_varint(const u8 *p, const u8 *end, u64 *v) {
  u64 x = 0;
  for (int i = 0; i < 8; i++) {
    if (p >= end) return NULL;
    x = x << 7 | (p[0] & 0x7f);
    if (!(*p++ & 0x80)) { *v = x; return p; }
  }
  if (p >= end) return NULL;
  *v = x << 8 | *p++;
  return p;
}

static u32 fb_len(u64 t) {
  static const u8 fixed[12] = {0, 1, 2, 3, 4, 6, 8, 8, 0, 0, 0, 0};
  return t < 12 ? fixed[t] : (u32)((t - 12) / 2);
}

/* The first n columns of a record; -1 when the record is shorter or malformed. */
static int fb_cols(const u8 *p, u32 size, int n, FbCol *col) {
  const u8 *end = p + size, *h;
  u64 headerSize;
  if (!(h = fb_varint(p, end, &headerSize)) || headerSize > size) return -1;
  const u8 *headerEnd = p + headerSize, *body = headerEnd;
  for (int i = 0; i < n; i++) {
    if (h >= headerEnd || !(h = fb_varint(h, headerEnd, &col[i].type))) return -1;
    col[i].p = body;
    body += fb_len(col[i].type);
  }
  return body <= end ? 0 : -1;
}

static int fb_isInt(const FbCol *c) { return (c->type >= 1 && c->type <= 6) || c->type == 8 || c->type == 9; }
/* Text, or NULL (which the SQL path writes as an empty string). */
static int fb_isText(const FbCol *c) { return c->type == 0 || (c->type >= 13 && (c->type & 1)); }

static i64 fb_int(const FbCol *c) {
  const u8 *p = c->p;
  u64 v = 0;
  switch (c->type) {
    case 8: return 0;
    case 9: return 1;
    case 1: return (int8_t)p[0];
    case 2: return (int16_t)((u16)p[0] << 8 | p[1]);
    case 3: return ((i64)(int8_t)p[0] << 16) | ((u32)p[1] << 8) | p[2];
    case 4: return (int32_t)((u32)p[0] << 24 | (u32)p[1] << 16 | (u32)p[2] << 8 | p[3]);
    case 5: return ((i64)(int16_t)((u16)p[0] << 8 | p[1]) << 32) | ((u32)p[2] << 24 | (u32)p[3] << 16 | (u32)p[4] << 8 | p[5]);
    case 6: for (int i = 0; i < 8; i++) v = v << 8 | p[i]; return (i64)v;
    default: return 0;
  }
}

/* ---- cursor steps: 0 on a row, 1 past the end, -1 on an error ---- */

static int fb_next(BtCursor *c) {
  int rc = sqlite3BtreeNext(c, 0);
  return rc == SQLITE_OK ? 0 : rc == SQLITE_DONE ? 1 : -1;
}

/* The row with this rowid: 0 on it, 1 absent. */
static int fb_seek(BtCursor *c, i64 rowid) {
  int res;
  if (sqlite3BtreeTableMoveto(c, rowid, 0, &res) != SQLITE_OK) return -1;
  return res == 0 && !sqlite3BtreeEof(c) ? 0 : 1;
}

/* The first row whose rowid is >= key. */
static int fb_tableSeekGe(BtCursor *c, i64 key) {
  int res;
  if (sqlite3BtreeTableMoveto(c, key, 0, &res) != SQLITE_OK) return -1;
  if (sqlite3BtreeEof(c)) return 1;
  return res < 0 ? fb_next(c) : 0;
}

/* The first likes_post_id_idx entry whose post_id is >= key. */
static int fb_likesSeekGe(i64 key) {
  Mem m;
  UnpackedRecord r;
  int res;
  memset(&m, 0, sizeof m);
  m.flags = MEM_Int;
  m.u.i = key;
  memset(&r, 0, sizeof r);
  r.pKeyInfo = B.kiLikes;
  r.aMem = &m;
  r.nField = 1;
  r.default_rc = +1;
  if (sqlite3BtreeIndexMoveto(B.likes, &r, &res) != SQLITE_OK) return -1;
  if (sqlite3BtreeEof(B.likes)) return 1;
  return res < 0 ? fb_next(B.likes) : 0;
}

/* Likes of every post id in [lo, hi] into counts[0 .. hi - lo]: one range scan of likes_post_id_idx. */
static int fb_countLikes(i64 lo, i64 hi, i64 *counts) {
  memset(counts, 0, sizeof(i64) * (size_t)(hi - lo + 1));
  int rc = fb_likesSeekGe(lo);
  while (rc == 0) {
    const u8 *p; u32 n; FbCol c[1];
    if (fb_record(B.likes, &p, &n) || fb_cols(p, n, 1, c) || !fb_isInt(&c[0])) return -1;
    i64 post = fb_int(&c[0]);
    if (post > hi) return 0;
    if (post >= lo) counts[post - lo]++;
    rc = fb_next(B.likes);
  }
  return rc < 0 ? -1 : 0;
}

/* The posts row under the cursor into row (its body and created_at copied out of the page). */
static int fb_takePost(FeedBtRow *row) {
  const u8 *p; u32 n; FbCol c[4];
  if (fb_record(B.posts, &p, &n) || fb_cols(p, n, 4, c) || !fb_isInt(&c[1]) || !fb_isText(&c[2]) || !fb_isText(&c[3])) return -1;
  u32 bl = c[2].type ? fb_len(c[2].type) : 0, cl = c[3].type ? fb_len(c[3].type) : 0;
  if (bl + cl > FEEDBT_STAGE) return -1;
  row->user = fb_int(&c[1]);
  row->bodyLen = bl;
  row->createdLen = cl;
  memcpy(row->bytes, c[2].p, bl);
  memcpy(row->bytes + bl, c[3].p, cl);
  return 0;
}

/* The author's name copied after the row's body and created_at: 0 found, 1 absent (the SQL join drops the post), -1 error. */
static int fb_author(FeedBtRow *row) {
  int rc = fb_seek(B.users, row->user);
  if (rc) return rc;
  const u8 *p; u32 n; FbCol c[2];
  if (fb_record(B.users, &p, &n) || fb_cols(p, n, 2, c) || !fb_isText(&c[1])) return -1;
  u32 len = c[1].type ? fb_len(c[1].type) : 0, at = row->bodyLen + row->createdLen;
  if (at + len > FEEDBT_STAGE) return -1;
  memcpy(row->bytes + at, c[1].p, len);
  row->nameLen = len;
  return 0;
}

/* The room one row can need: the fixed parts, two 20-digit numbers, six bytes per escaped byte. */
static i64 fb_room(const FeedBtRow *row) { return 100 + 6 * ((i64)row->bodyLen + row->createdLen + row->nameLen); }

/* One row as the SQL path writes it: {"id":N,"body":"..","created_at":"..","author":"..","like_count":N}. The caller
 * has checked fb_room. */
static int fb_row(const FeedBtRow *row, char *dst) {
  int w = 0;
  const u8 *created = row->bytes + row->bodyLen, *name = created + row->createdLen;
#define FB_PUT(lit) do { memcpy(dst + w, lit, sizeof(lit) - 1); w += (int)sizeof(lit) - 1; } while (0)
  FB_PUT("{\"id\":");
  w += feed_i64(dst + w, row->id);
  FB_PUT(",\"body\":\"");
  w += feed_json_text(row->bytes, (int)row->bodyLen, dst + w);
  FB_PUT("\",\"created_at\":\"");
  w += feed_json_text(created, (int)row->createdLen, dst + w);
  FB_PUT("\",\"author\":\"");
  w += feed_json_text(name, (int)row->nameLen, dst + w);
  FB_PUT("\",\"like_count\":");
  w += feed_i64(dst + w, row->likes);
  dst[w++] = '}';
#undef FB_PUT
  return w;
}

/* minus the room, as the callers return it (bounded so it stays below -1 and inside an int) */
static int fb_ask(i64 need) { return need > 0x3fffffff ? -0x3fffffff : (int)-need; }

/* ---- the plans ---- */

static int fb_feed(char *dst, int cap) {
  int n = 0, rc;
  int empty;
  if (sqlite3BtreeFirst(B.postsIdx, &empty) != SQLITE_OK) return -1;
  rc = empty ? 1 : 0;
  while (rc == 0 && n < FEEDBT_N) {
    const u8 *p; u32 size; FbCol c[2];
    if (fb_record(B.postsIdx, &p, &size) || fb_cols(p, size, 2, c) || !fb_isInt(&c[1])) return -1;
    B.rows[n++].id = fb_int(&c[1]);
    rc = fb_next(B.postsIdx);
  }
  if (rc < 0) return -1;
  i64 lo = B.rows[0].id, hi = lo;
  for (int i = 1; i < n; i++) { if (B.rows[i].id < lo) lo = B.rows[i].id; if (B.rows[i].id > hi) hi = B.rows[i].id; }
  if (n > 0 && hi - lo < FEEDBT_SPAN) {
    /* The ids are near each other: one range scan for the likes, one for the rows. */
    i64 counts[FEEDBT_SPAN];
    signed char slot[FEEDBT_SPAN];
    int found = 0;
    if (fb_countLikes(lo, hi, counts)) return -1;
    memset(slot, -1, sizeof slot);
    for (int i = 0; i < n; i++) { slot[B.rows[i].id - lo] = (signed char)i; B.rows[i].likes = counts[B.rows[i].id - lo]; }
    rc = fb_tableSeekGe(B.posts, lo);
    while (rc == 0) {
      i64 id = sqlite3BtreeIntegerKey(B.posts);
      if (id > hi) break;
      int i = slot[id - lo];
      if (i >= 0) {
        if (fb_takePost(&B.rows[i])) return -1;
        if (++found == n) break;
      }
      rc = fb_next(B.posts);
    }
    if (rc < 0 || found != n) return -1; /* a row the index names is missing: SQL decides */
  } else {
    /* Ids far apart: each one sought on its own. */
    for (int i = 0; i < n; i++) {
      i64 id = B.rows[i].id, likes = 0;
      if (fb_seek(B.posts, id) != 0 || fb_takePost(&B.rows[i])) return -1;
      rc = fb_likesSeekGe(id);
      while (rc == 0) {
        const u8 *p; u32 size; FbCol c[1];
        if (fb_record(B.likes, &p, &size) || fb_cols(p, size, 1, c) || !fb_isInt(&c[0])) return -1;
        if (fb_int(&c[0]) != id) break;
        likes++;
        rc = fb_next(B.likes);
      }
      if (rc < 0) return -1;
      B.rows[i].likes = likes;
    }
  }
  /* Every author, then the exact room, then the JSON: a short buffer is told the whole size before anything is written. */
  i64 need = 12;
  for (int i = 0; i < n; i++) {
    if (fb_author(&B.rows[i])) return -1; /* an author is missing: the SQL join drops the post, so SQL decides */
    need += fb_room(&B.rows[i]) + 1;
  }
  if (need > cap) return fb_ask(need);
  int w = 10;
  memcpy(dst, "{\"posts\":[", 10);
  for (int i = 0; i < n; i++) {
    if (i) dst[w++] = ',';
    w += fb_row(&B.rows[i], dst + w);
  }
  dst[w++] = ']';
  dst[w++] = '}';
  return w;
}

static int fb_post(i64 id, char *dst, int cap) {
  FeedBtRow *row = &B.rows[0];
  int rc = fb_seek(B.posts, id);
  if (rc) return rc < 0 ? -1 : 0;
  if (fb_takePost(row)) return -1;
  row->id = id;
  row->likes = 0;
  rc = fb_likesSeekGe(id);
  while (rc == 0) {
    const u8 *p; u32 size; FbCol c[1];
    if (fb_record(B.likes, &p, &size) || fb_cols(p, size, 1, c) || !fb_isInt(&c[0])) return -1;
    if (fb_int(&c[0]) != id) break;
    row->likes++;
    rc = fb_next(B.likes);
  }
  if (rc < 0) return -1;
  rc = fb_author(row);
  if (rc < 0) return -1;
  if (rc > 0) return 0; /* no author: the SQL join finds no row */
  i64 need = fb_room(row) + 9;
  if (need > cap) return fb_ask(need);
  memcpy(dst, "{\"post\":", 8);
  int k = fb_row(row, dst + 8);
  dst[8 + k] = '}';
  return 9 + k;
}

int feedbt_feed(char *dst, int cap) {
  int began, rc;
  if (!B.ok) return -1;
  rc = fb_open(&began) ? -1 : fb_feed(dst, cap);
  fb_close(began);
  return rc;
}

int feedbt_post(long long id, char *dst, int cap) {
  int began, rc;
  if (!B.ok) return -1;
  rc = fb_open(&began) ? -1 : fb_post(id, dst, cap);
  fb_close(began);
  return rc;
}
