import MoireKit
import SwiftUI

/// A thin strip next to the scroll bar that shows where every change sits in the whole file.
/// Click a mark to jump to it.
struct ChangeMap: View {
    let model: CompareModel
    let diff: LineDiff

    var body: some View {
        GeometryReader { geometry in
            let total = max(diff.rows.count, 1)
            let height = geometry.size.height
            ZStack(alignment: .top) {
                Capsule().fill(Theme.subtleFill).frame(width: 6)
                ForEach(diff.hunks.indices, id: \.self) { index in
                    let start = diff.hunkRows[index]
                    let length = max(diff.hunks[index].left.count, diff.hunks[index].right.count)
                    let y = height * Double(start) / Double(total)
                    let markHeight = max(3, height * Double(length) / Double(total))
                    mark(for: diff.hunks[index], isCurrent: model.currentHunk == index)
                        .frame(width: model.currentHunk == index ? 10 : 6, height: markHeight)
                        .offset(y: min(y, height - markHeight))
                        .onTapGesture { model.select(hunk: index) }
                        .help("Change \(index + 1) of \(diff.hunks.count)")
                }
            }
            .frame(maxWidth: .infinity)
            .animation(.spring(duration: 0.25), value: model.currentHunk)
        }
        .frame(width: 18)
        .padding(.vertical, 8)
    }

    private func mark(for hunk: Hunk, isCurrent: Bool) -> some View {
        let fill: AnyShapeStyle = if isCurrent {
            AnyShapeStyle(Theme.brand)
        } else if hunk.left.isEmpty {
            AnyShapeStyle(Theme.added)
        } else if hunk.right.isEmpty {
            AnyShapeStyle(Theme.removed)
        } else {
            AnyShapeStyle(Theme.changed)
        }
        return RoundedRectangle(cornerRadius: 2).fill(fill)
    }
}
