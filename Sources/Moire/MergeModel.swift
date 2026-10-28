import AppKit
import MoireKit
import SwiftUI

/// One of the three files of a merge.
struct MergeSource {
    var url: URL?
    var document = TextDocument(lines: [], endsWithLineBreak: false)
    var encoding = TextEncoding.utf8
    /// True for a base that does not exist on disk, as git passes for a file both sides added.
    var isMissing = false

    var title: String { url?.lastPathComponent ?? "Not chosen" }

    var subtitle: String {
        guard let url else { return "Drop a file or click to choose" }
        let location = (url.deletingLastPathComponent().path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
        guard !isMissing else { return "\(location) · No such file, merged as empty" }
        let count = document.lines.count == 1 ? "1 line" : "\(document.lines.count) lines"
        let ending = switch document.lineEnding {
        case .lf: "LF"
        case .crlf: "CRLF"
        case .cr: "CR"
        }
        return "\(location) · \(count) · \(encoding.name) · \(ending)"
    }
}

extension ThreeWayMerge.Version {
    /// Left, base, right: the order the panes are shown in.
    static let displayOrder: [ThreeWayMerge.Version] = [.left, .base, .right]

    var name: String {
        switch self {
        case .left: "Left"
        case .base: "Base"
        case .right: "Right"
        }
    }

    var role: String {
        switch self {
        case .left: "Yours"
        case .base: "Common ancestor"
        case .right: "Theirs"
        }
    }
}

/// What the merge panes show: a line of an unchanged run, a block for every chunk that
/// changed, or a run of unchanged lines folded away.
struct MergeScrollRequest: Equatable {
    var chunk: Int
    var serial: Int
}

enum MergeItem: Hashable {
    case line(chunk: Int, offset: Int)
    case block(chunk: Int)
    case fold(chunk: Int, offsets: Range<Int>)
}

@Observable
final class MergeModel {
    private(set) var sources: [ThreeWayMerge.Version: MergeSource] = [:]
    private(set) var merge: ThreeWayMerge?
    private(set) var resolutions: [Int: ThreeWayMerge.Resolution] = [:] { didSet { recountResult() } }
    /// For every chunk, the line of the saved result it starts at.
    private(set) var resultStarts: [Int] = []
    private(set) var items: [MergeItem] = []
    private(set) var isComputing = false

    /// The chunk the merge commands act on.
    var currentChunk: Int?
    /// Asks both panes to scroll to a chunk. A new serial number makes every request count, also
    /// a second one for the same chunk.
    private(set) var scrollRequest = MergeScrollRequest(chunk: 0, serial: 0)
    /// The chunk whose result is being typed by hand.
    var editingChunk: Int?
    var editDraft = ""

    /// Where Save writes the result. Set by `--merge`, otherwise chosen on the first save.
    private(set) var output: URL?
    /// Started by `git mergetool`: quitting without a clean save exits with a failure.
    private(set) var isMergetool = false
    /// Resolutions changed since the files were opened or last saved.
    private(set) var isDirty = false
    /// The last save had no conflict markers left in it.
    private(set) var savedResolved = false
    var errorMessage: String?

    var onlyChanges = UserDefaults.standard.bool(forKey: "mergeOnlyChanges") {
        didSet {
            UserDefaults.standard.set(onlyChanges, forKey: "mergeOnlyChanges")
            expandedFolds = []
            rebuildItems()
        }
    }

    private var expandedFolds: Set<Int> = []
    private var mergeTask: Task<Void, Never>?

    subscript(version: ThreeWayMerge.Version) -> MergeSource {
        sources[version] ?? MergeSource()
    }

    var isReady: Bool { ThreeWayMerge.Version.allCases.allSatisfy { sources[$0]?.url != nil } }
    var conflictCount: Int { merge?.conflicts.count ?? 0 }
    var unresolvedCount: Int { merge?.unresolvedConflicts(resolutions).count ?? 0 }
    var changeCount: Int { merge?.chunks.count { $0.kind != .unchanged } ?? 0 }

    /// 0 after a save with every conflict resolved, 1 otherwise, so git sees an unfinished merge.
    var exitStatus: Int32 { savedResolved ? 0 : 1 }

    var labels: ThreeWayMerge.Labels {
        ThreeWayMerge.Labels(left: self[.left].title, base: self[.base].title, right: self[.right].title)
    }

    // MARK: Opening and saving

    /// `Moire --merge BASE LOCAL REMOTE MERGED`, as `git mergetool` runs it.
    func openMergetool(base: URL, left: URL, right: URL, output: URL) {
        isMergetool = true
        self.output = output
        load(base, into: .base, allowMissing: true)
        load(left, into: .left)
        load(right, into: .right)
    }

