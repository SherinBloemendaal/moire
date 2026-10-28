/// Rows of fields read from comma, semicolon or tab separated text.
public struct CSVTable: Sendable, Hashable {
    public var rows: [[String]]
    public var delimiter: Unicode.Scalar

    public init(rows: [[String]], delimiter: Unicode.Scalar = ",") {
        self.rows = rows
        self.delimiter = delimiter
    }

    public var columnCount: Int { rows.reduce(0) { max($0, $1.count) } }

    /// The field, or an empty one for a row that is shorter.
    public subscript(row: Int, column: Int) -> String {
        guard rows.indices.contains(row), rows[row].indices.contains(column) else { return "" }
        return rows[row][column]
    }
}

/// A parser for RFC 4180: fields in double quotes may hold the delimiter, line breaks and quotes
/// written twice (`""`). Lines end in CRLF, LF or CR.
///
/// It is lenient where the RFC is strict, the way spreadsheet apps are: a quote inside an
/// unquoted field is kept as a character, text after a closing quote is added to the field, and
/// an unclosed quote runs to the end. Lines that are completely empty are skipped.
public enum CSV {
    public static let delimiters: [Unicode.Scalar] = [",", ";", "\t"]

    public static func parse(_ text: String, delimiter: Unicode.Scalar? = nil) -> CSVTable {
        let delimiter = delimiter ?? detectDelimiter(text)
        return CSVTable(rows: parseRows(text.unicodeScalars, delimiter: delimiter), delimiter: delimiter)
    }

    /// Picks the delimiter that splits the first records into the same number of fields most
    /// often, preferring more fields on a tie. Without any, the comma.
    public static func detectDelimiter(_ text: String) -> Unicode.Scalar {
        let sample = text.unicodeScalars.prefix(64 * 1024)
        let isCut = sample.count < text.unicodeScalars.count
        var best: (delimiter: Unicode.Scalar, share: Double, fields: Int)?
        for delimiter in delimiters {
            var rows = parseRows(sample, delimiter: delimiter, limit: 100)
            // The last record of a cut sample may be incomplete.
            if isCut, rows.count > 1, rows.count < 100 { rows.removeLast() }
            let counts = rows.map(\.count)
            guard !counts.isEmpty else { continue }
            var frequency: [Int: Int] = [:]
            for count in counts { frequency[count, default: 0] += 1 }
            guard let (fields, times) = frequency.max(by: { ($0.value, $0.key) < ($1.value, $1.key) }), fields > 1 else { continue }
            let share = Double(times) / Double(counts.count)
            if let current = best, (current.share, current.fields) >= (share, fields) { continue }
            best = (delimiter, share, fields)
        }
        return best?.delimiter ?? ","
    }

    private enum State {
        case fieldStart
        case unquoted
        case quoted
        /// Just read a quote inside a quoted field: another quote is a literal one.
        case quoteInQuoted
    }

    static func parseRows<Scalars: Sequence<Unicode.Scalar>>(_ scalars: Scalars, delimiter: Unicode.Scalar, limit: Int = .max) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = String.UnicodeScalarView()
        var state = State.fieldStart
        var rowHasContent = false
        var previousWasCR = false

        func endField() {
            row.append(String(field))
            field = String.UnicodeScalarView()
        }
        func endRow() {
            endField()
            if rowHasContent { rows.append(row) }
            row = []
            rowHasContent = false
            state = .fieldStart
        }

        for scalar in scalars {
            if previousWasCR {
                previousWasCR = false
                // The LF of a CRLF: the row already ended at the CR.
                if scalar == "\n", state == .fieldStart { continue }
            }
            switch state {
            case .quoted:
                rowHasContent = true
                if scalar == "\"" { state = .quoteInQuoted } else { field.append(scalar) }
                continue
            case .quoteInQuoted where scalar == "\"":
                field.append(scalar)
                state = .quoted
                continue
            default:
                break
            }

            if scalar == delimiter {
                rowHasContent = true
                endField()
                state = .fieldStart
            } else if scalar == "\r" || scalar == "\n" {
                endRow()
                previousWasCR = scalar == "\r"
                if rows.count >= limit { return rows }
            } else if scalar == "\"", state == .fieldStart {
                rowHasContent = true
                state = .quoted
            } else {
                rowHasContent = true
                field.append(scalar)
                state = .unquoted
            }
        }
        if rowHasContent || !field.isEmpty || state != .fieldStart {
            rowHasContent = true
            endRow()
        }
        return rows
    }
}
