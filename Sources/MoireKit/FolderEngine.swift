import Foundation
import Synchronization

/// How two files with the same path are judged equal.
public enum CompareMethod: String, Sendable, Hashable, CaseIterable {
    /// Size and modification date. No file is opened: fast on network disks.
    case metadata
    /// Size, then the first and last 64 KB.
    case quick
    /// Every byte.
    case binary
    /// As text, with the ignore options of `DiffOptions`.
    case lines
}

public struct FolderCompareSettings: Sendable, Hashable {
    public var method: CompareMethod
    /// Skip names that start with a dot (`.git`, `.DS_Store`).
    public var skipHidden: Bool
    /// How far two modification dates may be apart and still count as the same, in
    /// nanoseconds. FAT disks store dates in steps of 2 seconds.
    public var dateTolerance: Int64
    /// Also accept dates exactly one hour apart (within the tolerance): a copy made on a disk
    /// that stores local time, read after daylight saving time changed.
    public var allowsHourShift: Bool
    /// For `.lines`.
    public var diffOptions: DiffOptions
    /// Masks and `.gitignore` handling.
    public var filter: FolderFilter
    /// For `.lines`: rules for differences that do not matter, by file extension (lowercased,
    /// without the dot), with `"*"` for files without rules of their own.
    public var textRules: [String: TextRules] = [:]
    /// Threads that read folders. `nil` picks a number for the disks involved.
    public var folderThreads: Int?
    /// Threads that read file contents. `nil` picks a number for the disks involved.
    public var contentThreads: Int?

    public init(
        method: CompareMethod = .binary,
        skipHidden: Bool = true,
        dateTolerance: Int64 = 2_000_000_000,
        allowsHourShift: Bool = true,
        diffOptions: DiffOptions = DiffOptions(),
        filter: FolderFilter = FolderFilter(),
        folderThreads: Int? = nil,
        contentThreads: Int? = nil
    ) {
        self.method = method
        self.skipHidden = skipHidden
        self.dateTolerance = dateTolerance
        self.allowsHourShift = allowsHourShift
        self.diffOptions = diffOptions
        self.filter = filter
        self.folderThreads = folderThreads
        self.contentThreads = contentThreads
    }

    /// Metadata only when either folder is on a network disk, otherwise the given method.
    public static func defaultMethod(left: Volume, right: Volume, otherwise method: CompareMethod = .binary) -> CompareMethod {
        left.isLocal && right.isLocal ? method : .metadata
    }

    func sameDate(_ a: Int64, _ b: Int64) -> Bool {
        let difference = abs(a - b)
        if difference <= dateTolerance { return true }
        let hour: Int64 = 3_600_000_000_000
        return allowsHourShift && abs(difference - hour) <= dateTolerance
    }
}

/// How far a running comparison is.
public struct FolderProgress: Sendable, Hashable {
    public var foldersListed: Int
    public var itemsFound: Int
    /// Files whose contents have to be read, and how many of them are done.
    public var filesToRead: Int
    public var filesRead: Int
    public var bytesToRead: Int64
    public var bytesRead: Int64
}

/// Compares two folder trees on many threads.
///
/// `run()` blocks until the comparison is done. While it runs, other threads can call
/// `snapshot()` and `progress` to show results as they come in, and `cancel()` to stop it.
public final class FolderEngine: Sendable {
    public let settings: FolderCompareSettings
    private let makeSources: @Sendable () throws -> (any FolderSource, any FolderSource)
    private let sources = Mutex<(left: any FolderSource, right: any FolderSource)?>(nil)
    /// Results of earlier runs. Pairs found here are not read again; new results are added.
    public let cache: ResultCache?

    private let tree = Mutex(FolderTree())
    private let cancelled = Atomic<Bool>(false)
    private let foldersListed = Atomic<Int>(0)
    private let itemsFound = Atomic<Int>(0)
    private let filesToRead = Atomic<Int>(0)
    private let filesRead = Atomic<Int>(0)
    private let bytesToRead = Atomic<Int64>(0)
    private let bytesRead = Atomic<Int64>(0)

    public var progress: FolderProgress {
        FolderProgress(
            foldersListed: foldersListed.load(ordering: .relaxed),
            itemsFound: itemsFound.load(ordering: .relaxed),
            filesToRead: filesToRead.load(ordering: .relaxed),
            filesRead: filesRead.load(ordering: .relaxed),
            bytesToRead: bytesToRead.load(ordering: .relaxed),
            bytesRead: bytesRead.load(ordering: .relaxed)
        )
    }

    /// The tree as far as it is known right now, with folder statuses worked out (`.pending`
    /// where something inside is still open). Copying is cheap, but the next change the engine
    /// makes copies the arrays once, so call this a few times a second, not in a tight loop.
    public func snapshot() -> FolderTree {
        var copy = tree.withLock { $0 }
        copy.settleFolders()
        return copy
    }

