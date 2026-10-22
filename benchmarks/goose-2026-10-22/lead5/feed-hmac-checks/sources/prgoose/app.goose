// The challenge application is Goose: routing, JWT claim validation, SQL,
// database row traversal, Unicode validation and JSON response construction.
// C supplies only HTTP transport, SQLite calls, environment/time and HMAC.
import std;
import json;

extern fn native_env(name: const u8[:], out: u8[>..]&);
extern fn native_time_ms() -> i64;
extern fn auth_decode(token: const u8[:], secret: const u8[:], header: u8[>..]&, payload: u8[>..]&) -> i32;

extern fn db_open(path: const u8[:]) -> i64;
extern fn db_prepare(db: i64, sql: const u8[:]) -> i64;
extern fn db_bind_int(stmt: i64, index: i32, value: i64) -> i32;
extern fn db_bind_text(stmt: i64, index: i32, value: const u8[:]) -> i32;
extern fn db_step(stmt: i64) -> i32;
extern fn db_column_int(stmt: i64, col: i32) -> i64;
extern fn db_column_text(stmt: i64, col: i32, out: u8[>..]&);
extern fn db_column_json(stmt: i64, col: i32, out: u8[>..]&);
extern fn json_plain_prefix(text: const u8[:]) -> i64;
extern fn json_append_string(text: const u8[:], out: u8[>..]&);
extern fn db_reset(stmt: i64) -> i32;
extern fn db_begin(db: i64) -> i32;
extern fn db_commit(db: i64) -> i32;
extern fn db_changes(db: i64) -> i32;
extern fn db_last_id(db: i64) -> i64;
extern fn db_checkpoint(db: i64);

extern fn net_init(host: const u8[:], port: i64) -> i64;
extern fn net_poll(handle: i64) -> i64;
extern fn net_dispatch_batch(handle: i64);
extern fn net_method(handle: i64, index: i64, out: u8[>..]&);
extern fn net_path(handle: i64, index: i64, out: u8[>..]&);
extern fn net_auth(handle: i64, index: i64, out: u8[>..]&);
extern fn net_body(handle: i64, index: i64, out: u8[>..]&);
extern fn net_reply(handle: i64, index: i64, status: i32, body: const u8[:]);
extern fn net_flush(handle: i64, commit_ok: i32);

struct App {
    db: i64,
    health: i64,
    feed: i64,
    feed_recent: i64,
    feed_likes: i64,
    post: i64,
    create: i64,
    created: i64,
    exists: i64,
    like: i64,
    started_ms: i64,
}

var app_state: App = default<App>();
var secret_env: u8[>..] = [];

fn error(net: i64, index: i64, status: i32, message: const u8[:]) {
    var out: u8[>..] = [];
    out.append("{\"error\":");
    json_append_string(message, out);
    out.push('}');
    net_reply(net, index, status, out);
}

fn internal_error(net: i64, index: i64) {
    error(net, index, 500, "internal server error");
}

// Only decimal positive integer strings are accepted as IDs and subjects.
fn positive_id(text: const u8[:]) -> i64 {
    if text.len == 0 { return 0; }
    var value = 0;
    for c in text {
        if c < '0' || c > '9' { return 0; }
        let digit = c as i64 - '0';
        if value > (9007199254740991 - digit) / 10 { return 0; }
        value = value * 10 + digit;
    }
    return value;
}

// Plain strings borrow their input. The uncommon escape path uses the
// standard library's complete escape decoder and validation.
fn read_string(r: json::Reader&, scratch: u8[>..]&) -> const u8[:] {
    if json::peek(r) != '"' { json::fail(r, "expected a string"); return ""; }
    let start = r.pos + 1;
    let end = start + json_plain_prefix(r.text[start..]);
    if end < r.text.len && r.text[end] == '"' {
        r.pos = end + 1;
        return r.text[start..end];
    }
    return json::read_string(r, scratch);
}

// Decode keys as well as values, so escaped claim/member names work too.
// The callback consumes each value; finish() checks the complete document.
fn object_members<F>(r: json::Reader&, scratch: u8[>..]&) {
    if json::peek(r) != '{' { json::fail(r, "expected an object"); return; }
    r.pos++;
    if json::peek(r) == '}' { r.pos++; return; }
    loop {
        let key = read_string(r, scratch);
        if r.error.len > 0 { return; }
        if json::peek(r) != ':' { json::fail(r, "expected ':'"); return; }
        r.pos++;
        F(key);
        let next = json::peek(r);
        if next == ',' { r.pos++; continue; }
        if next == '}' { r.pos++; } else { json::fail(r, "expected ',' or '}'"); }
        return;
    }
}

