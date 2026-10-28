import AppKit
import MoireKit
import SwiftUI

/// One side of a comparison: pasted or typed text, or a file.
struct Side {
    enum Content {
        case text(TextDocument)
        /// A file that is not text. Only its bytes can be compared.
        case binary(Data)
    }

    var content: Content = .text(TextDocument("")) {
        didSet { revision &+= 1 }
    }
    var url: URL?
    var encoding: TextEncoding = .utf8
    var isDirty = false
    /// Counts every change of `content`, so a change is noticed without comparing the text.
    private(set) var revision = 0

    init(content: Content = .text(TextDocument("")), url: URL? = nil) {
        self.content = content
        self.url = url
    }

    var document: TextDocument {
        if case .text(let document) = content { return document }
        return TextDocument("")
    }

    /// The whole text as one string, for the plain text editor.
    var text: String { document.text }

    var isBinary: Bool {
        if case .binary = content { return true }
        return false
    }

    var isEmpty: Bool { url == nil && !isBinary && document.lines.isEmpty }

    var title: String { url?.lastPathComponent ?? "Untitled" }

    var subtitle: String {
        if case .binary(let data) = content {
            return "Binary · " + ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
        }
        let document = document
        let count = document.lines.count
        let lines = count == 1 ? "1 line" : "\(count.formatted()) lines"
        let ending = switch document.lineEnding {
        case .lf: "LF"
        case .crlf: "CRLF"
        case .cr: "CR"
        }
        let location = url.map { ($0.deletingLastPathComponent().path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath } ?? "Typed or pasted"
        return "\(location) · \(lines) · \(encoding.name) · \(ending)"
    }
}

typealias SideID = DiffSide

extension DiffSide {
    var name: String { self == .left ? "Left" : "Right" }
}

/// Asks the diff list to scroll to a row. Every request has a new id, so asking for the same
/// row twice scrolls twice.
struct ScrollRequest: Equatable {
    var id: Int
    var row: Int
    var side: SideID?
}

@Observable
final class CompareModel {
    typealias Layout = DiffDisplay.Layout

    var left = Side() { didSet { sidesChanged(oldValue: oldValue, newValue: left) } }
    var right = Side() { didSet { sidesChanged(oldValue: oldValue, newValue: right) } }

    var options = DiffOptions(
        whitespace: DiffOptions.Whitespace(rawValue: UserDefaults.standard.string(forKey: "whitespace") ?? "") ?? .exact,
        ignoreCase: UserDefaults.standard.bool(forKey: "ignoreCase")
    ) {
        didSet {
            UserDefaults.standard.set(options.whitespace.rawValue, forKey: "whitespace")
            UserDefaults.standard.set(options.ignoreCase, forKey: "ignoreCase")
            scheduleDiff(delay: .zero)
        }
    }

    var layout = Layout(rawValue: UserDefaults.standard.string(forKey: "layout") ?? "") ?? .sideBySide {
        didSet {
            UserDefaults.standard.set(layout.rawValue, forKey: "layout")
            rebuildDisplay()
        }
    }

    var onlyChanges = UserDefaults.standard.bool(forKey: "onlyChanges") {
        didSet {
            UserDefaults.standard.set(onlyChanges, forKey: "onlyChanges")
            expandedFolds = []
            rebuildDisplay()
        }
    }

    var fontSize: Double = UserDefaults.standard.object(forKey: "fontSize") as? Double ?? 12.5 {
        didSet { UserDefaults.standard.set(fontSize, forKey: "fontSize") }
    }

    var isEditing = false
    private(set) var diff: LineDiff?
    private(set) var display: DiffDisplay?
    /// Goes up whenever `display` is rebuilt, so the list knows to reload.
    private(set) var displayGeneration = 0
    private(set) var isComputing = false
    private(set) var isLoading = false
    var currentHunk: Int?
    private(set) var scrollRequest: ScrollRequest?
    var errorMessage: String?

