import AppKit
import MoireKit
import PDFKit
import SwiftUI

/// Takes the text out of PDF and word processor documents.
enum DocumentReader {
    struct Extracted: Sendable {
        var document: TextDocument
        /// Pages for a PDF, nil for other documents.
        var pageCount: Int?
    }

    enum ReadError: LocalizedError {
        case unreadable(String)
        case locked(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name): "\(name) could not be read as a document."
            case .locked(let name): "\(name) is locked with a password."
            }
        }
    }

    nonisolated static func read(_ url: URL, format: DocumentFormat) throws -> Extracted {
        let name = url.lastPathComponent
        switch format {
        case .pdf:
            guard let pdf = PDFDocument(url: url) else { throw ReadError.unreadable(name) }
            guard !pdf.isLocked else { throw ReadError.locked(name) }
            let pages = (0..<pdf.pageCount).map { pdf.page(at: $0)?.string ?? "" }
            return Extracted(document: DocumentText.pages(pages), pageCount: pdf.pageCount)
        case .docx, .doc, .rtf, .odt:
            let type: NSAttributedString.DocumentType = switch format {
            case .docx: .officeOpenXML
            case .doc: .docFormat
            case .rtf: .rtf
            default: .openDocument
            }
            do {
                let text = try NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil)
                return Extracted(document: DocumentText.text(text.string), pageCount: nil)
            } catch {
                throw ReadError.unreadable(name)
            }
        }
    }
}

/// Holds the text of both documents in a comparison of its own, which is read-only.
@Observable
final class DocumentModel: DifferenceNavigating {
    let text = CompareModel()
    private(set) var leftPages: Int?
    private(set) var rightPages: Int?
    private(set) var errorMessage: String?
    private(set) var isReading = false

    init() {
        text.isReadOnly = true
    }

    var differenceCount: Int { text.hunkCount }
    func goToNextDifference() { text.goToNextChange() }
    func goToPreviousDifference() { text.goToPreviousChange() }

    func load(left: (URL, DocumentFormat)?, right: (URL, DocumentFormat)?) async {
        isReading = true
        errorMessage = nil
        async let leftText = Self.extract(left)
        async let rightText = Self.extract(right)
        let (a, b) = await (leftText, rightText)
        guard !Task.isCancelled else { return }
        isReading = false
        do {
            let leftDocument = try a.get()
            let rightDocument = try b.get()
            leftPages = leftDocument?.pageCount
            rightPages = rightDocument?.pageCount
            text.left = Side(content: .text(leftDocument?.document.text ?? ""))
            text.right = Side(content: .text(rightDocument?.document.text ?? ""))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static func extract(_ file: (URL, DocumentFormat)?) async -> Result<DocumentReader.Extracted?, Error> {
        guard let (url, format) = file else { return .success(nil) }
        do {
            return .success(try await runDetached { try DocumentReader.read(url, format: format) })
        } catch {
            return .failure(error)
        }
    }
}

struct DocumentCompareView: View {
    let compare: CompareModel
    @State private var model = DocumentModel()

    var body: some View {
        let files = compare.fileView
        let text = model.text
        KindLayout {
            if let error = model.errorMessage {
                KindMessage(systemImage: "exclamationmark.triangle", title: "The text could not be read", message: error)
            } else if model.isReading {
                KindMessage(systemImage: "doc.richtext", title: "Reading the documents…", isWorking: true)
            } else if let diff = text.diff {
                if diff.statistics.isIdentical {
                    KindMessage(systemImage: "checkmark.circle.fill", title: "The text is the same",
                                message: "Both documents hold the same text. Layout, fonts and images are not compared.")
                } else {
                    HStack(spacing: 0) {
                        DiffListView(model: text, diff: diff)
                        ChangeMap(model: text, diff: diff)
                    }
                }
            } else {
                KindMessage(systemImage: "doc.richtext", title: "Comparing the text…", isWorking: true)
            }
        } bar: {
            Chip(text: "Compared as text", color: Theme.iris, systemImage: "doc.plaintext")
                .help("Only the text is compared, read-only. Layout, fonts and images are left out, and nothing can be saved back.")
            if let statistics = text.diff?.statistics, !statistics.isIdentical {
                Chip(text: "\(statistics.added) added", color: Theme.added)
                Chip(text: "\(statistics.removed) removed", color: Theme.removed)
                Chip(text: "\(statistics.changed) changed", color: Theme.changed)
            }
            if let pages = pagesText {
                Text(pages).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            DifferenceStepper(count: text.hunkCount, current: text.currentHunk, previous: text.goToPreviousChange, next: text.goToNextChange)
        }
        .task(id: files.revision) {
            await model.load(left: file(onLeft: true), right: file(onLeft: false))
        }
        .onAppear {
            files.navigator = model
            syncSettings()
        }
        .onDisappear { if files.navigator === model { files.navigator = nil } }
        .onChange(of: compare.layout) { syncSettings() }
        .onChange(of: compare.onlyChanges) { syncSettings() }
        .onChange(of: compare.fontSize) { syncSettings() }
        .onChange(of: compare.options) { syncSettings() }
    }

    private func file(onLeft: Bool) -> (URL, DocumentFormat)? {
        guard let url = onLeft ? compare.left.url : compare.right.url,
              let format = compare.fileView.documentFormat(onLeft: onLeft) else { return nil }
        return (url, format)
    }

    private var pagesText: String? {
        switch (model.leftPages, model.rightPages) {
        case let (l?, r?): l == r ? "\(l) pages each" : "\(l) and \(r) pages"
        case let (l?, nil): "\(l) pages on the left"
        case let (nil, r?): "\(r) pages on the right"
        case (nil, nil): nil
        }
    }

    /// The document text follows the layout and options of the main comparison.
    private func syncSettings() {
        let text = model.text
        if text.layout != compare.layout { text.layout = compare.layout }
        if text.onlyChanges != compare.onlyChanges { text.onlyChanges = compare.onlyChanges }
        if text.fontSize != compare.fontSize { text.fontSize = compare.fontSize }
        if text.options != compare.options { text.options = compare.options }
    }
}
