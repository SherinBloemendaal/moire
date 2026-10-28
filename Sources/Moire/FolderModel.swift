import AppKit
import MoireKit
import os
import SwiftUI

/// One side of a folder comparison: a folder on this Mac or one on a server.
enum FolderLocation: Hashable {
    case local(URL)
    case remote(RemoteLocation)

    var localURL: URL? {
        if case .local(let url) = self { url } else { nil }
    }

    var remote: RemoteLocation? {
        if case .remote(let location) = self { location } else { nil }
    }

    /// Known without connecting, so the method can be picked before anything is read.
    var remoteVolume: Volume? {
        guard let remote else { return nil }
        let fileSystem = switch remote.scheme {
        case .sftp: "sftp"
        case .ftp: "ftp"
        case .ftps, .ftpes: "ftps"
        case .s3: "s3"
        }
        return Volume(fileSystem: fileSystem, isLocal: false)
    }
}

@Observable
final class FolderModel {
    enum Filter: String, CaseIterable {
        case all
        case differences
    }

    var leftLocation: FolderLocation? { didSet { if leftLocation != oldValue { foldersChanged() } } }
    var rightLocation: FolderLocation? { didSet { if rightLocation != oldValue { foldersChanged() } } }

    /// The local folders. Setting one replaces whatever that side had, remote or not.
    var left: URL? {
        get { leftLocation?.localURL }
        set { leftLocation = newValue.map(FolderLocation.local) }
    }
    var right: URL? {
        get { rightLocation?.localURL }
        set { rightLocation = newValue.map(FolderLocation.local) }
    }

    /// Archives being unpacked to be compared here, by name.
    var unpacking: [String] = []
    /// Unpacked archives shown here, by their temporary folder, so the cards show the archive.
    var archiveOrigins: [URL: URL] = [:]

    func location(_ side: SideID) -> FolderLocation? { side == .left ? leftLocation : rightLocation }

    /// Files on this side can be opened, synced, renamed and moved to the Trash.
    func isLocal(_ side: SideID) -> Bool { location(side)?.localURL != nil }

    var hasBothSides: Bool { leftLocation != nil && rightLocation != nil }
    var canSync: Bool { isLocal(.left) && isLocal(.right) }

