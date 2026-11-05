// HTTP/1.1: the response head, and request parsing in place, straight out of the bytes a receive delivered.

/// HTTP/1.1: the response head, and (below) request parsing.
nonisolated enum HTTP {
    private static let limitHead = 64 * 1024
    private static let limitBody = 1024 * 1024

    private static func reasonPhrase(_ status: UInt16) -> StaticString {
        switch status {
        case 100: "100 Continue"
        case 200: "200 OK"
        case 201: "201 Created"
        case 400: "400 Bad Request"
        case 401: "401 Unauthorized"
        case 404: "404 Not Found"
        case 413: "413 Payload Too Large"
        case 431: "431 Request Header Fields Too Large"
        case 503: "503 Service Unavailable"
        default: "500 Internal Server Error"
        }
    }

    /// The error message of a request rejected before routing.
    static func errorMessage(_ status: UInt16) -> StaticString {
        switch status {
        case 413: "payload too large"
        case 431: "request header fields too large"
        default: "bad request"
        }
    }

    /// The response head (status line, Content-Type, Content-Length, Connection) into `out`; returns its length.
    static func formatHeader(into out: inout MutableSpan<UInt8>, _ status: UInt16, _ length: Int, _ close: Bool) -> Int {
        var n = 0
        if status == 200 && !close {
            n = put(&out, n, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ")
            n = putDecimal(&out, n, length)
            n = put(&out, n, "\r\n\r\n")
        } else {
            n = put(&out, n, "HTTP/1.1 ")
            n = put(&out, n, reasonPhrase(status))
            n = put(&out, n, "\r\nContent-Type: application/json\r\nContent-Length: ")
            n = putDecimal(&out, n, length)
            n = put(&out, n, close ? "\r\nConnection: close\r\n\r\n" : "\r\n\r\n")
        }
        return n
    }

    @inline(__always) private static func put(_ out: inout MutableSpan<UInt8>, _ at: Int, _ text: StaticString) -> Int {
        let bytes = text.utf8Start
        for i in 0..<text.utf8CodeUnitCount { out[at + i] = bytes[i] }
        return at + text.utf8CodeUnitCount
    }

    @inline(__always) private static func putDecimal(_ out: inout MutableSpan<UInt8>, _ at: Int, _ value: Int) -> Int {
        var digits = 1
        var v = value
        while v >= 10 {
            v /= 10
            digits += 1
        }
        v = value
        for i in stride(from: at + digits - 1, through: at, by: -1) {
            out[i] = 0x30 + UInt8(v % 10)
            v /= 10
        }
        return at + digits
    }

    enum ParseOutcome: ~Copyable {
        case complete(consumed: Int, closeAfter: Bool, dispatch: Router.Dispatch)
        case incomplete(sendContinue: Bool)
        case reject(UInt16)
    }
}

// ---------- HTTP/1.1 parsing ----------

nonisolated extension HTTP {
    @inline(__always) private static func trimOWS(_ s: Span<UInt8>) -> Span<UInt8> {
        var a = 0
        var b = s.count
        while a < b && (s[a] == 0x20 || s[a] == 0x09) { a += 1 }
        while b > a && (s[b - 1] == 0x20 || s[b - 1] == 0x09) { b -= 1 }
        return s.extracting(a..<b)
    }

    @inline(__always) private static func parseUsize(_ s: Span<UInt8>) -> Int? {
        guard s.count > 0 else { return nil }
        var value = 0
        for i in 0..<s.count {
            let b = s[i]
            guard (0x30...0x39).contains(b) else { return nil }
            let (m, o1) = value.multipliedReportingOverflow(by: 10)
            let (v, o2) = m.addingReportingOverflow(Int(b - 0x30))
            if o1 || o2 { return nil }
            value = v
        }
        return value
    }

    @inline(__always) private static func isTokenName(_ s: Span<UInt8>) -> Bool {
        guard s.count > 0 else { return false }
        for i in 0..<s.count {
            let b = s[i]
            if b <= 0x20 || b >= 0x7F { return false }
            switch b {
            case 0x28, 0x29, 0x3C, 0x3E, 0x40, 0x2C, 0x3B, 0x3A, 0x5C, 0x22, 0x2F, 0x5B, 0x5D, 0x3F, 0x3D, 0x7B, 0x7D: return false
            default: continue
            }
        }
        return true
    }

    @inline(__always) private static func equalsIgnoringCase(_ s: Span<UInt8>, _ lower: StaticString) -> Bool {
        guard s.count == lower.utf8CodeUnitCount else { return false }
        let l = lower.utf8Start
        for i in 0..<s.count {
            var c = s[i]
            if (0x41...0x5A).contains(c) { c |= 0x20 }
            if c != l[i] { return false }
        }
        return true
    }

    static func parseRequest(_ signer: TokenSigner, _ buf: Span<UInt8>) -> ParseOutcome {
        guard let reqLineEnd = Bytes.findCRLF(buf) else {
            return buf.count > limitHead ? .reject(431) : .incomplete(sendContinue: false)
        }
        let reqLine = buf.extracting(0..<reqLineEnd)
        guard let sp1 = Bytes.find(reqLine, 0x20) else { return .reject(400) }
        let method = reqLine.extracting(0..<sp1)
        guard isTokenName(method) else { return .reject(400) }
        guard let sp2 = Bytes.find(reqLine, 0x20, from: sp1 + 1) else { return .reject(400) }
        let rawTarget = reqLine.extracting((sp1 + 1)..<sp2)
        guard rawTarget.count > 0 else { return .reject(400) }
        for i in 0..<rawTarget.count where rawTarget[i] <= 0x20 || rawTarget[i] == 0x7F { return .reject(400) }
        let version = reqLine.extracting((sp2 + 1)..<reqLine.count)
        let isHTTP10: Bool
        if Bytes.equal(version, "HTTP/1.1") {
            isHTTP10 = false
        } else if Bytes.equal(version, "HTTP/1.0") {
            isHTTP10 = true
        } else {
            return .reject(400)
        }

        var contentLength: Int?
        var isChunked = false
        var authRange: Range<Int>?
        var keepAlive = !isHTTP10
        var expect100 = false

        var pos = reqLineEnd + 2
        var headEnd = 0
        while true {
            guard let lineEnd = Bytes.findCRLF(buf, from: pos) else {
                return buf.count > limitHead ? .reject(431) : .incomplete(sendContinue: false)
            }
            if lineEnd + 2 > limitHead { return .reject(431) }
            if lineEnd == pos {
                headEnd = pos + 2
                break
            }
            let line = buf.extracting(pos..<lineEnd)
            let lineStart = pos
            pos = lineEnd + 2
            guard let colon = Bytes.find(line, 0x3A) else { return .reject(400) }
            let name = line.extracting(0..<colon)
            guard isTokenName(name) else { return .reject(400) }
            let value = trimOWS(line.extracting((colon + 1)..<line.count))
            switch name.count {
            case 13 where equalsIgnoringCase(name, "authorization"):
                // The value's place in `buf` (after the leading whitespace trimOWS skipped), so the request borrows it.
                var a = colon + 1
                while a < line.count && (line[a] == 0x20 || line[a] == 0x09) { a += 1 }
                let valueStart = lineStart + a
                authRange = valueStart..<(valueStart + value.count)
            case 14 where equalsIgnoringCase(name, "content-length"):
                guard let n = parseUsize(value) else { return .reject(400) }
                if let prev = contentLength, prev != n { return .reject(400) }
                contentLength = n
            case 10 where equalsIgnoringCase(name, "connection"):
                if equalsIgnoringCase(value, "close") {
                    keepAlive = false
                } else if equalsIgnoringCase(value, "keep-alive") {
                    keepAlive = true
                }
            case 17 where equalsIgnoringCase(name, "transfer-encoding"):
                isChunked = equalsIgnoringCase(value, "chunked")
                if !isChunked { return .reject(400) }
            case 6 where equalsIgnoringCase(name, "expect"):
                expect100 = equalsIgnoringCase(value, "100-continue")
            default:
                break
            }
        }

        if isChunked && contentLength != nil { return .reject(400) }

        let path = rawTarget.extracting(0..<(Bytes.find(rawTarget, 0x3F) ?? rawTarget.count))
        var auth: Span<UInt8>? = nil
        if let authRange { auth = buf.extracting(authRange) }

        if isChunked {
            switch decodeChunkedBody(buf.extracting(headEnd..<buf.count)) {
            case .complete(let decoded, let used):
                if decoded.count > limitBody { return .reject(413) }
                let req = Request(method: method, path: path, auth: auth, body: decoded.span)
                let dispatch = Router.route(signer, req)
                return .complete(consumed: headEnd + used, closeAfter: !keepAlive, dispatch: dispatch)
            case .incomplete:
                if buf.count - headEnd > limitBody + 64 * 1024 { return .reject(413) }
                return .incomplete(sendContinue: expect100)
            case .malformed:
                return .reject(400)
            }
        }
        let cl = contentLength ?? 0
        if cl > limitBody { return .reject(413) }
        if buf.count < headEnd + cl { return .incomplete(sendContinue: expect100) }
        let req = Request(method: method, path: path, auth: auth, body: buf.extracting(headEnd..<(headEnd + cl)))
        let dispatch = Router.route(signer, req)
        return .complete(consumed: headEnd + cl, closeAfter: !keepAlive, dispatch: dispatch)
    }

    private enum ChunkResult {
        case complete([UInt8], Int)
        case incomplete
        case malformed
    }

    private static func decodeChunkedBody(_ src: Span<UInt8>) -> ChunkResult {
        var out: [UInt8] = []
        var pos = 0
        while true {
            guard let crlf = Bytes.findCRLF(src, from: pos) else { return .incomplete }
            let line = src.extracting(pos..<crlf)
            let hexPart = trimOWS(line.extracting(0..<(Bytes.find(line, 0x3B) ?? line.count)))
            guard hexPart.count > 0, hexPart.count <= 8 else { return .malformed }
            var chunkLen = 0
            for i in 0..<hexPart.count {
                let b = hexPart[i]
                let d: Int
                switch b {
                case 0x30...0x39: d = Int(b - 0x30)
                case 0x61...0x66: d = Int(b - 0x61 + 10)
                case 0x41...0x46: d = Int(b - 0x41 + 10)
                default: return .malformed
                }
                chunkLen = chunkLen << 4 | d
            }
            pos = crlf + 2
            if chunkLen == 0 {
                while true {
                    guard let endLine = Bytes.findCRLF(src, from: pos) else { return .incomplete }
                    let empty = endLine == pos
                    pos = endLine + 2
                    if empty { return .complete(out, pos) }
                }
            }
            if chunkLen > limitBody || out.count + chunkLen > limitBody {
                return .complete([UInt8](repeating: 0, count: limitBody + 1), pos)
            }
            if src.count < pos + chunkLen + 2 { return .incomplete }
            src.extracting(pos..<(pos + chunkLen)).withUnsafeBufferPointer { out.append(contentsOf: $0) }
            if src[pos + chunkLen] != 0x0D || src[pos + chunkLen + 1] != 0x0A { return .malformed }
            pos += chunkLen + 2
        }
    }
}
