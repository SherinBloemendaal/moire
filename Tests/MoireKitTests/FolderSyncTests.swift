import Foundation
@testable import MoireKit
import Testing

private let old = Date(timeIntervalSince1970: 1_700_000_000)
private let new = old.addingTimeInterval(3 * 3600)

private func tree(_ files: [String: (String, Date)], folders: [String] = []) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(path: "moire-sync-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for folder in folders {
        try FileManager.default.createDirectory(at: root.appending(path: folder), withIntermediateDirectories: true)
    }
    for (path, (contents, date)) in files {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path(percentEncoded: false))
    }
    return root
}

private func contents(_ root: URL) throws -> [String: String] {
    var result: [String: String] = [:]
    let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
    while let url = enumerator?.nextObject() as? URL {
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
        let relative = String(url.standardizedFileURL.path(percentEncoded: false).dropFirst(root.standardizedFileURL.path(percentEncoded: false).count))
        result[relative.hasPrefix("/") ? String(relative.dropFirst()) : relative] = try String(contentsOf: url, encoding: .utf8)
    }
    return result
}

private let settings = FolderCompareSettings(method: .binary)

private func compare(_ left: URL, _ right: URL) throws -> FolderTree {
    try FolderEngine(left: left, right: right, settings: settings).run()
}

/// Deletes instead of moving to the user's Trash, so tests leave nothing behind there.
private func delete(_ url: URL) throws { try FileManager.default.removeItem(at: url) }

struct FolderSyncTests {
    @Test func `update copies missing and newer files and keeps newer ones on the target`() throws {
        let left = try tree(["missing.txt": ("m", old), "newer.txt": ("left new", new), "older.txt": ("left old", old), "deep/a.txt": ("a", old)])
        let right = try tree(["newer.txt": ("right old", old), "older.txt": ("right new", new), "extra.txt": ("e", old)])
        let plan = FolderSync.plan(try compare(left, right), mode: .update, direction: .leftToRight, settings: settings)

        #expect(Set(plan.actions) == [
            .copy(path: "missing.txt", toRight: true, bytes: 1),
            .copy(path: "newer.txt", toRight: true, bytes: 8),
            .createFolder(path: "deep", onRight: true),
            .copy(path: "deep/a.txt", toRight: true, bytes: 1),
        ])
        #expect(FolderSync.execute(plan, left: left, right: right, trash: delete).isEmpty)
        #expect(try contents(right) == ["missing.txt": "m", "newer.txt": "left new", "older.txt": "right new", "deep/a.txt": "a", "extra.txt": "e"])
    }

    @Test func `mirror makes the target an exact copy`() throws {
        let left = try tree(["a.txt": ("a", old), "sub/b.txt": ("b", old), "changed.txt": ("left", old)])
        let right = try tree(["a.txt": ("a", old), "changed.txt": ("right is newer", new), "gone/x.txt": ("x", old), "gone/y/z.txt": ("z", old), "stray.txt": ("s", old)])
        let plan = FolderSync.plan(try compare(left, right), mode: .mirror, direction: .leftToRight, settings: settings)

        // A folder going to the Trash takes its contents with it: one action, not three.
        #expect(plan.trashes == 2)
        #expect(FolderSync.execute(plan, left: left, right: right, trash: delete).isEmpty)
        #expect(try contents(right) == contents(left))
        #expect(try compare(left, right).differenceCount == 0)
    }

    @Test func `both ways copies each newer file to the other side and leaves ties alone`() throws {
        let left = try tree(["l.txt": ("left only", old), "a.txt": ("left newer", new), "b.txt": ("left older", old), "tie.txt": ("left", old)])
        let right = try tree(["r.txt": ("right only", old), "a.txt": ("right older", old), "b.txt": ("right newer", new), "tie.txt": ("rite", old)])
        let plan = FolderSync.plan(try compare(left, right), mode: .update, direction: .both, settings: settings)
        #expect(FolderSync.execute(plan, left: left, right: right, trash: delete).isEmpty)

        #expect(try contents(left) == ["l.txt": "left only", "r.txt": "right only", "a.txt": "left newer", "b.txt": "right newer", "tie.txt": "left"])
        #expect(try contents(right) == ["l.txt": "left only", "r.txt": "right only", "a.txt": "left newer", "b.txt": "right newer", "tie.txt": "rite"])
    }

    @Test func `plans only the selection and what is inside selected folders`() throws {
        let left = try tree(["pick/a.txt": ("a", old), "pick/b.txt": ("b", old), "skip.txt": ("s", old)])
        let right = try tree([:])
        let compared = try compare(left, right)
        let pick = try #require((1..<compared.count).first { compared.path(of: $0) == "pick" })
        let plan = FolderSync.plan(compared, mode: .update, direction: .leftToRight, settings: settings, selection: [pick])
        #expect(Set(plan.actions.map(\.path)) == ["pick", "pick/a.txt", "pick/b.txt"])
    }

    @Test func `keeps the date and copies a symbolic link as a link`() throws {
        let left = try tree(["a.txt": ("a", old)])
        try FileManager.default.createSymbolicLink(atPath: left.appending(path: "link").path(percentEncoded: false), withDestinationPath: "a.txt")
        let right = try tree([:])
        let plan = FolderSync.plan(try compare(left, right), mode: .update, direction: .leftToRight, settings: settings)
        #expect(FolderSync.execute(plan, left: left, right: right, trash: delete).isEmpty)

        let date = try FileManager.default.attributesOfItem(atPath: right.appending(path: "a.txt").path(percentEncoded: false))[.modificationDate] as? Date
        #expect(date == old)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: right.appending(path: "link").path(percentEncoded: false)) == "a.txt")
    }

    @Test func `reports what failed and carries on`() throws {
        let left = try tree(["ok.txt": ("ok", old), "locked.txt": ("l", old)])
        let right = try tree([:])
        let locked = left.appending(path: "locked.txt").path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked) }

        let plan = FolderSync.plan(try compare(left, right), mode: .update, direction: .leftToRight, settings: settings)
        let failures = FolderSync.execute(plan, left: left, right: right, trash: delete)
        #expect(failures.map(\.action.path) == ["locked.txt"])
        #expect(try contents(right) == ["ok.txt": "ok"])
        // Nothing half-written is left next to the failed file.
        #expect(try FileManager.default.contentsOfDirectory(atPath: right.path(percentEncoded: false)) == ["ok.txt"])
    }
}
