/* Ruby bindings to SQLite: the few SQL calls the server needs, and the two read endpoints rendered from
 * SQLite's own B-tree cursor API. The pinned, unmodified amalgamation is compiled in with SQLITE_PRIVATE
 * empty so its internal B-tree functions are visible. Ruby decides when cursors open and close (which
 * transaction they read in); this file walks them and writes the JSON. One connection, one thread: no
 * GVL release. */
#include "sqlite3.c"
#include <ruby.h>

static VALUE eError;

static void raise_db(sqlite3 *db, int rc) {
  rb_raise(eError, "%s (%d)", db ? sqlite3_errmsg(db) : sqlite3_errstr(rc), rc);
}

/* --- Lite::DB ------------------------------------------------------------------------------------ */

typedef struct { sqlite3 *db; Btree *bt; } DB;

static void db_free(void *p) {
  DB *d = p;
  if (d->db) sqlite3_close_v2(d->db);
  xfree(d);
}
static const rb_data_type_t db_type = {"Lite::DB", {0, db_free, 0}, 0, 0, RUBY_TYPED_FREE_IMMEDIATELY};

static DB *get_db(VALUE self) {
  DB *d;
  TypedData_Get_Struct(self, DB, &db_type, d);
  if (!d->db) rb_raise(eError, "database is closed");
  return d;
}

static VALUE db_alloc(VALUE klass) {
  DB *d;
  VALUE self = TypedData_Make_Struct(klass, DB, &db_type, d);
  return self;
}

static VALUE db_initialize(VALUE self, VALUE path) {
  DB *d;
  TypedData_Get_Struct(self, DB, &db_type, d);
  int rc = sqlite3_open_v2(StringValueCStr(path), &d->db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, NULL);
  if (rc != SQLITE_OK) raise_db(d->db, rc);
  d->bt = sqlite3DbNameToBtree(d->db, "main");
  return self;
}

/* Closes the connection once its statements are finalized (sqlite3_close_v2 defers until then). */
static VALUE db_close(VALUE self) {
  DB *d;
  TypedData_Get_Struct(self, DB, &db_type, d);
  if (d->db) sqlite3_close_v2(d->db);
  d->db = NULL;
  return Qnil;
}

/* Runs one or more statements, discarding rows. */
static VALUE db_exec(VALUE self, VALUE sql) {
  DB *d = get_db(self);
  int rc = sqlite3_exec(d->db, StringValueCStr(sql), NULL, NULL, NULL);
  if (rc != SQLITE_OK) raise_db(d->db, rc);
  return Qnil;
}

static VALUE db_in_transaction(VALUE self) {
  return sqlite3_get_autocommit(get_db(self)->db) ? Qfalse : Qtrue;
}

static VALUE db_changes(VALUE self) {
  return INT2FIX(sqlite3_changes(get_db(self)->db));
}

/* Opens (sqlite3BtreeBeginTrans) and ends (sqlite3BtreeCommit) a read transaction on the main B-tree.
 * Pages still come through SQLite's pager, WAL and page cache. */
static VALUE db_begin_read(VALUE self) {
  DB *d = get_db(self);
  int rc = sqlite3BtreeBeginTrans(d->bt, 0, NULL);
  if (rc != SQLITE_OK) raise_db(d->db, rc);
  return Qnil;
}

static VALUE db_end_read(VALUE self) {
  DB *d = get_db(self);
  int rc = sqlite3BtreeCommit(d->bt);
  if (rc != SQLITE_OK) raise_db(d->db, rc);
  return Qnil;
}

/* --- Lite::Stmt ---------------------------------------------------------------------------------- */

typedef struct { sqlite3_stmt *stmt; VALUE db; } Stmt;

static void stmt_mark(void *p) { rb_gc_mark(((Stmt *)p)->db); }
static void stmt_free(void *p) {
  Stmt *s = p;
  if (s->stmt) sqlite3_finalize(s->stmt);
  xfree(s);
}
static const rb_data_type_t stmt_type = {"Lite::Stmt", {stmt_mark, stmt_free, 0}, 0, 0, RUBY_TYPED_FREE_IMMEDIATELY};

