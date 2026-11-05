/* Storage primitives over SQLite. Compiled in the same translation unit as the amalgamation
 * (server.c includes sqlite3.c first), so reads can use SQLite's B-tree cursors directly: the
 * pager, WAL, locking and page cache are SQLite's own, only the bytecode engine is skipped.
 * Writes are prepared SQL statements.
 *
 * The SQLite helpers, the record decoding, the payload fetch (cur_payload) and the index seek
 * (likes_seek_ge) started from lean-derive-hargup's runtime/db.c (#153); c-iouring-pavlyhalim's
 * src/btree.h has the same three. The descent for several keys at once (lookup_many, page_key,
 * page_lower_bound, hit_record) is adapted from that src/btree.h (#233, kept in #245), and
 * lookup_sorted, find_rowid and it_lower use its guess inside a page.
 *
 * Every primitive is called from Lean (Feed/Store.lean) and has a one-line contract there,
 * stated over the list model of the tables (Feed/Model.lean): a page holds the posts asked for,
 * each with its author and like count. Which posts a response needs and how they are rendered
 * are Lean definitions (Feed/Handler.lean). */
#include "rt.h"
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>
#include <malloc.h>
#include <sys/prctl.h>
#include <sys/mman.h>

static sqlite3 *db;
static Btree *db_bt;
static const char *db_vfs;   /* "feedwal" (runtime/walvfs.c), or SQLite's default */
static sqlite3_stmt *st_begin, *st_commit, *st_rollback, *st_health, *st_like, *st_post;
static Pgno root_posts, root_users, root_feed_idx, root_likes_post_idx;
static KeyInfo *ki_feed_idx, *ki_likes_post_idx;
static BtCursor *c_posts, *c_users, *c_feed_idx, *c_likes, *c_exists;
static int reads_open;
static int phase_now_len;   /* the length of the write phase's created_at once taken (db_phase_now), else 0 */
static void pins_release(void);
LEAN_EXPORT lean_obj_res feed_db_commit(void);

static void db_die(const char *what) {
  fprintf(stderr, "fatal: %s: %s\n", what, db ? sqlite3_errmsg(db) : "no database");
  exit(1);
}
static sqlite3_stmt *db_prepare(const char *sql) {
  sqlite3_stmt *s;
  if (sqlite3_prepare_v3(db, sql, -1, SQLITE_PREPARE_PERSISTENT, &s, 0) != SQLITE_OK) db_die(sql);
  return s;
}
static void db_exec(const char *sql) {
  char *err = 0;
  if (sqlite3_exec(db, sql, 0, 0, &err) != SQLITE_OK) { fprintf(stderr, "fatal: %s: %s\n", sql, err); exit(1); }
}
static Pgno db_root(const char *name) {
  sqlite3_stmt *s = db_prepare("SELECT rootpage FROM sqlite_schema WHERE name = ?1");
  sqlite3_bind_text(s, 1, name, -1, SQLITE_STATIC);
  Pgno r = sqlite3_step(s) == SQLITE_ROW ? (Pgno)sqlite3_column_int64(s, 0) : 0;
  sqlite3_finalize(s);
  if (!r) { fprintf(stderr, "fatal: no b-tree for %s\n", name); exit(1); }
  return r;
}
static KeyInfo *db_keyinfo(int nkey, int nextra) {
  KeyInfo *k = sqlite3KeyInfoAlloc(db, nkey, nextra);
  if (!k) db_die("keyinfo");
  for (int i = 0; i < nkey + nextra; i++) k->aColl[i] = db->pDfltColl;
  return k;
}

/* The schema these primitives read is fixed by the challenge (schema.sql). Check the column
 * layout once at startup so a different file is refused rather than misread. */
static void db_check_layout(void) {
  static const struct { const char *sql, *want; } checks[] = {
      {"SELECT group_concat(name || ':' || type || ':' || pk, ',') FROM pragma_table_info('posts')",
       "id:INTEGER:1,user_id:INTEGER:0,body:TEXT:0,created_at:TEXT:0"},
      {"SELECT group_concat(name || ':' || type || ':' || pk, ',') FROM pragma_table_info('users')",
       "id:INTEGER:1,username:TEXT:0,created_at:TEXT:0"},
      {"SELECT group_concat(name || ':' || desc, ',') FROM pragma_index_xinfo('posts_created_at_id_idx') WHERE key",
       "created_at:1,id:1"},
      {"SELECT group_concat(name, ',') FROM pragma_index_xinfo('likes_post_id_idx')", "post_id"},
  };
  for (size_t i = 0; i < sizeof checks / sizeof checks[0]; i++) {
    sqlite3_stmt *s = db_prepare(checks[i].sql);
    const char *got = sqlite3_step(s) == SQLITE_ROW ? (const char *)sqlite3_column_text(s, 0) : 0;
    if (!got || strcmp(got, checks[i].want)) {
      fprintf(stderr, "fatal: schema layout: got '%s', expected '%s'\n", got ? got : "(null)", checks[i].want);
      exit(1);
    }
    sqlite3_finalize(s);
  }
}

/* ---- WAL checkpoints on a second thread ------------------------------------------------
 * A checkpoint copies committed pages into the database file and fsyncs it. On the request
 * thread that would stall every connection for the length of an fsync, so a second thread with
 * its own connection runs PASSIVE checkpoints. Durability does not depend on them (a commit is
 * in the WAL, synchronous=NORMAL). The WAL restarts from the beginning only when a writer finds
 * it fully checkpointed, so after a checkpoint that copied everything the request thread's next
 * commit starts the log over and it stays small. */
static int CKPT_FRAMES = 500;      /* FEED_CKPT_FRAMES overrides it (for measurements); PR #271's version
                                      (30d259c) used 500 when the box held it at 290,000 (see
                                      write_window_us in uring.c). A checkpoint copies each page once
                                      however many frames it has, so larger ones write fewer pages */
static int WAL_PAUSE_FRAMES = 4096;   /* see db_writes_ok; FEED_WAL_PAUSE_FRAMES overrides it (for measurements) */
static int pause_at = 4096;
/* On one vCPU a checkpoint pass at the request thread's priority takes the CPU from the loop for
 * the length of the pass (c-iouring-public #158 measured passes of 300-430 ms at the memory wall,
 * as c-iouring-pavlyhalim #245's README cites). At nice 19 it ran only while the loop waited
 * between batches, and c-iouring-pavlyhalim #278 found such a thread starved on the box once the
 * CPU saturated (about 1.4 % of the CPU, where its checkpoints needed about 4.5 % at 300,000 users;
 * the log grew to 970,000 frames); at nice 10 its log stayed under 4,300 frames at 310,000 users.
 * At nice 10 the thread gets about a tenth of the CPU while the loop is busy (scheduler weights 110
 * against 1024). FEED_CKPT_NICE overrides it. */
static int ckpt_nice = 10;
static u64_t WAL_PAUSE_NS = 300000000ull;  /* the longest write pause (below); FEED_PAUSE_MS overrides it */
static sqlite3 *ckpt_db;
static pthread_mutex_t ckpt_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t ckpt_cv = PTHREAD_COND_INITIALIZER;
static int ckpt_wanted;
static volatile int wal_frames;
static int ckpt_full;          /* the last checkpoint copied every frame of the log */

static void ckpt_wake(void) {
  if (__atomic_load_n(&ckpt_wanted, __ATOMIC_RELAXED)) return;
  pthread_mutex_lock(&ckpt_mu);
  ckpt_wanted = 1;
  pthread_cond_signal(&ckpt_cv);
  pthread_mutex_unlock(&ckpt_mu);
}

/* Background checkpoints run each time the log has grown by CKPT_FRAMES since the last one. */
static int ckpt_next = 2000;
static int wal_hook(void *arg, sqlite3 *d, const char *name, int frames) {
  (void)arg; (void)d; (void)name;
  wal_frames = frames;
  if (frames < ckpt_next - CKPT_FRAMES) ckpt_next = CKPT_FRAMES;   /* the log restarted */
  if (frames >= ckpt_next) { ckpt_next = frames + CKPT_FRAMES; ckpt_wake(); }
  return SQLITE_OK;
}
static void *ckpt_main(void *arg) {
  (void)arg;
  if (ckpt_nice && nice(ckpt_nice) == -1) {}
  for (;;) {
    pthread_mutex_lock(&ckpt_mu);
    while (!ckpt_wanted) pthread_cond_wait(&ckpt_cv, &ckpt_mu);
    pthread_mutex_unlock(&ckpt_mu);
    int nlog = 0, ndone = 0;
    int rc = sqlite3_wal_checkpoint_v2(ckpt_db, "main", SQLITE_CHECKPOINT_PASSIVE, &nlog, &ndone);
    if (rc != SQLITE_OK && rc != SQLITE_BUSY) fprintf(stderr, "checkpoint: %s\n", sqlite3_errmsg(ckpt_db));
    if (rc == SQLITE_OK && nlog >= 0 && ndone == nlog) __atomic_store_n(&ckpt_full, 1, __ATOMIC_RELEASE);
    __atomic_store_n(&ckpt_wanted, 0, __ATOMIC_RELEASE);
  }
  return 0;
}
static void ckpt_start(const char *path) {
  if (getenv("FEED_CKPT_FRAMES")) CKPT_FRAMES = atoi(getenv("FEED_CKPT_FRAMES"));
  if (getenv("FEED_CKPT_NICE")) ckpt_nice = atoi(getenv("FEED_CKPT_NICE"));
  if (getenv("FEED_PAUSE_MS")) WAL_PAUSE_NS = (u64_t)atoll(getenv("FEED_PAUSE_MS")) * 1000000ull;
  if (getenv("FEED_WAL_PAUSE_FRAMES")) pause_at = WAL_PAUSE_FRAMES = atoi(getenv("FEED_WAL_PAUSE_FRAMES"));
  ckpt_next = CKPT_FRAMES;
  if (sqlite3_open_v2(path, &ckpt_db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, db_vfs) != SQLITE_OK) db_die("open (checkpointer)");
  sqlite3_exec(ckpt_db, "PRAGMA synchronous = NORMAL; PRAGMA cache_size = -2048; SELECT count(*) FROM users WHERE id = 1", 0, 0, 0);
  pthread_t t;
  pthread_attr_t at;
  pthread_attr_init(&at);
  pthread_attr_setstacksize(&at, 1 << 20);
  if (pthread_create(&t, &at, ckpt_main, 0)) { perror("pthread_create"); exit(1); }
  pthread_detach(t);
}

/* ---- page cache: SQLite's own, behind its plugin interface (SQLITE_CONFIG_PCACHE2) ----------
 * With one change: at commit SQLite drops the cached pages past the end of the database
 * (xTruncate). The default cache scans its whole hash table for them whenever a key at or past
 * that limit was ever seen, and balance_nonroot parks a page under the lock-byte page's number
 * for a moment when it reorders new pages, so after every page split the next commit would scan
 * the whole cache. This wrapper tracks the largest key that a page of the cache actually holds
 * (the parked key is not one: the page moves on at once) and passes xTruncate on only when that
 * key is at or past the limit. */
typedef struct { sqlite3_pcache *in; unsigned top, parked; } pc_t;
static sqlite3_pcache_methods2 pc_in;
static sqlite3_pcache *pc_create(int szPage, int szExtra, int bPurgeable) {
  pc_t *c = malloc(sizeof *c);
  if (!c) return 0;
  if (!(c->in = pc_in.xCreate(szPage, szExtra, bPurgeable))) { free(c); return 0; }
  c->top = 0;
  c->parked = (unsigned)(PENDING_BYTE / szPage) + 1;   /* the lock-byte page's number */
  return (sqlite3_pcache *)c;
}
static void pc_cachesize(sqlite3_pcache *p, int n) { pc_in.xCachesize(((pc_t *)p)->in, n); }
static int pc_pagecount(sqlite3_pcache *p) { return pc_in.xPagecount(((pc_t *)p)->in); }
static sqlite3_pcache_page *pc_fetch(sqlite3_pcache *p, unsigned key, int create) {
  pc_t *c = (pc_t *)p;
  sqlite3_pcache_page *r = pc_in.xFetch(c->in, key, create);
  if (r && key > c->top) c->top = key;
  return r;
}
static void pc_unpin(sqlite3_pcache *p, sqlite3_pcache_page *pg, int discard) { pc_in.xUnpin(((pc_t *)p)->in, pg, discard); }
static void pc_rekey(sqlite3_pcache *p, sqlite3_pcache_page *pg, unsigned old, unsigned new) {
  pc_t *c = (pc_t *)p;
  pc_in.xRekey(c->in, pg, old, new);
  if (new > c->top && new != c->parked) c->top = new;
}
static void pc_truncate(sqlite3_pcache *p, unsigned limit) {
  pc_t *c = (pc_t *)p;
  if (limit > c->top) return;   /* no page of the cache has a key at or past the limit */
  pc_in.xTruncate(c->in, limit);
  c->top = limit ? limit - 1 : 0;
}
static void pc_destroy(sqlite3_pcache *p) { pc_in.xDestroy(((pc_t *)p)->in); free(p); }
static void pc_shrink(sqlite3_pcache *p) { pc_in.xShrink(((pc_t *)p)->in); }
static void pc_install(void) {
  if (getenv("FEED_PLAIN_PCACHE")) return;
  if (sqlite3_config(SQLITE_CONFIG_GETPCACHE2, &pc_in) != SQLITE_OK) return;
  static sqlite3_pcache_methods2 m;
  m = pc_in;
  m.xCreate = pc_create;
  m.xCachesize = pc_cachesize;
  m.xPagecount = pc_pagecount;
  m.xFetch = pc_fetch;
  m.xUnpin = pc_unpin;
  m.xRekey = pc_rekey;
  m.xTruncate = pc_truncate;
  m.xDestroy = pc_destroy;
  m.xShrink = pc_shrink;
  sqlite3_config(SQLITE_CONFIG_PCACHE2, &m);
}

