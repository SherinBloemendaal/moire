import Foundation
@testable import MoireKit
import Testing

private func makeTree(_ files: [String: String], links: [String: String] = [:], dates: [String: Date] = [:]) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(path: "moire-engine-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for (path, contents) in files {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if path.hasSuffix("/") { continue }
        try Data(contents.utf8).write(to: url)
    }
    for (path, destination) in links {
        try FileManager.default.createSymbolicLink(atPath: root.appending(path: path).path(percentEncoded: false), withDestinationPath: destination)
    }
    for (path, date) in dates {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: root.appending(path: path).path(percentEncoded: false))
    }
    return root
}

private func statuses(_ tree: FolderTree) -> [String: FolderTree.Status] {
    Dictionary(uniqueKeysWithValues: (1..<tree.count).map { (tree.path(of: $0), tree.status(of: $0)) })
}

private let fixed = Date(timeIntervalSince1970: 1_700_000_000)

struct DirectoryReaderTests {
    @Test func `lists names, kinds, sizes and dates like FileManager`() throws {
        let root = try makeTree(["a.txt": "hello", "sub/b.txt": "x", ".hidden": "h", "ünïcode é.txt": "u"], links: ["link": "a.txt"], dates: ["a.txt": fixed])
        let entries = try DirectoryReader.entries(of: root.path(percentEncoded: false), skipHidden: false)
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })

        #expect(Set(byName.keys) == Set(try FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false))))
        #expect(byName["a.txt"]?.kind == .file)
        #expect(byName["a.txt"]?.size == 5)
        let expectedDate: Int64 = 1_700_000_000_000_000_000
        #expect(byName["a.txt"]?.modified == expectedDate)
        #expect(byName["sub"]?.kind == .directory)
        #expect(byName["link"]?.kind == .symbolicLink)
        #expect(byName["a.txt"]?.fileID != byName["sub"]?.fileID)
    }

    @Test func `skips hidden names when asked`() throws {
        let root = try makeTree([".hidden": "h", "shown": "s"])
        #expect(try DirectoryReader.entries(of: root.path(percentEncoded: false), skipHidden: true).map(\.name) == ["shown"])
    }

    @Test func `lists a folder bigger than one read buffer`() throws {
        var files: [String: String] = [:]
        for index in 0..<3000 { files[String(format: "file-with-a-fairly-long-name-%05d.txt", index)] = "" }
        let root = try makeTree(files)
        #expect(try DirectoryReader.entries(of: root.path(percentEncoded: false), skipHidden: true).count == 3000)
    }

    @Test func `throws for a folder that does not exist`() {
        #expect(throws: POSIXError.self) { try DirectoryReader.entries(of: "/no/such/folder", skipHidden: true) }
    }
}

struct FolderEngineMetadataTests {
    private func compare(_ left: URL, _ right: URL, _ settings: FolderCompareSettings = FolderCompareSettings(method: .metadata)) throws -> FolderTree {
        try FolderEngine(left: left, right: right, settings: settings).run()
    }

