import MoireKit
import SwiftUI

@Observable
final class TableModel: DifferenceNavigating {
    enum Delimiter: String, CaseIterable {
        case automatic
        case comma
        case semicolon
        case tab

        var title: String {
            switch self {
            case .automatic: "Detect Delimiter"
            case .comma: "Comma"
            case .semicolon: "Semicolon"
            case .tab: "Tab"
            }
        }

        var scalar: Unicode.Scalar? {
            switch self {
            case .automatic: nil
            case .comma: ","
            case .semicolon: ";"
            case .tab: "\t"
            }
        }
    }

    var hasHeader = UserDefaults.standard.object(forKey: "tableHeader") as? Bool ?? true {
        didSet { UserDefaults.standard.set(hasHeader, forKey: "tableHeader") }
    }
    var delimiter = Delimiter.automatic
    /// Names of the columns rows are matched by. Empty: rows are lined up in order.
    var keyNames: [String] = []
    var onlyChanges = false

    private(set) var diff: TableDiff?
    /// Indexes into `diff.rows` of the rows that are not the same.
    private(set) var changeRows: [Int] = []
    /// Column widths in points, one per column of `diff`.
    private(set) var widths: [Double] = []
    private(set) var isComparing = false
    var currentChange: Int?
    /// A row of `diff.rows` to scroll to; the grid clears it.
    var scrollRequest: Int?

    var differenceCount: Int { changeRows.count }

    func goToNextDifference() { move(by: 1) }
    func goToPreviousDifference() { move(by: -1) }

    func select(change index: Int) {
        guard changeRows.indices.contains(index) else { return }
        currentChange = index
        scrollRequest = changeRows[index]
    }

    private func move(by step: Int) {
        let count = changeRows.count
        guard count > 0 else { return }
        select(change: currentChange.map { ($0 + step + count) % count } ?? (step > 0 ? 0 : count - 1))
    }

    func load(left: String, right: String, options: DiffOptions, characterWidth: Double) async {
        isComparing = true
        let hasHeader = hasHeader
        let delimiter = delimiter.scalar
        let keyNames = keyNames
        let result = try? await runDetached {
            let leftTable = CSV.parse(left, delimiter: delimiter)
            let rightTable = CSV.parse(right, delimiter: delimiter)
            let columns = TableDiff.columns(left: leftTable, right: rightTable, hasHeader: hasHeader)
            let keys = keyNames.compactMap { name in columns.firstIndex { $0.name == name && $0.isShared } }
            let diff = TableDiff(left: leftTable, right: rightTable, hasHeader: hasHeader, keyColumns: keys, options: options)
            return (diff, Self.widths(diff, characterWidth: characterWidth))
        }
        guard !Task.isCancelled, let (diff, widths) = result else { return }
        self.diff = diff
        self.widths = widths
        changeRows = diff.rows.indices.filter { diff.rows[$0].kind != .same }
        currentChange = nil
        isComparing = false
    }

    func toggleKey(_ name: String) {
        if let index = keyNames.firstIndex(of: name) { keyNames.remove(at: index) } else { keyNames.append(name) }
    }

    /// Wide enough for the longest value in the first rows, within limits.
    nonisolated private static func widths(_ diff: TableDiff, characterWidth: Double) -> [Double] {
        diff.columns.map { column in
            var longest = column.name.count
            for row in diff.rows.prefix(500) {
                if let l = row.left, let index = column.left { longest = max(longest, diff.left[l, index].count) }
                if let r = row.right, let index = column.right { longest = max(longest, diff.right[r, index].count) }
            }
            return Double(min(max(longest, 3), 40)) * characterWidth + 18
        }
    }
}

struct TableCompareView: View {
    let compare: CompareModel
    @State private var model = TableModel()

    private var fontSize: Double { max(compare.fontSize - 0.5, 9) }
    private var characterWidth: Double { fontSize * 0.61 }

