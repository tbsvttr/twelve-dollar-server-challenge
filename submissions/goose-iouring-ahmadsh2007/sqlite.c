/* sqlite.c: SQLite under app.goose (the unmodified 3.54.1 amalgamation is compiled in here).
 *
 * Reads go through SQLite's own B-tree cursors inside the pass's transaction: this file moves a
 * cursor where Goose asks and copies the row's record bytes into a Goose buffer; app.goose
 * decodes the record and decides what to read next. Writes, BEGIN/COMMIT and /health are plain
 * SQL. A second thread, on its own connection, runs WAL checkpoints when app.goose asks for one
 * (the policy of when, and when writes must wait, is in app.goose). SQLITE_THREADSAFE=2: each
 * connection is used by one thread only. */
#include "sqlite3.c"
#include <pthread.h>
#include <stdbool.h>
#include <sys/resource.h>
#include <sys/syscall.h>
#include "goose.h"

typedef struct { const uint8_t *data; int64_t len; } bytes_t;
typedef struct { uint32_t *data; int64_t len; } counts_t;

enum { T_POSTS, T_USERS, T_FEED, T_LIKES, NTREES }; /* app.goose's C_POSTS .. C_LIKES */

static sqlite3 *conn;
static Btree *btree;
static Pgno root[NTREES];
static KeyInfo *keys[NTREES];
static BtCursor *curs[NTREES];
static bool tx_open, tx_lost;
static sqlite3_stmt *q_begin, *q_commit, *q_rollback, *q_post, *q_like, *q_ping, *q_feed;
static volatile int wal_size; /* frames in the log, as the WAL hook last reported */

static void say(gs_rref err, const char *what) {
  const char *m = conn ? sqlite3_errmsg(conn) : "no database";
  gs_bld_append(err, what, (int64_t)strlen(what));
  gs_bld_append(err, ": ", 2);
  gs_bld_append(err, m, (int64_t)strlen(m));
}

static int on_wal(void *u, sqlite3 *d, const char *n, int frames) {
  (void)u; (void)d; (void)n;
  wal_size = frames;
  return SQLITE_OK;
}

/* The first column of a one-row query, as text (or "" if none). */
static void one_text(const char *sql, char *out, size_t cap) {
  sqlite3_stmt *s;
  out[0] = 0;
  if (sqlite3_prepare_v2(conn, sql, -1, &s, 0) != SQLITE_OK) return;
  if (sqlite3_step(s) == SQLITE_ROW && sqlite3_column_text(s, 0))
    snprintf(out, cap, "%s", (const char *)sqlite3_column_text(s, 0));
  sqlite3_finalize(s);
}

static sqlite3_stmt *prepare(const char *sql) {
  sqlite3_stmt *s = 0;
  return sqlite3_prepare_v3(conn, sql, -1, SQLITE_PREPARE_PERSISTENT, &s, 0) == SQLITE_OK ? s : 0;
}

static KeyInfo *index_keys(int nkey, bool desc) {
  KeyInfo *k = sqlite3KeyInfoAlloc(conn, nkey, 1); /* the key columns, then the rowid */
  if (!k) return 0;
  for (int i = 0; i <= nkey; i++) k->aColl[i] = conn->pDfltColl;
  for (int i = 0; i < nkey; i++) k->aSortFlags[i] = desc ? KEYINFO_ORDER_DESC : 0;
  return k;
}

/* ---- the checkpointer ---- */

static sqlite3 *ck_conn;
static pthread_mutex_t ck_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t ck_wake = PTHREAD_COND_INITIALIZER;
static int ck_asked;           /* under ck_lock: a checkpoint is wanted */
static int ck_status;          /* 0 idle, 1 running, 2 done: everything copied, 3 done: some left */

