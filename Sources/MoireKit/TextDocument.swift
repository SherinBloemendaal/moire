/// Text split into lines, remembering how it was written so it can be joined back exactly.
public struct TextDocument: Sendable, Hashable {
    public enum LineEnding: String, Sendable, Hashable {
        case lf = "\n"
        case crlf = "\r\n"
        case cr = "\r"
    }

    public var lines: [String]
    public var lineEnding: LineEnding
    /// Whether the last line ended with a line break.
    public var endsWithLineBreak: Bool

    public init(lines: [String], lineEnding: LineEnding = .lf, endsWithLineBreak: Bool = true) {
        self.lines = lines
        self.lineEnding = lineEnding
        self.endsWithLineBreak = endsWithLineBreak
    }

    /// Splits on `\r\n`, `\n` and `\r`. The most common break becomes the document's line ending.
    public init(_ text: String) {
        var lines: [String] = []
        var counts: [LineEnding: Int] = [:]
        var current = ""
        var previousWasCR = false

        for scalar in text.unicodeScalars {
            switch scalar {
            case "\n":
                if previousWasCR {
                    // "\r\n": the line was already closed at "\r".
                    counts[.cr, default: 0] -= 1
                    counts[.crlf, default: 0] += 1
                } else {
                    lines.append(current)
                    current = ""
                    counts[.lf, default: 0] += 1
                }
                previousWasCR = false
            case "\r":
                lines.append(current)
                current = ""
                counts[.cr, default: 0] += 1
                previousWasCR = true
            default:
                current.unicodeScalars.append(scalar)
                previousWasCR = false
            }
        }

        let endsWithLineBreak = current.isEmpty && !lines.isEmpty
        if !endsWithLineBreak, !(current.isEmpty && lines.isEmpty) {
            lines.append(current)
        }

        let lineEnding = [LineEnding.lf, .crlf, .cr].max { counts[$0, default: 0] < counts[$1, default: 0] } ?? .lf
        self.init(lines: lines, lineEnding: counts.values.contains { $0 > 0 } ? lineEnding : .lf, endsWithLineBreak: endsWithLineBreak)
    }

    public var text: String {
        guard !lines.isEmpty else { return "" }
        let joined = lines.joined(separator: lineEnding.rawValue)
        return endsWithLineBreak ? joined + lineEnding.rawValue : joined
    }
}
