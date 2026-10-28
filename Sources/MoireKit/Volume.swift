import Darwin
import Foundation

/// The disk a folder lives on, as far as comparing it is concerned.
public struct Volume: Sendable, Hashable {
    /// The file system type, such as `apfs`, `smbfs` or `nfs`.
    public var fileSystem: String
    /// False for network shares (SMB, NFS, AFP, WebDAV and the like).
    public var isLocal: Bool
    /// False on case-insensitive volumes (APFS and HFS+ by default), where `Readme.md` and
    /// `README.md` are the same file.
    public var isCaseSensitive: Bool

    public init(fileSystem: String, isLocal: Bool, isCaseSensitive: Bool = true) {
        self.fileSystem = fileSystem
        self.isLocal = isLocal
        self.isCaseSensitive = isCaseSensitive
    }

    public static func of(_ path: String) throws -> Volume {
        var info = statfs()
        guard statfs(path, &info) == 0 else { throw POSIXError.current(path: path) }
        let name = withUnsafeBytes(of: info.f_fstypename) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        return Volume(fileSystem: name, isLocal: info.f_flags & UInt32(MNT_LOCAL) != 0, isCaseSensitive: pathconf(path, _PC_CASE_SENSITIVE) != 0)
    }
}
