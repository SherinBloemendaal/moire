import Foundation

/// An archive unpacked into a folder of its own in the temporary folder. The folder is removed
/// with `remove()`, or when the last reference to this goes away.
public final class ExtractedArchive: Sendable {
    /// The archive that was unpacked.
    public let archive: URL
    /// The unpacked contents, named after the archive.
    public let folder: URL
    /// The temporary folder that holds `folder`, and is removed with it.
    let root: URL

    init(archive: URL, folder: URL, root: URL) {
        self.archive = archive
        self.folder = folder
        self.root = root
    }

    deinit {
        remove()
    }

    /// Removes the unpacked files. Safe to call more than once.
    public func remove() {
        ArchiveExtractor.removeTree(root)
    }
}

/// Unpacks zip and tar archives with the tools macOS ships (`ditto` and `bsdtar`), after
/// checking that no entry would land outside the folder it is unpacked into.
public enum ArchiveExtractor {
    public enum Failure: LocalizedError, Equatable {
        /// An entry with an absolute path, a `..` part, or one that would be written through a
        /// link or over another entry.
        case unsafeEntry(String)
        case toolFailed(tool: String, message: String)
        /// Unpacked, the archive would not fit in the space that is left (a "zip bomb", or just big).
        case tooLarge(needed: Int64, available: Int64)

        public var errorDescription: String? {
            switch self {
            case .unsafeEntry(let name):
                "The archive was not opened because the entry “\(name)” would be written outside its folder."
            case .toolFailed(let tool, let message):
                message.isEmpty ? "\(tool) could not unpack the archive." : "\(tool) could not unpack the archive: \(message)"
            case let .tooLarge(needed, available):
                "The archive was not opened: unpacked it takes \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)), "
                    + "and only \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) is free for it."
            }
        }
    }

    /// Where archives are unpacked unless told otherwise.
    public static var defaultParent: URL {
        FileManager.default.temporaryDirectory.appending(path: "Moire Archives", directoryHint: .isDirectory)
    }