static void *ck_thread(void *arg) {
  (void)arg;
  /* On one vCPU a checkpoint at the loop's priority takes the loop's CPU while it copies. */
  setpriority(PRIO_PROCESS, (id_t)syscall(SYS_gettid), 19);
  for (;;) {
    pthread_mutex_lock(&ck_lock);
    while (!ck_asked) pthread_cond_wait(&ck_wake, &ck_lock);
    ck_asked = 0;
    pthread_mutex_unlock(&ck_lock);
    int in_log = -1, copied = -1;
    /* PASSIVE: copies what it can without waiting on the loop's locks; the loop never waits on
     * this thread either. */
    int rc = sqlite3_wal_checkpoint_v2(ck_conn, "main", SQLITE_CHECKPOINT_PASSIVE, &in_log, &copied);
    __atomic_store_n(&ck_status, rc == SQLITE_OK && in_log == copied ? 2 : 3, __ATOMIC_RELEASE);
  }
  return 0;
}

/* Asks the thread for one checkpoint (ignored while one is running). */
void ck_ask(void) {
  if (__atomic_load_n(&ck_status, __ATOMIC_ACQUIRE) == 1) return;
  __atomic_store_n(&ck_status, 1, __ATOMIC_RELEASE);
  pthread_mutex_lock(&ck_lock);
  ck_asked = 1;
  pthread_cond_signal(&ck_wake);
  pthread_mutex_unlock(&ck_lock);
}

/* 0 idle, 1 running, 2 finished with the whole log copied, 3 finished with frames left.
 * Reading a finished status makes the checkpointer idle again. */
int32_t ck_poll(void) {
  int s = __atomic_load_n(&ck_status, __ATOMIC_ACQUIRE);
  if (s >= 2) __atomic_store_n(&ck_status, 0, __ATOMIC_RELEASE);
  return s;
}

/* Frames in the log. After a whole-log checkpoint the next write starts the log over; the hook
 * then reports the new, small size. */
int64_t wal_frames(void) { return wal_size; }

void wal_reset(void) { wal_size = 0; }

/* ---- one write per commit ----
 *
 * SQLite appends each log frame with two writes, its 24-byte header and then its page, so a
 * commit of 20 frames is 40 system calls. "goose" is a VFS over unix-excl that gathers a
 * commit's frames and writes them with one call, at the moment the commit frame's page
 * arrives: still inside SQLite's own write, so before the frames are entered in the WAL index
 * and before COMMIT returns, exactly when unix-excl would have finished writing them. Only
 * writes that continue where the previous one ended are gathered (the frames of a transaction,
 * the log header after a restart); any other write, and every read, sync, truncate, size query,
 * file control and close, first writes out what is gathered. The database file itself is opened
 * straight through unix-excl, untouched. */
typedef struct {
  sqlite3_file io;      /* our methods (WAL files only) */
  sqlite3_file *real;   /* the unix-excl file, which lives right after this struct */
  u8 *run;              /* gathered bytes, for the file at offset run_at */
  i64 run_at, next;     /* next: where the previous write ended */
  int run_len, run_cap;
  int commit_header;    /* the last write gathered was a commit frame's header */
} wal_file;

#define RUN_CAP (4 << 20)
static sqlite3_vfs *base_vfs, goose_vfs;
static sqlite3_io_methods wal_io;

/* The unix VFS writes at most 0x1ffff bytes per call (it masks the length), so a long run goes
 * out in pieces under that: one write for a typical commit, two or three for a large one. */
#define RUN_PIECE 0x1f000

static int run_out(wal_file *w) {
  int rc = SQLITE_OK;
  for (int done = 0; done < w->run_len && rc == SQLITE_OK; done += RUN_PIECE) {
    int n = w->run_len - done < RUN_PIECE ? w->run_len - done : RUN_PIECE;
    rc = w->real->pMethods->xWrite(w->real, w->run + done, n, w->run_at + done);
  }
  w->run_len = 0;
  w->commit_header = 0;
  return rc;
}

