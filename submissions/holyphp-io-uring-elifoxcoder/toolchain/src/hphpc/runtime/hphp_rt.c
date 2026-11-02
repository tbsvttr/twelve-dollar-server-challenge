/* hphp_rt.c — HolyPHP runtime: values, strings, arrays (COW), exceptions.
 *
 * Memory model:
 *   - strings and arrays are refcounted immutable-ish structures
 *   - arrays use copy-on-write: assignment shares; first write clones
 *   - objects are owned via own<T>/Rc<T> smart pointers (refcounted)
 *   - raw pointers only exist inside unsafe blocks; runtime helpers used
 *     there map directly onto C (malloc/free/memcpy/memset)
 *
 * POSIX: _DEFAULT_SOURCE must be defined before any system include (glibc
 * hides POSIX symbols under strict -std=c11 otherwise).
 */
#if !defined(_WIN32)
#define _DEFAULT_SOURCE 1
#endif

/* thread-local interpreter state (see hphp_thr.c): every worker thread
 * runs its own try-stack, exception slot and closure environment
 * (HP_THREAD_QUAL comes from hphp_rt.h) */
#include "hphp_rt.h"
#include <stdlib.h>
#if defined(__GLIBC__)
#include <malloc.h>
#endif
#include <string.h>
#include <stdio.h>
#include <math.h>
#include <ctype.h>
#include <time.h>

/* ---------------- allocation ---------------- */
static _Thread_local int64_t g_live_allocs = 0;
int64_t hp_live_allocs(void) { return g_live_allocs; }
int64_t hp_live_bytes(void) {
#if defined(__GLIBC__)
    struct mallinfo2 mi = mallinfo2();
    return (int64_t)mi.uordblks;
#else
    return 0;
#endif
}

void *hp_alloc(size_t n) {
    void *p = calloc(1, n ? n : 1);
    g_live_allocs++;
    if (!p) {
        fprintf(stderr, "Fatal error: Allowed memory size exhausted\n");
        exit(255);
    }
    return p;
}

/* Free a block from hp_alloc. The allocator is a plain calloc, so this is
 * free() plus the diagnostic counter -- callers that free a heap string or
 * builder must use hp_str_free/hp_free so hp_live_allocs stays a true leak
 * indicator. */
void hp_free(void *p) {
    if (!p) return;
    free(p);
    g_live_allocs--;
}

void hp_rc_inc(void *p) { (void)p; }
void hp_rc_dec(void *p) { (void)p; }

void hp_echo(hval v) {
    hstr *s = hp_val_to_str(v);
    fwrite(s->data, 1, s->len, stdout);
}

/* ---------------- string builder ---------------- */
void hbuf_init(Buf *b) { b->data = NULL; b->len = b->cap = 0; }

static void hbuf_grow_impl(Buf *b, size_t need) {
    if (b->len + need + 1 <= b->cap) return;
    size_t ncap = b->cap ? b->cap : 64;
    while (ncap < b->len + need + 1) ncap *= 2;
    b->data = realloc(b->data, ncap);
    if (!b->data) { fprintf(stderr, "Fatal error: out of memory\n"); exit(255); }
    b->cap = ncap;
}

void hbuf_grow_slow(Buf *b, size_t need) { hbuf_grow_impl(b, need); }
void hbuf_reserve(Buf *b, size_t n) { hbuf_grow_impl(b, n); }

void hbuf_puts(Buf *b, const char *s) { hbuf_write(b, s, strlen(s)); }

void hbuf_printf(Buf *b, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    va_list ap2;
    va_copy(ap2, ap);
    int n = vsnprintf(NULL, 0, fmt, ap);
    va_end(ap);
    if (n > 0) {
        hbuf_need(b, (size_t)n);
        vsnprintf(b->data + b->len, (size_t)n + 1, fmt, ap2);
        b->len += (size_t)n;
    }
    va_end(ap2);
}

char *hbuf_take(Buf *b) {
    if (!b->data) { b->data = malloc(1); b->data[0] = 0; }
    char *out = b->data;
    b->data = NULL;
    b->len = b->cap = 0;
    return out;
}

/* ---------------- strings ---------------- */

/* Request scope. A server loop wraps one poll cycle in hp_scope_begin() /
 * hp_scope_end(); every string allocated in between is released in one shot
 * when the cycle ends, instead of leaking one allocation per builtin call.
 * Values that must survive the cycle are copied out with hp_str_persist().
 * Outside a scope nothing changes: allocations are plain heap blocks. */
typedef struct hp_arena_blk { struct hp_arena_blk *next; size_t size; } hp_arena_blk;
/* Bump arena for the request scope. Blocks are allocated once and reused for
 * every following scope: a request carves ~20 strings out of one block, and
 * hp_scope_end() only rewinds the bump pointer. */
static _Thread_local hp_arena_blk *g_ablocks = NULL;   /* in allocation order */
static _Thread_local hp_arena_blk *g_acur_blk = NULL;
static _Thread_local char *g_acur = NULL;
static _Thread_local size_t g_aleft = 0;
static _Thread_local int g_scope_depth = 0;

#define HP_ARENA_BLOCK (256u * 1024u)

static void hp_arena_reset(void) {
    g_acur_blk = g_ablocks;
    if (g_acur_blk) {
        g_acur = (char *)(g_acur_blk + 1);
        g_aleft = g_acur_blk->size;
    } else {
        g_acur = NULL;
        g_aleft = 0;
    }
}

void hp_scope_begin(void) { g_scope_depth++; }

void hp_scope_end(void) {
    if (g_scope_depth == 0) return;
    if (--g_scope_depth > 0) return;
    hp_st[HP_ST_SCOPE_END]++;
    hp_arena_reset();
}

static void *hp_arena_alloc(size_t n) {
    n = (n + 15u) & ~(size_t)15u;
    if (n > g_aleft) {
        hp_arena_blk *b = g_acur_blk ? g_acur_blk->next : g_ablocks;
        while (b && b->size < n) b = b->next;
        if (!b) {
            size_t need = n > HP_ARENA_BLOCK ? n : HP_ARENA_BLOCK;
            b = (hp_arena_blk *)malloc(sizeof(hp_arena_blk) + need);
            if (!b) {
                fprintf(stderr, "Fatal error: Allowed memory size exhausted\n");
                exit(255);
            }
            b->size = need;
            if (g_acur_blk) {
                b->next = g_acur_blk->next;
                g_acur_blk->next = b;
            } else {
                b->next = g_ablocks;
                g_ablocks = b;
            }
            g_live_allocs++;
        }
        g_acur_blk = b;
        g_acur = (char *)(b + 1);
        g_aleft = b->size;
    }
    void *p = g_acur;
    g_acur += n;
    g_aleft -= n;
    return p;
}

/* Always heap, never scoped: for interned literals and the shared empty
 * string, which outlive every scope. */
static hstr *hp_str_heap_new(const char *bytes, size_t len) {
    size_t cap = len + 1;
    hstr *s = hp_alloc(sizeof(hstr) + cap);
    s->len = len;
    s->cap = cap;
    s->hash = 0;
    s->rc = 1;
    s->flags = 0;
    if (bytes && len) memcpy(s->data, bytes, len);
    s->data[len] = 0;
    return s;
}

/* Single characters are shared, immortal strings. Loops such as base64url(),
 * cp_len(), parse_id() and the JSON scanner index a string hundreds of times
 * per request and must not allocate a fresh one-character string each time. */
static _Thread_local hstr *g_chars[256];
hstr *hp_char_str(unsigned char c) {
    if (!g_chars[c]) {
        g_chars[c] = hp_str_heap_new((const char *)&c, 1);
        g_chars[c]->flags = HP_F_STATIC;
        g_chars[c]->rc = 0;
    }
    return g_chars[c];
}

