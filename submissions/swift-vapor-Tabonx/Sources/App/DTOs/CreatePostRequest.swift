import Foundation
import NIOCore

/// The `POST /posts` body. Decoding fails only on invalid JSON, so a wrong or missing `body`
/// reaches validation as nil and gets its own error message.
struct CreatePostRequest: Decodable {
    let body: String?

    enum CodingKeys: String, CodingKey {
        case body
    }

    init(from decoder: any Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        body = try? container?.decode(String.self, forKey: .body)
    }

    static func decode(from buffer: ByteBuffer?) throws -> CreatePostRequest {
        do {
            return try JSONDecoder().decode(CreatePostRequest.self, from: buffer ?? ByteBuffer())
        } catch {
            throw APIError.malformedJSON
        }
    }
}

/// A post body that passed validation: trimmed, not empty, at most 500 characters.
struct PostBody: Sendable, Equatable {
    static let maximumLength = 500

    let text: String

    init(validating raw: String?) throws {
        guard let raw else { throw APIError.bodyRequired }
        let trimmed = Self.trimmed(raw)
        guard !trimmed.isEmpty else { throw APIError.bodyRequired }
        // Counted in Unicode scalars, the unit SQLite's length() uses in the CHECK constraint.
        // String.count counts grapheme clusters, which can be fewer, so a body could pass here and
        // then fail the insert.
        guard trimmed.unicodeScalars.count <= Self.maximumLength else { throw APIError.bodyTooLong }
        text = trimmed
    }

    /// Trims the same characters as JavaScript's `String.prototype.trim`. Foundation's
    /// `.whitespacesAndNewlines` is a different set: it also strips U+0085 and leaves U+FEFF.
    private static func trimmed(_ text: String) -> String {
        var scalars = Substring(text).unicodeScalars
        while let first = scalars.first, isTrimmable(first) { scalars.removeFirst() }
        while let last = scalars.last, isTrimmable(last) { scalars.removeLast() }
        return String(scalars)
    }

    private static func isTrimmable(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
            true
        default:
            false
        }
    }
}
