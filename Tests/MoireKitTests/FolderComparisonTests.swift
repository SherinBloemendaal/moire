import Foundation
@testable import MoireKit
import Testing

private func makeTree(_ files: [String: String], links: [String: String] = [:]) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(path: "moire-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for (path, contents) in files {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }
    for (path, destination) in links {
        try FileManager.default.createSymbolicLink(atPath: root.appending(path: path).path(percentEncoded: false), withDestinationPath: destination)
    }
    return root
}

struct FolderComparisonTests {
    @Test func `compares files by content and lists files found on one side only`() throws {
        let left = try makeTree(["same.txt": "x", "changed.txt": "a", "only-left.txt": "l", "src/deep.swift": "1"])
        let right = try makeTree(["same.txt": "x", "changed.txt": "b", "only-right.txt": "r", "src/deep.swift": "1"])
        let comparison = try FolderComparison(left: left, right: right)
        let statuses = Dictionary(uniqueKeysWithValues: comparison.items.map { ($0.path, $0.status) })

        #expect(statuses == [
            "same.txt": .identical, "changed.txt": .different, "only-left.txt": .leftOnly,
            "only-right.txt": .rightOnly, "src": .identical, "src/deep.swift": .identical,
        ])
        #expect(comparison.differenceCount == 3)
    }

    @Test func `marks a folder as different when something inside it differs`() throws {
        let left = try makeTree(["a/b/c.txt": "1"])
        let right = try makeTree(["a/b/c.txt": "2"])
        let statuses = Dictionary(uniqueKeysWithValues: try FolderComparison(left: left, right: right).items.map { ($0.path, $0.status) })
        #expect(statuses["a"] == .different)
        #expect(statuses["a/b"] == .different)
    }

    @Test func `orders folders before files and contents right after their folder`() throws {
        let tree = try makeTree(["b.txt": "", "a/z.txt": "", "c/x.txt": "", "A2.txt": ""])
        let paths = try FolderComparison(left: tree, right: tree).items.map(\.path)
        #expect(paths == ["a", "a/z.txt", "c", "c/x.txt", "A2.txt", "b.txt"])
    }

    @Test func `skips hidden files unless asked`() throws {
        let left = try makeTree([".DS_Store": "1", "a.txt": "x"])
        let right = try makeTree([".DS_Store": "2", "a.txt": "x"])
        #expect(try FolderComparison(left: left, right: right).differenceCount == 0)
        #expect(try FolderComparison(left: left, right: right, options: .init(skipHidden: false)).differenceCount == 1)
    }

    @Test func `compares symbolic links by destination without following them`() throws {
        let left = try makeTree(["a.txt": "x"], links: ["loop": ".", "link": "a.txt"])
        let right = try makeTree(["a.txt": "x"], links: ["loop": ".", "link": "b.txt"])
        let statuses = Dictionary(uniqueKeysWithValues: try FolderComparison(left: left, right: right).items.map { ($0.path, $0.status) })
        #expect(statuses["loop"] == .identical)
        #expect(statuses["link"] == .different)
    }

    @Test func `sees a difference in large files of the same size`() throws {
        let body = String(repeating: "0123456789", count: 20_000)
        let left = try makeTree(["big.bin": body + "a"])
        let right = try makeTree(["big.bin": body + "b"])
        #expect(try FolderComparison(left: left, right: right).differenceCount == 1)
    }
}
