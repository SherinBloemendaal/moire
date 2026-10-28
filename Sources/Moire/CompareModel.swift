import AppKit
import MoireKit
import SwiftUI

/// One side of a comparison: pasted or typed text, or a file.
struct Side {
    enum Content: Equatable {
        case text(String)
        /// A file that is not text. Only its bytes can be compared.
        case binary(Data)
    }

    var content: Content = .text("")
    var url: URL?
    var encoding: TextEncoding = .utf8
    var isDirty = false

    var text: String {
        if case .text(let text) = content { return text }
        return ""
    }

    var isBinary: Bool {
        if case .binary = content { return true }
        return false
    }

    var isEmpty: Bool { url == nil && text.isEmpty && !isBinary }

    var title: String { url?.lastPathComponent ?? "Untitled" }

    var subtitle: String {
        if case .binary(let data) = content {
            return "Binary · " + ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
        }
        let document = TextDocument(text)
        let lines = document.lines.count == 1 ? "1 line" : "\(document.lines.count) lines"
        let ending = switch document.lineEnding {
        case .lf: "LF"
        case .crlf: "CRLF"
        case .cr: "CR"
        }
        let location = url.map { ($0.deletingLastPathComponent().path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath } ?? "Typed or pasted"
        return "\(location) · \(lines) · \(encoding.name) · \(ending)"
    }
}

enum SideID: CaseIterable {
    case left, right

    var name: String { self == .left ? "Left" : "Right" }
}

/// What the diff list shows: unchanged lines, a block of changed lines, or a run of unchanged
/// lines folded away.
enum DisplayItem: Identifiable, Hashable {
    case same(row: Int)
    case hunk(index: Int, rows: Range<Int>)
    case fold(rows: Range<Int>)

    var id: Int {
        switch self {
        case .same(let row): row
        case .hunk(_, let rows): rows.lowerBound
        // Negative, so a fold never collides with a row it replaces.
        case .fold(let rows): -rows.lowerBound - 1
        }
    }
}

@Observable
final class CompareModel {
    enum Layout: String, CaseIterable {
        case sideBySide
        case unified
    }

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
        didSet { UserDefaults.standard.set(layout.rawValue, forKey: "layout") }
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
    /// Text taken from documents: shown and compared, never changed or saved.
    var isReadOnly = false
    /// How the files are shown: as text, or as hex, an image, a table and so on.
    let fileView = FileViewModel()
    private(set) var diff: LineDiff?
    private(set) var displayItems: [DisplayItem] = []
    private(set) var isComputing = false
    var currentHunk: Int?
    /// Set to ask the diff list to scroll; the list clears it once it has scrolled.
    var scrollRequest: Int?
    var errorMessage: String?

    private var expandedFolds: Set<Int> = []
    private var diffTask: Task<Void, Never>?

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

    func load(_ url: URL, into side: SideID) {
        guard canReplace(side) else { return }
        do {
            let file = try FileContent.read(url)
            var new = Side(url: url)
            switch file.body {
            case .text(let document, let encoding):
                new.content = .text(document.text)
                new.encoding = encoding
            case .binary(let data):
                new.content = .binary(data)
            }
            self[side] = new
            if hasBinarySide { isEditing = false }
        } catch {
            errorMessage = "Could not open \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func reload() {
        for side in SideID.allCases {
            if let url = self[side].url { load(url, into: side) }
        }
    }

    var hasFiles: Bool { left.url != nil || right.url != nil }

    func setText(_ text: String, on side: SideID) {
        guard !isReadOnly, !self[side].isBinary, self[side].text != text else { return }
        self[side].content = .text(text)
        self[side].isDirty = self[side].url != nil
    }

    func pasteClipboard(into side: SideID) {
        guard canReplace(side), let text = NSPasteboard.general.string(forType: .string) else { return }
        self[side] = Side(content: .text(text))
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
            try current.encoding.encode(current.text).write(to: destination, options: .atomic)
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
        reveal(row: diff.hunkRows[index])
        scrollRequest = diff.hunkRows[index]
    }

    /// Copies a change over to the other side. `toRight` copies the left version to the right.
    func copy(hunk index: Int, toRight: Bool) {
        guard !isReadOnly, let diff, diff.hunks.indices.contains(index) else { return }
        let target: SideID = toRight ? .right : .left
        setText(diff.copying(hunk: index, toRight: toRight).text, on: target)
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
        fileView.update(left: left, right: right)
        guard oldValue.content != newValue.content else { return }
        // Typing recomputes after a short pause; opening or merging recomputes right away.
        scheduleDiff(delay: isEditing ? .milliseconds(150) : .zero)
    }

    private func scheduleDiff(delay: Duration) {
        diffTask?.cancel()
        guard !hasBinarySide else {
            diff = nil
            displayItems = []
            return
        }
        let leftDocument = TextDocument(left.text)
        let rightDocument = TextDocument(right.text)
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
        guard let diff else {
            displayItems = []
            return
        }
        let context = 3
        var items: [DisplayItem] = []
        var index = 0
        let rows = diff.rows

        while index < rows.count {
            if let hunk = rows[index].hunk {
                var end = index
                while end < rows.count, rows[end].hunk == hunk { end += 1 }
                items.append(.hunk(index: hunk, rows: index..<end))
                index = end
                continue
            }

            var end = index
            while end < rows.count, rows[end].hunk == nil { end += 1 }
            let keepBefore = index == 0 ? 0 : context
            let keepAfter = end == rows.count ? 0 : context
            let foldStart = index + keepBefore
            let foldEnd = end - keepAfter

            if onlyChanges, foldEnd - foldStart >= 4, !expandedFolds.contains(foldStart) {
                items.append(contentsOf: (index..<foldStart).map { .same(row: $0) })
                items.append(.fold(rows: foldStart..<foldEnd))
                items.append(contentsOf: (foldEnd..<end).map { .same(row: $0) })
            } else {
                items.append(contentsOf: (index..<end).map { .same(row: $0) })
            }
            index = end
        }
        displayItems = items
    }

    /// Unfolds the fold that hides `row`, if any.
    private func reveal(row: Int) {
        for case .fold(let rows) in displayItems where rows.contains(row) {
            expand(fold: rows)
        }
    }
}
