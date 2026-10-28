import Foundation
import Testing

/// Finds the built `moire-cli` next to this test bundle: SwiftPM puts every product of the package in the same
/// build folder as `MoirePackageTests.xctest`, and the test target depends on `MoireCLI` so it is built first.
/// Asking `swift build --show-bin-path` instead would start a second build while `swift test` holds the lock.
private final class BundleMarker {}

private let binary = Bundle(for: BundleMarker.self).bundleURL.deletingLastPathComponent().appending(path: "moire-cli")

private struct Run {
    let status: Int32
    let output: String
    let errors: String
}

private func moire(_ arguments: [String]) throws -> Run {
    try #require(FileManager.default.isExecutableFile(atPath: binary.path(percentEncoded: false)), "no moire-cli at \(binary.path(percentEncoded: false))")
    let process = Process()
    process.executableURL = binary
    process.arguments = arguments
    let output = Pipe()
    let errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    process.standardInput = FileHandle.nullDevice
    try process.run()
    // Read before waiting, so a full pipe cannot block the child.
    let out = output.fileHandleForReading.readDataToEndOfFile()
    let err = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return Run(status: process.terminationStatus, output: String(decoding: out, as: UTF8.self), errors: String(decoding: err, as: UTF8.self))
}

private let old = Date(timeIntervalSince1970: 1_700_000_000)
private let new = old.addingTimeInterval(3 * 3600)

private func folder(_ files: [String: (String, Date)]) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(path: "moire-cli-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
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
        let relative = url.standardizedFileURL.path(percentEncoded: false).dropFirst(root.standardizedFileURL.path(percentEncoded: false).count)
        result[String(relative.drop { $0 == "/" })] = try String(contentsOf: url, encoding: .utf8)
    }
    return result
}

private func path(_ url: URL) -> String { url.path(percentEncoded: false) }

struct CommandLineTests {
    @Test func `help prints the usage to standard output and exits 0`() throws {
        for arguments in [["--help"], ["-h"], ["compare", "--help"]] {
            let run = try moire(arguments)
            #expect(run.status == 0, "\(arguments)")
            #expect(run.output.hasPrefix("usage: moire compare LEFT RIGHT"), "\(arguments)")
            #expect(run.errors.isEmpty, "\(arguments)")
        }
    }

    @Test func `no arguments prints the usage as an error and exits 2`() throws {
        let run = try moire([])
        #expect(run.status == 2)
        #expect(run.output.isEmpty)
        #expect(run.errors.contains("usage: moire compare LEFT RIGHT"))
    }

    @Test func `an unknown option or command exits 2 and names it`() throws {
        let files = try folder(["a.txt": ("a\n", old), "b.txt": ("a\n", old)])
        let option = try moire(["compare", path(files.appending(path: "a.txt")), path(files.appending(path: "b.txt")), "--frobnicate"])
        #expect(option.status == 2)
        #expect(option.errors.contains("unknown option --frobnicate"))

        let command = try moire(["frobnicate"])
        #expect(command.status == 2)
        #expect(command.errors.contains("unknown command frobnicate"))
    }

    @Test func `a missing path or a bad value exits 2 with a message`() throws {
        let files = try folder(["a.txt": ("a\n", old)])
        let missing = try moire(["compare", path(files.appending(path: "a.txt")), path(files.appending(path: "gone.txt"))])
        #expect(missing.status == 2)
        #expect(missing.errors.contains("gone.txt does not exist"))

        let method = try moire(["compare", path(files), path(files), "--method", "psychic"])
        #expect(method.status == 2)
        #expect(method.errors.contains("unknown method psychic"))

        let value = try moire(["compare", path(files), path(files), "--format"])
        #expect(value.status == 2)
        #expect(value.errors.contains("--format needs a value"))

        let mixed = try moire(["compare", path(files), path(files.appending(path: "a.txt"))])
        #expect(mixed.status == 2)
        #expect(mixed.errors.contains("not one of each"))
    }