/* SQLite's page cache in one pool of huge pages (SQLITE_CONFIG_PAGECACHE). The pool's 12 MB hold
 * 2,880 pages, each a 4 KB slot plus its headers, the first pages the caches take (48 MB for the
 * request thread, 2 MB for the checkpointer); the caches take the rest from malloc. In 4 KB pages
 * the pool is more than the TLB holds, so the reads' random page accesses (a feed's authors, a
 * post's leaves) would walk the page tables; six 2 MB pages cover it. It is faulted in here, at
 * startup, before db_open turns transparent huge pages off for the process (pages already mapped
 * as huge stay so). Without huge pages (THP set to never) the pool is in 4 KB pages.
 * FEED_PLAIN_POOL turns the pool off (for measurements). */
static void pc_pool(void) {
  if (getenv("FEED_PLAIN_POOL")) return;
  int hdr = 0;
  if (sqlite3_config(SQLITE_CONFIG_PCACHE_HDRSZ, &hdr) != SQLITE_OK || hdr <= 0) return;
  size_t huge = 2u << 20, sz = 4096 + (((size_t)hdr + 7) & ~(size_t)7), len = 6 * huge;
  u8_t *p = mmap(0, len + huge, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (p == MAP_FAILED) return;
  u8_t *a = (u8_t *)(((uintptr_t)p + huge - 1) & ~(uintptr_t)(huge - 1));
  madvise(a, len, MADV_HUGEPAGE);
  memset(a, 0, len);
  if (sqlite3_config(SQLITE_CONFIG_PAGECACHE, a, (int)sz, (int)(len / sz)) != SQLITE_OK) munmap(p, len + huge);
}
static void db_open(const char *path) {
  pc_pool();
  /* no transparent huge pages for this process: Lean's allocator advises its 1 GiB arena for them,
   * and a fault there may then compact memory synchronously, stalling the event loop for as long
   * as that takes when memory is fragmented (it mostly is: the kernel's socket objects fill it) */
  prctl(PR_SET_THP_DISABLE, 1, 0, 0, 0);
  pc_install();
  /* the request thread is not the process's main thread, so glibc gives it an arena that it
   * grows and shrinks with mprotect as SQLite allocates and frees pages: keep what it got */
  mallopt(M_TRIM_THRESHOLD, 512 << 20);
  mallopt(M_TOP_PAD, 16 << 20);
  if (!getenv("FEED_PLAIN_VFS")) { walvfs_register(); db_vfs = "feedwal"; }
  if (sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, db_vfs) != SQLITE_OK) db_die("open");
  db_exec("PRAGMA journal_mode = WAL");
  db_exec("PRAGMA synchronous = NORMAL");
  db_exec("PRAGMA temp_store = MEMORY");
  /* SQLite's page cache is memory the kernel cannot take back, and a page it misses is a pread on
   * the request thread. Near the memory wall of a 2 GB machine (about 1.5 GB of kernel memory for
   * 350,000 connections) the kernel's page cache shrinks below the database's working set and that
   * pread goes to the disk: on a VM like the box at 350,000 users with an 8 MB cache, the loop read
   * about 1,000 pages a second from disk for 40 s at the end of the ramp, iterations took 200-330
   * ms and p99 was 6 s. The writes' working set is the likes primary-key index (29.5 MB in the
   * seed, a random leaf per like), so the cache is 48 MB: the same run then read from disk about
   * 10 times a second and held 350,000 users with p99 14 ms. The kernel drops its own copies of
   * these pages first, so the larger cache mostly moves memory rather than adding it.
   * FEED_CACHE_KB overrides the size (for measurements). */
  {
    char q[64];
    snprintf(q, sizeof q, "PRAGMA cache_size = -%ld", getenv("FEED_CACHE_KB") ? atol(getenv("FEED_CACHE_KB")) : 49152L);
    db_exec(q);
  }
  if (getenv("FEED_MMAP")) { char q[64]; snprintf(q, sizeof q, "PRAGMA mmap_size = %s", getenv("FEED_MMAP")); db_exec(q); }
  else db_exec("PRAGMA mmap_size = 0");      /* page-cache hits are cheaper than mapped pages in WAL mode */
  db_exec("PRAGMA wal_autocheckpoint = 0");  /* checkpoints run on their own thread */
  sqlite3_wal_hook(db, wal_hook, 0);
  db_check_layout();
  db_bt = db->aDb[0].pBt;
  root_posts = db_root("posts");
  root_users = db_root("users");
  root_feed_idx = db_root("posts_created_at_id_idx");
  root_likes_post_idx = db_root("likes_post_id_idx");
  ki_feed_idx = db_keyinfo(2, 1);
  ki_feed_idx->aSortFlags[0] = KEYINFO_ORDER_DESC;
  ki_feed_idx->aSortFlags[1] = KEYINFO_ORDER_DESC;
  ki_likes_post_idx = db_keyinfo(1, 1);
  st_begin = db_prepare("BEGIN");
  st_commit = db_prepare("COMMIT");
  st_rollback = db_prepare("ROLLBACK");
  st_health = db_prepare("SELECT 1");
  /* OR IGNORE: for these values (never NULL; a body postText accepted, which meets the CHECK on
   * length(body)) the only constraint that can fail is the like's primary key, which it ignores as
   * ON CONFLICT DO NOTHING would; and no constraint can abort the statement, so SQLite needs no
   * statement journal. created_at is bound in the schema default's format, one time per write
   * phase (db_phase_now). */
  st_like = db_prepare("INSERT OR IGNORE INTO likes (user_id, post_id, created_at) VALUES (?1, ?2, ?3)");
  st_post = db_prepare("INSERT OR IGNORE INTO posts (user_id, body, created_at) VALUES (?1, ?2, ?3)");
  c_posts = malloc((size_t)sqlite3BtreeCursorSize());
  c_users = malloc((size_t)sqlite3BtreeCursorSize());
  c_feed_idx = malloc((size_t)sqlite3BtreeCursorSize());
  c_likes = malloc((size_t)sqlite3BtreeCursorSize());
  c_exists = malloc((size_t)sqlite3BtreeCursorSize());
  if (!c_posts || !c_users || !c_feed_idx || !c_likes || !c_exists) abort();
  ckpt_start(path);
}

/* Keeping the log bounded. SQLite starts the WAL over only when a write transaction begins
 * after every frame was copied into the database; with a write in every batch that moment never
 * comes and the log (and its page cache) grows without bound. So once the log passes
 * WAL_PAUSE_FRAMES, new writes wait (reads go on) until a checkpoint has copied the whole log;
 * the next write then restarts it. Checkpoints run every CKPT_FRAMES frames, so little is left
 * to copy when a pause begins. A pause ends when that checkpoint's fsync does, at most after
 * WAL_PAUSE_NS; after a pause that timed out the next one waits for another WAL_PAUSE_FRAMES / 4
 * frames. On a cloud VM's volume (3,000 writes per second) at 320,000 users a checkpoint's fsync
 * took longer than 30 ms: with a 30 ms limit every pause timed out, the log never started over
 * and grew to 105,000 frames during a 5-minute hold, and its page cache with it. With writes
 * limited the same way in the local harness, a 300 ms limit kept the log under 9,000 frames and
 * no pause reached it. On a fast disk a pause takes a few milliseconds. */
static int writes_paused;
static u64_t pause_start;
static u64_t st_pauses, st_pause_timeouts;
static int db_writes_ok(u64_t now_ns) {
  if (!writes_paused) {
    if (wal_frames < WAL_PAUSE_FRAMES) pause_at = WAL_PAUSE_FRAMES;
    if (wal_frames >= pause_at) {
      writes_paused = 1;
      pause_start = now_ns;
      __atomic_store_n(&ckpt_full, 0, __ATOMIC_RELEASE);
      ckpt_wake();
      st_pauses++;
    }
  } else if (__atomic_load_n(&ckpt_full, __ATOMIC_ACQUIRE)) {
    writes_paused = 0;
    wal_frames = 0;   /* the next commit reports the size of the (restarted) log */
  } else if (now_ns - pause_start > WAL_PAUSE_NS) {
    writes_paused = 0;
    pause_at = wal_frames + WAL_PAUSE_FRAMES / 4;
    st_pause_timeouts++;
  } else ckpt_wake();
  return !writes_paused;
}

static void db_log_error(const char *what) {
  static time_t last;
  static int n;
  time_t t = time(0);
  if (t != last) { last = t; n = 0; }
  if (n++ < 5) fprintf(stderr, "sqlite: %s: %s (%d)\n", what, sqlite3_errmsg(db), sqlite3_extended_errcode(db));
}

static int step_reset(sqlite3_stmt *s) {
  int rc = sqlite3_step(s);
  sqlite3_reset(s);
  return rc;
}

/* ---- record decoding (https://sqlite.org/fileformat2.html#record_format) ---------------- */
typedef struct { u64_t t; const u8_t *p; } col_t;
static inline const u8_t *rd_varint(const u8_t *p, const u8_t *end, u64_t *v) {
  u64_t x = 0;
  for (int i = 0; i < 8; i++) {
    if (p >= end) return 0;
    x = x << 7 | (p[0] & 0x7f);
    if (!(*p++ & 0x80)) { *v = x; return p; }
  }
  if (p >= end) return 0;
  *v = x << 8 | *p++;
  return p;
}
static inline u32_t serial_len(u64_t t) {
  static const u8_t n[12] = {0, 1, 2, 3, 4, 6, 8, 8, 0, 0, 0, 0};
  return t < 12 ? n[t] : (u32_t)((t - 12) / 2);
}
static int rec_cols(const u8_t *rec, u32_t n, int ncol, col_t *c) {
  const u8_t *end = rec + n;
  u64_t hsz;
  const u8_t *h = rd_varint(rec, end, &hsz);
  if (!h || hsz > n) return -1;
  const u8_t *hend = rec + hsz, *body = hend;
  for (int i = 0; i < ncol; i++) {
    if (h >= hend) return -1;
    h = rd_varint(h, hend, &c[i].t);
    if (!h) return -1;
    c[i].p = body;
    body += serial_len(c[i].t);
  }
  return body <= end ? 0 : -1;
}
/* The second column of a record: 0, or -1 if the record is not as expected. When the header's first
 * three varints are one byte each (its size and two serial types) the column is where they put it;
 * otherwise rec_cols finds it. */
static inline int rec_col1(const u8_t *rec, u32_t n, col_t *c1) {
  if (LIKELY(n >= 3 && rec[0] >= 3 && rec[0] < 0x80 && rec[1] < 0x80 && rec[2] < 0x80)) {
    c1->t = rec[2];
    c1->p = rec + rec[0] + serial_len(rec[1]);
    return c1->p + serial_len(c1->t) > rec + n ? -1 : 0;
  }
  col_t c[2];
  if (rec_cols(rec, n, 2, c)) return -1;
  *c1 = c[1];
  return 0;
}
static inline int col_is_int(const col_t *c) { return (c->t >= 1 && c->t <= 6) || c->t == 8 || c->t == 9; }
static inline int col_is_text(const col_t *c) { return c->t >= 13 && (c->t & 1); }
static inline i64_t col_int(const col_t *c) {
  const u8_t *p = c->p;
  switch (c->t) {
  case 1: return (int8_t)p[0];
  case 2: return (int16_t)((u16_t)p[0] << 8 | p[1]);
  case 3: return (int32_t)((u32_t)p[0] << 24 | (u32_t)p[1] << 16 | (u32_t)p[2] << 8) >> 8;
  case 4: return (int32_t)((u32_t)p[0] << 24 | (u32_t)p[1] << 16 | (u32_t)p[2] << 8 | p[3]);
  case 5: return (i64_t)((u64_t)(int16_t)((u16_t)p[0] << 8 | p[1]) << 32 | (u64_t)((u32_t)p[2] << 24 | (u32_t)p[3] << 16 | (u32_t)p[4] << 8 | p[5]));
  case 6: { u64_t v = 0; for (int i = 0; i < 8; i++) v = v << 8 | p[i]; return (i64_t)v; }
  case 9: return 1;
  default: return 0;
  }
}