static Stmt *get_stmt(VALUE self) {
  Stmt *s;
  TypedData_Get_Struct(self, Stmt, &stmt_type, s);
  return s;
}

static VALUE db_prepare(VALUE self, VALUE sql) {
  DB *d = get_db(self);
  Stmt *s;
  VALUE stmt = TypedData_Make_Struct(rb_path2class("Lite::Stmt"), Stmt, &stmt_type, s);
  s->db = self;
  int rc = sqlite3_prepare_v3(d->db, StringValuePtr(sql), (int)RSTRING_LEN(sql), SQLITE_PREPARE_PERSISTENT,
                              &s->stmt, NULL);
  if (rc != SQLITE_OK) raise_db(d->db, rc);
  return stmt;
}

static VALUE stmt_bind_int(VALUE self, VALUE i, VALUE v) {
  Stmt *s = get_stmt(self);
  int rc = sqlite3_bind_int64(s->stmt, FIX2INT(i), NUM2LL(v));
  if (rc != SQLITE_OK) raise_db(sqlite3_db_handle(s->stmt), rc);
  return self;
}

static VALUE stmt_bind_text(VALUE self, VALUE i, VALUE v) {
  Stmt *s = get_stmt(self);
  StringValue(v);
  int rc = sqlite3_bind_text(s->stmt, FIX2INT(i), RSTRING_PTR(v), (int)RSTRING_LEN(v), SQLITE_TRANSIENT);
  if (rc != SQLITE_OK) raise_db(sqlite3_db_handle(s->stmt), rc);
  return self;
}

/* true for a row, false when done. */
static VALUE stmt_step(VALUE self) {
  Stmt *s = get_stmt(self);
  int rc = sqlite3_step(s->stmt);
  if (rc == SQLITE_ROW) return Qtrue;
  if (rc == SQLITE_DONE) return Qfalse;
  sqlite3_reset(s->stmt);
  raise_db(sqlite3_db_handle(s->stmt), rc);
  return Qnil;
}

static VALUE stmt_reset(VALUE self) {
  sqlite3_reset(get_stmt(self)->stmt);
  return self;
}

static VALUE stmt_text(VALUE self, VALUE i) {
  Stmt *s = get_stmt(self);
  const unsigned char *t = sqlite3_column_text(s->stmt, FIX2INT(i));
  if (!t) return Qnil;
  return rb_utf8_str_new((const char *)t, sqlite3_column_bytes(s->stmt, FIX2INT(i)));
}

static VALUE stmt_int(VALUE self, VALUE i) {
  return LL2NUM(sqlite3_column_int64(get_stmt(self)->stmt, FIX2INT(i)));
}

/* --- Lite::Cursor: sqlite3Btree* on one table or index ------------------------------------------- */

typedef struct {
  BtCursor *cur;
  KeyInfo *key_info;        /* NULL for a table (rowid) B-tree */
  UnpackedRecord *key;      /* one integer field, for index seeks */
  VALUE db;
  int open;
} Cursor;

static void cursor_mark(void *p) { rb_gc_mark(((Cursor *)p)->db); }
static void cursor_free(void *p) {
  Cursor *c = p;
  if (c->open) sqlite3BtreeCloseCursor(c->cur);
  if (c->key_info) sqlite3KeyInfoUnref(c->key_info);
  sqlite3_free(c->key);
  xfree(c->cur);
  xfree(c);
}
static const rb_data_type_t cursor_type = {"Lite::Cursor", {cursor_mark, cursor_free, 0}, 0, 0,
                                           RUBY_TYPED_FREE_IMMEDIATELY};

static Cursor *get_cursor(VALUE self) {
  Cursor *c;
  TypedData_Get_Struct(self, Cursor, &cursor_type, c);
  return c;
}

static VALUE cursor_alloc(VALUE klass) {
  Cursor *c;
  return TypedData_Make_Struct(klass, Cursor, &cursor_type, c);
}

