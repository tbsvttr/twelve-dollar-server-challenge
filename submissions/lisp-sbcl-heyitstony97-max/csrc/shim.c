/* The only C in this entry: SQLite itself (the pinned, unmodified amalgamation, #included below so
 * the compiler sees one translation unit), a few open/prepare helpers that run once at boot, and
 * the idle-priority helper thread.
 *
 * The helper thread is plain C and never touches the Lisp heap. SBCL's GC stops every thread it
 * knows about; this one is invisible to it, so a collection never waits for (or runs) a
 * checkpoint. It owns everything that is not urgent:
 *   - WAL checkpoints (its own SQLite connection, PASSIVE: readers and writers never wait for it),
 *   - the memory monitor (/proc/meminfo every 200 ms into a word the event loop reads),
 *   - stats logging (the event loop writes its counters into td_stats; this thread prints them).
 * It lowers its own scheduling class to SCHED_IDLE, falling back to nice 19 when refused, so on
 * the one vCPU it only runs when the event loop is waiting. */
#define _GNU_SOURCE
#include "sqlite3.c"

#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <stdlib.h>
#include <sched.h>
#include <pthread.h>
#include <unistd.h>
#include <time.h>
#include <fcntl.h>
#include <sys/resource.h>
#include <sys/syscall.h>

static sqlite3 *main_db;   /* the event loop's connection (set by shim_open) */

static int run(sqlite3 *db, const char *sql, char *err, int n) {
  char *msg = 0;
  if (sqlite3_exec(db, sql, 0, 0, &msg) != SQLITE_OK) {
    snprintf(err, n, "%s: %s", sql, msg ? msg : "error");
    sqlite3_free(msg);
    return -1;
  }
  return 0;
}

/* Opens the database through the unix-excl VFS (this process takes an exclusive lock and keeps it,
 * and the WAL index lives in heap memory) and applies the pragmas. NULL on failure, reason in err.
 * wal_autocheckpoint is the emergency valve only: the helper thread normally checkpoints long
 * before the WAL reaches 32,768 pages, and then the event loop never does. */
sqlite3 *shim_open(const char *path, char *err, int n) {
  sqlite3 *db = 0;
  int rc = sqlite3_initialize();
  if (rc != SQLITE_OK) { snprintf(err, n, "sqlite3_initialize: %d", rc); return 0; }
  rc = sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, "unix-excl");
  if (rc != SQLITE_OK) {
    snprintf(err, n, "open %s: %s", path, db ? sqlite3_errmsg(db) : "out of memory");
    if (db) sqlite3_close(db);
    return 0;
  }
  sqlite3_busy_timeout(db, 5000);
  if (run(db, "PRAGMA journal_mode = WAL", err, n) || run(db, "PRAGMA synchronous = NORMAL", err, n) ||
      run(db, "PRAGMA temp_store = MEMORY", err, n) || run(db, "PRAGMA cache_size = -65536", err, n) ||
      run(db, "PRAGMA mmap_size = 0", err, n) || run(db, "PRAGMA wal_autocheckpoint = 32768", err, n) ||
      run(db, "SELECT count(*) FROM sqlite_schema", err, n)) {
    sqlite3_close(db);
    return 0;
  }
  main_db = db;
  return db;
}

/* A statement kept for the life of the process. */
sqlite3_stmt *shim_prepare(sqlite3 *db, const char *sql, char *err, int n) {
  sqlite3_stmt *st = 0;
  if (sqlite3_prepare_v3(db, sql, -1, SQLITE_PREPARE_PERSISTENT, &st, 0) != SQLITE_OK) {
    snprintf(err, n, "prepare: %s", sqlite3_errmsg(db));
    return 0;
  }
  return st;
}

/* ---- B-tree cursor reads (PR #153: the organiser allowed reading through SQLite's own B-tree) ---
 *
 * GET /feed, GET /posts/:id and the like handler's existence check read SQLite's B-tree cursors
 * inside the pass's read transaction instead of running the bytecode engine. The cursors are thin
 * wrappers over the unmodified amalgamation's internals (this file #includes sqlite3.c). Record
 * decoding happens in Lisp (src/btree.lisp). Writes stay on prepared SQL.
 *
 * td_bt_init checks the schema the decoders assume and resolves the four root pages once; on any
 * surprise it returns -1 with the reason and the server uses the prepared-SQL path instead. Nothing
 * here depends on row data: only on the schema. Every request seeks and reads its rows live. */
