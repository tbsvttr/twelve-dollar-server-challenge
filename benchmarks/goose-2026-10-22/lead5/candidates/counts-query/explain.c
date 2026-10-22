#include "sqlite3.h"
#include <stdio.h>
int main(int argc, char **argv) {
    sqlite3 *db = NULL;
    sqlite3_stmt *stmt = NULL;
    if (argc != 2 || sqlite3_open_v2(argv[1], &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) return 1;
    puts(sqlite3_libversion());
    const char *sql = "EXPLAIN QUERY PLAN SELECT post_id,count(*) FROM likes WHERE post_id>=?1 AND post_id<=?2 GROUP BY post_id ORDER BY post_id";
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) != SQLITE_OK) {
        fprintf(stderr, "prepare failed: %s\n", sqlite3_errmsg(db));
        sqlite3_close(db);
        return 2;
    }
    int rc;
    while ((rc = sqlite3_step(stmt)) == SQLITE_ROW) puts((const char *)sqlite3_column_text(stmt, 3));
    sqlite3_finalize(stmt);
    sqlite3_close(db);
    return rc == SQLITE_DONE ? 0 : 3;
}
