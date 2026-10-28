/// A small lexer per language: keywords, types, strings, numbers and comments, including block
/// comments and strings that run over several lines. It reads UTF-8 bytes and never builds a
/// string for a line, so it can run through millions of lines to find where a comment ends.
public struct SyntaxHighlighter: Sendable {
    public let language: SyntaxLanguage
    private let rules: Rules

    public init(language: SyntaxLanguage) {
        self.language = language
        rules = Rules.for(language)
    }

    /// The tokens of one line in UTF-16 units, and the state for the next line.
    public func tokens(_ line: String, state: inout SyntaxState) -> [SyntaxToken] {
        var line = line
        return line.withUTF8 { tokens($0, state: &state) }
    }

    public func tokens(_ line: UnsafeBufferPointer<UInt8>, state: inout SyntaxState) -> [SyntaxToken] {
        var tokens: [SyntaxToken] = []
        lex(line, state: &state, wantTokens: true) { range, kind in
            tokens.append(SyntaxToken(range: range, kind: kind))
        }
        guard line.contains(where: { $0 >= 0x80 }) else { return tokens }
        // Byte offsets become UTF-16 offsets: a character counts one unit, or two above U+FFFF.
        var units = [Int](repeating: 0, count: line.count + 1)
        for index in 0..<line.count {
            let byte = line[index]
            units[index + 1] = units[index] + (byte & 0xC0 != 0x80 ? 1 : 0) + (byte >= 0xF0 ? 1 : 0)
        }
        return tokens.map { SyntaxToken(range: units[$0.range.lowerBound]..<units[$0.range.upperBound], kind: $0.kind) }
    }

    /// Only moves the state past a line, which is all the lines above the visible ones need.
    public func advance(_ line: UnsafeBufferPointer<UInt8>, state: inout SyntaxState) {
        lex(line, state: &state, wantTokens: false) { _, _ in }
    }

    private func lex(_ line: UnsafeBufferPointer<UInt8>, state: inout SyntaxState, wantTokens: Bool, emit: (Range<Int>, SyntaxKind) -> Void) {
        state = withoutActuallyEscaping(emit) { emit in
            var lexer = Lexer(line: line, rules: rules, state: state, wantTokens: wantTokens, emit: emit)
            switch language {
            case .html, .xml: lexer.markup()
            case .css: lexer.css()
            case .yaml: lexer.yaml()
            case .markdown: lexer.markdown()
            default: lexer.code()
            }
            return lexer.state
        }
    }
}

struct StringRule {
    var open: [UInt8]
    var close: [UInt8]
    var escapes = true
    var multiline = false
}

struct Rules {
    var lineComments: [[UInt8]] = []
    /// `#` only starts a comment at the start of a line or after a space (shell, YAML).
    var commentNeedsSpace = false
    var blockComments: [(open: [UInt8], close: [UInt8])] = []
    var nestedComments = false
    /// Longer openings first, so `"""` wins over `"`.
    var strings: [StringRule] = []
    var keywords: Set<String> = []
    var types: Set<String> = []
    var keywordsIgnoreCase = false
    var capitalizedTypes = false
    /// `$name` (PHP, shell).
    var variables = false
    /// `@name`, as an attribute (Swift, Python, Java) or a keyword (Objective-C).
    var atKind: SyntaxKind?
    /// `#name` as a keyword (Swift's `#if`, C's `#include` at the start of a line).
    var hashKeywords = false
    var hashKeywordsOnlyFirst = false
    /// A string followed by `:` is a key (JSON).
    var stringKeys = false
    var dollarInIdentifiers = false

    private static func words(_ list: String) -> Set<String> {
        Set(list.split(separator: " ").map(String.init))
    }

    private static func string(_ quote: String, multiline: Bool = false, escapes: Bool = true) -> StringRule {
        StringRule(open: Array(quote.utf8), close: Array(quote.utf8), escapes: escapes, multiline: multiline)
    }

    private static let cComments: [(open: [UInt8], close: [UInt8])] = [(Array("/*".utf8), Array("*/".utf8))]
    private static let slashes = [Array("//".utf8)]

