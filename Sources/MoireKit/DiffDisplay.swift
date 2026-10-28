/// What the comparison list shows, line by line: every row of a diff side by side, or removed
/// lines above added lines (unified), with long runs of unchanged rows folded away when asked.
/// It is built from the hunks, so it takes memory per change and not per line.
public struct DiffDisplay: Sendable {
    public enum Layout: String, Sendable, CaseIterable {
        case sideBySide
        case unified
    }

    public enum Line: Sendable, Hashable {
        /// A whole diff row: both sides next to each other, or an unchanged row in unified.
        case row(Int)
        /// Unified: the left line of a row in a hunk.
        case removed(row: Int)
        /// Unified: the right line of a row in a hunk.
        case added(row: Int)
        /// Unchanged rows folded into one line.
        case fold(Range<Int>)

        /// The diff row this line shows, if it shows one.
        public var row: Int? {
            switch self {
            case .row(let row), .removed(let row), .added(let row): row
            case .fold: nil
            }
        }
    }

    public struct Block: Sendable, Hashable {
        public enum Kind: Sendable, Hashable {
            case same
            case hunk(Int)
            case fold
        }

        public var kind: Kind
        /// The diff rows it covers.
        public var rows: Range<Int>
        /// Its lines in the display.
        public var lines: Range<Int>
    }

    public let diff: LineDiff
    public let layout: Layout
    public let blocks: [Block]
    public var count: Int { blocks.last?.lines.upperBound ?? 0 }

    /// `expandedFolds` holds the first row of every fold the user opened.
    public init(diff: LineDiff, layout: Layout, foldUnchanged: Bool, expandedFolds: Set<Int> = [], context: Int = 3) {
        self.diff = diff
        self.layout = layout
        var blocks: [Block] = []
        var next = 0

        func add(_ kind: Block.Kind, rows: Range<Int>, lineCount: Int) {
            guard lineCount > 0 else { return }
            blocks.append(Block(kind: kind, rows: rows, lines: next..<(next + lineCount)))
            next += lineCount
        }

        func addUnchanged(_ rows: Range<Int>) {
            guard !rows.isEmpty else { return }
            let keepBefore = rows.lowerBound == 0 ? 0 : context
            let keepAfter = rows.upperBound == diff.rowCount ? 0 : context
            let foldStart = rows.lowerBound + keepBefore
            let foldEnd = rows.upperBound - keepAfter
            if foldUnchanged, foldEnd - foldStart >= 4, !expandedFolds.contains(foldStart) {
                add(.same, rows: rows.lowerBound..<foldStart, lineCount: foldStart - rows.lowerBound)
                add(.fold, rows: foldStart..<foldEnd, lineCount: 1)
                add(.same, rows: foldEnd..<rows.upperBound, lineCount: rows.upperBound - foldEnd)
            } else {
                add(.same, rows: rows, lineCount: rows.count)
            }
        }

        var row = 0
        for (index, hunk) in diff.hunks.enumerated() {
            let start = diff.hunkRows[index]
            addUnchanged(row..<start)
            let rows = start..<(start + diff.rowCount(ofHunk: index))
            add(.hunk(index), rows: rows, lineCount: layout == .sideBySide ? rows.count : hunk.left.count + hunk.right.count)
            row = rows.upperBound
        }
        addUnchanged(row..<diff.rowCount)
        self.blocks = blocks
    }

    /// The block that holds a display line.
    public func block(containing line: Int) -> Int {
        var low = 0
        var high = blocks.count - 1
        while low < high {
            let middle = (low + high) / 2
            if blocks[middle].lines.upperBound > line { high = middle } else { low = middle + 1 }
        }
        return low
    }

    public subscript(line: Int) -> Line {
        let block = blocks[block(containing: line)]
        let offset = line - block.lines.lowerBound
        switch block.kind {
        case .same:
            return .row(block.rows.lowerBound + offset)
        case .fold:
            return .fold(block.rows)
        case .hunk(let index):
            guard layout == .unified else { return .row(block.rows.lowerBound + offset) }
            let leftCount = diff.hunks[index].left.count
            return offset < leftCount ? .removed(row: block.rows.lowerBound + offset) : .added(row: block.rows.lowerBound + offset - leftCount)
        }
    }

    /// The block that holds a diff row.
    public func block(containingRow row: Int) -> Int? {
        var low = 0
        var high = blocks.count
        while low < high {
            let middle = (low + high) / 2
            if blocks[middle].rows.upperBound > row { high = middle } else { low = middle + 1 }
        }
        return low < blocks.count && blocks[low].rows.contains(row) ? low : nil
    }

    /// The display line that shows a diff row, or nil when it is folded away. In unified, a
    /// changed row is on two lines; `side` picks one (the left one when nil).
    public func line(ofRow row: Int, side: DiffSide? = nil) -> Int? {
        guard let index = block(containingRow: row) else { return nil }
        let block = blocks[index]
        let offset = row - block.rows.lowerBound
        switch block.kind {
        case .same:
            return block.lines.lowerBound + offset
        case .fold:
            return nil
        case .hunk(let hunk):
            guard layout == .unified else { return block.lines.lowerBound + offset }
            let diffRow = diff.row(at: row, withSegments: false)
            let useRight = side == .right ? diffRow.right != nil : diffRow.left == nil
            return block.lines.lowerBound + (useRight ? diff.hunks[hunk].left.count + offset : offset)
        }
    }

    /// The display line that shows a line of one side, or nil when it is folded away.
    public func line(ofDocumentLine line: Int, on side: DiffSide) -> Int? {
        self.line(ofRow: diff.row(ofLine: line, on: side), side: side)
    }

    /// The fold that hides a diff row.
    public func fold(containingRow row: Int) -> Range<Int>? {
        guard let index = block(containingRow: row), blocks[index].kind == .fold else { return nil }
        return blocks[index].rows
    }

    /// The display lines of a hunk.
    public func lines(ofHunk hunk: Int) -> Range<Int>? {
        guard diff.hunks.indices.contains(hunk), let index = block(containingRow: diff.hunkRows[hunk]) else { return nil }
        return blocks[index].lines
    }
}
