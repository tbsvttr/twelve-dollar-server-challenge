// The connection layer and HTTP framing of ruby-cring-cicloid, in C.
//
// Client connections are io_uring direct descriptors: slots in each ring's registered-file table, so
// they don't count against RLIMIT_NOFILE. Every connection has one multishot receive armed for its
// lifetime, filled from the ring's buffer ring. Cring::Server#process handles a ring's completions:
// it frames requests, answers the GETs that can't suspend by calling the app right there, and hands
// back the connections that need a worker fiber (writes, and reads while a write batch is open).
// Workers take those requests with #request and answer with #respond. Responses are copied into
// shared send segments and sent in order, one send in flight per connection.
//
// The framing is http.rb's HTTPServer#drain, byte for byte: the same request-line checks, the same
// four headers, the same rejections. Ruby keeps the routing, JWT, validation and the store.
#include <ruby.h> // first: its config.h defines _GNU_SOURCE, which memmem needs
#include <liburing.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/eventfd.h>
#include <sys/mman.h>
#include <unistd.h>

#define SLOT_BITS 16
#define SLOT_MASK 0xFFFFu
#define MAX_RINGS 8
#define BGID 0
#define MAX_LISTENERS 16
#define MAX_HEAD (16 * 1024)
#define MAX_BODY (1024 * 1024)
#define SEG_SIZE (1u << 20)
#define STATUSES 600

// user_data = connection id << 3 | operation; connection id = ring << SLOT_BITS | slot
enum { OP_ACCEPT, OP_RECV, OP_SEND, OP_CANCEL, OP_CLOSE };
enum {
  C_BUSY = 1,       // queued for or held by a worker
  C_SENDING = 2,    // a send is in flight
  C_CLOSING = 4,    // close once the sends are done
  C_CANCELLED = 8,  // the receive was asked to end
  C_DEAD = 16,      // the receive has ended
  C_HTTP10 = 32,    // the request being answered: HTTP/1.0
  C_CLOSE = 64,     //   asked for Connection: close (or HTTP/1.0 without keep-alive)
  C_FEED = 128      //   for /feed
};
enum { HEAD_KEEP, HEAD_CLOSE, HEAD_KEEP_10 };
enum { M_GET, M_POST, M_OTHER };
enum { P_NEED, P_OK, P_REJECT };

typedef struct {
  char *data;
  uint32_t len;
} bytes_t;

typedef struct {
  char *in; // bytes received and not yet served
  uint32_t in_len, in_cap;
  char *pend; // responses waiting for the send in flight
  uint32_t pend_len, pend_cap;
  char *send_ptr; // the send in flight
  uint32_t send_len, send_off;
  int32_t send_seg;
  uint16_t flags;
} conn_t;

typedef struct {
  char *base;
  size_t size;
  uint32_t refs; // sends in flight from this segment
  int big;       // one oversized response; freed when its send is done
} seg_t;

typedef struct {
  struct io_uring ring;
  struct io_uring_buf_ring *br;
  char *bufs;
  unsigned br_mask;
  int eventfd;
  conn_t *conns;
  unsigned held; // slots taken by connections and by accepts in flight
  int pending;   // entries queued since the last submit
} ring_t;

typedef struct {
  ring_t rings[MAX_RINGS];
  int nrings;
  unsigned slots, buffer_size;
  int listeners[MAX_LISTENERS];
  int nlisteners, next_listener, accept_target;
  int started, writing, accepts;
  long open, budget, hard_budget;
  seg_t *segs;
  int nsegs, segcap, cur;
  size_t cur_off;
  int *free_segs;
  int nfree;
  bytes_t heads[3][STATUSES];
  bytes_t rejects[STATUSES];
  VALUE app, s_get, s_post, s_feed;
  // By ring: connections to hand to workers. Not shared: while one pump starts workers for its list,
  // the reactor can run another ring's pump.
  VALUE deferred[MAX_RINGS];
  int error; // a pending exception from an inline request, re-raised after the pass
} server_t;

typedef struct {
  int method;
  uint32_t method_len;
  int feed, http10, close, has_auth;
  uint32_t path_off, path_len, auth_off, auth_len, body_off, body_len, total;
  int status;
} req_t;

static ID id_call;

static void server_mark(void *p) {
  server_t *s = p;
  rb_gc_mark(s->app);
  for (int i = 0; i < MAX_RINGS; i++) rb_gc_mark(s->deferred[i]);
  rb_gc_mark(s->s_get);
  rb_gc_mark(s->s_post);
  rb_gc_mark(s->s_feed);
}

