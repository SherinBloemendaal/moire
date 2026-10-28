import Foundation
import Synchronization

/// Runs the system `curl` for FTP. The login goes in through standard input as a config file,
/// so a password never shows up in the list of running programs.
struct Curl: Sendable {
    let executable: String
    let config: String
    let options: [String]

    init(executable: String = "/usr/bin/curl", user: String?, password: String?, requireTLS: Bool) {
        self.executable = executable
        if let user {
            config = "user = \"\(Self.quote(user)):\(Self.quote(password ?? ""))\"\n"
        } else {
            config = ""
        }
        options = [
            // Must come first: ignore ~/.curlrc, so nothing there changes what curl prints.
            "-q",
            "--silent", "--show-error", "--globoff",
            "--ftp-method", "singlecwd",
            "--connect-timeout", "20",
            // Give up on a transfer that stalls for a minute.
            "--speed-limit", "1", "--speed-time", "60",
        ] + (requireTLS ? ["--ssl-reqd"] : []) + ["--config", "-"]
    }

    static func quote(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    func start(_ arguments: [String], url: String) throws -> ChildProcess {
        let process = try ChildProcess(executable: executable, arguments: options + arguments + [url])
        do {
            try process.write(Data(config.utf8))
        } catch {
            process.terminate()
            throw RemoteError("Could not start curl: \(error.localizedDescription)")
        }
        process.closeInput()
        return process
    }

    struct Result {
        let code: Int32
        let output: Data
        let error: String
    }

    func run(_ arguments: [String], url: String) throws -> Result {
        let process = try start(arguments, url: url)
        let output = try process.readToEnd()
        let code = process.wait()
        return Result(code: code, output: output, error: code == 0 ? "" : process.errorOutput())
    }

    /// curl's message without its `curl: (67)` prefix.
    static func message(_ text: String, code: Int32) -> String {
        var message = text.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        if message.hasPrefix("curl: ("), let close = message.firstIndex(of: ")") {
            message = message[message.index(after: close)...].trimmingCharacters(in: .whitespaces)
        }
        return message.isEmpty ? "curl ended with exit code \(code)." : message
    }

    /// Exit codes that mean the server, the login or the folder is the problem, so trying another
    /// listing command would not help: cannot resolve or connect, access denied, timeout, login
    /// denied, TLS failures.
    static let fatalCodes: Set<Int32> = [5, 6, 7, 9, 28, 35, 51, 53, 54, 58, 59, 60, 64, 66, 67, 77, 80, 82, 83, 90, 91]
}

/// A folder on an FTP server, read with `curl`. Folders are listed with `MLSD` (exact sizes,
/// types and UTC dates), or with `LIST` on servers that lack it.
public final class FTPSource: FolderSource {
    public let displayName: String
    public let volume: Volume
    let curl: Curl
    /// `ftp://host:port/folder`, percent-encoded, without a trailing slash.
    let rootURL: String

    private struct ListState {
        var useMLSD = true
        /// Set once a listing worked, so a later failure is reported instead of trying `LIST`.
        var settled = false
    }

    private let listState = Mutex(ListState())
    private let links = Mutex<[String: String]>([:])
    private let firstListing = Mutex<[FTPListing.Item]?>(nil)
    /// Each curl is a connection of its own; many servers refuse more than a few per address.
    let gate = DispatchSemaphore(value: 4)

    public convenience init(location: RemoteLocation, password: String?) throws {
        let curl = Curl(user: location.user, password: password, requireTLS: location.scheme == .ftpes)
        try self.init(location: location, curl: curl)
    }

    init(location: RemoteLocation, curl: Curl) throws {
        displayName = location.displayName
        volume = Volume(fileSystem: location.scheme == .ftp ? "ftp" : "ftps", isLocal: false)
        self.curl = curl
        // Explicit TLS starts as plain FTP and switches with AUTH TLS (`--ssl-reqd`).
        let scheme = location.scheme == .ftps ? "ftps" : "ftp"
        var host = location.host.contains(":") ? "[\(location.host)]" : location.host
        if let port = location.port { host += ":\(port)" }
        rootURL = "\(scheme)://\(host)" + Self.encodedPath(location.path)
        // Lists the folder once now, so a wrong password or folder is reported right away.
        let items = try listItems("")
        firstListing.withLock { $0 = items }
    }

    /// The URL path as curl wants it. Like curl, a path is relative to the login folder, and one
    /// that starts with `//` (typed as `/%2F`) is absolute.
    static func encodedPath(_ path: String) -> String {
        var rest = Substring(path)
        var prefix = ""
        if rest.hasPrefix("//") {
            prefix = "/%2F"
            rest = rest.dropFirst(2)
        } else if rest.hasPrefix("/") {
            rest = rest.dropFirst()
        }
        let segments = rest.split(separator: "/").map { AWSSigner.encode(String($0)) }
        if segments.isEmpty { return prefix }
        return (prefix.isEmpty ? "/" : prefix + "/") + segments.joined(separator: "/")
    }

