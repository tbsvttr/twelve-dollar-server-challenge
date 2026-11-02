/* hphp_rt.h — HolyPHP runtime interface.
 *
 * Every generated program includes this header and links against
 * libhphp.a (the runtime implemented in hphp_rt.c + hphp_std.c).
 */
#ifndef HPHP_RT_H
#define HPHP_RT_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <setjmp.h>
#include <stdarg.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---------- string builder (runtime-internal helper) ---------- */
typedef struct {
    char *data;
    size_t len, cap;
} Buf;
void hbuf_init(Buf *b);
void hbuf_reserve(Buf *b, size_t n);
void hbuf_grow_slow(Buf *b, size_t need);

/* Inline fast path: every response byte goes through these, and a call plus a
 * capacity check per byte is measurable. */
static inline void hbuf_need(Buf *b, size_t n) {
    if (b->len + n + 1 > b->cap) hbuf_grow_slow(b, n);
}
static inline void hbuf_putc(Buf *b, char c) {
    hbuf_need(b, 1);
    b->data[b->len++] = c;
    b->data[b->len] = 0;
}
static inline void hbuf_write(Buf *b, const char *s, size_t n) {
    hbuf_need(b, n);
    memcpy(b->data + b->len, s, n);
    b->len += n;
    b->data[b->len] = 0;
}
void hbuf_puts(Buf *b, const char *s);
void hbuf_printf(Buf *b, const char *fmt, ...);
char *hbuf_take(Buf *b); /* NUL-terminated, transfers ownership */
const char *hbuf_base(Buf *b);
size_t hbuf_len(Buf *b);
void hbuf_free(Buf *b);
#define buf_init  hbuf_init
#define buf_putc  hbuf_putc
#define buf_write hbuf_write
#define buf_puts  hbuf_puts
#define buf_printf hbuf_printf
#define buf_take  hbuf_take
#define buf_base  hbuf_base
#define buf_len   hbuf_len
#define buf_free  hbuf_free

/* ---------- forward types ---------- */
typedef struct hstr hstr;
typedef struct harr harr;
typedef struct hobj hobj;
typedef struct hclosure hclosure;
typedef struct hval hval;

/* ---------- runtime counters (generic introspection) ----------
 * Plain adds: the VM is single-threaded. Exposed as a JSON object by the
 * runtime_stats() builtin; the indices are the key order. */
enum {
    HP_ST_REQ = 0,     /* request reads handed to the program */
    HP_ST_ENTER,       /* io_uring enter syscalls issued */
    HP_ST_SQE_SUB,     /* SQEs driven into the kernel in one enter */
    HP_ST_SQE_PUSH,    /* SQEs accepted by the ring */
    HP_ST_SQE_PARK,    /* pushes rejected because the ring was full */
    HP_ST_CQE,         /* CQEs drained (incl. stale + cancels) */
    HP_ST_CQE_RECV,
    HP_ST_CQE_SEND,
    HP_ST_CQE_POLL,
    HP_ST_ARM_RECV,
    HP_ST_ARM_SEND,
    HP_ST_ARM_POLL,
    HP_ST_ARM_FAIL,    /* an arm could not be queued (ring full / state) */
    HP_ST_CLOSE,       /* stream_close calls (connection ends) */
    HP_ST_ACCEPT,      /* accepted connections */
    HP_ST_SEND_CHUNK,  /* send-payload copies queued (malloc per chunk) */
    HP_ST_STR_NEW,     /* hstr allocations */
    HP_ST_SCOPE_END,   /* poll cycles / memory scopes closed */
    HP_ST_N
};
extern uint64_t hp_st[HP_ST_N];

/* ---------- strings: length-prefixed, refcounted ---------- */
/* hstr flags */
#define HP_F_STATIC 1u  /* interned literal: lives in the literal table forever */
#define HP_F_SCOPED 2u  /* owned by the current request scope: freed by hp_scope_end */

struct hstr {
    size_t len;         /* byte length (PHP-style byte strings) */
    size_t cap;         /* allocated bytes incl. NUL; >= len+1 */
    uint32_t hash;      /* 0 = not computed */
    uint32_t rc;
    uint32_t flags;     /* HP_F_STATIC / HP_F_SCOPED */
    char data[];        /* NUL-terminated for C interop */
};

hstr *hp_str_lit(const char *cstr);
hstr *hp_char_str(unsigned char c);   /* shared 1-byte string (never freed) */
hstr *hp_str_intern(const char *cstr);   /* cached literal, rc == 0 */
/* Request scope: strings allocated between begin/end are released in one
 * shot by hp_scope_end(). Values that must outlive the scope are copied out
 * with hp_str_persist(). */
void hp_scope_begin(void);
void hp_scope_end(void);
hstr *hp_str_persist(hstr *s);
hstr *hp_str_new(const char *bytes, size_t len);
hstr *hp_str_copy(hstr *s);
void hp_str_free(hstr *s);
bool hp_str_eq(hstr *a, hstr *b);
int hp_str_cmp(hstr *a, hstr *b);
hstr *hp_str_concat2(hstr *a, hstr *b);
hstr *hp_str_concat_n(int n, const hval *vals); /* array of hvals */
hstr *hp_str_concat_v(hval a, hval b);          /* PHP '.' on any two values */
hstr *hp_str_join_v(hval a, hval b);            /* '.' as a value: never mutates a */
hstr *hp_str_append_v(hval a, hval b);          /* '.=' : lhs may grow in place */
hstr *hp_str_slice(hstr *s, int64_t start, int64_t end);
hstr *hp_str_char_at(hstr *s, int64_t idx);
int64_t hp_str_len(hstr *s);
int64_t hp_str_index(hstr *haystack, hstr *needle);
hstr *hp_str_from_int(int64_t v);
hstr *hp_str_from_double(double v);
hstr *hp_str_from_bool(bool b);
int64_t hp_str_to_int(hstr *s);
double hp_str_to_double(hstr *s);
bool hp_str_is_numeric(hstr *s); /* PHP is_numeric() on a string value */
uint32_t hp_str_hash(hstr *s);
hstr *hp_str_toupper(hstr *s);
hstr *hp_str_tolower(hstr *s);
hstr *hp_str_repeat(hstr *s, int64_t n);
hstr *hp_str_replace(hstr *subject, hstr *search, hstr *replace);
hstr *hp_str_trim(hstr *s);
hstr *hp_str_reverse(hstr *s);

/* ---------- dynamic value (PHP zval analogue) ---------- */
typedef enum {
    HV_NULL = 0, HV_INT, HV_FLOAT, HV_BOOL, HV_STR, HV_ARR, HV_OBJ, HV_CLO
} HKind;

struct hval {
    HKind tag;
    union {
        int64_t i;
        double f;
        bool b;
        hstr *s;
        harr *a;
        void *p;
        hclosure *c;
    } u;
};

hval hp_of_float(double f);
hval hp_of_arr(harr *a);
hval hp_of_ptr(void *p);
hval hp_of_clo(hclosure *c);

/* The hot boxing/unboxing paths are inline: every builtin call and every
 * array index goes through them, and a function call there shows up in the
 * profile. The slow cases live in hphp_rt.c. */