static const rb_data_type_t server_type = {
    "Cring::Server", {server_mark, NULL, NULL}, NULL, NULL, RUBY_TYPED_FREE_IMMEDIATELY};

static server_t *get_server(VALUE self) {
  server_t *s;
  TypedData_Get_Struct(self, server_t, &server_type, s);
  return s;
}

static VALUE server_alloc(VALUE klass) {
  server_t *s = ZALLOC(server_t);
  s->app = s->s_get = s->s_post = s->s_feed = Qnil;
  for (int i = 0; i < MAX_RINGS; i++) s->deferred[i] = Qnil;
  return TypedData_Wrap_Struct(klass, &server_type, s);
}

static void *xgrow(void *p, uint32_t *cap, uint32_t need) {
  if (need <= *cap) return p;
  uint32_t n = *cap ? *cap : 512;
  while (n < need) n *= 2;
  p = realloc(p, n);
  if (!p) rb_memerror();
  *cap = n;
  return p;
}

// --- submissions -----------------------------------------------------------------------------

static struct io_uring_sqe *take_sqe(ring_t *r) {
  struct io_uring_sqe *sqe;
  while (!(sqe = io_uring_get_sqe(&r->ring))) io_uring_submit(&r->ring); // full: hand it over first
  r->pending = 1;
  return sqe;
}

static void arm_recv(ring_t *r, unsigned slot, uint32_t id) {
  struct io_uring_sqe *sqe = take_sqe(r);
  io_uring_prep_recv_multishot(sqe, slot, NULL, 0, 0);
  sqe->flags |= IOSQE_FIXED_FILE | IOSQE_BUFFER_SELECT;
  sqe->buf_group = BGID;
  io_uring_sqe_set_data64(sqe, (uint64_t)id << 3 | OP_RECV);
}

// Keeps accept_target single-shot accepts in flight, each on the ring holding the fewest connections
// (with a multishot accept per ring the kernel fills the first ring's table before the next), and
// on the listeners in turn. A connection that arrives while an accept waits is taken by the kernel
// at once; one that finds none waits in its listener's queue, which holds only net.core.somaxconn
// (4,096 on Ubuntu) and drops connections once full, so the client retries after 1, 3, 7... s.
static void arm_accepts(server_t *s) {
  while (s->accepts < s->accept_target) {
    int index = 0;
    for (int i = 1; i < s->nrings; i++)
      if (s->rings[i].held < s->rings[index].held) index = i;
    ring_t *r = &s->rings[index];
    if (r->held >= s->slots) break;
    r->held++;
    s->accepts++;
    struct io_uring_sqe *sqe = take_sqe(r);
    int listener = s->listeners[s->next_listener];
    s->next_listener = (s->next_listener + 1) % s->nlisteners;
    io_uring_prep_accept_direct(sqe, listener, NULL, NULL, 0, IORING_FILE_INDEX_ALLOC);
    io_uring_sqe_set_data64(sqe, (uint64_t)((uint32_t)index << SLOT_BITS) << 3 | OP_ACCEPT);
  }
}

// --- send segments ---------------------------------------------------------------------------

static int new_segment(server_t *s, size_t size, int big) {
  int index;
  if (!big && s->nfree) {
    index = s->free_segs[--s->nfree];
  } else {
    if (s->nsegs == s->segcap) {
      s->segcap = s->segcap ? s->segcap * 2 : 16;
      s->segs = realloc(s->segs, s->segcap * sizeof(seg_t));
      s->free_segs = realloc(s->free_segs, s->segcap * sizeof(int));
      if (!s->segs || !s->free_segs) rb_memerror();
    }
    index = s->nsegs++;
    s->segs[index].base = malloc(size);
    if (!s->segs[index].base) rb_memerror();
    s->segs[index].size = size;
  }
  s->segs[index].refs = 0;
  s->segs[index].big = big;
  return index;
}

// Room for `len` bytes that stay put until their send completes.
static char *segment_take(server_t *s, size_t len, int *seg) {
  if (len > SEG_SIZE) {
    *seg = new_segment(s, len, 1);
    return s->segs[*seg].base;
  }
  if (s->cur_off + len > SEG_SIZE) {
    if (s->segs[s->cur].refs == 0) {
      s->cur_off = 0; // nothing in flight from it: start over
    } else {
      s->cur = new_segment(s, SEG_SIZE, 0);
      s->cur_off = 0;
    }
  }
  *seg = s->cur;
  char *p = s->segs[s->cur].base + s->cur_off;
  s->cur_off += len;
  return p;
}

