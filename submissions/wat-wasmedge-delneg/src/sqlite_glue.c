// The C next to stock SQLite and wasi-libc, other than the embedder. It compiles the pinned, unmodified
// amalgamation into a WASI reactor module (one translation unit, so SQLite's internal B-tree calls are
// reachable). src/app.wat calls SQLite's public API directly (build.sh exports each function it imports).
// This file adds one-line wrappers over SQLite's B-tree cursor layer, a VFS with shared memory, and the
// checkpoint logic: ck_tick on the loop's instance, ckpt_main on the checkpointer's. No request logic lives
// here: which cursors to open, what to seek, how to decode records, when to fall back to SQL and how POSTs
// are parked during a hold are all decided in src/app.wat.
#include "sqlite3.c"

_Static_assert(SQLITE_VERSION_NUMBER == 3054001, "the B-tree wrappers below are checked against SQLite 3.54.1");

// ---- B-tree layer: pager, page cache, WAL and locks stay SQLite's; only the bytecode engine is skipped
Btree *bt_of(sqlite3 *db) { return db->aDb[0].pBt; }
// starts (or joins) the read transaction and writes the schema cookie to *cookie
int bt_read(Btree *bt, u32 *cookie) {
  int rc = sqlite3BtreeBeginTrans(bt, 0, 0);
  if (rc == SQLITE_OK) sqlite3BtreeGetMeta(bt, BTREE_SCHEMA_VERSION, cookie);
  return rc;
}
KeyInfo *key_info(sqlite3 *db, int nKey, int nExtra) { return sqlite3KeyInfoAlloc(db, nKey, nExtra); }
int cur_size(void) { return sqlite3BtreeCursorSize(); }
int cur_open(Btree *bt, int root, KeyInfo *k, BtCursor *c) {
  memset(c, 0, (size_t)sqlite3BtreeCursorSize());
  sqlite3BtreeCursorZero(c);
  return sqlite3BtreeCursor(bt, (Pgno)root, 0, k, c);
}
int cur_close(BtCursor *c) { return sqlite3BtreeCloseCursor(c); }
int cur_first(BtCursor *c, int *res) { return sqlite3BtreeFirst(c, res); }
int cur_next(BtCursor *c) { return sqlite3BtreeNext(c, 0); }
int cur_prev(BtCursor *c) { return sqlite3BtreePrevious(c, 0); }
int cur_eof(BtCursor *c) { return sqlite3BtreeEof(c); }
long long cur_rowid(BtCursor *c) { return sqlite3BtreeIntegerKey(c); }
int cur_seek_rowid(BtCursor *c, long long key, int *res) { return sqlite3BtreeTableMoveto(c, key, 0, res); }
// seeks an index on its first column, an integer; default_rc says where entries equal to the key sort
int cur_seek_int(BtCursor *c, KeyInfo *k, long long key, int default_rc, int *res) {
  Mem m; memset(&m, 0, sizeof m); m.flags = MEM_Int; m.u.i = key;
  UnpackedRecord r; memset(&r, 0, sizeof r);
  r.pKeyInfo = k; r.aMem = &m; r.nField = 1; r.default_rc = (i8)default_rc;
  return sqlite3BtreeIndexMoveto(c, &r, res);
}
unsigned cur_payload_size(BtCursor *c) { return sqlite3BtreePayloadSize(c); }
// the record's bytes on the cursor's page; *amt = how many are there (fewer than the size: overflow)
const u8 *cur_payload(BtCursor *c, u32 *amt) { return sqlite3BtreePayloadFetch(c, amt); }

