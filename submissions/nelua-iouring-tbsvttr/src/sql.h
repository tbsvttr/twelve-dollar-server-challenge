/* sql.h: SQLite compiled into this translation unit (the amalgamation, unmodified), thin wrappers over its B-tree
 * layer for the read plans in db.nelua, and the checkpoint thread. Every page the plans read comes through
 * SQLite's pager, WAL and page cache inside the batch's transaction; only the bytecode engine is skipped. */
#ifndef TD_SQL_H
#define TD_SQL_H
#include "sqlite3.c"
#include <pthread.h>
#include <stdatomic.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/syscall.h>
#include <time.h>

static inline uint64_t td_now_ns(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

/* ---- the C API where it takes a pointer to a pointer ---- */

static sqlite3 *td_open(const char *path, const char *vfs, int *rc) {
  sqlite3 *db = NULL;
  *rc = sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_EXRESCODE, vfs);
  return db;
}
static sqlite3_stmt *td_prepare(sqlite3 *db, const char *sql) {
  sqlite3_stmt *st = NULL;
  if (sqlite3_prepare_v3(db, sql, -1, SQLITE_PREPARE_PERSISTENT, &st, NULL) != SQLITE_OK) {
    fprintf(stderr, "sqlite prepare: %s: %s\n", sql, sqlite3_errmsg(db));
    return NULL;
  }
  return st;
}
static int td_exec(sqlite3 *db, const char *sql) {
  char *err = NULL;
  int rc = sqlite3_exec(db, sql, NULL, NULL, &err);
  if (rc != SQLITE_OK) fprintf(stderr, "sqlite: %s: %s\n", sql, err ? err : sqlite3_errstr(rc));
  sqlite3_free(err);
  return rc;
}
/* The binary's code and constant data stay in RAM: with no swap, reclaim near the memory wall takes file-backed
 * pages first, and the loop would stall reading its own code back. */
extern char __executable_start, etext;
static int td_lock_code(void) {
  uintptr_t a = (uintptr_t)&__executable_start & ~(uintptr_t)4095, b = (uintptr_t)&etext;
  return mlock((void *)a, b - a);
}

/* ---- the B-tree layer ---- */

static Btree *td_btree(sqlite3 *db) { return db->aDb[0].pBt; }

/* An index's key description: nkey key columns (descending if desc) plus nextra trailing ones (the rowid). */
static KeyInfo *td_keyinfo(sqlite3 *db, int nkey, int nextra, int desc) {
  KeyInfo *k = sqlite3KeyInfoAlloc(db, nkey, nextra);
  if (!k) return NULL;
  for (int i = 0; i < nkey + nextra; i++) {
    k->aColl[i] = db->pDfltColl;
    if (desc && i < nkey) k->aSortFlags[i] = KEYINFO_ORDER_DESC;
  }
  return k;
}
static BtCursor *td_cursor_alloc(void) {
  BtCursor *c = malloc((size_t)sqlite3BtreeCursorSize());
  if (c) sqlite3BtreeCursorZero(c);
  return c;
}
/* A read transaction on the B-tree, inside the batch's BEGIN: the SQL statements of the same batch join it. */
static int td_read_begin(Btree *bt) { return sqlite3BtreeBeginTrans(bt, 0, 0); }
static int td_cursor_open(Btree *bt, int root, KeyInfo *ki, BtCursor *c) {
  sqlite3BtreeCursorZero(c);
  return sqlite3BtreeCursor(bt, (Pgno)root, 0, ki, c);
}
static void td_cursor_close(BtCursor *c) { sqlite3BtreeCloseCursor(c); }

