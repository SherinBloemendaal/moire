/// Writes a comparison as a unified diff, the patch format of `diff -u`, `patch` and `git apply`.
///
/// Lines are compared exactly, whatever the ignore options of the view are, because a patch has
/// to turn the left file into the right one byte for byte. Each line keeps its own file's line
/// ending, and a missing break on the last line gets the usual `\ No newline at end of file`.
public enum UnifiedDiff {
    /// An empty string when both documents are the same.
    public static func patch(from left: TextDocument, to right: TextDocument, leftLabel: String, rightLabel: String, context: Int = 3) -> String {
        let oldLines = left.textLines
        let newLines = right.textLines
        var interner = LineInterner()
        let operations = Myers.diff(interner.ids(for: oldLines), interner.ids(for: newLines))

        struct Step {
            var operation: EditOperation
            /// Positions in the left and right document before this step.
            var old: Int
            var new: Int
        }
        var steps: [Step] = []
        steps.reserveCapacity(operations.count)
        var i = 0, j = 0
        for operation in operations {
            steps.append(Step(operation: operation, old: i, new: j))
            switch operation {
            case .equal: i += 1; j += 1
            case .delete: i += 1
            case .insert: j += 1
            }
        }

        // Changes closer together than twice the context share one hunk, like `diff -u` does.
        var groups: [ClosedRange<Int>] = []
        for index in steps.indices where steps[index].operation != .equal {
            if let last = groups.last, index - last.upperBound - 1 <= 2 * context {
                groups[groups.count - 1] = last.lowerBound...index
            } else {
                groups.append(index...index)
            }
        }
        guard !groups.isEmpty else { return "" }

        var output = "--- \(leftLabel)\n+++ \(rightLabel)\n"
        for group in groups {
            let low = max(0, group.lowerBound - context)
            let high = min(steps.count - 1, group.upperBound + context)
            let hunk = steps[low...high]
            let oldCount = hunk.count { $0.operation != .insert }
            let newCount = hunk.count { $0.operation != .delete }
            output += "@@ -\(range(start: steps[low].old, count: oldCount)) +\(range(start: steps[low].new, count: newCount)) @@\n"
            for step in hunk {
                switch step.operation {
                case .equal: output += line(" ", oldLines[step.old], ending: left.lineEnding)
                case .delete: output += line("-", oldLines[step.old], ending: left.lineEnding)
                case .insert: output += line("+", newLines[step.new], ending: right.lineEnding)
                }
            }
        }
        return output
    }

    /// `start,count` with a 1-based start. An empty range names the line before it, and a
    /// count of one is left out, as GNU diff writes it.
    private static func range(start: Int, count: Int) -> String {
        switch count {
        case 0: "\(start),0"
        case 1: "\(start + 1)"
        default: "\(start + 1),\(count)"
        }
    }

    private static func line(_ prefix: String, _ line: TextLine, ending: TextDocument.LineEnding) -> String {
        guard line.hasLineBreak else {
            return prefix + line.text + "\n\\ No newline at end of file\n"
        }
        // A CR line ending would end the patch line too early for `patch`, so those lines end in LF.
        return prefix + line.text + (ending == .crlf ? "\r\n" : "\n")
    }
}