// ---- Checkpoints off the loop: the wal-index is shared with a second wasm instance, on a host thread, that runs
// the checkpoints, so the event loop doesn't wait for their fsyncs. The host maps one memfd into a page-aligned
// slice of each instance's memory (sys.shm_map); this VFS wraps unix-none and gives the main database file the
// four shm methods SQLite's WASI build lacks. Lock words and the checkpoint handshake are process-wide words in
// the host (sys.shm_cas / sys.shm_add: real atomics); each instance keeps its own held-lock masks.
#define IMP(n) __attribute__((import_module("sys"), import_name(#n)))
IMP(shm_map) int h_shm_map(void *p, int len);
IMP(shm_cas) int h_cas(int i, int old, int nw);
IMP(shm_add) int h_add(int i, int d);
IMP(nap) int h_nap(int us);
IMP(shm_lock) int h_lock(int ofst, int n, int flags, int role);   // SQLite xShmLock semantics, held masks per role
IMP(ck_wait) int h_wait(void);
IMP(ck_wake) int h_wake(void);
IMP(ckpt_spawn) int h_spawn(void);
#define SHMLEN (8 << 20)
enum { W_NREG = 8, W_ST = 9, W_DONE = 10, W_READY = 11, W_FENCE = 15 };   // W_ST: 0 idle, 1 asked, 2 running, 3 done
static char *shm;
static sqlite3_vfs V, *B; static sqlite3_io_methods M;
static int xMap(sqlite3_file *f, int r, int sz, int ext, void volatile **pp) {
  (void)f; if ((r + 1) * sz > SHMLEN) return SQLITE_IOERR_SHMSIZE;
  int n = h_add(W_NREG, 0);
  if (r >= n) { if (!ext) { *pp = 0; return SQLITE_OK; } while (n <= r) { int p = h_cas(W_NREG, n, r + 1); if (p == n) break; n = p; } }
  *pp = shm + r * sz; return SQLITE_OK;
}
static int role;   // 0: the loop's instance, 1: the checkpointer's
static int xLk(sqlite3_file *f, int ofst, int n, int fl) { (void)f; return h_lock(ofst, n, fl, role); }
// an opaque indirect call is a compiler barrier, and x86 keeps load-load and store-store order
static void xBar(sqlite3_file *f) { (void)f; }
static int xUnmap(sqlite3_file *f, int del) { (void)f; (void)del; return SQLITE_OK; }
static int xOpen(sqlite3_vfs *v, sqlite3_filename z, sqlite3_file *f, int fl, int *o) {
  (void)v; int rc = B->xOpen(B, z, f, fl, o);
  if (rc == SQLITE_OK && (fl & SQLITE_OPEN_MAIN_DB) && f->pMethods) {
    if (!M.xClose) { M = *f->pMethods; M.iVersion = 2; M.xShmMap = xMap; M.xShmLock = xLk; M.xShmBarrier = xBar; M.xShmUnmap = xUnmap; }
    f->pMethods = &M;
  }
  return rc;
}
static int shmx_setup(void) {
  char *p = malloc(SHMLEN + 65536); if (!p) return 1;
  shm = (char *)(((uintptr_t)p + 65535) & ~(uintptr_t)65535);
  if (h_shm_map(shm, SHMLEN)) return 1;
  B = sqlite3_vfs_find("unix-none"); if (!B) return 1;
  V = *B; V.zName = "shmx"; V.xOpen = xOpen; V.pNext = 0;
  return sqlite3_vfs_register(&V, 0) != SQLITE_OK;
}
// the loop's instance: -> "shmx" (open the database with it, locking_mode NORMAL) or 0 (SHMX=0, or setup failed)
const char *shmx_init(void) {
  const char *e = getenv("SHMX"); if (e && *e == '0') return 0;
  if (shmx_setup() || h_spawn()) return 0;
  return "shmx";
}
// the loop, between batches with no transaction open; n = the WAL's frames after the last commit -> what to keep.
// Bulk passes on the checkpointer until few frames are left (CKPT_TAIL); then writes are held (the loop parks POSTs, see
// $on_data in app.wat; reads go on) while the checkpointer copies the rest. With nothing written since, the WAL
// is then fully copied, and the first write restarts it. The only sync left on the loop then is SQLite's sync of the
// WAL's new header at that restart. A hold ends after
// holdms at the latest (writes go on, the next round tries again), 4x that past 3x the threshold, when the passes
// aren't catching up. One inline checkpoint only past 8x the threshold, as the last resort, or with CKPT_HOLD=0.
static int tailmax, holdms, hold, ckpt_log; static long long hold_t0, ev_t0;
static long long now_ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1000LL + t.tv_nsec / 1000000; }
#define EV(what, n, d) do { if (ckpt_log) { long long t_ = now_ms(); fprintf(stderr, "ck %s n=%d done=%d dt=%d\n", what, n, d, (int)(t_ - ev_t0)); ev_t0 = t_; } } while (0)
int ck_hold(void) { return hold; }
static int ck_inline(sqlite3 *db, int n, int *busy) {
  int nl = 0, nd = 0, rc = sqlite3_wal_checkpoint_v2(db, 0, SQLITE_CHECKPOINT_PASSIVE, &nl, &nd);
  EV("inline", nl, nd);
  h_cas(W_ST, 3, 0); *busy = 0;
  return rc == SQLITE_OK && nl == nd ? 0 : n;
}
int ck_tick(sqlite3 *db, int n, int t) {
  static int ready, busy;
  if (!ready) {
    h_cas(W_READY, 0, 1); ready = 1;
    const char *e = getenv("CKPT_TAIL"); tailmax = e ? atoi(e) : 200;
    e = getenv("CKPT_HOLD"); holdms = e ? atoi(e) : 500;
    e = getenv("CKPT_LOG"); ckpt_log = e && *e == '1';
  }
  if (!busy) { if (n < t) return n; busy = 1; EV("start", n, 0); h_cas(W_ST, 0, 1); h_wake(); return n; }
  if (h_add(W_ST, 0) != 3) {
    if (hold && now_ms() - hold_t0 > (n >= 3 * t ? 4 * holdms : holdms)) { hold = 0; EV("timeout", n, 0); }
    return n;
  }
  int done = h_add(W_DONE, 0);
  if (hold) { hold = 0; EV("tail", n, done); h_cas(W_ST, 3, 0); busy = 0; return n == done ? 0 : n; }
  EV("bulk", n, done);
  if (n >= 8 * t || !holdms) return ck_inline(db, n, &busy);
  if (n - done > tailmax && n < 3 * t) { h_cas(W_ST, 3, 1); h_wake(); return n; }   // another bulk pass
  hold = 1; hold_t0 = now_ms(); h_cas(W_ST, 3, 1); h_wake();
  return n;
}
// the checkpointer's instance (run by the host on its thread): its own connection, PASSIVE checkpoints on request
void ckpt_main(void) {
  role = 1; if (shmx_setup()) return;
  while (!h_add(W_READY, 0)) h_nap(1000);
  sqlite3 *c; if (sqlite3_open_v2(getenv("SQLITE_PATH"), &c, SQLITE_OPEN_READWRITE, "shmx")) return;
  int one = 1; sqlite3_file_control(c, "main", SQLITE_FCNTL_PERSIST_WAL, &one);
  sqlite3_exec(c, "PRAGMA cache_size=16; PRAGMA synchronous=NORMAL;", 0, 0, 0);
  for (;;) {
    h_wait();
    h_cas(W_ST, 1, 2);
    int nl = 0, nd = 0; sqlite3_wal_checkpoint_v2(c, 0, SQLITE_CHECKPOINT_PASSIVE, &nl, &nd);
    for (int v = h_add(W_DONE, 0); h_cas(W_DONE, v, nd) != v; v = h_add(W_DONE, 0)) {}
    h_cas(W_ST, 2, 3);
  }
}
