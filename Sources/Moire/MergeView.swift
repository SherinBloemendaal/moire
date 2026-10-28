import MoireKit
import SwiftUI

/// Colors of the merge: one per side, one for a change both sides made, and the conflict states.
enum MergeTheme {
    static let left = Theme.iris
    static let right = Color.dynamic(light: 0x0891B2, dark: 0x22D3EE)
    static let both = Theme.changed
    static let conflict = Theme.removed
    static let resolved = Theme.added
    static let edited = Theme.pink
    static let base = Theme.gutterText

    static func color(for version: ThreeWayMerge.Version) -> Color {
        switch version {
        case .left: left
        case .base: base
        case .right: right
        }
    }
}

struct MergeView: View {
    @Bindable var model: MergeModel

    var body: some View {
        VStack(spacing: 0) {
            if model.isReady {
                header
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 10)
                VSplitView {
                    pane { VersionsPane(model: model) }
                        .padding(.bottom, 5)
                        .frame(minHeight: 140)
                    pane { ResultPane(model: model) }
                        .padding(.top, 5)
                        .frame(minHeight: 160)
                }
                .padding(.horizontal, 14)
                MergeStatusBar(model: model)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
            } else {
                MergeEmptyView(model: model)
            }
        }
        .background(Theme.window)
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ForEach(ThreeWayMerge.Version.displayOrder, id: \.self) { version in
                SourceCard(model: model, version: version)
            }
        }
    }

    private func pane<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .background(Theme.pane, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.paneBorder))
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// The name and location of one of the three files, and a drop target for it.
private struct SourceCard: View {
    let model: MergeModel
    let version: ThreeWayMerge.Version
    @State private var isTargeted = false

    var body: some View {
        let source = model[version]
        let color = MergeTheme.color(for: version)
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.14))
                Text(version.name.prefix(1))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(source.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(version.role)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(color.opacity(0.12), in: Capsule())
                        .fixedSize()
                }
                Text(source.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if !model.isMergetool {
                Menu {
                    Button("Open File…", systemImage: "folder") { model.openPanel(for: version) }
                    if let url = source.url, !source.isMissing {
                        Button("Reload from Disk", systemImage: "arrow.clockwise") { model.load(url, into: version) }
                        Button("Show in Finder", systemImage: "magnifyingglass") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Theme.pane, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isTargeted ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Theme.paneBorder), lineWidth: isTargeted ? 2 : 1)
        )
        .scaleEffect(isTargeted ? 1.015 : 1)
        .animation(.spring(duration: 0.25), value: isTargeted)
        .dropDestination(for: URL.self) { urls, _ in
            guard !model.isMergetool, let url = urls.first else { return false }
            model.load(url, into: version)
            return true
        } isTargeted: { isTargeted = $0 && !model.isMergetool }
    }
}

// MARK: The three versions

/// Left, base and right next to each other, every changed chunk padded so the three line up.
private struct VersionsPane: View {
    let model: MergeModel
    @AppStorage("fontSize") private var fontSize = 12.5

    var body: some View {
        if let merge = model.merge {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.items, id: \.self) { item in
                            row(item, merge: merge).id(item)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .onChange(of: model.scrollRequest) { _, request in
                    withAnimation(.smooth(duration: 0.35)) {
                        proxy.scrollTo(MergeItem.block(chunk: request.chunk), anchor: UnitPoint(x: 0.5, y: 0.25))
                    }
                }
            }
            .font(Theme.code(size: fontSize))
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func row(_ item: MergeItem, merge: ThreeWayMerge) -> some View {
        switch item {
        case .line(let index, let offset):
            let chunk = merge.chunks[index]
            let text = merge.base[chunk.base.lowerBound + offset].text
            HStack(spacing: 0) {
                MergeLineCell(number: chunk.left.lowerBound + offset, segments: plainSegments(text))
                Rectangle().fill(Theme.paneBorder).frame(width: 1)
                MergeLineCell(number: chunk.base.lowerBound + offset, segments: plainSegments(text))
                Rectangle().fill(Theme.paneBorder).frame(width: 1)
                MergeLineCell(number: chunk.right.lowerBound + offset, segments: plainSegments(text))
            }
        case .block(let index):
            VersionsBlock(model: model, merge: merge, index: index)
        case .fold(let index, let offsets):
            MergeFoldRow(count: offsets.count) { withAnimation(.smooth) { model.expand(fold: index) } }
        }
    }
}

private struct VersionsBlock: View {
    let model: MergeModel
    let merge: ThreeWayMerge
    let index: Int

