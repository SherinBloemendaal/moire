import Foundation
@testable import MoireKit
import Testing

/// Replays an edit script and checks that it really turns `a` into `b`.
private func apply<Element: Equatable>(_ operations: [EditOperation], _ a: [Element], _ b: [Element]) -> [Element]? {
    var result: [Element] = []
    var i = 0
    var j = 0
    for operation in operations {
        switch operation {
        case .equal:
            guard i < a.count, j < b.count, a[i] == b[j] else { return nil }
            result.append(a[i])
            i += 1
            j += 1
        case .delete:
            guard i < a.count else { return nil }
            i += 1
        case .insert:
            guard j < b.count else { return nil }
            result.append(b[j])
            j += 1
        }
    }
    return i == a.count && j == b.count ? result : nil
}

/// Length of the longest common subsequence, by dynamic programming, to check that Myers is minimal.
private func lcsLength<Element: Equatable>(_ a: [Element], _ b: [Element]) -> Int {
    var previous = [Int](repeating: 0, count: b.count + 1)
    for x in a {
        var current = [Int](repeating: 0, count: b.count + 1)
        for (index, y) in b.enumerated() {
            current[index + 1] = x == y ? previous[index] + 1 : max(previous[index + 1], current[index])
        }
        previous = current
    }
    return previous[b.count]
}

struct MyersTests {
    @Test func `handles empty inputs`() {
        #expect(Myers.diff([Int](), []) == [])
        #expect(Myers.diff([], [1, 2]) == [.insert, .insert])
        #expect(Myers.diff([1, 2], []) == [.delete, .delete])
    }

    @Test func `finds the classic example from the paper`() {
        let a = Array("ABCABBA")
        let b = Array("CBABAC")
        let operations = Myers.diff(a, b)
        #expect(apply(operations, a, b) == b)
        #expect(operations.count { $0 == .equal } == 4)
    }

    @Test func `is minimal and correct on random inputs`() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            let a = (0..<Int.random(in: 0...40, using: &generator)).map { _ in Int.random(in: 0...4, using: &generator) }
            let b = (0..<Int.random(in: 0...40, using: &generator)).map { _ in Int.random(in: 0...4, using: &generator) }
            let operations = Myers.diff(a, b)
            #expect(apply(operations, a, b) == b, "a: \(a) b: \(b)")
            #expect(operations.count { $0 == .equal } == lcsLength(a, b), "a: \(a) b: \(b)")
        }
    }

    @Test func `puts deletions before insertions in every changed run`() {
        let operations = Myers.diff([1, 2, 3, 9, 5], [1, 7, 8, 3, 6, 5])
        for (index, operation) in operations.enumerated().dropFirst() where operation == .delete {
            #expect(operations[index - 1] != .insert)
        }
    }

    @Test func `copes with large inputs that share nothing`() {
        let a = Array(0..<20_000)
        let b = Array(20_000..<40_000)
        let operations = Myers.diff(a, b)
        #expect(operations.count == 40_000)
        #expect(!operations.contains(.equal))
    }

    @Test func `stays minimal around elements only one side has`() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            let a = (0..<Int.random(in: 0...30, using: &generator)).map { _ in Int.random(in: 0...9, using: &generator) }
            let b = (0..<Int.random(in: 0...30, using: &generator)).map { _ in Int.random(in: 5...14, using: &generator) }
            let operations = Myers.diff(a, b)
            #expect(apply(operations, a, b) == b, "a: \(a) b: \(b)")
            #expect(operations.count { $0 == .equal } == lcsLength(a, b), "a: \(a) b: \(b)")
        }
    }
}

struct TextDocumentTests {
    @Test(arguments: ["", "one", "one\n", "one\ntwo", "one\r\ntwo\r\n", "a\rb\r", "\n", "\n\n", "x\n\ny"])
    func `joins back to exactly the original text`(text: String) {
        #expect(TextDocument(text).text == text)
    }

