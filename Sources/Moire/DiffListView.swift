import MoireKit
import SwiftUI

/// The comparison itself: every line of both sides, aligned, with the changes marked.
struct DiffListView: View {
    @Bindable var model: CompareModel
    let diff: LineDiff

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.displayItems) { item in
                        itemView(item)
                    }
                }
                .padding(.vertical, 6)
            }
            .onChange(of: model.scrollRequest) { _, row in
                guard let row else { return }
                withAnimation(.smooth(duration: 0.35)) {
                    proxy.scrollTo(row, anchor: UnitPoint(x: 0.5, y: 0.3))
                }
                model.scrollRequest = nil
            }
        }
        .font(Theme.code(size: model.fontSize))
    }

    @ViewBuilder
    private func itemView(_ item: DisplayItem) -> some View {
        switch item {
        case .same(let row):
            if model.layout == .sideBySide {
                SideBySideRow(diff: diff, row: diff.rows[row])
            } else {
                UnifiedLine(kind: .same, left: diff.rows[row].left, right: diff.rows[row].right, segments: plain(diff.rows[row].left.map { diff.left.lines[$0] }))
            }
        case .hunk(let index, let rows):
            HunkBlock(model: model, diff: diff, index: index, rows: rows)
        case .fold(let rows):
            FoldRow(count: rows.count) { withAnimation(.smooth) { model.expand(fold: rows) } }
        }
    }
}

private func plain(_ text: String?) -> [Segment] {
    [Segment(text ?? "", isChanged: false)]
}

/// One block of changed lines, with buttons to copy it to the other side.
private struct HunkBlock: View {
    let model: CompareModel
    let diff: LineDiff
    let index: Int
    let rows: Range<Int>
    @State private var isHovered = false

    private var isCurrent: Bool { model.currentHunk == index }

    var body: some View {
        content
            .overlay(alignment: .leading) {
                if isCurrent {
                    Capsule().fill(Theme.brand).frame(width: 3).padding(.vertical, 1).transition(.opacity)
                }
            }
            .overlay(alignment: model.layout == .sideBySide ? .top : .topTrailing) {
                MergeButtons(
                    isVisible: isHovered || isCurrent,
                    copyRight: { withAnimation(.smooth) { model.copy(hunk: index, toRight: true) } },
                    copyLeft: { withAnimation(.smooth) { model.copy(hunk: index, toRight: false) } }
                )
                .padding(.top, 2)
                .padding(.trailing, model.layout == .unified ? 12 : 0)
            }
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .onTapGesture { model.currentHunk = index }
            .contextMenu {
                Button("Copy to Right", systemImage: "arrow.right") { model.copy(hunk: index, toRight: true) }
                Button("Copy to Left", systemImage: "arrow.left") { model.copy(hunk: index, toRight: false) }
                Divider()
                Button("Copy Left Lines as Text") { copyLines(diff.left.lines[diff.hunks[index].left]) }
                Button("Copy Right Lines as Text") { copyLines(diff.right.lines[diff.hunks[index].right]) }
            }
            .animation(.smooth(duration: 0.2), value: isCurrent)
    }

    @ViewBuilder
    private var content: some View {
        if model.layout == .sideBySide {
            VStack(spacing: 0) {
                ForEach(rows, id: \.self) { row in
                    SideBySideRow(diff: diff, row: diff.rows[row])
                }
            }
        } else {
            let hunk = diff.hunks[index]
            let changedRows = diff.rows[rows].filter { $0.kind == .changed }
            let leftSegments = Dictionary(uniqueKeysWithValues: changedRows.compactMap { row in row.left.map { ($0, row.leftSegments ?? []) } })
            let rightSegments = Dictionary(uniqueKeysWithValues: changedRows.compactMap { row in row.right.map { ($0, row.rightSegments ?? []) } })
            VStack(spacing: 0) {
                ForEach(hunk.left, id: \.self) { line in
                    UnifiedLine(kind: .removed, left: line, right: nil, segments: leftSegments[line] ?? plain(diff.left.lines[line]))
                }
                ForEach(hunk.right, id: \.self) { line in
                    UnifiedLine(kind: .added, left: nil, right: line, segments: rightSegments[line] ?? plain(diff.right.lines[line]))
                }
            }
        }
    }

    private func copyLines(_ lines: ArraySlice<String>) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}

