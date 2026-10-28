import Darwin
import Foundation
import Synchronization

/// Deterministic pseudo random numbers, so every run builds byte for byte the same trees.
struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func next(in range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.count))
    }
}

/// What a generated pair of folders contains, so a benchmark can check the engine's answer.
struct Manifest: Codable, Equatable {
    var version: Int
    var kind: String
    var files: Int
    var leftOnly: Int
    var rightOnly: Int
    var changedSameSize: Int
    var changedSize: Int
    var totalBytes: Int64

    var differences: Int { leftOnly + rightOnly + changedSameSize + changedSize }
}

/// A pair of folders on disk: `left`, and `right` cloned from it with known changes.
struct Dataset {
    static let version = 2
    /// Every file gets this date, and a changed file this date plus a minute, so comparing by
    /// date sees exactly the generated changes.
    static let baseDate = timespec(tv_sec: 1_700_000_000, tv_nsec: 0)
    static let changedDate = timespec(tv_sec: 1_700_000_060, tv_nsec: 0)

    let root: URL
    let manifest: Manifest

    var left: URL { root.appending(path: "left") }
    var right: URL { root.appending(path: "right") }

    private static let words = [
        "let", "var", "func", "return", "struct", "import", "self", "guard", "else", "true", "false",
        "invoice", "customer", "total", "amount", "line", "date", "value", "count", "index", "name",
        "{", "}", "(", ")", "=", "+", "-", ".", ",", ":", "//", "0", "1", "42", "100",
    ]

    /// A tree of `files` small text files: 100 per folder, 20 folders per top folder. The right
    /// side is an APFS clone of the left (sharing its blocks), then changed:
    /// - every 200th file (at offset 17) is missing on the right,
    /// - every 100th file (at offset 7) has one letter changed, keeping its size,
    /// - every 200th file (at offset 13) has a line added,
    /// - one extra file per 200 exists only on the right.
    static func tree(files: Int, in base: URL) throws -> Dataset {
        let root = base.appending(path: "tree-\(files)")
        if let existing = try load(root, kind: "tree", files: files) { return existing }
        try reset(root)

        let left = root.appending(path: "left")
        let tops = (files + 1999) / 2000
        let bytes = Atomic64()
        let failure = FirstError()
        DispatchQueue.concurrentPerform(iterations: tops) { top in
            do {
                for index in (top * 2000)..<min(files, (top + 1) * 2000) {
                    let url = left.appending(path: path(index))
                    if index % 100 == 0 {
                        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    }
                    let data = textFile(seed: UInt64(index))
                    try data.write(to: url)
                    try setDate(url, baseDate)
                    bytes.add(Int64(data.count))
                }
            } catch {
                failure.record(error)
            }
        }
        try failure.throwIfSet()

        try clone(left, to: root.appending(path: "right"))

        var manifest = Manifest(version: version, kind: "tree", files: files, leftOnly: 0, rightOnly: 0, changedSameSize: 0, changedSize: 0, totalBytes: bytes.value)
        let right = root.appending(path: "right")
        for index in 0..<files {
            let url = right.appending(path: path(index))
            if index % 200 == 17 {
                try FileManager.default.removeItem(at: url)
                manifest.leftOnly += 1
            } else if index % 100 == 7 {
                var data = try Data(contentsOf: url)
                let middle = data.count / 2
                data[middle] = data[middle] == UInt8(ascii: "x") ? UInt8(ascii: "y") : UInt8(ascii: "x")
                try data.write(to: url)
                try setDate(url, changedDate)
                manifest.changedSameSize += 1
            } else if index % 200 == 13 {
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data("added line\n".utf8))
                try handle.close()
                try setDate(url, changedDate)
                manifest.changedSize += 1
            }
        }
        for extra in 0..<(files / 200) {
            let url = right.appending(path: path(extra * 200 + 50)).deletingLastPathComponent().appending(path: "extra-\(extra).txt")
            try textFile(seed: UInt64(files + extra)).write(to: url)
            manifest.rightOnly += 1
        }

