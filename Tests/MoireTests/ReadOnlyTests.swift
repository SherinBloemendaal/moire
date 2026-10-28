import Foundation
@testable import Moire
import MoireKit
import Testing

/// Waits for work the model started on its own, such as reading a file or comparing.
private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<1000 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Timed out")
}

struct ReadOnlyTests {
    private let local: URL
    private let download: URL

    init() throws {
        local = FileManager.default.temporaryDirectory.appending(path: "moire-readonly-\(UUID().uuidString)", directoryHint: .isDirectory)
        download = FolderModel.downloads.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        for folder in [local, download] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    private func clean() {
        for folder in [local, download] { try? FileManager.default.removeItem(at: folder) }
    }

    private func file(_ name: String, in folder: URL, _ text: String) throws -> URL {
        let url = folder.appending(path: name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func loaded(_ model: CompareModel) async throws {
        try await waitUntil { !model.isLoading && model.diff != nil && !model.isComputing }
    }

    @Test func `knows Moire's temporary folders`() {
        #expect(TemporaryCopies.contains(FolderModel.downloads.appending(path: "x/a.txt")))
        #expect(TemporaryCopies.contains(ArchiveExtractor.defaultParent.appending(path: "x/app/a.txt")))
        #expect(!TemporaryCopies.contains(URL(filePath: "/Users/me/a.txt")))
        let folder = URL(filePath: "/tmp/one", directoryHint: .isDirectory)
        #expect(TemporaryCopies.contains(URL(filePath: "/tmp/one/a"), in: [folder]))
        #expect(!TemporaryCopies.contains(URL(filePath: "/tmp/onemore/a"), in: [folder]))
    }

    @Test func `keeps a downloaded copy read-only when a local file is loaded into the other side`() async throws {
        defer { clean() }
        let remote = try file("app.conf", in: download, "a\nserver\n")
        let first = try file("app.conf", in: local, "a\nfirst\n")
        let second = try file("other.conf", in: local, "a\nsecond\n")
        let model = CompareModel()
        model.openDownloaded(left: (remote, "sftp://host/etc"), right: (first, "~/etc"))
        try await loaded(model)
        #expect(model.left.isReadOnly)
        #expect(!model.right.isReadOnly)

        model.load(second, into: .right)
        try await waitUntil { model.right.url == second }
        try await loaded(model)
        #expect(model.left.isReadOnly)
        #expect(model.left.origin == "sftp://host/etc")
        #expect(!model.right.isReadOnly)
        #expect(!model.canEdit(.left))
        #expect(model.canEdit(.right))
    }

    @Test func `keeps a downloaded copy read-only when it is read again`() async throws {
        defer { clean() }
        let remote = try file("a.txt", in: download, "one\n")
        let model = CompareModel()
        model.openDownloaded(left: (remote, "sftp://host"), right: nil)
        try await waitUntil { !model.isLoading && model.left.url == remote }
        let revision = model.left.revision
        model.load(remote, into: .left, askFirst: false)
        try await waitUntil { !model.isLoading && model.left.revision != revision }
        #expect(model.left.isReadOnly)
        #expect(model.left.origin == "sftp://host")
    }

    @Test func `copies changes only into the side that can be edited`() async throws {
        defer { clean() }
        let remote = try file("a.txt", in: download, "same\nserver\n")
        let mine = try file("a.txt", in: local, "same\nmine\n")
        let model = CompareModel()
        model.openDownloaded(left: (remote, "sftp://host"), right: (mine, "~"))
        try await loaded(model)

        model.copy(hunk: 0, toRight: false)
        #expect(Array(model.left.document.lines) == ["same", "server"])
        model.setLine("typed", line: 0, on: .left)
        #expect(Array(model.left.document.lines) == ["same", "server"])
        #expect(!model.save(.left))
        #expect(try String(contentsOf: remote, encoding: .utf8) == "same\nserver\n")

        model.copy(hunk: 0, toRight: true)
        #expect(Array(model.right.document.lines) == ["same", "server"])
        #expect(model.right.isDirty)
        #expect(model.save(.right))
        #expect(try String(contentsOf: mine, encoding: .utf8) == "same\nserver\n")
    }

    @Test func `opens a file of an unpacked archive read-only`() async throws {
        let unpacked = ArchiveExtractor.defaultParent.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: unpacked)
            clean()
        }
        let inside = try file("a.txt", in: unpacked, "x\n")
        let mine = try file("a.txt", in: local, "y\n")
        let model = CompareModel()
        model.openPair(left: inside, right: mine)
        try await loaded(model)
        #expect(model.left.isReadOnly)
        #expect(!model.right.isReadOnly)
    }

}
