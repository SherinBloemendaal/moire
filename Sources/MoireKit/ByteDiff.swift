import Foundation

/// A run of bytes that differ: `left` bytes of the left file stand where `right` bytes of the
/// right file are. Between two hunks both files hold the same bytes, equally many on each side.
public struct ByteHunk: Sendable, Hashable {
    public var left: Range<Int>
    public var right: Range<Int>

    public init(left: Range<Int>, right: Range<Int>) {
        self.left = left
        self.right = right
    }
}

/// The differences between two files, byte by byte, read in chunks so files of any size work.
public struct ByteDiff: Sendable {
    public enum Matching: String, Sendable, Hashable, CaseIterable {
        /// Compare by offset when both files are equally long, and look for inserted or removed
        /// bytes when they are not.
        case automatic
        /// Byte 10 is compared with byte 10, whatever was inserted before it.
        case byOffset
        /// Always look for inserted or removed bytes.
        case findInsertions
    }

    public enum Alignment: Sendable, Hashable {
        case byOffset
        /// Inserted and removed bytes were found, so the bytes after them line up again.
        case aligned
        /// Insertions were looked for up to these offsets. After them the files differ too much
        /// to line up, and the rest is compared by offset.
        case alignedUntil(left: Int, right: Int)
    }

    public struct Options: Sendable, Hashable {
        public var matching: Matching
        /// Bytes read at once while the files are the same.
        public var chunkSize = 256 * 1024
        /// Bytes on each side that Myers' algorithm looks at to find a small edit.
        public var window = 1024
        /// Equal bytes in a row it takes to count as lined up again.
        public var syncLength = 16
        /// How far ahead a large insertion or removal is looked for.
        public var searchDistance = 1 << 20
        /// Failed attempts in a row after which the files are compared by offset.
        public var maximumFailedSyncs = 64
        /// Differences closer together than this are shown as one.
        public var mergeGap = 8

        public init(matching: Matching = .automatic) {
            self.matching = matching
        }
    }

    public let leftCount: Int
    public let rightCount: Int
    public let hunks: [ByteHunk]
    public let alignment: Alignment

    public var isIdentical: Bool { hunks.isEmpty && leftCount == rightCount }
    /// Bytes of the left file inside a difference.
    public var leftChangedBytes: Int { hunks.reduce(0) { $0 + $1.left.count } }
    public var rightChangedBytes: Int { hunks.reduce(0) { $0 + $1.right.count } }

    public init(leftCount: Int, rightCount: Int, hunks: [ByteHunk], alignment: Alignment) {
        self.leftCount = leftCount
        self.rightCount = rightCount
        self.hunks = hunks
        self.alignment = alignment
    }

    /// Throws `CancellationError` when the surrounding task is cancelled.
    public static func compare(_ left: some ByteSource, _ right: some ByteSource, options: Options = Options()) throws -> ByteDiff {
        var comparer = Comparer(left: left, right: right, options: options)
        let align = switch options.matching {
        case .automatic: left.count != right.count
        case .byOffset: false
        case .findInsertions: true
        }
        let alignment: Alignment
        if align {
            alignment = try comparer.compareAligned()
        } else {
            try comparer.compareByOffset(from: 0, 0)
            alignment = .byOffset
        }
        return ByteDiff(leftCount: left.count, rightCount: right.count, hunks: comparer.hunks, alignment: alignment)
    }
}

private struct Comparer<Left: ByteSource, Right: ByteSource> {
    let left: Left
    let right: Right
    let options: ByteDiff.Options
    var hunks: [ByteHunk] = []

    init(left: Left, right: Right, options: ByteDiff.Options) {
        self.left = left
        self.right = right
        self.options = options
    }

    private enum Resync {
        /// Both files line up again from these offsets.
        case at(Int, Int)
        /// The rest of both files was compared completely.
        case tail([ByteHunk])
    }

