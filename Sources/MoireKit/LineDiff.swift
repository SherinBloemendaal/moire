/// What counts as "the same line".
public struct DiffOptions: Sendable, Hashable {
    public enum Whitespace: String, Sendable, Hashable, CaseIterable {
        /// Every space counts.
        case exact
        /// Spaces and tabs at the start and end of a line are ignored.
        case ignoreLeadingAndTrailing
        /// All spaces and tabs are ignored.
        case ignoreAll
    }

    public var whitespace: Whitespace
    public var ignoreCase: Bool

    public init(whitespace: Whitespace = .exact, ignoreCase: Bool = false) {
        self.whitespace = whitespace
        self.ignoreCase = ignoreCase
    }

    /// One piece of text as these options compare it, for comparisons that work on strings
    /// (table cells). Lines are compared byte by byte by `LineInterner` instead.
    func key(for text: String) -> String {
        var key = text
        switch whitespace {
        case .exact: break
        case .ignoreLeadingAndTrailing: key = key.trimmingSpacesAndTabs()
        case .ignoreAll: key.unicodeScalars.removeAll { $0 == " " || $0 == "\t" }
        }
        return ignoreCase ? key.lowercased() : key
    }
}

extension String {
    func trimmingSpacesAndTabs() -> String {
        let scalars = unicodeScalars
        guard let start = scalars.firstIndex(where: { $0 != " " && $0 != "\t" }) else { return "" }
        let end = scalars.lastIndex { $0 != " " && $0 != "\t" } ?? start
        return String(scalars[start...end])
    }
}

/// A run of lines that differ: `left` lines of the left side are replaced by `right` lines of the
/// right side. One of the ranges can be empty (lines only added, or only removed).
public struct Hunk: Sendable, Hashable {
    public var left: Range<Int>
    public var right: Range<Int>

    public init(left: Range<Int>, right: Range<Int>) {
        self.left = left
        self.right = right
    }
}

/// A piece of a line, marked when it differs from the line it is paired with.
public struct Segment: Sendable, Hashable {
    public var text: String
    public var isChanged: Bool

    public init(_ text: String, isChanged: Bool) {
        self.text = text
        self.isChanged = isChanged
    }
}

/// One row of a side-by-side view: a line on the left, on the right, or both.
public struct DiffRow: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// The same on both sides (under the chosen options).
        case same
        /// A line that was changed: shown next to its new version, with the changed words marked.
        case changed
        /// Only on the left.
        case removed
        /// Only on the right.
        case added
    }

    public var kind: Kind
    /// Line indexes into the left and right document.
    public var left: Int?
    public var right: Int?
    /// The hunk this row belongs to, for rows that are not `.same`.
    public var hunk: Int?
    /// Only set for `.changed` rows read from `LineDiff.rows`.
    public var leftSegments: [Segment]?
    public var rightSegments: [Segment]?

    public func line(on side: DiffSide) -> Int? { side == .left ? left : right }
}

/// One of the two sides of a comparison.
public enum DiffSide: Sendable, Hashable, CaseIterable {
    case left, right

    public var other: DiffSide { self == .left ? .right : .left }
}

public struct DiffStatistics: Sendable, Hashable {
    public var added = 0
    public var removed = 0
    public var changed = 0

    public var isIdentical: Bool { added == 0 && removed == 0 && changed == 0 }

    public init(added: Int = 0, removed: Int = 0, changed: Int = 0) {
        self.added = added
        self.removed = removed
        self.changed = changed
    }
}

/// A line on the left and a line on the right that the user wants on one row. The comparison
/// is worked out separately above, between and below anchors.
public struct LineAnchor: Sendable, Hashable {
    public var left: Int
    public var right: Int

    public init(left: Int, right: Int) {
        self.left = left
        self.right = right
    }

    public func line(on side: DiffSide) -> Int { side == .left ? left : right }

    /// The anchors that can be used together: inside both documents, sorted, and never
    /// crossing (an anchor lower on the left is also lower on the right).
    public static func normalized(_ anchors: [LineAnchor], leftCount: Int, rightCount: Int) -> [LineAnchor] {
        var result: [LineAnchor] = []
        for anchor in anchors.sorted(by: { ($0.left, $0.right) < ($1.left, $1.right) })
        where anchor.left >= 0 && anchor.left < leftCount && anchor.right >= 0 && anchor.right < rightCount {
            if let last = result.last, anchor.left <= last.left || anchor.right <= last.right { continue }
            result.append(anchor)
        }
        return result
    }

