/* codegen.c — translate the typed HolyPHP AST into C11.
 *
 * Target conventions:
 *   - hval is the dynamic value (PHP zval analogue): tag + payload
 *   - scalars live in registers/locals as plain C ints/doubles/bools
 *   - arrays/maps are runtime-managed COW structures (harr*)
 *   - strings are hstr* (length-prefixed)
 *   - own<T>  -> T* with move-only discipline (enforced by sema)
 *   - Rc<T>   -> T* with refcounting via hp_rc_inc/hp_rc_dec
 *   - &T/&mut -> plain C pointer to the variable
 *   - exceptions use setjmp/longjmp-based try frames
 *   - closures are structs with captured environment
 *
 * Invariant: every emitted expression has the C type that sema assigned.
 */
#include "codegen.h"
#include "builtins.h"
#include "sema.h"
#include <stdarg.h>

struct Codegen {
    Buf *out;
    Program *prog;
    int depth;
    int tmp_id;
    int label_id;
    AstFn *cur_fn;
    bool in_closure;      /* emitting a closure impl: returns must be hval */
    PtrVec closures;      /* AstFn* of all closures, in discovery order */
    int vcls_id;          /* id allocator for virtual dispatch classes */
    int try_id;           /* unique try-block ids (helper fn names) */
    bool in_try_helper;   /* emitting a try-body/catch helper: honor returns */
    PtrVec *cur_helper_vars; /* vars aliased by the helper being emitted */
    PtrVec loop_labels;   /* continue targets: stack of hp_cont_<n> ids */
    int helper_depth;     /* try-helper nesting level (0 = normal code) */
    Buf try_bufs[8];      /* file-scope try-helper defs, per nesting level */
    int loop_depth;       /* loop/switch nesting (break/continue legality) */
    Expr *cur_assign;     /* assignment currently emitted (destructuring) */
};

static void emit_stmt(Codegen *g, Stmt *s);
static void emit_expr(Codegen *g, Expr *e, Buf *dst);

/* ---------------- concatenation chains ----------------
 *
 * PHP's `.` is left-associative, so "a" . "b" . "c" parses as ((a . b) . c).
 * Emitting that shape verbatim produced one nested hp_str_concat_v() call per
 * operand, which is fine for two or three parts and pathological past that:
 * a 60-part HTML literal emitted 60 nested calls, and gcc needs memory
 * exponential in the nesting depth (it died with "out of memory allocating
 * 67108848 bytes"). Balancing the tree keeps the depth at log2(n). */

static int dot_chain_len(Expr *e) {
    int n = 1;
    while (e && e->kind == EX_BIN && !e->is_nullcoal && e->u.bin.op.kind == T_DOT) {
        n++;
        e = e->u.bin.l;
    }
    return n;
}

/* operands in source order: down the left spine, right children first */
static int dot_collect(Expr *e, Expr **out, int cap) {
    if (e && e->kind == EX_BIN && !e->is_nullcoal && e->u.bin.op.kind == T_DOT) {
        int n = dot_collect(e->u.bin.l, out, cap);
        if (n < cap) out[n] = e->u.bin.r;
        return n + 1 > cap ? cap : n + 1;
    }
    if (cap > 0) out[0] = e;
    return cap > 0 ? 1 : 0;
}

static void emit_dot_chain(Codegen *g, Expr **parts, int lo, int hi, Buf *dst) {
    if (hi - lo == 1) { emit_expr(g, parts[lo], dst); return; }
    int mid = lo + (hi - lo) / 2;
    Buf a, b;
    buf_init(&a);
    buf_init(&b);
    emit_dot_chain(g, parts, lo, mid, &a);
    emit_dot_chain(g, parts, mid, hi, &b);
    buf_printf(dst, "hp_str_join_v(hv(%s), hv(%s))", buf_take(&a), buf_take(&b));
}
static const char *ctype_of(const Type *t);

/* A local captured by the try-helper currently being emitted: its name is a
 * macro aliasing a pointer slot in the env, so writes reach catch/finally. */
static bool is_aliased(Codegen *g, void *sym) {
    if (!sym || !g->cur_helper_vars) return false;
    for (size_t i = 0; i < g->cur_helper_vars->len; i++)
        if (g->cur_helper_vars->items[i] == sym) return true;
    return false;
}
static bool method_overridden(Codegen *g, AstClass *owner, AstFn *m);
static void class_vmethods(AstClass *c, PtrVec *out);
static void collect_syms_stmt(PtrVec *syms, Stmt *s);
static bool is_global_alias(VarSym *v);   /* file-scope `global $x;` alias */
static void emit_closure(Codegen *g, AstFn *fn);
static void emit_closure_prototype(Codegen *g, AstFn *fn);

/* ---------------- helpers ---------------- */
static void line(Codegen *g, const char *fmt_, ...) {
    va_list ap;
    va_start(ap, fmt_);
    for (int i = 0; i < g->depth; i++) buf_puts(g->out, "    ");
    buf_vprintf(g->out, fmt_, ap);
    va_end(ap);
    buf_putc(g->out, '\n');
}

/* User functions live in the hpu_ namespace: the runtime owns hp_* (hp_add,
 * hp_len, ...), so a user function named `add` must not become hp_add. */
static const char *mangle_fn(const char *name) { return fmt("hpu_%s", name); }
/* Class methods are class-namespaced (Tier_laut); classes can't be named like
 * a runtime symbol because type names are used as struct tags only. */
static const char *mangle_method(AstClass *c, const char *name) {
    return fmt("hpu_%s_%s", c->name, name);
}

static const char *ctype_of(const Type *t) {
    if (!t) return "hval";
    switch (t->kind) {
    case TY_INT: case TY_I8: case TY_I16: case TY_I32: case TY_I64:
        return "int64_t";
    case TY_FLOAT: case TY_F32: case TY_F64: return "double";
    case TY_BOOL: return "bool";
    case TY_STRING: return "hstr*";
    case TY_VOID: return "void";
    case TY_MIXED: case TY_TUPLE: case TY_OPTION: case TY_RESULT: return "hval";
    /* a nullable/union slot holds an hval: the tag says whether there is a
     * value, the payload carries it */
    case TY_NULL: case TY_NULLABLE: case TY_UNION: return "hval";
    case TY_ARRAY: case TY_VEC: case TY_MAP: case TY_SET: return "harr*";
    case TY_REF: case TY_MUTREF: return fmt("%s*", ctype_of(t->elem));
    case TY_PTR: return "void*";
    case TY_OWN: case TY_RC: {
        const Type *e = t->elem;
        if (e && (e->kind == TY_CLASS || e->kind == TY_STRUCT))
            return fmt("struct %s*", e->name);
        if (e && e->kind == TY_STRING) return "hstr*";
        if (e && e->kind == TY_ARRAY) return "harr*";
        if (e && type_is_value(e->kind)) return ctype_of(e);
        return "hval";
    }
    case TY_CLASS: case TY_STRUCT: return fmt("struct %s*", t->name);
    case TY_INTERFACE: return "hobj*";
    case TY_ENUM: return "int64_t";
    case TY_FN: return "hclosure*";
    default: return "hval";
    }
}

static const char *var_name(void *sym) {
    if (!sym) return "hp_missing_var";
    return fmt("v%u", ((VarSym *)sym)->uid);
}

/* C name of a parameter in the signature.
 *
 * A by-value parameter a closure captured by reference is not used under its
 * own name in the body: the prologue puts its value in a heap box that the
 * closure env aliases (see emit_auto_decls), and the box takes the parameter's
 * name so every access site keeps working. So such a parameter arrives under
 * `<name>_arg` instead. */
static const char *param_slot_name(Param *pm) {
    if (!pm || !pm->sym) return "hp_missing_var";
    VarSym *v = (VarSym *)pm->sym;
    if (v->captured_byref && !pm->by_ref) return fmt("%s_arg", var_name(v));
    return var_name(v);
}

/* C type of a pointer-to-parameter: used for by-ref parameters, where the
 * callee receives &slot of the parameter's declared type. */
static const char *ctype_ref_of(const Type *t) {
    return fmt("%s *", ctype_of(t));
}



static const char *s_this;
static const char *s_argc;
static const char *s_argv;
/* interned PHP_* constant names (set once in codegen_init alongside s_this) */
static const char *s_php_int_max, *s_php_int_min, *s_php_int_size, *s_php_int_digits;
static const char *s_php_float_epsilon, *s_php_euler, *s_php_pi;
static const char *s_m_pi, *s_m_e;
static const char *s_php_round_half_up, *s_php_round_half_down, *s_php_round_half_even, *s_php_round_half_odd;
static const char *s_php_os, *s_php_eol, *s_php_version, *s_php_sapi, *s_php_uname;
static const char *s_php_bool_true, *s_php_bool_false, *s_php_null;
static const char *s_php_file_append, *s_php_file_ignore_new_lines, *s_php_file_skip_empty_lines, *s_php_file_use_include_path;
static const char *s_json_pretty_print, *s_json_unescaped_slashes, *s_json_numeric_check, *s_json_force_object;

/* Convert any typed value into an hval for runtime calls. */
/* Is this type carried in an hval slot?
 *
 * mixed and Option/Result are dynamic values, and so is a nullable or union
 * slot: the tag says whether a value is there, the payload carries it. */
static bool type_is_hval_slot(const Type *t) {
    if (!t) return false;
    switch (t->kind) {
    case TY_MIXED: case TY_OPTION: case TY_RESULT:
    case TY_NULL: case TY_NULLABLE: case TY_UNION:
        return true;
    default:
        return false;
    }
}

/* Is this read of a nullable/union slot narrowed to a concrete type?
 *
 * The slot keeps holding an hval, but the branch that proved the value is
 * there works with the payload itself, so the read has to project it. */
static bool narrowed_read_needs_projection(const Expr *e) {
    if (!e || e->kind != EX_VAR || !e->u.var.sym) return false;
    const Type *slot = ((VarSym *)e->u.var.sym)->type;
    if (!slot) return false;
    if (slot->kind != TY_NULLABLE && slot->kind != TY_UNION) return false;
    const Type *t = e->type;
    if (!t) return false;
    switch (t->kind) {
    case TY_NULL: case TY_NULLABLE: case TY_UNION: case TY_MIXED:
        return false;               /* still an hval */
    default:
        return true;
    }
}

/* Project a narrowed hval slot to the concrete type the branch works with. */
static void project_narrowed(Buf *dst, const Type *t, const char *slot) {
    if (!t) { buf_printf(dst, "%s", slot); return; }
    switch (t->kind) {
    case TY_INT: case TY_I8: case TY_I16: case TY_I32: case TY_I64: case TY_ENUM:
        buf_printf(dst, "(%s).u.i", slot); break;
    case TY_FLOAT: case TY_F32: case TY_F64:
        buf_printf(dst, "(%s).u.f", slot); break;
    case TY_BOOL:
        buf_printf(dst, "(%s).u.b", slot); break;
    case TY_STRING:
        buf_printf(dst, "(%s).u.s", slot); break;
    case TY_ARRAY: case TY_VEC: case TY_MAP: case TY_SET:
        buf_printf(dst, "(%s).u.a", slot); break;
    case TY_CLASS: case TY_STRUCT:
        buf_printf(dst, "((struct %s *)((%s).u.p))", t->name, slot); break;
    case TY_INTERFACE:
        buf_printf(dst, "((hobj *)((%s).u.p))", slot); break;
    default:
        buf_printf(dst, "%s", slot); break;
    }
}

/* Does this expression's generated C form have the type hval?
 *
 * Most expressions do not: a variable holding an int is emitted as an
 * int64_t, an array as an harr*, and so on, and the reader can trust the
 * AST's inferred type. The exception is a variable a closure captured by
 * reference (`use (&$x)`): it lives in a heap box and is emitted as `(*box)`,
 * which is an *hval lvalue*. Its inferred type still says int / string /
 * array, so any consumer that trusted the type either handed an hval to a
 * function expecting an int64_t (a hard C error, "incompatible type for
 * argument") or boxed the value a second time. Ask about the shape of the
 * expression, not about its type.
 *
 * An untyped `&$x` parameter is the same story: it arrives as an hval*.
 */
static bool emits_hval_lvalue(const Expr *e) {
    if (!e || e->kind != EX_VAR || !e->u.var.sym) return false;
    VarSym *v = (VarSym *)e->u.var.sym;
    /* a narrowed nullable box is projected to its payload, not read as hval */
    if (narrowed_read_needs_projection(e)) return false;
    if (v->captured_byref) return true;
    if (v->is_param_ref && (!v->type || v->type->kind == TY_MIXED)) return true;
    return false;
}

/* Is this expression's generated C form an hval?
 *
 * It is not the same question as "is its type mixed": a closure literal is a
 * TY_FN but emits an `hclosure*`, while an array element read from a typed
 * array can carry the element's own type and still come back as an hval from
 * the runtime. Every conversion decision in emit_to_type() has to ask THIS
 * question - asking the other one boxed a fresh closure (making the C
 * compiler reject a pointer dereference) and left PHP-style values unboxed in
 * typed slots. */
static bool c_form_is_hval(const Expr *e) {
    if (!e) return false;
    if (emits_hval_lvalue(e)) return true;          /* use (&$x) box, untyped &$p */
    const Type *t = e->type;
    if (!t) return false;
    if (t->kind == TY_FN) return false;             /* closures are pointers */
    return type_is_hval_slot(t);
}

/* the PHP-style scalar cast for a target type (hp_val_to_int/str/...) */
static const char *hval_cast_fn(const Type *want) {
    if (type_is_integral(want->kind)) return "hp_val_to_int";
    if (want->kind == TY_BOOL) return "hp_val_to_bool";
    if (type_is_numeric(want->kind)) return "hp_val_to_float";
    return "hp_val_to_str";
}

static void to_hval(Codegen *g, Expr *e, Buf *dst) {
    /* an hval lvalue (by-ref capture box) is already an hval */
    if (emits_hval_lvalue(e)) { emit_expr(g, e, dst); return; }
    Buf b;
    buf_init(&b);
    /* bool literals must box as HV_BOOL: under C11 true/false are plain
     * ints, so hv() would tag them HV_INT and break ===/!== identity. */
    if (e->kind == EX_BOOL) {
        buf_printf(dst, "hp_of_bool(%s)", e->u.boolean.b ? "true" : "false");
        return;
    }
    emit_expr(g, e, &b);
    const Type *t = e->type;
    if (!t) {
        /* sema left this expression untyped — common for parameter defaults.
         * Box from the literal's own shape; emitting it raw would drop a
         * bare hstr pointer or int64_t straight into an hval slot. */
        switch (e->kind) {
        case EX_STR:   buf_printf(dst, "hp_of_str(%s)", buf_take(&b)); break;
        case EX_INT:   buf_printf(dst, "hp_of_int(%s)", buf_take(&b)); break;
        case EX_FLOAT: buf_printf(dst, "hp_of_float(%s)", buf_take(&b)); break;
        default:       buf_printf(dst, "hv(%s)", buf_take(&b)); break;
        }
        free(b.data);
        return;
    }
    switch (t->kind) {
    case TY_INT: case TY_I8: case TY_I16: case TY_I32: case TY_I64:
        buf_printf(dst, "hp_of_int(%s)", buf_take(&b)); break;
    case TY_FLOAT: case TY_F32: case TY_F64:
        buf_printf(dst, "hp_of_float(%s)", buf_take(&b)); break;
    case TY_BOOL: buf_printf(dst, "hp_of_bool(%s)", buf_take(&b)); break;
    case TY_STRING: buf_printf(dst, "hp_of_str(%s)", buf_take(&b)); break;
    case TY_ARRAY: case TY_VEC: case TY_MAP: case TY_SET:
        buf_printf(dst, "hp_of_arr(%s)", buf_take(&b)); break;            case TY_FN:
        /* a closure is an hclosure*: box it when an hval is expected */
        buf_printf(dst, "hp_of_clo(%s)", buf_take(&b)); break;
    case TY_CLASS: case TY_INTERFACE: case TY_STRUCT: case TY_ENUM:
        /* user objects/values box as an owned pointer payload */
        buf_printf(dst, "hp_of_ptr(%s)", buf_take(&b)); break;
    default:
        /* dynamic/unknown: hv() is _Generic - identity for hval values and
         * the right boxing constructor for anything else (struct ptrs, ints,
         * bools, ...). Never leaks a raw non-hval into an hval slot. */
        buf_printf(dst, "hv(%s)", buf_take(&b));
        break;
    }
    free(b.data);
}

/* Box a value into a nullable slot, in the shape the slot's member says.
 *
 * A nullable slot holds one member type, and a narrowed read projects that
 * member out of the payload - so the payload has to be in the member's
 * shape. An int in a ?float slot is stored as a float, the way the type
 * says it is; without that the narrowed read would pull an int out of a
 * float payload, and `===` against a float would not match either. */
static void to_hval_member(Codegen *g, Expr *e, const Type *mem, Buf *dst) {
    if (!mem) { to_hval(g, e, dst); return; }
    if (!e) { buf_puts(dst, "hp_null"); return; }
    if (e->kind == EX_NULL) { buf_puts(dst, "hp_null"); return; }
    /* a dynamic value: convert it to the member's shape first */
    if (c_form_is_hval(e)) {
        Buf b;
        buf_init(&b);
        emit_expr(g, e, &b);
        const char *src = buf_take(&b);
        char *boxed = NULL;
        switch (mem->kind) {
        case TY_STRING: boxed = fmt("hp_of_str(hp_val_to_str(%s))", src); break;
        case TY_BOOL:   boxed = fmt("hp_of_bool(hp_val_to_bool(%s))", src); break;
        case TY_FLOAT: case TY_F32: case TY_F64:
            boxed = fmt("hp_of_float(hp_val_to_float(%s))", src);
            break;
        case TY_INT: case TY_I8: case TY_I16: case TY_I32: case TY_I64:
            boxed = fmt("hp_of_int(hp_val_to_int(%s))", src);
            break;
        default:
            /* an object/array payload is the same shape in the box and in
             * the member, so the value goes in as it is */
            boxed = xstrdup(src);
            break;
        }
        /* a null stays null - the slot is nullable, that is the point */
        buf_printf(dst, "(hp_tag(%s) == HV_NULL ? hp_null : %s)", src, boxed);
        free(boxed);
        free(b.data);
        return;
    }
    const Type *t = e->type;
    if (!t || t->kind == mem->kind) { to_hval(g, e, dst); return; }
    /* a plain value in another shape: convert it before boxing */
    Buf b;
    buf_init(&b);
    emit_expr(g, e, &b);
    const char *src = buf_take(&b);
    switch (mem->kind) {
    case TY_FLOAT: case TY_F32: case TY_F64:
        buf_printf(dst, "hp_of_float((double)(%s))", src);
        break;
    case TY_BOOL:
        buf_printf(dst, "hp_of_bool((%s) != 0)", src);
        break;
    default:
        buf_printf(dst, "hp_of_int((int64_t)(%s))", src);
        break;
    }
    free(b.data);
}

/* Box a bare C value (a parameter slot, by name) into an hval. Mirrors
 * to_hval(), but takes a type and an expression string instead of an Expr. */
static const char *box_param_value(const Type *t, const char *expr) {
    switch (t ? t->kind : TY_MIXED) {
    case TY_INT: case TY_I8: case TY_I16: case TY_I32: case TY_I64: case TY_ENUM:
        return fmt("hp_of_int(%s)", expr);
    case TY_FLOAT: case TY_F32: case TY_F64:
        return fmt("hp_of_float(%s)", expr);
    case TY_BOOL: return fmt("hp_of_bool(%s)", expr);
    case TY_STRING: return fmt("hp_of_str(%s)", expr);
    case TY_ARRAY: case TY_VEC: case TY_MAP: case TY_SET:
        return fmt("hp_of_arr(%s)", expr);
    case TY_FN: return fmt("hp_of_clo(%s)", expr);
    case TY_CLASS: case TY_STRUCT: case TY_INTERFACE:
        return fmt("hp_of_ptr(%s)", expr);
    case TY_PTR: return fmt("hp_of_ptr((void*)%s)", expr);
    default: return fmt("hv(%s)", expr);   /* mixed: already an hval */
    }
}

/* If a builtin's hval result is consumed as a scalar, project it. */
static void project_hval(Buf *dst, const Type *ret) {
    if (!ret) return;
    /* Objects are carried in hval.u.p, which is a void*. Unboxing one needs a
     * cast to the concrete struct: without it a `[Thing]`-typed array read
     * yields void* and `->field` on it does not compile. The whole rewrite
     * happens here rather than at each site so method arguments, returns and
     * index reads all agree. */
    if (ret->kind == TY_CLASS || ret->kind == TY_STRUCT) {
        char *raw = buf_take(dst);
        buf_printf(dst, "((struct %s *)((%s).u.p))", ret->name, raw);
        free(raw);
        return;
    }
    switch (ret->kind) {
    case TY_INT: case TY_I8: case TY_I16: case TY_I32: case TY_I64: case TY_ENUM:
        buf_printf(dst, ".u.i"); break;
    case TY_FLOAT: case TY_F32: case TY_F64: buf_printf(dst, ".u.f"); break;
    case TY_BOOL: buf_printf(dst, ".u.b"); break;
    case TY_STRING: buf_printf(dst, ".u.s"); break;
    case TY_ARRAY: case TY_VEC: case TY_MAP: case TY_SET:
        buf_printf(dst, ".u.a"); break;
    default: break;
    }
}

/* Builtins whose C implementation takes an optional trailing argument:
 * calls with fewer args must pad with hp_null (PHP optional params). */
static int builtin_min_args(const char *name) {
    if (strcmp(name, "substr") == 0) return 2;
    if (strcmp(name, "ltrim") == 0 || strcmp(name, "rtrim") == 0) return 1;
    if (strcmp(name, "round") == 0) return 1;
    if (strcmp(name, "str_replace") == 0) return 2;
    if (strcmp(name, "md5") == 0 || strcmp(name, "sha1") == 0) return 1;
    if (strcmp(name, "implode") == 0) return 1;
    if (strcmp(name, "number_format") == 0) return 1;
    if (strcmp(name, "file_put_contents") == 0) return 2;
    if (strcmp(name, "array_merge") == 0 || strcmp(name, "array_replace") == 0 ||
        strcmp(name, "array_diff") == 0 || strcmp(name, "array_intersect") == 0 ||
        strcmp(name, "compact") == 0) return 1;
    if (strcmp(name, "array_map") == 0) return 2;
    if (strcmp(name, "http_post") == 0) return 2;
    if (strcmp(name, "mysql_connect") == 0) return 1;
    if (strcmp(name, "hash_hmac") == 0) return 3;
    if (strcmp(name, "mktime") == 0) return 6;
    return 0; /* 0 = no optional-arg protocol known */
}

/* the C arity of a builtin implementation (max args it accepts) */
static int builtin_max_args(const char *name) {
    if (strcmp(name, "substr") == 0) return 3;
    if (strcmp(name, "ltrim") == 0 || strcmp(name, "rtrim") == 0) return 2;
    if (strcmp(name, "round") == 0) return 3;
    if (strcmp(name, "str_replace") == 0) return 3;
    if (strcmp(name, "md5") == 0 || strcmp(name, "sha1") == 0) return 2;
    if (strcmp(name, "implode") == 0) return 2;
    if (strcmp(name, "array_slice") == 0) return 3;
    if (strcmp(name, "str_split") == 0) return 2;
    if (strcmp(name, "number_format") == 0) return 4;
    if (strcmp(name, "file_put_contents") == 0) return 3;
    if (strcmp(name, "fopen") == 0) return 2;
    if (strcmp(name, "fread") == 0) return 2;
    if (strcmp(name, "array_merge") == 0 || strcmp(name, "array_replace") == 0 ||
        strcmp(name, "array_diff") == 0 || strcmp(name, "array_intersect") == 0 ||
        strcmp(name, "compact") == 0) return 4;
    if (strcmp(name, "mkdir") == 0) return 3;
    if (strcmp(name, "array_column") == 0) return 3;
    if (strcmp(name, "array_chunk") == 0) return 3;
    if (strcmp(name, "array_pad") == 0) return 3;
    if (strcmp(name, "array_walk") == 0 || strcmp(name, "array_walk_recursive") == 0) return 3;
    if (strcmp(name, "basename") == 0 || strcmp(name, "pathinfo") == 0 ||
        strcmp(name, "strip_tags") == 0) return 2;
    if (strcmp(name, "http_request") == 0) return 4;
    if (strcmp(name, "date") == 0) return 2;
    if (strcmp(name, "json_encode") == 0 || strcmp(name, "json_encode_pretty") == 0) return 2;
    if (strcmp(name, "json_decode") == 0) return 2;
    if (strcmp(name, "http_post") == 0) return 3;
    if (strcmp(name, "mysql_connect") == 0) return 5;
    if (strcmp(name, "hash_hmac") == 0) return 4;
    if (strcmp(name, "mktime") == 0) return 6;
    if (strcmp(name, "preg_match") == 0 || strcmp(name, "preg_match_all") == 0 ||
        strcmp(name, "preg_split") == 0 || strcmp(name, "preg_grep") == 0) return 2;
    if (strcmp(name, "preg_replace") == 0) return 3;
    if (strcmp(name, "mysql_query") == 0 || strcmp(name, "mysql_exec") == 0) return 2;
    /* the embedded-Chromium calls that gained optional parameters: a view id
     * plus what to do, where to put the window, or how wide it may be */
    if (strcmp(name, "ui_browser_fit") == 0) return 3;
    if (strcmp(name, "ui_browser_devtools") == 0) return 2;
    if (strcmp(name, "ui_browser_devtools_fit") == 0) return 5;
    return -1;
}

/* min args for the new optional-arg builtins */

/* ---------------- string literals ---------------- */
static void emit_c_string(const char *s, size_t n, Buf *dst) {
    buf_putc(dst, '"');
    for (size_t i = 0; i < n; i++) {
        unsigned char c = (unsigned char)s[i];
        switch (c) {
        case '"': buf_puts(dst, "\\\""); break;
        case '\\': buf_puts(dst, "\\\\"); break;
        case '\n': buf_puts(dst, "\\n"); break;
        case '\t': buf_puts(dst, "\\t"); break;
        case '\r': buf_puts(dst, "\\r"); break;
        default:
            if (c < 32 || c == 127) buf_printf(dst, "\\x%02x", c);
            else buf_putc(dst, (char)c);
        }
    }
    buf_putc(dst, '"');
}

static void emit_str_lit(const char *s, Buf *dst) {
    size_t n = strlen(s);
    /* A per-call-site cache: the literal's address is stable, so the first
     * evaluation interns it and every later one is a load instead of a hash
     * probe. Statement expressions are a GCC/Clang extension; the backend
     * compiles with gcc. */
    buf_puts(dst, "({ static hstr *hp_lit_; if (!hp_lit_) hp_lit_ = hp_str_intern(");
    emit_c_string(s, n, dst);
    buf_puts(dst, "); hp_lit_; })");
}