static inline hval hp_of_int(int64_t i) {
    hval v;
    v.tag = HV_INT;
    v.u.i = i;
    return v;
}
static inline hval hp_of_bool(bool b) {
    hval v;
    v.tag = HV_BOOL;
    v.u.i = 0;      /* the whole union, so no uninitialised bytes travel */
    v.u.b = b;
    return v;
}
static inline hval hp_of_str(hstr *s) {
    hval v;
    v.tag = HV_STR;
    v.u.s = s;
    return v;
}
int64_t hp_val_to_int_slow(hval v);
static inline int64_t hp_val_to_int(hval v) {
    if (v.tag == HV_INT) return v.u.i;
    return hp_val_to_int_slow(v);
}
static inline hval hp_hv_id(hval v) { return v; }
#define hv(x) _Generic((x), \
    hval: hp_hv_id, \
    int: hp_of_int, \
    long long: hp_of_int, \
    unsigned long long: hp_of_int, \
    long: hp_of_int, \
    unsigned int: hp_of_int, \
    double: hp_of_float, \
    bool: hp_of_bool, \
    hstr*: hp_of_str, \
    harr*: hp_of_arr, \
    hclosure*: hp_of_clo, \
    default: hp_of_ptr)(x)

extern hval hp_null;
hstr *hp_null_str(void);
harr *hp_null_arr(void);
void hp_val_free(hval v);
void hp_val_rc_inc(hval v);
void hp_val_rc_dec(hval v);
const char *hp_kind_name(HKind k);
hstr *hp_val_to_str(hval v);       /* PHP-style cast to string */
int64_t hp_val_to_int(hval v);
double hp_val_to_float(hval v);
bool hp_val_to_bool(hval v);
bool hp_val_eq(hval a, hval b);    /* == */
int64_t hp_val_cmp(hval a, hval b);/* <=> */
HKind hp_tag(hval v);

/* ---------- arrays / maps (COW) ---------- */
struct harr {
    size_t len, cap;
    uint32_t rc;
    bool is_map;
    int64_t next_index;
    hval *vals;
    hval *keys;         /* for maps; NULL for plain arrays */
    /* ---- open-addressing hash index for maps (lazily built) ----
     * slots store value-slot+1; 0 = empty. -1u marks a deleted slot.
     * Rebuilt whenever len changes beyond the incremental budget. */
    uint32_t *index;    /* hash -> slot+1 table; NULL = not built */
    uint32_t icap;      /* power of two, or 0 */
    uint32_t ibudget;   /* inserts until full rebuild (tombstone pressure) */
};

harr *hp_arr_new(void);
harr *hp_arr_of(int n, const hval *vals);      /* counted hval array */
harr *hp_map_of(int n, const hval *kvs);       /* k,v,k,v... counted */
harr *hp_arr_clone(harr *a);   /* deep copy */
harr *hp_arr_cow(harr *a);     /* returns a writable version (COW) */
void hp_arr_push(harr *a, hval v);
hval hp_arr_push_v(harr *a, hval v);   /* PHP $a[] = v; returns the array ptr as hval */
harr *hp_val_to_arr(hval v);               /* PHP (array) cast */
hval hp_arr_push_vv(hval container, hval v); /* append through a boxed (hval) container */
hval hp_val_clone_v(hval v);           /* value-semantics copy: deep-clones arrays */
int64_t hp_pow_i(int64_t a, int64_t b); /* integer pow for ** on ints */
hval hp_arr_pop(harr *a);
hval hp_arr_shift(harr *a);
void hp_arr_unshift(harr *a, hval v);
hval hp_arr_get(harr *a, hval idx);
hval hp_arr_get_v(hval container, hval idx); /* PHP-style: index any value */
void hp_arr_set_v(hval container, hval idx, hval v); /* set on hval container */
void hp_arr_set(harr *a, hval idx, hval v);
bool hp_arr_has(harr *a, hval key);
void hp_arr_unset(harr *a, hval key);
int64_t hp_arr_len(harr *a);
harr *hp_arr_slice(harr *a, int64_t start, int64_t end);
harr *hp_arr_keys(harr *a);
harr *hp_arr_values(harr *a);
harr *hp_arr_merge(harr *a, harr *b);
harr *hp_arr_reverse(harr *a);
bool hp_arr_in(harr *a, hval v);
harr *hp_arr_sort(harr *a);
harr *hp_arr_rsort(harr *a);
harr *hp_map_sort_by_key(harr *a);
hval hp_arr_sum(harr *a);
harr *hp_arr_unique(harr *a);
harr *hp_range(int64_t lo, int64_t hi);
void hp_arr_free(harr *a);

/* foreach protocol */
typedef struct {
    harr *a;
    hstr *s;
    size_t pos;
    int64_t i;
    hval k;
    bool is_str;
} hp_foreach_ctx;
hp_foreach_ctx hp_arr_iter(harr *a);
hp_foreach_ctx hp_map_iter(harr *a);
hp_foreach_ctx hp_val_iter(hval v);   /* foreach over a dynamic value */
hp_foreach_ctx hp_str_iter(hstr *s);
extern hval hpv_tmp;
bool hp_foreach_next(hp_foreach_ctx *ctx, hval *out);

/* ---------- dynamic operators ---------- */
hval hp_add(hval a, hval b);
hval hp_sub(hval a, hval b);
hval hp_mul(hval a, hval b);
hval hpbi_scalar_sub(hval a, hval b);
hval hpbi_scalar_mul(hval a, hval b);
hval hp_divv(hval a, hval b);
bool hp_streq(hval a, hval b);
bool hp_ident_eq(hval a, hval b);
hval hpbi_stream_socket_accept2(hval srv, hval timeout_ms);
hval hpbi_accept_emfile(void);
bool hp_lt(hval a, hval b);
bool hp_gt(hval a, hval b);
bool hp_le(hval a, hval b);
bool hp_ge(hval a, hval b);
/* scalar fast paths for generated code */
static inline bool hp_le_i(int64_t a, int64_t b) { return a <= b; }
static inline bool hp_ge_i(int64_t a, int64_t b) { return a >= b; }
static inline bool hp_lt_i(int64_t a, int64_t b) { return a < b; }
static inline bool hp_gt_i(int64_t a, int64_t b) { return a > b; }
/* PHP-semantics modulo, inline so hot loops stay call-free (gcc can turn
 * `x % 7` into a magic-number multiply); throws "Modulo by zero" like hp_mod */
void hp_throw_str(const char *msg);   /* fwd: real decl below */
static inline int64_t hp_mod_i(int64_t a, int64_t b) {
    if (b == 0) hp_throw_str("Modulo by zero");
    return a % b;
}
static inline bool hp_le_f(double a, double b) { return a <= b; }
static inline bool hp_ge_f(double a, double b) { return a >= b; }
static inline bool hp_lt_f(double a, double b) { return a < b; }
static inline bool hp_gt_f(double a, double b) { return a > b; }
static inline bool hp_eq_f(double a, double b) { return a == b; }
int64_t hp_cmp(hval a, hval b);   /* spaceship on hvals */
int64_t hp_mod(int64_t a, int64_t b);
hval hp_powv(hval a, hval b);
hval hp_nullcoal(hval a, hval b);
hval hp_match_any(hval subj, hval *pats, size_t n);
hval hp_match_no_default(void);
/* inline so gcc folds the zero-check away for literal divisors
 * (e.g. `$x / 2` becomes one divsd instruction) */
static inline double hp_div(double a, double b) {
    if (b == 0.0) hp_throw_str("Division by zero");
    return a / b;
}

