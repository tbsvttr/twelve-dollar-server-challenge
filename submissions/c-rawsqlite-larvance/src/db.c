#include "rt.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <time.h>

typedef struct {
  i64 id;
  u8 body[2048];
  u32 body_len;
  u8 created_at[64];
  u32 created_at_len;
  u8 author[128];
  u32 author_len;
  i64 like_count;
} db_post_view_t;

typedef struct {
  db_post_view_t items[20];
  int count;
} db_feed_result_t;

static sqlite3 *db;
static Btree *db_bt;
static sqlite3_stmt *stmt_begin, *stmt_commit, *stmt_rollback;
static sqlite3_stmt *stmt_health, *stmt_insert_like, *stmt_insert_post;

#define CKPT_THRESHOLD 1000
#define WAL_HIGH_LIMIT 16384

static sqlite3 *ckpt_db;
static pthread_mutex_t ckpt_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t ckpt_signal = PTHREAD_COND_INITIALIZER;
static int ckpt_needed = 0;
static int wal_frame_count = 0;

static int on_wal_commit(void *arg, sqlite3 *d, const char *name, int frames) {
  (void)arg; (void)d; (void)name;
  wal_frame_count = frames;
  if (frames >= CKPT_THRESHOLD && !__atomic_load_n(&ckpt_needed, __ATOMIC_RELAXED)) {
    pthread_mutex_lock(&ckpt_lock);
    ckpt_needed = 1;
    pthread_cond_signal(&ckpt_signal);
    pthread_mutex_unlock(&ckpt_lock);
  }
  return SQLITE_OK;
}

static void *checkpoint_worker(void *arg) {
  (void)arg;
  for (;;) {
    pthread_mutex_lock(&ckpt_lock);
    while (!ckpt_needed) pthread_cond_wait(&ckpt_signal, &ckpt_lock);
    pthread_mutex_unlock(&ckpt_lock);
    int log_sz = 0, ckpt_sz = 0;
    int rc = sqlite3_wal_checkpoint_v2(ckpt_db, "main", SQLITE_CHECKPOINT_PASSIVE, &log_sz, &ckpt_sz);
    if (rc != SQLITE_OK && rc != SQLITE_BUSY) fprintf(stderr, "checkpoint: %s\n", sqlite3_errmsg(ckpt_db));
    __atomic_store_n(&ckpt_needed, 0, __ATOMIC_RELEASE);
  }
  return NULL;
}

static void ckpt_init(const char *path) {
  if (sqlite3_open_v2(path, &ckpt_db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, 0) != SQLITE_OK) {
    fprintf(stderr, "ckpt open failed\n"); exit(1);
  }
  sqlite3_exec(ckpt_db, "PRAGMA synchronous = NORMAL", 0, 0, 0);
  pthread_t th;
  if (pthread_create(&th, 0, checkpoint_worker, 0)) { perror("pthread_create"); exit(1); }
  pthread_detach(th);
}

static Pgno root_posts = 0;
static Pgno root_users = 0;
static Pgno root_likes_idx = 0;
static KeyInfo *keyinfo_likes_idx = NULL;

static Pgno lookup_schema_rootpage(const char *target_name) {
  sqlite3_stmt *s = NULL;
  if (sqlite3_prepare_v3(db, "SELECT rootpage FROM sqlite_schema WHERE name = ?1", -1, SQLITE_PREPARE_PERSISTENT, &s, NULL) != SQLITE_OK) {
    abort();
  }
  sqlite3_bind_text(s, 1, target_name, -1, SQLITE_STATIC);
  Pgno pg = (sqlite3_step(s) == SQLITE_ROW) ? (Pgno)sqlite3_column_int64(s, 0) : 0;
  sqlite3_finalize(s);
  if (!pg) { fprintf(stderr, "schema error for %s\n", target_name); exit(1); }
  return pg;
}

