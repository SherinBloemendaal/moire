import MoireKit
import SwiftUI

/// A thin strip next to the scroll bar that shows where every change sits in the whole file.
/// Click a mark to jump to it. Drawn in one pass, so a file with many thousands of changes
/// costs no more than a few views.
struct ChangeMap: View {
    let model: CompareModel
    let diff: LineDiff
    @State private var hovered: Int?

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            Canvas { context, size in
                let track = Path(roundedRect: CGRect(x: (size.width - 6) / 2, y: 0, width: 6, height: size.height), cornerRadius: 3)
                context.fill(track, with: .color(Theme.subtleFill))
                for index in diff.hunks.indices {
                    let isCurrent = model.currentHunk == index
                    let frame = markFrame(index, height: size.height, width: size.width, isCurrent: isCurrent)
                    let path = Path(roundedRect: frame, cornerRadius: 2)
                    if isCurrent {
                        context.fill(path, with: .linearGradient(Gradient(colors: [Theme.iris, Theme.cyan]), startPoint: frame.origin, endPoint: CGPoint(x: frame.maxX, y: frame.maxY)))
                    } else {
                        context.fill(path, with: .color(diff.ignoredHunks.contains(index) ? Theme.gutterText.opacity(0.5) : color(for: diff.hunks[index])))
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                if let index = hunk(at: location.y, height: height) { model.select(hunk: index) }
            }
            .onContinuousHover { phase in
                if case .active(let location) = phase { hovered = hunk(at: location.y, height: height) } else { hovered = nil }
            }
            .help(hovered.map { "Change \($0 + 1) of \(diff.hunks.count)" } ?? "")
        }
        .frame(width: 18)
        .padding(.vertical, 8)
    }

    private func markFrame(_ index: Int, height: Double, width: Double, isCurrent: Bool) -> CGRect {
        let total = Double(max(diff.rowCount, 1))
        let length = Double(diff.rowCount(ofHunk: index))
        let markHeight = max(3, height * length / total)
        let y = min(height * Double(diff.hunkRows[index]) / total, height - markHeight)
        let markWidth: Double = isCurrent ? 10 : 6
        return CGRect(x: (width - markWidth) / 2, y: y, width: markWidth, height: markHeight)
    }

    /// The change under a point of the strip, or the nearest one within a few points.
    private func hunk(at y: Double, height: Double) -> Int? {
        guard !diff.hunks.isEmpty, height > 0 else { return nil }
        let row = Int(y / height * Double(diff.rowCount))
        var low = 0
        var high = diff.hunkRows.count
        while low < high {
            let middle = (low + high) / 2
            if diff.hunkRows[middle] <= row { low = middle + 1 } else { high = middle }
        }
        let candidates = [low - 1, low].filter { diff.hunks.indices.contains($0) }
        let nearest = candidates.min { distance($0, to: y, height: height) < distance($1, to: y, height: height) }
        guard let nearest, distance(nearest, to: y, height: height) <= 4 else { return nil }
        return nearest
    }

    private func distance(_ index: Int, to y: Double, height: Double) -> Double {
        let frame = markFrame(index, height: height, width: 18, isCurrent: false)
        if y < frame.minY { return frame.minY - y }
        if y > frame.maxY { return y - frame.maxY }
        return 0
    }

    private func color(for hunk: Hunk) -> Color {
        if hunk.left.isEmpty { return Theme.added }
        if hunk.right.isEmpty { return Theme.removed }
        return Theme.changed
    }
}
