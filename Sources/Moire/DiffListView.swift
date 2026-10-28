import AppKit
import MoireKit
import SwiftUI

/// What the list draws besides the lines themselves. Any change redraws the visible rows; a new
/// `generation` reloads the list.
struct DiffListState: Equatable {
    var generation: Int
    var currentHunk: Int?
    var fontSize: Double
    var scrollRequest: ScrollRequest?
    var searchGeneration: Int
    var flashedLine: FlashedLine?
}

/// The comparison itself: every line of both sides, aligned, with the changes marked. An
/// AppKit table that only makes views for the visible rows, so millions of lines scroll as
/// smoothly as a hundred.
struct DiffListView: NSViewRepresentable {
    let model: CompareModel
    let display: DiffDisplay
    let state: DiffListState

    func makeCoordinator() -> DiffListController {
        DiffListController(model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(display: display, state: state)
    }

    /// Takes whatever room it gets; the table's own height is millions of points.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 400, height: proposal.height ?? 300)
    }
}

/// Sizes that follow from the font.
struct DiffMetrics {
    let font: NSFont
    let numberFont: NSFont
    let characterWidth: CGFloat
    let lineHeight: CGFloat
    let textInset: CGFloat
    let paragraph: NSParagraphStyle
    /// Room for the line numbers of the longer side.
    let numberWidth: CGFloat
    static let actionWidth: CGFloat = 16
    static let numberGap: CGFloat = 10
    static let trailingPadding: CGFloat = 14
    static let signWidth: CGFloat = 26

    init(fontSize: Double, lineCount: Int) {
        font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        numberFont = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
        characterWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
        let textHeight = ceil(font.ascender - font.descender + font.leading)
        lineHeight = textHeight + 3
        textInset = 1.5
        let style = NSMutableParagraphStyle()
        style.tabStops = []
        style.defaultTabInterval = characterWidth * 4
        style.lineBreakMode = .byClipping
        paragraph = style
        let digits = max(3, String(max(lineCount, 1)).count)
        numberWidth = ceil(CGFloat(digits) * characterWidth) + 4
    }

    /// From the left edge of a side to its text.
    var gutterWidth: CGFloat { Self.actionWidth + numberWidth + Self.numberGap }
}

