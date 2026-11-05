// A Swift view of SQLite's B-trees, for reading them directly: CSQLite/btree.c moves cursors over the tables and
// indexes inside the connection's open transaction, and the records are decoded here (Record.swift), in place. Pages,
// cache, WAL and transaction stay SQLite's. Inlinable, so the server's calls compile as if they were its own.
public import CSQLite

/// A cursor over one of SQLite's B-trees. Its moves are `mutating`, and a record is a `Span` borrowed from it, so the
/// compiler rules out reading a record after its cursor has moved on.
public struct Cursor: ~Copyable, ~Sendable {
    @usableFromInline let raw: OpaquePointer

    /// Over the table (`keyColumns` 0) or index whose root is page `root` of `db`; nil when out of memory.
    public init?(_ db: OpaquePointer, root: UInt32, keyColumns: Int32 = 0, descending: Bool = false) {
        guard let raw = btree_cursor_new(db, root, keyColumns, descending ? 1 : 0) else { return nil }
        self.raw = raw
    }

    deinit {
        btree_cursor_free(raw)
    }

    /// Inside the connection's open transaction; closed before it ends.
    @inlinable public mutating func open() -> Bool { btree_cursor_open(raw) == SQLITE_OK }
    @inlinable public mutating func close() { btree_cursor_close(raw) }

    /// The table row `rowid`.
    @inlinable public mutating func seek(_ rowid: Int64) -> Move { Move(btree_seek(raw, rowid)) }
    /// The first index entry whose first column is at least `key`.
    @inlinable public mutating func seek(atLeast key: Int64) -> Move { Move(btree_seek_at_least(raw, key)) }
    @inlinable public mutating func first() -> Move { Move(btree_first(raw)) }
    @inlinable public mutating func next() -> Move { Move(btree_next(raw)) }

    /// `counts[key - lo]` += the entries of this index (on one integer column) with each key in `lo...hi`.
    @inlinable public mutating func count(_ lo: Int64, _ hi: Int64, into counts: inout MutableSpan<UInt32>) -> Count {
        precondition(lo <= hi && hi - lo < Int64(counts.count))
        let rc = counts.withUnsafeMutableBufferPointer { btree_count_range(raw, lo, hi, $0.baseAddress) }
        return rc == 0 ? .done : rc == 1 ? .unexpected : .failed
    }

    /// The current entry's record; empty when it spills onto overflow pages.
    @inlinable public var record: Span<UInt8> {
        @_lifetime(borrow self) borrowing get {
            var length: UInt32 = 0
            let base = btree_record(raw, &length)
            let span = Span(_unsafeElements: UnsafeBufferPointer(start: base, count: Int(length)))
            return _overrideLifetime(span, borrowing: self)
        }
    }

    public enum Move {
        case entry, none, failed

        @inlinable init(_ rc: Int32) {
            self = rc == 1 ? .entry : rc == 0 ? .none : .failed
        }
    }

    public enum Count {
        case done, unexpected, failed
    }
}