/* Scoped when a scope is active, heap otherwise. */
static hstr *hp_str_alloc(size_t len, size_t cap) {
    hstr *s;
    if (g_scope_depth > 0) {
        s = (hstr *)hp_arena_alloc(sizeof(hstr) + cap);
        memset(s, 0, sizeof(hstr));
        s->flags = HP_F_SCOPED;
        s->rc = 1;
    } else {
        s = hp_alloc(sizeof(hstr) + cap);
        s->flags = 0;
        s->rc = 1;
    }
    s->len = len;
    s->cap = cap;
    s->data[len] = 0;
    return s;
}

hstr *hp_str_new(const char *bytes, size_t len) {
    hstr *s = hp_str_alloc(len, len + 1);
    hp_st[HP_ST_STR_NEW]++;
    if (bytes && len) memcpy(s->data, bytes, len);
    s->data[len] = 0;
    return s;
}

hstr *hp_str_lit(const char *cstr) {
    return hp_str_new(cstr, strlen(cstr));
}

/* Interned literals. Codegen emits hp_str_intern("...") for string literals:
 * the argument is the address of a C string constant, so it is stable for the
 * whole process. Evaluating the same literal a million times (a hot loop, a
 * server request) then costs one cache probe instead of one allocation +
 * strlen + memcpy. Interned strings carry HP_F_STATIC and are never freed.
 * The table is thread-local, so threads never race on it. */
#define HP_LIT_SLOTS 1024
typedef struct { const char *key; hstr *val; } hp_lit_ent;
static _Thread_local hp_lit_ent hp_lit_tab[HP_LIT_SLOTS];

hstr *hp_str_intern(const char *cstr) {
    uintptr_t h = (uintptr_t)cstr;
    h ^= h >> 33; h *= 0xff51afd7ed558ccdULL; h ^= h >> 29;
    size_t i = (size_t)h & (HP_LIT_SLOTS - 1);
    for (size_t probe = 0; probe < 32; probe++) {
        hp_lit_ent *e = &hp_lit_tab[(i + probe) & (HP_LIT_SLOTS - 1)];
        if (e->key == cstr) return e->val;
        if (!e->key) {
            hstr *s = hp_str_heap_new(cstr, strlen(cstr));
            s->flags = HP_F_STATIC;
            s->rc = 0;
            e->key = cstr;
            e->val = s;
            return s;
        }
    }
    hstr *s = hp_str_heap_new(cstr, strlen(cstr));
    s->flags = HP_F_STATIC;
    s->rc = 0;
    return s;
}

hstr *hp_str_copy(hstr *s) {
    return hp_str_new(s ? s->data : "", s ? s->len : 0);
}

/* Copy a scoped string out of the request scope (no-op for heap/static). */
hstr *hp_str_persist(hstr *s) {
    if (!s) return hp_null_str();
    if (!(s->flags & HP_F_SCOPED)) return s;
    hstr *r = hp_str_heap_new(s->data, s->len);
    r->hash = s->hash;
    return r;
}

/* Free a heap string. Static literals and scoped strings are owned by the
 * literal table / the scope and are never freed here. */
void hp_str_free(hstr *s) {
    if (!s) return;
    if (s->flags & (HP_F_STATIC | HP_F_SCOPED)) return;
    free(s);
    g_live_allocs--;
}

uint32_t hp_str_hash(hstr *s) {
    if (!s) return 0;
    if (s->hash) return s->hash;
    uint32_t h = 2166136261u;
    for (size_t i = 0; i < s->len; i++) {
        h ^= (unsigned char)s->data[i];
        h *= 16777619u;
    }
    s->hash = h ? h : 1;
    return s->hash;
}

int hp_argc_global = 0;

harr *hp_argv_from_c(int argc, char **argv) {
    harr *out = hp_arr_new();
    for (int i = 0; i < argc; i++)
        hp_arr_push(out, hp_of_str(hp_str_new(argv[i] ? argv[i] : "",
                                              strlen(argv[i] ? argv[i] : ""))));
    hp_argc_global = argc;
    return out;
}

int64_t hp_rand(void) {
    static bool seeded = false;
    if (!seeded) { srand((unsigned)time(NULL)); seeded = true; }
    return (int64_t)rand();
}

int64_t hp_rand_range(int64_t min, int64_t max) {
    if (max < min) { int64_t t = min; min = max; max = t; }
    static bool seeded2 = false;
    if (!seeded2) { srand((unsigned)time(NULL)); seeded2 = true; }
    if (max == min) return min;
    return min + (int64_t)rand() % (max - min + 1);
}

double hp_mt_rand(void) {
    static bool seeded3 = false;
    if (!seeded3) { srand((unsigned)time(NULL)); seeded3 = true; }
    return (double)rand() / (double)RAND_MAX;
}

bool hp_str_eq(hstr *a, hstr *b) {
    if (a == b) return true;
    if (!a || !b || a->len != b->len) return false;
    return memcmp(a->data, b->data, a->len) == 0;
}

int hp_str_cmp(hstr *a, hstr *b) {
    if (!a) a = hp_str_lit("");
    if (!b) b = hp_str_lit("");
    size_t n = a->len < b->len ? a->len : b->len;
    int r = memcmp(a->data, b->data, n);
    if (r) return r;
    return a->len < b->len ? -1 : (a->len > b->len ? 1 : 0);
}

hstr *hp_str_concat2(hstr *a, hstr *b) {
    if (!a) a = hp_str_lit("");
    if (!b) b = hp_str_lit("");
    size_t len = a->len + b->len;
    /* Builder optimization: if the left string is uniquely owned, has
     * spare capacity and enough room for the right side, append in place.
     * This makes "$s .= "x";" loops amortized O(n) like PHP/rope builds. */
    if (a->rc == 1 && a->cap > a->len && len < a->cap) {
        memcpy(a->data + a->len, b->data, b->len);
        a->len = len;
        a->data[len] = 0;
        a->hash = 0;
        return a;
    }
    /* grow geometrically so repeated .= reuses the in-place path */
    size_t cap = len + 1;
    if (a->rc == 1) {
        cap = len * 2 + 16;
    }
    hstr *s = hp_str_alloc(len, cap);
    memcpy(s->data, a->data, a->len);
    memcpy(s->data + a->len, b->data, b->len);
    s->data[len] = 0;
    return s;
}

/* hval-level concat: PHP '.' operator on two values of any kind. */
hstr *hp_str_concat_v(hval a, hval b) {
    hstr *l = hp_val_to_str(a);
    hstr *r = hp_val_to_str(b);
    hstr *out = hp_str_concat2(l, r);
    return out;
}

/* PHP `.` on two values: the result is a NEW string.
 *
 * hp_str_concat2 appends in place when its left operand is uniquely owned,
 * which is the right thing for a builder nobody else can see - but a
 * variable holding the left operand is exactly the case where "uniquely
 * owned" is a lie, because the variable is still there afterwards. Codegen
 * emits this one for `.`, so `$b = $a . "x"` leaves $a alone; `$a .= "x"`
 * goes through hp_str_append_v, where overwriting $a is the point. */
hstr *hp_str_join_v(hval a, hval b) {
    hstr *l = hp_val_to_str(a);
    hstr *r = hp_val_to_str(b);
    if (!l) l = hp_str_lit("");
    if (!r) r = hp_str_lit("");
    size_t len = l->len + r->len;
    hstr *s = hp_str_alloc(len, len + 1);
    memcpy(s->data, l->data, l->len);
    memcpy(s->data + l->len, r->data, r->len);
    s->data[len] = 0;
    return s;
}

