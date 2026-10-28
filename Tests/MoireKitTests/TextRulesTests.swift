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
