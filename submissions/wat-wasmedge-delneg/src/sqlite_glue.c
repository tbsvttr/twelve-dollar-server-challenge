// The only C in this entry besides stock SQLite and wasi-libc. It compiles the pinned, unmodified
// amalgamation into a WASI reactor module (one translation unit, so SQLite's internal B-tree calls are
// reachable) and exports the calls the hand-written WAT server uses: the public SQL API, and one-line
// wrappers over SQLite's B-tree cursor layer. No request logic lives here: which cursors to open, what
// to seek, how to decode records and when to fall back to SQL are all decided in src/app.wat.
#include "sqlite3.c"
#include <stdlib.h>

_Static_assert(SQLITE_VERSION_NUMBER == 3054001, "the B-tree wrappers below are checked against SQLite 3.54.1");

#define X(name) __attribute__((export_name(#name)))
// The page cache is SQLite's default one, wrapped through the public SQLITE_CONFIG_PCACHE2 interface.
// balance_nonroot swaps two pages through a temporary key, the lock-byte page's number (262,145 at 4 KiB),
// which raises the default cache's highest key; each commit's xTruncate(dbSize + 1) then walks its whole
// hash table (~250 us at 8,192 slots) looking for pages past the end that are not there. The wrapper keeps
// its own highest key, leaving out that temporary one (the page moves on to a real number before
// balance_nonroot returns), and skips xTruncate when no page can be at or above the limit.
static sqlite3_pcache_methods2 pc_base;
static unsigned pc_tmp;
typedef struct { sqlite3_pcache *c; unsigned max; } PcWrap;
static int pc_init(void *a) { return pc_base.xInit ? pc_base.xInit(a) : SQLITE_OK; }
static void pc_shutdown(void *a) { if (pc_base.xShutdown) pc_base.xShutdown(a); }
static sqlite3_pcache *pc_create(int szPage, int szExtra, int bPurgeable) {
  PcWrap *w = sqlite3_malloc(sizeof *w); if (!w) return 0;
  if (!(w->c = pc_base.xCreate(szPage, szExtra, bPurgeable))) { sqlite3_free(w); return 0; }
  w->max = 0; pc_tmp = (unsigned)PENDING_BYTE / (unsigned)szPage + 1; return (sqlite3_pcache *)w;
}
#define PW ((PcWrap *)p)
static void pc_cachesize(sqlite3_pcache *p, int n) { pc_base.xCachesize(PW->c, n); }
static int pc_pagecount(sqlite3_pcache *p) { return pc_base.xPagecount(PW->c); }
static sqlite3_pcache_page *pc_fetch(sqlite3_pcache *p, unsigned key, int create) {
  sqlite3_pcache_page *pg = pc_base.xFetch(PW->c, key, create);
  if (pg && key > PW->max) PW->max = key;
  return pg;
}
static void pc_unpin(sqlite3_pcache *p, sqlite3_pcache_page *pg, int discard) { pc_base.xUnpin(PW->c, pg, discard); }
static void pc_rekey(sqlite3_pcache *p, sqlite3_pcache_page *pg, unsigned from, unsigned to) {
  pc_base.xRekey(PW->c, pg, from, to);
  if (to > PW->max && to != pc_tmp) PW->max = to;
}
static void pc_truncate(sqlite3_pcache *p, unsigned limit) {
  if (limit > PW->max) return;   // no page has a key >= limit
  pc_base.xTruncate(PW->c, limit);
  PW->max = limit ? limit - 1 : 0;
}
static void pc_destroy(sqlite3_pcache *p) { pc_base.xDestroy(PW->c); sqlite3_free(p); }
static void pc_shrink(sqlite3_pcache *p) { if (pc_base.xShrink) pc_base.xShrink(PW->c); }
X(db_open) int db_open(const char *path, sqlite3 **db) {
  static int done;
  if (!done) {
    static sqlite3_pcache_methods2 m;
    if (sqlite3_config(SQLITE_CONFIG_GETPCACHE2, &pc_base) == SQLITE_OK) {
      m = pc_base; m.xInit = pc_init; m.xShutdown = pc_shutdown; m.xCreate = pc_create; m.xCachesize = pc_cachesize;
      m.xPagecount = pc_pagecount; m.xFetch = pc_fetch; m.xUnpin = pc_unpin; m.xRekey = pc_rekey;
      m.xTruncate = pc_truncate; m.xDestroy = pc_destroy; m.xShrink = pc_shrink;
      sqlite3_config(SQLITE_CONFIG_PCACHE2, &m);
    }
    done = 1;
  }
  int rc = sqlite3_initialize();
  if (rc) return rc;
  return sqlite3_open_v2(path, db, SQLITE_OPEN_READWRITE, "unix-none");
}
X(db_exec) int db_exec(sqlite3 *db, const char *sql) { return sqlite3_exec(db, sql, 0, 0, 0); }
X(db_prepare) int db_prepare(sqlite3 *db, const char *sql, sqlite3_stmt **st) {
  return sqlite3_prepare_v3(db, sql, -1, SQLITE_PREPARE_PERSISTENT, st, 0);
}
X(st_bind_int64) int st_bind_int64(sqlite3_stmt *s, int i, long long v) { return sqlite3_bind_int64(s, i, v); }
X(st_bind_text) int st_bind_text(sqlite3_stmt *s, int i, const char *p, int n) { return sqlite3_bind_text(s, i, p, n, SQLITE_STATIC); }
X(st_step) int st_step(sqlite3_stmt *s) { return sqlite3_step(s); }
X(st_reset) int st_reset(sqlite3_stmt *s) { return sqlite3_reset(s); }
X(st_int64) long long st_int64(sqlite3_stmt *s, int i) { return sqlite3_column_int64(s, i); }
X(st_text) const unsigned char *st_text(sqlite3_stmt *s, int i) { return sqlite3_column_text(s, i); }
X(st_bytes) int st_bytes(sqlite3_stmt *s, int i) { return sqlite3_column_bytes(s, i); }
X(db_changes) int db_changes(sqlite3 *db) { return sqlite3_changes(db); }
X(db_last_rowid) long long db_last_rowid(sqlite3 *db) { return sqlite3_last_insert_rowid(db); }
X(db_errmsg) const char *db_errmsg(sqlite3 *db) { return sqlite3_errmsg(db); }
// checkpoints, all through SQLite's public API: the WAL hook records the WAL's size after each commit, and
// the WAT runs a PASSIVE checkpoint once it is over CKPT_FRAMES (or lets SQLite's autocheckpoint do it)
static int wal_n;
static int wal_cb(void *a, sqlite3 *db, const char *name, int n) { (void)a; (void)db; (void)name; wal_n = n; return SQLITE_OK; }
X(db_walhook) void db_walhook(sqlite3 *db) { sqlite3_wal_hook(db, wal_cb, 0); }
X(wal_frames) int wal_frames(void) { return wal_n; }
X(db_autockpt) int db_autockpt(sqlite3 *db, int n) { return sqlite3_wal_autocheckpoint(db, n); }
X(db_checkpoint) int db_checkpoint(sqlite3 *db) {
  int log = 0, ck = 0; wal_n = 0;
  return sqlite3_wal_checkpoint_v2(db, 0, SQLITE_CHECKPOINT_PASSIVE, &log, &ck);
}
X(db_autocommit) int db_autocommit(sqlite3 *db) { return sqlite3_get_autocommit(db); }
X(db_utf8) int db_utf8(sqlite3 *db) { return ENC(db) == SQLITE_UTF8; }
X(env_get) const char *env_get(const char *name) { return getenv(name); }
X(mem_alloc) void *mem_alloc(unsigned long n) { return malloc(n); }
X(mem_free) void mem_free(void *p) { free(p); }
X(mem_realloc) void *mem_realloc(void *p, unsigned long n) { return realloc(p, n); }

