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