fn valid_header(text: const u8[:]) -> bool {
    var r = json::reader(text);
    var scratch: u8[>..] = [];
    var seen = false;
    var valid = false;
    object_members(r, scratch) { key =>
        if key == "alg" && !seen {
            seen = true;
            if json::peek(r) == '"' { valid = read_string(r, scratch) == "HS256"; }
            else { json::skip(r); }
        } else { json::skip(r); }
    };
    return json::finish(r) && valid;
}

// The return code selects the precise challenge authentication error.
// Goose validates claims in one pass without building a generic JSON tree.
fn authenticate(authorization: const u8[:], secret: const u8[:], username: u8[>..]&) -> i64, i32 {
    if !starts_with(authorization, "Bearer ") { return 0, 1; }
    var header: u8[>..] = [];
    var payload: u8[>..] = [];
    if auth_decode(authorization[7..], secret, header, payload) != 1 { return 0, 2; }
    if !valid_header(header) { return 0, 2; }
    var r = json::reader(payload);
    var scratch: u8[>..] = [];
    var subject_seen = false;
    var name_seen = false;
    var expires_seen = false;
    var name_ok = false;
    var expires_ok = false;
    var user_id = 0;
    var expires = 0.0;
    object_members(r, scratch) { key =>
        if key == "sub" && !subject_seen {
            subject_seen = true;
            if json::peek(r) == '"' { user_id = positive_id(read_string(r, scratch)); }
            else { json::skip(r); }
        } else if key == "username" && !name_seen {
            name_seen = true;
            if json::peek(r) == '"' {
                username.append(read_string(r, scratch));
                name_ok = true;
            } else { json::skip(r); }
        } else if key == "exp" && !expires_seen {
            expires_seen = true;
            let next = json::peek(r);
            if next == '-' || (next >= '0' && next <= '9') {
                expires = json::read_number(r);
                expires_ok = true;
            } else { json::skip(r); }
        } else { json::skip(r); }
    };
    if !json::finish(r) || !expires_ok || expires <= native_time_ms() / 1000 { return 0, 2; }
    if user_id == 0 || !name_ok { return 0, 3; }
    return user_id, 0;
}

fn parse_body(text: const u8[:], scratch: u8[>..]&, body: u8[>..]&) -> i32 {
    var r = json::reader(text);
    var seen = false;
    var is_string = false;
    if json::peek(r) == '{' {
        object_members(r, scratch) { key =>
            if key == "body" && !seen {
                seen = true;
                if json::peek(r) == '"' { body.append(read_string(r, scratch)); is_string = true; }
                else { json::skip(r); }
            } else { json::skip(r); }
        };
    } else { json::skip(r); }
    if !json::finish(r) { return 1; }
    if !is_string { return 2; }
    return 0;
}

fn auth_error(net: i64, index: i64, code: i32) {
    if code == 1 { error(net, index, 401, "missing bearer token"); }
    else if code == 2 { error(net, index, 401, "invalid or expired token"); }
    else { error(net, index, 401, "invalid token payload"); }
}

// One Unicode scalar and the number of UTF-8 bytes consumed. A zero length
// rejects truncated, overlong, surrogate and out-of-range encodings.
fn utf8_at(text: const u8[:], at: i64) -> i64, i64 {
    let b = text[at];
    if b < 0x80 { return b, 1; }
    let n: i64 = if b >= 0xc2 && b <= 0xdf { 2 }
        else if b >= 0xe0 && b <= 0xef { 3 }
        else if b >= 0xf0 && b <= 0xf4 { 4 } else { 0 };
    if n == 0 || at + n > text.len { return 0, 0; }
    var cp = (b as i64) & ((1 << (7 - n)) - 1);
    for j in n - 1 {
        let next = text[at + j + 1];
        if next & 0xc0 != 0x80 { return 0, 0; }
        cp = (cp << 6) | ((next as i64) & 0x3f);
    }
    if (n == 2 && cp < 0x80) || (n == 3 && cp < 0x800) ||
       (n == 4 && cp < 0x10000) || (cp >= 0xd800 && cp <= 0xdfff) || cp > 0x10ffff {
        return 0, 0;
    }
    return cp, n;
}

fn unicode_space(cp: i64) -> bool {
    return (cp >= 9 && cp <= 13) || cp == 0x20 || cp == 0xa0 || cp == 0x1680 ||
        (cp >= 0x2000 && cp <= 0x200a) || cp == 0x2028 || cp == 0x2029 ||
        cp == 0x202f || cp == 0x205f || cp == 0x3000 || cp == 0xfeff;
}

