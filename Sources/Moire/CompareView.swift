import MoireKit
import SwiftUI
import UniformTypeIdentifiers

struct CompareView: View {
    @Bindable var model: CompareModel
    var compareFolders: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if model.isEmpty && !model.isEditing {
                if model.isLoading {
                    ProgressView("Reading the files…").controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    EmptyCompareView(model: model, compareFolders: compareFolders)
                }
            } else {
                header
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 10)
                if model.fileView.isSpecial, !model.isEditing {
                    FileKindView(model: model)
                } else {
                    content
                        .background(Theme.pane, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.paneBorder))
                        .padding(.horizontal, 14)
                    StatusBar(model: model)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                }
            }
        }
        .background(Theme.window)
        .sheet(isPresented: $model.isGoToLineVisible) {
            GoToLineView(model: model)
        }
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
        HStack(spacing: 0) {
            SideCard(model: model, side: .left)
            Button {
                withAnimation(.spring(duration: 0.4, bounce: 0.35)) { model.swapSides() }
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Theme.brand, in: Circle())
                    .shadow(color: Theme.iris.opacity(0.45), radius: 8, y: 2)
            }
            .buttonStyle(.plain)
            .help("Swap the left and right side")
            .padding(.horizontal, 10)
            SideCard(model: model, side: .right)
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.isEditing {
            HStack(spacing: 0) {
                EditorPane(model: model, side: .left)
                Rectangle().fill(Theme.paneBorder).frame(width: 1)
                EditorPane(model: model, side: .right)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
        } else if model.hasBinarySide {
            BinaryComparisonView(left: model.left, right: model.right)
        } else if let display = model.display {
            let diff = display.diff
            if diff.statistics.isIdentical, diff.rowCount > 0, model.onlyChanges {
                IdenticalView(lineCount: diff.rowCount, showAll: { model.onlyChanges = false })
            } else {
                VStack(spacing: 0) {
                    if model.isSearchVisible {
                        FindBar(model: model)
                        Rectangle().fill(Theme.paneBorder).frame(height: 1)
                    }
                    DiffPane(model: model, display: display)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The name, location and actions of one side, and a drop target for a file.
private struct SideCard: View {
    let model: CompareModel
    let side: SideID
    @State private var isTargeted = false

    var body: some View {
        let value = model[side]
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(side == .left ? Theme.removed.opacity(0.14) : Theme.added.opacity(0.14))
                Image(systemName: value.url == nil ? "text.cursor" : (value.isBinary ? "doc.zipper" : "doc.text"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(side == .left ? Theme.removed : Theme.added)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(value.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if value.isDirty {
                        Circle().fill(Theme.changed).frame(width: 7, height: 7).help("Unsaved changes")
                    }
                }
                Text(value.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Menu {
                Button("Open File…", systemImage: "folder") { model.openPanel(for: side) }
                Button("Paste from Clipboard", systemImage: "doc.on.clipboard") { model.pasteClipboard(into: side) }
                if let url = value.url {
                    Button("Reload from Disk", systemImage: "arrow.clockwise") { model.load(url, into: side) }
                    Button("Show in Finder", systemImage: "magnifyingglass") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                Divider()
                Button("Save", systemImage: "square.and.arrow.down") { model.save(side) }
                    .disabled(value.isBinary || (value.url != nil && !value.isDirty))
                Button("Clear", systemImage: "xmark", role: .destructive) { model.clear(side) }
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
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.pane, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isTargeted ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Theme.paneBorder), lineWidth: isTargeted ? 2 : 1)
        )
        .scaleEffect(isTargeted ? 1.015 : 1)
        .animation(.spring(duration: 0.25), value: isTargeted)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.load(url, into: side)
            return true
        } isTargeted: { isTargeted = $0 }
    }
}

/// The whole text of one side in a plain editor. It keeps its own copy of the text, so typing
/// does not join the document into one string on every key.
private struct EditorPane: View {
    @Bindable var model: CompareModel
    let side: SideID
    @State private var text = ""
    /// What was last read from the model, or written to it.
    @State private var synced: (text: String, revision: Int)?

    var body: some View {
        TextEditor(text: $text)
            .font(Theme.code(size: model.fontSize))
            .scrollContentBackground(.hidden)
            .autocorrectionDisabled()
            .padding(10)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Type or paste the \(side.name.lowercased()) text")
                        .font(Theme.code(size: model.fontSize))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 10)
                        .allowsHitTesting(false)
                }
            }
            .onAppear { pull() }
            .onChange(of: model[side].revision) { _, revision in
                if revision != synced?.revision { pull() }
            }
            .onChange(of: text) { _, new in
                guard new != synced?.text else { return }
                model.setText(new, on: side)
                synced = (new, model[side].revision)
            }
    }

    private func pull() {
        let current = model[side].text
        synced = (current, model[side].revision)
        text = current
    }
}

private struct StatusBar: View {
    @Bindable var model: CompareModel

    var body: some View {
        HStack(spacing: 8) {
            if let statistics = model.diff?.statistics, !model.hasBinarySide {
                if statistics.isIdentical {
                    Chip(text: "Identical", color: Theme.iris, systemImage: "checkmark")
                } else {
                    Chip(text: "\(statistics.added) added", color: Theme.added)
                    Chip(text: "\(statistics.removed) removed", color: Theme.removed)
                    Chip(text: "\(statistics.changed) changed", color: Theme.changed)
                }
            }
            if model.isComputing || model.isLoading {
                ProgressView().controlSize(.mini)
            }

            Spacer()

            if model.hunkCount > 0, !model.isEditing {
                HStack(spacing: 2) {
                    Button { model.goToPreviousChange() } label: { Image(systemName: "chevron.up") }
                        .help("Previous change (⌥⌘↑)")
                    Text(model.currentHunk.map { "\($0 + 1) of \(model.hunkCount)" } ?? "\(model.hunkCount) changes")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .frame(minWidth: 70)
                    Button { model.goToNextChange() } label: { Image(systemName: "chevron.down") }
                        .help("Next change (⌥⌘↓)")
                }
                .buttonStyle(.borderless)
            }

            Menu {
                Picker("Whitespace", selection: $model.options.whitespace) {
                    Text("Compare All Spaces").tag(DiffOptions.Whitespace.exact)
                    Text("Ignore Spaces at Line Ends").tag(DiffOptions.Whitespace.ignoreLeadingAndTrailing)
                    Text("Ignore All Spaces").tag(DiffOptions.Whitespace.ignoreAll)
                }
                .pickerStyle(.inline)
                Toggle("Ignore Case", isOn: $model.options.ignoreCase)
            } label: {
                Label("Options", systemImage: "slider.horizontal.3")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("What counts as a difference")

            Toggle(isOn: $model.onlyChanges) {
                Image(systemName: "rectangle.compress.vertical")
            }
            .toggleStyle(.button)
            .buttonStyle(.borderless)
            .help("Only show changes, with a few lines around them")

            Picker("Layout", selection: $model.layout) {
                Image(systemName: "rectangle.split.2x1").tag(CompareModel.Layout.sideBySide).help("Side by side")
                Image(systemName: "rectangle.split.1x2").tag(CompareModel.Layout.unified).help("Unified")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .font(.system(size: 12))
        .controlSize(.small)
    }
}

private struct BinaryComparisonView: View {
    let left: Side
    let right: Side

    var body: some View {
        let identical = switch (left.content, right.content) {
        case (.binary(let a), .binary(let b)): a == b
        default: false
        }
        VStack(spacing: 14) {
            Image(systemName: identical ? "checkmark.seal.fill" : "doc.zipper")
                .font(.system(size: 40))
                .foregroundStyle(Theme.brand)
            Text(identical ? "The files are identical" : "The files differ")
                .font(.title2.weight(.semibold))
            Text("At least one side is not a text file, so Moire compares the bytes only.")
                .foregroundStyle(.secondary)
            HStack(spacing: 24) {
                size(of: left, label: "Left")
                size(of: right, label: "Right")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func size(of side: Side, label: String) -> some View {
        let bytes: Int64 = switch side.content {
        case .binary(let data): Int64(data.count)
        case .text(let document): Int64(document.utf8.count)
        }
        return VStack(spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)).font(.system(.body, design: .monospaced))
        }
    }
}

private struct IdenticalView: View {
    let lineCount: Int
    let showAll: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 40)).foregroundStyle(Theme.brand)
            Text("No differences").font(.title2.weight(.semibold))
            Text("All \(lineCount) lines are the same.").foregroundStyle(.secondary)
            Button("Show All Lines", action: showAll).buttonStyle(.link)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The first screen: a drop target with the moiré drifting behind it.
private struct EmptyCompareView: View {
    let model: CompareModel
    let compareFolders: () -> Void
    @State private var isTargeted = false

    var body: some View {
        ZStack {
            MoireBackground(opacity: isTargeted ? 0.55 : 0.32)
                .animation(.smooth(duration: 0.4), value: isTargeted)
            VStack(spacing: 22) {
                VStack(spacing: 8) {
                    Text("Drop two files to compare")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("Or open them, paste text, or compare whole folders.")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Button { model.openPanel(for: nil) } label: {
                        Label("Open Files…", systemImage: "doc.on.doc").padding(.horizontal, 6)
                    }
                    .buttonStyle(GlowButtonStyle())
                    .keyboardShortcut("o")

                    Button { model.isEditing = true } label: {
                        Label("Paste Text", systemImage: "text.alignleft").padding(.horizontal, 6)
                    }
                    .buttonStyle(GlassButtonStyle())

                    Button(action: compareFolders) {
                        Label("Compare Folders…", systemImage: "folder").padding(.horizontal, 6)
                    }
                    .buttonStyle(GlassButtonStyle())
                }
            }
            .padding(40)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(isTargeted ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Theme.paneBorder), lineWidth: isTargeted ? 2 : 1))
            .shadow(color: .black.opacity(0.12), radius: 30, y: 10)
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

struct GlowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.vertical, 9)
            .padding(.horizontal, 12)
            .background(Theme.brand, in: Capsule())
            .shadow(color: Theme.iris.opacity(configuration.isPressed ? 0.2 : 0.45), radius: 12, y: 4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

struct GlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.vertical, 9)
            .padding(.horizontal, 12)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.paneBorder))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

/// The aligned lines with the change map beside them, for any comparison model.
struct DiffPane: View {
    let model: CompareModel
    let display: DiffDisplay

    var body: some View {
        HStack(spacing: 0) {
            DiffListView(model: model, display: display, state: DiffListState(
                generation: model.displayGeneration,
                replacements: model.replacements,
                currentHunk: model.currentHunk,
                fontSize: model.fontSize,
                scrollRequest: model.scrollRequest,
                searchGeneration: model.searchGeneration,
                flashedLine: model.flashedLine,
                alignmentMarks: model.alignmentMarks
            ))
            ChangeMap(model: model, diff: display.diff)
        }
    }
}