    static func `for`(_ language: SyntaxLanguage) -> Rules {
        var rules = Rules()
        switch language {
        case .swift:
            rules.lineComments = slashes
            rules.blockComments = cComments
            rules.nestedComments = true
            rules.strings = [string("\"\"\"", multiline: true), string("\"")]
            rules.keywords = words("actor any as associatedtype async await borrowing break case catch class consuming continue convenience default defer deinit didSet do dynamic else enum extension fallthrough false fileprivate final for func get guard if import in indirect init inout internal is lazy let macro mutating nil nonisolated nonmutating open operator optional override package precedencegroup private protocol public repeat required rethrows return self Self sending set some static struct subscript super switch throw throws true try typealias unowned var weak where while willSet")
            rules.capitalizedTypes = true
            rules.atKind = .attribute
            rules.hashKeywords = true
        case .javascript:
            rules.lineComments = slashes
            rules.blockComments = cComments
            rules.strings = [string("`", multiline: true), string("\""), string("'")]
            rules.keywords = words("abstract as async await break case catch class const constructor continue debugger declare default delete do else enum export extends false finally for from function get if implements import in infer instanceof interface is keyof let module namespace never new null of override private protected public readonly return satisfies set static super switch this throw true try type typeof undefined var void while with yield")
            rules.types = words("any boolean number object string symbol unknown bigint")
            rules.capitalizedTypes = true
            rules.atKind = .attribute
            rules.dollarInIdentifiers = true
        case .json:
            rules.lineComments = slashes
            rules.blockComments = cComments
            rules.strings = [string("\"")]
            rules.keywords = words("true false null")
            rules.stringKeys = true
        case .python:
            rules.lineComments = [Array("#".utf8)]
            rules.strings = [string("\"\"\"", multiline: true), string("'''", multiline: true), string("\""), string("'")]
            rules.keywords = words("and as assert async await break case class continue def del elif else except False finally for from global if import in is lambda match None nonlocal not or pass raise return self cls True try type while with yield")
            rules.types = words("int str float bool list dict set tuple bytes bytearray object complex frozenset")
            rules.capitalizedTypes = true
            rules.atKind = .attribute
        case .php:
            rules.lineComments = [Array("//".utf8), Array("#".utf8)]
            rules.blockComments = cComments
            rules.strings = [string("\"", multiline: true), string("'", multiline: true)]
            rules.keywords = words("abstract and array as break callable case catch class clone const continue declare default do echo else elseif empty enddeclare endfor endforeach endif endswitch endwhile enum extends false final finally fn for foreach function global goto if implements include include_once instanceof insteadof interface isset list match namespace new null or parent print private protected public readonly require require_once return self static switch throw trait true try unset use var while xor yield")
            rules.types = words("int float bool string void mixed never iterable object")
            rules.keywordsIgnoreCase = true
            rules.capitalizedTypes = true
            rules.variables = true
        case .go:
            rules.lineComments = slashes
            rules.blockComments = cComments
            rules.strings = [StringRule(open: Array("`".utf8), close: Array("`".utf8), escapes: false, multiline: true), string("\""), string("'")]
            rules.keywords = words("break case chan const continue default defer else fallthrough false for func go goto if import interface iota map nil package range return select struct switch true type var")
            rules.types = words("any bool byte comparable complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8 uint16 uint32 uint64 uintptr")
            rules.capitalizedTypes = true
        case .rust:
            rules.lineComments = slashes
            rules.blockComments = cComments
            rules.nestedComments = true
            rules.strings = [string("\"", multiline: true)]
            rules.keywords = words("as async await break const continue crate dyn else enum extern false fn for if impl in let loop macro_rules match mod move mut pub ref return self Self static struct super trait true type union unsafe use where while yield")
            rules.types = words("bool char str u8 u16 u32 u64 u128 usize i8 i16 i32 i64 i128 isize f32 f64")
            rules.capitalizedTypes = true
        case .c:
            rules.lineComments = slashes
            rules.blockComments = cComments
            rules.strings = [string("\""), string("'")]
            rules.keywords = words("alignas alignof auto break case catch char class const const_cast constexpr continue decltype default delete do double dynamic_cast else enum explicit extern false final float for friend goto if inline int long mutable namespace new noexcept nullptr NULL operator override private protected public register reinterpret_cast restrict return short signed sizeof static static_cast struct switch template this throw true try typedef typename union unsigned using virtual void volatile while self super nil YES NO id instancetype")
            rules.types = words("bool BOOL size_t int8_t int16_t int32_t int64_t uint8_t uint16_t uint32_t uint64_t")
            rules.capitalizedTypes = true
            rules.atKind = .keyword
            rules.hashKeywords = true
            rules.hashKeywordsOnlyFirst = true
        case .java:
            rules.lineComments = slashes
            rules.blockComments = cComments
            rules.strings = [string("\"\"\"", multiline: true), string("\""), string("'")]
            rules.keywords = words("abstract assert break case catch class const continue default do else enum extends false final finally for goto if implements import instanceof interface native new null package permits private protected public record return sealed static strictfp super switch synchronized this throw throws transient true try var void volatile while yield")
            rules.types = words("boolean byte char double float int long short")
            rules.capitalizedTypes = true
            rules.atKind = .attribute
        case .kotlin:
            rules.lineComments = slashes
            rules.blockComments = cComments
            rules.nestedComments = true
            rules.strings = [StringRule(open: Array("\"\"\"".utf8), close: Array("\"\"\"".utf8), escapes: false, multiline: true), string("\""), string("'")]
            rules.keywords = words("abstract actual annotation as break by catch class companion const constructor continue crossinline data do else enum expect external false final finally for fun get if import in infix init inline inner interface internal is lateinit noinline null object open operator out override package private protected public reified return sealed set super suspend tailrec this throw true try typealias val value var vararg when where while")
            rules.capitalizedTypes = true
            rules.atKind = .attribute
            rules.variables = false
        case .shell:
            rules.lineComments = [Array("#".utf8)]
            rules.commentNeedsSpace = true
            rules.strings = [StringRule(open: Array("'".utf8), close: Array("'".utf8), escapes: false, multiline: true), string("\"", multiline: true)]
            rules.keywords = words("alias break case continue declare do done elif else esac eval exec exit export false fi for function if in local readonly return select set shift source then time trap true unset until while")
            rules.variables = true
        case .sql:
            rules.lineComments = [Array("--".utf8)]
            rules.blockComments = cComments
            rules.strings = [StringRule(open: Array("'".utf8), close: Array("'".utf8), escapes: false, multiline: true)]
            rules.keywords = words("add all alter and as asc begin between by cascade case check column commit constraint create cross database default delete desc distinct drop else end exists false foreign from full function grant group having if in index inner insert into is join key left like limit not null offset on or order outer primary procedure references replace returning revoke right rollback schema select set table then transaction trigger true truncate union unique update using values view when where with")
            rules.types = words("bigint binary bit blob boolean char date datetime decimal double float int integer json jsonb numeric real serial smallint text time timestamp tinyint uuid varchar")
            rules.keywordsIgnoreCase = true
        case .html, .xml:
            rules.blockComments = [(Array("<!--".utf8), Array("-->".utf8))]
            rules.strings = [string("\"", escapes: false), string("'", escapes: false)]
        case .css:
            rules.blockComments = cComments
            rules.strings = [string("\""), string("'")]
        case .yaml:
            rules.lineComments = [Array("#".utf8)]
            rules.commentNeedsSpace = true
            rules.strings = [string("\""), StringRule(open: Array("'".utf8), close: Array("'".utf8), escapes: false)]
            rules.keywords = words("true false null yes no on off True False Null Yes No On Off TRUE FALSE NULL YES NO ON OFF ~")
        case .markdown:
            break
        }
        return rules
    }
}