    @Test func `compares by size and date without reading contents`() throws {
        let left = try makeTree(["same.txt": "aaaa", "touched.txt": "aaaa", "resized.txt": "a", "sub/deep.txt": "1"], dates: ["same.txt": fixed, "touched.txt": fixed, "resized.txt": fixed, "sub/deep.txt": fixed])
        // Same size and date, different bytes: metadata cannot see that, by design.
        let right = try makeTree(["same.txt": "bbbb", "touched.txt": "aaaa", "resized.txt": "ab", "sub/deep.txt": "1"], dates: ["same.txt": fixed, "touched.txt": fixed.addingTimeInterval(60), "resized.txt": fixed, "sub/deep.txt": fixed])

        #expect(try statuses(compare(left, right)) == [
            "sub": .identical, "sub/deep.txt": .identical,
            "resized.txt": .different, "same.txt": .identical, "touched.txt": .different,
        ])
    }

    @Test func `allows two seconds and a daylight saving hour`() throws {
        let names = ["fat.txt", "hour.txt", "far.txt"]
        let left = try makeTree(Dictionary(uniqueKeysWithValues: names.map { ($0, "x") }), dates: Dictionary(uniqueKeysWithValues: names.map { ($0, fixed) }))
        let right = try makeTree(Dictionary(uniqueKeysWithValues: names.map { ($0, "x") }), dates: [
            "fat.txt": fixed.addingTimeInterval(2), "hour.txt": fixed.addingTimeInterval(3601), "far.txt": fixed.addingTimeInterval(3),
        ])

        #expect(try statuses(compare(left, right)) == ["fat.txt": .identical, "hour.txt": .identical, "far.txt": .different])
        var strict = FolderCompareSettings(method: .metadata, allowsHourShift: false)
        strict.dateTolerance = 0
        #expect(try statuses(compare(left, right, strict)) == ["fat.txt": .different, "hour.txt": .different, "far.txt": .different])
    }

    @Test func `lists the contents of folders that exist on one side only`() throws {
        let left = try makeTree(["gone/a.txt": "1", "gone/inner/b.txt": "2", "kept.txt": "k"], dates: ["kept.txt": fixed])
        let right = try makeTree(["new/c.txt": "3", "kept.txt": "k"], dates: ["kept.txt": fixed])

        #expect(try statuses(compare(left, right)) == [
            "gone": .leftOnly, "gone/inner": .leftOnly, "gone/inner/b.txt": .leftOnly, "gone/a.txt": .leftOnly,
            "new": .rightOnly, "new/c.txt": .rightOnly, "kept.txt": .identical,
        ])
    }

    @Test func `marks folders by what is inside them`() throws {
        let left = try makeTree(["a/b/c.txt": "1", "a/same.txt": "s"], dates: ["a/b/c.txt": fixed, "a/same.txt": fixed])
        let right = try makeTree(["a/b/c.txt": "22", "a/same.txt": "s"], dates: ["a/b/c.txt": fixed, "a/same.txt": fixed])
        let result = statuses(try compare(left, right))
        #expect(result["a"] == .different)
        #expect(result["a/b"] == .different)
        #expect(result["a/same.txt"] == .identical)
    }

    @Test func `orders folders first and children right after their folder`() throws {
        let tree = try makeTree(["b.txt": "", "a/z.txt": "", "c/x.txt": "", "A2.txt": "", "file10.txt": "", "file9.txt": ""])
        let result = try compare(tree, tree)
        #expect(result.children(of: 0).map { result.name(of: $0) } == ["a", "c", "A2.txt", "b.txt", "file9.txt", "file10.txt"])
        for item in 1..<result.count {
            let parent = try #require(result.parent(of: item))
            #expect(result.children(of: parent).contains(item))
        }
    }

    @Test func `treats a file against a folder as a difference and lists the folder`() throws {
        let left = try makeTree(["thing": "file"])
        let right = try makeTree(["thing/inside.txt": "x"])
        let result = try compare(left, right)
        // The folder's contents are listed, so a sync that replaces the file knows what to copy.
        #expect(statuses(result) == ["thing": .different, "thing/inside.txt": .rightOnly])
        #expect(result.differenceCount == 2)
    }

    @Test func `compares symbolic links by destination and never follows them`() throws {
        let left = try makeTree(["a.txt": "x"], links: ["loop": ".", "link": "a.txt"], dates: ["a.txt": fixed])
        let right = try makeTree(["a.txt": "x"], links: ["loop": ".", "link": "b.txt"], dates: ["a.txt": fixed])
        let result = statuses(try compare(left, right))
        #expect(result["loop"] == .identical)
        #expect(result["link"] == .different)
    }

    @Test func `matches names written in decomposed form`() throws {
        let left = try makeTree(["caf\u{E9}.txt": "x"], dates: ["caf\u{E9}.txt": fixed])
        let right = try makeTree(["cafe\u{301}.txt": "x"], dates: ["cafe\u{301}.txt": fixed])
        #expect(try compare(left, right).differenceCount == 0)
    }

    @Test func `gives the same answer with one thread or many`() throws {
        var files: [String: String] = [:]
        var changed: [String: String] = [:]
        for index in 0..<2000 {
            let path = "d\(index % 37)/e\(index % 5)/f\(index).txt"
            files[path] = String(index)
            changed[path] = index % 13 == 0 ? String(index) + "!" : String(index)
        }
        let left = try makeTree(files)
        let right = try makeTree(changed)
        let one = try compare(left, right, FolderCompareSettings(method: .metadata, folderThreads: 1))
        let many = try compare(left, right, FolderCompareSettings(method: .metadata, folderThreads: 16))
        #expect(statuses(one) == statuses(many))
        #expect(one.differenceCount == many.differenceCount)
    }

    @Test func `marks a folder it cannot read and carries on`() throws {
        let left = try makeTree(["locked/a.txt": "1", "open.txt": "o"], dates: ["open.txt": fixed])
        let right = try makeTree(["locked/a.txt": "1", "open.txt": "o"], dates: ["open.txt": fixed])
        let locked = left.appending(path: "locked").path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked) }

        let result = try compare(left, right)
        let item = try #require((1..<result.count).first { result.path(of: $0) == "locked" })
        #expect(result.status(of: item) == .unreadable)
        #expect(result.error(at: item) != nil)
        #expect(statuses(result)["open.txt"] == .identical)
    }

    @Test func `stops when cancelled`() throws {
        var files: [String: String] = [:]
        for index in 0..<500 { files["d\(index)/f.txt"] = "x" }
        let tree = try makeTree(files)
        let engine = FolderEngine(left: tree, right: tree, settings: FolderCompareSettings(method: .metadata, folderThreads: 1))
        engine.cancel()
        #expect(throws: CancellationError.self) { try engine.run() }
    }

    @Test func `picks metadata only when a folder is on a network disk`() throws {
        let local = Volume(fileSystem: "apfs", isLocal: true)
        let share = Volume(fileSystem: "smbfs", isLocal: false)
        #expect(FolderCompareSettings.defaultMethod(left: local, right: local) == .binary)
        #expect(FolderCompareSettings.defaultMethod(left: local, right: share) == .metadata)
        #expect(FolderCompareSettings.defaultMethod(left: share, right: local, otherwise: .lines) == .metadata)
        #expect(try Volume.of(NSTemporaryDirectory()).isLocal)
    }
}

