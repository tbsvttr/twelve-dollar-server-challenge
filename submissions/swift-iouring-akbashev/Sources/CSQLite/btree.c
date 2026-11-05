// SQLite's amalgamation, compiled here rather than on its own, and cursors over its B-trees (see include/btree.h).
#include "sqlite3.c"
#include "btree.h"

struct btree_cursor {
  BtCursor *cursor; /* sqlite3BtreeCursorSize() bytes */
  Btree *btree;
  KeyInfo *keys; /* NULL for a table */
  Pgno root;
  int open;
};

btree_cursor *btree_cursor_new(sqlite3 *db, uint32_t root, int key_columns, int descending) {
  btree_cursor *c = sqlite3_malloc(sizeof *c);
  if (!c) return 0;
  memset(c, 0, sizeof *c);
  c->btree = db->aDb[0].pBt;
  c->root = root;
  c->cursor = sqlite3_malloc(sqlite3BtreeCursorSize());
  if (key_columns > 0) {
    /* The key columns, then the rowid: laid out as sqlite3KeyInfoAlloc does, but from the global allocator, so that
     * freeing it needs no connection. */
    int n = key_columns + 1;
    size_t size = SZ_KEYINFO(n) + n;
    c->keys = sqlite3_malloc64(size);
    if (c->keys) {
      memset(c->keys, 0, size);
      c->keys->aSortFlags = (u8 *)&c->keys->aColl[n];
      c->keys->nKeyField = (u16)key_columns;
      c->keys->nAllField = (u16)n;
      c->keys->enc = ENC(db);
      c->keys->db = db;
      c->keys->nRef = 1;
      for (int i = 0; i < n; i++) c->keys->aColl[i] = db->pDfltColl;
      for (int i = 0; i < key_columns; i++) c->keys->aSortFlags[i] = descending ? KEYINFO_ORDER_DESC : 0;
    }
  }
  if (!c->cursor || (key_columns > 0 && !c->keys)) {
    btree_cursor_free(c);
    return 0;
  }
  return c;
}

void btree_cursor_free(btree_cursor *c) {
  if (!c) return;
  btree_cursor_close(c);
  sqlite3_free(c->keys);
  sqlite3_free(c->cursor);
  sqlite3_free(c);
}

int btree_cursor_open(btree_cursor *c) {
  if (c->open) return SQLITE_OK;
  int rc = sqlite3BtreeBeginTrans(c->btree, 0, 0);
  if (rc != SQLITE_OK) return rc;
  sqlite3BtreeCursorZero(c->cursor);
  rc = sqlite3BtreeCursor(c->btree, c->root, 0, c->keys, c->cursor);
  if (rc == SQLITE_OK) c->open = 1;
  return rc;
}

void btree_cursor_close(btree_cursor *c) {
  if (!c->open) return;
  sqlite3BtreeCloseCursor(c->cursor);
  c->open = 0;
}

int btree_seek(btree_cursor *c, int64_t rowid) {
  BtCursor *cur = c->cursor;
  /* SQLite's own seek steps forward from the row before; this steps back from the row after. */
  if (cur->eState == CURSOR_VALID && (cur->curFlags & BTCF_ValidNKey) && cur->info.nKey == rowid + 1) {
    int rc = sqlite3BtreePrevious(cur, 0);
    if (rc == SQLITE_OK) {
      getCellInfo(cur);
      if (cur->info.nKey == rowid) return 1;
    } else if (rc != SQLITE_DONE) {
      return -1;
    }
  }
  int res = 0;
  if (sqlite3BtreeTableMoveto(cur, rowid, 0, &res) != SQLITE_OK) return -1;
  return res == 0 && cur->eState == CURSOR_VALID;
}

int btree_seek_at_least(btree_cursor *c, int64_t key) {
  BtCursor *cur = c->cursor;
  Mem value;
  UnpackedRecord record;
  memset(&value, 0, sizeof value);
  value.flags = MEM_Int;
  value.u.i = key;
  memset(&record, 0, sizeof record);
  record.pKeyInfo = c->keys;
  record.aMem = &value;
  record.nField = 1;
  record.default_rc = +1; /* entries equal on the key sort after it: land on the first of them */
  int res = 0;
  if (sqlite3BtreeIndexMoveto(cur, &record, &res) != SQLITE_OK) return -1;
  if (sqlite3BtreeEof(cur)) return 0;
  if (res < 0) return btree_next(c);
  return 1;
}

int btree_first(btree_cursor *c) {
  int empty = 1;
  if (sqlite3BtreeFirst(c->cursor, &empty) != SQLITE_OK) return -1;
  return !empty;
}

int btree_next(btree_cursor *c) {
  int rc = sqlite3BtreeNext(c->cursor, 0);
  return rc == SQLITE_OK ? 1 : rc == SQLITE_DONE ? 0 : -1;
}

const uint8_t *btree_record(btree_cursor *c, uint32_t *length) {
  BtCursor *cur = c->cursor;
  getCellInfo(cur);
  if (cur->info.nLocal != cur->info.nPayload) {
    *length = 0;
    return 0;
  }
  *length = cur->info.nPayload;
  return cur->info.pPayload;
}

int btree_count_range(btree_cursor *c, int64_t lo, int64_t hi, uint32_t *counts) {
  static const uint8_t sizes[7] = {0, 1, 2, 3, 4, 6, 8};
  BtCursor *cur = c->cursor;
  int r = btree_seek_at_least(c, lo);
  if (r <= 0) return r;
  for (;;) {
    MemPage *page = cur->pPage;
    /* All of a leaf's cells from here; on an interior page (its cells are entries too), just this one. */
    int i = cur->ix, last = page->leaf ? page->nCell : i + 1;
    for (; i < last; i++) {
      const u8 *cell = findCell(page, i) + page->childPtrSize;
      /* A one-byte payload size, so the record is whole on this page; then a one-byte header size and the key's
       * serial type. */
      u32 length = cell[0];
      const u8 *record = cell + 1;
      if (length >= 0x80 || length < 3 || record + length > page->aDataEnd) return 1;
      u32 header = record[0], type = record[1];
      if (header >= length || header < 3 || type >= 0x80) return 1;
      int64_t key;
      if (type >= 1 && type <= 6) {
        u32 n = sizes[type];
        if (header + n > length) return 1;
        const u8 *v = record + header;
        key = (int8_t)v[0];
        for (u32 j = 1; j < n; j++) key = (int64_t)((uint64_t)key << 8 | v[j]);
      } else if (type == 8 || type == 9) {
        key = type - 8;
      } else {
        return 1;
      }
      if (key > hi) return 0;
      if (key >= lo) counts[key - lo]++;
    }
    cur->ix = (u16)(last - 1);
    int rc = sqlite3BtreeNext(cur, 0);
    if (rc == SQLITE_DONE) return 0;
    if (rc != SQLITE_OK) return -1;
  }
}
