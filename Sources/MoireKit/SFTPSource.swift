import Foundation

/// A folder on an SFTP server, reached through the system `ssh`. Keys, the agent, `~/.ssh/config`
/// and `known_hosts` work exactly as in Terminal; there is never a password prompt, so a host
/// that needs one fails with ssh's own explanation instead.
public final class SFTPSource: FolderSource {
    public let displayName: String
    public let volume = Volume(fileSystem: "sftp", isLocal: false)
    /// The folder on the server, as an absolute path.
    public let root: String
    let connection: SFTPConnection

    public convenience init(location: RemoteLocation) throws {
        let transport = try ProcessTransport(executable: "/usr/bin/ssh", arguments: Self.sshArguments(for: location))
        try self.init(connection: SFTPConnection(transport: transport), path: Self.serverPath(location.path), displayName: location.displayName)
    }

    /// Opens `path` on an established session. Relative paths start in the login folder.
    init(connection: SFTPConnection, path: String, displayName: String) throws {
        self.connection = connection
        self.displayName = displayName
        root = try connection.realpath(path)
        let attributes = try connection.stat(root)
        guard attributes.kind == .directory || attributes.kind == nil else {
            throw RemoteError("\(root) on the server is not a folder.")
        }
    }

    deinit {
        connection.close()
    }

    static func sshArguments(for location: RemoteLocation) -> [String] {
        var arguments = [
            "-s",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=20",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
        ]
        if let port = location.port { arguments += ["-p", String(port)] }
        if let user = location.user { arguments += ["-l", user] }
        // `--` so a host name can never be read as an option.
        arguments += ["--", location.host, "sftp"]
        return arguments
    }

    /// The URL path on the server: like curl, `/~/x` is `x` in the login folder, and an empty
    /// path is the login folder itself.
    static func serverPath(_ urlPath: String) -> String {
        if urlPath.isEmpty || urlPath == "/~" { return "." }
        if urlPath.hasPrefix("/~/") { return String(urlPath.dropFirst(3)) }
        return urlPath
    }

    private func absolute(_ path: String) -> String {
        path.isEmpty ? root : (root.hasSuffix("/") ? root + path : root + "/" + path)
    }

    public func list(_ path: String, skipHidden: Bool) throws -> [DirectoryEntry] {
        try connection.list(absolute(path)).compactMap { name in
            if skipHidden, name.filename.hasPrefix(".") { return nil }
            // A name with a slash would point somewhere else; no real server sends one.
            if name.filename.contains("/") || name.filename.isEmpty { return nil }
            let kind = name.kind
            let size = kind == .file ? Int64(clamping: name.attributes.size ?? 0) : 0
            let modified = Int64(name.attributes.modified ?? 0) * 1_000_000_000
            return DirectoryEntry(name: name.filename, kind: kind, size: size, modified: modified, fileID: 0)
        }
    }

    public func open(_ path: String) throws -> any ReadableFile {
        let absolute = absolute(path)
        let handle = try connection.openFile(absolute)
        do {
            let attributes = try connection.fstat(handle, path: absolute)
            return SFTPFile(connection: connection, handle: handle, path: absolute, size: Int64(clamping: attributes.size ?? 0))
        } catch {
            connection.closeHandle(handle)
            throw error
        }
    }

    public func linkDestination(_ path: String) throws -> String {
        try connection.readlink(absolute(path))
    }

    public func localURL(_ path: String) -> URL? { nil }
}

/// A file on an SFTP server. Sequential reads keep many requests in flight, so a file streams
/// at the speed of the link instead of one round trip per chunk.
final class SFTPFile: ReadableFile {
    let size: Int64
    private let connection: SFTPConnection
    private let handle: Data
    private let path: String

    /// Every server must take reads this big; bigger ones may be cut short or refused.
    static let chunk = 32 * 1024
    /// Reads in flight while streaming: 1 MB.
    static let window = 32

