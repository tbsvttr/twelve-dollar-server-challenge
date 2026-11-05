/* The workload that build.sh profiles the compiler's optimizations on (gcc -fprofile-generate,
 * then -fprofile-use). `bin/server --train <dir>` writes a database of its own made-up rows to
 * <dir>/train.db (no seed data), then runs batches of requests through Feed.batch as the
 * transport would: the user model of bench/load.js (feed, a post from it, sometimes a like or a
 * new post) and some requests the server rejects. Tokens are signed here with a training key.
 * Nothing here runs when the server serves. */
#include <stdio.h>

static u64_t tr_rng = 0x9e3779b97f4a7c15ull;
static u64_t tr_rnd(void) { tr_rng ^= tr_rng << 13; tr_rng ^= tr_rng >> 7; tr_rng ^= tr_rng << 17; return tr_rng; }

#define TR_USERS 5000
#define TR_POSTS 40000
#define TR_LIKES 160000

static void tr_exec(sqlite3 *d, const char *sql) {
  char *err = 0;
  if (sqlite3_exec(d, sql, 0, 0, &err) != SQLITE_OK) { fprintf(stderr, "train: %s: %s\n", sql, err); exit(1); }
}

/* The schema of schema.sql, and made-up rows: increasing timestamps, some text that JSON escapes. */
static void tr_make_db(const char *path) {
  sqlite3 *d;
  unlink(path);
  if (sqlite3_open(path, &d) != SQLITE_OK) { fprintf(stderr, "train: open %s\n", path); exit(1); }
  tr_exec(d, "PRAGMA journal_mode = WAL; BEGIN;"
             "CREATE TABLE users (id INTEGER PRIMARY KEY, username TEXT NOT NULL UNIQUE,"
             " created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')));"
             "CREATE TABLE posts (id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL REFERENCES users(id),"
             " body TEXT NOT NULL CHECK (length(body) BETWEEN 1 AND 500),"
             " created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')));"
             "CREATE TABLE likes (user_id INTEGER NOT NULL REFERENCES users(id), post_id INTEGER NOT NULL REFERENCES posts(id),"
             " created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')), PRIMARY KEY (user_id, post_id));"
             "CREATE INDEX posts_created_at_id_idx ON posts (created_at DESC, id DESC);"
             "CREATE INDEX posts_user_id_idx ON posts (user_id);"
             "CREATE INDEX likes_post_id_idx ON likes (post_id);");
  sqlite3_stmt *u, *p, *l;
  sqlite3_prepare_v2(d, "INSERT INTO users (id, username, created_at) VALUES (?1, ?2, '2026-01-01T00:00:00.000Z')", -1, &u, 0);
  sqlite3_prepare_v2(d, "INSERT INTO posts (id, user_id, body, created_at) VALUES (?1, ?2, ?3, ?4)", -1, &p, 0);
  sqlite3_prepare_v2(d, "INSERT OR IGNORE INTO likes (user_id, post_id, created_at) VALUES (?1, ?2, '2026-01-02T00:00:00.000Z')", -1, &l, 0);
  static const char *words[] = {"lorem", "ipsum", "dolor", "sit", "amet", "the", "quick", "brown", "fox", "jumps",
                                "über", "naïve", "\"quoted\"", "back\\slash", "tab\there", "line\nbreak", "😀", "café"};
  char buf[600];
  for (int i = 1; i <= TR_USERS; i++) {
    snprintf(buf, sizeof buf, "trainee_%d_%llu", i, (unsigned long long)(tr_rnd() % 100000));
    sqlite3_bind_int(u, 1, i);
    sqlite3_bind_text(u, 2, buf, -1, SQLITE_TRANSIENT);
    sqlite3_step(u); sqlite3_reset(u);
  }
  for (int i = 1; i <= TR_POSTS; i++) {
    int n = 0, nw = 3 + (int)(tr_rnd() % 40);
    for (int w = 0; w < nw && n < 400; w++) n += snprintf(buf + n, sizeof buf - (size_t)n, "%s%s", w ? " " : "", words[tr_rnd() % 18]);
    char ts[40];
    long s = i * 7L;
    snprintf(ts, sizeof ts, "2026-03-%02ldT%02ld:%02ld:%02ld.%03dZ", 1 + s / 86400 % 28, s / 3600 % 24, s / 60 % 60, s % 60, (int)(tr_rnd() % 1000));
    sqlite3_bind_int(p, 1, i);
    sqlite3_bind_int(p, 2, 1 + (int)(tr_rnd() % (TR_USERS + 50)));   /* a few authors are missing */
    sqlite3_bind_text(p, 3, buf, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(p, 4, ts, -1, SQLITE_TRANSIENT);
    sqlite3_step(p); sqlite3_reset(p);
  }
  for (int i = 0; i < TR_LIKES; i++) {
    sqlite3_bind_int(l, 1, 1 + (int)(tr_rnd() % TR_USERS));
    sqlite3_bind_int(l, 2, TR_POSTS - (int)(tr_rnd() % (tr_rnd() % 4 ? 3000 : TR_POSTS)));
    sqlite3_step(l); sqlite3_reset(l);
  }
  sqlite3_finalize(u); sqlite3_finalize(p); sqlite3_finalize(l);
  tr_exec(d, "COMMIT; PRAGMA wal_checkpoint(TRUNCATE);");
  sqlite3_close(d);
}

/* base64url of s[0, n) at d (no padding); the length written */
static size_t tr_b64(char *d, const u8_t *s, size_t n) {
  lean_object *a = lean_alloc_sarray(1, n, n);
  memcpy(lean_sarray_cptr(a), s, n);
  lean_object *r = feed_b64_encode(a);
  size_t k = lean_sarray_size(r);
  memcpy(d, lean_sarray_cptr(r), k);
  lean_dec(a); lean_dec(r);
  return k;
}
/* An HS256 token for (uid, name), expiring at exp, signed with key. */
static size_t tr_token(char *out, lean_object *key, int uid, const char *name, long exp) {
  char payload[256];
  int pn = snprintf(payload, sizeof payload, "{\"sub\":\"%d\",\"username\":\"%s\",\"iat\":1700000000,\"exp\":%ld}", uid, name, exp);
  const char *hdr = "{\"alg\":\"HS256\",\"typ\":\"JWT\"}";
  size_t k = tr_b64(out, (const u8_t *)hdr, strlen(hdr));
  out[k++] = '.';
  k += tr_b64(out + k, (const u8_t *)payload, (size_t)pn);
  lean_object *m = lean_alloc_sarray(1, k, k);
  memcpy(lean_sarray_cptr(m), out, k);
  lean_object *mac = feed_hmac_mac(key, m, lean_box(0), lean_box(k));
  out[k++] = '.';
  k += tr_b64(out + k, lean_sarray_cptr(mac), lean_sarray_size(mac));
  lean_dec(m); lean_dec(mac);
  out[k] = 0;
  return k;
}

LEAN_EXPORT lean_obj_res feed_train_run(b_lean_obj_arg dirn) {
  char path[4096];
  snprintf(path, sizeof path, "%s/train.db", lean_string_cstr(dirn));
  tr_make_db(path);
  sqlite3_shutdown();   /* as the server: db_open's settings (the page cache pool and wrapper) apply only to an uninitialized library */
  db_open(path);
  const char *sec = "training-key-not-a-secret";
  lean_object *secret = lean_alloc_sarray(1, strlen(sec), strlen(sec));
  memcpy(lean_sarray_cptr(secret), sec, strlen(sec));
  lean_object *key = feed_make_key(secret);
  static char tok[256][512];
  static char uname[256][64];
  long now = (long)time(0);
  for (int i = 0; i < 256; i++) {
    int uid = 1 + (int)(tr_rnd() % TR_USERS);
    sqlite3_stmt *s;
    sqlite3_prepare_v2(db, "SELECT username FROM users WHERE id = ?1", -1, &s, 0);
    sqlite3_bind_int(s, 1, uid);
    if (sqlite3_step(s) == SQLITE_ROW) snprintf(uname[i], sizeof uname[i], "%s", (const char *)sqlite3_column_text(s, 0));
    sqlite3_finalize(s);
    tr_token(tok[i], key, uid, uname[i], i == 255 ? now - 10 : now + 3600);   /* one expired */
  }
  u64_t maxid = TR_POSTS;
  char req[2048], body[600];
  for (int it = 0; it < 1500; it++) {
    int batch = 8 + (int)(tr_rnd() % 120);
    lean_object *arr = lean_alloc_array(0, (size_t)batch);
    for (int k = 0; k < batch; k++) {
      u64_t x = tr_rnd() % 1000;
      int t = (int)(tr_rnd() % 256), n;
      u64_t pid = maxid - tr_rnd() % 3000;
      if (x < 450) n = snprintf(req, sizeof req, "GET /feed HTTP/1.1\r\nHost: 10.0.0.1\r\nUser-Agent: train\r\n\r\n");
      else if (x < 900) n = snprintf(req, sizeof req, "GET /posts/%llu HTTP/1.1\r\nHost: 10.0.0.1\r\nUser-Agent: train\r\n\r\n", (unsigned long long)pid);
      else if (x < 970) n = snprintf(req, sizeof req, "POST /posts/%llu/like HTTP/1.1\r\nHost: 10.0.0.1\r\nContent-Length: 0\r\nAuthorization: Bearer %s\r\nContent-Type: application/json\r\n\r\n", (unsigned long long)pid, tok[t]);
      else if (x < 985) {
        int bl = snprintf(body, sizeof body, "{\"body\":\"%s says hi at 2026-11-01T00:00:00.000Z (VU %d, iter %d)\"}", uname[t], t, it);
        n = snprintf(req, sizeof req, "POST /posts HTTP/1.1\r\nHost: 10.0.0.1\r\nContent-Length: %d\r\nAuthorization: Bearer %s\r\nContent-Type: application/json\r\n\r\n%s", bl, tok[t], body);
      } else if (x < 988) n = snprintf(req, sizeof req, "GET /health HTTP/1.1\r\nHost: 10.0.0.1\r\n\r\n");
      else if (x < 991) n = snprintf(req, sizeof req, "GET /posts/abc HTTP/1.1\r\nHost: 10.0.0.1\r\n\r\n");
      else if (x < 994) n = snprintf(req, sizeof req, "POST /posts/%llu/like HTTP/1.1\r\nHost: 10.0.0.1\r\nContent-Length: 0\r\nAuthorization: Bearer %.40sxx\r\n\r\n", (unsigned long long)pid, tok[t]);
      else if (x < 997) n = snprintf(req, sizeof req, "POST /posts HTTP/1.1\r\nHost: 10.0.0.1\r\nContent-Length: 9\r\nAuthorization: Bearer %s\r\n\r\n{\"body\":1", tok[t]);
      else n = snprintf(req, sizeof req, "GET /nope HTTP/1.1\r\nHost: 10.0.0.1\r\n\r\n");
      lean_object *b = lean_alloc_sarray(1, 0, (size_t)n + 512);
      memcpy(lean_sarray_cptr(b), req, (size_t)n);
      lean_to_sarray(b)->m_size = (size_t)n;
      arr = lean_array_push(arr, b);
    }
    lean_inc(key);
    lean_object *res = feed_batch(arr, (u64_t)time(0), (u64_t)it, (uint8_t)(it % 4 == 0), key);
    if (!lean_io_result_is_ok(res)) { lean_io_result_show_error(res); exit(1); }
    lean_object *reps = lean_io_result_get_value(res);
    for (size_t i = 0; i < lean_array_size(reps); i++) {
      lean_object *rep = lean_ctor_get(lean_array_get_core(reps, i), 0);
      if (lean_sarray_size(rep) > 20 && !memcmp(lean_sarray_cptr(rep), "HTTP/1.1 201 Created", 20) &&
          memmem(lean_sarray_cptr(rep), lean_sarray_size(rep), "{\"post\":", 8)) maxid++;
    }
    lean_dec(res);
  }
  fprintf(stderr, "train: done\n");
  return lean_io_result_mk_ok(lean_box_uint32(0));
}