/* ---------------- expressions ---------------- */
static void emit_tpl(Codegen *g, Expr *e, Buf *dst) {
    size_t nexpr = e->u.tpl.exprs.len;
    if (nexpr == 0) {
        emit_str_lit(e->u.tpl.strs.len ? e->u.tpl.strs.items[0] : "", dst);
        return;
    }
    /* count total parts: non-empty literal chunks + one per interpolation */
    size_t nparts = nexpr;
    for (size_t i = 0; i < e->u.tpl.strs.len; i++)
        if (e->u.tpl.strs.items[i] && *(char *)e->u.tpl.strs.items[i]) nparts++;
    Buf parts;
    buf_init(&parts);
    buf_printf(&parts, "hp_str_concat_n(%zu, (const hval[]){", nparts);
    size_t si = 0;
    bool first_part = true;
    #define CSEP() do { if (!first_part) buf_puts(&parts, ", "); first_part = false; } while (0)
    for (size_t i = 0; i < nexpr; i++) {
        const char *s = si < e->u.tpl.strs.len ? e->u.tpl.strs.items[si++] : "";
        if (s && *s) {
            CSEP();
            buf_puts(&parts, "hp_of_str(");
            emit_str_lit(s, &parts);
            buf_puts(&parts, ")");
        }
        CSEP();
        to_hval(g, e->u.tpl.exprs.items[i], &parts);
    }
    const char *tail = si < e->u.tpl.strs.len ? e->u.tpl.strs.items[si] : NULL;
    if (tail && *tail) {
        CSEP();
        buf_puts(&parts, "hp_of_str(");
        emit_str_lit(tail, &parts);
        buf_puts(&parts, ")");
    }
    buf_puts(&parts, "})");
    buf_write(dst, parts.data ? parts.data : "", parts.len);
    free(parts.data);
    #undef CSEP
}

/* Constant folding: pure-int binops on two int literals become C literals.
 * Removes runtime helper calls from hot loops and lets gcc see constant
 * loop bounds. Wrap-around math is done in unsigned to avoid UB. */
static bool fold_int_binop(TokKind op, long long a, long long b, long long *out) {
    switch (op) {
    case T_PLUS:  *out = (long long)((unsigned long long)a + (unsigned long long)b); return true;
    case T_MINUS: *out = (long long)((unsigned long long)a - (unsigned long long)b); return true;
    case T_STAR:  *out = (long long)((unsigned long long)a * (unsigned long long)b); return true;
    case T_PERCENT: if (b == 0) return false; *out = a % b; return true;
    case T_SHL: if (b < 0 || b > 63) return false; *out = (long long)((unsigned long long)a << b); return true;
    case T_SHR: if (b < 0 || b > 63) return false; *out = a >> b; return true;
    case T_AMP:   *out = a & b; return true;
    case T_PIPE:  *out = a | b; return true;
    case T_CARET: *out = a ^ b; return true;
    default: return false;   /* T_SLASH: PHP / is float division, never fold */
    }
}

/* An operand already emitted as C text, boxed for a runtime hval call.
 *
 * A bool literal must go through hp_of_bool: under C11 `true`/`false` are
 * macros for the ints 1/0, so hv() tags them HV_INT. That made
 * `"x" == false` true (0 == 0 numerically) and `"x" == true` false - the
 * bool branch of hp_val_eq never ran. */
static void hv_operand(const Expr *e, const char *s, Buf *dst) {
    if (e && e->kind == EX_BOOL)
        buf_printf(dst, "hp_of_bool(%s)", e->u.boolean.b ? "true" : "false");
    else
        buf_printf(dst, "hv(%s)", s);
}

static void emit_binop(Codegen *g, Expr *e, Buf *dst) {
    if (e->is_slice) {
        Buf o, lo, hi;
        buf_init(&o); buf_init(&lo); buf_init(&hi);
        emit_expr(g, e->u.bin.l, &o);
        emit_expr(g, e->u.bin.r, &lo);
        if (e->u.bin.slice_hi) emit_expr(g, e->u.bin.slice_hi, &hi);
        else buf_puts(&hi, "(int64_t)-1");
        const Type *t = e->u.bin.l->type;
        if (t && t->kind == TY_STRING)
            buf_printf(dst, "hp_str_slice(%s, %s, %s)", buf_take(&o), buf_take(&lo), buf_take(&hi));
        else
            buf_printf(dst, "hp_arr_slice(%s, %s, %s)", buf_take(&o), buf_take(&lo), buf_take(&hi));
        free(o.data); free(lo.data); free(hi.data);
        return;
    }
    if (e->is_nullcoal) {
        Buf l, r;
        buf_init(&l); buf_init(&r);
        to_hval(g, e->u.bin.l, &l);
        to_hval(g, e->u.bin.r, &r);
        buf_printf(dst, "hp_nullcoal(%s, %s)", buf_take(&l), buf_take(&r));
        free(l.data); free(r.data);
        return;
    }
    TokKind op = e->u.bin.op.kind;
    /* long `.` chains are emitted balanced, before the operands are walked */
    if (op == T_DOT && !e->is_nullcoal && dot_chain_len(e) > 3) {
        int cap = dot_chain_len(e);
        Expr **parts = (Expr **)xmalloc((size_t)cap * sizeof(Expr *));
        int n = dot_collect(e, parts, cap);
        emit_dot_chain(g, parts, 0, n, dst);
        free(parts);
        return;
    }
    const Type *lt = e->u.bin.l->type;
    const Type *rt = e->u.bin.r->type;
    bool ln = type_is_numeric(lt ? lt->kind : TY_ERROR);
    bool rn = type_is_numeric(rt ? rt->kind : TY_ERROR);
    bool lf = lt && (lt->kind == TY_FLOAT || lt->kind == TY_F32 || lt->kind == TY_F64);
    bool rf = rt && (rt->kind == TY_FLOAT || rt->kind == TY_F32 || rt->kind == TY_F64);
    bool numeric = ln && rn;
    bool strings = lt && rt && lt->kind == TY_STRING && rt->kind == TY_STRING;
    Buf l, r;
    buf_init(&l); buf_init(&r);
    emit_expr(g, e->u.bin.l, &l);
    emit_expr(g, e->u.bin.r, &r);
    const char *ls = buf_take(&l);
    const char *rs = buf_take(&r);
    /* two int literals + a native-safe op => emit the folded C literal */
    if (numeric && !lf && !rf && e->u.bin.l->kind == EX_INT && e->u.bin.r->kind == EX_INT) {
        long long folded;
        if (fold_int_binop(op, e->u.bin.l->u.i.ival, e->u.bin.r->u.i.ival, &folded)) {
            buf_printf(dst, "(int64_t)%lldLL", folded);
            free((void *)ls);
            free((void *)rs);
            return;
        }
    }
    /* float comparisons take two doubles: a mixed operand arrives as an
     * hval and must be unboxed first (hp_lt_f(double, double) etc.) */
    if (lf || rf) {
        if (lt && lt->kind == TY_MIXED) {
            char *w = fmt("hp_val_to_float(hv(%s))", ls);
            free((void *)ls);
            ls = w;
        }
        if (rt && rt->kind == TY_MIXED) {
            char *w = fmt("hp_val_to_float(hv(%s))", rs);
            free((void *)rs);
            rs = w;
        }
    }
    /* && and || need scalar bools: mixed operands (e.g. an hval callback
     * param like $eof) are PHP-truthiness-converted first, exactly like
     * mixed operands of the float comparisons above */
    if (op == T_ANDAND || op == T_OROR) {
        if (lt && lt->kind == TY_MIXED) {
            char *w = fmt("hp_val_to_bool(hv(%s))", ls);
            free((void *)ls);
            ls = w;
        }
        if (rt && rt->kind == TY_MIXED) {
            char *w = fmt("hp_val_to_bool(hv(%s))", rs);
            free((void *)rs);
            rs = w;
        }
    }
    switch (op) {
    case T_PLUS:
        if (lt && lt->kind == TY_PTR && lt->elem) {
            const char *pt = lt->elem->kind == TY_I8 ? "unsigned char" : ctype_of(lt->elem);
            buf_printf(dst, "((%s*)(%s) + (%s))", pt, ls, rs);
        }
        else if (lt && lt->kind == TY_PTR) buf_printf(dst, "((char*)(%s) + (%s))", ls, rs);
        else if (numeric) buf_printf(dst, "((%s) + (%s))", ls, rs);
        /* the runtime's hp_add keeps PHP semantics (numeric strings add as
         * numbers), so only project to hstr* when the node is typed string */
        else if (e->type && e->type->kind == TY_STRING)
            buf_printf(dst, "hp_add(hv(%s), hv(%s)).u.s", ls, rs);
        else
            buf_printf(dst, "hp_add(hv(%s), hv(%s))", ls, rs);
        break;
    case T_MINUS:
        if (lt && lt->kind == TY_PTR && lt->elem) {
            const char *pt = lt->elem->kind == TY_I8 ? "unsigned char" : ctype_of(lt->elem);
            buf_printf(dst, "((%s*)(%s) - (%s))", pt, ls, rs);
        }
        else if (lt && lt->kind == TY_PTR) buf_printf(dst, "((char*)(%s) - (%s))", ls, rs);
        else if (numeric) buf_printf(dst, "((%s) - (%s))", ls, rs);
        else buf_printf(dst, "hpbi_scalar_sub(hv(%s), hv(%s))", ls, rs);
        break;
    case T_STAR:
        if (numeric) buf_printf(dst, "((%s) * (%s))", ls, rs);
        else buf_printf(dst, "hpbi_scalar_mul(hv(%s), hv(%s))", ls, rs);
        break;
    /* Integer shifts are common in typed unsafe record decoders. Keep them
     * in C integer space instead of wrapping/unwrapping each operand as an
     * hval. Dynamic and string operands still use PHP's int conversion. */
    case T_SHL:
        if (lt && rt && type_is_integral(lt->kind) && type_is_integral(rt->kind))
            buf_printf(dst, "((%s) << (%s))", ls, rs);
        else
            buf_printf(dst, "(hp_val_to_int(hv(%s)) << hp_val_to_int(hv(%s)))", ls, rs);
        break;
    case T_SHR:
        if (lt && rt && type_is_integral(lt->kind) && type_is_integral(rt->kind))
            buf_printf(dst, "((%s) >> (%s))", ls, rs);
        else
            buf_printf(dst, "(hp_val_to_int(hv(%s)) >> hp_val_to_int(hv(%s)))", ls, rs);
        break;
    case T_SLASH:
        /* the fast path is plain double division; a string operand has to go
         * through the value-aware runtime (hp_divv), whose result is hval */
        if (lt && rt && type_is_numeric(lt->kind) && type_is_numeric(rt->kind)) {
            /* nonzero literal divisor: "Division by zero" is impossible, so
             * emit plain C division — gcc turns it into reciprocal-multiply
             * and can auto-vectorize loops exactly like hand-written C */
            if (e->u.bin.r->kind == EX_INT && e->u.bin.r->u.i.ival != 0)
                buf_printf(dst, "(((double)(%s)) / ((double)(%s)))", ls, rs);
            else
                buf_printf(dst, "hp_div((%s), (%s))", ls, rs);
        }
        else
            /* hp_divv yields hval, but PHP division always produces a float
             * (sema types this node float) — unbox so the emitted C matches */
            buf_printf(dst, "hp_val_to_float(hp_divv(hv(%s), hv(%s)))", ls, rs);
        break;
    case T_PERCENT:
        /* inline-native modulo keeps hot loops free of out-of-line calls;
         * hp_mod_i still throws PHP's "Modulo by zero" */
        if (numeric) buf_printf(dst, "hp_mod_i(%s, %s)", ls, rs);
        else buf_printf(dst, "hp_mod(hp_val_to_int(hv(%s)), hp_val_to_int(hv(%s)))", ls, rs);
        break;
    case T_POW:
        if (numeric) buf_printf(dst, "hp_pow_i((int64_t)(%s), (int64_t)(%s))", ls, rs);
        else buf_printf(dst, "hp_powv(hv(%s), hv(%s))", ls, rs);
        break;
    case T_DOT:
        buf_printf(dst, "hp_str_join_v(hv(%s), hv(%s))", ls, rs);
        break;
    case T_EQ:
        if (numeric) buf_printf(dst, "((%s) == (%s))", ls, rs);
        else if (strings) buf_printf(dst, "hp_str_eq(%s, %s)", ls, rs);
        else {
            Buf bl, br;
            buf_init(&bl); buf_init(&br);
            hv_operand(e->u.bin.l, ls, &bl);
            hv_operand(e->u.bin.r, rs, &br);
            buf_printf(dst, "hp_streq(%s, %s)", buf_take(&bl), buf_take(&br));
            free(bl.data); free(br.data);
        }
        break;
    case T_EQ2:
        /* identity: tag and value must both match */
        if (strings) {
            buf_printf(dst, "hp_str_eq(%s, %s)", ls, rs);
        } else if (numeric && lt->kind == rt->kind) {
            buf_printf(dst, "((%s) == (%s))", ls, rs);
        } else {
            Buf bl, br;
            buf_init(&bl); buf_init(&br);
            hv_operand(e->u.bin.l, ls, &bl);
            hv_operand(e->u.bin.r, rs, &br);
            buf_printf(dst, "hp_ident_eq(%s, %s)", buf_take(&bl), buf_take(&br));
            free(bl.data); free(br.data);
        }
        break;
    case T_NEQ: case T_NEQ2:
        if (op == T_NEQ2 && strings) {
            buf_printf(dst, "(!hp_str_eq(%s, %s))", ls, rs);
            break;
        }
        if (op == T_NEQ2 && numeric && lt->kind == rt->kind) {
            buf_printf(dst, "((%s) != (%s))", ls, rs);
            break;
        }
        if (op == T_NEQ) {
            if (numeric) { buf_printf(dst, "((%s) != (%s))", ls, rs); break; }
            if (strings) { buf_printf(dst, "(!hp_str_eq(%s, %s))", ls, rs); break; }
            Buf bl, br;
            buf_init(&bl); buf_init(&br);
            hv_operand(e->u.bin.l, ls, &bl);
            hv_operand(e->u.bin.r, rs, &br);
            buf_printf(dst, "(!hp_streq(%s, %s))", buf_take(&bl), buf_take(&br));
            free(bl.data); free(br.data);
            break;
        }
        {
            Buf bl, br;
            buf_init(&bl); buf_init(&br);
            hv_operand(e->u.bin.l, ls, &bl);
            hv_operand(e->u.bin.r, rs, &br);
            buf_printf(dst, "(!hp_ident_eq(%s, %s))", buf_take(&bl), buf_take(&br));
            free(bl.data); free(br.data);
        }
        break;
    case T_LT:
        if (lf || rf) buf_printf(dst, "hp_lt_f((%s), (%s))", ls, rs);
        else if (numeric) buf_printf(dst, "hp_lt_i((%s), (%s))", ls, rs);
        else buf_printf(dst, "hp_lt(hv(%s), hv(%s))", ls, rs);
        break;
    case T_GT:
        if (lf || rf) buf_printf(dst, "hp_gt_f((%s), (%s))", ls, rs);
        else if (numeric) buf_printf(dst, "hp_gt_i((%s), (%s))", ls, rs);
        else buf_printf(dst, "hp_gt(hv(%s), hv(%s))", ls, rs);
        break;
    case T_LE:
        if (lf || rf) buf_printf(dst, "hp_le_f((%s), (%s))", ls, rs);
        else if (numeric) buf_printf(dst, "hp_le_i((%s), (%s))", ls, rs);
        else buf_printf(dst, "hp_le(hv(%s), hv(%s))", ls, rs);
        break;
    case T_GE:
        if (lf || rf) buf_printf(dst, "hp_ge_f((%s), (%s))", ls, rs);
        else if (numeric) buf_printf(dst, "hp_ge_i((%s), (%s))", ls, rs);
        else buf_printf(dst, "hp_ge(hv(%s), hv(%s))", ls, rs);
        break;
    case T_SPACESHIP: buf_printf(dst, "hp_cmp(hv(%s), hv(%s))", ls, rs); break;
    case T_ANDAND: buf_printf(dst, "((%s) && (%s))", ls, rs); break;
    case T_OROR: buf_printf(dst, "((%s) || (%s))", ls, rs); break;
    case T_AMP: buf_printf(dst, "((%s) & (%s))", ls, rs); break;
    case T_PIPE: buf_printf(dst, "((%s) | (%s))", ls, rs); break;
    case T_CARET: buf_printf(dst, "((%s) ^ (%s))", ls, rs); break;
    default: buf_printf(dst, "hpbi_scalar_binop(hv(%s), hv(%s))", ls, rs); break;
    }
    free((void *)ls);
    free((void *)rs);
}

static void emit_builtin_call_body(Codegen *g, const char *name, PtrVec args,
                                   const Type *ret, Buf *dst);

/* Builtin calls project their hval result onto the C type the caller
 * wants, and that projection REWRITES the buffer it is handed (see
 * emit_index). Emit into a private buffer first, so a projection can never
 * reach back into text the caller had already written - an argument left
 * inside the enclosing call would be wrapped instead of the result. */
static void emit_builtin_call(Codegen *g, const char *name, PtrVec args,
                              const Type *ret, Buf *dst) {
    Buf out;
    buf_init(&out);
    emit_builtin_call_body(g, name, args, ret, &out);
    char *code = buf_take(&out);
    buf_puts(dst, code);
    free(code);
}

static void emit_builtin_call_body(Codegen *g, const char *name, PtrVec args,
                                   const Type *ret, Buf *dst) {
    if (strcmp(name, "max") == 0 || strcmp(name, "min") == 0) {
        /* single array argument: pass it as-is (PHP max([1,2,3]));
         * otherwise pack the variadic args into a runtime array */
        if (args.len == 1) {
            buf_puts(dst, "hpbi_");
            buf_puts(dst, name);
            buf_puts(dst, "(");
            to_hval(g, args.items[0], dst);
            buf_puts(dst, ")");
            project_hval(dst, ret);
            return;
        }
        /* variadic: pack args into a runtime array */
        buf_printf(dst, "hpbi_%s(hp_of_arr(hp_arr_of(%zu, (const hval[]){", name, args.len);
        for (size_t i = 0; i < args.len; i++) {
            if (i) buf_puts(dst, ", ");
            to_hval(g, args.items[i], dst);
        }
        buf_puts(dst, "})))");
        project_hval(dst, ret);
        return;
    }
    /* unset($arr[$k]): needs the raw harr*, not a copy.
     * Sema types the whole $arr[$k] expression as the builtin call, so we
     * re-derive the container/index from the expression tree here. */
    if (strcmp(name, "unset") == 0 && args.len == 1 &&
        ((Expr *)args.items[0])->kind == EX_INDEX) {
        Expr *ix = (Expr *)args.items[0];
        Expr *obj = ix->u.index.obj;
        if (obj->kind == EX_VAR && obj->u.var.sym && ix->u.index.idx) {
            Buf k;
            buf_init(&k);
            emit_expr(g, ix->u.index.idx, &k);
            buf_printf(dst, "hpbi_unset(%s, hv(%s))", var_name(obj->u.var.sym),
                       buf_take(&k));
            project_hval(dst, ret);
            free(k.data);
            return;
        }
        if (obj->kind == EX_FIELD && obj->u.field.obj && obj->u.field.sf) {
            /* unset($this->arr[$k]) / unset($o->arr[$k]): the field is a
             * typed struct member holding harr*; cow-write the delete */
            StructField *usf = (StructField *)obj->u.field.sf;
            Buf k, o;
            buf_init(&k);
            emit_expr(g, ix->u.index.idx, &k);
            buf_init(&o);
            emit_expr(g, obj->u.field.obj, &o);
            buf_printf(dst, "hpbi_unset_slot(&(%s)->%s, hv(%s))",
                       buf_take(&o), usf->name, buf_take(&k));
            project_hval(dst, ret);
            free(k.data);
            free(o.data);
            return;
        }
    }
    /* Exception handling helpers: getMessage() on the catch var */
    if (strcmp(name, "exception_get_message") == 0) {
        buf_puts(dst, "hp_of_str(hp_exception_msg())");
        project_hval(dst, ret);
        return;
    }
    /* sprintf/printf: pack args into a runtime array like max/min */
    if ((strcmp(name, "sprintf") == 0 || strcmp(name, "printf") == 0) && args.len >= 1) {
        buf_printf(dst, "hpbi_%s(", name);
        to_hval(g, args.items[0], dst);
        buf_puts(dst, ", hp_of_arr(hp_arr_of(");
        buf_printf(dst, "%zu, (const hval[]){", args.len - 1);
        for (size_t i = 1; i < args.len; i++) {
            if (i > 1) buf_puts(dst, ", ");
            to_hval(g, args.items[i], dst);
        }
        buf_puts(dst, "})))");
        project_hval(dst, ret);
        return;
    }
    /* optional-arg builtins: ltrim/rtrim($s, $chars) or ($s) */
    if ((strcmp(name, "ltrim") == 0 || strcmp(name, "rtrim") == 0) && args.len == 1) {
        buf_printf(dst, "hpbi_%s(", name);
        to_hval(g, args.items[0], dst);
        buf_puts(dst, ", hp_null)");
        project_hval(dst, ret);
        return;
    }
    /* pow: 1-arg form is not PHP, but keep it tolerant */
    if (strcmp(name, "pow") == 0) {
        buf_printf(dst, "hpbi_pow(");
        for (size_t i = 0; i < args.len; i++) {
            if (i) buf_puts(dst, ", ");
            to_hval(g, args.items[i], dst);
        }
        buf_puts(dst, ")");
        project_hval(dst, ret);
        return;
    }
    /* str_replace with 2 args: PHP needs 3 — sema now allows B_MISC, but
     * guard the 2-arg call to the 3-arg C function */
    if (strcmp(name, "str_replace") == 0) {
        buf_printf(dst, "hpbi_str_replace(");
        for (size_t i = 0; i < args.len; i++) {
            if (i) buf_puts(dst, ", ");
            to_hval(g, args.items[i], dst);
        }
        if (args.len == 2) buf_puts(dst, ", hp_null");
        buf_puts(dst, ")");
        project_hval(dst, ret);
        return;
    }
    /* stream_socket_accept2 with optional timeout: default 0 (poll once) */
    if (strcmp(name, "stream_socket_accept2") == 0) {
        buf_puts(dst, "hpbi_stream_socket_accept2(");
        to_hval(g, args.items[0], dst);
        buf_puts(dst, ", ");
        if (args.len == 2) { to_hval(g, args.items[1], dst); }
        else buf_puts(dst, "hp_of_int(0)");
        buf_puts(dst, ")");
        project_hval(dst, ret);
        return;
    }
    /* threading primitives with optional trailing args */
    if (strcmp(name, "thr_spawn") == 0) {
        buf_puts(dst, "hpbi_thr_spawn(");
        to_hval(g, args.items[0], dst);
        if (args.len == 2) { buf_puts(dst, ", "); to_hval(g, args.items[1], dst); }
        else buf_puts(dst, ", hp_null");
        buf_puts(dst, ")");
        project_hval(dst, ret);
        return;
    }
    if (strcmp(name, "thr_parallel_map") == 0) {
        buf_puts(dst, "hpbi_thr_parallel_map(");
        to_hval(g, args.items[0], dst);
        buf_puts(dst, ", ");
        to_hval(g, args.items[1], dst);
        if (args.len == 3) { buf_puts(dst, ", "); to_hval(g, args.items[2], dst); }
        else buf_puts(dst, ", hp_of_int(0)");
        buf_puts(dst, ")");
        project_hval(dst, ret);
        return;
    }
    if (strcmp(name, "atomic_new") == 0 && args.len == 0) {
        buf_puts(dst, "hpbi_atomic_new(hp_of_int(0))");
        project_hval(dst, ret);
        return;
    }
    /* strpos with optional offset: default 0 */
    if (strcmp(name, "strpos") == 0) {
        buf_puts(dst, "hpbi_strpos(");
        to_hval(g, args.items[0], dst);
        buf_puts(dst, ", ");
        to_hval(g, args.items[1], dst);
        if (args.len == 3) { buf_puts(dst, ", "); to_hval(g, args.items[2], dst); }
        else buf_puts(dst, ", hp_null");
        buf_puts(dst, ")");
        project_hval(dst, ret);
        return;
    }
    /* optional-argument builtins: PHP allows microtime(true) — ignore flag */
    if (strcmp(name, "microtime") == 0 && args.len == 1) {
        buf_puts(dst, "hpbi_microtime()");
        project_hval(dst, ret);
        return;
    }
    /* hrtime(bool $as_number) — PHP semantics; flag accepted, always int ns */
    if (strcmp(name, "hrtime") == 0 && args.len == 1) {
        buf_puts(dst, "hpbi_hrtime(");
        to_hval(g, args.items[0], dst);
        buf_puts(dst, ")");
        project_hval(dst, ret);
        return;
    }
    /* md5/sha1 take an optional raw-output flag: pad missing args with null */
    if ((strcmp(name, "md5") == 0 || strcmp(name, "sha1") == 0) &&
        (args.len == 1 || args.len == 2)) {
        buf_printf(dst, "hpbi_%s(", name);
        for (size_t i = 0; i < args.len; i++) {
            if (i) buf_puts(dst, ", ");
            to_hval(g, args.items[i], dst);
        }
        if (args.len == 1) buf_puts(dst, ", hp_null");
        buf_puts(dst, ")");
        project_hval(dst, ret);
        return;
    }
    /* optional-argument builtins: compiler calls them with 1 arg */
    if (strcmp(name, "round") == 0 && args.len == 1) {
        buf_printf(dst, "hpbi_round(");
        to_hval(g, args.items[0], dst);
        buf_puts(dst, ", hp_null, hp_null)");
        project_hval(dst, ret);
        return;
    }
    /* isset(): emit the index expression RAW (as hval, without the
     * compiler's type projection). Missing keys must reach the helper as
     * hp_null, not as the projected 0/"". The raw emit of an array index
     * yields a typed read (hp_arr_get + .u.i projection) which zeroes
     * missing keys — so for `$var[...]` targets read the element hval
     * directly through the runtime helper instead. */
    if (strcmp(name, "isset") == 0 && args.len == 1) {
        Expr *arg = (Expr *)args.items[0];            if (arg->kind == EX_INDEX && arg->u.index.obj->kind == EX_VAR &&
                arg->u.index.obj->u.var.sym) {
                Buf ix;
                buf_init(&ix);
                if (arg->u.index.idx) emit_expr(g, arg->u.index.idx, &ix);
                else buf_puts(&ix, "(int64_t)0");
                /* the variable's slot type decides how the array is reached:
                 * a typed (harr*) variable holds the array directly, while a
                 * mixed (hval) variable boxes it — reading it as harr** would
                 * reinterpret a tagged value as a pointer (invalid C, and on
                 * strict gcc an error) */
                const Type *vt = ((VarSym *)arg->u.index.obj->u.var.sym)->type;
                if (vt && vt->kind == TY_MIXED)
                    buf_printf(dst, "hpbi_isset_val(&%s, hv(%s))",
                               var_name(arg->u.index.obj->u.var.sym), buf_take(&ix));
                else
                    buf_printf(dst, "hpbi_isset_raw(&%s, hv(%s))",
                               var_name(arg->u.index.obj->u.var.sym), buf_take(&ix));
            } else {
            Buf raw;
            buf_init(&raw);
            emit_expr(g, arg, &raw);
            buf_printf(dst, "hpbi_isset(hv(%s))", buf_take(&raw));
        }
        project_hval(dst, ret);
        return;
    }
    /* generic builtin: pad missing optional args with hp_null so the C
     * implementation's arity is always satisfied (PHP-style optionals) */
    /* preg_match/_all with a $matches out-var: pass the hval slot by
     * pointer (the implementations take hval*) — one-off, like is_array */
    if ((strcmp(name, "preg_match") == 0 || strcmp(name, "preg_match_all") == 0) &&
        args.len == 3 && ((Expr *)args.items[2])->kind == EX_VAR &&
        ((Expr *)args.items[2])->u.var.sym) {
        Buf mv, p0, p1;
        buf_init(&mv);
        buf_init(&p0);
        buf_init(&p1);
        emit_expr(g, (Expr *)args.items[2], &mv);
        to_hval(g, (Expr *)args.items[0], &p0);
        to_hval(g, (Expr *)args.items[1], &p1);
        static int pm_n = 0;
        int tn = ++pm_n;
        /* the out-var may be typed as a real array (harr*) by sema — then it
         * takes the raw pointer, not an hval wrapper */
        const Type *pvt = ((Expr *)args.items[2])->type;
        int raw_arr = pvt && (pvt->kind == TY_ARRAY || pvt->kind == TY_VEC ||
                              pvt->kind == TY_MAP || pvt->kind == TY_SET);
        char *mvn = buf_take(&mv);
        Buf asg;
        buf_init(&asg);
        if (raw_arr)
            buf_printf(&asg, "%s = _pm%d.u.a", mvn, tn);
        else
            buf_printf(&asg, "%s = hp_of_arr(_pm%d.u.a)", mvn, tn);
        /* statement expression: fills $matches from the temp hval,
         * yields the hval result (projected by the caller) */
        buf_printf(dst,
            "({ hval _pm%d = hp_null; hval _pr%d = hpbi_%s3(%s, %s, &_pm%d); "
            "%s; _pr%d; })",
            tn, tn, name, buf_take(&p0), buf_take(&p1), tn,
            buf_take(&asg), tn);
        project_hval(dst, ret);
        return;
    }
    if (strcmp(name, "str_pad") == 0 && args.len == 2) {
        /* PHP: pad string defaults to " " */
        buf_puts(dst, "hpbi_str_pad(");
        to_hval(g, args.items[0], dst);
        buf_puts(dst, ", ");
        to_hval(g, args.items[1], dst);
        buf_puts(dst, ", hp_of_str(hp_str_intern(\" \")))");
        project_hval(dst, ret);
        return;
    }
    if (strcmp(name, "json_encode_pretty") == 0 && args.len >= 1) {
        /* always pretty: json_encode2(v, flags=JSON_PRETTY_PRINT) */
        buf_puts(dst, "hpbi_json_encode2(");
        to_hval(g, args.items[0], dst);
        buf_puts(dst, ", hp_of_int(1))");
        project_hval(dst, ret);
        return;
    }
    /* Typed fast path: when every argument has the static type the builtin
     * expects, call the raw-typed variant and skip hval boxing on both
     * sides. Falls through to the hval ABI for anything else. */
    {
        static const struct { const char *name; const char *params; char ret; } T[] = {
            {"iarr_new",          "i",   'i'},
            {"iarr_release",      "i",   'b'},
            {"iarr_get",          "ii",  'i'},
            {"iarr_set",          "iii", 'b'},
            {"iarr_len",          "i",   'i'},
            {"epoll_wait_iarr2",  "iii", 'b'},
            {"sb_new",           "",    'i'},
            {"sb_reserve",       "ii",  'b'},
            {"sb_len",           "i",   'i'},
            {"sb_data_ptr",      "i",   'i'},
            {"sb_discard",       "i",   'b'},
            {"sb_prepend",       "is",  'b'},
            {"sb_put",           "is",  'b'},
            {"sb_bytes",         "iii", 'b'},
            {"sb_int",           "ii",  'b'},
            {"sb_json",          "iii", 'b'},
            {"sb_json_str",      "is",  'b'},
            {"sb_take",          "i",   's'},
            {"stream_send_sb",   "ii",  'i'},
            {"int_digits",       "i",   'i'},
            {"jwt_verify",       "ssi", 's'},
            {"jwt_verifier_new", "s",   's'},
            {"jwt_verify_prepared", "ssi", 's'},
            {"json_str_field",   "ss",  's'},
            {"json_num_field",   "ss",  'i'},
            {"bt_last",          "i",   'i'},
            {"bt_first",         "i",   'i'},
            {"bt_prev",          "i",   'i'},
            {"bt_next",          "i",   'i'},
            {"bt_seek",          "ii",  'i'},
            {"bt_multi_seek",    "iii", 'i'},
            {"bt_multi_payloads", "ii", 'b'},
            {"bt_multi_release", "i",   'b'},
            {"bt_rowid",         "i",   'i'},
            {"bt_payload_ptr",   "i",   'i'},
            {"bt_payload_size",  "i",   'i'},
            {"bt_payload_pin",   "i",   'i'},
            {"bt_page_release",  "i",   'b'},
            {"bt_cols",          "i",   'i'},
            {"bt_col_off",       "i",   'i'},
            {"bt_col_len",       "i",   'i'},
            {"bt_col_int",       "i",   'i'},
            {"bt_read",          "iii", 'i'},
            {"stream_send_nb",   "is",  'i'},
            {"stream_send2_nb",  "iss", 'i'},
            {"epoll_mod",        "ii",  'b'},
            {"nofile_limit",     "",    'i'},
            {"runtime_stats",    "",    's'},
            {"uring_active",     "",    'b'},
            {"uring_direct",     "",    'b'},
            {"uring_direct_slots", "",  'i'},
            {"strlen",           "s",   'i'},
            {"str_at_eq",        "siis", 'b'},
            {"str_to_int",       "s",   'i'},
            {"strtolower",       "s",   's'},
            {"trim",             "s",   's'},
            {"substr",           "sii", 's'},
            {"stream_recv",      "ii",  's'},
            {"stream_recv_release", "i", 'b'},
            {"sqlite_bind_int",  "iii", 'b'},
            {"sqlite_bind_text", "iis", 'b'},
            {"sqlite_step",      "i",   'i'},
            {"sqlite_reset",     "i",   'i'},
            {"sqlite_clear_bindings", "i", 'b'},
            {"sqlite_column_text", "ii", 's'},
            {"sqlite_column_int",  "ii", 'i'},
            {"sqlite_changes",     "i",  'i'},
        };
        for (size_t k = 0; k < sizeof T / sizeof T[0]; k++) {
            if (strcmp(name, T[k].name) != 0) continue;
            if (strlen(T[k].params) != args.len) break;
            bool ok = true;
            for (size_t i = 0; i < args.len; i++) {
                const Type *at = ((Expr *)args.items[i])->type;
                char want = T[k].params[i];
                if (!at) { ok = false; break; }
                if (want == 'i') { if (!type_is_integral(at->kind)) { ok = false; break; } }
                else if (want == 's') { if (at->kind != TY_STRING) { ok = false; break; } }
                else { ok = false; break; }
            }
            if (!ok) break;
            if (!ret) break;
            bool ret_ok = (T[k].ret == 'i' && type_is_integral(ret->kind)) ||
                          (T[k].ret == 's' && ret->kind == TY_STRING) ||
                          (T[k].ret == 'b' && ret->kind == TY_BOOL);
            if (!ret_ok) break;
            buf_printf(dst, "hp_%s_t(", name);
            for (size_t i = 0; i < args.len; i++) {
                if (i) buf_puts(dst, ", ");
                emit_expr(g, args.items[i], dst);
            }
            buf_puts(dst, ")");
            return;
        }
    }
    const char *cname = name;   /* emitted C name (aliases below) */
    if (strcmp(name, "date") == 0) cname = "date2";
    else if (strcmp(name, "json_encode") == 0) cname = "json_encode2";
    else if (strcmp(name, "json_decode") == 0) cname = "json_decode2";
    else if (strcmp(name, "json_encode_pretty") == 0) cname = "json_encode2";
    buf_printf(dst, "hpbi_%s(", cname);
    for (size_t i = 0; i < args.len; i++) {
        if (i) buf_puts(dst, ", ");
        to_hval(g, args.items[i], dst);
    }
    {
        int mn = builtin_min_args(name), mx = builtin_max_args(name);
        if (mx >= 0 && (int)args.len < mx && (int)args.len >= mn)
            for (int i = (int)args.len; i < mx; i++) buf_puts(dst, ", hp_null");
    }
    buf_puts(dst, ")");
    project_hval(dst, ret);
}

