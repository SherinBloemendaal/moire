import Foundation
@testable import MoireKit
import Testing

/// A plain splitter to check the fast one against: the most common break wins, and a lone `\r`
/// only ends a line when it is that break.
private func referenceSplit(_ text: String) -> (lines: [String], ending: TextDocument.LineEnding, endsWithLineBreak: Bool) {
    let scalars = Array(text.unicodeScalars)
    var counts: [TextDocument.LineEnding: Int] = [:]
    for (index, scalar) in scalars.enumerated() {
        if scalar == "\n" {
            counts[index > 0 && scalars[index - 1] == "\r" ? .crlf : .lf, default: 0] += 1
        } else if scalar == "\r", index + 1 == scalars.count || scalars[index + 1] != "\n" {
            counts[.cr, default: 0] += 1
        }
    }
    let ending = [TextDocument.LineEnding.lf, .crlf, .cr].max { counts[$0, default: 0] < counts[$1, default: 0] } ?? .lf
    let resolved = counts.values.contains { $0 > 0 } ? ending : .lf

    var lines: [String] = []
    var current = String.UnicodeScalarView()
    var index = 0
    var endsWithBreak = false
    while index < scalars.count {
        let scalar = scalars[index]
        endsWithBreak = false
        if scalar == "\r", index + 1 < scalars.count, scalars[index + 1] == "\n" {
            lines.append(String(current))
            current = String.UnicodeScalarView()
            index += 2
            endsWithBreak = true
            continue
        }
        if scalar == "\n" || (scalar == "\r" && resolved == .cr) {
            lines.append(String(current))
            current = String.UnicodeScalarView()
            endsWithBreak = true
        } else {
            current.append(scalar)
        }
        index += 1
    }
    if !endsWithBreak, !scalars.isEmpty { lines.append(String(current)) }
    return (lines, resolved, endsWithBreak)
}

private func randomText(length: Int, using generator: inout some RandomNumberGenerator) -> String {
    let alphabet: [String] = ["a", "b", " ", "\t", "\n", "\r", "\r\n", "é", "ü", "😀"]
    return (0..<length).map { _ in alphabet.randomElement(using: &generator) ?? "a" }.joined()
}

struct LinesTests {
    @Test func `splits like a plain splitter and writes every byte back`() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            let text = randomText(length: Int.random(in: 0...40, using: &generator), using: &generator)
            let document = TextDocument(text)
            let reference = referenceSplit(text)
            #expect(Array(document.lines) == reference.lines, "\(text.debugDescription)")
            #expect(document.lineEnding == reference.ending, "\(text.debugDescription)")
            #expect(document.endsWithLineBreak == reference.endsWithLineBreak, "\(text.debugDescription)")
            // Every break is written back as it was read.
            #expect(document.text == text, "\(text.debugDescription)")
        }
    }

    @Test func `splits a text bigger than one chunk with breaks on the chunk edges`() {
        // Chunks are 4 MB; put a "\r\n" right across the first edge.
        let chunk = 1 << 22
        var text = String(repeating: "x", count: chunk - 1) + "\r\n"
        text += String(repeating: "line\r\n", count: 1000) + "end"
        let document = TextDocument(text)
        #expect(document.lines.count == 1002)
        #expect(document.lineEnding == .crlf)
        #expect(document.lines[0].count == chunk - 1)
        #expect(document.lines[1] == "line")
        #expect(document.lines[1001] == "end")
        #expect(document.text == text)
    }

    @Test func `splits a text of a million lines`() {
        let count = 1_000_000
        let text = (0..<count).map { "line \($0)\n" }.joined()
        let document = TextDocument(text)
        #expect(document.lines.count == count)
        #expect(document.endsWithLineBreak)
        for index in [0, 1, 4095, 314_159, 500_000, count - 2, count - 1] {
            #expect(document.lines[index] == "line \(index)")
        }
        #expect(document.text == text)
    }

    @Test func `replaces lines without touching the rest`() {
        var lines = TextDocument("a\nb\nc\nd\n").lines
        lines[1] = "B"
        #expect(lines == ["a", "B", "c", "d"])
        lines.replaceSubrange(2..<4, with: ["x", "y", "z"])
        #expect(lines == ["a", "B", "x", "y", "z"])
        lines.removeSubrange(0..<2)
        #expect(lines == ["x", "y", "z"])
        lines.insert("w", at: 0)
        lines.append("end")
        #expect(Array(lines) == ["w", "x", "y", "z", "end"])
    }

    @Test func `copies lines between documents as pieces`() {
        let source = TextDocument("one\ntwo\nthree\n")
        var target = TextDocument("a\nb\n")
        target.lines.replaceSubrange(1..<1, with: source.lines[0..<2])
        #expect(target.lines == ["a", "one", "two", "b"])
        #expect(target.text == "a\none\ntwo\nb\n")
    }

    @Test func `matches an array on random edits`() {
        var generator = SystemRandomNumberGenerator()
        var lines = TextDocument((0..<50).map { "line \($0)\n" }.joined()).lines
        var reference = (0..<50).map { "line \($0)" }
        for step in 0..<400 {
            let lower = Int.random(in: 0...reference.count, using: &generator)
            let upper = Int.random(in: lower...min(reference.count, lower + 4), using: &generator)
            let new = (0..<Int.random(in: 0...3, using: &generator)).map { "new \(step).\($0)" }
            lines.replaceSubrange(lower..<upper, with: new)
            reference.replaceSubrange(lower..<upper, with: new)
            #expect(Array(lines) == reference)
            #expect(lines.count == reference.count)
        }
        #expect(lines.indices.map { lines[$0] } == reference)
    }

    @Test func `finds the first line that differs`() {
        let base = TextDocument("a\nb\nc\nd\n").lines
        var edited = base
        #expect(base.firstDifference(from: edited) == nil)
        edited[2] = "C"
        #expect(base.firstDifference(from: edited) == 2)
        edited[2] = "c"
        #expect(base.firstDifference(from: edited) == nil)
        edited.append("e")
        #expect(base.firstDifference(from: edited) == 4)
        #expect(TextDocument("a\nb\n").lines.firstDifference(from: TextDocument("a\nb\n").lines) == nil)
    }

    @Test func `compares and hashes by content`() {
        let a = TextDocument("x\ny\n")
        let b = TextDocument(lines: ["x", "y"])
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
        #expect(TextDocument(lines: ["ab", "c"]).lines != TextDocument(lines: ["a", "bc"]).lines)
    }
}

