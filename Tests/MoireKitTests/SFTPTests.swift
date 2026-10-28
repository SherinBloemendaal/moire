import Darwin
import Foundation
@testable import MoireKit
import Synchronization
import Testing

/// Both ends of a pair of pipes, so a client and a server in this process can talk.
private final class PipeTransport: SFTPTransport {
    let readFrom: Int32
    let writeTo: Int32
    private let closed = Atomic<Bool>(false)

    init(readFrom: Int32, writeTo: Int32) {
        self.readFrom = readFrom
        self.writeTo = writeTo
        _ = fcntl(writeTo, F_SETNOSIGPIPE, 1)
    }

    func write(_ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var done = 0
            while done < bytes.count {
                let result = Darwin.write(writeTo, base + done, bytes.count - done)
                guard result > 0 else { throw POSIXError(.EPIPE) }
                done += result
            }
        }
    }

    func readExactly(into buffer: UnsafeMutableRawPointer, count: Int) throws -> Bool {
        var done = 0
        while done < count {
            let result = Darwin.read(readFrom, buffer + done, count - done)
            if result < 0, errno == EINTR { continue }
            guard result > 0 else { return false }
            done += result
        }
        return true
    }

    func close() {
        if !closed.exchange(true, ordering: .relaxed) { Darwin.close(writeTo) }
    }

    func failureDescription() -> String? { nil }

    static func pair() -> (client: PipeTransport, server: PipeTransport) {
        var toServer: [Int32] = [-1, -1]
        var toClient: [Int32] = [-1, -1]
        pipe(&toServer)
        pipe(&toClient)
        return (PipeTransport(readFrom: toClient[0], writeTo: toServer[1]), PipeTransport(readFrom: toServer[0], writeTo: toClient[1]))
    }
}

/// An SFTP server on a thread that keeps its files in memory. It answers requests in reverse
/// order in small batches and cuts every read short, to test what real servers are allowed to do.
private final class FakeServer: Sendable {
    let transport: PipeTransport
    let files: [String: Data]
    let folders: Set<String>
    let links: [String: String]
    let maximumRead: Int
    let requests = Atomic<Int>(0)
    private let handleCounter = Atomic<Int>(0)

    private func nextHandle() -> Int { handleCounter.add(1, ordering: .relaxed).newValue }

    init(transport: PipeTransport, files: [String: Data], links: [String: String] = [:], maximumRead: Int = 1000) {
        self.transport = transport
        self.files = files
        self.links = links
        self.maximumRead = maximumRead
        var folders: Set<String> = ["/"]
        for path in Array(files.keys) + Array(links.keys) {
            var parts = path.split(separator: "/").dropLast()
            while !parts.isEmpty {
                folders.insert("/" + parts.joined(separator: "/"))
                parts = parts.dropLast()
            }
        }
        self.folders = folders
        let thread = Thread { [self] in serve() }
        thread.start()
    }

