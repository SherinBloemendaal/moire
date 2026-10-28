@testable import MoireKit
import Testing

/// The pieces of each line with their kind, as "kind:text".
private func lex(_ text: String, _ language: SyntaxLanguage) -> [[String]] {
    let highlighter = SyntaxHighlighter(language: language)
    var state = SyntaxState.start
    return TextDocument(text).lines.map { line in
        let utf16 = Array(line.utf16)
        return highlighter.tokens(line, state: &state).map { token in
            "\(token.kind):" + String(decoding: utf16[token.range], as: UTF16.self)
        }
    }
}

struct SyntaxHighlighterTests {
    @Test func `picks the language by extension or file name`() {
        #expect(SyntaxLanguage(fileExtension: "TSX") == .javascript)
        #expect(SyntaxLanguage(fileExtension: "mm") == .c)
        #expect(SyntaxLanguage(fileName: "notes.markdown") == .markdown)
        #expect(SyntaxLanguage(fileName: ".zshrc") == .shell)
        #expect(SyntaxLanguage(fileName: "README") == nil)
        #expect(SyntaxLanguage(fileExtension: "exe") == nil)
    }

    @Test func `colors Swift keywords, types, strings, numbers and comments`() {
        #expect(lex(#"let total: Int = count + 42 // sum"#, .swift) == [["keyword:let", "type:Int", "number:42", "comment:// sum"]])
        #expect(lex(#"@MainActor func f() { print("a \"b\"") }"#, .swift) == [["attribute:@MainActor", "keyword:func", #"string:"a \"b\"""#]])
        #expect(lex("#if DEBUG", .swift) == [["keyword:#if", "type:DEBUG"]])
    }

    @Test func `carries block comments and multi-line strings to the next lines`() {
        #expect(lex("a /* one\ntwo\nthree */ let", .swift) == [["comment:/* one"], ["comment:two"], ["comment:three */", "keyword:let"]])
        #expect(lex("/* outer /* inner */ still */ var", .swift) == [["comment:/* outer /* inner */ still */", "keyword:var"]])
        #expect(lex("x = \"\"\"\nbody\n\"\"\" + 1", .python) == [["string:\"\"\""], ["string:body"], ["string:\"\"\"", "number:1"]])
        #expect(lex("s := `raw\nmore` + \"x\"", .go) == [["string:`raw"], ["string:more`", "string:\"x\""]])
    }

    @Test func `does not carry a single-line string over`() {
        #expect(lex("let a = \"open\nlet b", .swift) == [["keyword:let", "string:\"open"], ["keyword:let"]])
    }

    @Test func `colors JSON keys apart from values`() {
        #expect(lex(#"{"name": "moire", "count": 3, "ok": true}"#, .json) == [[#"attribute:"name""#, #"string:"moire""#, #"attribute:"count""#, "number:3", #"attribute:"ok""#, "keyword:true"]])
    }

    @Test func `colors tags, attributes and comments in markup, also across lines`() {
        #expect(lex(#"<a href="x">go</a> &amp;"#, .html) == [["tag:<a", "attribute:href", #"string:"x""#, "tag:>", "tag:</a", "tag:>", "keyword:&amp;"]])
        #expect(lex("<div\n  class=\"c\">\n<!-- a\nb -->", .html) == [["tag:<div"], ["attribute:class", "string:\"c\"", "tag:>"], ["comment:<!-- a"], ["comment:b -->"]])
    }

    @Test func `colors CSS selectors, properties and values`() {
        #expect(lex("a.big { color: #fff; margin: 0 2px !important }", .css) == [["tag:a", "type:.big", "attribute:color", "number:#fff", "attribute:margin", "number:0", "number:2px", "keyword:!important"]])
    }

    @Test func `colors YAML keys, lists and comments`() {
        #expect(lex("name: moire # app\n- key: yes\nurl: http://x", .yaml) == [["attribute:name", "comment:# app"], ["keyword:-", "attribute:key", "keyword:yes"], ["attribute:url"]])
    }

    @Test func `colors Markdown headings, code and fences`() {
        #expect(lex("# Title\nSome `code` and **bold**\n```\nlet x\n```", .markdown) == [["markup:# Title"], ["string:`code`", "markup:**bold**"], ["markup:```"], ["string:let x"], ["markup:```"]])
    }

    @Test func `colors shell variables and comments only after a space`() {
        #expect(lex("echo $HOME ${PATH} a#b # note", .shell) == [["variable:$HOME", "variable:${PATH}", "comment:# note"]])
    }

    @Test func `matches SQL keywords in any case`() {
        #expect(lex("SELECT name FROM users -- all", .sql) == [["keyword:SELECT", "keyword:FROM", "comment:-- all"]])
    }

    @Test func `reports places in UTF-16 units`() {
        #expect(lex("let é = \"😀\" // x", .swift) == [["keyword:let", "string:\"😀\"", "comment:// x"]])
        let tokens = SyntaxHighlighter(language: .swift).tokens("\"😀\" 1", state: &SyntaxStateBox.state)
        #expect(tokens.map(\.range) == [0..<4, 5..<6])
    }
}

private enum SyntaxStateBox {
    nonisolated(unsafe) static var state = SyntaxState.start
}

struct SyntaxHighlightCacheTests {
    @Test func `works out lines far down from remembered states`() {
        var text = "/*\n"
        text += String(repeating: "still a comment\n", count: 1000)
        text += "*/\nlet x = 1\n"
        let document = TextDocument(text)
        let cache = SyntaxHighlightCache(language: .swift)
        cache.update(to: document)
        #expect(cache.prepare(lines: 1002..<1003))
        #expect(cache.tokens(line: 1002)?.map(\.kind) == [.keyword, .number])
        #expect(cache.tokens(line: 500) == nil)
        #expect(cache.prepare(lines: 500..<501))
        #expect(cache.tokens(line: 500)?.map(\.kind) == [.comment])
    }

    @Test func `keeps what lies above an edit and redoes what lies below`() {
        let document = TextDocument((0..<400).map { "let a\($0) = \($0)\n" }.joined())
        let cache = SyntaxHighlightCache(language: .swift)
        cache.update(to: document)
        cache.prepare(lines: 0..<400)
        var edited = document
        edited.lines[300] = "/* open"
        cache.update(to: edited)
        #expect(cache.tokens(line: 299) != nil)
        #expect(cache.tokens(line: 300) == nil)
        cache.prepare(lines: 300..<302)
        #expect(cache.tokens(line: 301)?.map(\.kind) == [.comment])
    }
}