struct FolderEngineContentTests {
    private func compare(_ left: URL, _ right: URL, _ method: CompareMethod, options: DiffOptions = DiffOptions()) throws -> FolderTree {
        try FolderEngine(left: left, right: right, settings: FolderCompareSettings(method: method, diffOptions: options)).run()
    }

    @Test(arguments: [CompareMethod.quick, .binary, .lines])
    func `finds a changed byte in a small file even when size and date match`(method: CompareMethod) throws {
        let left = try makeTree(["a.txt": "hello world", "same.txt": "same"], dates: ["a.txt": fixed])
        let right = try makeTree(["a.txt": "hello World", "same.txt": "same"], dates: ["a.txt": fixed])
        #expect(try statuses(compare(left, right, method)) == ["a.txt": .different, "same.txt": .identical])
    }

    @Test func `quick reads only the start and end of big files`() throws {
        let size = 512 * 1024
        var bytes = [UInt8](repeating: 65, count: size)
        let left = try makeTree([:])
        let right = try makeTree([:])
        try Data(bytes).write(to: left.appending(path: "middle.bin"))
        try Data(bytes).write(to: left.appending(path: "end.bin"))
        bytes[size / 2] = 66
        try Data(bytes).write(to: right.appending(path: "middle.bin"))
        bytes[size / 2] = 65
        bytes[size - 1] = 66
        try Data(bytes).write(to: right.appending(path: "end.bin"))

        // A change in the middle of a big file is what Quick trades away for speed.
        #expect(try statuses(compare(left, right, .quick)) == ["middle.bin": .identical, "end.bin": .different])
        #expect(try statuses(compare(left, right, .binary)) == ["middle.bin": .different, "end.bin": .different])
    }

