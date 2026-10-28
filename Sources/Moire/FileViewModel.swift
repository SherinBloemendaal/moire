import Foundation
import MoireKit

/// The ways a pair of files can be shown. Moire picks one from the kind of the files, and the
/// toolbar lets you pick another, for example to see a text file as hex.
enum FileView: String, CaseIterable, Identifiable {
    case text
    case hex
    case image
    case table
    case document
    case archive

    var id: Self { self }

    var title: String {
        switch self {
        case .text: "Text"
        case .hex: "Hex"
        case .image: "Image"
        case .table: "Table"
        case .document: "Document Text"
        case .archive: "Archive"
        }
    }

    var systemImage: String {
        switch self {
        case .text: "text.alignleft"
        case .hex: "number"
        case .image: "photo"
        case .table: "tablecells"
        case .document: "doc.richtext"
        case .archive: "archivebox"
        }
    }
}

/// A view with differences to step through, for Next and Previous Change.
@MainActor
protocol DifferenceNavigating: AnyObject {
    var differenceCount: Int { get }
    func goToNextDifference()
    func goToPreviousDifference()
}

/// The bytes of one side, for the hex view: the file on disk while it has no unsaved edits,
/// otherwise the text as it would be saved.
enum ByteInput: Sendable {
    case none
    case file(URL)
    case data(Data)
}

@Observable
final class FileViewModel {
    /// The kind of each side, nil for a side without a file (typed text, or empty).
    private(set) var leftKind: FileKind?
    private(set) var rightKind: FileKind?
    private(set) var leftURL: URL?
    private(set) var rightURL: URL?
    private(set) var hasLeftContent = false
    private(set) var hasRightContent = false
    /// Goes up whenever either side changes, so the views know to compare again.
    private(set) var revision = 0
    /// Picked by hand. Cleared when other files are opened.
    var chosen: FileView?
    /// The view on screen that has differences to step through.
    weak var navigator: (any DifferenceNavigating)?
    /// Opens archives in the folder comparison; the flag is true when Moire does it on its
    /// own rather than on a click. Set by `AppState`.
    @ObservationIgnored var openArchivesAsFolders: ((URL?, URL?, Bool) -> Void)?
    /// True while archives are being unpacked for the folder comparison.
    var isOpeningArchives = false
    /// The last pair that was sent to the folder comparison on its own, so it happens once.
    @ObservationIgnored private var routedPair: [URL?]?

    func update(left: Side, right: Side) {
        revision += 1
        hasLeftContent = !left.isEmpty
        hasRightContent = !right.isEmpty
        guard left.url != leftURL || right.url != rightURL else {
            // The same files, read again from disk: they may have become another kind. A side
            // with unsaved edits keeps its kind; its file did not change.
            if !left.isDirty { leftKind = left.url.map(FileKind.detect) }
            if !right.isDirty { rightKind = right.url.map(FileKind.detect) }
            return
        }
        let urlsSwapped = left.url == rightURL && right.url == leftURL
        if urlsSwapped {
            swap(&leftKind, &rightKind)
        } else {
            leftKind = left.url.map(FileKind.detect)
            rightKind = right.url.map(FileKind.detect)
            chosen = nil
        }
        leftURL = left.url
        rightURL = right.url
        routeArchivesIfNeeded()
    }

    /// What is on screen: the choice when it fits the files, otherwise the automatic pick.
    var current: FileView {
        if let chosen, available.contains(chosen) { return chosen }
        return automatic
    }

    var isSpecial: Bool { current != .text }

    /// Editing is for text. A document, image or archive that happens to decode as text is not
    /// edited, so it cannot be saved back as text by accident.
    var allowsEditing: Bool {
        kinds.allSatisfy { $0 == .text || $0 == .table }
    }

    var automatic: FileView {
        let kinds = kinds
        guard let first = kinds.first else { return .text }
        if kinds.allSatisfy({ $0 == first }) { return Self.view(for: first) }
        if kinds.allSatisfy({ $0 == .text || $0 == .table }) { return .text }
        if kinds.allSatisfy(\.isDocument) { return .document }
        return .hex
    }

    var available: [FileView] {
        let kinds = kinds
        var views: [FileView] = [.text, .hex]
        if kinds.allSatisfy({ $0 == .text || $0 == .table }) { views.append(.table) }
        if !kinds.isEmpty, kinds.allSatisfy({ $0 == .image }) { views.append(.image) }
        if !kinds.isEmpty, kinds.allSatisfy(\.isDocument) { views.append(.document) }
        if !kinds.isEmpty, kinds.allSatisfy(\.isArchive) { views.append(.archive) }
        return FileView.allCases.filter(views.contains)
    }

    var differenceCount: Int { navigator?.differenceCount ?? 0 }

    func archiveFormat(onLeft: Bool) -> ArchiveFormat? {
        if case .archive(let format)? = onLeft ? leftKind : rightKind { return format }
        return nil
    }

    func documentFormat(onLeft: Bool) -> DocumentFormat? {
        if case .document(let format)? = onLeft ? leftKind : rightKind { return format }
        return nil
    }

    /// Kinds of the sides that have something: a file's kind, or text for typed text.
    private var kinds: [FileKind] {
        var kinds: [FileKind] = []
        if let leftKind { kinds.append(leftKind) } else if hasLeftContent { kinds.append(.text) }
        if let rightKind { kinds.append(rightKind) } else if hasRightContent { kinds.append(.text) }
        return kinds
    }

    private static func view(for kind: FileKind) -> FileView {
        switch kind {
        case .text: .text
        case .table: .table
        case .image: .image
        case .document: .document
        case .archive: .archive
        case .binary: .hex
        }
    }

    /// Two archives open in the folder comparison right away, like two folders do.
    private func routeArchivesIfNeeded() {
        guard leftURL != nil, rightURL != nil, archiveFormat(onLeft: true) != nil, archiveFormat(onLeft: false) != nil else { return }
        let pair = [leftURL, rightURL]
        guard routedPair != pair else { return }
        routedPair = pair
        openArchivesAsFolders?(leftURL, rightURL, true)
    }
}

extension FileKind {
    var isDocument: Bool {
        if case .document = self { return true }
        return false
    }

    var isArchive: Bool {
        if case .archive = self { return true }
        return false
    }
}

extension Side {
    var byteInput: ByteInput {
        if let url, !isDirty { return .file(url) }
        switch content {
        case .binary(_, let data?): return .data(data)
        case .binary(_, nil): return url.map(ByteInput.file) ?? .none
        case .text(let text):
            if isEmpty { return .none }
            return .data((try? encoding.encode(text)) ?? Data(text.utf8))
        }
    }
}
