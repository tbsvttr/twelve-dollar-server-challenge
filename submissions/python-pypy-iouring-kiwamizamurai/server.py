"""The $12 server challenge on PyPy: one thread, raw io_uring and SQLite's B-tree cursors, written in Python.

The JIT compiles everything here, including the ring handling and the record decoding. The only C in the process
is SQLite itself, OpenSSL's HMAC and the thin wrappers in build_sqlite.py.
"""
import binascii
import gc
import hmac
import json
import os
import resource
import socket
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "bin"))
from _sq import ffi, lib  # noqa: E402

SECRET = os.environ["JWT_SECRET"].encode()
START = time.monotonic()
MAX_ID = 2**63 - 1
WHITESPACE = "\t\n\v\f\r \xa0                　﻿"
HS256_HEADER = b"eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"  # base64url of {"alg":"HS256","typ":"JWT"}
cast = ffi.cast
new = ffi.new
NULL = ffi.NULL
TRANSIENT = cast("void *", -1)
UC = ffi.typeof("unsigned char *")
CP = ffi.typeof("char *")
unpack = ffi.unpack
memmove = ffi.memmove


# --- strict JSON ----------------------------------------------------------------------------
def _reject(_):
    raise ValueError("non-finite number")


def _finite(text):
    number = float(text)
    if number - number != 0:
        raise ValueError("non-finite number")
    return number


_strict = json.JSONDecoder(parse_constant=_reject, parse_float=_finite).decode
_loads = json.loads


def loads(raw):
    """json.loads, but UTF-8 only, no lone-surrogate escapes, no NaN/Infinity/overflowing numbers."""
    text = raw.decode("utf-8")
    value = _loads(text)
    if type(value) is dict:
        for item in value.values():
            kind = type(item)
            if kind is str:
                if not item.isascii():
                    item.encode("utf-8")
            elif kind is float:
                if item - item != 0:
                    raise ValueError("non-finite number")
            elif kind is dict or kind is list:
                return _strict(text)
    elif type(value) is list:
        return _strict(text)
    return value


def quote(raw):
    """JSON string contents for valid UTF-8 text from the database."""
    return json.dumps(raw.decode("utf-8", "replace"), separators=(",", ":"), ensure_ascii=False)[1:-1].encode("utf-8")


# --- database -------------------------------------------------------------------------------
_db = new("sqlite3 **")
if lib.sqlite3_open_v2(os.environ["SQLITE_PATH"].encode(), _db, lib.SQLITE_OPEN_READWRITE, NULL):
    raise SystemExit("cannot open database")
db = _db[0]


def sql_exec(sql):
    if lib.sqlite3_exec(db, sql, NULL, NULL, NULL):
        raise SystemExit("%s: %s" % (sql, ffi.string(lib.sqlite3_errmsg(db))))


for _pragma in (b"journal_mode=WAL", b"synchronous=NORMAL", b"foreign_keys=ON", b"locking_mode=EXCLUSIVE",
                b"mmap_size=1073741824", b"cache_size=-32768", b"temp_store=MEMORY", b"busy_timeout=5000"):
    sql_exec(b"PRAGMA " + _pragma)
sql_exec(b"BEGIN IMMEDIATE")  # takes the exclusive lock now
sql_exec(b"COMMIT")


def prepare(sql):
    s = new("sqlite3_stmt **")
    if lib.sqlite3_prepare_v2(db, sql, -1, s, NULL):
        raise SystemExit("%s: %s" % (sql, ffi.string(lib.sqlite3_errmsg(db))))
    return s[0]


def rootpage(name):
    s = prepare(b"SELECT rootpage FROM sqlite_schema WHERE name='" + name + b"'")
    lib.sqlite3_step(s)
    r = lib.sqlite3_column_int64(s, 0)
    lib.sqlite3_finalize(s)
    return r


POST_JSON = (b"json_object('id',p.id,'body',p.body,'created_at',p.created_at,'author',u.username,"
             b"'like_count',(SELECT count(*) FROM likes WHERE post_id=p.id))")
S_FEED = prepare(b"SELECT CAST('{\"posts\":[' || coalesce(group_concat(" + POST_JSON + b", ','), '') || ']}' AS BLOB) "
                 b"FROM (SELECT id, user_id, body, created_at FROM posts ORDER BY created_at DESC, id DESC LIMIT 20) p "
                 b"JOIN users u ON u.id = p.user_id")
S_POST = prepare(b"SELECT CAST(json_object('post'," + POST_JSON + b") AS BLOB) FROM posts p JOIN users u ON u.id=p.user_id WHERE p.id=?")
S_CREATE = prepare(b"INSERT INTO posts(user_id,body) VALUES(?,?) RETURNING id,created_at")
S_LIKE = prepare(b"INSERT INTO likes(user_id,post_id) SELECT ?,id FROM posts WHERE id=? "
                 b"ON CONFLICT(user_id,post_id) DO NOTHING RETURNING post_id")
S_EXISTS = prepare(b"SELECT 1 FROM posts WHERE id=?")
S_ONE = prepare(b"SELECT 1")
S_BEGIN = prepare(b"BEGIN IMMEDIATE")
S_COMMIT = prepare(b"COMMIT")
S_ROLLBACK = prepare(b"ROLLBACK")
step = lib.sqlite3_step
reset = lib.sqlite3_reset
bind_int = lib.sqlite3_bind_int64
bind_text = lib.sqlite3_bind_text
column_int = lib.sqlite3_column_int64
column_blob = lib.sqlite3_column_blob
column_bytes = lib.sqlite3_column_bytes
column_text = lib.sqlite3_column_text
SQLITE_ROW = 100
SQLITE_DONE = 101


def sql_blob(stmt):
    """First column of the first row as bytes (None if there is no row); leaves the statement reset."""
    out = None
    if step(stmt) == SQLITE_ROW:
        out = unpack(cast(CP, column_blob(stmt, 0)), column_bytes(stmt, 0))
    reset(stmt)
    return out