    /// `anchors` with `new` added. Anchors that share a line with it or cross it make way.
    public static func adding(_ new: LineAnchor, to anchors: [LineAnchor]) -> [LineAnchor] {
        var result = anchors.filter { anchor in
            anchor.left != new.left && anchor.right != new.right && (anchor.left < new.left) == (anchor.right < new.right)
        }
        result.append(new)
        return result.sorted { $0.left < $1.left }
    }

    /// Where the anchor ends up after `edit`. Nil when its line on the edited side was removed.
    public func adjusted(for edit: LineEdit) -> LineAnchor? {
        guard let line = edit.map(line: line(on: edit.side)) else { return nil }
        return edit.side == .left ? LineAnchor(left: line, right: right) : LineAnchor(left: left, right: line)
    }
}

public struct LineDiff: Sendable {
    public let left: TextDocument
    public let right: TextDocument
    public let options: DiffOptions
    /// The anchors that were used, after `LineAnchor.normalized`.
    public let anchors: [LineAnchor]
    public let hunks: [Hunk]
    /// For each hunk, the index of its first row in `rows`.
    public let hunkRows: [Int]
    public let statistics: DiffStatistics
    public let rowCount: Int

    /// Every row, worked out from the hunks when it is read, so millions of unchanged lines take
    /// no memory. Changed rows come with their changed words marked.
    public var rows: Rows { Rows(diff: self) }

    public init(left: TextDocument, right: TextDocument, options: DiffOptions = DiffOptions(), anchors: [LineAnchor] = []) {
        self.left = left
        self.right = right
        self.options = options
        let anchors = LineAnchor.normalized(anchors, leftCount: left.lines.count, rightCount: right.lines.count)
        self.anchors = anchors

        let (leftIDs, rightIDs) = LineInterner.ids(left.lines, right.lines, options: options)
        var builder = Builder()
        var marks = Myers.InternedMarks(idCount: leftIDs.count + rightIDs.count)
        var leftStart = 0
        var rightStart = 0
        for anchor in anchors + [LineAnchor(left: leftIDs.count, right: rightIDs.count)] {
            let operations = Myers.diff(ids: leftIDs[leftStart..<anchor.left], rightIDs[rightStart..<anchor.right], marks: &marks)
            builder.add(operations)
            guard anchor.left < leftIDs.count else { break }
            if leftIDs[anchor.left] == rightIDs[anchor.right] {
                builder.add([.equal])
            } else {
                // On its own, so it is paired with the anchored line and nothing else.
                builder.addHunk(deleted: 1, inserted: 1)
            }
            leftStart = anchor.left + 1
            rightStart = anchor.right + 1
        }

        hunks = builder.hunks
        hunkRows = builder.hunkRows
        statistics = builder.statistics
        rowCount = builder.rowCount
    }

    private struct Builder {
        var hunks: [Hunk] = []
        var hunkRows: [Int] = []
        var statistics = DiffStatistics()
        var rowCount = 0
        var l = 0
        var r = 0

        mutating func add(_ operations: [EditOperation]) {
            var index = 0
            while index < operations.count {
                if operations[index] == .equal {
                    var end = index
                    while end < operations.count, operations[end] == .equal { end += 1 }
                    let run = end - index
                    l += run
                    r += run
                    rowCount += run
                    index = end
                    continue
                }
                var deleted = 0
                var inserted = 0
                while index < operations.count, operations[index] != .equal {
                    if operations[index] == .delete { deleted += 1 } else { inserted += 1 }
                    index += 1
                }
                addHunk(deleted: deleted, inserted: inserted)
            }
        }

        mutating func addHunk(deleted: Int, inserted: Int) {
            hunks.append(Hunk(left: l..<(l + deleted), right: r..<(r + inserted)))
            hunkRows.append(rowCount)
            let paired = min(deleted, inserted)
            statistics.changed += paired
            statistics.removed += deleted - paired
            statistics.added += inserted - paired
            rowCount += max(deleted, inserted)
            l += deleted
            r += inserted
        }
    }

