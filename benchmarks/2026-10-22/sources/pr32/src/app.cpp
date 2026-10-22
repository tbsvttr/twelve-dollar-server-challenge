#include "app.hpp"

#include <charconv>
#include <cstring>
#include <ctime>

#include "json.hpp"

namespace srv {

namespace {

using View = eastl::string_view;

constexpr size_t kMaxPostChars = 500;
constexpr View kWhitespace = " \t\n\r\f\v";

char g_decoded[kMaxBodyBytes + 16];

View trim(View v) {
    size_t first = v.find_first_not_of(kWhitespace);
    if (first == View::npos) return View();
    size_t last = v.find_last_not_of(kWhitespace);
    return v.substr(first, last - first + 1);
}

size_t char_count(View v) {
    size_t count = 0;
    for (char c : v) count += (static_cast<unsigned char>(c) & 0xC0) != 0x80;
    return count;
}

}

bool parse_post_id(View text, int64_t &id) {
    if (text.empty()) return false;
    int64_t value = 0;
    auto r = std::from_chars(text.data(), text.data() + text.size(), value);
    if (r.ec != std::errc{} || r.ptr != text.data() + text.size() || value <= 0) return false;
    id = value;
    return true;
}

App::App(Db &db, const JwtVerifier &jwt) : db_(db), jwt_(jwt) { clock_gettime(CLOCK_MONOTONIC, &start_); }

int App::fail(Writer &out, int status, const char *message) {
    out.clear();
    out.put("{\"error\":\"");
    out.put(View(message));
    out.put("\"}");
    return status;
}

int App::authenticate(const Request &req, Identity &who, Writer &out) {
    switch (jwt_.verify(req.authorization, time(nullptr), who)) {
        case AuthStatus::Ok:
            return 0;
        case AuthStatus::MissingBearer:
            return fail(out, 401, "missing bearer token");
        case AuthStatus::InvalidToken:
            return fail(out, 401, "invalid or expired token");
        case AuthStatus::InvalidPayload:
            return fail(out, 401, "invalid token payload");
    }
    return fail(out, 500, "internal server error");
}

int App::health(Writer &out) {
    if (db_.ping()) {
        timespec now{};
        clock_gettime(CLOCK_MONOTONIC, &now);
        out.put("{\"status\":\"ok\",\"db\":\"ok\",\"uptime_s\":");
        out.put_int(now.tv_sec - start_.tv_sec);
        out.put('}');
        return 200;
    }
    out.put("{\"status\":\"degraded\",\"db\":\"unreachable\",\"error\":");
    out.put_json_string(db_.error());
    out.put('}');
    return 503;
}

int App::feed(Writer &out) {
    if (!db_.feed(out) || out.overflowed()) return fail(out, 500, "internal server error");
    return 200;
}

int App::get_post(View id_text, Writer &out) {
    int64_t id = 0;
    if (!parse_post_id(id_text, id)) return fail(out, 400, "invalid post id");
    switch (db_.post(id, out)) {
        case Lookup::Found:
            return out.overflowed() ? fail(out, 500, "internal server error") : 200;
        case Lookup::Missing:
            return fail(out, 404, "post not found");
        case Lookup::Failed:
            break;
    }
    return fail(out, 500, "internal server error");
}

int App::create_post(const Request &req, Writer &out) {
    Identity who;
    if (int status = authenticate(req, who, out)) return status;

    JsonFields fields;
    if (!scan_json(req.body, fields)) return fail(out, 400, "malformed JSON body");
    if (!fields.top_is_object || fields.body.kind != 's') return fail(out, 400, "body is required");

    View body = fields.body.escaped ? View(g_decoded, json_unescape(fields.body.p, fields.body.n, g_decoded)) : fields.body.raw();
    body = trim(body);
    if (body.empty()) return fail(out, 400, "body is required");
    if (body.size() > kMaxPostChars && char_count(body) > kMaxPostChars) return fail(out, 400, "body must be at most 500 characters");

    Created created;
    if (!db_.insert_post(who.user_id, body, created)) return fail(out, 500, "internal server error");
    out.put("{\"post\":");
    write_post(out, created.id, body, View(created.created_at.data(), created.created_at.size()), View(who.username.data(), who.username.size()), 0);
    out.put('}');
    return out.overflowed() ? fail(out, 500, "internal server error") : 201;
}

int App::like_post(const Request &req, View id_text, Writer &out) {
    Identity who;
    if (int status = authenticate(req, who, out)) return status;
    int64_t id = 0;
    if (!parse_post_id(id_text, id)) return fail(out, 400, "invalid post id");
    LikeResult result = db_.like(who.user_id, id);
    if (result == LikeResult::NoPost) return fail(out, 404, "post not found");
    if (result == LikeResult::Failed) return fail(out, 500, "internal server error");
    bool already = result == LikeResult::Already;
    out.put("{\"liked\":true,\"already_liked\":");
    out.put(already ? View("true") : View("false"));
    out.put(",\"post_id\":");
    out.put_int(id);
    out.put('}');
    return already ? 200 : 201;
}

int App::handle(const Request &req, Writer &out) {
    out.clear();
    View path = req.path;
    if (req.method == Method::Get) {
        if (path == View("/feed")) return feed(out);
        if (path == View("/health")) return health(out);
        if (path.starts_with(View("/posts/"))) {
            View rest = path.substr(7);
            if (rest.find('/') == View::npos) return get_post(rest, out);
        }
    } else if (req.method == Method::Post) {
        if (path == View("/posts")) return create_post(req, out);
        if (path.size() >= 12 && path.starts_with(View("/posts/")) && path.ends_with(View("/like"))) {
            View middle = path.substr(7, path.size() - 12);
            if (middle.find('/') == View::npos) return like_post(req, middle, out);
        }
    }
    return fail(out, 404, "not found");
}

}
