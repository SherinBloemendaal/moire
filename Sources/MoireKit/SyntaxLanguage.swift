/// The languages Moire colors, picked by file extension.
public enum SyntaxLanguage: String, Sendable, CaseIterable {
    case swift, javascript, json, python, php, go, rust, c, java, kotlin, html, xml, css, yaml, markdown, shell, sql

    public init?(fileExtension: String) {
        let found: SyntaxLanguage? = switch fileExtension.lowercased() {
        case "swift": .swift
        case "js", "mjs", "cjs", "jsx", "ts", "tsx", "mts", "cts": .javascript
        case "json", "jsonc", "json5", "geojson", "webmanifest": .json
        case "py", "pyw", "pyi": .python
        case "php", "phtml": .php
        case "go": .go
        case "rs": .rust
        case "c", "h", "cc", "cpp", "cxx", "c++", "hpp", "hh", "hxx", "m", "mm": .c
        case "java": .java
        case "kt", "kts": .kotlin
        case "html", "htm", "xhtml", "vue", "svelte": .html
        case "xml", "plist", "svg", "xsd", "xsl", "xslt", "xib", "storyboard", "csproj", "props": .xml
        case "css", "scss", "less": .css
        case "yml", "yaml": .yaml
        case "md", "markdown", "mdown": .markdown
        case "sh", "bash", "zsh", "ksh", "command": .shell
        case "sql": .sql
        default: nil
        }
        guard let found else { return nil }
        self = found
    }

    /// By extension, or by the name of files that have none, such as `.zshrc` or `Dockerfile`.
    public init?(fileName: String) {
        let lowered = fileName.lowercased()
        if [".bashrc", ".bash_profile", ".zshrc", ".zprofile", ".profile", ".envrc"].contains(lowered) {
            self = .shell
            return
        }
        guard let dot = fileName.lastIndex(of: "."), dot != fileName.startIndex else { return nil }
        self.init(fileExtension: String(fileName[fileName.index(after: dot)...]))
    }
}

/// What a piece of a line is, for its color.
public enum SyntaxKind: UInt8, Sendable, Hashable {
    case keyword, type, string, number, comment, tag, attribute, variable, markup
}

/// A colored piece of a line, in UTF-16 units.
public struct SyntaxToken: Sendable, Hashable {
    public var range: Range<Int>
    public var kind: SyntaxKind

    public init(range: Range<Int>, kind: SyntaxKind) {
        self.range = range
        self.kind = kind
    }
}

/// Where the lexer is at the end of a line: inside a block comment or a string that goes on,
/// inside a tag, and so on. The next line starts from here.
public struct SyntaxState: Sendable, Hashable {
    enum Mode: UInt8 {
        case normal
        case blockComment
        case string
        /// Markup: between `<name` and `>`.
        case tag
        /// Markdown: inside a fenced code block.
        case fence
    }

    var mode: Mode = .normal
    /// Which comment or string rule is open, or which fence character.
    var rule: UInt8 = 0
    /// Nesting of block comments; in markup, 1 for a string inside a tag.
    var depth: UInt16 = 0
    /// CSS: how many braces are open.
    var braces: UInt16 = 0

    public static let start = SyntaxState()
}
