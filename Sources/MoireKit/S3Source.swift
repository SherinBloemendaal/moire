import Foundation
import Synchronization

/// A folder (a key prefix) in an S3 bucket, on AWS or on storage that speaks the same API
/// (Cloudflare R2, MinIO, Backblaze B2). Folders are the common prefixes of `ListObjectsV2` with
/// `/` as the delimiter.
public final class S3Source: FolderSource {
    public let displayName: String
    public let volume = Volume(fileSystem: "s3", isLocal: false)
    /// The key prefix of the compared folder: empty, or ending in `/`.
    public let prefix: String
    let client: S3Client

    public convenience init(location: RemoteLocation) throws {
        try self.init(location: location, settings: AWSSettings.resolve(location.s3))
    }

    init(location: RemoteLocation, settings: AWSSettings, configuration: URLSessionConfiguration = .ephemeral) throws {
        displayName = location.displayName
        let trimmed = location.path.split(separator: "/").joined(separator: "/")
        prefix = trimmed.isEmpty ? "" : trimmed + "/"
        client = S3Client(bucket: location.host, settings: settings, configuration: configuration)
        // Reaches the bucket once, so a wrong key, region or bucket name is reported right away.
        let first = try client.list(prefix: prefix, continuation: nil, maximum: 1)
        if !prefix.isEmpty, first.objects.isEmpty, first.prefixes.isEmpty {
            throw RemoteError("Nothing is stored under \"\(prefix)\" in the bucket \(location.host).")
        }
    }

    private func key(_ path: String) -> String { prefix + path }

    public func list(_ path: String, skipHidden: Bool) throws -> [DirectoryEntry] {
        let folder = path.isEmpty ? prefix : prefix + path + "/"
        var entries: [DirectoryEntry] = []
        var continuation: String?
        repeat {
            let page = try client.list(prefix: folder, continuation: continuation, maximum: nil)
            for common in page.prefixes {
                guard common.hasPrefix(folder) else { continue }
                let name = String(common.dropFirst(folder.count).dropLast())
                // `a//b` has an empty folder name in it, which no file system can show.
                guard !name.isEmpty, !name.contains("/"), !(skipHidden && name.hasPrefix(".")) else { continue }
                entries.append(DirectoryEntry(name: name, kind: .directory, size: 0, modified: 0, fileID: 0))
            }
            for object in page.objects {
                guard object.key.hasPrefix(folder) else { continue }
                let name = String(object.key.dropFirst(folder.count))
                // The empty object some tools create to mark a folder.
                guard !name.isEmpty, !(skipHidden && name.hasPrefix(".")) else { continue }
                entries.append(DirectoryEntry(name: name, kind: .file, size: object.size, modified: object.modified, fileID: 0))
            }
            continuation = page.nextContinuation
        } while continuation != nil
        return entries
    }

    public func open(_ path: String) throws -> any ReadableFile {
        let size = try client.size(of: key(path))
        return S3File(client: client, key: key(path), size: size)
    }

    public func open(_ path: String, listedSize: Int64) throws -> any ReadableFile {
        S3File(client: client, key: key(path), size: listedSize)
    }

    /// S3 has no symbolic links, so none is ever listed.
    public func linkDestination(_ path: String) throws -> String {
        throw RemoteError("S3 has no symbolic links.")
    }

    public func localURL(_ path: String) -> URL? { nil }
}

/// Signs and sends S3 requests for one bucket.
final class S3Client: Sendable {
    let bucket: String
    let settings: AWSSettings
    let session: URLSession
    /// Fixed on the first answer that names another region for the bucket.
    private let region: Mutex<String>

