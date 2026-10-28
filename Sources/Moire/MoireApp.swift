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
    }

    var mode = Mode.text
    let compare = CompareModel()
    let folders = FolderModel()
    /// True while the text comparison shows a pair picked from the folder comparison.
    var cameFromFolders = false

    /// Files and folders from Finder, the Dock or the command line.
    func open(_ urls: [URL]) {
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
        // `open -a Moire --args left.txt right.txt`, or a difftool configured to run the binary.
        let paths = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        let urls = paths.map { URL(filePath: $0, relativeTo: URL.currentDirectory()).standardizedFileURL }
            .filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
        if !urls.isEmpty { state.open(urls) }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        state.open(urls)
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
    private var canSearch: Bool { isText && !compare.isEditing && compare.display != nil }

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
            Button(compare.isEditing ? "Show Differences" : "Edit Text") { compare.isEditing.toggle() }
                .keyboardShortcut("e")
                .disabled(!isText || compare.hasBinarySide)
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