/* Payload of the cursor's current cell. Records that spill onto overflow pages are copied. */
static u8_t *spill;
static u32_t spill_cap;
static const u8_t *cur_payload(BtCursor *c, u32_t *n) {
  u32_t total = sqlite3BtreePayloadSize(c), local;
  const u8_t *p = sqlite3BtreePayloadFetch(c, &local);
  if (LIKELY(local == total)) { *n = total; return p; }
  if (total > spill_cap) {
    free(spill);
    spill_cap = total + 4096;
    if (!(spill = malloc(spill_cap))) abort();
  }
  if (sqlite3BtreePayload(c, 0, total, spill) != SQLITE_OK) return 0;
  *n = total;
  return spill;
}

/* ---- Lean objects built here ------------------------------------------------------------- */
static inline lean_obj_res io_ok(lean_obj_arg v) { return lean_io_result_mk_ok(v); }
static lean_obj_res mk_pair(lean_obj_arg a, lean_obj_arg b) {
  lean_object *o = lean_alloc_ctor(0, 2, 0);
  lean_ctor_set(o, 0, a);
  lean_ctor_set(o, 1, b);
  return o;
}
static inline lean_obj_res nat_array(size_t cap) { return lean_alloc_array(0, cap); }
static inline void nat_push(lean_object *a, u64_t v) {
  lean_array_object *o = lean_to_array(a);
  o->m_data[o->m_size++] = u64_nat(v);
}
/* ---- read primitives ----------------------------------------------------------------------
 * All reads of one batch happen inside one read transaction (feed_db_begin .. feed_db_end_reads):
 * they see the same snapshot, the state before the batch's writes. */

static void cursor_open(BtCursor *c, Pgno root, KeyInfo *ki) {
  sqlite3BtreeCursorZero(c);
  if (sqlite3BtreeCursor(db_bt, root, 0, ki, c) != SQLITE_OK) db_die("cursor");
}

LEAN_EXPORT lean_obj_res feed_db_begin(void) {

  if (step_reset(st_begin) != SQLITE_DONE) return io_ok(lean_box(0));
  if (sqlite3BtreeBeginTrans(db_bt, 0, 0) != SQLITE_OK) { step_reset(st_rollback); return io_ok(lean_box(0)); }
  cursor_open(c_posts, root_posts, 0);
  cursor_open(c_users, root_users, 0);
  cursor_open(c_feed_idx, root_feed_idx, ki_feed_idx);
  cursor_open(c_likes, root_likes_post_idx, ki_likes_post_idx);
  reads_open = 1;
  return io_ok(lean_box(1));
}

LEAN_EXPORT lean_obj_res feed_db_end_reads(void) {

  pins_release();
  if (reads_open) {
    sqlite3BtreeCloseCursor(c_posts);
    sqlite3BtreeCloseCursor(c_users);
    sqlite3BtreeCloseCursor(c_feed_idx);
    sqlite3BtreeCloseCursor(c_likes);
    reads_open = 0;
  }
  phase_now_len = 0;   /* the write phase begins: its first insert takes the time */
  return io_ok(lean_box(0));
}

/* Position the likes_post_id_idx cursor on the first entry with post_id >= k. 0 on an entry. */
static int likes_seek_ge(i64_t k) {
  Mem m;
  memset(&m, 0, sizeof m);
  m.flags = MEM_Int;
  m.u.i = k;
  UnpackedRecord r;
  memset(&r, 0, sizeof r);
  r.pKeyInfo = ki_likes_post_idx;
  r.aMem = &m;
  r.nField = 1;
  r.default_rc = +1;
  int res;
  if (sqlite3BtreeIndexMoveto(c_likes, &r, &res) != SQLITE_OK) return -1;
  if (sqlite3BtreeEof(c_likes)) return 1;
  if (res < 0) { int rc = sqlite3BtreeNext(c_likes, 0); return rc == SQLITE_OK ? 0 : 1; }
  return 0;
}
static inline int likes_key(i64_t *k) {
  u32_t len;
  const u8_t *rec = cur_payload(c_likes, &len);
  col_t c[1];
  if (!rec || rec_cols(rec, len, 1, c) || !col_is_int(&c[0])) return -1;
  *k = col_int(&c[0]);
  return 0;
}

/* The number of likes rows with this post id: a range of likes_post_id_idx. */
static u64_t like_count_one(u64_t id) {
  u64_t c = 0;
  if (reads_open && id <= (u64_t)INT64_MAX && likes_seek_ge((i64_t)id) == 0) {
    for (;;) {
      i64_t k;
      if (likes_key(&k) || k != (i64_t)id) break;
      c++;
      if (sqlite3BtreeNext(c_likes, 0) != SQLITE_OK) break;
    }
  }
  return c;
}
/* The like counts of post ids lo..hi in win[id - lo] (zero on entry), by the cursor: one range of
 * likes_post_id_idx. */
static void likes_window_cursor(i64_t lo, i64_t hi, u32_t *win) {
  if (likes_seek_ge(lo) != 0) return;
  for (;;) {
    i64_t key;
    if (likes_key(&key) || key > hi) break;
    if (key >= lo) win[key - lo]++;
    if (sqlite3BtreeNext(c_likes, 0) != SQLITE_OK) break;
  }
}
/* ---- pages: posts with their authors and like counts ---------------------------------------
 * Row k of a page is cols[8k .. 8k+8) = id, b, c, e, found, s, t, likes: the body is blob[b, c),
 * created_at blob[c, e), the author's username blob[s, t) when found is 1. */
typedef struct { i64_t id, uid; u32_t b, c, e; } prow_t;

/* rec_cols for the four columns of a posts record (id, user_id, body, created_at), with a fast path
 * for the header the table's records have: its size and the serial types one-byte varints but the
 * body's, of one or two bytes (a body of up to 8,185 bytes). */
static inline int post_cols(const u8_t *rec, u32_t n, col_t *c) {
  if (LIKELY(n >= 6 && rec[0] < 0x80 && rec[1] < 0x80 && rec[2] < 0x80)) {
    u32_t h = rec[0], i = 4;
    u64_t t2 = rec[3];
    if (t2 >= 0x80) {
      if (rec[4] >= 0x80) goto general;
      t2 = (t2 & 0x7f) << 7 | rec[4];
      i = 5;
    }
    if (i >= h || rec[i] >= 0x80) goto general;   /* the last type inside the header */
    c[0].t = rec[1];
    c[1].t = rec[2];
    c[2].t = t2;
    c[3].t = rec[i];
    const u8_t *p = rec + h;
    for (int j = 0; j < 4; j++) { c[j].p = p; p += serial_len(c[j].t); }
    return p <= rec + n ? 0 : -1;
  }
general:
  return rec_cols(rec, n, 4, c);
}
/* Append one posts record to blob and describe it in *r. 0 if the record is not the expected layout. */
static int page_post(lean_object **blob, prow_t *r, i64_t rowid, const u8_t *rec, u32_t n) {
  col_t c[4];
  if (post_cols(rec, n, c) || !col_is_int(&c[1]) || !col_is_text(&c[2]) || !col_is_text(&c[3])) return 0;
  u32_t bl = serial_len(c[2].t), cl = serial_len(c[3].t);
  *blob = ba_reserve(*blob, bl + cl + 32);   /* slack: leaves may load 32 bytes past a field */
  u32_t bs = (u32_t)lean_sarray_size(*blob);
  memcpy(ba_end(*blob), c[2].p, bl + cl);   /* the body, then created_at: adjacent in the record */
  ba_grow(*blob, bl + cl);
  r->id = rowid; r->uid = col_int(&c[1]); r->b = bs; r->c = bs + bl; r->e = bs + bl + cl;
  return 1;
}

/* ---- rowid lookups of several keys of one table, a level at a time ------------------------
 * The search of sqlite3BtreeTableMoveto for up to MANY keys together (sorted, distinct): on each
 * level the child page of every key is chosen before any page of the next level is fetched, each
 * page once, and a fetched page's cell pointers are prefetched, so that the cache misses of
 * different keys overlap. Within a page the search starts where a line through the page's first
 * and last keys puts the key (rowids are dense), then bisects. */
#define MANY 64
static inline i64_t page_key(MemPage *pg, int i) {
  u8_t *c = findCellPastPtr(pg, i);
  if (pg->intKeyLeaf)
    while (*c++ & 0x80)
      if (c >= pg->aDataEnd) return INT64_MAX;   /* corrupt: the caller checks the cell it finds */
  return sqlite3VarintValue(c);
}
/* The first cell of pg whose key is >= k (nCell if there is none), given its first key k0 and its
 * last key *kn (read here if *kn is INT64_MIN). The keys of a page are increasing. With dense
 * rowids the key is at k - k0; otherwise the guess is where a line through k0 and kn puts it,
 * then its neighbour, then bisection. */
static int page_lower_bound(MemPage *pg, i64_t k, i64_t k0, i64_t *knp) {
  int n = pg->nCell;
  if (k <= k0) return 0;
  u64_t off = (u64_t)(k - k0);
  if (pg->leaf && off < (u64_t)n && page_key(pg, (int)off) == k) return (int)off;
  if (*knp == INT64_MIN) *knp = page_key(pg, n - 1);
  i64_t kn = *knp;
  if (k > kn) return n;
  int lo = 1, hi = n - 1;   /* key(lo - 1) < k <= key(hi) */
  u64_t span = (u64_t)(kn - k0);
  int g = span < (1ull << 32) ? (int)(off * (u64_t)(n - 1) / span) : (int)((double)off / (double)span * (double)(n - 1));
  if (g < lo) g = lo;
  if (g > hi) g = hi;
  if (page_key(pg, g) >= k) {
    if (g == lo || page_key(pg, g - 1) < k) return g;
    hi = g - 1;
  } else {
    if (g + 1 > hi) return hi;
    if (page_key(pg, g + 1) >= k) return g + 1;
    lo = g + 2;
  }
  while (lo < hi) {
    int m = lo + ((hi - lo) >> 1);
    if (page_key(pg, m) >= k) hi = m; else lo = m + 1;
  }
  return lo;
}

/* page_lower_bound for a key k of a run of sorted keys on one page, given that every cell before
 * `from` (the result for the run's previous key) has a key below k: that cell or the next, as
 * consecutive keys are, or the search. */
static inline int lower_from(MemPage *pg, i64_t k, int from, i64_t k0, i64_t *knp) {
  int n = pg->nCell;
  if (from >= n) return n;
  if (page_key(pg, from) >= k) return from;
  if (from + 1 < n && page_key(pg, from + 1) >= k) return from + 1;
  return page_lower_bound(pg, k, k0, knp);
}

/* ---- the batch's pages ----------------------------------------------------------------------
 * The pages the reads of a batch fetch stay referenced until the reads end (feed_db_end_reads), as
 * the pages on an open cursor's path do: a table from page number to page, so that a later read
 * of the same batch finds a page without the pager. Every read still searches the pages for its
 * own rows; only the pager's lookup is skipped. At most PT_MAX pages are held (2 MB of the 48 MB
 * cache); when the table is full at the start of a read it is emptied, and within one read a page
 * that does not fit is fetched and released as before ("own"). */
#define PT_BITS 11
#define PT_SLOTS (1u << PT_BITS)
#define PT_MAX 512
static Pgno pt_no[PT_SLOTS];      /* 0: a free slot (no b-tree page has number 0) */
static MemPage *pt_pg[PT_SLOTS];
static u16_t pt_slot[PT_MAX];     /* the slots in use */
static int pt_n;
static inline unsigned pt_hash(Pgno no) { return (unsigned)(no * 2654435761u) >> (32 - PT_BITS); }
/* Page no, initialized (0 on an error). *own: the caller holds a reference of its own and
 * releases it (pg_done); otherwise the table holds the page until the reads end. */
static MemPage *pg_get(Pgno no, u8_t *own) {
  unsigned h = pt_hash(no);
  for (; pt_no[h]; h = (h + 1) & (PT_SLOTS - 1))
    if (pt_no[h] == no) { *own = 0; return pt_pg[h]; }
  MemPage *pg;
  if (getAndInitPage(db_bt->pBt, no, &pg, PAGER_GET_READONLY) != SQLITE_OK) return 0;
  if (pt_n < PT_MAX) { pt_no[h] = no; pt_pg[h] = pg; pt_slot[pt_n++] = (u16_t)h; *own = 0; }
  else *own = 1;
  return pg;
}
static inline void pg_done(MemPage *pg, u8_t own) { if (own) releasePageNotNull(pg); }
static void pins_release(void) {
  for (int i = 0; i < pt_n; i++) { releasePageNotNull(pt_pg[pt_slot[i]]); pt_no[pt_slot[i]] = 0; }
  pt_n = 0;
}
/* At the start of a read: a full table is emptied (no page of it is in use then). */
static inline void pt_room(void) { if (UNLIKELY(pt_n >= PT_MAX)) pins_release(); }