    @Test func `detects the line ending`() {
        #expect(TextDocument("a\r\nb\r\n").lineEnding == .crlf)
        #expect(TextDocument("a\nb\n").lineEnding == .lf)
        #expect(TextDocument("a\rb").lineEnding == .cr)
        #expect(TextDocument("a\r\nb").lines == ["a", "b"])
    }

    @Test func `knows whether the last line ends with a break`() {
        #expect(TextDocument("a\n").endsWithLineBreak)
        #expect(!TextDocument("a").endsWithLineBreak)
        #expect(TextDocument("").lines.isEmpty)
    }
}

struct LineDiffTests {
    @Test func `reports identical text as identical`() {
        let diff = LineDiff(left: TextDocument("a\nb\n"), right: TextDocument("a\nb\n"))
        #expect(diff.statistics.isIdentical)
        #expect(diff.hunks.isEmpty)
        #expect(diff.rows.allSatisfy { $0.kind == .same })
    }

    @Test func `pairs changed lines and lists the rest as added or removed`() {
        let diff = LineDiff(
            left: TextDocument("keep\nold one\nold two\nend"),
            right: TextDocument("keep\nnew one\nend\nextra")
        )
        #expect(diff.hunks == [Hunk(left: 1..<3, right: 1..<2), Hunk(left: 4..<4, right: 3..<4)])
        #expect(diff.rows.map(\.kind) == [.same, .changed, .removed, .same, .added])
        #expect(diff.hunkRows == [1, 4])
        #expect(diff.statistics == DiffStatistics(added: 1, removed: 1, changed: 1))
    }

    @Test func `marks the changed words inside a changed line`() {
        let diff = LineDiff(left: TextDocument("let total = price * 2"), right: TextDocument("let total = cost * 3"))
        let row = diff.rows[0]
        #expect(row.kind == .changed)
        #expect(row.leftSegments == [
            Segment("let total = ", isChanged: false), Segment("price", isChanged: true),
            Segment(" * ", isChanged: false), Segment("2", isChanged: true),
        ])
        #expect(row.rightSegments?.filter(\.isChanged).map(\.text) == ["cost", "3"])
    }

    @Test func `can ignore whitespace and case`() {
        let left = TextDocument("  Hello World\nfoo\tbar")
        let right = TextDocument("hello world  \nfoo bar")
        #expect(!LineDiff(left: left, right: right).statistics.isIdentical)
        #expect(!LineDiff(left: left, right: right, options: DiffOptions(whitespace: .ignoreLeadingAndTrailing)).statistics.isIdentical)
        #expect(LineDiff(left: left, right: right, options: DiffOptions(whitespace: .ignoreAll, ignoreCase: true)).statistics.isIdentical)
    }

    @Test func `copies a hunk to either side`() {
        let diff = LineDiff(left: TextDocument("a\nb\nc\n"), right: TextDocument("a\nX\nY\nc\n"))
        #expect(diff.copying(hunk: 0, toRight: true).text == "a\nb\nc\n")
        #expect(diff.copying(hunk: 0, toRight: false).text == "a\nX\nY\nc\n")
    }

    @Test func `copying every hunk to the right makes the sides equal`() {
        var right = TextDocument("one\ntwo\nthree\nfour\nfive\n")
        let left = TextDocument("zero\none\n2\nthree\nfive\nsix\n")
        while let _ = LineDiff(left: left, right: right).hunks.first {
            right = LineDiff(left: left, right: right).copying(hunk: 0, toRight: true)
        }
        #expect(right == left)
    }
}

struct FileContentTests {
    @Test func `reads UTF-8, Latin-1 and UTF-16 and writes them back the same way`() throws {
        let samples: [(Data, String)] = [
            (Data("héllo\n".utf8), "UTF-8"),
            (Data([0xEF, 0xBB, 0xBF]) + Data("bom\n".utf8), "UTF-8 with BOM"),
            (Data([0x63, 0x61, 0x66, 0xE9]), "Latin-1"),
            (Data([0xFF, 0xFE, 0x68, 0x00, 0x69, 0x00]), "UTF-16 LE"),
        ]
        for (data, name) in samples {
            guard case .text(let document, let encoding) = FileContent.decode(data) else {
                Issue.record("\(name) was read as binary")
                continue
            }
            #expect(encoding.name == name)
            #expect(try encoding.encode(document.text) == data)
        }
    }