    private var chunk: ThreeWayMerge.Chunk { merge.chunks[index] }
    private var isCurrent: Bool { model.currentChunk == index }

    var body: some View {
        HStack(spacing: 0) {
            column(.left)
            Rectangle().fill(Theme.paneBorder).frame(width: 1)
            column(.base)
            Rectangle().fill(Theme.paneBorder).frame(width: 1)
            column(.right)
        }
        .fixedSize(horizontal: false, vertical: true)
        .overlay(alignment: .leading) {
            if isCurrent {
                Capsule().fill(Theme.brand).frame(width: 3).padding(.vertical, 1).transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.currentChunk = index }
        .animation(.smooth(duration: 0.2), value: isCurrent)
    }

    /// The color a version is marked with in this chunk, or nil when it is just the old text.
    private func accent(_ version: ThreeWayMerge.Version) -> Color? {
        switch (chunk.kind, version) {
        case (.conflict, .left), (.conflict, .right): MergeTheme.conflict
        case (.changedLeft, .left): MergeTheme.left
        case (.changedRight, .right): MergeTheme.right
        case (.changedBoth, .left), (.changedBoth, .right): MergeTheme.both
        default: nil
        }
    }

    private func column(_ version: ThreeWayMerge.Version) -> some View {
        let lines = merge.lines(of: version, in: index)
        let baseLines = merge.lines(of: .base, in: index)
        let range = switch version {
        case .left: chunk.left
        case .base: chunk.base
        case .right: chunk.right
        }
        let accent = accent(version)
        return VStack(spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { offset, line in
                // A changed line is paired with the base line at the same place, so the words that changed stand out.
                let baseIndex = baseLines.startIndex + offset
                let segments = if accent != nil, version != .base, baseIndex < baseLines.endIndex {
                    InlineDiff.segments(baseLines[baseIndex].text, line.text).1
                } else {
                    plainSegments(line.text)
                }
                MergeLineCell(number: range.lowerBound + offset, segments: segments, accent: accent)
            }
            if lines.isEmpty || lines.count < maxCount {
                Hatching(color: Theme.paneBorder)
                    .frame(minHeight: lines.isEmpty ? 6 : 0)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(accent == nil ? AnyShapeStyle(Theme.subtleFill) : AnyShapeStyle(.clear))
    }

    private var maxCount: Int { max(chunk.left.count, chunk.base.count, chunk.right.count) }
}

// MARK: The result

/// The merged file: what every chunk ends up as, with the open conflicts waiting for a choice.
private struct ResultPane: View {
    @Bindable var model: MergeModel
    @AppStorage("fontSize") private var fontSize = 12.5

    var body: some View {
        VStack(spacing: 0) {
            ResultHeader(model: model)
            Rectangle().fill(Theme.paneBorder).frame(height: 1)
            if let merge = model.merge, model.resultStarts.count == merge.chunks.count {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(model.items, id: \.self) { item in
                                row(item, merge: merge).id(item)
                            }
                            if merge.chunks.isEmpty {
                                Text("The merged file is empty.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .padding(20)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .onChange(of: model.scrollRequest) { _, request in
                        withAnimation(.smooth(duration: 0.35)) {
                            proxy.scrollTo(MergeItem.block(chunk: request.chunk), anchor: UnitPoint(x: 0.5, y: 0.25))
                        }
                    }
                }
                .font(Theme.code(size: fontSize))
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func row(_ item: MergeItem, merge: ThreeWayMerge) -> some View {
        switch item {
        case .line(let index, let offset):
            // An unchanged run that was edited by hand is drawn once, as a block, at its first line.
            if model.resolution(of: index) != nil || model.editingChunk == index {
                if offset == 0 { ResultBlock(model: model, merge: merge, index: index) }
            } else {
                let chunk = merge.chunks[index]
                MergeLineCell(number: model.resultStarts[index] + offset, segments: plainSegments(merge.base[chunk.base.lowerBound + offset].text))
                    .contextMenu {
                        Button("Edit These Lines", systemImage: "pencil") { model.beginEdit(index) }
                    }
            }
        case .block(let index):
            ResultBlock(model: model, merge: merge, index: index)
        case .fold(let index, let offsets):
            if model.resolution(of: index) == nil, model.editingChunk != index {
                MergeFoldRow(count: offsets.count) { withAnimation(.smooth) { model.expand(fold: index) } }
            } else if offsets.lowerBound == 0 {
                ResultBlock(model: model, merge: merge, index: index)
            }
        }
    }
}

private struct ResultHeader: View {
    let model: MergeModel

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Theme.brand.opacity(0.18))
                Image(systemName: "arrow.triangle.merge")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.iris)
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("Result").font(.system(size: 13, weight: .semibold))
                    if model.isDirty {
                        Circle().fill(Theme.changed).frame(width: 7, height: 7).help("Unsaved changes")
                    }
                }
                Text(destination)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button {
                model.save()
            } label: {
                Label(model.isMergetool ? "Save Result" : "Save…", systemImage: "square.and.arrow.down").padding(.horizontal, 2)
            }
            .buttonStyle(GlowButtonStyle())
            .controlSize(.small)
            .help(model.isMergetool ? "Write the result for git (⌘S), then quit to finish" : "Save the merged result (⌘S)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var destination: String {
        guard let output = model.output else { return "Not saved yet" }
        let path = (output.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
        return model.isMergetool ? "git mergetool · writes \(path) · quit Moire when done" : path
    }
}

/// What one changed chunk puts in the result, with the buttons to choose it.
private struct ResultBlock: View {
    @Bindable var model: MergeModel
    let merge: ThreeWayMerge
    let index: Int
    @State private var isHovered = false
    @AppStorage("fontSize") private var fontSize = 12.5

    private var chunk: ThreeWayMerge.Chunk { merge.chunks[index] }
    private var resolution: ThreeWayMerge.Resolution? { model.resolution(of: index) }
    private var isCurrent: Bool { model.currentChunk == index }
    private var isOpenConflict: Bool { chunk.kind == .conflict && resolution == nil }

    var body: some View {
        Group {
            if model.editingChunk == index {
                editor
            } else if let lines = merge.resolvedLines(of: index, resolution: resolution) {
                resolved(lines)
            } else {
                conflictCard
            }
        }
        .overlay(alignment: .leading) {
            if isCurrent {
                Capsule().fill(Theme.brand).frame(width: 3).padding(.vertical, 1).transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { model.currentChunk = index }
        .contextMenu { ResolveMenuItems(model: model, index: index, canReset: resolution != nil) }
        .animation(.smooth(duration: 0.2), value: isCurrent)
    }

    private var accent: Color {
        if chunk.kind == .conflict { return MergeTheme.resolved }
        return switch resolution {
        case nil: switch chunk.kind {
            case .changedLeft: MergeTheme.left
            case .changedRight: MergeTheme.right
            case .changedBoth: MergeTheme.both
            case .unchanged, .conflict: MergeTheme.base
            }
        case .left: MergeTheme.left
        case .right: MergeTheme.right
        case .base: MergeTheme.base
        case .leftThenRight, .rightThenLeft: MergeTheme.both
        case .edited: MergeTheme.edited
        }
    }

    private var sourceName: String {
        switch resolution {
        case nil: switch chunk.kind {
            case .changedLeft: "From left"
            case .changedRight: "From right"
            case .changedBoth: "Same on both sides"
            case .unchanged, .conflict: "Unchanged"
            }
        case .left: "Left"
        case .right: "Right"
        case .base: "Base"
        case .leftThenRight: "Left, then right"
        case .rightThenLeft: "Right, then left"
        case .edited: "Edited"
        }
    }

    private func resolved(_ lines: [TextLine]) -> some View {
        VStack(spacing: 0) {
            if lines.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "minus.circle").font(.system(size: 9, weight: .bold))
                    Text(chunk.kind == .conflict ? "Resolved by removing these lines" : "Lines removed")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(accent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 56)
                .padding(.vertical, 3)
                .background(Hatching(color: accent.opacity(0.25)))
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { offset, line in
                MergeLineCell(number: model.resultStarts[index] + offset, segments: plainSegments(line.text), accent: accent)
            }
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 6) {
                if chunk.kind == .conflict {
                    Chip(text: sourceName, color: MergeTheme.resolved, systemImage: "checkmark")
                } else if resolution != nil {
                    Chip(text: sourceName, color: accent)
                }
                ResolveBar(model: model, index: index, canReset: resolution != nil)
            }
            .opacity(isHovered || isCurrent ? 1 : 0)
            .scaleEffect(isHovered || isCurrent ? 1 : 0.9, anchor: .trailing)
            .animation(.spring(duration: 0.25, bounce: 0.3), value: isHovered || isCurrent)
            .allowsHitTesting(isHovered || isCurrent)
            .padding(.top, 2)
            .padding(.trailing, 12)
        }
    }

    private var conflictCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10, weight: .bold))
                Text("Conflict \(model.conflictNumber(of: index) ?? 0) of \(model.conflictCount)")
                    .font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 8)
                ResolveBar(model: model, index: index, canReset: false)
            }
            .foregroundStyle(MergeTheme.conflict)
            .padding(.leading, 14)
            .padding(.trailing, 12)
            .padding(.vertical, 5)
            versionLines(.left)
            versionLines(.right)
        }
        .background(MergeTheme.conflict.opacity(0.06))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(MergeTheme.conflict.opacity(isCurrent ? 0.7 : 0.35), lineWidth: isCurrent ? 1.5 : 1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
    }

