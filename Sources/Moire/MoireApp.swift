import AppKit
import MoireKit
import SwiftUI

@main
struct MoireApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        Window("Moire", id: "main") {
            ContentView(state: appDelegate.state)
                .frame(minWidth: 820, minHeight: 520)
        }
        .defaultSize(width: 1240, height: 780)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            MoireCommands(state: appDelegate.state)
        }
    }
}

@Observable
final class AppState {
    enum Mode: String, CaseIterable {
        case text
        case folders
    }

    var mode = Mode.text
    let compare = CompareModel()
    let folders = FolderModel()
    /// True while the text comparison shows a pair picked from the folder comparison.
    var cameFromFolders = false
    /// Archives unpacked for the folder comparison.
    let archives = ArchiveRouter()

    init() {
        compare.fileView.openArchivesAsFolders = { [weak self] left, right, automatic in
            // A pair of archives opened from inside the folder comparison does not replace it
            // on its own; the archive view offers the button instead.
            guard let self, !(automatic && mode == .folders) else { return }
            openArchives(left: left, right: right)
        }
        watchFolders()
    }

    /// Files and folders from Finder, the Dock or the command line.
    func open(_ urls: [URL]) {
        if urls.contains(where: ArchiveRouter.isArchive), urls.allSatisfy({ ArchiveRouter.isArchive($0) || ArchiveRouter.isFolder($0) }) {
            if urls.count >= 2 {
                openArchives(left: urls[0], right: urls[1])
            } else {
                openArchives(left: folders.left == nil ? urls[0] : nil, right: folders.left == nil ? nil : urls[0])
            }
            return
        }
        let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        if !folders.isEmpty {
            self.folders.open(folders)
            mode = .folders
        } else {
            compare.open(urls)
            mode = .text
        }
    }

    /// Unpacks archives (a side may also be a folder) and compares them in the folder comparison.
    func openArchives(left: URL?, right: URL?) {
        compare.fileView.isOpeningArchives = true
        archives.open(left: left, right: right) { [weak self] message in
            guard let self else { return }
            compare.fileView.isOpeningArchives = false
            if mode == .folders { folders.errorMessage = message } else { compare.errorMessage = message }
        } done: { [weak self] left, right in
            guard let self else { return }
            compare.fileView.isOpeningArchives = false
            if let left { folders.left = left }
            if let right { folders.right = right }
            cameFromFolders = false
            withAnimation(.smooth(duration: 0.3)) { mode = .folders }
        }
    }

    /// Removes unpacked archives as soon as the folder comparison stops showing them.
    private func watchFolders() {
        withObservationTracking {
            _ = folders.left
            _ = folders.right
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                archives.release(keeping: [folders.left, folders.right])
                watchFolders()
            }
        }
    }

    func openFromFolders(left: URL?, right: URL?) {
        compare.openPair(left: left, right: right)
        cameFromFolders = true
        withAnimation(.smooth(duration: 0.3)) { mode = .text }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task.detached(priority: .background) { ArchiveExtractor.removeLeftovers() }
        // `open -a Moire --args left.txt right.txt`, or a difftool configured to run the binary.
        let paths = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        let urls = paths.map { URL(filePath: $0, relativeTo: URL.currentDirectory()).standardizedFileURL }
            .filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
        if !urls.isEmpty { state.open(urls) }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        state.open(urls)
    }

    func applicationWillTerminate(_ notification: Notification) {
        state.archives.removeAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard state.compare.hasUnsavedChanges else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "Save your changes before quitting?"
        alert.informativeText = "A side has changes that are not saved yet."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn: return state.compare.saveAll() ? .terminateNow : .terminateCancel
        case .alertSecondButtonReturn: return .terminateNow
        default: return .terminateCancel
        }
    }
}

struct MoireCommands: Commands {
    let state: AppState

    private var compare: CompareModel { state.compare }
    private var isText: Bool { state.mode == .text }
    private var files: FileViewModel { compare.fileView }
    /// Hex, image, table, document text or archive instead of the text comparison.
    private var isSpecial: Bool { isText && files.isSpecial && !compare.isEditing }
    private var changeCount: Int { isSpecial ? files.differenceCount : compare.hunkCount }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Files…") {
                state.mode = .text
                compare.openPanel(for: nil)
            }
            .keyboardShortcut("o")
            Button("Open Left File…") { compare.openPanel(for: .left) }
            Button("Open Right File…") { compare.openPanel(for: .right) }
            Divider()
            Button("Compare Folders…") {
                state.mode = .folders
                state.folders.choose(.left)
                if state.folders.left != nil, state.folders.right == nil { state.folders.choose(.right) }
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { compare.saveAll() }
                .keyboardShortcut("s")
                .disabled(!compare.hasUnsavedChanges)
            Button("Reload from Disk") { compare.reload() }
                .keyboardShortcut("r")
                .disabled(!compare.hasFiles)
        }
        CommandMenu("Compare") {
            Button("Next Change") {
                if isSpecial { files.navigator?.goToNextDifference() } else { compare.goToNextChange() }
            }
            .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            .disabled(!isText || changeCount == 0)
            Button("Previous Change") {
                if isSpecial { files.navigator?.goToPreviousDifference() } else { compare.goToPreviousChange() }
            }
            .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            .disabled(!isText || changeCount == 0)
            Divider()
            Button("Copy Change to Right") { compare.copyCurrentChange(toRight: true) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(!isText || isSpecial || compare.currentHunk == nil)
            Button("Copy Change to Left") { compare.copyCurrentChange(toRight: false) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(!isText || isSpecial || compare.currentHunk == nil)
            Divider()
            Button("Swap Sides") {
                if isText { compare.swapSides() } else { state.folders.swapSides() }
            }
            .keyboardShortcut("x", modifiers: [.command, .shift])
            Button(compare.isEditing ? "Show Differences" : "Edit Text") { compare.isEditing.toggle() }
                .keyboardShortcut("e")
                .disabled(!isText || compare.hasBinarySide || !files.allowsEditing)
        }
        CommandGroup(after: .toolbar) {
            Menu("View As") {
                ForEach(FileView.allCases) { view in
                    Toggle(view.title, isOn: Binding(get: { files.current == view }, set: { if $0 { files.chosen = view } }))
                        .disabled(!files.available.contains(view))
                }
            }
            .disabled(!isText || compare.isEmpty)
            Divider()
            Button("Side by Side") { compare.layout = .sideBySide }
                .keyboardShortcut("1", modifiers: [.command, .control])
            Button("Unified") { compare.layout = .unified }
                .keyboardShortcut("2", modifiers: [.command, .control])
            Button(compare.onlyChanges ? "Show All Lines" : "Only Show Changes") { compare.onlyChanges.toggle() }
                .keyboardShortcut("f", modifiers: [.command, .option])
            Divider()
            Button("Bigger Text") { compare.fontSize = min(compare.fontSize + 1, 24) }
                .keyboardShortcut("+")
            Button("Smaller Text") { compare.fontSize = max(compare.fontSize - 1, 9) }
                .keyboardShortcut("-")
            Button("Actual Size") { compare.fontSize = 12.5 }
                .keyboardShortcut("0")
            Divider()
        }
    }
}