static void segment_release(server_t *s, int index) {
  seg_t *g = &s->segs[index];
  if (--g->refs || index == s->cur) return;
  if (g->big) {
    free(g->base);
    g->base = NULL;
    g->size = 0;
    g->big = 0; // the slot is reused as an ordinary segment later
    g->base = malloc(SEG_SIZE);
    if (!g->base) rb_memerror();
    g->size = SEG_SIZE;
  }
  s->free_segs[s->nfree++] = index;
}

// --- connections -----------------------------------------------------------------------------

static inline ring_t *ring_of(server_t *s, uint32_t id) { return &s->rings[id >> SLOT_BITS]; }
static inline conn_t *conn_of(server_t *s, uint32_t id) { return &ring_of(s, id)->conns[id & SLOT_MASK]; }

static void close_slot(server_t *s, uint32_t id, conn_t *c) {
  ring_t *r = ring_of(s, id);
  struct io_uring_sqe *sqe = take_sqe(r);
  io_uring_prep_close_direct(sqe, id & SLOT_MASK);
  sqe->flags |= IOSQE_CQE_SKIP_SUCCESS;
  io_uring_sqe_set_data64(sqe, (uint64_t)id << 3 | OP_CLOSE);
  free(c->in);
  free(c->pend);
  memset(c, 0, sizeof *c);
  s->open--;
  r->held--;
  arm_accepts(s);
}

// Moves the connection toward closing once nothing holds it: a closing connection's receive is
// cancelled, and the slot of one whose receive has ended is freed.
static void finish(server_t *s, uint32_t id, conn_t *c) {
  if (c->flags & (C_BUSY | C_SENDING)) return;
  if (c->flags & C_DEAD) {
    close_slot(s, id, c);
  } else if ((c->flags & C_CLOSING) && !(c->flags & C_CANCELLED)) {
    c->flags |= C_CANCELLED;
    struct io_uring_sqe *sqe = take_sqe(ring_of(s, id));
    io_uring_prep_cancel64(sqe, (uint64_t)id << 3 | OP_RECV, 0);
    sqe->flags |= IOSQE_CQE_SKIP_SUCCESS;
    io_uring_sqe_set_data64(sqe, (uint64_t)id << 3 | OP_CANCEL);
  }
}

static void start_send(server_t *s, uint32_t id, conn_t *c, char *p, uint32_t len, int seg) {
  c->send_ptr = p;
  c->send_len = len;
  c->send_off = 0;
  c->send_seg = seg;
  c->flags |= C_SENDING;
  s->segs[seg].refs++;
  struct io_uring_sqe *sqe = take_sqe(ring_of(s, id));
  io_uring_prep_send(sqe, id & SLOT_MASK, p, len, 0);
  sqe->flags |= IOSQE_FIXED_FILE;
  io_uring_sqe_set_data64(sqe, (uint64_t)id << 3 | OP_SEND);
}

// head, the length, a blank line and the document, in one send unless one is already in flight.
static void write_response(server_t *s, uint32_t id, conn_t *c, const bytes_t *head, const char *doc, long doc_len) {
  char digits[24];
  int digits_len = snprintf(digits, sizeof digits, "%ld", doc_len);
  uint32_t total = head->len + digits_len + 4 + (uint32_t)doc_len;
  char *p;
  int seg = -1;
  if (c->flags & C_SENDING) {
    c->pend = xgrow(c->pend, &c->pend_cap, c->pend_len + total);
    p = c->pend + c->pend_len;
    c->pend_len += total;
  } else {
    p = segment_take(s, total, &seg);
  }
  memcpy(p, head->data, head->len);
  memcpy(p + head->len, digits, digits_len);
  memcpy(p + head->len + digits_len, "\r\n\r\n", 4);
  memcpy(p + head->len + digits_len + 4, doc, doc_len);
  if (seg >= 0) start_send(s, id, c, p, total, seg);
}

