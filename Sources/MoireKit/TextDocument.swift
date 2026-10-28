/// Text split into lines, remembering how it was written so it can be joined back exactly.
public struct TextDocument: Sendable {
    public enum LineEnding: String, Sendable, Hashable {
        case lf = "\n"
        case crlf = "\r\n"
        case cr = "\r"
    }

    public var lines: Lines
    /// The break of new lines, and of every line when written back after it changed.
    public var lineEnding: LineEnding {
        didSet { if lineEnding != oldValue { ownBuffers = [] } }
    }
    /// Whether the last line ended with a line break.
    public var endsWithLineBreak: Bool
    /// The texts this document was read from. Their lines are written back with the break they
    /// were read with, so a file with mixed breaks keeps them; lines typed, or copied in from
    /// another document, get `lineEnding`.
    private(set) var ownBuffers: [LineBuffer] = []

    public init(lines: Lines, lineEnding: LineEnding = .lf, endsWithLineBreak: Bool = true) {
        self.lines = lines
        self.lineEnding = lineEnding
        self.endsWithLineBreak = endsWithLineBreak
    }

    init(lines: Lines, lineEnding: LineEnding, endsWithLineBreak: Bool, ownBuffers: [LineBuffer]) {
        self.init(lines: lines, lineEnding: lineEnding, endsWithLineBreak: endsWithLineBreak)
        self.ownBuffers = ownBuffers
    }

    public init(lines: [String], lineEnding: LineEnding = .lf, endsWithLineBreak: Bool = true) {
        self.init(lines: Lines(lines), lineEnding: lineEnding, endsWithLineBreak: endsWithLineBreak)
    }

    /// Splits on `\r\n` and `\n`, and on a lone `\r` when that is the most common break. The
    /// most common break becomes the document's line ending.
    public init(_ text: String) {
        var text = text
        self = text.withUTF8 { TextDocument(LineBuffer(copying: UnsafeRawBufferPointer($0))) }
    }

    init(_ buffer: LineBuffer) {
        self.init(lines: Lines(buffer), lineEnding: buffer.lineEnding, endsWithLineBreak: buffer.endsWithLineBreak, ownBuffers: [buffer])
    }

    public var text: String {
        let bytes = utf8
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The text as UTF-8. Lines read from this document's own text keep their exact bytes and
    /// line break; other lines are joined with the document's line ending.
    public var utf8: [UInt8] {
        guard !lines.isEmpty else { return [] }
        let ending = Array(lineEnding.rawValue.utf8)
        var size = 0
        for piece in lines.pieces {
            switch piece {
            case .buffer(let buffer, let range):
                size += buffer.starts[range.upperBound] - buffer.starts[range.lowerBound] + ending.count
            case .strings(let strings):
                for string in strings { size += string.utf8.count + ending.count }
            }
        }
        var result: [UInt8] = []
        result.reserveCapacity(size)
        var line = 0
        let lastLine = lines.count - 1
        for piece in lines.pieces {
            let holdsLast = line + piece.count - 1 == lastLine
            switch piece {
            case .buffer(let buffer, let range):
                let isOwn = ownBuffers.contains { $0 === buffer }
                buffer.append(range, to: &result, ending: lineEnding, keepingBreaks: isOwn, breakAfterLast: !holdsLast || endsWithLineBreak)
            case .strings(let strings):
                for (offset, string) in strings.enumerated() {
                    result.append(contentsOf: string.utf8)
                    if line + offset < lastLine || endsWithLineBreak { result.append(contentsOf: ending) }
                }
            }
            line += piece.count
        }
        return result
    }

    /// The document with `edit` applied. The edit's side is not checked.
    public func applying(_ edit: LineEdit) -> TextDocument {
        var copy = self
        copy.apply(edit)
        return copy
    }

    public mutating func apply(_ edit: LineEdit) {
        let range = edit.range.clamped(to: 0..<lines.count)
        lines.replaceSubrange(range, with: edit.lines)
    }
}

extension TextDocument: Hashable {
    /// Equal documents write the same bytes. Only a document that keeps mixed line breaks needs
    /// its bytes compared; otherwise every line gets the document's line ending.
    public static func == (lhs: TextDocument, rhs: TextDocument) -> Bool {
        guard lhs.lineEnding == rhs.lineEnding, lhs.endsWithLineBreak == rhs.endsWithLineBreak, lhs.lines == rhs.lines else { return false }
        let keepsMixedBreaks = (lhs.ownBuffers + rhs.ownBuffers).contains(where: \.hasMixedBreaks)
        return !keepsMixedBreaks || lhs.utf8 == rhs.utf8
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(lines)
        hasher.combine(lineEnding)
        hasher.combine(endsWithLineBreak)
    }
}

/// Lines `range` of one side replaced by `lines`. Inserting has an empty range, deleting no lines.
public struct LineEdit: Sendable, Hashable {
    public var side: DiffSide
    public var range: Range<Int>
    public var lines: Lines

    public init(side: DiffSide, range: Range<Int>, lines: Lines) {
        self.side = side
        self.range = range
        self.lines = lines
    }

    /// The edit that puts `document` back the way it was before this edit.
    public func inverse(in document: TextDocument) -> LineEdit {
        let range = range.clamped(to: 0..<document.lines.count)
        return LineEdit(side: side, range: range.lowerBound..<(range.lowerBound + lines.count), lines: Lines(pieces: document.lines.pieces(in: range)))
    }

    /// Where a line of the edited side ends up. Nil when the edit removed it; a line that was
    /// replaced one for one keeps its place.
    public func map(line: Int) -> Int? {
        if line < range.lowerBound { return line }
        if line >= range.upperBound { return line + lines.count - range.count }
        return lines.count == range.count ? line : nil
    }
}