    private func readPacket() -> Data? {
        var length: UInt32 = 0
        let ok = withUnsafeMutableBytes(of: &length) { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            return (try? transport.readExactly(into: base, count: 4)) ?? false
        }
        guard ok else { return nil }
        let size = Int(UInt32(bigEndian: length))
        var packet = Data(count: size)
        let complete = packet.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            return (try? transport.readExactly(into: base, count: size)) ?? false
        }
        return complete ? packet : nil
    }

    private func attributes(_ path: String) -> SFTP.Attributes? {
        if let data = files[path] { return SFTP.Attributes(size: UInt64(data.count), permissions: 0o100644, modified: 1_700_000_000) }
        if folders.contains(path) { return SFTP.Attributes(size: 0, permissions: 0o040755, modified: 1_700_000_000) }
        if links[path] != nil { return SFTP.Attributes(size: 1, permissions: 0o120777, modified: 1_700_000_000) }
        return nil
    }

    private func noSuchFile(_ id: UInt32) -> SFTP.Reply { .status(id: id, code: SFTP.StatusCode.noSuchFile.rawValue, message: "") }

    private func answer(_ request: SFTP.Request, handles: inout [Data: (path: String, listed: Bool)]) -> SFTP.Reply? {
        switch request {
        case .initialize:
            return .version(3, extensions: [:])
        case let .realpath(id, path):
            let resolved = path == "." ? "/" : path
            return .name(id: id, [SFTP.Name(filename: resolved, longname: resolved, attributes: SFTP.Attributes())])
        case let .stat(id, path), let .lstat(id, path):
            return attributes(path).map { .attrs(id: id, $0) } ?? noSuchFile(id)
        case let .opendir(id, path):
            guard folders.contains(path) else { return noSuchFile(id) }
            let handle = Data("d\(nextHandle())".utf8)
            handles[handle] = (path, false)
            return .handle(id: id, handle)
        case let .readdir(id, handle):
            guard let (path, listed) = handles[handle] else { return noSuchFile(id) }
            if listed { return .status(id: id, code: SFTP.StatusCode.eof.rawValue, message: "") }
            handles[handle] = (path, true)
            let prefix = path == "/" ? "/" : path + "/"
            var names: Set<String> = [".", ".."]
            for item in Array(files.keys) + Array(folders) + Array(links.keys) where item.hasPrefix(prefix) && item != path {
                if let name = item.dropFirst(prefix.count).split(separator: "/").first { names.insert(String(name)) }
            }
            return .name(id: id, names.sorted().map { name in
                let attributes = name == "." || name == ".." ? SFTP.Attributes(permissions: 0o040755) : (self.attributes(prefix + name) ?? SFTP.Attributes())
                return SFTP.Name(filename: name, longname: name, attributes: attributes)
            })
        case let .open(id, path, _):
            guard files[path] != nil else { return noSuchFile(id) }
            let handle = Data("f\(nextHandle())".utf8)
            handles[handle] = (path, false)
            return .handle(id: id, handle)
        case let .fstat(id, handle):
            guard let (path, _) = handles[handle], let attributes = attributes(path) else { return noSuchFile(id) }
            return .attrs(id: id, attributes)
        case let .read(id, handle, offset, length):
            guard let (path, _) = handles[handle], let data = files[path] else { return noSuchFile(id) }
            guard offset < UInt64(data.count) else { return .status(id: id, code: SFTP.StatusCode.eof.rawValue, message: "") }
            let end = min(data.count, Int(offset) + min(Int(length), maximumRead))
            return .data(id: id, data.subdata(in: Int(offset)..<end))
        case let .close(id, handle):
            handles[handle] = nil
            return .status(id: id, code: 0, message: "")
        case let .readlink(id, path):
            guard let target = links[path] else { return noSuchFile(id) }
            return .name(id: id, [SFTP.Name(filename: target, longname: target, attributes: SFTP.Attributes())])
        }
    }

    private func serve() {
        var handles: [Data: (path: String, listed: Bool)] = [:]
        var batch: [SFTP.Reply] = []
        func flush() {
            for reply in batch.reversed() { try? transport.write(reply.packet) }
            batch.removeAll()
        }
        while let packet = readPacket() {
            guard let request = try? SFTP.Request(packet: packet) else { return }
            requests.add(1, ordering: .relaxed)
            guard let reply = answer(request, handles: &handles) else { continue }
            batch.append(reply)
            // Reply when nothing else waits, so a lone request is never held back.
            var pending = pollfd(fd: transport.readFrom, events: Int16(POLLIN), revents: 0)
            if batch.count >= 4 || poll(&pending, 1, 2) == 0 { flush() }
        }
        flush()
        transport.close()
    }
}

private func randomData(_ count: Int, seed: UInt64) -> Data {
    var state = seed
    var bytes = [UInt8](repeating: 0, count: count)
    for index in bytes.indices {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        bytes[index] = UInt8(truncatingIfNeeded: state >> 33)
    }
    return Data(bytes)
}

struct SFTPPacketTests {
    @Test func `requests encode as the draft describes`() throws {
        let packet = SFTP.Request.open(id: 7, path: "/a", flags: SFTP.openRead).packet
        // length 19, OPEN, id 7, "/a", READ, no attributes
        #expect([UInt8](packet) == [0, 0, 0, 19, 3, 0, 0, 0, 7, 0, 0, 0, 2, 0x2f, 0x61, 0, 0, 0, 1, 0, 0, 0, 0])
        #expect(try SFTP.Request(packet: packet.dropFirst(4)) == .open(id: 7, path: "/a", flags: 1))
    }