/* ---------- exceptions ---------- */
typedef struct hp_try_frame {
    jmp_buf jmp;
    struct hp_try_frame *prev;
    bool caught;
} hp_try_frame;
/* thread-local interpreter state: worker threads (hphp_thr.c) get their own
 * try-stack and exception slot, so throw/catch works inside workers */
#define HP_THREAD_QUAL __thread
extern HP_THREAD_QUAL hp_try_frame *hp_cur_try;
extern HP_THREAD_QUAL hval hp_exception;
void hp_try_push(hp_try_frame *f);
void hp_try_pop(hp_try_frame *f);
void hp_throw(hval v);
void hp_throw_str(const char *msg);
hstr *hp_exception_msg(void);

/* try/catch runner: setjmp lives HERE so generated functions never
 * contain setjmp — no volatile locals, no register-clobber UB at -O2.
 * body_fn(env, hp_null) runs the try body; on a throw catch_fn(env, exc)
 * runs the handler. Returning a non-null hval from the handler means
 * "unhandled": the value comes back here so the caller can run its finally
 * block before rethrowing with hp_throw(). */
typedef hval (*hp_try_fn)(void *env, hval exv);
hval hp_try_run(hp_try_fn body_fn, hp_try_fn catch_fn, void *env);

/* ---------- closures ---------- */
typedef hval (*hfn_t)(void);
struct hclosure {
    hfn_t fn;
    uint32_t rc;
    size_t envsz;
    /* environment bytes follow */
};
hclosure *hpclosure_new(void *env, size_t envsz, void *fn);
void hpclosure_free(hclosure *c);
void *hp_closure_env(void);                       /* env of the running closure */
hval hp_closure_call_arr(hclosure *c, hval *args, int nargs);
hval hp_closure_call(hclosure *c, int nargs, const hval *args);
hval hp_call_value(hval fn, int nargs, const hval *args);

/* ---------- smart pointer support ---------- */
void hp_rc_inc(void *p);
void hp_rc_dec(void *p);

/* ---------- objects ---------- */
struct hobj {
    uint32_t rc;
};

void *hp_alloc(size_t n);
void hp_free(void *p);           /* counterpart of hp_alloc: keeps the live counter honest */
int64_t hp_live_allocs(void);   /* diagnostic: live hp_alloc blocks */
int64_t hp_live_bytes(void);    /* diagnostic: glibc in-use heap bytes */
void hp_echo(hval v);              /* PHP echo: print value */

/* ---------- builtin function entry points (hphp_std.c) ---------- */
hval hpbi_strlen(hval s);
hval hpbi_count(hval a);
hval hpbi_sizeof(hval a);
hval hpbi_strtoupper(hval s);
hval hpbi_strtolower(hval s);
hval hpbi_ucfirst(hval s);
hval hpbi_lcfirst(hval s);
hval hpbi_trim(hval s);
hval hpbi_ltrim(hval s, hval chars);
hval hpbi_rtrim(hval s, hval chars);
hval hpbi_chop(hval s);
hval hpbi_strrev(hval s);
hval hpbi_str_repeat(hval s, hval n);
hval hpbi_str_pad(hval s, hval n, hval pad);
hval hpbi_str_replace(hval subject, hval search, hval replace);
hval hpbi_substr(hval s, hval start, hval len);
hval hpbi_strstr(hval h, hval n);
hval hpbi_strchr(hval h, hval n);
hval hpbi_strpos(hval h, hval n, hval off);
hval hpbi_str_pos_ci(hval h, hval n, hval off);
hval hpbi_str_prefix_ci(hval s, hval p);
hval hpbi_str_int_range(hval s, hval a, hval b);
hval hpbi_str_trim_range(hval s, hval a, hval b);
hval hpbi_str_at_eq(hval s, hval start, hval len, hval lit);
hval hpbi_str_to_int(hval s);
hval hpbi_str_contains(hval h, hval n);
hval hpbi_str_starts_with(hval h, hval n);
hval hpbi_str_ends_with(hval h, hval n);
hval hpbi_strcmp(hval a, hval b);
hval hpbi_strncmp(hval a, hval b, hval n);
hval hpbi_strcasecmp(hval a, hval b);
hval hpbi_strncasecmp(hval a, hval b, hval n);
hval hpbi_explode(hval sep, hval s);
hval hpbi_split(hval sep, hval s);
hval hpbi_implode(hval glue, hval arr);
hval hpbi_join(hval glue, hval arr);
hval hpbi_nl2br(hval s);
hval hpbi_number_format(hval n, hval dec, hval dsep, hval tsep);
hval hpbi_unset(harr *a, hval key);
hval hpbi_json_encode(hval v);
hval hpbi_json_encode2(hval v, hval flags);      /* flags & 1 = JSON_PRETTY_PRINT */

/* ---- regex ---- */
hval hpbi_preg_match(hval pat, hval subj);
hval hpbi_preg_match_all(hval pat, hval subj);
hval hpbi_preg_match3(hval pat, hval subj, hval *out);
hval hpbi_preg_match_all3(hval pat, hval subj, hval *out);
hval hpbi_preg_replace(hval pat, hval rep, hval subj);
hval hpbi_preg_split(hval pat, hval subj);
hval hpbi_preg_grep(hval pat, hval arr);

/* ---- crypto ---- */
hval hpbi_sha256(hval s);
hval hpbi_hash_hmac(hval algo, hval data, hval key, hval raw_output);
hval hpbi_jwt_verify(hval tok, hval secret, hval now);
hstr *hp_jwt_verify_t(hstr *tok, hstr *secret, int64_t now);
hval hpbi_json_str_field(hval j, hval k);
hval hpbi_json_num_field(hval j, hval k);
hstr *hp_json_str_field_t(hstr *j, hstr *key);
int64_t hp_json_num_field_t(hstr *j, hstr *key);
hval hpbi_password_hash(hval pw);
hval hpbi_password_verify(hval pw, hval hash);
hval hpbi_random_bytes(hval n);
hval hpbi_hash_equals(hval known, hval user);

/* ---- time ---- */
hval hpbi_mktime(hval hour, hval min, hval sec, hval mon, hval day, hval year);
hval hpbi_strtotime(hval s);

/* ---- http extras ---- */
hval hpbi_http_post(hval url, hval body, hval headers);
hval hpbi_parse_url(hval url);
hval hpbi_http_build_query(hval d);

/* ---- mysql ---- */
hval hpbi_mysql_connect(hval host, hval port, hval user, hval pass, hval db);
hval hpbi_mysql_query(hval conn, hval sql);
hval hpbi_mysql_exec(hval conn, hval sql);
hval hpbi_mysql_insert_id(hval conn);
hval hpbi_mysql_close(hval conn);
hval hpbi_mysql_escape(hval s);
hval hpbi_json_decode(hval s);
hval hpbi_json_decode2(hval v, hval assoc);
hval hpbi_md5(hval s, hval raw_output);   /* real MD5; raw=true -> 16 bytes */
hval hpbi_sha1(hval s, hval raw_output);  /* real SHA-1; raw=true -> 20 bytes */

