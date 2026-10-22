#include <gtest/gtest.h>
#include <string>

#include "base64.hpp"
#include "jwt.hpp"
#include "test_util.hpp"

using srv::AuthStatus;
using View = eastl::string_view;

namespace {

constexpr const char *kSecret = "twelve-dollar-challenge";
constexpr int64_t kNow = 1'700'000'000;

using testutil::b64;
using testutil::token;

const std::string kHeader = R"({"alg":"HS256","typ":"JWT"})";

AuthStatus check(const std::string &auth, srv::Identity &id) {
    srv::JwtVerifier verifier{View(kSecret)};
    return verifier.verify(View(auth.data(), auth.size()), kNow, id);
}

}

TEST(Jwt, ValidToken) {
    srv::Identity id;
    ASSERT_EQ(check(token(kHeader, R"({"sub":"42","username":"bob","iat":1,"exp":1700003600})"), id), AuthStatus::Ok);
    EXPECT_EQ(id.user_id, 42);
    EXPECT_TRUE(View(id.username.data(), id.username.size()) == View("bob"));
}

TEST(Jwt, AcceptsNonCanonicalButValidHeader) {
    srv::Identity id;
    EXPECT_EQ(check(token(R"({ "typ": "JWT", "alg": "HS256" })", R"({"sub":"1","username":"a"})"), id), AuthStatus::Ok);
}

TEST(Jwt, MissingExpIsAccepted) {
    srv::Identity id;
    EXPECT_EQ(check(token(kHeader, R"({"sub":"1","username":"a"})"), id), AuthStatus::Ok);
}

TEST(Jwt, DecodesEscapedUsername) {
    srv::Identity id;
    ASSERT_EQ(check(token(kHeader, R"({"sub":"1","username":"caf\u00e9 \"x\""})"), id), AuthStatus::Ok);
    EXPECT_TRUE(View(id.username.data(), id.username.size()) == View("caf\xC3\xA9 \"x\""));
}

TEST(Jwt, MissingBearer) {
    srv::Identity id;
    EXPECT_EQ(check("", id), AuthStatus::MissingBearer);
    EXPECT_EQ(check("Basic abc", id), AuthStatus::MissingBearer);
    EXPECT_EQ(check("bearer abc", id), AuthStatus::MissingBearer);
}

TEST(Jwt, InvalidTokens) {
    srv::Identity id;
    const std::string good = R"({"sub":"1","username":"a","exp":1700003600})";
    EXPECT_EQ(check("Bearer abc", id), AuthStatus::InvalidToken);
    EXPECT_EQ(check("Bearer a.b", id), AuthStatus::InvalidToken);
    EXPECT_EQ(check("Bearer a.b.c.d", id), AuthStatus::InvalidToken);
    EXPECT_EQ(check(token(kHeader, good, "other-secret"), id), AuthStatus::InvalidToken);
    EXPECT_EQ(check(token(R"({"alg":"none"})", good), id), AuthStatus::InvalidToken);
    EXPECT_EQ(check(token(R"({"alg":"HS512","typ":"JWT"})", good), id), AuthStatus::InvalidToken);
    EXPECT_EQ(check(token("not json", good), id), AuthStatus::InvalidToken);
    EXPECT_EQ(check(token(kHeader, R"({"sub":"1","username":"a","exp":1699999999})"), id), AuthStatus::InvalidToken);
    EXPECT_EQ(check(token(kHeader, R"({"sub":"x","username":"a","exp":1699999999})"), id), AuthStatus::InvalidToken);
}

TEST(Jwt, TamperedSignatureAndPayload) {
    srv::Identity id;
    std::string t = token(kHeader, R"({"sub":"1","username":"a"})");
    std::string bad_sig = t;
    bad_sig.back() = bad_sig.back() == 'A' ? 'B' : 'A';
    EXPECT_EQ(check(bad_sig, id), AuthStatus::InvalidToken);
    std::string other = token(kHeader, R"({"sub":"2","username":"a"})");
    std::string swapped = t.substr(0, t.find_last_of('.')) + other.substr(other.find_last_of('.'));
    EXPECT_EQ(check(swapped, id), AuthStatus::InvalidToken);
}

TEST(Jwt, InvalidPayloads) {
    srv::Identity id;
    for (const char *payload : {
             R"({"sub":"abc","username":"a"})", R"({"sub":"0","username":"a"})", R"({"sub":"-1","username":"a"})",
             R"({"sub":"1.5","username":"a"})", R"({"sub":"","username":"a"})", R"({"sub":5,"username":"a"})",
             R"({"username":"a"})", R"({"sub":"1"})", R"({"sub":"1","username":7})", R"({"sub":"1","username":null})",
             R"({"sub":"1","username":"a","exp":"soon"})", R"([1,2])", R"("text")", R"({"sub":"1","username":)",
         }) {
        EXPECT_EQ(check(token(kHeader, payload), id), AuthStatus::InvalidPayload) << payload;
    }
}

TEST(Jwt, OverlongUsernameIsRejected) {
    srv::Identity id;
    EXPECT_EQ(check(token(kHeader, R"({"sub":"1","username":")" + std::string(254, 'a') + R"("})"), id), AuthStatus::Ok);
    EXPECT_EQ(check(token(kHeader, R"({"sub":"1","username":")" + std::string(255, 'a') + R"("})"), id), AuthStatus::InvalidPayload);
}

TEST(Base64Url, RoundTripsAndRejectsGarbage) {
    for (size_t n = 0; n < 40; ++n) {
        std::string raw;
        for (size_t i = 0; i < n; ++i) raw.push_back(static_cast<char>(i * 37 + 11));
        std::string enc = b64(raw);
        std::string dec(n + 4, '\0');
        size_t got = 0;
        ASSERT_TRUE(srv::base64url_decode(View(enc.data(), enc.size()), dec.data(), dec.size(), got));
        EXPECT_EQ(std::string(dec.data(), got), raw);
    }
    char out[16];
    size_t n = 0;
    EXPECT_FALSE(srv::base64url_decode(View("ab+/"), out, sizeof out, n));
    EXPECT_FALSE(srv::base64url_decode(View("a"), out, sizeof out, n));
    EXPECT_FALSE(srv::base64url_decode(View("abcdefghijklmnopqrstuvwxyz"), out, sizeof out, n));
}

TEST(Jwt, MatchesOpenSslHmacForEverySecretLength) {
    for (size_t n : {0, 1, 63, 64, 65, 128, 200}) {
        std::string secret(n, 'k');
        for (size_t i = 0; i < n; ++i) secret[i] = static_cast<char>('a' + i % 26);
        std::string auth = token(kHeader, R"({"sub":"7","username":"zed","iat":1,"exp":1700003600})", secret.c_str());
        srv::JwtVerifier verifier{View(secret.data(), secret.size())};
        srv::Identity id;
        EXPECT_EQ(verifier.verify(View(auth.data(), auth.size()), kNow, id), AuthStatus::Ok) << "secret length " << n;
        srv::JwtVerifier other{View("different")};
        EXPECT_EQ(other.verify(View(auth.data(), auth.size()), kNow, id), AuthStatus::InvalidToken) << "secret length " << n;
    }
}
