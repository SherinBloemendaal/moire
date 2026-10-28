import Darwin
import Foundation
import Synchronization

/// The byte stream an SFTP session runs over: the pipes of `ssh -s host sftp`, or of a server
/// started directly.
protocol SFTPTransport: Sendable {
    func write(_ data: Data) throws
    /// Reads exactly `count` bytes; `false` when the stream ended first.
    func readExactly(into buffer: UnsafeMutableRawPointer, count: Int) throws -> Bool
    /// Ends the session from this side. The server sees the end of its input and exits.
    func close()
    /// Why the stream ended, in the words of the program behind it (for `ssh`: its error output).
    func failureDescription() -> String?
}

/// Runs a program and speaks SFTP over its standard input and output.
final class ProcessTransport: SFTPTransport {
    let process: ChildProcess

    init(executable: String, arguments: [String]) throws {
        process = try ChildProcess(executable: executable, arguments: arguments)
    }

    func write(_ data: Data) throws { try process.write(data) }

    func readExactly(into buffer: UnsafeMutableRawPointer, count: Int) throws -> Bool {
        try process.readExactly(into: buffer, count: count)
    }

    func close() { process.closeInput() }

    func failureDescription() -> String? {
        let code = process.wait()
        let text = process.errorOutput()
        if !text.isEmpty { return text }
        return code == 0 ? nil : "\((process.executable as NSString).lastPathComponent) ended with exit code \(code)."
    }
}

/// One SFTP session that many threads can use at once.
///
/// Every request gets its own ID; a reader thread takes the replies off the stream and hands each
/// one to the thread waiting for that ID. So a slow folder listing never holds up a file read, and
/// a file can have many reads in flight.
final class SFTPConnection: Sendable {
    /// The extensions the server announced, such as `limits@openssh.com`.
    let extensions: [String: String]
    private let transport: any SFTPTransport
    private let shared = Shared()
    private let writeLock = Mutex(())

    /// Larger packets are taken as a sign that the stream is not SFTP at all, typically text a
    /// login script printed before the server started.
    static let maximumPacket = 4 << 20

    final class Slot: @unchecked Sendable {
        // `reply` is written once under the connection's lock before `ready` is signalled, and
        // only read after waiting on `ready`.
        let ready = DispatchSemaphore(value: 0)
        var reply: Result<SFTP.Reply, RemoteError>?
    }

    struct Pending {
        let id: UInt32
        let slot: Slot
    }

    private final class Shared: Sendable {
        struct State {
            var nextID: UInt32 = 1
            var slots: [UInt32: Slot] = [:]
            var failure: RemoteError?
        }

        let state = Mutex(State())

        func fail(_ error: RemoteError) {
            let slots = state.withLock { state in
                if state.failure == nil { state.failure = error }
                let slots = state.slots
                state.slots = [:]
                for slot in slots.values { slot.reply = .failure(state.failure ?? error) }
                return slots
            }
            for slot in slots.values { slot.ready.signal() }
        }
    }