private extension UInt8 {
    static let space: UInt8 = 0x20
    static let tab: UInt8 = 0x09
    var isSpace: Bool { self == .space || self == .tab }
    var isDigit: Bool { self >= 0x30 && self <= 0x39 }
    var isUpper: Bool { self >= 0x41 && self <= 0x5A }
    var isLetter: Bool { (self | 0x20) >= 0x61 && (self | 0x20) <= 0x7A }
    var isIdentifierStart: Bool { isLetter || self == 0x5F || self >= 0x80 }
    var isIdentifier: Bool { isIdentifierStart || isDigit }
    var isHex: Bool { isDigit || ((self | 0x20) >= 0x61 && (self | 0x20) <= 0x66) }
}

/// One pass over one line.
private struct Lexer {
    let line: UnsafeBufferPointer<UInt8>
    let rules: Rules
    var state: SyntaxState
    let wantTokens: Bool
    let emit: (Range<Int>, SyntaxKind) -> Void
    var index = 0

    init(line: UnsafeBufferPointer<UInt8>, rules: Rules, state: SyntaxState, wantTokens: Bool, emit: @escaping (Range<Int>, SyntaxKind) -> Void) {
        self.line = line
        self.rules = rules
        self.state = state
        self.wantTokens = wantTokens
        self.emit = emit
    }