        try save(manifest, in: root)
        return Dataset(root: root, manifest: manifest)
    }

    /// `count` files of `megabytes` MB each. Every second file differs in its last byte only, so
    /// a byte compare has to read all of them.
    static func large(count: Int, megabytes: Int, in base: URL) throws -> Dataset {
        let root = base.appending(path: "large-\(count)x\(megabytes)mb")
        if let existing = try load(root, kind: "large", files: count) { return existing }
        try reset(root)

        let left = root.appending(path: "left")
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
        let size = megabytes << 20
        let failure = FirstError()
        DispatchQueue.concurrentPerform(iterations: count) { index in
            var random = SplitMix64(state: UInt64(index) &* 7919)
            var data = Data(count: size)
            data.withUnsafeMutableBytes { buffer in
                let words = buffer.bindMemory(to: UInt64.self)
                for offset in words.indices { words[offset] = random.next() }
            }
            do {
                try data.write(to: left.appending(path: "big-\(index).bin"))
                try setDate(left.appending(path: "big-\(index).bin"), baseDate)
            } catch {
                failure.record(error)
            }
        }
        try failure.throwIfSet()

        let right = root.appending(path: "right")
        try clone(left, to: right)
        var manifest = Manifest(version: version, kind: "large", files: count, leftOnly: 0, rightOnly: 0, changedSameSize: 0, changedSize: 0, totalBytes: Int64(count) * Int64(size))
        for index in stride(from: 0, to: count, by: 2) {
            let handle = try FileHandle(forUpdating: right.appending(path: "big-\(index).bin"))
            try handle.seek(toOffset: UInt64(size - 1))
            let last = try handle.read(upToCount: 1) ?? Data([0])
            try handle.seek(toOffset: UInt64(size - 1))
            try handle.write(contentsOf: Data([last[0] ^ 0xFF]))
            try handle.close()
            try setDate(right.appending(path: "big-\(index).bin"), changedDate)
            manifest.changedSameSize += 1
        }

        try save(manifest, in: root)
        return Dataset(root: root, manifest: manifest)
    }

    private static func setDate(_ url: URL, _ date: timespec) throws {
        var times = [date, date]
        guard utimensat(AT_FDCWD, url.path(percentEncoded: false), &times, 0) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    static func path(_ index: Int) -> String {
        let top = index / 2000
        let sub = (index / 100) % 20
        return String(format: "t%04d/s%02d/f%03d.txt", top, sub, index % 100)
    }

    /// Mostly small files, like a source tree: 85% up to 3 KB, 14% up to 24 KB, 1% up to 256 KB.
    private static func textFile(seed: UInt64) -> Data {
        var random = SplitMix64(state: seed &* 0x2545_F491_4F6C_DD1D)
        let bucket = random.next(in: 0...99)
        let size = switch bucket {
        case 0..<85: random.next(in: 200...3000)
        case 85..<99: random.next(in: 3001...24000)
        default: random.next(in: 24001...256_000)
        }
        var text = [UInt8]()
        text.reserveCapacity(size + 16)
        var column = 0
        while text.count < size {
            let word = words[random.next(in: 0...(words.count - 1))]
            text.append(contentsOf: word.utf8)
            column += word.utf8.count + 1
            if column > 60 {
                text.append(UInt8(ascii: "\n"))
                column = 0
            } else {
                text.append(UInt8(ascii: " "))
            }
        }
        return Data(text)
    }

    private static func clone(_ source: URL, to destination: URL) throws {
        // On APFS a clone shares all blocks with the source, so the right side costs no space
        // until it is changed.
        if Darwin.clonefile(source.path(percentEncoded: false), destination.path(percentEncoded: false), 0) == 0 { return }
        let reason = String(cString: strerror(errno))
        FileHandle.standardError.write(Data("moire-bench: cannot clone (\(reason)), copying instead; this uses twice the disk space\n".utf8))
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private static func reset(_ root: URL) throws {
        if FileManager.default.fileExists(atPath: root.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private static func load(_ root: URL, kind: String, files: Int) throws -> Dataset? {
        let url = root.appending(path: "manifest.json")
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.version == version, manifest.kind == kind, manifest.files == files
        else { return nil }
        return Dataset(root: root, manifest: manifest)
    }

    private static func save(_ manifest: Manifest, in root: URL) throws {
        // Written last: a dataset without a manifest was interrupted and is built again.
        try JSONEncoder().encode(manifest).write(to: root.appending(path: "manifest.json"))
    }
}

final class Atomic64: Sendable {
    private let total = Atomic<Int64>(0)

    func add(_ amount: Int64) { total.add(amount, ordering: .relaxed) }

    var value: Int64 { total.load(ordering: .relaxed) }
}

final class FirstError: Sendable {
    private let error = Mutex<Error?>(nil)

    func record(_ error: Error) {
        self.error.withLock { if $0 == nil { $0 = error } }
    }

    func throwIfSet() throws {
        if let error = error.withLock({ $0 }) { throw error }
    }
}