    private struct Request {
        let offset: Int64
        let length: Int
        let pending: SFTPConnection.Pending
    }

    private var queue: [Request] = []
    private var queueHead = 0
    private var nextOffset: Int64 = 0
    private var leftover = Data()
    private var reachedEnd = false

    init(connection: SFTPConnection, handle: Data, path: String, size: Int64) {
        self.connection = connection
        self.handle = handle
        self.path = path
        self.size = size
    }

    deinit {
        for request in queue[queueHead...] { connection.discard(request.pending) }
        connection.closeHandle(handle)
    }

    private func send(offset: Int64, length: Int) throws(RemoteError) -> Request {
        let pending = try connection.send(.read(id: 0, handle: handle, offset: UInt64(offset), length: UInt32(length)))
        return Request(offset: offset, length: length, pending: pending)
    }

    private func fillWindow() throws(RemoteError) {
        while queue.count - queueHead < Self.window, nextOffset < size, !reachedEnd {
            let length = Int(min(Int64(Self.chunk), size - nextOffset))
            queue.append(try send(offset: nextOffset, length: length))
            nextOffset += Int64(length)
        }
        if queueHead > 256 {
            queue.removeFirst(queueHead)
            queueHead = 0
        }
    }

    /// The next piece of the file in order, or `nil` at the end.
    private func nextPiece() throws(RemoteError) -> Data? {
        try fillWindow()
        guard queueHead < queue.count else { return nil }
        let request = queue[queueHead]
        queueHead += 1
        let reply = try connection.wait(request.pending)
        switch reply {
        case .data(_, let data) where !data.isEmpty:
            if data.count < request.length {
                // A short read: ask for the rest right away and put it first in line.
                let rest = try send(offset: request.offset + Int64(data.count), length: request.length - data.count)
                queueHead -= 1
                queue[queueHead] = rest
            }
            return data
        case .data, .status(_, SFTP.StatusCode.eof.rawValue, _):
            // The file is shorter than it was when opened.
            reachedEnd = true
            for request in queue[queueHead...] { connection.discard(request.pending) }
            queueHead = queue.count
            return nil
        default:
            throw SFTPConnection.unexpected(reply, path)
        }
    }

    func readNext(into buffer: UnsafeMutableRawPointer, count: Int) throws -> Int {
        var total = 0
        while total < count {
            if leftover.isEmpty {
                guard let piece = try nextPiece() else { break }
                leftover = piece
            }
            let take = min(count - total, leftover.count)
            leftover.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                (buffer + total).copyMemory(from: base, byteCount: take)
            }
            leftover = take == leftover.count ? Data() : Data(leftover.dropFirst(take))
            total += take
        }
        return total
    }

    func read(at offset: Int64, count: Int) throws -> Data {
        var result = Data(capacity: count)
        var position = offset
        let end = offset + Int64(count)
        while position < end {
            // All the chunks of what is left at once, then in order.
            var requests: [Request] = []
            var cursor = position
            while cursor < end {
                let length = Int(min(Int64(Self.chunk), end - cursor))
                requests.append(try send(offset: cursor, length: length))
                cursor += Int64(length)
            }
            var shortened = false
            for (index, request) in requests.enumerated() {
                if shortened {
                    connection.discard(request.pending)
                    continue
                }
                let reply = try connection.wait(request.pending)
                switch reply {
                case .data(_, let data) where !data.isEmpty:
                    result.append(data)
                    position += Int64(data.count)
                    // The rest of the range is asked for again from where this one stopped.
                    if data.count < request.length { shortened = true }
                case .data, .status(_, SFTP.StatusCode.eof.rawValue, _):
                    for later in requests[(index + 1)...] { connection.discard(later.pending) }
                    return result
                default:
                    for later in requests[(index + 1)...] { connection.discard(later.pending) }
                    throw SFTPConnection.unexpected(reply, path)
                }
            }
        }
        return result
    }
}