/* Lite::Cursor.new(db, root_page, index_columns, descending): index_columns 0 means a table B-tree. An
 * index cursor's key is its columns plus the rowid, compared with the BINARY collation. */
static VALUE cursor_initialize(VALUE self, VALUE db, VALUE root, VALUE columns, VALUE descending) {
  Cursor *c = get_cursor(self);
  DB *d = get_db(db);
  int n = FIX2INT(columns);
  c->db = db;
  c->cur = xcalloc(1, sqlite3BtreeCursorSize());
  sqlite3BtreeCursorZero(c->cur);
  rb_iv_set(self, "@root", root);
  if (n > 0) {
    c->key_info = sqlite3KeyInfoAlloc(d->db, n, 1);
    for (int i = 0; i <= n; i++) {
      c->key_info->aColl[i] = d->db->pDfltColl;
      if (RTEST(descending) && i < n) c->key_info->aSortFlags[i] = KEYINFO_ORDER_DESC;
    }
    c->key = sqlite3_malloc(sizeof *c->key + sizeof(Mem));
    memset(c->key, 0, sizeof *c->key + sizeof(Mem));
    c->key->pKeyInfo = c->key_info;
    c->key->aMem = (Mem *)(c->key + 1);
    c->key->nField = 1;
    c->key->default_rc = 1; /* equal prefix sorts after the probe: a seek lands on the first match */
  }
  return self;
}

/* Opens the cursor inside the current read (or write) transaction. */
static VALUE cursor_open(VALUE self) {
  Cursor *c = get_cursor(self);
  DB *d = get_db(c->db);
  if (c->open) return self;
  sqlite3BtreeCursorZero(c->cur);
  int rc = sqlite3BtreeCursor(d->bt, (Pgno)NUM2UINT(rb_iv_get(self, "@root")), 0, c->key_info, c->cur);
  if (rc != SQLITE_OK) raise_db(d->db, rc);
  c->open = 1;
  return self;
}

static VALUE cursor_close(VALUE self) {
  Cursor *c = get_cursor(self);
  if (c->open) sqlite3BtreeCloseCursor(c->cur);
  c->open = 0;
  return self;
}

/* --- Rendering GET /feed and GET /posts/:id --------------------------------------------------------
 * The documents are built here from the B-tree cursors, with the same bytes as the SQL statements'
 * json_object output. Records are decoded per SQLite's record format (sqlite.org/fileformat.html). A
 * record shaped other than the schema says raises Lite::Fallback, and the caller answers with SQL. */

static VALUE eFallback;

#define FALLBACK(what) rb_raise(eFallback, "%s", what)
#define CHECK(rc)                                  \
  do {                                             \
    int rc_ = (rc);                                \
    if (rc_ != SQLITE_OK) raise_db(NULL, rc_);     \
  } while (0)

enum { FEED_SIZE = 20, SCAN_SPAN = 256 };

/* The entry's record, which must lie on its page (these tables never spill to overflow pages). */
static const u8 *record(BtCursor *cur, u32 *size) {
  u32 available = 0;
  *size = sqlite3BtreePayloadSize(cur);
  const u8 *p = sqlite3BtreePayloadFetch(cur, &available);
  if (available < *size) FALLBACK("record on overflow pages");
  return p;
}

/* Reads a serial type at p[*i], advancing *i; types fit in 32 bits here. */
static u32 serial_type(const u8 *p, u32 *i, u32 header) {
  u32 t;
  if (*i >= header) FALLBACK("record header too short");
  *i += getVarint32(p + *i, t);
  return t;
}

static i64 int_column(const u8 *p, u32 type) {
  switch (type) {
    case 1: return (i8)p[0];
    case 2: return (i16)((p[0] << 8) | p[1]);
    case 3: return ((i64)(i8)p[0] << 16) | (p[1] << 8) | p[2];
    case 4: return (int32_t)(((u32)p[0] << 24) | ((u32)p[1] << 16) | (p[2] << 8) | p[3]);
    case 5: return ((i64)(i16)((p[0] << 8) | p[1]) << 32) |
                   (((u32)p[2] << 24) | (p[3] << 16) | (p[4] << 8) | p[5]);
    case 6: {
      u64 v = 0;
      for (int k = 0; k < 8; k++) v = (v << 8) | p[k];
      return (i64)v;
    }
    case 8: return 0;
    case 9: return 1;
    default: FALLBACK("integer column expected");
  }
  return 0;
}