final class DiffListController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let model: CompareModel
    let scrollView = NSScrollView()
    let tableView = DiffTableView()
    private(set) var display: DiffDisplay?
    private var state: DiffListState?
    private(set) var metrics = DiffMetrics(fontSize: 12.5, lineCount: 1)
    /// How far the text is scrolled to the left, shared by both sides.
    private(set) var horizontalOffset: CGFloat = 0
    private(set) var hoveredLine: Int?
    private(set) var hoveredHunk: Int?
    private var segmentCache: [Int: (left: [Segment], right: [Segment])] = [:]
    private var widestLine = 0
    private var metricsLineCount = 0
    private var isHighlighting = false

    init(model: CompareModel) {
        self.model = model
        super.init()

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("line"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.gridStyleMask = []
        tableView.usesAutomaticRowHeights = false
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.focusRingType = .none
        tableView.allowsTypeSelect = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.controller = self
        tableView.rowHeight = metrics.lineHeight

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    /// Tells the model which row is at the top, where searching starts.
    @objc private func boundsChanged() {
        guard let display, display.count > 0 else { return }
        let top = tableView.row(at: NSPoint(x: 0, y: scrollView.contentView.bounds.minY + scrollView.contentInsets.top + 1))
        guard top >= 0 else { return }
        switch display[top] {
        case .fold(let rows): model.firstVisibleRow = rows.lowerBound
        case let line: model.firstVisibleRow = line.row ?? 0
        }
    }

    func update(display: DiffDisplay, state: DiffListState) {
        let previous = self.state
        self.display = display
        self.state = state
        let lineCount = max(display.diff.left.lines.count, display.diff.right.lines.count)
        // Wider line numbers move the text, so they count as a new font.
        let metricsChanged = previous?.fontSize != state.fontSize || String(lineCount).count != String(metricsLineCount).count
        if metricsChanged {
            metricsLineCount = lineCount
            metrics = DiffMetrics(fontSize: state.fontSize, lineCount: lineCount)
            tableView.rowHeight = metrics.lineHeight
        }
        if previous?.generation != state.generation || metricsChanged {
            segmentCache = [:]
            widestLine = Self.widestLine(display.diff)
            clampHorizontalOffset()
            tableView.reloadData()
        } else if previous != state {
            redrawVisibleRows()
        }
        if let request = state.scrollRequest, previous != nil, request.id != previous?.scrollRequest?.id {
            scroll(to: request)
        }
    }


    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        display?.count ?? 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("DiffLine")
        let view = tableView.makeView(withIdentifier: identifier, owner: nil) as? DiffLineView ?? DiffLineView()
        view.identifier = identifier
        view.controller = self
        view.index = row
        view.needsDisplay = true
        return view
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func redrawVisibleRows() {
        let rows = tableView.rows(in: tableView.visibleRect)
        for row in rows.location..<(rows.location + rows.length) {
            tableView.view(atColumn: 0, row: row, makeIfNecessary: false)?.needsDisplay = true
        }
    }

    private func redraw(lines: Range<Int>) {
        let visible = tableView.rows(in: tableView.visibleRect)
        let range = lines.clamped(to: visible.location..<(visible.location + visible.length))
        for row in range {
            tableView.view(atColumn: 0, row: row, makeIfNecessary: false)?.needsDisplay = true
        }
    }

    private func scroll(to request: ScrollRequest) {
        guard let display, let line = display.line(ofRow: request.row, side: request.side) else { return }
        scroll(toLine: line)
        if let match = request.match { reveal(match) }
    }

    /// Scrolls sideways when a match lies outside the visible part of its line.
    private func reveal(_ match: SearchMatch) {
        guard let display else { return }
        let document = match.side == .left ? display.diff.left : display.diff.right
        guard match.line < document.lines.count else { return }
        let text = document.lines[match.line] as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: metrics.font, .paragraphStyle: metrics.paragraph]
        let start = NSAttributedString(string: text.substring(to: min(match.range.lowerBound, text.length)), attributes: attributes).size().width
        let end = NSAttributedString(string: text.substring(to: min(match.range.upperBound, text.length)), attributes: attributes).size().width
        let width = textAreaWidth()
        if start < horizontalOffset {
            horizontalOffset = max(0, start - metrics.characterWidth * 4)
        } else if end > horizontalOffset + width {
            horizontalOffset = end - width + metrics.characterWidth * 4
        } else {
            return
        }
        clampHorizontalOffset()
        redrawVisibleRows()
    }

    /// Puts a line about a third down the visible area.
    func scroll(toLine line: Int, animated: Bool = true) {
        let clip = scrollView.contentView
        let rect = tableView.rect(ofRow: line)
        let insets = scrollView.contentInsets
        let maxY = max(-insets.top, tableView.bounds.height - clip.bounds.height + insets.bottom)
        let y = min(max(rect.minY - clip.bounds.height * 0.3, -insets.top), maxY)
        let target = NSPoint(x: clip.bounds.origin.x, y: y)
        guard animated else {
            clip.scroll(to: target)
            scrollView.reflectScrolledClipView(clip)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.allowsImplicitAnimation = true
            clip.animator().setBoundsOrigin(target)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.scrollView.reflectScrolledClipView(clip)
            }
        }
    }

    // MARK: Syntax colors

    /// Colors the lines around the visible ones off the main thread, then redraws. Asked for by
    /// a line drawn without colors; several such lines make one request.
    func requestHighlighting() {
        guard !isHighlighting else { return }
        isHighlighting = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let jobs = SideID.allCases.compactMap { side -> (SyntaxHighlightCache, Range<Int>)? in
                guard let highlighter = self.model.highlighters[side], let lines = self.visibleDocumentLines(on: side) else { return nil }
                let prefetch = 150
                return (highlighter, max(0, lines.lowerBound - prefetch)..<(lines.upperBound + prefetch))
            }
            guard !jobs.isEmpty else {
                isHighlighting = false
                return
            }
            Task { [weak self] in
                let changed = await Task.detached(priority: .userInitiated) {
                    jobs.map { $0.0.prepare(lines: $0.1) }.contains(true)
                }.value
                guard let self else { return }
                isHighlighting = false
                if changed { redrawVisibleRows() }
            }
        }
    }

    /// The lines of one side that the visible rows show.
    private func visibleDocumentLines(on side: SideID) -> Range<Int>? {
        guard let display else { return nil }
        let rows = tableView.rows(in: tableView.visibleRect)
        var lower = Int.max
        var upper = Int.min
        for index in rows.location..<(rows.location + rows.length) where index < display.count {
            guard let row = display[index].row, let line = display.diff.row(at: row, withSegments: false).line(on: side) else { continue }
            lower = min(lower, line)
            upper = max(upper, line + 1)
        }
        return lower < upper ? lower..<upper : nil
    }

    // MARK: Horizontal scrolling

    /// The widest line in columns, counting a tab as four. Bytes stand in for characters, which
    /// can only make the estimate wider than the text.
    private static func widestLine(_ diff: LineDiff) -> Int {
        max(diff.left.lines.widestLine(tabWidth: 4), diff.right.lines.widestLine(tabWidth: 4))
    }

    func textAreaWidth() -> CGFloat {
        let width = tableView.bounds.width
        if display?.layout == .unified {
            return width - unifiedTextX - DiffMetrics.trailingPadding
        }
        return (width - 1) / 2 - metrics.gutterWidth - DiffMetrics.trailingPadding
    }

    var unifiedTextX: CGFloat { (DiffMetrics.actionWidth + metrics.numberWidth) * 2 + DiffMetrics.signWidth }

    func scrollHorizontally(by delta: CGFloat) {
        horizontalOffset -= delta
        clampHorizontalOffset()
        redrawVisibleRows()
    }

    private func clampHorizontalOffset() {
        let limit = max(0, CGFloat(widestLine) * metrics.characterWidth - textAreaWidth() + metrics.characterWidth * 4)
        horizontalOffset = min(max(0, horizontalOffset), limit)
    }

    func tableResized() {
        clampHorizontalOffset()
    }

    // MARK: Mouse

    /// What sits under a point of a row.
    enum Target {
        case mergeButton(hunk: Int, toRight: Bool)
        case fold(Range<Int>)
        case text(side: SideID, line: Int)
        case row
    }

    func mouseMoved(to point: NSPoint) {
        let row = tableView.row(at: point)
        let line = row >= 0 ? row : nil
        let hunk = line.flatMap(hunk(atLine:))
        let previousLine = hoveredLine
        let previousHunk = hoveredHunk
        hoveredLine = line
        hoveredHunk = hunk
        if previousHunk != hunk {
            for value in [previousHunk, hunk].compactMap({ $0 }) {
                if let lines = display?.lines(ofHunk: value) { redraw(lines: lines) }
            }
        }
        if previousLine != line {
            for value in [previousLine, line].compactMap({ $0 }) {
                redraw(lines: value..<(value + 1))
            }
        }
    }

    func mouseExited() {
        mouseMoved(to: NSPoint(x: -1, y: -1))
    }

    func hunk(atLine line: Int) -> Int? {
        guard let display, line >= 0, line < display.count else { return nil }
        if case .hunk(let index) = display.blocks[display.block(containing: line)].kind { return index }
        return nil
    }

    func mouseDown(at point: NSPoint, line: Int, event: NSEvent) {
        switch target(at: point, line: line) {
        case .mergeButton(let hunk, let toRight):
            model.copy(hunk: hunk, toRight: toRight)
        case .fold(let rows):
            model.expand(fold: rows)
        case .text, .row:
            if let hunk = hunk(atLine: line) { model.currentHunk = hunk }
        }
    }

    func target(at point: NSPoint, line: Int) -> Target {
        guard let display, line < display.count else { return .row }
        let item = display[line]
        if case .fold(let rows) = item { return .fold(rows) }
        if let hunk = hunk(atLine: line), showsMergeButtons(hunk: hunk), display.lines(ofHunk: hunk)?.lowerBound == line {
            let frame = mergeButtonFrame()
            if frame.contains(point) {
                return .mergeButton(hunk: hunk, toRight: point.x < frame.midX)
            }
        }
        guard let row = item.row else { return .row }
        let diffRow = display.diff.row(at: row, withSegments: false)
        switch item {
        case .removed:
            if let number = diffRow.left, point.x >= unifiedTextX { return .text(side: .left, line: number) }
        case .added:
            if let number = diffRow.right, point.x >= unifiedTextX { return .text(side: .right, line: number) }
        default:
            if display.layout == .unified {
                if let number = diffRow.left, point.x >= unifiedTextX { return .text(side: .left, line: number) }
            } else {
                let side: SideID = point.x < sideFrame(.left).maxX ? .left : .right
                if let number = diffRow.line(on: side), point.x >= sideFrame(side).minX + metrics.gutterWidth {
                    return .text(side: side, line: number)
                }
            }
        }
        return .row
    }

    func menu(forLine line: Int) -> NSMenu? {
        guard let display, let hunk = hunk(atLine: line) else { return nil }
        let menu = NSMenu()
        menu.addItem(MenuAction.item("Copy to Right", image: "arrow.right") { [model] in model.copy(hunk: hunk, toRight: true) })
        menu.addItem(MenuAction.item("Copy to Left", image: "arrow.left") { [model] in model.copy(hunk: hunk, toRight: false) })
        menu.addItem(.separator())
        let diff = display.diff
        menu.addItem(MenuAction.item("Copy Left Lines as Text") { Self.copyLines(diff.left.lines[diff.hunks[hunk].left]) })
        menu.addItem(MenuAction.item("Copy Right Lines as Text") { Self.copyLines(diff.right.lines[diff.hunks[hunk].right]) })
        return menu
    }

    private static func copyLines(_ lines: Slice<Lines>) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    // MARK: Geometry

    func sideFrame(_ side: SideID) -> NSRect {
        let width = tableView.bounds.width
        let half = floor((width - 1) / 2)
        return side == .left
            ? NSRect(x: 0, y: 0, width: half, height: metrics.lineHeight)
            : NSRect(x: half + 1, y: 0, width: width - half - 1, height: metrics.lineHeight)
    }

    func mergeButtonFrame() -> NSRect {
        let size = NSSize(width: 52, height: min(18, metrics.lineHeight - 1))
        let y = (metrics.lineHeight - size.height) / 2
        if display?.layout == .unified {
            return NSRect(x: tableView.bounds.width - size.width - 12, y: y, width: size.width, height: size.height)
        }
        return NSRect(x: sideFrame(.left).maxX + 0.5 - size.width / 2, y: y, width: size.width, height: size.height)
    }

    func showsMergeButtons(hunk: Int) -> Bool {
        hoveredHunk == hunk || state?.currentHunk == hunk
    }

    var currentHunk: Int? { state?.currentHunk }
    var flashedLine: FlashedLine? { state?.flashedLine }

    func segments(forRow row: Int, of diffRow: DiffRow) -> (left: [Segment], right: [Segment])? {
        guard diffRow.kind == .changed, let display else { return nil }
        if let cached = segmentCache[row] { return cached }
        guard let segments = display.diff.segments(forRow: diffRow) else { return nil }
        if segmentCache.count > 4096 { segmentCache.removeAll(keepingCapacity: true) }
        segmentCache[row] = segments
        return segments
    }
}

