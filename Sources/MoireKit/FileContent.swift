import Foundation

/// How a text file was stored, so a save writes it back the same way.
public struct TextEncoding: Sendable, Hashable {
    public var encoding: String.Encoding
    public var byteOrderMark: Bool

    public static let utf8 = TextEncoding(encoding: .utf8, byteOrderMark: false)

    public init(encoding: String.Encoding, byteOrderMark: Bool) {
        self.encoding = encoding
        self.byteOrderMark = byteOrderMark
    }

    public var name: String {
        switch encoding {
        case .utf8: byteOrderMark ? "UTF-8 with BOM" : "UTF-8"
        case .utf16LittleEndian: "UTF-16 LE"
        case .utf16BigEndian: "UTF-16 BE"
        case .isoLatin1: "Latin-1"
        default: String.localizedName(of: encoding)
        }
    }

    public func encode(_ text: String) throws -> Data {
        guard let body = text.data(using: encoding, allowLossyConversion: false) else {
            throw EncodingError.cannotEncode(name)
        }
        guard byteOrderMark else { return body }
        let mark: [UInt8] = switch encoding {
        case .utf16LittleEndian: [0xFF, 0xFE]
        case .utf16BigEndian: [0xFE, 0xFF]
        default: [0xEF, 0xBB, 0xBF]
        }
        return Data(mark) + body
    }

    public enum EncodingError: LocalizedError {
        case cannotEncode(String)

        public var errorDescription: String? {
            switch self {
            case .cannotEncode(let name): "The text has characters that cannot be stored as \(name)."
            }
        }
    }
}

/// A file read for comparison: text with the encoding it was stored in, or raw bytes when it is
/// not text.
public struct FileContent: Sendable {
    public enum Body: Sendable {
        case text(TextDocument, TextEncoding)
        case binary(Data)
    }

    public let url: URL
    public let body: Body

    public init(url: URL, body: Body) {
        self.url = url
        self.body = body
    }

    public static func read(_ url: URL) throws -> FileContent {
        FileContent(url: url, body: decode(try Data(contentsOf: url)))
    }

    /// UTF-8 or UTF-16 with a byte order mark, then UTF-8, then Latin-1 for older files. Data
    /// without a byte order mark and with a NUL byte in its first 8 KB is binary.
    public static func decode(_ data: Data) -> Body {
        let marked: [([UInt8], String.Encoding)] = [
            ([0xEF, 0xBB, 0xBF], .utf8),
            ([0xFF, 0xFE], .utf16LittleEndian),
            ([0xFE, 0xFF], .utf16BigEndian),
        ]
        for (mark, encoding) in marked where data.starts(with: mark) {
            if let text = String(data: data.dropFirst(mark.count), encoding: encoding) {
                return .text(TextDocument(text), TextEncoding(encoding: encoding, byteOrderMark: true))
            }
        }
        if data.prefix(8192).contains(0) {
            return .binary(data)
        }
        if let text = String(data: data, encoding: .utf8) {
            return .text(TextDocument(text), .utf8)
        }
        if let text = String(data: data, encoding: .isoLatin1) {
            return .text(TextDocument(text), TextEncoding(encoding: .isoLatin1, byteOrderMark: false))
        }
        return .binary(data)
    }
}
