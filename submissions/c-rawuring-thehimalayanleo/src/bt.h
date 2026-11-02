// Direct reads through SQLite's B-tree cursor API (rules 2/3: allowed, see LEADERBOARD.md, 2026-10-31).
// Compiled in the same translation unit as the amalgamation. Every row comes from SQLite's pages through
// its pager, WAL and locks, inside the batch's read transaction. Only the bytecode interpreter is skipped.
// Anything unusual (overflow payload, unexpected record shape, schema change) returns -1, and the caller
// runs the plain SQL instead.

enum { C_POSTS, C_USERS, C_LIKES_IDX, C_CREATED_IDX, C_N };

static struct {
  Btree *bt;
  Pgno root[C_N];
  KeyInfo *ki_likes, *ki_created;
  BtCursor *cur[C_N];
  unsigned open;
  int cookie;
  int ok;  // 0: B-tree reads are off for good, SQL only
} B;

static void bt_setup(sqlite3 *d) {
  Table *tp = sqlite3FindTable(d, "posts", "main"), *tu = sqlite3FindTable(d, "users", "main");
  Index *il = sqlite3FindIndex(d, "likes_post_id_idx", "main"), *ic = sqlite3FindIndex(d, "posts_created_at_id_idx", "main");
  if (!tp || !tu || !il || !ic) return;
  // The record layouts this file decodes: posts(id IPK, user_id, body, created_at), users(id IPK, username, ...).
  if (tp->nCol != 4 || tp->iPKey != 0 || tu->nCol < 2 || tu->iPKey != 0) return;
  if (il->nKeyCol != 1 || ic->nKeyCol != 2) return;
  B.root[C_POSTS] = tp->tnum, B.root[C_USERS] = tu->tnum, B.root[C_LIKES_IDX] = il->tnum, B.root[C_CREATED_IDX] = ic->tnum;
  Parse ps;
  memset(&ps, 0, sizeof ps);
  ps.db = d;
  B.ki_likes = sqlite3KeyInfoOfIndex(&ps, il);
  B.ki_created = sqlite3KeyInfoOfIndex(&ps, ic);
  if (!B.ki_likes || !B.ki_created) return;
  B.bt = d->aDb[0].pBt;
  B.cookie = d->aDb[0].pSchema->schema_cookie;
  for (int i = 0; i < C_N; i++) B.cur[i] = calloc(1, (size_t)sqlite3BtreeCursorSize());
  B.ok = 1;
}

// Joins the read transaction opened by the batch's BEGIN. Returns -1 to use SQL.
static int bt_begin(void) {
  if (!B.ok) return -1;
  int cookie = 0;
  if (sqlite3BtreeBeginTrans(B.bt, 0, &cookie) != SQLITE_OK) return -1;
  if (cookie != B.cookie) { B.ok = 0; return -1; }
  return 0;
}

static BtCursor *bt_cur(int k) {
  if (!(B.open & (1u << k))) {
    KeyInfo *ki = k == C_LIKES_IDX ? B.ki_likes : k == C_CREATED_IDX ? B.ki_created : NULL;
    sqlite3BtreeCursorZero(B.cur[k]);
    if (sqlite3BtreeCursor(B.bt, B.root[k], 0, ki, B.cur[k]) != SQLITE_OK) return NULL;
    B.open |= 1u << k;
  }
  return B.cur[k];
}

// Cursors hold pages; close them before the read transaction ends so the snapshot is released.
static void bt_close(void) {
  for (int i = 0; i < C_N; i++)
    if (B.open & (1u << i)) sqlite3BtreeCloseCursor(B.cur[i]);
  B.open = 0;
}

// Decodes up to n fields of the record under the cursor. Fields: serial type and data pointer.
typedef struct { uint64_t t; const uint8_t *d; } fld_t;

