import Foundation
@testable import MoireKit
import Synchronization
import Testing

/// A bucket in memory behind `URLProtocol`, answering like S3: ListObjectsV2 with delimiter,
/// continuation tokens and URL encoding, HEAD, ranged and whole GETs, and S3's error XML.
private final class FakeS3: URLProtocol, @unchecked Sendable {
    struct Bucket {
        var objects: [String: Data]
        var pageSize = 1000
        /// Answer 301 with this region until a request is signed for it.
        var region: String?
        var requests: [String] = []
    }

    static let buckets = Mutex<[String: Bucket]>([:])

    static func add(_ objects: [String: Data], pageSize: Int = 1000, region: String? = nil) -> String {
        let name = "moire-\(UUID().uuidString.lowercased().prefix(12))"
        buckets.withLock { $0[name] = Bucket(objects: objects, pageSize: pageSize, region: region) }
        return name
    }

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeS3.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    private func respond(_ status: Int, headers: [String: String] = [:], body: Data = Data(), chunks: Int = 1) {
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let size = max(1, body.count / chunks)
        var offset = 0
        while offset < body.count {
            client?.urlProtocol(self, didLoad: body.subdata(in: offset..<min(body.count, offset + size)))
            offset += size
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    private func error(_ status: Int, _ code: String) {
        respond(status, body: Data("<?xml version=\"1.0\"?><Error><Code>\(code)</Code><Message>Fake \(code)</Message></Error>".utf8))
    }

    private static func encode(_ text: String) -> String {
        AWSSigner.encode(text, keepSlash: true).replacingOccurrences(of: "%20", with: "+")
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
    }

    override func startLoading() {
        guard let url = request.url, let host = url.host() else { return error(400, "BadRequest") }
        // Virtual-hosted (bucket.s3.region.amazonaws.com) or path-style (/bucket/key).
        var path = url.path(percentEncoded: false)
        let bucketName: String
        if host.hasSuffix(".amazonaws.com"), !host.hasPrefix("s3.") {
            bucketName = String(host.prefix { $0 != "." })
        } else {
            let parts = path.dropFirst().split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            bucketName = parts.first.map(String.init) ?? ""
            path = parts.count > 1 ? "/" + parts[1] : "/"
        }
        let key = String(path.dropFirst())
        let method = request.httpMethod ?? "GET"
        guard var bucket = Self.buckets.withLock({ $0[bucketName] }) else { return error(404, "NoSuchBucket") }
        Self.buckets.withLock { $0[bucketName]?.requests.append("\(method) \(key) \(url.query ?? "")") }

        guard let authorization = request.value(forHTTPHeaderField: "Authorization"), authorization.hasPrefix("AWS4-HMAC-SHA256 Credential=AKID/"),
              request.value(forHTTPHeaderField: "x-amz-date") != nil, request.value(forHTTPHeaderField: "x-amz-content-sha256") == AWSSigner.emptyPayloadHash
        else { return error(403, "AccessDenied") }
        if let region = bucket.region {
            guard authorization.contains("/\(region)/s3/") else {
                return respond(301, headers: ["x-amz-bucket-region": region], body: Data("<Error><Code>PermanentRedirect</Code></Error>".utf8))
            }
            bucket.region = nil
        }

        let query = Dictionary(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map { ($0.name, $0.value ?? "") } ?? [], uniquingKeysWith: { a, _ in a })
        if key.isEmpty, query["list-type"] == "2" {
            return list(bucket, query: query)
        }
        guard let data = bucket.objects[key] else { return error(404, "NoSuchKey") }
        if method == "HEAD" {
            return respond(200, headers: ["Content-Length": "\(data.count)"])
        }
        if let range = request.value(forHTTPHeaderField: "Range") {
            let bounds = range.dropFirst("bytes=".count).split(separator: "-").compactMap { Int($0) }
            guard bounds.count == 2, bounds[0] < data.count else { return error(416, "InvalidRange") }
            let slice = data.subdata(in: bounds[0]..<min(data.count, bounds[1] + 1))
            return respond(206, headers: ["Content-Range": "bytes \(bounds[0])-\(bounds[0] + slice.count - 1)/\(data.count)"], body: slice)
        }
        respond(200, headers: ["Content-Length": "\(data.count)"], body: data, chunks: 7)
    }

    private func list(_ bucket: FakeS3.Bucket, query: [String: String]) {
        let prefix = query["prefix"] ?? ""
        let delimiter = query["delimiter"] ?? ""
        let maximum = Int(query["max-keys"] ?? "") ?? bucket.pageSize
        var rows: [(String, Bool)] = []
        var seen: Set<String> = []
        for key in bucket.objects.keys.sorted() where key.hasPrefix(prefix) {
            let rest = key.dropFirst(prefix.count)
            if !delimiter.isEmpty, let cut = rest.range(of: delimiter) {
                let common = prefix + rest[..<cut.upperBound]
                if seen.insert(common).inserted { rows.append((common, true)) }
            } else {
                rows.append((key, false))
            }
        }
        let start = Int(query["continuation-token"] ?? "") ?? 0
        let page = rows.dropFirst(start).prefix(min(maximum, bucket.pageSize))
        let truncated = start + page.count < rows.count
        let encode = query["encoding-type"] == "url"
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<ListBucketResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">"
        xml += "<Name>b</Name><Prefix>\(Self.escape(encode ? Self.encode(prefix) : prefix))</Prefix><KeyCount>\(page.count)</KeyCount>"
        if encode { xml += "<EncodingType>url</EncodingType>" }
        xml += "<IsTruncated>\(truncated)</IsTruncated>"
        if truncated { xml += "<NextContinuationToken>\(start + page.count)</NextContinuationToken>" }
        for (name, isPrefix) in page {
            let shown = Self.escape(encode ? Self.encode(name) : name)
            if isPrefix {
                xml += "<CommonPrefixes><Prefix>\(shown)</Prefix></CommonPrefixes>"
            } else {
                xml += "<Contents><Key>\(shown)</Key><LastModified>2024-01-05T14:30:00.250Z</LastModified><ETag>\"x\"</ETag><Size>\(bucket.objects[name]?.count ?? 0)</Size><StorageClass>STANDARD</StorageClass></Contents>"
            }
        }
        xml += "</ListBucketResult>"
        respond(200, body: Data(xml.utf8))
    }
}

private let fakeCredentials = AWSCredentials(accessKey: "AKID", secretKey: "secret")

private func fakeSource(_ bucket: String, prefix: String = "", region: String = "us-east-1", endpoint: URL? = URL(string: "http://localhost:9000"), credentials: AWSCredentials? = fakeCredentials) throws -> S3Source {
    try S3Source(
        location: RemoteLocation(scheme: .s3, host: bucket, path: prefix),
        settings: AWSSettings(credentials: credentials, region: region, endpoint: endpoint),
        configuration: FakeS3.configuration()
    )
}

struct S3Tests {
    @Test func `lists folders and files across pages with odd names`() throws {
        let bucket = FakeS3.add([
            "root/a b+c.txt": Data("1".utf8),
            "root/ünï.txt": Data("22".utf8),
            "root/sub/x.txt": Data("333".utf8),
            "root/sub/": Data(),
            "root/other/y": Data(),
            "root/.hidden": Data(),
            "elsewhere/z": Data(),
        ], pageSize: 2)
        let source = try fakeSource(bucket, prefix: "/root")
        let entries = try source.list("", skipHidden: true).sorted { $0.name < $1.name }
        #expect(entries.map(\.name) == ["a b+c.txt", "other", "sub", "ünï.txt"])
        #expect(entries.map(\.kind) == [.file, .directory, .directory, .file])
        #expect(entries.first?.size == 1)
        #expect(entries.first?.modified == 1_704_465_000_250_000_000)
        // The empty marker object of the folder itself is not listed.
        #expect(try source.list("sub", skipHidden: true).map(\.name) == ["x.txt"])
        #expect(try source.list("", skipHidden: false).contains { $0.name == ".hidden" })
    }

    @Test func `streams whole objects and reads ranges`() throws {
        var bytes = [UInt8](repeating: 0, count: 500_000)
        for index in bytes.indices { bytes[index] = UInt8(truncatingIfNeeded: index &* 31 &+ index >> 8) }
        let data = Data(bytes)
        let bucket = FakeS3.add(["big.bin": data])
        let source = try fakeSource(bucket)
        let file = try source.open("big.bin")
        #expect(file.size == 500_000)
        #expect(try file.read(at: 450_000, count: 100_000) == data.subdata(in: 450_000..<500_000))
        #expect(try file.read(at: 600_000, count: 10).isEmpty)
        #expect(try file.readAll() == data)
    }

    @Test func `opening with the listed size skips the HEAD request`() throws {
        let bucket = FakeS3.add(["f": Data("abc".utf8)])
        let source = try fakeSource(bucket)
        let file = try source.open("f", listedSize: 3)
        #expect(try file.readAll() == Data("abc".utf8))
        let requests = FakeS3.buckets.withLock { $0[bucket]?.requests ?? [] }
        #expect(!requests.contains { $0.hasPrefix("HEAD") })
    }

    @Test func `the engine compares a bucket with a local folder`() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "moire-s3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "dir"), withIntermediateDirectories: true)
        try Data("same".utf8).write(to: root.appending(path: "same.txt"))
        try Data("left".utf8).write(to: root.appending(path: "dir/changed.txt"))
        try Data("l".utf8).write(to: root.appending(path: "only-left.txt"))
        let bucket = FakeS3.add(["p/same.txt": Data("same".utf8), "p/dir/changed.txt": Data("righ".utf8), "p/only-right.txt": Data("r".utf8)])

        let engine = FolderEngine(sources: { (try LocalSource(root), try fakeSource(bucket, prefix: "/p")) }, settings: FolderCompareSettings(method: .binary))
        let tree = try engine.run()
        let statuses = Dictionary(uniqueKeysWithValues: (1..<tree.count).map { (tree.path(of: $0), tree.status(of: $0)) })
        #expect(statuses["same.txt"] == .identical)
        #expect(statuses["dir/changed.txt"] == .different)
        #expect(statuses["only-left.txt"] == .leftOnly)
        #expect(statuses["only-right.txt"] == .rightOnly)
    }

    @Test func `follows a bucket that lives in another region`() throws {
        let bucket = FakeS3.add(["a": Data("a".utf8)], region: "eu-west-1")
        let source = try fakeSource(bucket, region: "us-east-1", endpoint: nil)
        #expect(try source.list("", skipHidden: true).map(\.name) == ["a"])
        let requests = FakeS3.buckets.withLock { $0[bucket]?.requests ?? [] }
        #expect(requests.count == 3)
    }

    @Test func `reports the server's own error`() throws {
        #expect(throws: RemoteError("The bucket moire-missing-bucket does not exist.")) { try fakeSource("moire-missing-bucket") }
        let bucket = FakeS3.add(["a": Data()])
        #expect(throws: RemoteError("Nothing is stored under \"nope/\" in the bucket \(bucket).")) { try fakeSource(bucket, prefix: "/nope") }
        let source = try fakeSource(bucket)
        #expect(throws: RemoteError("missing: No such file.")) { try source.open("missing") }
        #expect(throws: RemoteError.self) { try source.open("missing", listedSize: 3).readAll() }
    }

    @Test func `unsigned requests explain that no credentials were found`() throws {
        let bucket = FakeS3.add(["a": Data()])
        #expect(throws: RemoteError("Fake AccessDenied (AccessDenied) No AWS credentials were found, so the request was sent unsigned. Set a profile, or the AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY variables.")) {
            try fakeSource(bucket, credentials: nil)
        }
    }