    public struct Rows: RandomAccessCollection, Sendable {
        let diff: LineDiff
        public var startIndex: Int { 0 }
        public var endIndex: Int { diff.rowCount }
        public subscript(position: Int) -> DiffRow { diff.row(at: position) }
    }

    /// The number of rows a hunk takes up.
    public func rowCount(ofHunk index: Int) -> Int {
        max(hunks[index].left.count, hunks[index].right.count)
    }

    /// The hunk a row belongs to, if any.
    public func hunk(containingRow row: Int) -> Int? {
        guard let index = lastHunk(startingAtOrBefore: row) else { return nil }
        return row < hunkRows[index] + rowCount(ofHunk: index) ? index : nil
    }

    private func lastHunk(startingAtOrBefore row: Int) -> Int? {
        var low = 0
        var high = hunkRows.count
        while low < high {
            let middle = (low + high) / 2
            if hunkRows[middle] <= row { low = middle + 1 } else { high = middle }
        }
        return low == 0 ? nil : low - 1
    }

    /// One row. Without `withSegments` the changed words are not worked out, which is what a
    /// list that only needs the line numbers wants.
    public func row(at index: Int, withSegments: Bool = true) -> DiffRow {
        precondition(index >= 0 && index < rowCount, "Row \(index) is out of range")
        guard let hunkIndex = lastHunk(startingAtOrBefore: index) else {
            return DiffRow(kind: .same, left: index, right: index)
        }
        let hunk = hunks[hunkIndex]
        let offset = index - hunkRows[hunkIndex]
        let length = rowCount(ofHunk: hunkIndex)
        guard offset < length else {
            let after = offset - length
            return DiffRow(kind: .same, left: hunk.left.upperBound + after, right: hunk.right.upperBound + after)
        }
        let paired = min(hunk.left.count, hunk.right.count)
        if offset < paired {
            var row = DiffRow(kind: .changed, left: hunk.left.lowerBound + offset, right: hunk.right.lowerBound + offset, hunk: hunkIndex)
            if withSegments, let segments = segments(forRow: row) {
                row.leftSegments = segments.left
                row.rightSegments = segments.right
            }
            return row
        }
        if hunk.left.count > hunk.right.count {
            return DiffRow(kind: .removed, left: hunk.left.lowerBound + offset, right: nil, hunk: hunkIndex)
        }
        return DiffRow(kind: .added, left: nil, right: hunk.right.lowerBound + offset, hunk: hunkIndex)
    }

    /// The changed words of a `.changed` row.
    public func segments(forRow row: DiffRow) -> (left: [Segment], right: [Segment])? {
        guard row.kind == .changed, let leftLine = row.left, let rightLine = row.right else { return nil }
        let (leftSegments, rightSegments) = InlineDiff.segments(left.lines[leftLine], right.lines[rightLine], options: options)
        return (leftSegments, rightSegments)
    }

    /// The row that shows a line of one side.
    public func row(ofLine line: Int, on side: DiffSide) -> Int {
        var low = 0
        var high = hunks.count
        while low < high {
            let middle = (low + high) / 2
            if range(of: hunks[middle], on: side).lowerBound <= line { low = middle + 1 } else { high = middle }
        }
        guard low > 0 else { return line }
        let index = low - 1
        let range = range(of: hunks[index], on: side)
        if range.contains(line) { return hunkRows[index] + line - range.lowerBound }
        return hunkRows[index] + rowCount(ofHunk: index) + line - range.upperBound
    }

    private func range(of hunk: Hunk, on side: DiffSide) -> Range<Int> {
        side == .left ? hunk.left : hunk.right
    }

    // MARK: Merging

    /// The edit that copies one hunk over to the other side. `toRight` copies the left version.
    public func edit(copyingHunk index: Int, toRight: Bool) -> LineEdit {
        let hunk = hunks[index]
        if toRight {
            return LineEdit(side: .right, range: hunk.right, lines: Lines(pieces: left.lines.pieces(in: hunk.left)))
        }
        return LineEdit(side: .left, range: hunk.left, lines: Lines(pieces: right.lines.pieces(in: hunk.right)))
    }