static void db_open(const char *path) {
  if (sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, 0) != SQLITE_OK) {
    fprintf(stderr, "db open failed\n"); exit(1);
  }
  sqlite3_exec(db, "PRAGMA journal_mode = WAL", 0, 0, 0);
  sqlite3_exec(db, "PRAGMA synchronous = NORMAL", 0, 0, 0);
  sqlite3_exec(db, "PRAGMA temp_store = MEMORY", 0, 0, 0);
  sqlite3_exec(db, "PRAGMA cache_size = -4096", 0, 0, 0);
  sqlite3_exec(db, "PRAGMA mmap_size = 1073741824", 0, 0, 0);
  sqlite3_wal_hook(db, on_wal_commit, 0);
  db_bt = db->aDb[0].pBt;

  sqlite3_prepare_v3(db, "BEGIN", -1, SQLITE_PREPARE_PERSISTENT, &stmt_begin, 0);
  sqlite3_prepare_v3(db, "COMMIT", -1, SQLITE_PREPARE_PERSISTENT, &stmt_commit, 0);
  sqlite3_prepare_v3(db, "ROLLBACK", -1, SQLITE_PREPARE_PERSISTENT, &stmt_rollback, 0);
  sqlite3_prepare_v3(db, "SELECT 1", -1, SQLITE_PREPARE_PERSISTENT, &stmt_health, 0);
  sqlite3_prepare_v3(db, "INSERT INTO likes (user_id, post_id) VALUES (?1, ?2) ON CONFLICT (user_id, post_id) DO NOTHING", -1, SQLITE_PREPARE_PERSISTENT, &stmt_insert_like, 0);
  sqlite3_prepare_v3(db, "INSERT INTO posts (user_id, body) VALUES (?1, ?2) RETURNING id, created_at", -1, SQLITE_PREPARE_PERSISTENT, &stmt_insert_post, 0);

  root_posts = lookup_schema_rootpage("posts");
  root_users = lookup_schema_rootpage("users");
  root_likes_idx = lookup_schema_rootpage("likes_post_id_idx");

  keyinfo_likes_idx = sqlite3KeyInfoAlloc(db, 1, 1);
  if (!keyinfo_likes_idx) abort();
  keyinfo_likes_idx->aColl[0] = db->pDfltColl;
  keyinfo_likes_idx->aColl[1] = db->pDfltColl;

  ckpt_init(path);
}

static BtCursor *cursor_posts = NULL;
static BtCursor *cursor_users = NULL;
static BtCursor *cursor_likes = NULL;

static BtCursor *alloc_cursor(Pgno root, KeyInfo *ki) {
  BtCursor *c = malloc((size_t)sqlite3BtreeCursorSize());
  if (!c) abort();
  sqlite3BtreeCursorZero(c);
  if (sqlite3BtreeCursor(db_bt, root, 0, ki, c) != SQLITE_OK) abort();
  return c;
}

static void free_cursor(BtCursor **pc) {
  if (*pc) {
    sqlite3BtreeCloseCursor(*pc);
    free(*pc);
    *pc = NULL;
  }
}

static u8 *spill_mem = NULL;
static u32 spill_capacity = 0;

static const u8 *cursor_fetch_record(BtCursor *cur, u32 *out_len) {
  u32 total = sqlite3BtreePayloadSize(cur);
  *out_len = total;
  u32 local_bytes = 0;
  const u8 *ptr = sqlite3BtreePayloadFetch(cur, &local_bytes);
  if (__builtin_expect(local_bytes == total, 1)) return ptr;

  if (total > spill_capacity) {
    free(spill_mem);
    spill_capacity = total + 4096;
    spill_mem = malloc(spill_capacity);
    if (!spill_mem) abort();
  }
  if (sqlite3BtreePayload(cur, 0, total, spill_mem) != SQLITE_OK) return NULL;
  return spill_mem;
}

static inline const u8 *get_varint(const u8 *p, u64 *val) {
  u8 b0 = p[0];
  if (__builtin_expect((b0 & 0x80) == 0, 1)) {
    *val = b0;
    return p + 1;
  }
  u8 b1 = p[1];
  if ((b1 & 0x80) == 0) {
    *val = ((u64)(b0 & 0x7f) << 7) | b1;
    return p + 2;
  }
  u8 b2 = p[2];
  if ((b2 & 0x80) == 0) {
    *val = ((u64)(b0 & 0x7f) << 14) | ((u64)(b1 & 0x7f) << 7) | b2;
    return p + 3;
  }
  u64 x = ((u64)(b0 & 0x7f) << 14) | ((u64)(b1 & 0x7f) << 7) | (b2 & 0x7f);
  p += 3;
  for (int i = 0; i < 5; i++) {
    u8 b = *p++;
    x = (x << 7) | (b & 0x7f);
    if ((b & 0x80) == 0) { *val = x; return p; }
  }
  *val = (x << 8) | *p++;
  return p;
}

