import Foundation

/// The parts of SFTP version 3 (draft-ietf-secsh-filexfer-02) that reading a tree needs.
enum SFTP {
    enum PacketType: UInt8 {
        case initialize = 1
        case version = 2
        case open = 3
        case close = 4
        case read = 5
        case lstat = 7
        case fstat = 8
        case opendir = 11
        case readdir = 12
        case realpath = 16
        case stat = 17
        case readlink = 19
        case status = 101
        case handle = 102
        case data = 103
        case name = 104
        case attrs = 105
    }

    enum StatusCode: UInt32 {
        case ok = 0
        case eof = 1
        case noSuchFile = 2
        case permissionDenied = 3
        case failure = 4
        case badMessage = 5
        case noConnection = 6
        case connectionLost = 7
        case unsupported = 8
    }

    static let openRead: UInt32 = 0x01

    /// File attributes. Only the fields whose flag is set are on the wire.
    struct Attributes: Hashable {
        static let sizeFlag: UInt32 = 0x01
        static let ownerFlag: UInt32 = 0x02
        static let permissionsFlag: UInt32 = 0x04
        static let timesFlag: UInt32 = 0x08
        static let extendedFlag: UInt32 = 0x8000_0000

        var size: UInt64?
        var owner: (uid: UInt32, gid: UInt32)?
        var permissions: UInt32?
        var accessed: UInt32?
        var modified: UInt32?
        var extended: [(String, String)] = []

        init(size: UInt64? = nil, permissions: UInt32? = nil, modified: UInt32? = nil) {
            self.size = size
            self.permissions = permissions
            self.modified = modified
            accessed = modified
        }

        static func == (a: Attributes, b: Attributes) -> Bool {
            a.size == b.size && a.owner?.uid == b.owner?.uid && a.owner?.gid == b.owner?.gid && a.permissions == b.permissions
                && a.accessed == b.accessed && a.modified == b.modified
                && a.extended.map(\.0) == b.extended.map(\.0) && a.extended.map(\.1) == b.extended.map(\.1)
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(size)
            hasher.combine(permissions)
            hasher.combine(modified)
        }

        /// The kind from the file type bits of the permissions. `nil` when the server sent none.
        var kind: DirectoryEntry.Kind? {
            guard let permissions else { return nil }
            return switch permissions & 0o170000 {
            case 0o100000: .file
            case 0o040000: .directory
            case 0o120000: .symbolicLink
            default: .other
            }
        }
    }

    /// One `NAME` record: the file name, the `ls -l` style line, and the attributes.
    struct Name: Hashable {
        var filename: String
        var longname: String
        var attributes: Attributes

        /// From the attributes, or from the first letter of the `ls -l` line when a server leaves
        /// the permissions out.
        var kind: DirectoryEntry.Kind {
            if let kind = attributes.kind { return kind }
            return switch longname.first {
            case "d": .directory
            case "l": .symbolicLink
            case "-": .file
            default: .other
            }
        }
    }

    /// A decoded reply from the server.
    enum Reply: Hashable {
        case version(UInt32, extensions: [String: String])
        case status(id: UInt32, code: UInt32, message: String)
        case handle(id: UInt32, Data)
        case data(id: UInt32, Data)
        case name(id: UInt32, [Name])
        case attrs(id: UInt32, Attributes)

        var id: UInt32? {
            switch self {
            case .version: nil
            case .status(let id, _, _), .handle(let id, _), .data(let id, _), .name(let id, _), .attrs(let id, _): id
            }
        }
    }

    /// A request from the client, as the fake server in the tests reads it.
    enum Request: Hashable {
        case initialize(version: UInt32)
        case open(id: UInt32, path: String, flags: UInt32)
        case close(id: UInt32, handle: Data)
        case read(id: UInt32, handle: Data, offset: UInt64, length: UInt32)
        case lstat(id: UInt32, path: String)
        case fstat(id: UInt32, handle: Data)
        case opendir(id: UInt32, path: String)
        case readdir(id: UInt32, handle: Data)
        case realpath(id: UInt32, path: String)
        case stat(id: UInt32, path: String)
        case readlink(id: UInt32, path: String)
    }
}

