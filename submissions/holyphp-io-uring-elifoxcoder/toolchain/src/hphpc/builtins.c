/* builtins.c — PHP-compatible standard library function table. */
#include "builtins.h"

Type *ty_int, *ty_i8, *ty_i16, *ty_i32, *ty_i64,
    *ty_float, *ty_f32, *ty_f64, *ty_bool, *ty_string, *ty_void, *ty_mixed,
    *ty_null, *ty_false;
static Type *ty_int_false;

static Builtin *tbl = NULL;
static size_t tbl_len = 0, tbl_cap = 0;

Type *type_array_of(const Type *elem) {
    Type *t = type_new(TY_ARRAY);
    t->elem = elem;
    return t;
}

static void add(const char *name, BuiltinShape shape, const Type *ret,
                bool unsafe, bool variadic) {
    if (tbl_len == tbl_cap) {
        tbl_cap = tbl_cap ? tbl_cap * 2 : 64;
        tbl = xrealloc(tbl, tbl_cap * sizeof(Builtin));
    }
    tbl[tbl_len++] = (Builtin){ intern(name), shape, ret, unsafe, variadic };
}

void builtins_init(void) {
    if (ty_int) return;
    ty_int = type_new(TY_INT);
    ty_i8 = type_new(TY_I8); ty_i16 = type_new(TY_I16);
    ty_i32 = type_new(TY_I32); ty_i64 = type_new(TY_I64);
    ty_float = type_new(TY_FLOAT); ty_f32 = type_new(TY_F32); ty_f64 = type_new(TY_F64);
    ty_bool = type_new(TY_BOOL);
    ty_string = type_new(TY_STRING);
    ty_void = type_new(TY_VOID);
    ty_mixed = type_new(TY_MIXED);
    ty_null = type_new(TY_NULL);
    ty_false = type_new(TY_BOOL);
    ty_false->bool_const = 1;
    ty_int_false = type_new(TY_UNION);
    ty_int_false->nmembers = 2;
    ty_int_false->members = xmalloc(sizeof(Type *) * 2);
    ((Type **)ty_int_false->members)[0] = ty_int;
    ((Type **)ty_int_false->members)[1] = ty_false;

    /* PHP string functions */
    add("strlen",        B_LEN,     ty_int,    false, false);
    add("count",         B_LEN,     ty_int,    false, false);
    add("sizeof",        B_LEN,     ty_int,    false, false);
    add("strtoupper",    B_STR1,    ty_string, false, false);
    add("strtolower",    B_STR1,    ty_string, false, false);
    add("ucfirst",       B_STR1,    ty_string, false, false);
    add("lcfirst",       B_STR1,    ty_string, false, false);
    add("trim",          B_STR1,    ty_string, false, false);
    add("ltrim",         B_MISC,    ty_string, false, false);
    add("rtrim",         B_MISC,    ty_string, false, false);
    add("chop",          B_STR1,    ty_string, false, false);
    add("strrev",        B_STR1,    ty_string, false, false);
    add("str_repeat",    B_INT_STR, ty_string, false, false);
    add("str_pad",       B_MISC,    ty_string, false, false);
    add("str_replace",   B_MISC,    ty_string, false, false);
    add("substr",        B_MISC,    ty_string, false, false);
    add("strstr",        B_STR2,    ty_mixed,  false, false);   /* string|false, PHP-style */
    add("strchr",        B_STR2,    ty_mixed,  false, false);   /* alias, string|false */
    add("strpos",        B_MISC,    ty_int_false, false, false); /* (hay, needle[, offset]) -> int|false */
    add("str_contains",  B_STR2,    ty_bool,   false, false);
    add("str_at_eq",      B_MISC,    ty_bool,   false, false);
    add("str_to_int",      B_MISC,    ty_int,    false, false);
    add("str_starts_with", B_STR2,  ty_bool,   false, false);
    add("str_ends_with", B_STR2,    ty_bool,   false, false);
    add("strcmp",        B_CMP,     ty_int,    false, false);
    add("strncmp",       B_MISC,    ty_int,    false, false);
    add("strncasecmp",   B_MISC,    ty_int,    false, false);
    add("strcasecmp",    B_CMP,     ty_int,    false, false);
    add("explode",       B_STR2,    type_array_of(ty_string), false, false);
    add("split",         B_STR2,    type_array_of(ty_string), false, false);
    add("implode",       B_MISC,    ty_string, false, false);
    add("join",          B_MISC,    ty_string, false, false);
    add("nl2br",         B_STR1,    ty_string, false, false);
    add("number_format", B_MISC,    ty_string, false, false);   /* (n[, dec[, dsep[, tsep]]]) */
    add("unset",         B_MISC,    ty_void,   false, false);
    add("json_encode",   B_MISC,    ty_string, false, false);
    add("json_encode_pretty", B_STR1, ty_string, false, false);   /* 2nd impl: flags & 1 = pretty */
    add("json_decode",   B_STR_INT, ty_mixed,  false, false);

    /* regex (PCRE-style, /pattern/flags with i s m) */
    add("preg_match",      B_MISC, ty_mixed,  false, false);  /* (pat, subj) -> matches|false */
    add("preg_match_all",  B_MISC, ty_mixed,  false, false);  /* (pat, subj) -> array of matches|false */
    add("preg_replace",    B_MISC, ty_mixed,  false, false);  /* (pat, rep, subj) -> string|false */
    add("preg_split",      B_MISC, ty_mixed,  false, false);  /* (pat, subj) -> array */
    add("preg_grep",       B_MISC, ty_mixed,  false, false);  /* (pat, array) -> filtered */

    /* crypto */
    add("sha256",           B_STR1, ty_string, false, false);
    add("hash_hmac",        B_MISC, ty_mixed,  false, false);  /* (algo, data, key[, raw]) */
    add("jwt_verify",       B_MISC, ty_string, false, false);  /* (token, secret, now) -> payload|"" */
    add("jwt_verifier_new", B_MISC, ty_string, false, false);  /* (secret) -> reusable HMAC key state */
    add("jwt_verify_prepared", B_MISC, ty_string, false, false); /* (token, key_state, now) -> payload|"" */
    add("json_str_field",   B_MISC, ty_string, false, false);  /* (json, key) -> value|"" */
    add("json_num_field",   B_MISC, ty_int,    false, false);  /* (json, key) -> int|-1 */
    add("str_pos_ci",       B_MISC, ty_int_false, false, false); /* (hay, needle[, off]) -> int|false */
    add("str_prefix_ci",    B_MISC, ty_bool,   false, false);  /* (s, prefix) -> bool */
    add("str_int_range",    B_MISC, ty_int,    false, false);  /* (s, start, end) -> int */
    add("str_trim_range",   B_MISC, ty_string, false, false);  /* (s, start, end) -> trimmed slice */
    add("password_hash",    B_STR1, ty_string, false, false);
    add("password_verify",  B_STR2, ty_bool,   false, false);
    add("random_bytes",     B_INT_INT, ty_string, false, false);
    add("hash_equals",      B_STR2, ty_bool,   false, false);

    /* time */
    add("mktime",           B_MISC, ty_int,    false, false);  /* (h, i, s, m, d, y) */
    add("strtotime",        B_STR1, ty_int,    false, false);

    /* http extras */
    add("http_post",        B_MISC, ty_mixed,  false, false);  /* (url, body[, headers]) */
    add("parse_url",        B_STR1, ty_mixed,  false, false);
    add("http_build_query", B_STR1, ty_string, false, false);

    /* mysql client */
    add("mysql_connect",   B_MISC, ty_mixed,  false, false);  /* (host[, port[, user[, pass[, db]]]]) */
    add("mysql_query",     B_MISC, ty_mixed,  false, false);  /* (conn, sql) -> rows|affected|false */
    add("mysql_exec",      B_MISC, ty_mixed,  false, false);  /* (conn, sql) -> affected|false */
    add("mysql_insert_id", B_MISC, ty_int,    false, false);
    add("mysql_close",     B_MISC, ty_bool,   false, false);
    add("mysql_escape",    B_STR1, ty_string, false, false);
    /* 1 arg, or 2 with PHP's $raw_output flag (real SHA-1/MD5 digests) */
    add("md5",           B_MISC,    ty_string, false, false);
    add("sha1",          B_MISC,    ty_string, false, false);
    add("crc32",         B_STR1,    ty_int,    false, false);
    add("base64_encode", B_STR1,    ty_string, false, false);
    add("base64_decode", B_STR1,    ty_string, false, false);
    add("urlencode",     B_STR1,    ty_string, false, false);
    add("urldecode",     B_STR1,    ty_string, false, false);
    add("htmlentities",  B_STR1,    ty_string, false, false);
    add("htmlspecialchars", B_STR1,  ty_string, false, false);
    add("sprintf",       B_MISC,    ty_string, false, false);
    add("printf",        B_MISC,    ty_int,    false, false);
    add("vsprintf",      B_MISC,    ty_string, false, false);
    add("ord",           B_STR1,    ty_int,    false, false);
    add("chr",           B_INT_INT, ty_string, false, false);
    add("bin2hex",       B_STR1,    ty_string, false, false);
    add("hex2bin",       B_STR1,    ty_string, false, false);
    add("str_split",     B_MISC,    type_array_of(ty_string), false, false);
    add("ucwords",       B_STR1,    ty_string, false, false);
    add("wordwrap",      B_MISC,    ty_string, false, false);
    add("similar_text",  B_STR2,    ty_int,    false, false);
    add("levenshtein",   B_STR2,    ty_int,    false, false);

    /* array functions */
    add("array",         B_ARRAY,   ty_mixed,  false, true);
    add("array_keys",    B_KEYS,    ty_mixed,  false, false);
    add("array_values",  B_VALUES,  ty_mixed,  false, false);
    add("array_merge",   B_MISC,    ty_mixed,  false, true);
    add("array_slice",   B_MISC,    ty_mixed,  false, false);
    add("array_reverse", B_SORTISH, ty_mixed,  false, false);
    add("array_sum",     B_MISC,    ty_mixed,  false, false);
    add("array_product", B_MISC,    ty_mixed,  false, false);
    add("array_unique",  B_SORTISH, ty_mixed,  false, false);
    add("in_array",      B_MISC,    ty_bool,   false, false);
    add("array_key_exists", B_MISC, ty_bool,   false, false);
    add("isset",         B_MISC,    ty_bool,   false, true);
    add("range",         B_RANGE,   ty_mixed,  false, false);
    add("compact",       B_MISC,    ty_mixed,  false, false);
    add("array_column",  B_MISC,    ty_mixed,  false, false);
    add("array_chunk",   B_MISC,    ty_mixed,  false, false);
    add("array_pad",     B_MISC,    ty_mixed,  false, false);
    add("array_replace", B_MISC,    ty_mixed,  false, false);
    add("array_fill_keys", B_MISC,  ty_mixed,  false, false);
    add("array_key_first", B_MISC,  ty_mixed,  false, false);
    add("array_key_last",  B_MISC,  ty_mixed,  false, false);
    add("usort",         B_MISC,    ty_bool,   false, false);
    add("uasort",        B_MISC,    ty_bool,   false, false);
    add("uksort",        B_MISC,    ty_bool,   false, false);
    add("array_walk",    B_MISC,    ty_bool,   false, false);
    add("array_walk_recursive", B_MISC, ty_bool, false, false);
    add("substr_count",  B_STR2,    ty_int,    false, false);
    add("str_shuffle",   B_STR1,    ty_string, false, false);
    add("strip_tags",    B_MISC,    ty_string, false, false);
    add("html_entity_decode", B_STR1, ty_string, false, false);
    add("array_map",     B_MISC,    ty_mixed,  false, true);
    add("array_filter",  B_MISC,    ty_mixed,  false, true);
    add("array_reduce",  B_MISC,    ty_mixed,  false, false);
    add("array_flip",    B_SORTISH, ty_mixed,  false, false);
    add("array_fill",    B_MISC,    ty_mixed,  false, false);
    add("array_combine", B_MISC,    ty_mixed,  false, false);
    add("array_diff",    B_MISC,    ty_mixed,  false, true);
    add("array_intersect", B_MISC,  ty_mixed,  false, true);
    add("array_push",    B_MISC,    ty_int,    false, true);
    add("array_pop",     B_MISC,    ty_mixed,  false, false);
    add("array_shift",   B_MISC,    ty_mixed,  false, false);
    add("array_unshift", B_MISC,    ty_int,    false, true);
    add("array_splice",  B_MISC,    ty_mixed,  false, false);
    add("shuffle",       B_MISC,    ty_bool,   false, false);
    add("sort",          B_SORT,    ty_bool,   false, false);
    add("rsort",         B_SORT,    ty_bool,   false, false);
    add("ksort",         B_SORT,    ty_bool,   false, false);
    add("krsort",        B_SORT,    ty_bool,   false, false);
    add("asort",         B_SORT,    ty_bool,   false, false);
    add("array_search",   B_MISC,    ty_mixed,  false, false);
    add("end",           B_MISC,    ty_mixed,  false, false);
    add("reset",         B_MISC,    ty_mixed,  false, false);

    /* math */
    add("max",           B_MAXMIN,  ty_mixed,  false, true);
    add("min",           B_MAXMIN,  ty_mixed,  false, true);
    add("rand",          B_MISC,    ty_int,    false, false);
    add("mt_rand",       B_MISC,    ty_float,  false, false);
    add("srand",         B_MISC,    ty_void,   false, false);
    add("mt_srand",      B_MISC,    ty_void,   false, false);
    add("random_int",    B_MISC,    ty_int,    false, false);
    add("fgetc",         B_MISC,    ty_string, false, false);
    add("abs",           B_ABS,     ty_mixed,  false, false);
    add("round",         B_MISC,    ty_mixed,  false, false);
    add("floor",         B_ABS,     ty_float,  false, false);
    add("ceil",          B_ABS,     ty_float,  false, false);
    add("sqrt",          B_ABS,     ty_float,  false, false);
    add("pow",           B_MISC,    ty_mixed,  false, false);
    add("intdiv",        B_MISC,    ty_int,    false, false);
    add("fmod",          B_MISC,    ty_float,  false, false);
    add("sin",           B_ABS,     ty_float,  false, false);
    add("cos",           B_ABS,     ty_float,  false, false);
    add("tan",           B_ABS,     ty_float,  false, false);
    add("atan",          B_ABS,     ty_float,  false, false);
    add("atan2",         B_ABS,     ty_float,  false, false);
    add("asin",          B_ABS,     ty_float,  false, false);
    add("acos",          B_ABS,     ty_float,  false, false);
    add("log",           B_ABS,     ty_float,  false, false);
    add("log2",          B_ABS,     ty_float,  false, false);
    add("log10",         B_ABS,     ty_float,  false, false);
    add("exp",           B_ABS,     ty_float,  false, false);
    add("is_nan",        B_ABS,     ty_bool,   false, false);
    add("is_finite",     B_ABS,     ty_bool,   false, false);
    add("is_infinite",   B_ABS,     ty_bool,   false, false);
    add("pi",            B_MISC,    ty_float,  false, false);
    add("M_PI",          B_MISC,    ty_float,  false, false);
    add("deg2rad",       B_ABS,     ty_float,  false, false);
    add("rad2deg",       B_ABS,     ty_float,  false, false);
    add("hypot",         B_MISC,    ty_float,  false, false);
    add("lcg_value",     B_MISC,    ty_float,  false, false);

    /* type juggling helpers */
    add("is_int",        B_ABS,     ty_bool,   false, false);
    add("is_integer",    B_ABS,     ty_bool,   false, false);
    add("is_float",      B_ABS,     ty_bool,   false, false);
    add("is_string",     B_ABS,     ty_bool,   false, false);
    add("is_bool",       B_ABS,     ty_bool,   false, false);
    add("is_array",      B_ABS,     ty_bool,   false, false);
    add("is_null",       B_ABS,     ty_bool,   false, false);
    add("is_numeric",    B_ABS,     ty_bool,   false, false);
    add("intval",        B_ABS,     ty_int,    false, false);
    add("floatval",      B_ABS,     ty_float,  false, false);
    add("doubleval",     B_ABS,     ty_float,  false, false);
    add("strval",        B_ABS,     ty_string, false, false);
    add("boolval",       B_ABS,     ty_bool,   false, false);
    add("gettype",       B_ABS,     ty_string, false, false);
    add("var_dump",      B_MISC,    ty_void,   false, true);
    add("print_r",       B_MISC,    ty_string, false, true);
    add("var_export",    B_MISC,    ty_string, false, true);
    add("serialize",     B_ABS,     ty_string, false, false);
    add("unserialize",   B_ABS,     ty_mixed,  false, false);

    /* io / process */
    add("readline",      B_STR1,    ty_string, false, false);
    add("file_get_contents", B_STR1, ty_mixed, false, false);   /* string|false, PHP-style */
    add("file_put_contents", B_MISC, ty_mixed, false, false);   /* int bytes|false, PHP-style */
/* filesystem helpers */
    add("file_exists",   B_STR1,    ty_bool,   false, false);
    add("is_dir",        B_STR1,    ty_bool,   false, false);
    add("filesize",      B_STR1,    ty_int,    false, false);
    add("mkdir",         B_MISC,    ty_bool,   false, false);   /* (path[, recursive[, mode]]) */
    add("rmdir",         B_STR1,    ty_bool,   false, false);
    add("unlink",        B_STR1,    ty_bool,   false, false);
    add("rename",        B_STR2,    ty_bool,   false, false);
    add("copy",          B_STR2,    ty_mixed,  false, false);   /* bool|false */
    add("fgets",         B_STR1,    ty_mixed,  false, false);   /* string|false at EOF, PHP-style */
    add("fwrite",        B_STR2,    ty_int,    false, false);
    add("fopen",         B_STR2,    ty_mixed,  false, false);
    add("fclose",        B_STR1,    ty_bool,   false, false);
    add("scandir",       B_STR1,    type_array_of(ty_string), false, false);
    add("dirname",       B_STR1,    ty_string, false, false);
    add("basename",      B_MISC,    ty_string, false, false);
    add("pathinfo",      B_MISC,    ty_mixed,  false, false);
    add("realpath",      B_STR1,    ty_mixed,  false, false);
    add("is_file",       B_STR1,    ty_bool,   false, false);
    add("is_readable",   B_STR1,    ty_bool,   false, false);
    add("is_writable",   B_STR1,    ty_bool,   false, false);
    add("touch",         B_STR1,    ty_bool,   false, false);
    add("glob",          B_STR1,    type_array_of(ty_string), false, false);
    add("sys_get_temp_dir", B_ZERO, ty_string, false, false);
    add("checkdate",     B_MISC,    ty_bool,   false, false);
    add("fread",         B_MISC,    ty_string, false, false);
    add("feof",          B_MISC,    ty_bool,   false, false);
    add("http_get",      B_STR1,    ty_mixed,  false, false);
    add("http_request",  B_MISC,    ty_mixed,  false, false);
    /* sockets — the transport layer for library code (lib/websocket.hphp) */
    add("stream_socket_server", B_MISC, ty_mixed,  false, false);
    add("stream_socket_client", B_MISC, ty_mixed,  false, false);
    add("stream_socket_accept", B_MISC, ty_mixed,  false, false);
    add("stream_socket_accept2", B_MISC, ty_mixed, false, false);   /* (srv, timeoutMs): false on timeout */
    add("accept_emfile",     B_ZERO,    ty_bool,   false, false);   /* last accept failed with EMFILE/ENFILE */
    add("stream_set_blocking",  B_MISC, ty_bool,   false, false);
    add("stream_set_nodelay",   B_MISC, ty_bool,   false, false);
    add("stream_ready",         B_MISC, type_array_of(ty_mixed), false, false);
    add("stream_ready_into",    B_MISC, type_array_of(ty_mixed), false, false);
    add("epoll_add",            B_MISC, ty_bool,   false, false);
    add("epoll_del",            B_MISC, ty_bool,   false, false);
    add("epoll_mod",            B_MISC, ty_bool,   false, false);
    add("epoll_wait2",          B_MISC, ty_bool,   false, false);
    add("epoll_wait_iarr2",     B_MISC, ty_bool,   false, false);
    add("epoll_wait_into",      B_MISC, type_array_of(ty_mixed), false, false);
    add("stream_recv",          B_MISC, ty_string, false, false);
    add("stream_recv_release",  B_MISC, ty_bool,   false, false);
    add("stream_send",          B_MISC, ty_int,    false, false);
    add("stream_send2",         B_MISC, ty_int,    false, false);
    add("stream_send_nb",       B_MISC, ty_int,    false, false);
    add("stream_send2_nb",      B_MISC, ty_int,    false, false);
    add("nofile_limit",         B_ZERO, ty_int,    false, false);
    add("runtime_stats",        B_ZERO, ty_string, false, false);
    add("uring_active",         B_ZERO, ty_bool,   false, false);
    add("uring_direct",         B_ZERO, ty_bool,   false, false);
    add("uring_direct_slots",   B_ZERO, ty_int,    false, false);
    add("stream_eof",           B_MISC, ty_bool,   false, false);
    add("stream_peer",          B_MISC, ty_string, false, false);
    add("stream_close",         B_MISC, ty_bool,   false, false);
    add("getcwd",       B_ZERO,    ty_string, false, false);
    /* number base conversion */
    add("decbin",        B_INT_INT, ty_string, false, false);
    add("decoct",        B_INT_INT, ty_string, false, false);
    add("dechex",        B_INT_INT, ty_string, false, false);
    add("bindec",        B_STR1,    ty_int,    false, false);
    add("octdec",        B_STR1,    ty_int,    false, false);
    add("hexdec",        B_STR1,    ty_int,    false, false);
    add("getenv",        B_STR1,    ty_string, false, false);
    add("putenv",        B_STR1,    ty_bool,   false, false);
    add("php_uname",     B_MISC,    ty_string, false, false);
    add("phpversion",    B_MISC,    ty_string, false, false);
    add("php_sapi_name", B_MISC,    ty_string, false, false);
    add("microtime",     B_MISC,    ty_float,  false, false);
    add("hrtime",        B_MISC,    ty_int,    false, false);
    add("memory_get_usage", B_MISC, ty_int,    false, false);
    add("memory_get_peak_usage", B_MISC, ty_int, false, false);
    add("gc_collect_cycles", B_MISC, ty_int,   false, false);
    add("sys_getloadavg", B_MISC,   ty_mixed,  false, false);
    add("php_logo_guid", B_MISC,    ty_string, false, false);
    add("date",          B_MISC,    ty_string, false, false);   /* (fmt[, ts]) */
    add("time",          B_MISC,    ty_int,    false, false);
    add("usleep",        B_INT_INT, ty_void,   false, false);
    add("sleep",         B_INT_INT, ty_int,    false, false);
    add("exit",          B_MISC,    ty_void,   false, false);
    add("die",           B_MISC,    ty_void,   false, false);
    add("php_sapi",      B_MISC,    ty_string, false, false);

    /* UI layer (hphp_ui.c): windows, controls, menus, dialogs, timers */
    add("ui_dispatch",    B_INT_INT, ty_int,     false, false);
    add("ui_run_main",    B_ZERO,    ty_void,    false, false);
    add("ui_quit",        B_ZERO,    ty_void,    false, false);
    add("ui_window",      B_MISC,    ty_int,     false, false);
    add("ui_show",        B_MISC,    ty_int,     false, false);
    add("ui_title",       B_MISC,    ty_int,     false, false);
    add("ui_size",        B_MISC,    ty_int,     false, false);
    add("ui_pos",         B_MISC,    ty_int,     false, false);
    add("ui_close",       B_MISC,    ty_int,     false, false);
    add("ui_alive",       B_MISC,    ty_bool,    false, false);
    add("ui_add",         B_MISC,    ty_int,     false, false);
    add("ui_set",         B_MISC,    ty_int,     false, false);
    add("ui_get",         B_MISC,    ty_string,  false, false);
    add("ui_enable",      B_MISC,    ty_int,     false, false);
    add("ui_move",        B_MISC,    ty_int,     false, false);
    add("ui_focus",       B_MISC,    ty_int,     false, false);
    add("ui_select_all",  B_MISC,    ty_int,     false, false);
    add("ui_items",       B_MISC,    ty_int,     false, false);
    add("ui_remove",      B_MISC,    ty_int,     false, false);
    add("ui_clear",       B_MISC,    ty_int,     false, false);
    add("ui_ctrl_show",   B_MISC,    ty_int,     false, false);
    add("ui_selected",    B_MISC,    ty_int,     false, false);
    add("ui_select",      B_MISC,    ty_int,     false, false);
    add("ui_item_text",   B_MISC,    ty_string,  false, false);
    add("ui_check_get",   B_MISC,    ty_int,     false, false);
    add("ui_check_set",   B_MISC,    ty_int,     false, false);
    add("ui_progress",    B_MISC,    ty_int,     false, false);
    add("ui_slider_get",  B_MISC,    ty_int,     false, false);
    add("ui_slider_set",  B_MISC,    ty_int,     false, false);
    add("ui_bg",          B_MISC,    ty_int,     false, false);
    add("ui_fg",          B_MISC,    ty_int,     false, false);
    add("ui_font",        B_MISC,    ty_int,     false, false);
    add("ui_menu",        B_MISC,    ty_int,     false, false);
    add("ui_menu_item",   B_MISC,    ty_int,     false, false);
    add("ui_menu_sep",    B_MISC,    ty_int,     false, false);
    add("ui_menu_check",  B_MISC,    ty_int,     false, false);
    add("ui_on",          B_MISC,    ty_int,     false, false);
    add("ui_timer",       B_MISC,    ty_int,     false, false);
    add("ui_msg",         B_MISC,    ty_int,     false, false);
    add("ui_open_file",   B_MISC,    ty_mixed,   false, false);
    add("ui_save_file",   B_MISC,    ty_mixed,   false, false);
    add("ui_pick_folder", B_MISC,    ty_mixed,   false, false);
    add("ui_pick_color",  B_MISC,    ty_mixed,   false, false);
    add("ui_clip_set",    B_STR1,    ty_int,     false, false);
    add("ui_clip_get",    B_ZERO,    ty_string,  false, false);
    add("ui_theme",       B_MISC,    ty_int,     false, false);
    add("ui_style",       B_MISC,    ty_int,     false, false);
    add("ui_accent",      B_MISC,    ty_int,     false, false);
    add("ui_radius",      B_MISC,    ty_int,     false, false);
    add("ui_range",       B_MISC,    ty_int,     false, false);
    add("ui_repaint",     B_MISC,    ty_int,     false, false);
    add("ui_input_margin", B_MISC,   ty_int,     false, false);
    add("ui_raise",       B_MISC,    ty_int,     false, false);
    add("ui_svg",         B_MISC,    ty_int,     false, false);
    add("ui_picture",     B_MISC,    ty_int,     false, false);
    add("ui_text_px",      B_MISC,    ty_int,     false, false);
    add("ui_text_lines",   B_MISC,    ty_int,     false, false);
    add("ui_enabled",     B_MISC,    ty_bool,    false, false);
    add("ui_rect",        B_MISC,    type_array_of(ty_int), false, false);
    add("ui_client_size", B_MISC,    type_array_of(ty_int), false, false);
    add("ui_scroll",      B_MISC,    type_array_of(ty_int), false, false);
    add("ui_count",        B_MISC,    ty_int,     false, false);
    add("ui_progress_get", B_MISC,    ty_int,     false, false);

    /* embedded Chromium (WebView2): HolyBrowser's engine */
    add("ui_hwnd",          B_MISC,    ty_int,     false, false);
    /* canvas: a surface a script paints itself (drawing, fonts, input).
     * Every coordinate is a logical 96-dpi pixel, so an HTML/CSS engine can
     * lay out in one coordinate space and look the same at any display scale. */
    add("ui_font_new",     B_MISC,    ty_int,     false, false);
    add("ui_font_width",   B_MISC,    ty_int,     false, false);
    add("ui_font_height",  B_MISC,    ty_int,     false, false);
    add("ui_draw_clear",   B_MISC,    ty_int,     false, false);
    add("ui_draw_rect",    B_MISC,    ty_int,     false, false);
    add("ui_draw_round",   B_MISC,    ty_int,     false, false);
    add("ui_draw_line",    B_MISC,    ty_int,     false, false);
    add("ui_draw_text",    B_MISC,    ty_int,     false, false);
    add("ui_draw_clip",    B_MISC,    ty_int,     false, false);
    add("ui_draw_unclip",  B_MISC,    ty_int,     false, false);
    add("ui_canvas_size",  B_MISC,    type_array_of(ty_int), false, false);
    add("ui_canvas_pixel", B_MISC,    ty_int,     false, false);
    add("ui_canvas_invalidate", B_MISC, ty_int,    false, false);
    add("ui_canvas_flush", B_MISC,    ty_int,     false, false);
    add("ui_cursor",       B_MISC,    ty_int,     false, false);

    /* child processes (hphp_std.c): the integrated terminal and the IDE's
     * runner. Start a command in a directory, poll its two output pipes
     * without blocking, write to its stdin, ask whether it is still alive,
     * read the exit code, and close or kill it. `proc_*` and not `ui_*`:
     * nothing here touches a window, which is what makes a runner testable
     * from a script that has no UI at all. */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */
    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("exec",          B_STR1,    ty_mixed,  false, false);   /* (cmd) -> last-line|string|false, PHP-style */
    add("passthru",      B_STR1,    ty_void,   false, false);   /* (cmd) -> prints to stdout, returns void */
    add("shell_exec",    B_STR1,    ty_mixed,  false, false);   /* (cmd) -> stdout|string|false, PHP-style */

    add("proc_open",     B_MISC,    ty_mixed,  false, false);   /* CWD-aware equivalent of proc_* start */
    add("proc_get_status", B_MISC,  ty_mixed,  false, false);   /* (h) -> array */

    add("proc_start",     B_MISC,    ty_int,     false, false);   /* (cmd, cwd) -> handle|0 */
    add("proc_read",      B_MISC,    ty_string,  false, false);   /* (h[, max]) -> stdout so far */
    add("proc_read_err",  B_MISC,    ty_string,  false, false);   /* (h[, max]) -> stderr so far */
    add("proc_write",     B_MISC,    ty_int,     false, false);   /* (h, data) -> bytes written */
    add("proc_alive",     B_MISC,    ty_bool,    false, false);   /* (h) -> 1 while running */
    add("proc_exit",      B_MISC,    ty_int,     false, false);   /* (h) -> code, -1 while running */
    add("proc_close",     B_MISC,    ty_int,     false, false);   /* (h) -> release the slot */
    add("proc_kill",      B_MISC,    ty_int,     false, false);   /* (h) -> terminate the tree */

    add("ui_browser_ready", B_ZERO,    ty_bool,    false, false);
    add("ui_browser_loader",B_ZERO,    ty_string,  false, false);
    add("ui_browser_new",   B_MISC,    ty_int,     false, false);
    add("ui_browser_free",  B_MISC,    ty_int,     false, false);
    add("ui_browser_fit",   B_MISC,    ty_int,     false, false);
    add("ui_browser_go",    B_MISC,    ty_int,     false, false);
    add("ui_browser_html",  B_MISC,    ty_int,     false, false);
    add("ui_browser_back",  B_MISC,    ty_int,     false, false);
    add("ui_browser_forward",B_MISC,   ty_int,     false, false);
    add("ui_browser_reload",B_MISC,    ty_int,     false, false);
    add("ui_browser_stop",  B_MISC,    ty_int,     false, false);
    add("ui_browser_can_back",   B_MISC, ty_bool,  false, false);
    add("ui_browser_can_forward",B_MISC, ty_bool,  false, false);
    add("ui_browser_url",   B_MISC,    ty_string,  false, false);
    add("ui_browser_favicon", B_MISC,   ty_string, false, false);
    add("ui_browser_title", B_MISC,    ty_string,  false, false);
    add("ui_browser_zoom",  B_MISC,    ty_int,     false, false);
    add("ui_browser_zoom_get", B_MISC, ty_float,  false, false);
    add("ui_browser_devtools",  B_MISC, ty_int,    false, false);
    add("ui_browser_devtools_fit", B_MISC, ty_int,   false, false);
    add("ui_browser_devtools_ready", B_MISC, ty_int, false, false);
    add("ui_browser_print",   B_MISC,    ty_int,    false, false);
    add("ui_browser_post",  B_MISC, ty_int,    false, false);
    add("ui_browser_on",    B_MISC,    ty_int,     false, false);
    add("ui_browser_key",   B_MISC,    ty_int,     false, false);
    add("ui_browser_visible",B_MISC,    ty_int,     false, false);

    /* threading: workers, channels, mutexes, barriers, atomics */
    add("thr_spawn",       B_MISC,  ty_mixed,  false, false);  /* (closure[, args]) -> tid|false */
    add("thr_join",        B_MISC,  ty_mixed,  false, false);  /* (tid) -> bool */
    add("thr_current",     B_ZERO,  ty_int,    false, false);
    add("thr_id",          B_ZERO,  ty_int,    false, false);  /* OS-level id */
    add("thr_sleep_ms",    B_INT_INT, ty_void, false, false);
    add("thr_cpu_count",   B_ZERO,  ty_int,    false, false);
    add("thr_parallel_map", B_MISC, ty_mixed,  false, false); /* (closure, items[, workers]) -> array */
    add("chan_new",        B_INT_INT, ty_int,  false, false);  /* (capacity) -> id */
    add("chan_send",       B_MISC,  ty_bool,   false, false);  /* (ch, value), throws when closed */
    add("chan_recv",       B_MISC,  ty_mixed,  false, false);  /* (ch) -> value|false (closed+drained) */
    add("chan_try_send",   B_MISC,  ty_bool,   false, false);
    add("chan_try_recv",   B_MISC,  ty_mixed,  false, false);  /* value|false */
    add("chan_close",      B_MISC,  ty_bool,   false, false);
    add("mutex_new",       B_ZERO,  ty_int,    false, false);
    add("mutex_lock",      B_MISC,  ty_bool,   false, false);
    add("mutex_trylock",   B_MISC,  ty_bool,   false, false);
    add("mutex_unlock",    B_MISC,  ty_bool,   false, false);
    add("mutex_free",      B_MISC,  ty_bool,   false, false);
    add("barrier_new",     B_INT_INT, ty_int,  false, false);
    add("barrier_wait",    B_MISC,  ty_int,    false, false);  /* -> arrival index */
    add("atomic_new",      B_MISC,  ty_int,    false, false);  /* ([init]) -> id */
    add("atomic_get",      B_MISC,  ty_int,    false, false);
    add("atomic_set",      B_MISC,  ty_bool,   false, false);
    add("atomic_add",      B_MISC,  ty_int,    false, false);  /* -> previous value */
    add("atomic_cas",      B_MISC,  ty_bool,   false, false);

    /* unsafe: raw memory & ffi */
    add("malloc",        B_INT_INT, ty_mixed,  true,  false);
    add("free",          B_MISC,    ty_void,   true,  false);
    add("memcpy",        B_MISC,    ty_mixed,  true,  false);
    add("memset",        B_MISC,    ty_mixed,  true,  false);
    add("ffi_load",      B_STR1,    ty_mixed,  true,  false);
    add("ffi_call",      B_MISC,    ty_mixed,  true,  true);
    add("heap_dump",     B_MISC,    ty_string, true,  false);

    /* generic SQLite binding */
    add("scope_begin",          B_MISC, ty_bool,   false, false);
    add("scope_end",            B_MISC, ty_bool,   false, false);
    add("str_persist",          B_MISC, ty_string, false, false);
    add("str_free",             B_MISC, ty_bool,   false, false);
    add("live_bytes",           B_MISC, ty_int,    false, false);
    add("live_allocs",          B_MISC, ty_int,    false, false);
    add("arr_clear",            B_MISC, ty_bool,   false, false);
    add("arr_free",             B_MISC, ty_bool,   false, false);
    add("bt_root",              B_MISC, ty_int,    false, false);
    add("bt_open",              B_MISC, ty_int,    false, false);
    add("bt_close",             B_MISC, ty_bool,   false, false);
    add("bt_first",             B_MISC, ty_int,    false, false);
    add("bt_last",              B_MISC, ty_int,    false, false);
    add("bt_next",              B_MISC, ty_int,    false, false);
    add("bt_prev",              B_MISC, ty_int,    false, false);
    add("bt_seek",              B_MISC, ty_int,    false, false);
    add("bt_rowid",             B_MISC, ty_int,    false, false);
    add("bt_payload_ptr",       B_MISC, ty_int,    false, false);
    add("bt_payload_size",      B_MISC, ty_int,    false, false);
    add("bt_payload_pin",       B_MISC, ty_int,    false, false);
    add("bt_page_release",      B_MISC, ty_bool,   false, false);
    add("bt_cols",              B_MISC, ty_int,    false, false);
    add("bt_col_off",           B_MISC, ty_int,    false, false);
    add("bt_col_len",           B_MISC, ty_int,    false, false);
    add("bt_col_int",           B_MISC, ty_int,    false, false);
    add("bt_read",              B_MISC, ty_int,    false, false);
    add("bt_count_key",        B_MISC, ty_int,    false, false);
    add("bt_count_range",      B_MISC, ty_int,    false, false);
    add("bt_multi_seek",       B_MISC, ty_int,    false, false);
    add("bt_multi_payloads",   B_MISC, ty_bool,   false, false);
    add("bt_multi_release",    B_MISC, ty_bool,   false, false);
    add("iarr_new",            B_MISC, ty_int,    false, false);
    add("iarr_release",        B_MISC, ty_bool,   false, false);
    add("iarr_get",            B_MISC, ty_int,    false, false);
    add("iarr_set",            B_MISC, ty_bool,   false, false);
    add("iarr_len",            B_MISC, ty_int,    false, false);
    add("sb_new",               B_MISC, ty_int,    false, false);
    add("sb_put",               B_MISC, ty_bool,   false, false);
    add("sb_bytes",             B_MISC, ty_bool,   false, false);
    add("sb_data_ptr",          B_MISC, ty_int,    false, false);
    add("sb_discard",           B_MISC, ty_bool,   false, false);
    add("sb_int",               B_MISC, ty_bool,   false, false);
    add("sb_json",              B_MISC, ty_bool,   false, false);
    add("sb_json_str",          B_MISC, ty_bool,   false, false);
    add("str_from_bytes",       B_MISC, ty_string, false, false);
    add("sb_reserve",           B_MISC, ty_bool,   false, false);
    add("sb_len",               B_MISC, ty_int,    false, false);
    add("sb_prepend",           B_MISC, ty_bool,   false, false);
    add("sb_take",              B_MISC, ty_string, false, false);
    add("stream_send_sb",       B_MISC, ty_int,    false, false);
    add("int_digits",           B_MISC, ty_int,    false, false);
    add("sqlite_open",          B_MISC, ty_int,    false, false);  /* (path) -> handle|0 */
    add("sqlite_open_vfs",      B_MISC, ty_int,    false, false);  /* (path, vfs) -> handle|0 */
    add("sqlite_bg_checkpoint_start", B_MISC, ty_bool, false, false); /* (db, path, frames, hold_ms) */
    add("sqlite_bg_checkpoint_hold", B_MISC, ty_bool, false, false); /* (db) */
    add("sqlite_bg_checkpoint_active", B_MISC, ty_bool, false, false); /* (db) */
    add("sqlite_close",         B_MISC, ty_bool,   false, false);
    add("sqlite_exec",          B_MISC, ty_bool,   false, false);  /* (db, sql) */
    add("sqlite_prepare",       B_MISC, ty_int,    false, false);  /* (db, sql) -> stmt|0 */
    add("sqlite_finalize",      B_MISC, ty_bool,   false, false);
    add("sqlite_bind_int",      B_MISC, ty_bool,   false, false);  /* (stmt, 1-based idx, value) */
    add("sqlite_bind_text",     B_MISC, ty_bool,   false, false);
    add("sqlite_step",          B_MISC, ty_int,    false, false);  /* 100 row, 101 done */
    add("sqlite_reset",         B_MISC, ty_int,    false, false);
    add("sqlite_clear_bindings",B_MISC, ty_bool,   false, false);
    add("sqlite_column_text",   B_MISC, ty_string, false, false);
    add("sqlite_column_int",    B_MISC, ty_int,    false, false);
    add("sqlite_changes",       B_MISC, ty_int,    false, false);
    add("sqlite_last_insert_rowid", B_MISC, ty_int, false, false);
    add("sqlite_errmsg",        B_MISC, ty_string, false, false);
    add("sqlite_busy_timeout",  B_MISC, ty_bool,   false, false);
}

const Builtin *builtin_lookup(const char *name) {
    for (size_t i = 0; i < tbl_len; i++)
        if (tbl[i].name == intern(name)) return &tbl[i];
    return NULL;
}
