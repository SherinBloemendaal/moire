import AppKit
import MoireKit

/// How one line of the list is drawn.
extension DiffListController {
    func draw(line index: Int, in bounds: NSRect) {
        guard let display, index >= 0, index < display.count else { return }
        let item = display[index]
        switch item {
        case .fold(let rows):
            drawFold(rows: rows, in: bounds, isHovered: hoveredLine == index)
            return
        case .row(let row):
            let diffRow = display.diff.row(at: row, withSegments: false)
            if display.layout == .sideBySide {
                drawSideBySide(diffRow, row: row, line: index, in: bounds)
            } else {
                drawUnified(diffRow, row: row, side: nil, in: bounds)
            }
        case .removed(let row):
            drawUnified(display.diff.row(at: row, withSegments: false), row: row, side: .left, in: bounds)
        case .added(let row):
            drawUnified(display.diff.row(at: row, withSegments: false), row: row, side: .right, in: bounds)
        }

        guard let hunk = hunk(atLine: index), let lines = display.lines(ofHunk: hunk) else { return }
        if hoveredLine == index {
            drawLineButtons(for: item)
        }
        if currentHunk == hunk {
            drawCurrentMark(line: index, hunkLines: lines)
        }
        if showsMergeButtons(hunk: hunk), lines.lowerBound == index {
            drawMergeButtons()
        }
    }

    private func drawSideBySide(_ row: DiffRow, row index: Int, line: Int, in bounds: NSRect) {
        let segments = segments(forRow: index, of: row)
        for side in SideID.allCases {
            var frame = sideFrame(side)
            frame.size.height = bounds.height
            guard let number = row.line(on: side) else {
                drawHatching(in: frame, line: line)
                continue
            }
            if row.kind != .same {
                (side == .left ? Palette.removedRow : Palette.addedRow).setFill()
                frame.fill()
            }
            let color = row.kind == .same ? Palette.gutterText : (side == .left ? Palette.removedNumber : Palette.addedNumber)
            drawNumber(number, rightEdge: frame.minX + DiffMetrics.actionWidth + metrics.numberWidth, color: color)
            if alignmentMarks[side] == number { drawAlignmentMark(in: frame) }
            let text = NSRect(
                x: frame.minX + metrics.gutterWidth, y: 0,
                width: frame.width - metrics.gutterWidth - DiffMetrics.trailingPadding, height: bounds.height
            )
            drawText(side: side, line: number, segments: side == .left ? segments?.left : segments?.right, in: text)
        }
        Palette.paneBorder.setFill()
        NSRect(x: sideFrame(.left).maxX, y: 0, width: 1, height: bounds.height).fill()
        if let left = row.left, let right = row.right, display?.diff.anchors.contains(LineAnchor(left: left, right: right)) == true {
            drawAnchorLink(atX: sideFrame(.left).maxX + 0.5, height: bounds.height)
        }
    }

    /// A marked line: tinted, with a bar along its left edge.
    private func drawAlignmentMark(in frame: NSRect) {
        Palette.flash.setFill()
        frame.fill()
        Palette.iris.setFill()
        NSRect(x: frame.minX, y: 0, width: 2, height: frame.height).fill()
    }

    /// A link on the divider of a row whose lines were aligned by hand.
    private func drawAnchorLink(atX x: CGFloat, height: CGFloat) {
        guard let image = DiffSymbols.image("link", size: 9, color: Palette.iris) else { return }
        let size = NSSize(width: image.size.width + 6, height: min(height - 2, image.size.height + 4))
        let frame = NSRect(x: x - size.width / 2, y: (height - size.height) / 2, width: size.width, height: size.height)
        Palette.pane.setFill()
        NSBezierPath(roundedRect: frame, xRadius: size.height / 2, yRadius: size.height / 2).fill()
        image.draw(in: NSRect(x: x - image.size.width / 2, y: (height - image.size.height) / 2, width: image.size.width, height: image.size.height))
    }