/* sockets (see hphp_std.c) — handles are integers, non-blocking by default */
hval hpbi_stream_socket_server(hval addr);       /* "tcp://host:port" */
hval hpbi_stream_socket_client(hval addr);
hval hpbi_stream_socket_accept(hval srv);
hval hpbi_stream_set_blocking(hval s, hval block);
hval hpbi_stream_set_nodelay(hval s);
hval hpbi_stream_recv(hval s, hval max);
hval hpbi_stream_send(hval s, hval data);
hval hpbi_stream_send2(hval s, hval a, hval b);
hval hpbi_stream_send_nb(hval s, hval data);
hval hpbi_stream_send2_nb(hval s, hval a, hval b);
hval hpbi_stream_send_sb(hval s, hval sb);
hval hpbi_int_digits(hval n);
hval hpbi_nofile_limit(void);
hval hpbi_runtime_stats(void);
hstr *hp_runtime_stats_t(void);
hval hpbi_stream_ready(hval handles, hval timeout_ms);
hval hpbi_stream_ready_into(hval out, hval handles, hval timeout_ms);
hval hpbi_epoll_add(hval s);
hval hpbi_epoll_del(hval s);
hval hpbi_epoll_mod(hval s, hval mask);
hval hpbi_epoll_wait2(hval in, hval out, hval timeout_ms);
hval hpbi_epoll_wait_into(hval out, hval timeout_ms);
hval hpbi_stream_eof(hval s);
hval hpbi_stream_peer(hval s);
hval hpbi_stream_close(hval s);
hval hpbi_crc32(hval s);

/* threading (see hphp_thr.c) — ids are integers, closures run on real OS threads */
hval hpbi_thr_spawn(hval clo, hval args);
hval hpbi_thr_join(hval tid);
hval hpbi_thr_current(void);
hval hpbi_thr_id(void);
hval hpbi_thr_sleep_ms(hval ms);
hval hpbi_thr_cpu_count(void);
hval hpbi_thr_parallel_map(hval clo, hval items, hval workers);
hval hpbi_chan_new(hval cap);
hval hpbi_chan_send(hval ch, hval v);       /* throws on closed channel */
hval hpbi_chan_recv(hval ch);               /* value, or false when closed+drained */
hval hpbi_chan_try_send(hval ch, hval v);   /* false instead of blocking */
hval hpbi_chan_try_recv(hval ch);           /* value, or false when nothing ready */
hval hpbi_chan_close(hval ch);
hval hpbi_mutex_new(void);
hval hpbi_mutex_lock(hval m);
hval hpbi_mutex_trylock(hval m);
hval hpbi_mutex_unlock(hval m);
hval hpbi_mutex_free(hval m);
hval hpbi_barrier_new(hval n);
hval hpbi_barrier_wait(hval b);             /* arrival index; last thread gets n-1 */
hval hpbi_atomic_new(hval init);
hval hpbi_atomic_get(hval a);
hval hpbi_atomic_set(hval a, hval v);
hval hpbi_atomic_add(hval a, hval delta);   /* returns the previous value */
hval hpbi_atomic_cas(hval a, hval expect, hval set);
hval hpbi_unset_slot(harr **slot, hval key);   /* unset($obj->arr[$k]) */
hval hpbi_base64_encode(hval s);
hval hpbi_base64_decode(hval s);
hval hpbi_urlencode(hval s);
hval hpbi_urldecode(hval s);
hval hpbi_htmlentities(hval s);
hval hpbi_htmlspecialchars(hval s);
hval hpbi_sprintf(hval fmt, hval args);
hval hpbi_printf(hval fmt, hval args);
hval hpbi_ord(hval s);
hval hpbi_chr(hval n);
hval hpbi_bin2hex(hval s);
hval hpbi_hex2bin(hval s);
hval hpbi_str_split(hval s, hval n);
hval hpbi_ucwords(hval s);
hval hpbi_wordwrap(hval s, hval w);
hval hpbi_similar_text(hval a, hval b);
hval hpbi_levenshtein(hval a, hval b);
hval hpbi_array_keys(hval a);
hval hpbi_array_values(hval a);
hval hpbi_array_merge(hval a, hval b, hval c, hval d);
hval hpbi_array_slice(hval a, hval off, hval len);
hval hpbi_array_reverse(hval a);
hval hpbi_array_sum(hval a);
hval hpbi_array_product(hval a);
hval hpbi_array_unique(hval a);
hval hpbi_in_array(hval needle, hval hay);
hval hpbi_array_search(hval needle, hval hay);
hval hpbi_array_key_exists(hval k, hval a);
hval hpbi_isset(hval v);
hval hpbi_isset_raw(harr **slot, hval key);
hval hpbi_isset_val(hval *slot, hval key);
hval hpbi_range(hval lo, hval hi);
hval hpbi_array_map(hval fn, hval a);
hval hpbi_array_filter(hval a, hval fn);
hval hpbi_array_reduce(hval a, hval fn, hval init);
hval hpbi_array_flip(hval a);
hval hpbi_array_fill(hval start, hval n, hval v);
hval hpbi_array_combine(hval keys, hval vals);
hval hpbi_array_diff(hval a, hval b, hval c, hval d);
hval hpbi_array_intersect(hval a, hval b, hval c, hval d);
hval hpbi_array_push(hval a, hval v);
hval hpbi_array_pop(hval a);
hval hpbi_end(hval a);
hval hpbi_reset(hval a);
hval hpbi_array_shift(hval a);
hval hpbi_array_unshift(hval a, hval v);
hval hpbi_array_splice(hval a, hval off, hval len);
hval hpbi_shuffle(hval a);
hval hpbi_sort(hval a);
hval hpbi_rsort(hval a);
hval hpbi_ksort(hval a);
hval hpbi_krsort(hval a);
hval hpbi_asort(hval a);
hval hpbi_max(hval a);
hval hpbi_min(hval a);
hval hpbi_abs(hval v);
hval hpbi_round(hval v, hval prec, hval mode);
hval hpbi_floor(hval v);
hval hpbi_ceil(hval v);
hval hpbi_sqrt(hval v);
hval hpbi_pow(hval a, hval b);
hval hpbi_intdiv(hval a, hval b);
hval hpbi_fmod(hval a, hval b);
hval hpbi_sin(hval v);
hval hpbi_cos(hval v);
hval hpbi_tan(hval v);
hval hpbi_atan(hval v);
hval hpbi_atan2(hval a, hval b);
hval hpbi_asin(hval v);
hval hpbi_acos(hval v);
hval hpbi_log(hval v);
hval hpbi_log2(hval v);
hval hpbi_log10(hval v);
hval hpbi_exp(hval v);
hval hpbi_is_nan(hval v);
hval hpbi_is_finite(hval v);
hval hpbi_is_infinite(hval v);
hval hpbi_pi(void);
hval hpbi_deg2rad(hval v);
hval hpbi_rad2deg(hval v);
hval hpbi_hypot(hval a, hval b);
hval hpbi_is_int(hval v);
hval hpbi_is_integer(hval v);
hval hpbi_is_float(hval v);
hval hpbi_is_string(hval v);
hval hpbi_is_bool(hval v);
hval hpbi_is_array(hval v);
hval hpbi_is_null(hval v);
hval hpbi_is_numeric(hval v);
hval hpbi_intval(hval v);
hval hpbi_floatval(hval v);
hval hpbi_doubleval(hval v);
hval hpbi_strval(hval v);
hval hpbi_boolval(hval v);
hval hpbi_gettype(hval v);
hval hpbi_var_dump(hval v);
hval hpbi_print_r(hval v);
hval hpbi_var_export(hval v);
hval hpbi_serialize(hval v);
hval hpbi_unserialize(hval s);
hval hpbi_readline(hval prompt);
hval hpbi_rand(hval mn, hval mx);
hval hpbi_mt_rand(hval mn, hval mx);
hval hpbi_srand(hval seed);
hval hpbi_mt_srand(hval seed);
hval hpbi_random_int(hval mn, hval mx);
hval hpbi_fgetc(hval stream);

