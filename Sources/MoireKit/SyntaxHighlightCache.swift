import Synchronization

/// The colors of one document, worked out only for the lines that are about to be shown. The
/// lexer state is remembered every `stride` lines, so a line far down is reached from the
/// nearest remembered line instead of from the top. When the document changes, only what lies
/// below the first changed line is thrown away.
public final class SyntaxHighlightCache: Sendable {
    public let highlighter: SyntaxHighlighter
    static let stride = 128
    /// Lines whose tokens are kept; past this the ones furthest from the last request go.
    static let tokenLimit = 20_000

    private struct Storage {
        var document = TextDocument("")
        var generation = 0
        /// `checkpoints[k]` is the state at the start of line `k * stride`.
        var checkpoints: [SyntaxState] = [.start]
        var tokens: [Int: [SyntaxToken]] = [:]
    }

    private let storage = Mutex(Storage())

    public init(language: SyntaxLanguage) {
        highlighter = SyntaxHighlighter(language: language)
    }

    /// Moves to a new version of the document. Cheap when the versions share most lines.
    public func update(to document: TextDocument) {
        storage.withLock { storage in
            guard let first = storage.document.lines.firstDifference(from: document.lines) else {
                storage.document = document
                return
            }
            storage.document = document
            storage.generation += 1
            // The state at line k * stride only depends on the lines above it.
            storage.checkpoints.removeSubrange(min(storage.checkpoints.count, first / Self.stride + 1)...)
            storage.tokens = storage.tokens.filter { $0.key < first }
        }
    }

    /// The tokens of a line if they are known.
    public func tokens(line: Int) -> [SyntaxToken]? {
        storage.withLock { $0.tokens[line] }
    }

    /// Works out the tokens of `lines`. Slow for a line far below what is known, so call it
    /// off the main thread. Returns false when nothing was kept: the lines are not in the
    /// document, or it changed in the meantime.
    @discardableResult
    public func prepare(lines requested: Range<Int>) -> Bool {
        let (document, generation, checkpoints) = storage.withLock { ($0.document, $0.generation, $0.checkpoints) }
        let lines = requested.clamped(to: 0..<document.lines.count)
        guard !lines.isEmpty else { return false }

        let startCheckpoint = min(lines.lowerBound / Self.stride, checkpoints.count - 1)
        var state = checkpoints[startCheckpoint]
        var newCheckpoints: [SyntaxState] = []
        var tokens: [Int: [SyntaxToken]] = [:]
        document.lines.forEachLine(in: (startCheckpoint * Self.stride)..<lines.upperBound) { line, bytes in
            if line % Self.stride == 0, line / Self.stride >= checkpoints.count {
                newCheckpoints.append(state)
            }
            if lines.contains(line) {
                tokens[line] = highlighter.tokens(bytes, state: &state)
            } else {
                highlighter.advance(bytes, state: &state)
            }
        }

        return storage.withLock { storage in
            guard storage.generation == generation else { return false }
            if storage.checkpoints.count == checkpoints.count {
                storage.checkpoints.append(contentsOf: newCheckpoints)
            }
            if storage.tokens.count + tokens.count > Self.tokenLimit {
                let middle = (lines.lowerBound + lines.upperBound) / 2
                storage.tokens = storage.tokens.filter { abs($0.key - middle) < Self.tokenLimit / 4 }
            }
            storage.tokens.merge(tokens) { _, new in new }
            return true
        }
    }
}