/* `$s .= x`: the slot is about to be overwritten, so the buffer may grow
 * in place (amortized O(n) for a loop that appends). The reference count
 * decides: a shared string is copied, so an alias is never clobbered. */
hstr *hp_str_append_v(hval a, hval b) {
    return hp_str_concat_v(a, b);
}/* Concat over an hval array — avoids struct varargs (Win64 ABI pitfalls). */
hstr *hp_str_concat_n(int n, const hval *vals) {
    hstr *parts[64];
    int cnt = 0;
    size_t len = 0;
    for (int i = 0; i < n && cnt < 64; i++) {
        parts[cnt++] = hp_val_to_str(vals[i]);
    }
    for (int i = 0; i < cnt; i++) len += parts[i]->len;

    hstr *s = hp_alloc(sizeof(hstr) + len + 1);
    s->len = len;
    s->cap = len + 1;
    s->rc = 1;
    size_t off = 0;
    for (int i = 0; i < cnt; i++) {
        memcpy(s->data + off, parts[i]->data, parts[i]->len);
        off += parts[i]->len;
    }
    s->data[len] = 0;
    return s;
}

static int64_t norm_index(int64_t i, size_t len) {
    if (i < 0) i += (int64_t)len;
    if (i < 0) return 0;
    if ((size_t)i > len) return (int64_t)len;
    return i;
}

hstr *hp_str_slice(hstr *s, int64_t start, int64_t end) {
    if (!s) return hp_str_lit("");
    start = norm_index(start, s->len);
    if (end < 0) end += (int64_t)s->len;
    if (end < 0 || (size_t)end > s->len) end = (int64_t)s->len;
    if (end <= start) return hp_str_lit("");
    return hp_str_new(s->data + start, (size_t)(end - start));
}

hstr *hp_str_char_at(hstr *s, int64_t idx) {
    if (!s || idx < 0 || (size_t)idx >= s->len) return hp_null_str();
    return hp_char_str((unsigned char)s->data[idx]);
}

int64_t hp_str_len(hstr *s) { return s ? (int64_t)s->len : 0; }

int64_t hp_str_index(hstr *hay, hstr *needle) {
    if (!hay || !needle || needle->len > hay->len) return -1;
    if (needle->len == 0) return 0;
    for (size_t i = 0; i + needle->len <= hay->len; i++) {
        if (memcmp(hay->data + i, needle->data, needle->len) == 0)
            return (int64_t)i;
    }
    return -1;
}

hstr *hp_str_from_int(int64_t v) {
    char buf[32];
    snprintf(buf, sizeof buf, "%lld", (long long)v);
    return hp_str_lit(buf);
}

hstr *hp_str_from_double(double v) {
    char buf[64];
    if (v == (double)(long long)v && fabs(v) < 1e15)
        snprintf(buf, sizeof buf, "%lld", (long long)v);
    else
        snprintf(buf, sizeof buf, "%.14g", v);
    return hp_str_lit(buf);
}

hstr *hp_str_from_bool(bool b) { return hp_str_lit(b ? "1" : ""); }

int64_t hp_str_to_int(hstr *s) {
    if (!s) return 0;
    return (int64_t)strtoll(s->data, NULL, 10);
}

double hp_str_to_double(hstr *s) {
    if (!s) return 0;
    return strtod(s->data, NULL);
}

/* PHP's is_numeric(): optional surrounding whitespace, optional sign, digits
 * with an optional decimal point and exponent. Used to decide whether '+' on
 * a string is arithmetic ("1" + "2" = 3) or our friendly concatenation. */
bool hp_str_is_numeric(hstr *s) {
    if (!s || s->len == 0) return false;
    const char *p = s->data;
    size_t n = s->len, i = 0;
    while (i < n && isspace((unsigned char)p[i])) i++;
    if (i < n && (p[i] == '+' || p[i] == '-')) i++;
    bool digits = false;
    while (i < n && isdigit((unsigned char)p[i])) { i++; digits = true; }
    if (i < n && p[i] == '.') {
        i++;
        while (i < n && isdigit((unsigned char)p[i])) { i++; digits = true; }
    }
    if (!digits) return false;
    if (i < n && (p[i] == 'e' || p[i] == 'E')) {
        size_t save = i;
        i++;
        if (i < n && (p[i] == '+' || p[i] == '-')) i++;
        bool exp_digits = false;
        while (i < n && isdigit((unsigned char)p[i])) { i++; exp_digits = true; }
        if (!exp_digits) i = save;
    }
    while (i < n && isspace((unsigned char)p[i])) i++;
    return i == n;
}

hstr *hp_str_toupper(hstr *s) {
    if (!s) return hp_str_lit("");
    hstr *r = hp_str_copy(s);
    for (size_t i = 0; i < r->len; i++) r->data[i] = (char)toupper((unsigned char)r->data[i]);
    return r;
}

hstr *hp_str_tolower(hstr *s) {
    if (!s) return hp_str_lit("");
    hstr *r = hp_str_copy(s);
    for (size_t i = 0; i < r->len; i++) r->data[i] = (char)tolower((unsigned char)r->data[i]);
    return r;
}

hstr *hp_str_repeat(hstr *s, int64_t n) {
    if (!s || n <= 0) return hp_str_lit("");
    size_t len = s->len * (size_t)n;
    hstr *r = hp_str_alloc(len, len + 1);
    for (int64_t i = 0; i < n; i++) memcpy(r->data + i * s->len, s->data, s->len);
    r->data[len] = 0;
    return r;
}

hstr *hp_str_replace(hstr *subject, hstr *search, hstr *replace) {
    if (!subject) return hp_str_lit("");
    if (!search || search->len == 0) return hp_str_copy(subject);
    if (!replace) replace = hp_str_lit("");
    hstr *out = hp_str_lit("");
    size_t i = 0;
    while (i < subject->len) {
        if (i + search->len <= subject->len &&
            memcmp(subject->data + i, search->data, search->len) == 0) {
            out = hp_str_concat2(out, replace);
            i += search->len;
        } else {
            out = hp_str_concat2(out, hp_str_new(subject->data + i, 1));
            i++;
        }
    }
    return out;
}

static bool is_ws(char c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\0' || c == '\v' || c == '\f';
}

hstr *hp_str_trim(hstr *s) {
    if (!s) return hp_str_lit("");
    size_t a = 0, b = s->len;
    while (a < b && is_ws(s->data[a])) a++;
    while (b > a && is_ws(s->data[b - 1])) b--;
    return hp_str_new(s->data + a, b - a);
}

hstr *hp_str_reverse(hstr *s) {
    if (!s) return hp_str_lit("");
    hstr *r = hp_str_copy(s);
    for (size_t i = 0; i < r->len / 2; i++) {
        char t = r->data[i];
        r->data[i] = r->data[r->len - 1 - i];
        r->data[r->len - 1 - i] = t;
    }
    return r;
}

/* ---------------- values ---------------- */
hval hp_null = { HV_NULL, { 0 } };

hval hp_of_float(double f) { hval v = { HV_FLOAT, { .f = f } }; return v; }
hval hp_of_arr(harr *a) { hval v = { HV_ARR, { .a = a } }; return v; }
hval hp_of_ptr(void *p) { hval v = { HV_OBJ, { .p = p } }; return v; }

hstr *hp_null_str(void) {
    static hstr *ns = NULL;
    if (!ns) {
        ns = hp_str_heap_new("", 0);
        ns->flags = HP_F_STATIC;   /* shared forever, never freed */
        ns->rc = 0;
    }
    return ns;
}

harr *hp_null_arr(void) {
    static harr *na = NULL;
    if (!na) na = hp_arr_new();
    return na;
}

