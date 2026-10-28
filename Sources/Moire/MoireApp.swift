import AppKit
import MoireKit
import SwiftUI

@main
struct MoireApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        WindowGroup(id: "comparison", for: WindowRequest.self) { $request in
            WindowRoot(request: request)
        }
        .defaultSize(width: 1240, height: 780)
        // Files from Finder, the Dock or `open` go through the app delegate, which decides whether
        // they need a new window; SwiftUI must not make one of its own for them.
        .handlesExternalEvents(matching: [])
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            MoireCommands()
        }

        Settings {
            TabView {
                RulesSettingsView()
                    .tabItem { Label("Rules", systemImage: "line.3.horizontal.decrease") }
            }
        }
    }
}

@Observable
final class AppState {
    enum Mode: String, CaseIterable {
        case text
        case folders
        case merge
    }

    var mode = Mode.text
    let compare = CompareModel()
    let folders = FolderModel()
    let merge = MergeModel()
    var recents: RecentSessions { RecentSessions.shared }
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
        if let session = urls.first(where: { $0.pathExtension == "moire" }) {
            openSession(session)
            return
        }
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

    /// Nothing loaded yet: files from Finder can go here instead of into a new window.
    var isEmpty: Bool {
        compare.isEmpty && !compare.isEditing && folders.leftLocation == nil && folders.rightLocation == nil
            && merge.merge == nil && merge.sources.values.allSatisfy { $0.url == nil }
    }

    /// For the window's tab and the Window menu.
    var windowTitle: String {
        switch mode {
        case .folders:
            let names = [folders.left, folders.right].compactMap { $0?.lastPathComponent }
            return names.isEmpty ? "Folders" : names.joined(separator: " ⇄ ")
        case .merge:
            return merge.merge == nil ? "Merge" : "Merge: \(merge.labels.left) ⇄ \(merge.labels.right)"
        case .text:
            if compare.isEmpty { return "Moire" }
            return "\(compare.left.title) ⇄ \(compare.right.title)"
        }
    }

    /// Unpacks archives (a side may also be a folder) and compares them in the folder comparison.
    func openArchives(left: URL?, right: URL?) {
        compare.fileView.isOpeningArchives = true
        folders.unpacking = [left, right].compactMap { $0 }.filter(ArchiveRouter.isArchive).map(\.lastPathComponent)
        archives.open(left: left, right: right) { [weak self] message in
            guard let self else { return }
            compare.fileView.isOpeningArchives = false
            folders.unpacking = []
            if mode == .folders { folders.errorMessage = message } else { compare.errorMessage = message }
        } done: { [weak self] left, right in
            guard let self else { return }
            compare.fileView.isOpeningArchives = false
            folders.unpacking = []
            for folder in [left, right].compactMap({ $0 }) {
                if let archive = archives.archive(for: folder) { folders.archiveOrigins[folder] = archive }
            }
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
    func applicationDidFinishLaunching(_ notification: Notification) {
        let downloads = FolderModel.downloads
        Task.detached(priority: .background) {
            ArchiveExtractor.removeLeftovers()
            ArchiveExtractor.removeLeftovers(in: downloads)
        }
        let arguments = Array(CommandLine.arguments.dropFirst())
        if let flag = arguments.firstIndex(of: "--merge") {
            openMergetool(Array(arguments[(flag + 1)...]))
            return
        }

        // `open -a Moire --args left.txt right.txt`, or a difftool running the binary. These
        // arrive only as arguments; files from Finder and `open` come to `application(_:open:)`.
        let paths = arguments.filter { !$0.hasPrefix("-") }
        let urls = paths.map { URL(filePath: $0, relativeTo: URL.currentDirectory()).standardizedFileURL }
            .filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
        if !urls.isEmpty { Windows.shared.open(urls) }
        // Files from Finder arrive through application(_:open:) around the same time.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { Windows.shared.openWindowForWaitingFiles() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Windows.shared.open(urls)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { Windows.shared.openWindowForWaitingFiles() }
    }

    /// `Moire --merge BASE LOCAL REMOTE MERGED`, the way `git mergetool` passes the files.
    private func openMergetool(_ paths: [String]) {
        guard paths.count >= 4 else {
            FileHandle.standardError.write(Data("usage: Moire --merge BASE LOCAL REMOTE MERGED\n".utf8))
            exit(2)
        }
        let urls = paths.prefix(4).map { URL(filePath: $0, relativeTo: URL.currentDirectory()).standardizedFileURL }
        Windows.shared.withFrontmost { [self] state in
            state.merge.openMergetool(base: urls[0], left: urls[1], right: urls[2], output: urls[3])
            state.mode = .merge
            mergetool = state.merge
        }
        NSApp.activate()
    }


    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for state in Windows.shared.states {
            guard Self.confirmQuit(state) else { return .terminateCancel }
        }
        return .terminateNow
    }

    /// Asks to save what this window has not saved yet. False means: do not quit.
    static func confirmQuit(_ state: AppState, closing: Bool = false) -> Bool {
        let leaving = closing ? "closing" : "quitting"
        if state.merge.isDirty {
            let alert = NSAlert()
            alert.messageText = "Save the merge result before \(leaving)?"
            alert.informativeText = state.merge.isMergetool
                ? "Without saving, git keeps the file marked as unmerged."
                : "The choices you made in the merge are not saved yet."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Don't Save")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                guard state.merge.save() else { return false }
            case .alertSecondButtonReturn: break
            default: return false
            }
        }

        guard state.compare.hasUnsavedChanges else { return true }

        let alert = NSAlert()
        alert.messageText = "Save your changes to \(state.windowTitle) before \(leaving)?"
        alert.informativeText = "A side has changes that are not saved yet."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn: return state.compare.saveAll()
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    /// Held here, not only by its window: closing the window ends the app, and the exit status
    /// still has to tell git whether the merge was saved.
    private var mergetool: MergeModel?

    func applicationWillTerminate(_ notification: Notification) {
        for state in Windows.shared.states { state.archives.removeAll() }
        // git mergetool with `trustExitCode` reads a failure as "not merged yet".
        guard let mergetool, mergetool.exitStatus != 0 else { return }
        exit(mergetool.exitStatus)
    }
}

struct MoireCommands: Commands {
    @FocusedValue(\.appState) private var focused
    @Environment(\.openWindow) private var openWindow