    init(bucket: String, settings: AWSSettings, configuration: URLSessionConfiguration) {
        self.bucket = bucket
        self.settings = settings
        region = Mutex(settings.region)
        configuration.httpMaximumConnectionsPerHost = 16
        configuration.timeoutIntervalForRequest = 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    deinit {
        session.invalidateAndCancel()
    }

    /// Virtual-hosted addresses for AWS (bucket names with dots or capitals do not fit in a host
    /// name, so those go in the path), path-style for custom endpoints, which all support it.
    func url(for key: String?, query: [(String, String)], region: String) -> (url: URL, encodedPath: String)? {
        let encodedKey = key.map { "/" + AWSSigner.encode($0, keepSlash: true) } ?? "/"
        var base: String
        var encodedPath: String
        if let endpoint = settings.endpoint {
            var root = endpoint.absoluteString
            while root.hasSuffix("/") { root.removeLast() }
            let endpointPath = endpoint.path(percentEncoded: true).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            base = root
            encodedPath = (endpointPath.isEmpty ? "" : "/" + endpointPath) + "/" + AWSSigner.encode(bucket) + (key == nil ? "/" : encodedKey)
            if !endpointPath.isEmpty, let host = endpoint.host() {
                base = "\(endpoint.scheme ?? "https")://\(host)\(endpoint.port.map { ":\($0)" } ?? "")"
            }
        } else if Self.fitsInHostName(bucket) {
            base = "https://\(bucket).s3.\(region).amazonaws.com"
            encodedPath = encodedKey
        } else {
            base = "https://s3.\(region).amazonaws.com"
            encodedPath = "/" + AWSSigner.encode(bucket) + (key == nil ? "/" : encodedKey)
        }
        let queryString = query.map { "\(AWSSigner.encode($0.0))=\(AWSSigner.encode($0.1))" }.joined(separator: "&")
        guard let url = URL(string: base + encodedPath + (queryString.isEmpty ? "" : "?" + queryString)) else { return nil }
        return (url, encodedPath)
    }

    static func fitsInHostName(_ bucket: String) -> Bool {
        guard (3...63).contains(bucket.count) else { return false }
        return bucket.allSatisfy { ($0.isLowercase && $0.isASCII) || ($0.isNumber && $0.isASCII) || $0 == "-" }
    }

    func request(method: String, key: String?, query: [(String, String)], headers: [(String, String)], date: Date = Date()) throws -> URLRequest {
        let region = region.withLock { $0 }
        guard let (url, encodedPath) = url(for: key, query: query, region: region), let host = url.host() else {
            throw RemoteError("Could not make an address for the bucket \(bucket).")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        guard let credentials = settings.credentials else { return request }

        let amzDate = AWSSigner.amzDate(date)
        var signed = headers
        let hostHeader = url.port.map { "\(host):\($0)" } ?? host
        signed.append(("host", hostHeader))
        signed.append(("x-amz-date", amzDate))
        signed.append(("x-amz-content-sha256", AWSSigner.emptyPayloadHash))
        if let token = credentials.sessionToken { signed.append(("x-amz-security-token", token)) }
        let signer = AWSSigner(credentials: credentials, region: region, service: "s3")
        let authorization = signer.authorization(
            method: method, encodedPath: encodedPath, query: query, headers: signed,
            payloadHash: AWSSigner.emptyPayloadHash, amzDate: amzDate
        )
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(AWSSigner.emptyPayloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        if let token = credentials.sessionToken { request.setValue(token, forHTTPHeaderField: "x-amz-security-token") }
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        return request
    }

    /// Sends a request and waits. Retries brief failures, and follows a bucket that lives in
    /// another region than the one configured. Answers outside 200 to 299 and `accepting` throw.
    func perform(method: String, key: String?, query: [(String, String)] = [], headers: [(String, String)] = [], accepting: Set<Int> = []) throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        var followedRegion = false
        while true {
            attempt += 1
            let request = try request(method: method, key: key, query: query, headers: headers)
            let result = Self.send(request, session: session)
            switch result {
            case .failure(let error):
                if attempt < 3, Self.isTransient(error) {
                    Thread.sleep(forTimeInterval: 0.25 * Double(attempt * attempt))
                    continue
                }
                throw RemoteError("Could not reach \(request.url?.host() ?? bucket): \(error.localizedDescription)")
            case .success(let (data, response)):
                if (200..<300).contains(response.statusCode) || accepting.contains(response.statusCode) { return (data, response) }
                if settings.endpoint == nil, !followedRegion, let actual = response.value(forHTTPHeaderField: "x-amz-bucket-region"),
                   actual != region.withLock({ $0 }) {
                    region.withLock { $0 = actual }
                    followedRegion = true
                    continue
                }
                if attempt < 3, [500, 502, 503, 504].contains(response.statusCode) {
                    Thread.sleep(forTimeInterval: 0.25 * Double(attempt * attempt))
                    continue
                }
                throw error(response: response, body: data, key: key)
            }
        }
    }

    static func isTransient(_ error: any Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return [.timedOut, .networkConnectionLost, .cannotConnectToHost].contains(error.code)
    }

    private final class Box: @unchecked Sendable {
        // Written by the completion handler before `done` is signalled, read after waiting.
        var result: Result<(Data, HTTPURLResponse), any Error> = .failure(URLError(.unknown))
        let done = DispatchSemaphore(value: 0)
    }

    static func send(_ request: URLRequest, session: URLSession) -> Result<(Data, HTTPURLResponse), any Error> {
        let box = Box()
        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                box.result = .failure(error)
            } else if let response = response as? HTTPURLResponse {
                box.result = .success((data ?? Data(), response))
            } else {
                box.result = .failure(URLError(.badServerResponse))
            }
            box.done.signal()
        }
        task.resume()
        box.done.wait()
        return box.result
    }

