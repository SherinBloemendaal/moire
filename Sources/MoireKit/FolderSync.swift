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
        case copy(path: String, toRight: Bool, bytes: Int64)
        case createFolder(path: String, onRight: Bool)
        /// Moves the item to the Trash, so it can be put back.
        case trash(path: String, onRight: Bool)

        public var path: String {
            switch self {
            case .copy(let path, _, _), .createFolder(let path, _), .trash(let path, _): path
            }
        }
    }

    public struct Plan: Sendable, Hashable {
        public var actions: [Action]
        public var bytesToCopy: Int64 { actions.reduce(0) { if case .copy(_, _, let bytes) = $1 { $0 + bytes } else { $0 } } }
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

        var actions: [Action] = []
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
            let path = tree.path(of: item)
            let status = tree.status(of: item)

            let new: [Action] = switch direction {
            case .leftToRight:
                oneWay(path, from: left, to: right, status: status, mode: mode, toRight: true, settings: settings)
            case .rightToLeft:
                oneWay(path, from: right, to: left, status: status, mode: mode, toRight: false, settings: settings)
            case .both:
                bothWays(path, left: left, right: right, status: status, settings: settings)
            }
            if new.contains(where: { if case .trash = $0 { true } else { false } }) { trashed[item] = true }
            actions += new
        }
        return Plan(actions: actions)
    }

    private static func oneWay(
        _ path: String, from source: FolderTree.SideInfo, to target: FolderTree.SideInfo, status: FolderTree.Status,
        mode: Mode, toRight: Bool, settings: FolderCompareSettings
    ) -> [Action] {
        switch (source.exists, target.exists) {
        case (true, false):
            return source.kind == .directory ? [.createFolder(path: path, onRight: toRight)] : [.copy(path: path, toRight: toRight, bytes: source.size)]
        case (false, true):
            return mode == .mirror ? [.trash(path: path, onRight: toRight)] : []
        case (true, true):
            guard source.kind != .directory || target.kind != .directory else { return [] }
            guard status != .identical else { return [] }
            if source.kind == .directory || target.kind == .directory {
                // A file on one side and a folder on the other: only a mirror replaces it.
                guard mode == .mirror else { return [] }
                let create: Action = source.kind == .directory ? .createFolder(path: path, onRight: toRight) : .copy(path: path, toRight: toRight, bytes: source.size)
                return [.trash(path: path, onRight: toRight), create]
            }
            if mode == .update, !isNewer(source, than: target, settings: settings) { return [] }
            return [.copy(path: path, toRight: toRight, bytes: source.size)]
        case (false, false):
            return []
        }
    }

    private static func bothWays(_ path: String, left: FolderTree.SideInfo, right: FolderTree.SideInfo, status: FolderTree.Status, settings: FolderCompareSettings) -> [Action] {
        switch (left.exists, right.exists) {
        case (true, false):
            return left.kind == .directory ? [.createFolder(path: path, onRight: true)] : [.copy(path: path, toRight: true, bytes: left.size)]
        case (false, true):
            return right.kind == .directory ? [.createFolder(path: path, onRight: false)] : [.copy(path: path, toRight: false, bytes: right.size)]
        case (true, true):
            guard status != .identical, left.kind == .file, right.kind == .file else { return [] }
            if isNewer(left, than: right, settings: settings) { return [.copy(path: path, toRight: true, bytes: left.size)] }
            if isNewer(right, than: left, settings: settings) { return [.copy(path: path, toRight: false, bytes: right.size)] }
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

    /// Carries out a plan. Files are copied next to their destination first and then moved into
    /// place, so an interrupted copy never leaves a half-written file. Returns what failed;
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
                switch action {
                case let .copy(path, toRight, _):
                    try copy(from: (toRight ? left : right).appending(path: path), to: (toRight ? right : left).appending(path: path))
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