    var body: some View {
        let files = compare.fileView
        KindLayout {
            if let diff = model.diff {
                if diff.columns.isEmpty {
                    KindMessage(systemImage: "tablecells", title: "No rows", message: "Neither side has anything to show as a table.")
                } else {
                    TableGrid(model: model, diff: diff, fontSize: fontSize)
                }
            } else {
                KindMessage(systemImage: "tablecells", title: "Reading the tables…", isWorking: true)
            }
        } bar: {
            statistics
            Spacer()
            DifferenceStepper(count: model.differenceCount, current: model.currentChange, noun: "changed rows",
                              previous: model.goToPreviousDifference, next: model.goToNextDifference)
            settings
            Toggle(isOn: $model.onlyChanges) { Image(systemName: "rectangle.compress.vertical") }
                .toggleStyle(.bar)
                .help("Only show rows that changed")
        }
        .task(id: Reload(revision: files.revision, hasHeader: model.hasHeader, delimiter: model.delimiter, keys: model.keyNames, options: compare.options)) {
            await model.load(left: compare.left.text, right: compare.right.text, options: compare.options, characterWidth: characterWidth)
        }
        .onAppear { files.navigator = model }
        .onDisappear { if files.navigator === model { files.navigator = nil } }
    }

    private struct Reload: Hashable {
        var revision: Int
        var hasHeader: Bool
        var delimiter: TableModel.Delimiter
        var keys: [String]
        var options: DiffOptions
    }

    @ViewBuilder
    private var statistics: some View {
        if let diff = model.diff {
            let statistics = diff.statistics
            if statistics.isIdentical {
                Chip(text: "Identical", color: Theme.iris, systemImage: "checkmark")
            } else {
                Chip(text: "\(statistics.changed) changed", color: Theme.changed)
                Chip(text: "\(statistics.changedCells) cells", color: Theme.changed, systemImage: "square.grid.3x3")
                Chip(text: "\(statistics.added) added", color: Theme.added)
                Chip(text: "\(statistics.removed) removed", color: Theme.removed)
                if statistics.addedColumns + statistics.removedColumns > 0 {
                    Text("\(statistics.addedColumns) columns added, \(statistics.removedColumns) removed").foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if diff.duplicateKeys > 0 {
                Label("\(diff.duplicateKeys) duplicate keys", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Theme.changed)
                    .help("Rows with the same key are matched in the order they appear")
            }
        }
        if model.isComparing {
            ProgressView().controlSize(.mini)
        }
    }

    private var settings: some View {
        Menu {
            Section("Match Rows By") {
                Toggle("Line Order", isOn: Binding(get: { model.keyNames.isEmpty }, set: { if $0 { model.keyNames = [] } }))
                ForEach(sharedColumnNames, id: \.self) { name in
                    Toggle(name.isEmpty ? "(unnamed)" : name, isOn: Binding(get: { model.keyNames.contains(name) }, set: { _ in model.toggleKey(name) }))
                }
            }
            Divider()
            Toggle("First Row Is a Header", isOn: $model.hasHeader)
            Picker("Delimiter", selection: $model.delimiter) {
                ForEach(TableModel.Delimiter.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Label(model.keyNames.isEmpty ? "Rows by Order" : "Key: " + model.keyNames.joined(separator: ", "), systemImage: "key")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Match rows by key columns, so a sorted table still lines up")
    }

    private var sharedColumnNames: [String] {
        var seen: Set<String> = []
        return (model.diff?.columns ?? []).filter(\.isShared).map(\.name).filter { seen.insert($0).inserted }
    }
}

private struct TableGrid: View {
    let model: TableModel
    let diff: TableDiff
    let fontSize: Double

    private static let markerWidth = 96.0

    var body: some View {
        let indexes = model.onlyChanges ? model.changeRows : Array(diff.rows.indices)
        let current = model.currentChange.map { model.changeRows[$0] }
        ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(indexes, id: \.self) { index in
                            TableRowView(diff: diff, row: diff.rows[index], widths: model.widths, isCurrent: current == index)
                                .id(index)
                                .onTapGesture {
                                    if let change = model.changeRows.firstIndex(of: index) { model.currentChange = change }
                                }
                        }
                    } header: {
                        header
                    }
                }
            }
            .onChange(of: model.scrollRequest) { _, row in
                guard let row else { return }
                withAnimation(.smooth(duration: 0.3)) { proxy.scrollTo(row, anchor: UnitPoint(x: 0, y: 0.3)) }
                model.scrollRequest = nil
            }
        }
        .font(Theme.code(size: fontSize))
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text(diff.keyColumns.isEmpty ? "Row" : "Row · key")
                .foregroundStyle(.secondary)
                .frame(width: Self.markerWidth, alignment: .leading)
                .padding(.leading, 10)
            ForEach(diff.columns.indices, id: \.self) { index in
                let column = diff.columns[index]
                HStack(spacing: 4) {
                    if diff.keyColumns.contains(index) { Image(systemName: "key.fill").font(.system(size: 9)) }
                    Text(column.name.isEmpty ? " " : column.name).lineLimit(1).truncationMode(.tail)
                }
                .fontWeight(.semibold)
                .foregroundStyle(column.left == nil ? Theme.added : (column.right == nil ? Theme.removed : Theme.text))
                .help(column.left == nil ? "Only the right table has this column" : (column.right == nil ? "Only the left table has this column" : column.name))
                .frame(width: model.widths[index], alignment: .leading)
                .padding(.horizontal, 6)
            }
        }
        .padding(.vertical, 6)
        .background(Theme.pane)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.paneBorder).frame(height: 1) }
    }
}

