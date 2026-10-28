/// Two tables compared row by row and cell by cell.
///
/// Columns are matched by their name when the first row is a header (so a column may move or be
/// added), and by position otherwise. Rows are matched by the key columns when there are any, so
/// sorting a table differently changes nothing; without keys they are lined up like lines of text.
public struct TableDiff: Sendable {
    public struct Column: Sendable, Hashable {
        public var name: String
        /// The column in each table; nil when only the other table has it.
        public var left: Int?
        public var right: Int?

        public var isShared: Bool { left != nil && right != nil }
    }

    public struct Row: Sendable, Hashable {
        public enum Kind: Sendable, Hashable {
            case same
            case changed
            /// Only in the right table.
            case added
            /// Only in the left table.
            case removed
        }

        public var kind: Kind
        /// Indexes into the rows of each table.
        public var left: Int?
        public var right: Int?
        /// Indexes into `columns` of the cells that differ.
        public var changedColumns: [Int]
    }

    public struct Statistics: Sendable, Hashable {
        public var added = 0
        public var removed = 0
        public var changed = 0
        public var changedCells = 0
        public var addedColumns = 0
        public var removedColumns = 0

        public var isIdentical: Bool { added == 0 && removed == 0 && changed == 0 && addedColumns == 0 && removedColumns == 0 }
    }

    public let left: CSVTable
    public let right: CSVTable
    public let hasHeader: Bool
    public let columns: [Column]
    /// The key columns that were used, as indexes into `columns`.
    public let keyColumns: [Int]
    public let rows: [Row]
    /// Rows whose key was already taken by an earlier row on the same side.
    public let duplicateKeys: Int
    public let statistics: Statistics

