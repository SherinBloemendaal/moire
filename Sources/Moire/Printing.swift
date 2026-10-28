import AppKit
import MoireKit
import UniformTypeIdentifiers
import WebKit

/// Prints what is on screen by laying out the same HTML page the exports write, in an
/// off-screen web view, always in light colors.
final class Printer: NSObject, WKNavigationDelegate {
    /// Kept alive until the print panel is done; the web view loads asynchronously.
    private static var current: Printer?

    private let webView: WKWebView
    private let title: String

    private init(title: String) {
        self.title = title
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 1400))
        webView.appearance = NSAppearance(named: .aqua)
        super.init()
        webView.navigationDelegate = self
    }

    static func print(html: String, title: String) {
        let printer = Printer(title: title)
        current = printer
        printer.webView.loadHTMLString(html, baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let info = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo.shared
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.topMargin = 36
        info.bottomMargin = 36
        info.leftMargin = 28
        info.rightMargin = 28
        let operation = webView.printOperation(with: info)
        operation.jobTitle = title
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        // WebKit needs a frame on its print view, or it prints blank pages.
        operation.view?.frame = webView.bounds
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
        Self.current = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Self.current = nil
    }
}

extension AppState {
    var canPrint: Bool {
        switch mode {
        case .text: ComparisonExport.canExport(compare)
        case .folders: folders.tree != nil && !folders.isComparing
        case .merge: merge.merge != nil
        }
    }

    func printCurrent() {
        switch mode {
        case .text:
            guard let diff = compare.diff, ComparisonExport.canExport(compare) else { return }
            let page = HTMLReport.page(
                for: diff,
                left: HTMLReport.Side(title: compare.left.title, detail: compare.left.subtitle),
                right: HTMLReport.Side(title: compare.right.title, detail: compare.right.subtitle),
                context: compare.onlyChanges ? 3 : nil,
                generated: Date.now.formatted(date: .long, time: .shortened)
            )
            Printer.print(html: page, title: "\(compare.left.title) and \(compare.right.title)")
        case .folders:
            guard let page = folderReport(.html) else { return }
            Printer.print(html: page, title: "Folder comparison")
        case .merge:
            guard let result = merge.merge?.result(merge.resolutions, labels: merge.labels) else { return }
            let text = result.text
            let page = """
            <!doctype html><html><head><meta charset="utf-8"><style>
            body { font: 10pt ui-monospace, Menlo, monospace; white-space: pre-wrap; margin: 0 }
            h1 { font: 600 14pt -apple-system, sans-serif; white-space: normal }
            </style></head><body><h1>Merge result</h1>\(FolderReport.escape(text))</body></html>
            """
            Printer.print(html: page, title: "Merge result")
        }
    }

    func folderReport(_ format: FolderReport.Format) -> String? {
        guard let tree = folders.tree, !folders.isComparing, let left = folders.left, let right = folders.right else { return nil }
        let options = FolderReport.Options(
            onlyDifferences: folders.filter == .differences,
            leftName: (left.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath,
            rightName: (right.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath,
            method: folders.method
        )
        return FolderReport.render(tree, format: format, options: options)
    }

    /// Saves the folder comparison as an HTML page, JSON or plain text.
    func exportFolderReport(_ format: FolderReport.Format) {
        guard let report = folderReport(format) else { return }
        let panel = NSSavePanel()
        let (name, type): (String, UTType) = switch format {
        case .html: ("Folder comparison.html", .html)
        case .json: ("Folder comparison.json", .json)
        case .text: ("Folder comparison.txt", .plainText)
        }
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [type]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(report.utf8).write(to: url, options: .atomic)
        } catch {
            folders.errorMessage = "Could not export \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }
}
