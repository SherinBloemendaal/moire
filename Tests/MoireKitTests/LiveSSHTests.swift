import Foundation
@testable import MoireKit
import Testing

/// Against a real `sshd`, only when one is configured, through the system `ssh` with the same
/// arguments the app uses plus a key and a known_hosts file of the test's own:
///
///     MOIRE_TEST_SSHD_PORT=22222
///     MOIRE_TEST_SSHD_KEY=/path/to/private_key
///     MOIRE_TEST_SSHD_KNOWN_HOSTS=/path/to/known_hosts   (filled on first contact)
///
/// The server must run on this Mac: folders made here are read back over SFTP, and every item
/// must get the same status as when both sides are read locally.
struct LiveSSHTests {
    static let environment = ProcessInfo.processInfo.environment
    static var configured: Bool { environment["MOIRE_TEST_SSHD_PORT"] != nil && environment["MOIRE_TEST_SSHD_KEY"] != nil }

    private func sftp(_ folder: URL) throws -> SFTPSource {
        let location = try RemoteLocation.parse("sftp://127.0.0.1:\(Self.environment["MOIRE_TEST_SSHD_PORT"] ?? "22")\(folder.path(percentEncoded: false))").location
        var arguments = SFTPSource.sshArguments(for: location)
        let trust = [
            "-o", "IdentitiesOnly=yes", "-i", Self.environment["MOIRE_TEST_SSHD_KEY"] ?? "",
            "-o", "StrictHostKeyChecking=accept-new", "-o", "UserKnownHostsFile=\(Self.environment["MOIRE_TEST_SSHD_KNOWN_HOSTS"] ?? "/dev/null")",
        ]
        arguments.insert(contentsOf: trust, at: arguments.firstIndex(of: "--") ?? arguments.endIndex)
        let transport = try ProcessTransport(executable: "/usr/bin/ssh", arguments: arguments)
        return try SFTPSource(connection: SFTPConnection(transport: transport), path: SFTPSource.serverPath(location.path), displayName: location.displayName)
    }

    private func tree(_ files: [String: Data]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "moire-ssh-\(UUID().uuidString)")
        for (path, data) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        return root
    }

    @Test(.enabled(if: LiveSSHTests.configured), arguments: [CompareMethod.metadata, .quick, .binary, .lines])
    func `a folder read over SFTP compares like the same folder read locally`(method: CompareMethod) throws {
        var big = Data((0..<3_000_000).map { UInt8($0 % 253) })
        let left = try tree([
            "same.txt": Data("same\n".utf8), "changed.txt": Data("one\ntwo\n".utf8), "only-left.txt": Data("l".utf8),
            "deep/er/big.bin": big, "with space/naïve café.txt": Data("é\n".utf8), "empty.txt": Data(),
        ])
        big[1_500_000] ^= 0xFF
        let right = try tree([
            "same.txt": Data("same\n".utf8), "changed.txt": Data("one\nTWO\n".utf8), "only-right.txt": Data("r".utf8),
            "deep/er/big.bin": big, "with space/naïve café.txt": Data("é\n".utf8), "empty.txt": Data(),
        ])
        let settings = FolderCompareSettings(method: method, skipHidden: false)

        let local = try FolderEngine(left: left, right: right, settings: settings).run()
        let remote = try FolderEngine(sources: { (try LocalSource(left), try self.sftp(right)) }, settings: settings).run()

        func statuses(_ tree: FolderTree) -> [String: FolderTree.Status] {
            Dictionary(uniqueKeysWithValues: (1..<tree.count).map { (tree.path(of: $0), tree.status(of: $0)) })
        }
        var expected = statuses(local)
        // SFTP gives dates in whole seconds; by metadata, files of the same size can then differ in date.
        var got = statuses(remote)
        if method == .metadata {
            for (path, status) in got where status == .different && expected[path] == .identical { got[path] = .identical }
        }
        #expect(got == expected, "\(method)")
        expected.removeAll()
        #expect(remote.count == local.count)
    }

    @Test(.enabled(if: LiveSSHTests.configured))
    func `reads a whole file and pieces of it over SFTP`() throws {
        let bytes = Data((0..<1_234_567).map { UInt8(($0 * 7) % 256) })
        let folder = try tree(["file.bin": bytes])
        let source = try sftp(folder)
        let file = try source.open("file.bin")
        #expect(file.size == Int64(bytes.count))
        #expect(try file.read(at: 1_000_000, count: 64) == bytes[1_000_000..<1_000_064])
        #expect(try source.open("file.bin").readAll() == bytes)
    }
}