    var count: Int { line.count }

    func matches(_ pattern: [UInt8], at position: Int) -> Bool {
        guard position + pattern.count <= count else { return false }
        for offset in pattern.indices where line[position + offset] != pattern[offset] {
            return false
        }
        return true
    }

    func identifierEnd(from start: Int, extra: UInt8? = nil) -> Int {
        var end = start
        while end < count, line[end].isIdentifier || (extra != nil && line[end] == extra) { end += 1 }
        return end
    }

    func word(_ range: Range<Int>) -> String {
        String(decoding: UnsafeBufferPointer(rebasing: line[range]), as: UTF8.self)
    }

    func next(after position: Int) -> UInt8? {
        var position = position
        while position < count, line[position].isSpace { position += 1 }
        return position < count ? line[position] : nil
    }

    // MARK: Shared pieces

    /// Continues a block comment or string left open by the line above. False when it goes on
    /// past this line too.
    mutating func resume() -> Bool {
        switch state.mode {
        case .blockComment:
            let end = closeComment(from: 0)
            emit(0..<(end ?? count), .comment)
            guard let end else { return false }
            index = end
        case .string:
            let rule = rules.strings[Int(state.rule)]
            let end = closeString(rule, from: 0)
            emit(0..<(end ?? count), .string)
            guard let end else { return false }
            index = end
            state.mode = state.depth == 1 ? .tag : .normal
            state.depth = 0
        default:
            break
        }
        return true
    }

    /// Where the open block comment ends on this line, counting nested ones.
    mutating func closeComment(from start: Int) -> Int? {
        let rule = rules.blockComments[Int(state.rule)]
        var position = start
        while position < count {
            if rules.nestedComments, matches(rule.open, at: position) {
                state.depth += 1
                position += rule.open.count
            } else if matches(rule.close, at: position) {
                state.depth -= 1
                position += rule.close.count
                if state.depth == 0 {
                    state.mode = .normal
                    return position
                }
            } else {
                position += 1
            }
        }
        return nil
    }

    func closeString(_ rule: StringRule, from start: Int) -> Int? {
        var position = start
        while position < count {
            if rule.escapes, line[position] == 0x5C {
                position += 2
                continue
            }
            if matches(rule.close, at: position) { return position + rule.close.count }
            position += 1
        }
        return nil
    }

    /// A comment, block comment or string starting here. True when it ran to the end of the line.
    mutating func commentOrString(inTag: Bool = false) -> (handled: Bool, ended: Bool) {
        let byte = line[index]
        for comment in rules.lineComments where matches(comment, at: index) {
            if rules.commentNeedsSpace, index > 0, !line[index - 1].isSpace { continue }
            emit(index..<count, .comment)
            index = count
            return (true, true)
        }
        if let rule = rules.blockComments.firstIndex(where: { matches($0.open, at: index) }) {
            let start = index
            state = SyntaxState(mode: .blockComment, rule: UInt8(rule), depth: 1, braces: state.braces)
            let end = closeComment(from: index + rules.blockComments[rule].open.count)
            emit(start..<(end ?? count), .comment)
            index = end ?? count
            return (true, end == nil)
        }
        guard byte == 0x22 || byte == 0x27 || byte == 0x60 else { return (false, false) }
        guard let rule = rules.strings.firstIndex(where: { matches($0.open, at: index) }) else { return (false, false) }
        let start = index
        let stringRule = rules.strings[rule]
        if let end = closeString(stringRule, from: index + stringRule.open.count) {
            let isKey = rules.stringKeys && next(after: end) == 0x3A
            emit(start..<end, isKey ? .attribute : .string)
            index = end
            return (true, false)
        }
        emit(start..<count, .string)
        index = count
        if stringRule.multiline || inTag {
            state = SyntaxState(mode: .string, rule: UInt8(rule), depth: inTag ? 1 : 0, braces: state.braces)
        }
        return (true, true)
    }