/* filesystem helpers */
hval hpbi_getcwd(void);
hval hpbi_file_exists(hval path);
hval hpbi_is_dir(hval path);
hval hpbi_filesize(hval path);
hval hpbi_mkdir(hval path, hval recursive, hval mode);
hval hpbi_rmdir(hval path);
hval hpbi_unlink(hval path);
hval hpbi_rename(hval from, hval to);
hval hpbi_copy(hval from, hval to);
hval hpbi_fgets(hval path);
hval hpbi_fwrite(hval path, hval data);
hval hpbi_fopen(hval path, hval mode);
hval hpbi_fclose(hval path);
hval hpbi_scandir(hval path);

/* number base conversion */
hval hpbi_decbin(hval n);
hval hpbi_decoct(hval n);
hval hpbi_dechex(hval n);
hval hpbi_bindec(hval s);
hval hpbi_octdec(hval s);
hval hpbi_hexdec(hval s);
hval hpbi_file_get_contents(hval path);
hval hpbi_file_put_contents(hval path, hval data, hval flags);
hval hpbi_getenv(hval name);
hval hpbi_putenv(hval kv);
hval hpbi_php_uname(void);
hval hpbi_phpversion(void);
hval hpbi_php_sapi_name(void);
hval hpbi_microtime(void);
hval hpbi_hrtime(hval as_number);
hval hpbi_memory_get_usage(void);
hval hpbi_memory_get_peak_usage(void);
hval hpbi_gc_collect_cycles(void);
hval hpbi_date2(hval fmt, hval ts);   /* ts = null -> now */
hval hpbi_time(void);
hval hpbi_usleep(hval us);
hval hpbi_sleep(hval s);
hval hpbi_exit(hval code);
hval hpbi_die(hval code);

/* ---------- lifecycle ---------- */
void hp_init(void);
void hp_shutdown(void);

/* PHP superglobal support + randomness */
harr *hp_argv_from_c(int argc, char **argv);
extern int hp_argc_global;
int64_t hp_rand(void);
int64_t hp_rand_range(int64_t min, int64_t max);
double hp_mt_rand(void);

/* ---------- UI layer (Win32; no-op stubs elsewhere) ---------- */
/* Controls live in a runtime-side table; hval slots carry the int handle. */
#define HPUI_WINDOW 1
#define HPUI_BUTTON 2
#define HPUI_LABEL 3
#define HPUI_INPUT 4
#define HPUI_CHECKBOX 5
#define HPUI_LIST 6
#define HPUI_COMBO 7
#define HPUI_PROGRESS 8
#define HPUI_SLIDER 9
#define HPUI_GROUP 10
#define HPUI_TAB 11
#define HPUI_PANEL 12
#define HPUI_MENU 13
#define HPUI_MENUITEM 14
#define HPUI_PICTURE 15
#define HPUI_TIMER 16
#define HPUI_DIVIDER 17
#define HPUI_CANVAS 18

/* Canvas input events, passed to hpui_on_event(). 1-5 keep the original
 * meanings (click / change / action / key / drag); 6 upward are the canvas
 * ones, which report where the pointer was and which button was used.
 * A handler always receives (x, y, button_or_delta) for mouse events and
 * (vk, char, mods) for key events, so one binding table serves both. */
enum {
    HPUI_EV_CLICK  = 1,
    HPUI_EV_CHANGE = 2,
    HPUI_EV_ACTION = 3,
    HPUI_EV_KEY    = 4,
    HPUI_EV_DRAG   = 5,
    HPUI_EV_DOWN   = 6,   /* (x, y, button)  1 left, 2 right, 3 middle */
    HPUI_EV_UP     = 7,   /* (x, y, button)                            */
    HPUI_EV_MOVE   = 8,   /* (x, y, 0)      while inside or captured   */
    HPUI_EV_WHEEL  = 9,   /* (x, y, delta)  delta is a wheel notch     */
    HPUI_EV_RESIZE = 10,  /* (w, h, 0)      new logical size           */
    HPUI_EV_CHAR   = 11,  /* (codepoint, 0, 0) a typed character       */
    HPUI_EV_DBL    = 12,  /* (x, y, button)                            */
    HPUI_EV_LEAVE  = 13,  /* (0, 0, 0)                                 */
    HPUI_EV_ENTER  = 14,  /* (0, 0, 0)                                 */
    HPUI_EV_FOCUS  = 15,  /* (1 focused / 0 blurred, 0, 0)             */
    HPUI_EV_NEV    = 16
};

/* cursor shapes accepted by hpui_cursor_set() */
enum {
    HPUI_CUR_ARROW  = 0, HPUI_CUR_IBEAM = 1, HPUI_CUR_HAND = 2,
    HPUI_CUR_SIZEWE = 3, HPUI_CUR_SIZENS = 4, HPUI_CUR_SIZEALL = 5,
    HPUI_CUR_CROSS  = 6, HPUI_CUR_NO = 7
};

void hpui_init(void);
int64_t hpui_dispatch(int ms);            /* pump events up to ms, 0 = block */
int64_t hpui_dpi_scale(void);            /* device pixels per 96-dpi logical px */
void hpui_run_main(void);                 /* blocking GetMessage loop */
void hpui_quit(void);                     /* post WM_QUIT */

int64_t hpui_window_new(const char *title, int x, int y, int w, int h);
int64_t hpui_window_show(int64_t win, bool visible);
int64_t hpui_window_title(int64_t win, const char *title);
int64_t hpui_window_size(int64_t win, int w, int h);
int64_t hpui_window_pos(int64_t win, int x, int y);
int64_t hpui_window_close(int64_t win);
bool hpui_window_alive(int64_t win);

int64_t hpui_ctrl_new(int64_t kind, int64_t parent, const char *text,
                      int x, int y, int w, int h);
