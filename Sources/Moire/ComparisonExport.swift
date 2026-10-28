import AppKit
import MoireKit
import UniformTypeIdentifiers

/// Writes the text comparison to a file: as a patch, or as an HTML page to read or share.
enum ComparisonExport {
    static func canExport(_ model: CompareModel) -> Bool {
        !model.isEmpty && !model.hasBinarySide && model.diff != nil
    }

    /// The patch compares the exact text, so `patch -p1` or `git apply` gives the right file back.
    static func exportPatch(_ model: CompareModel) {
        guard canExport(model) else { return }
        let left = TextDocument(model.left.text)
        let right = TextDocument(model.right.text)
        if left.lineEnding == .cr || right.lineEnding == .cr {
            let alert = NSAlert()
            alert.messageText = "The patch will use LF line endings"
            alert.informativeText = "A file with old Mac line endings (CR only) is one long line to patch and git apply, so its lines are written with LF. Applying the patch gives the right text, but with LF line endings."
            alert.addButton(withTitle: "Export Anyway")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        // Both headers name the left file: `patch` applies to the first name and `git apply` to the
        // second, so with two different names they would each change another file.
        let name = model.left.url == nil ? model.right.title : model.left.title
        let text = UnifiedDiff.patch(from: left, to: right, leftLabel: "a/\(name)", rightLabel: "b/\(name)")
        guard !text.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "There is nothing to export"
            alert.informativeText = "Both sides are exactly the same, so the patch would be empty."
            alert.runModal()
            return
        }
        save(Data(text.utf8), suggestedName: "\(baseName(model.right)).patch", type: UTType(filenameExtension: "patch") ?? .plainText, model: model)
    }

    /// The report shows what the comparison shows: the same ignore options, and folded the same way.
    static func exportHTML(_ model: CompareModel) {
        guard canExport(model), let diff = model.diff else { return }
        let page = HTMLReport.page(
            for: diff,
            left: HTMLReport.Side(title: model.left.title, detail: model.left.subtitle),
            right: HTMLReport.Side(title: model.right.title, detail: model.right.subtitle),
            context: model.onlyChanges ? 3 : nil,
            generated: Date.now.formatted(date: .long, time: .shortened)
        )
        save(Data(page.utf8), suggestedName: "\(baseName(model.right)) comparison.html", type: .html, model: model)
    }

    private static func baseName(_ side: Side) -> String {
        side.url?.deletingPathExtension().lastPathComponent ?? "Comparison"
    }

    private static func save(_ data: Data, suggestedName: String, type: UTType, model: CompareModel) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [type]
        panel.directoryURL = model.right.url?.deletingLastPathComponent() ?? model.left.url?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            model.errorMessage = "Could not export \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }
}