/* Emit a condition as a C boolean. PHP truthiness applies when the
 * condition's static type is dynamic (mixed/hval): hp_val_to_bool does the
 * runtime conversion. Statically-typed bools stay untouched. */
static void emit_cond(Codegen *g, Expr *cond, Buf *dst) {
    const Type *ct = cond->type;
    /* a dynamic value is truthiness-tested: null, "" and 0 are falsy */
    bool boxed = !ct || ct->kind == TY_MIXED || ct->kind == TY_OPTION ||
                 ct->kind == TY_RESULT || ct->kind == TY_NULL ||
                 ct->kind == TY_NULLABLE || ct->kind == TY_UNION;
    if (boxed) {
        Buf c;
        buf_init(&c);
        emit_expr(g, cond, &c);
        buf_printf(dst, "hp_val_to_bool(hv(%s))", buf_take(&c));
        free(c.data);
        return;
    }
    emit_expr(g, cond, dst);
}

/* emit an expression into a temporary heap buffer (caller frees) */
static const char *emit_expr_str(Codegen *g, Expr *e) {
    Buf b;
    buf_init(&b);
    emit_expr(g, e, &b);
    return buf_take(&b);
}

static AstFn *class_find_ctor(AstClass *c);   /* defined below */
static void emit_to_type(Codegen *g, Expr *val, const Type *want, Buf *dst);

/* Pass one argument to a parameter of known type. An hval parameter (untyped
 * or `mixed`) accepts anything, so scalars, arrays and closures are boxed;
 * for anything else the value is already the right C type. */
static void emit_arg(Codegen *g, Expr *arg, const Type *pt, Buf *dst) {
    if (!pt || pt->kind == TY_MIXED) to_hval(g, arg, dst);
    else emit_to_type(g, arg, pt, dst);
}

/* emit a parameter's default value at a call site (PHP default arguments) */
static void emit_param_default(Codegen *g, Param *pm, Buf *dst) {
    if (pm && pm->dflt) emit_arg(g, pm->dflt, pm->resolved, dst);
    else buf_puts(dst, "hp_null");
}

/* append default arguments for params the caller did not pass */
static void emit_missing_defaults(Codegen *g, AstFn *fn, size_t nargs, Buf *dst) {
    for (size_t i = nargs; i < fn->params.len; i++) {
        Param *pm = fn->params.items[i];
        if (!pm->dflt) break; /* sema already rejected this */
        buf_puts(dst, ", ");
        emit_param_default(g, pm, dst);
    }
}

/* ---------------- by-reference arguments ----------------
 *
 * A by-ref parameter compiles to a pointer to the parameter's C type, so the
 * caller has to hand it the address of a slot of exactly that type. The
 * caller's variable may live in one of four shapes:
 *
 *   plain local     int64_t v, hstr* v ... -> &v
 *   program global  the file-scope slot    -> &v
 *   closure box     hval *v, value (*v)    -> the box pointer itself for a
 *                                            mixed parameter, the address of
 *                                            the matching union member for a
 *                                            typed one
 *   by-ref param    T *v, value (*v)       -> v (already such a pointer)
 *
 * The boxed shapes hold an hval, so a typed parameter gets the address of the
 * union member carrying its type - and the box is coerced to that type first,
 * which also fixes the tag. Without the coercion a counter a closure captured
 * by reference (`use (&$n)`) could not be passed to `bump(int &$x)` at all,
 * and a box holding null would hand out an int64_t that still reads as null.
 */
static void emit_byref_arg(Codegen *g, Expr *arg, Param *pm, Buf *dst) {
    if (arg->kind != EX_VAR || !arg->u.var.sym) {
        fatal("%s:%zu:%zu: by-ref argument must be a variable",
              arg->tok.file ? arg->tok.file : "?", arg->tok.line, arg->tok.col);
        return;
    }
    VarSym *v = (VarSym *)arg->u.var.sym;
    const char *vname = var_name(v);
    const Type *pt = pm ? pm->resolved : NULL;
    const char *want = ctype_of(pt);             /* "hval" when mixed/untyped */
    const char *have = ctype_of(v->type);
    bool aligned = strcmp(want, have) == 0;
    bool is_ptr_slot = v->is_param_ref || v->captured_byref;
    if (aligned) {
        if (is_ptr_slot)
            buf_puts(dst, vname);               /* the pointer itself aliases */
        else
            buf_printf(dst, "&%s", vname);
        return;
    }
    /* the only other aliasable shape is an hval slot (a closure's use(&$x)
     * box, a `global $x` file-scope slot, or an untyped &$x parameter) */
    if (strcmp(have, "hval") != 0) {
        fatal("%s:%zu:%zu: cannot pass $%s by reference: %s is not an %s slot",
              arg->tok.file ? arg->tok.file : "?", arg->tok.line, arg->tok.col,
              v->name ? v->name : "?", have, want);
        return;
    }
    const char *L = v->captured_byref || v->is_param_ref
                        ? fmt("(*%s)", vname)
                        : fmt("%s", vname);
    switch (pt ? pt->kind : TY_MIXED) {
    case TY_INT: case TY_I8: case TY_I16: case TY_I32: case TY_I64: case TY_ENUM:
        buf_printf(dst, "((%s) = hp_of_int(hp_val_to_int(%s)), &(%s).u.i)", L, L, L);
        break;
    case TY_FLOAT: case TY_F32: case TY_F64:
        buf_printf(dst, "((%s) = hp_of_float(hp_val_to_float(%s)), &(%s).u.f)", L, L, L);
        break;
    case TY_BOOL:
        buf_printf(dst, "((%s) = hp_of_bool(hp_val_to_bool(%s)), &(%s).u.b)", L, L, L);
        break;
    case TY_STRING:
        buf_printf(dst, "((%s) = hp_of_str(hp_val_to_str(%s)), &(%s).u.s)", L, L, L);
        break;
    case TY_ARRAY: case TY_VEC: case TY_MAP: case TY_SET:
        buf_printf(dst, "((%s) = hp_of_arr(hp_val_to_arr(%s)), &(%s).u.a)", L, L, L);
        break;
    case TY_FN:
        buf_printf(dst, "((%s) = hp_of_clo((%s).u.c), &(%s).u.c)", L, L, L);
        break;
    case TY_CLASS: case TY_STRUCT: case TY_OWN: case TY_RC:
    case TY_INTERFACE: case TY_PTR:
        buf_printf(dst, "((%s) = hp_of_ptr((%s).u.p), (%s *)&(%s).u.p)",
                   L, L, ctype_of(pt), L);
        break;
    default:
        buf_printf(dst, "&%s", L);              /* mixed slot aliases directly */
        break;
    }
}

static void emit_call(Codegen *g, Expr *e, Buf *dst) {
    if (e->builtin) {
        emit_builtin_call(g, e->builtin, e->u.call.args, e->type, dst);
        return;
    }
    AstFn *fn = e->u.call.target;
    if (fn) {
        buf_printf(dst, "%s(", mangle_fn(fn->name));
        for (size_t i = 0; i < e->u.call.args.len; i++) {
            if (i) buf_puts(dst, ", ");            Expr *arg = e->u.call.args.items[i];
            const Type *at = arg->type;
            Param *pm = (i < fn->params.len) ? fn->params.items[i] : NULL;
            if (pm && pm->by_ref) {
                /* PHP by-ref call: pass a pointer to the caller's slot so the
                 * callee's writes reach it (see emit_byref_arg) */
                emit_byref_arg(g, arg, pm, dst);
                continue;
            }
            if (pm && at && (at->kind == TY_ARRAY || at->kind == TY_VEC ||
                             at->kind == TY_MAP || at->kind == TY_SET) &&
                pm->resolved && pm->resolved->kind != TY_MIXED) {
                /* COW: clone array-typed args into value-param slots. A
                 * by-ref capture box emits an hval, so it has to be unboxed
                 * before the clone sees it. */
                const char *as = emit_expr_str(g, arg);
                if (emits_hval_lvalue(arg))
                    buf_printf(dst, "hp_arr_clone(hp_val_to_arr(%s))", as);
                else
                    buf_printf(dst, "hp_arr_clone(%s)", as);
                free((void *)as);
            } else {
                /* converts boxed/mixed args into the param's type and boxes
                 * into hval params — PHP runtime conversions */
                emit_arg(g, arg, pm ? pm->resolved : NULL, dst);
            }
        }
        emit_missing_defaults(g, fn, e->u.call.args.len, dst);
        buf_puts(dst, ")");
        return;
    }
    /* first-class closure call: (hclosure*, int nargs, const hval *args) */
    Buf f;
    buf_init(&f);
    emit_expr(g, e->u.call.fn, &f);
    const Type *ct = e->u.call.fn->type;
    bool dynamic_callee = !ct || ct->kind == TY_MIXED;
    if (dynamic_callee) {
        /* hval callee (property / map entry / untyped param): hp_call_value
         * unwraps it and throws "not callable" if it isn't a closure */
        buf_printf(dst, "hp_call_value(hv(%s), %zu, (const hval[]){", buf_take(&f),
                   e->u.call.args.len);
    } else {
        buf_printf(dst, "hp_closure_call(%s, %zu, (const hval[]){", buf_take(&f),
                   e->u.call.args.len);
    }
    for (size_t i = 0; i < e->u.call.args.len; i++) {
        if (i) buf_puts(dst, ", ");
        to_hval(g, e->u.call.args.items[i], dst);
    }
    buf_puts(dst, "})");
    project_hval(dst, e->type);
    free(f.data);
}

static void emit_method(Codegen *g, Expr *e, Buf *dst) {
    if (e->builtin) {
        PtrVec args = {0};
        ptrvec_push(&args, e->u.method.obj);
        for (size_t i = 0; i < e->u.method.args.len; i++)
            ptrvec_push(&args, e->u.method.args.items[i]);
        emit_builtin_call(g, e->builtin, args, e->type, dst);
        return;
    }
    AstFn *m = e->u.method.target;
    if (m && m->cls) {
        Buf obj;
        buf_init(&obj);
        emit_expr(g, e->u.method.obj, &obj);
        const char *objcode = buf_take(&obj);
        const Type *ot = e->u.method.obj->type;
        /* virtual dispatch when overridden by some derived class: the shim
         * switches on the receiver's runtime class id (PHP override rules) */
        if (!m->is_static && m->name != intern("__construct") &&
            method_overridden(g, m->cls, m)) {
            const char *decl = mangle_method(m->cls, m->name);
            buf_printf(dst, "%s_virt((struct %s*)(%s)", decl, m->cls->name, objcode);
            for (size_t i = 0; i < e->u.method.args.len; i++) {
                buf_puts(dst, ", ");
                Param *pm = (i < m->params.len) ? m->params.items[i] : NULL;
                if (pm && pm->by_ref)
                    emit_byref_arg(g, (Expr *)e->u.method.args.items[i], pm, dst);
                else
                    emit_arg(g, e->u.method.args.items[i], pm ? pm->resolved : NULL, dst);
            }
            emit_missing_defaults(g, m, e->u.method.args.len, dst);
            buf_puts(dst, ")");
            free((void *)objcode);
            return;
        }
        /* upcast derived pointers to the declaring class (base is embedded
         * as the first member, so a plain struct pointer conversion works) */
        const char *decl = mangle_method(m->cls, m->name);
        /* the receiver's static type may be a derived class while the method
         * is defined on a base (or vice versa with own<T>): cast to the
         * declaring struct unless the types already match exactly */
        bool ptr_mismatch = false;
        const Type *nom = NULL;                 /* named object type of receiver */
        if (ot) {
            if ((ot->kind == TY_OWN || ot->kind == TY_RC) && ot->elem) nom = ot->elem;
            else if (ot->kind == TY_CLASS || ot->kind == TY_STRUCT) nom = ot;
        }
        if (nom && nom->kind == TY_CLASS && nom->name != intern(m->cls->name))
            ptr_mismatch = true;
        if (ptr_mismatch) {
            buf_printf(dst, "%s((struct %s*)(%s)", decl, m->cls->name, objcode);
        } else {
            buf_printf(dst, "%s(%s", decl, objcode);
        }
        for (size_t i = 0; i < e->u.method.args.len; i++) {
            buf_puts(dst, ", ");
            Param *pm = (i < m->params.len) ? m->params.items[i] : NULL;
            if (pm && pm->by_ref)
                emit_byref_arg(g, (Expr *)e->u.method.args.items[i], pm, dst);
            else
                emit_arg(g, e->u.method.args.items[i], pm ? pm->resolved : NULL, dst);
        }
        emit_missing_defaults(g, m, e->u.method.args.len, dst);
        buf_puts(dst, ")");
        free((void *)objcode);
        return;
    }
    if (e->u.method.sf) {
        /* a property holding a callable: $this->onMessage($client, $msg).
         * hp_call_value unwraps the hval/hclosure and throws a catchable
         * error when the value isn't callable. */
        StructField *sf = e->u.method.sf;
        Buf obj;
        buf_init(&obj);
        emit_expr(g, e->u.method.obj, &obj);
        buf_printf(dst, "hp_call_value(hv((%s)->%s), %zu, (const hval[]){",
                   buf_take(&obj), sf->name, e->u.method.args.len);
        for (size_t i = 0; i < e->u.method.args.len; i++) {
            if (i) buf_puts(dst, ", ");
            to_hval(g, e->u.method.args.items[i], dst);
        }
        buf_puts(dst, "})");
        project_hval(dst, e->type);
        free(obj.data);
        return;
    }
    buf_puts(dst, "hp_undefined_method()");
}
static void emit_static(Codegen *g, Expr *e, Buf *dst) {
    if (e->builtin) {
        emit_builtin_call(g, e->builtin, e->u.staticcall.args, e->type, dst);
        return;
    }
    AstFn *m = e->u.staticcall.target;
    if (m) {
        if (m->cls)
            buf_printf(dst, "%s(", mangle_method(m->cls, m->name));
        else
            buf_printf(dst, "%s(", mangle_fn(m->name));
        for (size_t i = 0; i < e->u.staticcall.args.len; i++) {
            if (i) buf_puts(dst, ", ");
            Param *pm = (i < m->params.len) ? m->params.items[i] : NULL;
            if (pm && pm->by_ref)
                emit_byref_arg(g, (Expr *)e->u.staticcall.args.items[i], pm, dst);
            else
                emit_arg(g, e->u.staticcall.args.items[i], pm ? pm->resolved : NULL, dst);
        }
        if (m) emit_missing_defaults(g, m, e->u.staticcall.args.len, dst);
        buf_puts(dst, ")");
        return;
    }
    buf_puts(dst, "hp_undefined_method()");
}

static void emit_field(Codegen *g, Expr *e, Buf *dst) {
    if (e->u.field.is_static && e->u.field.obj->kind == EX_VAR &&
        e->u.field.case_index >= 0) {
        buf_printf(dst, "(int64_t)%d", e->u.field.case_index);
        return;
    }
    StructField *sf = e->u.field.sf;
    if (sf) {
        Buf obj;
        buf_init(&obj);
        emit_expr(g, e->u.field.obj, &obj);
        /* PHP inheritance: fields live in the *defining* class. The base is
         * embedded as the first member, so walk up to the defining class. */
        if (sf->cls && e->u.field.vcls && e->u.field.vcls != sf->cls) {
            int depth = 0;
            for (AstClass *c = e->u.field.vcls; c && c != sf->cls; c = c->base)
                depth++;
            if (depth > 0)
                buf_printf(dst, "(&(%s)->__base)->%s", buf_take(&obj), sf->name);
            else
                buf_printf(dst, "(%s)->%s", buf_take(&obj), sf->name);
        } else {
            buf_printf(dst, "(%s)->%s", buf_take(&obj), sf->name);
        }
        free(obj.data);
        return;
    }
    buf_puts(dst, "hp_undefined_field()");
    (void)g;
}

static void emit_index(Codegen *g, Expr *e, Buf *dst) {
    Buf o, ix, out;
    buf_init(&o); buf_init(&ix); buf_init(&out);
    emit_expr(g, e->u.index.obj, &o);
    if (e->u.index.idx) emit_expr(g, e->u.index.idx, &ix);
    else buf_puts(&ix, "(int64_t)0");
    const Type *ot = e->u.index.obj->type;
    const Type *it = e->u.index.idx ? e->u.index.idx->type : NULL;
    if (ot && ot->kind == TY_STRING) {
        /* PHP "char at": yields a 1-char string as an hval; the projection
         * below unboxes it when the consumer wants hstr*. */
        buf_printf(&out, "hp_of_str(hp_str_char_at(%s, %s))", buf_take(&o), buf_take(&ix));
    }
    else if ((ot && ot->kind == TY_MIXED) || (it && it->kind == TY_MIXED))
        /* container or index is mixed (PHP-style dynamic access):
         * route through the generic runtime helper. */
        buf_printf(&out, "hp_arr_get_v(hv(%s), hv(%s))", buf_take(&o), buf_take(&ix));
    else
        buf_printf(&out, "hp_arr_get(%s, hv(%s))", buf_take(&o), buf_take(&ix));
    /* Project into OUR buffer, never into the caller's.
     *
     * project_hval() REWRITES the buffer it is handed: for a class-typed
     * element it takes the whole contents and wraps them in a cast. A caller
     * that shares its output buffer has already written into it by the time
     * this runs - emitting `f($obj->kids[$i])` has put `hpu_f(` there - so the
     * cast landed around the CALL:
     *     ((struct N *)((hpu_f(hp_arr_get(...))).u.p))
     * and the argument stayed an unboxed hval, which the C compiler rejected.
     * Building the fragment in a private buffer keeps the projection inside
     * the expression it belongs to. */
    project_hval(&out, e->type);
    {
        char *code = buf_take(&out);
        buf_puts(dst, code);
        free(code);
    }
    free(o.data); free(ix.data);
}
static void emit_array_lit(Codegen *g, Expr *e, Buf *dst) {
    if (e->u.map.vals.len) {
        size_t n = e->u.map.vals.len * 2;
        buf_printf(dst, "hp_map_of(%zu, (const hval[]){", n);
        for (size_t i = 0; i < e->u.map.vals.len; i++) {
            if (i) buf_puts(dst, ", ");
            to_hval(g, e->u.map.keys.items[i], dst);
            buf_puts(dst, ", ");
            to_hval(g, e->u.map.vals.items[i], dst);
        }
        buf_puts(dst, "})");
        return;
    }
    buf_printf(dst, "hp_arr_of(%zu, (const hval[]){", e->u.arr.elems.len);
    for (size_t i = 0; i < e->u.arr.elems.len; i++) {
        if (i) buf_puts(dst, ", ");
        to_hval(g, e->u.arr.elems.items[i], dst);
    }
    buf_puts(dst, "})");
}