    func load(_ url: URL, into version: ThreeWayMerge.Version, allowMissing: Bool = false) {
        guard canDiscardResolutions() else { return }
        var source = MergeSource(url: url)
        if allowMissing, !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            source.isMissing = true
        } else {
            do {
                switch try FileContent.read(url).body {
                case .text(let document, let encoding):
                    source.document = document
                    source.encoding = encoding
                case .binary:
                    errorMessage = "\(url.lastPathComponent) is not a text file, so it cannot be merged line by line."
                    return
                }
            } catch {
                errorMessage = "Could not open \(url.lastPathComponent): \(error.localizedDescription)"
                return
            }
        }
        sources[version] = source
        remerge()
    }

    /// Three files dropped at once, in the order left, base, right.
    func open(_ urls: [URL]) {
        let order: [ThreeWayMerge.Version] = [.left, .base, .right]
        for (url, version) in zip(urls, order) { load(url, into: version) }
    }

    func openPanel(for version: ThreeWayMerge.Version) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.message = "Choose the \(version.name.lowercased()) file (\(version.role.lowercased()))"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url, into: version)
    }

    /// Asks for the missing files one after the other.
    func chooseFiles() {
        for version in [ThreeWayMerge.Version.left, .base, .right] where sources[version]?.url == nil {
            openPanel(for: version)
            guard sources[version]?.url != nil else { return }
        }
    }

    func reload() {
        guard canDiscardResolutions() else { return }
        isDirty = false
        for version in ThreeWayMerge.Version.allCases {
            if let url = sources[version]?.url { load(url, into: version, allowMissing: version == .base) }
        }
    }

    /// Writes the result. With conflicts left, asks first, and saves them with markers.
    @discardableResult
    func save() -> Bool {
        guard let merge else { return false }
        commitEdit()
        let unresolved = merge.unresolvedConflicts(resolutions).count
        if unresolved > 0 {
            let alert = NSAlert()
            alert.messageText = unresolved == 1 ? "1 conflict is not resolved" : "\(unresolved) conflicts are not resolved"
            alert.informativeText = "They are saved with conflict markers around both versions."
                + (isMergetool ? " git keeps the file marked as unmerged." : "")
            alert.addButton(withTitle: "Save Anyway")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
        }

        var destination = output
        if destination == nil {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = self[.left].url?.lastPathComponent ?? "Merged.txt"
            panel.directoryURL = self[.left].url?.deletingLastPathComponent()
            panel.message = "Save the merged result"
            guard panel.runModal() == .OK, let url = panel.url else { return false }
            destination = url
        }
        guard let destination else { return false }

        do {
            try FileWriter.write(self[.left].encoding.encode(merge.result(resolutions, labels: labels)), to: destination)
            output = destination
            isDirty = false
            savedResolved = unresolved == 0
            return true
        } catch {
            errorMessage = "Could not save \(destination.lastPathComponent): \(error.localizedDescription)"
            return false
        }
    }

    /// Asks before throwing away resolutions that are not saved. False means: leave it alone.
    private func canDiscardResolutions() -> Bool {
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save the merge result first?"
        alert.informativeText = "Opening another file starts the merge over, and the conflicts you resolved are lost."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    // MARK: Resolving

    func resolve(_ chunk: Int, _ resolution: ThreeWayMerge.Resolution) {
        guard let merge, merge.chunks.indices.contains(chunk) else { return }
        if editingChunk == chunk { editingChunk = nil }
        if resolution == merge.automaticResolution(of: chunk) {
            resolutions[chunk] = nil
        } else {
            resolutions[chunk] = resolution
        }
        isDirty = true
        currentChunk = chunk
    }

    /// Back to how the merge resolved the chunk by itself; for a conflict, unresolved again.
    func reset(_ chunk: Int) {
        guard resolutions[chunk] != nil else { return }
        if editingChunk == chunk { editingChunk = nil }
        resolutions[chunk] = nil
        isDirty = true
    }

    func resolution(of chunk: Int) -> ThreeWayMerge.Resolution? {
        resolutions[chunk]
    }

    /// What the menu commands use: resolve the current chunk, then go on to the next open conflict.
    func resolveCurrent(_ resolution: ThreeWayMerge.Resolution) {
        guard let currentChunk else { return }
        resolve(currentChunk, resolution)
        if let next = nextUnresolved(after: currentChunk) { select(next) }
    }

    func resetCurrent() {
        guard let currentChunk else { return }
        reset(currentChunk)
    }

    func beginEdit(_ chunk: Int) {
        guard let merge, merge.chunks.indices.contains(chunk) else { return }
        commitEdit()
        let lines = merge.resolvedLines(of: chunk, resolution: resolutions[chunk])
            ?? merge.resolvedLines(of: chunk, resolution: .leftThenRight)
            ?? []
        editDraft = TextDocument(textLines: lines, lineEnding: .lf).text
        editingChunk = chunk
        currentChunk = chunk
    }

    func beginEditCurrent() {
        guard let currentChunk else { return }
        beginEdit(currentChunk)
    }

    func commitEdit() {
        guard let chunk = editingChunk else { return }
        editingChunk = nil
        resolve(chunk, .edited(text: editDraft))
    }

    func cancelEdit() {
        editingChunk = nil
    }

    // MARK: Moving

    func goToNextConflict() { moveConflict(by: 1) }
    func goToPreviousConflict() { moveConflict(by: -1) }

    private func moveConflict(by step: Int) {
        guard let merge, !merge.conflicts.isEmpty else { return }
        let conflicts = merge.conflicts
        let target: Int = if let currentChunk {
            if step > 0 {
                conflicts.first { $0 > currentChunk } ?? conflicts[0]
            } else {
                conflicts.last { $0 < currentChunk } ?? conflicts[conflicts.count - 1]
            }
        } else {
            step > 0 ? conflicts[0] : conflicts[conflicts.count - 1]
        }
        select(target)
    }

    private func nextUnresolved(after chunk: Int) -> Int? {
        guard let merge else { return nil }
        let open = merge.unresolvedConflicts(resolutions)
        return open.first { $0 > chunk } ?? open.first
    }

    func select(_ chunk: Int) {
        currentChunk = chunk
        scrollRequest = MergeScrollRequest(chunk: chunk, serial: scrollRequest.serial + 1)
    }

    /// The position of a conflict among all conflicts, counting from 1.
    func conflictNumber(of chunk: Int) -> Int? {
        merge?.conflicts.firstIndex(of: chunk).map { $0 + 1 }
    }

    func expand(fold chunk: Int) {
        expandedFolds.insert(chunk)
        rebuildItems()
    }

    // MARK: Merging

    private func remerge() {
        mergeTask?.cancel()
        resolutions = [:]
        currentChunk = nil
        editingChunk = nil
        isDirty = false
        guard isReady else {
            merge = nil
            items = []
            return
        }
        let base = self[.base].document
        let left = self[.left].document
        let right = self[.right].document
        isComputing = true
        mergeTask = Task {
            let result = await Task.detached(priority: .userInitiated) {
                ThreeWayMerge(base: base, left: left, right: right)
            }.value
            guard !Task.isCancelled else { return }
            merge = result
            isComputing = false
            recountResult()
            expandedFolds = []
            rebuildItems()
            if let first = result.conflicts.first { select(first) }
        }
    }

    private func recountResult() {
        guard let merge else {
            resultStarts = []
            return
        }
        var starts: [Int] = []
        starts.reserveCapacity(merge.chunks.count)
        var line = 0
        for (index, chunk) in merge.chunks.enumerated() {
            starts.append(line)
            // An open conflict is saved with four marker lines around the three versions.
            line += merge.resolvedLines(of: index, resolution: resolutions[index])?.count
                ?? chunk.left.count + chunk.base.count + chunk.right.count + 4
        }
        resultStarts = starts
    }

    /// Every unchanged line on its own, so long files stay lazy, and folds around changes when
    /// "Only Changes" is on.
    private func rebuildItems() {
        guard let merge else {
            items = []
            return
        }
        let context = 3
        var items: [MergeItem] = []
        for (index, chunk) in merge.chunks.enumerated() {
            guard chunk.kind == .unchanged else {
                items.append(.block(chunk: index))
                continue
            }
            let count = chunk.base.count
            let keepBefore = index == 0 ? 0 : context
            let keepAfter = index == merge.chunks.count - 1 ? 0 : context
            let foldStart = keepBefore
            let foldEnd = count - keepAfter
            if onlyChanges, foldEnd - foldStart >= 4, !expandedFolds.contains(index) {
                items.append(contentsOf: (0..<foldStart).map { .line(chunk: index, offset: $0) })
                items.append(.fold(chunk: index, offsets: foldStart..<foldEnd))
                items.append(contentsOf: (foldEnd..<count).map { .line(chunk: index, offset: $0) })
            } else {
                items.append(contentsOf: (0..<count).map { .line(chunk: index, offset: $0) })
            }
        }
        self.items = items
    }
}