    @Test func `every request survives a round trip`() throws {
        let requests: [SFTP.Request] = [
            .initialize(version: 3), .open(id: 1, path: "ü/x", flags: 1), .close(id: 2, handle: Data([1, 2])),
            .read(id: 3, handle: Data([9]), offset: 1 << 40, length: 32768), .lstat(id: 4, path: "l"), .fstat(id: 5, handle: Data()),
            .opendir(id: 6, path: "/"), .readdir(id: 7, handle: Data([0])), .realpath(id: 8, path: "."), .stat(id: 9, path: "s"),
            .readlink(id: 10, path: "k"),
        ]
        for request in requests {
            #expect(try SFTP.Request(packet: request.packet.dropFirst(4)) == request)
        }
    }

    @Test func `replies with every attribute decode`() throws {
        var attributes = SFTP.Attributes(size: 1 << 33, permissions: 0o100600, modified: 1_700_000_123)
        attributes.owner = (501, 20)
        attributes.accessed = 1_600_000_000
        attributes.extended = [("a@example.com", "x")]
        let replies: [SFTP.Reply] = [
            .version(3, extensions: ["limits@openssh.com": "1"]),
            .status(id: 1, code: 2, message: "No such file"),
            .handle(id: 2, Data("h".utf8)),
            .data(id: 3, Data([0, 255])),
            .name(id: 4, [SFTP.Name(filename: "f", longname: "-rw------- f", attributes: attributes)]),
            .attrs(id: 5, attributes),
        ]
        for reply in replies {
            #expect(try SFTP.Reply(packet: reply.packet.dropFirst(4)) == reply)
        }
    }

    @Test func `a status without message from an old server decodes`() throws {
        var writer = SFTPWriter()
        writer.write(UInt32(9))
        writer.write(UInt32(1))
        #expect(try SFTP.Reply(packet: writer.packet(.status).dropFirst(4)) == .status(id: 9, code: 1, message: ""))
    }

    @Test func `truncated packets throw`() {
        let packet = SFTP.Reply.handle(id: 1, Data("handle".utf8)).packet.dropFirst(4).dropLast(2)
        #expect(throws: SFTPCodingError.truncated) { try SFTP.Reply(packet: Data(packet)) }
    }

    @Test func `kinds come from the permissions or the long name`() {
        #expect(SFTP.Name(filename: "a", longname: "", attributes: SFTP.Attributes(permissions: 0o040755)).kind == .directory)
        #expect(SFTP.Name(filename: "a", longname: "", attributes: SFTP.Attributes(permissions: 0o120777)).kind == .symbolicLink)
        #expect(SFTP.Name(filename: "a", longname: "lrwxr-xr-x 1 u g 1 Jan 1 a -> b", attributes: SFTP.Attributes()).kind == .symbolicLink)
        #expect(SFTP.Name(filename: "a", longname: "-rw-r--r-- 1 u g 1 Jan 1 a", attributes: SFTP.Attributes()).kind == .file)
    }

    @Test func `URL paths map to server paths like curl`() {
        #expect(SFTPSource.serverPath("") == ".")
        #expect(SFTPSource.serverPath("/~") == ".")
        #expect(SFTPSource.serverPath("/~/sites/app") == "sites/app")
        #expect(SFTPSource.serverPath("/srv/app") == "/srv/app")
    }

    @Test func `ssh runs in batch mode with the port and user`() {
        let location = RemoteLocation(scheme: .sftp, user: "deploy", host: "example.com", port: 2222, path: "/srv")
        let arguments = SFTPSource.sshArguments(for: location)
        #expect(arguments.first == "-s")
        #expect(arguments.contains("BatchMode=yes"))
        #expect(arguments.suffix(5) == ["-l", "deploy", "--", "example.com", "sftp"])
        #expect(arguments.contains("2222"))
    }
}

struct SFTPConnectionTests {
    private func connect(files: [String: Data], links: [String: String] = [:], maximumRead: Int = 1000) throws -> (SFTPSource, FakeServer) {
        let (client, serverSide) = PipeTransport.pair()
        let server = FakeServer(transport: serverSide, files: files, links: links, maximumRead: maximumRead)
        let connection = try SFTPConnection(transport: client)
        return (try SFTPSource(connection: connection, path: ".", displayName: "fake"), server)
    }

