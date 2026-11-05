// Byte search, the JSON writer (strings, integers, RFC 3339 timestamps), base64url, and the JSON reader for
// request bodies and JWT claims: a validating pass that builds nothing and reads strings in place. Readers take a `Span`; the parser is a ~Escapable view over one.
import Glibc
import Syscalls

/// Byte search and comparison.
nonisolated enum Bytes {
    /// The first `needle` in `hay[from..<end]` (memchr: glibc's vectorized search).
    @inline(__always) static func find(_ hay: Span<UInt8>, _ needle: UInt8, from: Int = 0, end: Int? = nil) -> Int? {
        let end = end ?? hay.count
        guard from < end else { return nil }
        return hay.withUnsafeBufferPointer { buf -> Int? in
            guard let hit = memchr(buf.baseAddress! + from, Int32(needle), end - from) else { return nil }
            return UnsafeRawPointer(buf.baseAddress!).distance(to: UnsafeRawPointer(hit))
        }
    }

    /// The index of the first "\r\n" at or after `from`.
    @inline(__always) static func findCRLF(_ hay: Span<UInt8>, from: Int = 0) -> Int? {
        guard hay.count >= 2 else { return nil }
        let last = hay.count - 1
        var pos = from
        while pos < last {
            guard let idx = find(hay, 0x0D, from: pos, end: last) else { return nil }
            if hay[idx + 1] == 0x0A { return idx }
            pos = idx + 1
        }
        return nil
    }

    /// Whether `bytes` is valid UTF-8, by the standard library's validator.
    @inline(__always) static func isValidUTF8(_ bytes: Span<UInt8>) -> Bool {
        (try? UTF8Span(validating: bytes)) != nil
    }

    /// An owned copy of `bytes`, for bytes that outlive the request.
    static func array(_ bytes: Span<UInt8>) -> [UInt8] {
        [UInt8](unsafeUninitializedCapacity: bytes.count) { out, n in
            bytes.withUnsafeBytes { UnsafeMutableRawBufferPointer(out).copyMemory(from: $0) }
            n = bytes.count
        }
    }

    /// A String copy of `bytes`, nil unless they are valid UTF-8.
    static func copyString(_ bytes: Span<UInt8>) -> String? {
        guard let utf8 = try? UTF8Span(validating: bytes) else { return nil }
        return String(copying: utf8)
    }

    /// memcmp of `n` bytes, where a pointer may be nil only if `n` is 0.
    @inline(__always) static func compare(_ a: UnsafeRawPointer?, _ b: UnsafeRawPointer?, _ n: Int) -> Int32 {
        n == 0 ? 0 : memcmp(a!, b!, n)
    }

    @inline(__always) static func equal(_ a: borrowing [UInt8], _ b: StaticString) -> Bool {
        a.count == b.utf8CodeUnitCount && a.withUnsafeBytes { compare($0.baseAddress, b.utf8Start, a.count) == 0 }
    }

    @inline(__always) static func equal(_ a: Span<UInt8>, _ b: StaticString) -> Bool {
        a.count == b.utf8CodeUnitCount && a.withUnsafeBytes { compare($0.baseAddress, b.utf8Start, a.count) == 0 }
    }
}

// ---------- JSON output ----------

