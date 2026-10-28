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
        didSet { revision = Side.nextRevision() }
    }
    var url: URL?
    var encoding: TextEncoding = .utf8
    var isDirty = false
    /// Different for every content any side ever had, so a change is noticed without comparing
    /// the text, also when a whole new side replaces this one.
    private(set) var revision = Side.nextRevision()

    private static var revisions = 0

    private static func nextRevision() -> Int {
        revisions += 1
        return revisions
    }

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

    /// Where a downloaded copy came from, e.g. `sftp://host/srv/app`; shown instead of its temporary folder.
    var origin: String?

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
        let location = origin ?? url.map { ($0.deletingLastPathComponent().path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath } ?? "Typed or pasted"
        return "\(location) · \(lines) · \(encoding.name) · \(ending)"
    }
}

typealias SideID = DiffSide

extension DiffSide {
    var name: String { self == .left ? "Left" : "Right" }
}

/// Asks the diff list to scroll to a row. Every request has a new id, so asking for the same
/// row twice scrolls twice. With a match, the list also scrolls sideways to show it.
struct ScrollRequest: Equatable {
    var id: Int
    var row: Int
    var side: SideID?
    var match: SearchMatch?
}

/// What a search found in the two documents of the current diff.
struct SearchResults {
    /// Per side, in line order, to find the matches of one line.
    var left: [SearchMatch] = []
    var right: [SearchMatch] = []
    /// Both sides together in the order they appear in the list.
    var ordered: [SearchMatch] = []
    var rows: [Int] = []

    func matches(on side: SideID, line: Int) -> ArraySlice<SearchMatch> {
        let all = side == .left ? left : right
        var low = 0
        var high = all.count
        while low < high {
            let middle = (low + high) / 2
            if all[middle].line < line { low = middle + 1 } else { high = middle }
        }
        var end = low
        while end < all.count, all[end].line == line { end += 1 }
        return all[low..<end]
    }
}

/// A line that was jumped to, marked for a moment.
struct FlashedLine: Equatable {
    var id: Int
    var side: SideID
    var line: Int
}

@Observable
final class CompareModel {
    typealias Layout = DiffDisplay.Layout