static Btree *bt;
static Pgno root_posts, root_users, root_feed_idx, root_likes_idx;
static KeyInfo *ki_feed, *ki_likes;
#define NCUR 4
static BtCursor *cur[NCUR];
static int cur_open;
static uint8_t *spill;     /* records that spill onto overflow pages are copied here */
static uint32_t spill_cap;

static Pgno bt_rootpage(const char *name) {
  sqlite3_stmt *s;
  Pgno r = 0;
  if (sqlite3_prepare_v2(main_db, "SELECT rootpage FROM sqlite_schema WHERE name = ?1", -1, &s, 0)) return 0;
  sqlite3_bind_text(s, 1, name, -1, SQLITE_STATIC);
  if (sqlite3_step(s) == SQLITE_ROW) r = (Pgno)sqlite3_column_int64(s, 0);
  sqlite3_finalize(s);
  return r;
}

/* Comma-joined result of a one-column query equals `want`. */
static int bt_layout(const char *sql, const char *want) {
  sqlite3_stmt *s;
  char got[512];
  size_t n = 0;
  got[0] = 0;
  if (sqlite3_prepare_v2(main_db, sql, -1, &s, 0)) return 0;
  while (sqlite3_step(s) == SQLITE_ROW) {
    const char *c = (const char *)sqlite3_column_text(s, 0);
    n += snprintf(got + n, sizeof got - n, "%s%s", n ? "," : "", c ? c : "");
    if (n >= sizeof got) break;
  }
  sqlite3_finalize(s);
  return strcmp(got, want) == 0;
}

static KeyInfo *bt_keyinfo(int nkey, int nextra, int desc) {
  KeyInfo *k = sqlite3KeyInfoAlloc(main_db, nkey, nextra);
  if (!k) return 0;
  for (int i = 0; i < nkey + nextra; i++) k->aColl[i] = main_db->pDfltColl;
  for (int i = 0; i < nkey; i++) k->aSortFlags[i] = desc ? KEYINFO_ORDER_DESC : 0;
  return k;
}

/* The sqlite_schema text the decoders were written against, compared with what the file holds
 * (SQLite keeps the CREATE statement as typed). Any difference: do not use the B-tree path. */
static int bt_sql_is(const char *name, const char *want) {
  sqlite3_stmt *s;
  int ok = 0;
  if (sqlite3_prepare_v2(main_db, "SELECT sql FROM sqlite_schema WHERE name = ?1", -1, &s, 0)) return 0;
  sqlite3_bind_text(s, 1, name, -1, SQLITE_STATIC);
  if (sqlite3_step(s) == SQLITE_ROW) {
    const char *t = (const char *)sqlite3_column_text(s, 0);
    ok = t && strcmp(t, want) == 0;
  }
  sqlite3_finalize(s);
  return ok;
}

