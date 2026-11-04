/* ---- HolyPHP generic B-tree cursor binding ----
 * Appended to sqlite3.c by build.sh so it can see SQLite's internals. This is
 * a driver primitive, like sqlite3_prepare: it exposes cursors on a table or
 * index, their payload bytes and the rowid. No challenge logic lives here. */

typedef struct HpBt {
    sqlite3 *db;
    Btree *pBt;
    BtCursor cur;
    KeyInfo *pKey;      /* owned by this cursor when it is an index cursor */
    Pgno root;
    int isIndex;
    int isOpen;         /* cur is linked into the btree and safe to use */
} HpBt;

#define HP_BT_MULTI_MAX 64
typedef struct HpBtMulti {
    int n;
    MemPage *page[HP_BT_MULTI_MAX];
    int ix[HP_BT_MULTI_MAX];
    unsigned char found[HP_BT_MULTI_MAX];
} HpBtMulti;


static inline i64 hp_bt_multi_cell_key(MemPage *pg, int i) {
    u8 *c = findCellPastPtr(pg, i);
    u64 key = 0;
    if (pg->intKeyLeaf) while (0x80 <= *(c++)) {}
    (void)sqlite3GetVarint(c, &key);
    return (i64)key;
}

/* Interpolation narrows dense integer table pages in one or two probes. The
 * short local walk handles nearby hits; binary search remains the fallback. */
static inline int hp_bt_multi_lower_bound(MemPage *pg, i64 k) {
    int n = pg->nCell, lo = 0, len = n;
    if (n >= 8) {
        i64 k0 = hp_bt_multi_cell_key(pg, 0), kn = hp_bt_multi_cell_key(pg, n - 1);
        if (k <= k0) return 0;
        if (k > kn) return n;
        u64 delta = (u64)k - (u64)k0;
        u64 span = (u64)kn - (u64)k0;
        int g = (int)((double)delta * (double)(n - 1) / (double)span);
        if (g < 1) g = 1;
        if (g > n - 1) g = n - 1;
        if (hp_bt_multi_cell_key(pg, g) >= k) {
            for (int s = 0; s < 4; s++) {
                if (hp_bt_multi_cell_key(pg, g - 1) < k) return g;
                g--;
            }
            lo = 1;
            len = g;
        } else {
            for (int s = 0; s < 4; s++) {
                g++;
                if (hp_bt_multi_cell_key(pg, g) >= k) return g;
            }
            lo = g + 1;
            len = n - 1 - g;
        }
    }
    while (len > 0) {
        int half = len >> 1;
        if (hp_bt_multi_cell_key(pg, lo + half) < k) {
            lo += half + 1;
            len -= half + 1;
        } else len = half;
    }
    return lo;
}

/* Generic batched rowid lookup for table cursors. Keys are sorted for the
 * descent so searches sharing a child page share its cache reference. The
 * result pins leaf pages until hp_bt_multi_release_impl(). */