    mutating func compareAligned() throws -> ByteDiff.Alignment {
        var i = 0
        var j = 0
        var failures = 0
        while i < left.count, j < right.count {
            let equal = try commonLength(i, j)
            i += equal
            j += equal
            guard i < left.count, j < right.count else { break }

            switch try resync(i, j) {
            case .at(let newI, let newJ)?:
                append(ByteHunk(left: i..<newI, right: j..<newJ))
                i = newI
                j = newJ
                failures = 0
            case .tail(let tail)?:
                tail.forEach { append($0) }
                return .aligned
            case nil:
                failures += 1
                if failures >= options.maximumFailedSyncs {
                    try compareByOffset(from: i, j)
                    return .alignedUntil(left: i, right: j)
                }
                let block = min(options.window, left.count - i, right.count - j)
                append(ByteHunk(left: i..<(i + block), right: j..<(j + block)))
                i += block
                j += block
            }
        }
        if i < left.count || j < right.count {
            append(ByteHunk(left: i..<left.count, right: j..<right.count))
        }
        return .aligned
    }

    /// Compares byte `i + k` with byte `j + k` up to the end of the shorter file; what is left of
    /// the longer one becomes the last difference.
    mutating func compareByOffset(from i: Int, _ j: Int) throws {
        let shared = min(left.count - i, right.count - j)
        var k = 0
        var runStart: Int?
        var runEnd = 0

        while k < shared {
            try Task.checkCancellation()
            let count = min(options.chunkSize, shared - k)
            let a = try left.bytes(in: (i + k)..<(i + k + count))
            let b = try right.bytes(in: (j + k)..<(j + k + count))
            guard a.count == count, b.count == count else { throw CocoaError(.fileReadUnknown) }
            if !Self.equal(a, b) {
                for t in 0..<count where a[t] != b[t] {
                    let position = k + t
                    if let start = runStart, position - runEnd > options.mergeGap {
                        append(ByteHunk(left: (i + start)..<(i + runEnd), right: (j + start)..<(j + runEnd)))
                        runStart = position
                    } else if runStart == nil {
                        runStart = position
                    }
                    runEnd = position + 1
                }
            }
            k += count
        }
        if let start = runStart {
            append(ByteHunk(left: (i + start)..<(i + runEnd), right: (j + start)..<(j + runEnd)))
        }
        if left.count - i != right.count - j {
            append(ByteHunk(left: (i + shared)..<left.count, right: (j + shared)..<right.count))
        }
    }

    /// How many bytes from `i` and `j` on are the same.
    private func commonLength(_ i: Int, _ j: Int) throws -> Int {
        var length = 0
        while i + length < left.count, j + length < right.count {
            try Task.checkCancellation()
            let count = min(options.chunkSize, left.count - i - length, right.count - j - length)
            let a = try left.bytes(in: (i + length)..<(i + length + count))
            let b = try right.bytes(in: (j + length)..<(j + length + count))
            guard a.count == count, b.count == count else { throw CocoaError(.fileReadUnknown) }
            let same = Self.mismatch(a, b)
            length += same
            if same < count { break }
        }
        return length
    }

    /// Finds where the files line up again after differing at `i` and `j`: first a small edit
    /// inside a window, then a larger insertion or removal by searching ahead for a run of bytes.
    private func resync(_ i: Int, _ j: Int) throws -> Resync? {
        let a = try left.bytes(in: i..<min(left.count, i + options.window))
        let b = try right.bytes(in: j..<min(right.count, j + options.window))
        let operations = Myers.diff(a, b)

        if i + a.count == left.count, j + b.count == right.count {
            return .tail(Self.hunks(operations, i, j))
        }

        var x = 0
        var y = 0
        var run = 0
        var runX = 0
        var runY = 0
        for operation in operations {
            switch operation {
            case .equal:
                if run == 0 {
                    runX = x
                    runY = y
                }
                run += 1
                x += 1
                y += 1
                if run >= options.syncLength { return .at(i + runX, j + runY) }
            case .delete:
                run = 0
                x += 1
            case .insert:
                run = 0
                y += 1
            }
        }

        let anchorLength = options.syncLength * 2
        let nearLeft = try left.bytes(in: i..<min(left.count, i + options.searchDistance))
        let nearRight = try right.bytes(in: j..<min(right.count, j + options.searchDistance))
        var best: (Int, Int)?
        var bestCost = Int.max
        for distance in [0, 64, 512, 4096, 32768] {
            if distance + anchorLength <= nearLeft.count {
                let anchor = nearLeft[distance..<(distance + anchorLength)]
                if !Self.isUniform(anchor), let found = Self.find(anchor, in: nearRight), distance + found < bestCost {
                    best = (i + distance, j + found)
                    bestCost = distance + found
                }
            }
            if distance + anchorLength <= nearRight.count {
                let anchor = nearRight[distance..<(distance + anchorLength)]
                if !Self.isUniform(anchor), let found = Self.find(anchor, in: nearLeft), distance + found < bestCost {
                    best = (i + found, j + distance)
                    bestCost = distance + found
                }
            }
        }
        return best.map { .at($0.0, $0.1) }
    }

