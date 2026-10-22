module app;

import asdf;
import jwtlited.phobos;

import vibe.core.core : runApplication;
import vibe.http.router : URLRouter;
import vibe.http.server :
    HTTPServerRequest,
    HTTPServerResponse,
    HTTPServerSettings,
    listenHTTP;

import d2sqlite3;
import std.datetime : Clock, SysTime;
import std.process : environment;
import std.string : strip, startsWith;
import std.conv : to;
import std.stdio : writeln;
import std.uni : byCodePoint;

struct Post
{
    long id;
    string body;
    string created_at;
    string author;
    long like_count;
}

struct PostEnvelope
{
    Post post;
}

struct FeedEnvelope
{
    Post[] posts;
}

struct HealthOK
{
    string status;
    string db;
    long uptime_s;
}

struct HealthDegraded
{
    string status;
    string db;
    string error;
}

struct LikeResponse
{
    bool liked;
    bool already_liked;
    long post_id;
}

enum AuthResult
{
    ok,
    invalidToken,
    invalidPayload
}

struct AuthClaims
{
    long uid;
    string username;
}

string envOr(string key, string fallback)
{
    auto value = environment.get(key, "");
    return value.length ? value : fallback;
}

string json(T)(auto ref T value)
{
    return value.serializeToJson();
}

void respond(T)(
    scope HTTPServerResponse res,
    int status,
    auto ref T value
)
{
    res.statusCode = status;
    res.headers["Content-Type"] = "application/json; charset=utf-8";
    res.writeBody(json(value));
}

struct ErrorResponse
{
    string error;
}

void fail(
    scope HTTPServerResponse res,
    int status,
    string message
)
{
    ErrorResponse e;
    e.error = message;
    respond(res, status, e);
}

bool parsePostID(string value, out long id)
{
    try
    {
        id = to!long(value);
        return id > 0;
    }
    catch (Exception)
    {
        return false;
    }
}

/*
 * JWT verification is performed by jwtlited's HS256 handler.
 * The verified payload is read as an ASDF document so that the
 * difference between a bad token and a bad payload can be reported.
 */
AuthResult authenticate(
    ref HS256Handler jwt,
    string token,
    out AuthClaims auth
)
{
    try
    {
        if (!jwt.validate(token))
            return AuthResult.invalidToken;

        char[4096] headerBuffer;
        char[16384] payloadBuffer;

        if (!jwt.decode(token, headerBuffer[], payloadBuffer[]))
            return AuthResult.invalidToken;

        /*
         * jwtlited writes decoded JSON into the provided buffers.
         * Find the JSON document terminator without treating the
         * entire fixed-size buffer as input.
         */
        auto payloadEnd = payloadBuffer[].length;

        while (payloadEnd > 0 && payloadBuffer[payloadEnd - 1] == '\0')
            --payloadEnd;

        Asdf claims;

        try
            claims = payloadBuffer[0 .. payloadEnd].parseJson;
        catch (Exception)
            return AuthResult.invalidPayload;

        if (claims.kind != Asdf.Kind.object)
            return AuthResult.invalidPayload;

        auto sub = claims["sub"];
        auto username = claims["username"];
        auto exp = claims["exp"];

        if (!sub.data.length || sub.kind != Asdf.Kind.string ||
            !username.data.length || username.kind != Asdf.Kind.string)
            return AuthResult.invalidPayload;

        long uid;

        try
            uid = to!long(cast(string) sub);
        catch (Exception)
            return AuthResult.invalidPayload;

        if (uid <= 0)
            return AuthResult.invalidPayload;

        if (!exp.data.length || exp.kind != Asdf.Kind.number)
            return AuthResult.invalidToken;

        double expSeconds;

        try
            expSeconds = cast(double) exp;
        catch (Exception)
            return AuthResult.invalidToken;

        if (expSeconds <= cast(double) Clock.currTime.toUnixTime)
            return AuthResult.invalidToken;

        auth.uid = uid;
        auth.username = (cast(string) username).idup;
        return AuthResult.ok;
    }
    catch (Exception)
    {
        return AuthResult.invalidToken;
    }
}

struct FeedServer
{
    Database db;
    HS256Handler jwt;
    SysTime started;

