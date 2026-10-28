import Foundation
@testable import MoireKit
import Testing

struct RemoteLocationTests {
    @Test func `parses addresses and keeps the password apart`() throws {
        let (location, password) = try RemoteLocation.parse("sftp://deploy@example.com:2222/srv/app/")
        #expect(location == RemoteLocation(scheme: .sftp, user: "deploy", host: "example.com", port: 2222, path: "/srv/app"))
        #expect(password == nil)
        #expect(location.url == "sftp://deploy@example.com:2222/srv/app")
        #expect(location.name == "app")

        let (ftp, secret) = try RemoteLocation.parse("ftp://me:p%40ss@files.example.com/pub")
        #expect(ftp.user == "me")
        #expect(secret == "p@ss")
        #expect(!ftp.url.contains("p%40ss"))

        let (bucket, _) = try RemoteLocation.parse("s3://my-bucket/")
        #expect(bucket.path == "")
        #expect(bucket.name == "my-bucket")
    }

    @Test func `rejects what it cannot connect to`() {
        #expect(throws: RemoteError.self) { try RemoteLocation.parse("http://example.com") }
        #expect(throws: RemoteError.self) { try RemoteLocation.parse("sftp:///path") }
        #expect(throws: RemoteError.self) { try RemoteLocation.parse("s3://user@bucket/x") }
        #expect(throws: RemoteError.self) { try RemoteLocation.parse("not a url") }
    }

    @Test func `survives a round trip through JSON`() throws {
        let location = RemoteLocation(scheme: .s3, host: "b", path: "/p", s3: .init(endpoint: "https://e", region: "auto", profile: "r2"))
        let decoded = try JSONDecoder().decode(RemoteLocation.self, from: JSONEncoder().encode(location))
        #expect(decoded == location)
    }
}
