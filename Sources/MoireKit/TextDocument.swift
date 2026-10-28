/// Text split into lines, remembering how it was written so it can be joined back exactly.
public struct TextDocument: Sendable, Hashable {
    public enum LineEnding: String, Sendable, Hashable {
        case lf = "\n"
        case crlf = "\r\n"
        case cr = "\r"
    }

    public var lines: Lines
    public var lineEnding: LineEnding
    /// Whether the last line ended with a line break.
    public var endsWithLineBreak: Bool

    public init(lines: Lines, lineEnding: LineEnding = .lf, endsWithLineBreak: Bool = true) {
        self.lines = lines
        self.lineEnding = lineEnding
        self.endsWithLineBreak = endsWithLineBreak
    }

    public init(lines: [String], lineEnding: LineEnding = .lf, endsWithLineBreak: Bool = true) {
        self.init(lines: Lines(lines), lineEnding: lineEnding, endsWithLineBreak: endsWithLineBreak)
    }

    /// Splits on `\r\n`, `\n` and `\r`. The most common break becomes the document's line ending.
    public init(_ text: String) {
        var text = text
        self = text.withUTF8 { TextDocument(LineBuffer(copying: UnsafeRawBufferPointer($0))) }
    }

    init(_ buffer: LineBuffer) {
        self.init(lines: Lines(buffer), lineEnding: buffer.lineEnding, endsWithLineBreak: buffer.endsWithLineBreak)
    }

    public var text: String {
        let bytes = utf8
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The text as UTF-8, joined with the document's line ending.
    public var utf8: [UInt8] {
        guard !lines.isEmpty else { return [] }
        let ending = Array(lineEnding.rawValue.utf8)
        var size = 0
        lines.forEachLine(in: 0..<lines.count) { _, bytes in size += bytes.count + ending.count }
        var result: [UInt8] = []
        result.reserveCapacity(size)
        lines.forEachLine(in: 0..<lines.count) { index, bytes in
            result.append(contentsOf: bytes)
            if index < lines.count - 1 || endsWithLineBreak { result.append(contentsOf: ending) }
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