static int wal_write(sqlite3_file *f, const void *z, int amt, sqlite3_int64 off) {
  wal_file *w = (wal_file *)f;
  int follows = off == w->next || off == 0;
  w->next = off + amt;
  if (!follows || w->run_len + amt > RUN_CAP) {
    int rc = run_out(w);
    if (rc != SQLITE_OK) return rc;
    if (!follows) return w->real->pMethods->xWrite(w->real, z, amt, off);
  }
  if (w->run_len && w->run_at + w->run_len != off) { /* restarted at the top: a new run */
    int rc = run_out(w);
    if (rc != SQLITE_OK) return rc;
  }
  if (w->run_len + amt > w->run_cap) {
    int cap = w->run_cap ? w->run_cap : 1 << 17;
    while (cap < w->run_len + amt) cap *= 2;
    u8 *n = sqlite3_realloc(w->run, cap);
    if (!n) { int rc = run_out(w); return rc != SQLITE_OK ? rc : w->real->pMethods->xWrite(w->real, z, amt, off); }
    w->run = n;
    w->run_cap = cap;
  }
  if (!w->run_len) w->run_at = off;
  memcpy(w->run + w->run_len, z, (size_t)amt);
  w->run_len += amt;
  if (amt == WAL_FRAME_HDRSIZE && off >= WAL_HDRSIZE) {
    w->commit_header = sqlite3Get4byte((const u8 *)z + 4) != 0; /* nonzero: database size after a commit */
    return SQLITE_OK;
  }
  if (w->commit_header) return run_out(w); /* the commit frame's page: the transaction is complete */
  return SQLITE_OK;
}

static int wal_close(sqlite3_file *f) {
  wal_file *w = (wal_file *)f;
  int rc = run_out(w), rc2 = w->real->pMethods->xClose(w->real);
  sqlite3_free(w->run);
  w->run = 0;
  return rc != SQLITE_OK ? rc : rc2;
}
static int wal_read(sqlite3_file *f, void *z, int amt, sqlite3_int64 off) {
  wal_file *w = (wal_file *)f;
  int rc = run_out(w);
  return rc != SQLITE_OK ? rc : w->real->pMethods->xRead(w->real, z, amt, off);
}
static int wal_truncate(sqlite3_file *f, sqlite3_int64 size) {
  wal_file *w = (wal_file *)f;
  int rc = run_out(w);
  return rc != SQLITE_OK ? rc : w->real->pMethods->xTruncate(w->real, size);
}
static int wal_sync(sqlite3_file *f, int flags) {
  wal_file *w = (wal_file *)f;
  int rc = run_out(w);
  return rc != SQLITE_OK ? rc : w->real->pMethods->xSync(w->real, flags);
}
static int wal_filesize(sqlite3_file *f, sqlite3_int64 *size) {
  wal_file *w = (wal_file *)f;
  int rc = run_out(w);
  return rc != SQLITE_OK ? rc : w->real->pMethods->xFileSize(w->real, size);
}
static int wal_lock(sqlite3_file *f, int l) { return ((wal_file *)f)->real->pMethods->xLock(((wal_file *)f)->real, l); }
static int wal_unlock(sqlite3_file *f, int l) { return ((wal_file *)f)->real->pMethods->xUnlock(((wal_file *)f)->real, l); }
static int wal_reserved(sqlite3_file *f, int *out) {
  return ((wal_file *)f)->real->pMethods->xCheckReservedLock(((wal_file *)f)->real, out);
}
static int wal_control(sqlite3_file *f, int op, void *arg) {
  wal_file *w = (wal_file *)f;
  int rc = run_out(w);
  return rc != SQLITE_OK ? rc : w->real->pMethods->xFileControl(w->real, op, arg);
}
static int wal_sector(sqlite3_file *f) { return ((wal_file *)f)->real->pMethods->xSectorSize(((wal_file *)f)->real); }
static int wal_traits(sqlite3_file *f) {
  return ((wal_file *)f)->real->pMethods->xDeviceCharacteristics(((wal_file *)f)->real);
}