static u32 int_size(u32 type) {
  static const u8 sizes[10] = {0, 1, 2, 3, 4, 6, 8, 0, 0, 0};
  if (type > 9 || type == 7 || type == 0) FALLBACK("integer column expected");
  return sizes[type];
}

static u32 text_size(u32 type) {
  if (type < 13 || !(type & 1)) FALLBACK("text column expected");
  return (type - 13) / 2;
}

/* The document is built in one native buffer, reused across requests (one thread), and copied into a
 * Ruby String once at the end. */
static struct { char *p; size_t len, cap; } out;

static void reserve(size_t n) {
  if (out.len + n <= out.cap) return;
  size_t cap = out.cap ? out.cap : 16384;
  while (cap < out.len + n) cap *= 2;
  out.p = xrealloc(out.p, cap);
  out.cap = cap;
}

static inline void put(const void *s, size_t n) {
  reserve(n);
  memcpy(out.p + out.len, s, n);
  out.len += n;
}

#define PUT_LITERAL(s) put(s, sizeof(s) - 1)

/* Bytes json_object escapes: the quote, the backslash and control characters. */
static u8 needs_escape[256];

/* Appends bytes as a JSON string. UTF-8 passes through; the rest is escaped as json_object does. */
static void put_json_string(const u8 *s, u32 n) {
  static const char hex[] = "0123456789abcdef";
  reserve((size_t)n * 6 + 2); /* the worst case: every byte as \u00XX */
  char *o = out.p + out.len;
  *o++ = '"';
  u32 i = 0;
  while (i < n) {
    u32 run = i;
    while (i < n && !needs_escape[s[i]]) i++;
    memcpy(o, s + run, i - run);
    o += i - run;
    if (i == n) break;
    u8 c = s[i++];
    *o++ = '\\';
    switch (c) {
      case '"': *o++ = '"'; break;
      case '\\': *o++ = '\\'; break;
      case '\b': *o++ = 'b'; break;
      case '\f': *o++ = 'f'; break;
      case '\n': *o++ = 'n'; break;
      case '\r': *o++ = 'r'; break;
      case '\t': *o++ = 't'; break;
      default: *o++ = 'u'; *o++ = '0'; *o++ = '0'; *o++ = hex[c >> 4]; *o++ = hex[c & 15];
    }
  }
  *o++ = '"';
  out.len = o - out.p;
}

static void put_int(i64 v) {
  char b[24], *e = b + sizeof b, *o = e;
  u64 u = v < 0 ? (u64)0 - (u64)v : (u64)v;
  do *--o = (char)('0' + u % 10); while (u /= 10);
  if (v < 0) *--o = '-';
  put(o, e - o);
}

static VALUE take_document(void) {
  return rb_utf8_str_new(out.p, (long)out.len);
}

/* Moves an index cursor to its first entry whose first column is >= v. 0 if there is none. */
static int seek_index(Cursor *c, i64 v) {
  int res = 0;
  c->key->aMem->flags = MEM_Int;
  c->key->aMem->u.i = v;
  CHECK(sqlite3BtreeIndexMoveto(c->cur, c->key, &res));
  if (res < 0) {
    int rc = sqlite3BtreeNext(c->cur, 0);
    if (rc == SQLITE_DONE) return 0;
    CHECK(rc);
    return 1;
  }
  return !sqlite3BtreeEof(c->cur);
}

/* likes_post_id_idx entry: (post_id, rowid). */
static i64 like_post_id(BtCursor *cur) {
  u32 size, i = 1;
  const u8 *p = record(cur, &size);
  u32 header = p[0];
  if (header >= 128 || header > size) FALLBACK("likes index header");
  u32 type = serial_type(p, &i, header);
  int_size(type);
  return int_column(p + header, type);
}

