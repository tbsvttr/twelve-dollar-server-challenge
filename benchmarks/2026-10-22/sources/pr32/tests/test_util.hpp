#pragma once

#include <openssl/evp.h>
#include <openssl/hmac.h>

#include <cstring>
#include <string>

#include "base64.hpp"

namespace testutil {

inline constexpr const char *kTestSchema = R"(
CREATE TABLE users (id INTEGER PRIMARY KEY, username TEXT NOT NULL UNIQUE, created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')));
CREATE TABLE posts (id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL REFERENCES users(id), body TEXT NOT NULL CHECK (length(body) BETWEEN 1 AND 500), created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')));
CREATE TABLE likes (user_id INTEGER NOT NULL REFERENCES users(id), post_id INTEGER NOT NULL REFERENCES posts(id), created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')), PRIMARY KEY (user_id, post_id));
CREATE INDEX posts_created_at_id_idx ON posts (created_at DESC, id DESC);
CREATE INDEX posts_user_id_idx ON posts (user_id);
CREATE INDEX likes_post_id_idx ON likes (post_id);
)";

inline std::string b64(const std::string &raw) {
    std::string out(raw.size() * 2 + 4, '\0');
    out.resize(srv::base64url_encode(reinterpret_cast<const unsigned char *>(raw.data()), raw.size(), out.data()));
    return out;
}

inline std::string token(const std::string &header, const std::string &payload, const char *secret = "twelve-dollar-challenge") {
    std::string signing = b64(header) + "." + b64(payload);
    unsigned char mac[EVP_MAX_MD_SIZE];
    unsigned int len = 0;
    HMAC(EVP_sha256(), secret, static_cast<int>(strlen(secret)), reinterpret_cast<const unsigned char *>(signing.data()), signing.size(), mac, &len);
    std::string sig(64, '\0');
    sig.resize(srv::base64url_encode(mac, len, sig.data()));
    return "Bearer " + signing + "." + sig;
}

inline std::string user_token(int64_t id, const std::string &name) {
    return token(R"({"alg":"HS256","typ":"JWT"})", "{\"sub\":\"" + std::to_string(id) + "\",\"username\":\"" + name + "\",\"iat\":1,\"exp\":4102444800}");
}

}