struct LineEditTests {
    @Test func `undoes itself`() {
        let document = TextDocument("a\nb\nc\n")
        let edit = LineEdit(side: .left, range: 1..<2, lines: ["x", "y"])
        let edited = document.applying(edit)
        #expect(edited.text == "a\nx\ny\nc\n")
        #expect(edited.applying(edit.inverse(in: document)) == document)
    }

    @Test func `maps lines through an edit`() {
        let insert = LineEdit(side: .left, range: 2..<2, lines: ["new"])
        #expect(insert.map(line: 1) == 1)
        #expect(insert.map(line: 2) == 3)
        let replace = LineEdit(side: .left, range: 2..<3, lines: ["changed"])
        #expect(replace.map(line: 2) == 2)
        let delete = LineEdit(side: .left, range: 2..<4, lines: [])
        #expect(delete.map(line: 3) == nil)
        #expect(delete.map(line: 5) == 3)
    }
}

struct UTF8ValidationTests {
    @Test func `agrees with Foundation on random bytes`() {
        var generator = SystemRandomNumberGenerator()
        let interesting: [UInt8] = [0x41, 0x7F, 0x80, 0xBF, 0xC0, 0xC2, 0xDF, 0xE0, 0xA0, 0xED, 0x9F, 0xA0, 0xEF, 0xF0, 0x90, 0xF4, 0x8F, 0x90, 0xF5, 0xFF]
        for _ in 0..<5000 {
            let bytes = (0..<Int.random(in: 0...12, using: &generator)).map { _ in
                Bool.random(using: &generator) ? interesting.randomElement(using: &generator) ?? 0 : UInt8.random(in: 0...255, using: &generator)
            }
            let expected = String(data: Data(bytes), encoding: .utf8) != nil
            #expect(bytes.withUnsafeBufferPointer(UTF8Validation.isValid) == expected, "\(bytes)")
        }
    }

    @Test func `accepts long ASCII and valid characters`() {
        let text = String(repeating: "plain ascii text ", count: 100) + "héllo 😀 ∑"
        #expect(Array(text.utf8).withUnsafeBufferPointer(UTF8Validation.isValid))
    }
}

struct LineInternerTests {
    @Test func `gives equal lines the same number and different lines different numbers`() {
        var generator = SystemRandomNumberGenerator()
        let words = ["a", "A", " a", "a ", "\ta", "b", "É", "é", "a b", "ab", ""]
        for options in [DiffOptions(), DiffOptions(whitespace: .ignoreLeadingAndTrailing), DiffOptions(whitespace: .ignoreAll, ignoreCase: true), DiffOptions(ignoreCase: true)] {
            let left = (0..<60).map { _ in words.randomElement(using: &generator) ?? "" }
            let right = (0..<60).map { _ in words.randomElement(using: &generator) ?? "" }
            let (leftIDs, rightIDs) = LineInterner.ids(Lines(left), Lines(right), options: options)
            let all = left + right
            let ids = leftIDs + rightIDs
            func key(_ line: String) -> String {
                var key = line
                switch options.whitespace {
                case .exact: break
                case .ignoreLeadingAndTrailing: key = key.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
                case .ignoreAll: key.unicodeScalars.removeAll { $0 == " " || $0 == "\t" }
                }
                return options.ignoreCase ? key.lowercased() : key
            }
            for i in all.indices {
                for j in all.indices {
                    #expect((ids[i] == ids[j]) == (key(all[i]) == key(all[j])), "\(all[i].debugDescription) \(all[j].debugDescription)")
                }
            }
        }
    }

    @Test func `numbers many lines on several cores`() {
        let left = TextDocument((0..<200_000).map { "line \($0 % 5000)\n" }.joined())
        let right = TextDocument((0..<200_000).map { "line \(($0 + 7) % 5000)\n" }.joined())
        let (leftIDs, rightIDs) = LineInterner.ids(left.lines, right.lines, options: DiffOptions())
        #expect(leftIDs[5000] == leftIDs[0])
        #expect(leftIDs[1] != leftIDs[0])
        #expect(rightIDs[0] == leftIDs[7])
        #expect(Set(leftIDs).count == 5000)
    }
}

struct FileContentReadTests {
    @Test func `reads a file from disk`() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "moire-read-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("first\r\nsecond\r\n".utf8).write(to: url)
        let content = try FileContent.read(url)
        guard case .text(let document, let encoding) = content.body else {
            Issue.record("expected text")
            return
        }
        #expect(document.lines == ["first", "second"])
        #expect(document.lineEnding == .crlf)
        #expect(encoding == .utf8)
        #expect(try encoding.encode(document) == Data("first\r\nsecond\r\n".utf8))
    }

    @Test func `reports a missing file`() {
        #expect(throws: (any Error).self) {
            try FileContent.read(URL(filePath: "/nonexistent/moire/\(UUID().uuidString)"))
        }
    }
}
