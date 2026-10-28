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

    /// The document in this encoding. UTF-8 is written straight from the lines.
    public func encode(_ document: TextDocument) throws -> Data {
        guard encoding == .utf8 else { return try encode(document.text) }
        let body = Data(document.utf8)
        return byteOrderMark ? Data([0xEF, 0xBB, 0xBF]) + body : body
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

    /// Reads the whole file into one block of memory, which a text file then keeps as its lines,
    /// so a big file is not copied again on the way in.
    public static func read(_ url: URL) throws -> FileContent {
        let descriptor = open(url.path(percentEncoded: false), O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            let code = errno
            let kind: CocoaError.Code = switch code {
            case ENOENT, ENOTDIR: .fileReadNoSuchFile
            case EACCES, EPERM: .fileReadNoPermission
            default: .fileReadUnknown
            }
            throw CocoaError(kind, userInfo: [NSURLErrorKey: url, NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)])
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        var capacity = max(Int(info.st_size), 0) + 1
        var allocation = UnsafeMutableRawBufferPointer.allocate(byteCount: capacity, alignment: 16)
        var count = 0
        while true {
            if count == capacity {
                // The file grew while it was read.
                let larger = UnsafeMutableRawBufferPointer.allocate(byteCount: capacity * 2, alignment: 16)
                larger.copyMemory(from: UnsafeRawBufferPointer(allocation))
                allocation.deallocate()
                allocation = larger
                capacity *= 2
            }
            guard let base = allocation.baseAddress else { break }
            let result = Darwin.read(descriptor, base + count, capacity - count)
            if result < 0 {
                if errno == EINTR { continue }
                allocation.deallocate()
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if result == 0 { break }
            count += result
        }
        return FileContent(url: url, body: decode(taking: allocation, count: count))
    }

    /// UTF-8 or UTF-16 with a byte order mark, then UTF-8, then Latin-1 for older files. Data
    /// without a byte order mark and with a NUL byte in its first 8 KB is binary.
    public static func decode(_ data: Data) -> Body {
        let allocation = UnsafeMutableRawBufferPointer.allocate(byteCount: max(data.count, 1), alignment: 16)
        data.withUnsafeBytes { bytes in
            if let source = bytes.baseAddress, let destination = allocation.baseAddress {
                destination.copyMemory(from: source, byteCount: bytes.count)
            }
        }
        return decode(taking: allocation, count: data.count)
    }

    /// Decodes the first `count` bytes of `allocation` and takes it over: the lines of a UTF-8
    /// file point straight into it.
    static func decode(taking allocation: UnsafeMutableRawBufferPointer, count: Int) -> Body {
        let bytes = UnsafeBufferPointer(start: allocation.baseAddress?.assumingMemoryBound(to: UInt8.self), count: count)
        func data(from offset: Int = 0) -> Data {
            Data(UnsafeBufferPointer(rebasing: bytes[offset...]))
        }

        if bytes.starts(with: [0xEF, 0xBB, 0xBF]), UTF8Validation.isValid(UnsafeBufferPointer(rebasing: bytes[3...])) {
            return .text(TextDocument(LineBuffer(taking: allocation, offset: 3, count: count - 3)), TextEncoding(encoding: .utf8, byteOrderMark: true))
        }
        for (mark, encoding) in [([UInt8]([0xFF, 0xFE]), String.Encoding.utf16LittleEndian), ([0xFE, 0xFF], .utf16BigEndian)] where bytes.starts(with: mark) {
            if let text = String(data: data(from: 2), encoding: encoding) {
                allocation.deallocate()
                return .text(TextDocument(text), TextEncoding(encoding: encoding, byteOrderMark: true))
            }
        }
        if UnsafeBufferPointer(rebasing: bytes.prefix(8192)).contains(0) {
            defer { allocation.deallocate() }
            return .binary(data())
        }
        if UTF8Validation.isValid(bytes) {
            return .text(TextDocument(LineBuffer(taking: allocation, count: count)), .utf8)
        }
        // Every byte is a character in Latin-1, so this always works.
        defer { allocation.deallocate() }
        let extra = bytes.count { $0 >= 0x80 }
        let converted = UnsafeMutableRawBufferPointer.allocate(byteCount: max(count + extra, 1), alignment: 16)
        var index = 0
        for byte in bytes {
            if byte < 0x80 {
                converted[index] = byte
                index += 1
            } else {
                converted[index] = 0xC0 | (byte >> 6)
                converted[index + 1] = 0x80 | (byte & 0x3F)
                index += 2
            }
        }
        return .text(TextDocument(LineBuffer(taking: converted, count: index)), TextEncoding(encoding: .isoLatin1, byteOrderMark: false))
    }
}