void *hp_bt_multi_seek_impl(void *v, const sqlite3_int64 *keys_in, int n) {
    HpBt *h = (HpBt *)v;
    HpBtMulti *out;
    MemPage *cur[HP_BT_MULTI_MAX] = {0};
    Pgno child[HP_BT_MULTI_MAX];
    int ord[HP_BT_MULTI_MAX];
    sqlite3_int64 keys[HP_BT_MULTI_MAX];
    int rc;
    if (!h || !h->isOpen || h->isIndex || !keys_in || n < 1 || n > HP_BT_MULTI_MAX)
        return 0;
    out = (HpBtMulti *)sqlite3_malloc(sizeof *out);
    if (!out) return 0;
    memset(out, 0, sizeof *out);
    out->n = n;
    for (int i = 0; i < n; i++) {
        int j = i;
        ord[i] = i;
        while (j > 0 && keys_in[ord[j - 1]] > keys_in[i]) {
            ord[j] = ord[j - 1];
            j--;
        }
        ord[j] = i;
    }
    for (int i = 0; i < n; i++) keys[i] = keys_in[ord[i]];
    rc = getAndInitPage(h->pBt->pBt, h->root, &cur[0], PAGER_GET_READONLY);
    if (rc != SQLITE_OK) goto fail;
    if (cur[0]->nCell == 0) {
        releasePage(cur[0]);
        cur[0] = 0;
        return out;
    }
    for (int i = 1; i < n; i++) {
        sqlite3PagerRef(cur[0]->pDbPage);
        cur[i] = cur[0];
    }
    for (int depth = 0; !cur[0]->leaf; depth++) {
        if (depth > 20) { rc = SQLITE_CORRUPT_BKPT; goto fail; }
        for (int i = 0; i < n; i++) {
            MemPage *pg = cur[i];
            int lb = hp_bt_multi_lower_bound(pg, keys[i]);
            child[i] = lb >= pg->nCell
                ? get4byte(&pg->aData[pg->hdrOffset + 8])
                : get4byte(findCell(pg, lb));
        }
        /* The descent array contains one reference per key, including keys
         * sharing a page. Rebuild those shared references before the next
         * level, after releasing every reference from this level. */
        for (int i = 0; i < n; i++) releasePage(cur[i]);
        memset(cur, 0, sizeof cur);
        for (int i = 0; i < n; i++) {
            if (i && child[i] == child[i - 1]) {
                sqlite3PagerRef(cur[i - 1]->pDbPage);
                cur[i] = cur[i - 1];
                continue;
            }
            if ((rc = getAndInitPage(h->pBt->pBt, child[i], &cur[i], PAGER_GET_READONLY)) != SQLITE_OK)
                goto fail;
            if (cur[i]->nCell < 1 || cur[i]->intKey != 1 || cur[i]->leaf != cur[0]->leaf) {
                rc = SQLITE_CORRUPT_PGNO(child[i]);
                goto fail;
            }
        }
    }
    for (int i = 0; i < n; i++) {
        MemPage *pg = cur[i];
        int lb = hp_bt_multi_lower_bound(pg, keys[i]);
        int found = 0;
        if (lb < pg->nCell) found = hp_bt_multi_cell_key(pg, lb) == keys[i];
        out->page[ord[i]] = pg;
        out->ix[ord[i]] = lb;
        out->found[ord[i]] = (unsigned char)found;
        cur[i] = 0;
    }
    return out;
fail:
    for (int i = 0; i < n; i++) if (cur[i]) releasePage(cur[i]);
    sqlite3_free(out);
    return 0;
}

int hp_bt_multi_payloads_impl(void *v, sqlite3_int64 *dst, sqlite3_int64 cap) {
    HpBtMulti *r = (HpBtMulti *)v;
    if (!r || !dst || cap < (sqlite3_int64)r->n * 3) return 0;
    for (int i = 0; i < r->n; i++) {
        dst[i * 3] = r->found[i];
        dst[i * 3 + 1] = 0;
        dst[i * 3 + 2] = 0;
        if (r->found[i]) {
            MemPage *pg = r->page[i];
            CellInfo info;
            pg->xParseCell(pg, findCell(pg, r->ix[i]), &info);
            if (info.nLocal != info.nPayload) return 0;
            dst[i * 3 + 1] = (sqlite3_int64)(intptr_t)info.pPayload;
            dst[i * 3 + 2] = info.nPayload;
        }
    }
    return 1;
}

void hp_bt_multi_release_impl(void *v) {
    HpBtMulti *r = (HpBtMulti *)v;
    if (!r) return;
    for (int i = 0; i < r->n; i++) if (r->page[i]) releasePage(r->page[i]);
    sqlite3_free(r);
}

#ifndef HP_BT_SEEK_WALK_MAX
#define HP_BT_SEEK_WALK_MAX 32
#endif

/* A cursor may only exist inside a b-tree transaction. Without one the pager
 * is free to drop the entire page cache at the next write commit
 * (pager_reset -> sqlite3PcacheClear), which frees the MemPage objects the
 * cursor holds pointers to; the next cursor move then reads freed memory.
 *
 * All cursors of one connection share one read transaction: the first cursor
 * that opens starts it, the last one that closes ends it (unless the caller
 * owns a write transaction, which is never committed here). */
typedef struct HpBtTxn {
    Btree *pBt;
    int depth;          /* open cursors on this b-tree */
    int owned;          /* this layer started the transaction */
    int used;
} HpBtTxn;

