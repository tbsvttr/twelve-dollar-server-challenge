module app;

import arsd.cgi;
import arsd.sqlite;
import arsd.database : Row, ResultSet;

import jwtlited : decode;
import jwtlited.phobos : HS256Handler;

import std.array : appender, Appender;
import std.base64 : Base64URLNoPadding;
import std.conv : to;
import std.datetime : Clock, SysTime;
import std.json : JSONValue, JSONType, parseJSON, JSONException;
import std.process : environment;
import std.string : strip, startsWith, endsWith, indexOf;

enum feedSql = `SELECT p.id, p.body, p.created_at, u.username,
    (SELECT count(*) FROM likes l WHERE l.post_id = p.id) AS like_count
    FROM posts p JOIN users u ON u.id = p.user_id
    ORDER BY p.created_at DESC, p.id DESC LIMIT 20`;

enum postSql = `SELECT p.id, p.body, p.created_at, u.username,
    (SELECT count(*) FROM likes l WHERE l.post_id = p.id) AS like_count
    FROM posts p JOIN users u ON u.id = p.user_id
    WHERE p.id = ?`;

enum existsSql = `SELECT 1 FROM posts WHERE id = ?`;

enum insertPostSql =
    `INSERT INTO posts (user_id, body) VALUES (?, ?) RETURNING id, created_at`;

enum insertLikeSql =
    `INSERT INTO likes (user_id, post_id)
     SELECT ?, ? WHERE EXISTS (SELECT 1 FROM posts WHERE id = ?)
     ON CONFLICT (user_id, post_id) DO NOTHING`;

enum maxPostID = 9007199254740992L; // 2^53, beyond this ids are out of scope

private __gshared string g_dbPath;
private __gshared string g_secret;
private __gshared SysTime g_started;
private __gshared HS256Handler g_jwt;

/**
 * One sqlite connection plus its prepared statements, cached per worker thread.
 * arsd's embedded server dispatches requests from a thread pool (and, in the
 * hybrid build, one connection per fiber is unnecessary because our handler
 * never yields), so a thread-local connection gives us a real connection pool
 * for free without any locking.
 */
final class Worker
{
    Sqlite db;
    Statement* feedStmt;
    Statement* postStmt;
    Statement* existsStmt;
    Statement* insertPostStmt;
    Statement* insertLikeStmt;

    this(string path)
    {
        db = new Sqlite(path);

        // arsd.sqlite's exec() invokes a null callback delegate for any
        // statement that returns rows, so use query() (which is safe) for
        // every pragma, including the ones that report a value back.
        db.query("PRAGMA journal_mode=WAL");
        db.query("PRAGMA synchronous=NORMAL");
        db.query("PRAGMA busy_timeout=5000");
        db.query("PRAGMA cache_size=-65536");
        db.query("PRAGMA temp_store=MEMORY");
        db.query("PRAGMA mmap_size=268435456");

        feedStmt = new Statement(db, feedSql);
        postStmt = new Statement(db, postSql);
        existsStmt = new Statement(db, existsSql);
        insertPostStmt = new Statement(db, insertPostSql);
        insertLikeStmt = new Statement(db, insertLikeSql);
    }
}

private static Worker tlsWorker;

/*
 * Keep every worker reachable for the life of the process. arsd.sqlite's
 * destructor throws if the connection is closed while statements are still
 * open, and a throw from a finalizer during a normal GC collection would
 * abort the process, so we make sure these objects are only ever finalized
 * (if at all) at shutdown rather than mid-run.
 */
private __gshared Worker[] g_allWorkers;
private __gshared Object g_workerLock;

private Worker worker()
{
    if (tlsWorker is null)
    {
        auto created = new Worker(g_dbPath);
        synchronized (g_workerLock)
            g_allWorkers ~= created;
        tlsWorker = created;
    }

    return tlsWorker;
}

struct AuthClaims
{
    long uid;
    string username;
}

enum AuthResult
{
    ok,
    missing,
    invalid,
    payload
}

string envOr(string key, string fallback)
{
    auto value = environment.get(key, "");
    return value.length ? value : fallback;
}

bool parsePostID(string value, out long id)
{
    if (value.length == 0 || value.length > 19)
        return false;

    long v;
    foreach (char c; value)
    {
        if (c < '0' || c > '9')
            return false;

        v = v * 10 + (c - '0');
        if (v > maxPostID)
            return false;
    }

    if (v <= 0)
        return false;

    id = v;
    return true;
}

