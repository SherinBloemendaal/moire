import AppKit
import MoireKit

/// Typing in the comparison: one line at a time, in an editor laid over that line.
extension DiffListController {
    func beginEditing(side: SideID, line: Int, event: NSEvent?) {
        guard !model.isEditing, model.canEdit(side), line < model[side].document.lines.count else { return }
        if let editor, editor.side == side, editor.line == line { return }
        endEditing()
        let editor = InlineEditor(side: side, line: line, metrics: metrics, controller: self)
        self.editor = editor
        editor.load(model[side].document.lines[line], caret: nil)
        tableView.addSubview(editor.scrollView)
        positionEditor()
        editor.textView.sizeToFit()
        editor.scroll(toOffset: horizontalOffset)
        tableView.window?.makeFirstResponder(editor.textView)
        if let event {
            // The click that opened the editor also places the caret, or starts a selection.
            editor.textView.mouseDown(with: event)
        }
        redrawVisibleRows()
    }

    func endEditing() {
        guard let editor else { return }
        let wasFocused = tableView.window?.firstResponder === editor.textView
        editor.scrollView.removeFromSuperview()
        self.editor = nil
        model.endTypingSession()
        redrawVisibleRows()
        if wasFocused { tableView.window?.makeFirstResponder(tableView) }
    }

    /// After the list reloaded: the line may have moved, been folded away, or changed under the
    /// editor (undo, a merge, a reload).
    func syncEditor() {
        guard let editor else { return }
        let lines = model[editor.side].document.lines
        guard editor.line < lines.count else {
            endEditing()
            return
        }
        let current = lines[editor.line]
        if current != editor.text {
            editor.load(current, caret: editor.textView.selectedRange().location)
        }
        positionEditor()
    }

    func positionEditor() {
        guard let editor, let display else { return }
        let diff = display.diff
        let lineCount = editor.side == .left ? diff.left.lines.count : diff.right.lines.count
        // Right after Return the new line is not in the shown diff yet; it comes a moment later.
        guard editor.line < lineCount else { return }
        guard let line = display.line(ofDocumentLine: editor.line, on: editor.side) else {
            if let fold = display.fold(containingRow: diff.row(ofLine: editor.line, on: editor.side)) {
                model.expand(fold: fold)
            }
            return
        }
        let row = tableView.rect(ofRow: line)
        let text = textFrame(side: editor.side, layout: display.layout)
        editor.scrollView.frame = NSRect(x: text.minX, y: row.minY, width: max(0, text.width), height: row.height)
        editor.textView.sizeToFit()
        editor.textView.frame.size.width = max(editor.textView.frame.width, text.width)
    }

    /// Where the text of a side sits in a row, from its left edge.
    func textFrame(side: SideID, layout: DiffDisplay.Layout) -> NSRect {
        if layout == .unified {
            return NSRect(x: unifiedTextX, y: 0, width: tableView.bounds.width - unifiedTextX - DiffMetrics.trailingPadding, height: metrics.lineHeight)
        }
        let frame = sideFrame(side)
        return NSRect(x: frame.minX + metrics.gutterWidth, y: 0, width: frame.width - metrics.gutterWidth - DiffMetrics.trailingPadding, height: metrics.lineHeight)
    }

    /// The text areas of a display line, for the I-beam cursor.
    func textFrames(forLine index: Int) -> [NSRect] {
        guard let display, index < display.count else { return [] }
        let item = display[index]
        guard let row = item.row else { return [] }
        let diffRow = display.diff.row(at: row, withSegments: false)
        if display.layout == .unified {
            return [textFrame(side: .left, layout: .unified)]
        }
        return SideID.allCases.filter { diffRow.line(on: $0) != nil }.map { textFrame(side: $0, layout: .sideBySide) }
    }

    // MARK: From the editor

    func editorDidChange(_ editor: InlineEditor) {
        model.setLine(editor.text, line: editor.line, on: editor.side)
        editor.textView.sizeToFit()
    }

    /// Inserts text with line breaks at the selection: the line becomes several lines.
    func editorInsert(_ editor: InlineEditor, text: String, replacing range: NSRange? = nil) {
        let current = editor.text as NSString
        let selection = range ?? editor.textView.selectedRange()
        let before = current.substring(to: selection.location)
        let after = current.substring(from: NSMaxRange(selection))
        let pieces = Self.splitLines(before + text + after)
        model.replaceLines(editor.line..<(editor.line + 1), with: pieces, on: editor.side)
        let last = pieces.last ?? ""
        editor.line += pieces.count - 1
        editor.load(last, caret: (last as NSString).length - (after as NSString).length)
        positionEditor()
    }

    /// Backspace at the start of a line, or Delete at its end, joins it with the line next to it.
    func editorJoin(_ editor: InlineEditor, withNext: Bool) -> Bool {
        let lines = model[editor.side].document.lines
        let other = withNext ? editor.line + 1 : editor.line - 1
        guard other >= 0, other < lines.count else { return false }
        let upper = min(editor.line, other)
        let first = lines[upper]
        let joined = first + lines[upper + 1]
        model.replaceLines(upper..<(upper + 2), with: [joined], on: editor.side)
        editor.line = upper
        editor.load(joined, caret: (first as NSString).length)
        positionEditor()
        return true
    }

    /// The arrow keys move the editor up or down a line, keeping the column.
    func editorMove(_ editor: InlineEditor, by step: Int) -> Bool {
        let lines = model[editor.side].document.lines
        let target = editor.line + step
        guard target >= 0, target < lines.count else { return false }
        let column = editor.textView.selectedRange().location
        model.endTypingSession()
        editor.line = target
        editor.load(lines[target], caret: column)
        positionEditor()
        if let display, let line = display.line(ofDocumentLine: target, on: editor.side) {
            tableView.scrollRowToVisible(line)
        }
        redrawVisibleRows()
        return true
    }

    /// Splits on `\r\n`, `\n` and `\r`, keeping empty lines, so "a\n" is "a" and "".
    static func splitLines(_ text: String) -> [String] {
        var lines: [String] = []
        var current = ""
        var previousWasCR = false
        for scalar in text.unicodeScalars {
            if scalar == "\n", previousWasCR {
                previousWasCR = false
                continue
            }
            previousWasCR = scalar == "\r"
            if scalar == "\n" || scalar == "\r" {
                lines.append(current)
                current = ""
            } else {
                current.unicodeScalars.append(scalar)
            }
        }
        lines.append(current)
        return lines
    }
}