HKind hp_tag(hval v) { return v.tag; }

const char *hp_kind_name(HKind k) {
    switch (k) {
    case HV_NULL: return "null";
    case HV_INT: return "integer";
    case HV_FLOAT: return "double";
    case HV_BOOL: return "boolean";
    case HV_STR: return "string";
    case HV_ARR: return "array";
    case HV_OBJ: return "object";
    case HV_CLO: return "closure";
    default: return "unknown";
    }
}

hstr *hp_val_to_str(hval v) {
    switch (v.tag) {
    case HV_NULL: return hp_str_lit("");
    case HV_INT: return hp_str_from_int(v.u.i);
    case HV_FLOAT: return hp_str_from_double(v.u.f);
    case HV_BOOL: return hp_str_from_bool(v.u.b);
    case HV_STR: return v.u.s ? v.u.s : hp_null_str();
    case HV_ARR: return hp_str_lit("Array");
    case HV_OBJ: return hp_str_lit("Object");
    case HV_CLO: return hp_str_lit("Closure");
    default: return hp_str_lit("");
    }
}

int64_t hp_val_to_int_slow(hval v) {
    switch (v.tag) {
    case HV_INT: return v.u.i;
    case HV_FLOAT: return (int64_t)v.u.f;
    case HV_BOOL: return v.u.b ? 1 : 0;
    case HV_STR: return hp_str_to_int(v.u.s);
    case HV_NULL: return 0;
    default: return 1;
    }
}

double hp_val_to_float(hval v) {
    switch (v.tag) {
    case HV_INT: return (double)v.u.i;
    case HV_FLOAT: return v.u.f;
    case HV_BOOL: return v.u.b ? 1.0 : 0.0;
    case HV_STR: return hp_str_to_double(v.u.s);
    case HV_NULL: return 0.0;
    default: return 0.0;
    }
}

bool hp_val_to_bool(hval v) {
    switch (v.tag) {
    case HV_NULL: return false;
    case HV_INT: return v.u.i != 0;
    case HV_FLOAT: return v.u.f != 0.0;
    case HV_BOOL: return v.u.b;
    /* PHP's "falsy strings" are "" and the single character "0" - and only
     * those. A non-empty "0"-led string like "00" or "0.0" is truthy. */
    case HV_STR:
        return v.u.s && !(v.u.s->len == 0 ||
                          (v.u.s->len == 1 && v.u.s->data[0] == '0'));
    case HV_ARR: return v.u.a && v.u.a->len > 0;
    /* A property declared with a class type but defaulted to null --
       `public Button $tab = null;` -- is an object slot holding a NULL
       pointer, not a real object. Reading it as unconditionally truthy
       made every `if ($o->f == null)` guard lie, so callers went on to
       dereference the null. An absent object is falsy, as in PHP. */
    case HV_OBJ:
    case HV_CLO: return v.u.p != NULL;
    default: return true;
    }
}

bool hp_val_eq(hval a, hval b) {
    if (a.tag == HV_STR && b.tag == HV_STR) return hp_str_eq(a.u.s, b.u.s);
    if (a.tag == HV_ARR && b.tag == HV_ARR) return a.u.a == b.u.a;
    if (a.tag == HV_NULL && b.tag == HV_NULL) return true;
    if (a.tag == HV_NULL || b.tag == HV_NULL)
        return hp_val_to_bool(a) == false && hp_val_to_bool(b) == false;
    if (a.tag == HV_BOOL || b.tag == HV_BOOL) return hp_val_to_bool(a) == hp_val_to_bool(b);
    if (a.tag == HV_FLOAT || b.tag == HV_FLOAT || a.tag == HV_INT || b.tag == HV_INT)
        return hp_val_to_float(a) == hp_val_to_float(b);
    return false;
}

int64_t hp_val_cmp(hval a, hval b) {
    if (a.tag == HV_STR && b.tag == HV_STR) {
        int r = hp_str_cmp(a.u.s, b.u.s);
        return r < 0 ? -1 : (r > 0 ? 1 : 0);
    }
    double x = hp_val_to_float(a), y = hp_val_to_float(b);
    return x < y ? -1 : (x > y ? 1 : 0);
}

/* ---------------- arrays: COW ---------------- */
harr *hp_arr_new(void) {
    harr *a = hp_alloc(sizeof(harr));
    a->rc = 1;
    a->next_index = 0;
    return a;
}

static void hp_arr_grow(harr *a, size_t need) {
    if (need <= a->cap) return;
    size_t cap = a->cap ? a->cap : 8;
    while (cap < need) cap *= 2;
    a->vals = realloc(a->vals, cap * sizeof(hval));
    if (a->is_map) {
        a->keys = realloc(a->keys, cap * sizeof(hval));
        for (size_t i = a->cap; i < cap; i++) {
            a->keys[i] = hp_null;
        }
    }
    a->cap = cap;
}

harr *hp_arr_clone(harr *a) {
    harr *r = hp_arr_new();
    r->is_map = a->is_map;
    r->next_index = a->next_index;
    hp_arr_grow(r, a->len);
    for (size_t i = 0; i < a->len; i++) {
        /* deep clone: nested arrays get value semantics too */
        if (a->vals[i].tag == HV_ARR && a->vals[i].u.a)
            r->vals[i] = hp_of_arr(hp_arr_clone(a->vals[i].u.a));
        else
            r->vals[i] = a->vals[i];
        if (r->is_map) r->keys[i] = a->keys[i];
    }
    r->len = a->len;
    return r;
}

/* value-assignment helper: clone arrays, pass everything else through.
 * Strings are immutable so sharing them is safe. */
hval hp_val_clone_v(hval v) {
    if (v.tag == HV_ARR && v.u.a) return hp_of_arr(hp_arr_clone(v.u.a));
    return v;
}

harr *hp_arr_of(int n, const hval *vals) {
    harr *a = hp_arr_new();
    for (int i = 0; i < n; i++)
        hp_arr_push(a, vals[i]);
    return a;
}

harr *hp_map_of(int n, const hval *kvs) {
    harr *a = hp_arr_new();
    a->is_map = true;
    for (int i = 0; i < n / 2; i++)
        hp_arr_set(a, kvs[2 * i], kvs[2 * i + 1]);
    return a;
}

void hp_arr_push(harr *a, hval v) {
    a = hp_arr_cow(a);
    hp_arr_grow(a, a->len + 1);
    a->vals[a->len] = v;
    if (a->is_map) a->keys[a->len] = hp_of_int(a->next_index);
    a->len++;
    a->next_index++;
}

/* PHP `$a[] = v`: push and return the array (hval wrapper) so the
 * expression also works as a value. */
hval hp_arr_push_v(harr *a, hval v) {
    if (!a) a = hp_arr_new();
    a = hp_arr_cow(a);      /* COW: mutate the writable copy, not a shared one */
    hp_arr_push(a, v);
    return hp_of_arr(a);
}

/* PHP `$a[] = v` where the container is a runtime hval (boxed by-ref
 * capture / untyped slot): push and return the container so the caller
 * can store it back (the push may have cloned the array under COW). */
harr *hp_val_to_arr(hval v) {
    if (v.tag == HV_ARR && v.u.a) return v.u.a;
    return hp_arr_new();   /* PHP cast semantics: null/scalar -> [] */
}

hval hp_arr_push_vv(hval container, hval v) {
    if (container.tag != HV_ARR || !container.u.a) {
        /* PHP auto-vivification: pushing into null creates the array */
        if (container.tag == HV_NULL) {
            harr *na = hp_arr_new();
            hp_arr_push(na, v);
            return hp_of_arr(na);
        }
        return container;
    }
    harr *a = hp_arr_cow(container.u.a);
    hp_arr_push(a, v);
    return hp_of_arr(a);
}