static int goose_open(sqlite3_vfs *v, sqlite3_filename name, sqlite3_file *f, int flags, int *out) {
  (void)v;
  if (!(flags & SQLITE_OPEN_WAL)) return base_vfs->xOpen(base_vfs, name, f, flags, out); /* in place */
  wal_file *w = (wal_file *)f;
  memset(w, 0, sizeof *w);
  w->real = (sqlite3_file *)(w + 1);
  int rc = base_vfs->xOpen(base_vfs, name, w->real, flags, out);
  if (rc != SQLITE_OK) { w->io.pMethods = 0; return rc; }
  w->io.pMethods = &wal_io;
  return SQLITE_OK;
}

/* Registers "goose" over unix-excl (once). */
static int goose_vfs_init(void) {
  if (base_vfs) return SQLITE_OK;
  base_vfs = sqlite3_vfs_find("unix-excl");
  if (!base_vfs) return SQLITE_ERROR;
  goose_vfs = *base_vfs;
  goose_vfs.zName = "goose";
  goose_vfs.pNext = 0;
  goose_vfs.szOsFile = (int)sizeof(wal_file) + base_vfs->szOsFile;
  goose_vfs.xOpen = goose_open;
  memset(&wal_io, 0, sizeof wal_io);
  wal_io.iVersion = 1; /* a WAL file needs no shared memory and no mmap */
  wal_io.xClose = wal_close;
  wal_io.xRead = wal_read;
  wal_io.xWrite = wal_write;
  wal_io.xTruncate = wal_truncate;
  wal_io.xSync = wal_sync;
  wal_io.xFileSize = wal_filesize;
  wal_io.xLock = wal_lock;
  wal_io.xUnlock = wal_unlock;
  wal_io.xCheckReservedLock = wal_reserved;
  wal_io.xFileControl = wal_control;
  wal_io.xSectorSize = wal_sector;
  wal_io.xDeviceCharacteristics = wal_traits;
  return sqlite3_vfs_register(&goose_vfs, 0);
}

/* ---- open ---- */

