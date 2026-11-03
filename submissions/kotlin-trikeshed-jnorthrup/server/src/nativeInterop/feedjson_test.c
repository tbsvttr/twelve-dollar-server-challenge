/*
 * The C the feed's rows are written with, held to byte-wise references:
 *   feed_json_text  one text column as a JSON string body, by Out.escapeFrom's rules: quote and backslash get a backslash,
 *                   \b \f \n \r \t keep their letters, the other bytes below 0x20 become \u00XX (lower-case hex), every
 *                   other byte (UTF-8, DEL) is copied (feedbt.c, with feed_i64)
 *   feed_row_json   one row of POST_SELECT as the feed's JSON object, read from SQLite itself (cinterop/feedc.def)
 * Both functions are cut out of the files that hold them, so the test runs the shipped source.
 *
 *   cd server/src/nativeInterop
 *   { awk '/BEGIN feed_json_text/,/END feed_json_text/' feedbt.c; awk '/BEGIN feed_row_json/,/END feed_row_json/' cinterop/feedc.def; } > /tmp/feed_json.h
 *   cc -O2 -fsanitize=address -I/tmp -o /tmp/feedjson_test feedjson_test.c -lsqlite3 && /tmp/feedjson_test
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sqlite3.h>
#include "feed_json.h"

static int expected(const unsigned char *s, int n, char *d) {
  static const char hex[] = "0123456789abcdef";
  int w = 0;
  for (int i = 0; i < n; i++) {
    unsigned c = s[i];
    if (c == '"') { d[w++] = '\\'; d[w++] = '"'; }
    else if (c == '\\') { d[w++] = '\\'; d[w++] = '\\'; }
    else if (c >= 0x20) d[w++] = (char)c;
    else if (c == 0x08) { d[w++] = '\\'; d[w++] = 'b'; }
    else if (c == 0x0C) { d[w++] = '\\'; d[w++] = 'f'; }
    else if (c == 0x0A) { d[w++] = '\\'; d[w++] = 'n'; }
    else if (c == 0x0D) { d[w++] = '\\'; d[w++] = 'r'; }
    else if (c == 0x09) { d[w++] = '\\'; d[w++] = 't'; }
    else { d[w++] = '\\'; d[w++] = 'u'; d[w++] = '0'; d[w++] = '0'; d[w++] = hex[c >> 4]; d[w++] = hex[c & 15]; }
  }
  return w;
}

static unsigned long long cases;

static void fail(const unsigned char *s, int n, const char *want, int wn, const char *got, int gn, const char *why) {
  printf("FAIL (%s) after %llu cases, n=%d\n input:", why, cases, n);
  for (int i = 0; i < n && i < 64; i++) printf(" %02x", s[i]);
  printf("\n want(%d): %.*s\n got (%d): %.*s\n", wn, wn, want, gn, gn, got);
  exit(1);
}

static void check(const unsigned char *s, int n) {
  static char want[4096], got[4096];
  int wn = expected(s, n, want);
  memset(got, 0xEE, sizeof got);
  /* An exact-size heap copy, so a read past the end of the input aborts under -fsanitize=address. */
  unsigned char *exact = malloc(n ? (size_t)n : 1);
  memcpy(exact, s, (size_t)n);
  int gn = feed_json_text(exact, n, got);
  free(exact);
  cases++;
  if (gn != wn) fail(s, n, want, wn, got, gn < 0 ? 0 : gn, "length");
  if (memcmp(got, want, (size_t)wn) != 0) fail(s, n, want, wn, got, gn, "bytes");
  for (int i = wn; i < wn + 16; i++) if ((unsigned char)got[i] != 0xEE) fail(s, n, want, wn, got, gn, "wrote past the returned length");
}

static unsigned long long rng = 0x9E3779B97F4A7C15ULL;
static unsigned next(void) { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return (unsigned)(rng >> 16); }

static const unsigned char heavy[] = { 0x00, 0x08, 0x09, 0x0A, 0x0C, 0x0D, 0x1F, 0x22, 0x5C, 0x7F };

/* len bytes of one kind: 0 uniform bytes, 1 and 2 letters with escape-heavy bytes mixed in (1 often, 2 rarely), 3 letters,
 * 4 only escape-heavy bytes, 5 only bytes that grow six-fold (\u00XX): the worst case the room bound must cover. */