    /// Digits, with letters for hex, exponents and suffixes, and a dot before more digits.
    mutating func number() -> Bool {
        let byte = line[index]
        let startsWithDot = byte == 0x2E && index + 1 < count && line[index + 1].isDigit
        guard byte.isDigit || startsWithDot else { return false }
        var end = index + 1
        while end < count, line[end].isIdentifier || (line[end] == 0x2E && end + 1 < count && line[end + 1].isDigit) { end += 1 }
        emit(index..<end, .number)
        index = end
        return true
    }

    // MARK: Code

    mutating func code() {
        guard resume() else { return }
        while index < count {
            let byte = line[index]
            if byte.isSpace {
                index += 1
                continue
            }
            let (handled, ended) = commentOrString()
            if ended { return }
            if handled { continue }
            if number() { continue }

            if rules.variables, byte == 0x24, index + 1 < count {
                let next = line[index + 1]
                if next == 0x7B, let close = line[(index + 2)...].firstIndex(of: 0x7D) {
                    emit(index..<(close + 1), .variable)
                    index = close + 1
                    continue
                }
                if next.isIdentifierStart || next.isDigit || next == 0x40 || next == 0x23 || next == 0x3F {
                    let end = next.isIdentifierStart ? identifierEnd(from: index + 1) : index + 2
                    emit(index..<end, .variable)
                    index = end
                    continue
                }
            }
            if let kind = rules.atKind, byte == 0x40, index + 1 < count, line[index + 1].isIdentifierStart {
                let end = identifierEnd(from: index + 1)
                emit(index..<end, kind)
                index = end
                continue
            }
            if rules.hashKeywords, byte == 0x23, !rules.hashKeywordsOnlyFirst || line[0..<index].allSatisfy(\.isSpace) {
                var start = index + 1
                while start < count, line[start].isSpace { start += 1 }
                if start < count, line[start].isIdentifierStart {
                    let end = identifierEnd(from: start)
                    emit(index..<end, .keyword)
                    index = end
                    continue
                }
            }
            if byte.isIdentifierStart || (rules.dollarInIdentifiers && byte == 0x24) {
                let end = identifierEnd(from: index + 1, extra: rules.dollarInIdentifiers ? 0x24 : nil)
                if wantTokens {
                    var name = word(index..<end)
                    if rules.keywordsIgnoreCase { name = name.lowercased() }
                    if rules.keywords.contains(name) {
                        emit(index..<end, .keyword)
                    } else if rules.types.contains(name) || (rules.capitalizedTypes && byte.isUpper) {
                        emit(index..<end, .type)
                    }
                }
                index = end
                continue
            }
            index += 1
        }
    }

    // MARK: Markup

    mutating func markup() {
        guard resume() else { return }
        while index < count {
            if state.mode == .tag {
                insideTag()
                continue
            }
            let byte = line[index]
            if byte == 0x3C {
                let (handled, ended) = commentOrString()
                if ended { return }
                if handled { continue }
                var end = index + 1
                if end < count, line[end] == 0x2F || line[end] == 0x21 || line[end] == 0x3F { end += 1 }
                if end < count, line[end].isIdentifierStart {
                    end = nameEnd(from: end)
                    emit(index..<end, .tag)
                    index = end
                    state.mode = .tag
                    continue
                }
            } else if byte == 0x26, let semicolon = line[index...].prefix(12).firstIndex(of: 0x3B), semicolon > index + 1 {
                emit(index..<(semicolon + 1), .keyword)
                index = semicolon + 1
                continue
            }
            index += 1
        }
    }