static void emit_match_expr(Codegen *g, Expr *e, Buf *dst) {
    Buf sub;
    buf_init(&sub);
    emit_expr(g, e->u.matchexpr.subject, &sub);
    const char *subj = buf_take(&sub);
    buf_puts(dst, "(");
    for (size_t i = 0; i < e->u.matchexpr.cases.len; i++) {
        MatchCase *mc = e->u.matchexpr.cases.items[i];

        /* An arm matches through two kinds of pattern.
         *
         * A value pattern is compared with the subject by === (hp_match_any),
         * and a type test (`$x is T`) is a condition in its own right: it
         * evaluates to the bool the checker already narrowed on, so it is
         * used as it stands instead of being compared with the subject. */
        Buf pats;
        buf_init(&pats);
        size_t npats = 0;
        for (size_t k = 0; k < mc->patterns.len; k++) {
            Expr *pat = mc->patterns.items[k];
            if (pat->kind == EX_IS) continue;
            if (npats) buf_puts(&pats, ", ");
            to_hval(g, pat, &pats);
            npats++;
        }

        Buf cond;
        buf_init(&cond);
        if (npats) {
            char *pv = buf_take(&pats);
            buf_printf(&cond, "hp_val_to_bool(hp_match_any(hv(%s), (hval[]){%s}, %zu))",
                       subj, pv, npats);
            free(pv);
        }
        for (size_t k = 0; k < mc->patterns.len; k++) {
            Expr *pat = mc->patterns.items[k];
            if (pat->kind != EX_IS) continue;
            Buf is;
            buf_init(&is);
            emit_expr(g, pat, &is);
            char *iv = buf_take(&is);
            if (cond.len) buf_puts(&cond, " || ");
            /* an `is` test already emits a C condition, not a value */
            buf_printf(&cond, "(%s)", iv);
            free(iv);
        }
        if (!cond.len) buf_puts(&cond, "0");   /* unreachable: sema rejects it */

        Buf body;
        buf_init(&body);
        emit_expr(g, mc->body, &body);
        char *cv = buf_take(&cond);
        buf_puts(dst, cv);
        free(cv);
        buf_puts(dst, " ? (");
        char *bv = buf_take(&body);
        buf_puts(dst, bv);
        free(bv);
        buf_puts(dst, ") : ");
        free(pats.data);
    }
    if (e->u.matchexpr.dflt) {
        emit_expr(g, e->u.matchexpr.dflt, dst);
    } else {
        buf_puts(dst, "hp_match_no_default()");
    }
    buf_puts(dst, ")");
    free((void *)subj);
}

/* ---------------- closures ---------------- */
static void emit_stmt(Codegen *g, Stmt *s);
static void emit_block(Codegen *g, PtrVec stmts);
static const char *zero_init_of(const Type *t);
static const char *zero_init_decl_of(const Type *t);

static const char *closure_c_name(AstFn *fn) {
    return fmt("closure_%zu", (size_t)((uintptr_t)fn) & 0xffffff);
}

/* Build an initializer list for the env struct from the capture list. */
static void emit_env_init(Codegen *g, AstFn *fn, const char *cname, Buf *dst) {
    buf_printf(dst, "%s_env _env = {", cname);
    for (size_t i = 0; i < fn->captures.len; i++) {
        if (i) buf_puts(dst, ", ");
        VarSym *v = fn->captures.items[i];
        const Type *t = v->type;
        /* captures are stored as hval; lift scalars into boxed hvals */
        switch (t ? t->kind : TY_MIXED) {
        case TY_INT: case TY_I8: case TY_I16: case TY_I32: case TY_I64:
            buf_printf(dst, "hp_of_int(%s)", var_name(v));
            break;
        case TY_FLOAT: case TY_F32: case TY_F64:
            buf_printf(dst, "hp_of_float(%s)", var_name(v));
            break;
        case TY_BOOL:
            buf_printf(dst, "hp_of_bool(%s)", var_name(v));
            break;
        case TY_STRING:
            buf_printf(dst, "hp_of_str(%s)", var_name(v));
            break;
        case TY_ARRAY: case TY_VEC: case TY_MAP: case TY_SET:
            buf_printf(dst, "hp_of_arr(%s)", var_name(v));
            break;
        default:
            buf_printf(dst, "hv(%s)", var_name(v));
            break;
        }
    }
    buf_puts(dst, "}");
    (void)g;
}

/* prototype pass: emit only the env typedef + closure_new prototype so
 * code earlier in the file can reference this closure (C needs both before
 * the call site). The definition comes later from emit_closure. */
static void emit_closure_prototype(Codegen *g, AstFn *fn) {
    const char *cname = closure_c_name(fn);
    if (!fn->proto_emitted) {
        line(g, "typedef struct {");
        g->depth++;
        for (size_t i = 0; i < fn->captures.len; i++) {
            VarSym *v = fn->captures.items[i];
            if (v->captured_byref)
                line(g, "hval *%s;", var_name(v));
            else
                line(g, "hval %s;", var_name(v));
        }
        if (fn->uses_this)
            line(g, "void *hp_this;");
        g->depth--;
        line(g, "} %s_env;", cname);
        fn->proto_emitted = true;
    }
    /* repeating a static prototype is legal C; the typedef is not */
    line(g, "static hclosure *%s_closure_new(%s_env _src);", cname, cname);
    line(g, "");
}

static void emit_closure(Codegen *g, AstFn *fn) {
    const char *cname = closure_c_name(fn);
    /* env struct: one hval per capture; optional $this pointer.
     * Skipped when a prototype pass already emitted the typedef. */
    if (!fn->proto_emitted) {
        line(g, "typedef struct {");
        g->depth++;
        for (size_t i = 0; i < fn->captures.len; i++) {
            VarSym *v = fn->captures.items[i];
            if (v->captured_byref)
                line(g, "hval *%s;", var_name(v));
            else
                line(g, "hval %s;", var_name(v));
        }
        if (fn->uses_this)
            line(g, "void *hp_this;");
        g->depth--;
        line(g, "} %s_env;", cname);
        fn->proto_emitted = true;
    }

    /* impl: hval name_impl(void *op) — args come from the hval array */
    line(g, "static hval %s_impl(void *_op) {", cname);
    g->depth++;
    line(g, "hval *_args = (hval*)_op;");
    line(g, "%s_env *_env = (%s_env *)hp_closure_env(); (void)_env;", cname, cname);
    size_t ai = 0;
    for (size_t i = 0; i < fn->params.len; i++) {
        Param *pm = fn->params.items[i];
        VarSym *ps = (VarSym *)pm->sym;
        if (ps && ps->captured_byref) {
            /* by-ref param capture: param lives in a box so the closure's
             * env can alias it and writes escape to the caller */
            line(g, "hval *%s = hp_box_new();", var_name(ps));
            line(g, "*%s = _args[%zu];", var_name(ps), ai++);
            continue;
        }
        const Type *pt = pm->resolved;
        switch (pt ? pt->kind : TY_MIXED) {
        case TY_INT: case TY_I8: case TY_I16: case TY_I32: case TY_I64:
            line(g, "int64_t %s = _args[%zu].u.i;", var_name(pm->sym), ai++);
            break;
        case TY_FLOAT: case TY_F32: case TY_F64:
            line(g, "double %s = _args[%zu].u.f;", var_name(pm->sym), ai++);
            break;
        case TY_BOOL:
            line(g, "bool %s = _args[%zu].u.b;", var_name(pm->sym), ai++);
            break;
        case TY_STRING:
            line(g, "hstr* %s = _args[%zu].u.s;", var_name(pm->sym), ai++);
            break;
        case TY_ARRAY: case TY_VEC: case TY_MAP: case TY_SET:
            line(g, "harr* %s = _args[%zu].u.a;", var_name(pm->sym), ai++);
            break;
        default:
            line(g, "hval %s = _args[%zu];", var_name(pm->sym), ai++);
            break;
        }
    }
    for (size_t i = 0; i < fn->captures.len; i++) {
        VarSym *v = fn->captures.items[i];
        if (v->captured_byref) {
            /* by-ref capture: share the caller's heap box */
            line(g, "hval *%s = _env->%s;", var_name(v), var_name(v));
            continue;
        }
        const Type *t = v->type;
        switch (t ? t->kind : TY_MIXED) {
        case TY_INT: case TY_I8: case TY_I16: case TY_I32: case TY_I64:
            line(g, "int64_t %s = _env->%s.u.i;", var_name(v), var_name(v));
            break;
        case TY_FLOAT: case TY_F32: case TY_F64:
            line(g, "double %s = _env->%s.u.f;", var_name(v), var_name(v));
            break;
        case TY_BOOL:
            line(g, "bool %s = _env->%s.u.b;", var_name(v), var_name(v));
            break;
        case TY_STRING:
            line(g, "hstr* %s = _env->%s.u.s;", var_name(v), var_name(v));
            break;
        case TY_CLASS: case TY_INTERFACE: case TY_STRUCT:
            /* captured as a boxed value (property semantics); unbox to the
             * raw struct pointer for typed method calls and field access */
            line(g, "struct %s* %s = (struct %s*)(_env->%s.u.p);",
                 t->name, var_name(v), t->name, var_name(v));
            break;
        case TY_OWN: case TY_RC: case TY_REF: case TY_MUTREF: {
            /* own<T>/Rc<T> captures ride as hval too; project to elem type */
            const Type *el = t->elem;
            if (el && (el->kind == TY_CLASS || el->kind == TY_STRUCT))
                line(g, "struct %s* %s = (struct %s*)(_env->%s.u.p);",
                     el->name, var_name(v), el->name, var_name(v));
            else if (el && el->kind == TY_STRING)
                line(g, "hstr* %s = _env->%s.u.s;", var_name(v), var_name(v));
            else if (el && (el->kind == TY_ARRAY || el->kind == TY_VEC ||
                            el->kind == TY_MAP || el->kind == TY_SET))
                line(g, "harr* %s = _env->%s.u.a;", var_name(v), var_name(v));
            else if (el && type_is_integral(el->kind))
                line(g, "int64_t %s = _env->%s.u.i;", var_name(v), var_name(v));
            else if (el && type_is_numeric(el->kind))
                line(g, "double %s = _env->%s.u.f;", var_name(v), var_name(v));
            else if (el && el->kind == TY_BOOL)
                line(g, "bool %s = _env->%s.u.b;", var_name(v), var_name(v));
            else
                line(g, "hval %s = _env->%s;", var_name(v), var_name(v));
            break;
        }
        case TY_ARRAY: case TY_VEC: case TY_MAP: case TY_SET:
            line(g, "harr* %s = _env->%s.u.a;", var_name(v), var_name(v));
            break;
        case TY_FN:
            /* closure-typed captures: stored boxed as hval, loaded as the
             * raw hclosure* so first-class calls use it directly */
            line(g, "hclosure* %s = (hclosure*)_env->%s.u.c;", var_name(v), var_name(v));
            break;
        default:
            line(g, "hval %s = _env->%s;", var_name(v), var_name(v));
            break;
        }
    }
    if (fn->uses_this) {
        const char *self_cls = (fn->owner_cls) ? fn->owner_cls->name
                             : (fn->cls ? fn->cls->name : NULL);
        if (self_cls)
            line(g, "struct %s *self = (struct %s*)_env->hp_this;", self_cls, self_cls);
        else
            line(g, "struct hp_dummy_self *self = (struct hp_dummy_self*)_env->hp_this;");
    }
    g->cur_fn = fn;
    g->in_closure = true;
    /* hoist PHP-style auto variables to the top of the impl, like emit_fn
     * does for regular functions (sema declares them at assignment site) */
    {
        PtrVec syms = {0};
        for (size_t i = 0; i < fn->body.len; i++)
            collect_syms_stmt(&syms, fn->body.items[i]);
        for (size_t i = 0; i < syms.len; i++) {
            VarSym *v = syms.items[i];
            if (!v->is_auto || v->is_param) continue;
            if (is_global_alias(v)) continue;   /* file-scope storage */
            if (v->is_program_global) continue; /* file-scope storage */
            bool seen = false;
            for (size_t j = 0; j < i; j++)
                if (syms.items[j] == v) { seen = true; break; }
            if (seen) continue;
            /* captured vars already come from the env */
            bool captured = false;
            for (size_t j = 0; j < fn->captures.len; j++)
                if (fn->captures.items[j] == v) { captured = true; break; }
            if (captured) continue;
            if (v->captured_byref) {
                /* local captured by-ref by an inner closure: heap box shared
                 * with the inner env; all frame accesses go through (*v). */
                line(g, "hval *%s = hp_box_new();", var_name(v));
                continue;
            }
            line(g, "%s %s = %s;", ctype_of(v->type),
                 var_name(v), zero_init_decl_of(v->type));
        }
        free(syms.items);
    }
    emit_block(g, fn->body);
    g->in_closure = false;
    /* fallback returns */
    const Type *ret = fn->ftype ? fn->ftype->fn.ret : ty_void;
    if (!ret || ret->kind == TY_VOID || ret->kind == TY_MIXED)
        line(g, "return hp_null;");
    else if (type_is_integral(ret->kind))
        line(g, "return hp_of_int(0);");
    else if (type_is_numeric(ret->kind))
        line(g, "return hp_of_float(0);");
    else if (ret->kind == TY_BOOL)
        line(g, "return hp_of_bool(false);");
    else if (ret->kind == TY_STRING)
        line(g, "return hp_of_str(hp_null_str());");
    else if (ret->kind == TY_ARRAY || ret->kind == TY_VEC ||
             ret->kind == TY_MAP || ret->kind == TY_SET)
        line(g, "return hp_of_arr(hp_null_arr());");
    else
        line(g, "return hp_null;");
    g->depth--;
    g->cur_fn = NULL;
    line(g, "}");
    line(g, "");

    /* constructor used at the EX_CLOSURE site: pack the env here */
    line(g, "static hclosure *%s_closure_new(%s_env _src) {", cname, cname);
    g->depth++;
    line(g, "return hpclosure_new(&_src, sizeof(%s_env), (void*)%s_impl);", cname, cname);
    g->depth--;
    line(g, "}");
    line(g, "");
    (void)g;
}

static void emit_assign(Codegen *g, Expr *e, Buf *dst);

/* PHP list destructuring: [$a, , $c] = expr;  /  ["k" => $v] = expr;
 * The source is evaluated once into a hidden hval temp, each pattern slot
 * becomes one assignment (array values are cloned: PHP value semantics). */
static void emit_list_destructure(Codegen *g, Expr *e) {
    Expr *pat = e->u.assign.target;
    bool keyed = pat->u.map.vals.len > 0;
    Buf src;
    buf_init(&src);
    emit_expr(g, e->u.assign.value, &src);
    const char *sv = buf_take(&src);
    const Type *st = e->u.assign.value->type;
    bool sarr = st && (st->kind == TY_ARRAY || st->kind == TY_VEC);
    line(g, "{");
    g->depth++;
    if (sarr) line(g, "hval _src = hp_of_arr(%s);", sv);
    else if (st) line(g, "hval _src = hv(%s);", sv);
    else line(g, "hval _src = %s;", sv);
    free((void *)sv);
    (void)keyed;   /* slots below look keys up directly via hp_arr_get */
    size_t n = keyed ? pat->u.map.vals.len : pat->u.arr.elems.len;
    for (size_t i = 0; i < n; i++) {
        Expr *tgt = keyed ? (Expr *)pat->u.map.vals.items[i]
                          : (Expr *)pat->u.arr.elems.items[i];
        if (!tgt) continue;   /* [$a, , $c] skip slot */
        char tmp[24];
        snprintf(tmp, sizeof tmp, "_v%zu", i);
        if (keyed) {
            Expr *k = (Expr *)pat->u.map.keys.items[i];
            Buf kb;
            buf_init(&kb);
            to_hval(g, k, &kb);
            line(g, "hval %s = hp_arr_get(_src.u.a, %s);", tmp, buf_take(&kb));
        } else {
            line(g, "hval %s = ((size_t)%zu < hp_arr_len(_src.u.a)) ? _src.u.a->vals[%zu] : hp_null;",
                 tmp, i, i);
        }
        if (tgt->kind != EX_VAR)
            fatal("%s:%zu:%zu: unsupported destructuring target (only $var)",
                  tgt->tok.file ? tgt->tok.file : "?", tgt->tok.line, tgt->tok.col);
        const char *name = var_name(tgt->u.var.sym);
        VarSym *sym = (VarSym *)tgt->u.var.sym;
        bool box = sym && (sym->captured_byref || sym->is_program_global);
        if (sym && sym->captured_byref) name = fmt("(*%s)", name);
        const Type *tt = sym ? sym->type : NULL;
        if (box)
            line(g, "%s = %s;", name, tmp);
        else if (tt && (tt->kind == TY_ARRAY || tt->kind == TY_VEC ||
                        tt->kind == TY_MAP || tt->kind == TY_SET))
            line(g, "%s = (%s.tag == HV_ARR ? hp_arr_clone(%s.u.a) : NULL);", name, tmp, tmp);
        else if (tt && tt->kind == TY_STRING)
            line(g, "%s = hp_val_to_str(%s);", name, tmp);
        else if (tt && (tt->kind == TY_FLOAT || tt->kind == TY_F32 || tt->kind == TY_F64))
            line(g, "%s = hp_val_to_float(%s);", name, tmp);
        else if (tt && (type_is_integral(tt->kind) || tt->kind == TY_BOOL))
            line(g, "%s = hp_val_to_int(%s);", name, tmp);
        else
            line(g, "%s = %s;", name, tmp);
    }
    g->depth--;
    line(g, "}");
}

static void emit_assign(Codegen *g, Expr *e, Buf *dst) {
    Expr *tgt = e->u.assign.target;
    TokKind op = e->u.assign.op.kind;
    if (tgt->kind == EX_VAR) {
        const char *name = var_name(tgt->u.var.sym);
        VarSym *tvs = (VarSym *)tgt->u.var.sym;
        bool is_refparam = tvs && tvs->is_param_ref;
        /* boxed hval slots (closure use(&$x) captures, global aliases);
         * by-ref params are typed pointers, not hval boxes */
        bool tgt_is_box = tvs && !is_refparam &&
            (tvs->captured_byref || tvs->is_program_global);
        if (tvs && (tvs->captured_byref || is_refparam))
            name = fmt("(*%s)", name);   /* write through the heap box / ref param */
        if (op == T_QQASSIGN) {
            /* PHP ??= : assign only when the target was null; the value
             * expression is only evaluated in the null branch */
            Buf v;
            buf_init(&v);
            emit_expr(g, e->u.assign.value, &v);
            const char *vs = buf_take(&v);
            const Type *vt2 = e->u.assign.value->type;
            const Type *tt2 = tgt->u.var.sym ? ((VarSym *)tgt->u.var.sym)->type : NULL;
            bool arrv = vt2 && (vt2->kind == TY_ARRAY || vt2->kind == TY_VEC);
            bool strv = !arrv && tt2 && tt2->kind == TY_STRING &&
                        (!vt2 || vt2->kind == TY_STRING || vt2->kind == TY_MIXED);
            if (tgt_is_box)
                buf_printf(dst, "((%s.tag == HV_NULL) ? (%s = hv(%s)) : (%s))", name, name, vs, name);
            else if (strv)
                /* hstr* slots use hp_null_str() as their null sentinel */
                buf_printf(dst, "((%s == hp_null_str()) ? (%s = hp_val_to_str(hv(%s))) : (%s))", name, name, vs, name);
            else if (arrv)
                buf_printf(dst, "((%s == NULL) ? (%s = %s) : (%s))", name, name, vs, name);
            else
                buf_printf(dst, "((%s.tag == HV_NULL) ? (%s = hv(%s)) : (%s))", name, name, vs, name);
            free((void *)vs);
            return;
        }
        if (op == T_ASSIGN) {
            if (!e->u.assign.value) {
                /* typed declaration without initializer: "$x: int;" */
                const Type *zt = tgt->u.var.sym ? ((VarSym *)tgt->u.var.sym)->type : NULL;
                buf_printf(dst, "(%s = %s)", name, zero_init_decl_of(zt));
                return;
            }
            Buf v;
            buf_init(&v);
            emit_expr(g, e->u.assign.value, &v);
            const Type *vt = e->u.assign.value->type;
            bool is_arr_v = vt && (vt->kind == TY_ARRAY || vt->kind == TY_VEC ||
                                   vt->kind == TY_MAP || vt->kind == TY_SET);
            /* An array literal already produces a fresh array that nothing
             * else can alias, so cloning it again is a wasted allocation
             * (and a leak: nothing frees the intermediate). */
            bool fresh_arr = e->u.assign.value->kind == EX_ARRAY_LIT ||
                             e->u.assign.value->kind == EX_MAP_LIT ||
                             e->u.assign.value->kind == EX_TUPLE_LIT;
            if (tgt_is_box && is_arr_v) {
                /* the slot is an hval but the value is a bare harr*: box it */
                if (fresh_arr)
                    buf_printf(dst, "(%s = hp_of_arr(%s))", name, buf_take(&v));
                else
                    buf_printf(dst, "(%s = hp_of_arr(hp_arr_clone(%s)))",
                               name, buf_take(&v));
            }
            else if (!tgt_is_box && is_arr_v) {
                if (fresh_arr)
                    buf_printf(dst, "(%s = %s)", name, buf_take(&v));
                else
                    buf_printf(dst, "(%s = hp_arr_clone(%s))", name, buf_take(&v));
            }
            else {
                free(v.data);
                buf_init(&v);
                const Type *tt = tgt->u.var.sym ? ((VarSym *)tgt->u.var.sym)->type : NULL;
                /* The C slot is an hval whenever the target is a box - a
                 * `use (&$x)` capture or file-scope storage - and that is
                 * true of the *symbol*, not of the type sema inferred for
                 * it. `$pulse = ($pulse + 4) % 100;` inside a closure is the
                 * case that exposed it: the value is an int64_t, the slot is
                 * an hval, and the raw value cannot be assigned to it. Box
                 * it (to_hval) instead of projecting it to its own type. */
                if (tgt_is_box) to_hval(g, e->u.assign.value, &v);
                else emit_to_type(g, e->u.assign.value, tt, &v);
                buf_printf(dst, "(%s = %s)", name, buf_take(&v));
            }
            free(v.data);
        } else if (op == T_DOTASSIGN) {
            Buf v;
            buf_init(&v);
            emit_expr(g, e->u.assign.value, &v);
            const Type *dt = tgt->u.var.sym ? ((VarSym *)tgt->u.var.sym)->type : NULL;
            bool dboxed = tgt_is_box || !tgt->u.var.sym || !dt ||
                          dt->kind == TY_MIXED;
            if (dboxed) /* concat yields hstr*: box it for the hval slot */
                buf_printf(dst, "((%s) = hp_of_str(hp_str_append_v(hv(%s), hv(%s))))",
                           name, name, buf_take(&v));
            else
                buf_printf(dst, "(%s = hp_str_append_v(hv(%s), hv(%s)))", name, name, buf_take(&v));
            free(v.data);
        } else if (op == T_POWASSIGN) {
            Buf v;
            buf_init(&v);
            emit_expr(g, e->u.assign.value, &v);
            const Type *pt = tgt->u.var.sym ? ((VarSym *)tgt->u.var.sym)->type : NULL;
            bool pboxed = tgt_is_box;
            if (pboxed) /* hval box: pow in value space, hval flows back in */
                buf_printf(dst, "((%s) = hp_powv((%s), hv(%s)))",
                           name, name, buf_take(&v));
            else if (pt && (type_is_integral(pt->kind) || pt->kind == TY_BOOL))
                buf_printf(dst, "(%s = hp_val_to_int(hp_powv(hv(%s), hv(%s))))",
                           name, name, buf_take(&v));
            else if (pt && type_is_numeric(pt->kind))
                buf_printf(dst, "(%s = hp_val_to_float(hp_powv(hv(%s), hv(%s))))",
                           name, name, buf_take(&v));
            else
                buf_printf(dst, "(%s = hp_powv((%s), hv(%s)))",
                           name, name, buf_take(&v));
            free(v.data);
        } else {
            const char *c_op = "+=";
            switch (op) {
            case T_MINUSASSIGN: c_op = "-="; break;
            case T_STARASSIGN: c_op = "*="; break;
            case T_SLASHASSIGN: c_op = "/="; break;
            case T_PERCENTASSIGN: c_op = "%="; break;
            case T_SHLASSIGN: c_op = "<<="; break;
            case T_SHRASSIGN: c_op = ">>="; break;
            default: c_op = "+="; break;
            }
            Buf v;
            buf_init(&v);
            emit_expr(g, e->u.assign.value, &v);
            /* mixed RHS (e.g. hp_arr_get result) needs unboxing before a
             * typed C compound assignment: project hval -> scalar first */
            const Type *cvt = e->u.assign.value->type;
            const Type *tt2 = tgt->u.var.sym ? ((VarSym *)tgt->u.var.sym)->type : NULL;
            bool cboxed = tgt->u.var.sym &&
                          ((VarSym *)tgt->u.var.sym)->captured_byref;
            /* an untyped or mixed-typed local's C slot is an hval: run the
             * op in value space, exactly like a captured box */
            bool hvalslot = !tgt->u.var.sym || !tt2 || tt2->kind == TY_MIXED;
            if ((cboxed || hvalslot) && (op == T_PLUSASSIGN || op == T_MINUSASSIGN ||
                           op == T_STARASSIGN || op == T_SLASHASSIGN)) {
                /* hval box: apply the op in value space, store the hval back */
                const char *rop = op == T_MINUSASSIGN ? "hpbi_scalar_sub" :
                                  op == T_STARASSIGN  ? "hpbi_scalar_mul" :
                                  op == T_SLASHASSIGN ? "hp_divv" : "hp_add";
                buf_printf(dst, "((%s) = %s((%s), hv(%s)))",
                           name, rop, name, buf_take(&v));
            }
            else if (cboxed || hvalslot) {
                /* The remaining compound operators (%%, <<, >>, ...) have no
                 * value-space helper, so compute in integer space and box the
                 * result. Without this they were emitted as a plain C compound
                 * assignment on an hval - `(*v) %= 4` - which is not even
                 * valid C, let alone PHP. */
                const char *iop = op == T_PERCENTASSIGN ? "%" :
                                  op == T_SHLASSIGN ? "<<" :
                                  op == T_SHRASSIGN ? ">>" : "+";
                buf_printf(dst, "((%s) = hp_of_int(hp_val_to_int(%s) %s hp_val_to_int(hv(%s))))",
                           name, name, iop, buf_take(&v));
            }
            else if (cvt && cvt->kind == TY_MIXED && tt2 &&
                (type_is_integral(tt2->kind) || tt2->kind == TY_BOOL))
                buf_printf(dst, "(%s %s hp_val_to_int(%s))", name, c_op, buf_take(&v));
            else if (cvt && cvt->kind == TY_MIXED && tt2 && type_is_numeric(tt2->kind))
                buf_printf(dst, "(%s %s hp_val_to_float(%s))", name, c_op, buf_take(&v));
            else
                buf_printf(dst, "(%s %s %s)", name, c_op, buf_take(&v));
            free(v.data);
        }
        return;
    }
    if (tgt->kind == EX_INDEX) {
        Buf o, ix, v;
        buf_init(&o); buf_init(&ix); buf_init(&v);
        emit_expr(g, tgt->u.index.obj, &o);
        emit_expr(g, e->u.assign.value, &v);
        const char *os = buf_take(&o);
        const char *vs = buf_take(&v);
        TokKind aop = e->u.assign.op.kind;
        if (tgt->u.index.idx) {
            /* $a[$i] = v  /  $a[$i] += v */
            emit_expr(g, tgt->u.index.idx, &ix);
            const char *xs = buf_take(&ix);
            const Type *it = tgt->u.index.idx->type;
            const Type *ot = tgt->u.index.obj->type;
            bool dynamic = (ot && ot->kind == TY_MIXED) || (it && it->kind == TY_MIXED);
            if (aop == T_ASSIGN) {
                if (dynamic)
                    buf_printf(dst, "hp_arr_set_v(hv(%s), hv(%s), hv(%s))", os, xs, vs);
                else
                    buf_printf(dst, "hp_arr_set(%s, hv(%s), hv(%s))", os, xs, vs);
            } else {
                /* read-modify-write through the generic value path */
                const char *rt = aop == T_PLUSASSIGN ? "hp_add" :
                                 aop == T_MINUSASSIGN ? "hpbi_scalar_sub" :
                                 aop == T_STARASSIGN ? "hpbi_scalar_mul" : "hp_add";
                buf_printf(dst, "hp_arr_set_v(hv(%s), hv(%s), %s(hp_arr_get_v(hv(%s), hv(%s)), hv(%s)))",
                           os, xs, rt, os, xs, vs);
            }
            free((void *)xs);
        } else {
            /* $a[] = v  (PHP append) */
            const Type *pot = tgt->u.index.obj->type;
            if (pot && pot->kind == TY_MIXED)
                /* boxed container (by-ref capture / untyped slot): the
                 * container is an hval — push in value space, store back */
                buf_printf(dst, "((%s) = hp_arr_push_vv(%s, hv(%s)))", os, os, vs);
            else
                buf_printf(dst, "hp_arr_push_v(%s, hv(%s))", os, vs);
        }
        free((void *)os); free((void *)vs);
        free(ix.data); free(o.data); free(v.data);
        return;
    }
    if (tgt->kind == EX_FIELD) {
        StructField *sf = tgt->u.field.sf;
        Buf o, v;
        buf_init(&o); buf_init(&v);
        emit_expr(g, tgt->u.field.obj, &o);
        const char *os = buf_take(&o);
        /* PHP inheritance: the field may live in a base class; walk up the
         * embedded __base chain exactly like emit_field does for reads. */
        const char *lval;
        if (sf && sf->cls && tgt->u.field.vcls && tgt->u.field.vcls != sf->cls) {
            int depth = 0;
            for (AstClass *c = tgt->u.field.vcls; c && c != sf->cls; c = c->base)
                depth++;
            lval = depth > 0 ? fmt("(&(%s)->__base)->%s", os, sf->name)
                             : fmt("(%s)->%s", os, sf->name);
        } else {
            lval = fmt("(%s)->%s", os, sf ? sf->name : "hp_missing_field");
        }
        free((void *)os);
        if (op != T_ASSIGN) {
            /* `$this->x += 1` is read-modify-write on the field, exactly like
             * a plain variable: the previous value must participate. */
            const Type *ft = sf ? sf->type : NULL;
            bool fboxed = !ft || ft->kind == TY_MIXED;
            if (op == T_DOTASSIGN) {
                emit_expr(g, e->u.assign.value, &v);
                if (fboxed)
                    buf_printf(dst,
                        "((%s) = hp_of_str(hp_str_append_v(hv(%s), hv(%s))))",
                        lval, lval, buf_take(&v));
                else
                    buf_printf(dst, "(%s = hp_str_append_v(hv(%s), hv(%s)))",
                               lval, lval, buf_take(&v));
            } else if (op == T_POWASSIGN) {
                emit_expr(g, e->u.assign.value, &v);
                if (fboxed)
                    buf_printf(dst, "((%s) = hp_powv((%s), hv(%s)))",
                               lval, lval, buf_take(&v));
                else if (ft && type_is_integral(ft->kind))
                    buf_printf(dst, "(%s = hp_val_to_int(hp_powv(hv(%s), hv(%s))))",
                               lval, lval, buf_take(&v));
                else if (ft && type_is_numeric(ft->kind))
                    buf_printf(dst, "(%s = hp_val_to_float(hp_powv(hv(%s), hv(%s))))",
                               lval, lval, buf_take(&v));
                else
                    buf_printf(dst, "(%s = hp_powv((%s), hv(%s)))",
                               lval, lval, buf_take(&v));
            } else {
                const char *c_op = "+=";
                switch (op) {
                case T_MINUSASSIGN: c_op = "-="; break;
                case T_STARASSIGN: c_op = "*="; break;
                case T_SLASHASSIGN: c_op = "/="; break;
                case T_PERCENTASSIGN: c_op = "%="; break;
                case T_SHLASSIGN: c_op = "<<="; break;
                case T_SHRASSIGN: c_op = ">>="; break;
                default: c_op = "+="; break;
                }
                const char *rop = op == T_MINUSASSIGN ? "hpbi_scalar_sub" :
                                  op == T_STARASSIGN  ? "hpbi_scalar_mul" :
                                  op == T_SLASHASSIGN ? "hp_divv" : "hp_add";
                bool arith = op == T_PLUSASSIGN || op == T_MINUSASSIGN ||
                             op == T_STARASSIGN || op == T_SLASHASSIGN;
                const Type *cvt2 = e->u.assign.value->type;
                if (fboxed && arith) {
                    emit_expr(g, e->u.assign.value, &v);
                    buf_printf(dst, "((%s) = %s((%s), hv(%s)))",
                               lval, rop, lval, buf_take(&v));
                } else if (cvt2 && cvt2->kind == TY_MIXED && ft &&
                           (type_is_integral(ft->kind) || ft->kind == TY_BOOL)) {
                    emit_expr(g, e->u.assign.value, &v);
                    buf_printf(dst, "(%s %s hp_val_to_int(%s))",
                               lval, c_op, buf_take(&v));
                } else if (cvt2 && cvt2->kind == TY_MIXED && ft &&
                           type_is_numeric(ft->kind)) {
                    emit_expr(g, e->u.assign.value, &v);
                    buf_printf(dst, "(%s %s hp_val_to_float(%s))",
                               lval, c_op, buf_take(&v));
                } else {
                    if (sf && sf->type)
                        emit_to_type(g, e->u.assign.value, sf->type, &v);
                    else
                        emit_expr(g, e->u.assign.value, &v);
                    buf_printf(dst, "(%s %s %s)", lval, c_op, buf_take(&v));
                }
            }
            free((void *)lval); free(v.data);
            return;
        }
        if (sf && sf->type) {
            if (sf->type->kind == TY_MIXED)
                to_hval(g, e->u.assign.value, &v); /* dynamic slot: box */
            else
                emit_to_type(g, e->u.assign.value, sf->type, &v);
        }
        else emit_expr(g, e->u.assign.value, &v);
        buf_printf(dst, "(%s = %s)", lval, buf_take(&v));
        free((void *)lval); free(v.data);
        return;
    }
    buf_puts(dst, "(void)0");
}