static int rec_fields(BtCursor *c, fld_t *f, int n) {
  u32 amt;
  u32 sz = sqlite3BtreePayloadSize(c);
  const uint8_t *p = sqlite3BtreePayloadFetch(c, &amt);
  if (!p || amt < sz) return -1;  // overflow pages: SQL path
  u32 hl, h = getVarint32(p, hl);
  if (hl > sz) return -1;
  const uint8_t *d = p + hl;
  int k = 0;
  while (h < hl && k < n) {
    u64 t;
    h += sqlite3GetVarint(p + h, &t);
    f[k].t = t, f[k].d = d;
    d += sqlite3VdbeSerialTypeLen((u32)t);
    k++;
  }
  if (d > p + sz) return -1;
  return k;
}

static inline int fld_isint(const fld_t *f) { return f->t >= 1 && f->t <= 9 && f->t != 7; }

static int64_t fld_int(const fld_t *f) {
  const uint8_t *b = f->d;
  switch (f->t) {
    case 1: return (int8_t)b[0];
    case 2: return (int16_t)((b[0] << 8) | b[1]);
    case 3: return ((int32_t)((b[0] << 24) | (b[1] << 16) | (b[2] << 8))) >> 8;
    case 4: return (int32_t)((uint32_t)b[0] << 24 | b[1] << 16 | b[2] << 8 | b[3]);
    case 5: { int64_t v = (int16_t)((b[0] << 8) | b[1]); return (v << 32) | ((uint32_t)b[2] << 24 | b[3] << 16 | b[4] << 8 | b[5]); }
    case 6: { uint64_t v = 0; for (int i = 0; i < 8; i++) v = (v << 8) | b[i]; return (int64_t)v; }
    case 8: return 0;
    case 9: return 1;
  }
  return 0;
}

static inline int fld_istext(const fld_t *f) { return f->t >= 13 && (f->t & 1); }
static inline int fld_textlen(const fld_t *f) { return (int)((f->t - 13) / 2); }

// Like counts for post ids in [lo, hi] from one range scan of likes_post_id_idx.
static int bt_count_likes(int64_t lo, int64_t hi, int64_t *cnt) {
  BtCursor *c = bt_cur(C_LIKES_IDX);
  if (!c) return -1;
  Mem m;
  memset(&m, 0, sizeof m);
  m.flags = MEM_Int, m.u.i = lo;
  UnpackedRecord key;
  memset(&key, 0, sizeof key);
  key.pKeyInfo = B.ki_likes, key.aMem = &m, key.nField = 1, key.default_rc = +1;
  int res, rc;
  if (sqlite3BtreeIndexMoveto(c, &key, &res) != SQLITE_OK) return -1;
  if (sqlite3BtreeEof(c)) return 0;
  if (res < 0) {
    rc = sqlite3BtreeNext(c, 0);
    if (rc == SQLITE_DONE) return 0;
    if (rc != SQLITE_OK) return -1;
  }
  for (;;) {
    fld_t f[1];
    if (rec_fields(c, f, 1) != 1 || !fld_isint(&f[0])) return -1;
    int64_t pid = fld_int(&f[0]);
    if (pid > hi) return 0;
    if (pid < lo) return -1;
    cnt[pid - lo]++;
    rc = sqlite3BtreeNext(c, 0);
    if (rc == SQLITE_DONE) return 0;
    if (rc != SQLITE_OK) return -1;
  }
}

// The author of the posts row whose user_id field is f. Returns 1 found, 0 missing, -1 SQL path.
static int bt_user(const fld_t *uf, const char **name, int *nl) {
  if (!fld_isint(uf)) return -1;
  BtCursor *c = bt_cur(C_USERS);
  if (!c) return -1;
  int res;
  if (sqlite3BtreeTableMoveto(c, fld_int(uf), 0, &res) != SQLITE_OK) return -1;
  if (res != 0 || sqlite3BtreeEof(c)) return 0;
  fld_t f[2];
  if (rec_fields(c, f, 2) != 2 || f[0].t != 0 || !fld_istext(&f[1])) return -1;
  *name = (const char *)f[1].d, *nl = fld_textlen(&f[1]);
  return 1;
}

