/// A three-way merge of two versions of a file that share a common base, in the style of diff3.
///
/// Both sides are compared with the base. A base line that both sides kept is stable; the runs
/// between stable lines are the chunks where at least one side changed something. A chunk that
/// only one side changed, or that both changed the same way, merges by itself. A chunk that both
/// sides changed differently is a conflict, which needs a `Resolution`.
public struct ThreeWayMerge: Sendable {
    public struct Chunk: Sendable, Hashable {
        public enum Kind: Sendable, Hashable {
            /// All three versions agree.
            case unchanged
            /// Only the left side changed these lines.
            case changedLeft
            /// Only the right side changed these lines.
            case changedRight
            /// Both sides made the same change.
            case changedBoth
            /// Both sides changed these lines, each in its own way.
            case conflict
        }

        public var kind: Kind
        public var base: Range<Int>
        public var left: Range<Int>
        public var right: Range<Int>

        public init(kind: Kind, base: Range<Int>, left: Range<Int>, right: Range<Int>) {
            self.kind = kind
            self.base = base
            self.left = left
            self.right = right
        }
    }

    /// How a chunk ends up in the result.
    public enum Resolution: Sendable, Hashable {
        case left
        case right
        case base
        case leftThenRight
        case rightThenLeft
        /// Lines typed by hand.
        case edited([TextLine])

        /// Text typed by hand, split into lines the way a file would be.
        public static func edited(text: String) -> Resolution {
            .edited(TextDocument(text).textLines)
        }
    }

    public enum Version: Sendable, Hashable, CaseIterable {
        case base, left, right
    }

    /// The names written into the conflict markers.
    public struct Labels: Sendable, Hashable {
        public var left: String
        public var base: String
        public var right: String

        public init(left: String = "LEFT", base: String = "BASE", right: String = "RIGHT") {
            self.left = left
            self.base = base
            self.right = right
        }
    }

    public let base: [TextLine]
    public let left: [TextLine]
    public let right: [TextLine]
    /// The line ending of the result: the left side's, unless it is empty.
    public let lineEnding: TextDocument.LineEnding
    public let chunks: [Chunk]
    /// Indexes into `chunks` of every conflict, in order.
    public let conflicts: [Int]

    public init(base: TextDocument, left: TextDocument, right: TextDocument) {
        self.base = base.textLines
        self.left = left.textLines
        self.right = right.textLines
        lineEnding = [left, right, base].first { !$0.lines.isEmpty }?.lineEnding ?? left.lineEnding

        var interner = TextLineInterner()
        let baseIDs = interner.ids(for: self.base)
        let leftIDs = interner.ids(for: self.left)
        let rightIDs = interner.ids(for: self.right)
        let chunks = Self.chunks(base: baseIDs, left: leftIDs, right: rightIDs)
        self.chunks = chunks
        conflicts = chunks.indices.filter { chunks[$0].kind == .conflict }
    }

    public func lines(of version: Version, in chunk: Int) -> ArraySlice<TextLine> {
        let chunk = chunks[chunk]
        return switch version {
        case .base: base[chunk.base]
        case .left: left[chunk.left]
        case .right: right[chunk.right]
        }
    }

    /// What a chunk puts into the result. Without a resolution, a chunk that is not a conflict
    /// takes the side that changed it; a conflict without one has no lines yet and gives `nil`.
    public func resolvedLines(of chunk: Int, resolution: Resolution?) -> [TextLine]? {
        guard let resolution = resolution ?? automaticResolution(of: chunk) else { return nil }
        return switch resolution {
        case .left: Array(lines(of: .left, in: chunk))
        case .right: Array(lines(of: .right, in: chunk))
        case .base: Array(lines(of: .base, in: chunk))
        case .leftThenRight: Array(lines(of: .left, in: chunk)) + lines(of: .right, in: chunk)
        case .rightThenLeft: Array(lines(of: .right, in: chunk)) + lines(of: .left, in: chunk)
        case .edited(let lines): lines
        }
    }

    public func automaticResolution(of chunk: Int) -> Resolution? {
        switch chunks[chunk].kind {
        case .unchanged, .changedLeft, .changedBoth: .left
        case .changedRight: .right
        case .conflict: nil
        }
    }