    var left = Side() { didSet { sidesChanged(.left, oldValue: oldValue) } }
    var right = Side() { didSet { sidesChanged(.right, oldValue: oldValue) } }

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
            if isSearchVisible, !searchQuery.isEmpty { scheduleSearch(delay: .zero, jump: false) }
        }
    }

    var fontSize: Double = UserDefaults.standard.object(forKey: "fontSize") as? Double ?? 12.5 {
        didSet { UserDefaults.standard.set(fontSize, forKey: "fontSize") }
    }

    var isEditing = false
    /// Text taken from documents: shown and compared, never changed or saved.
    var isReadOnly = false
    /// How the files are shown: as text, or as hex, an image, a table and so on.
    let fileView = FileViewModel()
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

    var isSearchVisible = false
    var searchQuery = "" {
        didSet { if searchQuery != oldValue { scheduleSearch(delay: .milliseconds(120), jump: true) } }
    }
    var searchCaseSensitive = false {
        didSet { if searchCaseSensitive != oldValue { scheduleSearch(delay: .zero, jump: true) } }
    }
    private(set) var searchResults: SearchResults?
    private(set) var currentMatch: Int?
    /// Goes up whenever matches or the current match change, so the list redraws.
    private(set) var searchGeneration = 0
    private(set) var isSearching = false
    /// Goes up to ask the find field for focus.
    private(set) var searchFocusRequest = 0
    private var searchTask: Task<Void, Never>?
    /// The first row the list shows, kept up to date by the list. Searching starts there.
    @ObservationIgnored var firstVisibleRow = 0

    var isGoToLineVisible = false
    private(set) var flashedLine: FlashedLine?

    /// The colors of each side, for files of a language Moire knows.
    @ObservationIgnored private(set) var highlighters: [SideID: SyntaxHighlightCache] = [:]
    /// True while a side changes by an edit rather than being replaced.
    @ObservationIgnored private var replacedByEdit = false
    /// The revisions of the sides that `diff` was worked out from.
    @ObservationIgnored private var diffRevisions = (0, 0)

    @ObservationIgnored private var watchers: [SideID: FileWatcher] = [:]
    /// How each file looked when it was read or saved, to tell a real change from our own save.
    @ObservationIgnored private var diskSignatures: [SideID: FileSignature] = [:]
    @ObservationIgnored private var isAskingToReload: Set<SideID> = []

    /// Lines the user put on one row; the diff is worked out around them.
    private(set) var anchors: [LineAnchor] = []
    /// A line marked on each side, to be aligned once both are marked.
    private(set) var alignmentMarks: [SideID: Int] = [:]

    /// Goes up when a side is replaced as a whole.
    private(set) var replacements = 0
    /// The window's undo manager, set by the diff list.
    @ObservationIgnored weak var undoManager: UndoManager?
    /// The line being typed in: its first change is one undo step, the rest of the typing joins it.
    @ObservationIgnored private var typingSession: (side: SideID, line: Int)?
    @ObservationIgnored private var isTyping = false

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

    /// Shows copies downloaded from a server, read-only: there is nowhere to save them back to.
    func openDownloaded(left: (url: URL, origin: String)?, right: (url: URL, origin: String)?) {
        guard canReplace(.left), canReplace(.right) else { return }
        isEditing = false
        for (file, side) in [(left, SideID.left), (right, .right)] {
            if let file { load(file.url, into: side, askFirst: false, origin: file.origin) } else { self[side] = Side() }
        }
        isReadOnly = true
    }

    /// Reads the file off the main thread; a big file then does not stall the window. Unsaved
    /// changes are only asked about when `askFirst` is set.
    func load(_ url: URL, into side: SideID, askFirst: Bool = true, origin: String? = nil) {
        guard !askFirst || canReplace(side) else { return }
        isReadOnly = false
        loadTasks[side]?.cancel()
        isLoading = true
        loadTasks[side] = Task {
            let result = await Task.detached(priority: .userInitiated) {
                // Taken before reading: a write during the read then still counts as a change.
                let signature = FileSignature(url: url)
                return Result { (try FileContent.read(url), signature) }
            }.value
            guard !Task.isCancelled else { return }
            loadTasks[side] = nil
            isLoading = !loadTasks.isEmpty
            switch result {
            case .success(let (file, signature)):
                forgetEdits()
                var new = Side(file: file)
                new.origin = origin
                self[side] = new
                diskSignatures[side] = signature
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
        guard !isReadOnly, !self[side].isBinary else { return }
        forgetEdits()
        setDocument(TextDocument(text), on: side)
    }

    private func setDocument(_ document: TextDocument, on side: SideID) {
        guard !isReadOnly, !self[side].isBinary else { return }
        replacedByEdit = true
        defer { replacedByEdit = false }
        self[side].content = .text(document)
        self[side].isDirty = self[side].url != nil
    }

    func pasteClipboard(into side: SideID) {
        guard canReplace(side), let text = NSPasteboard.general.string(forType: .string) else { return }
        forgetEdits()
        self[side] = Side(content: .text(TextDocument(text)))
    }

    func clear(_ side: SideID) {
        guard canReplace(side) else { return }
        forgetEdits()
        self[side] = Side()
    }

    func swapSides() {
        let swappedAnchors = anchors.map { LineAnchor(left: $0.right, right: $0.left) }
        let swappedMarks = [SideID.left: alignmentMarks[.right], .right: alignmentMarks[.left]].compactMapValues { $0 }
        forgetEdits()
        anchors = swappedAnchors
        alignmentMarks = swappedMarks
        diskSignatures = [.left: diskSignatures[.right], .right: diskSignatures[.left]].compactMapValues { $0 }
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
            // Our own save is not a change on disk to reload.
            diskSignatures[side] = FileSignature(url: destination)
            return true
        } catch {
            errorMessage = "Could not save \(destination.lastPathComponent): \(error.localizedDescription)"
            return false
        }
    }

    // MARK: Aligning lines by hand

    var canAlign: Bool { alignmentMarks[.left] != nil && alignmentMarks[.right] != nil }

    /// Marks a line to be aligned; marking the same line again takes the mark away.
    func toggleAlignmentMark(side: SideID, line: Int) {
        alignmentMarks[side] = alignmentMarks[side] == line ? nil : line
    }

    func alignMarkedLines() {
        guard let leftLine = alignmentMarks[.left], let rightLine = alignmentMarks[.right] else { return }
        anchors = LineAnchor.adding(LineAnchor(left: leftLine, right: rightLine), to: anchors)
        alignmentMarks = [:]
        scheduleDiff(delay: .zero)
    }

    func removeAlignment(_ anchor: LineAnchor) {
        anchors.removeAll { $0 == anchor }
        scheduleDiff(delay: .zero)
    }

    func clearAlignments() {
        anchors = []
        alignmentMarks = [:]
        scheduleDiff(delay: .zero)
    }

    // MARK: Changes on disk

    private func watch(_ side: SideID) {
        watchers[side]?.stop()
        watchers[side] = nil
        guard let url = self[side].url else {
            diskSignatures[side] = nil
            return
        }
        watchers[side] = FileWatcher(url: url) { [weak self] in
            self?.fileChangedOnDisk(side, url: url)
        }
    }

    /// Reloads a side whose file was written by another app. A side with unsaved changes asks
    /// first; keeping them is remembered until the file changes again.
    private func fileChangedOnDisk(_ side: SideID, url: URL) {
        guard self[side].url == url, !isAskingToReload.contains(side) else { return }
        guard let signature = FileSignature(url: url), signature != diskSignatures[side] else { return }
        guard self[side].isDirty else {
            load(url, into: side, askFirst: false)
            return
        }
        isAskingToReload.insert(side)
        defer { isAskingToReload.remove(side) }
        let alert = NSAlert()
        alert.messageText = "\(url.lastPathComponent) changed on disk"
        alert.informativeText = "Another app saved this file, but the \(side.name.lowercased()) side also has changes that are not saved yet. Reload it and lose your changes, or keep your version?"
        alert.addButton(withTitle: "Keep Mine")
        alert.addButton(withTitle: "Reload")
        if alert.runModal() == .alertSecondButtonReturn {
            load(url, into: side, askFirst: false)
        } else {
            diskSignatures[side] = FileSignature(url: url)
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
        guard !isReadOnly, let diff = currentDiff(), diff.hunks.indices.contains(index) else { return }
        perform(diff.edit(copyingHunk: index, toRight: toRight), actionName: toRight ? "Copy Change to Right" : "Copy Change to Left")
        // The next change now sits where this one was.
        currentHunk = index < diff.hunks.count - 1 ? index : nil
    }

    /// The diff of the documents as they are now. Right after typing the shown diff can be a
    /// moment behind; merging must not work on old line numbers.
    private func currentDiff() -> LineDiff? {
        guard let diff, !hasBinarySide else { return nil }
        if diffRevisions == (left.revision, right.revision), diff.anchors == LineAnchor.normalized(anchors, leftCount: left.document.lines.count, rightCount: right.document.lines.count) {
            return diff
        }
        return LineDiff(left: left.document, right: right.document, options: options, anchors: anchors)
    }

    /// Copies one line of a change: the left version of that row goes right, or the other way.
    func copy(row index: Int, toRight: Bool) {
        guard let diff = currentDiff(), index < diff.rowCount, let edit = diff.edit(copyingRow: index, toRight: toRight) else { return }
        perform(edit, actionName: toRight ? "Copy Line to Right" : "Copy Line to Left")
    }

    func copyCurrentChange(toRight: Bool) {
        guard let currentHunk else { return }
        copy(hunk: currentHunk, toRight: toRight)
    }

    func expand(fold rows: Range<Int>) {
        expandedFolds.insert(rows.lowerBound)
        rebuildDisplay()
    }

    // MARK: Editing

    /// Changes lines of one side as one undoable step.
    func perform(_ edit: LineEdit, actionName: String, typing: Bool = false) {
        guard !isReadOnly, !self[edit.side].isBinary else { return }
        let document = self[edit.side].document
        guard edit.range.upperBound <= document.lines.count else { return }
        let inverse = edit.inverse(in: document)
        // Before the document changes, so the diff it starts already uses the moved anchors.
        anchors = anchors.compactMap { $0.adjusted(for: edit) }
        alignmentMarks[edit.side] = alignmentMarks[edit.side].flatMap { edit.map(line: $0) }
        isTyping = typing
        setDocument(document.applying(edit), on: edit.side)
        isTyping = false
        registerUndo(inverse, actionName: actionName)
    }

    /// Typing in a line. The first change of a line registers one undo step that brings the
    /// whole line back; the keys after it join that step.
    func setLine(_ text: String, line: Int, on side: SideID) {
        let document = self[side].document
        guard line < document.lines.count, document.lines[line] != text else { return }
        let edit = LineEdit(side: side, range: line..<(line + 1), lines: [text])
        if let session = typingSession, session.side == side, session.line == line {
            isTyping = true
            setDocument(document.applying(edit), on: side)
            isTyping = false
        } else {
            typingSession = (side, line)
            perform(edit, actionName: "Typing", typing: true)
        }
    }

    /// Replaces one line by several, as Return, joining lines or pasting do.
    func replaceLines(_ range: Range<Int>, with lines: [String], on side: SideID) {
        endTypingSession()
        perform(LineEdit(side: side, range: range, lines: Lines(lines)), actionName: "Typing")
    }

    func endTypingSession() {
        typingSession = nil
    }

    private func registerUndo(_ inverse: LineEdit, actionName: String) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                model.endTypingSession()
                model.perform(inverse, actionName: actionName)
            }
        }
        undoManager.setActionName(actionName)
    }

    /// Undo steps refer to line numbers, so they end when a side is replaced as a whole.
    private func forgetEdits() {
        typingSession = nil
        undoManager?.removeAllActions(withTarget: self)
        replacements += 1
        anchors = []
        alignmentMarks = [:]
    }

    // MARK: Diffing

    private func sidesChanged(_ side: SideID, oldValue: Side) {
        let newValue = self[side]
        fileView.update(left: left, right: right)
        guard oldValue.revision != newValue.revision || oldValue.url != newValue.url else { return }
        // A side read from disk or pasted gets new colors; an edit keeps what still holds.
        if isReplacement(of: oldValue, by: newValue) { resetHighlighter(side) }
        if oldValue.url != newValue.url { watch(side) }
        // Typing recomputes after a short pause; opening or merging recomputes right away.
        scheduleDiff(delay: isEditing || isTyping ? .milliseconds(150) : .zero)
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
        let revisions = (left.revision, right.revision)
        let options = options
        let anchors = anchors
        isComputing = true
        diffTask = Task {
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            let result = await Task.detached(priority: .userInitiated) {
                LineDiff(left: leftDocument, right: rightDocument, options: options, anchors: anchors)
            }.value
            guard !Task.isCancelled else { return }
            diff = result
            diffRevisions = revisions
            isComputing = false
            highlighters[.left]?.update(to: result.left)
            highlighters[.right]?.update(to: result.right)
            if let currentHunk, currentHunk >= result.hunks.count { self.currentHunk = result.hunks.isEmpty ? nil : result.hunks.count - 1 }
            expandedFolds = []
            rebuildDisplay()
            if isSearchVisible, !searchQuery.isEmpty { scheduleSearch(delay: .zero, jump: false) }
        }
    }

    /// Folds away long runs of unchanged lines when "Only Changes" is on, keeping a few lines of
    /// context around every change.
    private func rebuildDisplay() {
        display = diff.map { DiffDisplay(diff: $0, layout: layout, foldUnchanged: onlyChanges, expandedFolds: expandedFolds) }
        displayGeneration += 1
    }

    // MARK: Search

    var searchMatchCount: Int { searchResults?.ordered.count ?? 0 }

    func showSearch() {
        isSearchVisible = true
        searchFocusRequest += 1
        if !searchQuery.isEmpty, searchResults == nil { scheduleSearch(delay: .zero, jump: true) }
    }

    func hideSearch() {
        isSearchVisible = false
        searchTask?.cancel()
        searchResults = nil
        currentMatch = nil
        isSearching = false
        searchGeneration += 1
    }

    func findNext() { moveMatch(by: 1) }
    func findPrevious() { moveMatch(by: -1) }

    private func moveMatch(by step: Int) {
        guard let results = searchResults, !results.ordered.isEmpty else {
            if !isSearchVisible { showSearch() }
            return
        }
        let count = results.ordered.count
        let next: Int
        if let currentMatch {
            next = (currentMatch + step + count) % count
        } else {
            let start = firstMatch(atOrAfterRow: firstVisibleRow, in: results)
            next = step > 0 ? start : (start - 1 + count) % count
        }
        select(match: next)
    }

    private func select(match index: Int) {
        guard let results = searchResults, results.ordered.indices.contains(index) else { return }
        currentMatch = index
        searchGeneration += 1
        let match = results.ordered[index]
        reveal(row: results.rows[index])
        scrollRequest = ScrollRequest(id: (scrollRequest?.id ?? 0) + 1, row: results.rows[index], side: match.side, match: match)
    }

    private func firstMatch(atOrAfterRow row: Int, in results: SearchResults) -> Int {
        var low = 0
        var high = results.rows.count
        while low < high {
            let middle = (low + high) / 2
            if results.rows[middle] < row { low = middle + 1 } else { high = middle }
        }
        return low < results.rows.count ? low : 0
    }

    /// Searches the documents of the diff on screen. `jump` moves to the first match from the
    /// top of the list, as typing in the find field does.
    private func scheduleSearch(delay: Duration, jump: Bool) {
        searchTask?.cancel()
        guard isSearchVisible, !searchQuery.isEmpty, let diff else {
            searchResults = nil
            currentMatch = nil
            isSearching = false
            searchGeneration += 1
            return
        }
        let query = searchQuery
        let caseSensitive = searchCaseSensitive
        let previousRow = currentMatch.flatMap { searchResults?.rows[$0] }
        isSearching = true
        searchTask = Task {
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            let results = await Task.detached(priority: .userInitiated) {
                Self.search(query, in: diff, caseSensitive: caseSensitive)
            }.value
            guard !Task.isCancelled else { return }
            searchResults = results
            isSearching = false
            searchGeneration += 1
            if results.ordered.isEmpty {
                currentMatch = nil
            } else if jump {
                select(match: firstMatch(atOrAfterRow: firstVisibleRow, in: results))
            } else {
                currentMatch = previousRow.map { firstMatch(atOrAfterRow: $0, in: results) }
            }
        }
    }

    nonisolated private static func search(_ query: String, in diff: LineDiff, caseSensitive: Bool) -> SearchResults {
        var results = SearchResults()
        results.left = TextSearch.matches(of: query, in: diff.left.lines, side: .left, caseSensitive: caseSensitive)
        results.right = TextSearch.matches(of: query, in: diff.right.lines, side: .right, caseSensitive: caseSensitive)
        let leftRows = results.left.map { diff.row(ofLine: $0.line, on: .left) }
        let rightRows = results.right.map { diff.row(ofLine: $0.line, on: .right) }
        results.ordered.reserveCapacity(leftRows.count + rightRows.count)
        results.rows.reserveCapacity(leftRows.count + rightRows.count)
        var l = 0
        var r = 0
        // Each side is already in row order; on one row the left side comes first.
        while l < leftRows.count || r < rightRows.count {
            if r == rightRows.count || (l < leftRows.count && leftRows[l] <= rightRows[r]) {
                results.ordered.append(results.left[l])
                results.rows.append(leftRows[l])
                l += 1
            } else {
                results.ordered.append(results.right[r])
                results.rows.append(rightRows[r])
                r += 1
            }
        }
        return results
    }

    // MARK: Go to line

    func goToLine(_ number: Int, on side: SideID) {
        guard let diff else { return }
        let count = side == .left ? diff.left.lines.count : diff.right.lines.count
        guard count > 0 else { return }
        let line = min(max(number, 1), count) - 1
        scroll(toRow: diff.row(ofLine: line, on: side), side: side)
        let flash = FlashedLine(id: (flashedLine?.id ?? 0) + 1, side: side, line: line)
        flashedLine = flash
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            if flashedLine == flash { flashedLine = nil }
        }
    }

    private func isReplacement(of old: Side, by new: Side) -> Bool {
        old.url != new.url || old.isBinary != new.isBinary || !replacedByEdit
    }

    /// The language follows the file name; pasted text has none.
    private func resetHighlighter(_ side: SideID) {
        let language = self[side].url.flatMap { SyntaxLanguage(fileName: $0.lastPathComponent) }
        highlighters[side] = self[side].isBinary ? nil : language.map { SyntaxHighlightCache(language: $0) }
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