    @Test func `two equal text files exit 0 and print nothing`() throws {
        let files = try folder(["a.txt": ("same\nlines\n", old), "b.txt": ("same\nlines\n", new)])
        let run = try moire(["compare", path(files.appending(path: "a.txt")), path(files.appending(path: "b.txt"))])
        #expect(run.status == 0)
        #expect(run.output.isEmpty)
        #expect(run.errors.isEmpty)
    }

    @Test func `two different text files exit 1 and print a unified diff`() throws {
        let files = try folder(["a.txt": ("one\ntwo\nthree\n", old), "b.txt": ("one\nTWO\nthree\n", old)])
        let left = path(files.appending(path: "a.txt"))
        let right = path(files.appending(path: "b.txt"))
        let run = try moire(["compare", left, right])
        #expect(run.status == 1)
        #expect(run.output.contains("--- \(left)"))
        #expect(run.output.contains("+++ \(right)"))
        #expect(run.output.contains("\n-two\n"))
        #expect(run.output.contains("\n+TWO\n"))
        #expect(run.output.contains("\n one\n"))
    }

    @Test func `ignore case makes files that differ only in case equal`() throws {
        let files = try folder(["a.txt": ("Hello\n", old), "b.txt": ("hello\n", old)])
        let run = try moire(["compare", path(files.appending(path: "a.txt")), path(files.appending(path: "b.txt")), "--ignore-case"])
        #expect(run.status == 0)
        #expect(run.output.isEmpty)
    }

    @Test func `json for two files counts the changes`() throws {
        let files = try folder(["a.txt": ("one\ntwo\n", old), "b.txt": ("one\nTWO\nthree\n", old)])
        let run = try moire(["compare", path(files.appending(path: "a.txt")), path(files.appending(path: "b.txt")), "--format", "json"])
        #expect(run.status == 1)
        let summary = try JSONDecoder().decode([String: Int].self, from: Data(run.output.utf8))
        #expect(summary["changed"] == 1)
        #expect(summary["added"] == 1)
        #expect(summary["removed"] == 0)
    }

    @Test func `two different binary files exit 1 and say so`() throws {
        let files = try folder([:])
        try Data([0, 1, 2, 0]).write(to: files.appending(path: "a.bin"))
        try Data([0, 1, 3, 0]).write(to: files.appending(path: "b.bin"))
        let run = try moire(["compare", path(files.appending(path: "a.bin")), path(files.appending(path: "b.bin"))])
        #expect(run.status == 1)
        #expect(run.output.hasPrefix("Binary files"))
        #expect(run.output.hasSuffix("differ\n"))
    }

    @Test func `two equal folders exit 0`() throws {
        let left = try folder(["a.txt": ("a", old), "sub/b.txt": ("b", old)])
        let right = try folder(["a.txt": ("a", old), "sub/b.txt": ("b", old)])
        let run = try moire(["compare", path(left), path(right), "--no-cache"])
        #expect(run.status == 0)
        #expect(run.output.contains("= a.txt"))
        #expect(run.output.contains("0 different, 0 left only, 0 right only"))
    }

    @Test func `two different folders exit 1 and list each difference`() throws {
        let left = try folder(["same.txt": ("s", old), "changed.txt": ("left", old), "only-left.txt": ("l", old), "sub/deep.txt": ("d", old)])
        let right = try folder(["same.txt": ("s", old), "changed.txt": ("right", old), "only-right.txt": ("r", old)])
        let run = try moire(["compare", path(left), path(right), "--no-cache"])
        #expect(run.status == 1)
        let lines = Set(run.output.split(separator: "\n").map(String.init))
        #expect(lines.contains("= same.txt"))
        #expect(lines.contains("≠ changed.txt"))
        #expect(lines.contains("< only-left.txt"))
        #expect(lines.contains("> only-right.txt"))
        #expect(lines.contains("< sub/"))
        #expect(run.output.contains("1 different, 2 left only, 1 right only"))

        let differences = try moire(["compare", path(left), path(right), "--no-cache", "--differences"])
        #expect(differences.status == 1)
        #expect(!differences.output.contains("same.txt"))
        #expect(differences.output.contains("changed.txt"))
    }