/* hash-index maintenance (defined below; needed by pop/shift/unset) */
static void hp_arr_index_del(harr *a, size_t valslot);
static void hp_arr_index_rebuild(harr *a, uint32_t icap);

hval hp_arr_pop(harr *a) {
    if (!a || a->len == 0) return hp_null;
    a = hp_arr_cow(a);
    /* keep the hash index honest: the popped slot must leave the index, or a
     * later lookup can hand out a slot that is no longer inside the array */
    if (a->is_map && a->index) hp_arr_index_del(a, a->len - 1);
    hval v = a->vals[--a->len];
    return v;
}

hval hp_arr_shift(harr *a) {
    if (!a || a->len == 0) return hp_null;
    a = hp_arr_cow(a);
    hval v = a->vals[0];
    memmove(a->vals, a->vals + 1, (a->len - 1) * sizeof(hval));
    if (a->is_map) {
        memmove(a->keys, a->keys + 1, (a->len - 1) * sizeof(hval));
        /* every index entry now points one slot too far: drop the table and
         * let it rebuild lazily (lookups fall back to a linear scan) */
        free(a->index);
        a->index = NULL;
        a->icap = 0;
        a->ibudget = 0;
    }
    a->len--;
    return v;
}

void hp_arr_unshift(harr *a, hval v) {
    a = hp_arr_cow(a);
    hp_arr_grow(a, a->len + 1);
    memmove(a->vals + 1, a->vals, a->len * sizeof(hval));
    if (a->is_map) memmove(a->keys + 1, a->keys, a->len * sizeof(hval));
    a->vals[0] = v;
    if (a->is_map) a->keys[0] = hp_of_int(a->next_index++);
    a->len++;
}

/* strict array-key comparison (PHP array keys): only int==int and
 * str==str match. The loose hp_val_eq would accept 0 == "a" because the
 * numeric conversion of "a" is 0 — that corrupted mixed-key maps. */
static bool hp_key_eq(hval a, hval b) {
    if (a.tag == HV_INT && b.tag == HV_INT) return a.u.i == b.u.i;
    if (a.tag == HV_STR && b.tag == HV_STR) return hp_str_eq(a.u.s, b.u.s);
    return false;
}

static int64_t hp_key_index(harr *a, hval key) {
    if (a->is_map) {
        /* fast path: open-addressing hash index (int and string keys).
         * String keys are the common PHP pattern ($m["name"] => x), so they
         * get the same O(1) treatment as int keys via FNV-1a (hp_str_hash
         * caches the digest in the string itself). */
        if (a->index && key.tag == HV_INT) {
            uint32_t mask = a->icap - 1;
            uint32_t h = ((uint64_t)key.u.i * 0x9E3779B97F4A7C15ULL) >> 32;
            uint32_t slot = h & mask;
            for (uint32_t n = 0; n <= mask; n++) {
                uint32_t e = a->index[slot];
                if (e == 0) break;            /* key not present */
                if (e != 0xFFFFFFFFu) {
                    hval k = a->keys[e - 1];
                    if (k.tag == HV_INT && k.u.i == key.u.i) return (int64_t)(e - 1);
                }
                slot = (slot + 1) & mask;
            }
            /* No empty slot (the table filled with tombstones): fall through
             * to the linear scan. Without the bound this loop spins forever
             * once churn leaves the index without a single 0 entry. */
        }
        if (a->index && key.tag == HV_STR && key.u.s) {
            uint32_t mask = a->icap - 1;
            uint32_t h = hp_str_hash(key.u.s);
            uint32_t slot = h & mask;
            for (uint32_t n = 0; n <= mask; n++) {
                uint32_t e = a->index[slot];
                if (e == 0) break;
                if (e != 0xFFFFFFFFu) {
                    hval k = a->keys[e - 1];
                    if (k.tag == HV_STR && k.u.s && hp_str_eq(k.u.s, key.u.s))
                        return (int64_t)(e - 1);
                }
                slot = (slot + 1) & mask;
            }
        }
        for (size_t i = 0; i < a->len; i++)
            if (hp_key_eq(a->keys[i], key)) return (int64_t)i;
        return -1;
    }
    if (key.tag == HV_STR) return -1; /* string index on list */
    int64_t i = hp_val_to_int(key);
    if (i < 0 || (size_t)i >= a->len) return -1;
    return i;
}

/* ---- incremental hash index maintenance (int-key maps) ----
 * rebuild_flag(): decide whether to (re)build; called after inserts.
 * Cost amortized O(1) per insert, like PHP's ordered hash tables. */
static void hp_arr_index_add(harr *a, size_t valslot);
static uint32_t hp_hash_int(int64_t k) {
    uint64_t x = (uint64_t)k * 0x9E3779B97F4A7C15ULL;
    return (uint32_t)(x >> 32);
}

/* string-key hash: FNV-1a (cached in the string), forced non-zero so 0 can
 * stay the "empty slot" marker in the index table */
static uint32_t hp_hash_str(hstr *s) {
    uint32_t h = hp_str_hash(s);
    return h ? h : 1;
}

static void hp_arr_index_rebuild(harr *a, uint32_t icap) {
    free(a->index);
    a->index = calloc(icap, sizeof(uint32_t));
    a->icap = icap;
    a->ibudget = icap / 2;   /* keep load <= 0.5 between rebuilds */
    for (size_t i = 0; i < a->len; i++) {
        hval k = a->keys[i];
        if (k.tag != HV_INT && k.tag != HV_STR) continue;
        uint32_t slot = (k.tag == HV_INT ? hp_hash_int(k.u.i)
                                         : hp_hash_str(k.u.s)) & (icap - 1);
        while (a->index[slot] != 0 && a->index[slot] != 0xFFFFFFFFu)
            slot = (slot + 1) & (icap - 1);
        a->index[slot] = (uint32_t)i + 1;
    }
}

static void hp_arr_index_add(harr *a, size_t valslot) {
    if (a->keys[valslot].tag != HV_INT && a->keys[valslot].tag != HV_STR)
        return;
    if (!a->index) {
        if (a->len < 12) return;          /* too small to be worth it */
        /* The rebuild walks keys[0..len-1], which already includes valslot:
         * inserting it again here would leave a duplicate entry, and a later
         * delete only tombstones one of the two -> a stale slot survives and
         * a lookup can return an index past len (heap corruption on unset). */
        hp_arr_index_rebuild(a, 32);
        return;
    }
    if (a->ibudget == 0) {
        /* grow to keep load factor low, or just rebuild to clear tombstones */
        uint32_t want = (a->len * 2 >= a->icap) ? a->icap * 2 : a->icap;
        hp_arr_index_rebuild(a, want);    /* same: rebuild re-adds this key */
        return;
    }
    uint32_t mask = a->icap - 1;
    uint32_t slot = (a->keys[valslot].tag == HV_INT
                         ? hp_hash_int(a->keys[valslot].u.i)
                         : hp_hash_str(a->keys[valslot].u.s)) & mask;
    for (uint32_t n = 0; n <= mask; n++) {
        if (a->index[slot] == 0 || a->index[slot] == 0xFFFFFFFFu) {
            a->index[slot] = (uint32_t)valslot + 1;
            a->ibudget--;
            return;
        }
        slot = (slot + 1) & mask;
    }
    /* no free slot: rebuild (clears tombstones and re-indexes every key,
     * including valslot) instead of growing forever */
    hp_arr_index_rebuild(a, a->icap * 2);
}