size_t codePointCount(string s)
{
    size_t count;

    foreach (char c; s)
        if ((c & 0xC0) != 0x80)
            ++count;

    return count;
}

private enum hexDigits = "0123456789abcdef";

void putJsonString(ref Appender!string a, string s)
{
    a.put('"');

    foreach (char c; s)
    {
        switch (c)
        {
            case '"':
                a.put(`\"`);
                break;
            case '\\':
                a.put(`\\`);
                break;
            case '\n':
                a.put(`\n`);
                break;
            case '\r':
                a.put(`\r`);
                break;
            case '\t':
                a.put(`\t`);
                break;
            case '\f':
                a.put(`\f`);
                break;
            case '\b':
                a.put(`\b`);
                break;
            default:
                if (c < 0x20)
                {
                    a.put(`\u00`);
                    a.put(hexDigits[(c >> 4) & 0xF]);
                    a.put(hexDigits[c & 0xF]);
                }
                else
                {
                    a.put(c);
                }
        }
    }

    a.put('"');
}

void putLong(ref Appender!string a, long value)
{
    if (value == 0)
    {
        a.put('0');
        return;
    }

    char[24] buffer;
    size_t i = buffer.length;

    bool negative = value < 0;
    ulong u = negative ? (~cast(ulong) value + 1) : cast(ulong) value;

    while (u)
    {
        buffer[--i] = cast(char) ('0' + (u % 10));
        u /= 10;
    }

    if (negative)
        buffer[--i] = '-';

    a.put(buffer[i .. $]);
}

void sendJson(Cgi cgi, int status, string json)
{
    cgi.setResponseStatus(status);
    cgi.setResponseContentType("application/json; charset=utf-8");
    cgi.write(json, true);
}

void sendError(Cgi cgi, int status, string message)
{
    auto a = appender!string;
    a.reserve(64);
    a.put(`{"error":`);
    putJsonString(a, message);
    a.put('}');
    sendJson(cgi, status, a.data);
}

void writePost(ref Appender!string a, Row row)
{
    a.put(`{"id":`);
    a.put(row[0].toString);
    a.put(`,"body":`);
    putJsonString(a, row[1].toString);
    a.put(`,"created_at":`);
    putJsonString(a, row[2].toString);
    a.put(`,"author":`);
    putJsonString(a, row[3].toString);
    a.put(`,"like_count":`);
    a.put(row[4].toString);
    a.put('}');
}

/*
 * JWT verification is delegated to jwtlited's HS256 handler, which checks the
 * header's alg, the token structure and the signature. We then decode the
 * payload and enforce the payload semantics the spec cares about (a positive
 * integer sub and a string username), plus exp.
 */
AuthResult authenticate(Cgi cgi, out AuthClaims auth)
{
    immutable header = cgi.authorization;

    if (header.length < 7 || header[0 .. 7] != "Bearer ")
        return AuthResult.missing;

    immutable token = header[7 .. $];

    // Locate the three compact JWS segments and make sure there are exactly 3.
    auto firstDot = indexOf(token, ".");
    if (firstDot <= 0)
        return AuthResult.invalid;

    auto rest = token[firstDot + 1 .. $];
    auto secondDot = indexOf(rest, ".");
    if (secondDot <= 0)
        return AuthResult.invalid;

    if (indexOf(rest[secondDot + 1 .. $], ".") != -1)
        return AuthResult.invalid;

    auto headerLen = Base64URLNoPadding.decodeLength(firstDot);
    auto payloadLen = Base64URLNoPadding.decodeLength(secondDot);

    if (headerLen > 2048 || payloadLen > 16384)
        return AuthResult.invalid;

    char[2048] headerBuffer;
    char[16384] payloadBuffer;

    if (!decode(g_jwt, token, headerBuffer[0 .. headerLen],
                payloadBuffer[0 .. payloadLen]))
        return AuthResult.invalid;

    auto payloadText = payloadBuffer[0 .. payloadLen].idup;

    JSONValue claims;
    try
    {
        claims = parseJSON(payloadText);
    }
    catch (JSONException)
    {
        return AuthResult.invalid;
    }

    if (claims.type != JSONType.object)
        return AuthResult.invalid;

    // exp: required to be a JSON number in the future.
    auto expValue = claims.object.get("exp", JSONValue.init);
    if (expValue.type == JSONType.integer)
    {
        if (expValue.integer <= Clock.currTime.toUnixTime)
            return AuthResult.invalid;
    }
    else if (expValue.type == JSONType.float_)
    {
        if (expValue.floating <= Clock.currTime.toUnixTime)
            return AuthResult.invalid;
    }
    else
    {
        return AuthResult.invalid;
    }

    auto subValue = claims.object.get("sub", JSONValue.init);
    long uid;
    if (subValue.type == JSONType.string)
    {
        if (!parsePostID(subValue.str, uid))
            return AuthResult.payload;
    }
    else if (subValue.type == JSONType.integer)
    {
        if (subValue.integer <= 0 || subValue.integer > maxPostID)
            return AuthResult.payload;
        uid = subValue.integer;
    }
    else
    {
        return AuthResult.payload;
    }

    auto nameValue = claims.object.get("username", JSONValue.init);
    if (nameValue.type != JSONType.string)
        return AuthResult.payload;

    auth.uid = uid;
    auth.username = nameValue.str.idup;
    return AuthResult.ok;
}