/// The table, with horizontal scrolling of the text and mouse tracking for hover effects.
final class DiffTableView: NSTableView {
    weak var controller: DiffListController?

    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY), abs(event.scrollingDeltaX) > 0 {
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : event.scrollingDeltaX * (controller?.metrics.characterWidth ?? 8) * 3
            controller?.scrollHorizontally(by: delta)
            return
        }
        super.scrollWheel(with: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        controller?.mouseMoved(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        controller?.mouseExited()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        controller?.tableResized()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        controller?.tableResized()
    }
}

/// One line of the list. It draws itself; the controller knows what to draw.
final class DiffLineView: NSView {
    weak var controller: DiffListController?
    var index = 0

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        controller?.draw(line: index, in: bounds)
    }

    override func mouseDown(with event: NSEvent) {
        controller?.mouseDown(at: convert(event.locationInWindow, from: nil), line: index, event: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        controller?.menu(forLine: index)
    }
}

/// A menu item that runs a closure.
final class MenuAction: NSObject {
    private let action: () -> Void

    private init(_ action: @escaping () -> Void) {
        self.action = action
    }

    @objc private func run() { action() }

    static func item(_ title: String, image: String? = nil, isEnabled: Bool = true, action: @escaping () -> Void) -> NSMenuItem {
        let target = MenuAction(action)
        let item = NSMenuItem(title: title, action: #selector(run), keyEquivalent: "")
        item.target = target
        item.representedObject = target
        item.isEnabled = isEnabled
        if let image { item.image = NSImage(systemSymbolName: image, accessibilityDescription: nil) }
        return item
    }
}