int td_bt_init(char *err, int n) {
  static const char *checks[][2] = {
    {"SELECT name FROM pragma_table_info('posts')", "id,user_id,body,created_at"},
    {"SELECT name FROM pragma_table_info('users')", "id,username,created_at"},
    {"SELECT name FROM pragma_table_info('likes')", "user_id,post_id,created_at"},
    {"SELECT name FROM pragma_index_info('posts_created_at_id_idx')", "created_at,id"},
    {"SELECT name FROM pragma_index_info('likes_post_id_idx')", "post_id"},
    {"SELECT desc FROM pragma_index_xinfo('posts_created_at_id_idx') WHERE key", "1,1"},
    {"SELECT desc FROM pragma_index_xinfo('likes_post_id_idx') WHERE key", "0"},
    {"SELECT type FROM pragma_table_info('posts')", "INTEGER,INTEGER,TEXT,TEXT"},
    {"SELECT type FROM pragma_table_info('users')", "INTEGER,TEXT,TEXT"},
    {"SELECT pk FROM pragma_table_info('posts')", "1,0,0,0"},
    {"SELECT pk FROM pragma_table_info('users')", "1,0,0"},
  };
  if (!main_db) { snprintf(err, n, "no database"); return -1; }
  for (size_t i = 0; i < sizeof checks / sizeof checks[0]; i++) {
    if (!bt_layout(checks[i][0], checks[i][1])) {
      snprintf(err, n, "unexpected schema (%s)", checks[i][0]);
      return -1;
    }
  }
  if (!bt_sql_is("posts_created_at_id_idx", "CREATE INDEX posts_created_at_id_idx ON posts (created_at DESC, id DESC)") ||
      !bt_sql_is("likes_post_id_idx", "CREATE INDEX likes_post_id_idx       ON likes (post_id)")) {
    snprintf(err, n, "unexpected index SQL");
    return -1;
  }
  if (ENC(main_db) != SQLITE_UTF8) { snprintf(err, n, "database text encoding is not UTF-8"); return -1; }
  root_posts = bt_rootpage("posts");
  root_users = bt_rootpage("users");
  root_feed_idx = bt_rootpage("posts_created_at_id_idx");
  root_likes_idx = bt_rootpage("likes_post_id_idx");
  if (!root_posts || !root_users || !root_feed_idx || !root_likes_idx) { snprintf(err, n, "root pages"); return -1; }
  ki_feed = bt_keyinfo(2, 1, 1);
  ki_likes = bt_keyinfo(1, 1, 0);
  if (!ki_feed || !ki_likes) { snprintf(err, n, "keyinfo"); return -1; }
  bt = main_db->aDb[0].pBt;
  for (int i = 0; i < NCUR; i++) {
    cur[i] = sqlite3_malloc(sqlite3BtreeCursorSize());
    if (!cur[i]) { snprintf(err, n, "cursor alloc"); return -1; }
  }
  return 0;
}

/* Called right after the BEGIN statement succeeded (BEGIN is deferred and takes no lock): joins the
 * read transaction at the B-tree level and opens the four cursors. 0 ok, -1 failed. */
int td_bt_open_cursors(void) {
  if (cur_open) return 0;
  if (sqlite3BtreeBeginTrans(bt, 0, 0) != SQLITE_OK) return -1;
  static const Pgno *roots[NCUR] = {&root_posts, &root_users, &root_feed_idx, &root_likes_idx};
  KeyInfo *kis[NCUR] = {0, 0, ki_feed, ki_likes};
  for (int i = 0; i < NCUR; i++) {
    sqlite3BtreeCursorZero(cur[i]);
    if (sqlite3BtreeCursor(bt, *roots[i], 0, kis[i], cur[i]) != SQLITE_OK) {
      for (int j = 0; j < i; j++) sqlite3BtreeCloseCursor(cur[j]);
      return -1;
    }
  }
  cur_open = 1;
  return 0;
}

/* Before COMMIT or ROLLBACK. */
void td_bt_close_cursors(void) {
  if (!cur_open) return;
  for (int i = 0; i < NCUR; i++) sqlite3BtreeCloseCursor(cur[i]);
  cur_open = 0;
}

/* Is the batch's transaction still open at SQLite's level? (A failed statement can end it.) */
int td_in_txn(void) { return !sqlite3_get_autocommit(main_db); }

unsigned long td_cursor(int i) { return (unsigned long)cur[i]; }

/* Table cursor to rowid `id`: 1 found, 0 absent, -1 error. */
int td_seek(BtCursor *c, i64 id) {
  int res = 0;
  if (sqlite3BtreeTableMoveto(c, id, 0, &res) != SQLITE_OK) return -1;
  return res == 0 && c->eState == CURSOR_VALID;
}

/* Index cursor to the first entry whose leading integer column is >= k: 1 on an entry, 0 none. */
int td_seek_ge(BtCursor *c, i64 k) {
  Mem m;
  UnpackedRecord r;
  int res = 0;
  memset(&m, 0, sizeof m);
  m.flags = MEM_Int;
  m.u.i = k;
  memset(&r, 0, sizeof r);
  r.pKeyInfo = c->pKeyInfo;
  r.aMem = &m;
  r.nField = 1;
  r.default_rc = +1; /* entries equal on the key sort after it: land on the first of them */
  if (sqlite3BtreeIndexMoveto(c, &r, &res) != SQLITE_OK) return -1;
  if (sqlite3BtreeEof(c)) return 0;
  if (res < 0) {
    int rc = sqlite3BtreeNext(c, 0);
    if (rc == SQLITE_DONE) return 0;
    if (rc != SQLITE_OK) return -1;
  }
  return 1;
}