/* 0, or -1 with the reason appended to err. */
int32_t db_open(bytes_t path_b, gs_rref err) {
  char path[4096], got[256];
  if (path_b.len <= 0 || path_b.len >= (int64_t)sizeof path) { say(err, "SQLITE_PATH"); return -1; }
  memcpy(path, path_b.data, (size_t)path_b.len);
  path[path_b.len] = 0;
  /* unix-excl: one process holds the file for its whole life, so the WAL index can live in
   * heap memory (no -shm file, no file locks per transaction), shared by the two connections. */
  int flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX;
  const char *vfs = getenv("GOOSE_PLAIN_VFS") ? "unix-excl" : "goose"; /* test knob: A/B the write gathering */
  if (sqlite3_initialize() || goose_vfs_init() || sqlite3_open_v2(path, &conn, flags, vfs)) { say(err, "open"); return -1; }
  /* WAL with synchronous=NORMAL (rule 6). No mmap: a page in SQLite's own cache is found with
   * its parsed header and no WAL-index lookup. Checkpoints only when app.goose asks. */
  if (sqlite3_exec(conn,
                   "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA cache_size=-32768;"
                   "PRAGMA mmap_size=0; PRAGMA temp_store=MEMORY; PRAGMA wal_autocheckpoint=0;"
                   "SELECT count(*) FROM sqlite_schema;", 0, 0, 0)) {
    say(err, "pragmas");
    return -1;
  }
  sqlite3_wal_hook(conn, on_wal, 0);
  /* app.goose decodes these records by position: refuse a schema laid out any other way. */
  static const char *want[][2] = {
    {"SELECT group_concat(name, ' ') FROM pragma_table_info('posts')", "id user_id body created_at"},
    {"SELECT group_concat(name, ' ') FROM pragma_table_info('users')", "id username created_at"},
    {"SELECT group_concat(name || ':' || desc, ' ') FROM pragma_index_xinfo('posts_created_at_id_idx') WHERE key",
     "created_at:1 id:1"},
    {"SELECT group_concat(name, ' ') FROM pragma_index_info('likes_post_id_idx')", "post_id"},
    {"SELECT pk FROM pragma_table_info('posts') WHERE name = 'id'", "1"},
    {"SELECT type FROM pragma_table_info('posts') WHERE name = 'id'", "INTEGER"},
    {"SELECT type FROM pragma_table_info('users') WHERE name = 'id'", "INTEGER"},
  };
  for (size_t i = 0; i < sizeof want / sizeof want[0]; i++) {
    one_text(want[i][0], got, sizeof got);
    if (strcmp(got, want[i][1]) != 0) {
      char m[512];
      snprintf(m, sizeof m, "unexpected schema (%s gave \"%s\", not \"%s\")", want[i][0], got, want[i][1]);
      gs_bld_append(err, m, (int64_t)strlen(m));
      return -1;
    }
  }
  if (ENC(conn) != SQLITE_UTF8) { say(err, "the database's text encoding is not UTF-8"); return -1; }
  static const char *trees[NTREES] = {"posts", "users", "posts_created_at_id_idx", "likes_post_id_idx"};
  for (int i = 0; i < NTREES; i++) {
    char sql[160];
    snprintf(sql, sizeof sql, "SELECT rootpage FROM sqlite_schema WHERE name = '%s'", trees[i]);
    one_text(sql, got, sizeof got);
    root[i] = (Pgno)atol(got);
    if (!root[i]) { say(err, "root page"); return -1; }
  }
  keys[T_FEED] = index_keys(2, true);
  keys[T_LIKES] = index_keys(1, false);
  q_begin = prepare("BEGIN");
  q_commit = prepare("COMMIT");
  q_rollback = prepare("ROLLBACK");
  q_post = prepare("INSERT INTO posts (user_id, body) VALUES (?1, ?2) RETURNING id, created_at");
  q_like = prepare("INSERT INTO likes (user_id, post_id) VALUES (?1, ?2) ON CONFLICT (user_id, post_id) DO NOTHING");
  q_ping = prepare("SELECT 1");
  /* The reference query: the feed's answer when its rows are not laid out as the plan expects. */
  q_feed = prepare("SELECT p.id, p.body, p.created_at, u.username, "
                   "(SELECT count(*) FROM likes l WHERE l.post_id = p.id) "
                   "FROM posts p JOIN users u ON u.id = p.user_id ORDER BY p.created_at DESC, p.id DESC LIMIT 20");
  if (!keys[T_FEED] || !keys[T_LIKES] || !q_begin || !q_commit || !q_rollback || !q_post || !q_like ||
      !q_ping || !q_feed) {
    say(err, "prepare");
    return -1;
  }
  btree = conn->aDb[0].pBt;
  for (int i = 0; i < NTREES; i++)
    if (!(curs[i] = sqlite3_malloc(sqlite3BtreeCursorSize()))) { say(err, "cursor"); return -1; }
  /* The checkpointer's connection reads no tables: a checkpoint copies straight from the log. */
  if (sqlite3_open_v2(path, &ck_conn, flags, vfs) ||
      sqlite3_exec(ck_conn, "PRAGMA synchronous=NORMAL; PRAGMA wal_autocheckpoint=0; PRAGMA cache_size=16;", 0, 0, 0)) {
    say(err, "checkpoint connection");
    return -1;
  }
  pthread_t t;
  pthread_attr_t a;
  pthread_attr_init(&a);
  pthread_attr_setstacksize(&a, 256 << 10);
  if (pthread_create(&t, &a, ck_thread, 0)) { say(err, "checkpoint thread"); return -1; }
  return 0;
}

