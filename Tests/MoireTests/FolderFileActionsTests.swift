import Foundation
@testable import Moire
import MoireKit
import Testing

/// Move to Trash and Rename from the folder list, on real folders.
@MainActor
@Suite(.serialized)
struct FolderFileActionsTests {
    private func folder(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "moire-folderactions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (name, text) in files {
            try Data(text.utf8).write(to: root.appending(path: name))
        }
        return root
    }

    private func compared(_ left: URL, _ right: URL) async throws -> FolderModel {
        let model = FolderModel()
        model.pick(.binary)
        model.left = left
        model.right = right
        try await finished(model)
        return model
    }

    private func finished(_ model: FolderModel) async throws {
        for _ in 0..<400 where !model.isComplete { try await Task.sleep(for: .milliseconds(10)) }
        try #require(model.isComplete)
    }

    private func item(_ name: String, in model: FolderModel) throws -> Int {
        let tree = try #require(model.tree)
        return try #require((1..<tree.count).first { tree.name(of: $0) == name })
    }

    private func status(_ name: String, in model: FolderModel) throws -> FolderTree.Status {
        try #require(model.tree).status(of: try item(name, in: model))
    }

    private func names(_ root: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false)).sorted()
    }

    @Test func `trash moves the file to the Trash and compares again`() async throws {
        let original = FolderModel.confirmTrash
        defer { FolderModel.confirmTrash = original }
        var asked: [([URL], SideID)] = []
        FolderModel.confirmTrash = { asked.append(($0, $1)); return true }
        // A name of its own, so the test can take back out of the Trash exactly what it put there.
        let extra = "extra-\(UUID().uuidString).txt"
        let trash = try FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        defer { try? FileManager.default.removeItem(at: trash.appending(path: extra)) }
        let left = try folder(["same.txt": "s", extra: "e"])
        let right = try folder(["same.txt": "s"])
        let model = try await compared(left, right)
        #expect(try status(extra, in: model) == .leftOnly)

        model.trash([try item(extra, in: model)], side: .left)
        #expect(asked.map(\.0.count) == [1])
        #expect(asked.first?.0.first?.lastPathComponent == extra)
        #expect(asked.first?.1 == .left)
        #expect(try names(left) == ["same.txt"])
        #expect(FileManager.default.fileExists(atPath: trash.appending(path: extra).path(percentEncoded: false)))
        #expect(model.errorMessage == nil)

        try await finished(model)
        let tree = try #require(model.tree)
        #expect((1..<tree.count).map { tree.name(of: $0) } == ["same.txt"])
        #expect(model.count(.leftOnly) == 0)
    }

    @Test func `trash does nothing when the user cancels`() async throws {
        let original = FolderModel.confirmTrash
        defer { FolderModel.confirmTrash = original }
        FolderModel.confirmTrash = { _, _ in false }
        let left = try folder(["extra.txt": "e"])
        let right = try folder([:])
        let model = try await compared(left, right)
        let generation = model.generation

        model.trash([try item("extra.txt", in: model)], side: .left)
        #expect(try names(left) == ["extra.txt"])
        #expect(model.generation == generation)
    }

    @Test func `rename changes the name on disk and compares again`() async throws {
        let original = FolderModel.askNewName
        defer { FolderModel.askNewName = original }
        FolderModel.askNewName = { _, _ in "new.txt" }
        let left = try folder(["old.txt": "x"])
        let right = try folder(["new.txt": "x"])
        let model = try await compared(left, right)
        #expect(try status("old.txt", in: model) == .leftOnly)

        model.rename(try item("old.txt", in: model), side: .left)
        #expect(try names(left) == ["new.txt"])
        #expect(model.errorMessage == nil)

        try await finished(model)
        #expect(try status("new.txt", in: model) == .identical)
        #expect(model.count(.leftOnly) == 0)
        #expect(model.count(.rightOnly) == 0)
    }

    @Test func `rename can change only the case of a name`() async throws {
        let original = FolderModel.askNewName
        defer { FolderModel.askNewName = original }
        FolderModel.askNewName = { _, _ in "A.txt" }
        let left = try folder(["a.txt": "x"])
        let right = try folder(["a.txt": "x"])
        let model = try await compared(left, right)
        // On this disk "A.txt" already "exists": it is the file being renamed.
        try #require(try left.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames == false)

        model.rename(try item("a.txt", in: model), side: .left)
        #expect(model.errorMessage == nil)
        #expect(try names(left) == ["A.txt"])
        #expect(try String(contentsOf: left.appending(path: "A.txt"), encoding: .utf8) == "x")
        try await finished(model)
    }

    @Test func `rename refuses a name that is already taken`() async throws {
        let original = FolderModel.askNewName
        defer { FolderModel.askNewName = original }
        FolderModel.askNewName = { _, _ in "b.txt" }
        let left = try folder(["a.txt": "a", "b.txt": "b"])
        let right = try folder([:])
        let model = try await compared(left, right)

        model.rename(try item("a.txt", in: model), side: .left)
        #expect(model.errorMessage == "\"b.txt\" already exists there.")
        #expect(try names(left) == ["a.txt", "b.txt"])
        #expect(try String(contentsOf: left.appending(path: "b.txt"), encoding: .utf8) == "b")
    }

    @Test func `rename refuses a name with a slash and does nothing on Cancel`() async throws {
        let original = FolderModel.askNewName
        defer { FolderModel.askNewName = original }
        let left = try folder(["a.txt": "a"])
        let right = try folder([:])
        let model = try await compared(left, right)

        FolderModel.askNewName = { _, _ in "sub/a.txt" }
        model.rename(try item("a.txt", in: model), side: .left)
        #expect(model.errorMessage == "A name cannot contain \"/\".")

        model.errorMessage = nil
        FolderModel.askNewName = { _, _ in nil }
        model.rename(try item("a.txt", in: model), side: .left)
        #expect(model.errorMessage == nil)
        #expect(try names(left) == ["a.txt"])
    }
}