static void sent(server_t *s, uint32_t id, conn_t *c, int result) {
  if (result < 0) {
    segment_release(s, c->send_seg);
    c->flags &= ~C_SENDING;
    c->pend_len = 0;
    c->flags |= C_CLOSING;
    finish(s, id, c);
    return;
  }
  c->send_off += result;
  if (c->send_off < c->send_len) { // a short send: the rest goes next
    struct io_uring_sqe *sqe = take_sqe(ring_of(s, id));
    io_uring_prep_send(sqe, id & SLOT_MASK, c->send_ptr + c->send_off, c->send_len - c->send_off, 0);
    sqe->flags |= IOSQE_FIXED_FILE;
    io_uring_sqe_set_data64(sqe, (uint64_t)id << 3 | OP_SEND);
    return;
  }
  segment_release(s, c->send_seg);
  c->flags &= ~C_SENDING;
  if (c->pend_len) {
    int seg;
    uint32_t len = c->pend_len;
    char *p = segment_take(s, len, &seg);
    memcpy(p, c->pend, len);
    free(c->pend);
    c->pend = NULL;
    c->pend_len = c->pend_cap = 0;
    start_send(s, id, c, p, len, seg);
  } else {
    finish(s, id, c);
  }
}

static void respond(server_t *s, uint32_t id, conn_t *c, int status, VALUE document) {
  StringValue(document);
  int close = (c->flags & C_CLOSE) ||
              (s->open > s->budget && (!(c->flags & C_FEED) || s->open > s->hard_budget));
  int kind = close ? HEAD_CLOSE : (c->flags & C_HTTP10) ? HEAD_KEEP_10 : HEAD_KEEP;
  const bytes_t *head = (status >= 0 && status < STATUSES && s->heads[kind][status].data)
                            ? &s->heads[kind][status] : &s->heads[kind][500];
  write_response(s, id, c, head, RSTRING_PTR(document), RSTRING_LEN(document));
  if (close) c->flags |= C_CLOSING;
}

static void reject(server_t *s, uint32_t id, conn_t *c, int status) {
  write_response(s, id, c, &s->heads[HEAD_CLOSE][status], s->rejects[status].data, s->rejects[status].len);
  c->flags |= C_CLOSING;
}

// --- HTTP/1.1 framing (http.rb's drain) ------------------------------------------------------

static inline int lower(int b) { return b >= 'A' && b <= 'Z' ? b + 32 : b; }
static inline int word(int b) {
  return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9') || b == '_';
}

// /\btoken\b/i
static int has_token(const char *v, uint32_t n, const char *token, uint32_t t) {
  for (uint32_t i = 0; i + t <= n; i++) {
    uint32_t k = 0;
    while (k < t && lower((unsigned char)v[i + k]) == token[k]) k++;
    if (k == t && (i == 0 || !word((unsigned char)v[i - 1])) && (i + t == n || !word((unsigned char)v[i + t])))
      return 1;
  }
  return 0;
}

static const char *const NAMES[4] = {"content-length", "transfer-encoding", "connection", "authorization"};
static const uint32_t NAME_LENS[4] = {14, 17, 10, 13};