    /// `keyColumns` are indexes into `columns(left:right:hasHeader:)`; a key column that only
    /// one table has is left out.
    public init(left: CSVTable, right: CSVTable, hasHeader: Bool = true, keyColumns: [Int] = [], options: DiffOptions = DiffOptions()) {
        self.left = left
        self.right = right
        self.hasHeader = hasHeader
        let columns = Self.columns(left: left, right: right, hasHeader: hasHeader)
        self.columns = columns
        let shared = columns.indices.filter { columns[$0].isShared }
        let keys = keyColumns.filter { columns.indices.contains($0) && columns[$0].isShared }
        self.keyColumns = keys

        let first = hasHeader ? 1 : 0
        let leftRows = min(first, left.rows.count)..<left.rows.count
        let rightRows = min(first, right.rows.count)..<right.rows.count

        func cell(_ table: CSVTable, _ row: Int, _ column: Int?) -> String {
            column.map { options.key(for: table[row, $0]) } ?? ""
        }
        func key(_ row: Int, onLeft: Bool, _ columnIndexes: [Int]) -> String {
            columnIndexes.map { index in
                onLeft ? cell(left, row, columns[index].left) : cell(right, row, columns[index].right)
            }.joined(separator: "\u{1F}")
        }
        func compared(_ l: Int, _ r: Int) -> Row {
            let changed = shared.filter { cell(left, l, columns[$0].left) != cell(right, r, columns[$0].right) }
            return Row(kind: changed.isEmpty ? .same : .changed, left: l, right: r, changedColumns: changed)
        }

        var rows: [Row] = []
        var duplicates = 0
        if !keys.isEmpty {
            var rightByKey: [String: [Int]] = [:]
            for r in rightRows {
                let rowKey = key(r, onLeft: false, keys)
                if rightByKey[rowKey] != nil { duplicates += 1 }
                rightByKey[rowKey, default: []].append(r)
            }
            var seenLeft: Set<String> = []
            var leftForRight: [Int: Int] = [:]
            var matchedLeft: Set<Int> = []
            for l in leftRows {
                let rowKey = key(l, onLeft: true, keys)
                if !seenLeft.insert(rowKey).inserted { duplicates += 1 }
                guard var queue = rightByKey[rowKey], !queue.isEmpty else { continue }
                leftForRight[queue.removeFirst()] = l
                rightByKey[rowKey] = queue
                matchedLeft.insert(l)
            }
            // In the order of the right table, with rows only the left one has placed before the
            // next row that follows them on the left.
            var nextLeft = leftRows.lowerBound
            for r in rightRows {
                guard let l = leftForRight[r] else {
                    rows.append(Row(kind: .added, left: nil, right: r, changedColumns: []))
                    continue
                }
                while nextLeft < l {
                    if !matchedLeft.contains(nextLeft) {
                        rows.append(Row(kind: .removed, left: nextLeft, right: nil, changedColumns: []))
                    }
                    nextLeft += 1
                }
                nextLeft = max(nextLeft, l + 1)
                rows.append(compared(l, r))
            }
            for l in nextLeft..<leftRows.upperBound where !matchedLeft.contains(l) {
                rows.append(Row(kind: .removed, left: l, right: nil, changedColumns: []))
            }
        } else {
            let leftKeys = leftRows.map { key($0, onLeft: true, shared) }
            let rightKeys = rightRows.map { key($0, onLeft: false, shared) }
            var l = leftRows.lowerBound
            var r = rightRows.lowerBound
            let operations = Myers.diff(leftKeys, rightKeys)
            var index = 0
            while index < operations.count {
                if operations[index] == .equal {
                    rows.append(compared(l, r))
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
                let paired = min(deleted, inserted)
                for offset in 0..<paired {
                    rows.append(compared(l + offset, r + offset))
                }
                for offset in paired..<deleted {
                    rows.append(Row(kind: .removed, left: l + offset, right: nil, changedColumns: []))
                }
                for offset in paired..<inserted {
                    rows.append(Row(kind: .added, left: nil, right: r + offset, changedColumns: []))
                }
                l += deleted
                r += inserted
            }
        }

        var statistics = Statistics()
        for row in rows {
            switch row.kind {
            case .same: break
            case .changed: statistics.changed += 1
            case .added: statistics.added += 1
            case .removed: statistics.removed += 1
            }
            statistics.changedCells += row.changedColumns.count
        }
        statistics.addedColumns = columns.count { $0.left == nil }
        statistics.removedColumns = columns.count { $0.right == nil }
        self.rows = rows
        self.duplicateKeys = duplicates
        self.statistics = statistics
    }

    /// The columns of both tables lined up. With a header, columns with the same name are one
    /// column, wherever they are; without, the first column of each table is one, and so on.
    public static func columns(left: CSVTable, right: CSVTable, hasHeader: Bool) -> [Column] {
        let leftCount = left.columnCount
        let rightCount = right.columnCount
        guard hasHeader else {
            return (0..<max(leftCount, rightCount)).map { index in
                Column(name: letters(index), left: index < leftCount ? index : nil, right: index < rightCount ? index : nil)
            }
        }

        let leftNames = (0..<leftCount).map { left[0, $0] }
        let rightNames = (0..<rightCount).map { right[0, $0] }
        var aligned: [Column] = []
        var i = 0
        var j = 0
        for operation in Myers.diff(leftNames, rightNames) {
            switch operation {
            case .equal:
                aligned.append(Column(name: leftNames[i], left: i, right: j))
                i += 1
                j += 1
            case .delete:
                aligned.append(Column(name: leftNames[i], left: i, right: nil))
                i += 1
            case .insert:
                aligned.append(Column(name: rightNames[j], left: nil, right: j))
                j += 1
            }
        }

        // A column that moved shows up as removed in one place and added in another: join them
        // where the first of the two is.
        var columns: [Column] = []
        var joined: Set<Int> = []
        for (index, column) in aligned.enumerated() where !joined.contains(index) {
            guard !column.isShared else {
                columns.append(column)
                continue
            }
            let partner = aligned.indices.first { other in
                other > index && !joined.contains(other) && aligned[other].name == column.name
                    && !aligned[other].isShared && (aligned[other].left == nil) != (column.left == nil)
            }
            guard let partner else {
                columns.append(column)
                continue
            }
            joined.insert(partner)
            columns.append(Column(name: column.name, left: column.left ?? aligned[partner].left, right: column.right ?? aligned[partner].right))
        }
        return columns
    }

    /// Spreadsheet column names: A to Z, then AA, AB and so on.
    public static func letters(_ index: Int) -> String {
        var number = index + 1
        var name = ""
        while number > 0 {
            let remainder = (number - 1) % 26
            name = String(UnicodeScalar(UInt8(65 + remainder))) + name
            number = (number - 1) / 26
        }
        return name
    }
}