# --- reads through SQLite's B-tree cursors ---------------------------------------------------
# Every page comes through SQLite's pager, WAL and page cache inside a read transaction; only the bytecode
# interpreter is skipped. If a record isn't shaped as expected, the caller answers with the SQL statements above.
BT = lib.sqlite3DbNameToBtree(db, b"main")
_csize = lib.sqlite3BtreeCursorSize()
_keep = []


def _cursor():
    block = new("char[]", _csize)
    _keep.append(block)
    return cast("BtCursor *", block)


def _keyinfo(nkey, nextra, desc):
    k = lib.sqlite3KeyInfoAlloc(db, nkey, nextra)
    coll = lib.default_coll(db)
    for i in range(nkey + nextra):
        k.aColl[i] = coll
        if desc and i < nkey:
            k.aSortFlags[i] = 1
    return k


C_POSTS, C_USERS, C_LIKES, C_RECENT = _cursor(), _cursor(), _cursor(), _cursor()
KI_LIKES, KI_RECENT = _keyinfo(1, 1, False), _keyinfo(2, 1, True)
R_POSTS, R_USERS, R_LIKES, R_RECENT = rootpage(b"posts"), rootpage(b"users"), rootpage(b"likes_post_id_idx"), rootpage(b"posts_created_at_id_idx")
_mem = new("Mem[1]")
_rec = new("UnpackedRecord *")
_rec.pKeyInfo = KI_LIKES
_rec.aMem = _mem
_rec.nField = 1
_rec.default_rc = 1
_res = new("int *")
_amt = new("u32 *")
bt_size = lib.sqlite3BtreePayloadSize
bt_fetch = lib.sqlite3BtreePayloadFetch
bt_next = lib.sqlite3BtreeNext
bt_first = lib.sqlite3BtreeFirst
bt_eof = lib.sqlite3BtreeEof
bt_table_seek = lib.sqlite3BtreeTableMoveto
bt_index_seek = lib.sqlite3BtreeIndexMoveto
bt_key = lib.sqlite3BtreeIntegerKey
mem_set_int = lib.mem_set_int
read_open = False
SERIAL_LEN = (0, 1, 2, 3, 4, 6, 8, 8, 0, 0)
FEED_N = 20
FEED_SPAN = 256
_NEEDS_ESCAPE = bytes(range(32)) + b'"\\'


class Fallback(Exception):
    pass


def open_read():
    global read_open
    if lib.sqlite3BtreeBeginTrans(BT, 0, NULL):
        raise Fallback
    for c, root, ki in ((C_POSTS, R_POSTS, NULL), (C_USERS, R_USERS, NULL), (C_LIKES, R_LIKES, KI_LIKES), (C_RECENT, R_RECENT, KI_RECENT)):
        lib.sqlite3BtreeCursorZero(c)
        if lib.sqlite3BtreeCursor(BT, root, 0, ki, c):
            raise Fallback
    read_open = True


def close_read():
    global read_open
    read_open = False
    for c in (C_POSTS, C_USERS, C_LIKES, C_RECENT):
        lib.sqlite3BtreeCloseCursor(c)
    lib.sqlite3BtreeCommit(BT)


def record(c):
    total = bt_size(c)
    p = cast(UC, bt_fetch(c, _amt))
    if _amt[0] != total:  # spilled onto overflow pages: never for these tables at this page size
        raise Fallback
    return p


def varint(p, i):
    x = 0
    while True:
        b = p[i]
        i += 1
        if b < 128:
            return (x << 7) | b, i
        x = (x << 7) | (b & 127)


def column_uint(p, off, t):
    if t > 9 or t == 7 or t == 0:
        raise Fallback
    if t >= 8:
        return t - 8
    v = 0
    for k in range(off, off + SERIAL_LEN[t]):
        v = (v << 8) | p[k]
    return v


def seek_likes(lo):
    """Move the likes index to its first entry with post_id >= lo. True if there is one."""
    mem_set_int(_mem, lo)
    if bt_index_seek(C_LIKES, _rec, _res):
        raise Fallback
    if _res[0] < 0:
        return bt_next(C_LIKES, 0) == 0
    return not bt_eof(C_LIKES)


def username(uid):
    """The author's name as JSON-safe bytes."""
    if bt_table_seek(C_USERS, uid, 0, _res) or _res[0]:
        raise Fallback
    p = record(C_USERS)
    h, i = varint(p, 0)
    t0, i = varint(p, i)
    t1, i = varint(p, i)
    if t1 < 13 or not t1 & 1 or t0 != 0:
        raise Fallback
    name = unpack(cast(CP, p + h), (t1 - 13) >> 1)
    return name if len(name.translate(None, _NEEDS_ESCAPE)) == len(name) else quote(name)


def post_row():
    """(user_id, body, created_at) of the row under C_POSTS, with body JSON-safe."""
    p = record(C_POSTS)
    h, i = varint(p, 0)
    t0, i = varint(p, i)
    t1, i = varint(p, i)
    t2, i = varint(p, i)
    t3, i = varint(p, i)
    if t0 != 0 or t1 > 9 or t2 < 13 or not t2 & 1 or t3 < 13 or not t3 & 1:
        raise Fallback
    uid = column_uint(p, h, t1)
    b = h + SERIAL_LEN[t1]
    n = (t2 - 13) >> 1
    body = unpack(cast(CP, p + b), n)
    if len(body.translate(None, _NEEDS_ESCAPE)) != n:
        body = quote(body)
    return uid, body, unpack(cast(CP, p + b + n), (t3 - 13) >> 1)