/* Steps: 0 on a row, 1 past the end (or not found), -1 on an error. */
static int td_first(BtCursor *c) {
  int empty;
  return sqlite3BtreeFirst(c, &empty) != SQLITE_OK ? -1 : empty ? 1 : 0;
}
static int td_next(BtCursor *c) {
  int rc = sqlite3BtreeNext(c, 0);
  return rc == SQLITE_OK ? 0 : rc == SQLITE_DONE ? 1 : -1;
}
static int td_seek(BtCursor *c, int64_t rowid) {
  int res;
  if (sqlite3BtreeTableMoveto(c, rowid, 0, &res) != SQLITE_OK) return -1;
  return res == 0 ? 0 : 1;
}
/* The first row whose rowid is >= rowid, as the bytecode engine's OP_SeekGE does it. */
static int td_seek_ge(BtCursor *c, int64_t rowid) {
  int res;
  if (sqlite3BtreeTableMoveto(c, rowid, 0, &res) != SQLITE_OK) return -1;
  if (sqlite3BtreeEof(c)) return 1;
  return res < 0 ? td_next(c) : 0;
}
/* The first index entry whose leading integer column is >= k. */
static int td_index_ge(BtCursor *c, KeyInfo *ki, int64_t k) {
  Mem m;
  memset(&m, 0, sizeof m);
  m.flags = MEM_Int;
  m.u.i = k;
  UnpackedRecord r;
  memset(&r, 0, sizeof r);
  r.pKeyInfo = ki;
  r.aMem = &m;
  r.nField = 1;
  r.default_rc = +1;
  int res;
  if (sqlite3BtreeIndexMoveto(c, &r, &res) != SQLITE_OK) return -1;
  if (res < 0) return td_next(c);
  return sqlite3BtreeEof(c) ? 1 : 0;
}
static int64_t td_rowid(BtCursor *c) { return sqlite3BtreeIntegerKey(c); }
/* The record under the cursor: a pointer into its page, or into *spill (grown as needed) when it continues on
 * overflow pages. NULL on an error. */
static const uint8_t *td_record(BtCursor *c, uint32_t *n, uint8_t **spill, uint32_t *cap) {
  uint32_t total = sqlite3BtreePayloadSize(c), local;
  const uint8_t *p = sqlite3BtreePayloadFetch(c, &local);
  *n = total;
  if (local == total) return p;
  if (total > *cap) {
    free(*spill);
    *cap = total + 4096;
    *spill = malloc(*cap);
    if (!*spill) { *cap = 0; return NULL; }
  }
  if (sqlite3BtreePayload(c, 0, total, *spill) != SQLITE_OK) return NULL;
  return *spill;
}

/* ---- the checkpoint thread ----
 * WAL with wal_autocheckpoint off. A WAL hook counts the log's frames; past WAKE frames the thread runs PASSIVE
 * checkpoints on its own connection at nice 19 (on one vCPU the loop is scheduled ahead of it). SQLite only
 * restarts the log when a write begins with every frame copied back, and group commit leaves no such moment, so
 * past GATE frames writes are held (reads go on) until the thread reports the log copied, or for at most a
 * second. Past INLINE frames the loop checkpoints itself, as a last resort. */
#define TD_WAKE_FRAMES 1000
#define TD_GATE_FRAMES 4000
#define TD_INLINE_FRAMES 16384
#define TD_GATE_MAX_NS 1000000000ull

typedef struct td_ckpt {
  sqlite3 *c2;
  pthread_t thr;
  pthread_mutex_t mu;
  pthread_cond_t cv;
  int wanted;
  _Atomic int frames;
  _Atomic uint64_t commit_seq, copied_seq;
  int gate;
  uint64_t gate_since;
  uint64_t n_ckpt, n_gate, n_inline;
} td_ckpt;
static td_ckpt td_ck;