/* Likes per post for lo <= post_id <= hi, read off likes_post_id_idx (post_id, rowid) in one walk:
 * n[post_id - lo] counts the entries (n has hi - lo + 1 zeroed slots). 0 ok, -1 error, 1 a cell not
 * in the expected form (the caller then decodes the entries itself). */
int td_count_likes(BtCursor *c, i64 lo, i64 hi, unsigned *n) {
  int r = td_seek_ge(c, lo);
  if (r <= 0) return r;
  for (;;) {
    MemPage *pg = c->pPage;
    int i = c->ix, last = pg->leaf ? pg->nCell : i + 1; /* an interior entry: just this one */
    for (; i < last; i++) {
      u8 *cell = findCell(pg, i) + pg->childPtrSize;
      u32 len = cell[0];
      const u8 *p = cell + 1;
      if (len >= 0x80 || len < 3 || p + len > pg->aDataEnd) return 1;
      u32 h = p[0], t = p[1];
      if (h >= len || h < 3 || t >= 0x80) return 1;
      i64 v;
      if (t >= 1 && t <= 6) {
        static const u8 sz[7] = {0, 1, 2, 3, 4, 6, 8};
        u32 k = sz[t];
        if (h + k > len) return 1;
        const u8 *q = p + h;
        v = (i8)q[0];
        for (u32 j = 1; j < k; j++) v = v << 8 | q[j];
      } else if (t == 8 || t == 9) {
        v = t - 8;
      } else {
        return 1;
      }
      if (v > hi) return 0;
      if (v >= lo) n[v - lo]++;
    }
    c->ix = (u16)(last - 1);
    int rc = sqlite3BtreeNext(c, 0);
    if (rc == SQLITE_DONE) return 0;
    if (rc != SQLITE_OK) return -1;
  }
}

/* 1 on a row, 0 empty, -1 error. */
int td_first(BtCursor *c) {
  int empty = 1;
  if (sqlite3BtreeFirst(c, &empty) != SQLITE_OK) return -1;
  return !empty;
}

/* 1 on the next row, 0 at the end, -1 error. */
int td_next(BtCursor *c) {
  int rc = sqlite3BtreeNext(c, 0);
  if (rc == SQLITE_OK) return 1;
  return rc == SQLITE_DONE ? 0 : -1;
}

/* The current row's record bytes, valid until the cursor moves; *len gets the size. */
unsigned long td_payload(BtCursor *c, u32 *len) {
  getCellInfo(c);
  u32 total = c->info.nPayload;
  if (c->info.nLocal == total) { *len = total; return (unsigned long)c->info.pPayload; }
  if (total > spill_cap) {
    sqlite3_free(spill);
    spill_cap = total + 4096;
    spill = sqlite3_malloc(spill_cap);
    if (!spill) { spill_cap = 0; return 0; }
  }
  if (sqlite3BtreePayload(c, 0, total, spill) != SQLITE_OK) return 0;
  *len = total;
  return (unsigned long)spill;
}

/* ---- the helper thread ---------------------------------------------------------------------- */

/* Shared words. The event loop writes slots 0-8 and 10-11 (plain stores); this thread writes 9.
 *   0 turn_max_us (since the last report)   1 wait_max_us (since the last report)
 *   2 answer cap now                        3 open connections
 *   4 requests answered                     5 GCs so far
 *   6 passes                                7 turn_max_us overall
 *   8 wait_max_us overall                   9 MemAvailable kB (helper)
 *  10 requests answered in the last turn    11 checkpoints run (helper) */
volatile uint64_t td_stats[16];
static volatile int policy_applied;   /* 1 SCHED_IDLE, 2 nice 19, 0 none */
static char ckpt_path[1024];
static int stats_on;