    /// Chosen per pair of folders: metadata only on a network disk, otherwise the user's choice.
    var method: CompareMethod = .binary {
        didSet { if method != oldValue { compareIfReady() } }
    }
    var preferredMethod = CompareMethod(rawValue: UserDefaults.standard.string(forKey: "folderMethod") ?? "") ?? .binary {
        didSet { UserDefaults.standard.set(preferredMethod.rawValue, forKey: "folderMethod") }
    }
    var skipHidden = UserDefaults.standard.object(forKey: "skipHidden") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(skipHidden, forKey: "skipHidden")
            compareIfReady()
        }
    }
    var includeText = UserDefaults.standard.string(forKey: "includeMasks") ?? "" {
        didSet { UserDefaults.standard.set(includeText, forKey: "includeMasks") }
    }
    var excludeText = UserDefaults.standard.string(forKey: "excludeMasks") ?? "" {
        didSet { UserDefaults.standard.set(excludeText, forKey: "excludeMasks") }
    }
    var useGitignore = UserDefaults.standard.bool(forKey: "useGitignore") {
        didSet {
            UserDefaults.standard.set(useGitignore, forKey: "useGitignore")
            compareIfReady()
        }
    }
    var filter = Filter.all

    private(set) var tree: FolderTree?
    private(set) var progress: FolderProgress?
    private(set) var isComparing = false
    private(set) var startedAt: Date?
    private(set) var finishedIn: Duration?
    private(set) var leftVolume: Volume?
    private(set) var rightVolume: Volume?
    /// Bumped whenever `tree` changes, so the outline view knows to reload.
    private(set) var version = 0
    var errorMessage: String?

    private var engine: FolderEngine?
    private var refreshTask: Task<Void, Never>?
    nonisolated private static let log = Logger(subsystem: "io.github.sherinbloemendaal.moire", category: "folders")

    var isOnNetwork: Bool { leftVolume?.isLocal == false || rightVolume?.isLocal == false }

    var settings: FolderCompareSettings {
        var settings = FolderCompareSettings(
            method: method,
            skipHidden: skipHidden,
            filter: FolderFilter(
                include: FolderFilter.patterns(from: includeText),
                exclude: FolderFilter.patterns(from: excludeText),
                useGitignore: useGitignore
            )
        )
        settings.textRules = RulesStore.shared.rules
        return settings
    }

    /// Files per status, worked out once per new tree.
    private(set) var counts: [FolderTree.Status: Int] = [:]

    func count(_ status: FolderTree.Status) -> Int { counts[status] ?? 0 }

    private func show(_ tree: FolderTree?) {
        self.tree = tree
        var counts: [FolderTree.Status: Int] = [:]
        if let tree {
            for item in 1..<tree.count where !tree.isDirectory(item) {
                counts[tree.status(of: item), default: 0] += 1
            }
        }
        self.counts = counts
        version += 1
    }

    func choose(_ side: SideID) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.message = "Choose the \(side.name.lowercased()) folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        set(url, on: side)
    }

    func set(_ url: URL, on side: SideID) {
        if side == .left { left = url } else { right = url }
    }

    func set(_ location: RemoteLocation, on side: SideID) {
        if side == .left { leftLocation = .remote(location) } else { rightLocation = .remote(location) }
    }

    /// Takes dropped folders: two fill both sides, one fills the first empty side.
    func open(_ urls: [URL]) {
        let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        if folders.count >= 2 {
            left = folders[0]
            right = folders[1]
        } else if let folder = folders.first {
            set(folder, on: left == nil ? .left : (right == nil ? .right : .left))
        }
    }

    func swapSides() {
        let previous = leftLocation
        leftLocation = rightLocation
        rightLocation = previous
    }

    func refresh() { compareIfReady() }

    func applyMasks() { compareIfReady() }

    func stop() {
        engine?.cancel()
    }

    private func foldersChanged() {
        leftVolume = leftLocation.flatMap(Self.volume)
        rightVolume = rightLocation.flatMap(Self.volume)
        let start = if let leftVolume, let rightVolume {
            FolderCompareSettings.defaultMethod(left: leftVolume, right: rightVolume, otherwise: preferredMethod)
        } else {
            preferredMethod
        }
        if method != start {
            method = start
        } else {
            compareIfReady()
        }
    }

    private static func volume(_ location: FolderLocation) -> Volume? {
        if let url = location.localURL { return try? Volume.of(url.path(percentEncoded: false)) }
        return location.remoteVolume
    }

    /// Makes the source for one side when the comparison starts, off the main thread. The FTP
    /// password is read from the Keychain here, on the main thread, before that.
    private static func sourceMaker(_ location: FolderLocation) -> @Sendable () throws -> any FolderSource {
        switch location {
        case .local(let url):
            return { try LocalSource(url) }
        case .remote(let remote):
            let password = remote.scheme.isFTP ? ServerKeychain.password(for: remote) : nil
            return { try remote.makeSource(password: password) }
        }
    }

    /// The user picked a method: remember it for local folders.
    func pick(_ method: CompareMethod) {
        if !isOnNetwork { preferredMethod = method }
        self.method = method
    }

    private func compareIfReady() {
        engine?.cancel()
        refreshTask?.cancel()
        guard let leftLocation, let rightLocation else {
            show(nil)
            progress = nil
            isComparing = false
            return
        }

        let settings = settings
        // Remote files have no file IDs to key results by, so only two local folders get a cache.
        let cache: ResultCache? = if settings.method != .metadata, let left = leftLocation.localURL, let right = rightLocation.localURL {
            ResultCache(file: ResultCache.file(left: left, right: right, settings: settings))
        } else {
            nil
        }
        let makeLeft = Self.sourceMaker(leftLocation)
        let makeRight = Self.sourceMaker(rightLocation)
        let engine = FolderEngine(sources: { (try makeLeft(), try makeRight()) }, settings: settings, cache: cache)
        self.engine = engine
        isComparing = true
        startedAt = Date()
        finishedIn = nil
        show(FolderTree())
        progress = nil

        let clock = ContinuousClock()
        let started = clock.now
        let running = Task.detached(priority: .userInitiated) {
            let result = Result { try engine.run() }
            do {
                try cache?.save()
            } catch {
                // Only the next comparison gets slower; the results on screen are complete.
                Self.log.error("Could not save the result cache: \(error.localizedDescription, privacy: .public)")
            }
            return result
        }

        refreshTask = Task { [weak self] in
            // Show results as they come in, a few times a second.
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.engine === engine, self.isComparing else { return }
                self.show(engine.snapshot())
                self.progress = engine.progress
            }
        }

        Task { [weak self] in
            let result = await running.value
            guard let self, self.engine === engine else { return }
            self.refreshTask?.cancel()
            self.isComparing = false
            self.progress = engine.progress
            self.finishedIn = clock.now - started
            switch result {
            case .success(let tree):
                self.show(tree)
            case .failure(is CancellationError):
                // Stopped: keep what was found so far.
                self.show(engine.snapshot())
            case .failure(let error):
                self.show(nil)
                self.errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: Items

    func url(of item: Int, on side: SideID) -> URL? {
        guard let tree, let root = side == .left ? left : right else { return nil }
        let info = side == .left ? tree.left(item) : tree.right(item)
        guard info.exists else { return nil }
        return root.appending(path: tree.path(of: item))
    }

    /// Where downloaded copies of remote files go; leftovers older than a day are removed at launch.
    static var downloads: URL {
        FileManager.default.temporaryDirectory.appending(path: "Moire Downloads", directoryHint: .isDirectory)
    }

    /// The largest remote file that is downloaded for the text comparison.
    static let downloadLimit: Int64 = 1 << 30

    /// The item's file on each side, downloading remote ones into a temporary folder. Local
    /// files are used where they are. A side without the file is `nil`.
    func filesForComparison(_ item: Int) async throws -> (left: (url: URL, origin: String)?, right: (url: URL, origin: String)?) {
        guard let tree, item < tree.count else { return (nil, nil) }
        let path = tree.path(of: item)
        var result: [SideID: (url: URL, origin: String)] = [:]
        for side in SideID.allCases {
            let info = side == .left ? tree.left(item) : tree.right(item)
            guard info.exists, let location = location(side) else { continue }
            switch location {
            case .local(let root):
                let url = root.appending(path: path)
                result[side] = (url, (url.deletingLastPathComponent().path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath)
            case .remote(let remote):
                guard info.size <= Self.downloadLimit else {
                    throw CocoaError(.fileReadTooLarge, userInfo: [
                        NSLocalizedDescriptionKey: "\(tree.name(of: item)) is \(ByteCountFormatter.string(fromByteCount: info.size, countStyle: .file)); files over 1 GB on a server are not downloaded for the text comparison.",
                    ])
                }
                let makeSource = Self.sourceMaker(.remote(remote))
                let folder = Self.downloads.appending(path: UUID().uuidString, directoryHint: .isDirectory)
                let destination = folder.appending(path: tree.name(of: item))
                try await Task.detached(priority: .userInitiated) {
                    let data = try makeSource().open(path).readAll()
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try data.write(to: destination)
                }.value
                let parent = (path as NSString).deletingLastPathComponent
                result[side] = (destination, remote.displayName + (parent.isEmpty ? "" : "/" + parent))
            }
        }
        return (result[.left], result[.right])
    }

    /// Every side the item exists on is a local file, so the text comparison can open it.
    func canOpen(_ item: Int) -> Bool {
        guard let tree, item < tree.count else { return false }
        for side in SideID.allCases where (side == .left ? tree.left(item) : tree.right(item)).exists {
            if !isLocal(side) { return false }
        }
        return true
    }

    func showInFinder(_ items: [Int], side: SideID) {
        let urls = items.compactMap { url(of: $0, on: side) }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// Moves items to the Trash after asking, then compares again.
    func trash(_ items: [Int], side: SideID) {
        let urls = items.compactMap { url(of: $0, on: side) }
        guard !urls.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = urls.count == 1
            ? "Move \"\(urls[0].lastPathComponent)\" on the \(side.name.lowercased()) side to the Trash?"
            : "Move \(urls.count) items on the \(side.name.lowercased()) side to the Trash?"
        alert.informativeText = "You can put them back from the Trash."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        var failures: [String] = []
        for url in urls {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
        refresh()
    }

    /// Renames one item on one side, then compares again.
    func rename(_ item: Int, side: SideID) {
        guard let url = url(of: item, on: side) else { return }
        let alert = NSAlert()
        alert.messageText = "Rename \"\(url.lastPathComponent)\""
        alert.informativeText = "On the \(side.name.lowercased()) side."
        let field = NSTextField(string: url.lastPathComponent)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != url.lastPathComponent else { return }
        guard !name.contains("/") else {
            errorMessage = "A name cannot contain \"/\"."
            return
        }
        let destination = url.deletingLastPathComponent().appending(path: name)
        guard !FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) else {
            errorMessage = "\"\(name)\" already exists there."
            return
        }
        do {
            try FileManager.default.moveItem(at: url, to: destination)
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    // MARK: Sync

    func plan(mode: FolderSync.Mode, direction: FolderSync.Direction, selection: Set<Int>) -> FolderSync.Plan? {
        guard let tree, !isComparing, canSync else { return nil }
        return FolderSync.plan(tree, mode: mode, direction: direction, settings: settings, selection: selection)
    }

    /// Runs a plan off the main thread and compares again afterwards.
    func run(_ plan: FolderSync.Plan, progress: @escaping @MainActor @Sendable (Int) -> Void) async -> [FolderSync.Failure] {
        guard let left, let right else { return [] }
        let failures = await Task.detached(priority: .userInitiated) {
            FolderSync.execute(plan, left: left, right: right, progress: { done in
                Task { @MainActor in progress(done) }
            })
        }.value
        refresh()
        return failures
    }
}
