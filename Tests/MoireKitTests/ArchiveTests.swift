import Foundation
@testable import MoireKit
import Testing

@discardableResult
private func shell(_ tool: String, _ arguments: [String], in folder: URL) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(filePath: tool)
    process.arguments = arguments
    process.currentDirectoryURL = folder
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

/// A temporary folder with a small tree to pack, and a separate folder to unpack into.
private struct Workspace {
    let base: URL
    let source: URL
    let parent: URL

    init() throws {
        base = FileManager.default.temporaryDirectory.appending(path: "moire-archive-\(UUID().uuidString)", directoryHint: .isDirectory)
        source = base.appending(path: "source", directoryHint: .isDirectory)
        parent = base.appending(path: "unpacked", directoryHint: .isDirectory)
        let manager = FileManager.default
        try manager.createDirectory(at: source.appending(path: "nested/deeper"), withIntermediateDirectories: true)
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        try Data("top".utf8).write(to: source.appending(path: "top.txt"))
        try Data("deep".utf8).write(to: source.appending(path: "nested/deeper/deep.txt"))
    }

    func remove() {
        ArchiveExtractor.removeTree(base)
    }

    var unpackedFolders: [URL] {
        (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []
    }
}

private func contents(_ url: URL) throws -> String {
    String(decoding: try Data(contentsOf: url), as: UTF8.self)
}

@Suite struct ArchiveTests {
    @Test func `a zip made by ditto opens as a folder`() async throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        let archive = workspace.base.appending(path: "Photos.zip")
        #expect(try shell("/usr/bin/ditto", ["-c", "-k", workspace.source.path, archive.path], in: workspace.base) == 0)
        #expect(FileKind.detect(archive) == .archive(.zip))

        let extracted = try await ArchiveExtractor.extract(archive, format: .zip, into: workspace.parent)
        #expect(extracted.folder.lastPathComponent == "Photos")
        #expect(extracted.archive == archive)
        #expect(try contents(extracted.folder.appending(path: "top.txt")) == "top")
        #expect(try contents(extracted.folder.appending(path: "nested/deeper/deep.txt")) == "deep")

        extracted.remove()
        #expect(!FileManager.default.fileExists(atPath: extracted.folder.path))
        #expect(workspace.unpackedFolders.isEmpty)
    }

    @Test(arguments: [
        ("a.tar", "-cf", ArchiveFormat.tar),
        ("a.tar.gz", "-czf", .tarGzip),
        ("a.tgz", "-czf", .tarGzip),
        ("a.tar.bz2", "-cjf", .tarBzip2),
        ("a.tar.xz", "-cJf", .tarXz),
    ])
    func `tarballs open as a folder`(name: String, flags: String, format: ArchiveFormat) async throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        let archive = workspace.base.appending(path: name)
        #expect(try shell("/usr/bin/tar", [flags, archive.path, "-C", workspace.source.path, "."], in: workspace.base) == 0)
        #expect(FileKind.detect(archive) == .archive(format))