    /// Lists the entries, checks them, and unpacks the archive into a new folder inside `parent`.
    /// Cancelling the task stops the tool and removes what was unpacked so far.
    ///
    /// An archive that would take more than `limit` bytes unpacked is refused before anything is
    /// written. By default the limit is the free space on the disk of `parent`, less 1 GB.
    public static func extract(_ archive: URL, format: ArchiveFormat, into parent: URL = defaultParent, limit: Int64? = nil) async throws -> ExtractedArchive {
        try validate(try await entries(of: archive, format: format), format: format)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let available = try limit ?? freeSpace(at: parent)
        let needed = try await uncompressedSize(of: archive, format: format)
        guard needed <= available else { throw Failure.tooLarge(needed: needed, available: max(0, available)) }

        let root = parent.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let folder = root.appending(path: folderName(for: archive), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Created before unpacking, so a failure below removes the folder again.
        let extracted = ExtractedArchive(archive: archive, folder: folder, root: root)

        let source = archive.path(percentEncoded: false)
        let destination = folder.path(percentEncoded: false)
        switch format {
        case .zip:
            _ = try await run("/usr/bin/ditto", ["-x", "-k", source, destination])
        case .tar, .tarGzip, .tarBzip2, .tarXz:
            // bsdtar finds the compression itself, and by default refuses `..`, absolute paths
            // and writing through links.
            _ = try await run("/usr/bin/tar", ["-x", "-f", source, "-C", destination])
        }
        return extracted
    }

    /// The names of the entries, as the tool lists them.
    public static func entries(of archive: URL, format: ArchiveFormat) async throws -> [String] {
        let path = archive.path(percentEncoded: false)
        let output = switch format {
        // zipinfo exits with 1 for warnings that still list everything, such as an empty archive.
        case .zip: try await run("/usr/bin/zipinfo", ["-1", path], allowedStatus: [0, 1])
        case .tar, .tarGzip, .tarBzip2, .tarXz: try await run("/usr/bin/tar", ["-t", "-f", path])
        }
        return String(decoding: output, as: UTF8.self).split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    /// The size of all entries once unpacked, as the archive states it. For tar this reads the
    /// whole archive (decompressing it in memory, writing nothing).
    public static func uncompressedSize(of archive: URL, format: ArchiveFormat) async throws -> Int64 {
        let path = archive.path(percentEncoded: false)
        switch format {
        case .zip:
            // "3 files, 10485760 bytes uncompressed, 10196 bytes compressed:  99.9%"
            let output = String(decoding: try await run("/usr/bin/zipinfo", ["-t", path], allowedStatus: [0, 1]), as: UTF8.self)
            let words = output.split(whereSeparator: \.isWhitespace)
            guard let index = words.firstIndex(where: { $0.hasPrefix("bytes") }), index > 0, let size = Int64(words[index - 1]) else {
                return 0
            }
            return size
        case .tar, .tarGzip, .tarBzip2, .tarXz:
            // "-rw-r--r--  0 me staff  10485760 Oct 27 21:00 name": the fifth column is the size.
            let output = String(decoding: try await run("/usr/bin/tar", ["-t", "-v", "-f", path]), as: UTF8.self)
            return output.split(separator: "\n").reduce(Int64(0)) { total, line in
                let columns = line.split(whereSeparator: \.isWhitespace)
                return total + (columns.count > 4 ? Int64(columns[4]) ?? 0 : 0)
            }
        }
    }

    static func freeSpace(at folder: URL) throws -> Int64 {
        let values = try folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return (values.volumeAvailableCapacityForImportantUsage ?? 0) - (1 << 30)
    }

    /// Refuses absolute paths and `..` parts. For zip, which `ditto` unpacks, it also refuses an
    /// entry that comes twice or that has entries below it without being a folder (a link
    /// another entry would be written through).
    public static func validate(_ names: [String], format: ArchiveFormat) throws {
        var paths: Set<String> = []
        var files: Set<String> = []
        var splitNames: [(name: String, parts: [Substring])] = []
        for name in names {
            var trimmed = Substring(name)
            while trimmed.hasPrefix("./") { trimmed = trimmed.dropFirst(2) }
            guard !trimmed.isEmpty, trimmed != "." else { continue }
            guard !trimmed.hasPrefix("/") else { throw Failure.unsafeEntry(name) }
            let parts = trimmed.split(separator: "/")
            guard !parts.contains("..") else { throw Failure.unsafeEntry(name) }
            guard format == .zip else { continue }

            let path = parts.joined(separator: "/")
            guard paths.insert(path).inserted else { throw Failure.unsafeEntry(name) }
            if !trimmed.hasSuffix("/") { files.insert(path) }
            splitNames.append((name, parts))
        }
        for (name, parts) in splitNames where parts.count > 1 {
            for length in 1..<parts.count where files.contains(parts[0..<length].joined(separator: "/")) {
                throw Failure.unsafeEntry(name)
            }
        }
    }

    /// `photos.tar.gz` becomes `photos`.
    public static func folderName(for archive: URL) -> String {
        let name = archive.lastPathComponent
        let lowercased = name.lowercased()
        for suffix in [".tar.gz", ".tar.bz2", ".tar.xz", ".tgz", ".tbz2", ".tbz", ".txz", ".tar", ".zip"] where lowercased.hasSuffix(suffix) {
            let stem = String(name.dropLast(suffix.count))
            return stem.isEmpty ? "Archive" : stem
        }
        let stem = (name as NSString).deletingPathExtension
        return stem.isEmpty ? "Archive" : stem
    }

    /// Removes folders in `parent` that were unpacked more than `age` seconds ago and never
    /// removed, for example because Moire was force quit.
    public static func removeLeftovers(in parent: URL = defaultParent, olderThan age: TimeInterval = 24 * 60 * 60) {
        let limit = Date().addingTimeInterval(-age)
        let items = (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for item in items {
            guard let created = try? item.resourceValues(forKeys: [.creationDateKey]).creationDate, created < limit else { continue }
            removeTree(item)
        }
    }

    /// Removes a folder even when the archive made parts of it read-only.
    static func removeTree(_ url: URL) {
        let manager = FileManager.default
        func unlock(_ folder: URL) {
            try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path(percentEncoded: false))
            let children = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for child in children {
                let type = (try? manager.attributesOfItem(atPath: child.path(percentEncoded: false)))?[.type] as? FileAttributeType
                if type == .typeDirectory { unlock(child) }
            }
        }
        let type = (try? manager.attributesOfItem(atPath: url.path(percentEncoded: false)))?[.type] as? FileAttributeType
        guard let type else { return }
        if type == .typeDirectory { unlock(url) }
        try? manager.removeItem(at: url)
    }

    /// Runs a tool and returns what it printed. Its error output becomes the failure message.
    static func run(_ tool: String, _ arguments: [String], allowedStatus: Set<Int32> = [0]) async throws -> Data {
        let run = ToolRun(tool: tool, arguments: arguments)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try run.wait(allowedStatus: allowedStatus) })
                }
            }
        } onCancel: {
            run.cancel()
        }
    }
}

/// One run of a tool that can be stopped from another thread.
private final class ToolRun: @unchecked Sendable {
    private let process = Process()
    private let output = Pipe()
    private let errors = Pipe()
    private let lock = NSLock()
    private var isCancelled = false
    private let toolName: String

    init(tool: String, arguments: [String]) {
        toolName = URL(filePath: tool).lastPathComponent
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
    }

    /// Blocks until the tool exits.
    func wait(allowedStatus: Set<Int32>) throws -> Data {
        try lock.withLock {
            guard !isCancelled else { throw CancellationError() }
            try process.run()
        }
        // Both pipes are read at once, so neither fills up and blocks the tool.
        let errorReader = DispatchQueue(label: "moire.tool.errors")
        nonisolated(unsafe) var errorData = Data()
        let errorHandle = errors.fileHandleForReading
        let group = DispatchGroup()
        errorReader.async(group: group) { errorData = errorHandle.readDataToEndOfFile() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()

        if lock.withLock({ isCancelled }) { throw CancellationError() }
        guard allowedStatus.contains(process.terminationStatus) else {
            let message = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ArchiveExtractor.Failure.toolFailed(tool: toolName, message: message)
        }
        return data
    }

    func cancel() {
        lock.withLock {
            isCancelled = true
            if process.isRunning { process.terminate() }
        }
    }
}