// One request from the start of `b`: P_NEED (incomplete), P_REJECT (q->status) or P_OK.
static int parse(const char *b, uint32_t size, req_t *q) {
  memset(q, 0, sizeof *q);
  const char *h = memmem(b, size, "\r\n\r\n", 4);
  if (!h) {
    if (size > MAX_HEAD) { q->status = 431; return P_REJECT; }
    return P_NEED;
  }
  uint32_t head_end = h - b;
  uint32_t line_end = (const char *)memmem(b, size, "\r\n", 2) - b;
  const char *sp = memchr(b, ' ', size);
  const char *sp2 = sp ? memchr(sp + 1, ' ', size - (sp + 1 - b)) : NULL;
  if (!sp2 || sp == b || (uint32_t)(sp2 - b) >= line_end) { q->status = 400; return P_REJECT; }
  uint32_t space = sp - b, space2 = sp2 - b, v = space2 + 1;

  // "HTTP/1." then the minor version; the CRLF after it is line_end
  if (line_end - v != 8 || memcmp(b + v, "HTTP/1.", 7) != 0 || (b[v + 7] != '0' && b[v + 7] != '1')) {
    q->status = 400;
    return P_REJECT;
  }
  q->http10 = b[v + 7] == '0';

  if (space == 3 && memcmp(b, "GET", 3) == 0) q->method = M_GET;
  else if (space == 4 && memcmp(b, "POST", 4) == 0) q->method = M_POST;
  else q->method = M_OTHER;
  q->method_len = space;

  uint32_t after = space + 6;
  if (after < size && (b[after] == ' ' || b[after] == '?') && memcmp(b + space + 1, "/feed", 5) == 0) {
    q->feed = 1;
  } else {
    const char *query = memchr(b + space + 1, '?', size - space - 1);
    uint32_t path_end = query && (uint32_t)(query - b) < space2 ? (uint32_t)(query - b) : space2;
    q->path_off = space + 1;
    q->path_len = path_end - space - 1;
  }

  long length = 0;
  q->close = q->http10;
  // /\r\n(content-length|transfer-encoding|connection|authorization)[ \t]*:[ \t]*([^\r\n]*)/i, from
  // line_end on; a match must start before head_end
  uint32_t at = line_end;
  for (;;) {
    const char *crlf = memmem(b + at, size - at, "\r\n", 2);
    if (!crlf) break;
    uint32_t start = crlf - b;
    if (start >= head_end) break;
    at = start + 2;
    int name = -1;
    for (int i = 0; i < 4 && name < 0; i++) {
      uint32_t n = NAME_LENS[i], k = 0;
      if (at + n > size) continue;
      while (k < n && lower((unsigned char)b[at + k]) == NAMES[i][k]) k++;
      if (k == n) name = i;
    }
    if (name < 0) continue;
    uint32_t p = at + NAME_LENS[name];
    while (p < size && (b[p] == ' ' || b[p] == '\t')) p++;
    if (p >= size || b[p] != ':') continue;
    p++;
    while (p < size && (b[p] == ' ' || b[p] == '\t')) p++;
    uint32_t value = p;
    while (p < size && b[p] != '\r' && b[p] != '\n') p++;
    uint32_t value_end = p;
    while (value_end > value && (b[value_end - 1] == ' ' || b[value_end - 1] == '\t')) value_end--;
    uint32_t n = value_end - value;
    switch (name) {
    case 0: { // content-length
      if (n == 0) { q->status = 400; return P_REJECT; }
      long l = 0;
      for (uint32_t i = 0; i < n; i++) {
        if (b[value + i] < '0' || b[value + i] > '9') { q->status = 400; return P_REJECT; }
        if (l <= MAX_BODY) l = l * 10 + (b[value + i] - '0');
      }
      length = l;
      break;
    }
    case 1: // transfer-encoding: request bodies must use Content-Length
      q->status = 411;
      return P_REJECT;
    case 2: // connection
      if (has_token(b + value, n, "close", 5)) q->close = 1;
      else if (q->http10 && has_token(b + value, n, "keep-alive", 10)) q->close = 0;
      break;
    default: // authorization
      q->has_auth = 1;
      q->auth_off = value;
      q->auth_len = n;
    }
  }
  if (length > MAX_BODY) { q->status = 413; return P_REJECT; }

  uint32_t body_start = head_end + 4;
  if ((uint64_t)size < (uint64_t)body_start + length) return P_NEED; // the body hasn't fully arrived
  q->body_off = body_start;
  q->body_len = length;
  q->total = body_start + length;
  return P_OK;
}

static void set_request_flags(conn_t *c, const req_t *q) {
  c->flags &= ~(C_HTTP10 | C_CLOSE | C_FEED);
  if (q->http10) c->flags |= C_HTTP10;
  if (q->close) c->flags |= C_CLOSE;
  if (q->feed) c->flags |= C_FEED;
}

static VALUE request_values(server_t *s, const char *b, const req_t *q, VALUE *out) {
  out[0] = q->method == M_GET ? s->s_get : q->method == M_POST ? s->s_post : rb_str_new(b, q->method_len);
  out[1] = q->feed ? s->s_feed : rb_str_new(b + q->path_off, q->path_len);
  out[2] = q->has_auth ? rb_str_new(b + q->auth_off, q->auth_len) : Qnil;
  out[3] = q->body_len ? rb_str_new(b + q->body_off, q->body_len) : Qnil;
  return Qnil;
}

typedef struct {
  VALUE app;
  VALUE args[4];
} call_t;

static VALUE call_app(VALUE arg) {
  call_t *call = (call_t *)arg;
  return rb_funcallv(call->app, id_call, 4, call->args);
}

// A GET with no write batch open can't suspend: the pump answers it right here.
static void serve_inline(server_t *s, uint32_t id, conn_t *c, const char *b, const req_t *q) {
  call_t call = {s->app, {0}};
  request_values(s, b, q, call.args);
  set_request_flags(c, q);
  int state = 0;
  VALUE result = rb_protect(call_app, (VALUE)&call, &state);
  if (state) { // an exception App#call didn't rescue: close, and re-raise after the pass
    c->flags |= C_CLOSING;
    if (!s->error) s->error = state;
    return;
  }
  respond(s, id, c, NUM2INT(rb_ary_entry(result, 0)), rb_ary_entry(result, 1));
}

