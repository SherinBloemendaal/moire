import Foundation
@testable import MoireKit
import Testing

/// Reads bytes the way a file is read.
private func read(_ text: String) throws -> TextDocument {
    let bytes = Array(text.utf8)
    let allocation = UnsafeMutableRawBufferPointer.allocate(byteCount: max(bytes.count, 1), alignment: 16)
    allocation.copyBytes(from: bytes)
    guard case .text(let document, _) = FileContent.decode(taking: allocation, count: bytes.count) else {
        throw CocoaError(.fileReadCorruptFile)
    }
    return document
}

private func written(_ document: TextDocument) -> String {
    String(decoding: document.utf8, as: UTF8.self)
}

struct LineEndingTests {
    @Test(arguments: [
        "one\ntwo\r\nthree\nfour\n",
        "a\r\nb\r\nc\nd\r\n",
        "stray\rcarriage\nreturn\n",
        "a\rb\rc\r",
        "a\rb\r\nc\nd\re",
        "no final break\r\nhere",
        "ends in a lone cr\r",
        "\r\n\n\r\n",
        "",
    ])
    func `writes back exactly what it read`(text: String) throws {
        #expect(written(try read(text)) == text)
    }

    @Test func `keeps a lone carriage return inside its line in a file that breaks on line feeds`() throws {
        let document = try read("a\rb\nc\n")
        #expect(Array(document.lines) == ["a\rb", "c"])
        #expect(document.lineEnding == .lf)
    }

    @Test func `still breaks a file of carriage returns on them`() throws {
        var document = try read("one\rtwo\rthree\r")
        #expect(Array(document.lines) == ["one", "two", "three"])
        #expect(document.lineEnding == .cr)
        document.lines[1] = "TWO"
        document.lines.insert("new", at: 3)
        #expect(written(document) == "one\rTWO\rthree\rnew\r")
    }

    @Test func `editing one line leaves every other byte as it was`() throws {
        let original = "first\nsecond\r\nthird\nfourth\r\nfifth"
        var document = try read(original)
        #expect(document.lineEnding == .lf)
        document.lines[2] = "THIRD"
        #expect(written(document) == "first\nsecond\r\nTHIRD\nfourth\r\nfifth")
    }

    @Test func `gives an edited or new line the document's line ending`() throws {
        var document = try read("a\nb\r\nc\n")
        document.lines[1] = "B"
        document.lines.append("d")
        #expect(written(document) == "a\nB\nc\nd\n")
    }

    @Test func `gives the old last line a break when a line is added after it`() throws {
        var document = try read("a\r\nb\r\nlast")
        document.lines.append("after")
        #expect(document.endsWithLineBreak == false)
        #expect(written(document) == "a\r\nb\r\nlast\r\nafter")
    }

    @Test func `gives lines copied from another document this document's line ending`() throws {
        let other = try read("x\r\ny\r\n")
        var document = try read("a\nb\r\nc\n")
        document.apply(LineEdit(side: .left, range: 2..<3, lines: other.lines))
        #expect(written(document) == "a\nb\r\nx\ny\n")
    }

    @Test func `undo brings back the exact bytes`() throws {
        let original = "a\nb\r\nc\rd\ne\r\n"
        let document = try read(original)
        let edit = LineEdit(side: .left, range: 1..<3, lines: ["changed"])
        let edited = document.applying(edit)
        #expect(written(edited.applying(edit.inverse(in: document))) == original)
    }

    @Test func `converts every line when the line ending is changed`() throws {
        var document = try read("a\nb\r\nc\n")
        document.lineEnding = .crlf
        #expect(written(document) == "a\r\nb\r\nc\r\n")
    }

    @Test func `counts kept line breaks when comparing documents`() throws {
        let mixed = try read("a\r\nb\n")
        let plain = try read("a\nb\n")
        #expect(Array(mixed.lines) == Array(plain.lines))
        #expect(mixed != plain)
        #expect(mixed == (try read("a\r\nb\n")))
        #expect(plain == TextDocument(lines: ["a", "b"]))
    }

    @Test func `reports the break of every line`() throws {
        let buffer = "a\nb\r\nc\rd".withCString { LineBuffer(copying: UnsafeRawBufferPointer(start: $0, count: strlen($0))) }
        #expect(buffer.lineCount == 3)
        #expect((0..<3).map(buffer.lineBreak(of:)) == [.lf, .crlf, nil])
        #expect(buffer.string(of: 2) == "c\rd")
        #expect(buffer.hasMixedBreaks)
    }

    @Test func `splits a big file of carriage returns across chunk edges`() {
        let chunk = 1 << 22
        var text = String(repeating: "x", count: chunk - 1) + "\r"
        text += String(repeating: "line\r", count: 1000) + "a\r\nb\nend"
        let document = TextDocument(text)
        #expect(document.lineEnding == .cr)
        #expect(document.lines.count == 1004)
        #expect(document.lines[1] == "line")
        #expect(document.lines[1001] == "a")
        #expect(document.lines[1003] == "end")
        #expect(document.text == text)
    }

    @Test func `keeps the mixed breaks of a merged file`() throws {
        let base = try read("one\ntwo\r\nthree\nfour\n")
        let left = try read("one\ntwo\r\nthree\nFOUR\n")
        let right = try read("ONE\ntwo\r\nthree\nfour\n")
        let merge = ThreeWayMerge(base: base, left: left, right: right)
        #expect(merge.conflicts.isEmpty)
        #expect(written(merge.result([:])) == "ONE\ntwo\r\nthree\nFOUR\n")
    }

    @Test func `gives merged lines of a side with another line ending the result's ending`() throws {
        let base = try read("a\nb\nc\n")
        let left = try read("a\nb\nc\nleft\n")
        let right = try read("A\r\nb\r\nc\r\n")
        let merge = ThreeWayMerge(base: base, left: left, right: right)
        #expect(written(merge.result([:])) == "A\nb\nc\nleft\n")
    }

    @Test func `writes typed and marker lines with the result's ending`() throws {
        let base = try read("a\r\nb\r\n")
        let left = try read("a\r\nL\r\n")
        let right = try read("a\r\nR\r\n")
        let merge = ThreeWayMerge(base: base, left: left, right: right)
        let conflict = try #require(merge.conflicts.first)
        #expect(written(merge.result([conflict: .edited(text: "typed\nhere")])) == "a\r\ntyped\r\nhere")
        #expect(written(merge.result([:])).hasPrefix("a\r\n<<<<<<< LEFT\r\nL\r\n"))
    }
}