    this(string dbPath, string secret)
    {
        db = Database(dbPath);

        db.run("PRAGMA journal_mode=WAL");
        db.run("PRAGMA synchronous=NORMAL");
        db.run("PRAGMA busy_timeout=5000");
        db.run("PRAGMA cache_size=-65536");
        db.run("PRAGMA temp_store=MEMORY");
        db.run("PRAGMA mmap_size=268435456");

        jwt.loadKey(secret);
        started = Clock.currTime;
    }

    Post readPost(Row row)
    {
        Post p;
        p.id = row.peek!long(0);
        p.body = row.peek!string(1);
        p.created_at = row.peek!string(2);
        p.author = row.peek!string(3);
        p.like_count = row.peek!long(4);
        return p;
    }

    string postQuery()
    {
        return `SELECT p.id, p.body, p.created_at, u.username,
            (SELECT count(*) FROM likes l WHERE l.post_id = p.id)
            AS like_count
            FROM posts p JOIN users u ON u.id = p.user_id`;
    }

    bool findPost(long id, out Post p)
    {
        auto stmt = db.prepare(postQuery() ~ " WHERE p.id = ?");
        stmt.bind(1, id);

        auto rows = stmt.execute();
        foreach (row; rows)
        {
            p = readPost(row);
            return true;
        }
        return false;
    }

    void internalError(
        scope HTTPServerResponse res,
        Exception e
    )
    {
        writeln("request error: ", e.msg);
        fail(res, 500, "internal server error");
    }

    bool requireAuth(
        scope HTTPServerRequest req,
        scope HTTPServerResponse res,
        out AuthClaims auth
    )
    {
        auto authHeader = req.headers.get("Authorization", "");

        if (!authHeader.startsWith("Bearer "))
        {
            fail(res, 401, "missing bearer token");
            return false;
        }

        auto result =
            authenticate(jwt, authHeader["Bearer ".length .. $], auth);

        if (result == AuthResult.ok)
            return true;

        if (result == AuthResult.invalidPayload)
            fail(res, 401, "invalid token payload");
        else
            fail(res, 401, "invalid or expired token");

        return false;
    }

    void notFound(
        scope HTTPServerRequest req,
        scope HTTPServerResponse res
    )
    {
        fail(res, 404, "not found");
    }

    void health(
        scope HTTPServerRequest req,
        scope HTTPServerResponse res
    )
    {
        try
        {
            db.execute("SELECT 1").oneValue!long;

            HealthOK outValue;
            outValue.status = "ok";
            outValue.db = "ok";
            outValue.uptime_s =
                (Clock.currTime - started).total!"seconds";

            respond(res, 200, outValue);
        }
        catch (Exception e)
        {
            HealthDegraded outValue;
            outValue.status = "degraded";
            outValue.db = "unreachable";
            outValue.error = e.msg;
            respond(res, 503, outValue);
        }
    }

    void feed(
        scope HTTPServerRequest req,
        scope HTTPServerResponse res
    )
    {
        try
        {
            auto stmt = db.prepare(
                postQuery() ~
                " ORDER BY p.created_at DESC, p.id DESC LIMIT 20"
            );

            FeedEnvelope outValue;
            auto rows = stmt.execute();

            foreach (row; rows)
                outValue.posts ~= readPost(row);

            respond(res, 200, outValue);
        }
        catch (Exception e)
        {
            internalError(res, e);
        }
    }

    void getPost(
        scope HTTPServerRequest req,
        scope HTTPServerResponse res
    )
    {
        try
        {
            long id;
            if (!parsePostID(req.params["id"], id))
            {
                fail(res, 400, "invalid post id");
                return;
            }

            Post p;
            if (!findPost(id, p))
            {
                fail(res, 404, "post not found");
                return;
            }

            PostEnvelope outValue;
            outValue.post = p;
            respond(res, 200, outValue);
        }
        catch (Exception e)
        {
            internalError(res, e);
        }
    }

