import Darwin
import Foundation

/// Saves a file the way an editor should: through symbolic links, without breaking hard links,
/// and without leaving a half-written file behind when the disk is full or the app stops.
public enum FileWriter {
    public enum Failure: LocalizedError {
        case linkLoop(String)
        case system(String, Int32)

        public var errorDescription: String? {
            switch self {
            case .linkLoop(let name): "\(name) is a symbolic link that leads back to itself."
            case let .system(name, code): "\(name): \(String(cString: strerror(code)))"
            }
        }
    }

    /// Writes `data` to the file `url` names.
    ///
    /// A symbolic link is followed to the file it points to, and that file is written, so the link
    /// stays a link. A new file is written next to the old one and moved over it only once it is
    /// complete, with the old file's permissions, owner, extended attributes and access list.
    ///
    /// The file is overwritten in place instead when it has more than one hard link (replacing it
    /// would split the links: the other names would keep the old text), when its folder does not
    /// allow a new file, or when the new file could not get the old one's owner. That keeps the
    /// links and the owner, but a write that fails halfway leaves the file half written. Editors
    /// such as vim make the same choice.
    public static func write(_ data: Data, to url: URL) throws {
        let target = try resolvingLinks(url)
        var info = stat()
        guard lstat(target.path(percentEncoded: false), &info) == 0 else {
            guard errno == ENOENT else { throw Failure.system(target.lastPathComponent, errno) }
            try data.write(to: target, options: .atomic)
            return
        }
        if info.st_nlink > 1 {
            try overwrite(target, with: data)
            return
        }
        if try !replace(target, with: data, keeping: info) {
            try overwrite(target, with: data)
        }
    }

    /// The file a chain of symbolic links ends at. A link that points nowhere gives the path it
    /// points to, so saving creates that file.
    public static func resolvingLinks(_ url: URL) throws -> URL {
        var current = url.standardizedFileURL
        for _ in 0..<32 {
            var info = stat()
            guard lstat(current.path(percentEncoded: false), &info) == 0, info.st_mode & S_IFMT == S_IFLNK else { return current }
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let length = readlink(current.path(percentEncoded: false), &buffer, buffer.count - 1)
            guard length >= 0 else { throw Failure.system(current.lastPathComponent, errno) }
            let destination = String(decoding: buffer[0..<length].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            current = destination.hasPrefix("/")
                ? URL(filePath: destination).standardizedFileURL
                : current.deletingLastPathComponent().appending(path: destination).standardizedFileURL
        }
        throw Failure.linkLoop(url.lastPathComponent)
    }

    /// Writes a complete copy next to `target` and moves it over. False when the folder does not
    /// allow a new file, or the copy could not get the owner of `target`.
    private static func replace(_ target: URL, with data: Data, keeping info: stat) throws -> Bool {
        let name = target.lastPathComponent
        let temporary = target.deletingLastPathComponent().appending(path: ".\(name).moire-\(UUID().uuidString.prefix(8))")
        let path = temporary.path(percentEncoded: false)
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            if errno == EACCES || errno == EPERM { return false }
            throw Failure.system(name, errno)
        }
        var isOpen = true
        var isMoved = false
        defer {
            if isOpen { close(descriptor) }
            if !isMoved { unlink(path) }
        }

        try writeAll(data, to: descriptor, name: name)
        if info.st_uid != geteuid() || info.st_gid != getegid() {
            guard fchown(descriptor, info.st_uid, info.st_gid) == 0 else { return false }
        }
        // After the owner: changing the owner clears the set-user-ID and set-group-ID bits.
        guard fchmod(descriptor, info.st_mode & 0o7777) == 0 else { throw Failure.system(name, errno) }
        guard copyfile(target.path(percentEncoded: false), path, nil, copyfile_flags_t(COPYFILE_ACL | COPYFILE_XATTR)) == 0 else {
            throw Failure.system(name, errno)
        }
        guard fsync(descriptor) == 0 else { throw Failure.system(name, errno) }
        isOpen = false
        guard close(descriptor) == 0 else { throw Failure.system(name, errno) }
        guard rename(path, target.path(percentEncoded: false)) == 0 else { throw Failure.system(name, errno) }
        isMoved = true
        return true
    }

    /// Writes over the file itself, keeping its inode and with it every hard link.
    private static func overwrite(_ target: URL, with data: Data) throws {
        let name = target.lastPathComponent
        let descriptor = open(target.path(percentEncoded: false), O_WRONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.system(name, errno) }
        var isOpen = true
        defer { if isOpen { close(descriptor) } }
        try writeAll(data, to: descriptor, name: name)
        guard ftruncate(descriptor, off_t(data.count)) == 0, fsync(descriptor) == 0 else { throw Failure.system(name, errno) }
        isOpen = false
        guard close(descriptor) == 0 else { throw Failure.system(name, errno) }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32, name: String) throws {
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = pwrite(descriptor, base + offset, bytes.count - offset, off_t(offset))
                if written < 0 {
                    if errno == EINTR { continue }
                    throw Failure.system(name, errno)
                }
                offset += written
            }
        }
    }
}
