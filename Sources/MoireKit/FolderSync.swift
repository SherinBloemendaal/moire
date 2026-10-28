import Darwin
import Foundation

/// Makes two compared folders (more) alike: a plan to look at first, then carrying it out.
public enum FolderSync {
    public enum Direction: String, Sendable, Hashable, CaseIterable {
        case leftToRight
        case rightToLeft
        case both
    }

    public enum Mode: String, Sendable, Hashable, CaseIterable {
        /// Copy what is missing on the target, and replace files that are older there.
        case update
        /// Make the target an exact copy: copy everything that differs, and move what only the
        /// target has to the Trash.
        case mirror
    }

    public enum Action: Sendable, Hashable {
        /// `from` is the path on the source side, `to` on the target side. They differ only when
        /// the sides spell a name in another case.
        case copy(from: String, to: String, toRight: Bool, bytes: Int64)
        case createFolder(path: String, onRight: Bool)
        /// Moves the item to the Trash, so it can be put back.
        case trash(path: String, onRight: Bool)

        /// The path on the side that changes.
        public var path: String {
            switch self {
            case .copy(_, let path, _, _), .createFolder(let path, _), .trash(let path, _): path
            }
        }
    }

    /// What an item looked like when it was compared. Before every action the files are
    /// checked against it, so a file that changed since is never overwritten or trashed.
    public struct Expected: Sendable, Hashable {
        public var kind: FolderTree.Kind
        public var size: Int64
        public var modified: Int64

        init(_ info: FolderTree.SideInfo) {
            kind = info.kind
            size = info.size
            modified = info.modified
        }
    }

    public struct Check: Sendable, Hashable {
        /// For a copy: the file that is copied.
        public var source: Expected?
        /// The item that is replaced, trashed or created (`.absent` when there should be nothing).
        public var target: Expected
    }

    public struct Plan: Sendable, Hashable {
        public var actions: [Action]
        /// One per action.
        public var checks: [Check]
        public var bytesToCopy: Int64 { actions.reduce(0) { if case .copy(_, _, _, let bytes) = $1 { $0 + bytes } else { $0 } } }
        public var copies: Int { actions.count { if case .copy = $0 { true } else { false } } }
        public var trashes: Int { actions.count { if case .trash = $0 { true } else { false } } }
    }

    /// What `mode` in `direction` would do, for the items in `selection` (and everything inside
    /// selected folders), or for the whole tree when `selection` is empty. Changes nothing.
    ///
    /// "Newer" compares modification dates with the tolerance of `settings`. A file that is
    /// newer on the target is left alone by `.update` and overwritten by `.mirror`.
    public static func plan(_ tree: FolderTree, mode: Mode, direction: Direction, settings: FolderCompareSettings, selection: Set<Int> = []) -> Plan {
        var included = [Bool](repeating: selection.isEmpty, count: tree.count)
        if !selection.isEmpty {
            // Children follow their parent, so one forward pass marks whole selected folders.
            for item in 1..<tree.count where selection.contains(item) || included[tree.parent(of: item) ?? 0] {
                included[item] = true
            }
        }

        var plan = Plan(actions: [], checks: [])
        // A folder that goes to the Trash takes its contents along, so nothing inside it gets an
        // action of its own.
        var trashed = [Bool](repeating: false, count: tree.count)
        // Parents come first in the tree, so a folder is created before what goes into it.
        for item in 1..<tree.count where included[item] {
            if let parent = tree.parent(of: item), trashed[parent] {
                trashed[item] = true
                continue
            }
            let left = tree.left(item)
            let right = tree.right(item)
            // Devices, sockets and pipes are never copied.
            guard left.kind != .other, right.kind != .other else { continue }
            let paths = (left: tree.path(of: item, on: .left), right: tree.path(of: item, on: .right))
            let status = tree.status(of: item)

            let steps: [(Action, Check)] = switch direction {
            case .leftToRight:
                oneWay(from: (left, paths.left), to: (right, paths.right), status: status, mode: mode, toRight: true, settings: settings)
            case .rightToLeft:
                oneWay(from: (right, paths.right), to: (left, paths.left), status: status, mode: mode, toRight: false, settings: settings)
            case .both:
                bothWays(left: (left, paths.left), right: (right, paths.right), status: status, settings: settings)
            }
            for (action, check) in steps {
                // Only a folder that goes to the Trash takes its contents along. A file replaced by
                // a folder is trashed too, but the folder's contents still have to be copied.
                if case .trash = action, check.target.kind == .directory { trashed[item] = true }
                plan.actions.append(action)
                plan.checks.append(check)
            }
        }
        return plan
    }

    private typealias Side = (info: FolderTree.SideInfo, path: String)

    private static func oneWay(from source: Side, to target: Side, status: FolderTree.Status, mode: Mode, toRight: Bool, settings: FolderCompareSettings) -> [(Action, Check)] {
        let absent = Expected(.absent)
        func copy() -> (Action, Check) {
            (.copy(from: source.path, to: target.path, toRight: toRight, bytes: source.info.size), Check(source: Expected(source.info), target: Expected(target.info)))
        }
        func createFolder() -> (Action, Check) {
            (.createFolder(path: target.path, onRight: toRight), Check(source: nil, target: absent))
        }
        func trash() -> (Action, Check) {
            (.trash(path: target.path, onRight: toRight), Check(source: nil, target: Expected(target.info)))
        }

        switch (source.info.exists, target.info.exists) {
        case (true, false):
            return [source.info.kind == .directory ? createFolder() : copy()]
        case (false, true):
            return mode == .mirror ? [trash()] : []
        case (true, true):
            guard source.info.kind != .directory || target.info.kind != .directory else { return [] }
            guard status != .identical else { return [] }
            if source.info.kind == .directory || target.info.kind == .directory {
                // A file on one side and a folder on the other: only a mirror replaces it.
                guard mode == .mirror else { return [] }
                if source.info.kind == .directory { return [trash(), createFolder()] }
                var replacement = copy()
                replacement.1.target = absent
                return [trash(), replacement]
            }
            if mode == .update, !isNewer(source.info, than: target.info, settings: settings) { return [] }
            return [copy()]
        case (false, false):
            return []
        }
    }