int64_t hpui_ctrl_set_text(int64_t h, const char *text);
int64_t hpui_ctrl_text(int64_t h, hstr **out);          /* returns 0/-1 */
int64_t hpui_ctrl_show(int64_t h, bool visible);
int64_t hpui_ctrl_enable(int64_t h, bool enabled);
int64_t hpui_ctrl_move(int64_t h, int x, int y, int w, int hgt);
int64_t hpui_ctrl_focus(int64_t h);
int64_t hpui_ctrl_select_all(int64_t h);
int64_t hpui_list_add(int64_t h, const char *item);
int64_t hpui_list_clear(int64_t h);
int64_t hpui_list_remove(int64_t h, int64_t index);
int64_t hpui_list_count(int64_t h, int64_t *out);
int64_t hpui_list_selected(int64_t h, int64_t *out);
int64_t hpui_list_select(int64_t h, int64_t index);
int64_t hpui_list_text(int64_t h, int64_t index, hstr **out);
int64_t hpui_check_get(int64_t h, bool *out);
int64_t hpui_check_set(int64_t h, bool on);
int64_t hpui_progress_set(int64_t h, int64_t pct);
int64_t hpui_progress_get(int64_t h);
int64_t hpui_slider_get(int64_t h, int64_t *out);
int64_t hpui_slider_set(int64_t h, int64_t pos);
int64_t hpui_ctrl_checked(int64_t h);                    /* menu item check */
int64_t hpui_ctrl_enabled(int64_t h);                   /* 1 = accepts input */
int64_t hpui_ctrl_rect(int64_t h, int64_t *x, int64_t *y, int64_t *w, int64_t *ht);
int64_t hpui_window_scroll(int64_t w, int dy, int to, int64_t *scroll, int64_t *content);
int64_t hpui_menu_new(int64_t win, const char *label);
int64_t hpui_menu_item(int64_t menu, const char *label, int64_t id);
int64_t hpui_menu_sep(int64_t menu);
int64_t hpui_ctrl_set_bg(int64_t h, int64_t rgb);
int64_t hpui_ctrl_set_fg(int64_t h, int64_t rgb);
int64_t hpui_ctrl_accent(int64_t h, int64_t rgb);
int64_t hpui_ctrl_radius(int64_t h, int64_t r);
int64_t hpui_ctrl_style(int64_t h, int64_t role);
int64_t hpui_ctrl_font(int64_t h, int64_t size, bool bold);
int64_t hpui_range_set(int64_t h, int64_t lo, int64_t hi);
int64_t hpui_repaint(int64_t h);
int64_t hpui_input_margin(int64_t h, int64_t l, int64_t r);
int64_t hpui_ctrl_svg(int64_t h, const char *source);
int64_t hpui_picture_load(int64_t h, const char *path);
int64_t hpui_ctrl_raise(int64_t h);
int64_t hpui_textw(const char *text, int pt, bool bold);
int64_t hpui_text_lines(const char *text, int pt, bool bold, int maxw);

/* --- canvas: a surface the script paints (see the HPUI_EV_* block above) ---
 * Every call takes the canvas handle and logical 96-dpi pixels. Drawing goes
 * into a backbuffer and reaches the screen on the next paint, or immediately
 * with hpui_canvas_flush(). Text is drawn with a font from the canvas font
 * table, whose id is what hpui_font_id() hands back. */
int64_t hpui_font_id(const char *family, int pt, bool bold, bool italic);
int64_t hpui_font_w(int64_t font_id, const char *text);
int64_t hpui_font_h(int64_t font_id);
int64_t hpui_draw_clear(int64_t canvas, int64_t rgb);
int64_t hpui_draw_rect(int64_t canvas, int x, int y, int w, int h, int64_t rgb);
int64_t hpui_draw_round(int64_t canvas, int x, int y, int w, int h, int radius,
                        int64_t fill, int64_t stroke, int stroke_w);
int64_t hpui_draw_line(int64_t canvas, int x1, int y1, int x2, int y2,
                       int64_t rgb, int w);
/* flags: 1 ellipsis, 2 centre vertically, 4 right align, 8 no clipping */
int64_t hpui_draw_text(int64_t canvas, int x, int y, int w, int h,
                       const char *text, int64_t rgb, int64_t font_id, int flags);
int64_t hpui_draw_clip(int64_t canvas, int x, int y, int w, int h);
int64_t hpui_draw_unclip(int64_t canvas);
int64_t hpui_canvas_size(int64_t canvas, int64_t *out_w, int64_t *out_h);
int64_t hpui_canvas_pixel(int64_t canvas, int x, int y);   /* 0xRRGGBB, -1 outside */
int64_t hpui_canvas_invalidate(int64_t canvas);
int64_t hpui_canvas_flush(int64_t canvas);
int64_t hpui_cursor_set(int64_t canvas, int64_t shape);
int64_t hpui_hwnd(int64_t win);                 /* raw HWND, for embedding */
int64_t hpui_client_size(int64_t win, int64_t *out_w, int64_t *out_h);
int64_t hpui_theme_set(int64_t win, const int64_t *v, int n);
int64_t hpui_picture_load(int64_t h, const char *path);

/* events: cb is a closure; id identifies which control fired */
int64_t hpui_on_event(int64_t handle, int64_t evtype, hval cb);
/* timer: id > 0; ms = 0 cancels */
int64_t hpui_timer(int64_t ms, hval cb);
/* message box; type 0=info 1=warn 2=error 3=question; returns 1/0 for yes/no */
int64_t hpui_msgbox(int64_t win, const char *title, const char *text, int type);
/* file/folder pickers; return hp_null on cancel */
hval hpui_open_file(int64_t win, const char *filter);
hval hpui_save_file(int64_t win, const char *filter);
hval hpui_pick_folder(int64_t win);
hval hpui_color_pick(int64_t win, int64_t init_rgb);
/* clipboard */
int64_t ui_clip_set(const char *text);
hval ui_clip_get(void);

/* UI builtins (implemented in hphp_std.c) */
hval hpbi_ui_dispatch(hval ms);
hval hpbi_ui_run_main(void);
hval hpbi_ui_quit(void);
hval hpbi_ui_window(hval title, hval x, hval y, hval w, hval hgt);
hval hpbi_ui_show(hval h, hval vis);
hval hpbi_ui_title(hval h, hval t);
hval hpbi_ui_size(hval h, hval w, hval hgt);
hval hpbi_ui_pos(hval h, hval x, hval y);
hval hpbi_ui_close(hval h);
hval hpbi_ui_alive(hval h);
hval hpbi_ui_add(hval parent, hval kind, hval text, hval x, hval y, hval w, hval hgt);
hval hpbi_ui_set(hval h, hval text);
hval hpbi_ui_get(hval h);
hval hpbi_ui_enable(hval h, hval on);
hval hpbi_ui_move(hval h, hval x, hval y, hval w, hval hgt);
hval hpbi_ui_focus(hval h);
hval hpbi_ui_select_all(hval h);
hval hpbi_ui_items(hval h, hval item);
hval hpbi_ui_remove(hval h, hval idx);
hval hpbi_ui_clear(hval h);
hval hpbi_ui_ctrl_show(hval h, hval vis);
hval hpbi_ui_selected(hval h);
hval hpbi_ui_select(hval h, hval idx);
hval hpbi_ui_item_text(hval h, hval idx);
hval hpbi_ui_check_get(hval h);
hval hpbi_ui_check_set(hval h, hval on);
hval hpbi_ui_progress(hval h, hval pct);
hval hpbi_ui_slider_get(hval h);
hval hpbi_ui_slider_set(hval h, hval pos);
hval hpbi_ui_bg(hval h, hval rgb);
hval hpbi_ui_fg(hval h, hval rgb);
hval hpbi_ui_font(hval h, hval size, hval bold);
hval hpbi_ui_menu(hval win, hval label);
hval hpbi_ui_menu_item(hval menu, hval label, hval cmdid);
hval hpbi_ui_menu_sep(hval menu);
hval hpbi_ui_menu_check(hval h);
hval hpbi_ui_on(hval h, hval ev, hval cb);
hval hpbi_ui_timer(hval ms, hval cb);
hval hpbi_ui_msg(hval win, hval title, hval text, hval type);
hval hpbi_ui_open_file(hval win, hval filter);
hval hpbi_ui_save_file(hval win, hval filter);
hval hpbi_ui_pick_folder(hval win);
hval hpbi_ui_pick_color(hval win, hval init);
hval hpbi_ui_clip_set(hval text);
hval hpbi_ui_clip_get(void);
hval hpbi_ui_style(hval h, hval role);
hval hpbi_ui_accent(hval h, hval rgb);
hval hpbi_ui_radius(hval h, hval r);
hval hpbi_ui_range(hval h, hval lo, hval hi);
hval hpbi_ui_repaint(hval h);
hval hpbi_ui_input_margin(hval h, hval l, hval r);
hval hpbi_ui_svg(hval h, hval source);
hval hpbi_ui_picture(hval h, hval path);
hval hpbi_ui_raise(hval h);
hval hpbi_ui_enabled(hval h);
hval hpbi_ui_rect(hval h);
hval hpbi_ui_client_size(hval win);
hval hpbi_ui_scroll(hval win, hval dy, hval to);
hval hpbi_ui_count(hval h);
hval hpbi_ui_progress_get(hval h);
hval hpbi_ui_text_px(hval s, hval pt, hval bold);
hval hpbi_ui_text_lines(hval s, hval pt, hval bold, hval maxw);
hval hpbi_ui_hwnd(hval win);
hval hpbi_ui_browser_ready(void);
hval hpbi_ui_browser_loader(void);
hval hpbi_ui_browser_new(hval parent, hval dir);
hval hpbi_ui_browser_free(hval b);
hval hpbi_ui_browser_fit(hval b, hval top, hval width);
hval hpbi_ui_browser_go(hval b, hval url);
hval hpbi_ui_browser_html(hval b, hval html);
hval hpbi_ui_browser_back(hval b);
hval hpbi_ui_browser_forward(hval b);
hval hpbi_ui_browser_reload(hval b);
hval hpbi_ui_browser_stop(hval b);
hval hpbi_ui_browser_can_back(hval b);
hval hpbi_ui_browser_can_forward(hval b);
hval hpbi_ui_browser_url(hval b);
hval hpbi_ui_browser_title(hval b);
hval hpbi_ui_browser_favicon(hval b);
hval hpbi_ui_browser_zoom(hval b, hval factor);
hval hpbi_ui_browser_zoom_get(hval b);
hval hpbi_ui_browser_devtools(hval b, hval on);
hval hpbi_ui_browser_devtools_fit(hval b, hval x, hval y, hval w, hval h);
hval hpbi_ui_browser_devtools_ready(hval b);
hval hpbi_ui_browser_print(hval b);
hval hpbi_ui_browser_post(hval b, hval json);
hval hpbi_ui_browser_visible(hval b, hval on);
hval hpbi_ui_browser_key(hval b, hval mod, hval vk, hval cmd, hval cb);
hval hpbi_ui_browser_on(hval b, hval ev, hval cb);

