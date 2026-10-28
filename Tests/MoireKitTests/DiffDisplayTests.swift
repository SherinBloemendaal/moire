@testable import MoireKit
import Testing

struct DiffDisplayTests {
    private func randomDiff(using generator: inout some RandomNumberGenerator) -> LineDiff {
        let left = (0..<Int.random(in: 0...40, using: &generator)).map { _ in "\(Int.random(in: 0...3, using: &generator))" }
        var right = left
        for _ in 0..<Int.random(in: 0...4, using: &generator) where !right.isEmpty {
            right[Int.random(in: 0..<right.count, using: &generator)] = "x"
        }
        if Bool.random(using: &generator) { right.insert("new", at: Int.random(in: 0...right.count, using: &generator)) }
        return LineDiff(left: TextDocument(lines: left), right: TextDocument(lines: right))
    }

    @Test func `shows every row once side by side`() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let diff = randomDiff(using: &generator)
            let display = DiffDisplay(diff: diff, layout: .sideBySide, foldUnchanged: false)
            #expect(display.count == diff.rowCount)
            for line in 0..<display.count {
                #expect(display[line] == .row(line))
                #expect(display.line(ofRow: line) == line)
            }
        }
    }

    @Test func `shows removed lines above added lines in unified`() {
        let diff = LineDiff(left: TextDocument("a\nb\nc\nz\n"), right: TextDocument("a\nB\nz\nnew\n"))
        let display = DiffDisplay(diff: diff, layout: .unified, foldUnchanged: false)
        #expect((0..<display.count).map { display[$0] } == [.row(0), .removed(row: 1), .removed(row: 2), .added(row: 1), .row(3), .added(row: 4)])
        #expect(display.line(ofRow: 1, side: .left) == 1)
        #expect(display.line(ofRow: 1, side: .right) == 3)
        #expect(display.line(ofDocumentLine: 3, on: .right) == 5)
        #expect(display.lines(ofHunk: 0) == 1..<4)
    }

    @Test func `folds long unchanged runs and keeps three lines of context`() {
        let left = (0..<30).map { "line \($0)" }
        var right = left
        right[15] = "changed"
        let diff = LineDiff(left: TextDocument(lines: left), right: TextDocument(lines: right))
        let display = DiffDisplay(diff: diff, layout: .sideBySide, foldUnchanged: true)
        #expect(display[0] == .fold(0..<12))
        #expect(display[1] == .row(12))
        #expect(display[4] == .row(15))
        #expect(display[8] == .fold(19..<30))
        #expect(display.count == 9)
        #expect(display.line(ofRow: 5) == nil)
        #expect(display.fold(containingRow: 5) == 0..<12)
        #expect(display.line(ofRow: 16) == 5)

        let opened = DiffDisplay(diff: diff, layout: .sideBySide, foldUnchanged: true, expandedFolds: [0])
        #expect(opened.line(ofRow: 5) == 5)
        #expect(opened.count == 20)
    }

    @Test func `finds every display line of a side in unified`() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let diff = randomDiff(using: &generator)
            let display = DiffDisplay(diff: diff, layout: .unified, foldUnchanged: false)
            var seenLeft: [Int] = []
            var seenRight: [Int] = []
            for index in 0..<display.count {
                switch display[index] {
                case .row(let row):
                    let diffRow = diff.row(at: row, withSegments: false)
                    #expect(diffRow.kind == .same)
                    if let line = diffRow.left { seenLeft.append(line); #expect(display.line(ofDocumentLine: line, on: .left) == index) }
                    if let line = diffRow.right { seenRight.append(line); #expect(display.line(ofDocumentLine: line, on: .right) == index) }
                case .removed(let row):
                    let line = diff.row(at: row, withSegments: false).left
                    #expect(line != nil)
                    if let line { seenLeft.append(line); #expect(display.line(ofDocumentLine: line, on: .left) == index) }
                case .added(let row):
                    let line = diff.row(at: row, withSegments: false).right
                    #expect(line != nil)
                    if let line { seenRight.append(line); #expect(display.line(ofDocumentLine: line, on: .right) == index) }
                case .fold:
                    Issue.record("nothing is folded")
                }
            }
            #expect(seenLeft == Array(0..<diff.left.lines.count))
            #expect(seenRight == Array(0..<diff.right.lines.count))
        }
    }
}