    private static func bothWays(left: Side, right: Side, status: FolderTree.Status, settings: FolderCompareSettings) -> [(Action, Check)] {
        switch (left.info.exists, right.info.exists) {
        case (true, false):
            return oneWay(from: left, to: right, status: status, mode: .update, toRight: true, settings: settings)
        case (false, true):
            return oneWay(from: right, to: left, status: status, mode: .update, toRight: false, settings: settings)
        case (true, true):
            guard status != .identical, left.info.kind == .file, right.info.kind == .file else { return [] }
            if isNewer(left.info, than: right.info, settings: settings) {
                return oneWay(from: left, to: right, status: status, mode: .update, toRight: true, settings: settings)
            }
            if isNewer(right.info, than: left.info, settings: settings) {
                return oneWay(from: right, to: left, status: status, mode: .update, toRight: false, settings: settings)
            }
            // Same date but different contents: there is no safe winner, so nothing happens.
            return []
        case (false, false):
            return []
        }
    }

    private static func isNewer(_ a: FolderTree.SideInfo, than b: FolderTree.SideInfo, settings: FolderCompareSettings) -> Bool {
        a.modified > b.modified && !settings.sameDate(a.modified, b.modified)
    }

    public struct Failure: Sendable, Hashable {
        public var action: Action
        public var message: String
    }

    /// Carries out a plan. Before each action the files involved are checked against what the
    /// comparison saw; anything that changed since is skipped and reported, never overwritten.
    /// Files are copied next to their destination first and then moved into place, so an
    /// interrupted copy never leaves a half-written file. Returns what failed or was skipped;
    /// everything else was done. `progress` gets the number of finished actions.
    public static func execute(
        _ plan: Plan, left: URL, right: URL,
        isCancelled: @Sendable () -> Bool = { false },
        progress: @Sendable (Int) -> Void = { _ in },
        trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) -> [Failure] {
        var failures: [Failure] = []
        for (index, action) in plan.actions.enumerated() {
            if isCancelled() { break }
            do {
                if index < plan.checks.count { try verify(plan.checks[index], for: action, left: left, right: right) }
                switch action {
                case let .copy(from, to, toRight, _):
                    try copy(from: (toRight ? left : right).appending(path: from), to: (toRight ? right : left).appending(path: to))
                case let .createFolder(path, onRight):
                    try FileManager.default.createDirectory(at: (onRight ? right : left).appending(path: path), withIntermediateDirectories: true)
                case let .trash(path, onRight):
                    try trash((onRight ? right : left).appending(path: path))
                }
            } catch {
                failures.append(Failure(action: action, message: error.localizedDescription))
            }
            progress(index + 1)
        }
        return failures
    }

    public struct ChangedSinceComparison: LocalizedError {
        public var errorDescription: String? { "Changed since the comparison, so it was left alone. Compare again to include it." }
    }

    private static func verify(_ check: Check, for action: Action, left: URL, right: URL) throws {
        let (sourceRoot, targetRoot, sourcePath): (URL, URL, String?) = switch action {
        case let .copy(from, _, toRight, _): (toRight ? left : right, toRight ? right : left, from)
        case let .createFolder(_, onRight), let .trash(_, onRight): (onRight ? left : right, onRight ? right : left, nil)
        }
        if let expected = check.source, let sourcePath {
            guard matches(expected, sourceRoot.appending(path: sourcePath)) else { throw ChangedSinceComparison() }
        }
        guard matches(check.target, targetRoot.appending(path: action.path)) else { throw ChangedSinceComparison() }
    }

    /// Whether what is at `url` now (not following links) is what the comparison saw.
    static func matches(_ expected: Expected, _ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path(percentEncoded: false), &info) == 0 else { return expected.kind == .absent }
        let kind: FolderTree.Kind = switch info.st_mode & S_IFMT {
        case S_IFREG: .file
        case S_IFDIR: .directory
        case S_IFLNK: .symbolicLink
        default: .other
        }
        guard kind == expected.kind else { return false }
        // Folders change their dates whenever something inside changes; only files are compared closely.
        guard kind == .file else { return true }
        let modified = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        return Int64(info.st_size) == expected.size && modified == expected.modified
    }

    /// Copies one file with its dates and permissions, as an APFS clone when both are on the
    /// same volume, replacing `destination` in one step.
    static func copy(from source: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = destination.deletingLastPathComponent().appending(path: ".\(destination.lastPathComponent).moire-\(UUID().uuidString)")
        // A symbolic link is copied as a link, never as what it points to.
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_CLONE | COPYFILE_NOFOLLOW_SRC)
        guard copyfile(source.path(percentEncoded: false), temporary.path(percentEncoded: false), nil, flags) == 0 else {
            let error = POSIXError.current(path: source.path(percentEncoded: false))
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        guard rename(temporary.path(percentEncoded: false), destination.path(percentEncoded: false)) == 0 else {
            let error = POSIXError.current(path: destination.path(percentEncoded: false))
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}
