/* ast.h — HolyPHP abstract syntax tree.
 *
 * An Expr carries its Token start (for diagnostics) and, after semantic
 * analysis, its Type. Stmt nodes cover PHP-style statements plus HolyPHP
 * specifics (let/mut/own bindings, unsafe blocks, borrow expressions).
 */
#ifndef HPHPC_AST_H
#define HPHPC_AST_H

#include "token.h"

typedef struct Type Type;
typedef struct EnumCase EnumCase;
typedef struct StructField StructField;
typedef struct Param Param;
typedef struct AstFn AstFn;
typedef struct AstClass AstClass;

/* ---- Types ---- */
typedef enum {
    TY_ERROR = 0,
    TY_INT, TY_I8, TY_I16, TY_I32, TY_I64,
    TY_FLOAT, TY_F32, TY_F64,
    TY_BOOL, TY_STRING, TY_VOID, TY_MIXED,
    TY_ARRAY,      /* .elem   : value array (COW), PHP-like */
    TY_VEC,        /* .elem   : mutable Vec<T> */
    TY_MAP,        /* .key/.val : Map<K,V> */
    TY_SET,        /* .elem : Set<T> */
    TY_REF,        /* .elem   : &T borrow */
    TY_MUTREF,     /* .elem   : &mut T borrow */
    TY_PTR,        /* .elem   : raw pointer (unsafe only) */
    TY_OWN,        /* .elem   : owned smart pointer (unique) */
    TY_RC,         /* .elem   : shared smart pointer (refcounted) */
    TY_STRUCT, TY_CLASS, TY_INTERFACE, TY_ENUM,
    TY_FN,         /* function type */
    TY_TUPLE,
    TY_OPTION,     /* Option<T> */
    TY_RESULT,     /* Result<T,E> */
    TY_NULL,       /* the null type */
    TY_NULLABLE,   /* ?T - T or null (.elem = T) */
    TY_UNION,      /* A|B (.members) */
    TY_SELF,
} TypeKind;

struct Type {
    TypeKind kind;
    /* 0 = ordinary bool, 1 = singleton false, 2 = singleton true.
     * Used internally for precise PHP builtin unions such as int|false. */
    uint8_t bool_const;
    const Type *elem, *key, *val;
    const Type *ok, *err;      /* Result */
    const char *name;          /* struct/class/interface/enum */
    AstClass *decl;            /* declaration, for nominal types */
    /* union members (TY_UNION) */
    const Type **members;
    size_t nmembers;
    /* function types */
    struct { const Type **params; size_t nparams; const Type *ret; bool variadic; } fn;
};

/* A nullable/union type is stored as an hval slot: the tag says whether the
 * value is there, the payload carries it. `?T` is the two-member union
 * {T, null}; TY_UNION is the general case. */
bool type_is_nullable(TypeKind k);
bool type_is_union(TypeKind k);
/* the type of a union with its null member removed (TY_NULLABLE -> T) */
const Type *type_without_null(const Type *t);
/* the type left after dropping one member (TY_NULL for the null itself) */
const Type *type_without_member(const Type *t, TypeKind drop);
/* do two types name the same member? (the kind, plus the name for the named
 * ones: Widget and Gadget are both classes, but not the same member) */
bool type_same_member(const Type *a, const Type *b);
/* the type left after dropping one member, matched by the member itself:
 * `Widget|Gadget` without `Widget` is `Gadget`, not an empty union */
const Type *type_without_type(const Type *t, const Type *drop);

bool type_is_ref(TypeKind k);
bool type_is_numeric(TypeKind k);
bool type_is_integral(TypeKind k);
bool type_is_pointerish(TypeKind k); /* ref/mutref/ptr */
bool type_is_smart_ptr(TypeKind k);  /* own/rc */
bool type_is_value(TypeKind k);      /* int/float/bool/enum */
const char *type_kind_name(TypeKind k);
char *type_to_string(const Type *t);

