/* A VFS shim over SQLite's default (unix) VFS that issues the WAL frames of one commit in writes of
 * up to 64 KiB (one write for a commit of up to 15 frames of 4 KB pages). SQLite writes each frame
 * with two calls (its 24-byte header, then the page); here consecutive WAL writes are collected
 * and written together once the page of the commit frame (the frame whose header has a non-zero
 * database size) has arrived. That happens inside the
 * commit, before SQLite publishes the frames in the WAL index, so no reader can see a frame that
 * is not in the file; any other operation on the WAL file (read, sync, truncate, size, close,
 * file control) also writes the collected bytes first. The bytes, offsets and their order relative
 * to every other file operation are SQLite's; only the number of system calls changes. The main
 * database file and the shared-memory index are passed through untouched. */
#include "rt.h"
#include <stdlib.h>

typedef struct {
  sqlite3_file base;
  sqlite3_file *real;     /* the unix VFS's file, allocated right after this struct */
  int wal;
  int commit_page;        /* the next write is the page of a commit frame */
  u8_t *buf;
  size_t len, cap;
  sqlite3_int64 start;
} wv_file;

static sqlite3_vfs *wv_base;
static sqlite3_vfs wv_vfs;
static sqlite3_io_methods wv_methods;

/* The unix VFS writes at most 128 KiB - 1 per call (seekAndWriteFd masks the length), so the
 * collected bytes go out in pieces of 64 KiB. */
#define WV_PIECE 65536
static int wv_flush(wv_file *f) {
  size_t off = 0;
  int rc = SQLITE_OK;
  while (off < f->len && rc == SQLITE_OK) {
    size_t n = f->len - off < WV_PIECE ? f->len - off : WV_PIECE;
    rc = f->real->pMethods->xWrite(f->real, f->buf + off, (int)n, f->start + (sqlite3_int64)off);
    off += n;
  }
  f->len = 0;
  return rc;
}
static int wv_close(sqlite3_file *p) {
  wv_file *f = (wv_file *)p;
  int rc = wv_flush(f);
  int rc2 = f->real->pMethods->xClose(f->real);
  free(f->buf);
  f->buf = 0;
  return rc != SQLITE_OK ? rc : rc2;
}
static int wv_read(sqlite3_file *p, void *b, int n, sqlite3_int64 o) {
  wv_file *f = (wv_file *)p;
  int rc = wv_flush(f);
  return rc != SQLITE_OK ? rc : f->real->pMethods->xRead(f->real, b, n, o);
}
static int wv_write(sqlite3_file *p, const void *b, int n, sqlite3_int64 o) {
  wv_file *f = (wv_file *)p;
  if (!f->wal) return f->real->pMethods->xWrite(f->real, b, n, o);
  int rc;
  if (f->len && o != f->start + (sqlite3_int64)f->len && (rc = wv_flush(f)) != SQLITE_OK) return rc;
  if (f->len + (size_t)n > f->cap) {
    if (f->len && (rc = wv_flush(f)) != SQLITE_OK) return rc;
    if ((size_t)n > f->cap) {
      size_t cap = (size_t)n < (1u << 20) ? (1u << 20) : (size_t)n;
      u8_t *m = realloc(f->buf, cap);
      if (!m) return f->real->pMethods->xWrite(f->real, b, n, o);
      f->buf = m;
      f->cap = cap;
    }
  }
  if (!f->len) f->start = o;
  memcpy(f->buf + f->len, b, (size_t)n);
  f->len += (size_t)n;
  if (f->commit_page) { f->commit_page = 0; return wv_flush(f); }
  if (n == 24) {
    const u8_t *h = b;
    if (h[4] | h[5] | h[6] | h[7]) f->commit_page = 1;
  }
  return SQLITE_OK;
}
static int wv_truncate(sqlite3_file *p, sqlite3_int64 size) {
  wv_file *f = (wv_file *)p;
  int rc = wv_flush(f);
  return rc != SQLITE_OK ? rc : f->real->pMethods->xTruncate(f->real, size);
}
static int wv_sync(sqlite3_file *p, int flags) {
  wv_file *f = (wv_file *)p;
  int rc = wv_flush(f);
  return rc != SQLITE_OK ? rc : f->real->pMethods->xSync(f->real, flags);
}
static int wv_size(sqlite3_file *p, sqlite3_int64 *s) {
  wv_file *f = (wv_file *)p;
  int rc = wv_flush(f);
  return rc != SQLITE_OK ? rc : f->real->pMethods->xFileSize(f->real, s);
}
static int wv_lock(sqlite3_file *p, int l) { return ((wv_file *)p)->real->pMethods->xLock(((wv_file *)p)->real, l); }
static int wv_unlock(sqlite3_file *p, int l) { return ((wv_file *)p)->real->pMethods->xUnlock(((wv_file *)p)->real, l); }
static int wv_reserved(sqlite3_file *p, int *r) { return ((wv_file *)p)->real->pMethods->xCheckReservedLock(((wv_file *)p)->real, r); }
static int wv_fcntl(sqlite3_file *p, int op, void *a) {
  wv_file *f = (wv_file *)p;
  int rc = wv_flush(f);
  return rc != SQLITE_OK ? rc : f->real->pMethods->xFileControl(f->real, op, a);
}
static int wv_sector(sqlite3_file *p) { return ((wv_file *)p)->real->pMethods->xSectorSize(((wv_file *)p)->real); }
static int wv_devchar(sqlite3_file *p) { return ((wv_file *)p)->real->pMethods->xDeviceCharacteristics(((wv_file *)p)->real); }
static int wv_shm_map(sqlite3_file *p, int pg, int sz, int ext, void volatile **pp) { return ((wv_file *)p)->real->pMethods->xShmMap(((wv_file *)p)->real, pg, sz, ext, pp); }
static int wv_shm_lock(sqlite3_file *p, int o, int n, int fl) { return ((wv_file *)p)->real->pMethods->xShmLock(((wv_file *)p)->real, o, n, fl); }
static void wv_shm_barrier(sqlite3_file *p) { ((wv_file *)p)->real->pMethods->xShmBarrier(((wv_file *)p)->real); }
static int wv_shm_unmap(sqlite3_file *p, int del) { return ((wv_file *)p)->real->pMethods->xShmUnmap(((wv_file *)p)->real, del); }
static int wv_fetch(sqlite3_file *p, sqlite3_int64 o, int n, void **pp) {
  wv_file *f = (wv_file *)p;
  int rc = wv_flush(f);
  return rc != SQLITE_OK ? rc : f->real->pMethods->xFetch(f->real, o, n, pp);
}
static int wv_unfetch(sqlite3_file *p, sqlite3_int64 o, void *q) { return ((wv_file *)p)->real->pMethods->xUnfetch(((wv_file *)p)->real, o, q); }