static inline u32 serial_type_size(u64 st) {
  if (st <= 4) return (u32)st;
  if (st == 5) return 6;
  if (st == 6 || st == 7) return 8;
  if (st <= 9) return 0;
  if (st >= 12) return (u32)((st - 12) >> 1);
  return 0;
}

static inline i64 decode_record_int(u64 st, const u8 *src) {
  if (st == 1) return (int8_t)src[0];
  if (st == 2) return (int16_t)(((u16)src[0] << 8) | src[1]);
  if (st == 3) {
    u32 v = ((u32)src[0] << 16) | ((u32)src[1] << 8) | src[2];
    return (v & 0x800000) ? (i64)(v | 0xff000000U) : (i64)v;
  }
  if (st == 4) {
    u32 v;
    memcpy(&v, src, 4);
    return (int32_t)__builtin_bswap32(v);
  }
  if (st == 5) {
    u64 hi = (int16_t)(((u16)src[0] << 8) | src[1]);
    u32 lo;
    memcpy(&lo, src + 2, 4);
    return (i64)((hi << 32) | __builtin_bswap32(lo));
  }
  if (st == 6) {
    u64 v;
    memcpy(&v, src, 8);
    return (i64)__builtin_bswap64(v);
  }
  if (st == 8) return 0;
  if (st == 9) return 1;
  return 0;
}

static inline int extract_post_row(const u8 *payload, u32 len, i64 *uid, const u8 **body, u32 *body_len, const u8 **created, u32 *created_len) {
  u64 hlen = 0;
  const u8 *p = get_varint(payload, &hlen);
  if (__builtin_expect(!p || hlen > len, 0)) return -1;
  const u8 *hend = payload + hlen;

  u64 t0 = 0, t1 = 0, t2 = 0, t3 = 0;
  p = get_varint(p, &t0); if (!p || p >= hend) return -1;
  p = get_varint(p, &t1); if (!p || p >= hend) return -1;
  p = get_varint(p, &t2); if (!p || p >= hend) return -1;
  p = get_varint(p, &t3); if (!p || p > hend) return -1;

  const u8 *data = hend + serial_type_size(t0);
  *uid = decode_record_int(t1, data);
  data += serial_type_size(t1);

  *body_len = serial_type_size(t2);
  *body = data;
  data += *body_len;

  *created_len = serial_type_size(t3);
  *created = data;
  data += *created_len;

  return __builtin_expect(data <= payload + len, 1) ? 0 : -1;
}

static inline int extract_user_row(const u8 *payload, u32 len, const u8 **name, u32 *name_len) {
  u64 hlen = 0;
  const u8 *p = get_varint(payload, &hlen);
  if (__builtin_expect(!p || hlen > len, 0)) return -1;
  const u8 *hend = payload + hlen;

  u64 t0 = 0, t1 = 0;
  p = get_varint(p, &t0); if (!p || p >= hend) return -1;
  p = get_varint(p, &t1); if (!p || p > hend) return -1;

  const u8 *data = hend + serial_type_size(t0);
  *name_len = serial_type_size(t1);
  *name = data;

  return __builtin_expect(data + *name_len <= payload + len, 1) ? 0 : -1;
}

static int seek_likes_for_post(i64 post_id) {
  Mem m;
  memset(&m, 0, sizeof(m));
  m.flags = MEM_Int;
  m.u.i = post_id;

  UnpackedRecord probe;
  memset(&probe, 0, sizeof(probe));
  probe.pKeyInfo = keyinfo_likes_idx;
  probe.aMem = &m;
  probe.nField = 1;
  probe.default_rc = 1;

  int res = 0;
  if (sqlite3BtreeIndexMoveto(cursor_likes, &probe, &res) != SQLITE_OK) return -1;
  if (res < 0) {
    int rc = sqlite3BtreeNext(cursor_likes, 0);
    if (rc == SQLITE_DONE) return 1;
    if (rc != SQLITE_OK) return -1;
  }
  return sqlite3BtreeEof(cursor_likes) ? 1 : 0;
}

static inline int extract_index_post_id(const u8 *payload, u32 len, i64 *out_pid) {
  u64 hlen = 0;
  const u8 *p = get_varint(payload, &hlen);
  if (__builtin_expect(!p || hlen > len, 0)) return -1;
  const u8 *hend = payload + hlen;
  u64 t0 = 0;
  p = get_varint(p, &t0);
  if (__builtin_expect(!p || p > hend, 0)) return -1;
  *out_pid = decode_record_int(t0, hend);
  return 0;
}