/* ---- Expressions ---- */
typedef enum {
    EX_INT, EX_FLOAT, EX_STR, EX_TPL, EX_BOOL, EX_NULL,
    EX_VAR, EX_INDEX, EX_FIELD, EX_CALL, EX_METHOD, EX_STATIC,
    EX_NEW, EX_BIN, EX_UN, EX_ASSIGN, EX_TERNARY, EX_MATCH, EX_CLOSURE,
    EX_ARRAY_LIT, EX_MAP_LIT, EX_TUPLE_LIT,
    EX_BORROW, EX_MUTBORROW, EX_DEREF,
    EX_CAST, EX_IS, EX_ELLIPSIS,
} ExprKind;

typedef struct Expr Expr;
typedef struct Stmt Stmt;
typedef struct MatchCase MatchCase;

struct Expr {
    ExprKind kind;
    Token tok;
    const Type *type;          /* filled by sema */
    bool is_stmt_value;        /* discardable result */
    union {
        struct { long long ival; } i;
        struct { double fval; } f;
        struct { const char *s; } str;
        struct { PtrVec strs; PtrVec exprs; } tpl;   /* const char* / Expr* */
        struct { bool b; } boolean;
        struct { const char *name; void *sym; bool is_global; bool bare_name; } var;
        struct { Expr *obj; Expr *idx; } index;
        struct { Expr *obj; const char *name; Token name_tok; void *sf; AstClass *vcls; const Type *owner; int case_index; bool is_static; } field;
        struct { Expr *fn; PtrVec args; AstFn *target; } call;
        struct { Expr *obj; const char *name; Token name_tok; PtrVec args; AstFn *target; void *msig; void *sf; } method;
        struct { const char *cls; const char *name; PtrVec args; AstFn *target; AstClass *cls_res; } staticcall;
        struct { const char *cls; PtrVec args; AstClass *cls_res; } newexpr;
        struct { Token op; Expr *l, *r; Expr *slice_hi; } bin;
        struct { Token op; Expr *operand; bool postfix; } un;
        struct { Token op; Expr *target; Expr *value; Type *ann; } assign;
        struct { Expr *cond, *then, *els; } tern;
        struct { Expr *subject; PtrVec cases; Expr *dflt; } matchexpr;
        struct { AstFn *fn; } closure;
        struct { PtrVec elems; } arr;                /* Expr* */
        struct { PtrVec keys, vals; } map;           /* Expr*, Expr* */
        struct { PtrVec elems; } tuple;              /* Expr* */
        struct { Expr *operand; } borrow;
        struct { Expr *operand; } deref;
        struct { const Type *to; Expr *operand; Token ty_tok; } cast;
        struct { const Type *to; Expr *operand; Token ty_tok; } ischeck;
        struct { Expr *inner; } ellipsis;            /* spread in calls */
    } u;
    /* expression-external flags */
    bool is_slice;        /* EX_BIN used as slice a[lo..hi] */
    bool is_nullcoal;     /* EX_BIN ?? */
    bool discard;         /* result unused (sema) */
    const char *builtin;  /* builtin call name (EX_CALL/EX_METHOD/EX_STATIC) */
};

/* ---- Statements ---- */
typedef enum {
    ST_EXPR, ST_LET, ST_RETURN, ST_ECHO, ST_PRINT,
    ST_IF, ST_WHILE, ST_FOR, ST_FOREACH,
    ST_BREAK, ST_CONTINUE,
    ST_BLOCK, ST_UNSAFE_BLOCK, ST_GLOBAL,
    ST_TRY, ST_THROW, ST_SWITCH, ST_DO,
} StmtKind;

struct Stmt {
    StmtKind kind;
    Token tok;
    union {
        struct { Expr *expr; bool discard; } expr;
        struct { const char *name; bool is_mut, is_own; Expr *init; Type *ann; Token name_tok; void *sym; } let;
        struct { Expr *value; } ret;
        struct { PtrVec exprs; } echo; /* Expr* */
        struct { Expr *expr; } print;
        struct { Expr *cond; PtrVec then; PtrVec els; } if_;   /* Stmt* */
        struct { Expr *cond; PtrVec body; } while_;
        struct { PtrVec init; Expr *cond; PtrVec step; PtrVec body; } for_;
        struct { const char *var; const char *kvar; Expr *iter; PtrVec body; Token var_tok; void *vsym; void *ksym; } foreach;
        struct { int depth; } brk;
        struct { PtrVec stmts; } block;
        struct { PtrVec stmts; } unsafe;
        struct { PtrVec names; PtrVec toks; PtrVec syms; } globals; /* const char* + Token* + VarSym* */
        struct { PtrVec body; PtrVec catches; PtrVec fin; } try;
        struct { Expr *expr; } throw;
        struct { Expr *cond; PtrVec cases; } switch_;   /* SwitchCase* */
        struct { Expr *cond; PtrVec body; } do_;
    } u;
};
typedef struct SwitchCase {
    PtrVec patterns;           /* Expr*; empty => default arm */
    PtrVec body;               /* Stmt* */
    bool is_default;
} SwitchCase;

