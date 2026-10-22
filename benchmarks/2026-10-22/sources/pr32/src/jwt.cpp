#include "jwt.hpp"

#include <openssl/crypto.h>
#include <openssl/sha.h>

#include <charconv>
#include <cstring>

#include "base64.hpp"
#include "json.hpp"

namespace srv {

namespace {

constexpr eastl::string_view kBearer = "Bearer ";
constexpr eastl::string_view kCanonicalHeader = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9";
constexpr size_t kMaxJson = 1024;
constexpr size_t kSignatureLength = 43;

bool header_is_hs256(eastl::string_view encoded) {
    if (encoded == kCanonicalHeader) return true;
    char buf[kMaxJson];
    size_t n = 0;
    if (!base64url_decode(encoded, buf, sizeof buf, n)) return false;
    JsonFields fields;
    if (!scan_json({buf, n}, fields) || !fields.top_is_object) return false;
    return fields.alg.kind == 's' && !fields.alg.escaped && fields.alg.raw() == eastl::string_view("HS256");
}

}

JwtVerifier::JwtVerifier(eastl::string_view secret) {
    unsigned char key[SHA256_CBLOCK] = {};
    if (secret.size() > sizeof key) {
        SHA256(reinterpret_cast<const unsigned char *>(secret.data()), secret.size(), key);
    } else {
        memcpy(key, secret.data(), secret.size());
    }
    unsigned char pad[SHA256_CBLOCK];
    for (size_t i = 0; i < sizeof pad; ++i) pad[i] = key[i] ^ 0x36;
    SHA256_Init(&inner_);
    SHA256_Update(&inner_, pad, sizeof pad);
    for (size_t i = 0; i < sizeof pad; ++i) pad[i] = key[i] ^ 0x5c;
    SHA256_Init(&outer_);
    SHA256_Update(&outer_, pad, sizeof pad);
}

AuthStatus JwtVerifier::verify(eastl::string_view authorization, int64_t now, Identity &out) const {
    if (!authorization.starts_with(kBearer)) return AuthStatus::MissingBearer;
    eastl::string_view token = authorization.substr(kBearer.size());

    size_t d1 = token.find('.');
    if (d1 == eastl::string_view::npos) return AuthStatus::InvalidToken;
    size_t d2 = token.find('.', d1 + 1);
    if (d2 == eastl::string_view::npos || token.find('.', d2 + 1) != eastl::string_view::npos) return AuthStatus::InvalidToken;

    if (!header_is_hs256(token.substr(0, d1))) return AuthStatus::InvalidToken;

    unsigned char digest[SHA256_DIGEST_LENGTH];
    unsigned char mac[SHA256_DIGEST_LENGTH];
    SHA256_CTX ctx = inner_;
    SHA256_Update(&ctx, token.data(), d2);
    SHA256_Final(digest, &ctx);
    ctx = outer_;
    SHA256_Update(&ctx, digest, sizeof digest);
    SHA256_Final(mac, &ctx);
    char expected[kSignatureLength + 1];
    size_t expected_len = base64url_encode(mac, sizeof mac, expected);
    eastl::string_view signature = token.substr(d2 + 1);
    if (signature.size() != expected_len || CRYPTO_memcmp(signature.data(), expected, expected_len) != 0) return AuthStatus::InvalidToken;

    char payload[kMaxJson];
    size_t payload_len = 0;
    if (!base64url_decode(token.substr(d1 + 1, d2 - d1 - 1), payload, sizeof payload, payload_len)) return AuthStatus::InvalidPayload;
    JsonFields fields;
    if (!scan_json({payload, payload_len}, fields) || !fields.top_is_object) return AuthStatus::InvalidPayload;

    if (fields.exp.kind != 0) {
        double exp = 0;
        if (fields.exp.kind != 'n') return AuthStatus::InvalidPayload;
        if (std::from_chars(fields.exp.p, fields.exp.p + fields.exp.n, exp).ec != std::errc{}) return AuthStatus::InvalidPayload;
        if (exp <= static_cast<double>(now)) return AuthStatus::InvalidToken;
    }

    if (fields.sub.kind != 's' || fields.sub.escaped || fields.sub.n == 0) return AuthStatus::InvalidPayload;
    int64_t user_id = 0;
    const char *sub_end = fields.sub.p + fields.sub.n;
    auto parsed = std::from_chars(fields.sub.p, sub_end, user_id);
    if (parsed.ec != std::errc{} || parsed.ptr != sub_end || user_id <= 0) return AuthStatus::InvalidPayload;

    if (fields.username.kind != 's' || fields.username.n > out.username.capacity()) return AuthStatus::InvalidPayload;
    char name[256];
    size_t name_len = fields.username.escaped ? json_unescape(fields.username.p, fields.username.n, name) : 0;
    if (!fields.username.escaped) {
        memcpy(name, fields.username.p, fields.username.n);
        name_len = fields.username.n;
    }
    if (name_len > out.username.capacity()) return AuthStatus::InvalidPayload;

    out.user_id = user_id;
    out.username.assign(name, name_len);
    return AuthStatus::Ok;
}

}