    @Test func `lists folders with kinds, sizes and dates`() throws {
        let (source, _) = try connect(files: ["/a.txt": Data("hello".utf8), "/sub/b.txt": Data("b".utf8), "/.hidden": Data()], links: ["/link": "a.txt"])
        let entries = try source.list("", skipHidden: true)
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })
        #expect(Set(byName.keys) == ["a.txt", "sub", "link"])
        #expect(byName["a.txt"]?.kind == .file)
        #expect(byName["a.txt"]?.size == 5)
        #expect(byName["a.txt"]?.modified == 1_700_000_000_000_000_000)
        #expect(byName["sub"]?.kind == .directory)
        #expect(byName["link"]?.kind == .symbolicLink)
        #expect(try source.linkDestination("link") == "a.txt")
        #expect(try source.list("sub", skipHidden: false).map(\.name) == ["b.txt"])
        #expect(try source.list("", skipHidden: false).contains { $0.name == ".hidden" })
    }

    @Test func `streams a file whose reads are all cut short and answered out of order`() throws {
        let data = randomData(300_000, seed: 1)
        let (source, _) = try connect(files: ["/big.bin": data])
        let file = try source.open("big.bin")
        #expect(file.size == 300_000)
        #expect(try file.readAll() == data)
    }

    @Test func `reads at an offset, across chunks and past the end`() throws {
        let data = randomData(100_000, seed: 2)
        let (source, _) = try connect(files: ["/f": data])
        let file = try source.open("f")
        #expect(try file.read(at: 70_000, count: 20_000) == data.subdata(in: 70_000..<90_000))
        #expect(try file.read(at: 95_000, count: 10_000) == data.subdata(in: 95_000..<100_000))
        #expect(try file.read(at: 200_000, count: 10).isEmpty)
        // Sequential reads are not moved by reads at an offset.
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 10, alignment: 1)
        defer { buffer.deallocate() }
        #expect(try file.readNext(into: buffer, count: 10) == 10)
        #expect(Data(bytes: buffer, count: 10) == data.prefix(10))
    }

    @Test func `many threads share one connection`() throws {
        let files = Dictionary(uniqueKeysWithValues: (0..<40).map { index in
            ("/d\(index % 5)/f\(index)", randomData(5_000 + index * 997, seed: UInt64(index)))
        })
        let (source, _) = try connect(files: files, maximumRead: 4096)
        let failures = Mutex<[String]>([])
        DispatchQueue.concurrentPerform(iterations: 40) { index in
            let path = "d\(index % 5)/f\(index)"
            do {
                let listed = try source.list("d\(index % 5)", skipHidden: true)
                guard listed.contains(where: { $0.name == "f\(index)" }) else { throw RemoteError("missing \(path)") }
                guard try source.open(path).readAll() == files["/" + path] else { throw RemoteError("wrong bytes in \(path)") }
            } catch {
                failures.withLock { $0.append(error.localizedDescription) }
            }
        }
        #expect(failures.withLock { $0 } == [])
    }

    @Test func `a missing file is reported with its path`() throws {
        let (source, _) = try connect(files: ["/a": Data()])
        #expect(throws: RemoteError("/missing: No such file or folder.")) { try source.open("missing") }
    }

    @Test func `waiting requests fail when the server goes away`() throws {
        let (client, serverSide) = PipeTransport.pair()
        let server = FakeServer(transport: serverSide, files: [:])
        let connection = try SFTPConnection(transport: client)
        _ = server
        // Ending the session closes the server's input; it then closes its output.
        let pending = try connection.send(.stat(id: 0, path: "/nowhere"))
        _ = try? connection.wait(pending)
        connection.close()
        #expect(throws: RemoteError.self) {
            for _ in 0..<100 {
                _ = try connection.call(.stat(id: 0, path: "/"))
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
    }

    @Test func `text before the SFTP version is reported as a login script problem`() throws {
        let (client, serverSide) = PipeTransport.pair()
        try serverSide.write(Data("Welcome to the server!\n".utf8))
        serverSide.close()
        #expect(throws: RemoteError("The server sent something that is not SFTP. A login script that prints text (for example in .bashrc) can cause this.")) {
            try SFTPConnection(transport: client)
        }
    }

    @Test func `a program that ends before answering is reported with its error output`() throws {
        let transport = try ProcessTransport(executable: "/bin/sh", arguments: ["-c", "echo 'Host key verification failed.' >&2; exit 255"])
        #expect(throws: RemoteError("Host key verification failed.")) { try SFTPConnection(transport: transport) }
    }
}