    /// Says hello (INIT, VERSION) and starts reading replies. Throws when the other side is not an
    /// SFTP server, or ends before it answers.
    init(transport: any SFTPTransport) throws {
        self.transport = transport
        do {
            try transport.write(SFTP.Request.initialize(version: 3).packet)
        } catch {
            transport.close()
            throw RemoteError(transport.failureDescription() ?? "Could not start the SFTP session: \(error.localizedDescription)")
        }
        let first: Data?
        do {
            first = try Self.readPacket(transport)
        } catch {
            transport.close()
            throw error
        }
        guard let first else {
            transport.close()
            throw RemoteError(transport.failureDescription() ?? "The server closed the connection before SFTP started.")
        }
        guard case .version(let version, let extensions) = try? SFTP.Reply(packet: first) else {
            transport.close()
            throw RemoteError("The server did not answer with an SFTP version.")
        }
        guard version >= 3 else {
            transport.close()
            throw RemoteError("The server speaks SFTP version \(version); Moire needs version 3.")
        }
        self.extensions = extensions

        let shared = shared
        let thread = Thread {
            Self.readReplies(transport, shared)
        }
        thread.name = "Moire SFTP replies"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    deinit {
        transport.close()
    }

    /// Reads one packet, without its length. `nil` at the end of the stream.
    private static func readPacket(_ transport: any SFTPTransport) throws(RemoteError) -> Data? {
        var length: UInt32 = 0
        do {
            let complete = try withUnsafeMutableBytes(of: &length) { buffer in
                guard let base = buffer.baseAddress else { return false }
                return try transport.readExactly(into: base, count: 4)
            }
            guard complete else { return nil }
        } catch {
            throw RemoteError("Reading from the server failed: \(error.localizedDescription)")
        }
        let size = Int(UInt32(bigEndian: length))
        guard size > 0, size <= maximumPacket else {
            throw RemoteError("The server sent something that is not SFTP. A login script that prints text (for example in .bashrc) can cause this.")
        }
        var packet = Data(count: size)
        let complete: Bool
        do {
            complete = try packet.withUnsafeMutableBytes { buffer in
                guard let base = buffer.baseAddress else { return false }
                return try transport.readExactly(into: base, count: size)
            }
        } catch {
            throw RemoteError("Reading from the server failed: \(error.localizedDescription)")
        }
        return complete ? packet : nil
    }

    private static func readReplies(_ transport: any SFTPTransport, _ shared: Shared) {
        while true {
            let packet: Data?
            do {
                packet = try readPacket(transport)
            } catch {
                shared.fail(error)
                transport.close()
                return
            }
            guard let packet else {
                shared.fail(RemoteError(transport.failureDescription() ?? "The server closed the connection."))
                return
            }
            guard let reply = try? SFTP.Reply(packet: packet), let id = reply.id else {
                shared.fail(RemoteError("The server sent a reply Moire cannot read."))
                transport.close()
                return
            }
            let slot = shared.state.withLock { state -> Slot? in
                guard let slot = state.slots.removeValue(forKey: id) else { return nil }
                slot.reply = .success(reply)
                return slot
            }
            // A reply nobody waits for any more (a read ahead of a file that was closed) is dropped.
            slot?.ready.signal()
        }
    }

    /// Sends a request without waiting for the reply. The request's own ID is replaced.
    func send(_ request: SFTP.Request) throws(RemoteError) -> Pending {
        let slot = Slot()
        let id = try shared.state.withLock { state throws(RemoteError) -> UInt32 in
            if let failure = state.failure { throw failure }
            let id = state.nextID
            state.nextID = state.nextID == UInt32.max ? 1 : state.nextID + 1
            state.slots[id] = slot
            return id
        }
        do {
            try writeLock.withLock { _ in try transport.write(request.with(id: id).packet) }
        } catch {
            shared.state.withLock { _ = $0.slots.removeValue(forKey: id) }
            let failure = RemoteError(transport.failureDescription() ?? "Writing to the server failed: \(error.localizedDescription)")
            shared.fail(failure)
            throw shared.state.withLock { $0.failure } ?? failure
        }
        return Pending(id: id, slot: slot)
    }

    func wait(_ pending: Pending) throws(RemoteError) -> SFTP.Reply {
        pending.slot.ready.wait()
        guard let reply = pending.slot.reply else { throw RemoteError("The SFTP session ended.") }
        return try reply.get()
    }

    func call(_ request: SFTP.Request) throws(RemoteError) -> SFTP.Reply {
        try wait(send(request))
    }

    /// Forgets a request that was sent but whose reply is no longer wanted.
    func discard(_ pending: Pending) {
        shared.state.withLock { _ = $0.slots.removeValue(forKey: pending.id) }
    }

    /// Ends the session.
    func close() {
        transport.close()
    }

    // MARK: Requests

    func realpath(_ path: String) throws(RemoteError) -> String {
        let reply = try call(.realpath(id: 0, path: path))
        guard case .name(_, let names) = reply, let first = names.first else { throw Self.unexpected(reply, path) }
        return first.filename
    }

    func stat(_ path: String) throws(RemoteError) -> SFTP.Attributes {
        try attributes(call(.stat(id: 0, path: path)), path)
    }

    func lstat(_ path: String) throws(RemoteError) -> SFTP.Attributes {
        try attributes(call(.lstat(id: 0, path: path)), path)
    }

    func fstat(_ handle: Data, path: String) throws(RemoteError) -> SFTP.Attributes {
        try attributes(call(.fstat(id: 0, handle: handle)), path)
    }

    private func attributes(_ reply: SFTP.Reply, _ path: String) throws(RemoteError) -> SFTP.Attributes {
        guard case .attrs(_, let attributes) = reply else { throw Self.unexpected(reply, path) }
        return attributes
    }

    func readlink(_ path: String) throws(RemoteError) -> String {
        let reply = try call(.readlink(id: 0, path: path))
        guard case .name(_, let names) = reply, let first = names.first else { throw Self.unexpected(reply, path) }
        return first.filename
    }

    /// Every item in a folder, without `.` and `..`.
    func list(_ path: String) throws(RemoteError) -> [SFTP.Name] {
        let handle = try openHandle(.opendir(id: 0, path: path), path)
        defer { closeHandle(handle) }
        var names: [SFTP.Name] = []
        while true {
            let reply = try call(.readdir(id: 0, handle: handle))
            switch reply {
            case .name(_, let batch):
                names.append(contentsOf: batch.filter { $0.filename != "." && $0.filename != ".." })
            case .status(_, SFTP.StatusCode.eof.rawValue, _):
                return names
            default:
                throw Self.unexpected(reply, path)
            }
        }
    }

    func openFile(_ path: String) throws(RemoteError) -> Data {
        try openHandle(.open(id: 0, path: path, flags: SFTP.openRead), path)
    }

    private func openHandle(_ request: SFTP.Request, _ path: String) throws(RemoteError) -> Data {
        let reply = try call(request)
        guard case .handle(_, let handle) = reply else { throw Self.unexpected(reply, path) }
        return handle
    }

    /// Closes a handle without waiting for the answer: there is nothing to do when it fails.
    func closeHandle(_ handle: Data) {
        guard let pending = try? send(.close(id: 0, handle: handle)) else { return }
        discard(pending)
    }

    /// A status reply where something else was expected, or a reply of the wrong kind.
    static func unexpected(_ reply: SFTP.Reply, _ path: String) -> RemoteError {
        guard case let .status(_, code, message) = reply else { return RemoteError("\(path): the server sent an unexpected reply.") }
        let text = message.isEmpty ? describe(code) : message
        return RemoteError("\(path): \(text)")
    }

    static func describe(_ code: UInt32) -> String {
        switch SFTP.StatusCode(rawValue: code) {
        case .ok: "Done."
        case .eof: "End of file."
        case .noSuchFile: "No such file or folder."
        case .permissionDenied: "Permission denied."
        case .failure: "The server could not do it."
        case .badMessage: "The server did not understand the request."
        case .noConnection, .connectionLost: "The connection was lost."
        case .unsupported: "The server does not support this."
        case nil: "Error \(code)."
        }
    }
}