    private func versionLines(_ version: ThreeWayMerge.Version) -> some View {
        let lines = merge.lines(of: version, in: index)
        let color = MergeTheme.color(for: version)
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(version.name).font(.system(size: 10, weight: .bold))
                Text(model[version].title).font(.system(size: 10)).lineLimit(1)
            }
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 56)
            .padding(.vertical, 2)
            if lines.isEmpty {
                Text("Removed these lines")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 56)
                    .padding(.vertical, 2)
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                MergeLineCell(number: nil, segments: plainSegments(line.text), accent: color)
            }
        }
    }

    private var editor: some View {
        let lineCount = max(model.editDraft.count { $0 == "\n" } + 1, 3)
        return VStack(alignment: .leading, spacing: 0) {
            TextEditor(text: $model.editDraft)
                .font(Theme.code(size: fontSize))
                .scrollContentBackground(.hidden)
                .autocorrectionDisabled()
                .frame(height: min(CGFloat(lineCount) * fontSize * 1.32 + 12, 420))
                .padding(.leading, 50)
                .padding(.vertical, 4)
            HStack(spacing: 8) {
                Text("Editing the result by hand").font(.system(size: 11, weight: .medium)).foregroundStyle(MergeTheme.edited)
                Spacer()
                Button("Cancel") { model.cancelEdit() }
                    .keyboardShortcut(.cancelAction)
                Button("Done") { withAnimation(.smooth) { model.commitEdit() } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.iris)
            }
            .controlSize(.small)
            .padding(.leading, 56)
            .padding(.trailing, 12)
            .padding(.bottom, 6)
        }
        .background(MergeTheme.edited.opacity(0.07))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(MergeTheme.edited.opacity(0.5)))
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
    }
}