    void createPost(
        scope HTTPServerRequest req,
        scope HTTPServerResponse res
    )
    {
        import vibe.stream.operations : readAllUTF8;

        try
        {
            AuthClaims auth;
            if (!requireAuth(req, res, auth))
                return;

            string requestBody;

            try
            {
                requestBody = req.bodyReader.readAllUTF8();
            }
            catch (Exception)
            {
                fail(res, 400, "malformed JSON body");
                return;
            }

            Asdf input;
            try
            {
                input = requestBody.parseJson;
            }
            catch (Exception)
            {
                fail(res, 400, "malformed JSON body");
                return;
            }

            if (!input.data.length ||
                input.kind != Asdf.Kind.object)
            {
                fail(res, 400, "body is required");
                return;
            }

            auto bodyValue = input["body"];

            if (!bodyValue.data.length ||
                bodyValue.kind != Asdf.Kind.string)
            {
                fail(res, 400, "body is required");
                return;
            }

            auto body = strip(cast(string) bodyValue).idup;
            if (body.length == 0)
            {
                fail(res, 400, "body is required");
                return;
            }

            size_t characterCount;
            foreach (dchar ch; body.byCodePoint)
                ++characterCount;

            if (characterCount > 500)
            {
                fail(res, 400,
                    "body must be at most 500 characters");
                return;
            }

            auto stmt = db.prepare(
                "INSERT INTO posts (user_id, body) "
                ~ "VALUES (?, ?) RETURNING id, created_at"
            );

            stmt.bind(1, auth.uid);
            stmt.bind(2, body);

            long id;
            string createdAt;
            auto rows = stmt.execute();

            foreach (row; rows)
            {
                id = row.peek!long(0);
                createdAt = row.peek!string(1);
                break;
            }

            Post p;
            p.id = id;
            p.body = body;
            p.created_at = createdAt;
            p.author = auth.username;
            p.like_count = 0;

            PostEnvelope outValue;
            outValue.post = p;
            respond(res, 201, outValue);
        }
        catch (Exception e)
        {
            internalError(res, e);
        }
    }

    void likePost(
        scope HTTPServerRequest req,
        scope HTTPServerResponse res
    )
    {
        try
        {
            AuthClaims auth;
            if (!requireAuth(req, res, auth))
                return;

            long id;
            if (!parsePostID(req.params["id"], id))
            {
                fail(res, 400, "invalid post id");
                return;
            }

            auto stmt = db.prepare(
                "INSERT INTO likes (user_id, post_id) "
                ~ "SELECT ?, ? WHERE EXISTS "
                ~ "(SELECT 1 FROM posts WHERE id = ?) "
                ~ "ON CONFLICT (user_id, post_id) DO NOTHING"
            );

            stmt.bind(1, auth.uid);
            stmt.bind(2, id);
            stmt.bind(3, id);
            stmt.execute();

            auto changes =
                db.execute("SELECT changes()").oneValue!long;

            if (changes == 1)
            {
                LikeResponse outValue;
                outValue.liked = true;
                outValue.already_liked = false;
                outValue.post_id = id;
                respond(res, 201, outValue);
                return;
            }

            Post p;
            if (!findPost(id, p))
            {
                fail(res, 404, "post not found");
                return;
            }

            LikeResponse outValue;
            outValue.liked = true;
            outValue.already_liked = true;
            outValue.post_id = id;
            respond(res, 200, outValue);
        }
        catch (Exception e)
        {
            internalError(res, e);
        }
    }
}

void main()
{
    auto app = new FeedServer(
        envOr("SQLITE_PATH", "seed/feed.db"),
        envOr("JWT_SECRET", "twelve-dollar-challenge")
    );

    auto settings = new HTTPServerSettings;
    settings.port = to!ushort(envOr("PORT", "80"));
    settings.bindAddresses = [envOr("HOST", "0.0.0.0")];

    auto router = new URLRouter;
    router.get("/health", &app.health);
    router.get("/feed", &app.feed);
    router.get("/posts/:id", &app.getPost);
    router.post("/posts", &app.createPost);
    router.post("/posts/:id/like", &app.likePost);
    router.any("*", &app.notFound);

    writeln("Listening on ",
        envOr("HOST", "0.0.0.0"), ":", settings.port);

    auto listener = listenHTTP(settings, router);
    scope (exit) listener.stopListening();

    runApplication();
}
