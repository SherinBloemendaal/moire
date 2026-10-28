/// The lines of a document, as a list of pieces: runs of lines in a shared `LineBuffer` (a file
/// as it was read) and runs of strings (lines that were typed or replaced). Editing one line of
/// a file with millions of lines only splits a piece; copying lines between documents copies
/// pieces, not text.
public struct Lines: Sendable {
    enum Piece: Sendable {
        case buffer(LineBuffer, Range<Int>)
        case strings(ArraySlice<String>)

        var count: Int {
            switch self {
            case .buffer(_, let range): range.count
            case .strings(let strings): strings.count
            }
        }

        func slice(_ range: Range<Int>) -> Piece {
            switch self {
            case .buffer(let buffer, let lines):
                .buffer(buffer, (lines.lowerBound + range.lowerBound)..<(lines.lowerBound + range.upperBound))
            case .strings(let strings):
                .strings(strings[(strings.startIndex + range.lowerBound)..<(strings.startIndex + range.upperBound)])
            }
        }
    }

    private(set) var pieces: [Piece]
    /// `ends[i]` is the number of lines in pieces `0...i`.
    private var ends: [Int]

    public init() {
        pieces = []
        ends = []
    }

    init(_ buffer: LineBuffer) {
        self.init(pieces: [.buffer(buffer, 0..<buffer.lineCount)])
    }

    init(pieces: [Piece]) {
        self.pieces = []
        ends = []
        setPieces(pieces)
    }

    private mutating func setPieces(_ newPieces: [Piece]) {
        var merged: [Piece] = []
        merged.reserveCapacity(newPieces.count)
        for piece in newPieces where piece.count > 0 {
            guard let last = merged.last else {
                merged.append(piece)
                continue
            }
            switch (last, piece) {
            case (.buffer(let a, let first), .buffer(let b, let second)) where a === b && first.upperBound == second.lowerBound:
                merged[merged.count - 1] = .buffer(a, first.lowerBound..<second.upperBound)
            case (.strings(let first), .strings(let second)) where first.count + second.count <= 4096:
                merged[merged.count - 1] = .strings(ArraySlice(Array(first) + Array(second)))
            default:
                merged.append(piece)
            }
        }
        pieces = merged
        var total = 0
        ends = merged.map { piece in
            total += piece.count
            return total
        }
    }

    /// The piece that holds `line`, and the line's position inside it.
    @inline(__always)
    private func locate(_ line: Int) -> (piece: Int, offset: Int) {
        precondition(line >= 0 && line < count, "Line \(line) is out of range")
        if pieces.count == 1 { return (0, line) }
        var low = 0
        var high = ends.count - 1
        while low < high {
            let middle = (low + high) / 2
            if ends[middle] > line { high = middle } else { low = middle + 1 }
        }
        return (low, line - (low == 0 ? 0 : ends[low - 1]))
    }

    /// Calls `body` with the UTF-8 bytes of a line, without its line break.
    @inline(__always)
    func withBytes<R>(of line: Int, _ body: (UnsafeBufferPointer<UInt8>) throws -> R) rethrows -> R {
        let (piece, offset) = locate(line)
        switch pieces[piece] {
        case .buffer(let buffer, let lines):
            return try body(buffer.bytes(of: lines.lowerBound + offset))
        case .strings(let strings):
            var string = strings[strings.startIndex + offset]
            return try string.withUTF8(body)
        }
    }

    /// Calls `body` for every line in `range` with its index and bytes, walking the pieces in
    /// order instead of looking every line up.
    func forEachLine(in range: Range<Int>, _ body: (Int, UnsafeBufferPointer<UInt8>) throws -> Void) rethrows {
        guard !range.isEmpty else { return }
        var (piece, offset) = locate(range.lowerBound)
        var line = range.lowerBound
        while line < range.upperBound {
            let take = Swift.min(pieces[piece].count - offset, range.upperBound - line)
            switch pieces[piece] {
            case .buffer(let buffer, let lines):
                for index in 0..<take {
                    try body(line + index, buffer.bytes(of: lines.lowerBound + offset + index))
                }
            case .strings(let strings):
                for index in 0..<take {
                    var string = strings[strings.startIndex + offset + index]
                    try string.withUTF8 { try body(line + index, $0) }
                }
            }
            line += take
            piece += 1
            offset = 0
        }
    }

