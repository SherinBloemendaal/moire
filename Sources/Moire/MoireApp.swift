import AppKit
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
        case merge
    }

    var mode = Mode.text
    let compare = CompareModel()
    let folders = FolderModel()
    let merge = MergeModel()
    let recents = RecentSessions()
    /// True while the text comparison shows a pair picked from the folder comparison.
    var cameFromFolders = false

    /// Files and folders from Finder, the Dock or the command line.
    func open(_ urls: [URL]) {
        if let session = urls.first(where: { $0.pathExtension == "moire" }) {
            openSession(session)
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

    func openFromFolders(left: URL?, right: URL?) {
        compare.openPair(left: left, right: right)
        cameFromFolders = true
        withAnimation(.smooth(duration: 0.3)) { mode = .text }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if let flag = arguments.firstIndex(of: "--merge") {
            openMergetool(Array(arguments[(flag + 1)...]))
            return
        }

        // `open -a Moire --args left.txt right.txt`, or a difftool configured to run the binary.
        let paths = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        let urls = paths.map { URL(filePath: $0, relativeTo: URL.currentDirectory()).standardizedFileURL }
            .filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
        if !urls.isEmpty { state.open(urls) }
    }

    /// `Moire --merge BASE LOCAL REMOTE MERGED`, the way `git mergetool` passes the files.
    private func openMergetool(_ paths: [String]) {
        guard paths.count >= 4 else {
            FileHandle.standardError.write(Data("usage: Moire --merge BASE LOCAL REMOTE MERGED\n".utf8))
            exit(2)
        }
        let urls = paths.prefix(4).map { URL(filePath: $0, relativeTo: URL.currentDirectory()).standardizedFileURL }
        state.merge.openMergetool(base: urls[0], left: urls[1], right: urls[2], output: urls[3])
        state.mode = .merge
        NSApp.activate()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        state.open(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if state.merge.isDirty {
            let alert = NSAlert()
            alert.messageText = "Save the merge result before quitting?"
            alert.informativeText = state.merge.isMergetool
                ? "Without saving, git keeps the file marked as unmerged."
                : "The choices you made in the merge are not saved yet."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Don't Save")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                guard state.merge.save() else { return .terminateCancel }
            case .alertSecondButtonReturn: break
            default: return .terminateCancel
            }
        }

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

    func applicationWillTerminate(_ notification: Notification) {
        // git mergetool with `trustExitCode` reads a failure as "not merged yet".
        guard state.merge.isMergetool, state.merge.exitStatus != 0 else { return }
        exit(state.merge.exitStatus)
    }
}

struct MoireCommands: Commands {
    let state: AppState

    private var compare: CompareModel { state.compare }
    private var merge: MergeModel { state.merge }
    private var isText: Bool { state.mode == .text }
    private var isMerge: Bool { state.mode == .merge }
    private var canResolve: Bool {
        guard isMerge, let chunk = merge.currentChunk, let result = merge.merge, result.chunks.indices.contains(chunk) else { return false }
        return result.chunks[chunk].kind != .unchanged
    }

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
        CommandMenu("Compare") {
            Button("Next Change") { compare.goToNextChange() }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(!isText || compare.hunkCount == 0)
            Button("Previous Change") { compare.goToPreviousChange() }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(!isText || compare.hunkCount == 0)
            Divider()
            Button("Copy Change to Right") { compare.copyCurrentChange(toRight: true) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(!isText || compare.currentHunk == nil)
            Button("Copy Change to Left") { compare.copyCurrentChange(toRight: false) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(!isText || compare.currentHunk == nil)
            Divider()
            Button("Swap Sides") {
                if isText { compare.swapSides() } else { state.folders.swapSides() }
            }
            .keyboardShortcut("x", modifiers: [.command, .shift])
            .disabled(isMerge)
            Button(compare.isEditing ? "Show Differences" : "Edit Text") { compare.isEditing.toggle() }
                .keyboardShortcut("e")
                .disabled(!isText || compare.hasBinarySide)
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