static i64 count_likes(Cursor *likes, i64 id) {
  i64 n = 0;
  int more = seek_index(likes, id);
  while (more && like_post_id(likes->cur) == id) {
    n++;
    int rc = sqlite3BtreeNext(likes->cur, 0);
    if (rc == SQLITE_DONE) break;
    CHECK(rc);
  }
  return n;
}

/* users(id INTEGER PRIMARY KEY, username, created_at): appends the username of user_id as JSON. */
static void put_username(Cursor *users, i64 user_id) {
  int res = 0;
  u32 size, i = 1;
  CHECK(sqlite3BtreeTableMoveto(users->cur, user_id, 0, &res));
  if (res != 0) FALLBACK("post author not found");
  const u8 *p = record(users->cur, &size);
  u32 header = p[0];
  if (header >= 128 || header > size) FALLBACK("users header");
  if (serial_type(p, &i, header) != 0) FALLBACK("users.id stored"); /* the rowid alias is NULL */
  u32 name = text_size(serial_type(p, &i, header));
  if (header + name > size) FALLBACK("users record");
  put_json_string(p + header, name);
}

/* posts(id INTEGER PRIMARY KEY, user_id, body, created_at), the row under posts->cur: appends
 * {"id","body","created_at","author","like_count"}. */
static void put_post(Cursor *posts, Cursor *users, i64 id, i64 like_count) {
  u32 size, i = 1;
  const u8 *p = record(posts->cur, &size);
  u32 header = p[0];
  if (header >= 128 || header > size) FALLBACK("posts header");
  if (serial_type(p, &i, header) != 0) FALLBACK("posts.id stored");
  u32 user_type = serial_type(p, &i, header);
  u32 body = text_size(serial_type(p, &i, header));
  u32 created = text_size(serial_type(p, &i, header));
  u32 at = header + int_size(user_type);
  if (at + body + created > size) FALLBACK("posts record");
  i64 user_id = int_column(p + header, user_type);

  PUT_LITERAL("{\"id\":");
  put_int(id);
  PUT_LITERAL(",\"body\":");
  put_json_string(p + at, body);
  PUT_LITERAL(",\"created_at\":");
  put_json_string(p + at + body, created);
  PUT_LITERAL(",\"author\":");
  put_username(users, user_id);
  PUT_LITERAL(",\"like_count\":");
  put_int(like_count);
  PUT_LITERAL("}");
}

/* Lite.feed(recent, likes, posts, users): the 20 newest posts, newest first, as the /feed document.
 * recent is posts_created_at_id_idx, (created_at DESC, id DESC); the cursors are open. */
static VALUE lite_feed(VALUE mod, VALUE vrecent, VALUE vlikes, VALUE vposts, VALUE vusers) {
  Cursor *recent = get_cursor(vrecent), *likes = get_cursor(vlikes), *posts = get_cursor(vposts),
         *users = get_cursor(vusers);
  i64 ids[FEED_SIZE];
  int n = 0, empty = 0;
  out.len = 0;

  CHECK(sqlite3BtreeFirst(recent->cur, &empty));
  while (!empty && n < FEED_SIZE) {
    /* (created_at, id): the seed's entries stop there; entries for posts the server inserts also
     * carry the rowid (the same id) after it. */
    u32 size, i = 1;
    const u8 *p = record(recent->cur, &size);
    u32 header = p[0];
    if (header >= 128 || header > size) FALLBACK("feed index header");
    u32 created = text_size(serial_type(p, &i, header));
    u32 id_type = serial_type(p, &i, header);
    if (header + created + int_size(id_type) > size) FALLBACK("feed index record");
    ids[n++] = int_column(p + header + created, id_type);
    int rc = sqlite3BtreeNext(recent->cur, 0);
    if (rc == SQLITE_DONE) break;
    CHECK(rc);
  }

  /* Likes for every post in lo..hi in one walk of the index, when the ids are close together. */
  i64 lo = n ? ids[0] : 0, hi = lo;
  for (int k = 1; k < n; k++) {
    if (ids[k] < lo) lo = ids[k];
    if (ids[k] > hi) hi = ids[k];
  }
  i64 counts[SCAN_SPAN];
  int scanned = n > 0 && hi - lo < SCAN_SPAN;
  if (scanned) {
    memset(counts, 0, sizeof counts);
    int more = seek_index(likes, lo);
    while (more) {
      i64 post_id = like_post_id(likes->cur);
      if (post_id > hi) break;
      counts[post_id - lo]++;
      int rc = sqlite3BtreeNext(likes->cur, 0);
      if (rc == SQLITE_DONE) break;
      CHECK(rc);
    }
  }

  PUT_LITERAL("{\"posts\":[");
  for (int k = 0; k < n; k++) {
    int res = 0;
    CHECK(sqlite3BtreeTableMoveto(posts->cur, ids[k], 0, &res));
    if (res != 0) FALLBACK("indexed post not found");
    if (k) PUT_LITERAL(",");
    put_post(posts, users, ids[k], scanned ? counts[ids[k] - lo] : count_likes(likes, ids[k]));
  }
  PUT_LITERAL("]}");
  return take_document();
}