#define HP_BT_TXN_MAX 8
static HpBtTxn hp_bt_txns[HP_BT_TXN_MAX];

static HpBtTxn *hp_bt_txn_find(Btree *pBt) {
    int i;
    for (i = 0; i < HP_BT_TXN_MAX; i++)
        if (hp_bt_txns[i].used && hp_bt_txns[i].pBt == pBt) return &hp_bt_txns[i];
    return 0;
}

static HpBtTxn *hp_bt_txn_get(Btree *pBt) {
    HpBtTxn *t = hp_bt_txn_find(pBt);
    int i;
    if (t) return t;
    for (i = 0; i < HP_BT_TXN_MAX; i++) {
        if (!hp_bt_txns[i].used) {
            memset(&hp_bt_txns[i], 0, sizeof hp_bt_txns[i]);
            hp_bt_txns[i].used = 1;
            hp_bt_txns[i].pBt = pBt;
            return &hp_bt_txns[i];
        }
    }
    return 0;
}

/* Release the read transaction started for our low-level cursors. A cursor
 * may have been used while the caller promoted that transaction to a write
 * transaction; in that case the caller owns the write commit. */
static void hp_bt_txn_drop_if_empty(HpBtTxn *t) {
    if (!t || t->depth != 0) return;
    if (t->owned && t->pBt && t->pBt->inTrans == TRANS_READ) {
        int rc = sqlite3BtreeCommit(t->pBt);
        if (rc != SQLITE_OK && t->pBt->inTrans == TRANS_READ)
            sqlite3BtreeRollback(t->pBt, SQLITE_OK, 0);
    }
    memset(t, 0, sizeof *t);
}

unsigned int hp_bt_root_impl(sqlite3 *db, const char *zName, int isIndex) {
    char *zErr = 0;
    if (!db || !zName) return 0;
    /* sqlite3_open() does not read the schema; do it before looking up a
     * table or index by name. */
    {
        int rc = sqlite3Init(db, &zErr);
        if (rc != SQLITE_OK) { sqlite3_free(zErr); return 0; }
    }
    if (isIndex) {
        HashElem *k;
        for (k = sqliteHashFirst(&db->aDb[0].pSchema->idxHash); k; k = sqliteHashNext(k)) {
            Index *pIdx = (Index *)sqliteHashData(k);
            if (sqlite3StrICmp(pIdx->zName, zName) == 0) return pIdx->tnum;
        }
        return 0;
    } else {
        Table *pTab = sqlite3FindTable(db, zName, "main");
        return pTab ? pTab->tnum : 0;
    }
}

static Index *hp_find_index(sqlite3 *db, const char *zName) {
    HashElem *k;
    for (k = sqliteHashFirst(&db->aDb[0].pSchema->idxHash); k; k = sqliteHashNext(k)) {
        Index *pIdx = (Index *)sqliteHashData(k);
        if (sqlite3StrICmp(pIdx->zName, zName) == 0) return pIdx;
    }
    return 0;
}

/* Open a cursor on a table (isIndex == 0) or on an index by name. The index
 * cursor needs the index's KeyInfo, otherwise the btree cannot interpret the
 * keys and sqlite3BtreeLast() fails. */