// Keeps `len` bytes from `p` as the connection's unserved input (p may point into c->in).
static void keep_input(conn_t *c, const char *p, uint32_t len) {
  if (len == 0) {
    free(c->in);
    c->in = NULL;
    c->in_len = c->in_cap = 0;
  } else if (c->in && p >= c->in && p < c->in + c->in_cap) {
    memmove(c->in, p, len);
    c->in_len = len;
  } else {
    c->in = xgrow(c->in, &c->in_cap, len);
    memcpy(c->in, p, len);
    c->in_len = len;
  }
}

// New bytes on a connection no worker holds: frames them, answers inline what it can, and hands the
// connection to a worker from the first request it can't answer here.
static void received(server_t *s, uint32_t id, conn_t *c, const char *data, uint32_t len) {
  if (c->flags & C_CLOSING) { // a closing connection's input is dropped
    finish(s, id, c);
    return;
  }
  if (c->flags & C_BUSY || c->in_len) {
    c->in = xgrow(c->in, &c->in_cap, c->in_len + len);
    memcpy(c->in + c->in_len, data, len);
    c->in_len += len;
    if (c->flags & C_BUSY) return;
    data = c->in;
    len = c->in_len;
  }
  uint32_t pos = 0;
  int defer = 0;
  while (pos < len) {
    req_t q;
    int r = parse(data + pos, len - pos, &q);
    if (r == P_NEED) break;
    if (r == P_REJECT) {
      reject(s, id, c, q.status);
      break;
    }
    if (q.method != M_GET || s->writing) {
      defer = 1;
      break;
    }
    serve_inline(s, id, c, data + pos, &q);
    pos += q.total;
    if (c->flags & C_CLOSING) break;
  }
  if (c->flags & C_CLOSING) keep_input(c, NULL, 0);
  else keep_input(c, data + pos, len - pos);
  if (defer) {
    c->flags |= C_BUSY;
    rb_ary_push(s->deferred[id >> SLOT_BITS], UINT2NUM(id));
  } else {
    finish(s, id, c);
  }
}

// --- completions -----------------------------------------------------------------------------

static void complete(server_t *s, int index, struct io_uring_cqe *cqe) {
  ring_t *r = &s->rings[index];
  uint64_t data = cqe->user_data;
  int op = data & 7;
  uint32_t id = (uint32_t)(data >> 3);
  int result = cqe->res;
  switch (op) {
  case OP_RECV: {
    conn_t *c = conn_of(s, id);
    if (result > 0) {
      unsigned bid = cqe->flags >> IORING_CQE_BUFFER_SHIFT;
      char *buf = r->bufs + (size_t)bid * s->buffer_size;
      received(s, id, c, buf, result);
      io_uring_buf_ring_add(r->br, buf, s->buffer_size, bid, r->br_mask, 0);
      io_uring_buf_ring_advance(r->br, 1);
      if (!(cqe->flags & IORING_CQE_F_MORE) && !(c->flags & C_DEAD)) arm_recv(r, id & SLOT_MASK, id);
    } else if (result == -ENOBUFS) { // out of buffers: they come back as soon as they're read
      arm_recv(r, id & SLOT_MASK, id);
    } else { // end of stream, an error, or cancelled
      c->flags |= C_DEAD;
      finish(s, id, c);
    }
    break;
  }
  case OP_SEND:
    sent(s, id, conn_of(s, id), result);
    break;
  case OP_ACCEPT:
    s->accepts--;
    if (result >= 0) {
      uint32_t cid = (uint32_t)index << SLOT_BITS | (uint32_t)result;
      conn_t *c = &r->conns[result];
      free(c->in);
      free(c->pend);
      memset(c, 0, sizeof *c);
      s->open++;
      arm_recv(r, result, cid);
    } else {
      r->held--;
    }
    arm_accepts(s);
    break;
  default: // CANCEL and CLOSE complete only when they fail: the receive ends or the slot is freed anyway
    break;
  }
}

// --- Ruby API --------------------------------------------------------------------------------

static void fail(const char *call, int result) {
  if (result < 0) rb_syserr_fail(-result, call);
}

