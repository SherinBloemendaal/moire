import Darwin
import Foundation

/// Where one side of a folder comparison comes from: a local folder, or a remote one (SFTP, FTP,
/// S3). Paths are relative to the source's root, with `/` between parts; `""` is the root.
public protocol FolderSource: Sendable {
    /// Shown to the user, e.g. `~/Code/app` or `sftp://host/srv/app`.
    var displayName: String { get }
    /// Decides the default compare method and how many requests run at once.
    var volume: Volume { get }
    /// The items in a folder.
    func list(_ path: String, skipHidden: Bool) throws -> [DirectoryEntry]
    /// Opens a file for reading.
    func open(_ path: String) throws -> any ReadableFile
    /// Opens a file whose size the folder listing reported. Remote sources use it to skip asking
    /// the server for the size again, which costs a round trip per file.
    func open(_ path: String, listedSize: Int64) throws -> any ReadableFile
    /// Where a symbolic link points.
    func linkDestination(_ path: String) throws -> String
    /// The local file for `path`, when there is one. Lets the app open, sync and edit it.
    func localURL(_ path: String) -> URL?
}

/// A file opened for reading. Sequential reads and reads at an offset can be mixed.
public protocol ReadableFile: AnyObject {
    var size: Int64 { get }
    /// Fills `buffer` as far as the file allows; returns the bytes read, 0 at the end.
    func readNext(into buffer: UnsafeMutableRawPointer, count: Int) throws -> Int
    func read(at offset: Int64, count: Int) throws -> Data
}

extension FolderSource {
    public func open(_ path: String, listedSize: Int64) throws -> any ReadableFile {
        try open(path)
    }
}

extension ReadableFile {
    /// The whole file. For line by line comparison, which needs all of it anyway.
    public func readAll() throws -> Data {
        var data = Data(capacity: Int(size))
        let chunk = 1 << 20
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16)
        defer { buffer.deallocate() }
        while true {
            let read = try readNext(into: buffer, count: chunk)
            if read == 0 { return data }
            data.append(buffer.assumingMemoryBound(to: UInt8.self), count: read)
        }
    }
}

/// A folder on this Mac.
public struct LocalSource: FolderSource {
    public let root: URL
    public let volume: Volume
    private let rootPath: String

    public init(_ root: URL) throws {
        self.root = root
        rootPath = root.path(percentEncoded: false)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: rootPath])
        }
        volume = try Volume.of(rootPath)
    }

    public var displayName: String { (rootPath as NSString).abbreviatingWithTildeInPath }

    private func absolute(_ path: String) -> String {
        path.isEmpty ? rootPath : (rootPath.hasSuffix("/") ? rootPath + path : rootPath + "/" + path)
    }

    public func list(_ path: String, skipHidden: Bool) throws -> [DirectoryEntry] {
        try DirectoryReader.entries(of: absolute(path), skipHidden: skipHidden)
    }

    public func open(_ path: String) throws -> any ReadableFile {
        try LocalFile(absolute(path))
    }

    public func linkDestination(_ path: String) throws -> String {
        try FileManager.default.destinationOfSymbolicLink(atPath: absolute(path))
    }

    public func localURL(_ path: String) -> URL? {
        path.isEmpty ? root : root.appending(path: path)
    }
}

/// A local file read with plain `read` calls.
///
/// Memory mapping is avoided on purpose: when a mapped file shrinks while it is being read (a
/// file being written, or a share that drops), the process crashes instead of getting an error.
final class LocalFile: ReadableFile {
    let descriptor: Int32
    let size: Int64
    /// Whether reads bypass the file cache: set for files of `uncachedFrom` bytes or more.
    let bypassesCache: Bool

    /// Above this size a read bypasses the file cache, so one huge file does not push out the
    /// cached contents of everything else.
    static let uncachedFrom: Int64 = 256 << 20

    init(_ path: String) throws {
        descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError.current(path: path) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            let error = POSIXError.current(path: path)
            Darwin.close(descriptor)
            throw error
        }
        size = Int64(info.st_size)
        bypassesCache = size >= Self.uncachedFrom && fcntl(descriptor, F_NOCACHE, 1) != -1
    }

    deinit { Darwin.close(descriptor) }

    func readNext(into buffer: UnsafeMutableRawPointer, count: Int) throws -> Int {
        var total = 0
        while total < count {
            let result = Darwin.read(descriptor, buffer + total, count - total)
            if result == 0 { break }
            if result < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            total += result
        }
        return total
    }

    func read(at offset: Int64, count: Int) throws -> Data {
        var data = Data(count: count)
        let total = try data.withUnsafeMutableBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            var total = 0
            while total < count {
                let result = pread(descriptor, base + total, count - total, off_t(offset) + off_t(total))
                if result == 0 { break }
                if result < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                total += result
            }
            return total
        }
        return data.prefix(total)
    }
}