    /// `side` is nil for an unchanged row, which shows the left line with both numbers.
    private func drawUnified(_ row: DiffRow, row index: Int, side: SideID?, in bounds: NSRect) {
        if let side {
            (side == .left ? Palette.removedRow : Palette.addedRow).setFill()
            bounds.fill()
        }
        if side != .right, let left = row.left {
            drawNumber(left, rightEdge: unifiedNumberRightEdge(.left), color: Palette.gutterText)
        }
        if side != .left, let right = row.right {
            drawNumber(right, rightEdge: unifiedNumberRightEdge(.right), color: Palette.gutterText)
        }
        if let side, !isHoveredUnified(row: index, side: side) {
            let sign = NSAttributedString(string: side == .left ? "−" : "+", attributes: [
                .font: metrics.font,
                .foregroundColor: side == .left ? Palette.removed : Palette.added,
            ])
            let size = sign.size()
            sign.draw(at: NSPoint(x: unifiedTextX - DiffMetrics.signWidth + (DiffMetrics.signWidth - size.width) / 2, y: metrics.textInset))
        }
        let shown = side ?? .left
        guard let number = row.line(on: shown) else { return }
        if alignmentMarks[shown] == number {
            drawAlignmentMark(in: NSRect(x: unifiedTextX - 4, y: 0, width: bounds.width - unifiedTextX + 4, height: bounds.height))
        }
        let segments = side == nil ? nil : segments(forRow: index, of: row)
        let text = NSRect(x: unifiedTextX, y: 0, width: bounds.width - unifiedTextX - DiffMetrics.trailingPadding, height: bounds.height)
        drawText(side: shown, line: number, segments: shown == .left ? segments?.left : segments?.right, in: text)
    }

    private func isHoveredUnified(row: Int, side: SideID) -> Bool {
        guard let hoveredLine, let display, hoveredLine < display.count else { return false }
        return display[hoveredLine] == (side == .left ? .removed(row: row) : .added(row: row))
    }

    private func drawLineButtons(for item: DiffDisplay.Line) {
        for button in lineButtons(for: item) {
            guard let image = DiffSymbols.image(button.toRight ? "arrow.right" : "arrow.left", size: 9, color: Palette.iris) else { continue }
            let background = NSBezierPath(roundedRect: button.frame.insetBy(dx: 1, dy: 2), xRadius: 3, yRadius: 3)
            Palette.pane.setFill()
            background.fill()
            Palette.paneBorder.setStroke()
            background.lineWidth = 1
            background.stroke()
            image.draw(in: NSRect(
                x: button.frame.midX - image.size.width / 2, y: button.frame.midY - image.size.height / 2,
                width: image.size.width, height: image.size.height
            ))
        }
    }

    func unifiedNumberRightEdge(_ side: SideID) -> CGFloat {
        let column = DiffMetrics.actionWidth + metrics.numberWidth
        return side == .left ? column : column * 2
    }

    private func drawNumber(_ line: Int, rightEdge: CGFloat, color: NSColor) {
        let number = NSAttributedString(string: String(line + 1), attributes: [.font: metrics.numberFont, .foregroundColor: color])
        number.draw(at: NSPoint(x: rightEdge - number.size().width, y: metrics.textInset))
    }