    @Test func `binary compares files bigger than one read chunk`() throws {
        let size = (1 << 20) * 3 + 123
        var bytes = [UInt8](repeating: 7, count: size)
        let left = try makeTree([:])
        let right = try makeTree([:])
        try Data(bytes).write(to: left.appending(path: "big.bin"))
        try Data(bytes).write(to: left.appending(path: "same.bin"))
        try Data(bytes).write(to: right.appending(path: "same.bin"))
        bytes[size - 1] = 8
        try Data(bytes).write(to: right.appending(path: "big.bin"))
        #expect(try statuses(compare(left, right, .binary)) == ["big.bin": .different, "same.bin": .identical])
    }

    @Test func `binary never reads files of different sizes`() throws {
        let left = try makeTree(["a.txt": "short"])
        let right = try makeTree(["a.txt": "longer"])
        let locked = right.appending(path: "a.txt").path(percentEncoded: false)
        // Unreadable on purpose: a read would turn the result into an error.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked) }
        #expect(try statuses(compare(left, right, .binary)) == ["a.txt": .different])
    }

    @Test func `lines applies the ignore options and counts changed lines`() throws {
        let left = try makeTree(["spaces.txt": "a b\nc\n", "real.txt": "one\ntwo\nthree\n"])
        let right = try makeTree(["spaces.txt": "a  b  \nc\n", "real.txt": "one\n2\nthree\nfour\n"])
        let tree = try compare(left, right, .lines, options: DiffOptions(whitespace: .ignoreAll))
        #expect(statuses(tree) == ["spaces.txt": .identical, "real.txt": .different])
        let real = try #require((1..<tree.count).first { tree.path(of: $0) == "real.txt" })
        #expect(tree.changedLines(of: real) == 2)
    }

    @Test func `marks a file it cannot read as unreadable`() throws {
        let left = try makeTree(["secret.txt": "a"])
        let right = try makeTree(["secret.txt": "b"])
        let locked = left.appending(path: "secret.txt").path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked) }
        let tree = try compare(left, right, .binary)
        #expect(statuses(tree) == ["secret.txt": .unreadable])
        #expect(tree.error(at: 1) != nil)
    }
}

struct FolderEngineProgressTests {
    private func bigTree(changed: Bool) throws -> URL {
        var files: [String: String] = [:]
        for index in 0..<3000 { files["d\(index % 40)/e\(index % 7)/f\(index).txt"] = changed && index % 11 == 0 ? "changed \(index)" : "file \(index)" }
        return try makeTree(files)
    }

    @Test func `counts every folder, item and file it reads`() throws {
        let left = try bigTree(changed: false)
        let right = try bigTree(changed: true)
        let engine = FolderEngine(left: left, right: right, settings: FolderCompareSettings(method: .binary))
        let tree = try engine.run()
        let progress = engine.progress

        #expect(progress.itemsFound == tree.count - 1)
        #expect(progress.foldersListed == (1..<tree.count).count { tree.isDirectory($0) } + 1)
        #expect(progress.filesRead == progress.filesToRead)
        #expect(progress.bytesRead == progress.bytesToRead)
        #expect(progress.filesToRead > 0)
    }