void *hp_bt_open_impl(sqlite3 *db, const char *zName, int isIndex) {
    HpBt *h;
    Pgno root, lockRoot;
    KeyInfo *pKey = 0;
    Table *pTab = 0;
    Index *pIdx = 0;
    HpBtTxn *txn;
    int rc;
    char *zErr = 0;
    if (!db || !zName) return 0;
    if (sqlite3Init(db, &zErr) != SQLITE_OK) { sqlite3_free(zErr); return 0; }
    if (isIndex) {
        pIdx = hp_find_index(db, zName);
        Parse sParse;
        if (!pIdx) return 0;
        root = pIdx->tnum;
        lockRoot = pIdx->pTable->tnum;
        /* The index cursor needs the index's KeyInfo; without it the btree
         * cannot compare keys and sqlite3BtreeLast() fails. sqlite3KeyInfoOfIndex
         * wants a Parse, but only reads db/nErr from it. */
        memset(&sParse, 0, sizeof sParse);
        sParse.db = db;
        pKey = sqlite3KeyInfoOfIndex(&sParse, pIdx);
        if (!pKey) return 0;
    } else {
        pTab = sqlite3FindTable(db, zName, "main");
        if (!pTab) return 0;
        root = pTab->tnum;
        lockRoot = root;
    }
    h = (HpBt *)sqlite3_malloc(sizeof *h);
    if (!h) return 0;
    memset(h, 0, sizeof *h);
    h->db = db;
    h->pBt = db->aDb[0].pBt;
    h->pKey = pKey;
    h->root = root;
    h->isIndex = isIndex;

    txn = hp_bt_txn_get(h->pBt);
    if (!txn) goto open_fail;
    if (txn->depth == 0) {
        txn->owned = h->pBt->inTrans == TRANS_NONE;
        if (txn->owned) {
            rc = sqlite3BtreeBeginTrans(h->pBt, 0, 0);
            if (rc != SQLITE_OK) goto open_fail;
        }
    }
#ifndef SQLITE_OMIT_SHARED_CACHE
    rc = sqlite3BtreeLockTable(h->pBt, lockRoot, 0);
    if (rc != SQLITE_OK) goto open_fail;
#else
    (void)lockRoot;
#endif
    rc = sqlite3BtreeCursor(h->pBt, root, 0, pKey, &h->cur);
    if (rc != SQLITE_OK) goto open_fail;
    txn->depth++;
    h->isOpen = 1;
    return h;

open_fail:
    if (txn && txn->depth == 0) hp_bt_txn_drop_if_empty(txn);
    if (pKey) sqlite3KeyInfoUnref(pKey);
    sqlite3_free(h);
    return 0;
}

void hp_bt_close_impl(void *v) {
    HpBt *h = (HpBt *)v;
    HpBtTxn *txn;
    if (!h) return;
    if (h->isOpen) {
        sqlite3BtreeCloseCursor(&h->cur);
        h->isOpen = 0;
        txn = hp_bt_txn_find(h->pBt);
        if (txn && txn->depth > 0) {
            txn->depth--;
            hp_bt_txn_drop_if_empty(txn);
        }
    }
    if (h->pKey) sqlite3KeyInfoUnref(h->pKey);
    sqlite3_free(h);
}

/* 1 = on a row, 0 = empty / past the end, -1 = error */
int hp_bt_first_impl(void *v) {
    HpBt *h = (HpBt *)v;
    int res = 1;
    if (!h) return -1;
    return sqlite3BtreeFirst(&h->cur, &res) == SQLITE_OK ? (res ? 0 : 1) : -1;
}
int hp_bt_last_impl(void *v) {
    HpBt *h = (HpBt *)v;
    int res = 1;
    if (!h) return -1;
    return sqlite3BtreeLast(&h->cur, &res) == SQLITE_OK ? (res ? 0 : 1) : -1;
}
int hp_bt_next_impl(void *v) {
    HpBt *h = (HpBt *)v;
    if (!h) return 0;
    return sqlite3BtreeNext(&h->cur, 0) == SQLITE_OK ? 1 : 0;
}
int hp_bt_prev_impl(void *v) {
    HpBt *h = (HpBt *)v;
    if (!h) return 0;
    return sqlite3BtreePrevious(&h->cur, 0) == SQLITE_OK ? 1 : 0;
}
int hp_bt_seek_impl(void *v, sqlite3_int64 rowid) {
    HpBt *h = (HpBt *)v;
    int res = 1;
    if (!h) return -1;
    /* Consecutive table-row seeks are common when a caller walks IDs that
     * came from an adjacent index range. Reusing a nearby valid table cursor
     * avoids repeating a root-to-leaf TableMoveto for every row. Keep the
     * window small and generic; distant or index-cursor seeks use SQLite's
     * normal search path. */
    if (!h->isIndex && h->cur.eState == CURSOR_VALID) {
        sqlite3_int64 at = sqlite3BtreeIntegerKey(&h->cur);
        u64 distance = rowid >= at
            ? (u64)rowid - (u64)at
            : (u64)at - (u64)rowid;
        if (distance <= HP_BT_SEEK_WALK_MAX) {
            while (at != rowid) {
                int forward = rowid > at;
                int rc = forward
                    ? sqlite3BtreeNext(&h->cur, 0)
                    : sqlite3BtreePrevious(&h->cur, 0);
                if (rc == SQLITE_DONE) return 0;
                if (rc != SQLITE_OK) return -1;
                at = sqlite3BtreeIntegerKey(&h->cur);
                if ((forward && at > rowid) || (!forward && at < rowid))
                    return 0;
            }
            return 1;
        }
    }
    return sqlite3BtreeTableMoveto(&h->cur, (i64)rowid, 0, &res) == SQLITE_OK ? (res ? 0 : 1) : -1;
}