enum SFTPCodingError: Error, Equatable {
    case truncated
    case unknownType(UInt8)
}

/// Builds the body of one packet. `packet(_:)` adds the length and type in front.
struct SFTPWriter {
    private(set) var bytes: [UInt8] = []

    mutating func write(_ value: UInt8) { bytes.append(value) }

    mutating func write(_ value: UInt32) {
        withUnsafeBytes(of: value.bigEndian) { bytes.append(contentsOf: $0) }
    }

    mutating func write(_ value: UInt64) {
        withUnsafeBytes(of: value.bigEndian) { bytes.append(contentsOf: $0) }
    }

    mutating func write(_ data: Data) {
        write(UInt32(data.count))
        bytes.append(contentsOf: data)
    }

    mutating func write(_ string: String) { write(Data(string.utf8)) }

    mutating func write(_ attributes: SFTP.Attributes) {
        var flags: UInt32 = 0
        if attributes.size != nil { flags |= SFTP.Attributes.sizeFlag }
        if attributes.owner != nil { flags |= SFTP.Attributes.ownerFlag }
        if attributes.permissions != nil { flags |= SFTP.Attributes.permissionsFlag }
        if attributes.modified != nil || attributes.accessed != nil { flags |= SFTP.Attributes.timesFlag }
        if !attributes.extended.isEmpty { flags |= SFTP.Attributes.extendedFlag }
        write(flags)
        if let size = attributes.size { write(size) }
        if let owner = attributes.owner {
            write(owner.uid)
            write(owner.gid)
        }
        if let permissions = attributes.permissions { write(permissions) }
        if flags & SFTP.Attributes.timesFlag != 0 {
            write(attributes.accessed ?? attributes.modified ?? 0)
            write(attributes.modified ?? attributes.accessed ?? 0)
        }
        if !attributes.extended.isEmpty {
            write(UInt32(attributes.extended.count))
            for (key, value) in attributes.extended {
                write(key)
                write(value)
            }
        }
    }

    /// The finished packet: length, type, body.
    func packet(_ type: SFTP.PacketType) -> Data {
        var out = SFTPWriter()
        out.write(UInt32(bytes.count + 1))
        out.write(type.rawValue)
        return Data(out.bytes + bytes)
    }
}

