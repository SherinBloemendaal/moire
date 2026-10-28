import AppKit
import MoireKit
import SwiftUI

struct FolderView: View {
    @Bindable var model: FolderModel
    /// Opens a pair of files in the text comparison. A missing side is `nil`.
    var openFiles: (URL?, URL?) -> Void
    /// Opens copies of files from a server, read-only.
    var openDownloaded: ((url: URL, origin: String)?, (url: URL, origin: String)?) -> Void
    @State private var selection: Set<Int> = []
    @State private var syncItems: [Int]?
    @State private var showsFilters = false
    @State private var connectRequest: ConnectRequest?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                FolderCard(model: model, side: .left) { connectRequest = ConnectRequest(side: .left) }
                Button {
                    withAnimation(.spring(duration: 0.4, bounce: 0.35)) { model.swapSides() }
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Theme.brand, in: Circle())
                        .shadow(color: Theme.iris.opacity(0.45), radius: 8, y: 2)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Swap the left and right folder")
                .padding(.horizontal, 10)
                FolderCard(model: model, side: .right) { connectRequest = ConnectRequest(side: .right) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Group {
                if let tree = model.tree, model.hasBothSides {
                    FolderOutline(
                        tree: tree,
                        version: model.version,
                        differencesOnly: model.filter == .differences,
                        leftIsLocal: model.isLocal(.left),
                        rightIsLocal: model.isLocal(.right),
                        selection: $selection,
                        perform: perform
                    )
                } else {
                    placeholder
                }
            }
            .background(Theme.pane, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.paneBorder))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 14)

            statusBar
                .glassBar()
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
        }
        .background(Theme.window)
        .dropDestination(for: URL.self) { urls, _ in
            model.open(urls)
            return true
        }
        // Item numbers belong to one comparison; a new one numbers its items afresh.
        .onChange(of: model.generation) { selection = [] }
        .sheet(item: Binding(get: { syncItems.map(SyncRequest.init) }, set: { syncItems = $0?.items })) { request in
            SyncSheet(model: model, items: request.items)
        }
        .sheet(item: $connectRequest) { request in
            ConnectSheet(model: model, side: request.side)
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

    private func perform(_ action: FolderItemAction) {
        switch action {
        case .open(let item):
            guard !model.canOpen(item) else {
                openFiles(model.url(of: item, on: .left), model.url(of: item, on: .right))
                return
            }
            // A file on a server is downloaded to a temporary folder and shown read-only.
            Task {
                do {
                    let (left, right) = try await model.filesForComparison(item)
                    openDownloaded(left, right)
                } catch {
                    model.errorMessage = "Could not download the file: \(error.localizedDescription)"
                }
            }
        case .showInFinder(let items, let side):
            model.showInFinder(items, side: side)
        case .trash(let items, let side):
            model.trash(items, side: side)
        case .rename(let item, let side):
            model.rename(item, side: side)
        case .sync(let items):
            guard model.canPlanSync else { return }
            syncItems = items
        }
    }

    private var placeholder: some View {
        ZStack {
            MoireBackground(opacity: 0.22)
            if !model.unpacking.isEmpty {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.large)
                    Text("Unpacking \(model.unpacking.joined(separator: " and "))…")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                }
                .padding(30)
                .glass(in: RoundedRectangle(cornerRadius: 20), fallback: .ultraThinMaterial)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: 36))
                        .foregroundStyle(Theme.brand)
                    Text("Choose or drop two folders")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                    Text("Moire compares every file in them, on all cores. Double-click a file to see what changed.")
                        .foregroundStyle(.secondary)
                    Text("Folders on a server work too: SFTP, FTP, FTPS and S3, from the server button on a card.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(30)
                .glass(in: RoundedRectangle(cornerRadius: 20), fallback: .ultraThinMaterial)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if model.isComparing {
                ProgressLine(progress: model.progress, startedAt: model.startedAt)
                Button("Stop", systemImage: "stop.fill") { model.stop() }
                    .buttonStyle(.bar)
                    .help("Stop comparing and keep what was found so far")
            } else if model.tree != nil, model.hasBothSides {
                Chip(text: "\(model.count(.different)) different", color: Theme.changed)
                Chip(text: "\(model.count(.leftOnly)) left only", color: Theme.removed)
                Chip(text: "\(model.count(.rightOnly)) right only", color: Theme.added)
                Chip(text: "\(model.count(.identical)) identical", color: Theme.iris)
                if model.count(.unreadable) > 0 {
                    Chip(text: "\(model.count(.unreadable)) unreadable", color: Theme.removed, systemImage: "exclamationmark.triangle.fill")
                }
                if let finishedIn = model.finishedIn {
                    Text(finishedIn.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow, maximumUnitCount: 2)))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            Spacer()

            Picker("Compare", selection: Binding(get: { model.method }, set: { model.pick($0) })) {
                Text("Metadata").tag(CompareMethod.metadata)
                Text("Quick").tag(CompareMethod.quick)
                Text("Binary").tag(CompareMethod.binary)
                Text("Lines").tag(CompareMethod.lines)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Metadata: size and date, nothing is read. Quick: the first and last 64 KB. Binary: every byte. Lines: as text, with the ignore options.")

            Button { showsFilters.toggle() } label: {
                Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
            }
            .buttonStyle(.bar)
            .popover(isPresented: $showsFilters, arrowEdge: .top) { FilterPopover(model: model) }
            .help("Include and exclude masks, .gitignore, hidden files")

            Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.bar)
                .help("Compare again")
                .disabled(!model.hasBothSides)

            Button { syncItems = Array(selection) } label: { Image(systemName: "arrow.triangle.2.circlepath") }
                .buttonStyle(.bar)
                .help(model.hasBothSides && !model.canSync ? "Sync works between folders on this Mac only"
                    : !model.isComplete && model.tree != nil ? "Compare to the end first: a stopped comparison is not complete enough to sync"
                    : "Sync the folders, or the selected items")
                .disabled(!model.canPlanSync)

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

private struct SyncRequest: Identifiable {
    let items: [Int]
    var id: [Int] { items }
}

/// Live numbers while a comparison runs.
private struct ProgressLine: View {
    let progress: FolderProgress?
    let startedAt: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            HStack(spacing: 8) {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 120)
                Text(text(now: context.date))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
    }

    private var fraction: Double {
        guard let progress, progress.bytesToRead > 0 else { return 0 }
        return Double(progress.bytesRead) / Double(progress.bytesToRead)
    }

    private func text(now: Date) -> String {
        guard let progress else { return "Starting…" }
        var parts = ["\(progress.itemsFound.formatted()) items"]
        if progress.filesToRead > 0 {
            parts.append("read \(progress.filesRead.formatted()) of \(progress.filesToRead.formatted()) files")
        }
        if let startedAt {
            let seconds = max(now.timeIntervalSince(startedAt), 0.001)
            let rate = Double(progress.bytesRead) / seconds
            if rate > 0 {
                parts.append(ByteCountFormatter.string(fromByteCount: Int64(rate), countStyle: .file) + "/s")
                let left = Double(progress.bytesToRead - progress.bytesRead) / rate
                if left > 1 {
                    parts.append(Duration.seconds(left).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2)) + " left")
                }
            }
        }
        return parts.joined(separator: " · ")
    }
}