/* Lite.post(posts, likes, users, id): the /posts/:id document, or nil if there is no such post. */
static VALUE lite_post(VALUE mod, VALUE vposts, VALUE vlikes, VALUE vusers, VALUE vid) {
  Cursor *posts = get_cursor(vposts), *likes = get_cursor(vlikes), *users = get_cursor(vusers);
  i64 id = NUM2LL(vid);
  int res = 0;
  CHECK(sqlite3BtreeTableMoveto(posts->cur, id, 0, &res));
  if (res != 0) return Qnil;
  i64 like_count = count_likes(likes, id);
  out.len = 0;
  PUT_LITERAL("{\"post\":");
  put_post(posts, users, id, like_count);
  PUT_LITERAL("}");
  return take_document();
}

void Init_lite(void) {
  VALUE mLite = rb_define_module("Lite");
  eError = rb_define_class_under(mLite, "Error", rb_eStandardError);

  VALUE cDB = rb_define_class_under(mLite, "DB", rb_cObject);
  rb_define_alloc_func(cDB, db_alloc);
  rb_define_method(cDB, "initialize", db_initialize, 1);
  rb_define_method(cDB, "exec", db_exec, 1);
  rb_define_method(cDB, "close", db_close, 0);
  rb_define_method(cDB, "prepare", db_prepare, 1);
  rb_define_method(cDB, "in_transaction?", db_in_transaction, 0);
  rb_define_method(cDB, "changes", db_changes, 0);
  rb_define_method(cDB, "begin_read", db_begin_read, 0);
  rb_define_method(cDB, "end_read", db_end_read, 0);

  VALUE cStmt = rb_define_class_under(mLite, "Stmt", rb_cObject);
  rb_undef_alloc_func(cStmt);
  rb_define_method(cStmt, "bind_int", stmt_bind_int, 2);
  rb_define_method(cStmt, "bind_text", stmt_bind_text, 2);
  rb_define_method(cStmt, "step", stmt_step, 0);
  rb_define_method(cStmt, "reset", stmt_reset, 0);
  rb_define_method(cStmt, "text", stmt_text, 1);
  rb_define_method(cStmt, "int", stmt_int, 1);

  VALUE cCursor = rb_define_class_under(mLite, "Cursor", rb_cObject);
  rb_define_alloc_func(cCursor, cursor_alloc);
  rb_define_method(cCursor, "initialize", cursor_initialize, 4);
  rb_define_method(cCursor, "open", cursor_open, 0);
  rb_define_method(cCursor, "close", cursor_close, 0);

  eFallback = rb_define_class_under(mLite, "Fallback", eError);
  for (int c = 0; c < 0x20; c++) needs_escape[c] = 1;
  needs_escape['"'] = needs_escape['\\'] = 1;
  rb_define_module_function(mLite, "feed", lite_feed, 4);
  rb_define_module_function(mLite, "post", lite_post, 4);
}
