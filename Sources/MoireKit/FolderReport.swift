import Foundation

/// A finished folder comparison written out for people or programs.
public enum FolderReport {
    public enum Format: String, Sendable, CaseIterable {
        case text
        case json
        case html
    }

    public struct Options: Sendable {
        public var onlyDifferences: Bool
        public var leftName: String
        public var rightName: String
        public var method: CompareMethod

        public init(onlyDifferences: Bool = false, leftName: String, rightName: String, method: CompareMethod) {
            self.onlyDifferences = onlyDifferences
            self.leftName = leftName
            self.rightName = rightName
            self.method = method
        }
    }

    public static func render(_ tree: FolderTree, format: Format, options: Options) -> String {
        switch format {
        case .text: text(tree, options)
        case .json: json(tree, options)
        case .html: html(tree, options)
        }
    }

    static func label(_ status: FolderTree.Status) -> String {
        switch status {
        case .identical: "identical"
        case .different: "different"
        case .leftOnly: "left only"
        case .rightOnly: "right only"
        case .pending: "not compared"
        case .unreadable: "unreadable"
        }
    }

    private static func items(_ tree: FolderTree, _ options: Options) -> [Int] {
        (1..<tree.count).filter { !options.onlyDifferences || tree.status(of: $0) != .identical }
    }

    private static func summary(_ tree: FolderTree) -> [FolderTree.Status: Int] {
        var counts: [FolderTree.Status: Int] = [:]
        for item in 1..<tree.count where !tree.isDirectory(item) {
            counts[tree.status(of: item), default: 0] += 1
        }
        return counts
    }

    // MARK: Text