    func nameEnd(from start: Int) -> Int {
        var end = start
        while end < count, line[end].isIdentifier || line[end] == 0x2D || line[end] == 0x3A || line[end] == 0x2E { end += 1 }
        return end
    }

    mutating func insideTag() {
        let byte = line[index]
        if byte.isSpace {
            index += 1
        } else if byte == 0x3E || ((byte == 0x2F || byte == 0x3F) && index + 1 < count && line[index + 1] == 0x3E) {
            let end = byte == 0x3E ? index + 1 : index + 2
            emit(index..<end, .tag)
            index = end
            state.mode = .normal
        } else if byte == 0x22 || byte == 0x27 {
            _ = commentOrString(inTag: true)
        } else if byte.isIdentifierStart {
            let end = nameEnd(from: index)
            emit(index..<end, .attribute)
            index = end
        } else {
            index += 1
        }
    }

    // MARK: CSS

    mutating func css() {
        guard resume() else { return }
        while index < count {
            let byte = line[index]
            if byte.isSpace {
                index += 1
                continue
            }
            let (handled, ended) = commentOrString()
            if ended { return }
            if handled { continue }
            let inBlock = state.braces > 0
            switch byte {
            case 0x7B:
                state.braces += 1
                index += 1
                continue
            case 0x7D:
                state.braces = state.braces > 0 ? state.braces - 1 : 0
                index += 1
                continue
            case 0x40 where index + 1 < count && line[index + 1].isIdentifierStart:
                let end = nameEnd(from: index + 1)
                emit(index..<end, .keyword)
                index = end
                continue
            case 0x21 where matches(Array("!important".utf8), at: index):
                emit(index..<(index + 10), .keyword)
                index += 10
                continue
            case 0x23 where inBlock:
                var end = index + 1
                while end < count, line[end].isHex { end += 1 }
                emit(index..<end, .number)
                index = end
                continue
            case 0x23 where !inBlock && index + 1 < count && line[index + 1].isIdentifierStart,
                 0x2E where !inBlock && index + 1 < count && line[index + 1].isIdentifierStart:
                let end = nameEnd(from: index + 1)
                emit(index..<end, .type)
                index = end
                continue
            default:
                break
            }
            if inBlock, number() { continue }
            if byte.isIdentifierStart || byte == 0x2D {
                var end = index + 1
                while end < count, line[end].isIdentifier || line[end] == 0x2D { end += 1 }
                if inBlock {
                    if next(after: end) == 0x3A { emit(index..<end, .attribute) }
                } else {
                    emit(index..<end, .tag)
                }
                index = end
                continue
            }
            index += 1
        }
    }

    // MARK: YAML

    mutating func yaml() {
        guard resume() else { return }
        if matches(Array("---".utf8), at: 0) || matches(Array("...".utf8), at: 0) {
            emit(0..<3, .keyword)
            index = 3
        }
        // Indentation and list markers, then maybe a key.
        while index < count, line[index].isSpace || (line[index] == 0x2D && (index + 1 == count || line[index + 1].isSpace)) {
            if line[index] == 0x2D { emit(index..<(index + 1), .keyword) }
            index += 1
        }
        if let colon = keyEnd(from: index) {
            emit(index..<colon, .attribute)
            index = colon + 1
        }
        while index < count {
            let byte = line[index]
            if byte.isSpace {
                index += 1
                continue
            }
            let (handled, ended) = commentOrString()
            if ended { return }
            if handled { continue }
            if (byte == 0x26 || byte == 0x2A) && index + 1 < count && line[index + 1].isIdentifier {
                let end = identifierEnd(from: index + 1, extra: 0x2D)
                emit(index..<end, .variable)
                index = end
                continue
            }
            if byte == 0x21 {
                var end = index + 1
                while end < count, !line[end].isSpace { end += 1 }
                emit(index..<end, .type)
                index = end
                continue
            }
            if number() { continue }
            if byte.isIdentifierStart || byte == 0x7E {
                var end = index + 1
                while end < count, !line[end].isSpace, line[end] != 0x2C, line[end] != 0x5D, line[end] != 0x7D { end += 1 }
                if wantTokens, rules.keywords.contains(word(index..<end)) { emit(index..<end, .keyword) }
                index = end
                continue
            }
            index += 1
        }
    }

