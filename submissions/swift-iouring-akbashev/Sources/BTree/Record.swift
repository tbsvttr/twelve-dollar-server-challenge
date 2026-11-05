/// SQLite's record format: a header (its own length, then a serial type per column, as varints), then the values in
/// column order.
public enum Record {
    /// A column of a record: its serial type, and where its value lies.
    public struct Column {
        public var type: UInt64
        public var range: Range<Int>

        @inlinable init(type: UInt64 = 0, range: Range<Int> = 0..<0) {
            self.type = type
            self.range = range
        }

        @inlinable public var isText: Bool { type >= 13 && type & 1 == 1 }
    }

    /// The first `n` columns of `record`; nil if it has fewer, or isn't well formed.
    @inlinable public static func columns<let n: Int>(_ record: Span<UInt8>) -> InlineArray<n, Column>? {
        var i = 0
        guard let size = varint(record, &i, end: record.count), size <= UInt64(record.count) else { return nil }
        let headerEnd = Int(size)
        var columns = InlineArray<n, Column>(repeating: Column())
        var at = headerEnd
        for c in 0..<n {
            guard let type = varint(record, &i, end: headerEnd) else { return nil }
            let length = Self.length(type)
            guard length <= record.count - at else { return nil }
            columns[c] = Column(type: type, range: at..<(at + length))
            at += length
        }
        return columns
    }

    /// An integer column's value (serial types 1 to 6, 8 and 9).
    @inlinable public static func integer(_ record: Span<UInt8>, _ column: Column) -> Int64? {
        switch column.type {
        case 1...6:
            var value = Int64(Int8(bitPattern: record[column.range.lowerBound]))
            for i in (column.range.lowerBound + 1)..<column.range.upperBound { value = value << 8 | Int64(record[i]) }
            return value
        case 8: return 0
        case 9: return 1
        default: return nil
        }
    }

    /// How many bytes a value of serial type `type` takes.
    @inlinable static func length(_ type: UInt64) -> Int {
        switch type {
        case 0, 8, 9, 10, 11: 0
        case 1, 2, 3, 4: Int(type)
        case 5: 6
        case 6, 7: 8
        default: Int(min((type - 12) / 2, UInt64(Int32.max)))
        }
    }

    /// A varint at `i`, before `end`: one byte below 0x80 (nearly every one in these records), else up to nine.
    @inlinable static func varint(_ bytes: Span<UInt8>, _ i: inout Int, end: Int) -> UInt64? {
        guard i < end else { return nil }
        let first = bytes[i]
        if first < 0x80 {
            i += 1
            return UInt64(first)
        }
        return longVarint(bytes, &i, end: end)
    }

    @usableFromInline static func longVarint(_ bytes: Span<UInt8>, _ i: inout Int, end: Int) -> UInt64? {
        var value: UInt64 = 0
        for k in 0..<9 {
            guard i < end else { return nil }
            let byte = bytes[i]
            i += 1
            if k == 8 { return value << 8 | UInt64(byte) }
            value = value << 7 | UInt64(byte & 0x7F)
            if byte < 0x80 { return value }
        }
        return value
    }
}