static void hp_arr_index_del(harr *a, size_t valslot) {
    if (!a->index ||
        (a->keys[valslot].tag != HV_INT && a->keys[valslot].tag != HV_STR))
        return;
    uint32_t mask = a->icap - 1;
    uint32_t slot = (a->keys[valslot].tag == HV_INT
                         ? hp_hash_int(a->keys[valslot].u.i)
                         : hp_hash_str(a->keys[valslot].u.s)) & mask;
    for (uint32_t n = 0; n <= mask; n++) {
        uint32_t e = a->index[slot];
        if (e == 0) return;
        if (e == (uint32_t)valslot + 1) {
            a->index[slot] = 0xFFFFFFFFu;   /* tombstone */
            /* a tombstone still occupies a slot: count it against the
             * rebuild budget so deletes alone cannot fill the table */
            if (a->ibudget) a->ibudget--;
            return;
        }
        slot = (slot + 1) & mask;
    }
    /* table is all tombstones: rebuild so lookups keep an empty slot */
    hp_arr_index_rebuild(a, a->icap);
}

/* shiftless deletion: swap-with-last keeps O(1) unset and preserves the
 * hash index without slot shifting (iteration order for maps is therefore
 * not insertion-ordered after unset — documented tradeoff). */
void hp_arr_unset(harr *a, hval key) {
    a = hp_arr_cow(a);
    int64_t i = hp_key_index(a, key);
    if (i < 0) return;
    if ((size_t)i >= a->len) return;   /* stale index entry: nothing to delete */
    size_t last = a->len - 1;
    if ((size_t)i != last) {
        if (a->is_map && a->keys) {
            hp_arr_index_del(a, (size_t)i);
            hp_arr_index_del(a, last);
            a->keys[i] = a->keys[last];
        }
        a->vals[i] = a->vals[last];
        if (a->is_map && a->index) hp_arr_index_add(a, (size_t)i);
    } else if (a->is_map) {
        hp_arr_index_del(a, (size_t)i);
    }
    a->len = last;
}

hval hp_arr_get(harr *a, hval idx) {
    if (!a) return hp_null;
    int64_t i = hp_key_index(a, idx);
    if (i < 0) return hp_null; /* PHP notice + null; we return null */
    return a->vals[i];
}

/* PHP-style indexing on any value: arrays/maps index normally, strings
 * return a 1-char string, null indexes to null (like PHP 8 null["]). */
hval hp_arr_get_v(hval container, hval idx) {
    if (container.tag == HV_ARR) return hp_arr_get(container.u.a, idx);
    if (container.tag == HV_STR) {
        int64_t i = hp_val_to_int(idx);
        hstr *s = container.u.s;
        if (i < 0 || !s || (size_t)i >= s->len) return hp_of_str(hp_null_str());
        return hp_of_str(hp_char_str((unsigned char)s->data[i]));
    }
    return hp_null;
}

/* element write on a value container: only arrays are mutable in place;
 * the compiler only emits this for array-typed hvals. */
void hp_arr_set_v(hval container, hval idx, hval v) {
    if (container.tag != HV_ARR || !container.u.a) return;
    hp_arr_set(container.u.a, idx, v);
}

void hp_arr_set(harr *a, hval idx, hval v) {
    a = hp_arr_cow(a);
    if (idx.tag == HV_NULL) {
        hp_arr_push(a, v);
        return;
    }
    int64_t i = hp_key_index(a, idx);
    if (i >= 0) {
        a->vals[i] = v;
        return;
    }
    /* PHP semantics: arrays remember their keys. A string key or an int key
     * that does not continue the implicit 0..n sequence turns the array
     * into a keyed map ($m[1] = x keeps key 1; foreach yields it). */
    if (!a->is_map) {
        if (idx.tag == HV_STR)
            a->is_map = true;
        else if (idx.tag == HV_INT && idx.u.i != a->next_index)
            a->is_map = true;
    }
    hp_arr_grow(a, a->len + 1);
    if (a->is_map) {
        a->keys = realloc(a->keys, a->cap * sizeof(hval));
        a->keys[a->len] = idx;
    }
    size_t newslot = a->len;
    a->vals[a->len] = v;
    a->len++;
    if (a->is_map) hp_arr_index_add(a, newslot);
    if (idx.tag == HV_INT && idx.u.i >= a->next_index)
        a->next_index = idx.u.i + 1;
}

bool hp_arr_has(harr *a, hval key) {
    if (!a) return false;
    return hp_key_index(a, key) >= 0;
}

int64_t hp_arr_len(harr *a) { return a ? (int64_t)a->len : 0; }

harr *hp_arr_slice(harr *a, int64_t start, int64_t end) {
    harr *r = hp_arr_new();
    if (!a) return r;
    start = norm_index(start, a->len);
    if (end < 0) end += (int64_t)a->len;
    if ((size_t)end > a->len) end = (int64_t)a->len;
    for (int64_t i = start; i < end; i++)
        hp_arr_push(r, a->vals[i]);
    return r;
}

harr *hp_arr_keys(harr *a) {
    harr *r = hp_arr_new();
    if (!a) return r;
    for (size_t i = 0; i < a->len; i++)
        hp_arr_push(r, a->is_map ? a->keys[i] : hp_of_int((int64_t)i));
    return r;
}

harr *hp_arr_values(harr *a) {
    harr *r = hp_arr_new();
    if (!a) return r;
    for (size_t i = 0; i < a->len; i++)
        hp_arr_push(r, a->vals[i]);
    return r;
}

harr *hp_arr_merge(harr *a, harr *b) {
    harr *r = hp_arr_clone(a ? a : hp_null_arr());
    if (!b) return r;
    for (size_t i = 0; i < b->len; i++) {
        if (b->is_map && b->keys[i].tag == HV_STR)
            hp_arr_set(r, b->keys[i], b->vals[i]);
        else
            hp_arr_push(r, b->vals[i]);
    }
    return r;
}

harr *hp_arr_reverse(harr *a) {
    harr *r = hp_arr_new();
    if (!a) return r;
    for (size_t i = a->len; i > 0; i--)
        hp_arr_push(r, a->vals[i - 1]);
    return r;
}

bool hp_arr_in(harr *a, hval v) {
    if (!a) return false;
    for (size_t i = 0; i < a->len; i++)
        if (hp_val_eq(a->vals[i], v)) return true;
    return false;
}

static int hp_sort_cmp(const void *pa, const void *pb) {
    hval a = *(const hval *)pa, b = *(const hval *)pb;
    return (int)hp_val_cmp(a, b);
}

harr *hp_arr_sort(harr *a) {
    harr *r = hp_arr_clone(a ? a : hp_null_arr());
    qsort(r->vals, r->len, sizeof(hval), hp_sort_cmp);
    return r;
}

harr *hp_arr_rsort(harr *a) {
    harr *r = hp_arr_sort(a);
    hp_arr_reverse(r);
    return r;
}

harr *hp_map_sort_by_key(harr *a) {
    harr *r = hp_arr_clone(a ? a : hp_null_arr());
    /* simple insertion sort by key */
    for (size_t i = 1; i < r->len; i++) {
        hval kv = r->keys[i], vv = r->vals[i];
        size_t j = i;
        while (j > 0 && hp_val_cmp(r->keys[j - 1], kv) > 0) {
            r->keys[j] = r->keys[j - 1];
            r->vals[j] = r->vals[j - 1];
            j--;
        }
        r->keys[j] = kv;
        r->vals[j] = vv;
    }
    return r;
}

hval hp_arr_sum(harr *a) {
    if (!a) return hp_of_int(0);
    bool anyf = false;
    double sum = 0;
    int64_t isum = 0;
    for (size_t i = 0; i < a->len; i++) {
        if (a->vals[i].tag == HV_FLOAT) anyf = true;
        sum += hp_val_to_float(a->vals[i]);
        isum += hp_val_to_int(a->vals[i]);
    }
    return anyf ? hp_of_float(sum) : hp_of_int(isum);
}