    /// Adds a difference, joining it to the previous one when only a few equal bytes sit between.
    private mutating func append(_ hunk: ByteHunk) {
        guard !hunk.left.isEmpty || !hunk.right.isEmpty else { return }
        if let last = hunks.last, hunk.left.lowerBound - last.left.upperBound <= options.mergeGap {
            hunks[hunks.count - 1] = ByteHunk(
                left: last.left.lowerBound..<hunk.left.upperBound,
                right: last.right.lowerBound..<hunk.right.upperBound
            )
        } else {
            hunks.append(hunk)
        }
    }

    private static func hunks(_ operations: [EditOperation], _ i: Int, _ j: Int) -> [ByteHunk] {
        var hunks: [ByteHunk] = []
        var x = i
        var y = j
        var start: (Int, Int)?
        for operation in operations {
            if operation == .equal {
                if let (startX, startY) = start {
                    hunks.append(ByteHunk(left: startX..<x, right: startY..<y))
                    start = nil
                }
                x += 1
                y += 1
                continue
            }
            if start == nil { start = (x, y) }
            if operation == .delete { x += 1 } else { y += 1 }
        }
        if let (startX, startY) = start {
            hunks.append(ByteHunk(left: startX..<x, right: startY..<y))
        }
        return hunks
    }

    private static func equal(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        a.count == b.count && equalPrefix(a, b, a.count)
    }

    /// Index of the first byte that differs, or the length when none does.
    private static func mismatch(_ a: [UInt8], _ b: [UInt8]) -> Int {
        let count = min(a.count, b.count)
        if equalPrefix(a, b, count) { return count }
        for index in 0..<count where a[index] != b[index] {
            return index
        }
        return count
    }

    private static func equalPrefix(_ a: [UInt8], _ b: [UInt8], _ count: Int) -> Bool {
        a.withUnsafeBufferPointer { a in
            b.withUnsafeBufferPointer { b in
                guard count > 0, let a = a.baseAddress, let b = b.baseAddress else { return true }
                return memcmp(a, b, count) == 0
            }
        }
    }

    /// A run of one byte value matches every other run of it, so it says nothing about alignment.
    private static func isUniform(_ bytes: ArraySlice<UInt8>) -> Bool {
        guard let first = bytes.first else { return true }
        return bytes.allSatisfy { $0 == first }
    }

    private static func find(_ needle: ArraySlice<UInt8>, in haystack: [UInt8]) -> Int? {
        haystack.withUnsafeBufferPointer { haystack in
            needle.withUnsafeBufferPointer { needle in
                guard let base = haystack.baseAddress, let pattern = needle.baseAddress, let first = needle.first,
                      needle.count <= haystack.count else { return nil }
                let last = haystack.count - needle.count
                var start = 0
                while start <= last {
                    guard let hit = memchr(base + start, Int32(first), last - start + 1) else { return nil }
                    let index = base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
                    if memcmp(base + index, pattern, needle.count) == 0 { return index }
                    start = index + 1
                }
                return nil
            }
        }
    }
}
