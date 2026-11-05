using System.Buffers.Text;
using System.Security.Cryptography;
using System.Text.Json;

namespace Feed;

/// <summary>Result of <see cref="Jwt.Verify"/>.</summary>
internal enum AuthStatus {
    Ok,
    MissingToken,   // no Authorization header, or it doesn't start with "Bearer "
    InvalidToken,   // bad signature, expired, not yet valid, not HS256, or malformed JWT
    BadPayload,     // valid JWT, but sub or username is missing, sub isn't a positive integer string, or username isn't a string
}

/// <summary>
/// HS256 verification on every authenticated request (rule 5: no remembered verifications), on the raw header bytes.
/// From csharp-epoll-gichamba. Not thread-safe: the request thread is the only caller.
/// </summary>
internal sealed class Jwt(byte[] secret) {
    private const int MaxSegment = 1024;

    private readonly HMACSHA256 _hmac = new(secret);
    private readonly byte[] _username = new byte[MaxSegment];
    private int _usernameLength;

    /// <summary>The verified token's <c>sub</c>. Meaningful only after Verify returned Ok.</summary>
    public long UserId { get; private set; }

    /// <summary>The verified token's username as UTF-8. Meaningful only after Verify returned Ok, until the next call.</summary>
    public ReadOnlySpan<byte> Username => _username.AsSpan(0, _usernameLength);

    /// <summary>Checks an Authorization value: a "Bearer " three-part HS256 JWT with a valid signature, a future exp, and usable claims.</summary>
    public AuthStatus Verify(ReadOnlySpan<byte> authorization, bool present) {
        if (!present || !authorization.StartsWith("Bearer "u8)) {
            return AuthStatus.MissingToken;
        }

        ReadOnlySpan<byte> token = authorization[7..];
        int dot1 = token.IndexOf((byte)'.');
        if (dot1 < 0) {
            return AuthStatus.InvalidToken;
        }

        int dot2 = token[(dot1 + 1)..].IndexOf((byte)'.');
        if (dot2 < 0) {
            return AuthStatus.InvalidToken;
        }

        dot2 += dot1 + 1;
        if (token[(dot2 + 1)..].IndexOf((byte)'.') >= 0 || dot2 > MaxSegment) {
            return AuthStatus.InvalidToken;
        }

        // alg must be HS256, checked before the signature: alg=none is invalid, never verified.
        Span<byte> head = stackalloc byte[512];
        if (!TryB64UrlDecode(token[..dot1], head, out int headLen) || !IsHs256Header(head[..headLen])) {
            return AuthStatus.InvalidToken;
        }

        Span<byte> sig = stackalloc byte[48];
        if (!TryB64UrlDecode(token[(dot2 + 1)..], sig, out int sigLen) || sigLen != 32) {
            return AuthStatus.InvalidToken;
        }

        Span<byte> payload = stackalloc byte[768];
        if (!TryB64UrlDecode(token[(dot1 + 1)..dot2], payload, out int payloadLen)) {
            return AuthStatus.InvalidToken;
        }

        Span<byte> digest = stackalloc byte[32];
        _hmac.TryComputeHash(token[..dot2], digest, out _);
        if (!CryptographicOperations.FixedTimeEquals(sig[..32], digest)) {
            return AuthStatus.InvalidToken;
        }

        return ParsePayload(payload[..payloadLen]);
    }

    private static bool IsHs256Header(ReadOnlySpan<byte> json) {
        try {
            Utf8JsonReader reader = new(json);
            if (!reader.Read() || reader.TokenType != JsonTokenType.StartObject) {
                return false;
            }

            bool sawAlgorithm = false;
            while (reader.Read()) {
                if (reader.TokenType == JsonTokenType.EndObject) {
                    return sawAlgorithm && !reader.Read();
                }

                if (reader.TokenType != JsonTokenType.PropertyName) {
                    return false;
                }

                bool isAlgorithm = reader.ValueTextEquals("alg"u8);
                if (!reader.Read()) {
                    return false;
                }

                if (isAlgorithm) {
                    if (reader.TokenType != JsonTokenType.String || !reader.ValueTextEquals("HS256"u8)) {
                        return false;
                    }

                    sawAlgorithm = true;
                } else {
                    reader.Skip();
                }
            }

            return false;
        } catch (JsonException) {
            return false;
        }
    }