// Returns a slice and its scalar count, or -1 for malformed Unicode.
fn trim_body(text: const u8[:]) -> const u8[:], i64 {
    var start = 0;
    var end = 0;
    var count = 0;
    var kept = 0;
    var started = false;
    var at = 0;
    while at < text.len {
        let cp, n = utf8_at(text, at);
        if n == 0 { return "", -1; }
        if !unicode_space(cp) {
            if !started { start = at; started = true; }
            end = at + n;
            count++;
            kept = count;
        } else if started { count++; }
        at += n;
    }
    return text[start..end], kept;
}

fn append_column(out: u8[>..]&, stmt: i64, col: i32) {
    db_column_json(stmt, col, out);
}

fn append_post_prefix(out: u8[>..]&, stmt: i64, id: i64) {
    out.append("{\"id\":");
    format(out, id);
    out.append(",\"body\":");
    append_column(out, stmt, 1);
    out.append(",\"created_at\":");
    append_column(out, stmt, 2);
    out.append(",\"author\":");
    append_column(out, stmt, 3);
    out.append(",\"like_count\":");
}

fn append_post_with_likes(out: u8[>..]&, stmt: i64, likes: i64) {
    append_post_prefix(out, stmt, db_column_int(stmt, 0));
    format(out, likes);
    out.push('}');
}

fn append_post(out: u8[>..]&, stmt: i64) {
    append_post_with_likes(out, stmt, db_column_int(stmt, 4));
}

fn health(app: App&, net: i64, index: i64) {
    let rc = db_step(app.health);
    db_reset(app.health);
    if rc != 100 {
        net_reply(net, index, 503, "{\"status\":\"degraded\",\"db\":\"unreachable\",\"error\":\"database query failed\"}");
        return;
    }
    var out: u8[>..] = [];
    out.append("{\"status\":\"ok\",\"db\":\"ok\",\"uptime_s\":");
    format(out, max(0, (native_time_ms() - app.started_ms) / 1000));
    out.push('}');
    net_reply(net, index, 200, out);
}

// Discover and serialize the newest twenty rows in their requested order.
// Compact ID ranges need only one additional live likes scan; sparse IDs
// retain the general SQL path. Prefixes are copied before stepping SQLite.
// No rows, counts, IDs or finished JSON survive a request.
fn range_feed(app: App&, net: i64, index: i64) -> bool {
    var ids: i64[20] = [0; 20];
    var starts: i64[20] = [0; 20];
    var ends: i64[20] = [0; 20];
    var scratch: u8[>..] = [];
    var n = 0;
    var rc = db_step(app.feed_recent);
    while rc == 100 && n < 20 {
        ids[n] = db_column_int(app.feed_recent, 0);
        starts[n] = scratch.len;
        append_post_prefix(scratch, app.feed_recent, ids[n]);
        ends[n] = scratch.len;
        n++;
        rc = db_step(app.feed_recent);
    }
    db_reset(app.feed_recent);
    if rc != 101 { internal_error(net, index); return true; }
    if n == 0 {
        net_reply(net, index, 200, "{\"posts\":[]}");
        return true;
    }
    let minimum = min(ids[..n]);
    let maximum = max(ids[..n]);
    if maximum - minimum >= 256 { return false; }
    var slots: i32[256] = [-1; 256];
    for i in n { slots[ids[i] - minimum] = i as i32; }
    var likes: i64[20] = [0; 20];
    if db_bind_int(app.feed_likes, 1, minimum) != 0 {
        db_reset(app.feed_likes);
        internal_error(net, index);
        return true;
    }
    rc = db_step(app.feed_likes);
    while rc == 100 {
        let post_id = db_column_int(app.feed_likes, 0);
        // ORDER BY guarantees no selected ID can follow this upper boundary.
        if post_id > maximum { rc = 101; break; }
        let slot = slots[post_id - minimum];
        if slot >= 0 { likes[slot]++; }
        rc = db_step(app.feed_likes);
    }
    db_reset(app.feed_likes);
    if rc != 101 { internal_error(net, index); return true; }
    var out: u8[>..] = [];
    out.append("{\"posts\":[");
    for i in n {
        if i != 0 { out.push(','); }
        out.append(scratch[starts[i]..ends[i]]);
        format(out, likes[i]);
        out.push('}');
    }
    out.append("]}");
    net_reply(net, index, 200, out);
    return true;
}