    @Test func `addresses AWS buckets by host name when they fit`() throws {
        let client = S3Client(bucket: "my-bucket", settings: AWSSettings(credentials: nil, region: "eu-central-1", endpoint: nil), configuration: .ephemeral)
        #expect(client.url(for: "a b/c.txt", query: [], region: "eu-central-1")?.url.absoluteString == "https://my-bucket.s3.eu-central-1.amazonaws.com/a%20b/c.txt")
        let dotted = S3Client(bucket: "my.bucket", settings: AWSSettings(credentials: nil, region: "us-east-1", endpoint: nil), configuration: .ephemeral)
        #expect(dotted.url(for: "k", query: [("prefix", "x/")], region: "us-east-1")?.url.absoluteString == "https://s3.us-east-1.amazonaws.com/my.bucket/k?prefix=x%2F")
        let custom = S3Client(bucket: "b", settings: AWSSettings(credentials: nil, region: "auto", endpoint: URL(string: "https://acct.r2.cloudflarestorage.com/")), configuration: .ephemeral)
        #expect(custom.url(for: nil, query: [], region: "auto")?.url.absoluteString == "https://acct.r2.cloudflarestorage.com/b/")
    }

    @Test func `reads a listing without URL encoding as is`() throws {
        let xml = "<ListBucketResult><IsTruncated>false</IsTruncated><Contents><Key>a+b%20c</Key><Size>3</Size><LastModified>2024-01-05T14:30:00Z</LastModified></Contents></ListBucketResult>"
        let listing = try S3Client.parseListing(Data(xml.utf8))
        #expect(listing.objects.first?.key == "a+b%20c")
        #expect(listing.objects.first?.modified == 1_704_465_000_000_000_000)
    }
}