/* For sorted distinct keys key[0, n): hit[i] the leaf page holding key[i] and cell[i] its cell,
 * or hit[i] = 0 if the table has no such row; hown[i]: the hit holds a reference of its own
 * (release it, hits_done). -1 if the tree is not what the search expects (nothing is held then:
 * use the cursor). */
static int lookup_many(Pgno root, const i64_t *key, int n, MemPage **hit, int *cell, u8_t *hown) {
  MemPage *pg[MANY];
  Pgno next[MANY];
  i64_t k0[MANY];
  u8_t own[MANY], pown[MANY];
  if (n < 1 || n > MANY) return -1;
  for (int i = 0; i < n; i++) next[i] = root;
  for (int depth = 0;; depth++) {
    for (int i = 0; i < n; i++) {
      own[i] = 0;
      if (i > 0 && next[i] == next[i - 1]) { pg[i] = pg[i - 1]; pown[i] = pown[i - 1]; }
      else {
        if ((pg[i] = pg_get(next[i], &own[i]))) {
          __builtin_prefetch(pg[i]->aCellIdx);
          __builtin_prefetch(pg[i]->aCellIdx + 2 * (pg[i]->nCell - 1));
        }
        pown[i] = own[i];
      }
      /* what moveToRoot and moveToChild check before they search a page */
      if (!pg[i] || !pg[i]->intKey || pg[i]->nCell == 0 || pg[i]->nOverflow || depth >= BTCURSOR_MAX_DEPTH ||
          pg[i]->leaf != pg[0]->leaf) {
        for (int j = 0; j <= i; j++)
          if (own[j]) releasePageNotNull(pg[j]);
        return -1;
      }
    }
    for (int i = 0; i < n; i++) k0[i] = i == 0 || pg[i] != pg[i - 1] ? page_key(pg[i], 0) : k0[i - 1];
    if (pg[0]->leaf) break;
    i64_t kn = INT64_MIN;   /* the last key of pg[i], once read */
    for (int i = 0, lw = 0; i < n; i++) {
      /* key <= the cell's key: its left child */
      if (i == 0 || pg[i] != pg[i - 1]) { kn = INT64_MIN; lw = page_lower_bound(pg[i], key[i], k0[i], &kn); }
      else if ((u64_t)(key[i] - key[i - 1]) <= 2) lw = lower_from(pg[i], key[i], lw, k0[i], &kn);
      else lw = page_lower_bound(pg[i], key[i], k0[i], &kn);
      next[i] = lw >= pg[i]->nCell ? get4byte(&pg[i]->aData[pg[i]->hdrOffset + 8]) : get4byte(findCell(pg[i], lw));
    }
    for (int i = 0; i < n; i++)
      if (own[i]) releasePageNotNull(pg[i]);
  }
  /* a hit on a page outside the table holds its own reference: take them while the first key of
   * the page still holds its own, then drop those */
  i64_t kn = INT64_MIN;
  for (int i = 0, ix = 0; i < n; i++) {
    if (i == 0 || pg[i] != pg[i - 1]) { kn = INT64_MIN; ix = page_lower_bound(pg[i], key[i], k0[i], &kn); }
    else if ((u64_t)(key[i] - key[i - 1]) <= 2) ix = lower_from(pg[i], key[i], ix, k0[i], &kn);
    else ix = page_lower_bound(pg[i], key[i], k0[i], &kn);
    hown[i] = 0;
    if (ix < pg[i]->nCell && page_key(pg[i], ix) == key[i]) {
      if (pown[i]) { sqlite3PagerRef(pg[i]->pDbPage); hown[i] = 1; }
      hit[i] = pg[i];
      cell[i] = ix;
    } else hit[i] = 0;
  }
  for (int i = 0; i < n; i++)
    if (own[i]) releasePageNotNull(pg[i]);
  return 0;
}
static void hits_done(MemPage **hit, const u8_t *hown, int n) {
  for (int i = 0; i < n; i++) if (hit[i] && hown[i]) releasePageNotNull(hit[i]);
}

/* The leaf a search for key k ends on, from the root, as sqlite3BtreeTableMoveto's (with the
 * checks of moveToRoot and moveToChild): the page, *own as for pg_get; 0 if the tree is not what
 * the search expects. */
static MemPage *descend(Pgno root, i64_t k, u8_t *own) {
  Pgno no = root;
  for (int depth = 0; depth < BTCURSOR_MAX_DEPTH; depth++) {
    u8_t o = 0;
    MemPage *pg = pg_get(no, &o);
    if (!pg) return 0;
    if (!pg->intKey || pg->nCell == 0 || pg->nOverflow) { pg_done(pg, o); return 0; }
    if (pg->leaf) { *own = o; return pg; }
    i64_t kn = INT64_MIN;
    int lw = page_lower_bound(pg, k, page_key(pg, 0), &kn);
    no = lw >= pg->nCell ? get4byte(&pg->aData[pg->hdrOffset + 8]) : get4byte(findCell(pg, lw));
    pg_done(pg, o);
  }
  return 0;
}
/* lookup_many for sorted distinct keys that lie close together (the feed's newest posts): one
 * descent for each leaf they fall in. A key no larger than the last key of the leaf where the
 * previous key's search ended is in that leaf if it is anywhere: the keys of a leaf are
 * contiguous in the tree's order. */
static int lookup_sorted(Pgno root, const i64_t *key, int n, MemPage **hit, int *cell, u8_t *hown) {
  MemPage *leaf = 0;
  u8_t lown = 0;
  i64_t k0 = 0, kn = INT64_MIN;
  int ix = 0;
  for (int i = 0; i < n; i++) {
    if (!leaf || key[i] > kn) {
      if (leaf) pg_done(leaf, lown);
      if (!(leaf = descend(root, key[i], &lown))) { hits_done(hit, hown, i); return -1; }
      k0 = page_key(leaf, 0);
      kn = page_key(leaf, leaf->nCell - 1);
      ix = page_lower_bound(leaf, key[i], k0, &kn);
    } else ix = lower_from(leaf, key[i], ix, k0, &kn);
    hown[i] = 0;
    if (ix < leaf->nCell && page_key(leaf, ix) == key[i]) {
      if (lown) { sqlite3PagerRef(leaf->pDbPage); hown[i] = 1; }
      hit[i] = leaf;
      cell[i] = ix;
    } else hit[i] = 0;
  }
  if (leaf) pg_done(leaf, lown);
  return 0;
}

/* ---- one rowid at a time, over the batch's pages ----------------------------------------------
 * The search of sqlite3BtreeTableMoveto for one key, for keys in any order (a feed's authors):
 * what a search reads of an interior page (its first and last keys, the slope of the line through
 * them) is kept for the next key of the same read that meets the page, and the leaf is entered
 * at the cell where the key would be if the leaf's rowids were dense from the bound its parent
 * gives (one more than the key of the parent's cell before the child): one cell read when they
 * are, the search otherwise. */
typedef struct { MemPage *pg; i64_t k0, kn; u64_t slope; } lvl_t;
static inline i64_t ikey(MemPage *pg, int i) { return sqlite3VarintValue(findCellPastPtr(pg, i)); }
/* The first cell of interior table page pg whose key is >= k (nCell if none), as page_lower_bound;
 * *below: the key of the cell before it (INT64_MIN for the first). L remembers the page when memo. */
static inline int interior_lower(MemPage *pg, i64_t k, lvl_t *L, int memo, i64_t *below) {
  int n = pg->nCell;
  if (L->pg != pg || !memo) {
    L->k0 = ikey(pg, 0);
    L->kn = ikey(pg, n - 1);
    u64_t span = (u64_t)L->kn - (u64_t)L->k0;
    L->slope = L->kn > L->k0 && span < (1ull << 32) ? ((u64_t)(n - 1) << 32) / span : 0;
    L->pg = memo ? pg : 0;
  }
  i64_t k0 = L->k0, kn = L->kn;
  u64_t slope = L->slope;
  *below = INT64_MIN;
  if (k <= k0) return 0;
  if (k > kn) { *below = kn; return n; }
  int lo = 1, hi = n - 1;   /* key(lo - 1) < k <= key(hi) */
  int g = slope ? (int)((((u64_t)k - (u64_t)k0) * slope) >> 32) : lo + ((hi - lo) >> 1);
  if (g < lo) g = lo;
  if (g > hi) g = hi;
  i64_t v = ikey(pg, g);
  if (v >= k) {
    if (g == lo) { *below = k0; return g; }
    i64_t w = ikey(pg, g - 1);
    if (w < k) { *below = w; return g; }
    hi = g - 1;
  } else {
    if (g + 1 > hi) { *below = v; return hi; }
    i64_t w = ikey(pg, g + 1);
    if (w >= k) { *below = v; return g + 1; }
    lo = g + 2;
  }
  while (lo < hi) {
    int m = lo + ((hi - lo) >> 1);
    if (ikey(pg, m) >= k) hi = m; else lo = m + 1;
  }
  *below = ikey(pg, lo - 1);
  return lo;
}
/* Cell i of a table leaf: its rowid; *rec its record, when that lies on the page (0 otherwise), of
 * *len bytes. The cell is the payload's size, the rowid, then the payload (btreeParseCellPtr). */
static inline i64_t leaf_cell(MemPage *pg, int i, const u8_t **rec, u32_t *len) {
  const u8_t *c = findCell(pg, i);
  u32_t sz;
  u64_t key;
  c += getVarint32(c, sz);
  c += sqlite3GetVarint(c, &key);
  *rec = sz <= pg->maxLocal && c + sz <= pg->aDataEnd ? c : 0;
  *len = sz;
  return (i64_t)key;
}
/* What moveToRoot and moveToChild check of a page of a table b-tree (an empty root, nCell 0, too). */
static inline int table_page_ok(const MemPage *pg) { return pg->intKey && pg->nCell > 0 && !pg->nOverflow; }
/* Rowid k of the table b-tree whose root page is root (held by the caller, initialized, checked as
 * moveToRoot does): 1 found, cell *ixp of leaf *leafp (*ownp as for pg_get), with its record
 * *rec[0, *len) (0 if not on the page); 0 not found (nothing held); -1 if the tree is not what the
 * search expects (nothing held). L: one entry per level, kept across the keys of one read. */
static inline int find_rowid(MemPage *root, i64_t k, lvl_t *L, MemPage **leafp, u8_t *ownp, int *ixp,
                             const u8_t **rec, u32_t *len) {
  MemPage *pg = root;
  u8_t own = 0;            /* the root is the caller's */
  i64_t lb = INT64_MIN;    /* the parent's bound: the keys of pg's subtree are >= lb */
  for (int depth = 0; !pg->leaf;) {
    i64_t below;
    int lw = interior_lower(pg, k, &L[depth], !own, &below);
    if (below != INT64_MIN && below < INT64_MAX) lb = below + 1;
    Pgno no = lw >= pg->nCell ? get4byte(&pg->aData[pg->hdrOffset + 8]) : get4byte(findCell(pg, lw));
    pg_done(pg, own);
    /* what moveToChild checks */
    if (++depth >= BTCURSOR_MAX_DEPTH || !(pg = pg_get(no, &own))) return -1;
    if (!pg->intKey || pg->nCell == 0 || pg->nOverflow) { pg_done(pg, own); return -1; }
  }
  int n = pg->nCell, ix;
  u64_t d = (u64_t)k - (u64_t)lb;
  if (lb != INT64_MIN && k >= lb && d < (u64_t)n && leaf_cell(pg, (int)d, rec, len) == k) { ix = (int)d; goto found; }
  {
    i64_t kn = INT64_MIN;
    ix = page_lower_bound(pg, k, page_key(pg, 0), &kn);
    if (ix < n && leaf_cell(pg, ix, rec, len) == k) goto found;
  }
  pg_done(pg, own);
  return 0;
found:
  *leafp = pg;
  *ownp = own;
  *ixp = ix;
  return 1;
}

/* ---- index b-trees in order, over the batch's pages ------------------------------------------
 * An index b-tree keeps entries in its interior cells too: in order, the entries of child 0, the
 * entry of cell 0, the entries of child 1, ..., then those of the right child. An iterator is the
 * path from the root to the entry it is on: on each level above the last, the child it is in
 * (nCell for the right child); on the last level, the cell. Each step is what sqlite3BtreeNext
 * does (btreeNext, moveToChild, moveToLeftmost, moveToParent), with the checks moveToChild makes;
 * anything else (a page that is not an index page, a payload that spills onto overflow pages, a
 * record that is not as expected) answers -1 and the caller reads by the cursor instead. */