    /// Compares two local folders.
    public convenience init(left: URL, right: URL, settings: FolderCompareSettings = FolderCompareSettings(), cache: ResultCache? = nil) {
        self.init(sources: { (try LocalSource(left), try LocalSource(right)) }, settings: settings, cache: cache)
    }

    /// Compares two folders from any source. The sources are made when `run()` starts, so a
    /// missing folder or a failed connection is reported by `run()`.
    public init(
        sources: @escaping @Sendable () throws -> (any FolderSource, any FolderSource),
        settings: FolderCompareSettings = FolderCompareSettings(),
        cache: ResultCache? = nil
    ) {
        makeSources = sources
        self.settings = settings
        // Metadata never reads contents, so there is nothing to remember.
        self.cache = settings.method == .metadata ? nil : cache
        var exclude = settings.filter.exclude
        // Git never lists its own folder.
        if settings.filter.useGitignore { exclude.append(".git/") }
        rootRules = IgnoreRules(patterns: exclude)
        includeRules = IgnoreRules(patterns: settings.filter.include)
    }

    private let rootRules: IgnoreRules
    private let includeRules: IgnoreRules

    /// Stops a running comparison soon. `run()` then throws `CancellationError`.
    public func cancel() {
        cancelled.store(true, ordering: .relaxed)
    }

    /// Reads both trees and compares them. Blocks the calling thread until done.
    public func run() throws -> FolderTree {
        let (leftSource, rightSource) = try makeSources()
        sources.withLock { $0 = (leftSource, rightSource) }
        let leftVolume = leftSource.volume
        let rightVolume = rightSource.volume
        let folderPool = WorkPool<FolderJob>(
            threads: settings.folderThreads ?? Self.folderThreads(left: leftVolume, right: rightVolume),
            name: "Moire folders"
        ) { [self] job in read(job) }
        defer { folderPool.close() }

        // Contents are read while folders are still being listed, by a pool of its own, so a
        // slow disk never holds up the listing and the other way around.
        var contentPool: WorkPool<ContentJob>?
        if settings.method != .metadata {
            let pool = WorkPool<ContentJob>(
                threads: settings.contentThreads ?? Self.contentThreads(left: leftVolume, right: rightVolume),
                name: "Moire contents"
            ) { [self] job in compare(job) }
            contentPool = pool
        }
        defer { contentPool?.close() }

        pools.withLock { $0 = Pools(folders: folderPool, contents: contentPool) }
        defer { pools.withLock { $0 = nil } }
        folderPool.submit([FolderJob(item: 0, path: "", onLeft: true, onRight: true, rules: rootRules)])
        folderPool.waitUntilIdle()
        // Every content job has been handed out once the listing is done.
        contentPool?.waitUntilIdle()

        if cancelled.load(ordering: .relaxed) { throw CancellationError() }
        return tree.withLock { tree in
            tree.settleFolders()
            return tree
        }
    }

    private struct Pools: Sendable {
        let folders: WorkPool<FolderJob>
        let contents: WorkPool<ContentJob>?
    }

    private let pools = Mutex<Pools?>(nil)

    /// Measured on an M2 Max (APFS, 100,000 files): opening and listing files stops scaling at
    /// about four threads, and more threads make it slower because they wait on each other in
    /// the kernel. A network share is limited by waiting for answers, so more requests in flight
    /// pay off there.
    static func folderThreads(left: Volume, right: Volume) -> Int {
        left.isLocal && right.isLocal ? localThreads : 8
    }

    static func contentThreads(left: Volume, right: Volume) -> Int {
        left.isLocal && right.isLocal ? localThreads : 8
    }