    @Test func `shows unfinished work and growing counts while it runs`() async throws {
        var files: [String: String] = [:]
        for index in 0..<12 { files["d\(index % 3)/f\(index).txt"] = "file \(index)" }
        let left = try makeTree(files)
        // Same size, so the changed file is read too.
        files["d1/f4.txt"] = "fixe 4"
        let right = try makeTree(files)
        let gate = DispatchSemaphore(value: 0)
        let engine = FolderEngine(
            sources: { (GatedSource(inner: try LocalSource(left), gate: gate), try LocalSource(right)) },
            settings: FolderCompareSettings(method: .binary, contentThreads: 1)
        )
        let running = Task.detached { try engine.run() }

        // The folders are listed without the gate; every file read waits for it.
        try await waitFor { engine.progress.foldersListed == 4 && engine.progress.filesToRead == 12 }
        let open = engine.snapshot()
        #expect(open.status(of: 0) == .pending)
        #expect((1..<open.count).filter { open.isDirectory($0) }.allSatisfy { open.status(of: $0) == .pending })
        #expect((1..<open.count).filter { !open.isDirectory($0) }.allSatisfy { open.status(of: $0) == .pending })
        #expect(engine.progress.filesRead == 0)
        #expect(engine.progress.bytesRead == 0)

        var previous = engine.progress
        for released in 1...6 {
            gate.signal()
            // Files and bytes are counted one after the other, so wait for both.
            try await waitFor { engine.progress.filesRead == released && engine.progress.bytesRead > previous.bytesRead }
            let now = engine.progress
            #expect(now.filesRead == released)
            #expect(now.filesToRead == 12)
            previous = now
        }
        let half = engine.snapshot()
        let decided = (1..<half.count).filter { !half.isDirectory($0) && half.status(of: $0) != .pending }
        #expect(decided.count == 6)
        // Which files come first depends on the threads, so each folder is checked against its own files.
        #expect(decided.contains { half.status(of: $0) == .identical })
        for folder in [0] + (1..<half.count).filter({ half.isDirectory($0) }) {
            let inside = half.children(of: folder).map { half.status(of: $0) }
            let expected: FolderTree.Status = inside.contains(.different) ? .different : inside.contains(.pending) ? .pending : .identical
            #expect(half.status(of: folder) == expected, "\(half.path(of: folder))")
        }
        // A folder is never called identical while something inside it is still open.
        for item in 0..<half.count where half.status(of: item) == .pending {
            var parent = half.parent(of: item)
            while let current = parent {
                #expect(half.status(of: current) != .identical)
                parent = half.parent(of: current)
            }
        }

        for _ in 0..<6 { gate.signal() }
        let final = try await running.value
        #expect(engine.progress.filesRead == 12)
        #expect(final.differenceCount == 1)
        #expect((0..<final.count).allSatisfy { final.status(of: $0) != .pending })
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }
}

/// A local folder whose file reads each wait for one signal of `gate`.
private struct GatedSource: FolderSource {
    let inner: LocalSource
    let gate: DispatchSemaphore

    var displayName: String { inner.displayName }
    var volume: Volume { inner.volume }
    func list(_ path: String, skipHidden: Bool) throws -> [DirectoryEntry] { try inner.list(path, skipHidden: skipHidden) }
    func open(_ path: String) throws -> any ReadableFile {
        gate.wait()
        return try inner.open(path)
    }
    func linkDestination(_ path: String) throws -> String { try inner.linkDestination(path) }
    func localURL(_ path: String) -> URL? { inner.localURL(path) }
}

struct ThreadTuningTests {
    @Test func `uses half the performance cores, between 4 and 8, on local disks`() {
        #expect(ThreadTuning.localThreads(performanceCores: 2) == 4)
        #expect(ThreadTuning.localThreads(performanceCores: 8) == 4)
        #expect(ThreadTuning.localThreads(performanceCores: 12) == 6)
        #expect(ThreadTuning.localThreads(performanceCores: 16) == 8)
        #expect(ThreadTuning.localThreads(performanceCores: 24) == 8)
        let threads = ThreadTuning.threads(performanceCores: 12, isLocal: true, items: 0, maxVnodes: 1_000_000)
        #expect(threads.folders == 6)
        #expect(threads.contents == 6)
    }

