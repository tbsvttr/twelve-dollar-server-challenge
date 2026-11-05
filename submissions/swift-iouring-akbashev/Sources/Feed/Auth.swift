// SHA-256 and HMAC-SHA256 (HS256 with the secret's ipad/opad midstates computed once), and the bearer token check
// SPEC.md asks for on every authenticated request: signature, `alg`, a required `exp`, then `sub` and `username`.
import Glibc

/// SHA-256 and HMAC-SHA256, portable: Swift doesn't reach the SHA-NI instructions.
nonisolated enum SHA256 {
    typealias State = InlineArray<8, UInt32>
    typealias Digest = InlineArray<32, UInt8>

    static let initialState: State = [
        0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a, 0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19,
    ]

    private static let roundConstants: InlineArray<64, UInt32> = [
        0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5, 0x3956_c25b, 0x59f1_11f1, 0x923f_82a4, 0xab1c_5ed5,
        0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3, 0x72be_5d74, 0x80de_b1fe, 0x9bdc_06a7, 0xc19b_f174,
        0xe49b_69c1, 0xefbe_4786, 0x0fc1_9dc6, 0x240c_a1cc, 0x2de9_2c6f, 0x4a74_84aa, 0x5cb0_a9dc, 0x76f9_88da,
        0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7, 0xc6e0_0bf3, 0xd5a7_9147, 0x06ca_6351, 0x1429_2967,
        0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc, 0x5338_0d13, 0x650a_7354, 0x766a_0abb, 0x81c2_c92e, 0x9272_2c85,
        0xa2bf_e8a1, 0xa81a_664b, 0xc24b_8b70, 0xc76c_51a3, 0xd192_e819, 0xd699_0624, 0xf40e_3585, 0x106a_a070,
        0x19a4_c116, 0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5, 0x391c_0cb3, 0x4ed8_aa4a, 0x5b9c_ca4f, 0x682e_6ff3,
        0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208, 0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7, 0xc671_78f2,
    ]

    @inline(__always) private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { x >> n | x << (32 - n) }

    @inline(__always) static func compressWords(_ state: inout State, _ words: InlineArray<16, UInt32>) {
        var w = words
        var a = state[0], b = state[1], c = state[2], d = state[3]
        var e = state[4], f = state[5], g = state[6], h = state[7]
        for i in 0..<64 {
            if i >= 16 {
                let w15 = w[(i + 1) & 15]
                let w2 = w[(i + 14) & 15]
                let s0 = rotr(w15, 7) ^ rotr(w15, 18) ^ (w15 >> 3)
                let s1 = rotr(w2, 17) ^ rotr(w2, 19) ^ (w2 >> 10)
                w[i & 15] = w[i & 15] &+ s0 &+ w[(i + 9) & 15] &+ s1
            }
            let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
            let ch = (e & f) ^ (~e & g)
            let temp1 = h &+ s1 &+ ch &+ roundConstants[i] &+ w[i & 15]
            let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let temp2 = s0 &+ maj
            h = g
            g = f
            f = e
            e = d &+ temp1
            d = c
            c = b
            b = a
            a = temp1 &+ temp2
        }
        state[0] &+= a
        state[1] &+= b
        state[2] &+= c
        state[3] &+= d
        state[4] &+= e
        state[5] &+= f
        state[6] &+= g
        state[7] &+= h
    }

    /// Compresses the 64-byte block at `offset` of `data`.
    @inline(__always) static func compressBlock(_ state: inout State, _ data: RawSpan, at offset: Int = 0) {
        var w = InlineArray<16, UInt32>(repeating: 0)
        for i in 0..<16 { w[i] = data.load(fromByteOffset: offset + 4 * i, as: UInt32.self, .bigEndian) }
        compressWords(&state, w)
    }

    static func hash(from initial: State, priorBytes: UInt64, _ data: Span<UInt8>) -> State {
        var state = initial
        let full = data.count / 64
        for i in 0..<full { compressBlock(&state, data.bytes, at: 64 * i) }
        let rem = data.count - 64 * full
        let totalBits = (priorBytes + UInt64(data.count)) * 8
        var tail = InlineArray<64, UInt8>(repeating: 0)
        for i in 0..<rem { tail[i] = data[64 * full + i] }
        tail[rem] = 0x80
        if rem >= 56 {
            compressBlock(&state, tail.span.bytes)
            tail = InlineArray(repeating: 0)
        }
        for i in 0..<8 { tail[56 + i] = UInt8(truncatingIfNeeded: totalBits >> (56 - 8 * UInt64(i))) }
        compressBlock(&state, tail.span.bytes)
        return state
    }

    @inline(__always) static func stateBytes(_ state: State) -> Digest {
        Digest { i in UInt8(truncatingIfNeeded: state[i >> 2] >> (24 - 8 * UInt32(i & 3))) }
    }

    static func digest(_ data: Span<UInt8>) -> Digest {
        stateBytes(hash(from: initialState, priorBytes: 0, data))
    }

    static func hmac(key: borrowing [UInt8], _ data: Span<UInt8>) -> Digest {
        TokenSigner(secret: key).sign(data)
    }
}