/// Take Left, Take Right, Take Both and Edit for one chunk, in a small glass capsule.
private struct ResolveBar: View {
    let model: MergeModel
    let index: Int
    let canReset: Bool

    var body: some View {
        HStack(spacing: 0) {
            button("Take Left", systemImage: "arrow.left.to.line", color: MergeTheme.left) { model.resolve(index, .left) }
            divider
            button("Take Right", systemImage: "arrow.right.to.line", color: MergeTheme.right) { model.resolve(index, .right) }
            divider
            Menu {
                Button("Left, then Right") { withAnimation(.smooth) { model.resolve(index, .leftThenRight) } }
                Button("Right, then Left") { withAnimation(.smooth) { model.resolve(index, .rightThenLeft) } }
            } label: {
                Label("Take Both", systemImage: "square.stack")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 10.5, weight: .semibold))
            } primaryAction: {
                withAnimation(.smooth) { model.resolve(index, .leftThenRight) }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .tint(MergeTheme.both)
            .foregroundStyle(MergeTheme.both)
            .padding(.horizontal, 6)
            .help("Keep both versions, left first (click the arrow for right first)")
            divider
            iconButton("pencil", help: "Edit the result by hand") { model.beginEdit(index) }
            if canReset {
                divider
                iconButton("arrow.uturn.backward", help: "Undo this choice") { withAnimation(.smooth) { model.reset(index) } }
            }
        }
        .padding(.horizontal, 3)
        .frame(height: 22)
        .glass(in: Capsule())
    }

    private var divider: some View {
        Divider().frame(height: 12)
    }

    private func button(_ title: String, systemImage: String, color: Color, action: @escaping () -> Void) -> some View {
        Button { withAnimation(.smooth) { action() } } label: {
            Label(title, systemImage: systemImage)
                .labelStyle(.titleAndIcon)
                .font(.system(size: 10.5, weight: .semibold))
                .padding(.horizontal, 7)
                .frame(height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(color)
        .help("Use the \(title.dropFirst(5).lowercased()) version")
    }

    private func iconButton(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 24, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.iris)
        .help(help)
    }
}