static void emit_cast(Codegen *g, Expr *e, Buf *dst) {
    Buf o;
    buf_init(&o);
    emit_expr(g, e->u.cast.operand, &o);
    const char *os = buf_take(&o);
    const Type *to = e->u.cast.to;
    const Type *from = e->u.cast.operand->type;
    if (to->kind == TY_STRING && from && type_is_numeric(from->kind)) {
        buf_printf(dst, "hp_str_from_num(%s)", os);
    } else if (to->kind == TY_STRING && from && from->kind == TY_BOOL) {
        buf_printf(dst, "(%s ? hp_str_intern(\"true\") : hp_str_intern(\"false\"))", os);
    } else if (type_is_integral(to->kind) && from && from->kind == TY_STRING) {
        buf_printf(dst, "hp_str_to_int(%s)", os);
    } else if ((to->kind == TY_FLOAT || to->kind == TY_F32 || to->kind == TY_F64) &&
               from && from->kind == TY_STRING) {
        buf_printf(dst, "hp_str_to_float(%s)", os);
    } else if (type_is_integral(to->kind)) {
        buf_printf(dst, "((int64_t)(%s))", os);
    } else if (to->kind == TY_FLOAT || to->kind == TY_F32 || to->kind == TY_F64) {
        buf_printf(dst, "((double)(%s))", os);
    } else if (to->kind == TY_BOOL) {
        buf_printf(dst, "((bool)(%s))", os);
    } else {
        buf_printf(dst, "((%s)(%s))", ctype_of(to), os);
    }
    free((void *)os);
}

static void emit_expr(Codegen *g, Expr *e, Buf *dst) {
    switch (e->kind) {
    case EX_INT: buf_printf(dst, "(int64_t)%lld", e->u.i.ival); break;
    case EX_FLOAT: {
        char *s = fmt("%.17g", e->u.f.fval);
        buf_printf(dst, "(double)%s", s);
        free(s);
        break;
    }
    case EX_STR: emit_str_lit(e->u.str.s, dst); break;
    case EX_BOOL: buf_puts(dst, e->u.boolean.b ? "true" : "false"); break;
    case EX_NULL: buf_puts(dst, "hp_null"); break;
    case EX_TPL: emit_tpl(g, e, dst); break;
    case EX_VAR:
        if (e->u.var.name == s_this)
            buf_puts(dst, "self");
        else if (e->u.var.name && (strncmp(e->u.var.name, "PHP_", 4) == 0 ||
                                   strncmp(e->u.var.name, "JSON_", 5) == 0 ||
                                   strcmp(e->u.var.name, "M_PI") == 0 ||
                                   strcmp(e->u.var.name, "M_E") == 0)) {
            /* PHP_* predefined constants, resolved in sema */
            if (e->u.var.name == s_php_int_max) buf_puts(dst, "(int64_t)9223372036854775807LL");
            else if (e->u.var.name == s_php_int_min) buf_puts(dst, "(int64_t)(-9223372036854775807LL - 1)");
            else if (e->u.var.name == s_php_int_size) buf_puts(dst, "(int64_t)8");
            else if (e->u.var.name == s_php_int_digits) buf_puts(dst, "(int64_t)19");
            else if (e->u.var.name == s_php_float_epsilon) buf_puts(dst, "(double)2.220446049250313e-16");
            else if (e->u.var.name == s_php_euler) buf_puts(dst, "(double)2.718281828459045");
            else if (e->u.var.name == s_php_pi) buf_puts(dst, "(double)3.14159265358979323846");
            else if (e->u.var.name == s_m_pi) buf_puts(dst, "(double)3.14159265358979323846");
            else if (e->u.var.name == s_m_e) buf_puts(dst, "(double)2.718281828459045");
            else if (e->u.var.name == s_php_round_half_up) buf_puts(dst, "(int64_t)0");
            else if (e->u.var.name == s_php_round_half_down) buf_puts(dst, "(int64_t)1");
            else if (e->u.var.name == s_php_round_half_even) buf_puts(dst, "(int64_t)2");
            else if (e->u.var.name == s_php_round_half_odd) buf_puts(dst, "(int64_t)3");
            else if (e->u.var.name == s_php_os) buf_puts(dst, "hp_str_intern(\"Windows\")");
            else if (e->u.var.name == s_php_eol) buf_puts(dst, "hp_str_intern(\"\\r\\n\")");
            else if (e->u.var.name == s_php_version) buf_puts(dst, "hpbi_phpversion()");
            else if (e->u.var.name == s_php_sapi) buf_puts(dst, "hpbi_php_sapi_name()");
            else if (e->u.var.name == s_php_uname) buf_puts(dst, "hpbi_php_uname()");
            else if (e->u.var.name == s_php_bool_true) buf_puts(dst, "hp_of_bool(true)");
            else if (e->u.var.name == s_php_bool_false) buf_puts(dst, "hp_of_bool(false)");
            else if (e->u.var.name == s_php_null) buf_puts(dst, "hp_null");
            else if (e->u.var.name == s_json_pretty_print) buf_puts(dst, "(int64_t)1");
            else if (e->u.var.name == s_json_unescaped_slashes) buf_puts(dst, "(int64_t)2");
            else if (e->u.var.name == s_json_numeric_check) buf_puts(dst, "(int64_t)4");
            else if (e->u.var.name == s_json_force_object) buf_puts(dst, "(int64_t)8");
            else if (e->u.var.name == s_php_file_append) buf_puts(dst, "(int64_t)8");
            else if (e->u.var.name == s_php_file_ignore_new_lines) buf_puts(dst, "(int64_t)2");
            else if (e->u.var.name == s_php_file_skip_empty_lines) buf_puts(dst, "(int64_t)4");
            else if (e->u.var.name == s_php_file_use_include_path) buf_puts(dst, "(int64_t)1");
            else buf_puts(dst, "hp_null");
            break;
        }
        else if (e->u.var.is_global) {
            /* PHP superglobals */
            if (e->u.var.name == s_argc)
                buf_puts(dst, "hp_argc");
            else
                buf_puts(dst, "hp_argv");
        }        else {
            /* the slot the value lives in: a plain variable, a heap box for
             * a by-ref capture, or a by-ref parameter */
            const char *slot = var_name(e->u.var.sym);
            if (e->u.var.sym && ((VarSym *)e->u.var.sym)->captured_byref)
                slot = fmt("(*%s)", slot);
            else if (e->u.var.sym && ((VarSym *)e->u.var.sym)->is_param_ref)
                slot = fmt("(*%s)", slot);
            if (narrowed_read_needs_projection(e)) {
                /* the branch proved the value is there: read the payload out
                 * of the slot instead of the slot itself */
                Buf b;
                buf_init(&b);
                project_narrowed(&b, e->type, slot);
                buf_printf(dst, "%s", buf_take(&b));
                free(b.data);
            } else {
                buf_printf(dst, "%s", slot);
            }
        }
        break;
    case EX_INDEX: emit_index(g, e, dst); break;
    case EX_FIELD: emit_field(g, e, dst); break;
    case EX_CALL: emit_call(g, e, dst); break;
    case EX_METHOD: emit_method(g, e, dst); break;
    case EX_STATIC: emit_static(g, e, dst); break;
    case EX_NEW: {
        AstClass *c = e->u.newexpr.cls_res;
        if (!c) {
            /* builtin Exception: the thrown value is the message string */
            if (strcmp(e->u.newexpr.cls, "Exception") == 0) {
                if (e->u.newexpr.args.len >= 1) {
                    Buf m;
                    buf_init(&m);
                    to_hval(g, e->u.newexpr.args.items[0], &m);
                    buf_printf(dst, "hp_of_str(hp_val_to_str(%s))", buf_take(&m));
                    free(m.data);
                } else {
                    buf_puts(dst, "hp_of_str(hp_str_intern(\"\"))");
                }
            } else {
                buf_puts(dst, "hp_null");
            }
            break;
        }
        buf_printf(dst, "%s_new_args(\"%s\"", c->name, c->name);
        AstFn *ctor = class_find_ctor(c);
        for (size_t i = 0; i < e->u.newexpr.args.len; i++) {
            buf_puts(dst, ", ");
            Param *pm = (ctor && i < ctor->params.len) ? ctor->params.items[i] : NULL;
            const Type *pt = pm ? pm->resolved : NULL;
            if (pt && (pt->kind == TY_CLASS || pt->kind == TY_STRUCT))
                emit_expr(g, e->u.newexpr.args.items[i], dst);  /* raw struct ptr */
            else if (pt && (pt->kind == TY_OWN || pt->kind == TY_RC) && pt->elem &&
                     (pt->elem->kind == TY_CLASS || pt->elem->kind == TY_STRUCT))
                buf_printf(dst, "(struct %s*)%s", pt->elem->name,
                           emit_expr_str(g, e->u.newexpr.args.items[i]));
            else if (pm && (!pt || pt->kind == TY_MIXED))
                to_hval(g, e->u.newexpr.args.items[i], dst);
            else
                emit_expr(g, e->u.newexpr.args.items[i], dst);
        }
        if (ctor) emit_missing_defaults(g, ctor, e->u.newexpr.args.len, dst);
        buf_puts(dst, ")");
        break;
    }
    case EX_BIN: emit_binop(g, e, dst); break;
    case EX_UN: {
        Buf o;
        buf_init(&o);
        emit_expr(g, e->u.un.operand, &o);
        const char *os = buf_take(&o);
        switch (e->u.un.op.kind) {
        case T_NOT:
            /* PHP `!` accepts any value (truthiness): mixed operands go
             * through hp_val_to_bool first */
            if (e->u.un.operand->type &&
                (e->u.un.operand->type->kind == TY_MIXED ||
                 e->u.un.operand->type->kind == TY_OPTION ||
                 e->u.un.operand->type->kind == TY_RESULT))
                buf_printf(dst, "(!hp_val_to_bool(hv(%s)))", os);
            else
                buf_printf(dst, "(!(%s))", os);
            break;
        case T_MINUS:
            /* unary minus on a mixed value: unbox first */
            if (e->u.un.operand->type &&
                (e->u.un.operand->type->kind == TY_MIXED ||
                 e->u.un.operand->type->kind == TY_OPTION ||
                 e->u.un.operand->type->kind == TY_RESULT))
                buf_printf(dst, "(-(hp_val_to_float(hv(%s))))", os);
            else
                buf_printf(dst, "(-(%s))", os);
            break;
        case T_PLUS: buf_printf(dst, "(%s)", os); break;
        case T_TILDE: buf_printf(dst, "(~(uint64_t)(%s))", os); break;
        default: buf_printf(dst, "%s", os); break;
        }
        free((void *)os);
        break;
    }
    case EX_ASSIGN: emit_assign(g, e, dst); break;
    case EX_TERNARY: {
        Buf c, a, b;
        buf_init(&c); buf_init(&a); buf_init(&b);
        emit_cond(g, e->u.tern.cond, &c);
        emit_expr(g, e->u.tern.then, &a);
        emit_expr(g, e->u.tern.els, &b);
        /* a mixed branch boxed in a ternary whose result is typed (string,
         * int, ...) needs projecting — C rejects mixed struct/scalar ?: */
        const Type *tt3 = e->u.tern.then->type, *et3 = e->u.tern.els->type;
        const Type *rest3 = e->type;
        bool box_a = tt3 && (tt3->kind == TY_MIXED || tt3->kind == TY_OPTION ||
                             tt3->kind == TY_RESULT ||
                             /* string/array/object branches cannot mix with
                              * scalars in C's ternary - box when the other
                              * side is a scalar or the result is mixed */
                             (et3 && (type_is_numeric(et3->kind) || et3->kind == TY_BOOL)) ||
                             (et3 && (et3->kind == TY_ARRAY || et3->kind == TY_VEC ||
                                      et3->kind == TY_MAP || et3->kind == TY_SET ||
                                      et3->kind == TY_STRING)) ||
                             !et3 ||
                             (rest3 && rest3->kind == TY_MIXED));
        bool box_b = et3 && (et3->kind == TY_MIXED || et3->kind == TY_OPTION ||
                             et3->kind == TY_RESULT ||
                             (tt3 && (type_is_numeric(tt3->kind) || tt3->kind == TY_BOOL)) ||
                             (tt3 && (tt3->kind == TY_ARRAY || tt3->kind == TY_VEC ||
                                      tt3->kind == TY_MAP || tt3->kind == TY_SET ||
                                      tt3->kind == TY_STRING)) ||
                             !tt3 ||
                             (rest3 && rest3->kind == TY_MIXED));
        /* a single-type ?: stays native (string ?: string, arr ?: arr) */
        if (tt3 && et3 && tt3->kind == et3->kind &&
            (tt3->kind == TY_STRING || tt3->kind == TY_ARRAY ||
             tt3->kind == TY_VEC || tt3->kind == TY_MAP || tt3->kind == TY_SET)) {
            box_a = false;
            box_b = false;
        }
        const char *as = buf_take(&a), *bs = buf_take(&b);
        if (box_a) as = fmt("hv(%s)", as);
        if (box_b) bs = fmt("hv(%s)", bs);
        if ((box_a || box_b) && rest3) {
            /* projections consume hvals on BOTH sides — an unboxed native
             * branch (e.g. string ?: mixed) must be boxed here too */
            if (!box_a) as = fmt("hv(%s)", as);
            if (!box_b) bs = fmt("hv(%s)", bs);
            switch (rest3->kind) {
            case TY_STRING: {
                buf_printf(dst, "(%s ? hp_val_to_str(%s) : hp_val_to_str(%s))",
                           buf_take(&c), as, bs);
                break;
            }
            case TY_INT: case TY_I8: case TY_I16: case TY_I32: case TY_I64: case TY_ENUM:
                buf_printf(dst, "(%s ? hp_val_to_int(%s) : hp_val_to_int(%s))",
                           buf_take(&c), as, bs); break;
            case TY_FLOAT: case TY_F32: case TY_F64:
                buf_printf(dst, "(%s ? hp_val_to_float(%s) : hp_val_to_float(%s))",
                           buf_take(&c), as, bs); break;
            case TY_BOOL:
                buf_printf(dst, "(%s ? hp_val_to_bool(%s) : hp_val_to_bool(%s))",
                           buf_take(&c), as, bs); break;
            case TY_ARRAY: case TY_VEC: case TY_MAP: case TY_SET:
                buf_printf(dst, "(%s ? hp_val_to_arr(%s) : hp_val_to_arr(%s))",
                           buf_take(&c), as, bs); break;
            default:
                buf_printf(dst, "(%s ? %s : %s)", buf_take(&c), as, bs); break;
            }
        } else {
            /* result stays mixed: both branches must be hval for C's ?: —
             * box the unboxed side when the other side is a value */
            const char *a2 = as, *b2 = bs;
            if ((box_a || box_b) && !box_a) a2 = fmt("hv(%s)", as);
            if ((box_a || box_b) && !box_b) b2 = fmt("hv(%s)", bs);
            buf_printf(dst, "(%s ? %s : %s)", buf_take(&c), a2, b2);
        }
        free(c.data); free(a.data); free(b.data);
        break;
    }
    case EX_MATCH: emit_match_expr(g, e, dst); break;
    case EX_CLOSURE: {
        AstFn *fn = e->u.closure.fn;
        /* remember the enclosing class so the impl can type $this */
        if (fn && !fn->owner_cls && g->cur_fn && g->cur_fn->cls)
            fn->owner_cls = g->cur_fn->cls;
        /* register once — the prototype pass re-visits call sites */
        bool known = false;
        for (size_t i = 0; i < g->closures.len; i++)
            if (g->closures.items[i] == fn) { known = true; break; }
        if (!known) ptrvec_push(&g->closures, fn);
        const char *cname = closure_c_name(fn);
        /* build + pack the env right here from current locals */
        buf_printf(dst, "%s_closure_new((%s_env){", cname, cname);
        if (fn->uses_this) {
            buf_printf(dst, ".hp_this = (void*)self, ");
        }
        for (size_t i = 0; i < fn->captures.len; i++) {
            VarSym *v = fn->captures.items[i];
            if (i) buf_puts(dst, ", ");
            buf_printf(dst, ".%s = ", var_name(v));
            if (v->captured_byref) {
                /* by-ref capture: store the box pointer itself */
                buf_printf(dst, "(void*)%s", var_name(v));
                continue;
            }
            const Type *t = v->type;
            switch (t ? t->kind : TY_MIXED) {
            case TY_INT: case TY_I8: case TY_I16: case TY_I32: case TY_I64:
                buf_printf(dst, "hp_of_int(%s)", var_name(v));
                break;
            case TY_FLOAT: case TY_F32: case TY_F64:
                buf_printf(dst, "hp_of_float(%s)", var_name(v));
                break;
            case TY_BOOL:
                buf_printf(dst, "hp_of_bool(%s)", var_name(v));
                break;
            case TY_STRING:
                buf_printf(dst, "hp_of_str(%s)", var_name(v));
                break;
            case TY_ARRAY: case TY_VEC: case TY_MAP: case TY_SET:
                buf_printf(dst, "hp_of_arr(%s)", var_name(v));
                break;
            default:
                buf_printf(dst, "hv(%s)", var_name(v));
                break;
            }
        }
        buf_puts(dst, "})");
        break;
    }
    case EX_ARRAY_LIT: case EX_MAP_LIT: emit_array_lit(g, e, dst); break;
    case EX_TUPLE_LIT: {
        buf_printf(dst, "hp_arr_of(%zu, (const hval[]){", e->u.tuple.elems.len);
        for (size_t i = 0; i < e->u.tuple.elems.len; i++) {
            if (i) buf_puts(dst, ", ");
            to_hval(g, e->u.tuple.elems.items[i], dst);
        }
        buf_puts(dst, "})");
        break;
    }
    case EX_BORROW: case EX_MUTBORROW: {
        Buf o;
        buf_init(&o);
        emit_expr(g, e->u.borrow.operand, &o);
        buf_printf(dst, "(&%s)", buf_take(&o));
        free(o.data);
        break;
    }
    case EX_DEREF: {
        Buf o;
        buf_init(&o);
        emit_expr(g, e->u.deref.operand, &o);
        /* raw pointers are void*: cast to the pointee type so *p reads the
         * right width (a byte for *u8, not eight bytes) */
        const Type *pt = e->u.deref.operand->type;
        const char *ct = "int64_t";
        if (pt && pt->kind == TY_PTR && pt->elem) {
            if (pt->elem->kind == TY_I8)
                ct = "unsigned char";
            else
                ct = ctype_of(pt->elem);
        }
        buf_printf(dst, "(*(%s *)(%s))", ct, buf_take(&o));
        free(o.data);
        break;
    }
    case EX_CAST: emit_cast(g, e, dst); break;
    case EX_IS: {
        Buf o;
        buf_init(&o);
        to_hval(g, e->u.ischeck.operand, &o);
        const Type *to = e->u.ischeck.to;
        const char *tag = "HV_NULL";
        switch (to->kind) {
        case TY_INT: case TY_I8: case TY_I16: case TY_I32: case TY_I64: tag = "HV_INT"; break;
        case TY_FLOAT: case TY_F32: case TY_F64: tag = "HV_FLOAT"; break;
        case TY_BOOL: tag = "HV_BOOL"; break;
        case TY_STRING: tag = "HV_STR"; break;
        case TY_ARRAY: case TY_VEC: case TY_MAP: case TY_SET: tag = "HV_ARR"; break;
        case TY_NULL: tag = "HV_NULL"; break;
        default: tag = "HV_OBJ"; break;
        }
        buf_printf(dst, "(hp_tag(%s) == %s)", buf_take(&o), tag);
        free(o.data);
        break;
    }
    default: buf_puts(dst, "hp_null"); break;
    }
}

/* ---------------- statements ---------------- */
static void emit_block(Codegen *g, PtrVec stmts) {
    for (size_t i = 0; i < stmts.len; i++)
        emit_stmt(g, stmts.items[i]);
}

