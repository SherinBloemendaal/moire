/// Lays the bytes of a `ByteDiff` out in rows for a hex view, with both sides lined up: after an
/// insertion the bytes that are the same again sit on the same row.
public struct HexLayout: Sendable {
    public struct Row: Sendable, Hashable {
        /// Offsets shown on this row; empty where that side has no bytes here.
        public var left: Range<Int>
        public var right: Range<Int>
        /// The difference shown on this row, nil when both sides are the same here.
        public var hunk: Int?
    }

    struct Segment: Sendable, Hashable {
        var left: Range<Int>
        var right: Range<Int>
        var hunk: Int?
        var firstRow: Int
        var rowCount: Int
    }

    private enum Rows: Sendable {
        /// Every row starts at a multiple of the row width, on both sides.
        case byOffset(hunks: [ByteHunk])
        case segments([Segment])
    }

    public let bytesPerRow: Int
    public let rowCount: Int
    public let leftCount: Int
    public let rightCount: Int
    private let rows: Rows

    public init(diff: ByteDiff, bytesPerRow: Int) {
        precondition(bytesPerRow > 0)
        self.bytesPerRow = bytesPerRow
        leftCount = diff.leftCount
        rightCount = diff.rightCount

        let isByOffset = diff.hunks.allSatisfy { hunk in
            hunk.left.lowerBound == hunk.right.lowerBound
                && (hunk.left.count == hunk.right.count || (hunk.left.upperBound == diff.leftCount && hunk.right.upperBound == diff.rightCount))
        }
        if isByOffset {
            rows = .byOffset(hunks: diff.hunks)
            rowCount = Self.rows(for: max(diff.leftCount, diff.rightCount), bytesPerRow)
            return
        }

        var segments: [Segment] = []
        var row = 0
        var l = 0
        var r = 0
        func add(_ left: Range<Int>, _ right: Range<Int>, hunk: Int?) {
            let count = Self.rows(for: max(left.count, right.count), bytesPerRow)
            guard count > 0 else { return }
            segments.append(Segment(left: left, right: right, hunk: hunk, firstRow: row, rowCount: count))
            row += count
        }
        for (index, hunk) in diff.hunks.enumerated() {
            add(l..<hunk.left.lowerBound, r..<hunk.right.lowerBound, hunk: nil)
            add(hunk.left, hunk.right, hunk: index)
            l = hunk.left.upperBound
            r = hunk.right.upperBound
        }
        add(l..<diff.leftCount, r..<diff.rightCount, hunk: nil)
        rows = .segments(segments)
        rowCount = row
    }

    public func row(_ index: Int) -> Row {
        switch rows {
        case .byOffset(let hunks):
            let start = index * bytesPerRow
            let end = start + bytesPerRow
            let left = min(start, leftCount)..<min(end, leftCount)
            let right = min(start, rightCount)..<min(end, rightCount)
            // The first difference that ends after this row starts, if it also starts before it ends.
            let candidate = Self.firstIndex(in: hunks) { max($0.left.upperBound, $0.right.upperBound) > start }
            let hunk = candidate.flatMap { hunks[$0].left.lowerBound < end ? $0 : nil }
            return Row(left: left, right: right, hunk: hunk)
        case .segments(let segments):
            guard let found = Self.firstIndex(in: segments, where: { $0.firstRow + $0.rowCount > index }) else {
                return Row(left: leftCount..<leftCount, right: rightCount..<rightCount, hunk: nil)
            }
            let segment = segments[found]
            let offset = (index - segment.firstRow) * bytesPerRow
            func slice(_ range: Range<Int>) -> Range<Int> {
                let start = min(range.lowerBound + offset, range.upperBound)
                return start..<min(start + bytesPerRow, range.upperBound)
            }
            return Row(left: slice(segment.left), right: slice(segment.right), hunk: segment.hunk)
        }
    }

    /// The first row that shows a difference.
    public func firstRow(ofHunk index: Int) -> Int {
        switch rows {
        case .byOffset(let hunks):
            guard hunks.indices.contains(index) else { return 0 }
            return hunks[index].left.lowerBound / bytesPerRow
        case .segments(let segments):
            return segments.first { $0.hunk == index }?.firstRow ?? 0
        }
    }

    /// The row that shows the byte at `offset` of one side.
    public func row(containing offset: Int, onLeft: Bool) -> Int {
        switch rows {
        case .byOffset:
            return offset / bytesPerRow
        case .segments(let segments):
            let found = Self.firstIndex(in: segments) { (onLeft ? $0.left : $0.right).upperBound > offset }
            guard let found else { return max(rowCount - 1, 0) }
            let segment = segments[found]
            let start = (onLeft ? segment.left : segment.right).lowerBound
            return segment.firstRow + max(offset - start, 0) / bytesPerRow
        }
    }

    private static func rows(for bytes: Int, _ bytesPerRow: Int) -> Int {
        (bytes + bytesPerRow - 1) / bytesPerRow
    }

    /// Binary search for the first element where `predicate` turns true; it must stay true after.
    private static func firstIndex<Element>(in elements: [Element], where predicate: (Element) -> Bool) -> Int? {
        var low = 0
        var high = elements.count
        while low < high {
            let middle = (low + high) / 2
            if predicate(elements[middle]) { high = middle } else { low = middle + 1 }
        }
        return low < elements.count ? low : nil
    }
}