    public func unresolvedConflicts(_ resolutions: [Int: Resolution]) -> [Int] {
        conflicts.filter { resolutions[$0] == nil }
    }

    /// The merged lines. A conflict without a resolution is written with diff3-style markers
    /// around all three versions, the way `git merge` leaves it.
    public func resultLines(_ resolutions: [Int: Resolution], labels: Labels = Labels()) -> [TextLine] {
        var result: [TextLine] = []
        for index in chunks.indices {
            if let lines = resolvedLines(of: index, resolution: resolutions[index]) {
                result.append(contentsOf: lines)
                continue
            }
            func terminated(_ lines: ArraySlice<TextLine>) -> [TextLine] {
                lines.map { TextLine($0.text) }
            }
            result.append(TextLine("<<<<<<< \(labels.left)"))
            result.append(contentsOf: terminated(lines(of: .left, in: index)))
            result.append(TextLine("||||||| \(labels.base)"))
            result.append(contentsOf: terminated(lines(of: .base, in: index)))
            result.append(TextLine("======="))
            result.append(contentsOf: terminated(lines(of: .right, in: index)))
            result.append(TextLine(">>>>>>> \(labels.right)"))
        }
        return result
    }

    public func result(_ resolutions: [Int: Resolution], labels: Labels = Labels()) -> TextDocument {
        TextDocument(textLines: resultLines(resolutions, labels: labels), lineEnding: lineEnding)
    }

    // MARK: Chunks

    private static func chunks(base: [Int], left: [Int], right: [Int]) -> [Chunk] {
        let leftMatch = matches(base, left)
        let rightMatch = matches(base, right)
        var chunks: [Chunk] = []
        var b = 0, l = 0, r = 0

        func append(_ chunk: Chunk) {
            if chunk.kind == .unchanged, let last = chunks.last, last.kind == .unchanged {
                chunks[chunks.count - 1] = Chunk(
                    kind: .unchanged,
                    base: last.base.lowerBound..<chunk.base.upperBound,
                    left: last.left.lowerBound..<chunk.left.upperBound,
                    right: last.right.lowerBound..<chunk.right.upperBound
                )
            } else {
                chunks.append(chunk)
            }
        }

        while b < base.count || l < left.count || r < right.count {
            if b < base.count, leftMatch[b] == l, rightMatch[b] == r {
                append(Chunk(kind: .unchanged, base: b..<(b + 1), left: l..<(l + 1), right: r..<(r + 1)))
                b += 1; l += 1; r += 1
                continue
            }

            // The next base line that both sides kept closes this chunk; without one it runs to the end.
            var next = b
            var leftEnd = left.count
            var rightEnd = right.count
            while next < base.count {
                if let leftIndex = leftMatch[next], let rightIndex = rightMatch[next] {
                    leftEnd = leftIndex
                    rightEnd = rightIndex
                    break
                }
                next += 1
            }

            let baseSlice = base[b..<next]
            let leftSlice = left[l..<leftEnd]
            let rightSlice = right[r..<rightEnd]
            let kind: Chunk.Kind = if leftSlice.elementsEqual(baseSlice), rightSlice.elementsEqual(baseSlice) {
                .unchanged
            } else if leftSlice.elementsEqual(baseSlice) {
                .changedRight
            } else if rightSlice.elementsEqual(baseSlice) {
                .changedLeft
            } else if leftSlice.elementsEqual(rightSlice) {
                .changedBoth
            } else {
                .conflict
            }
            append(Chunk(kind: kind, base: b..<next, left: l..<leftEnd, right: r..<rightEnd))
            b = next; l = leftEnd; r = rightEnd
        }
        return chunks
    }

    /// For every element of `a`, the index of the element of `b` it is matched with, if any.
    private static func matches(_ a: [Int], _ b: [Int]) -> [Int?] {
        var result = [Int?](repeating: nil, count: a.count)
        var i = 0, j = 0
        for operation in Myers.diff(a, b) {
            switch operation {
            case .equal:
                result[i] = j
                i += 1; j += 1
            case .delete: i += 1
            case .insert: j += 1
            }
        }
        return result
    }
}