static void emit_foreach(Codegen *g, Stmt *s) {
    const char *v = var_name(s->u.foreach.vsym);
    const char *k = s->u.foreach.ksym ? var_name(s->u.foreach.ksym) : NULL;
    k = k ? k : "hp_unused_key";
    Buf it;
    buf_init(&it);
    emit_expr(g, s->u.foreach.iter, &it);
    char *iter = buf_take(&it);
    const Type *it_t = s->u.foreach.iter->type;
    int id = g->tmp_id++;
    bool is_map = it_t && it_t->kind == TY_MAP;
    bool is_str = it_t && it_t->kind == TY_STRING;
    /* a dynamically typed container (untyped property, mixed value) is
     * iterated by the runtime, which throws on non-iterables */
    bool is_dyn = !it_t || it_t->kind == TY_MIXED || it_t->kind == TY_OPTION ||
                  it_t->kind == TY_RESULT;
    line(g, "{");
    g->depth++;
    if (is_str) {
        line(g, "hp_foreach_ctx ctx%d = hp_str_iter(%s);", id, iter);
        line(g, "hstr* %s = hp_null_str();", v);
        line(g, "while (hp_foreach_next(&ctx%d, &hpv_tmp)) {", id);
        line(g, "%s = hpv_tmp.s;", v);
        line(g, "int64_t %s = ctx%d.i;", k, id);
    } else {
        if (is_dyn)
            line(g, "hp_foreach_ctx ctx%d = hp_val_iter(hv(%s));", id, iter);
        else
            line(g, "hp_foreach_ctx ctx%d = %s(%s);", id,
                 is_map ? "hp_map_iter" : "hp_arr_iter", iter);
        /* declare the loop variable with its sema-resolved C type */
        const Type *vt = s->u.foreach.vsym ? ((VarSym *)s->u.foreach.vsym)->type : NULL;
        line(g, "%s %s = %s;", ctype_of(vt ? vt : ty_mixed), v,
             zero_init_decl_of(vt ? vt : ty_mixed));
        line(g, "while (hp_foreach_next(&ctx%d, &hpv_tmp)) {", id);
        switch (vt ? vt->kind : TY_MIXED) {
        case TY_INT: case TY_I8: case TY_I16: case TY_I32: case TY_I64: case TY_ENUM:
            line(g, "%s = hpv_tmp.u.i;", v);
            break;
        case TY_FLOAT: case TY_F32: case TY_F64:
            line(g, "%s = hpv_tmp.u.f;", v);
            break;
        case TY_BOOL:
            line(g, "%s = hpv_tmp.u.b;", v);
            break;
        case TY_STRING:
            line(g, "%s = hpv_tmp.u.s;", v);
            break;
        case TY_ARRAY: case TY_VEC: case TY_MAP: case TY_SET:
            line(g, "%s = hpv_tmp.u.a;", v);
            break;
        default:
            line(g, "%s = hpv_tmp;", v);
            break;
        }
        /* key var: typed per sema too. ctx.k is always the real PHP key:
         * for maps the stored key, for plain arrays the position (the
         * runtime fills both, so no static is_map test is needed). */
        const Type *kt2 = s->u.foreach.ksym ? ((VarSym *)s->u.foreach.ksym)->type : ty_int;
        switch (kt2 ? kt2->kind : TY_INT) {
        case TY_STRING:
            line(g, "hstr* %s = ctx%d.k.u.s;", k, id);
            break;
        default:
            line(g, "int64_t %s = ctx%d.k.u.i;", k, id);
            break;
        }
    }
    g->depth++;
    g->loop_depth++;
    {
        int lid = g->label_id++;
        ptrvec_push(&g->loop_labels, (void *)(intptr_t)lid);
        emit_block(g, s->u.foreach.body);
        line(g, "hp_cont_%d: ;", lid);
        g->loop_labels.len--;
    }
    g->loop_depth--;
    g->depth--;
    line(g, "}");
    g->depth--;
    line(g, "}");
    free(iter);
}

/* unique, non-catch-var symbols referenced by a try statement */
static void collect_syms_stmt(PtrVec *syms, Stmt *s);
static void try_syms(Stmt *s, PtrVec *out) {
    PtrVec raw = {0};
    for (size_t i = 0; i < s->u.try.body.len; i++)
        collect_syms_stmt(&raw, s->u.try.body.items[i]);
    for (size_t i = 0; i < s->u.try.catches.len; i++) {
        CatchClause *cc = s->u.try.catches.items[i];
        for (size_t j = 0; j < cc->body.len; j++)
            collect_syms_stmt(&raw, cc->body.items[j]);
    }
    for (size_t i = 0; i < s->u.try.fin.len; i++)
        collect_syms_stmt(&raw, s->u.try.fin.items[i]);
    for (size_t i = 0; i < raw.len; i++) {
        VarSym *v = raw.items[i];
        bool dup = false, is_cv = false;
        for (size_t j = 0; j < i; j++)
            if (raw.items[j] == v) { dup = true; break; }
        if (dup) continue;
        for (size_t j = 0; j < s->u.try.catches.len; j++)
            if (((CatchClause *)s->u.try.catches.items[j])->sym == v) is_cv = true;
        if (is_cv) continue;
        ptrvec_push(out, v);
    }
    free(raw.items);
}

/* project an hval expression to the C type of t (try-helper returns) */
static const char *proj_hval_expr(const Type *t, const char *expr) {
    if (!t || t->kind == TY_VOID || t->kind == TY_MIXED || t->kind == TY_OPTION ||
        t->kind == TY_RESULT || t->kind == TY_TUPLE ||
        t->kind == TY_NULL || t->kind == TY_NULLABLE || t->kind == TY_UNION)
        return fmt("%s", expr); /* already an hval */
    switch (t->kind) {
    case TY_INT: case TY_I8: case TY_I16: case TY_I32: case TY_I64: case TY_ENUM:
        return fmt("(%s).u.i", expr);
    case TY_FLOAT: case TY_F32: case TY_F64: return fmt("(%s).u.f", expr);
    case TY_BOOL: return fmt("(%s).u.b", expr);
    case TY_STRING: return fmt("(%s).u.s", expr);
    case TY_ARRAY: case TY_VEC: case TY_MAP: case TY_SET: return fmt("(%s).u.a", expr);
    default: return fmt("((%s)((%s).u.p))", ctype_of(t), expr);
    }
}

/* Emit $val for a slot declared as $want.
 *
 * The question that matters here is not what type sema inferred but whether
 * the expression's generated C form is an hval: a PHP-style value slot, a
 * `use (&$x)` capture box and a closure are all different, and each has to be
 * converted its own way. $want is what the *slot* needs. */
static void emit_to_type(Codegen *g, Expr *val, const Type *want, Buf *dst) {
    bool want_scalar = want && (type_is_numeric(want->kind) || want->kind == TY_BOOL ||
                                want->kind == TY_STRING);
    bool want_arr = want && (want->kind == TY_ARRAY || want->kind == TY_VEC ||
                             want->kind == TY_MAP || want->kind == TY_SET);
    /* hval in C, heading for something that is not an hval slot: project it.
     *
     * The scalar case is PHP's runtime conversion (hp_val_to_int/str/...).
     * Arrays and objects need their payload pulled out of the value. Getting
     * only the scalar case right left `$stack = array_slice($stack, 0, $k);`
     * emitting an hval where the field is an harr*, and passing an array
     * element (`$n->kids[$i]`) to a function taking a class pointer was the
     * same gap from the other side. */
    if (c_form_is_hval(val)) {
        if (want && want->kind == TY_NULLABLE) {
            /* a nullable slot is an hval slot, but the value goes in in the
             * member's shape */
            to_hval_member(g, val, want->elem, dst);
            return;
        }
        Buf v;
        buf_init(&v);
        emit_expr(g, val, &v);
        const char *src = buf_take(&v);
        if (!want || want->kind == TY_MIXED) {
            buf_printf(dst, "%s", src);
        } else if (want_scalar) {
            buf_printf(dst, "%s(%s)", hval_cast_fn(want), src);
        } else if (want_arr) {
            buf_printf(dst, "hp_val_to_arr(%s)", src);
        } else {
            buf_printf(dst, "%s", proj_hval_expr(want, src));
        }
        free(v.data);
        return;
    }
    /* assigning into a value slot (untyped property, mixed param, by-ref box):
     * box the value. Only when the slot is actually mixed - a typed scalar
     * slot must stay in its C representation (boxing it breaks int64_t fields),
     * and a closure is a plain hclosure* until something asks for an hval.
     * A nullable/union slot is an hval slot too, so it takes the value the
     * same way. */
    bool want_box = !want || want->kind == TY_MIXED ||
                    want->kind == TY_NULLABLE || want->kind == TY_UNION ||
                    want->kind == TY_NULL;
    if (want_box) {
        if (want && want->kind == TY_NULLABLE) {
            /* the slot holds one member - the payload is in its shape */
            to_hval_member(g, val, want->elem, dst);
            return;
        }
        /* to_hval covers scalars, strings, arrays, closures and objects */
        to_hval(g, val, dst);
        return;
    }
    /* `pub Widget $w = null;` is a NULL C pointer (emit_class writes the
     * declaration that way), so `$o->w = null;` has to write a NULL C
     * pointer too. Falling through to emit_expr would box the literal as
     * `hp_null`, an hval, and C rejects assigning it to `struct Widget *`. */
    if (val && val->kind == EX_NULL && want &&
        (want->kind == TY_CLASS || want->kind == TY_STRUCT ||
         want->kind == TY_OWN  || want->kind == TY_RC ||
         want->kind == TY_INTERFACE || want->kind == TY_FN)) {
        buf_puts(dst, "0");
        return;
    }
    emit_expr(g, val, dst);
}

static void emit_stmt(Codegen *g, Stmt *s) {
    switch (s->kind) {
    case ST_LET: {
        VarSym *v = s->u.let.sym;
        const Type *t = s->u.let.ann ? s->u.let.ann
                                     : (s->u.let.init ? s->u.let.init->type : NULL);
        if (!s->u.let.init) {
            /* `let mut $x: T;` - a slot and no value (see sema) */
            if (v && !v->is_auto && t) line(g, "%s %s;", ctype_of(t), var_name(v));
            break;
        }
        Buf init;
        buf_init(&init);
        if (v && v->is_auto) {
            /* hoisted at fn top; this is just the first assignment.
             * program globals + by-ref-captured autos are hval slots —
             * route the value through emit_to_type so it is boxed. */
            const char *vn = var_name(v);
            if (v->captured_byref || v->is_program_global) {
                if (v->captured_byref) vn = fmt("(*%s)", vn);
                emit_to_type(g, s->u.let.init, NULL, &init);
            } else {
                emit_expr(g, s->u.let.init, &init);
            }
            line(g, "%s = %s;", vn, buf_take(&init));
        } else if (t && type_is_hval_slot(t)) {
            /* the binding is an hval slot (mixed, nullable, union): the value
             * has to be boxed into it, the way an assignment does */
            emit_to_type(g, s->u.let.init, t, &init);
            line(g, "%s %s = %s;", ctype_of(t), var_name(v), buf_take(&init));
        } else {
            emit_expr(g, s->u.let.init, &init);
            line(g, "%s %s = %s;", ctype_of(t), var_name(v), buf_take(&init));
        }
        free(init.data);
        break;
    }
    case ST_EXPR: {
        /* PHP list destructuring expands into a statement block */
        if (s->u.expr.expr->kind == EX_ASSIGN &&
            s->u.expr.expr->u.assign.target->kind == EX_ARRAY_LIT &&
            s->u.expr.expr->u.assign.op.kind == T_ASSIGN) {
            Expr *outer = g->cur_assign;
            g->cur_assign = s->u.expr.expr;
            emit_list_destructure(g, s->u.expr.expr);
            g->cur_assign = outer;
            break;
        }
        Buf e;
        buf_init(&e);
        emit_expr(g, s->u.expr.expr, &e);
        line(g, "%s;", buf_take(&e));
        free(e.data);
        break;
    }
    case ST_RETURN: {
        if (g->in_try_helper) {
            /* return inside try body: return FROM the enclosing function —
             * value + 'return' action travel through the env (hval-boxed) */
            if (s->u.ret.value) {
                Buf v;
                buf_init(&v);
                emit_expr(g, s->u.ret.value, &v);
                line(g, "_env->ret = hv(%s); _env->act = 1; return hp_null;",
                     buf_take(&v));
                free(v.data);
            } else {
                line(g, "_env->act = 1; return hp_null;");
            }
            break;
        }
        if (s->u.ret.value) {
            Buf v;
            buf_init(&v);
            if (g->in_closure)
                to_hval(g, s->u.ret.value, &v); /* closure impls return hval */
            else {
                const Type *rt = g->cur_fn ? g->cur_fn->ret : NULL;
                if (rt && rt->kind == TY_MIXED)
                    to_hval(g, s->u.ret.value, &v); /* inferred fns return hval */
                else
                    emit_to_type(g, s->u.ret.value, rt, &v);
            }
            line(g, "return %s;", buf_take(&v));
            free(v.data);
        } else {
            line(g, "%s;", g->in_closure ? "return hp_null" : "return");
        }
        break;
    }
    case ST_ECHO: {
        for (size_t i = 0; i < s->u.echo.exprs.len; i++) {
            Buf v;
            buf_init(&v);
            to_hval(g, s->u.echo.exprs.items[i], &v);
            line(g, "hp_echo(%s);", buf_take(&v));
            free(v.data);
        }
        line(g, "hp_echo_newline();");
        break;
    }
    case ST_PRINT: {
        Buf v;
        buf_init(&v);
        to_hval(g, s->u.print.expr, &v);
        line(g, "hp_echo(%s);", buf_take(&v));
        free(v.data);
        break;
    }
    case ST_IF: {
        Buf c;
        buf_init(&c);
        emit_cond(g, s->u.if_.cond, &c);
        line(g, "if (%s) {", buf_take(&c));
        free(c.data);
        g->depth++;
        emit_block(g, s->u.if_.then);
        g->depth--;
        if (s->u.if_.els.len == 1 && ((Stmt *)s->u.if_.els.items[0])->kind == ST_IF) {
            line(g, "} else {");
            g->depth++;
            emit_stmt(g, s->u.if_.els.items[0]);
            g->depth--;
        } else if (s->u.if_.els.len) {
            line(g, "} else {");
            g->depth++;
            emit_block(g, s->u.if_.els);
            g->depth--;
        }
        line(g, "}");
        break;
    }
    case ST_WHILE: {
        Buf c;
        buf_init(&c);
        emit_cond(g, s->u.while_.cond, &c);
        line(g, "while (%s) {", buf_take(&c));
        free(c.data);
        g->depth++;
        g->loop_depth++;
        int lid = g->label_id++;
        ptrvec_push(&g->loop_labels, (void *)(intptr_t)lid);
        emit_block(g, s->u.while_.body);
        line(g, "hp_cont_%d: ;", lid);
        g->loop_labels.len--;
        g->loop_depth--;
        g->depth--;
        line(g, "}");
        break;
    }
    case ST_DO: {
        line(g, "do {");
        g->depth++;
        g->loop_depth++;
        int lid = g->label_id++;
        ptrvec_push(&g->loop_labels, (void *)(intptr_t)lid);
        emit_block(g, s->u.do_.body);
        line(g, "hp_cont_%d: ;", lid);
        g->loop_labels.len--;
        g->loop_depth--;
        g->depth--;
        Buf c;
        buf_init(&c);
        emit_expr(g, s->u.do_.cond, &c);
        line(g, "} while (%s);", buf_take(&c));
        free(c.data);
        break;
    }
    case ST_SWITCH: {
        /* PHP switch: statements run from the matching case onward until the
         * end of the whole switch — 'break' exits. Per-case bodies are not
         * wrapped in braces, so PHP fallthrough semantics are preserved. */
        Buf c;
        buf_init(&c);
        emit_expr(g, s->u.switch_.cond, &c);
        bool cond_str = s->u.switch_.cond->type &&
                        s->u.switch_.cond->type->kind == TY_STRING;
        if (cond_str) {
            line(g, "do {");
            g->depth++;
            g->loop_depth++;
            line(g, "hstr *hp_sw_v = %s;", buf_take(&c));
            free(c.data);
            for (size_t i = 0; i < s->u.switch_.cases.len; i++) {
                SwitchCase *cse = s->u.switch_.cases.items[i];
                if (cse->is_default) continue;
                for (size_t k = 0; k < cse->patterns.len; k++) {
                    Buf p;
                    buf_init(&p);
                    emit_expr(g, cse->patterns.items[k], &p);
                    line(g, k == 0 ? "if (hp_str_eq(hp_sw_v, %s)) {" :
                          "} else if (hp_str_eq(hp_sw_v, %s)) {", buf_take(&p));
                    free(p.data);
                }
                g->depth++;
                emit_block(g, cse->body);
                g->depth--;
                line(g, "break;");
                line(g, "}");
            }
            {
                /* default arm runs last (PHP executes it whenever no case
                 * matched, so scanning order stays intuitive) */
                for (size_t i = 0; i < s->u.switch_.cases.len; i++) {
                    SwitchCase *cse = s->u.switch_.cases.items[i];
                    if (!cse->is_default) continue;
                    emit_block(g, cse->body);
                }
            }
            g->loop_depth--;
            g->depth--;
            line(g, "} while (0);");
            break;
        }
        bool cond_dyn = s->u.switch_.cond->type &&
                        (s->u.switch_.cond->type->kind == TY_NULLABLE ||
                         s->u.switch_.cond->type->kind == TY_UNION ||
                         s->u.switch_.cond->type->kind == TY_MIXED);
        if (cond_dyn) {
            /* a nullable/union/mixed subject holds an hval, so the cases
             * compare with PHP's loose == (hp_val_eq) - the way the string
             * path compares with hp_str_eq */
            line(g, "do {");
            g->depth++;
            g->loop_depth++;
            line(g, "hval hp_sw_v = hv(%s);", buf_take(&c));
            free(c.data);
            for (size_t i = 0; i < s->u.switch_.cases.len; i++) {
                SwitchCase *cse = s->u.switch_.cases.items[i];
                if (cse->is_default) continue;
                for (size_t k = 0; k < cse->patterns.len; k++) {
                    Buf p;
                    buf_init(&p);
                    to_hval(g, cse->patterns.items[k], &p);
                    line(g, k == 0 ? "if (hp_val_eq(hp_sw_v, %s)) {" :
                          "} else if (hp_val_eq(hp_sw_v, %s)) {", buf_take(&p));
                    free(p.data);
                }
                g->depth++;
                emit_block(g, cse->body);
                g->depth--;
                line(g, "break;");
                line(g, "}");
            }
            {
                /* default arm runs last, whenever no case matched */
                for (size_t i = 0; i < s->u.switch_.cases.len; i++) {
                    SwitchCase *cse = s->u.switch_.cases.items[i];
                    if (!cse->is_default) continue;
                    emit_block(g, cse->body);
                }
            }
            g->loop_depth--;
            g->depth--;
            line(g, "} while (0);");
            break;
        }
        /* integer switch: plain C switch, PHP break/fallthrough semantics */
        line(g, "switch (%s) {", buf_take(&c));
        free(c.data);
        g->depth++;
        g->loop_depth++;
        for (size_t i = 0; i < s->u.switch_.cases.len; i++) {
            SwitchCase *cse = s->u.switch_.cases.items[i];
            for (size_t k = 0; k < cse->patterns.len; k++) {
                Buf p;
                buf_init(&p);
                emit_expr(g, cse->patterns.items[k], &p);
                line(g, "case %s:", buf_take(&p));
                free(p.data);
            }
            if (cse->is_default) line(g, "default:");
            g->depth++;
            emit_block(g, cse->body);
            g->depth--;
        }
        g->loop_depth--;
        g->depth--;
        line(g, "}");
        break;
    }
    case ST_FOR: {
        line(g, "{");
        g->depth++;
        for (size_t i = 0; i < s->u.for_.init.len; i++)
            emit_stmt(g, s->u.for_.init.items[i]);
        Buf c;
        buf_init(&c);
        char *cond = xstrdup("1");
        if (s->u.for_.cond) {
            emit_expr(g, s->u.for_.cond, &c);
            cond = buf_take(&c);
        }
        line(g, "for (; %s ;) {", cond);
        free(cond);
        g->depth++;
        g->loop_depth++;
        /* the step lives inside the body, so 'continue' must jump *past* it
         * to the label below (a plain C continue would skip the step and
         * loop forever) */
        int lid = g->label_id++;
        ptrvec_push(&g->loop_labels, (void *)(intptr_t)lid);
        emit_block(g, s->u.for_.body);
        line(g, "hp_cont_%d: ;", lid);
        g->loop_labels.len--;
        for (size_t i = 0; i < s->u.for_.step.len; i++)
            emit_stmt(g, s->u.for_.step.items[i]);
        g->loop_depth--;
        g->depth--;
        line(g, "}");
        g->depth--;
        line(g, "}");
        break;
    }
    case ST_FOREACH:
        emit_foreach(g, s);
        break;
    case ST_BREAK:
        if (g->in_try_helper && g->loop_depth == 0)
            line(g, "_env->act = 2; return hp_null;");
        else
            line(g, "break;");
        break;
    case ST_CONTINUE:
        if (g->in_try_helper && g->loop_depth == 0) {
            /* leaves the helper: the loop lives in the caller */
            line(g, "_env->act = 3; return hp_null;");
        } else if (g->loop_labels.len > 0) {
            line(g, "goto hp_cont_%d;",
                 (int)(intptr_t)g->loop_labels.items[g->loop_labels.len - 1]);
        } else {
            line(g, "continue;");
        }
        break;
    case ST_BLOCK:
        line(g, "{");
        g->depth++;
        emit_block(g, s->u.block.stmts);
        g->depth--;
        line(g, "}");
        break;
    case ST_UNSAFE_BLOCK:
        line(g, "{ /* unsafe */");
        g->depth++;
        emit_block(g, s->u.unsafe.stmts);
        g->depth--;
        line(g, "}");
        break;
    case ST_TRY: {
        int id = g->try_id++;
        /* try/catch compiles to two file-scope helpers run by the runtime's
         * hp_try_run: setjmp lives ONLY there, so generated functions never
         * contain setjmp — no volatile locals, no -O2 longjmp-clobber UB.
         * Captured locals are passed by address and aliased with #define, so
         * catch/finally observe every write immediately and no copy-back is
         * needed on early return/break/continue. */
        const Type *rt = g->cur_fn ? (g->cur_fn->ret ? g->cur_fn->ret : ty_void) : ty_void;
        bool in_helper = g->in_try_helper;
        bool is_meth = g->cur_fn && g->cur_fn->is_method && !g->cur_fn->is_static && g->cur_fn->cls;
        PtrVec vs = {0};
        {
            PtrVec raw = {0};
            try_syms(s, &raw);
            for (size_t i = 0; i < raw.len; i++) {
                VarSym *cv = raw.items[i];
                if (cv->is_auto || cv->is_param) ptrvec_push(&vs, cv);
            }
            free(raw.items);
        }
        if (vs.len > 64)
            fatal("a single try block captures %zu locals; the limit is 64", vs.len);
        line(g, "{ /* try/catch — setjmp lives only in the runtime */");
        g->depth++;
        line(g, "extern hval T%d_body(void *_envp, hval _ex);", id);
        line(g, "extern hval T%d_catch(void *_envp, hval _ex);", id);
        line(g, "T_env e%d;", id);
        line(g, "e%d.act = 0;", id);
        line(g, "e%d.ret = hp_null;", id);
        line(g, "e%d.self = %s;", id, is_meth ? "(void *)self" : "NULL");
        for (size_t i = 0; i < vs.len; i++)
            line(g, "e%d.vp[%zu] = (void *)&%s;", id, i, var_name(vs.items[i]));
        /* --- helper definitions: file scope, one buffer per nesting level --- */
        Buf *saved_out = g->out;
        int saved_depth = g->depth;
        bool saved_helper = g->in_try_helper;
        PtrVec *saved_vars = g->cur_helper_vars;
        int saved_loop = g->loop_depth;
        int hlevel = g->helper_depth;
        if (hlevel > 7) hlevel = 7;
        g->out = &g->try_bufs[hlevel];
        g->depth = 0;
        g->in_try_helper = true;
        g->cur_helper_vars = &vs;
        g->helper_depth = hlevel + 1;
        g->loop_depth = 0;
        /* body helper */
        line(g, "hval T%d_body(void *_envp, hval _ex) {", id);
        g->depth++;
        line(g, "(void)_ex;");
        line(g, "T_env *_env = (T_env *)_envp; (void)_env;");
        if (is_meth)
            line(g, "struct %s *self = (struct %s *)_env->self; (void)self;",
                 g->cur_fn->cls->name, g->cur_fn->cls->name);
        for (size_t i = 0; i < vs.len; i++)
            line(g, "#define %s (*((%s *)_env->vp[%zu]))", var_name(vs.items[i]),
                 ctype_of(((VarSym *)vs.items[i])->type), i);
        emit_block(g, s->u.try.body);
        for (size_t i = 0; i < vs.len; i++)
            line(g, "#undef %s", var_name(vs.items[i]));
        line(g, "return hp_null;");
        g->depth--;
        line(g, "}");
        /* catch helper */
        line(g, "hval T%d_catch(void *_envp, hval _ex) {", id);
        g->depth++;
        line(g, "T_env *_env = (T_env *)_envp; (void)_env;");
        if (is_meth)
            line(g, "struct %s *self = (struct %s *)_env->self; (void)self;",
                 g->cur_fn->cls->name, g->cur_fn->cls->name);
        for (size_t i = 0; i < vs.len; i++)
            line(g, "#define %s (*((%s *)_env->vp[%zu]))", var_name(vs.items[i]),
                 ctype_of(((VarSym *)vs.items[i])->type), i);
        if (s->u.try.catches.len == 0) {
            line(g, "(void)_ex;");
        } else {
            for (size_t ci = 0; ci < s->u.try.catches.len; ci++) {
                CatchClause *cc = s->u.try.catches.items[ci];
                const char *cvname = cc->sym ? var_name((VarSym *)cc->sym) : "hp_e";
                const Type *ct = cc->sym ? ((VarSym *)cc->sym)->type : ty_string;
                if (ct && ct->kind == TY_CLASS && ct->name == intern("Exception"))
                    line(g, "hval %s = _ex; (void)%s;", cvname, cvname);
                else if (ct && ct->kind == TY_STRING)
                    line(g, "hstr *%s = hp_exception_msg(); (void)%s;", cvname, cvname);
                else
                    line(g, "%s %s = %s; (void)%s;", ctype_of(ct), cvname,
                         proj_hval_expr(ct, "_ex"), cvname);
                emit_block(g, cc->body);
            }
        }
        /* no handler matched: hand the exception back so the caller runs its
         * finally block and only then rethrows */
        if (s->u.try.catches.len == 0)
            line(g, "return _ex;");
        for (size_t i = 0; i < vs.len; i++)
            line(g, "#undef %s", var_name(vs.items[i]));
        line(g, "return hp_null;");
        g->depth--;
        line(g, "}");
        g->loop_depth = saved_loop;
        g->cur_helper_vars = saved_vars;
        g->helper_depth = hlevel;
        g->in_try_helper = saved_helper;
        g->depth = saved_depth;
        g->out = saved_out;
        /* --- run it: finally first, then honor return/break/continue --- */
        line(g, "hval _tr%d = hp_try_run(T%d_body, T%d_catch, &e%d); (void)_tr%d;",
             id, id, id, id, id);
        if (s->u.try.fin.len) emit_block(g, s->u.try.fin);
        line(g, "if (_tr%d.tag != HV_NULL) hp_throw(_tr%d); /* unhandled: propagate */", id, id);
        if (in_helper) {
            line(g, "if (e%d.act != 0) { _env->ret = e%d.ret; _env->act = e%d.act; return hp_null; }",
                 id, id, id);
        } else if (g->in_closure) {
            line(g, "if (e%d.act == 1) return e%d.ret;", id, id);
        } else if (g->cur_fn == NULL) {
            line(g, "if (e%d.act == 1) return 0;", id);
        } else if (!rt || rt->kind == TY_VOID) {
            line(g, "if (e%d.act == 1) return;", id);
        } else {
            line(g, "if (e%d.act == 1) return %s;", id, proj_hval_expr(rt, fmt("e%d.ret", id)));
        }
        if (!in_helper && g->loop_depth > 0) {
            line(g, "if (e%d.act == 2) break;", id);
            if (g->loop_labels.len > 0)
                line(g, "if (e%d.act == 3) goto hp_cont_%d;", id,
                     (int)(intptr_t)g->loop_labels.items[g->loop_labels.len - 1]);
            else
                line(g, "if (e%d.act == 3) continue;", id);
        }
        g->depth--;
        line(g, "}");
        free(vs.items);
        break;
    }
    case ST_THROW: {
        Buf v;
        buf_init(&v);
        emit_expr(g, s->u.throw.expr, &v);
        line(g, "hp_throw(hv(%s));", buf_take(&v));
        free(v.data);
        break;
    }
    }
}

