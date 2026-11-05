using System.Diagnostics;
using System.Text;
using System.Text.Json;

namespace Feed;

/// <summary>
/// Routes one request, validates it and writes its JSON body. Validation rules and error precedence come from
/// csharp-epoll-gichamba, which took them from the C# entry by maks-march (#27).
/// </summary>
internal sealed class Api(Db db, Jwt jwt) {
    // JavaScript's String.prototype.trim() whitespace set, so bodies trim like the reference.
    private static readonly char[] JsWhitespace = [
        '\t', '\n', '\v', '\f', '\r', ' ', (char)0x00A0, (char)0x1680, (char)0x2000, (char)0x2001, (char)0x2002, (char)0x2003, (char)0x2004,
        (char)0x2005, (char)0x2006, (char)0x2007, (char)0x2008, (char)0x2009, (char)0x200A, (char)0x2028, (char)0x2029, (char)0x202F,
        (char)0x205F, (char)0x3000, (char)0xFEFF,
    ];

    private readonly long _started = Stopwatch.GetTimestamp();
    private char[] _chars = new char[16 * 1024];
    private byte[] _utf8 = new byte[64 * 1024];

    /// <summary>Handles one request, writes its JSON body to <paramref name="o"/> and returns the HTTP status.</summary>
    public int Handle(ReadOnlySpan<byte> method, ReadOnlySpan<byte> path, ReadOnlySpan<byte> authorization,
        bool hasAuthorization, ReadOnlySpan<byte> body, Out o) {
        int q = path.IndexOf((byte)'?');
        if (q >= 0) {
            path = path[..q];
        }

        if (method.SequenceEqual("GET"u8)) {
            if (path.SequenceEqual("/feed"u8)) {
                int start = o.Len;
                if (db.Feed(o)) {
                    return 200;
                }

                o.Len = start;
                return Error(o, 500, Internal);
            }

            if (path.StartsWith("/posts/"u8) && path.Length > 7 && path[7..].IndexOf((byte)'/') < 0) {
                return ParseId(path[7..], out long id) switch {
                    IdResult.Invalid => Error(o, 400, InvalidId),
                    IdResult.TooLarge => Error(o, 404, PostNotFound),
                    _ => PostOrError(id, o),
                };
            }

            if (path.SequenceEqual("/health"u8)) {
                return Health(o);
            }
        } else if (method.SequenceEqual("POST"u8)) {
            if (path.SequenceEqual("/posts"u8)) {
                AuthStatus auth = jwt.Verify(authorization, hasAuthorization);
                return auth == AuthStatus.Ok ? Create(body, o) : AuthError(o, auth);
            }

            if (path.StartsWith("/posts/"u8) && path.EndsWith("/like"u8) && path.Length > 12
                && path[7..^5].IndexOf((byte)'/') < 0) {
                // Auth first, then the id (SPEC).
                AuthStatus auth = jwt.Verify(authorization, hasAuthorization);
                if (auth != AuthStatus.Ok) {
                    return AuthError(o, auth);
                }

                return ParseId(path[7..^5], out long id) switch {
                    IdResult.Invalid => Error(o, 400, InvalidId),
                    IdResult.TooLarge => Error(o, 404, PostNotFound),
                    _ => Like(id, o),
                };
            }
        }

        return Error(o, 404, NotFound);
    }

    private int PostOrError(long id, Out o) {
        int status = db.Post(id, o);
        return status == 200 ? 200 : Error(o, status, status == 404 ? PostNotFound : Internal);
    }

    private int Health(Out o) {
        string? error = db.Health();
        if (error is null) {
            o.Bytes("{\"status\":\"ok\",\"db\":\"ok\",\"uptime_s\":"u8);
            o.Int((Stopwatch.GetTimestamp() - _started) / Stopwatch.Frequency);
            o.Byte((byte)'}');
            return 200;
        }

        o.Bytes("{\"status\":\"degraded\",\"db\":\"unreachable\",\"error\":"u8);
        o.JsonString(Encoding.UTF8.GetBytes(error));
        o.Byte((byte)'}');
        return 503;
    }

    private int Create(ReadOnlySpan<byte> json, Out o) {
        switch (ReadBody(json, out int length)) {
            case BodyResult.Malformed: return Error(o, 400, Malformed);
            case BodyResult.Required: return Error(o, 400, BodyRequired);
        }

        ReadOnlySpan<char> trimmed = ((ReadOnlySpan<char>)_chars.AsSpan(0, length)).Trim(JsWhitespace);
        if (trimmed.IsEmpty) {
            return Error(o, 400, BodyRequired);
        }

        // The same unit as the schema's CHECK (length(body) ...): code points, so a request that passes here also passes there.
        if (CountCodePoints(trimmed) > 500) {
            return Error(o, 400, BodyTooLong);
        }

        int bytes = Encoding.UTF8.GetBytes(trimmed, _utf8);
        int start = o.Len;
        if (db.CreatePost(jwt.UserId, _utf8.AsSpan(0, bytes), jwt.Username, o)) {
            return 201;
        }

        o.Len = start;
        return Error(o, 500, Internal);
    }

