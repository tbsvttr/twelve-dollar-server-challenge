/*
 * feedbt_test.c: the B-tree read plans (feedbt.c) against the SQL path, byte for byte, on a copy of the seed, then both
 * timed. The SQL path is the server's: POST_SELECT and feed_row_json (cut out of feedc.def).
 *
 *   cd server/src/nativeInterop
 *   awk '/BEGIN feed_row_json/,/END feed_row_json/' cinterop/feedc.def > /tmp/feed_json.h
 *   cc -O2 -I/tmp -I<dir of sqlite3.c> -DSQLITE_THREADSAFE=0 -DSQLITE_DEFAULT_MEMSTATUS=0 -DSQLITE_OMIT_LOAD_EXTENSION \
 *      -o /tmp/feedbt_test feedbt_test.c -lm && /tmp/feedbt_test <copy of seed/feed.db>
 */
#include "feedbt.c" /* first: the amalgamation defines _GNU_SOURCE before any system header */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "feed_json.h"

#define POST_SELECT "SELECT p.id, p.body, p.created_at, u.username, " \
    "(SELECT count(*) FROM likes l WHERE l.post_id = p.id) FROM posts p JOIN users u ON u.id = p.user_id"

static sqlite3 *db;
static sqlite3_stmt *feedStmt, *postStmt;
static long checks, fallbacks;

static void exec1(const char *sql) {
  char *err = NULL;
  feedbt_release(); /* as the server's step(): SQL never runs inside the wake's held read */
  if (sqlite3_exec(db, sql, 0, 0, &err) != SQLITE_OK) { printf("sql failed: %s: %s\n", sql, err); exit(1); }
}

/* The server's SQL feed: {"posts":[row,row,...]} */
static int sql_feed(char *dst) {
  int w = 0, first = 1;
  feedbt_release();
  memcpy(dst, "{\"posts\":[", 10); w = 10;
  while (sqlite3_step(feedStmt) == SQLITE_ROW) {
    if (!first) dst[w++] = ',';
    first = 0;
    w += feed_row_json(feedStmt, dst + w, 1 << 20);
  }
  sqlite3_reset(feedStmt);
  memcpy(dst + w, "]}", 2);
  return w + 2;
}

/* The server's SQL post: {"post":row}, or 0 when absent */
static int sql_post(long long id, char *dst) {
  feedbt_release();
  sqlite3_bind_int64(postStmt, 1, id);
  int w = 0;
  if (sqlite3_step(postStmt) == SQLITE_ROW) {
    memcpy(dst, "{\"post\":", 8); w = 8;
    w += feed_row_json(postStmt, dst + w, 1 << 20);
    dst[w++] = '}';
  }
  sqlite3_reset(postStmt);
  return w;
}

static char want[1 << 21], got[1 << 21];

static void same(const char *what, int wn, int gn) {
  checks++;
  if (gn == -1) { fallbacks++; return; }   /* the plan declined: the server runs SQL, which is the reference itself */
  if (gn != wn || memcmp(want, got, (size_t)wn) != 0) {
    printf("FAIL %s: want %d bytes, got %d\n want: %.300s\n got:  %.300s\n", what, wn, gn, want, gn > 0 ? got : "");
    exit(1);
  }
}

static void check_feed(const char *what) {
  int wn = sql_feed(want);
  same(what, wn, feedbt_feed(got, sizeof got));
}

static void check_post(long long id) {
  char what[64];
  snprintf(what, sizeof what, "post %lld", id);
  int wn = sql_post(id, want);
  same(what, wn, feedbt_post(id, got, sizeof got));
}

static void check_posts(const char *what, int random) {
  static const long long edge[] = { 0, -1, 1, 2, 3, 1000, 250000, 499990, 499999, 500000, 500001, 500002, 500010,
                                    999999999, -9223372036854775807LL - 1, 9223372036854775807LL };
  for (unsigned i = 0; i < sizeof edge / sizeof edge[0]; i++) check_post(edge[i]);
  unsigned long long x = 0x9E3779B97F4A7C15ULL;
  for (int i = 0; i < random; i++) { x = x * 6364136223846793005ULL + 1442695040888963407ULL; check_post(1 + (long long)((x >> 33) % 500020)); }
  printf("  %-48s ok (%ld checks so far, %ld declined)\n", what, checks, fallbacks);
}

static double now_ns(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1e9 + t.tv_nsec; }