// Appends the post object for the posts row under cursor cp. Returns 1 ok, 0 author missing, -1 SQL path.
static int bt_emit_row(ob_t *o, BtCursor *cp, int64_t id, int64_t likes) {
  fld_t f[4];
  if (rec_fields(cp, f, 4) != 4 || f[0].t != 0 || !fld_istext(&f[2]) || !fld_istext(&f[3])) return -1;
  const char *au;
  int al;
  int r = bt_user(&f[1], &au, &al);
  if (r <= 0) return r;
  // The users cursor moved; the posts cursor's page is still pinned, so f[] stays valid.
  ob_post(o, id, (const char *)f[2].d, fld_textlen(&f[2]), (const char *)f[3].d, fld_textlen(&f[3]), au, al, likes);
  return 1;
}

static int bt_feed(ob_t *o) {
  BtCursor *ci = bt_cur(C_CREATED_IDX), *cp = bt_cur(C_POSTS);
  if (!ci || !cp) return -1;
  int64_t ids[20];
  int n = 0, res, rc;
  // posts_created_at_id_idx is (created_at DESC, id DESC): its first 20 entries are the feed, in order.
  if (sqlite3BtreeFirst(ci, &res) != SQLITE_OK) return -1;
  if (!res) {
    for (;;) {
      fld_t f[3];
      int k = rec_fields(ci, f, 3);
      if (k < 2 || !fld_isint(&f[k - 1])) return -1;
      ids[n++] = fld_int(&f[k - 1]);  // the rowid is the record's last field
      if (n == 20) break;
      rc = sqlite3BtreeNext(ci, 0);
      if (rc == SQLITE_DONE) break;
      if (rc != SQLITE_OK) return -1;
    }
  }
  OB_LIT(o, "{\"posts\":[");
  if (n) {
    int64_t mn = ids[0], mx = ids[0];
    for (int k = 1; k < n; k++) mn = ids[k] < mn ? ids[k] : mn, mx = ids[k] > mx ? ids[k] : mx;
    if (mx - mn >= 1024) return -1;
    static int64_t cnt[1024];
    memset(cnt, 0, (size_t)(mx - mn + 1) * sizeof *cnt);
    if (bt_count_likes(mn, mx, cnt) < 0) return -1;
    int out = 0;
    for (int k = 0; k < n; k++) {
      // The feed's ids usually step down by one: then the row is the previous cell, no seek from the root.
      int stepped = 0;
      if (k && ids[k] == ids[k - 1] - 1) {
        rc = sqlite3BtreePrevious(cp, 0);
        if (rc != SQLITE_OK && rc != SQLITE_DONE) return -1;
        stepped = rc == SQLITE_OK && sqlite3BtreeIntegerKey(cp) == ids[k];
      }
      if (!stepped) {
        if (sqlite3BtreeTableMoveto(cp, ids[k], 0, &res) != SQLITE_OK) return -1;
        if (res != 0 || sqlite3BtreeEof(cp)) return -1;  // index entry without a row: let SQL decide
      }
      uint32_t at = o->len;
      if (out) OB_LIT(o, ",");
      int r = bt_emit_row(o, cp, ids[k], cnt[ids[k] - mn]);
      if (r < 0) return -1;
      if (r == 0) { o->len = at; continue; }  // inner join drops a post without an author
      out++;
    }
  }
  OB_LIT(o, "]}");
  return 0;
}

// Returns 1 written, 0 not found, -1 SQL path.
static int bt_post(ob_t *o, int64_t id) {
  BtCursor *cp = bt_cur(C_POSTS);
  if (!cp) return -1;
  int res;
  if (sqlite3BtreeTableMoveto(cp, id, 0, &res) != SQLITE_OK) return -1;
  if (res != 0 || sqlite3BtreeEof(cp)) return 0;
  int64_t cnt = 0;
  if (bt_count_likes(id, id, &cnt) < 0) return -1;
  uint32_t at = o->len;
  OB_LIT(o, "{\"post\":");
  int r = bt_emit_row(o, cp, id, cnt);
  if (r <= 0) { o->len = at; return r; }
  OB_LIT(o, "}");
  return 1;
}
