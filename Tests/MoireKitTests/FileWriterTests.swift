import Foundation
@testable import MoireKit
import Testing

struct FileWriterTests {
    private let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "moire-writer-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func path(_ name: String) -> String { folder.appending(path: name).path(percentEncoded: false) }

    private func inode(_ name: String) throws -> UInt64 {
        try #require(FileManager.default.attributesOfItem(atPath: path(name))[.systemFileNumber] as? UInt64)
    }

    private func clean() {
        try? FileManager.default.removeItem(at: folder)
    }

    @Test func `writes through a symbolic link and keeps the link`() throws {
        defer { clean() }
        try FileManager.default.createDirectory(atPath: path("dotfiles"), withIntermediateDirectories: true)
        try Data("old\n".utf8).write(to: URL(filePath: path("dotfiles/zshrc")))
        try FileManager.default.createSymbolicLink(atPath: path(".zshrc"), withDestinationPath: "dotfiles/zshrc")

        try FileWriter.write(Data("new\n".utf8), to: URL(filePath: path(".zshrc")))

        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: path(".zshrc")) == "dotfiles/zshrc")
        #expect(try String(contentsOfFile: path("dotfiles/zshrc"), encoding: .utf8) == "new\n")
    }

    @Test func `follows a chain of links with absolute and relative targets`() throws {
        defer { clean() }
        try Data("old".utf8).write(to: URL(filePath: path("real.txt")))
        try FileManager.default.createSymbolicLink(atPath: path("middle"), withDestinationPath: path("real.txt"))
        try FileManager.default.createSymbolicLink(atPath: path("first"), withDestinationPath: "middle")

        try FileWriter.write(Data("new".utf8), to: URL(filePath: path("first")))

        #expect(try String(contentsOfFile: path("real.txt"), encoding: .utf8) == "new")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: path("first")) == "middle")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: path("middle")) == path("real.txt"))
    }

    @Test func `creates the file a dangling link points to`() throws {
        defer { clean() }
        try FileManager.default.createSymbolicLink(atPath: path("link"), withDestinationPath: "missing.txt")
        try FileWriter.write(Data("made".utf8), to: URL(filePath: path("link")))
        #expect(try String(contentsOfFile: path("missing.txt"), encoding: .utf8) == "made")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: path("link")) == "missing.txt")
    }

    @Test func `refuses a link that leads back to itself`() throws {
        defer { clean() }
        try FileManager.default.createSymbolicLink(atPath: path("a"), withDestinationPath: "b")
        try FileManager.default.createSymbolicLink(atPath: path("b"), withDestinationPath: "a")
        #expect(throws: FileWriter.Failure.self) { try FileWriter.write(Data("x".utf8), to: URL(filePath: path("a"))) }
    }

    @Test func `keeps hard links together`() throws {
        defer { clean() }
        try Data("old text that is longer\n".utf8).write(to: URL(filePath: path("one.txt")))
        try FileManager.default.linkItem(atPath: path("one.txt"), toPath: path("two.txt"))
        let before = try inode("one.txt")

        try FileWriter.write(Data("new\n".utf8), to: URL(filePath: path("one.txt")))

        #expect(try inode("one.txt") == before)
        #expect(try inode("two.txt") == before)
        #expect(try String(contentsOfFile: path("two.txt"), encoding: .utf8) == "new\n")
    }

    @Test func `replaces a single file as a whole and keeps its permissions`() throws {
        defer { clean() }
        try Data("#!/bin/sh\necho old\n".utf8).write(to: URL(filePath: path("run.sh")))
        try FileManager.default.setAttributes([.posixPermissions: 0o750], ofItemAtPath: path("run.sh"))
        let before = try inode("run.sh")

        try FileWriter.write(Data("#!/bin/sh\necho new\n".utf8), to: URL(filePath: path("run.sh")))

        let attributes = try FileManager.default.attributesOfItem(atPath: path("run.sh"))
        #expect(attributes[.posixPermissions] as? Int == 0o750)
        #expect(try inode("run.sh") != before)
        #expect(try String(contentsOfFile: path("run.sh"), encoding: .utf8) == "#!/bin/sh\necho new\n")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)) == ["run.sh"])
    }

    @Test func `keeps extended attributes`() throws {
        defer { clean() }
        try Data("old".utf8).write(to: URL(filePath: path("tagged.txt")))
        let value = Array("kept".utf8)
        #expect(setxattr(path("tagged.txt"), "io.github.moire.test", value, value.count, 0, 0) == 0)

        try FileWriter.write(Data("new".utf8), to: URL(filePath: path("tagged.txt")))

        var buffer = [UInt8](repeating: 0, count: 16)
        let length = getxattr(path("tagged.txt"), "io.github.moire.test", &buffer, buffer.count, 0, 0)
        #expect(length == value.count)
        #expect(Array(buffer.prefix(max(0, length))) == value)
    }

    @Test func `writes in place in a folder that allows no new files`() throws {
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path(percentEncoded: false))
            clean()
        }
        try Data("old".utf8).write(to: URL(filePath: path("locked.txt")))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path(percentEncoded: false))

        try FileWriter.write(Data("new".utf8), to: URL(filePath: path("locked.txt")))

        #expect(try String(contentsOfFile: path("locked.txt"), encoding: .utf8) == "new")
    }

    @Test func `creates a new file`() throws {
        defer { clean() }
        try FileWriter.write(Data("fresh".utf8), to: URL(filePath: path("new.txt")))
        #expect(try String(contentsOfFile: path("new.txt"), encoding: .utf8) == "fresh")
    }
}
