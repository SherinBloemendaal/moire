import Foundation

/// Random access to the bytes of a file or a buffer, so large files can be read a page at a time.
public protocol ByteSource {
    var count: Int { get }
    /// The bytes in `range`, cut off at the end of the source.
    func bytes(in range: Range<Int>) throws -> [UInt8]
}

public struct DataByteSource: ByteSource, Sendable {
    public let data: Data

    public init(_ data: Data) {
        self.data = data
    }

    public var count: Int { data.count }

    public func bytes(in range: Range<Int>) throws -> [UInt8] {
        let clamped = range.clamped(to: 0..<data.count)
        guard !clamped.isEmpty else { return [] }
        let start = data.startIndex
        return [UInt8](data[(start + clamped.lowerBound)..<(start + clamped.upperBound)])
    }
}

/// Reads a file in fixed pages and keeps the most recently used ones, so scrolling through a
/// file of any size reads only what is shown.
public final class FileByteSource: ByteSource {
    public let url: URL
    public let count: Int
    private let handle: FileHandle
    private let pageSize: Int
    private let maximumPages: Int
    private var pages: [Int: [UInt8]] = [:]
    /// Page numbers from least to most recently used.
    private var recent: [Int] = []

    public init(url: URL, pageSize: Int = 64 * 1024, maximumPages: Int = 64) throws {
        precondition(pageSize > 0 && maximumPages > 0)
        self.url = url
        self.pageSize = pageSize
        self.maximumPages = maximumPages
        handle = try FileHandle(forReadingFrom: url)
        count = Int(try handle.seekToEnd())
    }

    deinit {
        try? handle.close()
    }

    public func bytes(in range: Range<Int>) throws -> [UInt8] {
        let clamped = range.clamped(to: 0..<count)
        guard !clamped.isEmpty else { return [] }
        var result: [UInt8] = []
        result.reserveCapacity(clamped.count)
        var position = clamped.lowerBound
        while position < clamped.upperBound {
            let number = position / pageSize
            let page = try self.page(number)
            let pageStart = number * pageSize
            let from = position - pageStart
            let to = min(page.count, clamped.upperBound - pageStart)
            guard from < to else { break }
            result.append(contentsOf: page[from..<to])
            position = pageStart + to
        }
        return result
    }

    private func page(_ number: Int) throws -> [UInt8] {
        if let page = pages[number] {
            if recent.last != number {
                recent.removeAll { $0 == number }
                recent.append(number)
            }
            return page
        }
        try handle.seek(toOffset: UInt64(number * pageSize))
        let page = [UInt8](try handle.read(upToCount: pageSize) ?? Data())
        pages[number] = page
        recent.append(number)
        if recent.count > maximumPages {
            pages[recent.removeFirst()] = nil
        }
        return page
    }
}