int main(int argc, char **argv) {
  if (argc < 2) { printf("usage: feedbt_test <copy of feed.db>\n"); return 2; }
  if (sqlite3_open_v2(argv[1], &db, SQLITE_OPEN_READWRITE, NULL) != SQLITE_OK) { printf("open failed\n"); return 1; }
  exec1("PRAGMA locking_mode=EXCLUSIVE"); exec1("PRAGMA journal_mode=WAL"); exec1("PRAGMA synchronous=NORMAL");
  exec1("PRAGMA mmap_size=1073741824"); exec1("PRAGMA cache_size=-16384");
  sqlite3_prepare_v2(db, POST_SELECT " ORDER BY p.created_at DESC, p.id DESC LIMIT 20", -1, &feedStmt, NULL);
  sqlite3_prepare_v2(db, POST_SELECT " WHERE p.id = ?1", -1, &postStmt, NULL);
  if (!feedbt_init(db)) { printf("FAIL feedbt_init declined the seed schema\n"); return 1; }

  printf("== correctness against the SQL path\n");
  check_feed("seed feed"); check_posts("seed: feed and posts", 2000);

  exec1("INSERT INTO likes (user_id, post_id) SELECT id, 499995 FROM users WHERE id <= 300");
  exec1("INSERT INTO posts (user_id, body) VALUES (7, 'say \"hi\" \\ there' || char(10) || char(9) || char(1) || ' caf' || char(233) || ' ' || char(10003))");
  exec1("INSERT INTO posts (user_id, body) VALUES (8, printf('%.*c', 500, 'x'))");
  check_feed("new posts, 300 likes"); check_posts("new posts, 300 likes", 200);

  exec1("BEGIN IMMEDIATE");
  exec1("INSERT INTO posts (user_id, body) VALUES (9, 'inside an open write transaction')");
  exec1("INSERT INTO likes (user_id, post_id) VALUES (1, 500003), (2, 500003)");
  check_feed("inside an open write transaction"); check_posts("inside an open write transaction", 100);
  exec1("COMMIT");

  exec1("UPDATE posts SET created_at = '2099-01-01T00:00:00.000Z' WHERE id IN (7, 123456)");
  check_feed("ids not ordered (per-id path)"); check_posts("ids not ordered", 100);
  long before = fallbacks;
  check_feed("ids not ordered, again");
  if (fallbacks != before) { printf("FAIL the per-id path declined a feed it can serve\n"); return 1; }
  exec1("UPDATE posts SET created_at = '2020-01-01T00:00:00.000Z' WHERE id IN (7, 123456)");

  /* The 20 newest ids spanning exactly 63 (range scans) and exactly 64 (one past the arrays: sought one by one). */
  sqlite3_stmt *mx;
  sqlite3_prepare_v2(db, "SELECT max(id) FROM posts", -1, &mx, NULL);
  feedbt_release();
  sqlite3_step(mx);
  long long hi = sqlite3_column_int64(mx, 0);
  sqlite3_finalize(mx);
  for (int span = 63; span <= 64; span++) {
    char sql[160], what[64];
    snprintf(sql, sizeof sql, "UPDATE posts SET created_at = '2098-01-01T00:00:00.000Z' WHERE id = %lld", hi - span);
    exec1(sql);
    exec1("INSERT INTO likes (user_id, post_id) SELECT id, (SELECT max(id) FROM posts) - 63 FROM users WHERE id BETWEEN 400 AND 410");
    snprintf(what, sizeof what, "the 20 newest ids span %d", span);
    check_feed(what);
    snprintf(sql, sizeof sql, "UPDATE posts SET created_at = '2020-01-01T00:00:00.000Z' WHERE id = %lld", hi - span);
    exec1(sql);
    exec1("DELETE FROM likes WHERE user_id BETWEEN 400 AND 410 AND post_id = (SELECT max(id) FROM posts) - 63");
  }
  printf("  %-48s ok\n", "the 20 newest ids span 63 and 64");

  { /* one wake: held reads agree with each other; the write between wakes is seen by the next wake */
    static char a[1 << 16], b2[1 << 16];
    int na = feedbt_feed(a, sizeof a), nb = feedbt_feed(b2, sizeof b2), np = feedbt_post(500001, b2 + nb, (int)sizeof b2 - nb);
    if (na <= 0 || na != nb || memcmp(a, b2, (size_t)na) || np <= 0) { printf("FAIL reads inside one wake differ\n"); return 1; }
    exec1("INSERT INTO posts (user_id, body) VALUES (3, 'wake-2 post')");
    feedbt_release();
    check_feed("the next wake after a write");
    if (!memmem(got, (size_t)feedbt_feed(got, sizeof got), "wake-2 post", 11)) { printf("FAIL the next wake misses the write\n"); return 1; }
    printf("  %-48s ok\n", "held reads in a wake, the write seen next wake");
  }

  exec1("UPDATE users SET username = 'q\"u' || char(10) || 'x' WHERE id = 7");
  check_feed("an author name with escapes"); check_posts("an author name with escapes", 50);

  int small = feedbt_feed(got, 100);
  if (small >= 0 || small == -1) { printf("FAIL a 100-byte buffer must ask for room (got %d)\n", small); return 1; }
  char *exact = malloc((size_t)-small); /* exactly the asked room: a write past it aborts under -fsanitize=address */
  int again = feedbt_feed(exact, -small);
  int wn = sql_feed(want);
  if (again != wn || memcmp(want, exact, (size_t)wn)) { printf("FAIL one retry with the asked room (%d) must give the SQL bytes (got %d)\n", -small, again); return 1; }
  free(exact);
  small = feedbt_post(500001, got, 20);
  exact = malloc((size_t)-small);
  again = feedbt_post(500001, exact, -small);
  wn = sql_post(500001, want);
  if (small >= -1 || again != wn || memcmp(want, exact, (size_t)wn)) { printf("FAIL a short post buffer: asked %d, retry %d\n", -small, again); return 1; }
  free(exact);
  printf("  %-48s ok\n", "a short buffer asks once for the exact room");

  exec1("PRAGMA foreign_keys=OFF");
  exec1("DELETE FROM users WHERE id = 8");
  int gn = feedbt_feed(got, sizeof got);
  wn = sql_feed(want);
  checks++;
  if (gn != -1 && (gn != wn || memcmp(want, got, (size_t)wn))) { printf("FAIL feed with a missing author: got %d, want -1 or the SQL bytes\n", gn); return 1; }
  if (gn == -1) fallbacks++;
  check_posts("a missing author", 50);
  printf("correctness: %ld checks, %ld declined to SQL\n", checks, fallbacks);

  printf("== timing (this database, after the edits)\n");
  exec1("PRAGMA foreign_keys=ON");
  exec1("UPDATE posts SET created_at = strftime('%Y-%m-%dT%H:%M:%fZ', '2020-01-01') WHERE id IN (7, 123456)");
  exec1("INSERT INTO users (id, username) VALUES (8, 'feedbt-test-user-8')");
  int R = 20000; double t0, t1; volatile long sink = 0;
  for (int pass = 0; pass < 2; pass++) {
    t0 = now_ns(); for (int i = 0; i < R; i++) sink += sql_feed(want); t1 = now_ns();
    double a = (t1 - t0) / R;
    t0 = now_ns(); for (int i = 0; i < R; i++) { sink += feedbt_feed(got, sizeof got); feedbt_release(); } t1 = now_ns();
    double b = (t1 - t0) / R;
    t0 = now_ns(); for (int i = 0; i < R; i++) { sink += feedbt_feed(got, sizeof got); if (i % 20 == 19) feedbt_release(); } t1 = now_ns();
    double bw = (t1 - t0) / R;
    t0 = now_ns(); for (int i = 0; i < R; i++) sink += sql_post(500000 - i % 20, want); t1 = now_ns();
    double c = (t1 - t0) / R;
    t0 = now_ns(); for (int i = 0; i < R; i++) { sink += feedbt_post(500000 - i % 20, got, sizeof got); feedbt_release(); } t1 = now_ns();
    double d = (t1 - t0) / R;
    t0 = now_ns(); for (int i = 0; i < R; i++) { sink += feedbt_post(500000 - i % 20, got, sizeof got); if (i % 20 == 19) feedbt_release(); } t1 = now_ns();
    double dw = (t1 - t0) / R;
    if (pass) printf("GET /feed: SQL %.2f us, B-tree %.2f us, 20 per wake %.2f us   GET /posts/:id: SQL %.2f us, B-tree %.2f us, 20 per wake %.2f us\n",
                     a / 1000, b / 1000, bw / 1000, c / 1000, d / 1000, dw / 1000);
  }
  printf("feedbt ok\n");
  return 0;
}