private struct ResolveMenuItems: View {
    let model: MergeModel
    let index: Int
    let canReset: Bool

    var body: some View {
        Button("Take Left", systemImage: "arrow.left.to.line") { model.resolve(index, .left) }
        Button("Take Right", systemImage: "arrow.right.to.line") { model.resolve(index, .right) }
        Button("Take Both, Left First") { model.resolve(index, .leftThenRight) }
        Button("Take Both, Right First") { model.resolve(index, .rightThenLeft) }
        Button("Take Base") { model.resolve(index, .base) }
        Divider()
        Button("Edit by Hand", systemImage: "pencil") { model.beginEdit(index) }
        if canReset {
            Button("Undo Choice", systemImage: "arrow.uturn.backward") { model.reset(index) }
        }
    }
}

// MARK: Pieces

private struct MergeLineCell: View {
    let number: Int?
    let segments: [Segment]
    var accent: Color?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(number.map { String($0 + 1) } ?? "")
                .foregroundStyle(accent.map { $0.opacity(0.85) } ?? Theme.gutterText)
                .frame(width: 46, alignment: .trailing)
                .padding(.trailing, 10)
            Text(attributed)
                .foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(.vertical, 1.5)
        .padding(.trailing, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.map { $0.opacity(0.11) } ?? .clear)
    }

    private var attributed: AttributedString {
        var result = AttributedString()
        for segment in segments {
            var part = AttributedString(segment.text.replacingOccurrences(of: "\t", with: "    "))
            if segment.isChanged, let accent {
                part.backgroundColor = accent.opacity(0.32)
            }
            result += part
        }
        return result.characters.isEmpty ? AttributedString(" ") : result
    }
}

private func plainSegments(_ text: String) -> [Segment] {
    [Segment(text, isChanged: false)]
}

private struct MergeFoldRow: View {
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

private struct MergeStatusBar: View {
    @Bindable var model: MergeModel