    /// The server's own words from an error answer.
    func error(response: HTTPURLResponse, body: Data, key: String?) -> RemoteError {
        let xml = S3XML.parse(body)
        let code = xml?.text(of: "Code")
        let message = xml?.text(of: "Message")
        let what = key.map { "\($0): " } ?? ""
        var text: String
        switch (response.statusCode, code) {
        case (404, "NoSuchBucket"):
            text = "The bucket \(bucket) does not exist."
        case (404, nil) where key == nil:
            text = "The bucket \(bucket) does not exist."
        case (404, _):
            text = "\(what)No such file."
        default:
            text = what + (message ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode).capitalized)
            if let code { text += " (\(code))" }
        }
        if settings.credentials == nil, response.statusCode == 403 {
            text += " No AWS credentials were found, so the request was sent unsigned. Set a profile, or the AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY variables."
        }
        return RemoteError(text)
    }

    struct Listing {
        struct Object {
            let key: String
            let size: Int64
            let modified: Int64
        }

        var objects: [Object] = []
        var prefixes: [String] = []
        var nextContinuation: String?
    }

    func list(prefix: String, continuation: String?, maximum: Int?) throws -> Listing {
        var query: [(String, String)] = [("list-type", "2"), ("delimiter", "/"), ("encoding-type", "url"), ("prefix", prefix)]
        if let continuation { query.append(("continuation-token", continuation)) }
        if let maximum { query.append(("max-keys", String(maximum))) }
        let (data, _) = try perform(method: "GET", key: nil, query: query)
        return try Self.parseListing(data)
    }

    static func parseListing(_ data: Data) throws -> Listing {
        guard let root = S3XML.parse(data), root.name == "ListBucketResult" else {
            throw RemoteError("The storage server sent a folder listing Moire cannot read.")
        }
        // Keys come percent-encoded (with + for spaces) only when the server applied the encoding.
        let encoded = root.text(of: "EncodingType") == "url"
        func key(_ text: String) -> String {
            guard encoded else { return text }
            return text.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? text
        }
        var listing = Listing()
        for element in root.children where element.name == "Contents" {
            guard let rawKey = element.text(of: "Key") else { continue }
            let size = element.text(of: "Size").flatMap { Int64($0) } ?? 0
            let modified = element.text(of: "LastModified").flatMap(RemoteDate.iso8601) ?? 0
            listing.objects.append(Listing.Object(key: key(rawKey), size: size, modified: modified))
        }
        for element in root.children where element.name == "CommonPrefixes" {
            if let prefix = element.text(of: "Prefix") { listing.prefixes.append(key(prefix)) }
        }
        if root.text(of: "IsTruncated") == "true" {
            guard let next = root.text(of: "NextContinuationToken"), !next.isEmpty else {
                throw RemoteError("The storage server cut the folder listing short without saying where to go on.")
            }
            listing.nextContinuation = next
        }
        return listing
    }

    func size(of key: String) throws -> Int64 {
        let (_, response) = try perform(method: "HEAD", key: key)
        guard let length = response.value(forHTTPHeaderField: "Content-Length").flatMap({ Int64($0) }) else {
            throw RemoteError("\(key): the storage server did not say how big the file is.")
        }
        return length
    }

    /// Bytes `offset..<offset + count`; fewer at the end of the object.
    func read(key: String, offset: Int64, count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        let range = "bytes=\(offset)-\(offset + Int64(count) - 1)"
        // 416: the range starts past the end of the object.
        let (data, response) = try perform(method: "GET", key: key, headers: [("Range", range)], accepting: [416])
        switch response.statusCode {
        case 416:
            return Data()
        case 200:
            // A server that ignores the range sends the whole object.
            let start = Int(min(offset, Int64(data.count)))
            return data.subdata(in: start..<min(data.count, start + count))
        default:
            return data.prefix(count)
        }
    }
}