    /// Half the performance cores, at least 4 and at most 8.
    static let localThreads: Int = {
        var cores: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &cores, &size, nil, 0) != 0 || cores <= 0 {
            cores = Int32(ProcessInfo.processInfo.activeProcessorCount)
        }
        return min(8, max(4, Int(cores) / 2))
    }()

    // MARK: Reading folders

    private struct FolderJob: Sendable {
        let item: Int32
        /// The folder's path relative to the compared folders; empty for the root.
        let path: String
        let onLeft: Bool
        let onRight: Bool
        /// Exclude masks plus the `.gitignore` rules of this folder and the folders above it.
        let rules: IgnoreRules
    }

    private func currentSources() -> (left: any FolderSource, right: any FolderSource) {
        guard let current = sources.withLock({ $0 }) else { preconditionFailure("jobs only run inside run()") }
        return current
    }

    private static func join(_ folder: String, _ name: String) -> String {
        folder.isEmpty ? name : folder + "/" + name
    }

    private func read(_ job: FolderJob) {
        if cancelled.load(ordering: .relaxed) {
            stopPools()
            return
        }

        let (leftSource, rightSource) = currentSources()
        var leftEntries: [DirectoryEntry] = []
        var rightEntries: [DirectoryEntry] = []
        do {
            if job.onLeft { leftEntries = try leftSource.list(job.path, skipHidden: settings.skipHidden) }
            if job.onRight { rightEntries = try rightSource.list(job.path, skipHidden: settings.skipHidden) }
        } catch {
            tree.withLock { tree in
                tree.statuses[Int(job.item)] = .unreadable
                tree.errors[job.item] = error.localizedDescription
            }
            return
        }

        var rules = job.rules
        if settings.filter.useGitignore {
            for (source, entries) in [(leftSource, leftEntries), (rightSource, rightEntries)] where entries.contains(where: { $0.name == ".gitignore" }) || settings.skipHidden {
                // Hidden entries are not listed when skipped, so the file is opened directly then.
                guard let file = try? source.open(Self.join(job.path, ".gitignore")), let data = try? file.readAll() else { continue }
                rules.add(gitignore: String(decoding: data, as: UTF8.self), base: job.path)
            }
        }
        if !rules.isEmpty || !includeRules.isEmpty {
            leftEntries = leftEntries.filter { keep($0, in: job.path, rules: rules) }
            rightEntries = rightEntries.filter { keep($0, in: job.path, rules: rules) }
        }

        var children = pair(leftEntries, rightEntries, job: job)
        var cachedLines: [(offset: Int, lines: Int)] = []
        if let cache {
            for offset in children.indices where children[offset].status == .pending && children[offset].left.kind == .file && children[offset].right.kind == .file {
                switch cache.lookup(left: children[offset].left, right: children[offset].right) {
                case .identical: children[offset].status = .identical
                case .different: children[offset].status = .different
                case .differentLines(let lines):
                    children[offset].status = .different
                    cachedLines.append((offset, lines))
                case nil: break
                }
            }
        }
        let first = tree.withLock { tree in
            let first = tree.appendChildren(children, to: job.item)
            for (offset, lines) in cachedLines { tree.changedLines[first + Int32(offset)] = lines }
            return first
        }
        foldersListed.add(1, ordering: .relaxed)
        itemsFound.add(children.count, ordering: .relaxed)

        var folders: [FolderJob] = []
        var contents: [ContentJob] = []
        for (offset, child) in children.enumerated() where child.status == .pending {
            let item = first + Int32(offset)
            let path = Self.join(job.path, child.name)
            if child.left.kind == .file, child.right.kind == .file {
                contents.append(ContentJob(item: item, path: path, leftInfo: child.left, rightInfo: child.right))
                continue
            }
            let isFolder = (child.left.kind == .directory || !child.left.exists) && (child.right.kind == .directory || !child.right.exists)
            guard isFolder else { continue }
            folders.append(FolderJob(item: item, path: path, onLeft: child.left.exists, onRight: child.right.exists, rules: rules))
        }
        if !contents.isEmpty {
            filesToRead.add(contents.count, ordering: .relaxed)
            bytesToRead.add(contents.reduce(0) { $0 + bytesRead(for: $1) }, ordering: .relaxed)
        }
        let current = pools.withLock { $0 }
        // Reversed, so a pool (which takes the last job first) works in list order.
        current?.folders.submit(folders.reversed())
        current?.contents?.submit(contents.reversed())
    }

    private func keep(_ entry: DirectoryEntry, in folder: String, rules: IgnoreRules) -> Bool {
        let path = Self.join(folder, entry.name)
        let isDirectory = entry.kind == .directory
        if rules.ignores(path, isDirectory: isDirectory) { return false }
        if !includeRules.isEmpty, !isDirectory, !includeRules.matchesAny(path, isDirectory: false) { return false }
        return true
    }

    private func stopPools() {
        let current = pools.withLock { $0 }
        current?.folders.cancel()
        current?.contents?.cancel()
    }

    // MARK: Reading contents

    private struct ContentJob: Sendable {
        let item: Int32
        let path: String
        let leftInfo: FolderTree.SideInfo
        let rightInfo: FolderTree.SideInfo

        var size: Int64 { leftInfo.size }
    }

    /// The diff options for one file, with the rules for its kind.
    private func diffOptions(for path: String) -> DiffOptions {
        var options = settings.diffOptions
        guard settings.method == .lines, !settings.textRules.isEmpty else { return options }
        let name = (path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()
        options.rules = settings.textRules[ext] ?? settings.textRules["*"] ?? TextRules()
        options.commentSyntax = CommentSyntax.forFile(named: name)
        return options
    }

    /// What a job reads from both files together, at most.
    private func bytesRead(for job: ContentJob) -> Int64 {
        let window = Int64(ContentComparer.quickWindow * 2)
        return settings.method == .quick && job.size > window ? window * 2 : job.size * 2
    }

    private func compare(_ job: ContentJob) {
        if cancelled.load(ordering: .relaxed) {
            stopPools()
            return
        }
        defer {
            filesRead.add(1, ordering: .relaxed)
            bytesRead.add(bytesRead(for: job), ordering: .relaxed)
        }
        do {
            let (leftSource, rightSource) = currentSources()
            let verdict = try ContentComparer.compare(
                leftSource.open(job.path, listedSize: job.leftInfo.size), rightSource.open(job.path, listedSize: job.rightInfo.size),
                method: settings.method, options: diffOptions(for: job.path)
            )
            let remembered: ResultCache.Verdict = switch verdict {
            case .identical: .identical
            case .different: .different
            case .differentLines(let lines): .differentLines(lines)
            }
            cache?.record(left: job.leftInfo, right: job.rightInfo, verdict: remembered)
            tree.withLock { tree in
                switch verdict {
                case .identical:
                    tree.statuses[Int(job.item)] = .identical
                case .different:
                    tree.statuses[Int(job.item)] = .different
                case .differentLines(let count):
                    tree.statuses[Int(job.item)] = .different
                    tree.changedLines[job.item] = count
                }
            }
        } catch {
            tree.withLock { tree in
                tree.statuses[Int(job.item)] = .unreadable
                tree.errors[job.item] = error.localizedDescription
            }
        }
    }

    /// Matches the items of both sides by name and decides what can be decided from the folder
    /// listing alone.
    private func pair(_ leftEntries: [DirectoryEntry], _ rightEntries: [DirectoryEntry], job: FolderJob) -> [FolderTree.Child] {
        // Names are matched in composed form: a share may hand out "é" as e + accent.
        var rightByName: [String: DirectoryEntry] = Dictionary(minimumCapacity: rightEntries.count)
        for entry in rightEntries {
            rightByName[entry.name.precomposedStringWithCanonicalMapping] = entry
        }

        var children: [FolderTree.Child] = []
        children.reserveCapacity(max(leftEntries.count, rightEntries.count))
        for entry in leftEntries {
            let key = entry.name.precomposedStringWithCanonicalMapping
            let match = rightByName.removeValue(forKey: key)
            children.append(child(name: entry.name, left: entry, right: match, job: job))
        }
        for entry in rightEntries where rightByName[entry.name.precomposedStringWithCanonicalMapping] != nil {
            children.append(child(name: entry.name, left: nil, right: entry, job: job))
        }

        children.sort { a, b in
            let aIsFolder = a.left.kind == .directory || a.right.kind == .directory
            let bIsFolder = b.left.kind == .directory || b.right.kind == .directory
            if aIsFolder != bIsFolder { return aIsFolder }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return children
    }

    private func child(name: String, left: DirectoryEntry?, right: DirectoryEntry?, job: FolderJob) -> FolderTree.Child {
        let leftInfo = left.map(Self.info) ?? .absent
        let rightInfo = right.map(Self.info) ?? .absent
        let status: FolderTree.Status

        switch (leftInfo.kind, rightInfo.kind) {
        case (_, .absent):
            // A folder on one side is still read, so its contents are listed too.
            status = leftInfo.kind == .directory ? .pending : .leftOnly
        case (.absent, _):
            status = rightInfo.kind == .directory ? .pending : .rightOnly
        case (.directory, .directory):
            status = .pending
        case let (a, b) where a != b:
            status = .different
        case (.symbolicLink, .symbolicLink):
            let (leftSource, rightSource) = currentSources()
            let path = Self.join(job.path, name)
            do {
                status = try leftSource.linkDestination(path) == rightSource.linkDestination(path) ? .identical : .different
            } catch {
                status = .unreadable
            }
        case (.file, .file):
            status = fileStatus(leftInfo, rightInfo)
        default:
            // Devices, sockets and pipes are never read.
            status = .identical
        }

        return FolderTree.Child(name: name, left: leftInfo, right: rightInfo, status: status)
    }

    private func fileStatus(_ left: FolderTree.SideInfo, _ right: FolderTree.SideInfo) -> FolderTree.Status {
        switch settings.method {
        case .metadata:
            return left.size == right.size && settings.sameDate(left.modified, right.modified) ? .identical : .different
        case .quick, .binary:
            return left.size == right.size ? .pending : .different
        case .lines:
            return .pending
        }
    }

    private static func info(_ entry: DirectoryEntry) -> FolderTree.SideInfo {
        FolderTree.SideInfo(kind: FolderTree.Kind(entry.kind), size: entry.size, modified: entry.modified, fileID: entry.fileID)
    }
}