/// HS256 with the secret's ipad/opad midstates precomputed: each signature costs the message's blocks plus one.
nonisolated struct TokenSigner {
    private var ipadState: SHA256.State
    private var opadState: SHA256.State

    init(secret: borrowing [UInt8]) {
        var block = InlineArray<64, UInt8>(repeating: 0)
        if secret.count > 64 {
            let hashed = SHA256.digest(secret.span)
            for i in 0..<32 { block[i] = hashed[i] }
        } else {
            for i in 0..<secret.count { block[i] = secret[i] }
        }
        let ipad = InlineArray<64, UInt8> { 0x36 ^ block[$0] }
        let opad = InlineArray<64, UInt8> { 0x5C ^ block[$0] }
        ipadState = SHA256.initialState
        opadState = SHA256.initialState
        SHA256.compressBlock(&ipadState, ipad.span.bytes)
        SHA256.compressBlock(&opadState, opad.span.bytes)
    }

    func sign(_ data: Span<UInt8>) -> SHA256.Digest {
        let inner = SHA256.hash(from: ipadState, priorBytes: 64, data)
        let words: InlineArray<16, UInt32> = [
            inner[0], inner[1], inner[2], inner[3], inner[4], inner[5], inner[6], inner[7],
            0x8000_0000, 0, 0, 0, 0, 0, 0, 768,
        ]
        var outer = opadState
        SHA256.compressWords(&outer, words)
        return SHA256.stateBytes(outer)
    }


    /// Checks a bearer token (SPEC.md, Auth): a verified signature, `alg` HS256 and an unexpired `exp` make it valid;
    /// then `sub` must be a positive integer string and `username` a string. A valid token's user id and username go
    /// to `body` while the decoded payload is borrowed: the name is a view of it, copied only by a caller that keeps
    /// it.
    func verify<R>(_ token: Span<UInt8>, _ body: (_ userID: Int64, _ username: Span<UInt8>) -> R) -> Verdict<R> {
        guard let dot1 = Bytes.find(token, 0x2E), let dot2 = Bytes.find(token, 0x2E, from: dot1 + 1) else { return .invalid }
        let header = token.extracting(0..<dot1)
        let payload64 = token.extracting((dot1 + 1)..<dot2)
        let signature64 = token.extracting((dot2 + 1)..<token.count)
        if Bytes.find(signature64, 0x2E) != nil { return .invalid }

        var signature = InlineArray<48, UInt8>(repeating: 0)
        var signatureSpan = signature.mutableSpan
        guard Base64.urlDecode(signature64, into: &signatureSpan) == 32 else { return .invalid }
        guard Self.constantTimeEqual32(sign(token.extracting(0..<dot2)), signature.span) else { return .invalid }
        guard Self.isHS256(header) else { return .invalid }

        // A payload is decoded on the stack (a rare long one onto the heap).
        let now = Sys.unixNowF64()
        if payload64.count <= 680 {
            var payload = InlineArray<512, UInt8>(repeating: 0)
            var payloadSpan = payload.mutableSpan
            guard let n = Base64.urlDecode(payload64, into: &payloadSpan) else { return .invalid }
            return Self.claims(payload.span.extracting(0..<n), now: now, body)
        }
        guard let payload = Base64.urlDecodeArray(payload64) else { return .invalid }
        return Self.claims(payload.span, now: now, body)
    }
}

nonisolated extension TokenSigner {
    enum Verdict<Value> {
        case valid(Value)
        /// Bad signature, expired, not HS256, or malformed: 401 "invalid or expired token".
        case invalid
        /// Valid, but `sub` isn't a positive integer string or `username` isn't a string: 401 "invalid token payload".
        case badPayload
    }

    private static let headerStandard: StaticString = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
    private static let headerReordered: StaticString = "eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9"
    private static let headerMinimal: StaticString = "eyJhbGciOiJIUzI1NiJ9"

    /// Whether the header says `"alg":"HS256"`: the usual spellings compared as they are, anything else read.
    private static func isHS256(_ header: Span<UInt8>) -> Bool {
        if Bytes.equal(header, headerStandard) || Bytes.equal(header, headerReordered) || Bytes.equal(header, headerMinimal) {
            return true
        }
        if header.count > 340 { return false }
        var bytes = InlineArray<256, UInt8>(repeating: 0)
        var span = bytes.mutableSpan
        guard let n = Base64.urlDecode(header, into: &span) else { return false }
        let json = bytes.span.extracting(0..<n)
        guard let fields = JSON.scan(json, keys: ["alg"]), let alg = fields[0], alg.kind == .string else { return false }
        return JSON.withString(json, alg) { Bytes.equal($0, "HS256") }
    }

    /// The claims, read in place: `exp` (required) and `nbf` against the clock, `iat` a number if present, then
    /// `sub` and `username`.
    private static func claims<R>(_ payload: Span<UInt8>, now: Double, _ body: (Int64, Span<UInt8>) -> R) -> Verdict<R> {
        guard let fields = JSON.scan(payload, keys: ["exp", "nbf", "iat", "sub", "username"]), fields.isObject,
              let exp = fields[0], exp.kind == .number,
              let expires = JSON.number(payload, exp), now < expires else { return .invalid }
        if let nbf = fields[1] {
            guard nbf.kind == .number, let notBefore = JSON.number(payload, nbf), now >= notBefore else { return .invalid }
        }
        if let iat = fields[2], iat.kind != .number { return .invalid }
        guard let sub = fields[3], sub.kind == .string, let userID = JSON.withString(payload, sub, positiveInteger),
              let name = fields[4], name.kind == .string else { return .badPayload }
        return .valid(JSON.withString(payload, name) { body(userID, $0) })
    }

    /// A positive decimal integer that fits an Int64, nil otherwise.
    private static func positiveInteger(_ digits: Span<UInt8>) -> Int64? {
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

    @inline(__always) private static func constantTimeEqual32(_ a: SHA256.Digest, _ b: Span<UInt8>) -> Bool {
        guard b.count >= 32 else { return false }
        var diff: UInt8 = 0
        for i in 0..<32 { diff |= a[i] ^ b[i] }
        return diff == 0
    }
}
