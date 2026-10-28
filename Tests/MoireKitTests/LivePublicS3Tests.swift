import Foundation
@testable import MoireKit
import Testing

/// Against Amazon S3 itself: NOAA's public GHCN bucket (AWS Open Data), read anonymously.
/// Only with `MOIRE_TEST_PUBLIC_S3=1`, since it needs the internet. Your own `~/.aws` is never
/// read: the credential files are pointed at /dev/null, so requests go out unsigned.
@Suite(.serialized)
struct LivePublicS3Tests {
    static let enabled = ProcessInfo.processInfo.environment["MOIRE_TEST_PUBLIC_S3"] == "1"
    static let bucket = "noaa-ghcn-pds"

    private func source() throws -> any FolderSource {
        setenv("AWS_SHARED_CREDENTIALS_FILE", "/dev/null", 1)
        setenv("AWS_CONFIG_FILE", "/dev/null", 1)
        unsetenv("AWS_ACCESS_KEY_ID")
        unsetenv("AWS_SECRET_ACCESS_KEY")
        unsetenv("AWS_PROFILE")
        var (location, _) = try RemoteLocation.parse("s3://\(Self.bucket)")
        location.s3 = RemoteLocation.S3Options(endpoint: "", region: "us-east-1", profile: "")
        return try location.makeSource()
    }

    /// The same object fetched without Moire: a plain HTTPS GET on the public URL.
    private func direct(_ key: String) throws -> Data {
        try Data(contentsOf: URL(string: "https://\(Self.bucket).s3.amazonaws.com/\(key)")!)
    }

    @Test(.enabled(if: LivePublicS3Tests.enabled))
    func `lists the bucket's top level like S3 itself`() throws {
        let entries = try source().list("", skipHidden: false)
        let files = Dictionary(uniqueKeysWithValues: entries.filter { $0.kind == .file }.map { ($0.name, $0.size) })
        let folders = Set(entries.filter { $0.kind == .directory }.map(\.name))

        // From S3's own listing, parsed separately.
        let xml = String(decoding: try Data(contentsOf: URL(string: "https://\(Self.bucket).s3.amazonaws.com/?list-type=2&delimiter=/")!), as: UTF8.self)
        let keys = xml.components(separatedBy: "<Key>").dropFirst().map { String($0.prefix { $0 != "<" }) }
        let sizes = xml.components(separatedBy: "<Size>").dropFirst().map { Int64($0.prefix { $0 != "<" }) ?? -1 }
        let prefixes = xml.components(separatedBy: "<Prefix>").dropFirst(2).map { String($0.prefix { $0 != "/" }) }

        #expect(files == Dictionary(uniqueKeysWithValues: zip(keys, sizes)))
        #expect(folders == Set(prefixes))
        #expect(files["ghcnd-countries.txt"] != nil)
    }

    @Test(.enabled(if: LivePublicS3Tests.enabled), arguments: ["ghcnd-countries.txt", "ghcnd-states.txt", "readme-by_year.txt", "test.txt"])
    func `reads an object byte for byte`(key: String) throws {
        let file = try source().open(key)
        let expected = try direct(key)
        #expect(file.size == Int64(expected.count))
        #expect(try file.readAll() == expected)
        if expected.count > 200 {
            #expect(try file.read(at: 100, count: 50) == expected[100..<150])
        }
    }

    @Test(.enabled(if: LivePublicS3Tests.enabled))
    func `compares S3 with a local copy, and finds a changed byte`() throws {
        let names = ["ghcnd-countries.txt", "ghcnd-states.txt", "readme-by_year.txt"]
        let local = FileManager.default.temporaryDirectory.appending(path: "moire-public-s3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        for name in names { try direct(name).write(to: local.appending(path: name)) }
        let remote = try source()

        for name in names {
            let engineless = try ContentComparer.bytes(LocalFile(local.appending(path: name).path(percentEncoded: false)), remote.open(name))
            #expect(engineless, "\(name)")
        }
        var changed = try Data(contentsOf: local.appending(path: names[0]))
        changed[changed.count / 2] ^= 0x20
        try changed.write(to: local.appending(path: names[0]))
        #expect(try !ContentComparer.bytes(LocalFile(local.appending(path: names[0]).path(percentEncoded: false)), remote.open(names[0])))
    }
}
