// What a request asks for, decided on the reactor that parsed it: SPEC.md's five endpoints. Whatever needs no database
// (a 404, a bad id, a bad token or body) is answered on the spot; the rest is a query for SQLite.

nonisolated extension HTTP {
    /// A parsed request, borrowing the bytes it was parsed from (the reactor's read buffer, or a de-chunked body): it
    /// can't outlive them, so routing reads them in place.
    struct Request: ~Escapable {
        let method: Span<UInt8>
        let path: Span<UInt8>
        let auth: Span<UInt8>?
        let body: Span<UInt8>

        @_lifetime(copy method, copy path, copy auth, copy body)
        init(method: Span<UInt8>, path: Span<UInt8>, auth: Span<UInt8>?, body: Span<UInt8>) {
            self.method = method
            self.path = path
            self.auth = auth
            self.body = body
        }
    }
}

nonisolated enum Router {
    /// What routing decided, used once: an error answered now (the reactor writes its body), or a query.
    enum Dispatch: ~Copyable {
        case error(UInt16, StaticString)
        case read(Query)
        /// Commits with its pass's transaction, before its response (rule 6).
        case write(Query)
    }

    @inline(__always) private static func fail(_ status: UInt16, _ message: StaticString) -> Dispatch {
        .error(status, message)
    }

    static func route(_ signer: TokenSigner, _ req: borrowing HTTP.Request) -> Dispatch {
        let path = req.path
        if Bytes.equal(req.method, "GET") {
            if Bytes.equal(path, "/feed") { return .read(.feed) }
            if Bytes.equal(path, "/health") { return .read(.health) }
            if let id = segment(path, after: "/posts/"), Bytes.find(id, 0x2F) == nil {
                guard let postID = postID(id) else { return fail(400, "invalid post id") }
                return .read(.post(id: postID))
            }
        } else if Bytes.equal(req.method, "POST") {
            if Bytes.equal(path, "/posts") {
                // The response echoes the username: it is copied, as the post's text is.
                let author: (id: Int64, name: [UInt8])
                switch bearer(signer, req.auth, { id, name in (id, Bytes.array(name)) }) {
                case .claims(let a): author = a
                case .rejected(let message): return fail(401, message)
                }
                switch newPostText(req.body) {
                case .text(let text): return .write(.createPost(userID: author.id, body: text, author: author.name))
                case .rejected(let message): return fail(400, message)
                }
            }
            if let rest = segment(path, after: "/posts/"), let slash = Bytes.find(rest, 0x2F),
               Bytes.equal(rest.extracting(slash..<rest.count), "/like")
            {
                // Auth first, then the id (SPEC.md). A like needs only the user id.
                let userID: Int64
                switch bearer(signer, req.auth, { id, _ in id }) {
                case .claims(let id): userID = id
                case .rejected(let message): return fail(401, message)
                }
                guard let postID = postID(rest.extracting(0..<slash)) else { return fail(400, "invalid post id") }
                return .write(.like(userID: userID, postID: postID))
            }
        }
        return fail(404, "not found")
    }

    /// What follows `prefix` in `path`, if `path` starts with it and something follows.
    @_lifetime(copy path)
    private static func segment(_ path: Span<UInt8>, after prefix: StaticString) -> Span<UInt8>? {
        let n = prefix.utf8CodeUnitCount
        guard path.count > n, Bytes.equal(path.extracting(0..<n), prefix) else { return nil }
        return path.extracting(n..<path.count)
    }

    /// A post id: a positive decimal integer.
    private static func postID(_ digits: Span<UInt8>) -> Int64? {
        guard digits.count > 0 else { return nil }
        var value: Int64 = 0
        for i in 0..<digits.count {
            let ch = digits[i]
            guard (0x30...0x39).contains(ch) else { return nil }
            let (m, o1) = value.multipliedReportingOverflow(by: 10)
            let (s, o2) = m.addingReportingOverflow(Int64(ch - 0x30))
            if o1 || o2 { return nil }
            value = s
        }
        return value > 0 ? value : nil
    }

    // ---------- auth ----------

    private enum Bearer<Value> {
        case claims(Value)
        case rejected(StaticString)
    }

    /// What `body` makes of the claims of an `Authorization: Bearer <jwt>` header, or the 401's message.
    private static func bearer<R>(_ signer: TokenSigner, _ header: Span<UInt8>?, _ body: (Int64, Span<UInt8>) -> R) -> Bearer<R> {
        guard let header, header.count >= 7, Bytes.equal(header.extracting(0..<7), "Bearer ") else {
            return .rejected("missing bearer token")
        }
        switch signer.verify(header.extracting(7..<header.count), body) {
        case .valid(let value): return .claims(value)
        case .invalid: return .rejected("invalid or expired token")
        case .badPayload: return .rejected("invalid token payload")
        }
    }

    // ---------- the new post's body ----------

    private enum NewPost {
        case text([UInt8])
        case rejected(StaticString)
    }

    /// `{"body":"..."}`: trimmed as JavaScript's `trim()` does, then 1 to 500 characters (code points, Postgres's
    /// `char_length`).
    private static func newPostText(_ body: Span<UInt8>) -> NewPost {
        guard let fields = JSON.scan(body, keys: ["body"]) else { return .rejected("malformed JSON body") }
        guard let text = fields[0], text.kind == .string else { return .rejected("body is required") }
        return JSON.withString(body, text) { span in
            let kept = trimmed(span)
            if kept.isEmpty { return .rejected("body is required") }
            if kept.count > 500 {
                var characters = 0
                for i in kept where span[i] & 0xC0 != 0x80 { characters += 1 }
                if characters > 500 { return .rejected("body must be at most 500 characters") }
            }
            // The one copy: the text outlives the request (a write can wait for a checkpoint).
            return .text(Bytes.array(span.extracting(kept)))
        }
    }

    /// The part of `s` (valid UTF-8) without the leading and trailing whitespace and line terminators JavaScript's
    /// `trim()` removes.
    private static func trimmed(_ s: Span<UInt8>) -> Range<Int> {
        var start = 0
        while start < s.count {
            let n = whitespaceLength(s, at: start)
            if n == 0 { break }
            start += n
        }
        var end = s.count
        while end > start {
            var lead = end - 1
            while lead > start && s[lead] & 0xC0 == 0x80 { lead -= 1 }
            let n = whitespaceLength(s, at: lead)
            if n == 0 || lead + n != end { break }
            end = lead
        }
        return start..<end
    }

    /// The UTF-8 length of the `trim()` whitespace character at `i`, or 0: TAB, LF, VT, FF, CR, SPACE, U+00A0, U+1680,
    /// U+2000–U+200A, U+2028, U+2029, U+202F, U+205F, U+3000 and U+FEFF.
    @inline(__always) private static func whitespaceLength(_ s: Span<UInt8>, at i: Int) -> Int {
        switch s[i] {
        case 0x09...0x0D, 0x20:
            return 1
        case 0xC2:
            return i + 1 < s.count && s[i + 1] == 0xA0 ? 2 : 0
        case 0xE1, 0xE2, 0xE3, 0xEF:
            guard i + 2 < s.count else { return 0 }
            let (b0, b1, b2) = (s[i], s[i + 1], s[i + 2])
            switch (b0, b1) {
            case (0xE1, 0x9A): return b2 == 0x80 ? 3 : 0
            case (0xE2, 0x80): return (0x80...0x8A).contains(b2) || b2 == 0xA8 || b2 == 0xA9 || b2 == 0xAF ? 3 : 0
            case (0xE2, 0x81): return b2 == 0x9F ? 3 : 0
            case (0xE3, 0x80): return b2 == 0x80 ? 3 : 0
            case (0xEF, 0xBB): return b2 == 0xBF ? 3 : 0
            default: return 0
            }
        default:
            return 0
        }
    }
}