static int tally_likes_span(i64 lo, i64 hi, i64 *counts) {
  memset(counts, 0, sizeof(i64) * (size_t)(hi - lo + 1));
  int rc = seek_likes_for_post(lo);
  while (rc == 0) {
    u32 len = 0;
    const u8 *payload = cursor_fetch_record(cursor_likes, &len);
    if (!payload) return -1;
    i64 pid = 0;
    if (extract_index_post_id(payload, len, &pid) != 0) return -1;
    if (pid > hi) break;
    if (pid >= lo) counts[pid - lo]++;
    int step_rc = sqlite3BtreeNext(cursor_likes, 0);
    if (step_rc == SQLITE_DONE) break;
    if (step_rc != SQLITE_OK) return -1;
  }
  return 0;
}

static int db_fetch_author(i64 user_id, const u8 **out_name, u32 *out_len) {
  int res = 0;
  if (sqlite3BtreeTableMoveto(cursor_users, user_id, 0, &res) != SQLITE_OK) return -1;
  if (res != 0) return -1;
  u32 len = 0;
  const u8 *payload = cursor_fetch_record(cursor_users, &len);
  if (!payload) return -1;
  return extract_user_row(payload, len, out_name, out_len);
}

int db_get_post(i64 post_id, db_post_view_t *view) {
  int res = 0;
  if (sqlite3BtreeTableMoveto(cursor_posts, post_id, 0, &res) != SQLITE_OK) return -1;
  if (res != 0) return 1;
  u32 len = 0;
  const u8 *payload = cursor_fetch_record(cursor_posts, &len);
  if (!payload) return -1;
  i64 uid = 0;
  const u8 *pbody = NULL, *pcreated = NULL;
  u32 blen = 0, clen = 0;
  if (extract_post_row(payload, len, &uid, &pbody, &blen, &pcreated, &clen) != 0) {
    return -1;
  }
  if (blen >= sizeof(view->body)) blen = sizeof(view->body) - 1;
  if (clen >= sizeof(view->created_at)) clen = sizeof(view->created_at) - 1;
  memcpy(view->body, pbody, blen);
  view->body_len = blen;
  memcpy(view->created_at, pcreated, clen);
  view->created_at_len = clen;
  view->id = post_id;

  const u8 *pauthor = NULL;
  u32 alen = 0;
  if (db_fetch_author(uid, &pauthor, &alen) != 0) return -1;
  if (alen >= sizeof(view->author)) alen = sizeof(view->author) - 1;
  memcpy(view->author, pauthor, alen);
  view->author_len = alen;

  view->like_count = 0;
  if (tally_likes_span(post_id, post_id, &view->like_count) != 0) return -1;
  return 0;
}

int db_get_feed(db_feed_result_t *feed) {
  feed->count = 0;
  int empty = 0;
  if (sqlite3BtreeLast(cursor_posts, &empty) != SQLITE_OK) return -1;
  if (empty) return 0;

  i64 uids[20];
  int n = 0;
  for (int i = 0; i < 20; i++) {
    feed->items[n].id = sqlite3BtreeIntegerKey(cursor_posts);
    u32 len = 0;
    const u8 *payload = cursor_fetch_record(cursor_posts, &len);
    if (!payload) return -1;
    const u8 *pbody = NULL, *pcreated = NULL;
    u32 blen = 0, clen = 0;
    if (extract_post_row(payload, len, &uids[n], &pbody, &blen, &pcreated, &clen) != 0) {
      return -1;
    }
    if (blen >= sizeof(feed->items[n].body)) blen = sizeof(feed->items[n].body) - 1;
    if (clen >= sizeof(feed->items[n].created_at)) clen = sizeof(feed->items[n].created_at) - 1;
    memcpy(feed->items[n].body, pbody, blen);
    feed->items[n].body_len = blen;
    memcpy(feed->items[n].created_at, pcreated, clen);
    feed->items[n].created_at_len = clen;
    n++;
    int step_rc = sqlite3BtreePrevious(cursor_posts, 0);
    if (step_rc != SQLITE_OK) break;
  }

  if (n == 0) return 0;
  i64 hi = feed->items[0].id;
  i64 lo = feed->items[n - 1].id;
  if (hi - lo < 64) {
    i64 counts[64];
    if (tally_likes_span(lo, hi, counts) != 0) return -1;
    for (int i = 0; i < n; i++) {
      feed->items[i].like_count = counts[feed->items[i].id - lo];
      const u8 *pauthor = NULL;
      u32 alen = 0;
      if (db_fetch_author(uids[i], &pauthor, &alen) != 0) return -1;
      if (alen >= sizeof(feed->items[i].author)) alen = sizeof(feed->items[i].author) - 1;
      memcpy(feed->items[i].author, pauthor, alen);
      feed->items[i].author_len = alen;
    }
  } else {
    for (int i = 0; i < n; i++) {
      feed->items[i].like_count = 0;
      if (tally_likes_span(feed->items[i].id, feed->items[i].id, &feed->items[i].like_count) != 0) return -1;
      const u8 *pauthor = NULL;
      u32 alen = 0;
      if (db_fetch_author(uids[i], &pauthor, &alen) != 0) return -1;
      if (alen >= sizeof(feed->items[i].author)) alen = sizeof(feed->items[i].author) - 1;
      memcpy(feed->items[i].author, pauthor, alen);
      feed->items[i].author_len = alen;
    }
  }
  feed->count = n;
  return 0;
}

