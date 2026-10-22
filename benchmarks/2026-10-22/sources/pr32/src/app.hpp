#pragma once

#include <EASTL/string_view.h>

#include <ctime>

#include "db.hpp"
#include "http.hpp"
#include "jwt.hpp"
#include "writer.hpp"

namespace srv {

class App {
public:
    App(Db &db, const JwtVerifier &jwt);

    int handle(const Request &req, Writer &out);

private:
    int fail(Writer &out, int status, const char *message);
    int authenticate(const Request &req, Identity &who, Writer &out);
    int health(Writer &out);
    int feed(Writer &out);
    int get_post(eastl::string_view id, Writer &out);
    int create_post(const Request &req, Writer &out);
    int like_post(const Request &req, eastl::string_view id, Writer &out);

    Db &db_;
    const JwtVerifier &jwt_;
    timespec start_{};
};

bool parse_post_id(eastl::string_view text, int64_t &id);

}
