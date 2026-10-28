import Foundation
@testable import Moire
import MoireKit
import Testing

/// A file another app writes while it is open: reloaded, or asked about when it has unsaved edits.
@MainActor
@Suite(.serialized)
struct ReloadOnChangeTests {
    private func file(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "moire-reload-\(UUID().uuidString).txt")
        try Data(text.utf8).write(to: url)
        return url
    }

    private func loaded(_ url: URL) async throws -> CompareModel {
        let model = CompareModel()
        model.load(url, into: .left)
        for _ in 0..<200 where model.left.url == nil { try await Task.sleep(for: .milliseconds(5)) }
        try #require(model.left.url == url)
        return model
    }

    /// Waits as long as a reload can take: the watcher waits 0.2 s, then the file is read.
    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func `a file written by another app is reloaded without asking`() async throws {
        let original = CompareModel.confirmReload
        defer { CompareModel.confirmReload = original }
        var asked = 0
        CompareModel.confirmReload = { _, _ in asked += 1; return false }
        let url = try file("one\n")
        let model = try await loaded(url)

        try Data("two\n".utf8).write(to: url)
        try await waitFor { model.left.text == "two\n" }
        #expect(model.left.text == "two\n")
        #expect(!model.left.isDirty)
        #expect(asked == 0)
    }

    @Test func `a file replaced by a save that moves a new file over it is still followed`() async throws {
        let original = CompareModel.confirmReload
        defer { CompareModel.confirmReload = original }
        CompareModel.confirmReload = { _, _ in false }
        let url = try file("one\n")
        let model = try await loaded(url)

        try Data("two\n".utf8).write(to: url, options: .atomic)
        try await waitFor { model.left.text == "two\n" }
        #expect(model.left.text == "two\n")

        // The watcher now follows the new file, not the one that was moved away.
        try Data("three\n".utf8).write(to: url, options: .atomic)
        try await waitFor { model.left.text == "three\n" }
        #expect(model.left.text == "three\n")
    }

    @Test func `unsaved edits are kept when the user keeps them`() async throws {
        let original = CompareModel.confirmReload
        defer { CompareModel.confirmReload = original }
        var asked: [(URL, SideID)] = []
        CompareModel.confirmReload = { asked.append(($0, $1)); return false }
        let url = try file("one\n")
        let model = try await loaded(url)
        model.setText("mine\n", on: .left)

        try Data("theirs\n".utf8).write(to: url)
        try await waitFor { !asked.isEmpty }
        #expect(asked.count == 1)
        #expect(asked.first?.0 == url)
        #expect(asked.first?.1 == .left)
        try await Task.sleep(for: .milliseconds(400))
        #expect(model.left.text == "mine\n")
        #expect(model.left.isDirty)
        // Kept until the file changes again: no second question for the same change.
        #expect(asked.count == 1)
    }

    @Test func `unsaved edits give way when the user picks Reload`() async throws {
        let original = CompareModel.confirmReload
        defer { CompareModel.confirmReload = original }
        var asked = 0
        CompareModel.confirmReload = { _, _ in asked += 1; return true }
        let url = try file("one\n")
        let model = try await loaded(url)
        model.setText("mine\n", on: .left)

        try Data("theirs\n".utf8).write(to: url)
        try await waitFor { model.left.text == "theirs\n" }
        #expect(asked == 1)
        #expect(model.left.text == "theirs\n")
        #expect(!model.left.isDirty)
    }

    @Test func `saving the file here is not taken for a change by another app`() async throws {
        let original = CompareModel.confirmReload
        defer { CompareModel.confirmReload = original }
        var asked = 0
        CompareModel.confirmReload = { _, _ in asked += 1; return true }
        let url = try file("one\n")
        let model = try await loaded(url)
        let replacements = model.replacements
        model.setText("mine\n", on: .left)
        #expect(model.save(.left))

        try await Task.sleep(for: .milliseconds(600))
        #expect(asked == 0)
        #expect(model.left.text == "mine\n")
        // Typing replaced the text once; a reload would have replaced it again.
        #expect(model.replacements == replacements + 1)
    }
}
