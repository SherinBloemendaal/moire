/// Text taken out of a PDF or a word processor document, made ready to compare as lines.
public enum DocumentText {
    /// The line put between two pages. It holds no page count, so adding a page at the end
    /// does not change every marker before it.
    public static func pageMarker(_ number: Int) -> String {
        "--- Page \(number) ---"
    }

    /// One document of all pages, each page after its marker line.
    public static func pages(_ pages: [String]) -> TextDocument {
        var lines: [String] = []
        for (index, page) in pages.enumerated() {
            lines.append(pageMarker(index + 1))
            let text = normalize(page)
            if !text.isEmpty { lines.append(contentsOf: TextDocument(text).lines) }
        }
        return TextDocument(lines: lines)
    }

    public static func text(_ text: String) -> TextDocument {
        TextDocument(lines: TextDocument(normalize(text)).lines)
    }

    /// Makes line breaks plain, drops the invisible characters that layout leaves behind,
    /// removes spaces at line ends, and keeps at most one empty line in a row.
    public static func normalize(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar {
            // Line and paragraph separators, form feed, vertical tab and next line.
            case "\u{2028}", "\u{2029}", "\u{0C}", "\u{0B}", "\u{85}":
                scalars.append("\n")
            // Soft hyphen, zero width space and joiners, byte order mark, and the attachment
            // character that stands in for images.
            case "\u{AD}", "\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}", "\u{FFFC}":
                continue
            case "\u{A0}":
                scalars.append(" ")
            default:
                scalars.append(scalar)
            }
        }
        var lines = TextDocument(String(scalars)).lines.map { $0.trimmingTrailingSpaces() }
        var kept: [String] = []
        for line in lines where !(line.isEmpty && (kept.last?.isEmpty ?? true)) {
            kept.append(line)
        }
        while kept.last?.isEmpty == true { kept.removeLast() }
        lines = kept
        return lines.joined(separator: "\n")
    }
}

extension String {
    func trimmingTrailingSpaces() -> String {
        let scalars = unicodeScalars
        guard let last = scalars.lastIndex(where: { $0 != " " && $0 != "\t" }) else { return "" }
        return String(scalars[...last])
    }
}