struct AWSSettingsTests {
    private let credentials = """
        [default]
        aws_access_key_id = DEFAULTKEY
        aws_secret_access_key = defaultsecret

        [work]
        aws_access_key_id=WORKKEY
        aws_secret_access_key=worksecret
        aws_session_token = token
        """
    private let config = """
        [default]
        region = eu-west-1

        [profile work]
        region = auto
        endpoint_url = https://acct.r2.cloudflarestorage.com
        s3 =
          addressing_style = path

        [profile sso]
        sso_session = company

        [profile tool]
        credential_process = /usr/local/bin/creds
        """

    private func resolve(_ options: RemoteLocation.S3Options, environment: [String: String] = [:]) throws -> AWSSettings {
        try AWSSettings.resolve(options, environment: environment, credentialsFile: credentials, configFile: config) { command in
            #expect(command == "/usr/local/bin/creds")
            return AWSCredentials(accessKey: "TOOLKEY", secretKey: "toolsecret")
        }
    }

    @Test func `uses the default profile`() throws {
        let settings = try resolve(.init())
        #expect(settings.credentials == AWSCredentials(accessKey: "DEFAULTKEY", secretKey: "defaultsecret"))
        #expect(settings.region == "eu-west-1")
        #expect(settings.endpoint == nil)
    }