    @Test func `uses 8 threads for a network disk however big the tree`() {
        for items in [0, 10_000_000] {
            let threads = ThreadTuning.threads(performanceCores: 4, isLocal: false, items: items, maxVnodes: 100)
            #expect(threads.folders == 8)
            #expect(threads.contents == 8)
        }
    }

    @Test func `grows once a tree outgrows half the vnode cache`() {
        #expect(ThreadTuning.bigTree(maxVnodes: 500_000) == 250_000)
        #expect(ThreadTuning.bigTree(maxVnodes: 0) == 131_072)
        let below = ThreadTuning.threads(performanceCores: 10, isLocal: true, items: 249_999, maxVnodes: 500_000)
        #expect(below.folders == 5)
        #expect(below.contents == 5)
        let above = ThreadTuning.threads(performanceCores: 10, isLocal: true, items: 250_000, maxVnodes: 500_000)
        #expect(above.folders == 16)
        #expect(above.contents == 32)
    }

    @Test func `starts the engine with the tuned counts for this machine`() {
        let local = Volume(fileSystem: "apfs", isLocal: true)
        let share = Volume(fileSystem: "smbfs", isLocal: false)
        let expected = ThreadTuning.localThreads(performanceCores: FolderEngine.performanceCores)
        #expect(FolderEngine.folderThreads(left: local, right: local) == expected)
        #expect(FolderEngine.contentThreads(left: local, right: local) == expected)
        #expect(FolderEngine.folderThreads(left: local, right: share) == 8)
        #expect(FolderEngine.contentThreads(left: share, right: local) == 8)
        #expect(FolderEngine.performanceCores > 0)
        #expect(FolderEngine.maxVnodes > 0)
        #expect(FolderEngine.bigTree == FolderEngine.maxVnodes / 2)
    }
}

struct LocalFileCacheTests {
    private func sparseFile(size: Int64) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "moire-nocache-\(UUID().uuidString).bin")
        try Data().write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(size))
        try handle.close()
        return url
    }

    @Test func `bypasses the file cache only for big files`() throws {
        let folder = FileManager.default.temporaryDirectory
        for (size, uncached) in [(Int64(4096), false), (LocalFile.uncachedFrom - 1, false), (LocalFile.uncachedFrom, true)] {
            let url = try sparseFile(size: size)
            defer { try? FileManager.default.removeItem(at: url) }
            let file = try #require(try LocalSource(folder).open(url.lastPathComponent) as? LocalFile)
            #expect(file.size == size)
            #expect(file.bypassesCache == uncached, "\(size) bytes")
            #expect(try file.read(at: size - 4, count: 8) == Data(count: 4))
        }
    }
}

struct FolderTreeStorageTests {
    @Test func `stays under 64 bytes per item`() {
        var tree = FolderTree()
        let folder = FolderTree.SideInfo(kind: .directory, size: 0, modified: 0, fileID: 0)
        let folders = (0..<40).map { FolderTree.Child(name: String(format: "dir%05d", $0), left: folder, right: folder, status: .pending) }
        _ = tree.appendChildren(folders, to: 0)
        for parent in 1...40 {
            let files = (0..<100).map { index in
                let file = FolderTree.SideInfo(kind: .file, size: Int64(index), modified: 1, fileID: 0)
                return FolderTree.Child(name: String(format: "f%03d.txt", index), left: file, right: file, status: .identical)
            }
            _ = tree.appendChildren(files, to: Int32(parent))
        }
        #expect(tree.count == 4041)
        // 54 bytes of fixed fields plus 8 bytes of name is the 62 the README promises; a new
        // field of 2 bytes or more per item breaks the limit.
        #expect(Double(tree.storageBytes) / Double(tree.count) < 64)
    }
}

