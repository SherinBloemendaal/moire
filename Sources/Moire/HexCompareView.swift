import AppKit
import MoireKit
import SwiftUI

@Observable
final class HexModel: DifferenceNavigating {
    var matching = ByteDiff.Matching(rawValue: UserDefaults.standard.string(forKey: "hexMatching") ?? "") ?? .automatic {
        didSet { UserDefaults.standard.set(matching.rawValue, forKey: "hexMatching") }
    }

    private(set) var diff: ByteDiff?
    private(set) var isComparing = false
    private(set) var errorMessage: String?
    var currentHunk: Int?
    /// Goes up to ask the grid to scroll to `currentHunk`.
    private(set) var scrollRequest = 0
    /// The bytes the grid shows, read a page at a time.
    @ObservationIgnored private(set) var left: any ByteSource = DataByteSource(Data())
    @ObservationIgnored private(set) var right: any ByteSource = DataByteSource(Data())
    private(set) var sourceRevision = 0

    var differenceCount: Int { diff?.hunks.count ?? 0 }

    func goToNextDifference() { move(by: 1) }
    func goToPreviousDifference() { move(by: -1) }

    /// Makes a difference the current one, scrolling to it unless it was clicked on screen.
    func select(hunk: Int, scroll: Bool = true) {
        guard let diff, diff.hunks.indices.contains(hunk) else { return }
        currentHunk = hunk
        if scroll { scrollRequest += 1 }
    }

    private func move(by step: Int) {
        let count = differenceCount
        guard count > 0 else { return }
        select(hunk: currentHunk.map { ($0 + step + count) % count } ?? (step > 0 ? 0 : count - 1))
    }

