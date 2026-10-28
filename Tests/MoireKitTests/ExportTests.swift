import Foundation
@testable import MoireKit
import Testing

private func patch(_ left: String, _ right: String, context: Int = 3) -> String {
    UnifiedDiff.patch(from: TextDocument(left), to: TextDocument(right), leftLabel: "a/file.txt", rightLabel: "b/file.txt", context: context)
}

/// Runs a tool in `directory` and returns its exit status and output.
@discardableResult
private func run(_ tool: String, _ arguments: [String], in directory: URL) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(filePath: tool)
    process.arguments = arguments
    process.currentDirectoryURL = directory
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// Writes `left` to a temporary file, applies the patch to it with `tool`, and returns the file.
private func applied(_ left: String, _ right: String, tool: String) throws -> String {
    let directory = FileManager.default.temporaryDirectory.appending(path: "moire-patch-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "file.txt")
    try Data(left.utf8).write(to: file)
    try Data(patch(left, right).utf8).write(to: directory.appending(path: "change.patch"))

    let result = tool == "git"
        ? try run("/usr/bin/git", ["apply", "change.patch"], in: directory)
        : try run("/usr/bin/patch", ["-p1", "-s", "-i", "change.patch"], in: directory)
    guard result.status == 0 else {
        Issue.record("\(tool) failed: \(result.output)")
        return ""
    }
    return String(decoding: try Data(contentsOf: file), as: UTF8.self)
}

private let pairs: [(String, String)] = [
    ("a\nb\nc\n", "a\nB\nc\n"),
    ("a\nb\nc\n", "start\na\nb\nc\n"),
    ("a\nb\nc\n", "a\nb\n"),
    ("a\nb\nc\n", "a\nb\nc\nd\n"),
    ("a\nb", "a\nb\n"),
    ("a\nb\n", "a\nB"),
    ("a\nb", "a\nB"),
    ("", "one\ntwo\n"),
    ("one\ntwo\n", ""),
    ("a\r\nb\r\nc\r\n", "a\r\nB\r\nc\r\nd\r\n"),
    ((1...40).map { "line \($0)" }.joined(separator: "\n") + "\n",
     (1...40).map { [5, 20, 21, 38].contains($0) ? "changed \($0)" : "line \($0)" }.joined(separator: "\n") + "\n"),
]

@Suite struct UnifiedDiffTests {
    @Test func `identical documents give an empty patch`() {
        #expect(patch("a\nb\n", "a\nb\n") == "")
        #expect(patch("", "") == "")
    }

    @Test func `a patch has headers and hunks with three lines of context`() {
        let left = (1...10).map(String.init).joined(separator: "\n") + "\n"
        let right = left.replacingOccurrences(of: "\n5\n", with: "\nfive\n")
        #expect(patch(left, right) == """
        --- a/file.txt
        +++ b/file.txt
        @@ -2,7 +2,7 @@
         2
         3
         4
        -5
        +five
         6
         7
         8

        """)
    }

    @Test func `changes more than six lines apart get their own hunk`() {
        let left = (1...20).map(String.init).joined(separator: "\n") + "\n"
        let near = left.replacingOccurrences(of: "\n3\n", with: "\nx\n").replacingOccurrences(of: "\n10\n", with: "\ny\n")
        let far = left.replacingOccurrences(of: "\n3\n", with: "\nx\n").replacingOccurrences(of: "\n11\n", with: "\ny\n")
        #expect(patch(left, near).components(separatedBy: "@@ -").count - 1 == 1)
        #expect(patch(left, far).components(separatedBy: "@@ -").count - 1 == 2)
        #expect(patch(left, far).contains("@@ -1,6 +1,6 @@\n"))
        #expect(patch(left, far).contains("@@ -8,7 +8,7 @@\n"))
    }

    @Test func `an empty side has a zero range`() {
        #expect(patch("", "one\ntwo\n") == "--- a/file.txt\n+++ b/file.txt\n@@ -0,0 +1,2 @@\n+one\n+two\n")
        #expect(patch("one\n", "") == "--- a/file.txt\n+++ b/file.txt\n@@ -1 +0,0 @@\n-one\n")
    }

    @Test func `a missing line break at the end is marked`() {
        #expect(patch("a\nb", "a\nb\n") == """
        --- a/file.txt
        +++ b/file.txt
        @@ -1,2 +1,2 @@
         a
        -b
        \\ No newline at end of file
        +b

        """)
    }

    @Test func `CRLF lines keep their line ending`() {
        #expect(patch("a\r\nb\r\n", "a\r\nB\r\n") == "--- a/file.txt\n+++ b/file.txt\n@@ -1,2 +1,2 @@\n a\r\n-b\r\n+B\r\n")
    }

    @Test(arguments: pairs.indices)
    func `patch turns the left file into the right one`(index: Int) throws {
        let (left, right) = pairs[index]
        #expect(try applied(left, right, tool: "patch") == right)
    }

    @Test(arguments: pairs.indices)
    func `git apply turns the left file into the right one`(index: Int) throws {
        let (left, right) = pairs[index]
        #expect(try applied(left, right, tool: "git") == right)
    }

    @Test func `random edits survive a round trip through patch`() throws {
        var generator = SplitMix(seed: 3)
        for _ in 0..<25 {
            let left = randomText(&generator)
            let right = randomText(&generator)
            guard left != right else { continue }
            #expect(try applied(left, right, tool: "patch") == right, "left: \(left.debugDescription) right: \(right.debugDescription)")
        }
    }
}

@Suite struct HTMLReportTests {
    private func page(_ left: String, _ right: String, context: Int? = nil) -> String {
        let diff = LineDiff(left: TextDocument(left), right: TextDocument(right))
        return HTMLReport.page(
            for: diff,
            left: HTMLReport.Side(title: "old <a>.txt", detail: "~/Desktop"),
            right: HTMLReport.Side(title: "new.txt"),
            context: context,
            generated: "28 October 2026"
        )
    }

    @Test func `the report is one self-contained page`() {
        let html = page("a\n", "b\n")
        #expect(html.hasPrefix("<!doctype html>"))
        #expect(html.contains("<style>"))
        #expect(!html.contains("<script"))
        #expect(!html.contains("<link"))
        #expect(!html.contains("src="))
        #expect(!html.contains("url("))
    }

    @Test func `light and dark follow the system`() {
        let html = page("a\n", "b\n")
        #expect(html.contains("color-scheme: light dark"))
        #expect(html.contains("@media (prefers-color-scheme: dark)"))
    }

    @Test func `text is escaped`() {
        let html = page("if a < b && c > d { \"x\" }\n", "if a < b && c > e { 'x' }\n")
        #expect(html.contains("old &lt;a&gt;.txt"))
        #expect(html.contains("&lt; b &amp;&amp; c &gt;"))
        #expect(!html.contains("a < b"))
        #expect(html.contains("<ins>&#39;</ins>x<ins>&#39;</ins>"))
    }

    @Test func `changed words are marked on both sides`() {
        let html = page("let total = price * count\n", "let total = price * amount\n")
        #expect(html.contains("<tr class=\"chg\">"))
        #expect(html.contains("<del>count</del>"))
        #expect(html.contains("<ins>amount</ins>"))
    }

    @Test func `lines on one side only leave the other side empty`() {
        let html = page("a\n", "a\nb\n")
        #expect(html.contains("<tr class=\"add\"><td class=\"n\"></td><td class=\"empty\"></td><td class=\"n\">2</td><td class=\"code\">b</td></tr>"))
        #expect(html.contains("<span class=\"chip add\">1 added</span>"))
    }

    @Test func `context folds long runs of unchanged lines`() {
        let left = (1...30).map(String.init).joined(separator: "\n") + "\n"
        let right = left.replacingOccurrences(of: "\n15\n", with: "\nfifteen\n")
        let folded = page(left, right, context: 3)
        #expect(folded.contains("11 unchanged lines"))
        #expect(folded.contains("12 unchanged lines"))
        #expect(folded.contains("<td class=\"n\">12</td>"))
        #expect(!folded.contains("<td class=\"n\">11</td>"))
        #expect(!page(left, right).contains("unchanged lines"))
    }

    @Test func `identical files say so`() {
        #expect(page("a\n", "a\n").contains("Identical"))
    }
}