sqlite3_int64 hp_bt_rowid_impl(void *v) {
    HpBt *h = (HpBt *)v;
    if (!h) return -1;
    return (sqlite3_int64)sqlite3BtreeIntegerKey(&h->cur);
}
const unsigned char *hp_bt_payload_impl(void *v, int *pn) {
    HpBt *h = (HpBt *)v;
    u32 amt = 0;
    const void *p;
    if (!h || !pn) return 0;
    *pn = 0;
    if (h->cur.eState != CURSOR_VALID) return 0;
    /* getCellInfo() runs here: fetchPayload() asserts info.nSize != 0, and a
     * cursor that just moved has it cleared. */
    (void)sqlite3BtreePayloadSize(&h->cur);
    p = sqlite3BtreePayloadFetch(&h->cur, &amt);
    *pn = (int)amt;
    return (const unsigned char *)p;
}

/* Pin the current table page so a caller can keep a borrowed payload pointer
 * valid while it seeks through another cursor. Each successful pin must be
 * balanced by hp_bt_page_release_impl(). */
void *hp_bt_payload_pin_impl(void *v) {
    HpBt *h = (HpBt *)v;
    MemPage *pg;
    if (!h || h->isIndex || h->cur.eState != CURSOR_VALID || !(pg = h->cur.pPage))
        return 0;
    sqlite3PagerRef(pg->pDbPage);
    return pg;
}
void hp_bt_page_release_impl(void *v) {
    if (v) releasePage((MemPage *)v);
}

/* Decode the first column of an index record (serial types in the header). */
static sqlite3_int64 hp_index_first_key(const unsigned char *p, int n, int *ok) {
    *ok = 0;
    if (!p || n < 2) return 0;
    int hdr = p[0] & 0xFF;
    if (hdr < 2 || hdr > n) return 0;
    int st = p[1] & 0xFF;
    int len;
    if (st >= 1 && st <= 4) len = st;
    else if (st == 5) len = 6;
    else if (st == 6 || st == 7) len = 8;
    else if (st == 8) { *ok = 1; return 0; }
    else if (st == 9) { *ok = 1; return 1; }
    else return 0;
    if (hdr + len > n) return 0;
    sqlite3_int64 v = 0;
    for (int i = 0; i < len; i++) v = (v << 8) | (sqlite3_int64)p[hdr + i];
    *ok = 1;
    return v;
}

/* Count the index entries whose first key column equals `key`.
 *
 * Seek with (key, MAX rowid): the cursor lands on the last entry <= that
 * key, i.e. the last entry of the key's run (or just past it when the key
 * has no entries). Walk backwards while the first column still matches. */
int hp_bt_count_key_impl(void *v, sqlite3_int64 key) {
    HpBt *h = (HpBt *)v;
    UnpackedRecord r;
    Mem m[2];
    int res = 0, count = 0;
    if (!h || !h->pKey) return -1;

    memset(m, 0, sizeof m);
    m[0].flags = MEM_Int;
    m[0].u.i = key;
    m[1].flags = MEM_Int;
    m[1].u.i = 0x7fffffffffffffffLL;
    memset(&r, 0, sizeof r);
    r.pKeyInfo = h->pKey;
    r.nField = 2;
    r.default_rc = 1;
    r.aMem = m;

    if (sqlite3BtreeIndexMoveto(&h->cur, &r, &res) != SQLITE_OK) return -1;
    if (h->cur.eState != CURSOR_VALID) return 0;

    for (;;) {
        int n = 0, ok = 0;
        const unsigned char *p = hp_bt_payload_impl(h, &n);
        sqlite3_int64 k = hp_index_first_key(p, n, &ok);
        if (!ok) break;
        if (k > key) {
            if (sqlite3BtreePrevious(&h->cur, 0) != SQLITE_OK) break;
            continue;
        }
        if (k < key) break;
        count++;
        if (sqlite3BtreePrevious(&h->cur, 0) != SQLITE_OK) break;
    }
    return count;
}