    /// The pieces that make up `range`.
    func pieces(in range: Range<Int>) -> [Piece] {
        guard !range.isEmpty else { return [] }
        var result: [Piece] = []
        var (piece, offset) = locate(range.lowerBound)
        var remaining = range.count
        while remaining > 0 {
            let take = Swift.min(pieces[piece].count - offset, remaining)
            result.append(pieces[piece].slice(offset..<(offset + take)))
            remaining -= take
            piece += 1
            offset = 0
        }
        return result
    }

    /// The first line where `self` and `other` differ, or nil when they are the same. Lines
    /// both share from one buffer are skipped without reading them.
    public func firstDifference(from other: Lines) -> Int? {
        var line = 0
        let common = Swift.min(count, other.count)
        while line < common {
            let (a, aOffset) = locate(line)
            let (b, bOffset) = other.locate(line)
            if case .buffer(let first, let firstLines) = pieces[a], case .buffer(let second, let secondLines) = other.pieces[b],
               first === second, firstLines.lowerBound + aOffset == secondLines.lowerBound + bOffset {
                line += Swift.min(pieces[a].count - aOffset, other.pieces[b].count - bOffset)
                continue
            }
            let equal = withBytes(of: line) { left in other.withBytes(of: line) { right in left.elementsEqual(right) } }
            if !equal { return line }
            line += 1
        }
        return count == other.count ? nil : common
    }
}

extension Lines: RandomAccessCollection, MutableCollection, RangeReplaceableCollection {
    public var startIndex: Int { 0 }
    public var endIndex: Int { ends.last ?? 0 }
    public var count: Int { ends.last ?? 0 }

    public subscript(position: Int) -> String {
        get {
            let (piece, offset) = locate(position)
            switch pieces[piece] {
            case .buffer(let buffer, let lines): return buffer.string(of: lines.lowerBound + offset)
            case .strings(let strings): return strings[strings.startIndex + offset]
            }
        }
        set {
            replaceSubrange(position..<(position + 1), with: CollectionOfOne(newValue))
        }
    }

    public mutating func replaceSubrange<C: Collection>(_ subrange: Range<Int>, with newElements: C) where C.Element == String {
        precondition(subrange.lowerBound >= 0 && subrange.upperBound <= count, "Range \(subrange) is out of bounds")
        let inserted: [Piece] = if let lines = newElements as? Lines {
            lines.pieces
        } else if let slice = newElements as? Slice<Lines> {
            slice.base.pieces(in: slice.startIndex..<slice.endIndex)
        } else {
            newElements.isEmpty ? [] : [.strings(ArraySlice(newElements))]
        }
        setPieces(pieces(in: 0..<subrange.lowerBound) + inserted + pieces(in: subrange.upperBound..<count))
    }

    public mutating func reserveCapacity(_ n: Int) {}

    public struct Iterator: IteratorProtocol {
        let lines: Lines
        var piece = 0
        var offset = 0

        public mutating func next() -> String? {
            while piece < lines.pieces.count {
                let current = lines.pieces[piece]
                guard offset < current.count else {
                    piece += 1
                    offset = 0
                    continue
                }
                defer { offset += 1 }
                switch current {
                case .buffer(let buffer, let range): return buffer.string(of: range.lowerBound + offset)
                case .strings(let strings): return strings[strings.startIndex + offset]
                }
            }
            return nil
        }
    }

    public func makeIterator() -> Iterator { Iterator(lines: self) }
}

extension Lines: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: String...) {
        self.init(pieces: [.strings(ArraySlice(elements))])
    }
}

extension Lines: Equatable, Hashable {
    public static func == (lhs: Lines, rhs: Lines) -> Bool {
        lhs.count == rhs.count && lhs.firstDifference(from: rhs) == nil
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(count)
        forEachLine(in: 0..<count) { _, bytes in
            hasher.combine(bytes.count)
            hasher.combine(bytes: UnsafeRawBufferPointer(bytes))
        }
    }
}

extension Lines: CustomStringConvertible {
    public var description: String { Array(self).description }
}