    private static func text(_ tree: FolderTree, _ options: Options) -> String {
        var lines: [String] = []
        let marks: [FolderTree.Status: String] = [.identical: "=", .different: "≠", .leftOnly: "<", .rightOnly: ">", .pending: "?", .unreadable: "!"]
        for item in items(tree, options) {
            let path = tree.path(of: item) + (tree.isDirectory(item) ? "/" : "")
            var line = "\(marks[tree.status(of: item)] ?? "?") \(path)"
            if let changed = tree.changedLines(of: item) { line += "  (\(changed) \(changed == 1 ? "line" : "lines"))" }
            if let error = tree.error(at: item) { line += "  (\(error))" }
            lines.append(line)
        }
        let counts = summary(tree)
        lines.append("")
        lines.append([
            "\(counts[.different] ?? 0) different",
            "\(counts[.leftOnly] ?? 0) left only",
            "\(counts[.rightOnly] ?? 0) right only",
            "\(counts[.identical] ?? 0) identical",
        ].joined(separator: ", ") + ((counts[.unreadable] ?? 0) > 0 ? ", \(counts[.unreadable] ?? 0) unreadable" : ""))
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: JSON

    private struct JSONReport: Encodable {
        struct Side: Encodable {
            let kind: String
            let size: Int64?
            let modified: String?
        }

        struct Item: Encodable {
            let path: String
            let folder: Bool
            let status: String
            let left: Side?
            let right: Side?
            let changedLines: Int?
            let error: String?
        }

        let left: String
        let right: String
        let method: String
        let summary: [String: Int]
        let items: [Item]
    }

    private static func json(_ tree: FolderTree, _ options: Options) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func side(_ info: FolderTree.SideInfo) -> JSONReport.Side? {
            guard info.exists else { return nil }
            let kind = switch info.kind {
            case .file: "file"
            case .directory: "folder"
            case .symbolicLink: "link"
            case .other, .absent: "other"
            }
            let isFile = info.kind == .file || info.kind == .symbolicLink
            return JSONReport.Side(
                kind: kind,
                size: isFile ? info.size : nil,
                modified: isFile ? formatter.string(from: Date(timeIntervalSince1970: Double(info.modified) / 1e9)) : nil
            )
        }
        let report = JSONReport(
            left: options.leftName,
            right: options.rightName,
            method: options.method.rawValue,
            summary: Dictionary(uniqueKeysWithValues: summary(tree).map { (label($0.key), $0.value) }),
            items: items(tree, options).map { item in
                JSONReport.Item(
                    path: tree.path(of: item),
                    folder: tree.isDirectory(item),
                    status: label(tree.status(of: item)),
                    left: side(tree.left(item)),
                    right: side(tree.right(item)),
                    changedLines: tree.changedLines(of: item),
                    error: tree.error(at: item)
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? String(decoding: encoder.encode(report), as: UTF8.self)).map { $0 + "\n" } ?? "{}\n"
    }

    // MARK: HTML

    public static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            default: result.append(character)
            }
        }
        return result
    }

    private static func html(_ tree: FolderTree, _ options: Options) -> String {
        let counts = summary(tree)
        let sizeFormatter = ByteCountFormatter()
        sizeFormatter.countStyle = .file
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short

        func cell(_ info: FolderTree.SideInfo) -> String {
            guard info.exists, info.kind != .directory else { return "<td></td><td></td>" }
            let date = dateFormatter.string(from: Date(timeIntervalSince1970: Double(info.modified) / 1e9))
            return "<td class=\"num\">\(escape(sizeFormatter.string(fromByteCount: info.size)))</td><td class=\"num\">\(escape(date))</td>"
        }

        var rows = ""
        for item in items(tree, options) {
            let status = tree.status(of: item)
            let css = switch status {
            case .identical: "same"
            case .different: "diff"
            case .leftOnly: "left"
            case .rightOnly: "right"
            case .pending, .unreadable: "warn"
            }
            let indent = tree.depth(of: item) * 18
            let icon = tree.isDirectory(item) ? "📁" : "📄"
            var label = label(status)
            if let changed = tree.changedLines(of: item) { label += " · \(changed) \(changed == 1 ? "line" : "lines")" }
            rows += "<tr class=\"\(css)\"><td style=\"padding-left:\(indent + 10)px\">\(icon) \(escape(tree.name(of: item)))</td>"
                + cell(tree.left(item)) + cell(tree.right(item))
                + "<td><span class=\"pill\">\(escape(label))</span></td></tr>\n"
        }

        return """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Moire: \(escape(options.leftName)) and \(escape(options.rightName))</title>
        <style>
        :root { --bg:#f6f6fa; --pane:#fff; --text:#1b1c2a; --muted:#6b6b85; --line:rgba(0,0,0,.08);
          --diff:#d97706; --left:#e11d48; --right:#059669; --same:#9a9ab0; --brand:linear-gradient(90deg,#7c5cff,#22d3ee); }
        @media (prefers-color-scheme: dark) { :root { --bg:#0c0d14; --pane:#12131d; --text:#e4e5f1; --muted:#8c8da6;
          --line:rgba(255,255,255,.08); --diff:#fbbf24; --left:#fb7185; --right:#34d399; --same:#5e6078; } }
        * { box-sizing:border-box } body { margin:0; padding:32px 16px; background:var(--bg); color:var(--text);
          font:13px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif }
        main { max-width:1100px; margin:0 auto } h1 { font-size:26px; margin:0 0 4px; letter-spacing:-.5px }
        .bar { height:4px; width:160px; border-radius:2px; background:var(--brand); margin:10px 0 18px }
        .muted { color:var(--muted) } .chips { display:flex; flex-wrap:wrap; gap:8px; margin:16px 0 20px }
        .chip { padding:3px 10px; border-radius:999px; font-weight:600; font-size:12px }
        .c-diff { color:var(--diff); background:color-mix(in srgb,var(--diff) 14%,transparent) }
        .c-left { color:var(--left); background:color-mix(in srgb,var(--left) 14%,transparent) }
        .c-right { color:var(--right); background:color-mix(in srgb,var(--right) 14%,transparent) }
        .c-same { color:var(--same); background:color-mix(in srgb,var(--same) 14%,transparent) }
        .wrap { overflow-x:auto; background:var(--pane); border:1px solid var(--line); border-radius:12px }
        table { border-collapse:collapse; width:100%; min-width:760px } th, td { padding:5px 10px; text-align:left; white-space:nowrap }
        th { font-size:11px; text-transform:uppercase; letter-spacing:.4px; color:var(--muted); border-bottom:1px solid var(--line) }
        td.num { text-align:right; color:var(--muted); font-variant-numeric:tabular-nums } tr + tr td { border-top:1px solid var(--line) }
        .pill { font-weight:600; font-size:11px; padding:2px 8px; border-radius:999px }
        tr.diff .pill { color:var(--diff); background:color-mix(in srgb,var(--diff) 14%,transparent) }
        tr.left .pill { color:var(--left); background:color-mix(in srgb,var(--left) 14%,transparent) }
        tr.right .pill { color:var(--right); background:color-mix(in srgb,var(--right) 14%,transparent) }
        tr.same { color:var(--muted) } tr.same .pill { color:var(--same) } tr.warn .pill { color:var(--left) }
        </style></head><body><main>
        <h1>Folder comparison</h1>
        <div class="muted">\(escape(options.leftName)) &nbsp;⇄&nbsp; \(escape(options.rightName)) · compared by \(options.method.rawValue)</div>
        <div class="bar"></div>
        <div class="chips">
        <span class="chip c-diff">\(counts[.different] ?? 0) different</span>
        <span class="chip c-left">\(counts[.leftOnly] ?? 0) left only</span>
        <span class="chip c-right">\(counts[.rightOnly] ?? 0) right only</span>
        <span class="chip c-same">\(counts[.identical] ?? 0) identical</span>
        </div>
        <div class="wrap"><table>
        <thead><tr><th>Name</th><th>Left size</th><th>Left modified</th><th>Right size</th><th>Right modified</th><th>Status</th></tr></thead>
        <tbody>
        \(rows)</tbody></table></div>
        <p class="muted">Made with Moire.</p>
        </main></body></html>

        """
    }
}