/* ---------------- declarations ---------------- */
static AstFn *class_find_ctor(AstClass *c) {
    for (size_t i = 0; i < c->methods.len; i++) {
        AstFn *m = c->methods.items[i];
        if (m->name == intern("__construct")) return m;
    }
    if (c->base) return class_find_ctor(c->base);
    return NULL;
}

/* ---- virtual dispatch (PHP-style overrides, C++-style vtables) ---- */
static bool class_has_derived(Codegen *g, AstClass *c) {
    for (size_t i = 0; i < g->prog->decls.len; i++) {
        Decl *d = g->prog->decls.items[i];
        if (d->kind != DK_CLASS && d->kind != DK_TRAIT) continue;
        AstClass *k = d->u.cls;
        for (AstClass *b = k->base; b; b = b->base)
            if (b == c) return true;
    }
    return false;
}

static AstClass *class_root(AstClass *c) {
    while (c->base) c = c->base;
    return c;
}

/* does any class derived from owner define a method with m's name? */
static bool method_overridden(Codegen *g, AstClass *owner, AstFn *m) {
    for (size_t i = 0; i < g->prog->decls.len; i++) {
        Decl *d = g->prog->decls.items[i];
        if (d->kind != DK_CLASS && d->kind != DK_TRAIT) continue;
        AstClass *k = d->u.cls;
        if (k == owner) continue;
        bool derives = false;
        for (AstClass *b = k->base; b; b = b->base)
            if (b == owner) { derives = true; break; }
        if (!derives) continue;
        for (size_t j = 0; j < k->methods.len; j++)
            if (((AstFn *)k->methods.items[j])->name == m->name) return true;
    }
    return false;
}

/* virtual methods of c, root-first — prefix property keeps slots stable */
static void class_vmethods(AstClass *c, PtrVec *out) {
    AstClass *chain[32];
    int n = 0;
    for (AstClass *k = c; k && n < 32; k = k->base) chain[n++] = k;
    for (int i = n - 1; i >= 0; i--)
        for (size_t j = 0; j < chain[i]->methods.len; j++) {
            AstFn *m = chain[i]->methods.items[j];
            if (m->is_static || m->is_abstract) continue;
            if (m->name == intern("__construct")) continue;
            ptrvec_push(out, m);
        }
}

static void emit_fn_body(Codegen *g, AstFn *fn, const Type *self_type);
static void collect_syms_stmt(PtrVec *syms, Stmt *s);
static void emit_closure(Codegen *g, AstFn *fn);
static void emit_closure_prototype(Codegen *g, AstFn *fn);

static bool g_emit_bodies = true;

static void emit_fn(Codegen *g, AstFn *fn) {
    const Type *ret = fn->ret ? fn->ret : type_new(TY_VOID);
    const char *retty = ctype_of(ret);
    const char *name = fn->is_method && fn->cls ? mangle_method(fn->cls, fn->name)
                                                : mangle_fn(fn->name);
    Buf hdr;
    buf_init(&hdr);
    buf_printf(&hdr, "%s %s(", retty, name);
    bool first = true;
    if (fn->is_method && !fn->is_static) {
        buf_printf(&hdr, "struct %s* self", fn->cls->name);
        first = false;
    }
    for (size_t i = 0; i < fn->params.len; i++) {
        Param *pm = fn->params.items[i];
        if (!first) buf_puts(&hdr, ", ");
        if (pm->by_ref) {
            /* by-ref param: the caller passes &slot (typed pointer) */
            buf_printf(&hdr, "%s *%s", ctype_of(pm->resolved), var_name(pm->sym));
        } else {
            buf_printf(&hdr, "%s %s", ctype_of(pm->resolved), param_slot_name(pm));
        }
        first = false;
    }
    buf_puts(&hdr, ")");
    if (!g_emit_bodies) {
        line(g, "%s;", buf_take(&hdr));
        return;
    }
    free((void *)hdr.data);
    g->cur_fn = fn;
    /* body */
    buf_init(&hdr);
    buf_printf(&hdr, "%s %s(", retty, name);
    first = true;
    if (fn->is_method && !fn->is_static) {
        buf_printf(&hdr, "struct %s* self", fn->cls->name);
        first = false;
    }
    for (size_t i = 0; i < fn->params.len; i++) {
        Param *pm = fn->params.items[i];
        if (!first) buf_puts(&hdr, ", ");
        if (pm->by_ref) {
            buf_printf(&hdr, "%s *%s", ctype_of(pm->resolved), var_name(pm->sym));
        } else {
            buf_printf(&hdr, "%s %s", ctype_of(pm->resolved), param_slot_name(pm));
        }
        first = false;
    }
    buf_puts(&hdr, ") {");
    line(g, "%s", buf_take(&hdr));
    g->depth++;
    emit_fn_body(g, fn, NULL);
    g->depth--;
    line(g, "}");
    line(g, "");
    g->cur_fn = NULL;
}

/* Hoist-declaration scan: PHP-style auto-declared vars may first be assigned
 * inside nested blocks, but C needs them declared in that block. We pre-declare
 * every auto-declared var that is assigned anywhere within a block, at the top
 * of the innermost ENCLOSING block where it is also visible... simplified: we
 * emit a declaration at the start of each block that (re)assigns it, guarded
 * by a static flag — instead we rely on sema assigning one symbol per var and
 * declare it in the scope where sema declared it (approximated as the fn body
 * or top-level block). Here: collect syms declared anywhere inside. */static void collect_syms_stmt(PtrVec *syms, Stmt *s);
static void collect_syms_expr(PtrVec *syms, Expr *e);
static const char *zero_init_of(const Type *t);
static const char *zero_init_decl_of(const Type *t);
static void collect_globals_stmt(PtrVec *syms, Stmt *s);
static bool is_global_alias(VarSym *v);   /* file-scope `global $x;` alias */
static bool is_global_alias(VarSym *v) { return v && v->is_global_alias; }
static bool is_global_alias(VarSym *v);   /* file-scope `global $x;` alias */




static void collect_syms_expr(PtrVec *syms, Expr *e) {
    if (!e) return;
    switch (e->kind) {
    case EX_VAR:
        if (e->u.var.sym) ptrvec_push(syms, e->u.var.sym);
        break;
    case EX_ASSIGN:
        collect_syms_expr(syms, e->u.assign.target);
        collect_syms_expr(syms, e->u.assign.value);
        break;
    case EX_CALL:
        collect_syms_expr(syms, e->u.call.fn);   /* callee may be a var: $f() */
        for (size_t i = 0; i < e->u.call.args.len; i++)
            collect_syms_expr(syms, e->u.call.args.items[i]);
        break;
    case EX_METHOD:
        collect_syms_expr(syms, e->u.method.obj);
        for (size_t i = 0; i < e->u.method.args.len; i++)
            collect_syms_expr(syms, e->u.method.args.items[i]);
        break;
    case EX_TPL:
        for (size_t i = 0; i < e->u.tpl.exprs.len; i++)
            collect_syms_expr(syms, e->u.tpl.exprs.items[i]);
        break;
    case EX_BIN:
        collect_syms_expr(syms, e->u.bin.l);
        collect_syms_expr(syms, e->u.bin.r);
        break;
    case EX_INDEX:
        collect_syms_expr(syms, e->u.index.obj);
        collect_syms_expr(syms, e->u.index.idx);
        break;
    case EX_BORROW: case EX_MUTBORROW:
        collect_syms_expr(syms, e->u.borrow.operand);
        break;
    case EX_DEREF:
        collect_syms_expr(syms, e->u.deref.operand);
        break;
    case EX_CAST:
        collect_syms_expr(syms, e->u.cast.operand);
        break;
    case EX_UN:
        collect_syms_expr(syms, e->u.un.operand);
        break;
    case EX_MAP_LIT:
        for (size_t i = 0; i < e->u.map.keys.len; i++)
            collect_syms_expr(syms, e->u.map.keys.items[i]);
        for (size_t i = 0; i < e->u.map.vals.len; i++)
            collect_syms_expr(syms, e->u.map.vals.items[i]);
        break;
    case EX_NEW:
        for (size_t i = 0; i < e->u.newexpr.args.len; i++)
            collect_syms_expr(syms, e->u.newexpr.args.items[i]);
        break;
    case EX_STATIC:
        for (size_t i = 0; i < e->u.staticcall.args.len; i++)
            collect_syms_expr(syms, e->u.staticcall.args.items[i]);
        break;
    case EX_IS:
        collect_syms_expr(syms, e->u.ischeck.operand);
        break;
    case EX_CLOSURE:
        if (e->u.closure.fn)
            for (size_t i = 0; i < e->u.closure.fn->captures.len; i++)
                ptrvec_push(syms, e->u.closure.fn->captures.items[i]);
        break;
    case EX_TERNARY:
        collect_syms_expr(syms, e->u.tern.cond);
        collect_syms_expr(syms, e->u.tern.then);
        collect_syms_expr(syms, e->u.tern.els);
        break;
    case EX_MATCH:
        collect_syms_expr(syms, e->u.matchexpr.subject);
        break;
    case EX_FIELD: collect_syms_expr(syms, e->u.field.obj); break;
    case EX_ARRAY_LIT:
        for (size_t i = 0; i < e->u.arr.elems.len; i++)
            collect_syms_expr(syms, e->u.arr.elems.items[i]);
        break;
    default: break;
    }
}

static void collect_syms_stmt(PtrVec *syms, Stmt *s) {
    if (!s) return;
    switch (s->kind) {
    case ST_EXPR: collect_syms_expr(syms, s->u.expr.expr); break;
    case ST_ECHO:
        for (size_t i = 0; i < s->u.echo.exprs.len; i++)
            collect_syms_expr(syms, s->u.echo.exprs.items[i]);
        break;
    case ST_LET:
        if (s->u.let.init) collect_syms_expr(syms, s->u.let.init);
        if (s->u.let.sym) ptrvec_push(syms, s->u.let.sym);
        break;
    case ST_RETURN: collect_syms_expr(syms, s->u.ret.value); break;
    case ST_PRINT: collect_syms_expr(syms, s->u.print.expr); break;
    case ST_IF:
        collect_syms_expr(syms, s->u.if_.cond);
        for (size_t i = 0; i < s->u.if_.then.len; i++)
            collect_syms_stmt(syms, s->u.if_.then.items[i]);
        for (size_t i = 0; i < s->u.if_.els.len; i++)
            collect_syms_stmt(syms, s->u.if_.els.items[i]);
        break;
    case ST_WHILE:
        collect_syms_expr(syms, s->u.while_.cond);
        for (size_t i = 0; i < s->u.while_.body.len; i++)
            collect_syms_stmt(syms, s->u.while_.body.items[i]);
        break;
    case ST_FOR:
        for (size_t i = 0; i < s->u.for_.init.len; i++)
            collect_syms_stmt(syms, s->u.for_.init.items[i]);
        collect_syms_expr(syms, s->u.for_.cond);
        for (size_t i = 0; i < s->u.for_.step.len; i++)
            collect_syms_stmt(syms, s->u.for_.step.items[i]);
        for (size_t i = 0; i < s->u.for_.body.len; i++)
            collect_syms_stmt(syms, s->u.for_.body.items[i]);
        break;
    case ST_FOREACH:
        collect_syms_expr(syms, s->u.foreach.iter);
        if (s->u.foreach.vsym) ptrvec_push(syms, s->u.foreach.vsym);
        if (s->u.foreach.ksym) ptrvec_push(syms, s->u.foreach.ksym);
        for (size_t i = 0; i < s->u.foreach.body.len; i++)
            collect_syms_stmt(syms, s->u.foreach.body.items[i]);
        break;
    case ST_BLOCK:
        for (size_t i = 0; i < s->u.block.stmts.len; i++)
            collect_syms_stmt(syms, s->u.block.stmts.items[i]);
        break;
    case ST_UNSAFE_BLOCK:
        for (size_t i = 0; i < s->u.unsafe.stmts.len; i++)
            collect_syms_stmt(syms, s->u.unsafe.stmts.items[i]);
        break;
    case ST_TRY:
        for (size_t i = 0; i < s->u.try.body.len; i++)
            collect_syms_stmt(syms, s->u.try.body.items[i]);
        for (size_t i = 0; i < s->u.try.catches.len; i++) {
            CatchClause *cc = s->u.try.catches.items[i];
            if (cc->sym) ptrvec_push(syms, cc->sym);
            for (size_t j = 0; j < cc->body.len; j++)
                collect_syms_stmt(syms, cc->body.items[j]);
        }
        for (size_t i = 0; i < s->u.try.fin.len; i++)
            collect_syms_stmt(syms, s->u.try.fin.items[i]);
        break;
    case ST_THROW:
        collect_syms_expr(syms, s->u.throw.expr);
        break;
    case ST_SWITCH:
        collect_syms_expr(syms, s->u.switch_.cond);
        for (size_t i = 0; i < s->u.switch_.cases.len; i++) {
            SwitchCase *sc = s->u.switch_.cases.items[i];
            for (size_t k = 0; k < sc->patterns.len; k++)
                collect_syms_expr(syms, sc->patterns.items[k]);
            for (size_t j = 0; j < sc->body.len; j++)
                collect_syms_stmt(syms, sc->body.items[j]);
        }
        break;
    case ST_DO:
        for (size_t i = 0; i < s->u.do_.body.len; i++)
            collect_syms_stmt(syms, s->u.do_.body.items[i]);
        collect_syms_expr(syms, s->u.do_.cond);
        break;
    default: break;
    }
}

static const char *zero_init_of(const Type *t) {
    if (!t) return "hp_null";
    switch (t->kind) {
    case TY_INT: case TY_I8: case TY_I16: case TY_I32: case TY_I64: case TY_ENUM:
        return "0";
    case TY_FLOAT: case TY_F32: case TY_F64:
        return "0.0";
    case TY_BOOL:
        return "false";
    case TY_STRING:
        return "hp_null_str()";
    case TY_ARRAY: case TY_VEC: case TY_MAP: case TY_SET:
        return "hp_null_arr()";
    case TY_MIXED:
        return "hp_null";
    /* a nullable/union slot starts out empty: hp_null is the hval that says
     * "no value" (a zeroed hval would read as the integer 0) */
    case TY_NULL: case TY_NULLABLE: case TY_UNION:
        return "hp_null";
    default:
        return "0"; /* pointers (struct X*, hclosure*) accept 0 */
    }
}

/* The value a declared-but-uninitialised VARIABLE starts with.
 *
 * Arrays get a *fresh*, unshared empty array instead of the
 * hp_null_arr() singleton that zero_init_of hands out. The singleton has
 * exactly one owner (rc == 1), so the copy-on-write in hp_arr_push has
 * nothing to clone: the first push into a local that was never assigned
 * writes into the singleton, and then every other "empty" array in the
 * process sees that element. Fresh scalars have no such problem - they are
 * immutable in C - so only containers are special-cased. */
static const char *zero_init_decl_of(const Type *t) {
    if (t) switch (t->kind) {
    case TY_ARRAY: case TY_VEC: case TY_MAP: case TY_SET:
        return "hp_arr_new()";
    default: break;
    }
    return zero_init_of(t);
}

/* Walk for ST_GLOBAL statements only; push their shared VarSyms. Recurses
 * into nested blocks and closure bodies so nothing is missed. */
static void collect_globals_stmt(PtrVec *syms, Stmt *s) {
    if (!s) return;
    switch (s->kind) {
    case ST_GLOBAL:
        for (size_t i = 0; i < s->u.globals.syms.len; i++)
            ptrvec_push(syms, s->u.globals.syms.items[i]);
        break;
    case ST_BLOCK:
        for (size_t i = 0; i < s->u.block.stmts.len; i++)
            collect_globals_stmt(syms, s->u.block.stmts.items[i]);
        break;
    case ST_EXPR:
        if (s->u.expr.expr && s->u.expr.expr->kind == EX_CLOSURE &&
            s->u.expr.expr->u.closure.fn)
            for (size_t i = 0; i < s->u.expr.expr->u.closure.fn->body.len; i++)
                collect_globals_stmt(syms, s->u.expr.expr->u.closure.fn->body.items[i]);
        break;
    case ST_IF:
        for (size_t i = 0; i < s->u.if_.then.len; i++)
            collect_globals_stmt(syms, s->u.if_.then.items[i]);
        for (size_t i = 0; i < s->u.if_.els.len; i++)
            collect_globals_stmt(syms, s->u.if_.els.items[i]);
        break;
    case ST_WHILE:
        for (size_t i = 0; i < s->u.while_.body.len; i++)
            collect_globals_stmt(syms, s->u.while_.body.items[i]);
        break;
    case ST_FOR:
        for (size_t i = 0; i < s->u.for_.init.len; i++)
            collect_globals_stmt(syms, s->u.for_.init.items[i]);
        for (size_t i = 0; i < s->u.for_.step.len; i++)
            collect_globals_stmt(syms, s->u.for_.step.items[i]);
        for (size_t i = 0; i < s->u.for_.body.len; i++)
            collect_globals_stmt(syms, s->u.for_.body.items[i]);
        break;
    case ST_FOREACH:
        for (size_t i = 0; i < s->u.foreach.body.len; i++)
            collect_globals_stmt(syms, s->u.foreach.body.items[i]);
        break;
    case ST_TRY:
        for (size_t i = 0; i < s->u.try.body.len; i++)
            collect_globals_stmt(syms, s->u.try.body.items[i]);
        for (size_t i = 0; i < s->u.try.catches.len; i++) {
            CatchClause *cc = s->u.try.catches.items[i];
            for (size_t j = 0; j < cc->body.len; j++)
                collect_globals_stmt(syms, cc->body.items[j]);
        }
        for (size_t i = 0; i < s->u.try.fin.len; i++)
            collect_globals_stmt(syms, s->u.try.fin.items[i]);
        break;
    case ST_SWITCH:
        for (size_t i = 0; i < s->u.switch_.cases.len; i++) {
            SwitchCase *swc = s->u.switch_.cases.items[i];
            for (size_t j = 0; j < swc->body.len; j++)
                collect_globals_stmt(syms, swc->body.items[j]);
        }
        break;
    case ST_DO:
        for (size_t i = 0; i < s->u.do_.body.len; i++)
            collect_globals_stmt(syms, s->u.do_.body.items[i]);
        break;
    default: break;
    }
}

/* Declare auto vars at fn top (C89-friendly, mirrors PHP hoisting). */
static void emit_auto_decls(Codegen *g, AstFn *fn) {
    PtrVec syms = {0};
    for (size_t i = 0; i < fn->body.len; i++)
        collect_syms_stmt(&syms, fn->body.items[i]);
    for (size_t i = 0; i < syms.len; i++) {
        VarSym *v = syms.items[i];
        if (!v->is_auto || v->is_param) continue;
        if (is_global_alias(v)) continue;   /* file-scope storage */
        if (v->is_program_global) continue; /* file-scope storage */
        bool seen = false;
        for (size_t j = 0; j < i; j++)
            if (syms.items[j] == v) { seen = true; break; }
        if (seen) continue;
        if (v->captured_byref) {
            /* PHP by-ref capture: heap box shared with the closure env.
             * All frame accesses go through (*v). */
            line(g, "hval *%s = hp_box_new();", var_name(v));
        } else {
            line(g, "%s %s = %s;", ctype_of(v->type),
                 var_name(v), zero_init_decl_of(v->type));
        }
    }
    /* A by-value parameter that a closure captured by reference under its own
     * name needs a box of its own: the box holds the parameter's value and is
     * shared with the closure env, so writes from the closure persist across
     * calls while the caller's variable is untouched - which is exactly what
     * capturing a value parameter by reference means in PHP. */
    for (size_t i = 0; i < fn->params.len; i++) {
        Param *pm = fn->params.items[i];
        VarSym *ps = (VarSym *)pm->sym;
        if (!ps || !ps->captured_byref || pm->by_ref) continue;
        line(g, "hval *%s = hp_box_new();", var_name(ps));
        line(g, "*%s = %s;", var_name(ps), box_param_value(pm->resolved, param_slot_name(pm)));
    }
}

static const char *zero_init_of(const Type *t);
static const char *zero_init_decl_of(const Type *t);

static void emit_fn_body(Codegen *g, AstFn *fn, const Type *self_type) {
    (void)self_type;
    emit_auto_decls(g, fn);
    emit_block(g, fn->body);
    const Type *ret = fn->ret ? fn->ret : type_new(TY_VOID);
    if (ret->kind != TY_VOID) {
        /* zero value of return type (unreachable fallback) */
        if (type_is_integral(ret->kind)) line(g, "return (int64_t)0;");
        else if (type_is_numeric(ret->kind)) line(g, "return (double)0;");
        else if (ret->kind == TY_BOOL) line(g, "return false;");
        else if (ret->kind == TY_STRING) line(g, "return hp_null_str();");
        else if (ret->kind == TY_ARRAY || ret->kind == TY_VEC ||
                 ret->kind == TY_MAP || ret->kind == TY_SET)
            line(g, "return hp_arr_new();");
        else if (ret->kind == TY_CLASS || ret->kind == TY_STRUCT)
            line(g, "return 0;");  /* unreachable fallback: null object */
        else if ((ret->kind == TY_OWN || ret->kind == TY_RC) && ret->elem &&
                 (ret->elem->kind == TY_CLASS || ret->elem->kind == TY_STRUCT))
            line(g, "return 0;");
        else line(g, "return hp_null;");
    }
}

static void emit_struct(Codegen *g, AstClass *c) {
    line(g, "typedef struct %s {", c->name);
    g->depth++;
    /* embed the base struct FIRST so derived pointers convert implicitly */
    if (c->base) line(g, "struct %s __base;", c->base->name);
    /* runtime class id for virtual dispatch (per-level, read via top ptr) */
    line(g, "int __cls;");
    for (size_t i = 0; i < c->fields.len; i++) {
        StructField *f = c->fields.items[i];
        if (f->is_static) continue;
        line(g, "%s %s;", ctype_of(f->type), f->name);
    }
    g->depth--;
    line(g, "} %s;", c->name);
    line(g, "");
}

/* Structs are emitted for every class before any method body, so a method
 * may touch a class declared later in the file (mutual references). */
static bool g_structs_emitted;

/* `self->field` at depth 0, `self->__base.field` one level up, and so on —
 * each ancestor struct is embedded as the next `__base` member. */
static const char *class_field_lval_depth(int depth, const char *name) {
    if (depth <= 0) return fmt("self->%s", name ? name : "hp_missing_field");
    /* each ancestor struct is embedded by value, so the chain uses `.` */
    char path[256];
    snprintf(path, sizeof path, "self->__base");
    for (int i = 1; i < depth; i++)
        snprintf(path + strlen(path), sizeof(path) - strlen(path), ".__base");
    return fmt("%s.%s", path, name ? name : "hp_missing_field");
}