// ---- B-tree layer: pager, page cache, WAL and locks stay SQLite's; only the bytecode engine is skipped
X(bt_of) Btree *bt_of(sqlite3 *db) { return db->aDb[0].pBt; }
// starts (or joins) the read transaction and writes the schema cookie to *cookie
X(bt_read) int bt_read(Btree *bt, u32 *cookie) {
  int rc = sqlite3BtreeBeginTrans(bt, 0, 0);
  if (rc == SQLITE_OK) sqlite3BtreeGetMeta(bt, BTREE_SCHEMA_VERSION, cookie);
  return rc;
}
X(key_info) KeyInfo *key_info(sqlite3 *db, int nKey, int nExtra) { return sqlite3KeyInfoAlloc(db, nKey, nExtra); }
X(cur_size) int cur_size(void) { return sqlite3BtreeCursorSize(); }
X(cur_open) int cur_open(Btree *bt, int root, KeyInfo *k, BtCursor *c) {
  memset(c, 0, (size_t)sqlite3BtreeCursorSize());
  sqlite3BtreeCursorZero(c);
  return sqlite3BtreeCursor(bt, (Pgno)root, 0, k, c);
}
X(cur_close) int cur_close(BtCursor *c) { return sqlite3BtreeCloseCursor(c); }
X(cur_first) int cur_first(BtCursor *c, int *res) { return sqlite3BtreeFirst(c, res); }
X(cur_next) int cur_next(BtCursor *c) { return sqlite3BtreeNext(c, 0); }
X(cur_prev) int cur_prev(BtCursor *c) { return sqlite3BtreePrevious(c, 0); }
X(cur_eof) int cur_eof(BtCursor *c) { return sqlite3BtreeEof(c); }
X(cur_rowid) long long cur_rowid(BtCursor *c) { return sqlite3BtreeIntegerKey(c); }
X(cur_seek_rowid) int cur_seek_rowid(BtCursor *c, long long key, int *res) { return sqlite3BtreeTableMoveto(c, key, 0, res); }
// seeks an index on its first column, an integer; default_rc says where entries equal to the key sort
X(cur_seek_int) int cur_seek_int(BtCursor *c, KeyInfo *k, long long key, int default_rc, int *res) {
  Mem m; memset(&m, 0, sizeof m); m.flags = MEM_Int; m.u.i = key;
  UnpackedRecord r; memset(&r, 0, sizeof r);
  r.pKeyInfo = k; r.aMem = &m; r.nField = 1; r.default_rc = (i8)default_rc;
  return sqlite3BtreeIndexMoveto(c, &r, res);
}
X(cur_payload_size) unsigned cur_payload_size(BtCursor *c) { return sqlite3BtreePayloadSize(c); }
// the record's bytes on the cursor's page; *amt = how many are there (fewer than the size: overflow)
X(cur_payload) const u8 *cur_payload(BtCursor *c, u32 *amt) { return sqlite3BtreePayloadFetch(c, amt); }
