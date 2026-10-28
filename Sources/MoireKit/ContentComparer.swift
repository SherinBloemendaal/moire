import Darwin
import Foundation

/// Compares the contents of two files, wherever they come from.
enum ContentComparer {
    enum Verdict: Equatable {
        case identical
        case different
        /// Line by line only: how many lines were added, removed or changed.
        case differentLines(Int)
    }

    static let quickWindow = 64 * 1024
    static let chunk = 1 << 20

    static func compare(_ left: any ReadableFile, _ right: any ReadableFile, method: CompareMethod, options: DiffOptions) throws -> Verdict {
        switch method {
        case .metadata:
            preconditionFailure("metadata never opens files")
        case .quick:
            return try quick(left, right)
        case .binary:
            return try bytes(left, right) ? .identical : .different
        case .lines:
            return try lines(left, right, options: options)
        }
    }

    /// Files up to two windows are compared whole; bigger ones by their first and last 64 KB.
    static func quick(_ left: any ReadableFile, _ right: any ReadableFile) throws -> Verdict {
        guard left.size == right.size else { return .different }
        let size = left.size
        if size <= Int64(quickWindow * 2) {
            return try bytes(left, right) ? .identical : .different
        }
        for offset in [Int64(0), size - Int64(quickWindow)] {
            if try left.read(at: offset, count: quickWindow) != right.read(at: offset, count: quickWindow) {
                return .different
            }
        }
        return .identical
    }

    /// Every byte, stopping at the first difference.
    static func bytes(_ left: any ReadableFile, _ right: any ReadableFile) throws -> Bool {
        guard left.size == right.size else { return false }
        let bufferSize = Int(min(left.size, Int64(chunk)))
        guard bufferSize > 0 else { return true }

        let first = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { first.deallocate() }
        let second = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { second.deallocate() }

        while true {
            let readLeft = try left.readNext(into: first, count: bufferSize)
            let readRight = try right.readNext(into: second, count: bufferSize)
            // A file that grew or shrank since it was listed differs from its partner here.
            if readLeft != readRight { return false }
            if readLeft == 0 { return true }
            if memcmp(first, second, readLeft) != 0 { return false }
        }
    }

    static func lines(_ left: any ReadableFile, _ right: any ReadableFile, options: DiffOptions) throws -> Verdict {
        let a = try left.readAll()
        let b = try right.readAll()
        if a == b { return .identical }
        guard case .text(let leftText, _) = FileContent.decode(a), case .text(let rightText, _) = FileContent.decode(b) else {
            return .different
        }
        let statistics = LineDiff(left: leftText, right: rightText, options: options).statistics
        let changed = statistics.added + statistics.removed + statistics.changed
        return changed == 0 ? .identical : .differentLines(changed)
    }
}