private struct MergeButtons: View {
    var isVisible: Bool
    var copyRight: () -> Void
    var copyLeft: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            button("arrow.right", help: "Copy this change to the right side", action: copyRight)
            Divider().frame(height: 12)
            button("arrow.left", help: "Copy this change to the left side", action: copyLeft)
        }
        .padding(.horizontal, 2)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.paneBorder))
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        .opacity(isVisible ? 1 : 0)
        .scaleEffect(isVisible ? 1 : 0.85)
        .animation(.spring(duration: 0.25, bounce: 0.3), value: isVisible)
        .allowsHitTesting(isVisible)
    }

    private func button(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 24, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.iris)
        .help(help)
    }
}

/// A row with the left line and the right line next to each other.
private struct SideBySideRow: View {
    let diff: LineDiff
    let row: DiffRow

    var body: some View {
        HStack(spacing: 0) {
            LineCell(
                number: row.left,
                segments: row.leftSegments ?? plain(row.left.map { diff.left.lines[$0] }),
                kind: row.kind,
                side: .left
            )
            Rectangle().fill(Theme.paneBorder).frame(width: 1)
            LineCell(
                number: row.right,
                segments: row.rightSegments ?? plain(row.right.map { diff.right.lines[$0] }),
                kind: row.kind,
                side: .right
            )
        }
    }
}

private struct LineCell: View {
    let number: Int?
    let segments: [Segment]
    let kind: DiffRow.Kind
    let side: SideID

    private var isRemovedSide: Bool { side == .left }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(number.map { String($0 + 1) } ?? "")
                .foregroundStyle(kind == .same ? Theme.gutterText : accent.opacity(0.8))
                .frame(width: 46, alignment: .trailing)
                .padding(.trailing, 10)
            if number != nil {
                Text(attributed)
                    .foregroundStyle(Theme.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 1.5)
        .padding(.trailing, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
    }

    private var accent: Color { isRemovedSide ? Theme.removed : Theme.added }

    @ViewBuilder
    private var background: some View {
        if number == nil {
            Hatching(color: Theme.paneBorder)
        } else if kind != .same {
            isRemovedSide ? Theme.removedRow : Theme.addedRow
        }
    }

    private var attributed: AttributedString {
        var result = AttributedString()
        for segment in segments {
            var part = AttributedString(displayText(segment.text))
            if segment.isChanged {
                part.backgroundColor = isRemovedSide ? Theme.removedWord : Theme.addedWord
            }
            result += part
        }
        return result.characters.isEmpty ? AttributedString(" ") : result
    }
}

/// One line of the unified view: removed lines and added lines below each other.
private struct UnifiedLine: View {
    let kind: DiffRow.Kind
    let left: Int?
    let right: Int?
    let segments: [Segment]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(left.map { String($0 + 1) } ?? "")
                .frame(width: 46, alignment: .trailing)
            Text(right.map { String($0 + 1) } ?? "")
                .frame(width: 46, alignment: .trailing)
            Text(kind == .removed ? "−" : kind == .added ? "+" : " ")
                .foregroundStyle(accent)
                .frame(width: 26)
            Text(attributed)
                .foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .foregroundStyle(Theme.gutterText)
        .padding(.vertical, 1.5)
        .padding(.trailing, 14)
        .background(kind == .removed ? Theme.removedRow : kind == .added ? Theme.addedRow : .clear)
    }

    private var accent: Color { kind == .removed ? Theme.removed : Theme.added }

    private var attributed: AttributedString {
        var result = AttributedString()
        for segment in segments {
            var part = AttributedString(displayText(segment.text))
            if segment.isChanged {
                part.backgroundColor = kind == .removed ? Theme.removedWord : Theme.addedWord
            }
            result += part
        }
        return result.characters.isEmpty ? AttributedString(" ") : result
    }
}

private struct FoldRow: View {
    let count: Int
    let expand: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: expand) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold))
                Text("\(count) unchanged lines").font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(isHovered ? Theme.iris : Theme.gutterText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(Theme.subtleFill)
            .overlay(alignment: .top) { Rectangle().fill(Theme.paneBorder).frame(height: 1) }
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.paneBorder).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .padding(.vertical, 2)
        .help("Show the hidden lines")
    }
}

/// Tabs as four spaces, so columns line up the way they do in an editor.
private func displayText(_ text: String) -> String {
    text.replacingOccurrences(of: "\t", with: "    ")
}
