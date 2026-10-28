import Darwin
import Foundation

/// Compares the contents of two files with plain `read` calls.
///
/// Memory mapping is avoided on purpose: when a mapped file shrinks while it is being read (a
/// file being written, or a share that drops), the process crashes instead of getting an error.
enum ContentComparer {
    enum Verdict: Equatable {
        case identical
        case different
        /// Line by line only: how many lines were added, removed or changed.
        case differentLines(Int)
    }

    static let quickWindow = 64 * 1024
    static let chunk = 1 << 20
    /// Above this size a read bypasses the file cache, so one huge file does not push out the
    /// cached contents of everything else.
    static let uncachedFrom: Int64 = 256 << 20

    static func compare(_ left: String, _ right: String, size: Int64, method: CompareMethod, options: DiffOptions) throws -> Verdict {
        switch method {
        case .metadata:
            preconditionFailure("metadata never opens files")
        case .quick:
            return try quick(left, right, size: size)
        case .binary:
            return try bytes(left, right) ? .identical : .different
        case .lines:
            return try lines(left, right, options: options)
        }
    }

    /// Same size assumed. Files up to two windows are compared whole; bigger ones by their first
    /// and last 64 KB.
    static func quick(_ left: String, _ right: String, size: Int64) throws -> Verdict {
        if size <= Int64(quickWindow * 2) {
            return try bytes(left, right) ? .identical : .different
        }
        let a = try OpenFile(left, size: size)
        let b = try OpenFile(right, size: size)
        let tail = size - Int64(quickWindow)
        for offset in [Int64(0), tail] {
            let first = try a.read(at: offset, count: quickWindow)
            let second = try b.read(at: offset, count: quickWindow)
            if first != second { return .different }
        }
        return .identical
    }

    /// Every byte, stopping at the first difference.
    static func bytes(_ left: String, _ right: String) throws -> Bool {
        let a = try OpenFile(left)
        let b = try OpenFile(right)
        guard a.size == b.size else { return false }
        let bufferSize = Int(min(a.size, Int64(chunk)))
        guard bufferSize > 0 else { return true }

        let first = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { first.deallocate() }
        let second = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { second.deallocate() }

        while true {
            let readA = try a.readNext(into: first, count: bufferSize)
            let readB = try b.readNext(into: second, count: bufferSize)
            // A file that grew or shrank since it was listed differs from its partner here.
            if readA != readB { return false }
            if readA == 0 { return true }
            if memcmp(first, second, readA) != 0 { return false }
        }
    }

    static func lines(_ left: String, _ right: String, options: DiffOptions) throws -> Verdict {
        let a = try Data(contentsOf: URL(filePath: left))
        let b = try Data(contentsOf: URL(filePath: right))
        if a == b { return .identical }
        guard case .text(let leftText, _) = FileContent.decode(a), case .text(let rightText, _) = FileContent.decode(b) else {
            return .different
        }
        let statistics = LineDiff(left: leftText, right: rightText, options: options).statistics
        let changed = statistics.added + statistics.removed + statistics.changed
        return changed == 0 ? .identical : .differentLines(changed)
    }
}

/// A file opened for reading, closed when released.
private final class OpenFile {
    let descriptor: Int32
    let size: Int64

    init(_ path: String, size knownSize: Int64? = nil) throws {
        descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError.current(path: path) }
        if let knownSize {
            size = knownSize
        } else {
            var info = stat()
            guard fstat(descriptor, &info) == 0 else {
                let error = POSIXError.current(path: path)
                Darwin.close(descriptor)
                throw error
            }
            size = Int64(info.st_size)
        }
        if size >= ContentComparer.uncachedFrom {
            _ = fcntl(descriptor, F_NOCACHE, 1)
        }
    }

    deinit { Darwin.close(descriptor) }

    /// Fills `buffer` as far as the file allows; returns the bytes read, 0 at the end.
    func readNext(into buffer: UnsafeMutableRawPointer, count: Int) throws -> Int {
        var total = 0
        while total < count {
            let result = Darwin.read(descriptor, buffer + total, count - total)
            if result == 0 { break }
            if result < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            total += result
        }
        return total
    }

    func read(at offset: Int64, count: Int) throws -> Data {
        var data = Data(count: count)
        let total = try data.withUnsafeMutableBytes { buffer in
            var total = 0
            while total < count {
                let result = pread(descriptor, buffer.baseAddress! + total, count - total, off_t(offset) + off_t(total))
                if result == 0 { break }
                if result < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                total += result
            }
            return total
        }
        return data.prefix(total)
    }
}