/* ---- the pass's transaction ---- */

static int run(sqlite3_stmt *s) {
  int rc = sqlite3_step(s);
  sqlite3_reset(s);
  return rc;
}

static void close_cursors(void) {
  for (int i = 0; i < NTREES; i++) sqlite3BtreeCloseCursor(curs[i]);
}

/* Joins the pass's transaction, opening it (and the four cursors) on first use: 0, or -1 if the
 * pass's transaction is lost (SQLite rolled it back on its own, e.g. on an I/O error). */
int32_t db_begin(void) {
  if (tx_lost) return -1;
  if (tx_open) {
    if (!sqlite3_get_autocommit(conn)) return 0;
    tx_lost = true; /* SQLite ended the transaction itself: nothing more in this pass */
    return -1;
  }
  if (run(q_begin) != SQLITE_DONE) return -1;
  if (sqlite3BtreeBeginTrans(btree, 0, 0) != SQLITE_OK) { run(q_rollback); return -1; }
  for (int i = 0; i < NTREES; i++) {
    sqlite3BtreeCursorZero(curs[i]);
    if (sqlite3BtreeCursor(btree, root[i], 0, keys[i], curs[i]) != SQLITE_OK) {
      while (--i >= 0) sqlite3BtreeCloseCursor(curs[i]);
      run(q_rollback);
      return -1;
    }
  }
  tx_open = true;
  return 0;
}

/* Ends the pass's transaction: true if it committed (or there was none). */
bool db_commit(void) {
  bool ok = true;
  if (tx_open) {
    close_cursors();
    tx_open = false;
    if (tx_lost || run(q_commit) != SQLITE_DONE) ok = false;
    if (!ok) fprintf(stderr, "commit failed: %s (%d)\n", sqlite3_errmsg(conn), sqlite3_extended_errcode(conn));
    if (!ok && !sqlite3_get_autocommit(conn)) run(q_rollback);
  } else if (tx_lost) {
    ok = false;
  }
  tx_lost = false;
  return ok;
}

/* After a write that failed: if SQLite ended the transaction itself, the pass is lost. */
static void after_failed_write(void) {
  if (tx_open && sqlite3_get_autocommit(conn)) tx_lost = true;
}

/* ---- cursors ---- */

/* A table cursor to rowid `key`: 1 found, 0 absent, -1 error. */
int32_t db_seek(int32_t t, int64_t key) {
  int where = 0;
  if (sqlite3BtreeTableMoveto(curs[t], key, 0, &where) != SQLITE_OK) return -1;
  return where == 0 && curs[t]->eState == CURSOR_VALID ? 1 : 0;
}

/* An index cursor to its first entry whose leading (integer) column is >= key: 1 there, 0 if
 * there is none, -1 error. */
int32_t db_seek_ge(int32_t t, int64_t key) {
  BtCursor *c = curs[t];
  Mem v;
  UnpackedRecord probe;
  int where = 0;
  memset(&v, 0, sizeof v);
  v.flags = MEM_Int;
  v.u.i = key;
  memset(&probe, 0, sizeof probe);
  probe.pKeyInfo = c->pKeyInfo;
  probe.aMem = &v;
  probe.nField = 1;
  probe.default_rc = 1; /* an entry equal on the leading column sorts after the probe */
  if (sqlite3BtreeIndexMoveto(c, &probe, &where) != SQLITE_OK) return -1;
  if (sqlite3BtreeEof(c)) return 0;
  if (where < 0) { /* on the entry before: step onto the first one >= key */
    int rc = sqlite3BtreeNext(c, 0);
    return rc == SQLITE_OK ? 1 : rc == SQLITE_DONE ? 0 : -1;
  }
  return 1;
}

int32_t db_first(int32_t t) {
  int empty = 1;
  if (sqlite3BtreeFirst(curs[t], &empty) != SQLITE_OK) return -1;
  return empty ? 0 : 1;
}