/// Against OpenSSH's own `sftp-server`, started directly instead of through ssh: the real
/// protocol implementation, without needing Remote Login.
struct SFTPServerTests {
    static let server = "/usr/libexec/sftp-server"
    static var available: Bool { FileManager.default.isExecutableFile(atPath: server) }

    private func makeFolder(_ files: [String: Data], links: [String: String] = [:]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "moire-sftp-\(UUID().uuidString)")
        for (path, data) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        for (path, target) in links {
            try FileManager.default.createSymbolicLink(atPath: root.appending(path: path).path(percentEncoded: false), withDestinationPath: target)
        }
        return root
    }

    private func source(_ root: URL) throws -> SFTPSource {
        let connection = try SFTPConnection(transport: ProcessTransport(executable: Self.server, arguments: []))
        return try SFTPSource(connection: connection, path: root.path(percentEncoded: false), displayName: "sftp-server")
    }

    @Test(.enabled(if: SFTPServerTests.available)) func `lists and reads like the local folder`() throws {
        let big = randomData(3_000_000, seed: 7)
        let root = try makeFolder(["a.txt": Data("hello".utf8), "sub/b.bin": big, "sub/é ü.txt": Data("x".utf8), ".env": Data("s".utf8)], links: ["link": "a.txt"])
        let remote = try source(root)
        let local = try LocalSource(root)
        for folder in ["", "sub"] {
            let remoteEntries = try remote.list(folder, skipHidden: false).sorted { $0.name < $1.name }
            let localEntries = try local.list(folder, skipHidden: false).sorted { $0.name < $1.name }
            #expect(remoteEntries.map(\.name) == localEntries.map(\.name).map(\.precomposedStringWithCanonicalMapping) || remoteEntries.map(\.name) == localEntries.map(\.name))
            #expect(remoteEntries.map(\.kind) == localEntries.map(\.kind))
            #expect(remoteEntries.map(\.size) == localEntries.map(\.size))
            // SFTP version 3 dates are whole seconds.
            #expect(remoteEntries.map { $0.modified / 1_000_000_000 } == localEntries.map { $0.modified / 1_000_000_000 })
        }
        #expect(try remote.linkDestination("link") == "a.txt")
        let file = try remote.open("sub/b.bin")
        #expect(file.size == 3_000_000)
        #expect(try file.read(at: 2_990_000, count: 64 * 1024) == big.subdata(in: 2_990_000..<3_000_000))
        #expect(try file.readAll() == big)
    }

    @Test(.enabled(if: SFTPServerTests.available)) func `the engine compares an SFTP folder with a local one`() throws {
        let shared = randomData(200_000, seed: 3)
        var changed = shared
        changed[100_000] ^= 0xff
        let left = try makeFolder(["same.bin": shared, "changed.bin": shared, "only-left.txt": Data("l".utf8), "dir/text.txt": Data("one\ntwo\n".utf8)], links: ["link": "same.bin"])
        let right = try makeFolder(["same.bin": shared, "changed.bin": changed, "only-right.txt": Data("r".utf8), "dir/text.txt": Data("one\nthree\n".utf8)], links: ["link": "same.bin"])

        for method in [CompareMethod.binary, .quick, .lines] {
            let engine = FolderEngine(sources: { (try LocalSource(left), try source(right)) }, settings: FolderCompareSettings(method: method))
            let tree = try engine.run()
            let statuses = Dictionary(uniqueKeysWithValues: (1..<tree.count).map { (tree.path(of: $0), tree.status(of: $0)) })
            #expect(statuses["same.bin"] == .identical)
            // Quick only looks at the first and last 64 KB, and the change sits in the middle.
            #expect(statuses["changed.bin"] == (method == .quick ? .identical : .different))
            #expect(statuses["only-left.txt"] == .leftOnly)
            #expect(statuses["only-right.txt"] == .rightOnly)
            #expect(statuses["dir/text.txt"] == .different)
            #expect(statuses["link"] == .identical)
        }
    }

    @Test(.enabled(if: SFTPServerTests.available)) func `a folder that does not exist fails to open`() throws {
        let connection = try SFTPConnection(transport: ProcessTransport(executable: Self.server, arguments: []))
        #expect(throws: RemoteError.self) {
            try SFTPSource(connection: connection, path: "/nonexistent-\(UUID().uuidString)", displayName: "x")
        }
    }
}
