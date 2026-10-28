/// The result of comparing two folders, stored as flat arrays instead of one object per item,
/// so millions of items stay compact and cheap to build from many threads.
///
/// Item 0 is the pair of compared folders itself. The children of an item sit next to each
/// other (`children(of:)`), folders first, then by name the way Finder sorts. A child always
/// has a higher index than its parent.
public struct FolderTree: Sendable {
    public enum Status: UInt8, Sendable {
        case identical
        case different
        case leftOnly
        case rightOnly
        /// Not decided yet: a folder still being read, or a file whose contents are next.
        case pending
        /// A folder that could not be read; `error(at:)` says why.
        case unreadable
    }

    public enum Kind: UInt8, Sendable {
        case file
        case directory
        case symbolicLink
        case other
        /// The item does not exist on this side.
        case absent = 0xFF

        init(_ kind: DirectoryEntry.Kind) {
            self = switch kind {
            case .file: .file
            case .directory: .directory
            case .symbolicLink: .symbolicLink
            case .other: .other
            }
        }
    }

    /// What one side knows about one item.
    public struct SideInfo: Sendable, Hashable {
        public var kind: Kind
        public var size: Int64
        /// Nanoseconds since 1970.
        public var modified: Int64
        public var fileID: UInt64

        public static let absent = SideInfo(kind: .absent, size: 0, modified: 0, fileID: 0)

        public var exists: Bool { kind != .absent }
    }

    var parents: [Int32] = [-1]
    var firstChild: [Int32] = [0]
    var childCount: [Int32] = [0]
    var nameOffsets: [UInt32] = [0]
    var nameLengths: [UInt32] = [0]
    var nameBytes: [UInt8] = []
    var leftKinds: [Kind] = [.directory]
    var rightKinds: [Kind] = [.directory]
    var leftSizes: [Int64] = [0]
    var rightSizes: [Int64] = [0]
    var leftDates: [Int64] = [0]
    var rightDates: [Int64] = [0]
    var leftIDs: [UInt64] = [0]
    var rightIDs: [UInt64] = [0]
    var statuses: [Status] = [.pending]
    /// Whether a folder's contents have been read. Files are always listed.
    var listed: [Bool] = [false]
    /// Only for the few items that need it: lines changed (line by line) and read errors.
    var changedLines: [Int32: Int] = [:]
    var errors: [Int32: String] = [:]

    public init() {}

    public var count: Int { parents.count }

    public func children(of item: Int) -> Range<Int> {
        let first = Int(firstChild[item])
        return first..<(first + Int(childCount[item]))
    }

    public func parent(of item: Int) -> Int? {
        parents[item] < 0 ? nil : Int(parents[item])
    }

    public func name(of item: Int) -> String {
        let start = Int(nameOffsets[item])
        return String(decoding: nameBytes[start..<(start + Int(nameLengths[item]))], as: UTF8.self)
    }

    /// The path relative to the compared folders, with `/` between parts. Empty for item 0.
    public func path(of item: Int) -> String {
        var parts: [String] = []
        var current = item
        while current > 0 {
            parts.append(name(of: current))
            current = Int(parents[current])
        }
        return parts.reversed().joined(separator: "/")
    }

    public func depth(of item: Int) -> Int {
        var depth = 0
        var current = Int(parents[item])
        while current > 0 {
            depth += 1
            current = Int(parents[current])
        }
        return depth
    }

    public func status(of item: Int) -> Status { statuses[item] }

    /// A folder on both sides. A file on one side and a folder on the other is not a folder here.
    public func isDirectory(_ item: Int) -> Bool {
        let left = leftKinds[item]
        let right = rightKinds[item]
        return (left == .directory || left == .absent) && (right == .directory || right == .absent)
    }

    public func left(_ item: Int) -> SideInfo {
        SideInfo(kind: leftKinds[item], size: leftSizes[item], modified: leftDates[item], fileID: leftIDs[item])
    }

    public func right(_ item: Int) -> SideInfo {
        SideInfo(kind: rightKinds[item], size: rightSizes[item], modified: rightDates[item], fileID: rightIDs[item])
    }

    /// Lines that differ, for files compared line by line.
    public func changedLines(of item: Int) -> Int? { changedLines[Int32(item)] }

    public func error(at item: Int) -> String? { errors[Int32(item)] }

    /// Items that are not folders and are not identical.
    public var differenceCount: Int {
        var total = 0
        for item in 1..<count where !isDirectory(item) && statuses[item] != .identical {
            total += 1
        }
        return total
    }

    // MARK: Building

    /// Adds the children of `parent` in one go, so they sit next to each other.
    mutating func appendChildren(_ children: [Child], to parent: Int32) -> Int32 {
        let first = Int32(count)
        firstChild[Int(parent)] = first
        childCount[Int(parent)] = Int32(children.count)
        listed[Int(parent)] = true
        for child in children {
            parents.append(parent)
            firstChild.append(0)
            childCount.append(0)
            nameOffsets.append(UInt32(nameBytes.count))
            let utf8 = child.name.utf8
            nameLengths.append(UInt32(utf8.count))
            nameBytes.append(contentsOf: utf8)
            leftKinds.append(child.left.kind)
            rightKinds.append(child.right.kind)
            leftSizes.append(child.left.size)
            rightSizes.append(child.right.size)
            leftDates.append(child.left.modified)
            rightDates.append(child.right.modified)
            leftIDs.append(child.left.fileID)
            rightIDs.append(child.right.fileID)
            statuses.append(child.status)
            let isFolder = (child.left.kind == .directory || child.left.kind == .absent) && (child.right.kind == .directory || child.right.kind == .absent)
            listed.append(!isFolder)
        }
        return first
    }

    /// Gives every folder the status of what is inside it. Children come after their parent, so
    /// one pass from the end settles every folder.
    ///
    /// While a comparison is still running, a folder is `.different` as soon as one item inside
    /// it is known to differ, `.pending` while anything inside it is still open (or it has not
    /// been listed yet), and `.identical` only when everything inside it is done and the same.
    mutating func settleFolders() {
        var differs = [Bool](repeating: false, count: count)
        var open = [Bool](repeating: false, count: count)
        for item in stride(from: count - 1, through: 1, by: -1) {
            if isDirectory(item), statuses[item] != .unreadable {
                if leftKinds[item] == .absent {
                    statuses[item] = open[item] || !listed[item] ? .pending : .rightOnly
                } else if rightKinds[item] == .absent {
                    statuses[item] = open[item] || !listed[item] ? .pending : .leftOnly
                } else if differs[item] {
                    statuses[item] = .different
                } else {
                    statuses[item] = open[item] || !listed[item] ? .pending : .identical
                }
            }
            let parent = Int(parents[item])
            switch statuses[item] {
            case .identical: break
            case .pending: open[parent] = true
            // A folder that exists on one side only differs, even while its contents are still being listed.
            case .different, .leftOnly, .rightOnly, .unreadable: differs[parent] = true
            }
            if isDirectory(item), leftKinds[item] == .absent || rightKinds[item] == .absent {
                differs[parent] = true
            }
        }
        statuses[0] = differs[0] ? .different : (open[0] || !listed[0] ? .pending : .identical)
    }

    struct Child {
        var name: String
        var left: SideInfo
        var right: SideInfo
        var status: Status
    }
}