/// The JSON writer, and (below) the parser for request bodies and JWT claims.
nonisolated enum JSON {
    private static let maskLo: UInt64 = 0x0101_0101_0101_0101
    private static let maskHi: UInt64 = 0x8080_8080_8080_8080

    /// Whether any of 8 bytes is a control character, a quote or a backslash (SWAR).
    @inline(__always) private static func hasSpecial8(_ word: UInt64) -> Bool {
        let q = word ^ (maskLo &* 0x22)
        let bs = word ^ (maskLo &* 0x5C)
        let ctrl = (word &- maskLo &* 0x20) | ((q &- maskLo) & ~q) | ((bs &- maskLo) & ~bs)
        return (ctrl & ~word & maskHi) != 0
    }

    /// Whether 16 bytes need no escaping (portable SIMD).
    @inline(__always) private static func chunk16Clean(_ raw: RawSpan, _ at: Int) -> Bool {
        let v = raw.load(fromByteOffset: at, as: SIMD16<UInt8>.self)
        let special = (v .== SIMD16(repeating: 0x22)) .| (v .== SIMD16(repeating: 0x5C)) .| (v .< SIMD16(repeating: 0x20))
        return !any(special)
    }

    private static let hexDigits: StaticString = "0123456789abcdef"

    /// `src` as a JSON string, quotes included.
    static func writeString(_ dst: inout ByteBuffer, _ src: Span<UInt8>) {
        let raw = src.bytes
        let n = src.count
        dst.append(0x22)
        var pos = 0
        while pos + 16 <= n, chunk16Clean(raw, pos) { pos += 16 }
        while pos + 8 <= n, !hasSpecial8(raw.load(fromByteOffset: pos, as: UInt64.self, .littleEndian)) {
            pos += 8
        }
        while pos < n {
            let c = src[pos]
            if c < 0x20 || c == 0x22 || c == 0x5C { break }
            pos += 1
        }
        if pos == n {
            dst.append(src)
            dst.append(0x22)
            return
        }
        dst.append(src.extracting(0..<pos))
        var anchor = pos
        var idx = pos
        while idx < n {
            if idx + 16 <= n, chunk16Clean(raw, idx) {
                idx += 16
                continue
            }
            let c = src[idx]
            let escape: StaticString
            switch c {
            case 0x22: escape = "\\\""
            case 0x5C: escape = "\\\\"
            case 0x0A: escape = "\\n"
            case 0x0D: escape = "\\r"
            case 0x09: escape = "\\t"
            case 0x00...0x1F: escape = ""
            default:
                idx += 1
                continue
            }
            dst.append(src.extracting(anchor..<idx))
            if escape.utf8CodeUnitCount == 0 {
                dst.append("\\u00")
                dst.append(hexDigits.utf8Start[Int(c >> 4)])
                dst.append(hexDigits.utf8Start[Int(c & 0x0F)])
            } else {
                dst.append(escape)
            }
            anchor = idx + 1
            idx += 1
        }
        dst.append(src.extracting(anchor..<n))
        dst.append(0x22)
    }

    @inline(__always) static func writeString(_ dst: inout ByteBuffer, _ src: borrowing [UInt8]) {
        writeString(&dst, src.span)
    }

    @inline(__always) static func writeString(_ dst: inout ByteBuffer, _ literal: StaticString) {
        writeString(&dst, Span(_unsafeElements: UnsafeBufferPointer(start: literal.utf8Start, count: literal.utf8CodeUnitCount)))
    }

    /// SPEC.md's error body, `{"error":"<message>"}`.
    static func writeError(_ dst: inout ByteBuffer, _ message: StaticString) {
        dst.append("{\"error\":")
        writeString(&dst, message)
        dst.append("}")
    }

    private static let decDigits: StaticString = """
        00010203040506070809101112131415161718192021222324252627282930313233343536373839\
        40414243444546474849505152535455565758596061626364656667686970717273747576777879\
        8081828384858687888990919293949596979899
        """

    /// The decimal digits of `n`, two digits per step.
    @inline(__always) static func writeUInt(_ dst: inout ByteBuffer, _ value: UInt64) {
        var digits = InlineArray<20, UInt8>(repeating: 0)
        var pos = 20
        var n = value
        let lut = decDigits.utf8Start
        while n >= 100 {
            let rem = Int((n % 100) * 2)
            n /= 100
            pos -= 2
            digits[pos] = lut[rem]
            digits[pos + 1] = lut[rem + 1]
        }
        if n < 10 {
            pos -= 1
            digits[pos] = 0x30 + UInt8(n)
        } else {
            let rem = Int(n * 2)
            pos -= 2
            digits[pos] = lut[rem]
            digits[pos + 1] = lut[rem + 1]
        }
        dst.append(digits.span.extracting(pos..<20))
    }

    @inline(__always) static func writeInt(_ dst: inout ByteBuffer, _ value: Int64) {
        if value < 0 { dst.append(0x2D) }
        writeUInt(&dst, value.magnitude)
    }

    @inline(__always) private static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }

    @inline(__always) private static func floorMod(_ a: Int64, _ b: Int64) -> Int64 {
        let r = a % b
        return r < 0 ? r + b : r
    }

    private static func ymdFromUnixDays(_ days: Int64) -> (year: Int64, month: UInt32, day: UInt32) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = UInt64(z - era * 146_097)
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let y = Int64(yoe) + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = UInt32(doy - (153 * mp + 2) / 5 + 1)
        let m = UInt32(mp < 10 ? mp + 3 : mp - 9)
        return (m <= 2 ? y + 1 : y, m, d)
    }

    /// A Postgres binary timestamptz (microseconds since 2000-01-01 UTC) as a quoted RFC 3339 string with milliseconds.
    static func writeTimestamp(_ dst: inout ByteBuffer, _ pgMicros: Int64) {
        let totalUs = pgMicros + 946_684_800_000_000
        let totalMs = floorDiv(totalUs, 1000)
        let totalSec = floorDiv(totalMs, 1000)
        let millis = UInt32(floorMod(totalMs, 1000))
        let days = floorDiv(totalSec, 86_400)
        let daySec = UInt32(floorMod(totalSec, 86_400))
        let (year, month, day) = ymdFromUnixDays(days)
        let y = UInt32(truncatingIfNeeded: year)
        let hh = daySec / 3600, mm = (daySec / 60) % 60, ss = daySec % 60
        @inline(__always) func digit(_ v: UInt32) -> UInt8 { 0x30 + UInt8(v % 10) }
        let out: InlineArray<26, UInt8> = [
            0x22, digit(y / 1000), digit(y / 100), digit(y / 10), digit(y), 0x2D,
            digit(month / 10), digit(month), 0x2D, digit(day / 10), digit(day), 0x54,
            digit(hh / 10), digit(hh), 0x3A, digit(mm / 10), digit(mm), 0x3A, digit(ss / 10), digit(ss), 0x2E,
            digit(millis / 100), digit(millis / 10), digit(millis), 0x5A, 0x22,
        ]
        dst.append(out.span)
    }
}

