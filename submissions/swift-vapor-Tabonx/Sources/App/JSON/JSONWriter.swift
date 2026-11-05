/// Writes compact JSON with object keys in the order they are written.
///
/// Foundation's `JSONEncoder` keeps keyed containers in a dictionary, so on Linux it emits keys in
/// hash order, and the spec requires an exact order. Responses go through this writer instead.
struct JSONWriter {
    private(set) var bytes: [UInt8] = []
    private var needsComma = false

    init() {
        bytes.reserveCapacity(1024)
    }

    static func encode(_ value: some JSONEncodable) -> [UInt8] {
        var writer = JSONWriter()
        value.encode(to: &writer)
        return writer.bytes
    }

    /// Writes `{...}`. Call `field(_:_:)` inside `fields` for each key, in order.
    mutating func object(_ fields: (inout JSONWriter) -> Void) {
        beginValue()
        bytes.append(UInt8(ascii: "{"))
        needsComma = false
        fields(&self)
        bytes.append(UInt8(ascii: "}"))
        needsComma = true
    }

    mutating func array(_ elements: some Sequence<some JSONEncodable>) {
        beginValue()
        bytes.append(UInt8(ascii: "["))
        needsComma = false
        for element in elements {
            element.encode(to: &self)
        }
        bytes.append(UInt8(ascii: "]"))
        needsComma = true
    }

    mutating func field(_ key: String, _ value: some JSONEncodable) {
        string(key)
        bytes.append(UInt8(ascii: ":"))
        needsComma = false
        value.encode(to: &self)
    }

    mutating func string(_ value: String) {
        beginValue()
        bytes.append(UInt8(ascii: "\""))
        var value = value
        value.withUTF8 { utf8 in
            // Most strings need no escaping, so clean runs are copied whole instead of byte by byte.
            var runStart = 0
            for index in 0..<utf8.count {
                let byte = utf8[index]
                guard byte < 0x20 || byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "\\") else { continue }
                bytes.append(contentsOf: UnsafeBufferPointer(rebasing: utf8[runStart..<index]))
                appendEscaped(byte)
                runStart = index + 1
            }
            bytes.append(contentsOf: UnsafeBufferPointer(rebasing: utf8[runStart...]))
        }
        bytes.append(UInt8(ascii: "\""))
        needsComma = true
    }

    private mutating func appendEscaped(_ byte: UInt8) {
        switch byte {
        case UInt8(ascii: "\""): bytes.append(contentsOf: #"\""#.utf8)
        case UInt8(ascii: "\\"): bytes.append(contentsOf: #"\\"#.utf8)
        case UInt8(ascii: "\n"): bytes.append(contentsOf: #"\n"#.utf8)
        case UInt8(ascii: "\r"): bytes.append(contentsOf: #"\r"#.utf8)
        case UInt8(ascii: "\t"): bytes.append(contentsOf: #"\t"#.utf8)
        default:
            let hex = Array("0123456789abcdef".utf8)
            bytes.append(contentsOf: #"\u00"#.utf8)
            bytes.append(hex[Int(byte >> 4)])
            bytes.append(hex[Int(byte & 0x0F)])
        }
    }

    mutating func literal(_ text: String) {
        beginValue()
        bytes.append(contentsOf: text.utf8)
        needsComma = true
    }

    private mutating func beginValue() {
        if needsComma {
            bytes.append(UInt8(ascii: ","))
        }
    }
}

/// A value that can write itself as JSON.
protocol JSONEncodable {
    func encode(to json: inout JSONWriter)
}

extension String: JSONEncodable {
    func encode(to json: inout JSONWriter) { json.string(self) }
}

extension Int: JSONEncodable {
    func encode(to json: inout JSONWriter) { json.literal(String(self)) }
}

extension Int64: JSONEncodable {
    func encode(to json: inout JSONWriter) { json.literal(String(self)) }
}

extension Bool: JSONEncodable {
    func encode(to json: inout JSONWriter) { json.literal(self ? "true" : "false") }
}

extension Array: JSONEncodable where Element: JSONEncodable {
    func encode(to json: inout JSONWriter) { json.array(self) }
}