// Cring::Server.new(rings, slots, buffers, buffer_size, entries, completions)
static VALUE server_initialize(VALUE self, VALUE rings, VALUE slots, VALUE buffers, VALUE buffer_size,
                               VALUE entries, VALUE completions) {
  server_t *s = get_server(self);
  s->nrings = NUM2INT(rings);
  if (s->nrings < 1 || s->nrings > MAX_RINGS) rb_raise(rb_eArgError, "1 to %d rings", MAX_RINGS);
  s->slots = NUM2UINT(slots);
  s->buffer_size = NUM2UINT(buffer_size);
  unsigned nbuf = NUM2UINT(buffers);
  if (nbuf & (nbuf - 1)) rb_raise(rb_eArgError, "buffers must be a power of two");
  for (int i = 0; i < s->nrings; i++) s->deferred[i] = rb_ary_new();
  for (int i = 0; i < s->nrings; i++) {
    ring_t *r = &s->rings[i];
    struct io_uring_params p;
    memset(&p, 0, sizeof p);
    p.flags = IORING_SETUP_CQSIZE | IORING_SETUP_SUBMIT_ALL | IORING_SETUP_SINGLE_ISSUER;
    p.cq_entries = NUM2UINT(completions);
    fail("io_uring_queue_init", io_uring_queue_init_params(NUM2UINT(entries), &r->ring, &p));
    fail("io_uring_register_files_sparse", io_uring_register_files_sparse(&r->ring, s->slots));
    r->eventfd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
    if (r->eventfd < 0) rb_sys_fail("eventfd");
    fail("io_uring_register_eventfd", io_uring_register_eventfd(&r->ring, r->eventfd));

    // The buffer ring. Ubuntu's 6.8.0-136+ kernels reject the registration unless a reserved field
    // is set (Launchpad #2162843), so a refusal is retried with it.
    size_t size = nbuf * sizeof(struct io_uring_buf);
    void *br = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (br == MAP_FAILED) rb_sys_fail("mmap");
    struct io_uring_buf_reg reg;
    memset(&reg, 0, sizeof reg);
    reg.ring_addr = (unsigned long)br;
    reg.ring_entries = nbuf;
    reg.bgid = BGID;
    int result = io_uring_register_buf_ring(&r->ring, &reg, 0);
    if (result == -EINVAL) {
      reg.resv[0] = 1;
      result = io_uring_register_buf_ring(&r->ring, &reg, 0);
    }
    fail("io_uring_register_buf_ring", result);
    r->br = br;
    r->br_mask = io_uring_buf_ring_mask(nbuf);
    io_uring_buf_ring_init(r->br);
    r->bufs = malloc((size_t)nbuf * s->buffer_size);
    if (!r->bufs) rb_memerror();
    for (unsigned b = 0; b < nbuf; b++)
      io_uring_buf_ring_add(r->br, r->bufs + (size_t)b * s->buffer_size, s->buffer_size, b, r->br_mask, b);
    io_uring_buf_ring_advance(r->br, nbuf);

    r->conns = calloc(s->slots, sizeof(conn_t));
    if (!r->conns) rb_memerror();
  }
  s->cur = new_segment(s, SEG_SIZE, 0);
  return self;
}

static void copy_heads(bytes_t *table, VALUE hash) {
  VALUE keys = rb_funcall(hash, rb_intern("keys"), 0);
  for (long i = 0; i < RARRAY_LEN(keys); i++) {
    VALUE key = rb_ary_entry(keys, i);
    int status = NUM2INT(key);
    if (status < 0 || status >= STATUSES) continue;
    VALUE value = rb_hash_aref(hash, key);
    StringValue(value);
    table[status].len = RSTRING_LEN(value);
    table[status].data = malloc(table[status].len);
    memcpy(table[status].data, RSTRING_PTR(value), table[status].len);
  }
}

// start(listener_fds, accepts, app, keep, close, keep_10, rejects, budget, hard_budget, get, post, feed)
static VALUE server_start(int argc, VALUE *argv, VALUE self) {
  server_t *s = get_server(self);
  rb_check_arity(argc, 12, 12);
  VALUE fds = rb_Array(argv[0]);
  s->nlisteners = (int)RARRAY_LEN(fds);
  if (s->nlisteners < 1 || s->nlisteners > MAX_LISTENERS) rb_raise(rb_eArgError, "1 to %d listeners", MAX_LISTENERS);
  for (int i = 0; i < s->nlisteners; i++) s->listeners[i] = NUM2INT(rb_ary_entry(fds, i));
  s->accept_target = NUM2INT(argv[1]);
  s->app = argv[2];
  copy_heads(s->heads[HEAD_KEEP], argv[3]);
  copy_heads(s->heads[HEAD_CLOSE], argv[4]);
  copy_heads(s->heads[HEAD_KEEP_10], argv[5]);
  copy_heads(s->rejects, argv[6]);
  s->budget = NUM2LONG(argv[7]);
  s->hard_budget = NUM2LONG(argv[8]);
  s->s_get = argv[9];
  s->s_post = argv[10];
  s->s_feed = argv[11];
  s->started = 1;
  arm_accepts(s);
  return Qnil;
}

