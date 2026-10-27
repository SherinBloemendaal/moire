import MoireKit
import SwiftUI

struct FolderView: View {
    @Bindable var model: FolderModel
    /// Opens a pair of files in the text comparison. A missing side is `nil`.
    var openFiles: (URL?, URL?) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                FolderCard(model: model, side: .left)
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
                .help("Swap the left and right folder")
                .padding(.horizontal, 10)
                FolderCard(model: model, side: .right)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Group {
                if model.comparison != nil {
                    list
                } else {
                    placeholder
                }
            }
            .background(Theme.pane, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.paneBorder))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 14)

            statusBar
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
        }
        .background(Theme.window)
        .dropDestination(for: URL.self) { urls, _ in
            model.open(urls)
            return true
        }
        .alert("Could not compare the folders", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var list: some View {
        List(selection: $model.selection) {
            ForEach(model.visibleItems) { item in
                FolderRow(item: item, isCollapsed: model.collapsed.contains(item.path)) {
                    withAnimation(.smooth(duration: 0.2)) { model.toggle(item) }
                }
                .tag(item.path)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: String.self) { paths in
            if let path = paths.first, let item = model.comparison?.items.first(where: { $0.path == path }), !item.isDirectory {
                Button("Compare Files") { open(item) }
            }
        } primaryAction: { paths in
            guard let path = paths.first, let item = model.comparison?.items.first(where: { $0.path == path }) else { return }
            if item.isDirectory {
                withAnimation(.smooth(duration: 0.2)) { model.toggle(item) }
            } else {
                open(item)
            }
        }
    }

    private func open(_ item: FolderComparison.Item) {
        guard let comparison = model.comparison else { return }
        openFiles(
            item.status == .rightOnly ? nil : comparison.left.appending(path: item.path),
            item.status == .leftOnly ? nil : comparison.right.appending(path: item.path)
        )
    }

    private var placeholder: some View {
        ZStack {
            MoireBackground(opacity: 0.22)
            VStack(spacing: 10) {
                Image(systemName: "folder.badge.questionmark")
                    .font(.system(size: 36))
                    .foregroundStyle(Theme.brand)
                Text(model.isComparing ? "Comparing…" : "Choose or drop two folders")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                Text("Every file is compared by its contents. Double-click a file to see what changed.")
                    .foregroundStyle(.secondary)
            }
            .padding(30)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if model.comparison != nil {
                Chip(text: "\(model.count(.different)) different", color: Theme.changed)
                Chip(text: "\(model.count(.leftOnly)) left only", color: Theme.removed)
                Chip(text: "\(model.count(.rightOnly)) right only", color: Theme.added)
                Chip(text: "\(model.count(.identical)) identical", color: Theme.iris)
            }
            if model.isComparing {
                ProgressView().controlSize(.mini)
            }
            Spacer()
            Toggle("Hidden Files", isOn: Binding(get: { !model.skipHidden }, set: { model.skipHidden = !$0 }))
                .toggleStyle(.checkbox)
                .help("Include files and folders whose name starts with a dot")
            Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Compare again")
                .disabled(model.left == nil || model.right == nil)
            Picker("Show", selection: $model.filter) {
                Text("All").tag(FolderModel.Filter.all)
                Text("Differences").tag(FolderModel.Filter.differences)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .font(.system(size: 12))
        .controlSize(.small)
    }
}

private struct FolderCard: View {
    let model: FolderModel
    let side: SideID
    @State private var isTargeted = false

    var body: some View {
        let url = side == .left ? model.left : model.right
        Button { model.choose(side) } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(side == .left ? Theme.removed.opacity(0.14) : Theme.added.opacity(0.14))
                    Image(systemName: "folder.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(side == .left ? Theme.removed : Theme.added)
                }
                .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(url?.lastPathComponent ?? "Choose the \(side.name.lowercased()) folder…")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(url.map { ($0.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath } ?? "Click, or drop a folder here")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Theme.pane, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isTargeted ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Theme.paneBorder), lineWidth: isTargeted ? 2 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(isTargeted ? 1.015 : 1)
        .animation(.spring(duration: 0.25), value: isTargeted)
        .dropDestination(for: URL.self) { urls, _ in
            guard let folder = urls.first(where: { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }) else { return false }
            model.set(folder, on: side)
            return true
        } isTargeted: { isTargeted = $0 }
    }
}

private struct FolderRow: View {
    let item: FolderComparison.Item
    let isCollapsed: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                if item.isDirectory {
                    Button(action: toggle) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                            .frame(width: 14, height: 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                } else {
                    Color.clear.frame(width: 14, height: 14)
                }
                Image(systemName: item.isDirectory ? "folder.fill" : "doc.text")
                    .foregroundStyle(item.isDirectory ? Theme.iris : .secondary)
                    .frame(width: 18)
                Text(item.name)
                    .lineLimit(1)
                    .foregroundStyle(item.status == .identical ? .secondary : .primary)
            }
            .padding(.leading, Double(item.depth) * 16)
            Spacer(minLength: 12)
            Text(size(item.leftSize))
                .frame(width: 80, alignment: .trailing)
                .foregroundStyle(.secondary)
            Text(size(item.rightSize))
                .frame(width: 80, alignment: .trailing)
                .foregroundStyle(.secondary)
            StatusPill(status: item.status)
                .frame(width: 96, alignment: .trailing)
        }
        .font(.system(size: 12))
        .monospacedDigit()
        .padding(.vertical, 1)
    }

    private func size(_ bytes: Int64?) -> String {
        guard let bytes, !item.isDirectory else { return "" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct StatusPill: View {
    let status: FolderComparison.Status

    var body: some View {
        let (text, color): (String, Color) = switch status {
        case .identical: ("Identical", Theme.gutterText)
        case .different: ("Different", Theme.changed)
        case .leftOnly: ("Left only", Theme.removed)
        case .rightOnly: ("Right only", Theme.added)
        }
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(status == .identical ? 0.08 : 0.14), in: Capsule())
    }
}
