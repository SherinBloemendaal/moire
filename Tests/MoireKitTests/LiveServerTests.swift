import Foundation
@testable import MoireKit
import Testing

/// Against real servers, only when they are configured: a remote folder and a local copy of it
/// must compare as identical, byte for byte.
///
///     MOIRE_TEST_REMOTE_URL=sftp://me@host/srv/copy   (or ftp://, ftps://, ftpes://, s3://)
///     MOIRE_TEST_REMOTE_LOCAL=/path/to/the/same/files
///     MOIRE_TEST_REMOTE_PASSWORD=...                  (FTP only)
///     MOIRE_TEST_S3_ENDPOINT, MOIRE_TEST_S3_REGION, MOIRE_TEST_S3_PROFILE   (S3 only, optional)
struct LiveServerTests {
    static let environment = ProcessInfo.processInfo.environment
    static var configured: Bool { environment["MOIRE_TEST_REMOTE_URL"] != nil && environment["MOIRE_TEST_REMOTE_LOCAL"] != nil }

    private func location() throws -> (RemoteLocation, String?) {
        var (location, password) = try RemoteLocation.parse(Self.environment["MOIRE_TEST_REMOTE_URL"] ?? "")
        location.s3 = RemoteLocation.S3Options(
            endpoint: Self.environment["MOIRE_TEST_S3_ENDPOINT"] ?? "",
            region: Self.environment["MOIRE_TEST_S3_REGION"] ?? "",
            profile: Self.environment["MOIRE_TEST_S3_PROFILE"] ?? ""
        )
        return (location, password ?? Self.environment["MOIRE_TEST_REMOTE_PASSWORD"])
    }

    @Test(.enabled(if: LiveServerTests.configured), arguments: [CompareMethod.metadata, .quick, .binary])
    func `a remote folder matches its local copy`(method: CompareMethod) throws {
        let (location, password) = try location()
        let local = URL(filePath: Self.environment["MOIRE_TEST_REMOTE_LOCAL"] ?? "")
        let engine = FolderEngine(
            sources: { (try LocalSource(local), try location.makeSource(password: password)) },
            settings: FolderCompareSettings(method: method, skipHidden: false)
        )
        let tree = try engine.run()
        #expect(tree.count > 1)
        var problems: [String] = []
        for item in 1..<tree.count where !tree.isDirectory(item) {
            let status = tree.status(of: item)
            // Dates are only as exact as the protocol: whole seconds, or minutes for FTP LIST.
            if method == .metadata, status == .different, tree.left(item).size == tree.right(item).size { continue }
            if status != .identical { problems.append("\(tree.path(of: item)): \(status) \(tree.error(at: item) ?? "")") }
        }
        #expect(problems == [])
    }
}
