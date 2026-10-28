import Foundation
import ImageIO

/// Archives Moire can open like a folder.
public enum ArchiveFormat: String, Sendable, Hashable, CaseIterable {
    case zip
    case tar
    case tarGzip
    case tarBzip2
    case tarXz
}

/// Documents Moire compares by their text.
public enum DocumentFormat: String, Sendable, Hashable, CaseIterable {
    case pdf
    case docx
    case doc
    case rtf
    case odt
}

/// What a file holds, which decides how it is compared.
public enum FileKind: Sendable, Hashable {
    case text
    /// Comma or tab separated values.
    case table
    case image
    case document(DocumentFormat)
    case archive(ArchiveFormat)
    /// Anything else: compared byte by byte.
    case binary

    /// Looks at the name and the first bytes, then asks ImageIO about binary files that are not
    /// recognized otherwise, so every image format the system can read counts as an image.
    /// Images stored as text, such as SVG, stay text.
    public static func detect(_ url: URL) -> FileKind {
        let header = (try? readHeader(of: url)) ?? Data()
        let kind = sniff(header: header, fileName: url.lastPathComponent)
        guard kind == .binary else { return kind }
        return imageIOCanRead(url) ? .image : kind
    }

    /// The bytes that `sniff` looks at.
    public static let headerLength = 8192

    public static func readHeader(of url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: headerLength) ?? Data()
    }

    /// Decides by magic numbers first and the file name second. Container formats that share a
    /// signature (zip for Word and OpenDocument files, gzip for a tarball) are told apart by name.
    public static func sniff(header: Data, fileName: String) -> FileKind {
        let name = fileName.lowercased()
        let fileExtension = (name as NSString).pathExtension
        let bytes = [UInt8](header.prefix(512))

        func starts(_ signature: [UInt8], at offset: Int = 0) -> Bool {
            bytes.count >= offset + signature.count && Array(bytes[offset..<(offset + signature.count)]) == signature
        }

        if starts([0x50, 0x4B, 0x03, 0x04]) || starts([0x50, 0x4B, 0x05, 0x06]) {
            switch fileExtension {
            case "docx": return .document(.docx)
            case "odt": return .document(.odt)
            case _ where zipDocumentExtensions.contains(fileExtension): return .binary
            default: return .archive(.zip)
            }
        }
        if starts(Array("ustar".utf8), at: 257) || (fileExtension == "tar" && !header.isEmpty) {
            return .archive(.tar)
        }
        if starts([0x1F, 0x8B]) {
            return name.hasSuffix(".tar.gz") || fileExtension == "tgz" ? .archive(.tarGzip) : .binary
        }
        if starts(Array("BZh".utf8)) {
            return name.hasSuffix(".tar.bz2") || ["tbz", "tbz2"].contains(fileExtension) ? .archive(.tarBzip2) : .binary
        }
        if starts([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) {
            return name.hasSuffix(".tar.xz") || fileExtension == "txz" ? .archive(.tarXz) : .binary
        }
        // The PDF signature may follow some junk, which readers accept within the first KB.
        if header.prefix(1024).range(of: Data("%PDF-".utf8)) != nil {
            return .document(.pdf)
        }
        if starts(Array("{\\rtf".utf8)) {
            return .document(.rtf)
        }
        if starts([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) {
            return fileExtension == "doc" ? .document(.doc) : .binary
        }
        if imageSignatures.contains(where: { starts($0.bytes, at: $0.offset) }) || isISOMediaImage(bytes) || isWebP(bytes) || isBMP(bytes) {
            return .image
        }

        let isText = startsWithByteOrderMark(bytes) || !header.contains(0)
        guard isText else { return .binary }
        return tableExtensions.contains(fileExtension) ? .table : .text
    }

    static let tableExtensions: Set<String> = ["csv", "tsv", "tab"]
    /// Zip containers that are documents of their own, not folders a person wants to browse.
    static let zipDocumentExtensions: Set<String> = ["xlsx", "pptx", "ods", "odp", "pages", "numbers", "key", "epub"]

    private static let imageSignatures: [(offset: Int, bytes: [UInt8])] = [
        (0, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
        (0, [0xFF, 0xD8, 0xFF]),
        (0, Array("GIF87a".utf8)),
        (0, Array("GIF89a".utf8)),
        (0, [0x49, 0x49, 0x2A, 0x00]),
        (0, [0x4D, 0x4D, 0x00, 0x2A]),
        (0, [0x00, 0x00, 0x01, 0x00]),
        (0, Array("8BPS".utf8)),
        (0, [0x00, 0x00, 0x00, 0x0C, 0x6A, 0x50, 0x20, 0x20]),
    ]

    /// "BM" alone is too common at the start of a text, so the reserved zero bytes must follow.
    private static func isBMP(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 14 && bytes[0] == 0x42 && bytes[1] == 0x4D && bytes[6..<10].allSatisfy { $0 == 0 }
    }

    private static func isWebP(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 12 && Array(bytes[0..<4]) == Array("RIFF".utf8) && Array(bytes[8..<12]) == Array("WEBP".utf8)
    }

    /// HEIF and AVIF: an ISO media `ftyp` box with an image brand.
    private static func isISOMediaImage(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 12, Array(bytes[4..<8]) == Array("ftyp".utf8) else { return false }
        let brand = String(decoding: bytes[8..<12], as: UTF8.self)
        return ["heic", "heix", "hevc", "heim", "heis", "mif1", "msf1", "avif", "avis"].contains(brand)
    }

    private static func startsWithByteOrderMark(_ bytes: [UInt8]) -> Bool {
        bytes.starts(with: [0xEF, 0xBB, 0xBF]) || bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF])
    }

    private static func imageIOCanRead(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetType(source) != nil else {
            return false
        }
        return CGImageSourceGetCount(source) > 0
    }
}
