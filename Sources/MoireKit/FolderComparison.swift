import Foundation

/// Two folders compared file by file, as one tree of relative paths.
public struct FolderComparison: Sendable {
    public enum Status: Sendable, Hashable {
        case identical
        case different
        case leftOnly
        case rightOnly
    }

    public struct Item: Sendable, Hashable, Identifiable {
        /// Path relative to the compared folders, with `/` between components.
        public let path: String
        public let isDirectory: Bool
        public let status: Status
        public let leftSize: Int64?
        public let rightSize: Int64?

        public var id: String { path }
        public var name: String { path.split(separator: "/").last.map(String.init) ?? path }
        public var depth: Int { path.split(separator: "/").count - 1 }
    }

    public struct Options: Sendable, Hashable {
        /// Skip files and folders whose name starts with a dot (`.git`, `.DS_Store`).
        public var skipHidden: Bool

        public init(skipHidden: Bool = true) {
            self.skipHidden = skipHidden
        }
    }

    public let left: URL
    public let right: URL
    /// Depth first, folders before files, by name.
    public let items: [Item]

    public var differenceCount: Int { items.count { !$0.isDirectory && $0.status != .identical } }

    public init(left: URL, right: URL, options: Options = Options()) throws {
        self.left = left
        self.right = right

        let leftEntries = try Self.entries(in: left, options: options)
        let rightEntries = try Self.entries(in: right, options: options)
        var statuses: [String: Status] = [:]
        var items: [String: (isDirectory: Bool, left: Int64?, right: Int64?)] = [:]

        for path in Set(leftEntries.keys).union(rightEntries.keys) {
            let l = leftEntries[path]
            let r = rightEntries[path]
            switch (l, r) {
            case let (l?, r?) where l.isDirectory != r.isDirectory:
                // A file on one side and a folder on the other.
                statuses[path] = .different
                items[path] = (l.isDirectory && r.isDirectory, l.size, r.size)
            case let (l?, r?):
                if l.linkDestination != nil || r.linkDestination != nil {
                    statuses[path] = l.linkDestination == r.linkDestination ? .identical : .different
                } else if !l.isDirectory {
                    statuses[path] = try Self.sameContents(left.appending(path: path), right.appending(path: path), sizes: (l.size, r.size)) ? .identical : .different
                }
                items[path] = (l.isDirectory, l.size, r.size)
            case let (l?, nil):
                statuses[path] = .leftOnly
                items[path] = (l.isDirectory, l.size, nil)
            case let (nil, r?):
                statuses[path] = .rightOnly
                items[path] = (r.isDirectory, nil, r.size)
            case (nil, nil):
                break
            }
        }

        // A folder on both sides takes the status of what is inside it.
        var foldersWithDifferences: Set<String> = []
        for (path, status) in statuses where status != .identical {
            var parts = path.split(separator: "/").dropLast()
            while !parts.isEmpty {
                foldersWithDifferences.insert(parts.joined(separator: "/"))
                parts = parts.dropLast()
            }
        }
        for (path, item) in items where item.isDirectory && statuses[path] == nil {
            statuses[path] = foldersWithDifferences.contains(path) ? .different : .identical
        }

        self.items = items.keys
            .sorted { Self.isOrderedBefore($0, $1, directories: items.mapValues(\.isDirectory)) }
            .compactMap { path in
                guard let item = items[path] else { return nil }
                return Item(path: path, isDirectory: item.isDirectory, status: statuses[path] ?? .identical, leftSize: item.left, rightSize: item.right)
            }
    }

    private struct Entry {
        let isDirectory: Bool
        let size: Int64?
        /// Set for symbolic links, which are compared by where they point, never followed.
        let linkDestination: String?
    }

    /// Every file and folder under `root`, keyed by relative path. Symbolic links are listed but
    /// not followed, so a link to a parent folder cannot loop.
    private static func entries(in root: URL, options: Options) throws -> [String: Entry] {
        var result: [String: Entry] = [:]
        try collect(root, prefix: "", options: options, into: &result)
        return result
    }

    private static func collect(_ folder: URL, prefix: String, options: Options, into result: inout [String: Entry]) throws {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        let children = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: keys,
            options: options.skipHidden ? [.skipsHiddenFiles] : []
        )
        for child in children {
            let values = try child.resourceValues(forKeys: Set(keys))
            let path = prefix + child.lastPathComponent
            if values.isSymbolicLink == true {
                let destination = try FileManager.default.destinationOfSymbolicLink(atPath: child.path(percentEncoded: false))
                result[path] = Entry(isDirectory: false, size: nil, linkDestination: destination)
            } else if values.isDirectory == true {
                result[path] = Entry(isDirectory: true, size: nil, linkDestination: nil)
                try collect(child, prefix: path + "/", options: options, into: &result)
            } else {
                result[path] = Entry(isDirectory: false, size: values.fileSize.map(Int64.init), linkDestination: nil)
            }
        }
    }

    static func sameContents(_ a: URL, _ b: URL, sizes: (Int64?, Int64?)) throws -> Bool {
        if let left = sizes.0, let right = sizes.1, left != right { return false }
        let first = try FileHandle(forReadingFrom: a)
        defer { try? first.close() }
        let second = try FileHandle(forReadingFrom: b)
        defer { try? second.close() }
        while true {
            let chunkA = try first.read(upToCount: 1 << 16) ?? Data()
            let chunkB = try second.read(upToCount: 1 << 16) ?? Data()
            if chunkA != chunkB { return false }
            if chunkA.isEmpty { return true }
        }
    }

    /// Orders a tree depth first: a folder comes right before its contents, and within one
    /// folder subfolders come before files, each sorted by name the way Finder does.
    private static func isOrderedBefore(_ a: String, _ b: String, directories: [String: Bool]) -> Bool {
        let aParts = a.split(separator: "/")
        let bParts = b.split(separator: "/")
        for index in 0..<min(aParts.count, bParts.count) where aParts[index] != bParts[index] {
            let aPrefix = aParts[...index].joined(separator: "/")
            let bPrefix = bParts[...index].joined(separator: "/")
            let aIsDirectory = directories[aPrefix] ?? false
            let bIsDirectory = directories[bPrefix] ?? false
            if aIsDirectory != bIsDirectory { return aIsDirectory }
            return aParts[index].localizedStandardCompare(bParts[index]) == .orderedAscending
        }
        return aParts.count < bParts.count
    }
}