int authErrorStatus(AuthResult result)
{
    return 401;
}

string authErrorMessage(AuthResult result)
{
    final switch (result)
    {
        case AuthResult.missing:
            return "missing bearer token";
        case AuthResult.invalid:
            return "invalid or expired token";
        case AuthResult.payload:
            return "invalid token payload";
        case AuthResult.ok:
            assert(0);
    }
}

void handleHealth(Cgi cgi)
{
    try
    {
        worker().db.query("SELECT 1");

        auto a = appender!string;
        a.reserve(64);
        a.put(`{"status":"ok","db":"ok","uptime_s":`);
        putLong(a, (Clock.currTime - g_started).total!"seconds");
        a.put('}');
        sendJson(cgi, 200, a.data);
    }
    catch (Exception e)
    {
        auto a = appender!string;
        a.reserve(96);
        a.put(`{"status":"degraded","db":"unreachable","error":`);
        putJsonString(a, e.msg);
        a.put('}');
        sendJson(cgi, 503, a.data);
    }
}

void handleFeed(Cgi cgi)
{
    auto w = worker();
    auto a = appender!string;
    a.reserve(4096);
    a.put(`{"posts":[`);

    bool first = true;
    foreach (row; w.feedStmt.execute())
    {
        if (!first)
            a.put(',');
        first = false;
        writePost(a, row);
    }

    a.put(`]}`);
    sendJson(cgi, 200, a.data);
}

void handleGetPost(Cgi cgi, string path)
{
    auto suffix = path["/posts/".length .. $];

    if (indexOf(suffix, "/") != -1)
    {
        sendError(cgi, 404, "not found");
        return;
    }

    long id;
    if (!parsePostID(suffix, id))
    {
        sendError(cgi, 400, "invalid post id");
        return;
    }

    auto w = worker();
    w.postStmt.bind(1, id);
    auto rows = w.postStmt.execute();

    if (rows.empty)
    {
        sendError(cgi, 404, "post not found");
        return;
    }

    auto a = appender!string;
    a.reserve(512);
    a.put(`{"post":`);
    writePost(a, rows.front);
    a.put('}');
    sendJson(cgi, 200, a.data);
}