private struct TableRowView: View {
    let diff: TableDiff
    let row: TableDiff.Row
    let widths: [Double]
    let isCurrent: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            marker
                .frame(width: 96, alignment: .leading)
                .padding(.leading, 10)
            ForEach(diff.columns.indices, id: \.self) { index in
                cell(index)
                    .frame(width: widths[index], alignment: .leading)
                    .padding(.horizontal, 6)
            }
        }
        .padding(.vertical, 3)
        .background(background)
        .overlay(alignment: .leading) {
            if isCurrent { Rectangle().fill(Theme.brand).frame(width: 3) }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.subtleFill).frame(height: 1) }
    }

    private var background: Color {
        switch row.kind {
        case .same: .clear
        case .changed: Theme.changed.opacity(0.07)
        case .added: Theme.addedRow
        case .removed: Theme.removedRow
        }
    }

    private var marker: some View {
        HStack(spacing: 6) {
            switch row.kind {
            case .same: Image(systemName: "equal").foregroundStyle(.tertiary)
            case .changed: Image(systemName: "pencil").foregroundStyle(Theme.changed)
            case .added: Image(systemName: "plus").foregroundStyle(Theme.added)
            case .removed: Image(systemName: "minus").foregroundStyle(Theme.removed)
            }
            Text(numbers).foregroundStyle(Theme.gutterText).monospacedDigit().lineLimit(1)
        }
        .font(.system(size: 11))
    }

    /// Row numbers as in the files, so a row can be found in a spreadsheet.
    private var numbers: String {
        switch (row.left, row.right) {
        case let (l?, r?): l == r ? "\(l + 1)" : "\(l + 1) → \(r + 1)"
        case let (l?, nil): "\(l + 1)"
        case let (nil, r?): "\(r + 1)"
        case (nil, nil): ""
        }
    }

    @ViewBuilder
    private func cell(_ index: Int) -> some View {
        let column = diff.columns[index]
        let leftValue = row.left.flatMap { l in column.left.map { diff.left[l, $0] } }
        let rightValue = row.right.flatMap { r in column.right.map { diff.right[r, $0] } }
        if row.changedColumns.contains(index) {
            VStack(alignment: .leading, spacing: 1) {
                Text(display(leftValue)).strikethrough().foregroundStyle(Theme.removed)
                    .padding(.horizontal, 3).background(Theme.removedWord, in: RoundedRectangle(cornerRadius: 3))
                Text(display(rightValue)).foregroundStyle(Theme.added)
                    .padding(.horizontal, 3).background(Theme.addedWord, in: RoundedRectangle(cornerRadius: 3))
            }
            .lineLimit(1)
        } else {
            Text(display(rightValue ?? leftValue))
                .foregroundStyle(column.isShared ? Theme.text : (column.left == nil ? Theme.added : Theme.removed))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func display(_ value: String?) -> String {
        guard let value else { return "" }
        return value.replacingOccurrences(of: "\r\n", with: " ↵ ").replacingOccurrences(of: "\n", with: " ↵ ")
    }
}