    /// The colon after a key at this position: `name:` followed by a space or the line end.
    func keyEnd(from start: Int) -> Int? {
        guard start < count, line[start] != 0x23 else { return nil }
        var position = start
        var quote: UInt8?
        while position < count {
            let byte = line[position]
            if let open = quote {
                if byte == open { quote = nil }
            } else if byte == 0x22 || byte == 0x27, position == start {
                quote = byte
            } else if byte == 0x3A, position + 1 == count || line[position + 1].isSpace {
                return position > start ? position : nil
            } else if byte == 0x23, position > start, line[position - 1].isSpace {
                return nil
            }
            position += 1
        }
        return nil
    }

    // MARK: Markdown

    mutating func markdown() {
        var start = 0
        while start < count, start < 4, line[start] == .space { start += 1 }
        let fence: UInt8? = start + 3 <= count && (matches(Array("```".utf8), at: start) || matches(Array("~~~".utf8), at: start)) ? line[start] : nil
        if state.mode == .fence {
            if let fence, fence == state.rule {
                emit(0..<count, .markup)
                state = .start
            } else {
                emit(0..<count, .string)
            }
            return
        }
        if let fence {
            emit(0..<count, .markup)
            state = SyntaxState(mode: .fence, rule: fence)
            return
        }
        guard start < count else { return }
        if line[start] == 0x23 {
            var hashes = start
            while hashes < count, line[hashes] == 0x23 { hashes += 1 }
            if hashes - start <= 6, hashes == count || line[hashes].isSpace {
                emit(0..<count, .markup)
                return
            }
        }
        if line[start] == 0x3E {
            emit(0..<count, .comment)
            return
        }
        index = start
        if line[index] == 0x2D || line[index] == 0x2A || line[index] == 0x2B, index + 1 < count, line[index + 1].isSpace {
            emit(index..<(index + 1), .keyword)
            index += 1
        } else {
            var digits = index
            while digits < count, line[digits].isDigit { digits += 1 }
            if digits > index, digits + 1 < count, line[digits] == 0x2E || line[digits] == 0x29, line[digits + 1].isSpace {
                emit(index..<(digits + 1), .keyword)
                index = digits + 1
            }
        }
        while index < count {
            let byte = line[index]
            switch byte {
            case 0x60:
                if let close = line[(index + 1)...].firstIndex(of: 0x60) {
                    emit(index..<(close + 1), .string)
                    index = close + 1
                    continue
                }
            case 0x2A, 0x5F:
                let double = index + 1 < count && line[index + 1] == byte
                let marker = double ? [byte, byte] : [byte]
                let from = index + marker.count
                if from < count, !line[from].isSpace, let close = find(marker, from: from + 1), !line[close - 1].isSpace {
                    emit(index..<(close + marker.count), .markup)
                    index = close + marker.count
                    continue
                }
            case 0x5B:
                if let close = line[index...].firstIndex(of: 0x5D) {
                    emit(index..<(close + 1), .tag)
                    index = close + 1
                    if index < count, line[index] == 0x28, let end = line[index...].firstIndex(of: 0x29) {
                        emit(index..<(end + 1), .string)
                        index = end + 1
                    }
                    continue
                }
            case 0x3C:
                if index + 1 < count, line[index + 1].isLetter || line[index + 1] == 0x2F, let close = line[index...].firstIndex(of: 0x3E) {
                    emit(index..<(close + 1), .tag)
                    index = close + 1
                    continue
                }
            default:
                break
            }
            index += 1
        }
    }

    func find(_ pattern: [UInt8], from start: Int) -> Int? {
        var position = start
        while position + pattern.count <= count {
            if matches(pattern, at: position) { return position }
            position += 1
        }
        return nil
    }
}