    @Test func `treats data with NUL bytes as binary`() {
        guard case .binary = FileContent.decode(Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01])) else {
            Issue.record("expected binary")
            return
        }
    }
}

/// The hunks of the plain generic Myers over whole lines, as a reference for `LineDiff`.
private func referenceHunks(_ left: [String], _ right: [String]) -> [Hunk] {
    var hunks: [Hunk] = []
    var l = 0
    var r = 0
    var deleted = 0
    var inserted = 0
    func flush() {
        if deleted + inserted > 0 { hunks.append(Hunk(left: (l - deleted)..<l, right: (r - inserted)..<r)) }
        deleted = 0
        inserted = 0
    }
    for operation in Myers.diff(left, right) {
        switch operation {
        case .equal:
            flush()
            l += 1
            r += 1
        case .delete:
            deleted += 1
            l += 1
        case .insert:
            inserted += 1
            r += 1
        }
    }
    flush()
    return hunks
}

struct LineDiffRowTests {
    @Test func `finds the same hunks as Myers on whole lines`() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            let left = (0..<Int.random(in: 0...30, using: &generator)).map { _ in "line \(Int.random(in: 0...6, using: &generator))" }
            let right = (0..<Int.random(in: 0...30, using: &generator)).map { _ in "line \(Int.random(in: 3...9, using: &generator))" }
            let diff = LineDiff(left: TextDocument(lines: left), right: TextDocument(lines: right))
            #expect(diff.hunks == referenceHunks(left, right), "\(left) \(right)")
        }
    }

    @Test func `works out rows from the hunks`() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let left = (0..<Int.random(in: 0...25, using: &generator)).map { _ in "\(Int.random(in: 0...5, using: &generator))" }
            let right = (0..<Int.random(in: 0...25, using: &generator)).map { _ in "\(Int.random(in: 0...5, using: &generator))" }
            let diff = LineDiff(left: TextDocument(lines: left), right: TextDocument(lines: right))
            let rows = Array(diff.rows)
            // Every line shows up exactly once, in order, on its own side.
            #expect(rows.compactMap(\.left) == Array(left.indices))
            #expect(rows.compactMap(\.right) == Array(right.indices))
            for (index, row) in rows.enumerated() {
                if let line = row.left { #expect(diff.row(ofLine: line, on: .left) == index) }
                if let line = row.right { #expect(diff.row(ofLine: line, on: .right) == index) }
                #expect(diff.hunk(containingRow: index) == row.hunk)
                if row.kind == .same, let l = row.left, let r = row.right { #expect(left[l] == right[r]) }
            }
            for (index, start) in diff.hunkRows.enumerated() {
                #expect(rows[start].hunk == index)
            }
        }
    }

    @Test func `copies a single changed, removed or added line`() {
        let diff = LineDiff(left: TextDocument("a\nold 1\nold 2\nold 3\nz\n"), right: TextDocument("a\nnew 1\nz\nonly right\n"))
        #expect(diff.rows.map(\.kind) == [.same, .changed, .removed, .removed, .same, .added])
        // A changed line replaces its partner.
        #expect(diff.copying(row: 1, toRight: true).text == "a\nold 1\nz\nonly right\n")
        #expect(diff.copying(row: 1, toRight: false).text == "a\nnew 1\nold 2\nold 3\nz\n")
        // A removed line is inserted after the other side's lines of the hunk, or removed.
        #expect(diff.copying(row: 3, toRight: true).text == "a\nnew 1\nold 3\nz\nonly right\n")
        #expect(diff.copying(row: 2, toRight: false).text == "a\nold 1\nold 3\nz\n")
        // An added line is removed, or inserted on the left.
        #expect(diff.copying(row: 5, toRight: true).text == "a\nnew 1\nz\n")
        #expect(diff.copying(row: 5, toRight: false).text == "a\nold 1\nold 2\nold 3\nz\nonly right\n")
        #expect(diff.edit(copyingRow: 0, toRight: true) == nil)
    }

    @Test func `copying the lines of a hunk one by one ends where copying the hunk does`() {
        let left = TextDocument("keep\nl1\nl2\nl3\nl4\nend\n")
        var right = TextDocument("keep\nr1\nr2\nend\n")
        let whole = LineDiff(left: left, right: right).copying(hunk: 0, toRight: true)
        var steps = 0
        while let first = LineDiff(left: left, right: right).hunkRows.first, steps < 10 {
            right = LineDiff(left: left, right: right).copying(row: first, toRight: true)
            steps += 1
        }
        #expect(right == whole)
        #expect(steps == 4)
    }
}