void handleCreatePost(Cgi cgi)
{
    AuthClaims auth;
    auto authResult = authenticate(cgi, auth);
    if (authResult != AuthResult.ok)
    {
        sendError(cgi, authErrorStatus(authResult),
                  authErrorMessage(authResult));
        return;
    }

    auto requestBody = cgi.postBody;
    JSONValue json;
    bool malformed;

    if (requestBody is null || requestBody.length == 0)
    {
        malformed = true;
    }
    else
    {
        try
            json = parseJSON(requestBody);
        catch (JSONException)
            malformed = true;
    }

    if (malformed || json.type != JSONType.object)
    {
        sendError(cgi, 400, "malformed JSON body");
        return;
    }

    auto bodyValue = json.object.get("body", JSONValue.init);
    if (bodyValue.type != JSONType.string)
    {
        sendError(cgi, 400, "body is required");
        return;
    }

    auto body = strip(bodyValue.str);
    if (body.length == 0)
    {
        sendError(cgi, 400, "body is required");
        return;
    }

    if (codePointCount(body) > 500)
    {
        sendError(cgi, 400, "body must be at most 500 characters");
        return;
    }

    auto ownedBody = body.idup;

    auto w = worker();
    w.insertPostStmt.bind(1, auth.uid);
    w.insertPostStmt.bind(2, ownedBody);
    auto rows = w.insertPostStmt.execute();

    if (rows.empty)
    {
        sendError(cgi, 500, "internal server error");
        return;
    }

    auto row = rows.front;

    auto a = appender!string;
    a.reserve(ownedBody.length + auth.username.length + 128);
    a.put(`{"post":{"id":`);
    a.put(row[0].toString);
    a.put(`,"body":`);
    putJsonString(a, ownedBody);
    a.put(`,"created_at":`);
    putJsonString(a, row[1].toString);
    a.put(`,"author":`);
    putJsonString(a, auth.username);
    a.put(`,"like_count":0}}`);
    sendJson(cgi, 201, a.data);
}

void handleLike(Cgi cgi, string path)
{
    AuthClaims auth;
    auto authResult = authenticate(cgi, auth);
    if (authResult != AuthResult.ok)
    {
        sendError(cgi, authErrorStatus(authResult),
                  authErrorMessage(authResult));
        return;
    }

    auto suffix = path["/posts/".length .. $ - "/like".length];

    long id;
    if (!parsePostID(suffix, id))
    {
        sendError(cgi, 400, "invalid post id");
        return;
    }

    auto w = worker();
    w.insertLikeStmt.bind(1, auth.uid);
    w.insertLikeStmt.bind(2, id);
    w.insertLikeStmt.bind(3, id);
    w.insertLikeStmt.execute();

    if (w.db.affectedRows() == 1)
    {
        auto a = appender!string;
        a.reserve(64);
        a.put(`{"liked":true,"already_liked":false,"post_id":`);
        putLong(a, id);
        a.put('}');
        sendJson(cgi, 201, a.data);
        return;
    }

    w.existsStmt.bind(1, id);
    if (w.existsStmt.execute().empty)
    {
        sendError(cgi, 404, "post not found");
        return;
    }

    auto a = appender!string;
    a.reserve(64);
    a.put(`{"liked":true,"already_liked":true,"post_id":`);
    putLong(a, id);
    a.put('}');
    sendJson(cgi, 200, a.data);
}

void route(Cgi cgi)
{
    immutable method = cgi.requestMethod;
    immutable path = cgi.pathInfo;

    if (method == Cgi.RequestMethod.GET)
    {
        if (path == "/health")
        {
            handleHealth(cgi);
            return;
        }

        if (path == "/feed")
        {
            handleFeed(cgi);
            return;
        }

        if (path.startsWith("/posts/"))
        {
            handleGetPost(cgi, path);
            return;
        }

        sendError(cgi, 404, "not found");
        return;
    }

    if (method == Cgi.RequestMethod.POST)
    {
        if (path == "/posts")
        {
            handleCreatePost(cgi);
            return;
        }

        if (path.length >= 12 && path.startsWith("/posts/") &&
            path.endsWith("/like"))
        {
            handleLike(cgi, path);
            return;
        }

        sendError(cgi, 404, "not found");
        return;
    }

    sendError(cgi, 404, "not found");
}

void handler(Cgi cgi)
{
    try
    {
        route(cgi);
    }
    catch (Throwable t)
    {
        import std.stdio : stderr;
        stderr.writeln("handler error: ", t.toString());
        if (cgi.canOutputHeaders())
            sendError(cgi, 500, "internal server error");
    }
}

void main()
{
    g_dbPath = envOr("SQLITE_PATH", "seed/feed.db");
    g_secret = envOr("JWT_SECRET", "twelve-dollar-challenge");
    g_jwt.loadKey(cast(const(ubyte)[]) g_secret);
    g_started = Clock.currTime;
    g_workerLock = new Object;

    RequestServer server;
    server.listeningHost = envOr("HOST", "0.0.0.0");
    server.listeningPort = to!ushort(envOr("PORT", "80"));

    server.serve!handler();
}