    /// The edit that makes one row of a hunk the same on the receiving side: a changed line is
    /// replaced, a line the other side lacks is inserted after that side's lines of the hunk, and
    /// a line only the receiving side has is removed. Nil for an unchanged row.
    public func edit(copyingRow index: Int, toRight: Bool) -> LineEdit? {
        let row = row(at: index, withSegments: false)
        guard let hunkIndex = row.hunk else { return nil }
        let hunk = hunks[hunkIndex]
        let source: DiffSide = toRight ? .left : .right
        let target = source.other
        let sourceDocument = toRight ? left : right
        let targetHunk = range(of: hunk, on: target)
        switch (row.line(on: source), row.line(on: target)) {
        case (let from?, let to?):
            return LineEdit(side: target, range: to..<(to + 1), lines: Lines(pieces: sourceDocument.lines.pieces(in: from..<(from + 1))))
        case (let from?, nil):
            let at = targetHunk.upperBound
            return LineEdit(side: target, range: at..<at, lines: Lines(pieces: sourceDocument.lines.pieces(in: from..<(from + 1))))
        case (nil, let to?):
            return LineEdit(side: target, range: to..<(to + 1), lines: [])
        case (nil, nil):
            return nil
        }
    }

    /// The document on the receiving side with one hunk copied over from the other side.
    public func copying(hunk index: Int, toRight: Bool) -> TextDocument {
        (toRight ? right : left).applying(edit(copyingHunk: index, toRight: toRight))
    }

    /// The document on the receiving side with one row copied over from the other side.
    public func copying(row index: Int, toRight: Bool) -> TextDocument {
        let target = toRight ? right : left
        guard let edit = edit(copyingRow: index, toRight: toRight) else { return target }
        return target.applying(edit)
    }
}

/// Marks the words that changed between two versions of one line.
public enum InlineDiff {
    public static func segments(_ left: String, _ right: String, options: DiffOptions = DiffOptions()) -> ([Segment], [Segment]) {
        let leftTokens = tokens(left)
        let rightTokens = tokens(right)
        let leftKeys = leftTokens.map { key($0, options) }
        let rightKeys = rightTokens.map { key($0, options) }

        var leftSegments: [Segment] = []
        var rightSegments: [Segment] = []
        var l = 0
        var r = 0
        for operation in Myers.diff(leftKeys, rightKeys) {
            switch operation {
            case .equal:
                append(leftTokens[l], changed: false, to: &leftSegments)
                append(rightTokens[r], changed: false, to: &rightSegments)
                l += 1
                r += 1
            case .delete:
                append(leftTokens[l], changed: true, to: &leftSegments)
                l += 1
            case .insert:
                append(rightTokens[r], changed: true, to: &rightSegments)
                r += 1
            }
        }
        return (leftSegments, rightSegments)
    }

    /// Words (letters, digits and `_`), runs of spaces, and every other character on its own.
    static func tokens(_ line: String) -> [String] {
        enum Class { case word, space, other }
        func classify(_ character: Character) -> Class {
            if character == " " || character == "\t" { return .space }
            if character.isLetter || character.isNumber || character == "_" { return .word }
            return .other
        }

        var tokens: [String] = []
        var current = ""
        var currentClass: Class?
        for character in line {
            let characterClass = classify(character)
            if characterClass == currentClass, characterClass != .other {
                current.append(character)
            } else {
                if !current.isEmpty { tokens.append(current) }
                current = String(character)
                currentClass = characterClass
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private static func key(_ token: String, _ options: DiffOptions) -> String {
        var key = token
        if options.whitespace != .exact, key.allSatisfy({ $0 == " " || $0 == "\t" }) {
            // Inside a changed line, a different amount of spacing is not worth marking then.
            key = " "
        }
        return options.ignoreCase ? key.lowercased() : key
    }

    private static func append(_ text: String, changed: Bool, to segments: inout [Segment]) {
        if let last = segments.last, last.isChanged == changed {
            segments[segments.count - 1].text += text
        } else {
            segments.append(Segment(text, isChanged: changed))
        }
    }
}