private struct FilterPopover: View {
    @Bindable var model: FolderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Filters").font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                Text("Only files matching").font(.caption).foregroundStyle(.secondary)
                TextField("*.swift, *.md", text: $model.includeText)
                    .onSubmit { model.applyMasks() }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Leave out").font(.caption).foregroundStyle(.secondary)
                TextField("node_modules/, *.log, build/", text: $model.excludeText)
                    .onSubmit { model.applyMasks() }
            }
            Text("Masks work like .gitignore: * and ? within a name, ** across folders, a trailing / for folders only.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Follow .gitignore files", isOn: $model.useGitignore)
            Toggle("Include hidden files", isOn: Binding(get: { !model.skipHidden }, set: { model.skipHidden = !$0 }))
            HStack {
                Spacer()
                Button("Apply") { model.applyMasks() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(16)
        .frame(width: 320)
    }
}

private struct FolderCard: View {
    let model: FolderModel
    let side: SideID
    let connect: () -> Void
    @State private var isTargeted = false

    private var tint: Color { side == .left ? Theme.removed : Theme.added }

    var body: some View {
        let location = model.location(side)
        let volume = side == .left ? model.leftVolume : model.rightVolume
        HStack(spacing: 0) {
            Button { model.choose(side) } label: {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(tint.opacity(0.14))
                        Image(systemName: icon(location, volume))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(tint)
                    }
                    .frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(title(location))
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)
                            if let badge = badge(location, volume) {
                                Text(badge)
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .foregroundStyle(Theme.cyan)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1.5)
                                    .background(Theme.cyan.opacity(0.14), in: Capsule())
                                    .help(archive(location) != nil
                                        ? "Unpacked into a temporary folder for this comparison, and removed again afterwards."
                                        : "Compared by size and date unless you pick another method: reading every file over the network is slow.")
                            }
                        }
                        Text(subtitle(location))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 10)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                Button("Choose Folder…", systemImage: "folder") { model.choose(side) }
                Button("Connect to Server…", systemImage: "server.rack", action: connect)
                let recents = RecentServers.load()
                if !recents.isEmpty {
                    Divider()
                    Section("Recent Servers") {
                        ForEach(recents.prefix(6), id: \.self) { recent in
                            Button(recent.displayName) { model.set(recent, on: side) }
                        }
                    }
                }
            } label: {
                Image(systemName: "server.rack")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Choose a folder, or connect to a server (SFTP, FTP, S3)")
            .padding(.trailing, 6)
        }
        .background(Theme.pane, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isTargeted ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Theme.paneBorder), lineWidth: isTargeted ? 2 : 1)
        )
        .scaleEffect(isTargeted ? 1.015 : 1)
        .animation(.spring(duration: 0.25), value: isTargeted)
        .dropDestination(for: URL.self) { urls, _ in
            guard let folder = urls.first(where: { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }) else { return false }
            model.set(folder, on: side)
            return true
        } isTargeted: { isTargeted = $0 }
    }

    /// The archive a local side was unpacked from, if it was.
    private func archive(_ location: FolderLocation?) -> URL? {
        location?.localURL.flatMap { model.archiveOrigins[$0] }
    }

    private func icon(_ location: FolderLocation?, _ volume: Volume?) -> String {
        if location?.remote != nil { return "server.rack" }
        if archive(location) != nil { return "doc.zipper" }
        return volume?.isLocal == false ? "network" : "folder.fill"
    }

    private func title(_ location: FolderLocation?) -> String {
        if let archive = archive(location) { return archive.lastPathComponent }
        return switch location {
        case .local(let url): url.lastPathComponent
        case .remote(let remote): remote.name
        case nil: "Choose the \(side.name.lowercased()) folder…"
        }
    }

    private func subtitle(_ location: FolderLocation?) -> String {
        if let archive = archive(location) {
            return (archive.deletingLastPathComponent().path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
        }
        return switch location {
        case .local(let url): (url.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
        case .remote(let remote): remote.displayName
        case nil: "Click, or drop a folder here"
        }
    }

    private func badge(_ location: FolderLocation?, _ volume: Volume?) -> String? {
        if let remote = location?.remote { return remote.scheme.title }
        if archive(location) != nil { return "Archive" }
        if let volume, !volume.isLocal { return "Network disk" }
        return nil
    }
}

/// Choose how to sync, look at the plan, then run it.
struct SyncSheet: View {
    let model: FolderModel
    let items: [Int]
    @Environment(\.dismiss) private var dismiss
    @State private var mode = FolderSync.Mode.update
    @State private var direction = FolderSync.Direction.leftToRight
    @State private var done: Int?
    @State private var failures: [FolderSync.Failure]?
    /// Worked out again only when the mode or direction changes, not on every progress update.
    @State private var job: FolderModel.SyncJob?
    @State private var stop = FolderModel.SyncStop()
    @State private var wasStopped = false

    private var plan: FolderSync.Plan? { job?.plan }

    private struct Choice: Hashable {
        let mode: FolderSync.Mode
        let direction: FolderSync.Direction
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(items.isEmpty ? "Sync the Folders" : "Sync \(items.count == 1 ? "1 Item" : "\(items.count) Items")")
                .font(.title3.weight(.semibold))

            Picker("Direction", selection: $direction) {
                Label("Left to Right", systemImage: "arrow.right").tag(FolderSync.Direction.leftToRight)
                Label("Right to Left", systemImage: "arrow.left").tag(FolderSync.Direction.rightToLeft)
                Label("Both Ways", systemImage: "arrow.left.arrow.right").tag(FolderSync.Direction.both)
            }
            .pickerStyle(.segmented)

            Picker("Mode", selection: $mode) {
                Text("Update").tag(FolderSync.Mode.update)
                Text("Mirror").tag(FolderSync.Mode.mirror)
            }
            .pickerStyle(.segmented)
            .disabled(direction == .both)

            Text(explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let plan {
                HStack(spacing: 8) {
                    Chip(text: "\(plan.copies) to copy", color: Theme.added)
                    Chip(text: ByteCountFormatter.string(fromByteCount: plan.bytesToCopy, countStyle: .file), color: Theme.iris)
                    Chip(text: "\(plan.trashes) to Trash", color: Theme.removed)
                }
                List(Array(plan.actions.prefix(500).enumerated()), id: \.offset) { _, action in
                    ActionRow(action: action)
                }
                .frame(minHeight: 180)
                if plan.actions.count > 500 {
                    Text("And \(plan.actions.count - 500) more.").font(.caption).foregroundStyle(.secondary)
                }
            }

            if let failures {
                if wasStopped {
                    Label("Stopped after \(done ?? 0) of \(plan?.actions.count ?? 0) actions. The folders are compared again.", systemImage: "stop.circle.fill")
                        .foregroundStyle(Theme.changed)
                }
                if failures.isEmpty {
                    if !wasStopped {
                        Label("Done. The folders are compared again.", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.added)
                    }
                } else {
                    Label("\(failures.count) actions failed or were left alone:", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.removed)
                    ScrollView {
                        Text(failures.map { "\($0.action.path): \($0.message)" }.joined(separator: "\n"))
                            .font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 120)
                }
            }

            HStack {
                if let done, let plan, failures == nil {
                    ProgressView(value: Double(done), total: Double(max(plan.actions.count, 1)))
                }
                Spacer()
                if done != nil, failures == nil {
                    // Running: stop between two actions; nothing is left half done.
                    Button("Stop") {
                        wasStopped = true
                        stop.stop()
                    }
                    .keyboardShortcut(.cancelAction)
                    .disabled(wasStopped)
                } else {
                    Button(failures == nil ? "Cancel" : "Close") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                if failures == nil {
                    Button("Sync") { run() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(plan?.actions.isEmpty ?? true || done != nil)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
        .interactiveDismissDisabled(done != nil && failures == nil)
        .task(id: Choice(mode: mode, direction: direction)) {
            guard done == nil else { return }
            job = model.plan(mode: mode, direction: direction, selection: Set(items))
        }
    }

    private var explanation: String {
        let what = switch (direction, mode) {
        case (.both, _):
            "Copies what is missing on either side, and the newer version of every file that differs. Files that differ but have the same date are left alone."
        case (_, .update):
            "Copies what is missing on the \(target) side and replaces older files there. Nothing is deleted, and newer files on the \(target) side are kept."
        case (_, .mirror):
            "Makes the \(target) side an exact copy. Items only the \(target) side has go to the Trash, so you can put them back; files that are replaced are overwritten."
        }
        return what + " Anything that changed since the comparison is left alone."
    }

    private var target: String { direction == .rightToLeft ? "left" : "right" }

    private func run() {
        guard let job else { return }
        done = 0
        Task {
            failures = await model.run(job, stop: stop) { done = $0 }
        }
    }
}

private struct ActionRow: View {
    let action: FolderSync.Action

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 16)
            Text(action.path).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text(detail).foregroundStyle(.secondary).font(.caption)
        }
        .font(.system(size: 12))
    }

    private var icon: String {
        switch action {
        case .copy(_, _, let toRight, _): toRight ? "arrow.right.doc.on.clipboard" : "arrow.left.doc.on.clipboard"
        case .createFolder: "folder.badge.plus"
        case .trash: "trash"
        }
    }

    private var color: Color {
        switch action {
        case .copy: Theme.added
        case .createFolder: Theme.iris
        case .trash: Theme.removed
        }
    }

    private var detail: String {
        switch action {
        case let .copy(_, _, toRight, bytes): "\(toRight ? "to right" : "to left") · " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        case .createFolder(_, let onRight): "new folder on the \(onRight ? "right" : "left")"
        case .trash(_, let onRight): "from the \(onRight ? "right" : "left")"
        }
    }
}
