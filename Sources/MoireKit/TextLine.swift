/// One line of a document together with whether it ends in a line break. Only the last line
/// of a file can lack one, and keeping that on the line makes a missing final break a change
/// like any other.
public struct TextLine: Sendable, Hashable {
    public var text: String
    public var hasLineBreak: Bool

    public init(_ text: String, hasLineBreak: Bool = true) {
        self.text = text
        self.hasLineBreak = hasLineBreak
    }
}

extension TextDocument {
    public var textLines: [TextLine] {
        lines.indices.map { TextLine(lines[$0], hasLineBreak: $0 < lines.count - 1 || endsWithLineBreak) }
    }

    /// Joins lines back into a document. A line without a break that is not the last one gets
    /// a break, since the next line has to start somewhere.
    public init(textLines: [TextLine], lineEnding: LineEnding) {
        self.init(lines: textLines.map(\.text), lineEnding: lineEnding, endsWithLineBreak: textLines.last?.hasLineBreak ?? true)
    }
}

/// Gives every distinct line a small integer, so Myers compares integers instead of strings.
struct LineInterner {
    private var ids: [TextLine: Int] = [:]

    mutating func ids(for lines: [TextLine]) -> [Int] {
        lines.map { line in
            if let existing = ids[line] { return existing }
            let new = ids.count
            ids[line] = new
            return new
        }
    }
}
