import Foundation
@testable import Moire
import Testing

struct MergeEditTests {
    @Test func `counts typed text in an open hand edit as unsaved and saves it`() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "moire-merge-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func file(_ name: String, _ text: String) throws -> URL {
            let url = folder.appending(path: name)
            try Data(text.utf8).write(to: url)
            return url
        }
        let output = folder.appending(path: "merged.txt")
        let model = MergeModel()
        model.openMergetool(base: try file("base.txt", "a\nb\n"), left: try file("left.txt", "a\nL\n"), right: try file("right.txt", "a\nR\n"), output: output)
        for _ in 0..<1000 where model.merge == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        let conflict = try #require(model.merge?.conflicts.first)

        model.beginEdit(conflict)
        #expect(!model.isDirty)
        model.editDraft = "typed\n"
        #expect(model.isDirty)
        model.cancelEdit()
        #expect(!model.isDirty)

        model.beginEdit(conflict)
        model.editDraft = "typed\n"
        #expect(model.save())
        #expect(!model.isDirty)
        #expect(model.editingChunk == nil)
        #expect(try String(contentsOf: output, encoding: .utf8) == "a\ntyped\n")
    }
}

struct MergetoolExitTests {
    @Test func `tells git the merge is done only after a save without conflicts`() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "moire-mergetool-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func file(_ name: String, _ text: String) throws -> URL {
            let url = folder.appending(path: name)
            try Data(text.utf8).write(to: url)
            return url
        }
        let output = try file("merged.txt", "<<<<<<< markers from git\n")
        let model = MergeModel()
        model.openMergetool(base: try file("base.txt", "a\nb\nc\n"), left: try file("left.txt", "a\nL\nc\n"), right: try file("right.txt", "a\nR\nc\nd\n"), output: output)
        for _ in 0..<1000 where model.merge == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.isMergetool)
        #expect(model.exitStatus != 0)

        let conflict = try #require(model.merge?.conflicts.first)
        model.select(conflict)
        model.resolveCurrent(.right)
        #expect(model.save())
        #expect(model.exitStatus == 0)
        #expect(try String(contentsOf: output, encoding: .utf8) == "a\nR\nc\nd\n")
    }
}