typedef struct {
  int d;                              /* pages on the path */
  MemPage *pg[BTCURSOR_MAX_DEPTH];
  int ix[BTCURSOR_MAX_DEPTH];
  u8_t own[BTCURSOR_MAX_DEPTH];
} it_t;
static void it_close(it_t *it) {
  for (int i = 0; i < it->d; i++) pg_done(it->pg[i], it->own[i]);
  it->d = 0;
}
/* Add page no to the path, on its first cell or child. 0, or -1. */
static int it_push(it_t *it, Pgno no) {
  if (it->d >= BTCURSOR_MAX_DEPTH) return -1;
  u8_t own = 0;
  MemPage *pg = pg_get(no, &own);
  if (!pg) return -1;
  /* an index page; only a root that is a leaf may be empty */
  if (pg->intKey || pg->nOverflow || (pg->nCell == 0 && (it->d > 0 || !pg->leaf))) { pg_done(pg, own); return -1; }
  it->pg[it->d] = pg;
  it->own[it->d] = own;
  it->ix[it->d] = 0;
  it->d++;
  return 0;
}
static inline Pgno it_child(MemPage *pg, int i) {
  return i >= pg->nCell ? get4byte(&pg->aData[pg->hdrOffset + 8]) : get4byte(findCell(pg, i));
}
/* From the last page of the path down to the first entry of its subtree. 0, or -1. */
static int it_leftmost(it_t *it) {
  for (MemPage *pg; !(pg = it->pg[it->d - 1])->leaf;)
    if (it_push(it, it_child(pg, it->ix[it->d - 1]))) return -1;
  return 0;
}
/* Past the last entry of a leaf: up to the next entry. 0 on an entry, 1 at the end. */
static int it_up(it_t *it) {
  while (it->d > 1) {
    it->d--;
    pg_done(it->pg[it->d], it->own[it->d]);
    if (it->ix[it->d - 1] < it->pg[it->d - 1]->nCell) return 0;   /* the cell after that child */
  }
  return 1;
}
/* To the next entry: 0 on an entry, 1 at the end, -1. */
static inline int it_next(it_t *it) {
  int t = it->d - 1;
  MemPage *pg = it->pg[t];
  if (LIKELY(pg->leaf)) {
    if (LIKELY(++it->ix[t] < pg->nCell)) return 0;
    return it_up(it);
  }
  it->ix[t]++;   /* after an interior cell: the first entry of the next child */
  if (it_push(it, it_child(pg, it->ix[t])) || it_leftmost(it)) return -1;
  return 0;
}
/* On the first entry: 0, 1 if the tree is empty, -1. */
static int it_first(it_t *it, Pgno root) {
  it->d = 0;
  if (it_push(it, root) || it_leftmost(it)) return -1;
  return it->pg[it->d - 1]->nCell ? 0 : 1;
}
/* The record of the entry the iterator is on, when it lies on the page (0 otherwise). */
static inline const u8_t *it_rec(const it_t *it, u32_t *n) {
  MemPage *pg = it->pg[it->d - 1];
  const u8_t *c = findCellPastPtr(pg, it->ix[it->d - 1]);
  u32_t sz;
  c += getVarint32(c, sz);
  if (UNLIKELY(sz > pg->maxLocal || c + sz > pg->aDataEnd)) return 0;
  *n = sz;
  return c;
}
/* The first column of a record, an integer: 0, or -1 if it is not one. */
static inline int rec_int0(const u8_t *rec, u32_t n, i64_t *v) {
  col_t c[1];
  if (LIKELY(n >= 2 && rec[0] >= 2 && rec[0] < 0x80 && rec[1] < 0x80)) {
    c[0].t = rec[1];
    c[0].p = rec + rec[0];
    if (rec[0] + serial_len(c[0].t) > n) return -1;
  } else if (rec_cols(rec, n, 1, c)) return -1;
  if (!col_is_int(&c[0])) return -1;
  *v = col_int(&c[0]);
  return 0;
}
/* The first cell of pg whose record's first column is >= k (nCell if none); -1 if a record is not as expected. */
/* The first column of cell i of an index page, an integer: 0, or -1 if it is not one. */
static inline int cell_int0(MemPage *pg, int i, i64_t *v) {
  const u8_t *c = findCellPastPtr(pg, i);
  u32_t sz;
  c += getVarint32(c, sz);
  if (sz > pg->maxLocal || c + sz > pg->aDataEnd) return -1;
  return rec_int0(c, sz, v);
}
/* The first cell's key v0 and the last's vn, then a guess where a line through them reaches k
 * (the post ids of likes_post_id_idx are spread evenly), its neighbour, then bisection, as
 * page_lower_bound does for rowids. */
static int it_lower(MemPage *pg, i64_t k) {
  int n = pg->nCell;
  i64_t v0, vn, v;
  if (n == 0 || cell_int0(pg, 0, &v0)) return n == 0 ? 0 : -1;
  if (v0 >= k) return 0;
  if (cell_int0(pg, n - 1, &vn)) return -1;
  if (vn < k) return n;
  int lo = 1, hi = n - 1;   /* key(lo - 1) < k <= key(hi) */
  u64_t span = (u64_t)(vn - v0), off = (u64_t)(k - v0);
  int g = span < (1ull << 32) ? (int)(off * (u64_t)(n - 1) / span) : lo + ((hi - lo) >> 1);
  if (g < lo) g = lo;
  if (g > hi) g = hi;
  if (cell_int0(pg, g, &v)) return -1;
  if (v >= k) {
    if (g == lo) return g;
    if (cell_int0(pg, g - 1, &v)) return -1;
    if (v < k) return g;
    hi = g - 1;
  } else {
    if (g + 1 > hi) return hi;
    if (cell_int0(pg, g + 1, &v)) return -1;
    if (v >= k) return g + 1;
    lo = g + 2;
  }
  while (lo < hi) {
    int m = lo + ((hi - lo) >> 1);
    if (cell_int0(pg, m, &v)) return -1;
    if (v >= k) hi = m; else lo = m + 1;
  }
  return lo;
}
/* On the first entry whose first column (an integer) is >= k: 0, 1 if there is none, -1. In each
 * page the first cell whose key is >= k: the entry is in the child left of that cell, or it is
 * that cell. */
static int it_seek(it_t *it, Pgno root, i64_t k) {
  it->d = 0;
  if (it_push(it, root)) return -1;
  for (;;) {
    int t = it->d - 1;
    MemPage *pg = it->pg[t];
    int i = it_lower(pg, k);
    if (i < 0) return -1;
    it->ix[t] = i;
    if (pg->leaf) return i < pg->nCell ? 0 : it_up(it);
    if (it_push(it, it_child(pg, i))) return -1;
  }
}

/* The like counts of post ids lo..hi in win[id - lo] (zero on entry): one ordered pass over
 * likes_post_id_idx from the first entry with post_id >= lo. 0, or -1 if the tree is not as
 * expected (win is zero again then: use the cursor). */
static int likes_window(i64_t lo, i64_t hi, u32_t *win) {
  it_t it;
  int r = it_seek(&it, root_likes_post_idx, lo);
  i64_t cur = lo;   /* the entries come in post_id order: count each run of one id in a register */
  u32_t run = 0;
  while (r == 0) {
    int t = it.d - 1;
    MemPage *pg = it.pg[t];
    int i = it.ix[t];
    const int nc = pg->leaf ? pg->nCell : i + 1;   /* a leaf's cells from i on; one interior cell */
    for (; i < nc; i++) {
      const u8_t *c = findCellPastPtr(pg, i);
      u32_t sz;
      c += getVarint32(c, sz);
      i64_t k;
      if (UNLIKELY(sz > pg->maxLocal || c + sz > pg->aDataEnd) || rec_int0(c, sz, &k) || k < lo) { r = -1; goto out; }
      if (k > hi) goto out;
      if (k != cur) { win[cur - lo] += run; cur = k; run = 0; }
      run++;
    }
    it.ix[t] = nc - 1;
    r = it_next(&it);
  }
out:
  win[cur - lo] += run;
  it_close(&it);
  if (r < 0) memset(win, 0, (size_t)(hi - lo + 1) * sizeof *win);
  return r < 0 ? -1 : 0;
}

/* The row of a hit (cell ix of a table leaf): its record, when it lies on the page (0 otherwise).
 * The cell is the payload's size, the rowid, then the payload (btreeParseCellPtr). */
static inline const u8_t *hit_record(MemPage *pg, int ix, u32_t *n) {
  const u8_t *c = findCell(pg, ix);
  u32_t sz;
  c += getVarint32(c, sz);
  int i = 0;
  while (i < 8 && (c[i] & 0x80)) i++;
  c += i + 1;
  if (sz > pg->maxLocal || c + sz > pg->aDataEnd) return 0;
  *n = sz;
  return c;
}

/* Append user uid's username to blob: 1 found (name at blob[*s, *t)), 0 not found, by the cursor. */
static int user_name_cursor(lean_object **blob, i64_t uid, u32_t *s, u32_t *t) {
  int res = 1;
  *s = *t = (u32_t)lean_sarray_size(*blob);
  if (!reads_open || sqlite3BtreeTableMoveto(c_users, uid, 0, &res) != SQLITE_OK || res != 0) return 0;
  u32_t len;
  const u8_t *rec = cur_payload(c_users, &len);
  col_t c[2];
  if (!rec || rec_cols(rec, len, 2, c) || !col_is_text(&c[1])) return 0;
  u32_t nl = serial_len(c[1].t);
  *blob = ba_reserve(*blob, nl + 32);
  *s = (u32_t)lean_sarray_size(*blob);
  memcpy(ba_end(*blob), c[1].p, nl);
  ba_grow(*blob, nl);
  *t = *s + nl;
  return 1;
}

/* The usernames of users uid[0, k): found[q], and the name at blob[s[q], t[q]). Each row's author
 * by its own search (find_rowid) over the batch's pages; by the cursor if the tree or a record is
 * not what the search expects. */
static void user_names(lean_object **blob, const i64_t *uid, size_t k, u8_t *found, u32_t *s, u32_t *t) {
  if (k == 0) return;
  if (!reads_open) goto by_cursor;
  u8_t rown;
  MemPage *root = pg_get(root_users, &rown);
  if (!root) goto by_cursor;
  /* what moveToRoot checks (an empty table, nCell 0, goes to the cursor) */
  if (!root->intKey || root->nCell == 0 || root->nOverflow) { pg_done(root, rown); goto by_cursor; }
  lvl_t L[BTCURSOR_MAX_DEPTH];
  for (int d = 0; d < BTCURSOR_MAX_DEPTH; d++) L[d].pg = 0;
  size_t size0 = lean_sarray_size(*blob);
  for (size_t q = 0; q < k; q++) {
    MemPage *leaf;
    u8_t lown;
    const u8_t *rec;
    u32_t len;
    int ix, r = find_rowid(root, uid[q], L, &leaf, &lown, &ix, &rec, &len);
    if (UNLIKELY(r < 0)) goto bad;
    found[q] = 0;
    s[q] = t[q] = (u32_t)lean_sarray_size(*blob);
    if (r == 0) continue;
    col_t c;
    if (UNLIKELY(!rec || rec_col1(rec, len, &c) || !col_is_text(&c))) { pg_done(leaf, lown); goto bad; }
    u32_t nl = serial_len(c.t);
    *blob = ba_reserve(*blob, nl + 32);
    s[q] = (u32_t)lean_sarray_size(*blob);
    copy_small(ba_end(*blob), c.p, nl);
    ba_grow(*blob, nl);
    t[q] = s[q] + nl;
    found[q] = 1;
    pg_done(leaf, lown);
  }
  pg_done(root, rown);
  return;
bad:
  pg_done(root, rown);
  lean_to_sarray(*blob)->m_size = size0;
by_cursor:
  for (size_t q = 0; q < k; q++) found[q] = (u8_t)user_name_cursor(blob, uid[q], &s[q], &t[q]);
}