static int td_wal_hook(void *ud, sqlite3 *c, const char *name, int frames) {
  (void)ud; (void)c; (void)name;
  atomic_store_explicit(&td_ck.frames, frames, memory_order_relaxed);
  atomic_fetch_add_explicit(&td_ck.commit_seq, 1, memory_order_release);
  if (frames >= TD_WAKE_FRAMES) {
    if (frames >= TD_GATE_FRAMES && !td_ck.gate) {
      td_ck.gate = 1;
      td_ck.gate_since = td_now_ns();
      td_ck.n_gate++;
    }
    pthread_mutex_lock(&td_ck.mu);
    td_ck.wanted = 1;
    pthread_cond_signal(&td_ck.cv);
    pthread_mutex_unlock(&td_ck.mu);
  }
  return SQLITE_OK;
}

static void *td_ckpt_main(void *ud) {
  (void)ud;
  setpriority(PRIO_PROCESS, (id_t)syscall(SYS_gettid), 19);
  for (;;) {
    pthread_mutex_lock(&td_ck.mu);
    while (!td_ck.wanted) {
      struct timespec ts;
      clock_gettime(CLOCK_REALTIME, &ts);
      ts.tv_nsec += 250000000L;
      if (ts.tv_nsec >= 1000000000L) { ts.tv_sec++; ts.tv_nsec -= 1000000000L; }
      pthread_cond_timedwait(&td_ck.cv, &td_ck.mu, &ts);
      if (atomic_load_explicit(&td_ck.frames, memory_order_relaxed) > 0) break;
    }
    td_ck.wanted = 0;
    pthread_mutex_unlock(&td_ck.mu);
    uint64_t seq = atomic_load_explicit(&td_ck.commit_seq, memory_order_acquire);
    int nlog = 0, ncopied = 0;
    int rc = sqlite3_wal_checkpoint_v2(td_ck.c2, "main", SQLITE_CHECKPOINT_PASSIVE, &nlog, &ncopied);
    td_ck.n_ckpt++;
    if ((rc == SQLITE_OK || rc == SQLITE_BUSY) && nlog == ncopied)
      atomic_store_explicit(&td_ck.copied_seq, seq, memory_order_release);
    else if (td_ck.gate) { /* keep going until the log is copied */
      pthread_mutex_lock(&td_ck.mu);
      td_ck.wanted = 1;
      pthread_mutex_unlock(&td_ck.mu);
    }
  }
  return NULL;
}

/* c2: the thread's own connection to the same file. 0 or -1. */
static int td_ckpt_start(sqlite3 *main, sqlite3 *c2) {
  td_ck.c2 = c2;
  pthread_mutex_init(&td_ck.mu, NULL);
  pthread_cond_init(&td_ck.cv, NULL);
  /* a connection that never ran a statement hasn't opened the WAL, and its checkpoints do nothing */
  sqlite3_exec(c2, "SELECT count(*) FROM (SELECT 1 FROM users LIMIT 1)", NULL, NULL, NULL);
  sqlite3_wal_hook(main, td_wal_hook, NULL);
  return pthread_create(&td_ck.thr, NULL, td_ckpt_main, NULL) == 0 ? 0 : -1;
}

/* Between batches: may this batch write? Opens the gate once the log is copied (or after a second), and runs the
 * inline checkpoint if the thread fell too far behind. */
static int td_writes_allowed(sqlite3 *main) {
  if (td_ck.gate) {
    uint64_t seq = atomic_load_explicit(&td_ck.commit_seq, memory_order_acquire);
    if (atomic_load_explicit(&td_ck.copied_seq, memory_order_acquire) == seq || td_now_ns() - td_ck.gate_since > TD_GATE_MAX_NS)
      td_ck.gate = 0;
  }
  if (atomic_load_explicit(&td_ck.frames, memory_order_relaxed) >= TD_INLINE_FRAMES) {
    int nlog = 0, ncopied = 0;
    sqlite3_wal_checkpoint_v2(main, "main", SQLITE_CHECKPOINT_PASSIVE, &nlog, &ncopied);
    td_ck.n_inline++;
    if (nlog == ncopied) {
      atomic_store_explicit(&td_ck.frames, 0, memory_order_relaxed);
      td_ck.gate = 0;
    }
  }
  return !td_ck.gate;
}
#endif