/// An S3 object. Sequential reads stream one `GetObject`; reads at an offset use `Range`.
final class S3File: ReadableFile {
    let size: Int64
    private let client: S3Client
    private let key: String
    private var stream: S3Stream?

    init(client: S3Client, key: String, size: Int64) {
        self.client = client
        self.key = key
        self.size = size
    }

    deinit {
        stream?.cancel()
    }

    func readNext(into buffer: UnsafeMutableRawPointer, count: Int) throws -> Int {
        if stream == nil {
            stream = try S3Stream(client: client, key: key)
        }
        guard let stream else { return 0 }
        var total = 0
        while total < count {
            let read = try stream.read(into: buffer + total, count: count - total)
            if read == 0 { break }
            total += read
        }
        return total
    }

    func read(at offset: Int64, count: Int) throws -> Data {
        try client.read(key: key, offset: offset, count: count)
    }
}

/// One `GetObject` whose body is handed out as it arrives. The download pauses while more than
/// a few MB wait to be read, so a slow comparison never fills memory.
final class S3Stream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    // Every field below is only touched while `condition` is locked.
    private let condition = NSCondition()
    private var chunks: [Data] = []
    private var chunkOffset = 0
    private var buffered = 0
    private var response: HTTPURLResponse?
    private var errorBody = Data()
    private var failure: (any Error)?
    private var finished = false
    private var paused = false
    private var task: URLSessionDataTask?
    private let client: S3Client
    private let key: String

    static let pauseAbove = 8 << 20
    static let resumeBelow = 2 << 20

    init(client: S3Client, key: String) throws {
        self.client = client
        self.key = key
        super.init()
        let request = try client.request(method: "GET", key: key, query: [], headers: [])
        let task = client.session.dataTask(with: request)
        task.delegate = self
        condition.lock()
        self.task = task
        condition.unlock()
        task.resume()
    }

    func cancel() {
        condition.lock()
        let task = task
        condition.unlock()
        task?.cancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        condition.lock()
        self.response = response as? HTTPURLResponse
        condition.broadcast()
        condition.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        condition.lock()
        defer { condition.unlock() }
        guard let response, (200..<300).contains(response.statusCode) else {
            errorBody.append(data)
            return
        }
        chunks.append(data)
        buffered += data.count
        if buffered > Self.pauseAbove, !paused {
            paused = true
            dataTask.suspend()
        }
        condition.broadcast()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        condition.lock()
        failure = error
        finished = true
        condition.broadcast()
        condition.unlock()
    }

    func read(into buffer: UnsafeMutableRawPointer, count: Int) throws -> Int {
        condition.lock()
        defer { condition.unlock() }
        while chunks.isEmpty, !finished {
            if let response, !(200..<300).contains(response.statusCode) {
                // Wait for the whole error answer before reporting it.
                while !finished { condition.wait() }
                break
            }
            condition.wait()
        }
        if let response, !(200..<300).contains(response.statusCode) {
            throw client.error(response: response, body: errorBody, key: key)
        }
        if chunks.isEmpty {
            if let failure { throw RemoteError("\(key): \(failure.localizedDescription)") }
            return 0
        }
        var total = 0
        while total < count, let first = chunks.first {
            let take = min(count - total, first.count - chunkOffset)
            first.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                (buffer + total).copyMemory(from: base + chunkOffset, byteCount: take)
            }
            total += take
            chunkOffset += take
            if chunkOffset == first.count {
                chunks.removeFirst()
                chunkOffset = 0
            }
        }
        buffered -= total
        if paused, buffered < Self.resumeBelow {
            paused = false
            task?.resume()
        }
        return total
    }
}

/// Just enough XML for S3 answers: elements with their text and children.
struct S3XML {
    var name: String
    var text = ""
    var children: [S3XML] = []

    func child(_ name: String) -> S3XML? { children.first { $0.name == name } }

    /// The text of the first child called `name`, or of this element when it is called `name`.
    func text(of name: String) -> String? {
        if self.name == name { return text }
        return child(name)?.text
    }

    static func parse(_ data: Data) -> S3XML? {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        guard parser.parse() else { return nil }
        return builder.root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var stack: [S3XML] = []
        var root: S3XML?

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            stack.append(S3XML(name: elementName))
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard !stack.isEmpty else { return }
            stack[stack.count - 1].text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            guard let finished = stack.popLast() else { return }
            if stack.isEmpty {
                root = finished
            } else {
                stack[stack.count - 1].children.append(finished)
            }
        }
    }
}
