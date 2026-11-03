"""cffi binding (API mode) to the pinned, unmodified SQLite amalgamation, including SQLite's B-tree layer.
The only C compiled here is SQLite itself plus the wrappers cffi generates; the C compiler fills in struct layouts."""
import os
import cffi

HERE = os.path.dirname(os.path.abspath(__file__))
VENDOR = os.path.join(HERE, "vendor", os.environ.get("SQLITE_DIR", "sqlite-amalgamation-3540100"))
ffi = cffi.FFI()
ffi.cdef("""
typedef long long i64; typedef unsigned int u32; typedef unsigned char u8;
typedef struct sqlite3 sqlite3; typedef struct sqlite3_stmt sqlite3_stmt;
typedef struct Btree Btree; typedef struct BtCursor BtCursor; typedef struct CollSeq CollSeq;
typedef struct KeyInfo { u8 *aSortFlags; CollSeq *aColl[]; ...; } KeyInfo;
typedef struct Mem { ...; } Mem;
typedef struct UnpackedRecord { KeyInfo *pKeyInfo; Mem *aMem; signed char default_rc; unsigned short nField; ...; } UnpackedRecord;
#define SQLITE_OPEN_READWRITE ...
#define SQLITE_OPEN_NOMUTEX ...
#define MEM_Int ...

int sqlite3_initialize(void);
int sqlite3_open_v2(const char *, sqlite3 **, int, const char *);
int sqlite3_exec(sqlite3 *, const char *, void *, void *, char **);
int sqlite3_prepare_v2(sqlite3 *, const char *, int, sqlite3_stmt **, const char **);
int sqlite3_step(sqlite3_stmt *); int sqlite3_reset(sqlite3_stmt *); int sqlite3_finalize(sqlite3_stmt *);
int sqlite3_bind_int64(sqlite3_stmt *, int, i64);
int sqlite3_bind_text(sqlite3_stmt *, int, const char *, int, void *);
i64 sqlite3_column_int64(sqlite3_stmt *, int);
const void *sqlite3_column_blob(sqlite3_stmt *, int);
const unsigned char *sqlite3_column_text(sqlite3_stmt *, int);
int sqlite3_column_bytes(sqlite3_stmt *, int);
int sqlite3_changes(sqlite3 *);
const char *sqlite3_errmsg(sqlite3 *);

Btree *sqlite3DbNameToBtree(sqlite3 *, const char *);
int sqlite3BtreeBeginTrans(Btree *, int, int *);
int sqlite3BtreeCommit(Btree *);
int sqlite3BtreeCursorSize(void);
void sqlite3BtreeCursorZero(BtCursor *);
int sqlite3BtreeCursor(Btree *, unsigned int, int, KeyInfo *, BtCursor *);
int sqlite3BtreeCloseCursor(BtCursor *);
int sqlite3BtreeFirst(BtCursor *, int *);
int sqlite3BtreeNext(BtCursor *, int);
int sqlite3BtreeEof(BtCursor *);
int sqlite3BtreeTableMoveto(BtCursor *, i64, int, int *);
int sqlite3BtreeIndexMoveto(BtCursor *, UnpackedRecord *, int *);
i64 sqlite3BtreeIntegerKey(BtCursor *);
u32 sqlite3BtreePayloadSize(BtCursor *);
const void *sqlite3BtreePayloadFetch(BtCursor *, u32 *);
int sqlite3BtreePayload(BtCursor *, u32, u32, void *);
KeyInfo *sqlite3KeyInfoAlloc(sqlite3 *, int, int);
void mem_set_int(Mem *, i64);
CollSeq *default_coll(sqlite3 *);

/* io_uring: thin syscall wrappers, the kernel's own structs. All ring logic is in server.py. */
struct io_sqring_offsets { unsigned head, tail, ring_mask, ring_entries, flags, dropped, array; ...; };
struct io_cqring_offsets { unsigned head, tail, ring_mask, ring_entries, overflow, cqes, flags; ...; };
struct io_uring_params { unsigned sq_entries, cq_entries, flags, sq_thread_cpu, sq_thread_idle, features, wq_fd;
                         struct io_sqring_offsets sq_off; struct io_cqring_offsets cq_off; ...; };
int ring_setup(unsigned, struct io_uring_params *);
int ring_enter(int, unsigned, unsigned, unsigned);
int ring_register_sparse(int, unsigned);
int ring_register_bufs(int, void *, unsigned, int, int);
int ring_register_eventfd(int, int);
void *ring_mmap(int, size_t, long long);
void *anon_mmap(size_t);
unsigned load_acquire(unsigned *);
void store_release(unsigned *, unsigned);
void store_release16(unsigned short *, unsigned short);
int get_errno(void);
int eventfd(unsigned, int);
""")
FLAGS = """-DSQLITE_THREADSAFE=0 -DSQLITE_DEFAULT_MEMSTATUS=0 -DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1
-DSQLITE_OMIT_PROGRESS_CALLBACK -DSQLITE_OMIT_SHARED_CACHE -DSQLITE_OMIT_DEPRECATED -DSQLITE_OMIT_LOAD_EXTENSION
-DSQLITE_DQS=0 -DSQLITE_TEMP_STORE=3 -DHAVE_FDATASYNC=1 -DHAVE_USLEEP=1 -DNDEBUG -DSQLITE_PRIVATE=""".split()
ffi.set_source("_sq", """
#include "sqlite3.c"
static void mem_set_int(Mem *m, i64 v) { memset(m, 0, sizeof *m); m->flags = MEM_Int; m->u.i = v; }
static CollSeq *default_coll(sqlite3 *db) { return db->pDfltColl; }

#include <errno.h>
#include <sys/eventfd.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <linux/io_uring.h>
static int ring_setup(unsigned n, struct io_uring_params *p) { return syscall(__NR_io_uring_setup, n, p); }
static int ring_enter(int fd, unsigned sub, unsigned min, unsigned fl) { return syscall(__NR_io_uring_enter, fd, sub, min, fl, NULL, 0); }
static int ring_register_sparse(int fd, unsigned n) {
  struct io_uring_rsrc_register r; memset(&r, 0, sizeof r); r.nr = n; r.flags = IORING_RSRC_REGISTER_SPARSE;
  return syscall(__NR_io_uring_register, fd, IORING_REGISTER_FILES2, &r, sizeof r);
}
static int ring_register_bufs(int fd, void *addr, unsigned n, int bgid, int resv0) {
  struct io_uring_buf_reg r; memset(&r, 0, sizeof r);
  r.ring_addr = (unsigned long)addr; r.ring_entries = n; r.bgid = bgid; r.resv[0] = resv0;
  return syscall(__NR_io_uring_register, fd, IORING_REGISTER_PBUF_RING, &r, 1);
}
static int ring_register_eventfd(int fd, int efd) { return syscall(__NR_io_uring_register, fd, IORING_REGISTER_EVENTFD, &efd, 1); }
static void *ring_mmap(int fd, size_t n, long long off) { return mmap(0, n, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE, fd, off); }
static void *anon_mmap(size_t n) { return mmap(0, n, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0); }
static unsigned load_acquire(unsigned *p) { return __atomic_load_n(p, __ATOMIC_ACQUIRE); }
static void store_release(unsigned *p, unsigned v) { __atomic_store_n(p, v, __ATOMIC_RELEASE); }
static void store_release16(unsigned short *p, unsigned short v) { __atomic_store_n(p, v, __ATOMIC_RELEASE); }
static int get_errno(void) { return errno; }
""", include_dirs=[VENDOR], extra_compile_args=FLAGS + ["-O2", "-w", "-fno-semantic-interposition", "-fomit-frame-pointer"])
if __name__ == "__main__":
    ffi.compile(tmpdir=os.path.join(HERE, "bin"), verbose=False)