harr *hp_arr_unique(harr *a) {
    harr *r = hp_arr_new();
    if (!a) return r;
    for (size_t i = 0; i < a->len; i++)
        if (!hp_arr_in(r, a->vals[i])) hp_arr_push(r, a->vals[i]);
    return r;
}

harr *hp_range(int64_t lo, int64_t hi) {
    harr *a = hp_arr_new();
    if (lo <= hi)
        for (int64_t i = lo; i <= hi; i++) hp_arr_push(a, hp_of_int(i));
    else
        for (int64_t i = lo; i >= hi; i--) hp_arr_push(a, hp_of_int(i));
    return a;
}

void hp_arr_free(harr *a) {
    if (!a) return;
    free(a->vals);
    free(a->keys);
    free(a->index);
    free(a);
    g_live_allocs--;
}

/* COW: the runtime shares arrays on assignment; writes go through
 * hp_arr_cow which clones when more than one owner exists. Ownership is
 * tracked by the compiler: values assigned by-value share, explicit
 * hp_arr_cow marks the write. In generated code, every mutating call
 * routes through hp_arr_cow first. */
harr *hp_arr_cow(harr *a) {
    if (!a) return hp_arr_new();
    if (a->rc > 1) {
        a->rc--;
        harr *r = hp_arr_clone(a);
        r->rc = 1;
        return r;
    }
    return a;
}

/* ---------------- foreach ---------------- */
hp_foreach_ctx hp_arr_iter(harr *a) {
    hp_foreach_ctx c = { .a = a, .pos = 0, .i = 0, .is_str = false };
    return c;
}
hp_foreach_ctx hp_map_iter(harr *a) { return hp_arr_iter(a); }

/* foreach over a dynamically typed value (untyped property, mixed param):
 * arrays/strings iterate, anything else is a catchable error, like PHP. */
hp_foreach_ctx hp_val_iter(hval v) {
    switch (v.tag) {
    case HV_ARR: return hp_arr_iter(v.u.a);
    case HV_STR: return hp_str_iter(v.u.s);
    case HV_NULL: return hp_arr_iter(hp_null_arr());
    default: {
        hstr *msg = hp_str_concat2(hp_str_lit("foreach: cannot iterate "),
                                   hp_str_lit(hp_kind_name(v.tag)));
        hp_throw(hp_of_str(msg));
        return hp_arr_iter(hp_null_arr());
    }
    }
}
hp_foreach_ctx hp_str_iter(hstr *s) {
    hp_foreach_ctx c = { .a = NULL, .s = s, .pos = 0, .i = 0, .is_str = true };
    return c;
}
hval hpv_tmp = { HV_NULL, { 0 } };

bool hp_foreach_next(hp_foreach_ctx *ctx, hval *out) {
    if (ctx->is_str) {
        if (!ctx->s || ctx->pos >= ctx->s->len) return false;
        *out = hp_of_str(hp_str_new(ctx->s->data + ctx->pos, 1));
        ctx->k = hp_of_int((int64_t)ctx->pos);
        ctx->pos++;
        ctx->i = (int64_t)ctx->pos;
        return true;
    }
    if (!ctx->a || ctx->pos >= ctx->a->len) return false;
    *out = ctx->a->vals[ctx->pos];
    ctx->k = ctx->a->is_map ? ctx->a->keys[ctx->pos] : hp_of_int((int64_t)ctx->pos);
    ctx->i = (int64_t)ctx->pos;
    ctx->pos++;
    return true;
}

/* ---------------- dynamic operators ---------------- */
static bool hp_num_like(hval v); /* defined below */

hval hp_add(hval a, hval b) {
    if (a.tag == HV_ARR && b.tag == HV_ARR) return hp_of_arr(hp_arr_merge(a.u.a, b.u.a));
    if (a.tag == HV_STR || b.tag == HV_STR) {
        /* PHP numeric-string arithmetic: "1" + "2" is 3, "1.5" + 1 is 2.5.
         * A non-numeric string has no numeric meaning, so we stay friendly
         * and concatenate ('.' is the real concatenation operator). */
        if (hp_num_like(a) && hp_num_like(b)) {
            double da = hp_val_to_float(a), db = hp_val_to_float(b);
            if (a.tag != HV_FLOAT && b.tag != HV_FLOAT &&
                da == (double)(int64_t)da && db == (double)(int64_t)db)
                return hp_of_int((int64_t)da + (int64_t)db);
            return hp_of_float(da + db);
        }
        return hp_of_str(hp_str_concat2(hp_val_to_str(a), hp_val_to_str(b)));
    }
    if (a.tag == HV_FLOAT || b.tag == HV_FLOAT)
        return hp_of_float(hp_val_to_float(a) + hp_val_to_float(b));
    return hp_of_int(hp_val_to_int(a) + hp_val_to_int(b));
}

hval hp_sub(hval a, hval b) {
    if (a.tag == HV_FLOAT || b.tag == HV_FLOAT)
        return hp_of_float(hp_val_to_float(a) - hp_val_to_float(b));
    return hp_of_int(hp_val_to_int(a) - hp_val_to_int(b));
}

hval hp_mul(hval a, hval b) {
    if (a.tag == HV_FLOAT || b.tag == HV_FLOAT)
        return hp_of_float(hp_val_to_float(a) * hp_val_to_float(b));
    return hp_of_int(hp_val_to_int(a) * hp_val_to_int(b));
}

hval hp_divv(hval a, hval b) {
    double d = hp_val_to_float(b);
    if (d == 0.0) hp_throw_str("Division by zero");
    return hp_of_float(hp_val_to_float(a) / d);
}

bool hp_streq(hval a, hval b) { return hp_val_eq(a, b); }

/* === : identity. Both the tag and the value must match — no bool/int/str
 * coercion. Two different tags are never equal (PHP 8 semantics). */
static bool hp_ident_eq_r(hval a, hval b, int depth);

bool hp_ident_eq(hval a, hval b) { return hp_ident_eq_r(a, b, 0); }

static bool hp_ident_eq_r(hval a, hval b, int depth) {
    if (a.tag != b.tag) return false;
    switch (a.tag) {
    case HV_NULL: return true;
    case HV_BOOL: return a.u.b == b.u.b;
    case HV_INT: return a.u.i == b.u.i;
    case HV_FLOAT: return a.u.f == b.u.f;
    case HV_STR: return hp_str_eq(a.u.s, b.u.s);
    case HV_ARR:
        /* PHP 8 ===: same key/value pairs, same order, same types */
        if (a.u.a == b.u.a) return true;
        if (!a.u.a || !b.u.a) return false;
        if (a.u.a->len != b.u.a->len) return false;
        if (a.u.a->is_map != b.u.a->is_map) return false;
        if (depth > 64) return false;   /* cycles: give up conservatively */
        for (size_t i = 0; i < a.u.a->len; i++) {
            if (a.u.a->keys && b.u.a->keys) {
                if (!hp_ident_eq_r(a.u.a->keys[i], b.u.a->keys[i], depth + 1))
                    return false;
            } else if (a.u.a->keys || b.u.a->keys) {
                return false;
            }
            if (!hp_ident_eq_r(a.u.a->vals[i], b.u.a->vals[i], depth + 1))
                return false;
        }
        return true;
    default: return a.u.p == b.u.p;       /* objects/closures by identity */
    }
}
static bool hp_num_like(hval v) {
    return v.tag == HV_INT || v.tag == HV_FLOAT || v.tag == HV_BOOL ||
           (v.tag == HV_STR && hp_str_is_numeric(v.u.s));
}

