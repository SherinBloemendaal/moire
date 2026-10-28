/// A comparison as one self-contained HTML page: both sides next to each other with the changed
/// words marked, light or dark following the reader's system. No scripts, fonts or images are
/// loaded from anywhere, so the file can be mailed or archived as it is.
public enum HTMLReport {
    public struct Side: Sendable, Hashable {
        public var title: String
        public var detail: String

        public init(title: String, detail: String = "") {
            self.title = title
            self.detail = detail
        }
    }

    /// `context` folds runs of unchanged lines away, keeping that many lines around every
    /// change; `nil` shows every line.
    public static func page(for diff: LineDiff, left: Side, right: Side, context: Int? = nil, generated: String) -> String {
        var body = ""
        for item in items(for: diff, context: context) {
            switch item {
            case .row(let index):
                body += row(diff.rows[index], diff: diff)
            case .fold(let count):
                body += "<tr class=\"fold\"><td colspan=\"4\">\(count) unchanged lines</td></tr>\n"
            }
        }
        if diff.rows.isEmpty {
            body = "<tr class=\"fold\"><td colspan=\"4\">Both sides are empty</td></tr>\n"
        }

        let statistics = diff.statistics
        let summary = statistics.isIdentical
            ? "<span class=\"chip same\">Identical</span>"
            : """
            <span class="chip add">\(statistics.added) added</span>\
            <span class="chip del">\(statistics.removed) removed</span>\
            <span class="chip chg">\(statistics.changed) changed</span>
            """
        let title = escape("\(left.title) and \(right.title)")

        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="generator" content="Moire">
        <title>\(title)</title>
        <style>
        \(style)
        </style>
        </head>
        <body>
        <header>
        <h1>\(title)</h1>
        <p class="meta">Compared with Moire on \(escape(generated))</p>
        <div class="summary">\(summary)</div>
        </header>
        <main>
        <table>
        <colgroup><col class="n"><col><col class="n"><col></colgroup>
        <thead><tr>
        <th colspan="2"><span class="name">\(escape(left.title))</span><span class="detail">\(escape(left.detail))</span></th>
        <th colspan="2"><span class="name">\(escape(right.title))</span><span class="detail">\(escape(right.detail))</span></th>
        </tr></thead>
        <tbody>
        \(body)</tbody>
        </table>
        </main>
        </body>
        </html>

        """
    }

    private enum Item {
        case row(Int)
        case fold(Int)
    }

    private static func items(for diff: LineDiff, context: Int?) -> [Item] {
        guard let context else { return diff.rows.indices.map(Item.row) }
        var items: [Item] = []
        var index = 0
        let rows = diff.rows
        while index < rows.count {
            guard rows[index].hunk == nil else {
                items.append(.row(index))
                index += 1
                continue
            }
            var end = index
            while end < rows.count, rows[end].hunk == nil { end += 1 }
            let foldStart = index == 0 ? 0 : index + context
            let foldEnd = end == rows.count ? end : end - context
            // Folding fewer than a few lines saves nothing and hides context.
            if foldEnd - foldStart >= 4 {
                items.append(contentsOf: (index..<foldStart).map(Item.row))
                items.append(.fold(foldEnd - foldStart))
                items.append(contentsOf: (foldEnd..<end).map(Item.row))
            } else {
                items.append(contentsOf: (index..<end).map(Item.row))
            }
            index = end
        }
        return items
    }

    private static func row(_ row: DiffRow, diff: LineDiff) -> String {
        let kind = switch row.kind {
        case .same: "same"
        case .changed: "chg"
        case .removed: "del"
        case .added: "add"
        }
        let left = cells(number: row.left, line: row.left.map { diff.left.lines[$0] }, segments: row.leftSegments, mark: "del")
        let right = cells(number: row.right, line: row.right.map { diff.right.lines[$0] }, segments: row.rightSegments, mark: "ins")
        return "<tr class=\"\(kind)\">\(left)\(right)</tr>\n"
    }

    private static func cells(number: Int?, line: String?, segments: [Segment]?, mark: String) -> String {
        guard let number, let line else {
            return "<td class=\"n\"></td><td class=\"empty\"></td>"
        }
        let content = segments.map { segments in
            segments.map { $0.isChanged ? "<\(mark)>\(escape($0.text))</\(mark)>" : escape($0.text) }.joined()
        } ?? escape(line)
        return "<td class=\"n\">\(number + 1)</td><td class=\"code\">\(content)</td>"
    }

    static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&#39;"
            default: result.append(character)
            }
        }
        return result
    }

    private static let style = """
    :root {
      color-scheme: light dark;
      --window: #f4f4f8; --pane: #ffffff; --border: rgba(0,0,0,.08); --text: #1b1c2a; --muted: #9a9ab0;
      --add: #059669; --add-row: rgba(16,185,129,.10); --add-word: rgba(16,185,129,.30);
      --del: #e11d48; --del-row: rgba(244,63,94,.09); --del-word: rgba(244,63,94,.26);
      --chg: #d97706; --iris: #7c5cff; --fill: rgba(0,0,0,.035);
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --window: #0c0d14; --pane: #12131d; --border: rgba(255,255,255,.08); --text: #e4e5f1; --muted: #5e6078;
        --add: #34d399; --add-row: rgba(16,185,129,.12); --add-word: rgba(16,185,129,.36);
        --del: #fb7185; --del-row: rgba(244,63,94,.12); --del-word: rgba(244,63,94,.36);
        --chg: #fbbf24; --fill: rgba(255,255,255,.04);
      }
    }
    * { box-sizing: border-box; }
    body { margin: 0; padding: 24px; background: var(--window); color: var(--text);
      font: 14px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif; }
    header { margin: 0 0 16px; }
    h1 { margin: 0 0 4px; font-size: 20px; font-weight: 650; word-break: break-word; }
    .meta { margin: 0 0 10px; color: var(--muted); font-size: 12px; }
    .summary { display: flex; flex-wrap: wrap; gap: 6px; }
    .chip { font-size: 11px; font-weight: 600; padding: 3px 9px; border-radius: 99px; font-variant-numeric: tabular-nums; }
    .chip.add { color: var(--add); background: var(--add-row); }
    .chip.del { color: var(--del); background: var(--del-row); }
    .chip.chg { color: var(--chg); background: color-mix(in srgb, var(--chg) 12%, transparent); }
    .chip.same { color: var(--iris); background: color-mix(in srgb, var(--iris) 12%, transparent); }
    main { background: var(--pane); border: 1px solid var(--border); border-radius: 12px; overflow: auto; }
    table { width: 100%; border-collapse: collapse; table-layout: fixed;
      font: 12.5px/1.5 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
    col.n { width: 4.2em; }
    th { position: sticky; top: 0; z-index: 1; background: var(--pane); text-align: left; font: 600 13px -apple-system, system-ui, sans-serif;
      padding: 10px 14px; border-bottom: 1px solid var(--border); }
    th + th { border-left: 1px solid var(--border); }
    th .detail { display: block; font-weight: 400; font-size: 11px; color: var(--muted); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    td { padding: 1px 14px 1px 0; vertical-align: top; }
    td.n { color: var(--muted); text-align: right; padding-right: 10px; user-select: none; -webkit-user-select: none; }
    td.code { white-space: pre-wrap; word-break: break-all; tab-size: 4; }
    td:nth-child(3) { border-left: 1px solid var(--border); }
    tr.del td:nth-child(2), tr.chg td:nth-child(2) { background: var(--del-row); }
    tr.add td:nth-child(4), tr.chg td:nth-child(4) { background: var(--add-row); }
    tr.del td:nth-child(1), tr.chg td:nth-child(1) { color: var(--del); }
    tr.add td:nth-child(3), tr.chg td:nth-child(3) { color: var(--add); }
    td.empty { background: repeating-linear-gradient(-45deg, transparent 0 6px, var(--border) 6px 7px); }
    del { text-decoration: none; background: var(--del-word); border-radius: 2px; }
    ins { text-decoration: none; background: var(--add-word); border-radius: 2px; }
    tr.fold td { text-align: center; color: var(--muted); background: var(--fill); font: 500 11px -apple-system, system-ui, sans-serif;
      padding: 5px; border-top: 1px solid var(--border); border-bottom: 1px solid var(--border); }
    @media print { body { padding: 0; background: none; } th { position: static; } }
    """
}