    func load(_ leftInput: ByteInput, _ rightInput: ByteInput) async {
        do {
            left = try Self.source(leftInput, pageSize: 64 * 1024, pages: 64)
            right = try Self.source(rightInput, pageSize: 64 * 1024, pages: 64)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        sourceRevision += 1
        errorMessage = nil
        diff = nil
        currentHunk = nil
        isComparing = true
        let options = ByteDiff.Options(matching: matching)
        do {
            let result = try await runDetached {
                // Separate readers with large pages: the comparison reads straight through.
                try ByteDiff.compare(
                    try Self.source(leftInput, pageSize: 1 << 20, pages: 8),
                    try Self.source(rightInput, pageSize: 1 << 20, pages: 8),
                    options: options
                )
            }
            diff = result
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
        isComparing = false
    }

    nonisolated private static func source(_ input: ByteInput, pageSize: Int, pages: Int) throws -> any ByteSource {
        switch input {
        case .none: DataByteSource(Data())
        case .data(let data): DataByteSource(data)
        case .file(let url): try FileByteSource(url: url, pageSize: pageSize, maximumPages: pages)
        }
    }
}

struct HexCompareView: View {
    let compare: CompareModel
    @State private var model = HexModel()

    var body: some View {
        let files = compare.fileView
        KindLayout {
            ZStack {
                if let diff = model.diff {
                    HexGrid(
                        diff: diff,
                        left: model.left,
                        right: model.right,
                        sourceRevision: model.sourceRevision,
                        currentHunk: model.currentHunk,
                        scrollRequest: model.scrollRequest,
                        fontSize: compare.fontSize,
                        select: { model.select(hunk: $0, scroll: false) }
                    )
                } else if let error = model.errorMessage {
                    KindMessage(systemImage: "exclamationmark.triangle", title: "The bytes could not be read", message: error)
                } else {
                    KindMessage(systemImage: "number", title: "Comparing bytes…", isWorking: true)
                }
            }
        } bar: {
            statistics
            Spacer()
            DifferenceStepper(count: model.differenceCount, current: model.currentHunk, previous: model.goToPreviousDifference, next: model.goToNextDifference)
            Picker("Match", selection: $model.matching) {
                Text("Automatic").tag(ByteDiff.Matching.automatic)
                Text("By Offset").tag(ByteDiff.Matching.byOffset)
                Text("Find Insertions").tag(ByteDiff.Matching.findInsertions)
            }
            .fixedSize()
            .help("Automatic compares equally long files by offset and looks for inserted bytes when the sizes differ")
        }
        .task(id: Reload(revision: files.revision, matching: model.matching)) {
            await model.load(compare.left.byteInput, compare.right.byteInput)
        }
        .onAppear { files.navigator = model }
        .onDisappear { if files.navigator === model { files.navigator = nil } }
    }

    private struct Reload: Hashable {
        var revision: Int
        var matching: ByteDiff.Matching
    }

    @ViewBuilder
    private var statistics: some View {
        if let diff = model.diff {
            if diff.isIdentical {
                Chip(text: "Identical bytes", color: Theme.iris, systemImage: "checkmark")
            } else {
                Chip(text: diff.hunks.count == 1 ? "1 difference" : "\(diff.hunks.count) differences", color: Theme.changed)
                Chip(text: "\(diff.leftChangedBytes.formatted()) bytes left", color: Theme.removed)
                Chip(text: "\(diff.rightChangedBytes.formatted()) bytes right", color: Theme.added)
            }
            Text(alignmentNote(diff))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(alignmentHelp(diff))
        } else if model.isComparing {
            ProgressView().controlSize(.mini)
        }
    }

    private func alignmentNote(_ diff: ByteDiff) -> String {
        let sizes = "\(diff.leftCount.fileSizeText) and \(diff.rightCount.fileSizeText)"
        switch diff.alignment {
        case .byOffset:
            return diff.leftCount == diff.rightCount ? "Compared by offset" : "Compared by offset · \(sizes)"
        case .aligned:
            return "Inserted and removed bytes lined up · \(sizes)"
        case .alignedUntil(let left, _):
            return "Lined up until offset \(HexGridView.hex(left, digits: 8)), by offset after that"
        }
    }

    private func alignmentHelp(_ diff: ByteDiff) -> String {
        switch diff.alignment {
        case .byOffset where diff.leftCount != diff.rightCount:
            "Byte 10 is compared with byte 10. After an inserted or removed byte everything counts as changed; choose Find Insertions to line the files up."
        case .byOffset:
            "Byte 10 is compared with byte 10. Choose Find Insertions to look for inserted or removed bytes."
        case .aligned:
            "Moire looked for bytes that were inserted or removed, so the bytes after them sit on the same row again."
        case .alignedUntil:
            "Moire looked for inserted and removed bytes, but past this offset the files have too little in common to line up. From there on byte N is compared with byte N."
        }
    }
}

/// Puts the AppKit grid into SwiftUI.
private struct HexGrid: NSViewRepresentable {
    let diff: ByteDiff
    let left: any ByteSource
    let right: any ByteSource
    let sourceRevision: Int
    let currentHunk: Int?
    let scrollRequest: Int
    let fontSize: Double
    let select: (Int) -> Void

    func makeNSView(context: Context) -> HexGridView {
        HexGridView()
    }

    func updateNSView(_ view: HexGridView, context: Context) {
        view.select = select
        view.update(diff: diff, left: left, right: right, sourceRevision: sourceRevision, fontSize: fontSize)
        view.currentHunk = currentHunk
        if view.handledScrollRequest != scrollRequest {
            view.handledScrollRequest = scrollRequest
            if let currentHunk { view.reveal(hunk: currentHunk) }
        }
    }
}

/// Offset, hex and text columns for both files, lined up row by row. Only the rows on screen
/// are read and drawn, so the size of the files does not matter.
final class HexGridView: NSView {
    var select: ((Int) -> Void)?
    var currentHunk: Int? { didSet { if currentHunk != oldValue { needsDisplay = true } } }
    var handledScrollRequest = 0

    private var diff: ByteDiff?
    private var layout: HexLayout?
    private var left: any ByteSource = DataByteSource(Data())
    private var right: any ByteSource = DataByteSource(Data())
    private var sourceRevision = -1
    private var fontSize = 12.5
    private var topRow = 0.0
    private let scroller = NSScroller()

    private var font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    private var characterWidth = 7.0
    private var rowHeight = 18.0

    private static let mapWidth = 10.0
    private static let padding = 12.0
    private static let divider = 18.0

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroller.scrollerStyle = .legacy
        scroller.target = self
        scroller.action = #selector(scrolled(_:))
        addSubview(scroller)
        updateMetrics()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func update(diff: ByteDiff, left: any ByteSource, right: any ByteSource, sourceRevision: Int, fontSize: Double) {
        if sourceRevision != self.sourceRevision {
            self.sourceRevision = sourceRevision
            self.left = left
            self.right = right
            topRow = 0
            needsDisplay = true
        }
        if fontSize != self.fontSize {
            self.fontSize = fontSize
            updateMetrics()
        }
        if self.diff?.hunks != diff.hunks || self.diff?.leftCount != diff.leftCount || self.diff?.rightCount != diff.rightCount {
            self.diff = diff
            layout = nil
        }
        relayout()
    }

    func reveal(hunk: Int) {
        guard let layout else { return }
        setTop(Double(layout.firstRow(ofHunk: hunk)) - 3)
    }

    // MARK: Layout

    private var offsetDigits: Int {
        max(diff?.leftCount ?? 0, diff?.rightCount ?? 0) > 0xFFFF_FFFF ? 12 : 8
    }

    /// Characters in one side: offset, two spaces, the hex bytes with an extra space in the
    /// middle, two spaces, the text.
    private func sideCharacters(_ bytesPerRow: Int) -> Int {
        offsetDigits + 2 + bytesPerRow * 3 + 1 + 1 + bytesPerRow
    }

    private func sideWidth(_ bytesPerRow: Int) -> Double {
        Double(sideCharacters(bytesPerRow)) * characterWidth + Self.padding * 2
    }

    private var contentWidth: Double {
        bounds.width - scroller.frame.width - Self.mapWidth
    }

    private var visibleRows: Double { bounds.height / rowHeight }

    private var maximumTop: Double { max(0, Double(layout?.rowCount ?? 0) - visibleRows + 1) }

    private func updateMetrics() {
        font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        characterWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
        rowHeight = ceil(font.ascender - font.descender + font.leading) + 5
        layout = nil
        relayout()
    }

    private func relayout() {
        let width = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        scroller.frame = NSRect(x: bounds.width - width, y: 0, width: width, height: bounds.height)
        guard let diff else { return }
        let bytesPerRow = contentWidth >= sideWidth(16) * 2 + Self.divider ? 16 : 8
        if layout?.bytesPerRow != bytesPerRow {
            // Keep the same bytes on screen when the row width changes.
            let firstOffset = layout.map { $0.row(Int(topRow)).left.lowerBound }
            let new = HexLayout(diff: diff, bytesPerRow: bytesPerRow)
            layout = new
            topRow = firstOffset.map { Double(new.row(containing: $0, onLeft: true)) } ?? 0
        }
        setTop(topRow)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        relayout()
    }

    private func setTop(_ value: Double) {
        topRow = min(max(0, value), maximumTop)
        let rows = Double(layout?.rowCount ?? 0)
        scroller.isEnabled = rows > visibleRows
        scroller.knobProportion = rows > 0 ? min(1, visibleRows / rows) : 1
        scroller.doubleValue = maximumTop > 0 ? topRow / maximumTop : 0
        needsDisplay = true
    }

    // MARK: Input

    override func scrollWheel(with event: NSEvent) {
        let rows = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / rowHeight : event.scrollingDeltaY * 3
        setTop(topRow - rows)
    }

    @objc private func scrolled(_ sender: NSScroller) {
        let page = max(1, visibleRows - 2)
        switch sender.hitPart {
        case .decrementPage: setTop(topRow - page)
        case .incrementPage: setTop(topRow + page)
        case .decrementLine: setTop(topRow - 1)
        case .incrementLine: setTop(topRow + 1)
        default: setTop(sender.doubleValue * maximumTop)
        }
    }

    override func keyDown(with event: NSEvent) {
        let page = max(1, visibleRows - 2)
        switch event.specialKey {
        case .upArrow?: setTop(topRow - 1)
        case .downArrow?: setTop(topRow + 1)
        case .pageUp?: setTop(topRow - page)
        case .pageDown?: setTop(topRow + page)
        case .home?: setTop(0)
        case .end?: setTop(maximumTop)
        default:
            if event.charactersIgnoringModifiers == " " {
                setTop(topRow + (event.modifierFlags.contains(.shift) ? -page : page))
            } else {
                super.keyDown(with: event)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let layout else { return }
        let point = convert(event.locationInWindow, from: nil)
        if point.x >= contentWidth {
            // The change map: jump to that place in the file.
            setTop(Double(layout.rowCount) * point.y / max(bounds.height, 1) - visibleRows / 2)
            return
        }
        let row = Int(topRow + point.y / rowHeight)
        guard row < layout.rowCount, let hunk = layout.row(row).hunk else { return }
        select?(hunk)
    }

    // MARK: Drawing

    private static let changedRow = NSColor(name: nil) { appearance in
        NSColor(hex: 0xD97706, alpha: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.10 : 0.07)
    }
    private static let currentRow = NSColor(name: nil) { appearance in
        NSColor(hex: 0x7C5CFF, alpha: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.20 : 0.12)
    }
    private static let removedByte = NSColor(name: nil) { appearance in
        NSColor(hex: 0xF43F5E, alpha: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.40 : 0.28)
    }
    private static let addedByte = NSColor(name: nil) { appearance in
        NSColor(hex: 0x10B981, alpha: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.40 : 0.30)
    }
    private static let mapMark = NSColor(hex: 0xD97706)

    override func draw(_ dirtyRect: NSRect) {
        NSColor(Theme.pane).setFill()
        bounds.fill()
        guard let layout else { return }

        let sideWidth = sideWidth(layout.bytesPerRow)
        let rightX = sideWidth + Self.divider
        let first = Int(topRow)
        let shift = (topRow - Double(first)) * rowHeight
        let rows = Int(ceil(visibleRows)) + 1
        let textColor = NSColor(Theme.text)
        let gutterColor = NSColor(Theme.gutterText)

        for index in 0..<rows {
            let rowIndex = first + index
            guard rowIndex < layout.rowCount else { break }
            let y = Double(index) * rowHeight - shift
            let row = layout.row(rowIndex)
            let a = (try? left.bytes(in: row.left)) ?? []
            let b = (try? right.bytes(in: row.right)) ?? []

            if let hunk = row.hunk {
                (hunk == currentHunk ? Self.currentRow : Self.changedRow).setFill()
                NSRect(x: 0, y: y, width: contentWidth, height: rowHeight).fill()
            }
            let isChange = row.hunk != nil
            drawSide(bytes: a, other: b, offset: row.left.lowerBound, x: 0, y: y, bytesPerRow: layout.bytesPerRow,
                     isChange: isChange, mark: Self.removedByte, text: textColor, gutter: gutterColor)
            drawSide(bytes: b, other: a, offset: row.right.lowerBound, x: rightX, y: y, bytesPerRow: layout.bytesPerRow,
                     isChange: isChange, mark: Self.addedByte, text: textColor, gutter: gutterColor)
        }

        NSColor(Theme.paneBorder).setFill()
        NSRect(x: sideWidth + Self.divider / 2, y: 0, width: 1, height: bounds.height).fill()
        drawMap(layout)
    }

    private func drawSide(bytes: [UInt8], other: [UInt8], offset: Int, x: Double, y: Double, bytesPerRow: Int,
                          isChange: Bool, mark: NSColor, text: NSColor, gutter: NSColor) {
        guard !bytes.isEmpty else { return }
        let baseline = NSPoint(x: x + Self.padding, y: y + 2.5)
        let hexX = baseline.x + Double(offsetDigits + 2) * characterWidth
        let textX = hexX + Double(bytesPerRow * 3 + 2) * characterWidth

        if isChange {
            mark.setFill()
            for (column, byte) in bytes.enumerated() where column >= other.count || other[column] != byte {
                let middle = column >= bytesPerRow / 2 ? characterWidth : 0
                NSRect(x: hexX + Double(column * 3) * characterWidth + middle - 1, y: y + 1, width: characterWidth * 2 + 2, height: rowHeight - 2).fill()
                NSRect(x: textX + Double(column) * characterWidth, y: y + 1, width: characterWidth, height: rowHeight - 2).fill()
            }
        }

        let plain: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: text]
        (Self.hex(offset, digits: offsetDigits) as NSString).draw(at: baseline, withAttributes: [.font: font, .foregroundColor: gutter])

        var hex = ""
        var printable = ""
        hex.reserveCapacity(bytesPerRow * 3 + 1)
        for (column, byte) in bytes.enumerated() {
            if column == bytesPerRow / 2 { hex += " " }
            hex += Self.hexByte[Int(byte)]
            hex += " "
            printable.unicodeScalars.append(byte >= 0x20 && byte < 0x7F ? Unicode.Scalar(byte) : "·")
        }
        (hex as NSString).draw(at: NSPoint(x: hexX, y: baseline.y), withAttributes: plain)
        (printable as NSString).draw(at: NSPoint(x: textX, y: baseline.y), withAttributes: plain)
    }

    /// Marks in a strip at the right edge for where the differences are in the whole file.
    private func drawMap(_ layout: HexLayout) {
        guard let diff, layout.rowCount > 0 else { return }
        let strip = NSRect(x: contentWidth, y: 0, width: Self.mapWidth, height: bounds.height)
        NSColor(Theme.subtleFill).setFill()
        strip.fill()
        Self.mapMark.setFill()
        let scale = bounds.height / Double(layout.rowCount)
        var lastPixel = -1
        for index in diff.hunks.indices {
            let row = layout.firstRow(ofHunk: index)
            let pixel = Int(Double(row) * scale)
            guard pixel != lastPixel else { continue }
            lastPixel = pixel
            let length = max(diff.hunks[index].left.count, diff.hunks[index].right.count)
            let height = max(2, Double(length) / Double(layout.bytesPerRow) * scale)
            NSRect(x: strip.minX + 2, y: Double(pixel), width: Self.mapWidth - 4, height: height).fill()
        }
        NSColor(Theme.paneBorder).setFill()
        NSRect(x: strip.minX + 1, y: topRow * scale, width: Self.mapWidth - 2, height: max(4, visibleRows * scale)).frame()
    }

    private static let hexByte: [String] = (0..<256).map { String(format: "%02X", $0) }

    static func hex(_ value: Int, digits: Int) -> String {
        let text = String(value, radix: 16, uppercase: true)
        return String(repeating: "0", count: max(0, digits - text.count)) + text
    }
}