/* Generic dense histogram of an ascending integer-leading index range.
 * out[key-lo] receives the number of rows for that leading key. This is a
 * cursor primitive, independent of table names or application schema. */
int hp_bt_count_range_impl(void *v, sqlite3_int64 lo, sqlite3_int64 hi,
                           sqlite3_int64 *out, sqlite3_int64 cap) {
    HpBt *h = (HpBt *)v;
    Mem m;
    UnpackedRecord r;
    int res = 0, rc;
    sqlite3_int64 span, n = 0;
    if (!h || !h->isIndex || !h->pKey || !out || lo < 0 || hi < lo) return -1;
    if (h->pKey->aSortFlags && (h->pKey->aSortFlags[0] & KEYINFO_ORDER_DESC)) return -1;
    span = hi - lo + 1;
    if (span <= 0 || span > cap) return -1;
    memset(out, 0, (size_t)span * sizeof *out);

    memset(&m, 0, sizeof m);
    m.flags = MEM_Int;
    m.u.i = lo;
    memset(&r, 0, sizeof r);
    r.pKeyInfo = h->pKey;
    r.aMem = &m;
    r.nField = 1;
    r.default_rc = +1;
    if (sqlite3BtreeIndexMoveto(&h->cur, &r, &res) != SQLITE_OK) return -1;
    if (sqlite3BtreeEof(&h->cur)) return 0;
    if (res < 0) {
        rc = sqlite3BtreeNext(&h->cur, 0);
        if (rc == SQLITE_DONE) return 0;
        if (rc != SQLITE_OK) return -1;
    }
    for (;;) {
        MemPage *pg = h->cur.pPage;
        int i = h->cur.ix;
        int last;
        if (!pg || h->cur.eState != CURSOR_VALID) break;
        last = pg->leaf ? pg->nCell : i + 1;
        for (; i < last; i++) {
            const u8 *cell = findCell(pg, i) + pg->childPtrSize;
            u32 payload_len = 0, header_len = 0;
            u64 serial = 0;
            int nvar, hvar, svar, bytes;
            const u8 *p, *q;
            sqlite3_int64 key = 0;
            /* sqlite3GetVarint32() assumes the one-byte case was already
             * handled; the macro is the complete decoder. */
            nvar = getVarint32(cell, payload_len);
            p = cell + nvar;
            /* The fast page walk only handles fully local records. A caller
             * can fall back to ordinary per-key seeks for larger cells. */
            if (payload_len < 3 || p + payload_len > pg->aDataEnd) return -1;
            hvar = getVarint32(p, header_len);
            if (hvar <= 0 || header_len > payload_len || hvar >= (int)payload_len) return -1;
            svar = sqlite3GetVarint(p + hvar, &serial);
            if (svar <= 0 || hvar + svar > (int)header_len) return -1;
            if (serial == 8) key = 0;
            else if (serial == 9) key = 1;
            else {
                u64 value = 0;
                if (serial >= 1 && serial <= 4) bytes = (int)serial;
                else if (serial == 5) bytes = 6;
                else if (serial == 6) bytes = 8;
                else return -1;
                if (header_len + (u32)bytes > payload_len) return -1;
                q = p + header_len;
                for (int j = 0; j < bytes; j++) value = (value << 8) | q[j];
                if (bytes < 8 && (q[0] & 0x80)) value |= ~0ULL << (bytes * 8);
                key = (sqlite3_int64)value;
            }
            if (key > hi) return 0;
            if (key >= lo) out[key - lo]++;
            if (++n > 10000000) return -1;
        }
        h->cur.ix = (u16)(last - 1);
        rc = sqlite3BtreeNext(&h->cur, 0);
        if (rc == SQLITE_DONE) break;
        if (rc != SQLITE_OK) return -1;
    }
    return 0;
}