int32_t db_next(int32_t t) {
  int rc = sqlite3BtreeNext(curs[t], 0);
  return rc == SQLITE_OK ? 1 : rc == SQLITE_DONE ? 0 : -1;
}

/* Appends the cursor's record to `out`: its length, or -1. */
int64_t db_row(int32_t t, gs_rref out) {
  BtCursor *c = curs[t];
  u32 n = sqlite3BtreePayloadSize(c), local = 0;
  const void *p = sqlite3BtreePayloadFetch(c, &local);
  if (local == n) {
    gs_bld_append(out, p, n);
  } else { /* the record spills onto overflow pages: read it through the pager */
    if (sqlite3BtreePayload(c, 0, n, out.stk->top) != SQLITE_OK) return -1;
    out.stk->top += n;
    out.hdr->len += n;
  }
  return n;
}

/* The integer a record's first column holds, read from the start of a cell's payload (header
 * size, first serial type, then the value). 0 if the cell is not in that simple form. */
static inline int first_int(const u8 *rec, const u8 *end, i64 *v) {
  if (rec + 2 > end || rec[0] >= 0x80 || rec[1] >= 0x80) return 0;
  const u8 *val = rec + rec[0];
  switch (rec[1]) {
  case 8: *v = 0; return 1;
  case 9: *v = 1; return 1;
  case 1: if (val + 1 > end) return 0; *v = (i8)val[0]; return 1;
  case 2: if (val + 2 > end) return 0; *v = (i16)(val[0] << 8 | val[1]); return 1;
  case 3: if (val + 3 > end) return 0; *v = ((int32_t)((u32)val[0] << 24 | (u32)val[1] << 16 | (u32)val[2] << 8)) >> 8; return 1;
  case 4: if (val + 4 > end) return 0; *v = (int32_t)((u32)val[0] << 24 | (u32)val[1] << 16 | (u32)val[2] << 8 | val[3]); return 1;
  default: return 0; /* 6- and 8-byte integers, and anything else: the caller's slow path */
  }
}

/* Counts the entries of the likes index for each post id in [lo, hi] (counts[id - lo], zeroed
 * by the caller) by reading the index's leaf cells in place. 0 ok, -1 error, 1 an entry this
 * does not read (app.goose then counts through the cursor instead). */
int32_t db_like_counts(int64_t lo, int64_t hi, counts_t counts) {
  BtCursor *c = curs[T_LIKES];
  if (hi < lo || hi - lo >= counts.len) return 1;
  int at = db_seek_ge(T_LIKES, lo);
  if (at <= 0) return at;
  for (;;) {
    MemPage *pg = c->pPage;
    if (!pg->leaf) return 1; /* an entry that lives in an interior cell: let the cursor walk it */
    int i = c->ix;
    for (; i < pg->nCell; i++) {
      u8 *cell = pg->aData + (get2byte(&pg->aCellIdx[2 * i]) & pg->maskPage);
      u32 size;
      const u8 *rec = cell + getVarint32(cell, size);
      i64 id;
      if (!first_int(rec, pg->aDataEnd, &id)) return 1;
      if (id > hi) return 0;
      counts.data[id - lo]++;
    }
    c->ix = (u16)(pg->nCell - 1); /* the last cell: the next step leaves this leaf */
    int rc = sqlite3BtreeNext(c, 0);
    if (rc == SQLITE_DONE) return 0;
    if (rc != SQLITE_OK) return -1;
  }
}

/* ---- writes and /health ---- */