    @Test func `output writes the report to a file instead of standard output`() throws {
        let left = try folder(["a.txt": ("a", old)])
        let right = try folder(["a.txt": ("b", old)])
        let report = try folder([:]).appending(path: "report.html")
        let run = try moire(["compare", path(left), path(right), "--no-cache", "--format", "html", "--output", path(report)])
        #expect(run.status == 1)
        #expect(run.output.isEmpty)
        let page = try String(contentsOf: report, encoding: .utf8)
        #expect(page.hasPrefix("<!doctype html>"))
        #expect(page.contains("a.txt"))
    }

    @Test func `sync dry run prints the plan and changes nothing`() throws {
        let left = try folder(["missing.txt": ("m", old), "newer.txt": ("left new", new), "deep/a.txt": ("a", old)])
        let right = try folder(["newer.txt": ("right old", old), "extra.txt": ("e", old)])
        let before = (try contents(left), try contents(right))
        let run = try moire(["sync", path(left), path(right), "--dry-run"])

        #expect(run.status == 1)
        #expect(run.output.contains("copy → missing.txt"))
        #expect(run.output.contains("copy → newer.txt"))
        #expect(run.output.contains("new folder on the right: deep/"))
        #expect(run.output.contains("3 to copy"))
        #expect(!run.output.contains("Done."))
        #expect(try contents(left) == before.0)
        #expect(try contents(right) == before.1)
    }

    @Test func `sync without yes and without a terminal refuses and changes nothing`() throws {
        let left = try folder(["missing.txt": ("m", old)])
        let right = try folder([:])
        let run = try moire(["sync", path(left), path(right)])
        #expect(run.status == 2)
        #expect(run.errors.contains("not syncing without --yes"))
        #expect(try contents(right).isEmpty)
    }

    @Test func `sync with yes makes the folders equal`() throws {
        let left = try folder(["missing.txt": ("m", old), "newer.txt": ("left new", new), "deep/a.txt": ("a", old)])
        let right = try folder(["newer.txt": ("right old", old)])
        let run = try moire(["sync", path(left), path(right), "--yes"])

        #expect(run.status == 0)
        #expect(run.output.hasSuffix("Done.\n"))
        #expect(run.errors.isEmpty)
        #expect(try contents(right) == contents(left))
        let again = try moire(["compare", path(left), path(right), "--no-cache"])
        #expect(again.status == 0)
        #expect(try moire(["sync", path(left), path(right), "--yes"]).output == "Nothing to do.\n")
    }

    @Test func `sync both ways copies the newer file to each side`() throws {
        let left = try folder(["l.txt": ("left only", old), "a.txt": ("left newer", new)])
        let right = try folder(["r.txt": ("right only", old), "a.txt": ("right older", old)])
        let run = try moire(["sync", path(left), path(right), "--direction", "both", "--yes"])
        #expect(run.status == 0)
        #expect(try contents(left) == ["l.txt": "left only", "r.txt": "right only", "a.txt": "left newer"])
        #expect(try contents(right) == contents(left))
    }

    @Test func `sync refuses two files`() throws {
        let files = try folder(["a.txt": ("a", old), "b.txt": ("b", old)])
        let run = try moire(["sync", path(files.appending(path: "a.txt")), path(files.appending(path: "b.txt")), "--yes"])
        #expect(run.status == 2)
        #expect(run.errors.contains("sync works on folders"))
        #expect(try String(contentsOf: files.appending(path: "b.txt"), encoding: .utf8) == "b")
    }
}