        let extracted = try await ArchiveExtractor.extract(archive, format: format, into: workspace.parent)
        #expect(extracted.folder.lastPathComponent == "a")
        #expect(try contents(extracted.folder.appending(path: "nested/deeper/deep.txt")) == "deep")
        extracted.remove()
        #expect(workspace.unpackedFolders.isEmpty)
    }

    @Test func `an entry outside the folder is refused before anything is unpacked`() async throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        let archive = workspace.base.appending(path: "evil.tar")
        // Stores top.txt as ../top.txt.
        #expect(try shell("/usr/bin/tar", ["-cf", archive.path, "-s", ",^,../,", "-C", workspace.source.path, "top.txt"], in: workspace.base) == 0)

        await #expect(throws: ArchiveExtractor.Failure.unsafeEntry("../top.txt")) {
            _ = try await ArchiveExtractor.extract(archive, format: .tar, into: workspace.parent)
        }
        #expect(workspace.unpackedFolders.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: workspace.base.appending(path: "top.txt").path))
    }

    @Test func `names that escape or go through a link are refused`() throws {
        for names in [["/etc/passwd"], ["a/../../b"], [".."], ["./../x"]] {
            #expect(throws: ArchiveExtractor.Failure.self) { try ArchiveExtractor.validate(names, format: .tar) }
        }
        // A file entry with entries below it is a link in disguise; ditto would follow it.
        #expect(throws: ArchiveExtractor.Failure.unsafeEntry("link/evil")) {
            try ArchiveExtractor.validate(["link", "link/evil"], format: .zip)
        }
        #expect(throws: ArchiveExtractor.Failure.unsafeEntry("a.txt")) {
            try ArchiveExtractor.validate(["a.txt", "a.txt"], format: .zip)
        }
        try ArchiveExtractor.validate(["dir/", "dir/a.txt", "./b", "c..d/e..", "._dir"], format: .zip)
        try ArchiveExtractor.validate(["./", "./dir/", "./dir/a"], format: .tar)
    }

    @Test func `read-only folders from an archive are still removed`() async throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        let locked = workspace.source.appending(path: "nested")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        let archive = workspace.base.appending(path: "locked.tar")
        let status = try shell("/usr/bin/tar", ["-cf", archive.path, "-C", workspace.source.path, "."], in: workspace.base)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        #expect(status == 0)

        let extracted = try await ArchiveExtractor.extract(archive, format: .tar, into: workspace.parent)
        let permissions = try FileManager.default.attributesOfItem(atPath: extracted.folder.appending(path: "nested").path)[.posixPermissions] as? Int
        #expect(permissions == 0o555)
        extracted.remove()
        #expect(workspace.unpackedFolders.isEmpty)
    }

    @Test func `the folder goes away with the last reference`() async throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        let archive = workspace.base.appending(path: "a.tgz")
        #expect(try shell("/usr/bin/tar", ["-czf", archive.path, "-C", workspace.source.path, "."], in: workspace.base) == 0)
        var extracted: ExtractedArchive? = try await ArchiveExtractor.extract(archive, format: .tarGzip, into: workspace.parent)
        let folder = try #require(extracted?.folder)
        #expect(FileManager.default.fileExists(atPath: folder.path))
        extracted = nil
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func `a broken archive reports the tool's message and leaves nothing behind`() async throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        let archive = workspace.base.appending(path: "broken.zip")
        try Data("PK\u{3}\u{4}not really a zip".utf8).write(to: archive)
        await #expect(throws: ArchiveExtractor.Failure.self) {
            _ = try await ArchiveExtractor.extract(archive, format: .zip, into: workspace.parent)
        }
        #expect(workspace.unpackedFolders.isEmpty)
    }

    @Test func `old leftovers are removed and new ones kept`() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        let old = workspace.parent.appending(path: "old")
        let new = workspace.parent.appending(path: "new")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSinceNow: -3 * 24 * 60 * 60)], ofItemAtPath: old.path)
        ArchiveExtractor.removeLeftovers(in: workspace.parent)
        #expect(workspace.unpackedFolders.map(\.lastPathComponent) == ["new"])
    }

    @Test func `folder names drop the archive extensions`() {
        #expect(ArchiveExtractor.folderName(for: URL(filePath: "/x/photos.tar.gz")) == "photos")
        #expect(ArchiveExtractor.folderName(for: URL(filePath: "/x/Site.ZIP")) == "Site")
        #expect(ArchiveExtractor.folderName(for: URL(filePath: "/x/app.jar")) == "app")
        #expect(ArchiveExtractor.folderName(for: URL(filePath: "/x/.tar")) == "Archive")
    }

    @Test(arguments: [(ArchiveFormat.zip, "big.zip"), (.tarGzip, "big.tar.gz")])
    func `measures the unpacked size and refuses what does not fit`(format: ArchiveFormat, name: String) async throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        // 8 MB of zeros packs into a few KB: the shape of a zip bomb, in small.
        try Data(count: 8 << 20).write(to: workspace.source.appending(path: "zeros.bin"))
        let archive = workspace.base.appending(path: name)
        let packed = format == .zip
            ? try shell("/usr/bin/ditto", ["-c", "-k", workspace.source.path, archive.path], in: workspace.base)
            : try shell("/usr/bin/tar", ["-c", "-z", "-f", archive.path, "-C", workspace.source.path, "."], in: workspace.base)
        #expect(packed == 0)

        let size = try await ArchiveExtractor.uncompressedSize(of: archive, format: format)
        #expect(size >= 8 << 20 && size < (8 << 20) + 1024)

        await #expect(throws: ArchiveExtractor.Failure.tooLarge(needed: size, available: 1 << 20)) {
            try await ArchiveExtractor.extract(archive, format: format, into: workspace.parent, limit: 1 << 20)
        }
        // Refused before anything was written.
        #expect(workspace.unpackedFolders.isEmpty)
        _ = try await ArchiveExtractor.extract(archive, format: format, into: workspace.parent, limit: 64 << 20)
    }
}