def read_feed():
    if not read_open:
        open_read()
    if bt_first(C_RECENT, _res):
        raise Fallback
    if _res[0]:
        return b'{"posts":[]}'
    ids = []
    while True:
        p = record(C_RECENT)
        hs = p[0]
        t0 = p[1]
        t1 = p[2]
        if hs != 3 or t0 < 13:  # both varints one byte: created_at is 24 bytes, ids fit
            raise Fallback
        ids.append(column_uint(p, hs + ((t0 - 13) >> 1), t1))
        if len(ids) == FEED_N or bt_next(C_RECENT, 0):
            break
    lo = min(ids)
    hi = max(ids)
    span = hi - lo + 1
    if span > FEED_SPAN:
        raise Fallback
    counts = [0] * span
    more = seek_likes(lo)
    while more:
        p = record(C_LIKES)
        pid = column_uint(p, p[0], p[1])
        if pid > hi:
            break
        counts[pid - lo] += 1
        more = bt_next(C_LIKES, 0) == 0
    rows = [None] * span
    if bt_table_seek(C_POSTS, lo, 0, _res):
        raise Fallback
    if _res[0]:
        raise Fallback  # lo came from the index, so the row exists
    pid = lo
    while True:
        rows[pid - lo] = post_row()
        if pid == hi or bt_next(C_POSTS, 0):
            break
        pid = bt_key(C_POSTS)
        if pid > hi:
            break
    out = []
    for pid in ids:
        i = pid - lo
        row = rows[i]
        if row is None:
            raise Fallback
        out.append(b'{"id":%d,"body":"%s","created_at":"%s","author":"%s","like_count":%d}'
                   % (pid, row[1], row[2], username(row[0]), counts[i]))
    return b'{"posts":[' + b",".join(out) + b"]}"


def read_post(pid):
    """The post body, or None if the post does not exist."""
    if not read_open:
        open_read()
    if bt_table_seek(C_POSTS, pid, 0, _res):
        raise Fallback
    if _res[0]:
        return None
    uid, body, created = post_row()
    n = 0
    more = seek_likes(pid)
    while more:
        p = record(C_LIKES)
        if column_uint(p, p[0], p[1]) != pid:
            break
        n += 1
        more = bt_next(C_LIKES, 0) == 0
    return b'{"post":{"id":%d,"body":"%s","created_at":"%s","author":"%s","like_count":%d}}' % (pid, body, created, username(uid), n)


# --- responses ------------------------------------------------------------------------------
REASONS = {200: b"OK", 201: b"Created", 400: b"Bad Request", 401: b"Unauthorized", 404: b"Not Found",
           413: b"Payload Too Large", 431: b"Request Header Fields Too Large", 500: b"Internal Server Error",
           503: b"Service Unavailable"}
PREFIX = {}
date_second = 0


def refresh_prefixes(now):
    global date_second
    date_second = int(now)
    date = time.strftime("%a, %d %b %Y %H:%M:%S GMT", time.gmtime(now)).encode()
    for status, reason in REASONS.items():
        head = b"HTTP/1.1 %d %s\r\nContent-Type: application/json\r\nDate: %s\r\n" % (status, reason, date)
        PREFIX[status, False] = head + b"Content-Length: "
        PREFIX[status, True] = head + b"Connection: close\r\nContent-Length: "


refresh_prefixes(time.time())


def err(status, message):
    return status, b'{"error":"' + message + b'"}'


E_NOT_FOUND = err(404, b"not found")
E_BAD_ID = err(400, b"invalid post id")
E_NO_POST = err(404, b"post not found")
E_NO_TOKEN = err(401, b"missing bearer token")
E_BAD_TOKEN = err(401, b"invalid or expired token")
E_BAD_PAYLOAD = err(401, b"invalid token payload")
E_BAD_JSON = err(400, b"malformed JSON body")
E_NO_BODY = err(400, b"body is required")
E_LONG_BODY = err(400, b"body must be at most 500 characters")
E_INTERNAL = err(500, b"internal server error")
BAD_REQUEST = PREFIX[400, True] + b'23\r\n\r\n{"error":"bad request"}'
HEADER_TOO_LARGE = PREFIX[431, True] + b'43\r\n\r\n{"error":"request header fields too large"}'

