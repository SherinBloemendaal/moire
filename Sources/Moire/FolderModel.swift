import AppKit
import MoireKit
import os
import SwiftUI

@Observable
final class FolderModel {
    enum Filter: String, CaseIterable {
        case all
        case differences
    }

    var left: URL? { didSet { if left != oldValue { foldersChanged() } } }
    var right: URL? { didSet { if right != oldValue { foldersChanged() } } }

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
        FolderCompareSettings(
            method: method,
            skipHidden: skipHidden,
            filter: FolderFilter(
                include: FolderFilter.patterns(from: includeText),
                exclude: FolderFilter.patterns(from: excludeText),
                useGitignore: useGitignore
            )
        )
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
        let previous = left
        left = right
        right = previous
    }

    func refresh() { compareIfReady() }

    func applyMasks() { compareIfReady() }

    func stop() {
        engine?.cancel()
    }

    private func foldersChanged() {
        leftVolume = left.flatMap { try? Volume.of($0.path(percentEncoded: false)) }
        rightVolume = right.flatMap { try? Volume.of($0.path(percentEncoded: false)) }
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

    /// The user picked a method: remember it for local folders.
    func pick(_ method: CompareMethod) {
        if !isOnNetwork { preferredMethod = method }
        self.method = method
    }

    private func compareIfReady() {
        engine?.cancel()
        refreshTask?.cancel()
        guard let left, let right else {
            show(nil)
            progress = nil
            isComparing = false
            return
        }

        let settings = settings
        let cache = settings.method == .metadata ? nil : ResultCache(file: ResultCache.file(left: left, right: right, settings: settings))
        let engine = FolderEngine(left: left, right: right, settings: settings, cache: cache)
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
        guard let tree, !isComparing else { return nil }
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