static void fill(unsigned char *s, int len, unsigned kind) {
  for (int i = 0; i < len; i++) {
    unsigned r = next();
    s[i] = kind == 0 ? (unsigned char)r
         : kind == 1 ? ((r & 3) == 0 ? heavy[(r >> 2) % sizeof heavy] : (unsigned char)('a' + (r >> 8) % 26))
         : kind == 2 ? ((r & 31) == 0 ? heavy[(r >> 5) % sizeof heavy] : (unsigned char)('a' + (r >> 8) % 26))
         : kind == 3 ? (unsigned char)('a' + (r >> 8) % 26)
         : kind == 4 ? heavy[(r >> 2) % sizeof heavy]
         : (unsigned char)(1 + (r >> 8) % 7);
  }
}

static void text_tests(void) {
  static const unsigned char fillers[] = { 'a', 0xC3, 0x7F, 0x20, 0x21, 0x23, 0x1F, 0x5B, 0x5D, 0xA2, 0xDC, 0x80, 0xFF };
  unsigned char s[512];
  /* Every byte value at every position of every short length, against fillers next to the escaped values. */
  for (int v = 0; v < 256; v++)
    for (int len = 1; len <= 40; len++)
      for (int pos = 0; pos < len; pos++)
        for (unsigned f = 0; f < sizeof fillers; f++) {
          memset(s, fillers[f], (size_t)len);
          s[pos] = (unsigned char)v;
          check(s, len);
        }
  /* Empty and spot values. */
#define SPOT(lit) check((const unsigned char *)(lit), (int)sizeof(lit) - 1)
  SPOT("");
  SPOT("plain text, no escapes at all, longer than one eight-byte step");
  SPOT("say \"hi\" \\ there\n\t\r\b\f\x01\x1f caf\xC3\xA9 \xE2\x9C\x93");
  SPOT("\"");
  SPOT("\\\\\\\\\\\\\\\\\\");
  /* Random strings up to 300 bytes. */
  for (int round = 0; round < 3000000; round++) {
    int len = (int)(next() % 301);
    fill(s, len, next() % 4);
    check(s, len);
  }
}

/* ---- feed_row_json against SQLite ---- */

static const char *POST_SELECT = /* the same text as POST_SELECT in SqliteStore.linux.kt */
    "SELECT p.id, p.body, p.created_at, u.username, "
    "(SELECT count(*) FROM likes l WHERE l.post_id = p.id) FROM posts p JOIN users u ON u.id = p.user_id";

static void sql(sqlite3 *db, const char *text) {
  char *err = NULL;
  if (sqlite3_exec(db, text, 0, 0, &err) != SQLITE_OK) { printf("sql failed: %s: %s\n", text, err); exit(1); }
}

static void put_post(sqlite3_stmt *ins, long long id, long long user, const unsigned char *body, int bn, const unsigned char *created, int cn) {
  sqlite3_reset(ins);
  sqlite3_bind_int64(ins, 1, id);
  sqlite3_bind_int64(ins, 2, user);
  if (body) sqlite3_bind_text(ins, 3, (const char *)body, bn, SQLITE_STATIC); else sqlite3_bind_null(ins, 3);
  if (created) sqlite3_bind_text(ins, 4, (const char *)created, cn, SQLITE_STATIC); else sqlite3_bind_null(ins, 4);
  if (sqlite3_step(ins) != SQLITE_DONE) { printf("insert failed for id %lld\n", id); exit(1); }
}

static void row_fail(const char *why, const char *want, int wn, const char *got, int gn) {
  printf("FAIL row (%s) after %llu cases\n want(%d): %.*s\n got (%d): %.*s\n", why, cases, wn, wn > 300 ? 300 : wn, want, gn, gn > 300 ? 300 : gn, got);
  exit(1);
}