/* ---- embedded Chromium (WebView2), see hphp_wv2.c ---- */
int64_t hpwv2_available(void);
const char *hpwv2_loader_path(void);
int64_t hpwv2_create(int64_t parent_hwnd, const char *user_data_dir);
int64_t hpwv2_destroy(int64_t id);
int64_t hpwv2_fit(int64_t id, int top_logical, int width_logical);
int64_t hpwv2_navigate(int64_t id, const char *url);
int64_t hpwv2_html(int64_t id, const char *html);
int64_t hpwv2_back(int64_t id);
int64_t hpwv2_forward(int64_t id);
int64_t hpwv2_reload(int64_t id);
int64_t hpwv2_stop(int64_t id);
int64_t hpwv2_can_back(int64_t id);
int64_t hpwv2_can_forward(int64_t id);
int64_t hpwv2_url(int64_t id, char **out);
int64_t hpwv2_title(int64_t id, char **out);
int64_t hpwv2_favicon(int64_t id, char **out);
int64_t hpwv2_zoom(int64_t id, double factor);
int64_t hpwv2_zoom_get(int64_t id, double *out);
int64_t hpwv2_devtools(int64_t id, bool on);
int64_t hpwv2_devtools_fit(int64_t id, int x, int y, int w, int hgt);
int64_t hpwv2_devtools_ready(int64_t id);
int64_t hpwv2_print(int64_t id);
int64_t hpwv2_post(int64_t id, const char *json);
int64_t hpwv2_on(int64_t id, int64_t evtype, hval cb);
int64_t hpwv2_visible(int64_t id, bool on);
int64_t hpwv2_shortcut(int64_t id, int64_t mod, int64_t vk, int64_t cmd, hval cb);
/* Drain the engine's event queue. Called from the UI message loop so script
 * callbacks run on the VM thread; a no-op when the engine is not loaded. */
void hpwv2_drain_events(void);
/* Shut the engine down on the way out, so its profile is flushed. */
void hpwv2_shutdown(void);
int hpwv2_closing(void);
hval hpbi_ui_theme(hval win, hval bg, hval surface, hval elevated, hval text,
                   hval muted, hval accent, hval onAccent, hval border,
                   hval radius, hval fontPt, hval titlePt, hval rowH, hval dark);

/* heap boxes for by-ref captures (use (&$x)) */
hval *hp_box_new(void);
void hp_box_free(hval *b);

/* ---------- PHP 8 parity additions ---------- */
/* closure-based sorting / walking */
hval hpbi_usort(hval a, hval fn);
hval hpbi_uasort(hval a, hval fn);
hval hpbi_uksort(hval a, hval fn);
hval hpbi_array_walk(hval a, hval fn, hval userdata);
hval hpbi_array_walk_recursive(hval a, hval fn, hval userdata);
/* arrays */
hval hpbi_array_column(hval rows, hval col, hval index_key);
hval hpbi_array_chunk(hval a, hval size, hval preserve);
hval hpbi_array_pad(hval a, hval size, hval v);
hval hpbi_array_replace(hval a, hval b, hval c, hval d);
hval hpbi_array_fill_keys(hval keys, hval v);
hval hpbi_array_key_first(hval a);
hval hpbi_array_key_last(hval a);
hval hpbi_compact(hval a, hval b, hval c, hval d);
/* strings */
hval hpbi_vsprintf(hval fmt, hval args);
hval hpbi_substr_count(hval hay, hval needle);
hval hpbi_str_shuffle(hval s);
hval hpbi_strip_tags(hval s, hval allowed);
hval hpbi_html_entity_decode(hval s);
/* filesystem (paths) */
hval hpbi_dirname(hval path);
hval hpbi_basename(hval path, hval suffix);
hval hpbi_pathinfo(hval path, hval flags);
hval hpbi_realpath(hval path);
hval hpbi_is_file(hval path);
hval hpbi_is_readable(hval path);
hval hpbi_is_writable(hval path);
hval hpbi_touch(hval path);
hval hpbi_glob(hval pattern);
hval hpbi_sys_get_temp_dir(void);
hval hpbi_checkdate(hval m, hval d, hval y);
/* file handles */
hval hpbi_fread(hval fh, hval n);
hval hpbi_feof(hval fh);
/* http client (http:// only) */
hval hpbi_http_get(hval url);
hval hpbi_http_request(hval url, hval method, hval body, hval headers);

/* canvas builtins (canvas surface, drawing, fonts, input) */
hval hpbi_ui_font_new(hval family, hval pt, hval bold, hval italic);
hval hpbi_ui_font_width(hval font_id, hval text);
hval hpbi_ui_font_height(hval font_id);
hval hpbi_ui_draw_clear(hval cv, hval rgb);
hval hpbi_ui_draw_rect(hval cv, hval x, hval y, hval w, hval h, hval rgb);
hval hpbi_ui_draw_round(hval cv, hval x, hval y, hval w, hval h, hval radius,
                        hval fill, hval stroke, hval sw);