typedef struct CatchClause {
    const Type *type;          /* may be NULL: catch any */
    const char *var;
    Token var_tok;
    PtrVec body;
    void *sym;                 /* VarSym* (sema) */
} CatchClause;

/* ---- Declarations ---- */
struct Param {
    const char *name;
    Type *type;                /* may be NULL -> inferred */
    bool by_ref, is_mut, is_own, variadic;
    Expr *dflt;
    Token name_tok;
    const Type *resolved;      /* sema */
    void *sym;                 /* VarSym* (sema) */
};

struct MatchCase {
    PtrVec patterns;           /* Expr*; empty => default arm */
    Expr *body;
};

typedef enum { VIS_PUBLIC, VIS_PRIVATE, VIS_PROTECTED } Vis;

struct StructField {
    const char *name;
    Type *type;
    Vis vis;
    bool is_mut, is_static;
    Expr *dflt;
    Token name_tok;
    size_t index;              /* position in struct */
    AstClass *cls;             /* defining class (sema) — for inherited fields */
};

struct AstFn {
    const char *name;
    Token name_tok;
    PtrVec params;             /* Param* */
    PtrVec use_vars;           /* Param* — PHP use() captures (closure) */
    Type *ret;                 /* may be NULL */
    bool ret_inferred;         /* sema: no return type written, inferred */
    PtrVec body;               /* Stmt* */
    bool is_method, is_static, is_abstract, is_pub;
    bool is_closure, is_unsafe, is_ctor;
    bool proto_emitted;        /* codegen: closure prototype already printed */
    Vis vis;
    AstClass *cls;
    const Type *ftype;         /* filled by sema */
    PtrVec captures;           /* VarSym* — closure captures (sema) */
    void *this_sym;            /* VarSym* of implicit $this (sema) */
    bool uses_this;
    AstClass *owner_cls;       /* closures: class of the enclosing method */
};

typedef struct AstClass {
    const char *name;
    Token name_tok;
    const char *extends;       /* name of base class or NULL */
    PtrVec interfaces;         /* const char* */
    PtrVec fields;             /* StructField* */
    PtrVec methods;            /* AstFn* */
    bool is_interface, is_trait, is_struct;
    AstClass *base;            /* resolved */
} AstClass;

struct EnumCase {
    const char *name;
    Token name_tok;
    Expr *value;               /* optional backing value */
    long long ival;
    bool has_value;
    size_t index;
};

typedef struct AstEnum {
    const char *name;
    Token name_tok;
    Type *backing;             /* int/string */
    PtrVec cases;              /* EnumCase* */
} AstEnum;

typedef enum { DK_FN, DK_CLASS, DK_TRAIT, DK_INTERFACE, DK_ENUM, DK_STRUCT } DeclKind;

typedef struct Decl {
    DeclKind kind;
    Token tok;
    Vis vis;
    union {
        AstFn *fn;
        AstClass *cls;
        AstEnum *enm;
    } u;
    const char *name;
} Decl;

typedef struct Import {
    const char *path;          /* as written, without quotes */
    Token tok;
} Import;

typedef struct Program {
    PtrVec imports;            /* Import* */
    PtrVec decls;              /* Decl* */
    PtrVec stmts;              /* top-level Stmt* */
    const char *file;
} Program;

/* constructors (parser) */
Expr *expr_new(ExprKind k, Token tok);
Stmt *stmt_new(StmtKind k, Token tok);
Type *type_new(TypeKind k);

#endif
