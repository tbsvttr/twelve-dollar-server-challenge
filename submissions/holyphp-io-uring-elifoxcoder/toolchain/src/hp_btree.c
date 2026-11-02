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
    rc = sqlite3BtreeLockTable(h->pBt, lockRoot, 0);
    if (rc != SQLITE_OK) goto open_fail;
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