static VALUE server_eventfd(VALUE self, VALUE index) {
  server_t *s = get_server(self);
  int i = NUM2INT(index);
  if (i < 0 || i >= s->nrings) rb_raise(rb_eIndexError, "no ring %d", i);
  return INT2NUM(s->rings[i].eventfd);
}

// Handles every completion on ring `index`. `writing`: a write batch is open, so reads must wait
// for it and go to workers too. Returns the ids of the connections to hand to workers, or nil.
static VALUE server_process(VALUE self, VALUE index, VALUE writing) {
  server_t *s = get_server(self);
  int i = NUM2INT(index);
  ring_t *r = &s->rings[i];
  uint64_t count;
  if (read(r->eventfd, &count, sizeof count) < 0 && errno != EAGAIN) rb_sys_fail("read eventfd");
  s->writing = RTEST(writing);
  rb_ary_clear(s->deferred[i]);
  s->error = 0;
  for (;;) {
    unsigned head, n = 0;
    struct io_uring_cqe *cqe;
    io_uring_for_each_cqe(&r->ring, head, cqe) {
      complete(s, i, cqe);
      n++;
    }
    if (n) {
      io_uring_cq_advance(&r->ring, n);
      continue;
    }
    if (!io_uring_cq_has_overflow(&r->ring)) break;
    io_uring_get_events(&r->ring); // completions the ring had no room for wait in the kernel
  }
  if (s->error) rb_jump_tag(s->error);
  return RARRAY_LEN(s->deferred[i]) ? s->deferred[i] : Qnil;
}

// The next complete request on a connection a worker holds, as [method, path, authorization, body],
// or nil once there is none: the worker lets go of the connection then.
static VALUE server_request(VALUE self, VALUE vid) {
  server_t *s = get_server(self);
  uint32_t id = NUM2UINT(vid);
  conn_t *c = conn_of(s, id);
  if (!(c->flags & C_CLOSING) && c->in_len) {
    req_t q;
    int r = parse(c->in, c->in_len, &q);
    if (r == P_REJECT) {
      reject(s, id, c, q.status);
      keep_input(c, NULL, 0);
    } else if (r == P_OK) {
      VALUE values[4];
      request_values(s, c->in, &q, values);
      set_request_flags(c, &q);
      keep_input(c, c->in + q.total, c->in_len - q.total);
      return rb_ary_new_from_values(4, values);
    }
  }
  c->flags &= ~C_BUSY;
  finish(s, id, c);
  return Qnil;
}

static VALUE server_respond(VALUE self, VALUE vid, VALUE status, VALUE document) {
  server_t *s = get_server(self);
  uint32_t id = NUM2UINT(vid);
  respond(s, id, conn_of(s, id), NUM2INT(status), document);
  return Qnil;
}

// A worker that raised: the connection closes once its sends are done.
static VALUE server_abandon(VALUE self, VALUE vid) {
  server_t *s = get_server(self);
  uint32_t id = NUM2UINT(vid);
  conn_t *c = conn_of(s, id);
  c->flags = (c->flags & ~C_BUSY) | C_CLOSING;
  keep_input(c, NULL, 0);
  finish(s, id, c);
  return Qnil;
}

// Hands every ring's queued entries to the kernel.
static VALUE server_submit(VALUE self) {
  server_t *s = get_server(self);
  for (int i = 0; i < s->nrings; i++) {
    ring_t *r = &s->rings[i];
    if (!r->pending) continue;
    r->pending = 0;
    fail("io_uring_submit", io_uring_submit(&r->ring));
  }
  return Qnil;
}

static VALUE server_open(VALUE self) { return LONG2NUM(get_server(self)->open); }

void Init_cring(void) {
  id_call = rb_intern("call");
  VALUE module = rb_define_module("Cring");
  VALUE klass = rb_define_class_under(module, "Server", rb_cObject);
  rb_define_alloc_func(klass, server_alloc);
  rb_define_method(klass, "initialize", server_initialize, 6);
  rb_define_method(klass, "start", server_start, -1);
  rb_define_method(klass, "eventfd", server_eventfd, 1);
  rb_define_method(klass, "process", server_process, 2);
  rb_define_method(klass, "request", server_request, 1);
  rb_define_method(klass, "respond", server_respond, 3);
  rb_define_method(klass, "abandon", server_abandon, 1);
  rb_define_method(klass, "submit", server_submit, 0);
  rb_define_method(klass, "open", server_open, 0);
}
