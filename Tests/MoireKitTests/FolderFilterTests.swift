import Foundation
@testable import MoireKit
import Testing

struct IgnoreRulesTests {
    @Test(arguments: [
        ("*.log", "debug.log", false, true),
        ("*.log", "logs/deep/debug.log", false, true),
        ("*.log", "debug.log.txt", false, false),
        ("build/", "build", true, true),
        ("build/", "build", false, false),
        ("build/", "src/build", true, true),
        ("/build", "build", true, true),
        ("/build", "src/build", true, false),
        ("doc/*.txt", "doc/notes.txt", false, true),
        ("doc/*.txt", "doc/server/notes.txt", false, false),
        ("doc/**/*.txt", "doc/server/arch.txt", false, true),
        ("doc/**/*.txt", "doc/arch.txt", false, true),
        ("**/foo", "a/b/foo", false, true),
        ("**/foo", "foo", false, true),
        ("a/**/b", "a/x/y/b", false, true),
        ("a/**", "a/x/y", false, true),
        ("f?le.[ch]", "file.c", false, true),
        ("f?le.[ch]", "file.o", false, false),
        ("\\#hash", "#hash", false, true),
        ("# comment", "# comment", false, false),
    ])
    func `matches like git`(pattern: String, path: String, isDirectory: Bool, ignored: Bool) {
        #expect(IgnoreRules(patterns: [pattern]).ignores(path, isDirectory: isDirectory) == ignored, "\(pattern) on \(path)")
    }

    @Test func `lets a later negation bring a file back`() {
        let rules = IgnoreRules(patterns: ["*.log", "!keep.log"])
        #expect(rules.ignores("a.log", isDirectory: false))
        #expect(!rules.ignores("keep.log", isDirectory: false))
        #expect(IgnoreRules(patterns: ["!keep.log", "*.log"]).ignores("keep.log", isDirectory: false))
    }

    @Test func `ties rules from a nested gitignore to its folder`() {
        var rules = IgnoreRules()
        rules.add(gitignore: "/out\n*.tmp\n", base: "app")
        #expect(rules.ignores("app/out", isDirectory: true))
        #expect(!rules.ignores("out", isDirectory: true))
        #expect(!rules.ignores("lib/out", isDirectory: true))
        #expect(rules.ignores("app/deep/x.tmp", isDirectory: false))
        #expect(!rules.ignores("x.tmp", isDirectory: false))
    }

    @Test func `splits typed masks`() {
        #expect(FolderFilter.patterns(from: "*.swift, *.md;node_modules/\nbuild/") == ["*.swift", "*.md", "node_modules/", "build/"])
    }
}

struct FolderEngineFilterTests {
    private func tree(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "moire-filter-\(UUID().uuidString)")
        for (path, contents) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
        return root
    }

    private func paths(_ left: URL, _ right: URL, _ filter: FolderFilter, skipHidden: Bool = true) throws -> Set<String> {
        let tree = try FolderEngine(left: left, right: right, settings: FolderCompareSettings(method: .binary, skipHidden: skipHidden, filter: filter)).run()
        return Set((1..<tree.count).map { tree.path(of: $0) })
    }

    @Test func `leaves out excluded files and folders with their contents`() throws {
        let files = ["src/a.swift": "a", "src/a.log": "l", "node_modules/x/y.js": "y", "README.md": "r"]
        let left = try tree(files)
        let right = try tree(files)
        #expect(try paths(left, right, FolderFilter(exclude: ["*.log", "node_modules/"])) == ["src", "src/a.swift", "README.md"])
    }

    @Test func `keeps only files matching an include mask`() throws {
        let files = ["src/a.swift": "a", "src/b.m": "b", "README.md": "r"]
        let left = try tree(files)
        let right = try tree(files)
        #expect(try paths(left, right, FolderFilter(include: ["*.swift", "*.md"])) == ["src", "src/a.swift", "README.md"])
    }

    @Test func `follows gitignore files on either side, nested ones too`() throws {
        let left = try tree([".gitignore": "*.o\n/dist/\n", "main.c": "m", "main.o": "o", "dist/app": "x", "lib/.gitignore": "gen/\n", "lib/gen/g.c": "g", "lib/l.c": "l", ".git/HEAD": "ref"])
        let right = try tree(["main.c": "m", "main.o": "o2", "dist/app": "y", "lib/gen/g.c": "g", "lib/l.c": "l"])
        let found = try paths(left, right, FolderFilter(useGitignore: true), skipHidden: false)
        #expect(found == [".gitignore", "lib", "lib/.gitignore", "lib/l.c", "main.c"])
    }
}
