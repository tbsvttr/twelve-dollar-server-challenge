#pragma once

#include <EASTL/fixed_string.h>
#include <EASTL/string_view.h>
#include <openssl/sha.h>

#include <cstdint>

namespace srv {

enum class AuthStatus { Ok, MissingBearer, InvalidToken, InvalidPayload };

struct Identity {
    int64_t user_id = 0;
    eastl::fixed_string<char, 255, false> username;
};

class JwtVerifier {
public:
    explicit JwtVerifier(eastl::string_view secret);

    AuthStatus verify(eastl::string_view authorization, int64_t now, Identity &out) const;

private:
    SHA256_CTX inner_;
    SHA256_CTX outer_;
};

}
