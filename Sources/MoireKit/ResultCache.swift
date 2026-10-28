import CryptoKit
import Foundation
import Synchronization

/// Remembers which file pairs were identical, so comparing the same folders again only reads
/// files that changed since.
///
/// A result is keyed by the file IDs (inodes) of both files and only reused while both sizes and
/// modification dates are still exactly the same. That is the same promise `rsync` and `make`
/// rely on: a program that changes a file without changing its date or size is not noticed.
///
/// One cache file holds the results of one pair of root folders and one way of comparing. Only
/// the pairs seen in the latest run are written back, so the file never grows past one tree.
public final class ResultCache: Sendable {
    public enum Verdict: Sendable, Hashable {
        case identical
        case different
        case differentLines(Int)
    }

    struct Key: Hashable, Sendable {
        let left: UInt64
        let right: UInt64
    }

    struct Entry: Hashable, Sendable {
        let leftSize: Int64
        let leftModified: Int64
        let rightSize: Int64
        let rightModified: Int64
        let verdict: Verdict
    }

    public let file: URL
    private let stored: [Key: Entry]
    private let seen = Mutex<[Key: Entry]>([:])

    /// Loads `file` if it exists. A missing, foreign or damaged file starts an empty cache.
    public init(file: URL) {
        self.file = file
        stored = (try? Data(contentsOf: file)).flatMap(Self.decode) ?? [:]
    }

    /// The cache file for comparing `left` with `right` using `settings`, in the user's caches folder.
    public static func file(left: URL, right: URL, settings: FolderCompareSettings) -> URL {
        let identity = [
            left.standardizedFileURL.path(percentEncoded: false),
            right.standardizedFileURL.path(percentEncoded: false),
            settings.method.rawValue,
            settings.method == .lines ? "\(settings.diffOptions.whitespace.rawValue)-\(settings.diffOptions.ignoreCase)" : "",
        ].joined(separator: "\n")
        let name = SHA256.hash(data: Data(identity.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "io.github.sherinbloemendaal.moire/results/\(name).cache")
    }

    public var count: Int { stored.count }

    func lookup(left: FolderTree.SideInfo, right: FolderTree.SideInfo) -> Verdict? {
        guard left.fileID != 0, right.fileID != 0 else { return nil }
        let key = Key(left: left.fileID, right: right.fileID)
        guard let entry = stored[key],
              entry.leftSize == left.size, entry.leftModified == left.modified,
              entry.rightSize == right.size, entry.rightModified == right.modified
        else { return nil }
        seen.withLock { $0[key] = entry }
        return entry.verdict
    }

    func record(left: FolderTree.SideInfo, right: FolderTree.SideInfo, verdict: Verdict) {
        guard left.fileID != 0, right.fileID != 0 else { return }
        let entry = Entry(leftSize: left.size, leftModified: left.modified, rightSize: right.size, rightModified: right.modified, verdict: verdict)
        seen.withLock { $0[Key(left: left.fileID, right: right.fileID)] = entry }
    }

    /// Writes the results of this run, replacing the file.
    public func save() throws {
        let entries = seen.withLock { $0 }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encode(entries).write(to: file, options: .atomic)
    }

    // MARK: File format
    //
    // "MOIRERC1", a UInt64 count, then one fixed-size record per pair, all little endian:
    // left ID, right ID, left size, left date, right size, right date (8 bytes each),
    // verdict (1 byte: 0 identical, 1 different, 2 different lines) and changed lines (4 bytes).

    private static let magic = Array("MOIRERC1".utf8)
    private static let recordSize = 8 * 6 + 1 + 4

    static func encode(_ entries: [Key: Entry]) -> Data {
        var bytes = [UInt8]()
        bytes.reserveCapacity(magic.count + 8 + entries.count * recordSize)
        bytes.append(contentsOf: magic)
        append(UInt64(entries.count), to: &bytes)
        for (key, entry) in entries {
            append(key.left, to: &bytes)
            append(key.right, to: &bytes)
            append(UInt64(bitPattern: entry.leftSize), to: &bytes)
            append(UInt64(bitPattern: entry.leftModified), to: &bytes)
            append(UInt64(bitPattern: entry.rightSize), to: &bytes)
            append(UInt64(bitPattern: entry.rightModified), to: &bytes)
            switch entry.verdict {
            case .identical:
                bytes.append(0)
                append(UInt32(0), to: &bytes)
            case .different:
                bytes.append(1)
                append(UInt32(0), to: &bytes)
            case .differentLines(let lines):
                bytes.append(2)
                append(UInt32(clamping: lines), to: &bytes)
            }
        }
        return Data(bytes)
    }

    static func decode(_ data: Data) -> [Key: Entry]? {
        let bytes = [UInt8](data)
        guard bytes.count >= magic.count + 8, Array(bytes[0..<magic.count]) == magic else { return nil }
        var offset = magic.count
        let count = read(UInt64.self, bytes, &offset)
        let (size, overflow) = Int(clamping: count).multipliedReportingOverflow(by: recordSize)
        guard !overflow, bytes.count == magic.count + 8 + size else { return nil }

        var entries: [Key: Entry] = Dictionary(minimumCapacity: Int(count))
        for _ in 0..<Int(count) {
            let key = Key(left: read(UInt64.self, bytes, &offset), right: read(UInt64.self, bytes, &offset))
            let leftSize = Int64(bitPattern: read(UInt64.self, bytes, &offset))
            let leftModified = Int64(bitPattern: read(UInt64.self, bytes, &offset))
            let rightSize = Int64(bitPattern: read(UInt64.self, bytes, &offset))
            let rightModified = Int64(bitPattern: read(UInt64.self, bytes, &offset))
            let kind = bytes[offset]
            offset += 1
            let lines = Int(read(UInt32.self, bytes, &offset))
            let verdict: Verdict
            switch kind {
            case 0: verdict = .identical
            case 1: verdict = .different
            case 2: verdict = .differentLines(lines)
            default: return nil
            }
            entries[key] = Entry(leftSize: leftSize, leftModified: leftModified, rightSize: rightSize, rightModified: rightModified, verdict: verdict)
        }
        return entries
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to bytes: inout [UInt8]) {
        withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
    }

    private static func read<T: FixedWidthInteger>(_ type: T.Type, _ bytes: [UInt8], _ offset: inout Int) -> T {
        var value: T = 0
        for index in 0..<MemoryLayout<T>.size {
            value |= T(bytes[offset + index]) << (8 * index)
        }
        offset += MemoryLayout<T>.size
        return value
    }
}