/// Reads the fields of one packet body, in order.
struct SFTPReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ data: Data) { bytes = [UInt8](data) }

    var isAtEnd: Bool { offset >= bytes.count }

    mutating func readByte() throws -> UInt8 {
        guard offset < bytes.count else { throw SFTPCodingError.truncated }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func readUInt32() throws -> UInt32 {
        guard bytes.count - offset >= 4 else { throw SFTPCodingError.truncated }
        defer { offset += 4 }
        return bytes[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    mutating func readUInt64() throws -> UInt64 {
        guard bytes.count - offset >= 8 else { throw SFTPCodingError.truncated }
        defer { offset += 8 }
        return bytes[offset..<offset + 8].reduce(0) { $0 << 8 | UInt64($1) }
    }

    mutating func readData() throws -> Data {
        let length = Int(try readUInt32())
        guard bytes.count - offset >= length else { throw SFTPCodingError.truncated }
        defer { offset += length }
        return Data(bytes[offset..<offset + length])
    }

    /// Names on a server are bytes; ones that are not valid UTF-8 get replacement characters.
    mutating func readString() throws -> String {
        String(decoding: try readData(), as: UTF8.self)
    }

    mutating func readAttributes() throws -> SFTP.Attributes {
        let flags = try readUInt32()
        var attributes = SFTP.Attributes()
        attributes.accessed = nil
        if flags & SFTP.Attributes.sizeFlag != 0 { attributes.size = try readUInt64() }
        if flags & SFTP.Attributes.ownerFlag != 0 { attributes.owner = (try readUInt32(), try readUInt32()) }
        if flags & SFTP.Attributes.permissionsFlag != 0 { attributes.permissions = try readUInt32() }
        if flags & SFTP.Attributes.timesFlag != 0 {
            attributes.accessed = try readUInt32()
            attributes.modified = try readUInt32()
        }
        if flags & SFTP.Attributes.extendedFlag != 0 {
            let count = try readUInt32()
            for _ in 0..<count {
                attributes.extended.append((try readString(), try readString()))
            }
        }
        return attributes
    }
}

extension SFTP.Reply {
    /// Decodes one packet without its length field: the type byte, then the body.
    init(packet: Data) throws {
        var reader = SFTPReader(packet)
        let rawType = try reader.readByte()
        guard let type = SFTP.PacketType(rawValue: rawType) else { throw SFTPCodingError.unknownType(rawType) }
        switch type {
        case .version:
            let version = try reader.readUInt32()
            var extensions: [String: String] = [:]
            while !reader.isAtEnd {
                let name = try reader.readString()
                extensions[name] = try reader.readString()
            }
            self = .version(version, extensions: extensions)
        case .status:
            let id = try reader.readUInt32()
            let code = try reader.readUInt32()
            // Version 3 servers may leave out the message and language.
            let message = reader.isAtEnd ? "" : try reader.readString()
            self = .status(id: id, code: code, message: message)
        case .handle:
            self = .handle(id: try reader.readUInt32(), try reader.readData())
        case .data:
            self = .data(id: try reader.readUInt32(), try reader.readData())
        case .name:
            let id = try reader.readUInt32()
            let count = try reader.readUInt32()
            var names: [SFTP.Name] = []
            names.reserveCapacity(Int(min(count, 4096)))
            for _ in 0..<count {
                names.append(SFTP.Name(filename: try reader.readString(), longname: try reader.readString(), attributes: try reader.readAttributes()))
            }
            self = .name(id: id, names)
        case .attrs:
            self = .attrs(id: try reader.readUInt32(), try reader.readAttributes())
        default:
            throw SFTPCodingError.unknownType(rawType)
        }
    }

    /// The packet a server sends for this reply, with its length field.
    var packet: Data {
        var writer = SFTPWriter()
        switch self {
        case let .version(version, extensions):
            writer.write(version)
            for (name, value) in extensions.sorted(by: { $0.key < $1.key }) {
                writer.write(name)
                writer.write(value)
            }
            return writer.packet(.version)
        case let .status(id, code, message):
            writer.write(id)
            writer.write(code)
            writer.write(message)
            writer.write("en")
            return writer.packet(.status)
        case let .handle(id, handle):
            writer.write(id)
            writer.write(handle)
            return writer.packet(.handle)
        case let .data(id, data):
            writer.write(id)
            writer.write(data)
            return writer.packet(.data)
        case let .name(id, names):
            writer.write(id)
            writer.write(UInt32(names.count))
            for name in names {
                writer.write(name.filename)
                writer.write(name.longname)
                writer.write(name.attributes)
            }
            return writer.packet(.name)
        case let .attrs(id, attributes):
            writer.write(id)
            writer.write(attributes)
            return writer.packet(.attrs)
        }
    }
}

extension SFTP.Request {
    /// Decodes one packet without its length field.
    init(packet: Data) throws {
        var reader = SFTPReader(packet)
        let rawType = try reader.readByte()
        guard let type = SFTP.PacketType(rawValue: rawType) else { throw SFTPCodingError.unknownType(rawType) }
        switch type {
        case .initialize:
            self = .initialize(version: try reader.readUInt32())
        case .open:
            let id = try reader.readUInt32()
            let path = try reader.readString()
            let flags = try reader.readUInt32()
            _ = try reader.readAttributes()
            self = .open(id: id, path: path, flags: flags)
        case .close:
            self = .close(id: try reader.readUInt32(), handle: try reader.readData())
        case .read:
            self = .read(id: try reader.readUInt32(), handle: try reader.readData(), offset: try reader.readUInt64(), length: try reader.readUInt32())
        case .lstat:
            self = .lstat(id: try reader.readUInt32(), path: try reader.readString())
        case .fstat:
            self = .fstat(id: try reader.readUInt32(), handle: try reader.readData())
        case .opendir:
            self = .opendir(id: try reader.readUInt32(), path: try reader.readString())
        case .readdir:
            self = .readdir(id: try reader.readUInt32(), handle: try reader.readData())
        case .realpath:
            self = .realpath(id: try reader.readUInt32(), path: try reader.readString())
        case .stat:
            self = .stat(id: try reader.readUInt32(), path: try reader.readString())
        case .readlink:
            self = .readlink(id: try reader.readUInt32(), path: try reader.readString())
        default:
            throw SFTPCodingError.unknownType(rawType)
        }
    }

    /// The packet a client sends for this request, with its length field.
    var packet: Data {
        var writer = SFTPWriter()
        switch self {
        case .initialize(let version):
            writer.write(version)
            return writer.packet(.initialize)
        case let .open(id, path, flags):
            writer.write(id)
            writer.write(path)
            writer.write(flags)
            writer.write(UInt32(0))
            return writer.packet(.open)
        case let .close(id, handle):
            writer.write(id)
            writer.write(handle)
            return writer.packet(.close)
        case let .read(id, handle, offset, length):
            writer.write(id)
            writer.write(handle)
            writer.write(offset)
            writer.write(length)
            return writer.packet(.read)
        case let .lstat(id, path):
            return Self.pathPacket(.lstat, id, path)
        case let .fstat(id, handle):
            writer.write(id)
            writer.write(handle)
            return writer.packet(.fstat)
        case let .opendir(id, path):
            return Self.pathPacket(.opendir, id, path)
        case let .readdir(id, handle):
            writer.write(id)
            writer.write(handle)
            return writer.packet(.readdir)
        case let .realpath(id, path):
            return Self.pathPacket(.realpath, id, path)
        case let .stat(id, path):
            return Self.pathPacket(.stat, id, path)
        case let .readlink(id, path):
            return Self.pathPacket(.readlink, id, path)
        }
    }

    private static func pathPacket(_ type: SFTP.PacketType, _ id: UInt32, _ path: String) -> Data {
        var writer = SFTPWriter()
        writer.write(id)
        writer.write(path)
        return writer.packet(type)
    }

    var id: UInt32? {
        switch self {
        case .initialize: nil
        case .open(let id, _, _), .close(let id, _), .read(let id, _, _, _), .lstat(let id, _), .fstat(let id, _),
             .opendir(let id, _), .readdir(let id, _), .realpath(let id, _), .stat(let id, _), .readlink(let id, _): id
        }
    }

    /// The same request with another ID.
    func with(id: UInt32) -> SFTP.Request {
        switch self {
        case .initialize: self
        case let .open(_, path, flags): .open(id: id, path: path, flags: flags)
        case let .close(_, handle): .close(id: id, handle: handle)
        case let .read(_, handle, offset, length): .read(id: id, handle: handle, offset: offset, length: length)
        case let .lstat(_, path): .lstat(id: id, path: path)
        case let .fstat(_, handle): .fstat(id: id, handle: handle)
        case let .opendir(_, path): .opendir(id: id, path: path)
        case let .readdir(_, handle): .readdir(id: id, handle: handle)
        case let .realpath(_, path): .realpath(id: id, path: path)
        case let .stat(_, path): .stat(id: id, path: path)
        case let .readlink(_, path): .readlink(id: id, path: path)
        }
    }
}