fn feed(app: App&, net: i64, index: i64) {
    if range_feed(app, net, index) { return; }
    var out: u8[>..] = [];
    out.append("{\"posts\":[");
    var first = true;
    var rc = db_step(app.feed);
    while rc == 100 {
        if !first { out.push(','); }
        first = false;
        append_post(out, app.feed);
        rc = db_step(app.feed);
    }
    db_reset(app.feed);
    if rc != 101 { internal_error(net, index); return; }
    out.append("]}");
    net_reply(net, index, 200, out);
}

fn get_post(app: App&, net: i64, index: i64, id: i64) {
    if db_bind_int(app.post, 1, id) != 0 { internal_error(net, index); return; }
    let rc = db_step(app.post);
    if rc != 100 {
        db_reset(app.post);
        if rc == 101 { error(net, index, 404, "post not found"); }
        else { internal_error(net, index); }
        return;
    }
    var out: u8[>..] = [];
    out.append("{\"post\":");
    append_post(out, app.post);
    out.push('}');
    db_reset(app.post);
    net_reply(net, index, 200, out);
}

fn create_post(app: App&, net: i64, index: i64, user_id: i64, username: const u8[:], body: const u8[:]) {
    var decoded: u8[>..] = [];
    var raw: u8[>..] = [];
    let parse_error = parse_body(body, decoded, raw);
    if parse_error == 1 { error(net, index, 400, "malformed JSON body"); return; }
    if parse_error == 2 { error(net, index, 400, "body is required"); return; }
    let trimmed, characters = trim_body(raw);
    if characters < 0 { error(net, index, 400, "malformed JSON body"); return; }
    if characters == 0 { error(net, index, 400, "body is required"); return; }
    if characters > 500 { error(net, index, 400, "body must be at most 500 characters"); return; }
    if db_bind_int(app.create, 1, user_id) != 0 || db_bind_text(app.create, 2, trimmed) != 0 {
        db_reset(app.create);
        internal_error(net, index);
        return;
    }
    let inserted = db_step(app.create);
    db_reset(app.create);
    if inserted != 101 {
        internal_error(net, index);
        return;
    }
    // Read the database's generated timestamp without INSERT RETURNING's
    // transient table. The event loop still owns this transaction.
    let id = db_last_id(app.db);
    if db_bind_int(app.created, 1, id) != 0 || db_step(app.created) != 100 {
        db_reset(app.created);
        internal_error(net, index);
        return;
    }
    var out: u8[>..] = [];
    out.append("{\"post\":{\"id\":");
    format(out, id);
    out.append(",\"body\":");
    json_append_string(trimmed, out);
    out.append(",\"created_at\":");
    append_column(out, app.created, 0);
    out.append(",\"author\":");
    json_append_string(username, out);
    out.append(",\"like_count\":0}}");
    let rc = db_step(app.created);
    db_reset(app.created);
    if rc != 101 { internal_error(net, index); return; }
    net_reply(net, index, 201, out);
}

fn like_post(app: App&, net: i64, index: i64, user_id: i64, id: i64) {
    if db_bind_int(app.like, 1, user_id) != 0 || db_bind_int(app.like, 2, id) != 0 {
        db_reset(app.like);
        internal_error(net, index);
        return;
    }
    let rc = db_step(app.like);
    let changed = db_changes(app.db);
    db_reset(app.like);
    if rc != 101 { internal_error(net, index); return; }
    if changed == 0 {
        if db_bind_int(app.exists, 1, id) != 0 { internal_error(net, index); return; }
        let exists = db_step(app.exists);
        db_reset(app.exists);
        if exists != 100 {
            if exists == 101 { error(net, index, 404, "post not found"); }
            else { internal_error(net, index); }
            return;
        }
    }
    var out: u8[>..] = [];
    out.append("{\"liked\":true,\"already_liked\":");
    json::format_bool(out, changed == 0);
    out.append(",\"post_id\":");
    format(out, id);
    out.push('}');
    net_reply(net, index, if changed == 0 { 200 } else { 201 }, out);
}

fn handle(app: App&, net: i64, index: i64, secret: const u8[:], method: const u8[:], target: const u8[:], auth: const u8[:], body: const u8[:]) {
    let query = find(target, "?");
    let path = if query >= 0 { target[..query] } else { target[..] };
    if method == "GET" {
        if path == "/health" { health(app, net, index); return; }
        if path == "/feed" { feed(app, net, index); return; }
        if starts_with(path, "/posts/") && find(path[7..], "/") < 0 {
            let id = positive_id(path[7..]);
            if id == 0 { error(net, index, 400, "invalid post id"); return; }
            get_post(app, net, index, id);
            return;
        }
    }
    if method == "POST" {
        let create = path == "/posts";
        let like = starts_with(path, "/posts/") && ends_with(path, "/like") && path.len >= 12 &&
            find(path[7..path.len - 5], "/") < 0;
        if create || like {
            var username: u8[>..] = [];
            let user_id, auth_status = authenticate(auth, secret, username);
            if auth_status != 0 { auth_error(net, index, auth_status); return; }
            if create {
                create_post(app, net, index, user_id, username, body);
            } else {
                let id = positive_id(path[7..path.len - 5]);
                if id == 0 { error(net, index, 400, "invalid post id"); return; }
                like_post(app, net, index, user_id, id);
            }
            return;
        }
    }
    error(net, index, 404, "not found");
}