int db_like_post(i64 user_id, i64 post_id, int *out_already_liked) {
  int res = 0;
  if (sqlite3BtreeTableMoveto(cursor_posts, post_id, 0, &res) != SQLITE_OK) return -1;
  if (res != 0) return 1;

  sqlite3_bind_int64(stmt_insert_like, 1, user_id);
  sqlite3_bind_int64(stmt_insert_like, 2, post_id);
  int rc = sqlite3_step(stmt_insert_like);
  sqlite3_reset(stmt_insert_like);
  if (rc != SQLITE_DONE) return -1;

  *out_already_liked = (sqlite3_changes(db) != 1);
  return 0;
}

int db_create_post(i64 user_id, const u8 *body, u32 body_len, i64 *out_id, u8 out_created[64], u32 *out_created_len) {
  sqlite3_bind_int64(stmt_insert_post, 1, user_id);
  sqlite3_bind_text(stmt_insert_post, 2, (const char *)body, (int)body_len, SQLITE_STATIC);
  int rc = sqlite3_step(stmt_insert_post);
  if (rc != SQLITE_ROW) {
    sqlite3_reset(stmt_insert_post);
    return -1;
  }
  *out_id = sqlite3_column_int64(stmt_insert_post, 0);
  const u8 *txt = sqlite3_column_text(stmt_insert_post, 1);
  u32 len = (u32)sqlite3_column_bytes(stmt_insert_post, 1);
  if (len >= 64) len = 63;
  memcpy(out_created, txt, len);
  out_created[len] = '\0';
  *out_created_len = len;
  sqlite3_reset(stmt_insert_post);
  return 0;
}

int db_health_check(void) {
  int rc = sqlite3_step(stmt_health);
  sqlite3_reset(stmt_health);
  return (rc == SQLITE_ROW) ? 0 : -1;
}

static void db_wal_bound(void) {
  if (wal_frame_count < WAL_HIGH_LIMIT || __atomic_load_n(&ckpt_needed, __ATOMIC_ACQUIRE)) return;
  int log_sz = 0, ckpt_sz = 0;
  int rc = sqlite3_wal_checkpoint_v2(db, "main", SQLITE_CHECKPOINT_PASSIVE, &log_sz, &ckpt_sz);
  if (rc == SQLITE_OK) wal_frame_count = 0;
}

void db_batch_begin(void) {
  sqlite3_step(stmt_begin);
  sqlite3_reset(stmt_begin);
  if (sqlite3BtreeBeginTrans(db_bt, 0, 0) != SQLITE_OK) abort();
  cursor_posts = alloc_cursor(root_posts, NULL);
  cursor_users = alloc_cursor(root_users, NULL);
  cursor_likes = alloc_cursor(root_likes_idx, keyinfo_likes_idx);
}

int db_batch_end(int has_writes) {
  free_cursor(&cursor_posts);
  free_cursor(&cursor_users);
  free_cursor(&cursor_likes);
  (void)has_writes;
  int rc = sqlite3_step(stmt_commit);
  sqlite3_reset(stmt_commit);
  if (rc == SQLITE_DONE) {
    db_wal_bound();
    return 0;
  }
  sqlite3_step(stmt_rollback);
  sqlite3_reset(stmt_rollback);
  return -1;
}
