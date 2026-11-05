// Reading SQLite's B-trees directly, for the read queries: a cursor over a table or an index of the main database,
// used inside the transaction the connection has open, and each entry's record handed back as bytes (Swift decodes
// them). btree.c compiles the amalgamation itself, so these functions reach SQLite's internals.
#ifndef FEED_BTREE_H
#define FEED_BTREE_H

#include <stdint.h>
#include "sqlite3.h"

typedef struct btree_cursor btree_cursor;

/* A cursor over the B-tree whose root is page `root`: a table (key_columns 0), or an index whose entries are
 * `key_columns` columns, all ascending or all descending, then the rowid. NULL when out of memory. Freeing one needs
 * no connection; it must not be open then. */
btree_cursor *btree_cursor_new(sqlite3 *db, uint32_t root, int key_columns, int descending);
void btree_cursor_free(btree_cursor *cursor);

/* Opens the cursor inside the transaction the connection has open (after BEGIN), starting the B-tree's read
 * transaction if no statement has yet: SQLITE_OK or an error code. Closed again before the transaction ends. */
int btree_cursor_open(btree_cursor *cursor);
void btree_cursor_close(btree_cursor *cursor);

/* The moves return 1 on an entry, 0 when there is none, -1 on an error. */

/* The table row whose rowid is `rowid`. From the row just after it (a walk down the ids), one step back. */
int btree_seek(btree_cursor *cursor, int64_t rowid);
/* The first entry of an index whose first column, an integer, is at least `key`. */
int btree_seek_at_least(btree_cursor *cursor, int64_t key);
int btree_first(btree_cursor *cursor);
int btree_next(btree_cursor *cursor);

/* The current entry's record, valid until the cursor moves or the transaction writes. NULL (length 0) when the
 * record doesn't lie whole on its page: it spills onto overflow pages, which no row of this schema does. */
const uint8_t *btree_record(btree_cursor *cursor, uint32_t *length);

/* For an index on one integer column: counts[key - lo] += 1 for each entry whose key is in lo...hi (the caller
 * zeroes hi - lo + 1 counts). Decodes a leaf's cells in one go rather than stepping entry by entry. 0 done, -1 an
 * error, 1 an entry not in the form expected (the caller counts another way). */
int btree_count_range(btree_cursor *cursor, int64_t lo, int64_t hi, uint32_t *counts);

#endif
