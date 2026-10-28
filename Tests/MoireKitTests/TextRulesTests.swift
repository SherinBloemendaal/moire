import Foundation
@testable import MoireKit
import Testing

struct TextRulesTests {
    private func apply(_ lines: [String], _ rules: TextRules, file: String = "a.swift") -> [TextRules.Line] {
        rules.apply(to: lines, language: CommentSyntax.forFile(named: file))
    }

    @Test func `leaves out line and block comments but not comment markers inside strings`() {
        let result = apply([
            "let a = 1 // the answer",
            "let url = \"http://example.com\" // link",
            "/* a block",
            "   still the block */ let b = 2",
            "let c = '/* not a comment */'",
        ], TextRules(ignoreComments: true))
        #expect(result.map(\.text) == ["let a = 1", "let url = \"http://example.com\"", "", "let b = 2", "let c = '/* not a comment */'"])
        #expect(result.map(\.ignorable) == [false, false, true, false, false])
    }

    @Test func `knows the comment syntax of common languages`() {
        let rules = TextRules(ignoreComments: true)
        #expect(apply(["x = 1  # note"], rules, file: "a.py").first?.text == "x = 1")
        #expect(apply(["SELECT 1 -- note"], rules, file: "q.sql").first?.text == "SELECT 1")
        #expect(apply(["<a/><!-- note -->"], rules, file: "a.xml").first?.text == "<a/>")
        #expect(apply(["--[[ block", "]] x = 1"], rules, file: "a.lua").map(\.text) == ["", "x = 1"])
        #expect(apply(["all: # note"], rules, file: "Makefile").first?.text == "all:")
        #expect(CommentSyntax.forFile(named: "notes.unknown") == nil)
    }

    @Test func `escaped quotes do not end a string`() {
        #expect(apply(["let s = \"a \\\" // b\" // c"], TextRules(ignoreComments: true)).first?.text == "let s = \"a \\\" // b\"")
    }

    @Test func `removes text matching a pattern`() {
        let rules = TextRules(ignorePatterns: [#"\d{4}-\d{2}-\d{2}T[\d:.]+Z"#])
        #expect(apply(["built 2026-10-27T21:00:00Z ok"], rules).first?.text == "built  ok")
        #expect(apply(["2026-10-27T21:00:00Z"], rules).first?.ignorable == true)
    }

    @Test func `marks blank lines only when asked`() {
        #expect(apply(["", "  "], TextRules()).map(\.ignorable) == [false, false])
        #expect(apply(["", "  ", "x"], TextRules(ignoreBlankLines: true)).map(\.ignorable) == [true, true, false])
    }

    @Test func `reports patterns that are not regular expressions`() {
        let rules = TextRules(ignorePatterns: ["[a-z", "ok"])
        #expect(rules.invalidPatterns.map(\.pattern) == ["[a-z"])
        // An invalid pattern is skipped, never applied half way.
        #expect(apply(["abc [a-z"], rules).first?.text == "abc [a-z")
    }
}

struct LineDiffRulesTests {
    private func diff(_ left: String, _ right: String, _ rules: TextRules, file: String = "a.swift") -> LineDiff {
        LineDiff(left: TextDocument(left), right: TextDocument(right), options: DiffOptions(rules: rules, commentSyntax: CommentSyntax.forFile(named: file)))
    }

    @Test func `a change in a comment only does not count`() {
        let result = diff("let a = 1 // old note\nlet b = 2\n", "let a = 1 // new note\nlet b = 2\n", TextRules(ignoreComments: true))
        #expect(result.statistics.isIdentical)
        #expect(result.hunks.isEmpty)
    }

    @Test func `added comment lines are shown but not counted`() {
        let result = diff("let a = 1\nlet b = 2\n", "let a = 1\n// explain b\n/* and more\n   lines */\nlet b = 2\n", TextRules(ignoreComments: true))
        #expect(result.statistics.isIdentical)
        #expect(result.hunks.count == 1)
        #expect(result.ignoredHunks == [0])
    }

    @Test func `real changes next to comments still count`() {
        let result = diff("let a = 1\n", "// note\nlet a = 2\n", TextRules(ignoreComments: true))
        #expect(!result.statistics.isIdentical)
        #expect(result.ignoredHunks.isEmpty)
    }

    @Test func `ignores text matching a pattern and blank lines`() {
        let rules = TextRules(ignorePatterns: [#"built at \S+"#], ignoreBlankLines: true)
        let result = diff("x\nbuilt at 10:00\ny\n", "x\n\nbuilt at 11:30\ny\n\n", rules, file: "log.txt")
        #expect(result.statistics.isIdentical)
    }

    @Test func `without rules every line counts as before`() {
        let result = diff("a // x\n", "a // y\n", TextRules())
        #expect(result.statistics == DiffStatistics(added: 0, removed: 0, changed: 1))
        #expect(result.ignoredHunks.isEmpty)
    }
}

struct FolderRulesTests {
    @Test func `line by line folder comparison applies the rules for each kind of file`() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "moire-rules-\(UUID().uuidString)")
        for (side, files) in [("left", ["a.swift": "let a = 1 // old\n", "b.txt": "x // old\n"]), ("right", ["a.swift": "let a = 1 // new\n", "b.txt": "x // new\n"])] {
            try FileManager.default.createDirectory(at: base.appending(path: side), withIntermediateDirectories: true)
            for (name, text) in files { try Data(text.utf8).write(to: base.appending(path: "\(side)/\(name)")) }
        }
        var settings = FolderCompareSettings(method: .lines)
        settings.textRules = ["swift": TextRules(ignoreComments: true)]
        let tree = try FolderEngine(left: base.appending(path: "left"), right: base.appending(path: "right"), settings: settings).run()
        let statuses = Dictionary(uniqueKeysWithValues: (1..<tree.count).map { (tree.path(of: $0), tree.status(of: $0)) })
        // Only Swift files have rules here, so the .txt change still counts.
        #expect(statuses == ["a.swift": .identical, "b.txt": .different])
    }

    @Test func `the cache keeps answers apart per set of rules`() {
        let a = URL(filePath: "/a"), b = URL(filePath: "/b")
        var with = FolderCompareSettings(method: .lines)
        with.textRules = ["swift": TextRules(ignoreComments: true)]
        #expect(ResultCache.file(left: a, right: b, settings: with) != ResultCache.file(left: a, right: b, settings: FolderCompareSettings(method: .lines)))
    }
}