static void row_check(sqlite3_stmt *s) {
  const unsigned char *b = sqlite3_column_text(s, 1); int bn = sqlite3_column_bytes(s, 1);
  const unsigned char *c = sqlite3_column_text(s, 2); int cn = sqlite3_column_bytes(s, 2);
  const unsigned char *a = sqlite3_column_text(s, 3); int an = sqlite3_column_bytes(s, 3);
  char *want = malloc(256 + 6 * (size_t)(bn + cn + an));
  int w = sprintf(want, "{\"id\":%lld,\"body\":\"", (long long)sqlite3_column_int64(s, 0));
  w += expected(b, bn, want + w);
  w += sprintf(want + w, "\",\"created_at\":\"");
  w += expected(c, cn, want + w);
  w += sprintf(want + w, "\",\"author\":\"");
  w += expected(a, an, want + w);
  w += sprintf(want + w, "\",\"like_count\":%lld}", (long long)sqlite3_column_int64(s, 4));
  char dummy;
  int need = -feed_row_json(s, &dummy, 0);                 /* room asked for, nothing written */
  if (need < w) row_fail("room asked for is below the row", want, w, "", 0);
  char *dst = malloc((size_t)need);                        /* exact size: a write past the stated room aborts under ASAN */
  int gn = feed_row_json(s, dst, need);
  if (gn != w || memcmp(dst, want, (size_t)w) != 0) row_fail("bytes", want, w, dst, gn < 0 ? 0 : gn);
  if (feed_row_json(s, dst, need - 1) != -need) row_fail("one byte short must ask for the same room", want, w, dst, 0);
  free(dst);
  char *big = malloc((size_t)need + 32);                   /* a larger buffer: nothing is touched past the returned length */
  memset(big, 0xEE, (size_t)need + 32);
  gn = feed_row_json(s, big, need + 32);
  for (int i = gn; i < need + 32; i++) if ((unsigned char)big[i] != 0xEE) row_fail("wrote past the returned length", want, w, big, gn);
  free(big);
  free(want);
  cases++;
}

static void row_tests(void) {
  sqlite3 *db;
  if (sqlite3_open(":memory:", &db) != SQLITE_OK) { printf("sqlite3_open failed\n"); exit(1); }
  sql(db, "CREATE TABLE users (id INTEGER PRIMARY KEY, username TEXT);"
          "CREATE TABLE posts (id INTEGER PRIMARY KEY, user_id INTEGER, body TEXT, created_at TEXT);"
          "CREATE TABLE likes (user_id INTEGER, post_id INTEGER, PRIMARY KEY (user_id, post_id));"
          "INSERT INTO users VALUES (1, 'ann'), (2, 'b\"o\\b'), (3, 'caf\xC3\xA9 \xE2\x9C\x93'), (4, ''), (5, NULL), (6, 'tab\tnl\n');");
  sqlite3_stmt *ins;
  sqlite3_prepare_v2(db, "INSERT INTO posts (id, user_id, body, created_at) VALUES (?1, ?2, ?3, ?4)", -1, &ins, NULL);
  static const long long ids[] = { 0, 1, -1, 9, 10, 99999, 123456789012LL, 9223372036854775807LL, -9223372036854775807LL - 1 };
  for (unsigned i = 0; i < sizeof ids / sizeof ids[0]; i++)
    put_post(ins, ids[i], 1 + (long long)(i % 6), (const unsigned char *)"plain", 5, (const unsigned char *)"2026-11-01 13:00:00", 19);
  put_post(ins, 20, 1, NULL, 0, NULL, 0);                                      /* NULL body and created_at */
  put_post(ins, 21, 2, (const unsigned char *)"", 0, (const unsigned char *)"", 0);  /* empty strings */
  unsigned char body[6000], created[64];
  for (int i = 0; i < 3000; i++) {
    int bn = (int)(next() % 301), cn = 19 + (int)(next() % 3);
    fill(body, bn, next() % 5);
    fill(created, cn, next() % 4 == 0 ? 2 : 3);
    put_post(ins, 1000 + i, 1 + (long long)(next() % 6), body, bn, created, cn);
  }
  fill(body, 5000, 4);                                                         /* 5,000 bytes that mostly expand */
  put_post(ins, 5000, 2, body, 5000, (const unsigned char *)"2026-11-01 13:00:00", 19);
  fill(body, 5000, 5);                                                         /* 5,000 bytes that all grow six-fold: the room bound */
  fill(created, 40, 5);
  put_post(ins, 5001, 6, body, 5000, created, 40);
  sqlite3_finalize(ins);
  sql(db, "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 1201) INSERT INTO likes SELECT 100 + i, 1000 FROM n;"
          "INSERT INTO likes VALUES (1, 1001), (2, 1001), (3, 1001), (1, 1002), (1, 5000);");
  sqlite3_stmt *s;
  if (sqlite3_prepare_v2(db, POST_SELECT, -1, &s, NULL) != SQLITE_OK) { printf("prepare failed: %s\n", sqlite3_errmsg(db)); exit(1); }
  int rows = 0;
  while (sqlite3_step(s) == SQLITE_ROW) { row_check(s); rows++; }
  sqlite3_finalize(s);
  sqlite3_close(db);
  printf("feed_row_json: %d rows\n", rows);
}

int main(void) {
  text_tests();
  printf("feed_json_text: %llu cases\n", cases);
  row_tests();
  printf("feedjson ok: %llu cases\n", cases);
  return 0;
}