# --- auth -----------------------------------------------------------------------------------
B64_OK = frozenset(b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
TO_STD = bytes.maketrans(b"-_", b"+/")
FROM_STD = bytes.maketrans(b"+/", b"-_")
a2b = binascii.a2b_base64
b2a = binascii.b2a_base64
compare = hmac.compare_digest
_hffi = __import__("cffi").FFI()
_hffi.cdef("""typedef struct evp_md_st EVP_MD; const EVP_MD *EVP_sha256(void);
              unsigned char *HMAC(const EVP_MD *evp_md, const void *key, int key_len,
                                  const unsigned char *d, size_t n, unsigned char *md, unsigned int *md_len);""")
_crypto = _hffi.dlopen("libcrypto.so.3")
_SHA256 = _crypto.EVP_sha256()
_mac_out = _hffi.new("unsigned char[32]")
_mac_len = _hffi.new("unsigned int *")
_HMAC = _crypto.HMAC
_mac_buffer = _hffi.buffer


def hmac_sha256(msg):
    # One-shot OpenSSL HMAC into a reused buffer: PyPy's hmac module is slower and frees its contexts only at a major GC.
    _HMAC(_SHA256, SECRET, len(SECRET), msg, len(msg), _mac_out, _mac_len)
    return _mac_buffer(_mac_out, 32)[:]


def b64d(seg):
    if not seg or not B64_OK.issuperset(seg):
        raise ValueError
    return a2b(seg.translate(TO_STD) + b"=" * (-len(seg) % 4))


def authenticate(value):
    """value: raw Authorization header bytes (or None). Returns (user_id, username) or (None, error)."""
    if value is None or not value.startswith(b"Bearer "):
        return None, E_NO_TOKEN
    token = value[7:]
    try:
        head64, payload64, sig64 = token.split(b".")
        if head64 != HS256_HEADER:
            head = loads(b64d(head64))
            if type(head) is not dict or head.get("alg") != "HS256":
                return None, E_BAD_TOKEN
        mac = b2a(hmac_sha256(token[:len(head64) + 1 + len(payload64)]), newline=False)
        if not compare(mac[:-1].translate(FROM_STD), sig64):
            return None, E_BAD_TOKEN
        payload = loads(b64d(payload64))
        if type(payload) is not dict:
            return None, E_BAD_TOKEN
        now = time.time()
        exp = payload.get("exp")
        if type(exp) not in (int, float) or now >= exp:  # exp is required
            return None, E_BAD_TOKEN
        nbf = payload.get("nbf")
        if nbf is not None and (type(nbf) not in (int, float) or now < nbf):
            return None, E_BAD_TOKEN
    except (ValueError, UnicodeError, binascii.Error):
        return None, E_BAD_TOKEN
    sub = payload.get("sub")
    name = payload.get("username")
    if type(sub) is not str or not (sub.isascii() and sub.isdigit()) or type(name) is not str:
        return None, E_BAD_PAYLOAD
    uid = int(sub)
    if uid <= 0 or uid > MAX_ID:
        return None, E_BAD_PAYLOAD
    return uid, name


def parse_id(raw):
    """b'123' -> 123; None if not a positive decimal integer; MAX_ID+1 if too large to exist."""
    if not raw.isdigit():
        return None
    n = int(raw)
    if n <= 0:
        return None
    return n if n <= MAX_ID else MAX_ID + 1


# --- handlers -------------------------------------------------------------------------------
def health():
    try:
        if read_open:
            close_read()
        rc = step(S_ONE)
        reset(S_ONE)
        if rc != SQLITE_ROW:
            raise OSError(ffi.string(lib.sqlite3_errmsg(db)).decode())
    except Exception as exc:
        return 503, json.dumps({"status": "degraded", "db": "unreachable", "error": str(exc)}, separators=(",", ":")).encode()
    return 200, b'{"status":"ok","db":"ok","uptime_s":%d}' % int(time.monotonic() - START)


def get_feed():
    try:
        return 200, read_feed()
    except Fallback:
        if read_open:
            close_read()
        return 200, sql_blob(S_FEED)


def get_post(raw_id):
    pid = parse_id(raw_id)
    if pid is None:
        return E_BAD_ID
    if pid > MAX_ID:
        return E_NO_POST
    try:
        body = read_post(pid)
    except Fallback:
        if read_open:
            close_read()
        bind_int(S_POST, 1, pid)
        body = sql_blob(S_POST)
    return (200, body) if body is not None else E_NO_POST


def do_create(uid, name, text_bytes):
    bind_int(S_CREATE, 1, uid)
    bind_text(S_CREATE, 2, text_bytes, len(text_bytes), TRANSIENT)
    rc = step(S_CREATE)
    if rc != SQLITE_ROW:
        reset(S_CREATE)
        return E_INTERNAL
    pid = column_int(S_CREATE, 0)
    created = unpack(cast(CP, column_text(S_CREATE, 1)), column_bytes(S_CREATE, 1))
    rc = step(S_CREATE)
    reset(S_CREATE)
    if rc != SQLITE_DONE:
        return E_INTERNAL
    return 201, b'{"post":{"id":%d,"body":%s,"created_at":"%s","author":%s,"like_count":0}}' % (
        pid, json.dumps(text_bytes.decode("utf-8"), separators=(",", ":"), ensure_ascii=False).encode("utf-8"), created,
        json.dumps(name, separators=(",", ":"), ensure_ascii=False).encode("utf-8"))


def do_like(uid, pid):
    bind_int(S_LIKE, 1, uid)
    bind_int(S_LIKE, 2, pid)
    rc = step(S_LIKE)
    if rc == SQLITE_ROW:
        rc = step(S_LIKE)
        reset(S_LIKE)
        if rc != SQLITE_DONE:
            return E_INTERNAL
        return 201, b'{"liked":true,"already_liked":false,"post_id":%d}' % pid
    reset(S_LIKE)
    if rc != SQLITE_DONE:
        return E_INTERNAL
    bind_int(S_EXISTS, 1, pid)
    rc = step(S_EXISTS)
    reset(S_EXISTS)
    if rc == SQLITE_ROW:
        return 200, b'{"liked":true,"already_liked":true,"post_id":%d}' % pid
    return E_NO_POST if rc == SQLITE_DONE else E_INTERNAL


def prepare_write(method_is_create, auth, arg):
    """Everything that doesn't touch the database. Returns (fn, a, b, c) to run in the batch's transaction, or an error tuple."""
    uid, name = authenticate(auth)
    if uid is None:
        return name
    if method_is_create:
        try:
            data = loads(arg)
        except ValueError:
            return E_BAD_JSON
        text = data.get("body") if type(data) is dict else None
        if type(text) is not str:
            return E_NO_BODY
        text = text.strip(WHITESPACE)
        if not text:
            return E_NO_BODY
        if len(text) > 500:
            return E_LONG_BODY
        return do_create, uid, name, text.encode("utf-8")
    pid = parse_id(arg)
    if pid is None:
        return E_BAD_ID
    if pid > MAX_ID:
        return E_NO_POST
    return do_like, uid, pid, None


def route(method, target, auth, body):
    """A (status, payload) answer, or a (fn, a, b, c) write for the batch's transaction."""
    q = target.find(b"?")
    if q >= 0:
        target = target[:q]
    if method == b"GET":
        if target == b"/feed":
            return get_feed()
        if target[:7] == b"/posts/":
            rest = target[7:]
            if rest and b"/" not in rest:
                return get_post(rest)
            return E_NOT_FOUND
        if target == b"/health":
            return health()
        return E_NOT_FOUND
    if method == b"POST":
        if target == b"/posts":
            return prepare_write(True, auth, body)
        if target[:7] == b"/posts/" and target[-5:] == b"/like":
            rest = target[7:-5]
            if rest and b"/" not in rest:
                return prepare_write(False, auth, rest)
    return E_NOT_FOUND


# --- io_uring -------------------------------------------------------------------------------
HOST = os.environ.get("HOST", "127.0.0.1")
PORT = int(os.environ.get("PORT", "3000"))
MAX_HEAD = 16384
MAX_BODY = 1 << 20
MAX_BATCH_OUT = 1 << 18
_soft, NOFILE = resource.getrlimit(resource.RLIMIT_NOFILE)
if _soft != NOFILE:
    resource.setrlimit(resource.RLIMIT_NOFILE, (NOFILE, NOFILE))
    NOFILE = resource.getrlimit(resource.RLIMIT_NOFILE)[0]
TABLE = max(256, min(NOFILE - 64, 65471))   # a fixed-file table can't be larger than RLIMIT_NOFILE
MAX_RINGS = 8                               # several tables: direct descriptors aren't limited by the process's table
ROLL_AT = max(TABLE - 8192, TABLE // 2)     # start accepting on the next ring as well
STOP_AT = max(TABLE - 4096, TABLE * 3 // 4)  # stop accepting on this one, before the table is full
NBUF = 4096
BUFSZ = 1024
BGID = 1
LISTENERS = 8                               # each has its own accept queue of somaxconn entries

IORING_SETUP_CQSIZE = 1 << 3
IORING_SETUP_COOP_TASKRUN = 1 << 8
IORING_SETUP_SUBMIT_ALL = 1 << 7
IORING_ENTER_GETEVENTS = 1
OP_ACCEPT, OP_ASYNC_CANCEL, OP_CLOSE, OP_SEND, OP_RECV, OP_SHUTDOWN, OP_POLL_ADD, OP_TIMEOUT = 13, 14, 19, 26, 27, 34, 6, 11
IOSQE_FIXED_FILE = 1
IOSQE_IO_LINK = 4
IOSQE_ASYNC = 16
IOSQE_BUFFER_SELECT = 32
IOSQE_CQE_SKIP = 64
RECV_MULTISHOT = 2
ACCEPT_MULTISHOT = 1
POLL_ADD_MULTI = 1
CQE_F_BUFFER = 1
CQE_F_MORE = 2
FILE_INDEX_ALLOC = 0xFFFFFFFF
CANCEL_FD = 2
CANCEL_ALL = 1
CANCEL_FD_FIXED = 8
MSG_WAITALL = 0x100
MSG_NOSIGNAL = 0x4000
SEND_FLAGS = (MSG_WAITALL | MSG_NOSIGNAL) << 32
ENOBUFS = 105
ECANCELED = 125
# user_data: op << 48 | seg << 24 | gen << 16 | slot
U_RECV = 1 << 48
U_SEND = 2 << 48
U_ACCEPT = 3 << 48
U_CLOSE = 4 << 48
U_IGNORE = 5 << 48
U_TIMER = 6 << 48
OPMASK = 7 << 48

ST_CLOSING = 1   # close once the sends in flight are done
ST_CLOSED = 2    # the close chain has been issued

SEG_SIZE = 1 << 20
_segs = []       # [pointer, address]; a segment is reused once its sends have all completed
_seg_refs = []
_seg_free = []
_cur = 0
_cur_off = 0
_seg_ptr = None
_seg_addr = 0


def add_segment():
    p = lib.anon_mmap(SEG_SIZE)
    if p == cast("void *", -1):
        raise MemoryError
    p = cast(CP, p)
    _segs.append((p, int(cast("uintptr_t", p))))
    _seg_refs.append(0)
    return len(_segs) - 1


def next_segment():
    global _cur, _cur_off, _seg_ptr, _seg_addr
    if _seg_refs[_cur] == 0:
        _seg_free.append(_cur)
    if _seg_free:
        _cur = _seg_free.pop()
    else:
        _cur = add_segment()
    _cur_off = 0
    _seg_ptr, _seg_addr = _segs[_cur]


class Ring:
    def __init__(self, index):
        self.index = index
        entries = 4096
        cq = 65536
        while True:
            p = new("struct io_uring_params *")
            p.flags = IORING_SETUP_CQSIZE | IORING_SETUP_SUBMIT_ALL | IORING_SETUP_COOP_TASKRUN
            p.cq_entries = cq
            fd = lib.ring_setup(entries, p)
            if fd >= 0:
                break
            if cq > 8192:
                cq //= 2
                continue
            raise OSError(lib.get_errno(), "io_uring_setup")
        self.fd = fd
        sq_size = p.sq_off.array + p.sq_entries * 4
        cq_size = p.cq_off.cqes + p.cq_entries * 16
        size = max(sq_size, cq_size)
        rings = lib.ring_mmap(fd, size, 0)  # IORING_FEAT_SINGLE_MMAP
        if rings == cast("void *", -1):
            raise OSError(lib.get_errno(), "mmap rings")
        sqes = lib.ring_mmap(fd, p.sq_entries * 64, 0x10000000)
        if sqes == cast("void *", -1):
            raise OSError(lib.get_errno(), "mmap sqes")
        base = cast(CP, rings)
        u = lambda off: cast("unsigned *", base + off)
        self.sq_khead = u(p.sq_off.head)
        self.sq_ktail = u(p.sq_off.tail)
        self.sq_mask = u(p.sq_off.ring_mask)[0]
        self.sq_entries = p.sq_entries
        array = u(p.sq_off.array)
        for i in range(p.sq_entries):
            array[i] = i
        self.cq_khead = u(p.cq_off.head)
        self.cq_ktail = u(p.cq_off.tail)
        self.cq_mask = u(p.cq_off.ring_mask)[0]
        self.cqes = cast("long long *", base + p.cq_off.cqes)
        self.sqes = cast("unsigned long long *", sqes)
        self.sq_tail = 0
        self.sq_submitted = 0
        self.cq_head = 0
        if lib.ring_register_sparse(fd, TABLE):
            raise OSError(lib.get_errno(), "register files")
        # provided buffers
        br = lib.anon_mmap(NBUF * 16)
        self.br = cast("unsigned long long *", br)
        self.br32 = cast("unsigned *", br)
        self.br16 = cast("unsigned short *", br)
        if lib.ring_register_bufs(fd, br, NBUF, BGID, 0):
            # Ubuntu's 6.8.0-136+ kernels reject the registration unless a reserved byte is set (Launchpad #2162843).
            if lib.ring_register_bufs(fd, br, NBUF, BGID, 1):
                raise OSError(lib.get_errno(), "register buffer ring")
        self.buf_ptr = cast(CP, lib.anon_mmap(NBUF * BUFSZ))
        self.buf_addr = int(cast("uintptr_t", self.buf_ptr))
        self.br_tail = 0
        for i in range(NBUF):
            self.give_buffer(i)
        lib.store_release16(self.br16 + 7, self.br_tail & 0xFFFF)
        self.free_bufs = NBUF
        self.gen = bytearray(TABLE)
        self.state = bytearray(TABLE)
        self.inflight = bytearray(TABLE)
        self.active = bytearray(TABLE)   # idle sweep: 1 if there was a request this period
        self.open = bytearray(TABLE)
        self.pending = {}                # slot -> bytes received but not yet answered
        self.rearm = []                  # slots whose multishot receive ran out of buffers
        self.continued = set()           # slots already sent "100 Continue" for the request in progress
        self.conns = 0
        self.accepting = False
        self.draining = False

    def give_buffer(self, bid):
        i = self.br_tail & (NBUF - 1)
        self.br[i * 2] = self.buf_addr + bid * BUFSZ
        self.br32[i * 4 + 2] = BUFSZ
        self.br16[i * 8 + 6] = bid
        self.br_tail = (self.br_tail + 1) & 0xFFFF

    def sqe(self):
        """The next SQE as an index into the uint64 view of the SQE array. Submits first if the queue is full."""
        if self.sq_tail - self.sq_submitted >= self.sq_entries:
            self.submit()
        i = (self.sq_tail & self.sq_mask) * 8
        self.sq_tail = (self.sq_tail + 1) & 0xFFFFFFFF
        return i

    def submit(self):
        n = (self.sq_tail - self.sq_submitted) & 0xFFFFFFFF
        if n:
            lib.store_release(self.sq_ktail, self.sq_tail)
            done = lib.ring_enter(self.fd, n, 0, 0)
            if done > 0:
                self.sq_submitted = (self.sq_submitted + done) & 0xFFFFFFFF

    def put(self, opcode, flags, ioprio, fd, off, addr, length, msg, ud, file_index=0, buf_group=0):
        i = self.sqe()
        q = self.sqes
        q[i] = opcode | flags << 8 | ioprio << 16 | (fd & 0xFFFFFFFF) << 32
        q[i + 1] = off
        q[i + 2] = addr
        q[i + 3] = length | msg << 32
        q[i + 4] = ud
        q[i + 5] = buf_group | file_index << 32  # buf_group at byte 40, file_index at byte 44
        q[i + 6] = 0
        q[i + 7] = 0

    def arm_recv(self, slot):
        i = self.sqe()
        q = self.sqes
        q[i] = OP_RECV | (IOSQE_FIXED_FILE | IOSQE_BUFFER_SELECT) << 8 | RECV_MULTISHOT << 16 | slot << 32
        q[i + 1] = 0
        q[i + 2] = 0
        q[i + 3] = 0
        q[i + 4] = U_RECV | self.gen[slot] << 16 | slot
        q[i + 5] = BGID
        q[i + 6] = 0
        q[i + 7] = 0

    def arm_accepts(self):
        self.accepting = True
        for lfd in LFDS:
            self.put(OP_ACCEPT, 0, ACCEPT_MULTISHOT, lfd, 0, 0, 0, 0, U_ACCEPT | lfd, FILE_INDEX_ALLOC)

    def cancel_accepts(self):
        self.accepting = False
        for lfd in LFDS:
            self.put(OP_ASYNC_CANCEL, IOSQE_CQE_SKIP, 0, -1, 0, U_ACCEPT | lfd, 0, 0, U_IGNORE)

    def send(self, slot, data):
        """Copy data into the current arena segment and queue a send for it."""
        global _cur_off
        n = len(data)
        if n > SEG_SIZE:
            self.close_slot(slot)
            return
        if _cur_off + n > SEG_SIZE:
            next_segment()
        memmove(_seg_ptr + _cur_off, data, n)
        addr = _seg_addr + _cur_off
        _cur_off += n
        _seg_refs[_cur] += 1
        self.inflight[slot] += 1
        i = self.sqe()
        q = self.sqes
        q[i] = OP_SEND | IOSQE_FIXED_FILE << 8 | slot << 32
        q[i + 1] = 0
        q[i + 2] = addr
        q[i + 3] = n | SEND_FLAGS
        q[i + 4] = U_SEND | _cur << 24 | self.gen[slot] << 16 | slot
        q[i + 5] = 0
        q[i + 6] = 0
        q[i + 7] = 0

    def close_slot(self, slot):
        """Cancel the receive, shut the socket down, free the slot. A request on a direct descriptor keeps the socket
        alive after its slot closes, so the receive has to go first. Waits for sends in flight."""
        st = self.state[slot]
        if st & ST_CLOSED:
            return
        if self.inflight[slot]:
            self.state[slot] = st | ST_CLOSING
            return
        self.state[slot] = ST_CLOSED
        self.pending.pop(slot, None)
        self.put(OP_ASYNC_CANCEL, IOSQE_FIXED_FILE | IOSQE_IO_LINK | IOSQE_CQE_SKIP, 0, slot, 0, 0, 0, CANCEL_FD | CANCEL_ALL | CANCEL_FD_FIXED, U_IGNORE)
        self.put(OP_SHUTDOWN, IOSQE_FIXED_FILE | IOSQE_IO_LINK | IOSQE_CQE_SKIP, 0, slot, 0, 0, 2, 0, U_IGNORE)
        self.put(OP_CLOSE, 0, 0, 0, 0, 0, 0, 0, U_CLOSE | slot, slot + 1)


# --- HTTP -----------------------------------------------------------------------------------
deferred = []   # (ring, slot, gen, keep, fn, a, b, c): writes waiting for the batch's transaction


def dechunk(data, start):
    """Decode a chunked body starting at start. None: incomplete; False: malformed; else (body, end)."""
    parts = []
    pos = start
    total = 0
    while True:
        le = data.find(b"\r\n", pos)
        if le < 0:
            return None
        try:
            size = int(data[pos:le].split(b";", 1)[0], 16)
        except ValueError:
            return False
        if size < 0:
            return False
        if size == 0:
            te = data.find(b"\r\n\r\n", le)
            if te < 0:
                return None
            return b"".join(parts), te + 4
        total += size
        if total > MAX_BODY:
            return False
        if le + 2 + size + 2 > len(data):
            return None
        parts.append(data[le + 2:le + 2 + size])
        pos = le + 2 + size + 2


def run_write_now(w):
    """A write that can't wait for the batch (pipelined requests must answer in order)."""
    if read_open:
        close_read()
    fn, a, b, c = w
    try:
        return fn(a, b, c) if fn is do_create else fn(a, b)
    except Exception:
        return E_INTERNAL


def on_data(r, slot, data):
    """Parse and answer every complete request in data."""
    pos = 0
    n = len(data)
    out = []
    keep = True
    continued = False
    size = 0
    while pos < n:
        if size >= MAX_BATCH_OUT:  # a client pipelining without reading: the rest waits until this send completes
            break
        he = data.find(b"\r\n\r\n", pos)
        if he < 0:
            if n - pos > MAX_HEAD:
                out.append(HEADER_TOO_LARGE)
                keep = False
            break
        le = data.find(b"\r\n", pos)
        line = data[pos:le]
        sp1 = line.find(b" ")
        sp2 = line.rfind(b" ")
        if sp1 <= 0 or sp2 <= sp1:
            out.append(BAD_REQUEST)
            keep = False
            break
        method = line[:sp1]
        target = line[sp1 + 1:sp2]
        http11 = line[sp2 + 1:] == b"HTTP/1.1"
        hdr = data[le:he + 2].lower()  # b"\r\nname: value\r\n...\r\n"
        cl = 0
        auth = None
        chunked = False
        if len(hdr) > 2:
            i = hdr.find(b"\r\ncontent-length:")
            t = hdr.find(b"\r\ntransfer-encoding:")
            if i >= 0:
                try:
                    cl = int(hdr[i + 17:hdr.find(b"\r\n", i + 17)])
                except ValueError:
                    cl = -1
                if cl < 0 or cl > MAX_BODY or t >= 0:  # both framings at once: refuse (RFC 9112 6.3)
                    out.append(BAD_REQUEST)
                    keep = False
                    break
            elif t >= 0:
                if not hdr[t + 20:hdr.find(b"\r\n", t + 20)].rstrip().endswith(b"chunked"):
                    out.append(BAD_REQUEST)
                    keep = False
                    break
                chunked = True
            i = hdr.find(b"\r\nauthorization:")
            if i >= 0:
                auth = data[le + i + 16:le + hdr.find(b"\r\n", i + 16)].strip()
            i = hdr.find(b"\r\nconnection:")
            if i >= 0:
                tokens = hdr[i + 13:hdr.find(b"\r\n", i + 13)].replace(b" ", b"").replace(b"\t", b"").split(b",")
                if http11:
                    if b"close" in tokens:
                        keep = False
                elif b"keep-alive" not in tokens:
                    keep = False
            elif not http11:
                keep = False
        elif not http11:
            keep = False
        if chunked:
            done = dechunk(data, he + 4)
            if done is None:
                if len(data) > MAX_HEAD + MAX_BODY:
                    out.append(BAD_REQUEST)
                    keep = False
                break
            if done is False:
                out.append(BAD_REQUEST)
                keep = False
                break
            body, end = done
        else:
            end = he + 4 + cl
            if end > n:
                if b"\r\nexpect: 100-continue" in hdr and not out and slot not in r.continued:
                    r.continued.add(slot)
                    continued = True
                break
            body = data[he + 4:end] if cl else b""
        if r.continued:
            r.continued.discard(slot)
        try:
            answer = route(method, target, auth, body)
        except Exception:
            answer = E_INTERNAL
        if type(answer[0]) is not int:
            if not out and end == n and keep:
                # The usual case, one write alone in its read: run it in the batch's transaction, answer after the commit.
                r.inflight[slot] += 1
                deferred.append((r, slot, r.gen[slot], answer))
                return
            answer = run_write_now(answer)
        status, payload = answer
        out.append(PREFIX[status, not keep] + b"%d\r\n\r\n" % len(payload) + payload)
        size += len(payload)
        pos = end
        if not keep:
            break
    if keep and pos < n:
        r.pending[slot] = data[pos:]
    if continued:
        out.append(b"HTTP/1.1 100 Continue\r\n\r\n")
    if out:
        r.send(slot, out[0] if len(out) == 1 else b"".join(out))
    if not keep:
        r.close_slot(slot)


def run_deferred():
    """The batch's writes in one transaction. Every response goes out only after the commit."""
    if read_open:
        close_read()
    ok = step(S_BEGIN) == SQLITE_DONE
    reset(S_BEGIN)
    answers = []
    for item in deferred:
        fn, a, b, c = item[3]
        try:
            answers.append(fn(a, b, c) if fn is do_create else fn(a, b))
        except Exception:
            answers.append(E_INTERNAL)
    committed = ok and step(S_COMMIT) == SQLITE_DONE
    reset(S_COMMIT)
    if not committed and ok:
        step(S_ROLLBACK)
        reset(S_ROLLBACK)
    for k, item in enumerate(deferred):
        r, slot, gen = item[0], item[1], item[2]
        status, payload = answers[k] if committed else E_INTERNAL
        if r.gen[slot] != gen or r.state[slot] & ST_CLOSED:
            continue
        r.inflight[slot] -= 1
        r.send(slot, PREFIX[status, False] + b"%d\r\n\r\n" % len(payload) + payload)
    del deferred[:]


# --- event loop -----------------------------------------------------------------------------
LFDS = []
_lsocks = []
for _ in range(LISTENERS):
    _s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    _s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    _s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    _s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    _s.bind((HOST, PORT))
    _s.listen(4096)
    _lsocks.append(_s)
    LFDS.append(_s.fileno())

rings = [Ring(0)]
_events = []
_timespec = new("long long[2]", [1, 0])
_timespec_addr = int(cast("uintptr_t", _timespec))


def start_ring():
    if len(rings) >= MAX_RINGS:
        return None
    try:
        r = Ring(len(rings))
    except OSError:
        return None
    efd = lib.eventfd(0, 0)
    if efd < 0 or lib.ring_register_eventfd(r.fd, efd):
        return None
    _events.append(efd)
    # Ring 0 is the one the loop waits on; a completion on any other ring wakes it through this eventfd.
    rings[0].put(OP_POLL_ADD, 0, POLL_ADD_MULTI, efd, 0, 0, 0, 1, U_IGNORE)
    rings.append(r)
    return r


def replay_pending(r, slot):
    data = r.pending.pop(slot, None)
    if data is not None:
        on_data(r, slot, data)


def drain(r):
    """Handle every completion on this ring."""
    head = r.cq_head
    tail = lib.load_acquire(r.cq_ktail)
    if head == tail:
        return
    cqes = r.cqes
    mask = r.cq_mask
    gen = r.gen
    inflight = r.inflight
    state = r.state
    pending = r.pending
    active = r.active
    buf_ptr = r.buf_ptr
    returned = False
    while head != tail:
        i = (head & mask) * 2
        head = (head + 1) & 0xFFFFFFFF
        ud = cqes[i]
        w = cqes[i + 1]
        res = w & 0xFFFFFFFF
        if res >= 0x80000000:
            res -= 0x100000000
        flags = (w >> 32) & 0xFFFFFFFF
        op = ud & OPMASK
        if op == U_RECV:
            slot = ud & 0xFFFF
            live = ((ud >> 16) & 0xFF) == gen[slot] and not state[slot] & ST_CLOSED
            if flags & CQE_F_BUFFER:
                bid = flags >> 16
                if live and res > 0:
                    data = unpack(buf_ptr + bid * BUFSZ, res)
                    r.give_buffer(bid)
                    returned = True
                    active[slot] = 1
                    prev = pending.get(slot)
                    if prev is not None:
                        del pending[slot]
                        data = prev + data
                        if len(data) > MAX_HEAD + MAX_BODY:
                            r.close_slot(slot)
                            continue
                    if inflight[slot] or state[slot]:
                        if len(data) > MAX_HEAD + MAX_BODY:  # a client that sends but never reads
                            r.close_slot(slot)
                            continue
                        pending[slot] = data
                    else:
                        on_data(r, slot, data)
                else:
                    r.give_buffer(bid)
                    returned = True
            if not flags & CQE_F_MORE and live and not state[slot] & ST_CLOSED:
                if res == -ENOBUFS:
                    r.rearm.append(slot)
                elif res > 0:
                    r.arm_recv(slot)
                else:
                    r.close_slot(slot)
        elif op == U_SEND:
            seg = (ud >> 24) & 0xFFFFFF
            _seg_refs[seg] -= 1
            if _seg_refs[seg] == 0 and seg != _cur:
                _seg_free.append(seg)
            slot = ud & 0xFFFF
            if ((ud >> 16) & 0xFF) == gen[slot] and not state[slot] & ST_CLOSED:
                inflight[slot] -= 1
                if res < 0:
                    state[slot] |= ST_CLOSING
                if not inflight[slot]:
                    if state[slot] & ST_CLOSING:
                        r.close_slot(slot)
                    elif slot in pending:
                        replay_pending(r, slot)
        elif op == U_ACCEPT:
            if res >= 0:
                slot = res
                gen[slot] = (gen[slot] + 1) & 0xFF
                state[slot] = 0
                inflight[slot] = 0
                active[slot] = 1
                r.open[slot] = 1
                r.conns += 1
                r.arm_recv(slot)
                if r.conns >= ROLL_AT:
                    if r.conns >= STOP_AT and r.accepting:
                        r.cancel_accepts()
                    if r.index == len(rings) - 1:
                        nr = start_ring()
                        if nr is not None:
                            nr.arm_accepts()
            if not flags & CQE_F_MORE and r.accepting and r.conns < STOP_AT and res != -ECANCELED:
                r.put(OP_ACCEPT, 0, ACCEPT_MULTISHOT, ud & 0xFFFF, 0, 0, 0, 0, ud, FILE_INDEX_ALLOC)
        elif op == U_CLOSE:
            slot = ud & 0xFFFF
            r.open[slot] = 0
            state[slot] = 0
            r.continued.discard(slot)
            r.conns -= 1
            if not r.accepting and r.conns < ROLL_AT // 2 and len(rings) > r.index + 1 and not rings[-1].accepting:
                r.arm_accepts()
    r.cq_head = head
    lib.store_release(r.cq_khead, head)
    if returned:
        lib.store_release16(r.br16 + 7, r.br_tail & 0xFFFF)
    if r.rearm:
        # Bounded by what the buffers can hold: re-arming them all at once would just run the buffers dry again.
        again = r.rearm[:NBUF // 2]
        del r.rearm[:NBUF // 2]
        for slot in again:
            if not r.state[slot] & ST_CLOSED:
                r.arm_recv(slot)


IDLE_PERIOD = 120.0  # a connection with no request for one to two periods is closed


def sweep():
    for r in rings:
        active = r.active
        opened = r.open
        for slot in range(TABLE):
            if opened[slot]:
                if not active[slot] and not r.inflight[slot]:
                    r.close_slot(slot)
                active[slot] = 0


def serve():
    next_sweep = time.monotonic() + IDLE_PERIOD
    r0 = rings[0]
    r0.arm_accepts()
    r0.put(OP_TIMEOUT, 0, 0, -1, 0, _timespec_addr, 1, 64, U_TIMER)  # multishot, once a second
    fd0 = r0.fd
    while True:
        n = (r0.sq_tail - r0.sq_submitted) & 0xFFFFFFFF
        if n:
            lib.store_release(r0.sq_ktail, r0.sq_tail)
        done = lib.ring_enter(fd0, n, 1, IORING_ENTER_GETEVENTS)
        if done > 0:
            r0.sq_submitted = (r0.sq_submitted + done) & 0xFFFFFFFF
        for r in rings:
            drain(r)
        if deferred:
            run_deferred()
        if read_open:
            close_read()
        for k in range(1, len(rings)):
            rings[k].submit()
        now = time.time()
        if int(now) != date_second:
            refresh_prefixes(now)
        if time.monotonic() >= next_sweep:
            sweep()
            next_sweep = time.monotonic() + IDLE_PERIOD


next_segment_ready = add_segment()
_cur = next_segment_ready
_seg_ptr, _seg_addr = _segs[_cur]
gc.collect()

if __name__ == "__main__":
    serve()
