/* builtins.h — PHP-compatible standard library function signatures.
 *
 * HolyPHP ships the familiar PHP functions compiled into the runtime.
 * The table below gives sema the argument/return contracts it needs.
 */
#ifndef HPHPC_BUILTINS_H
#define HPHPC_BUILTINS_H

#include "util.h"
#include "ast.h"

typedef enum {
    B_STR1,          /* string -> string */
    B_ZERO,          /* () -> value (e.g. getcwd) */
    B_STR2,          /* (string, string) -> string */
    B_INT_STR,       /* (int, string) -> string */
    B_STR_INT,       /* (string) -> int */
    B_LEN,           /* mixed -> int (strlen/count) */
    B_CMP,           /* (string, string) -> int */
    B_PRINT,         /* variadic print */
    B_ARRAY,         /* variadic -> array */
    B_MAXMIN,        /* variadic numeric -> mixed */
    B_ABS,           /* mixed -> mixed */
    B_INT_INT,       /* (int) -> int */
    B_JSON,          /* mixed -> string */
    B_SPLIT,         /* (string, string) -> array */
    B_JOIN,          /* (array|string glue, mixed) -> string */
    B_KEYS,          /* array -> array */
    B_VALUES,        /* array -> array */
    B_SORTISH,       /* array -> array */
    B_RANGE,         /* (int, int) -> array */
    B_SORT,          /* array in-place -> bool */
    B_MISC,          /* anything; checked loosely */
} BuiltinShape;

typedef struct Builtin {
    const char *name;
    BuiltinShape shape;
    const Type *ret;
    bool unsafe;               /* callable only inside unsafe */
    bool variadic;
} Builtin;

const Builtin *builtin_lookup(const char *name);
void builtins_init(void);      /* create shared Type singletons */

/* shared primitive type singletons */
extern Type *ty_int, *ty_i8, *ty_i16, *ty_i32, *ty_i64,
    *ty_float, *ty_f32, *ty_f64, *ty_bool, *ty_string, *ty_void, *ty_mixed,
    *ty_null, *ty_false;
Type *type_array_of(const Type *elem);

#endif
