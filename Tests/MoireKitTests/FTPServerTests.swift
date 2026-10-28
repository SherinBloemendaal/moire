import Foundation
@testable import MoireKit
import Testing

/// The FTP source against a real FTP conversation: Moire's own curl calls, with TLS for real,
/// talking to the small server in `Fixtures/ftps_server.py` (plain FTP, explicit and implicit TLS).
@Suite(.serialized)
final class FTPServerTests {
    let root: URL
    let certificate: URL
    let server: Process
    let input = Pipe()
    let plainPort: Int
    let implicitPort: Int
    static let password = "pa\"ss\\word with space"

    init() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "moire-ftps-\(UUID().uuidString)")
        root = base.appending(path: "served")
        let files: [String: Data] = [
            "a.txt": Data("hello\n".utf8),
            "empty.txt": Data(),
            "deep/er/big.bin": Data((0..<1_234_567).map { UInt8(($0 * 13) % 256) }),
            "with space/naïve café.txt": Data("é\n".utf8),
        ]
        for (path, data) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }

        // A certificate for this test only; curl is told to trust it, nothing else changes.
        certificate = base.appending(path: "cert.pem")
        let key = base.appending(path: "key.pem")
        let openssl = Process()
        openssl.executableURL = URL(filePath: "/usr/bin/openssl")
        openssl.arguments = [
            "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=127.0.0.1",
            "-addext", "subjectAltName=IP:127.0.0.1", "-keyout", key.path(percentEncoded: false), "-out", certificate.path(percentEncoded: false),
        ]
        openssl.standardOutput = FileHandle.nullDevice
        openssl.standardError = FileHandle.nullDevice
        try openssl.run()
        openssl.waitUntilExit()
        try #require(openssl.terminationStatus == 0)

        let script = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/ftps_server.py")
        server = Process()
        server.executableURL = URL(filePath: "/usr/bin/env")
        server.arguments = ["python3", "-I", script.path(percentEncoded: false), root.path(percentEncoded: false), certificate.path(percentEncoded: false), key.path(percentEncoded: false), Self.password]
        let output = Pipe()
        server.standardOutput = output
        server.standardInput = input
        try server.run()
        let line = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self).split(separator: " ")
        try #require(line.first == "ready" && line.count == 3)
        plainPort = Int(line[1].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        implicitPort = Int(line[2].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        setenv("CURL_CA_BUNDLE", certificate.path(percentEncoded: false), 1)
    }

    deinit {
        server.terminate()
        unsetenv("CURL_CA_BUNDLE")
    }

    private func location(_ scheme: String) throws -> RemoteLocation {
        let port = scheme == "ftps" ? implicitPort : plainPort
        return try RemoteLocation.parse("\(scheme)://moire@127.0.0.1:\(port)/").location
    }

    /// Both sides of a comparison, made the way the app makes them when it starts.
    private func sides(local: URL, scheme: String, password: String = FTPServerTests.password) throws -> @Sendable () throws -> (any FolderSource, any FolderSource) {
        let remote = try location(scheme)
        return { (try LocalSource(local), try remote.makeSource(password: password)) }
    }

    @Test(arguments: ["ftp", "ftpes", "ftps"])
    func `a folder read over FTP matches the same folder read locally`(scheme: String) throws {
        for method in [CompareMethod.quick, .binary, .lines] {
            let tree = try FolderEngine(sources: sides(local: root, scheme: scheme), settings: FolderCompareSettings(method: method, skipHidden: false)).run()
            let problems = (1..<tree.count).filter { !tree.isDirectory($0) && tree.status(of: $0) != .identical }.map { "\(tree.path(of: $0)): \(tree.status(of: $0)) \(tree.error(at: $0) ?? "")" }
            #expect(problems == [], "\(scheme) \(method)")
            #expect(tree.count == 8, "\(scheme) \(method)")
        }
    }

    @Test(arguments: ["ftp", "ftps"])
    func `notices a changed byte in the middle of a big file`(scheme: String) throws {
        let copy = root.deletingLastPathComponent().appending(path: "copy-\(scheme)")
        try FileManager.default.copyItem(at: root, to: copy)
        let big = copy.appending(path: "deep/er/big.bin")
        var bytes = try Data(contentsOf: big)
        bytes[600_000] ^= 0xFF
        try bytes.write(to: big)

        let tree = try FolderEngine(sources: sides(local: copy, scheme: scheme), settings: FolderCompareSettings(method: .binary, skipHidden: false)).run()
        let different = (1..<tree.count).filter { !tree.isDirectory($0) && tree.status(of: $0) == .different }.map { tree.path(of: $0) }
        #expect(different == ["deep/er/big.bin"])
    }

    @Test func `reads pieces of a file over FTPS`() throws {
        let file = try location("ftpes").makeSource(password: Self.password).open("deep/er/big.bin")
        let bytes = try Data(contentsOf: root.appending(path: "deep/er/big.bin"))
        #expect(file.size == Int64(bytes.count))
        #expect(try file.read(at: 1_000_000, count: 100) == bytes[1_000_000..<1_000_100])
    }

    @Test func `reports a wrong password`() throws {
        let engine = FolderEngine(sources: try sides(local: root, scheme: "ftpes", password: "wrong"), settings: FolderCompareSettings(method: .metadata))
        #expect(throws: (any Error).self) { try engine.run() }
    }

    @Test(arguments: ["ftpes", "ftps"])
    func `refuses a server whose certificate is not trusted`(scheme: String) throws {
        // Only the system's own certificates: the test server's certificate is not among them.
        setenv("CURL_CA_BUNDLE", "/etc/ssl/cert.pem", 1)
        defer { setenv("CURL_CA_BUNDLE", certificate.path(percentEncoded: false), 1) }
        let engine = FolderEngine(sources: try sides(local: root, scheme: scheme), settings: FolderCompareSettings(method: .metadata))
        #expect(throws: (any Error).self) { try engine.run() }
    }
}