    private AuthStatus ParsePayload(ReadOnlySpan<byte> json) {
        bool sawSub = false, sawUsername = false, sawExpiration = false;
        Span<byte> sub = stackalloc byte[768];
        long now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        try {
            Utf8JsonReader reader = new(json);
            if (!reader.Read() || reader.TokenType != JsonTokenType.StartObject) {
                return AuthStatus.InvalidToken;
            }

            while (reader.Read()) {
                if (reader.TokenType == JsonTokenType.EndObject) {
                    if (reader.Read()) {
                        return AuthStatus.InvalidToken;
                    }

                    break;
                }

                if (reader.TokenType != JsonTokenType.PropertyName) {
                    return AuthStatus.InvalidToken;
                }

                bool isExp = reader.ValueTextEquals("exp"u8);
                bool isNbf = !isExp && reader.ValueTextEquals("nbf"u8);
                bool isSub = !isExp && !isNbf && reader.ValueTextEquals("sub"u8);
                bool isUsername = !isExp && !isNbf && !isSub && reader.ValueTextEquals("username"u8);
                if (!reader.Read()) {
                    return AuthStatus.InvalidToken;
                }

                JsonTokenType kind = reader.TokenType;
                if (isExp || isNbf) {
                    if (isNbf && kind == JsonTokenType.Null) {
                        continue;
                    }

                    if (kind != JsonTokenType.Number) {
                        return AuthStatus.InvalidToken;
                    }

                    if (!reader.TryGetDouble(out double moment) || !double.IsFinite(moment)
                        || (isExp ? now >= moment : now < moment)) {
                        return AuthStatus.InvalidToken;
                    }

                    sawExpiration |= isExp;
                } else if (isSub) {
                    if (kind != JsonTokenType.String || reader.ValueSpan.Length > sub.Length) {
                        return AuthStatus.BadPayload;
                    }

                    int subLength = reader.CopyString(sub);
                    if (!TryParseSub(sub[..subLength], out long userId)) {
                        return AuthStatus.BadPayload;
                    }

                    UserId = userId;
                    sawSub = true;
                } else if (isUsername) {
                    if (kind != JsonTokenType.String) {
                        return AuthStatus.BadPayload;
                    }

                    _usernameLength = reader.CopyString(_username);
                    sawUsername = true;
                } else {
                    reader.Skip();
                }
            }
        } catch (JsonException) {
            return AuthStatus.InvalidToken;
        }

        if (!sawExpiration) {
            return AuthStatus.InvalidToken;
        }

        return sawSub && sawUsername ? AuthStatus.Ok : AuthStatus.BadPayload;
    }

    private static bool TryParseSub(ReadOnlySpan<byte> sub, out long userId) {
        userId = 0;
        if (sub.IsEmpty) {
            return false;
        }

        foreach (byte c in sub) {
            if (c is < (byte)'0' or > (byte)'9') {
                return false;
            }
        }

        return Utf8Parser.TryParse(sub, out userId, out int consumed) && consumed == sub.Length && userId > 0;
    }

    /// <summary>Base64url without padding; rejects any other character.</summary>
    private static bool TryB64UrlDecode(ReadOnlySpan<byte> src, Span<byte> dst, out int written) {
        written = 0;
        int len = src.Length;
        if (len == 0 || (len & 3) == 1) {
            return false;
        }

        int expected = (len / 4 * 3) + (len % 4 == 2 ? 1 : len % 4 == 3 ? 2 : 0);
        if (expected > dst.Length) {
            return false;
        }

        int acc = 0, bits = 0, o = 0;
        foreach (byte c in src) {
            int v = c switch {
                >= (byte)'A' and <= (byte)'Z' => c - 'A',
                >= (byte)'a' and <= (byte)'z' => c - 'a' + 26,
                >= (byte)'0' and <= (byte)'9' => c - '0' + 52,
                (byte)'-' => 62,
                (byte)'_' => 63,
                _ => -1,
            };
            if (v < 0) {
                return false;
            }

            acc = (acc << 6) | v;
            bits += 6;
            if (bits >= 8) {
                bits -= 8;
                dst[o++] = (byte)(acc >> bits);
            }
        }

        written = o;
        return true;
    }
}