/* INSERT ... RETURNING id, created_at: 0 (id set, created_at appended), -1 error. */
int32_t db_add_post(int64_t user_id, bytes_t body, int64_t *id, gs_rref created) {
  sqlite3_bind_int64(q_post, 1, user_id);
  sqlite3_bind_text(q_post, 2, (const char *)body.data, (int)body.len, SQLITE_STATIC);
  int ok = sqlite3_step(q_post) == SQLITE_ROW;
  if (ok) {
    *id = sqlite3_column_int64(q_post, 0);
    const unsigned char *t = sqlite3_column_text(q_post, 1);
    int n = sqlite3_column_bytes(q_post, 1);
    ok = t && n > 0 && n < 64;
    if (ok) gs_bld_append(created, t, n);
    ok = ok && sqlite3_step(q_post) == SQLITE_DONE;
  }
  sqlite3_reset(q_post);
  sqlite3_clear_bindings(q_post);
  if (!ok) {
    fprintf(stderr, "insert failed: %s (%d)\n", sqlite3_errmsg(conn), sqlite3_extended_errcode(conn));
    after_failed_write();
  }
  return ok ? 0 : -1;
}

/* 1 a new like, 0 already liked, -1 error. */
int32_t db_add_like(int64_t user_id, int64_t post_id) {
  sqlite3_bind_int64(q_like, 1, user_id);
  sqlite3_bind_int64(q_like, 2, post_id);
  if (run(q_like) != SQLITE_DONE) { after_failed_write(); return -1; }
  return sqlite3_changes(conn) > 0 ? 1 : 0;
}

/* SELECT 1: 0 ok, -1 with SQLite's message appended to err. */
int32_t db_ping(gs_rref err) {
  int ok = sqlite3_step(q_ping) == SQLITE_ROW && sqlite3_column_int(q_ping, 0) == 1;
  sqlite3_reset(q_ping);
  if (ok) return 0;
  const char *m = sqlite3_errmsg(conn);
  gs_bld_append(err, m, (int64_t)strlen(m));
  return -1;
}

/* One row of the reference feed query: 1 (body, created_at, author appended to text), 0 done,
 * -1 error. */
#pragma pack(push, 1)
typedef struct { int64_t id, likes, body_len, created_len, author_len; } feed_row_t;
#pragma pack(pop)
int32_t db_feed_step(feed_row_t *row, gs_rref text) {
  int rc = sqlite3_step(q_feed);
  if (rc != SQLITE_ROW) {
    sqlite3_reset(q_feed);
    return rc == SQLITE_DONE ? 0 : -1;
  }
  row->id = sqlite3_column_int64(q_feed, 0);
  row->likes = sqlite3_column_int64(q_feed, 4);
  int64_t *lens[3] = {&row->body_len, &row->created_len, &row->author_len};
  for (int k = 0; k < 3; k++) {
    const unsigned char *s = sqlite3_column_text(q_feed, k + 1);
    *lens[k] = sqlite3_column_bytes(q_feed, k + 1);
    gs_bld_append(text, s, *lens[k]);
  }
  return 1;
}

/* ---- the process ---- */

bool env_get(bytes_t name_b, gs_rref out) {
  char name[128];
  if (name_b.len <= 0 || name_b.len >= (int64_t)sizeof name) return false;
  memcpy(name, name_b.data, (size_t)name_b.len);
  name[name_b.len] = 0;
  const char *v = getenv(name);
  if (v) gs_bld_append(out, v, (int64_t)strlen(v));
  return v != NULL;
}

/* Gives the CPU away for `us` microseconds (see app.goose's checkpoints: the loop lets a lagging
 * checkpointer run). */
void pause_us(int64_t us) {
  struct timespec t = {.tv_sec = us / 1000000, .tv_nsec = (us % 1000000) * 1000};
  nanosleep(&t, NULL);
}

double clock_unix(void) {
  struct timespec t;
  clock_gettime(CLOCK_REALTIME, &t);
  return (double)t.tv_sec + (double)t.tv_nsec / 1e9;
}

int64_t clock_us(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (int64_t)t.tv_sec * 1000000 + t.tv_nsec / 1000;
}

void log_line(bytes_t s) {
  fwrite(s.data, 1, (size_t)s.len, stderr);
  fputc('\n', stderr);
}