struct ResultCacheTests {
    private func cacheFile() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "moire-cache-\(UUID().uuidString).cache")
    }

    @Test func `reuses results without reading unchanged files again`() throws {
        let left = try makeTree(["same.txt": "same", "other.txt": "a"], dates: ["same.txt": fixed, "other.txt": fixed])
        let right = try makeTree(["same.txt": "same", "other.txt": "b"], dates: ["same.txt": fixed, "other.txt": fixed])
        let file = cacheFile()
        let first = ResultCache(file: file)
        _ = try FolderEngine(left: left, right: right, settings: FolderCompareSettings(method: .binary), cache: first).run()
        try first.save()

        // Unreadable now, but size and date are unchanged: the cached answer is used, so no read happens.
        let locked = left.appending(path: "same.txt").path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked) }

        let second = ResultCache(file: file)
        #expect(second.count == 2)
        let engine = FolderEngine(left: left, right: right, settings: FolderCompareSettings(method: .binary), cache: second)
        #expect(try statuses(engine.run()) == ["same.txt": .identical, "other.txt": .different])
        #expect(engine.progress.filesToRead == 0)
    }

    @Test func `reads a file again once its size or date changed`() throws {
        let left = try makeTree(["a.txt": "same"], dates: ["a.txt": fixed])
        let right = try makeTree(["a.txt": "same"], dates: ["a.txt": fixed])
        let file = cacheFile()
        let first = ResultCache(file: file)
        _ = try FolderEngine(left: left, right: right, settings: FolderCompareSettings(method: .binary), cache: first).run()
        try first.save()

        try Data("diff".utf8).write(to: right.appending(path: "a.txt"))
        let engine = FolderEngine(left: left, right: right, settings: FolderCompareSettings(method: .binary), cache: ResultCache(file: file))
        #expect(try statuses(engine.run()) == ["a.txt": .different])
        #expect(engine.progress.filesToRead == 1)
    }

    @Test func `keeps the changed line count`() throws {
        let left = try makeTree(["a.txt": "one\ntwo\n"])
        let right = try makeTree(["a.txt": "one\nthree\nfour\n"])
        let file = cacheFile()
        let first = ResultCache(file: file)
        _ = try FolderEngine(left: left, right: right, settings: FolderCompareSettings(method: .lines), cache: first).run()
        try first.save()
        let tree = try FolderEngine(left: left, right: right, settings: FolderCompareSettings(method: .lines), cache: ResultCache(file: file)).run()
        #expect(tree.changedLines(of: 1) == 2)
    }

    @Test func `round trips its file and ignores a damaged one`() throws {
        let entries: [ResultCache.Key: ResultCache.Entry] = [
            .init(left: 1, right: 2): .init(leftSize: 10, leftModified: -5, rightSize: 11, rightModified: 1 << 60, verdict: .identical),
            .init(left: 3, right: 4): .init(leftSize: 0, leftModified: 0, rightSize: 0, rightModified: 0, verdict: .differentLines(7)),
        ]
        let data = ResultCache.encode(entries)
        #expect(ResultCache.decode(data) == entries)
        #expect(ResultCache.decode(data.dropLast()) == nil)
        #expect(ResultCache.decode(Data("not a cache".utf8)) == nil)

        let file = cacheFile()
        try Data("garbage".utf8).write(to: file)
        #expect(ResultCache(file: file).count == 0)
    }

    @Test func `uses one file per pair of folders and way of comparing`() {
        let a = URL(filePath: "/a"), b = URL(filePath: "/b")
        let binary = ResultCache.file(left: a, right: b, settings: FolderCompareSettings(method: .binary))
        #expect(binary == ResultCache.file(left: a, right: b, settings: FolderCompareSettings(method: .binary)))
        #expect(binary != ResultCache.file(left: b, right: a, settings: FolderCompareSettings(method: .binary)))
        #expect(binary != ResultCache.file(left: a, right: b, settings: FolderCompareSettings(method: .quick)))
        #expect(
            ResultCache.file(left: a, right: b, settings: FolderCompareSettings(method: .lines))
                != ResultCache.file(left: a, right: b, settings: FolderCompareSettings(method: .lines, diffOptions: DiffOptions(ignoreCase: true)))
        )
    }
}