hval hpbi_ui_draw_line(hval cv, hval x1, hval y1, hval x2, hval y2, hval rgb, hval w);
hval hpbi_ui_draw_text(hval cv, hval x, hval y, hval w, hval h, hval text,
                       hval rgb, hval font_id, hval flags);
hval hpbi_ui_draw_clip(hval cv, hval x, hval y, hval w, hval h);
hval hpbi_ui_draw_unclip(hval cv);
hval hpbi_ui_canvas_size(hval cv);
hval hpbi_ui_canvas_pixel(hval cv, hval x, hval y);
hval hpbi_ui_canvas_invalidate(hval cv);
hval hpbi_ui_canvas_flush(hval cv);
hval hpbi_ui_cursor(hval cv, hval shape);

/* child processes (the integrated terminal and the runner): see
 * hphp_std.c - start, poll, feed and reap a console program */
hval hpbi_proc_start(hval cmd, hval cwd);
hval hpbi_proc_read(hval h, hval maxn);
hval hpbi_proc_read_err(hval h, hval maxn);
hval hpbi_proc_write(hval h, hval data);
hval hpbi_proc_alive(hval h);
hval hpbi_proc_exit(hval h);
hval hpbi_proc_close(hval h);
hval hpbi_shell_exec(hval cmd);
hval hpbi_exec(hval cmd, hval ret);
hval hpbi_passthru(hval cmd);
hval hpbi_proc_open(hval cmd, hval cwd);
hval hpbi_proc_get_status(hval h);
hval hpbi_proc_kill(hval h);

/* generic SQLite binding (hphp_std.c): open/prepare/bind/step/column */
hval hpbi_scope_begin(void);
hval hpbi_scope_end(void);
hval hpbi_str_persist(hval s);
hval hpbi_str_free(hval s);
hval hpbi_live_bytes(void);
hval hpbi_live_allocs(void);
hval hpbi_arr_clear(hval a);
hval hpbi_arr_free(hval a);
hval hpbi_bt_root(hval db, hval name, hval is_index);
hval hpbi_bt_open(hval db, hval name, hval is_index);
hval hpbi_bt_close(hval h);
hval hpbi_bt_first(hval h);
hval hpbi_bt_last(hval h);
hval hpbi_bt_next(hval h);
hval hpbi_bt_prev(hval h);
hval hpbi_bt_seek(hval h, hval rowid);
hval hpbi_bt_rowid(hval h);
hval hpbi_bt_payload_ptr(hval h);
hval hpbi_bt_payload_size(hval h);
hval hpbi_bt_count_key(hval h, hval key);
hval hpbi_sb_new(void);
hval hpbi_sb_put(hval h, hval str);
hval hpbi_sb_bytes(hval h, hval ptr, hval len);
hval hpbi_sb_int(hval h, hval n);
hval hpbi_sb_json(hval h, hval ptr, hval len);
hval hpbi_sb_json_str(hval h, hval str);
hval hpbi_str_from_bytes(hval ptr, hval len);
hval hpbi_sb_reserve(hval h, hval n);
hval hpbi_sb_take(hval h);
hval hpbi_iarr_new(hval size);
hval hpbi_iarr_get(hval h, hval i);
hval hpbi_iarr_set(hval h, hval i, hval v);
hval hpbi_sqlite_open(hval path);
hval hpbi_sqlite_close(hval db);
hval hpbi_sqlite_exec(hval db, hval sql);
hval hpbi_sqlite_prepare(hval db, hval sql);
hval hpbi_sqlite_finalize(hval stmt);
hval hpbi_sqlite_bind_int(hval stmt, hval idx, hval value);
hval hpbi_sqlite_bind_text(hval stmt, hval idx, hval value);
hval hpbi_sqlite_step(hval stmt);
hval hpbi_sqlite_reset(hval stmt);
hval hpbi_sqlite_clear_bindings(hval stmt);
hval hpbi_sqlite_column_text(hval stmt, hval col);
hval hpbi_sqlite_column_int(hval stmt, hval col);
hval hpbi_sqlite_changes(hval db);
hval hpbi_sqlite_last_insert_rowid(hval db);
hval hpbi_sqlite_errmsg(hval db);
hval hpbi_sqlite_busy_timeout(hval db, hval ms);

/* ---- typed builtin fast paths (see hphp_std.c) ---- */
int64_t hp_sb_new_t(void);
bool hp_sb_reserve_t(int64_t h, int64_t n);
bool hp_sb_put_t(int64_t h, hstr *s);
int64_t hp_sb_len_t(int64_t h);
bool hp_sb_prepend_t(int64_t h, hstr *s);
bool hp_sb_int_t(int64_t h, int64_t n);
bool hp_sb_json_t(int64_t h, int64_t ptr, int64_t len);
bool hp_sb_json_str_t(int64_t h, hstr *s);
hstr *hp_sb_take_t(int64_t h);
int64_t hp_stream_send_sb_t(int64_t fd, int64_t sb);
int64_t hp_int_digits_t(int64_t n);
int64_t hp_iarr_new_t(int64_t n);
int64_t hp_iarr_get_t(int64_t h, int64_t k);
bool hp_iarr_set_t(int64_t h, int64_t k, int64_t v);
int64_t hp_bt_last_t(int64_t h);
int64_t hp_bt_first_t(int64_t h);
int64_t hp_bt_prev_t(int64_t h);
int64_t hp_bt_next_t(int64_t h);
int64_t hp_bt_seek_t(int64_t h, int64_t rowid);
int64_t hp_bt_rowid_t(int64_t h);
int64_t hp_bt_payload_ptr_t(int64_t h);
int64_t hp_bt_cols_t(int64_t h);
int64_t hp_bt_col_off_t(int64_t i);
int64_t hp_bt_col_len_t(int64_t i);
int64_t hp_bt_col_int_t(int64_t i);
int64_t hp_bt_payload_size_t(int64_t h);
int64_t hp_stream_send_nb_t(int64_t fd, hstr *s);
int64_t hp_stream_send2_nb_t(int64_t fd, hstr *a, hstr *b);
bool hp_epoll_mod_t(int64_t fd, int64_t mask);
int64_t hp_nofile_limit_t(void);
bool hp_uring_active_t(void);
bool hp_uring_direct_t(void);
int64_t hp_uring_direct_slots_t(void);
int64_t hp_strlen_t(hstr *s);
int64_t hp_str_to_int_t(hstr *s);
bool hp_str_at_eq_t(hstr *s, int64_t start, int64_t len, hstr *lit);
hstr *hp_strtolower_t(hstr *s);
hstr *hp_trim_t(hstr *s);
hstr *hp_substr_t(hstr *s, int64_t start, int64_t len);
hstr *hp_stream_recv_t(int64_t fd, int64_t maxn);
bool hp_sqlite_bind_int_t(int64_t stmt, int64_t idx, int64_t v);
bool hp_sqlite_bind_text_t(int64_t stmt, int64_t idx, hstr *s);
int64_t hp_sqlite_step_t(int64_t stmt);
int64_t hp_sqlite_reset_t(int64_t stmt);
bool hp_sqlite_clear_bindings_t(int64_t stmt);
hstr *hp_sqlite_column_text_t(int64_t stmt, int64_t col);
int64_t hp_sqlite_column_int_t(int64_t stmt, int64_t col);
int64_t hp_sqlite_changes_t(int64_t db);


#ifdef __cplusplus
}
#endif
#endif