    private func drawText(side: SideID, line: Int, segments: [Segment]?, in frame: NSRect) {
        guard let display, frame.width > 0 else { return }
        let document = side == .left ? display.diff.left : display.diff.right
        guard line < document.lines.count else { return }
        if let editor, editor.side == side, editor.line == line { return }
        let text = document.lines[line]
        // Only what can be seen is laid out: a column is at least one UTF-16 unit, and the
        // slack covers characters that take up no room of their own.
        let visibleColumns = Int((horizontalOffset + frame.width) / max(metrics.characterWidth, 1)) + 1
        let utf16 = text as NSString
        var length = min(utf16.length, visibleColumns * 2 + 64)
        if length < utf16.length, length > 0 {
            length = utf16.rangeOfComposedCharacterSequence(at: length).location
        }
        let shown = NSMutableAttributedString(string: utf16.substring(to: length), attributes: [
            .font: metrics.font,
            .foregroundColor: Palette.text,
            .paragraphStyle: metrics.paragraph,
        ])
        if let highlighter = model.highlighters[side] {
            if let tokens = highlighter.tokens(line: line) {
                for token in tokens where token.range.lowerBound < length {
                    let range = NSRange(location: token.range.lowerBound, length: min(token.range.upperBound, length) - token.range.lowerBound)
                    shown.addAttribute(.foregroundColor, value: Palette.syntax(token.kind), range: range)
                }
            } else {
                requestHighlighting()
            }
        }
        if let segments {
            let wordColor = side == .left ? Palette.removedWord : Palette.addedWord
            var location = 0
            for segment in segments {
                let count = segment.text.utf16.count
                defer { location += count }
                guard segment.isChanged, location < length else { continue }
                shown.addAttribute(.backgroundColor, value: wordColor, range: NSRange(location: location, length: min(count, length - location)))
            }
        }
        if let results = model.searchResults {
            let current = model.currentMatch.map { results.ordered[$0] }
            for match in results.matches(on: side, line: line) where match.range.lowerBound < length {
                let range = NSRange(location: match.range.lowerBound, length: min(match.range.upperBound, length) - match.range.lowerBound)
                shown.addAttribute(.backgroundColor, value: match == current ? Palette.currentMatch : Palette.searchMatch, range: range)
            }
        }
        NSGraphicsContext.saveGraphicsState()
        if let flashedLine, flashedLine.side == side, flashedLine.line == line {
            Palette.flash.setFill()
            NSRect(x: frame.minX - 4, y: 0, width: frame.width + 4, height: frame.height).fill()
        }
        frame.clip()
        shown.draw(at: NSPoint(x: frame.minX - horizontalOffset, y: metrics.textInset))
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Diagonal stripes for the empty half of a row whose line exists on one side only. The
    /// stripes run on across rows.
    private func drawHatching(in frame: NSRect, line: Int) {
        let height = frame.height
        let step: CGFloat = 7
        let top = CGFloat(line) * metrics.lineHeight
        let path = NSBezierPath()
        var x = (floor((frame.minX + top) / step) * step) - top
        while x <= frame.maxX + height {
            path.move(to: NSPoint(x: x, y: 0))
            path.line(to: NSPoint(x: x - height, y: height))
            x += step
        }
        NSGraphicsContext.saveGraphicsState()
        frame.clip()
        path.lineWidth = 1
        Palette.paneBorder.setStroke()
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawFold(rows: Range<Int>, in bounds: NSRect, isHovered: Bool) {
        let rect = bounds.insetBy(dx: 0, dy: 1)
        Palette.subtleFill.setFill()
        rect.fill()
        Palette.paneBorder.setFill()
        NSRect(x: 0, y: rect.minY, width: rect.width, height: 1).fill()
        NSRect(x: 0, y: rect.maxY - 1, width: rect.width, height: 1).fill()

        let color = isHovered ? Palette.iris : Palette.gutterText
        let label = NSAttributedString(string: "\(rows.count.formatted()) unchanged lines", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: color,
        ])
        let icon = DiffSymbols.image("chevron.up.chevron.down", size: 9, color: color)
        let labelSize = label.size()
        let iconSize = icon?.size ?? .zero
        let width = iconSize.width + 8 + labelSize.width
        let x = (bounds.width - width) / 2
        icon?.draw(in: NSRect(x: x, y: (bounds.height - iconSize.height) / 2, width: iconSize.width, height: iconSize.height))
        label.draw(at: NSPoint(x: x + iconSize.width + 8, y: (bounds.height - labelSize.height) / 2))
    }

    /// The bar along the left edge of the current change, one gradient over all its lines.
    private func drawCurrentMark(line: Int, hunkLines: Range<Int>) {
        let top = CGFloat(hunkLines.lowerBound - line) * metrics.lineHeight
        let rect = NSRect(x: 0, y: top + 1, width: 3, height: CGFloat(hunkLines.count) * metrics.lineHeight - 2)
        NSGradient(starting: Palette.iris, ending: Palette.cyan)?.draw(in: NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5), angle: 90)
    }

    private func drawMergeButtons() {
        let frame = mergeButtonFrame()
        let capsule = NSBezierPath(roundedRect: frame, xRadius: frame.height / 2, yRadius: frame.height / 2)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = Palette.shadow
        shadow.shadowBlurRadius = 4
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        Palette.pane.setFill()
        capsule.fill()
        NSGraphicsContext.restoreGraphicsState()
        Palette.paneBorder.setStroke()
        capsule.lineWidth = 1
        capsule.stroke()
        Palette.paneBorder.setFill()
        NSRect(x: frame.midX - 0.5, y: frame.midY - 6, width: 1, height: 12).fill()
        for (name, x) in [("arrow.right", frame.minX + frame.width / 4), ("arrow.left", frame.minX + frame.width * 3 / 4)] {
            guard let image = DiffSymbols.image(name, size: 10, color: Palette.iris) else { continue }
            image.draw(in: NSRect(x: x - image.size.width / 2, y: frame.midY - image.size.height / 2, width: image.size.width, height: image.size.height))
        }
    }
}

/// SF Symbols tinted for drawing, made once per name, size and color.
@MainActor
enum DiffSymbols {
    private static var cache: [String: NSImage] = [:]

    static func image(_ name: String, size: CGFloat, color: NSColor) -> NSImage? {
        let key = "\(name) \(size) \(ObjectIdentifier(color).hashValue)"
        if let image = cache[key] { return image }
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .bold).applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return nil }
        cache[key] = image
        return image
    }
}