    private static int CountCodePoints(ReadOnlySpan<char> s) {
        int n = s.Length;
        for (int i = 0; i + 1 < s.Length; i++) {
            if (char.IsHighSurrogate(s[i]) && char.IsLowSurrogate(s[i + 1])) {
                n--;
                i++;
            }
        }

        return n;
    }

    private int Like(long postId, Out o) {
        LikeOutcome outcome = db.Like(jwt.UserId, postId);
        if (outcome == LikeOutcome.PostMissing) {
            return Error(o, 404, PostNotFound);
        }

        if (outcome == LikeOutcome.Failed) {
            return Error(o, 500, Internal);
        }

        o.Bytes(outcome == LikeOutcome.Liked
            ? "{\"liked\":true,\"already_liked\":false,\"post_id\":"u8
            : "{\"liked\":true,\"already_liked\":true,\"post_id\":"u8);
        o.Int(postId);
        o.Byte((byte)'}');
        return outcome == LikeOutcome.Liked ? 201 : 200;
    }

    private enum BodyResult { Ok, Malformed, Required }

    /// <summary>
    /// Validates the whole document, then copies the root object's "body" string into _chars. A later "body" key replaces
    /// an earlier one. Malformed JSON wins over a missing or non-string body, as with JsonDocument.Parse.
    /// </summary>
    private BodyResult ReadBody(ReadOnlySpan<byte> json, out int length) {
        length = -1;
        bool rootIsObject = false;
        try {
            Utf8JsonReader reader = new(json);
            while (reader.Read()) {
                if (reader.CurrentDepth == 0 && reader.TokenType == JsonTokenType.StartObject) {
                    rootIsObject = true;
                }

                if (reader.CurrentDepth != 1 || reader.TokenType != JsonTokenType.PropertyName
                    || !reader.ValueTextEquals("body"u8)) {
                    continue;
                }

                reader.Read();
                if (reader.TokenType != JsonTokenType.String) {
                    length = -1;
                    if (reader.TokenType is JsonTokenType.StartObject or JsonTokenType.StartArray) {
                        reader.Skip();
                    }

                    continue;
                }

                int needed = reader.HasValueSequence ? (int)reader.ValueSequence.Length : reader.ValueSpan.Length;
                if (needed > _chars.Length) {
                    _chars = new char[needed];
                }

                length = reader.CopyString(_chars);
                if (length * 3 > _utf8.Length) {
                    _utf8 = new byte[length * 3];
                }
            }
        } catch (Exception ex) when (ex is JsonException or InvalidOperationException) {
            return BodyResult.Malformed;
        }

        return rootIsObject && length >= 0 ? BodyResult.Ok : BodyResult.Required;
    }

    private enum IdResult { Ok, Invalid, TooLarge }

    /// <summary>A positive integer in decimal digits. Beyond SQLite's INTEGER range it cannot name a row: 404, not 400.</summary>
    private static IdResult ParseId(ReadOnlySpan<byte> text, out long id) {
        id = 0;
        ulong value = 0;
        bool tooLarge = false;
        foreach (byte c in text) {
            if (c is < (byte)'0' or > (byte)'9') {
                return IdResult.Invalid;
            }

            if (tooLarge) {
                continue;
            }

            value = (value * 10) + (ulong)(c - '0');
            if (value > long.MaxValue) {
                tooLarge = true;
            }
        }

        if (tooLarge) {
            return IdResult.TooLarge;
        }

        if (value == 0) {
            return IdResult.Invalid;
        }

        id = (long)value;
        return IdResult.Ok;
    }

    private static int AuthError(Out o, AuthStatus status) {
        o.Bytes(status switch {
            AuthStatus.MissingToken => "{\"error\":\"missing bearer token\"}"u8,
            AuthStatus.BadPayload => "{\"error\":\"invalid token payload\"}"u8,
            _ => "{\"error\":\"invalid or expired token\"}"u8,
        });
        return 401;
    }

    private static ReadOnlySpan<byte> NotFound => "{\"error\":\"not found\"}"u8;
    private static ReadOnlySpan<byte> InvalidId => "{\"error\":\"invalid post id\"}"u8;
    private static ReadOnlySpan<byte> PostNotFound => "{\"error\":\"post not found\"}"u8;
    private static ReadOnlySpan<byte> Malformed => "{\"error\":\"malformed JSON body\"}"u8;
    private static ReadOnlySpan<byte> BodyRequired => "{\"error\":\"body is required\"}"u8;
    private static ReadOnlySpan<byte> BodyTooLong => "{\"error\":\"body must be at most 500 characters\"}"u8;
    private static ReadOnlySpan<byte> Internal => "{\"error\":\"internal server error\"}"u8;

    private static int Error(Out o, int status, ReadOnlySpan<byte> message) {
        o.Bytes(message);
        return status;
    }
}
