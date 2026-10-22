/* Synthetic training-database generator for PGO.
 *
 * Creates a tiny SQLite database with exactly the challenge schema
 * (users / posts / likes, see schema.sql) and a few deterministic rows. It
 * exists ONLY so the PGO training workload has a database to serve: the
 * instrumented server must never touch `seed/feed.db` (rule: training is
 * synthetic). It reads no input file and uses no randomness.
 *
 * Source-only: it is compiled by build.sh into `tools/gen_synth_db` (gitignored)
 * and is never linked into the shipped server. SQLite comes from the SAME
 * vendored amalgamation the server uses (vendor/sqlite3.c), never the system
 * library.
 *
 * Usage: gen_synth_db <db-path>
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../vendor/sqlite3.h"

/* Byte-for-byte the schema from schema.sql (fixed: no extra tables/columns). */
static const char *kDdl =
  "CREATE TABLE users ("
  "  id          INTEGER PRIMARY KEY,"
  "  username    TEXT NOT NULL UNIQUE,"
  "  created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))"
  ");"
  "CREATE TABLE posts ("
  "  id          INTEGER PRIMARY KEY,"
  "  user_id     INTEGER NOT NULL REFERENCES users(id),"
  "  body        TEXT NOT NULL CHECK (length(body) BETWEEN 1 AND 500),"
  "  created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))"
  ");"
  "CREATE TABLE likes ("
  "  user_id     INTEGER NOT NULL REFERENCES users(id),"
  "  post_id     INTEGER NOT NULL REFERENCES posts(id),"
  "  created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),"
  "  PRIMARY KEY (user_id, post_id)"
  ");"
  "CREATE INDEX posts_created_at_id_idx ON posts (created_at DESC, id DESC);"
  "CREATE INDEX posts_user_id_idx       ON posts (user_id);"
  "CREATE INDEX likes_post_id_idx       ON likes (post_id);";

static int run(sqlite3 *db, const char *sql) {
  char *err = NULL;
  int rc = sqlite3_exec(db, sql, NULL, NULL, &err);
  if (rc != SQLITE_OK) {
    fprintf(stderr, "sql: %s\n  error: %s\n", sql, err ? err : "(?)");
    sqlite3_free(err);
    return 1;
  }
  return 0;
}

int main(int argc, char **argv) {
  if (argc != 2) {
    fprintf(stderr, "usage: %s <db-path>\n", argv[0]);
    return 2;
  }

  sqlite3 *db = NULL;
  if (sqlite3_open(argv[1], &db) != SQLITE_OK) {
    fprintf(stderr, "cannot open %s: %s\n", argv[1],
            db ? sqlite3_errmsg(db) : "(?)");
    sqlite3_close(db);
    return 1;
  }

  int fail = 0;
  fail |= run(db, "BEGIN");
  fail |= run(db, kDdl);
  fail |= run(db,
      "INSERT INTO users(id, username, created_at) VALUES"
      "(1,'pgo_alice','2026-01-01T00:00:01.000Z'),"
      "(2,'pgo_bob',  '2026-01-01T00:00:02.000Z'),"
      "(3,'pgo_carol','2026-01-01T00:00:03.000Z')");

  /* 30 posts cycled across the three users; deterministic timestamps so the
   * feed ordering (created_at DESC, id DESC) is stable run to run. */
  for (int i = 1; i <= 30; ++i) {
    char sql[256];
    snprintf(sql, sizeof sql,
      "INSERT INTO posts(id, user_id, body, created_at) VALUES"
      "(%d,%d,'pgo synthetic post %d','2026-01-01T00:00:%02d.000Z')",
      i, ((i - 1) % 3) + 1, i, i % 60);
    fail |= run(db, sql);
  }

  /* 60 likes: users 1..3 over posts 1..20 (PK (user_id,post_id) stays unique).
   * created_at is pinned explicitly rather than taking the schema's
   * strftime('now') DEFAULT, so the whole synthetic DB is a pure function of
   * this program (nothing in the training input varies between builds). */
  for (int u = 1; u <= 3; ++u) {
    for (int p = 1; p <= 20; ++p) {
      char sql[200];
      snprintf(sql, sizeof sql,
        "INSERT INTO likes(user_id, post_id, created_at) "
        "VALUES(%d,%d,'2026-01-01T00:00:00.000Z')", u, p);
      fail |= run(db, sql);
    }
  }
  fail |= run(db, "COMMIT");

  if (fail) {
    sqlite3_close(db);
    return 1;
  }

  /* Compact + durable so the trained server reads a stable file. */
  run(db, "PRAGMA journal_mode=DELETE");
  fprintf(stderr, "synthetic training DB written: %s\n", argv[1]);
  sqlite3_close(db);
  return 0;
}