    private var expandedFolds: Set<Int> = []
    private var diffTask: Task<Void, Never>?
    private var loadTasks: [SideID: Task<Void, Never>] = [:]

    var isEmpty: Bool { left.isEmpty && right.isEmpty }
    var hasUnsavedChanges: Bool { left.isDirty || right.isDirty }
    var hasBinarySide: Bool { left.isBinary || right.isBinary }

    subscript(side: SideID) -> Side {
        get { side == .left ? left : right }
        set {
            if side == .left { left = newValue } else { right = newValue }
        }
    }

    // MARK: Loading and saving

    func open(_ urls: [URL]) {
        var remaining = urls
        if remaining.count >= 2 {
            load(remaining.removeFirst(), into: .left)
            load(remaining.removeFirst(), into: .right)
            return
        }
        guard let url = remaining.first else { return }
        load(url, into: left.isEmpty ? .left : (right.isEmpty ? .right : .left))
    }

    /// Shows a pair from the folder comparison. A file that only one folder has is compared
    /// with an empty side.
    func openPair(left leftURL: URL?, right rightURL: URL?) {
        guard canReplace(.left), canReplace(.right) else { return }
        isEditing = false
        for (url, side) in [(leftURL, SideID.left), (rightURL, .right)] {
            if let url { load(url, into: side) } else { self[side] = Side() }
        }
    }

    /// Reads the file off the main thread; a big file then does not stall the window.
    func load(_ url: URL, into side: SideID) {
        guard canReplace(side) else { return }
        loadTasks[side]?.cancel()
        isLoading = true
        loadTasks[side] = Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try FileContent.read(url) } }.value
            guard !Task.isCancelled else { return }
            loadTasks[side] = nil
            isLoading = !loadTasks.isEmpty
            switch result {
            case .success(let file):
                self[side] = Side(file: file)
                if hasBinarySide { isEditing = false }
            case .failure(let error):
                errorMessage = "Could not open \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    func reload() {
        for side in SideID.allCases {
            if let url = self[side].url { load(url, into: side) }
        }
    }

    var hasFiles: Bool { left.url != nil || right.url != nil }

    /// Replaces the whole text of a side, from the plain text editor.
    func setText(_ text: String, on side: SideID) {
        guard !self[side].isBinary else { return }
        setDocument(TextDocument(text), on: side)
    }

    private func setDocument(_ document: TextDocument, on side: SideID) {
        guard !self[side].isBinary else { return }
        self[side].content = .text(document)
        self[side].isDirty = self[side].url != nil
    }

    func pasteClipboard(into side: SideID) {
        guard canReplace(side), let text = NSPasteboard.general.string(forType: .string) else { return }
        self[side] = Side(content: .text(TextDocument(text)))
    }

    func clear(_ side: SideID) {
        guard canReplace(side) else { return }
        self[side] = Side()
    }

    func swapSides() {
        let previous = left
        left = right
        right = previous
    }

    func openPanel(for side: SideID?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = side == nil
        panel.message = side.map { "Choose the \($0.name.lowercased()) file" } ?? "Choose one or two files to compare"
        guard panel.runModal() == .OK else { return }
        if let side, let url = panel.url {
            load(url, into: side)
        } else {
            open(panel.urls)
        }
    }