    @Test func `a named profile brings its region and endpoint`() throws {
        let settings = try resolve(.init(profile: "work"))
        #expect(settings.credentials == AWSCredentials(accessKey: "WORKKEY", secretKey: "worksecret", sessionToken: "token"))
        #expect(settings.region == "auto")
        #expect(settings.endpoint?.absoluteString == "https://acct.r2.cloudflarestorage.com")
    }

    @Test func `the environment wins over the default profile but not over a chosen one`() throws {
        let environment = ["AWS_ACCESS_KEY_ID": "ENVKEY", "AWS_SECRET_ACCESS_KEY": "envsecret", "AWS_REGION": "ap-south-1", "AWS_ENDPOINT_URL_S3": "http://localhost:9000"]
        let settings = try resolve(.init(), environment: environment)
        #expect(settings.credentials?.accessKey == "ENVKEY")
        #expect(settings.region == "ap-south-1")
        #expect(settings.endpoint?.absoluteString == "http://localhost:9000")
        #expect(try resolve(.init(profile: "work"), environment: environment).credentials?.accessKey == "WORKKEY")
        #expect(try resolve(.init(), environment: ["AWS_PROFILE": "work"]).credentials?.accessKey == "WORKKEY")
    }

    @Test func `typed values win over everything`() throws {
        let settings = try resolve(.init(endpoint: "minio.local:9000", region: "us-west-2", profile: "work"))
        #expect(settings.region == "us-west-2")
        #expect(settings.endpoint?.absoluteString == "https://minio.local:9000")
    }

    @Test func `credential_process is run`() throws {
        #expect(try resolve(.init(profile: "tool")).credentials?.accessKey == "TOOLKEY")
    }

    @Test func `SSO profiles explain how to use them`() {
        #expect(throws: RemoteError.self) { try resolve(.init(profile: "sso")) }
    }

    @Test func `a missing profile is reported`() {
        #expect(throws: RemoteError("There is no AWS profile \"nope\" in ~/.aws/credentials or ~/.aws/config.")) { try resolve(.init(profile: "nope")) }
    }

    @Test func `no credentials at all means unsigned requests`() throws {
        let settings = try AWSSettings.resolve(.init(), environment: [:], credentialsFile: "", configFile: "") { _ in AWSCredentials(accessKey: "", secretKey: "") }
        #expect(settings.credentials == nil)
        #expect(settings.region == "us-east-1")
    }

    @Test func `reads the JSON of credential_process`() throws {
        let json = #"{"Version": 1, "AccessKeyId": "AK", "SecretAccessKey": "SK", "SessionToken": "ST", "Expiration": "2030-01-01T00:00:00Z"}"#
        #expect(try AWSSettings.parseCredentialProcess(Data(json.utf8)) == AWSCredentials(accessKey: "AK", secretKey: "SK", sessionToken: "ST"))
    }
}