static void emit_class(Codegen *g, AstClass *c) {
    if (!g_structs_emitted) emit_struct(g, c);
    /* generic constructor: Class_new_args("Class", field-init values...) */
    line(g, "static struct %s* %s_new_args(const char* cls, ...);", c->name, c->name);
    line(g, "static struct %s* %s_new_args(const char* cls, ...) {", c->name, c->name);
    g->depth++;
    line(g, "(void)cls;");
    line(g, "struct %s* self = hp_alloc(sizeof(struct %s));", c->name, c->name);
    line(g, "self->__cls = hp_cls_%s;", c->name);
    /* keep ancestor-level ids in sync so base-typed receivers dispatch right */
    {
        char path[256];
        snprintf(path, sizeof path, "__base");
        for (AstClass *p = c->base; p; p = p->base) {
            line(g, "self->%s.__cls = hp_cls_%s;", path, c->name);
            snprintf(path + strlen(path), sizeof(path) - strlen(path), ".__base");
        }
    }
    /* Property initialisation walks the whole inheritance chain: a subclass
     * must also zero and default every field its ancestors declare, or
     * `class App extends Widgets` silently starts with garbage metrics. */
    for (AstClass *k = c; k; k = k->base) {
        int depth = 0;
        for (AstClass *p = c; p && p != k; p = p->base) depth++;
        for (size_t i = 0; i < k->fields.len; i++) {
            StructField *f = k->fields.items[i];
            if (f->is_static) continue;
            if (f->cls && f->cls != k) continue;   /* handled at its own depth */
            const char *lv = class_field_lval_depth(depth, f->name);
            const Type *ft = f->type;
            /* an untyped property (`pub $cb = null;`) is hval-typed: PHP-style
             * dynamic members must not dereference a NULL type here */
            if (!ft) { line(g, "%s = hp_null;", lv); continue; }
            if (type_is_integral(ft->kind)) line(g, "%s = 0;", lv);
            else if (type_is_numeric(ft->kind)) line(g, "%s = 0.0;", lv);
            else if (ft->kind == TY_BOOL) line(g, "%s = false;", lv);
            else if (ft->kind == TY_STRING) line(g, "%s = hp_null_str();", lv);
            else if (ft->kind == TY_ARRAY || ft->kind == TY_VEC ||
                     ft->kind == TY_MAP || ft->kind == TY_SET)
                line(g, "%s = hp_arr_new();", lv);
            else if (ft->kind == TY_CLASS || ft->kind == TY_STRUCT ||
                     ft->kind == TY_OWN || ft->kind == TY_RC ||
                     ft->kind == TY_INTERFACE || ft->kind == TY_FN)
                line(g, "%s = 0;", lv);   /* pointer slots start null */
            else line(g, "%s = hp_null;", lv);
        }
        /* declared property defaults: `pub int $n = 42;` must actually be 42.
         * The zero pass above has run, so this overwrites it in declaration
         * order — PHP semantics. */
        for (size_t i = 0; i < k->fields.len; i++) {
            StructField *f = k->fields.items[i];
            if (f->is_static || !f->dflt) continue;
            if (f->cls && f->cls != k) continue;
            Buf dv;
            buf_init(&dv);
            /* a pointer-typed slot (`pub Flow $flow = null;`) must stay a NULL
             * C pointer — emitting the hval null constant fails to compile */
            if (f->dflt->kind == EX_NULL && f->type &&
                (f->type->kind == TY_CLASS || f->type->kind == TY_STRUCT ||
                 f->type->kind == TY_OWN || f->type->kind == TY_RC ||
                 f->type->kind == TY_INTERFACE || f->type->kind == TY_FN))
                buf_puts(&dv, "0");
            else if (!f->type || f->type->kind == TY_MIXED) to_hval(g, f->dflt, &dv);
            else emit_to_type(g, f->dflt, f->type, &dv);
            line(g, "%s = %s;", class_field_lval_depth(depth, f->name), buf_take(&dv));
            free(dv.data);
        }
    }
    /* run the user constructor if present (search base classes too — PHP-style
     * constructor inheritance: new Hund("Rex") runs Tier::__construct) */
    AstFn *ctor = class_find_ctor(c);
    if (ctor) {
        if (ctor->cls != c)
            line(g, "/* ctor inherited from %s */", ctor->cls->name);
        line(g, "va_list _ap;");
        line(g, "va_start(_ap, cls);");
        for (size_t i = 0; i < ctor->params.len; i++) {
            Param *pm = ctor->params.items[i];
            const Type *pt = pm->type;
            /* scalar args arrive as int in varargs (C default promotion);
             * floats as double; pointers/strings as their own type */
            const char *vt = "hval";
            if (pt && type_is_integral(pt->kind)) vt = "int";
            else if (pt && (pt->kind == TY_BOOL)) vt = "int";
            else if (pt && type_is_numeric(pt->kind)) vt = "double";
            else if (pt) vt = ctype_of(pt);
            line(g, "%s _a%zu = va_arg(_ap, %s);", pt ? ctype_of(pt) : "hval", i, vt);
            /* store into a local the ctor method can read via its param */
            (void)pm;
        }
        line(g, "va_end(_ap);");
        {
            Buf args;
            buf_init(&args);
            for (size_t i = 0; i < ctor->params.len; i++) {
                if (i) buf_puts(&args, ", ");
                buf_printf(&args, "_a%zu", i);
            }
            line(g, "%s((struct %s*)self%s%s);", mangle_method(ctor->cls, "__construct"),
                 ctor->cls->name, ctor->params.len ? ", " : "", buf_take(&args));
            free(args.data);
        }
    }
    line(g, "return self;");
    g->depth--;
    line(g, "}");
    line(g, "");
    /* virtual dispatch shims for methods overridden in derived classes */
    {
        PtrVec vm = {0};
        class_vmethods(c, &vm);
        for (size_t vi = 0; vi < vm.len; vi++) {
            AstFn *m = vm.items[vi];
            if (!method_overridden(g, m->cls, m)) continue;
            if (!m->cls || m->cls != c) continue;  /* only in the defining class */
            const Type *ret = m->ret ? m->ret : type_new(TY_VOID);
            Buf hdr;
            buf_init(&hdr);
            buf_printf(&hdr, "static %s %s_virt(", ctype_of(ret),
                       mangle_method(m->cls, m->name));
            buf_printf(&hdr, "struct %s* self", c->name);
            bool first2 = true;
            for (size_t i = 0; i < m->params.len; i++) {
                Param *pm = m->params.items[i];
                buf_printf(&hdr, ", %s %s", ctype_of(pm->resolved), var_name(pm->sym));
                (void)first2;
            }
            buf_puts(&hdr, ")");
            line(g, "%s;", buf_take(&hdr));
        }
        free(vm.items);
    }
    line(g, "");
    for (size_t i = 0; i < c->methods.len; i++) {
        AstFn *m = c->methods.items[i];
        if (m->name == intern("__construct")) {
            /* constructor is a normal method returning void */
            emit_fn(g, m);
            continue;
        }
        if (m->is_abstract) continue;
        emit_fn(g, m);
    }
    /* dispatch shim bodies: switch on the runtime class id, then tail-call */
    {
        PtrVec vm = {0};
        class_vmethods(c, &vm);
        for (size_t vi = 0; vi < vm.len; vi++) {
            AstFn *m = vm.items[vi];
            if (!m->cls || m->cls != c) continue;
            if (!method_overridden(g, m->cls, m)) continue;
            const Type *ret = m->ret ? m->ret : type_new(TY_VOID);
            const char *retty = ctype_of(ret);
            Buf hdr;
            buf_init(&hdr);
            buf_printf(&hdr, "static %s %s_virt(", retty,
                       mangle_method(m->cls, m->name));
            buf_printf(&hdr, "struct %s* self", c->name);
            for (size_t i = 0; i < m->params.len; i++) {
                Param *pm = m->params.items[i];
                buf_printf(&hdr, ", %s %s", ctype_of(pm->resolved), var_name(pm->sym));
            }
            buf_puts(&hdr, ") {");
            line(g, "%s", buf_take(&hdr));
            g->depth++;
            for (size_t i = 0; i < g->prog->decls.len; i++) {
                Decl *d = g->prog->decls.items[i];
                if (d->kind != DK_CLASS && d->kind != DK_TRAIT) continue;
                AstClass *k = d->u.cls;
                bool derives = false;
                for (AstClass *b = k->base; b; b = b->base)
                    if (b == c) { derives = true; break; }
                if (!derives) continue;
                AstFn *km = NULL;
                for (size_t j = 0; j < k->methods.len; j++)
                    if (((AstFn *)k->methods.items[j])->name == m->name) { km = k->methods.items[j]; break; }
                if (!km) continue;
                Buf call;
                buf_init(&call);
                buf_printf(&call, "%s((struct %s*)self", mangle_method(k, m->name), k->name);
                for (size_t j = 0; j < m->params.len; j++) {
                    Param *pm = m->params.items[j];
                    buf_printf(&call, ", %s", var_name(pm->sym));
                }
                buf_puts(&call, ")");
                const char *cc = buf_take(&call);
                if (ret->kind == TY_VOID) line(g, "if (self->__cls == hp_cls_%s) { %s; return; }", k->name, cc);
                else line(g, "if (self->__cls == hp_cls_%s) return %s;", k->name, cc);
                free((void *)cc);
            }
            /* default: the defining implementation */
            {
                Buf call;
                buf_init(&call);
                buf_printf(&call, "%s(self", mangle_method(c, m->name));
                for (size_t j = 0; j < m->params.len; j++) {
                    Param *pm = m->params.items[j];
                    buf_printf(&call, ", %s", var_name(pm->sym));
                }
                buf_puts(&call, ")");
                const char *cc = buf_take(&call);
                if (ret->kind == TY_VOID) line(g, "%s;", cc);
                else line(g, "return %s;", cc);
                free((void *)cc);
            }
            g->depth--;
            line(g, "}");
            line(g, "");
        }
        free(vm.items);
    }
}

/* ---------------- top level ---------------- */
static void emit_prelude(Codegen *g) {
    buf_puts(g->out, "/* Generated by hphpc — HolyPHP compiler */\n");
    buf_puts(g->out, "#include <stdint.h>\n#include <stdbool.h>\n#include <string.h>\n");
    buf_puts(g->out, "#include <stdio.h>\n#include <stdlib.h>\n#include <math.h>\n");
    buf_puts(g->out, "#include <setjmp.h>\n#include <stdarg.h>\n");
    buf_puts(g->out, "#include \"hphp_rt.h\"\n\n");
    /* uniform ENV struct for try-body/catch helpers (setjmp lives in the
     * runtime's hp_try_run — generated functions never contain setjmp) */
    buf_puts(g->out, "typedef struct {\n");
    buf_puts(g->out, "    void *self;    /* $this for methods/closures */\n");
    buf_puts(g->out, "    hval ret;      /* return value (act == 1) */\n");
    buf_puts(g->out, "    int act;       /* 0 normal, 1 return, 2 break, 3 continue */\n");
    buf_puts(g->out, "    void *vp[64];  /* pointers to the caller's captured locals */\n");
    buf_puts(g->out, "} T_env;\n\n");
}

/* ---- closure discovery: walk all bodies collecting EX_CLOSURE nodes ---- */
static void cg_visit_expr(PtrVec *out, Expr *e);
static void cg_visit_stmt(PtrVec *out, Stmt *s);

static void cg_visit_expr(PtrVec *out, Expr *e) {
    if (!e) return;
    if (e->kind == EX_CLOSURE) {
        AstFn *dfn = e->u.closure.fn;
        bool dknown = false;
        for (size_t i = 0; i < out->len; i++)
            if (out->items[i] == dfn) { dknown = true; break; }
        if (!dknown) {
            ptrvec_push(out, dfn);
            /* NESTED closures: walk the body so closures defined inside
             * this closure are discovered too (their prototypes must come
             * before any body that instantiates them) */
            if (dfn) {
                for (size_t i = 0; i < dfn->body.len; i++)
                    cg_visit_stmt(out, dfn->body.items[i]);
            }
        }
        return;
    }
    switch (e->kind) {
    case EX_TPL:
        for (size_t i = 0; i < e->u.tpl.exprs.len; i++)
            cg_visit_expr(out, e->u.tpl.exprs.items[i]);
        break;
    case EX_INDEX:
        cg_visit_expr(out, e->u.index.obj);
        cg_visit_expr(out, e->u.index.idx);
        break;
    case EX_FIELD: cg_visit_expr(out, e->u.field.obj); break;
    case EX_CALL:
        cg_visit_expr(out, e->u.call.fn);
        for (size_t i = 0; i < e->u.call.args.len; i++)
            cg_visit_expr(out, e->u.call.args.items[i]);
        break;
    case EX_METHOD:
        cg_visit_expr(out, e->u.method.obj);
        for (size_t i = 0; i < e->u.method.args.len; i++)
            cg_visit_expr(out, e->u.method.args.items[i]);
        break;
    case EX_STATIC:
        for (size_t i = 0; i < e->u.staticcall.args.len; i++)
            cg_visit_expr(out, e->u.staticcall.args.items[i]);
        break;
    case EX_NEW:
        for (size_t i = 0; i < e->u.newexpr.args.len; i++)
            cg_visit_expr(out, e->u.newexpr.args.items[i]);
        break;
    case EX_BIN:
        cg_visit_expr(out, e->u.bin.l);
        cg_visit_expr(out, e->u.bin.r);
        break;
    case EX_UN: cg_visit_expr(out, e->u.un.operand); break;
    case EX_ASSIGN:
        cg_visit_expr(out, e->u.assign.target);
        cg_visit_expr(out, e->u.assign.value);
        break;
    case EX_TERNARY:
        cg_visit_expr(out, e->u.tern.cond);
        cg_visit_expr(out, e->u.tern.then);
        cg_visit_expr(out, e->u.tern.els);
        break;
    case EX_MATCH:
        cg_visit_expr(out, e->u.matchexpr.subject);
        for (size_t i = 0; i < e->u.matchexpr.cases.len; i++) {
            MatchCase *mc = e->u.matchexpr.cases.items[i];
            for (size_t j = 0; j < mc->patterns.len; j++)
                cg_visit_expr(out, mc->patterns.items[j]);
            cg_visit_expr(out, mc->body);
        }
        if (e->u.matchexpr.dflt) cg_visit_expr(out, e->u.matchexpr.dflt);
        break;
    case EX_ARRAY_LIT:
        for (size_t i = 0; i < e->u.arr.elems.len; i++)
            cg_visit_expr(out, e->u.arr.elems.items[i]);
        break;
    case EX_MAP_LIT:
        for (size_t i = 0; i < e->u.map.keys.len; i++) {
            cg_visit_expr(out, e->u.map.keys.items[i]);
            cg_visit_expr(out, e->u.map.vals.items[i]);
        }
        break;
    case EX_TUPLE_LIT:
        for (size_t i = 0; i < e->u.tuple.elems.len; i++)
            cg_visit_expr(out, e->u.tuple.elems.items[i]);
        break;
    case EX_BORROW: case EX_MUTBORROW:
        cg_visit_expr(out, e->u.borrow.operand);
        break;
    case EX_DEREF: cg_visit_expr(out, e->u.deref.operand); break;
    case EX_CAST: cg_visit_expr(out, e->u.cast.operand); break;
    case EX_IS: cg_visit_expr(out, e->u.ischeck.operand); break;
    case EX_ELLIPSIS: cg_visit_expr(out, e->u.ellipsis.inner); break;
    default: break;
    }
}

static void cg_visit_stmt(PtrVec *out, Stmt *s) {
    if (!s) return;
    switch (s->kind) {
    case ST_EXPR: cg_visit_expr(out, s->u.expr.expr); break;
    case ST_LET: if (s->u.let.init) cg_visit_expr(out, s->u.let.init); break;
    case ST_RETURN: cg_visit_expr(out, s->u.ret.value); break;
    case ST_ECHO:
        for (size_t i = 0; i < s->u.echo.exprs.len; i++)
            cg_visit_expr(out, s->u.echo.exprs.items[i]);
        break;
    case ST_PRINT: cg_visit_expr(out, s->u.print.expr); break;
    case ST_IF:
        cg_visit_expr(out, s->u.if_.cond);
        for (size_t i = 0; i < s->u.if_.then.len; i++)
            cg_visit_stmt(out, s->u.if_.then.items[i]);
        for (size_t i = 0; i < s->u.if_.els.len; i++)
            cg_visit_stmt(out, s->u.if_.els.items[i]);
        break;
    case ST_WHILE:
        cg_visit_expr(out, s->u.while_.cond);
        for (size_t i = 0; i < s->u.while_.body.len; i++)
            cg_visit_stmt(out, s->u.while_.body.items[i]);
        break;
    case ST_FOR:
        for (size_t i = 0; i < s->u.for_.init.len; i++)
            cg_visit_stmt(out, s->u.for_.init.items[i]);
        cg_visit_expr(out, s->u.for_.cond);
        for (size_t i = 0; i < s->u.for_.step.len; i++)
            cg_visit_stmt(out, s->u.for_.step.items[i]);
        for (size_t i = 0; i < s->u.for_.body.len; i++)
            cg_visit_stmt(out, s->u.for_.body.items[i]);
        break;
    case ST_FOREACH:
        cg_visit_expr(out, s->u.foreach.iter);
        for (size_t i = 0; i < s->u.foreach.body.len; i++)
            cg_visit_stmt(out, s->u.foreach.body.items[i]);
        break;
    case ST_BLOCK:
        for (size_t i = 0; i < s->u.block.stmts.len; i++)
            cg_visit_stmt(out, s->u.block.stmts.items[i]);
        break;
    case ST_UNSAFE_BLOCK:
        for (size_t i = 0; i < s->u.unsafe.stmts.len; i++)
            cg_visit_stmt(out, s->u.unsafe.stmts.items[i]);
        break;
    case ST_TRY:
        for (size_t i = 0; i < s->u.try.body.len; i++)
            cg_visit_stmt(out, s->u.try.body.items[i]);
        for (size_t i = 0; i < s->u.try.catches.len; i++) {
            CatchClause *cc = s->u.try.catches.items[i];
            for (size_t j = 0; j < cc->body.len; j++)
                cg_visit_stmt(out, cc->body.items[j]);
        }
        for (size_t i = 0; i < s->u.try.fin.len; i++)
            cg_visit_stmt(out, s->u.try.fin.items[i]);
        break;
    case ST_THROW: cg_visit_expr(out, s->u.throw.expr); break;
    default: break;
    }
}

static void collect_closure_walk_fn(PtrVec *out, AstFn *fn) {
    for (size_t i = 0; i < fn->body.len; i++)
        cg_visit_stmt(out, fn->body.items[i]);
}

void codegen_emit(Program *prog, Buf *out) {
    Codegen g = {0};
    g.out = out;
    g.prog = prog;
    s_this = intern("this");
    s_argc = intern("argc");
    s_argv = intern("argv");
    s_php_int_max = intern("PHP_INT_MAX");          s_php_int_min = intern("PHP_INT_MIN");
    s_php_int_size = intern("PHP_INT_SIZE");        s_php_int_digits = intern("PHP_INT_DIGITS");
    s_php_float_epsilon = intern("PHP_FLOAT_EPSILON");
    s_php_euler = intern("PHP_EULER");              s_php_pi = intern("PHP_PI");
    s_m_pi = intern("M_PI");                        s_m_e = intern("M_E");
    s_php_round_half_up = intern("PHP_ROUND_HALF_UP");     s_php_round_half_down = intern("PHP_ROUND_HALF_DOWN");
    s_php_round_half_even = intern("PHP_ROUND_HALF_EVEN"); s_php_round_half_odd = intern("PHP_ROUND_HALF_ODD");
    s_php_os = intern("PHP_OS");                    s_php_eol = intern("PHP_EOL");
    s_php_version = intern("PHP_VERSION");          s_php_sapi = intern("PHP_SAPI");
    s_php_uname = intern("PHP_UNAME");
    s_php_bool_true = intern("PHP_TRUE");           s_php_bool_false = intern("PHP_FALSE");
    s_json_pretty_print = intern("JSON_PRETTY_PRINT");
    s_json_unescaped_slashes = intern("JSON_UNESCAPED_SLASHES");
    s_json_numeric_check = intern("JSON_NUMERIC_CHECK");
    s_json_force_object = intern("JSON_FORCE_OBJECT");
    s_php_null = intern("PHP_NULL");
    s_php_file_append = intern("PHP_FILE_APPEND");
    s_php_file_ignore_new_lines = intern("PHP_FILE_IGNORE_NEW_LINES");
    s_php_file_skip_empty_lines = intern("PHP_FILE_SKIP_EMPTY_LINES");
    s_php_file_use_include_path = intern("PHP_FILE_USE_INCLUDE_PATH");
    for (int tb = 0; tb < 8; tb++)
        buf_init(&g.try_bufs[tb]); /* file-scope try-helper defs, flushed at EOF */

    bool have_user_main = false;
    for (size_t i = 0; i < prog->decls.len; i++) {
        Decl *d = prog->decls.items[i];
        if (d->kind == DK_FN && d->u.fn->name == intern("main")) have_user_main = true;
    }

    /* 1) discover closures in functions, methods and top-level statements */
    for (size_t i = 0; i < prog->decls.len; i++) {
        Decl *d = prog->decls.items[i];
        if (d->kind == DK_FN)
            collect_closure_walk_fn(&g.closures, d->u.fn);
        else if (d->kind == DK_CLASS || d->kind == DK_TRAIT || d->kind == DK_INTERFACE) {
            AstClass *c = d->u.cls;
            for (size_t j = 0; j < c->methods.len; j++)
                collect_closure_walk_fn(&g.closures, c->methods.items[j]);
        }
    }
    for (size_t i = 0; i < prog->stmts.len; i++)
        cg_visit_stmt(&g.closures, prog->stmts.items[i]);
    for (size_t i = 0; i < g.closures.len; i++) {
        for (size_t j = i + 1; j < g.closures.len; ) {
            if (g.closures.items[j] == g.closures.items[i]) {
                memmove(&g.closures.items[j], &g.closures.items[j + 1],
                        (g.closures.len - j - 1) * sizeof(void *));
                g.closures.len--;
            } else j++;
        }
    }

    emit_prelude(&g);

    /* forward decls of structs so methods can reference classes mutually */
    for (size_t i = 0; i < prog->decls.len; i++) {
        Decl *d = prog->decls.items[i];
        if (d->kind == DK_CLASS || d->kind == DK_INTERFACE || d->kind == DK_TRAIT)
            line(&g, "struct %s;", d->u.cls->name);
    }
    /* runtime class ids for virtual dispatch */
    {
        Buf e;
        buf_init(&e);
        buf_puts(&e, "enum {");
        bool first = true;
        for (size_t i = 0; i < prog->decls.len; i++) {
            Decl *d = prog->decls.items[i];
            if (d->kind != DK_CLASS && d->kind != DK_TRAIT) continue;
            buf_printf(&e, "%shp_cls_%s = %zu", first ? " " : ", ", d->u.cls->name, i);
            first = false;
        }
        buf_puts(&e, " };");
        if (!first) line(&g, "%s", buf_take(&e));
        else { free(e.data); }
    }
    line(&g, "");

    /* 2) prototypes for functions & methods (so call order never matters) */
    /* 1c) file-scope storage for `global $x;` variables — collect the shared
     * VarSyms from every ST_GLOBAL stmt anywhere in the program. */
    {
        PtrVec gsyms = {0};
        for (size_t i = 0; i < prog->decls.len; i++) {
            Decl *d = prog->decls.items[i];
            if (d->kind == DK_FN)
                for (size_t b = 0; b < d->u.fn->body.len; b++)
                    collect_globals_stmt(&gsyms, d->u.fn->body.items[b]);
            else if (d->kind == DK_CLASS || d->kind == DK_TRAIT) {
                AstClass *c = d->u.cls;
                for (size_t j = 0; j < c->methods.len; j++) {
                    AstFn *m = (AstFn *)c->methods.items[j];
                    for (size_t b = 0; b < m->body.len; b++)
                        collect_globals_stmt(&gsyms, m->body.items[b]);
                }
            }
        }
        for (size_t i = 0; i < prog->stmts.len; i++)
            collect_globals_stmt(&gsyms, prog->stmts.items[i]);
        for (size_t i = 0; i < gsyms.len; i++) {
            VarSym *v = gsyms.items[i];
            bool seen = false;
            for (size_t j = 0; j < i; j++)
                if (gsyms.items[j] == v) { seen = true; break; }
            if (seen) continue;
            line(&g, "static %s %s;   /* global $%s */", ctype_of(v->type),
                 var_name(v), v->name ? v->name : "?");
        }
        if (gsyms.len) line(&g, "");
        free(gsyms.items);
    }
    line(&g, "static int hp_argc;        /* PHP superglobal $argc */");
    line(&g, "static harr *hp_argv;    /* PHP superglobal $argv */");
    g_emit_bodies = false;
    for (size_t i = 0; i < prog->decls.len; i++) {
        Decl *d = prog->decls.items[i];
        if (d->kind == DK_FN) emit_fn(&g, d->u.fn);
    }
    for (size_t i = 0; i < prog->decls.len; i++) {
        Decl *d = prog->decls.items[i];
        if (d->kind == DK_CLASS || d->kind == DK_INTERFACE || d->kind == DK_TRAIT) {
            AstClass *c = d->u.cls;
            for (size_t j = 0; j < c->methods.len; j++) {
                AstFn *m = c->methods.items[j];
                if (m->is_abstract) continue;
                emit_fn(&g, m);
            }
        }
    }
    g_emit_bodies = true;
    line(&g, "");

    /* 2a) prototypes for the constructor shims — class bodies and methods
     * reference each other's `X_new_args` regardless of declaration order */
    for (size_t i = 0; i < prog->decls.len; i++) {
        Decl *d = prog->decls.items[i];
        if (d->kind == DK_CLASS || d->kind == DK_INTERFACE || d->kind == DK_TRAIT)
            line(&g, "static struct %s* %s_new_args(const char* cls, ...);",
                 d->u.cls->name, d->u.cls->name);
    }
    line(&g, "");

    /* 2b) prototypes for closures discovered while emitting the function
     * prototypes above (emit_fn bodies are off, but registration happens at
     * EX_CLOSURE sites inside method prototypes too). */
    for (size_t i = 0; i < g.closures.len; i++)
        emit_closure_prototype(&g, g.closures.items[i]);

    /* 3) struct + class definitions, then closure definitions */
    g_structs_emitted = false;
    for (size_t i = 0; i < prog->decls.len; i++) {
        Decl *d = prog->decls.items[i];
        if (d->kind == DK_CLASS || d->kind == DK_INTERFACE || d->kind == DK_TRAIT)
            emit_struct(&g, d->u.cls);
    }
    g_structs_emitted = true;
    for (size_t i = 0; i < prog->decls.len; i++) {
        Decl *d = prog->decls.items[i];
        if (d->kind == DK_CLASS || d->kind == DK_INTERFACE || d->kind == DK_TRAIT)
            emit_class(&g, d->u.cls);
    }
    for (size_t i = 0; i < g.closures.len; i++)
        emit_closure(&g, g.closures.items[i]);
    for (size_t i = 0; i < prog->decls.len; i++) {
        Decl *d = prog->decls.items[i];
        if (d->kind == DK_FN) emit_fn(&g, d->u.fn);
    }
    /* 3b) prototypes for closures discovered while emitting free-function
     * bodies in step 3 — a body can reference a closure defined later only
     * if the prototype precedes it, so emit these right after the bodies. */
    for (size_t i = 0; i < g.closures.len; i++)
        emit_closure_prototype(&g, g.closures.items[i]);

    /* 3c) superglobal prototypes before hp_main */
    line(&g, "harr *hp_argv_from_c(int argc, char **argv);");

    /* 4) top-level main */
    line(&g, "static int hp_main(void) {");
    g.depth++;
    /* hoisted declarations for top-level PHP-style variables */
    {
        PtrVec syms = {0};
        for (size_t i = 0; i < prog->stmts.len; i++)
            collect_syms_stmt(&syms, prog->stmts.items[i]);
        for (size_t i = 0; i < syms.len; i++) {
            VarSym *v = syms.items[i];
            if (!v->is_auto || v->is_param) continue;
            if (is_global_alias(v)) continue;   /* file-scope storage */
            if (v->is_program_global) continue; /* file-scope storage */
            bool seen = false;
            for (size_t j = 0; j < i; j++)
                if (syms.items[j] == v) { seen = true; break; }
            if (seen) continue;
            if (v->captured_byref) {
                /* program-global by-ref capture: alias the file-scope static
                 * (plain locals get a fresh heap box) */
                if (v->is_program_global)
                    line(&g, "hval *%s = &%s;", var_name(v), var_name(v));
                else
                    line(&g, "hval *%s = hp_box_new();", var_name(v));
            } else {
                line(&g, "%s %s = %s;", ctype_of(v->type),
                     var_name(v), zero_init_decl_of(v->type));
            }
        }
    }
    /* initialize `global $x;` storage (hval slots need a runtime null) */
    {
        PtrVec gsyms = {0};
        for (size_t i = 0; i < prog->decls.len; i++) {
            Decl *d = prog->decls.items[i];
            if (d->kind == DK_FN)
                for (size_t b = 0; b < d->u.fn->body.len; b++)
                    collect_globals_stmt(&gsyms, d->u.fn->body.items[b]);
            else if (d->kind == DK_CLASS || d->kind == DK_TRAIT) {
                AstClass *c = d->u.cls;
                for (size_t j = 0; j < c->methods.len; j++) {
                    AstFn *m = (AstFn *)c->methods.items[j];
                    for (size_t b = 0; b < m->body.len; b++)
                        collect_globals_stmt(&gsyms, m->body.items[b]);
                }
            }
        }
        for (size_t i = 0; i < prog->stmts.len; i++)
            collect_globals_stmt(&gsyms, prog->stmts.items[i]);
        for (size_t i = 0; i < gsyms.len; i++) {
            VarSym *v = gsyms.items[i];
            bool seen = false;
            for (size_t j = 0; j < i; j++)
                if (gsyms.items[j] == v) { seen = true; break; }
            if (seen) continue;
            const char *zi = zero_init_of(v->type);
            if (strcmp(zi, "0") != 0)
                line(&g, "%s = %s;", var_name(v), zi);
            else if (v->type && v->type->kind == TY_ARRAY)
                line(&g, "%s = hp_of_arr(hp_arr_new());", var_name(v));
        }
        free(gsyms.items);
    }
    emit_block(&g, prog->stmts);
    line(&g, "return 0;");
    g.depth--;
    line(&g, "}");
    line(&g, "");
    line(&g, "int main(int argc, char** argv) {");
    g.depth++;
    line(&g, "hp_argc = argc;");
    line(&g, "hp_argv = hp_argv_from_c(argc, argv);");
    line(&g, "extern harr *hp_argv_from_c(int argc, char **argv);");
    line(&g, "hp_init();");
    line(&g, "int _rc = hp_main();");
    line(&g, "hp_shutdown();");
    line(&g, "return _rc;");
    g.depth--;
    line(&g, "}");

    /* try/catch helper definitions collected while emitting bodies. They are
     * declared at every call site via block-scope extern prototypes, so
     * emitting them last is fine (and keeps #define aliases from leaking). */
    for (int tb = 0; tb < 8; tb++) {
        if (g.try_bufs[tb].len) {
            buf_write(out, g.try_bufs[tb].data ? g.try_bufs[tb].data : "",
                      g.try_bufs[tb].len);
            buf_puts(out, "\n");
        }
    }
}