    /// The comparison in the front window. Without a window, an empty stand-in keeps the menus disabled.
    private var state: AppState { focused ?? Windows.shared.frontmost ?? Windows.shared.placeholder }

    private var compare: CompareModel { state.compare }
    private var merge: MergeModel { state.merge }
    private var isText: Bool { state.mode == .text }
    private var isMerge: Bool { state.mode == .merge }
    private var canResolve: Bool {
        guard isMerge, let chunk = merge.currentChunk, let result = merge.merge, result.chunks.indices.contains(chunk) else { return false }
        return result.chunks[chunk].kind != .unchanged
    }
    private var files: FileViewModel { compare.fileView }
    /// Hex, image, table, document text or archive instead of the text comparison.
    private var isSpecial: Bool { isText && files.isSpecial && !compare.isEditing }
    private var changeCount: Int { isSpecial ? files.differenceCount : compare.hunkCount }
    private var canSearch: Bool { isText && !isSpecial && !compare.isEditing && compare.display != nil }

    var body: some Commands {
        // The menus exist from launch on, before any window: the one place to get this early.
        let _ = Windows.shared.provide(openWindow)
        CommandGroup(replacing: .newItem) {
            Button("New Window") { Windows.shared.newWindow() }
                .keyboardShortcut("n")
            Button("New Tab") { Windows.shared.newTab() }
                .keyboardShortcut("t")
            Divider()
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
            Button("Open Saved Comparison…") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [ComparisonSession.fileType]
                guard panel.runModal() == .OK, let url = panel.url else { return }
                state.openSession(url)
            }
            RecentSessionsMenu(state: state)
            Divider()
            Button("Merge Files…") {
                state.mode = .merge
                merge.chooseFiles()
            }
            .keyboardShortcut("o", modifiers: [.command, .option])
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") {
                if isMerge { merge.save() } else { compare.saveAll() }
            }
            .keyboardShortcut("s")
            .disabled(isMerge ? merge.merge == nil : !compare.hasUnsavedChanges)
            Button("Reload from Disk") {
                if isMerge { merge.reload() } else { compare.reload() }
            }
            .keyboardShortcut("r")
            .disabled(isMerge ? !merge.isReady : !compare.hasFiles)
            Divider()
            Button("Save Comparison As…") { state.saveSessionPanel() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(state.currentSession == nil)
            Divider()
            Button("Export as Patch…") { ComparisonExport.exportPatch(compare) }
                .disabled(!isText || !ComparisonExport.canExport(compare))
            Button("Export as HTML Report…") { ComparisonExport.exportHTML(compare) }
                .disabled(!isText || !ComparisonExport.canExport(compare))
            Menu("Export Folder Report") {
                Button("HTML…") { state.exportFolderReport(.html) }
                Button("JSON…") { state.exportFolderReport(.json) }
                Button("Text…") { state.exportFolderReport(.text) }
            }
            .disabled(state.mode != .folders || state.folders.tree == nil || state.folders.isComparing)
            Divider()
            Button("Print…") { state.printCurrent() }
                .keyboardShortcut("p")
                .disabled(!state.canPrint)
        }
        CommandGroup(replacing: .textEditing) {
            Button("Find…") { compare.showSearch() }
                .keyboardShortcut("f")
                .disabled(!canSearch)
            Button("Find Next") { compare.findNext() }
                .keyboardShortcut("g")
                .disabled(!canSearch)
            Button("Find Previous") { compare.findPrevious() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(!canSearch)
            Divider()
            Button("Go to Line…") { compare.isGoToLineVisible = true }
                .keyboardShortcut("l")
                .disabled(!canSearch)
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
                .disabled(!isText || isSpecial || !compare.canCopyCurrentChange(toRight: true))
            Button("Copy Change to Left") { compare.copyCurrentChange(toRight: false) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(!isText || isSpecial || !compare.canCopyCurrentChange(toRight: false))
            Divider()
            Button("Align Marked Lines") { compare.alignMarkedLines() }
                .disabled(!isText || !compare.canAlign)
            Button("Clear Alignments") { compare.clearAlignments() }
                .disabled(!isText || (compare.anchors.isEmpty && compare.alignmentMarks.isEmpty))
            Divider()
            Button("Swap Sides") {
                if isText { compare.swapSides() } else { state.folders.swapSides() }
            }
            .keyboardShortcut("x", modifiers: [.command, .shift])
            .disabled(isMerge)
            Button(compare.isEditing ? "Show Differences" : "Edit Text") { compare.isEditing.toggle() }
                .keyboardShortcut("e")
                .disabled(!isText || compare.hasBinarySide || !files.allowsEditing)
        }
        CommandMenu("Merge") {
            Button("Next Conflict") { merge.goToNextConflict() }
                .keyboardShortcut(.downArrow, modifiers: [.command, .control])
                .disabled(!isMerge || merge.conflictCount == 0)
            Button("Previous Conflict") { merge.goToPreviousConflict() }
                .keyboardShortcut(.upArrow, modifiers: [.command, .control])
                .disabled(!isMerge || merge.conflictCount == 0)
            Divider()
            Button("Take Left") { merge.resolveCurrent(.left) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .control])
                .disabled(!canResolve)
            Button("Take Right") { merge.resolveCurrent(.right) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .control])
                .disabled(!canResolve)
            Button("Take Both, Left First") { merge.resolveCurrent(.leftThenRight) }
                .keyboardShortcut("b", modifiers: [.command, .control])
                .disabled(!canResolve)
            Button("Take Both, Right First") { merge.resolveCurrent(.rightThenLeft) }
                .keyboardShortcut("b", modifiers: [.command, .control, .option])
                .disabled(!canResolve)
            Button("Take Base") { merge.resolveCurrent(.base) }
                .disabled(!canResolve)
            Divider()
            Button("Edit by Hand") { merge.beginEditCurrent() }
                .keyboardShortcut("e", modifiers: [.command, .control])
                .disabled(!isMerge || merge.currentChunk == nil)
            Button("Undo Choice") { merge.resetCurrent() }
                .keyboardShortcut(.delete, modifiers: [.command, .control])
                .disabled(!isMerge || merge.currentChunk.map { merge.resolution(of: $0) == nil } ?? true)
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
