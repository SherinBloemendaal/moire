import Darwin

/// Which items a folder comparison looks at.
public struct FolderFilter: Sendable, Hashable {
    /// When not empty, only files matching one of these are compared (folders are always read).
    public var include: [String]
    /// Items matching one of these are left out, folders with everything inside them.
    public var exclude: [String]
    /// Also leave out what the `.gitignore` files in the compared folders ignore.
    public var useGitignore: Bool

    public init(include: [String] = [], exclude: [String] = [], useGitignore: Bool = false) {
        self.include = include
        self.exclude = exclude
        self.useGitignore = useGitignore
    }

    public var isEmpty: Bool { include.isEmpty && exclude.isEmpty && !useGitignore }

    /// Splits text the way a user types masks: separated by commas, semicolons, spaces or new lines.
    public static func patterns(from text: String) -> [String] {
        text.split { $0 == "," || $0 == ";" || $0 == " " || $0 == "\n" }.map(String.init)
    }
}

/// Patterns with `.gitignore` meaning:
/// - `*`, `?` and `[a-z]` match within one path part, `**` matches any number of parts;
/// - a pattern without a slash (other than a trailing one) matches the name at any depth;
/// - a leading `/` or a slash in the middle ties the pattern to the folder it was written for;
/// - a trailing `/` matches folders only;
/// - `!` brings back what an earlier pattern left out; the last matching pattern wins;
/// - `#` starts a comment, and `\` escapes a leading `#` or `!`.
public struct IgnoreRules: Sendable, Hashable {
    struct Rule: Sendable, Hashable {
        /// The path parts of the pattern, for anchored patterns.
        let parts: [String]
        /// For a pattern that matches the name at any depth.
        let name: String?
        let negated: Bool
        let directoryOnly: Bool
        /// The folder the pattern was written for, relative to the compared folders; empty for the root.
        let base: String
    }

    private(set) var rules: [Rule] = []

    public init() {}

    public init(patterns: [String], base: String = "") {
        add(patterns, base: base)
    }

    public var isEmpty: Bool { rules.isEmpty }

    /// Adds the lines of a `.gitignore` file found in `base`.
    public mutating func add(gitignore text: String, base: String) {
        add(text.split(whereSeparator: \.isNewline).map(String.init), base: base)
    }

    public mutating func add(_ patterns: [String], base: String) {
        for raw in patterns {
            var pattern = raw
            // Trailing spaces are ignored unless escaped.
            while pattern.hasSuffix(" "), !pattern.hasSuffix("\\ ") { pattern.removeLast() }
            guard !pattern.isEmpty, !pattern.hasPrefix("#") else { continue }

            var negated = false
            if pattern.hasPrefix("!") {
                negated = true
                pattern.removeFirst()
            } else if pattern.hasPrefix("\\#") || pattern.hasPrefix("\\!") {
                pattern.removeFirst()
            }

            var directoryOnly = false
            if pattern.hasSuffix("/") {
                directoryOnly = true
                pattern.removeLast()
            }
            guard !pattern.isEmpty else { continue }

            let anchored = pattern.contains("/")
            if pattern.hasPrefix("/") { pattern.removeFirst() }
            let parts = pattern.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard !parts.isEmpty else { continue }

            rules.append(Rule(
                parts: anchored ? parts : [],
                name: anchored ? nil : pattern,
                negated: negated,
                directoryOnly: directoryOnly,
                base: base
            ))
        }
    }

    /// Whether `path` (relative to the compared folders, `/` between parts) is left out.
    public func ignores(_ path: String, isDirectory: Bool) -> Bool {
        var ignored = false
        for rule in rules where rule.negated == ignored {
            if rule.directoryOnly && !isDirectory { continue }
            if matches(rule, path) { ignored = !rule.negated }
        }
        return ignored
    }

    /// Whether `path` matches any of the rules, ignoring negation. Used for include masks.
    func matchesAny(_ path: String, isDirectory: Bool) -> Bool {
        rules.contains { (!$0.directoryOnly || isDirectory) && matches($0, path) }
    }

    private func matches(_ rule: Rule, _ path: String) -> Bool {
        let relative: Substring
        if rule.base.isEmpty {
            relative = path[...]
        } else {
            guard path.hasPrefix(rule.base + "/") else { return false }
            relative = path.dropFirst(rule.base.count + 1)
        }
        if let name = rule.name {
            let last = relative.split(separator: "/").last.map(String.init) ?? String(relative)
            return Self.glob(name, last)
        }
        return Self.match(rule.parts[...], relative.split(separator: "/").map(String.init)[...])
    }

    private static func match(_ pattern: ArraySlice<String>, _ path: ArraySlice<String>) -> Bool {
        guard let first = pattern.first else { return path.isEmpty }
        if first == "**" {
            // "**" takes zero or more parts.
            var rest = path
            while true {
                if match(pattern.dropFirst(), rest) { return true }
                guard !rest.isEmpty else { return false }
                rest = rest.dropFirst()
            }
        }
        guard let part = path.first, glob(first, part) else { return false }
        return match(pattern.dropFirst(), path.dropFirst())
    }

    static func glob(_ pattern: String, _ name: String) -> Bool {
        fnmatch(pattern, name, 0) == 0
    }
}