    func url(_ path: String, folder: Bool) -> String {
        let encoded = path.split(separator: "/").map { AWSSigner.encode(String($0)) }.joined(separator: "/")
        let joined = encoded.isEmpty ? rootURL : rootURL + "/" + encoded
        return folder ? joined + "/" : joined
    }

    private func describe(_ path: String) -> String {
        path.isEmpty ? displayName : path
    }

    private func listItems(_ path: String) throws -> [FTPListing.Item] {
        gate.wait()
        defer { gate.signal() }
        let url = url(path, folder: true)
        let state = listState.withLock { $0 }
        if state.useMLSD {
            let result = try curl.run(["-X", "MLSD"], url: url)
            if result.code == 0 {
                listState.withLock { $0.settled = true }
                return FTPListing.mlsd(result.output)
            }
            if state.settled || Curl.fatalCodes.contains(result.code) {
                throw RemoteError("\(describe(path)): \(Curl.message(result.error, code: result.code))")
            }
        }
        // The server lacks MLSD. LIST shows no hidden files on most servers, and dates only to
        // the minute, in a time zone it does not name.
        let result = try curl.run([], url: url)
        guard result.code == 0 else {
            throw RemoteError("\(describe(path)): \(Curl.message(result.error, code: result.code))")
        }
        listState.withLock { $0 = ListState(useMLSD: false, settled: true) }
        return FTPListing.list(result.output)
    }

    public func list(_ path: String, skipHidden: Bool) throws -> [DirectoryEntry] {
        let items: [FTPListing.Item]
        if path.isEmpty, let first = firstListing.withLock({ state in defer { state = nil }; return state }) {
            items = first
        } else {
            items = try listItems(path)
        }
        var targets: [String: String] = [:]
        let entries = items.compactMap { item -> DirectoryEntry? in
            if skipHidden, item.entry.name.hasPrefix(".") { return nil }
            if let target = item.linkTarget { targets[path.isEmpty ? item.entry.name : path + "/" + item.entry.name] = target }
            return item.entry
        }
        if !targets.isEmpty { links.withLock { $0.merge(targets) { _, new in new } } }
        return entries
    }

    public func open(_ path: String) throws -> any ReadableFile {
        gate.wait()
        defer { gate.signal() }
        // `-I` on an FTP file asks for SIZE and MDTM only.
        let result = try curl.run(["-I"], url: url(path, folder: false))
        guard result.code == 0 else { throw RemoteError("\(path): \(Curl.message(result.error, code: result.code))") }
        let header = FTPListing.lines(result.output).first { $0.lowercased().hasPrefix("content-length:") }
        guard let size = header.flatMap({ Int64($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) }) else {
            throw RemoteError("\(path): the server did not say how big the file is.")
        }
        return FTPFile(source: self, path: path, size: size)
    }

    public func open(_ path: String, listedSize: Int64) throws -> any ReadableFile {
        FTPFile(source: self, path: path, size: listedSize)
    }

    public func linkDestination(_ path: String) throws -> String {
        if let target = links.withLock({ $0[path] }) { return target }
        let parent = path.split(separator: "/").dropLast().joined(separator: "/")
        _ = try list(parent, skipHidden: false)
        guard let target = links.withLock({ $0[path] }) else {
            throw RemoteError("\(path): the server does not say where this link points.")
        }
        return target
    }

    public func localURL(_ path: String) -> URL? { nil }
}

/// A file on an FTP server. Sequential reads stream one download; reads at an offset download
/// just that range.
final class FTPFile: ReadableFile {
    let size: Int64
    private let source: FTPSource
    private let path: String
    private var download: ChildProcess?
    private var holdsGate = false
    private var finished = false

    init(source: FTPSource, path: String, size: Int64) {
        self.source = source
        self.path = path
        self.size = size
    }

    deinit {
        download?.terminate()
        if holdsGate { source.gate.signal() }
    }

    private func release() {
        if holdsGate {
            holdsGate = false
            source.gate.signal()
        }
    }

    func readNext(into buffer: UnsafeMutableRawPointer, count: Int) throws -> Int {
        guard !finished else { return 0 }
        if download == nil {
            source.gate.wait()
            holdsGate = true
            do {
                download = try source.curl.start([], url: source.url(path, folder: false))
            } catch {
                release()
                throw error
            }
        }
        guard let download else { return 0 }
        var total = 0
        while total < count {
            let read = try download.read(into: buffer + total, count: count - total)
            if read == 0 {
                finished = true
                let code = download.wait()
                release()
                guard code == 0 else { throw RemoteError("\(path): \(Curl.message(download.errorOutput(), code: code))") }
                break
            }
            total += read
        }
        return total
    }

    func read(at offset: Int64, count: Int) throws -> Data {
        guard count > 0, offset < size else { return Data() }
        let last = min(offset + Int64(count), size) - 1
        source.gate.wait()
        defer { source.gate.signal() }
        let result = try source.curl.run(["-r", "\(offset)-\(last)"], url: source.url(path, folder: false))
        guard result.code == 0 else { throw RemoteError("\(path): \(Curl.message(result.error, code: result.code))") }
        return result.output.prefix(count)
    }
}
