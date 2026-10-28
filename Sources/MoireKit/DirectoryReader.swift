import Darwin
import Foundation

/// One item in a folder, as `getattrlistbulk` reports it.
public struct DirectoryEntry: Sendable, Hashable {
    public enum Kind: UInt8, Sendable {
        case file
        case directory
        case symbolicLink
        /// Devices, sockets and pipes: listed, never read.
        case other
    }

    public var name: String
    public var kind: Kind
    /// Logical size in bytes; 0 for folders.
    public var size: Int64
    /// Modification date in nanoseconds since 1970.
    public var modified: Int64
    public var fileID: UInt64
}

public enum DirectoryReader {
    /// Lists a folder with `getattrlistbulk`: name, kind, size, date and file ID of every item in
    /// a few system calls per folder, instead of several per item.
    ///
    /// `.` and `..` are never returned. Hidden means a name that starts with a dot.
    public static func entries(of path: String, skipHidden: Bool) throws -> [DirectoryEntry] {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError.current(path: path) }
        defer { close(descriptor) }

        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
            | attrgroup_t(ATTR_CMN_NAME)
            | attrgroup_t(ATTR_CMN_ERROR)
            | attrgroup_t(ATTR_CMN_OBJTYPE)
            | attrgroup_t(ATTR_CMN_MODTIME)
            | attrgroup_t(ATTR_CMN_FILEID)
        request.fileattr = attrgroup_t(ATTR_FILE_DATALENGTH)

        let bufferSize = 256 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }

        var result: [DirectoryEntry] = []
        while true {
            let count = getattrlistbulk(descriptor, &request, buffer, bufferSize, 0)
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw POSIXError.current(path: path)
            }
            var entry = buffer
            for _ in 0..<count {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                if let parsed = parse(entry), !(skipHidden && parsed.name.hasPrefix(".")) {
                    result.append(parsed)
                }
                entry += length
            }
        }
        return result
    }

    /// Reads one record. The layout is: length, the returned attribute set, then every returned
    /// attribute in a fixed order (error first, then name, type, date, file ID, then the file size).
    private static func parse(_ record: UnsafeMutableRawPointer) -> DirectoryEntry? {
        var cursor = record + MemoryLayout<UInt32>.size
        let returned = cursor.loadUnaligned(as: attribute_set_t.self)
        cursor += MemoryLayout<attribute_set_t>.size

        if returned.commonattr & attrgroup_t(ATTR_CMN_ERROR) != 0 {
            let error = cursor.loadUnaligned(as: UInt32.self)
            cursor += MemoryLayout<UInt32>.size
            // An item whose details could not be read; it is skipped like the system skips it.
            if error != 0 { return nil }
        }

        guard returned.commonattr & attrgroup_t(ATTR_CMN_NAME) != 0 else { return nil }
        let nameReference = cursor.loadUnaligned(as: attrreference_t.self)
        let namePointer = (cursor + Int(nameReference.attr_dataoffset)).assumingMemoryBound(to: CChar.self)
        let name = String(cString: namePointer)
        cursor += MemoryLayout<attrreference_t>.size

        var kind = DirectoryEntry.Kind.other
        if returned.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 {
            let type = cursor.loadUnaligned(as: fsobj_type_t.self)
            cursor += MemoryLayout<fsobj_type_t>.size
            kind = switch Int(type) {
            case Int(VREG.rawValue): .file
            case Int(VDIR.rawValue): .directory
            case Int(VLNK.rawValue): .symbolicLink
            default: .other
            }
        }

        var modified: Int64 = 0
        if returned.commonattr & attrgroup_t(ATTR_CMN_MODTIME) != 0 {
            let time = cursor.loadUnaligned(as: timespec.self)
            cursor += MemoryLayout<timespec>.size
            modified = Int64(time.tv_sec) * 1_000_000_000 + Int64(time.tv_nsec)
        }

        var fileID: UInt64 = 0
        if returned.commonattr & attrgroup_t(ATTR_CMN_FILEID) != 0 {
            fileID = cursor.loadUnaligned(as: UInt64.self)
            cursor += MemoryLayout<UInt64>.size
        }

        var size: Int64 = 0
        if kind == .file, returned.fileattr & attrgroup_t(ATTR_FILE_DATALENGTH) != 0 {
            size = cursor.loadUnaligned(as: off_t.self)
        }

        return DirectoryEntry(name: name, kind: kind, size: size, modified: modified, fileID: fileID)
    }
}

extension POSIXError {
    static func current(path: String) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO, userInfo: [NSFilePathErrorKey: path])
    }
}