static int wv_open(sqlite3_vfs *vfs, sqlite3_filename name, sqlite3_file *p, int flags, int *out) {
  (void)vfs;
  wv_file *f = (wv_file *)p;
  memset(f, 0, sizeof *f);
  f->real = (sqlite3_file *)(f + 1);
  f->wal = (flags & SQLITE_OPEN_WAL) != 0;
  int rc = wv_base->xOpen(wv_base, name, f->real, flags, out);
  if (rc == SQLITE_OK && f->real->pMethods) {
    if (f->real->pMethods->iVersion < 3) { f->real->pMethods->xClose(f->real); return SQLITE_CANTOPEN; }
    p->pMethods = &wv_methods;
  } else p->pMethods = 0;
  return rc;
}

static void walvfs_register(void) {
  wv_base = sqlite3_vfs_find(0);
  wv_vfs = *wv_base;
  wv_vfs.zName = "feedwal";
  wv_vfs.szOsFile = (int)sizeof(wv_file) + wv_base->szOsFile;
  wv_vfs.xOpen = wv_open;
  wv_vfs.pNext = 0;
  wv_methods = (sqlite3_io_methods){3, wv_close, wv_read, wv_write, wv_truncate, wv_sync, wv_size, wv_lock, wv_unlock,
                                    wv_reserved, wv_fcntl, wv_sector, wv_devchar, wv_shm_map, wv_shm_lock, wv_shm_barrier,
                                    wv_shm_unmap, wv_fetch, wv_unfetch};
  sqlite3_vfs_register(&wv_vfs, 0);
}