// Transport borrows receive bytes only for this synchronous callback.
// All request interpretation and response construction still run in Goose.
export "goose_handle_request" fn dispatch(net: i64, index: i64, method: const u8[:], path: const u8[:], auth: const u8[:], body: const u8[:]) {
    let secret = if secret_env.len > 0 { secret_env[..] } else { "twelve-dollar-challenge" };
    handle(app_state, net, index, secret, method, path, auth, body);
}

fn initialize() -> i64 {
    var db_env: u8[>..] = [];
    var host_env: u8[>..] = [];
    var port_env: u8[>..] = [];
    native_env("SQLITE_PATH", db_env);
    native_env("HOST", host_env);
    native_env("PORT", port_env);
    native_env("JWT_SECRET", secret_env);
    let db_path = if db_env.len > 0 { db_env[..] } else { "seed/feed.db" };
    let host = if host_env.len > 0 { host_env[..] } else { "127.0.0.1" };
    let configured_port, port_ok = parse_int(port_env);
    let port = if port_ok && configured_port > 0 && configured_port <= 65535 { configured_port } else { 3000 };
    let db = db_open(db_path);
    if db == 0 { print("Could not open SQLITE_PATH"); return 0; }
    app_state = App {
        db: db,
        health: db_prepare(db, "SELECT 1"),
        feed: db_prepare(db, "SELECT p.id,p.body,p.created_at,u.username,(SELECT count(*) FROM likes l WHERE l.post_id=p.id) FROM posts p JOIN users u ON u.id=p.user_id ORDER BY p.created_at DESC,p.id DESC LIMIT 20"),
        feed_recent: db_prepare(db, "SELECT p.id,p.body,p.created_at,u.username FROM posts p JOIN users u ON u.id=p.user_id ORDER BY p.created_at DESC,p.id DESC LIMIT 20"),
        feed_likes: db_prepare(db, "SELECT post_id FROM likes WHERE post_id>=?1 ORDER BY post_id"),
        post: db_prepare(db, "SELECT p.id,p.body,p.created_at,u.username,(SELECT count(*) FROM likes l WHERE l.post_id=p.id) FROM posts p JOIN users u ON u.id=p.user_id WHERE p.id=?1"),
        create: db_prepare(db, "INSERT INTO posts(user_id,body) VALUES(?1,?2)"),
        created: db_prepare(db, "SELECT created_at FROM posts WHERE id=?1"),
        exists: db_prepare(db, "SELECT 1 FROM posts WHERE id=?1"),
        like: db_prepare(db, "INSERT INTO likes(user_id,post_id) SELECT ?1,?2 WHERE EXISTS(SELECT 1 FROM posts WHERE id=?2) ON CONFLICT(user_id,post_id) DO NOTHING"),
        started_ms: native_time_ms(),
    };
    if app_state.health == 0 || app_state.feed == 0 || app_state.feed_recent == 0 || app_state.feed_likes == 0 || app_state.post == 0 || app_state.create == 0 || app_state.created == 0 || app_state.exists == 0 || app_state.like == 0 {
        print("Could not prepare challenge SQL");
        return 0;
    }
    let net = net_init(host, port);
    if net == 0 { print("Could not listen on HOST:PORT"); return 0; }
    print("Goose challenge server listening on ", host, ":", port);
    return net;
}

fn main() {
    // Exported callbacks reuse the Goose data stacks. Keep only scalar
    // locals alive across C dispatch; startup builders ended in initialize.
    let net = initialize();
    if net == 0 { return; }
    let db = app_state.db;
    loop {
        let batch = net_poll(net);
        if batch < 0 { break; }
        if batch == 0 { continue; }
        let begun = db_begin(db) == 0;
        if begun { net_dispatch_batch(net); }
        else { for index in batch { internal_error(net, index); } }
        let committed = begun && db_commit(db) == 0;
        net_flush(net, if committed { 1 } else { 0 });
        db_checkpoint(db);
    }
}