/* The authors and like counts of rows[0, k), then the page's columns. */
static lean_obj_res page_finish(lean_object *blob, const prow_t *rows, size_t k) {
  u64_t cbuf[64], *cnt = k <= 64 ? cbuf : malloc(k * sizeof(u64_t));
  if (!cnt) abort();
  /* like counts: one ordered scan of likes_post_id_idx when the ids are close together */
  i64_t lo = INT64_MAX, hi = 0;
  for (size_t q = 0; q < k; q++) { if (rows[q].id < lo) lo = rows[q].id; if (rows[q].id > hi) hi = rows[q].id; }
  if (k > 1 && (u64_t)(hi - lo) < 4 * k + 64) {
    size_t w = (size_t)(hi - lo + 1);
    u32_t wbuf[512], *win = w <= 512 ? wbuf : calloc(w, sizeof(u32_t));
    if (!win) abort();
    if (w <= 512) memset(win, 0, w * sizeof(u32_t));
    if (reads_open && likes_window(lo, hi, win)) likes_window_cursor(lo, hi, win);
    for (size_t q = 0; q < k; q++) cnt[q] = win[rows[q].id - lo];
    if (win != wbuf) free(win);
  } else {
    for (size_t q = 0; q < k; q++) {
      u32_t c = 0;
      cnt[q] = reads_open && likes_window(rows[q].id, rows[q].id, &c) == 0 ? c : like_count_one((u64_t)rows[q].id);
    }
  }
  i64_t ubuf[64], *uid = k <= 64 ? ubuf : malloc(k * sizeof(i64_t));
  u8_t fbuf[64], *found = k <= 64 ? fbuf : malloc(k);
  u32_t sbuf[64], tbuf[64], *s = k <= 64 ? sbuf : malloc(k * sizeof(u32_t)), *t = k <= 64 ? tbuf : malloc(k * sizeof(u32_t));
  if (!uid || !found || !s || !t) abort();
  for (size_t q = 0; q < k; q++) uid[q] = rows[q].uid;
  user_names(&blob, uid, k, found, s, t);
  lean_object *cols = nat_array(8 * k);
  for (size_t q = 0; q < k; q++) {
    nat_push(cols, (u64_t)rows[q].id);
    nat_push(cols, rows[q].b);
    nat_push(cols, rows[q].c);
    nat_push(cols, rows[q].e);
    nat_push(cols, (u64_t)found[q]);
    nat_push(cols, s[q]);
    nat_push(cols, t[q]);
    nat_push(cols, cnt[q]);
  }
  if (cnt != cbuf) free(cnt);
  if (uid != ubuf) { free(uid); free(found); free(s); free(t); }
  return io_ok(mk_pair(blob, cols));
}

/* The posts rows of ids[0, k) (0 < k <= MANY), in that order, by the grouped rowid search over the
 * batch's pages (feed_rows_desc for a run of consecutive descending ids); an id without a row is
 * left out. Their number, or -1 (the blob as it was) if the
 * tree or a record is not what the search expects: read them by the cursor then. */
/* The posts rows of ids[0, k) when the ids are consecutive and descending (ids[q] = ids[0] - q, as
 * the feed's newest posts are), in that order; an id without a row is left out: the first by
 * find_rowid, then each the cell before the previous one's on the same leaf when that cell has
 * its rowid, by find_rowid otherwise (a leaf boundary: one descent per leaf). Their number, or -1
 * (the blob as it was) if the tree or a record is not what the search expects. */
static long feed_rows_desc(lean_object **blob, const i64_t *ids, size_t k, prow_t *rows) {
  u8_t rown;
  MemPage *root = pg_get(root_posts, &rown);
  if (!root) return -1;
  if (!table_page_ok(root)) { pg_done(root, rown); return -1; }
  lvl_t L[BTCURSOR_MAX_DEPTH];
  for (int d = 0; d < BTCURSOR_MAX_DEPTH; d++) L[d].pg = 0;
  MemPage *leaf = 0;
  u8_t lown = 0;
  int ix = 0, bad = 0;
  size_t nr = 0, size0 = lean_sarray_size(*blob);
  for (size_t q = 0; q < k; q++) {
    const u8_t *rec;
    u32_t len;
    if (leaf && ix > 0 && leaf_cell(leaf, ix - 1, &rec, &len) == ids[q]) ix--;
    else {
      if (leaf) pg_done(leaf, lown);
      leaf = 0;
      int r = find_rowid(root, ids[q], L, &leaf, &lown, &ix, &rec, &len);
      if (r < 0) { bad = 1; break; }
      if (r == 0) { leaf = 0; continue; }
    }
    if (!rec || !page_post(blob, &rows[nr], ids[q], rec, len)) { bad = 1; break; }
    nr++;
  }
  if (leaf) pg_done(leaf, lown);
  pg_done(root, rown);
  if (bad) { lean_to_sarray(*blob)->m_size = size0; return -1; }
  return (long)nr;
}

static long feed_rows(lean_object **blob, const i64_t *ids, size_t k, prow_t *rows) {
  int consecutive = 1;
  for (size_t q = 1; consecutive && q < k; q++) consecutive = ids[q - 1] > INT64_MIN && ids[q] == ids[q - 1] - 1;
  if (consecutive) return feed_rows_desc(blob, ids, k, rows);
  int ord[MANY], of[MANY], nk = 0, desc = 1;
  for (size_t q = 1; desc && q < k; q++) desc = ids[q] < ids[q - 1];
  if (desc) for (int q = 0; q < (int)k; q++) ord[q] = (int)k - 1 - q;   /* the index's order: newest first */
  else for (int q = 0; q < (int)k; q++) {   /* by id (insertion sort), then the distinct ids */
    int i = q;
    while (i > 0 && ids[ord[i - 1]] > ids[q]) { ord[i] = ord[i - 1]; i--; }
    ord[i] = q;
  }
  i64_t key[MANY];
  for (int i = 0; i < (int)k; i++) {
    if (nk == 0 || key[nk - 1] != ids[ord[i]]) key[nk++] = ids[ord[i]];
    of[ord[i]] = nk - 1;
  }
  MemPage *hit[MANY];
  int cell[MANY];
  u8_t hown[MANY];
  int dense = (u64_t)(key[nk - 1] - key[0]) < 4 * (u64_t)nk + 64;
  if ((dense ? lookup_sorted : lookup_many)(root_posts, key, nk, hit, cell, hown)) return -1;
  size_t nr = 0, size0 = lean_sarray_size(*blob);
  int bad = 0;
  for (size_t q = 0; q < k && !bad; q++) {
    int i = of[q];
    if (!hit[i]) continue;
    u32_t len;
    const u8_t *rec = hit_record(hit[i], cell[i], &len);
    if (!rec || !page_post(blob, &rows[nr], ids[q], rec, len)) bad = 1;
    else nr++;
  }
  hits_done(hit, hown, nk);
  if (bad) { lean_to_sarray(*blob)->m_size = size0; return -1; }
  return (long)nr;
}

/* Append v to ids[0, *k) (room for *cap; the first ones in the caller's idbuf, past it malloc'd). */
static inline void ids_push(i64_t **ids, size_t *cap, size_t *k, const i64_t *idbuf, i64_t v) {
  if (UNLIKELY(*k == *cap)) {
    i64_t *m = malloc(2 * *cap * sizeof *m);
    if (!m) abort();
    memcpy(m, *ids, *k * sizeof *m);
    if (*ids != idbuf) free(*ids);
    *ids = m;
    *cap *= 2;
  }
  (*ids)[(*k)++] = v;
}
/* The second column of a record, an integer (the id of a posts_created_at_id_idx entry): 0, or -1
 * if it is not one. */
static inline int rec_int1(const u8_t *rec, u32_t n, i64_t *v) {
  col_t c;
  if (rec_col1(rec, n, &c) || !col_is_int(&c)) return -1;
  *v = col_int(&c);
  return 0;
}
/* The ids of the first n entries of posts_created_at_id_idx (each entry's second column), by the
 * cursor: as many as it read before the end or a record that is not as expected. */
static size_t feed_ids_cursor(u64_t n, i64_t **ids, size_t *cap, const i64_t *idbuf) {
  size_t k = 0;
  int empty = 1;
  if (reads_open && sqlite3BtreeFirst(c_feed_idx, &empty) == SQLITE_OK) {
    while (!empty && k < n) {
      u32_t len;
      const u8_t *rec = cur_payload(c_feed_idx, &len);
      col_t c[2];
      if (!rec || rec_cols(rec, len, 2, c) || !col_is_int(&c[1])) break;
      ids_push(ids, cap, &k, idbuf, col_int(&c[1]));
      if (sqlite3BtreeNext(c_feed_idx, 0) != SQLITE_OK) break;
    }
  }
  return k;
}
/* The same by the iterator over the batch's pages: their number, or -1 if the tree or a record is
 * not what it expects (a record on overflow pages): read them by the cursor then. */
static long feed_ids_it(u64_t n, i64_t **ids, size_t *cap, const i64_t *idbuf) {
  it_t it;
  size_t k = 0;
  int r = it_first(&it, root_feed_idx);
  while (r == 0 && k < n) {
    /* the entries of the iterator's page from its cell on: a leaf's up to the wanted number, or
     * one interior cell; then the iterator steps on from the last of them */
    int t = it.d - 1;
    MemPage *pg = it.pg[t];
    int i = it.ix[t];
    u64_t want = n - k;
    int nc = !pg->leaf ? i + 1 : (u64_t)(pg->nCell - i) < want ? pg->nCell : i + (int)want;
    if (UNLIKELY(*cap - k < (size_t)(nc - i))) {
      size_t c = *cap;
      while (c - k < (size_t)(nc - i)) c *= 2;
      i64_t *m = malloc(c * sizeof *m);
      if (!m) abort();
      memcpy(m, *ids, k * sizeof *m);
      if (*ids != idbuf) free(*ids);
      *ids = m;
      *cap = c;
    }
    i64_t *out = *ids;
    for (; i < nc; i++) {
      const u8_t *c = findCellPastPtr(pg, i);
      u32_t sz;
      c += getVarint32(c, sz);
      if (UNLIKELY(sz > pg->maxLocal || c + sz > pg->aDataEnd) || rec_int1(c, sz, &out[k])) { r = -1; break; }
      k++;
    }
    if (r < 0 || k >= n) break;
    it.ix[t] = nc - 1;
    r = it_next(&it);
  }
  it_close(&it);
  return r < 0 ? -1 : (long)k;
}

/* feedPage n: the first n posts in (created_at DESC, id DESC) order, with their authors and like
 * counts. The ids come from posts_created_at_id_idx, read in order over the batch's pages; up to
 * MANY of them, the rows by the grouped rowid search. Otherwise by the cursor: when the ids are
 * consecutive (the newest posts got increasing ids) by one backward scan of posts, each checked
 * against its id; otherwise, or from the first mismatch on, by one lookup per id. */
LEAN_EXPORT lean_obj_res feed_db_feed_page(b_lean_obj_arg nn) {
  u64_t n = nat_u64(nn);
  pt_room();
  i64_t idbuf[64], *ids = idbuf;
  size_t cap = 64, k = 0;
  long got_ids = reads_open ? feed_ids_it(n, &ids, &cap, idbuf) : -1;
  k = got_ids >= 0 ? (size_t)got_ids : feed_ids_cursor(n, &ids, &cap, idbuf);
  prow_t rbuf[64], *rows = k <= 64 ? rbuf : malloc(k * sizeof(prow_t));
  if (!rows) abort();
  lean_object *blob = lean_alloc_sarray(1, 0, (k < 64 ? k : 64) * 400 + 256);
  size_t j = 0, nr = 0;
  long got = k > 0 && k <= MANY ? feed_rows(&blob, ids, k, rows) : -1;
  if (got >= 0) { j = k; nr = (size_t)got; }
  int consecutive = got < 0 && k > 1;
  for (size_t q = 1; consecutive && q < k; q++) consecutive = ids[q] + 1 == ids[q - 1];
  int res = 1;
  if (consecutive && sqlite3BtreeTableMoveto(c_posts, ids[0], 0, &res) == SQLITE_OK && res == 0) {
    for (j = 0; j < k; j++) {
      if (j > 0 && (sqlite3BtreePrevious(c_posts, 0) != SQLITE_OK || sqlite3BtreeIntegerKey(c_posts) != ids[j])) break;
      u32_t len;
      const u8_t *rec = cur_payload(c_posts, &len);
      if (!rec || !page_post(&blob, &rows[nr], ids[j], rec, len)) break;
      nr++;
    }
  }
  for (; j < k; j++) {
    res = 1;
    if (sqlite3BtreeTableMoveto(c_posts, ids[j], 0, &res) != SQLITE_OK || res != 0) continue;
    u32_t len;
    const u8_t *rec = cur_payload(c_posts, &len);
    if (rec && page_post(&blob, &rows[nr], ids[j], rec, len)) nr++;
  }
  if (ids != idbuf) free(ids);
  lean_obj_res r = page_finish(blob, rows, nr);
  if (rows != rbuf) free(rows);
  return r;
}

/* postPage id: the post with this id with its author and like count; no row if there is none. */
LEAN_EXPORT lean_obj_res feed_db_post_page(b_lean_obj_arg idn) {
  u64_t id = nat_u64(idn);
  pt_room();
  prow_t row;
  size_t nr = 0;
  lean_object *blob = lean_alloc_sarray(1, 0, 1024);
  if (reads_open && id <= (u64_t)INT64_MAX) {
    /* the grouped search with one key, over the batch's pages; by the cursor if the tree or the
     * record is not what it expects (a record on overflow pages) */
    i64_t key = (i64_t)id;
    MemPage *hit;
    int cell, done = 0;
    u8_t hown;
    if (lookup_sorted(root_posts, &key, 1, &hit, &cell, &hown) == 0) {
      if (!hit) done = 1;
      else {
        u32_t len;
        const u8_t *rec = hit_record(hit, cell, &len);
        if (rec) { nr = (size_t)page_post(&blob, &row, key, rec, len); done = 1; }
        hits_done(&hit, &hown, 1);
      }
    }
    int res = 1;
    if (!done && sqlite3BtreeTableMoveto(c_posts, key, 0, &res) == SQLITE_OK && res == 0) {
      u32_t len;
      const u8_t *rec = cur_payload(c_posts, &len);
      if (rec && page_post(&blob, &row, key, rec, len)) nr = 1;
    }
  }
  return page_finish(blob, &row, nr);
}