struct LineAnchorTests {
    @Test func `aligns the anchored lines on one row`() {
        let left = TextDocument("a\nb\nc\nd\n")
        let right = TextDocument("x\nc\ny\nb\n")
        let plain = LineDiff(left: left, right: right)
        let anchored = LineDiff(left: left, right: right, anchors: [LineAnchor(left: 1, right: 3)])
        #expect(plain.row(ofLine: 1, on: .left) != plain.row(ofLine: 3, on: .right))
        #expect(anchored.row(ofLine: 1, on: .left) == anchored.row(ofLine: 3, on: .right))
        #expect(anchored.rows[anchored.row(ofLine: 1, on: .left)].kind == .same)
        #expect(Array(anchored.rows).compactMap(\.left) == [0, 1, 2, 3])
        #expect(Array(anchored.rows).compactMap(\.right) == [0, 1, 2, 3])
    }

    @Test func `pairs anchored lines that differ as a change of their own`() {
        let diff = LineDiff(left: TextDocument("a\nb\nc\n"), right: TextDocument("x\ny\nc\n"), anchors: [LineAnchor(left: 0, right: 1)])
        let row = diff.rows[diff.row(ofLine: 0, on: .left)]
        #expect(row.kind == .changed)
        #expect(row.right == 1)
        #expect(diff.hunks.contains(Hunk(left: 0..<1, right: 1..<2)))
        #expect(Array(diff.rows).compactMap(\.right) == [0, 1, 2])
    }

    @Test func `keeps anchors in range, sorted and uncrossed`() {
        let anchors = [LineAnchor(left: 5, right: 1), LineAnchor(left: 2, right: 3), LineAnchor(left: 9, right: 0), LineAnchor(left: 4, right: 4), LineAnchor(left: 50, right: 5)]
        #expect(LineAnchor.normalized(anchors, leftCount: 10, rightCount: 10) == [LineAnchor(left: 2, right: 3), LineAnchor(left: 4, right: 4)])
    }

    @Test func `a new anchor replaces the ones it crosses or shares a line with`() {
        let anchors = [LineAnchor(left: 1, right: 1), LineAnchor(left: 5, right: 5), LineAnchor(left: 8, right: 9)]
        #expect(LineAnchor.adding(LineAnchor(left: 6, right: 2), to: anchors) == [LineAnchor(left: 1, right: 1), LineAnchor(left: 6, right: 2), LineAnchor(left: 8, right: 9)])
        #expect(LineAnchor.adding(LineAnchor(left: 8, right: 3), to: anchors) == [LineAnchor(left: 1, right: 1), LineAnchor(left: 8, right: 3)])
    }

    @Test func `moves with edits and goes away when its line does`() {
        let anchor = LineAnchor(left: 4, right: 6)
        #expect(anchor.adjusted(for: LineEdit(side: .left, range: 0..<0, lines: ["new"])) == LineAnchor(left: 5, right: 6))
        #expect(anchor.adjusted(for: LineEdit(side: .right, range: 6..<7, lines: ["typed"])) == anchor)
        #expect(anchor.adjusted(for: LineEdit(side: .right, range: 5..<7, lines: [])) == nil)
        #expect(anchor.adjusted(for: LineEdit(side: .left, range: 9..<12, lines: [])) == anchor)
    }
}