    var body: some View {
        HStack(spacing: 8) {
            if model.merge != nil {
                if model.conflictCount == 0 {
                    Chip(text: "No conflicts", color: MergeTheme.resolved, systemImage: "checkmark")
                } else if model.unresolvedCount == 0 {
                    Chip(text: "All \(model.conflictCount) resolved", color: MergeTheme.resolved, systemImage: "checkmark")
                } else {
                    Chip(text: "\(model.unresolvedCount) of \(model.conflictCount) to resolve", color: MergeTheme.conflict, systemImage: "exclamationmark")
                }
                Chip(text: "\(model.changeCount - model.conflictCount) merged", color: Theme.iris)
            }
            if model.isComputing {
                ProgressView().controlSize(.mini)
            }

            Spacer()

            if model.conflictCount > 0 {
                HStack(spacing: 2) {
                    Button { model.goToPreviousConflict() } label: { Image(systemName: "chevron.up") }
                        .help("Previous conflict (⌃⌘↑)")
                    Text(position)
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .frame(minWidth: 80)
                    Button { model.goToNextConflict() } label: { Image(systemName: "chevron.down") }
                        .help("Next conflict (⌃⌘↓)")
                }
                .buttonStyle(.borderless)
            }

            Toggle(isOn: $model.onlyChanges) {
                Image(systemName: "rectangle.compress.vertical")
            }
            .toggleStyle(.button)
            .buttonStyle(.borderless)
            .help("Only show changes, with a few lines around them")
        }
        .font(.system(size: 12))
        .controlSize(.small)
    }

    private var position: String {
        if let current = model.currentChunk, let number = model.conflictNumber(of: current) {
            return "Conflict \(number) of \(model.conflictCount)"
        }
        return model.conflictCount == 1 ? "1 conflict" : "\(model.conflictCount) conflicts"
    }
}

/// The first merge screen: three slots for the three files.
private struct MergeEmptyView: View {
    let model: MergeModel
    @State private var isTargeted = false

    var body: some View {
        ZStack {
            MoireBackground(opacity: isTargeted ? 0.55 : 0.32)
                .animation(.smooth(duration: 0.4), value: isTargeted)
            VStack(spacing: 22) {
                VStack(spacing: 8) {
                    Text("Merge three files")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("Your version, theirs, and the base they both started from.\nChanges merge by themselves; you choose where they conflict.")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                HStack(spacing: 12) {
                    ForEach(ThreeWayMerge.Version.displayOrder, id: \.self) { version in
                        SourceSlot(model: model, version: version)
                    }
                }
                Button { model.chooseFiles() } label: {
                    Label("Choose Files…", systemImage: "doc.on.doc").padding(.horizontal, 6)
                }
                .buttonStyle(GlowButtonStyle())
                Text("Also runs as git mergetool: Moire --merge BASE LOCAL REMOTE MERGED")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            .padding(40)
            .glass(in: RoundedRectangle(cornerRadius: 24), fallback: .ultraThinMaterial)
            .overlay {
                if isTargeted { RoundedRectangle(cornerRadius: 24).strokeBorder(Theme.brand, lineWidth: 2) }
            }
            .cardShadow()
            .scaleEffect(isTargeted ? 1.03 : 1)
            .animation(.spring(duration: 0.35, bounce: 0.3), value: isTargeted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            model.open(urls)
            return !urls.isEmpty
        } isTargeted: { isTargeted = $0 }
    }
}

private struct SourceSlot: View {
    let model: MergeModel
    let version: ThreeWayMerge.Version
    @State private var isTargeted = false
    @State private var isHovered = false

    var body: some View {
        let source = model[version]
        let color = MergeTheme.color(for: version)
        Button { model.openPanel(for: version) } label: {
            VStack(spacing: 6) {
                ZStack {
                    Circle().fill(color.opacity(0.14))
                    Image(systemName: source.url == nil ? "plus" : "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(color)
                }
                .frame(width: 36, height: 36)
                Text(version.name).font(.system(size: 13, weight: .semibold))
                Text(source.url?.lastPathComponent ?? version.role)
                    .font(.system(size: 11))
                    .foregroundStyle(source.url == nil ? .secondary : color)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(width: 150, height: 110)
            .glass(in: RoundedRectangle(cornerRadius: 14), interactive: true)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(isTargeted || isHovered ? AnyShapeStyle(color) : AnyShapeStyle(Theme.paneBorder), style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: source.url == nil ? [5, 4] : []))
            )
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .scaleEffect(isTargeted ? 1.04 : 1)
        .animation(.spring(duration: 0.25), value: isTargeted)
        .help("Choose the \(version.name.lowercased()) file, or drop it here")
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.load(url, into: version)
            return true
        } isTargeted: { isTargeted = $0 }
    }
}