/* ---- write primitives (inside the batch transaction, after the reads) -------------------- */

/* postExists id: whether the posts table has a row with this id (as of the earlier writes of the
 * batch). 0 no, 1 yes, 2 error. */
LEAN_EXPORT lean_obj_res feed_db_post_exists(b_lean_obj_arg idn) {
  u64_t id = nat_u64(idn);
  if (id > (u64_t)INT64_MAX) return io_ok(lean_box(0));
  /* a cursor of the batch's transaction, so it sees the batch's earlier writes */
  int res = 1, rc;
  sqlite3BtreeCursorZero(c_exists);
  if ((rc = sqlite3BtreeCursor(db_bt, root_posts, 0, 0, c_exists)) == SQLITE_OK) {
    rc = sqlite3BtreeTableMoveto(c_exists, (i64_t)id, 0, &res);
    sqlite3BtreeCloseCursor(c_exists);
  }
  if (rc != SQLITE_OK) { db_log_error("post exists"); return io_ok(lean_box(2)); }
  return io_ok(lean_box(res == 0 ? 1 : 0));
}

/* The schema default of created_at, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'): the current UTC time
 * in milliseconds, as SQLite's 'now' (the unix VFS's clock, milliseconds truncated). */
static int db_now(char *out) {
  static time_t sec_cached = -1;
  static char head[64];   /* "YYYY-MM-DDTHH:MM:SS" of sec_cached */
  struct timespec ts;
  clock_gettime(CLOCK_REALTIME, &ts);
  if (ts.tv_sec != sec_cached) {
    struct tm tm;
    gmtime_r(&ts.tv_sec, &tm);
    snprintf(head, sizeof head, "%04d-%02d-%02dT%02d:%02d:%02d", tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday,
             tm.tm_hour, tm.tm_min, tm.tm_sec);
    sec_cached = ts.tv_sec;
  }
  int ms = (int)(ts.tv_nsec / 1000000);
  memcpy(out, head, 19);
  out[19] = '.';
  out[20] = (char)('0' + ms / 100);
  out[21] = (char)('0' + ms / 10 % 10);
  out[22] = (char)('0' + ms % 10);
  out[23] = 'Z';
  out[24] = 0;
  return 24;
}

/* The created_at of the write phase's rows. The model gives each write phase one clock reading
 * (DB.clock, Feed/Spec.lean): every post a batch inserts gets the same created_at. So the first
 * insert after the reads end takes the time (db_now) and the later inserts of the phase reuse it;
 * a phase runs from feed_db_end_reads to feed_db_commit, which both clear phase_now_len. */
static char phase_now[32];
static const char *db_phase_now(int *len) {
  if (!phase_now_len) phase_now_len = db_now(phase_now);
  *len = phase_now_len;
  return phase_now;
}

/* insertLike uid pid: insert the like unless present. 1 inserted, 0 already there, 2 error. */
LEAN_EXPORT lean_obj_res feed_db_insert_like(b_lean_obj_arg uidn, b_lean_obj_arg pidn) {
  u64_t uid = nat_u64(uidn), pid = nat_u64(pidn);
  if (uid > (u64_t)INT64_MAX || pid > (u64_t)INT64_MAX) return io_ok(lean_box(2));
  int nl;
  const char *now = db_phase_now(&nl);
  sqlite3_bind_int64(st_like, 1, (i64_t)uid);
  sqlite3_bind_int64(st_like, 2, (i64_t)pid);
  sqlite3_bind_text(st_like, 3, now, nl, SQLITE_STATIC);
  int rc = sqlite3_step(st_like);
  int changed = sqlite3_changes(db);
  if (rc != SQLITE_DONE) db_log_error("insert like");
  sqlite3_reset(st_like);
  return io_ok(lean_box(rc != SQLITE_DONE ? 2 : changed ? 1 : 0));
}

/* insertPost uid body: insert the post; its created_at and id (id 0 on error). */
LEAN_EXPORT lean_obj_res feed_db_insert_post(b_lean_obj_arg uidn, b_lean_obj_arg body) {
  u64_t uid = nat_u64(uidn), id = 0;
  lean_object *created = lean_alloc_sarray(1, 0, 32);
  if (uid <= (u64_t)INT64_MAX) {
    int nl;
    const char *now = db_phase_now(&nl);
    sqlite3_bind_int64(st_post, 1, (i64_t)uid);
    sqlite3_bind_text(st_post, 2, (const char *)lean_sarray_cptr(body), (int)lean_sarray_size(body), SQLITE_STATIC);
    sqlite3_bind_text(st_post, 3, now, nl, SQLITE_STATIC);
    int rc = sqlite3_step(st_post);
    if (rc != SQLITE_DONE) db_log_error("insert post");
    else if (sqlite3_changes(db) == 1) {
      i64_t v = sqlite3_last_insert_rowid(db);
      if (v > 0) {
        id = (u64_t)v;
        memcpy(lean_sarray_cptr(created), now, (size_t)nl);
        lean_to_sarray(created)->m_size = (size_t)nl;
      }
    }
    sqlite3_reset(st_post);
    sqlite3_clear_bindings(st_post);
  }
  return io_ok(mk_pair(created, u64_nat(id)));
}

/* For the self-test: lookup_many against sqlite3BtreeTableMoveto on the users table, for sets of
 * sorted distinct keys (every key up to past the largest, in runs of up to MANY; and random sets),
 * in one read transaction so that the pinned interior pages are reused. 1 if they agree. */
static int check_keys_by(int (*lookup)(Pgno, const i64_t *, int, MemPage **, int *, u8_t *), Pgno root, BtCursor *cur,
                         const i64_t *key, int n) {
  MemPage *hit[MANY];
  int cell[MANY], ok = 1;
  u8_t hown[MANY];
  pt_room();
  if (lookup(root, key, n, hit, cell, hown)) return 0;
  for (int i = 0; i < n; i++) {
    int res = 1;
    if (sqlite3BtreeTableMoveto(cur, key[i], 0, &res) != SQLITE_OK) ok = 0;
    else if ((res == 0) != (hit[i] != 0)) ok = 0;
    else if (hit[i]) {
      u32_t a, b;
      const u8_t *ra = cur_payload(cur, &a), *rb = hit_record(hit[i], cell[i], &b);
      if (!ra || !rb || a != b || memcmp(ra, rb, a)) ok = 0;
    }
  }
  hits_done(hit, hown, n);
  return ok;
}
/* find_rowid against sqlite3BtreeTableMoveto for key[0, n) in the order given, the levels' memory
 * kept from one key to the next as in user_names. 1 if they agree. */
static int check_find_order(Pgno root, BtCursor *cur, const i64_t *key, int n) {
  u8_t rown;
  pt_room();
  MemPage *r = pg_get(root, &rown);
  if (!r) return 0;
  if (!r->intKey || r->nCell == 0 || r->nOverflow) { pg_done(r, rown); return 0; }
  lvl_t L[BTCURSOR_MAX_DEPTH];
  for (int d = 0; d < BTCURSOR_MAX_DEPTH; d++) L[d].pg = 0;
  int ok = 1;
  for (int i = 0; ok && i < n; i++) {
    MemPage *leaf;
    u8_t lown;
    const u8_t *rec;
    u32_t len;
    int ix, f = find_rowid(r, key[i], L, &leaf, &lown, &ix, &rec, &len), res = 1;
    if (f < 0 || sqlite3BtreeTableMoveto(cur, key[i], 0, &res) != SQLITE_OK || (res == 0) != (f == 1)) ok = 0;
    else if (f == 1) {
      u32_t a;
      const u8_t *ra = cur_payload(cur, &a);
      const u8_t *rx;
      u32_t lx;
      if (!ra || !rec || a != len || memcmp(ra, rec, a)) ok = 0;
      else if (ix < 0 || ix >= leaf->nCell || leaf_cell(leaf, ix, &rx, &lx) != key[i] || rx != rec) ok = 0;
    }
    if (f == 1) pg_done(leaf, lown);
  }
  pg_done(r, rown);
  return ok;
}
/* ... for sorted keys in their order and zig-zag (first, last, second, ...: the memory misses). */
static int check_find(Pgno root, BtCursor *cur, const i64_t *key, int n) {
  i64_t zz[MANY];
  for (int i = 0; i < n; i++) zz[i] = i % 2 ? key[n - 1 - i / 2] : key[i / 2];
  return check_find_order(root, cur, key, n) && check_find_order(root, cur, zz, n);
}
/* Both grouped searches (level by level, and one descent per leaf) and the one-key search against
 * the cursor. */
static int check_keys(Pgno root, BtCursor *cur, const i64_t *key, int n) {
  return check_keys_by(lookup_many, root, cur, key, n) && check_keys_by(lookup_sorted, root, cur, key, n) &&
         check_find(root, cur, key, n);
}
/* Every key up to past the largest, in runs of MANY, and random sets of sorted distinct keys. */
static int check_table(Pgno root, BtCursor *cur) {
  int ok = 1, empty = 1;
  i64_t top = 0;
  if (sqlite3BtreeLast(cur, &empty) != SQLITE_OK) return 0;
  if (!empty) top = sqlite3BtreeIntegerKey(cur);
  i64_t key[MANY];
  for (i64_t k = 0; ok && k <= top + 70; k += MANY) {
    for (int i = 0; i < MANY; i++) key[i] = k + i;
    ok = check_keys(root, cur, key, MANY);
  }
  u64_t r = 0x853c49e6748fea9bull;
  for (int round = 0; ok && round < 4000; round++) {
    r ^= r << 13; r ^= r >> 7; r ^= r << 17;
    int n = 1 + (int)(r % MANY), nk = 0;
    i64_t base = (i64_t)((r >> 8) % (u64_t)(top + 100)), span = round % 3 == 0 ? 3 * MANY : top + 100;
    for (int i = 0; i < n; i++) {
      r ^= r << 13; r ^= r >> 7; r ^= r << 17;
      i64_t v = round % 3 == 0 ? base + (i64_t)(r % (u64_t)span) : (i64_t)(r % (u64_t)span);
      int j = nk;
      while (j > 0 && key[j - 1] > v) j--;
      if (j > 0 && key[j - 1] == v) continue;
      memmove(key + j + 1, key + j, (size_t)(nk - j) * sizeof *key);
      key[j] = v;
      nk++;
    }
    ok = check_keys(root, cur, key, nk);
  }
  return ok;
}
LEAN_EXPORT lean_obj_res feed_db_check_lookups(void) {
  lean_dec(feed_db_begin());
  int ok = reads_open && check_table(root_users, c_users) && check_table(root_posts, c_posts);
  lean_dec(feed_db_end_reads());
  lean_dec(feed_db_commit());
  return io_ok(lean_box(ok));
}

/* For the self-test: a transaction that grows the database and rolls back, then one that commits,
 * through the page cache wrapper (which drops the pages past the end of the file at the end of a
 * transaction); then SQLite's integrity check. 1 if every count and the check come out right. */
static int integrity_ok(void) {
  sqlite3_stmt *s = db_prepare("PRAGMA integrity_check");
  int ok = sqlite3_step(s) == SQLITE_ROW && !strcmp((const char *)sqlite3_column_text(s, 0), "ok");
  sqlite3_finalize(s);
  return ok;
}
static i64_t q_int(const char *sql) {
  sqlite3_stmt *s = db_prepare(sql);
  i64_t v = sqlite3_step(s) == SQLITE_ROW ? sqlite3_column_int64(s, 0) : -1;
  sqlite3_finalize(s);
  return v;
}
/* For the self-test: the iterator's pass over an index against the cursor's (sqlite3BtreeFirst,
 * sqlite3BtreeNext): the same entries in the same order. 1 if they agree. */
static int check_index_order(Pgno root, BtCursor *cur) {
  it_t it;
  int r = it_first(&it, root), empty = 1, ok = 1;
  if (sqlite3BtreeFirst(cur, &empty) != SQLITE_OK) ok = 0;
  while (ok) {
    if (r != 0 || empty) { ok = r == 1 && empty; break; }
    u32_t a, b;
    const u8_t *ra = it_rec(&it, &a), *rb = cur_payload(cur, &b);
    if (!ra || !rb || a != b || memcmp(ra, rb, a)) { ok = 0; break; }
    r = it_next(&it);
    int rc = sqlite3BtreeNext(cur, 0);
    if (rc == SQLITE_DONE) empty = 1;
    else if (rc != SQLITE_OK) ok = 0;
    pt_room();
  }
  it_close(&it);
  return ok;
}
/* The like counts of likes_window against the cursor's, for every post id up to past top alone
 * and for random windows of ids; 1 if they agree. */