bool hp_lt(hval a, hval b) { return hp_val_cmp(a, b) < 0; }
bool hp_gt(hval a, hval b) { return hp_val_cmp(a, b) > 0; }
bool hp_le(hval a, hval b) { return hp_val_cmp(a, b) <= 0; }
bool hp_ge(hval a, hval b) { return hp_val_cmp(a, b) >= 0; }
int64_t hp_cmp(hval a, hval b) { return hp_val_cmp(a, b); }

int64_t hp_mod(int64_t a, int64_t b) {
    if (b == 0) hp_throw_str("Modulo by zero");
    return a % b;
}

int64_t hp_pow_i(int64_t a, int64_t b) {
    if (b < 0) return 0; /* PHP: 2 ** -1 is float; ints truncate to 0 */
    int64_t r = 1, base = a;
    while (b) {
        if (b & 1) r *= base;
        base *= base;
        b >>= 1;
    }
    return r;
}

hval hp_powv(hval a, hval b) {
    if (a.tag == HV_INT && b.tag == HV_INT && b.u.i >= 0) {
        int64_t r = 1, base = a.u.i, e = b.u.i;
        while (e) {
            if (e & 1) r *= base;
            base *= base;
            e >>= 1;
        }
        return hp_of_int(r);
    }
    return hp_of_float(pow(hp_val_to_float(a), hp_val_to_float(b)));
}

hval hp_nullcoal(hval a, hval b) {
    if (a.tag == HV_NULL) return b;
    return a;
}

/* match ($x) { "a" => ... } compares with ===, the way PHP 8 does: match is
 * strict, only `switch`/`==` is loose. So `match(0.0) { 0 => ... }` takes the
 * default arm, and a pattern can only ever be taken by a value of its own
 * type - which is what lets the checker narrow the subject inside an arm. */
hval hp_match_any(hval subj, hval *pats, size_t n) {
    for (size_t i = 0; i < n; i++)
        if (hp_ident_eq(subj, pats[i])) return hp_of_bool(true);
    return hp_of_bool(false);
}

hval hp_match_no_default(void) {
    hp_throw_str("UnhandledMatchError");
    return hp_null;
}

/* hp_div is a static inline in hphp_rt.h so gcc can fold away the
 * zero-check for literal divisors and vectorize loops like hand-written C */

/* ---------------- exceptions ---------------- */
/* Thread-local: every spawned worker thread gets its own exception state
 * and closure environment (see hphp_thr.c), so workers can throw/catch and
 * use captured variables without racing the main thread. */
HP_THREAD_QUAL hp_try_frame *hp_cur_try = NULL;
HP_THREAD_QUAL hval hp_exception = { HV_NULL, { 0 } };

void hp_throw(hval v) {
    if (!hp_cur_try) {
        hstr *m = hp_val_to_str(v);
        fprintf(stderr, "PHP Fatal error: Uncaught exception: %.*s\n",
                (int)m->len, m->data);
        exit(255);
    }
    hp_exception = v;
    hp_cur_try->caught = false;
    hp_try_frame *f = hp_cur_try;
    longjmp(f->jmp, 1);
}

void hp_throw_str(const char *msg) {
    hp_throw(hp_of_str(hp_str_lit(msg)));
}

hstr *hp_exception_msg(void) {
    return hp_val_to_str(hp_exception);
}

void hp_try_push(hp_try_frame *f) {
    f->caught = false;
    f->prev = hp_cur_try;
    hp_cur_try = f;
}

void hp_try_pop(hp_try_frame *f) {
    if (hp_cur_try == f) hp_cur_try = f->prev;
}

/* The ONLY setjmp in generated programs lives here (Lua/CPython pattern).
 * Runs the try body; on a throw, runs the catch handler. A handler that
 * returns a non-null hval signals "not handled": we hand the exception back
 * to the call site, which runs its finally block and only then rethrows. */
hval hp_try_run(hp_try_fn body_fn, hp_try_fn catch_fn, void *env) {
    hp_try_frame fr, hfr;
    hp_try_push(&fr);
    if (setjmp(fr.jmp) == 0) {
        hval r = body_fn(env, hp_null);
        hp_try_pop(&fr);
        return r; /* body completion (normally hp_null) */
    }
    hp_try_pop(&fr);
    /* The handler runs under its OWN frame: a throw raised inside catch (a
     * bare rethrow or a fresh exception) lands back here instead of unwinding
     * past this try statement — otherwise the caller's finally block would be
     * skipped. We then hand the exception back (non-null), and the call site
     * runs finally before propagating. */
    hp_try_push(&hfr);
    if (setjmp(hfr.jmp) == 0) {
        hval r = catch_fn(env, hp_exception);
        hp_try_pop(&hfr);
        return r; /* hp_null = handled; else rethrow */
    }
    hp_try_pop(&hfr);
    return hp_exception; /* handler threw: caller runs finally, then rethrows */
}

/* ---------------- closures ---------------- */
HP_THREAD_QUAL void *hp_cur_env = NULL;

void *hp_closure_env(void) { return hp_cur_env; }

hclosure *hpclosure_new(void *env, size_t envsz, void *fn) {
    hclosure *c = hp_alloc(sizeof(hclosure) + envsz);
    c->fn = (hfn_t)fn;
    c->rc = 1;
    c->envsz = envsz;
    if (env && envsz) memcpy((char *)c + sizeof(hclosure), env, envsz);
    return c;
}

void hpclosure_free(hclosure *c) { free(c); }

hval hp_of_clo(hclosure *c) {
    hval v = { HV_CLO, { .p = c } };
    return v;
}

/* The closure trampoline: closure impls have C signature hval(void*).
 * We build a real call via a union-free double-cast through a function
 * pointer of the exact impl type (hval (*)(void*)). Args travel through a
 * heap hval array whose data pointer becomes the impl's single argument. */
typedef hval (*hclo_impl_t)(void *);

hval hp_closure_call_arr(hclosure *c, hval *args, int nargs) {
    if (!c) return hp_null;
    harr *aa = hp_arr_new();
    for (int i = 0; i < nargs; i++) hp_arr_push(aa, args[i]);
    void *saved = hp_cur_env;
    hp_cur_env = (char *)c + sizeof(hclosure);
    hclo_impl_t fn = (hclo_impl_t)c->fn;
    hval r = fn(aa->vals);   /* hval* data of the packed args */
    hp_cur_env = saved;
    return r;
}

hval hp_closure_call(hclosure *c, int nargs, const hval *args) {
    return hp_closure_call_arr(c, (hval *)args, nargs);
}

/* ---------------- smart pointers / objects ---------------- */
/* Rc<T> model: hp_alloc'd objects carry a uint32_t rc as first field.
 * Rc increments/decrements are real: hp_rc_inc_obj/hp_rc_dec_obj.
 * Compiler inserts calls for Rc<T> bindings; own<T> relies on scope end. */
void hp_val_free(hval v) { (void)v; }
void hp_val_rc_inc(hval v) { (void)v; }
void hp_val_rc_dec(hval v) { (void)v; }

/* ---------------- lifecycle ---------------- */
static bool hp_inited = false;
hval *hp_box_new(void) {
    hval *b = (hval *)malloc(sizeof(hval));
    if (b) *b = hp_null;
    return b;
}

void hp_box_free(hval *b) { free(b); }

void hp_init(void) {
    if (hp_inited) return;
    hp_inited = true;
    setvbuf(stdout, NULL, _IONBF, 0);
}

void hp_shutdown(void) {
    if (hp_cur_try) {
        /* uncaught */
    }
}