unsigned long td_stats_addr(void) { return (unsigned long)td_stats; }
int td_helper_policy(void) { return policy_applied; }

static long mem_available_kb(void) {
  char buf[2048];
  int fd = open("/proc/meminfo", O_RDONLY | O_CLOEXEC);
  if (fd < 0) return -1;
  ssize_t n = read(fd, buf, sizeof buf - 1);
  close(fd);
  if (n <= 0) return -1;
  buf[n] = 0;
  char *p = strstr(buf, "MemAvailable:");
  return p ? atol(p + 13) : -1;
}

static void apply_policy(void) {
  pid_t tid = (pid_t)syscall(SYS_gettid);
  struct sched_param sp;
  memset(&sp, 0, sizeof sp);
  if (sched_setscheduler(tid, SCHED_IDLE, &sp) == 0 && sched_getscheduler(tid) == SCHED_IDLE) {
    policy_applied = 1;
  } else if (setpriority(PRIO_PROCESS, tid, 19) == 0 && getpriority(PRIO_PROCESS, tid) == 19) {
    policy_applied = 2;
  } else {
    policy_applied = 0;
  }
  fprintf(stderr, "helper thread: %s\n",
          policy_applied == 1 ? "SCHED_IDLE (sched_getscheduler read back 5)"
          : policy_applied == 2 ? "nice 19 (SCHED_IDLE refused)" : "default priority (both refused)");
}

static uint64_t mono_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static void *helper_main(void *arg) {
  (void)arg;
  apply_policy();
  sqlite3 *db = 0;
  /* Same VFS as the event loop's connection: in one process they share the exclusive lock. */
  if (sqlite3_open_v2(ckpt_path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, "unix-excl") != SQLITE_OK) {
    fprintf(stderr, "helper thread: cannot open the database for checkpoints: %s\n",
            db ? sqlite3_errmsg(db) : "out of memory");
    db = 0;
  } else {
    sqlite3_busy_timeout(db, 0);
    sqlite3_wal_autocheckpoint(db, 0);
  }
  uint64_t last_report = mono_ms();
  for (;;) {
    struct timespec ts = {0, 200 * 1000000L};
    nanosleep(&ts, 0);
    long kb = mem_available_kb();
    if (kb >= 0) td_stats[9] = (uint64_t)kb;
    if (db) {
      int log = 0, ck = 0;
      /* PASSIVE: copies what no reader needs and stops; never blocks the loop. */
      if (sqlite3_wal_checkpoint_v2(db, 0, SQLITE_CHECKPOINT_PASSIVE, &log, &ck) == SQLITE_OK && ck > 0)
        td_stats[11]++;
    }
    uint64_t now = mono_ms();
    if (stats_on && now - last_report >= 5000) {
      last_report = now;
      uint64_t tm = td_stats[0], wm = td_stats[1];
      td_stats[0] = 0; td_stats[1] = 0;
      fprintf(stderr,
              "stats: reqs=%llu conns=%llu passes=%llu turn_max_us=%llu (overall %llu) "
              "wait_max_us=%llu (overall %llu) cap=%llu gcs=%llu mem_avail_kb=%llu ckpts=%llu\n",
              (unsigned long long)td_stats[4], (unsigned long long)td_stats[3],
              (unsigned long long)td_stats[6], (unsigned long long)tm,
              (unsigned long long)td_stats[7], (unsigned long long)wm,
              (unsigned long long)td_stats[8], (unsigned long long)td_stats[2],
              (unsigned long long)td_stats[5], (unsigned long long)td_stats[9],
              (unsigned long long)td_stats[11]);
    }
  }
  return 0;
}

int td_start_helper(const char *path, int stats) {
  pthread_t t;
  pthread_attr_t at;
  snprintf(ckpt_path, sizeof ckpt_path, "%s", path);
  stats_on = stats;
  pthread_attr_init(&at);
  pthread_attr_setstacksize(&at, 256 * 1024);
  pthread_attr_setdetachstate(&at, PTHREAD_CREATE_DETACHED);
  int rc = pthread_create(&t, &at, helper_main, 0);
  pthread_attr_destroy(&at);
  return rc;
}