static int check_likes_upto(i64_t top) {
  int ok = 1;
  for (i64_t id = 0; ok && id <= top + 3; id++) {
    u32_t a = 0;
    if (likes_window(id, id, &a) || a != like_count_one((u64_t)id)) ok = 0;
    pt_room();
  }
  u32_t wa[300], wb[300];
  u64_t r = 0x9e3779b97f4a7c15ull;
  for (int round = 0; ok && round < 3000; round++) {
    r ^= r << 13; r ^= r >> 7; r ^= r << 17;
    i64_t lo = (i64_t)(r % (u64_t)(top + 10)), w = 1 + (i64_t)((r >> 24) % 300);
    memset(wa, 0, sizeof wa);
    memset(wb, 0, sizeof wb);
    if (likes_window(lo, lo + w - 1, wa)) ok = 0;
    likes_window_cursor(lo, lo + w - 1, wb);
    if (memcmp(wa, wb, sizeof wa)) ok = 0;
    pt_room();
  }
  return ok;
}
/* The feed's ids by the iterator against the cursor's, for several n up to the whole index; 1 if
 * they agree. */
static int check_feed_ids(void) {
  static const u64_t ns[] = {0, 1, 2, 19, 20, 21, 63, 64, 65, 200, 5000, UINT64_MAX};
  int ok = 1;
  for (size_t i = 0; ok && i < sizeof ns / sizeof ns[0]; i++) {
    i64_t ba[64], bb[64], *a = ba, *b = bb;
    size_t ca = 64, cb = 64;
    pt_room();
    long ka = feed_ids_it(ns[i], &a, &ca, ba);
    size_t kb = feed_ids_cursor(ns[i], &b, &cb, bb);
    if (ka < 0 || (size_t)ka != kb || (kb && memcmp(a, b, kb * sizeof *a))) ok = 0;
    if (a != ba) free(a);
    if (b != bb) free(b);
  }
  return ok;
}
/* post_cols against rec_cols on every posts record: whole, cut short (also to the header's first
 * bytes), and with each header size from 0 to 9. 1 if they agree. */
static int post_cols_agree(const u8_t *rec, u32_t n) {
  col_t a[4], b[4];
  int ra = post_cols(rec, n, a), rb = rec_cols(rec, n, 4, b);
  if (ra != rb) return 0;
  if (ra == 0)
    for (int j = 0; j < 4; j++)
      if (a[j].t != b[j].t || a[j].p != b[j].p) return 0;
  return 1;
}
static int check_post_cols(void) {
  int empty = 1, ok = 1;
  static u8_t buf[4096];
  if (sqlite3BtreeFirst(c_posts, &empty) != SQLITE_OK) return 0;
  while (ok && !empty) {
    u32_t len;
    const u8_t *rec = cur_payload(c_posts, &len);
    if (!rec || len > sizeof buf) return 0;
    for (u32_t cut = 0; ok && cut <= 8 && cut <= len; cut++) ok = post_cols_agree(rec, len - cut);
    for (u32_t n = 0; ok && n < 8 && n <= len; n++) ok = post_cols_agree(rec, n);
    memcpy(buf, rec, len);
    for (u8_t h = 0; ok && h < 10 && len > 0; h++) { buf[0] = h; ok = post_cols_agree(buf, len); }
    int rc = sqlite3BtreeNext(c_posts, 0);
    if (rc == SQLITE_DONE) empty = 1;
    else if (rc != SQLITE_OK) ok = 0;
  }
  return ok;
}
/* feed_rows_desc against the cursor (sqlite3BtreeTableMoveto, the record by rec_cols) for runs of
 * consecutive descending ids, of random lengths up to MANY, ending at every id up to past the
 * largest rowid of posts (every third past 2,000). 1 if they agree: the same rows, user ids and
 * texts. */
static int check_rows_desc(void) {
  int empty = 1, ok = 1;
  i64_t top = 0;
  if (sqlite3BtreeLast(c_posts, &empty) != SQLITE_OK) return 0;
  if (!empty) top = sqlite3BtreeIntegerKey(c_posts);
  u64_t r = 0x51ed27bf4a1c3d95ull;
  for (i64_t hi = -2; ok && hi <= top + 70; hi += hi < 2000 ? 1 : 3) {
    r ^= r << 13; r ^= r >> 7; r ^= r << 17;
    int k = 1 + (int)(r % MANY);
    i64_t ids[MANY];
    for (int q = 0; q < k; q++) ids[q] = hi - q;
    prow_t got[MANY];
    pt_room();
    lean_object *blob = lean_alloc_sarray(1, 0, 64);
    long n = feed_rows_desc(&blob, ids, (size_t)k, got);
    int m = 0;
    for (int q = 0; ok && q < k; q++) {
      int res = 1;
      if (sqlite3BtreeTableMoveto(c_posts, ids[q], 0, &res) != SQLITE_OK) { ok = 0; break; }
      if (res != 0) continue;
      u32_t len;
      const u8_t *rec = cur_payload(c_posts, &len);
      col_t c[4];
      if (!rec || rec_cols(rec, len, 4, c) || !col_is_int(&c[1]) || !col_is_text(&c[2]) || !col_is_text(&c[3])) {
        ok = 0;
        break;
      }
      u32_t bl = serial_len(c[2].t), cl = serial_len(c[3].t);
      const prow_t *g = &got[m++];
      ok = n >= m && g->id == ids[q] && g->uid == col_int(&c[1]) && g->c - g->b == bl && g->e - g->c == cl &&
           g->e <= lean_sarray_size(blob) && !memcmp(lean_sarray_cptr(blob) + g->b, c[2].p, bl) &&
           !memcmp(lean_sarray_cptr(blob) + g->c, c[3].p, cl);
    }
    if (n != m) ok = 0;
    lean_dec(blob);
  }
  return ok;
}
static int check_reads(i64_t top) {
  return check_index_order(root_feed_idx, c_feed_idx) && check_index_order(root_likes_post_idx, c_likes) &&
         check_feed_ids() && check_likes_upto(top) && check_table(root_posts, c_posts) && check_post_cols() &&
         check_rows_desc();
}
/* For the self-test: the reads of the batch's pages (the index passes, the like counts, the grouped
 * search on posts) against SQLite's cursors, on the test database, then, in a transaction that is
 * rolled back, with 40,000 posts and 200,000 likes more: posts, posts_created_at_id_idx and
 * likes_post_id_idx then have three levels (the indexes keep entries in interior cells on two). */
LEAN_EXPORT lean_obj_res feed_db_check_index(void) {
  i64_t top = q_int("SELECT max(post_id) FROM likes");
  lean_dec(feed_db_begin());
  int ok = reads_open && top > 0 && check_reads(top);
  lean_dec(feed_db_end_reads());
  lean_dec(feed_db_commit());
  i64_t span = 40000;
  db_exec("BEGIN");
  static const char *stamps[] = {"2025-01-01T00:00:00.000Z", "2025-06-30T12:00:00.000Z", "2026-01-01T00:00:00.000Z",
                                 "2025-06-30T12:00:00.001Z"};
  sqlite3_stmt *ins = db_prepare("INSERT INTO posts (user_id, body, created_at) VALUES (?1, ?2, ?3)");
  u64_t r = 0x2545f4914f6cdd1dull;
  char body[128];
  for (int i = 0; ok && i < (int)span; i++) {
    r ^= r << 13; r ^= r >> 7; r ^= r << 17;
    int bl = 1 + (int)(r % 100);
    memset(body, 'a' + (int)(r >> 40) % 26, (size_t)bl);
    sqlite3_bind_int64(ins, 1, 1 + (i64_t)((r >> 8) % 60000));
    sqlite3_bind_text(ins, 2, body, bl, SQLITE_STATIC);
    sqlite3_bind_text(ins, 3, stamps[(r >> 20) % 4], -1, SQLITE_STATIC);
    if (step_reset(ins) != SQLITE_DONE) ok = 0;
  }
  sqlite3_finalize(ins);
  ins = db_prepare("INSERT INTO likes (user_id, post_id) VALUES (?1, ?2)");
  for (int i = 0; ok && i < 200000; i++) {
    r ^= r << 13; r ^= r >> 7; r ^= r << 17;
    sqlite3_bind_int64(ins, 1, 1000000 + i);
    sqlite3_bind_int64(ins, 2, 1 + (i64_t)(r % (u64_t)span));
    if (step_reset(ins) != SQLITE_DONE) ok = 0;
  }
  sqlite3_finalize(ins);
  ok = ok && q_int("SELECT count(*) FROM likes") > 200000;
  cursor_open(c_posts, root_posts, 0);
  cursor_open(c_feed_idx, root_feed_idx, ki_feed_idx);
  cursor_open(c_likes, root_likes_post_idx, ki_likes_post_idx);
  reads_open = 1;
  ok = ok && check_reads(span);
  pins_release();
  sqlite3BtreeCloseCursor(c_posts);
  sqlite3BtreeCloseCursor(c_feed_idx);
  sqlite3BtreeCloseCursor(c_likes);
  reads_open = 0;
  db_exec("ROLLBACK");
  ok = ok && q_int("SELECT count(*) FROM likes") < 200000;
  return io_ok(lean_box(ok));
}

LEAN_EXPORT lean_obj_res feed_db_check_rollback(void) {
  i64_t n0 = q_int("SELECT count(*) FROM posts"), pages0 = q_int("PRAGMA page_count");
  char big[401];
  memset(big, 'R', 400); big[400] = 0;
  char sql[600];
  db_exec("BEGIN");
  for (int i = 0; i < 3000; i++) {
    snprintf(sql, sizeof sql, "INSERT INTO posts (user_id, body) VALUES (%d, '%s')", 1 + i % 50, big);
    db_exec(sql);
  }
  int ok = q_int("PRAGMA page_count") > pages0 + 100;   /* the file grew */
  db_exec("ROLLBACK");

  ok = ok && q_int("SELECT count(*) FROM posts") == n0 && q_int("PRAGMA page_count") == pages0;
  memset(big, 'C', 400);
  db_exec("BEGIN");
  for (int i = 0; i < 2000; i++) {
    snprintf(sql, sizeof sql, "INSERT INTO posts (user_id, body) VALUES (%d, '%s')", 1 + i % 50, big);
    db_exec(sql);
  }
  db_exec("COMMIT");
  ok = ok && q_int("SELECT count(*) FROM posts") == n0 + 2000 &&
       q_int("SELECT count(*) FROM posts WHERE body GLOB 'R*'") == 0 &&
       q_int("SELECT count(*) FROM posts WHERE body GLOB 'C*'") == 2000;
  ok = ok && integrity_ok();
  db_exec("DELETE FROM posts WHERE body GLOB 'C*'");
  return io_ok(lean_box(ok));
}
/* For the self-test: PRAGMA integrity_check says ok. */
LEAN_EXPORT lean_obj_res feed_db_integrity(void) { return io_ok(lean_box(integrity_ok())); }

/* For the self-test (Feed/Selftest.lean): create a database file from an SQL script. */
LEAN_EXPORT lean_obj_res feed_db_create(b_lean_obj_arg path, b_lean_obj_arg script) {
  sqlite3 *d = 0;
  int rc = sqlite3_open_v2(lean_string_cstr(path), &d, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, 0);
  char *err = 0;
  if (rc == SQLITE_OK) rc = sqlite3_exec(d, lean_string_cstr(script), 0, 0, &err);
  if (rc != SQLITE_OK) fprintf(stderr, "selftest: %s\n", err ? err : sqlite3_errmsg(d));
  sqlite3_free(err);
  sqlite3_close(d);
  /* back to an uninitialized library, so that db_open's settings (the page cache pool and wrapper,
   * which sqlite3_config accepts only then) apply to the self-test's reads as to the server's */
  sqlite3_shutdown();
  return io_ok(lean_box(rc == SQLITE_OK));
}

/* commit: 1 if the batch's transaction committed. */
LEAN_EXPORT lean_obj_res feed_db_commit(void) {

  if (reads_open) lean_dec(feed_db_end_reads());
  phase_now_len = 0;   /* the write phase ends */
  if (sqlite3_get_autocommit(db)) return io_ok(lean_box(1));
  if (step_reset(st_commit) == SQLITE_DONE) return io_ok(lean_box(1));
  db_log_error("commit");
  step_reset(st_rollback);
  return io_ok(lean_box(0));
}

/* health: SELECT 1 succeeded. */
LEAN_EXPORT lean_obj_res feed_db_health(void) {

  int rc = sqlite3_step(st_health);
  sqlite3_reset(st_health);
  return io_ok(lean_box(rc == SQLITE_ROW ? 1 : 0));
}