// ---------- base64 ----------

/// URL-safe base64 (JWT).
nonisolated enum Base64 {

    /// A base64url character's value, 0xFF if it isn't one.
    @inline(__always) private static func urlValue(_ c: UInt8) -> UInt8 {
        switch c {
        case 0x41...0x5A: c - 0x41
        case 0x61...0x7A: c - 0x61 + 26
        case 0x30...0x39: c - 0x30 + 52
        case 0x2D: 62
        case 0x5F: 63
        default: 0xFF
        }
    }

    /// base64url without padding, appended.
    /// Decodes unpadded base64url into `dst`; the byte count, or nil if `src` isn't base64url or `dst` is too small.
    static func urlDecode(_ src: Span<UInt8>, into dst: inout MutableSpan<UInt8>) -> Int? {
        if src.count % 4 == 1 { return nil }
        let needed = (src.count / 4) * 3 + (src.count % 4 == 2 ? 1 : src.count % 4 == 3 ? 2 : 0)
        if dst.count < needed { return nil }
        var si = 0
        var di = 0
        while si + 4 <= src.count {
            let a = urlValue(src[si]), b = urlValue(src[si + 1]), c = urlValue(src[si + 2]), d = urlValue(src[si + 3])
            if (a | b | c | d) & 0x80 != 0 { return nil }
            let n = UInt32(a) << 18 | UInt32(b) << 12 | UInt32(c) << 6 | UInt32(d)
            dst[di] = UInt8(truncatingIfNeeded: n >> 16)
            dst[di + 1] = UInt8(truncatingIfNeeded: n >> 8)
            dst[di + 2] = UInt8(truncatingIfNeeded: n)
            si += 4
            di += 3
        }
        let rem = src.count - si
        if rem == 2 {
            let a = urlValue(src[si]), b = urlValue(src[si + 1])
            if (a | b) & 0x80 != 0 || b & 0x0F != 0 { return nil }
            dst[di] = a << 2 | b >> 4
            di += 1
        } else if rem == 3 {
            let a = urlValue(src[si]), b = urlValue(src[si + 1]), c = urlValue(src[si + 2])
            if (a | b | c) & 0x80 != 0 || c & 0x03 != 0 { return nil }
            let n = UInt32(a) << 18 | UInt32(b) << 12 | UInt32(c) << 6
            dst[di] = UInt8(truncatingIfNeeded: n >> 16)
            dst[di + 1] = UInt8(truncatingIfNeeded: n >> 8)
            di += 2
        }
        return di
    }

    /// Padded standard base64 (SCRAM).
    /// A payload too long for a stack buffer, decoded onto the heap.
    static func urlDecodeArray(_ src: Span<UInt8>) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: src.count * 3 / 4 + 3)
        var span = out.mutableSpan
        guard let n = urlDecode(src, into: &span) else { return nil }
        out.removeLast(out.count - n)
        return out
    }

}

