import Foundation
@testable import Moire
import MoireKit
import Testing

/// The sync the way the sheet runs it: through the folder model, on real folders.
@MainActor
@Suite(.serialized)
struct SyncFlowTests {
    private func folder(_ files: [String: String], date: Date) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "moire-syncflow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, text) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path(percentEncoded: false))
        }
        return root
    }

    private func compared(_ left: URL, _ right: URL) async throws -> FolderModel {
        let model = FolderModel()
        model.pick(.binary)
        model.left = left
        model.right = right
        for _ in 0..<400 where !model.isComplete { try await Task.sleep(for: .milliseconds(10)) }
        try #require(model.isComplete)
        return model
    }

    private func contents(_ root: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let relative = url.standardizedFileURL.path(percentEncoded: false).dropFirst(root.standardizedFileURL.path(percentEncoded: false).count)
            result[String(relative.drop { $0 == "/" })] = try String(contentsOf: url, encoding: .utf8)
        }
        return result
    }

    private let old = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func `update runs where it was planned and compares again`() async throws {
        let left = try folder(["new.txt": "n", "deep/a.txt": "a", "same.txt": "s"], date: old.addingTimeInterval(7200))
        let right = try folder(["same.txt": "s"], date: old.addingTimeInterval(7200))
        let model = try await compared(left, right)
        let job = try #require(model.plan(mode: .update, direction: .leftToRight, selection: []))
        #expect(job.plan.copies == 2)

        // The window moves on to other folders before the sync starts: it still syncs the planned ones.
        let elsewhere = try folder(["x.txt": "x"], date: old)
        model.right = elsewhere
        var progress: [Int] = []
        let failures = await model.run(job, stop: FolderModel.SyncStop()) { progress.append($0) }

        #expect(failures.isEmpty)
        #expect(try contents(right) == ["new.txt": "n", "deep/a.txt": "a", "same.txt": "s"])
        #expect(try contents(elsewhere) == ["x.txt": "x"])
    }

    @Test func `stop leaves the rest of the plan undone`() async throws {
        var files: [String: String] = [:]
        for index in 0..<50 { files["f\(index).txt"] = "\(index)" }
        let left = try folder(files, date: old)
        let right = try folder([:], date: old)
        let model = try await compared(left, right)
        let job = try #require(model.plan(mode: .update, direction: .leftToRight, selection: []))
        #expect(job.plan.copies == 50)

        let stop = FolderModel.SyncStop()
        stop.stop()
        let failures = await model.run(job, stop: stop) { _ in }
        #expect(failures.isEmpty)
        #expect(try contents(right).isEmpty)
    }

    @Test func `a stopped comparison cannot be synced`() async throws {
        var files: [String: String] = [:]
        for index in 0..<3000 { files["d\(index % 30)/f\(index).txt"] = "\(index)" }
        let left = try folder(files, date: old)
        let model = FolderModel()
        model.pick(.binary)
        model.left = left
        model.right = try folder([:], date: old)
        model.stop()
        for _ in 0..<400 where model.isComparing { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!model.isComplete)
        #expect(model.tree != nil)
        #expect(!model.canPlanSync)
        #expect(model.plan(mode: .update, direction: .leftToRight, selection: []) == nil)
    }
}
