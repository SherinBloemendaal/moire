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

    func key(for line: String) -> String {
        var key = line
        switch whitespace {
        case .exact: break
        case .ignoreLeadingAndTrailing: key = key.trimmingSpacesAndTabs()
        case .ignoreAll: key.unicodeScalars.removeAll { $0 == " " || $0 == "\t" }
        }
        return ignoreCase ? key.lowercased() : key
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
    /// Only set for `.changed` rows.
    public var leftSegments: [Segment]?
    public var rightSegments: [Segment]?
}

public struct DiffStatistics: Sendable, Hashable {
    public var added = 0
    public var removed = 0
    public var changed = 0

    public var isIdentical: Bool { added == 0 && removed == 0 && changed == 0 }
}

public struct LineDiff: Sendable {
    public let left: TextDocument
    public let right: TextDocument
    public let options: DiffOptions
    public let rows: [DiffRow]
    public let hunks: [Hunk]
    /// For each hunk, the index of its first row in `rows`.
    public let hunkRows: [Int]
    public let statistics: DiffStatistics

    public init(left: TextDocument, right: TextDocument, options: DiffOptions = DiffOptions()) {
        self.left = left
        self.right = right
        self.options = options

        // Interning makes line comparison an integer compare inside Myers.
        var ids: [String: Int] = [:]
        func id(_ line: String) -> Int {
            let key = options.key(for: line)
            if let existing = ids[key] { return existing }
            let new = ids.count
            ids[key] = new
            return new
        }
        let leftIDs = left.lines.map(id)
        let rightIDs = right.lines.map(id)

        var rows: [DiffRow] = []
        var hunks: [Hunk] = []
        var hunkRows: [Int] = []
        var statistics = DiffStatistics()
        var l = 0
        var r = 0
        let operations = Myers.diff(leftIDs, rightIDs)
        var index = 0

        while index < operations.count {
            if operations[index] == .equal {
                rows.append(DiffRow(kind: .same, left: l, right: r))
                l += 1
                r += 1
                index += 1
                continue
            }

            var deleted = 0
            var inserted = 0
            while index < operations.count, operations[index] != .equal {
                if operations[index] == .delete { deleted += 1 } else { inserted += 1 }
                index += 1
            }

            let hunkIndex = hunks.count
            hunks.append(Hunk(left: l..<(l + deleted), right: r..<(r + inserted)))
            hunkRows.append(rows.count)

            let paired = min(deleted, inserted)
            for offset in 0..<paired {
                let (leftSegments, rightSegments) = InlineDiff.segments(left.lines[l + offset], right.lines[r + offset], options: options)
                rows.append(DiffRow(
                    kind: .changed, left: l + offset, right: r + offset, hunk: hunkIndex,
                    leftSegments: leftSegments, rightSegments: rightSegments
                ))
            }
            for offset in paired..<max(paired, deleted) {
                rows.append(DiffRow(kind: .removed, left: l + offset, right: nil, hunk: hunkIndex))
            }
            for offset in paired..<max(paired, inserted) {
                rows.append(DiffRow(kind: .added, left: nil, right: r + offset, hunk: hunkIndex))
            }

            statistics.changed += paired
            statistics.removed += deleted - paired
            statistics.added += inserted - paired
            l += deleted
            r += inserted
        }

        self.rows = rows
        self.hunks = hunks
        self.hunkRows = hunkRows
        self.statistics = statistics
    }

    /// The document on the receiving side with one hunk copied over from the other side.
    public func copying(hunk index: Int, toRight: Bool) -> TextDocument {
        let hunk = hunks[index]
        if toRight {
            var target = right
            target.lines.replaceSubrange(hunk.right, with: left.lines[hunk.left])
            return target
        } else {
            var target = left
            target.lines.replaceSubrange(hunk.left, with: right.lines[hunk.right])
            return target
        }
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

extension String {
    func trimmingSpacesAndTabs() -> String {
        let scalars = unicodeScalars
        guard let start = scalars.firstIndex(where: { $0 != " " && $0 != "\t" }) else { return "" }
        let end = scalars.lastIndex { $0 != " " && $0 != "\t" } ?? start
        return String(scalars[start...end])
    }
}