// ---------- JSON input ----------

nonisolated extension JSON {
    /// What a value is.
    enum Kind {
        case string
        case number
        case object
        case array
        case `true`
        case `false`
        case null
    }

    /// A member of an object, as places in the document: its key's text and, for a string value, its text (both
    /// without the quotes), or the whole value otherwise. A string with escapes is decoded when it is read.
    struct Member {
        private let keyStart: UInt32
        private let keyEnd: UInt32
        private let valueStart: UInt32
        private let valueEnd: UInt32
        let kind: Kind
        let keyEscaped: Bool
        let valueEscaped: Bool

        init(key: Range<Int>, keyEscaped: Bool, value: Range<Int>, kind: Kind, valueEscaped: Bool) {
            keyStart = UInt32(truncatingIfNeeded: key.lowerBound)
            keyEnd = UInt32(truncatingIfNeeded: key.upperBound)
            valueStart = UInt32(truncatingIfNeeded: value.lowerBound)
            valueEnd = UInt32(truncatingIfNeeded: value.upperBound)
            self.kind = kind
            self.keyEscaped = keyEscaped
            self.valueEscaped = valueEscaped
        }

        @inline(__always) var key: Range<Int> { Int(keyStart)..<Int(keyEnd) }
        @inline(__always) var value: Range<Int> { Int(valueStart)..<Int(valueEnd) }

        static let none = Member(key: 0..<0, keyEscaped: false, value: 0..<0, kind: .null, valueEscaped: false)
    }

    /// What `scan` found: whether the document is an object, the last member of its top-level object named by each
    /// key asked for (by the key's position), and whether some string in it decodes to one with a NUL (`\u0000`).
    struct Found<let n: Int> {
        fileprivate var members = InlineArray<n, Member>(repeating: .none)
        fileprivate var present: UInt64 = 0
        fileprivate(set) var isObject = false
        fileprivate(set) var hasNul = false

        /// The member named by the `i`th key, if the object has one.
        @inline(__always) subscript(i: Int) -> Member? { present & (1 << UInt64(i)) != 0 ? members[i] : nil }
    }

    /// Checks that `src` is one JSON value (RFC 8259: strings valid UTF-8, nesting at most 64 deep) and, when it is an
    /// object, finds its members named by `keys` (a later duplicate wins, as in JavaScript's JSON.parse). Builds and
    /// keeps nothing else: nil if the document isn't valid.
    static func scan<let n: Int>(_ src: Span<UInt8>, keys: InlineArray<n, StaticString>) -> Found<n>? {
        var scanner = Scanner(src)
        var found = Found<n>()
        scanner.skipWhitespace()
        if scanner.pos < src.count && src[scanner.pos] == 0x7B {
            found.isObject = true
            guard scanner.object(depth: 1, keys: keys, found: &found) else { return nil }
        } else {
            guard scanner.value(depth: 0) != nil else { return nil }
        }
        scanner.skipWhitespace()
        found.hasNul = scanner.sawNul
        return scanner.pos == src.count ? found : nil
    }

    /// Calls `body` with a string member's text: in place, or decoded when it has escapes.
    static func withString<R>(_ src: Span<UInt8>, _ member: Member, _ body: (Span<UInt8>) -> R) -> R {
        if !member.valueEscaped { return body(src.extracting(member.value)) }
        let decoded = unescape(src.extracting(member.value))
        return body(decoded.span)
    }

    /// A number member's value.
    static func number(_ src: Span<UInt8>, _ member: Member) -> Double? {
        let text = src.extracting(member.value)
        // Integers, the usual case, without going through text.
        var value: Int64 = 0
        var i = text.count > 0 && text[0] == 0x2D ? 1 : 0
        let negative = i == 1
        while i < text.count, (0x30...0x39).contains(text[i]) {
            let (m, o1) = value.multipliedReportingOverflow(by: 10)
            let (v, o2) = m.addingReportingOverflow(Int64(text[i] - 0x30))
            if o1 || o2 { break }
            value = v
            i += 1
        }
        if i == text.count { return Double(negative ? -value : value) }
        guard let string = Bytes.copyString(text), let double = Double(string), double.isFinite else { return nil }
        return double
    }

    /// Whether a member's key is `key`: lengths and first bytes first, which rule out nearly every other key cheaply.
    @inline(__always) fileprivate static func keyMatches(_ text: Span<UInt8>, escaped: Bool, _ key: StaticString) -> Bool {
        if escaped { return Bytes.equal(unescape(text).span, key) }
        let n = key.utf8CodeUnitCount
        guard text.count == n else { return false }
        if n == 0 { return true }
        let k = key.utf8Start
        guard text[0] == k[0] else { return false }
        for i in 1..<n where text[i] != k[i] { return false }
        return true
    }

    /// A checked string's text with its escapes decoded.
    static func unescape(_ text: Span<UInt8>) -> ByteBuffer {
        var out = ByteBuffer(capacity: text.count)
        var i = 0
        while i < text.count {
            let c = text[i]
            if c != 0x5C {
                out.append(c)
                i += 1
                continue
            }
            let e = text[i + 1]
            i += 2
            switch e {
            case 0x62: out.append(0x08)
            case 0x66: out.append(0x0C)
            case 0x6E: out.append(0x0A)
            case 0x72: out.append(0x0D)
            case 0x74: out.append(0x09)
            case 0x75:
                var code = UInt32(hex4(text, i))
                i += 4
                if (0xD800...0xDBFF).contains(code) {
                    code = 0x10000 + ((code - 0xD800) << 10) + (UInt32(hex4(text, i + 2)) - 0xDC00)
                    i += 6
                }
                for byte in UTF8.encode(Unicode.Scalar(code)!)! { out.append(byte) }
            default: out.append(e)
            }
        }
        return out
    }

    @inline(__always) fileprivate static func hexValue(_ b: UInt8) -> UInt16? {
        switch b {
        case 0x30...0x39: UInt16(b - 0x30)
        case 0x61...0x66: UInt16(b - 0x61 + 10)
        case 0x41...0x46: UInt16(b - 0x41 + 10)
        default: nil
        }
    }

    /// Four hex digits at `at` (already checked).
    @inline(__always) private static func hex4(_ text: Span<UInt8>, _ at: Int) -> UInt16 {
        var value: UInt16 = 0
        for k in 0..<4 { value = value << 4 | hexValue(text[at + k])! }
        return value
    }

    /// The validating pass over a borrowed document: it can't outlive the bytes it reads.
    private struct Scanner: ~Escapable {
        let src: Span<UInt8>
        var pos = 0
        var sawNul = false

        @_lifetime(copy src)
        init(_ src: Span<UInt8>) {
            self.src = src
        }

        @inline(__always) mutating func skipWhitespace() {
            while pos < src.count {
                switch src[pos] {
                case 0x20, 0x09, 0x0D, 0x0A: pos += 1
                default: return
                }
            }
        }

        private mutating func literal(_ text: StaticString) -> Bool {
            let n = text.utf8CodeUnitCount
            guard pos + n <= src.count, Bytes.equal(src.extracting(pos..<(pos + n)), text) else { return false }
            pos += n
            return true
        }

        /// The value at `pos`, passed over: its kind and, for a string, whether it has escapes; nil if invalid.
        mutating func value(depth: Int) -> (kind: Kind, escaped: Bool)? {
            guard depth <= 64, pos < src.count else { return nil }
            switch src[pos] {
            case 0x22:
                guard let escaped = string() else { return nil }
                return (.string, escaped)
            case 0x7B:
                var none = Found<0>()
                return object(depth: depth + 1, keys: [], found: &none) ? (.object, false) : nil
            case 0x5B:
                return array(depth: depth + 1) ? (.array, false) : nil
            case 0x74: return literal("true") ? (.true, false) : nil
            case 0x66: return literal("false") ? (.false, false) : nil
            case 0x6E: return literal("null") ? (.null, false) : nil
            case 0x2D, 0x30...0x39: return number() ? (.number, false) : nil
            default: return nil
            }
        }

        /// The string whose opening quote is at `pos`, passed over: whether it has escapes; nil if invalid.
        mutating func string() -> Bool? {
            pos += 1
            let start = pos
            var escaped = false
            var ascii = true
            while pos < src.count {
                let c = src[pos]
                if c == 0x22 {
                    // Escapes are ASCII, so the text with them is valid UTF-8 exactly when its other bytes are; all-ASCII
                    // text needs no further check.
                    guard ascii || Bytes.isValidUTF8(src.extracting(start..<pos)) else { return nil }
                    pos += 1
                    return escaped
                }
                if c >= 0x80 { ascii = false }
                if c < 0x20 { return nil }
                if c == 0x5C {
                    escaped = true
                    guard pos + 1 < src.count else { return nil }
                    switch src[pos + 1] {
                    case 0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74:
                        pos += 2
                    case 0x75:
                        guard let unit = hex4(at: pos + 2) else { return nil }
                        if unit == 0 { sawNul = true }
                        pos += 6
                        if (0xDC00...0xDFFF).contains(unit) { return nil }
                        if (0xD800...0xDBFF).contains(unit) {
                            guard pos + 1 < src.count, src[pos] == 0x5C, src[pos + 1] == 0x75,
                                  let low = hex4(at: pos + 2), (0xDC00...0xDFFF).contains(low) else { return nil }
                            pos += 6
                        }
                    default:
                        return nil
                    }
                    continue
                }
                pos += 1
            }
            return nil
        }

        private func hex4(at: Int) -> UInt16? {
            guard at + 4 <= src.count else { return nil }
            var value: UInt16 = 0
            for k in 0..<4 {
                guard let d = JSON.hexValue(src[at + k]) else { return nil }
                value = value << 4 | d
            }
            return value
        }

        private mutating func digits() -> Bool {
            let start = pos
            while pos < src.count, (0x30...0x39).contains(src[pos]) { pos += 1 }
            return pos > start
        }

        mutating func number() -> Bool {
            if src[pos] == 0x2D { pos += 1 }
            guard pos < src.count else { return false }
            if src[pos] == 0x30 {
                pos += 1
            } else if !digits() {
                return false
            }
            if pos < src.count && src[pos] == 0x2E {
                pos += 1
                guard digits() else { return false }
            }
            if pos < src.count && (src[pos] == 0x65 || src[pos] == 0x45) {
                pos += 1
                if pos < src.count && (src[pos] == 0x2B || src[pos] == 0x2D) { pos += 1 }
                guard digits() else { return false }
            }
            return true
        }

        /// The object whose brace is at `pos`, passed over; its members named by `keys` noted in `found`.
        mutating func object<let n: Int>(depth: Int, keys: InlineArray<n, StaticString>, found: inout Found<n>) -> Bool {
            pos += 1
            skipWhitespace()
            if pos < src.count && src[pos] == 0x7D {
                pos += 1
                return true
            }
            while true {
                skipWhitespace()
                guard pos < src.count, src[pos] == 0x22 else { return false }
                let keyStart = pos + 1
                guard let keyEscaped = string() else { return false }
                let key = keyStart..<(pos - 1)
                skipWhitespace()
                guard pos < src.count, src[pos] == 0x3A else { return false }
                pos += 1
                skipWhitespace()
                let valueStart = pos
                guard let (kind, valueEscaped) = value(depth: depth) else { return false }
                for k in 0..<n where JSON.keyMatches(src.extracting(key), escaped: keyEscaped, keys[k]) {
                    let range = kind == .string ? (valueStart + 1)..<(pos - 1) : valueStart..<pos
                    found.members[k] = Member(key: key, keyEscaped: keyEscaped, value: range, kind: kind, valueEscaped: valueEscaped)
                    found.present |= 1 << UInt64(k)
                }
                skipWhitespace()
                guard pos < src.count else { return false }
                if src[pos] == 0x2C {
                    pos += 1
                } else if src[pos] == 0x7D {
                    pos += 1
                    return true
                } else {
                    return false
                }
            }
        }

        mutating func array(depth: Int) -> Bool {
            pos += 1
            skipWhitespace()
            if pos < src.count && src[pos] == 0x5D {
                pos += 1
                return true
            }
            while true {
                skipWhitespace()
                guard value(depth: depth) != nil else { return false }
                skipWhitespace()
                guard pos < src.count else { return false }
                if src[pos] == 0x2C {
                    pos += 1
                } else if src[pos] == 0x5D {
                    pos += 1
                    return true
                } else {
                    return false
                }
            }
        }
    }
}