    /// Asks to save first when the side has unsaved changes. False means: leave it alone.
    private func canReplace(_ side: SideID) -> Bool {
        guard self[side].isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save the changes to \(self[side].title)?"
        alert.informativeText = "The \(side.name.lowercased()) side has changes that are not saved yet."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save(side)
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    /// Writes every changed side. Returns false when a save failed or was cancelled.
    @discardableResult
    func saveAll() -> Bool {
        SideID.allCases.allSatisfy { !self[$0].isDirty || save($0) }
    }

    @discardableResult
    func save(_ side: SideID) -> Bool {
        var current = self[side]
        guard !current.isBinary else { return true }

        var destination = current.url
        if destination == nil {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "\(side.name).txt"
            guard panel.runModal() == .OK, let url = panel.url else { return false }
            destination = url
        }
        guard let destination else { return false }

        do {
            try current.encoding.encode(current.document).write(to: destination, options: .atomic)
            current.url = destination
            current.isDirty = false
            self[side] = current
            return true
        } catch {
            errorMessage = "Could not save \(destination.lastPathComponent): \(error.localizedDescription)"
            return false
        }
    }

    // MARK: Changes

    var hunkCount: Int { diff?.hunks.count ?? 0 }

    func goToNextChange() { move(by: 1) }
    func goToPreviousChange() { move(by: -1) }

    private func move(by step: Int) {
        guard hunkCount > 0 else { return }
        let next = currentHunk.map { ($0 + step + hunkCount) % hunkCount } ?? (step > 0 ? 0 : hunkCount - 1)
        select(hunk: next)
    }

    func select(hunk index: Int) {
        guard let diff, diff.hunks.indices.contains(index) else { return }
        currentHunk = index
        scroll(toRow: diff.hunkRows[index])
    }

    /// Unfolds what hides the row and asks the list to scroll to it.
    func scroll(toRow row: Int, side: SideID? = nil) {
        reveal(row: row)
        scrollRequest = ScrollRequest(id: (scrollRequest?.id ?? 0) + 1, row: row, side: side)
    }

    /// Copies a change over to the other side. `toRight` copies the left version to the right.
    func copy(hunk index: Int, toRight: Bool) {
        guard let diff, diff.hunks.indices.contains(index) else { return }
        let target: SideID = toRight ? .right : .left
        setDocument(diff.copying(hunk: index, toRight: toRight), on: target)
        // The next change now sits where this one was.
        currentHunk = index < hunkCount - 1 ? index : nil
    }

    func copyCurrentChange(toRight: Bool) {
        guard let currentHunk else { return }
        copy(hunk: currentHunk, toRight: toRight)
    }

    func expand(fold rows: Range<Int>) {
        expandedFolds.insert(rows.lowerBound)
        rebuildDisplay()
    }

    // MARK: Diffing

    private func sidesChanged(oldValue: Side, newValue: Side) {
        guard oldValue.revision != newValue.revision || oldValue.url != newValue.url else { return }
        // Typing recomputes after a short pause; opening or merging recomputes right away.
        scheduleDiff(delay: isEditing ? .milliseconds(150) : .zero)
    }

    private func scheduleDiff(delay: Duration) {
        diffTask?.cancel()
        guard !hasBinarySide else {
            diff = nil
            display = nil
            isComputing = false
            return
        }
        let leftDocument = left.document
        let rightDocument = right.document
        let options = options
        isComputing = true
        diffTask = Task {
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            let result = await Task.detached(priority: .userInitiated) {
                LineDiff(left: leftDocument, right: rightDocument, options: options)
            }.value
            guard !Task.isCancelled else { return }
            diff = result
            isComputing = false
            if let currentHunk, currentHunk >= result.hunks.count { self.currentHunk = result.hunks.isEmpty ? nil : result.hunks.count - 1 }
            expandedFolds = []
            rebuildDisplay()
        }
    }

    /// Folds away long runs of unchanged lines when "Only Changes" is on, keeping a few lines of
    /// context around every change.
    private func rebuildDisplay() {
        display = diff.map { DiffDisplay(diff: $0, layout: layout, foldUnchanged: onlyChanges, expandedFolds: expandedFolds) }
        displayGeneration += 1
    }

    /// Unfolds the fold that hides `row`, if any.
    private func reveal(row: Int) {
        if let rows = display?.fold(containingRow: row) { expand(fold: rows) }
    }
}

extension Side {
    init(file: FileContent) {
        switch file.body {
        case .text(let document, let encoding):
            self.init(content: .text(document), url: file.url)
            self.encoding = encoding
        case .binary(let data):
            self.init(content: .binary(data), url: file.url)
        }
    }
}
