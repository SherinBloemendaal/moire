import Foundation

/// Differences that do not matter for a kind of file: comments, text matching a pattern, and
/// lines that are left empty by those rules.
public struct TextRules: Sendable, Hashable, Codable {
    /// Leave out comments, using the comment syntax of the file's language.
    public var ignoreComments: Bool
    /// Regular expressions; matching text is left out before lines are compared, e.g. a
    /// timestamp `\d{4}-\d{2}-\d{2}T[\d:.]+Z` or a version header.
    public var ignorePatterns: [String]
    /// Lines that are empty (after the rules above) do not count as a difference.
    public var ignoreBlankLines: Bool

    public init(ignoreComments: Bool = false, ignorePatterns: [String] = [], ignoreBlankLines: Bool = false) {
        self.ignoreComments = ignoreComments
        self.ignorePatterns = ignorePatterns
        self.ignoreBlankLines = ignoreBlankLines
    }

    public var isEmpty: Bool { !ignoreComments && ignorePatterns.isEmpty && !ignoreBlankLines }

    /// Patterns that are not valid regular expressions, with the reason, for the settings screen.
    public var invalidPatterns: [(pattern: String, reason: String)] {
        ignorePatterns.compactMap { pattern in
            do {
                _ = try NSRegularExpression(pattern: pattern)
                return nil
            } catch {
                return (pattern, error.localizedDescription)
            }
        }
    }

    /// What each line is compared as, and whether it can be skipped.
    public struct Line: Sendable, Hashable {
        public var text: String
        /// True for a line that only held what the rules leave out, or was blank, when blank
        /// lines are ignored.
        public var ignorable: Bool
    }

    /// Applies the rules to a whole document. Comments are tracked across lines, so a block
    /// comment that spans several lines is left out completely.
    public func apply(to lines: [String], language: CommentSyntax?) -> [Line] {
        let expressions = ignorePatterns.compactMap { try? NSRegularExpression(pattern: $0) }
        var insideBlock: CommentSyntax.Block?
        return lines.map { original in
            var text = original
            var hadComment = false
            if ignoreComments, let language {
                (text, insideBlock, hadComment) = language.strip(text, insideBlock: insideBlock)
            }
            for expression in expressions {
                let range = NSRange(text.startIndex..., in: text)
                let stripped = expression.stringByReplacingMatches(in: text, range: range, withTemplate: "")
                if stripped != text { hadComment = true }
                text = stripped
            }
            let isBlank = text.allSatisfy { $0 == " " || $0 == "\t" }
            let ignorable = isBlank && (hadComment || ignoreBlankLines)
            // Text the rules removed leaves spacing behind; it should not count either.
            return Line(text: hadComment ? text.trimmingSpacesAndTabs() : text, ignorable: ignorable)
        }
    }
}

/// How comments are written in a language.
public struct CommentSyntax: Sendable, Hashable {
    public struct Block: Sendable, Hashable {
        let open: String
        let close: String
    }

    let line: [String]
    let blocks: [Block]
    /// Quotes that start a string, inside which comment markers mean nothing.
    let quotes: [Character]

    static let cLike = CommentSyntax(line: ["//"], blocks: [Block(open: "/*", close: "*/")], quotes: ["\"", "'", "`"])
    static let hash = CommentSyntax(line: ["#"], blocks: [], quotes: ["\"", "'"])
    static let sql = CommentSyntax(line: ["--"], blocks: [Block(open: "/*", close: "*/")], quotes: ["'", "\""])
    static let markup = CommentSyntax(line: [], blocks: [Block(open: "<!--", close: "-->")], quotes: [])
    static let css = CommentSyntax(line: [], blocks: [Block(open: "/*", close: "*/")], quotes: ["\"", "'"])
    static let lisp = CommentSyntax(line: [";"], blocks: [], quotes: ["\""])
    static let lua = CommentSyntax(line: ["--"], blocks: [Block(open: "--[[", close: "]]")], quotes: ["\"", "'"])
    static let haskell = CommentSyntax(line: ["--"], blocks: [Block(open: "{-", close: "-}")], quotes: ["\""])
    static let ini = CommentSyntax(line: [";", "#"], blocks: [], quotes: [])
    static let php = CommentSyntax(line: ["//", "#"], blocks: [Block(open: "/*", close: "*/")], quotes: ["\"", "'"])

    /// The comment syntax for a file name, by its extension.
    public static func forFile(named name: String) -> CommentSyntax? {
        let lowered = name.lowercased()
        if ["makefile", "dockerfile", "gemfile", "rakefile", "podfile"].contains(lowered) { return .hash }
        let ext = (lowered as NSString).pathExtension
        switch ext {
        case "swift", "c", "h", "m", "mm", "cpp", "cc", "cxx", "hpp", "hh", "js", "mjs", "cjs", "jsx", "ts", "tsx",
             "java", "kt", "kts", "go", "rs", "cs", "scala", "dart", "groovy", "gradle", "proto", "jsonc", "json5", "vue", "zig":
            return .cLike
        case "php": return .php
        case "py", "rb", "sh", "bash", "zsh", "fish", "pl", "pm", "r", "yaml", "yml", "toml", "conf", "cfg", "tf", "nix", "ps1", "cmake", "mk", "gitignore", "env", "properties":
            return .hash
        case "sql": return .sql
        case "html", "htm", "xml", "xhtml", "svg", "plist", "md", "markdown":
            return .markup
        case "css", "scss", "less":
            return ext == "css" ? .css : .cLike
        case "lisp", "clj", "cljs", "el", "scm", "asm", "s":
            return .lisp
        case "lua": return .lua
        case "hs": return .haskell
        case "ini": return .ini
        default: return nil
        }
    }

    /// Removes the comments from one line. Returns the rest, the block comment still open at
    /// the end of the line (if any), and whether anything was removed.
    func strip(_ line: String, insideBlock: Block?) -> (String, Block?, Bool) {
        var result = ""
        var open = insideBlock
        var removed = open != nil
        var quote: Character?
        var index = line.startIndex

        while index < line.endIndex {
            let rest = line[index...]
            if let block = open {
                guard let end = rest.range(of: block.close) else { return (result, block, true) }
                index = end.upperBound
                open = nil
                continue
            }
            let character = line[index]
            if let current = quote {
                result.append(character)
                if character == "\\", line.index(after: index) < line.endIndex {
                    index = line.index(after: index)
                    result.append(line[index])
                } else if character == current {
                    quote = nil
                }
                index = line.index(after: index)
                continue
            }
            if quotes.contains(character) {
                quote = character
                result.append(character)
                index = line.index(after: index)
                continue
            }
            // Blocks first: Lua's "--[[" starts with its line comment marker "--".
            if let block = blocks.first(where: { rest.hasPrefix($0.open) }) {
                removed = true
                open = block
                index = line.index(index, offsetBy: block.open.count)
                continue
            }
            if self.line.contains(where: { rest.hasPrefix($0) }) {
                return (result, nil, true)
            }
            result.append(character)
            index = line.index(after: index)
        }
        return (result, open, removed)
    }
}
