import CryptoKit
import Foundation

/// An access key, as AWS and S3-compatible storage hand them out.
public struct AWSCredentials: Sendable, Hashable {
    public var accessKey: String
    public var secretKey: String
    /// Only for temporary credentials (SSO, assumed roles).
    public var sessionToken: String?

    public init(accessKey: String, secretKey: String, sessionToken: String? = nil) {
        self.accessKey = accessKey
        self.secretKey = secretKey
        self.sessionToken = sessionToken
    }
}

/// AWS Signature Version 4 for requests in the `Authorization` header.
///
/// Paths are signed as given (already percent-encoded once), the way S3 wants them: S3 is the
/// one service that does not encode paths twice or remove `.` and `..` parts.
struct AWSSigner: Sendable {
    let credentials: AWSCredentials
    let region: String
    let service: String

    static let emptyPayloadHash = SHA256.hash(data: Data()).hex

    /// The headers to add to a request: `Authorization`, plus the session token when there is one.
    ///
    /// `headers` must include every header that is signed, at least `host` and `x-amz-date`.
    /// `query` holds names and values before encoding.
    func authorization(
        method: String,
        encodedPath: String,
        query: [(String, String)],
        headers: [(String, String)],
        payloadHash: String,
        amzDate: String
    ) -> String {
        let (canonical, signedHeaders) = Self.canonicalRequest(method: method, encodedPath: encodedPath, query: query, headers: headers, payloadHash: payloadHash)
        let day = String(amzDate.prefix(8))
        let scope = "\(day)/\(region)/\(service)/aws4_request"
        let stringToSign = Self.stringToSign(amzDate: amzDate, scope: scope, canonicalRequest: canonical)
        let signature = HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: signingKey(day: day)).hex
        return "AWS4-HMAC-SHA256 Credential=\(credentials.accessKey)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
    }

    func signingKey(day: String) -> SymmetricKey {
        func hmac(_ key: SymmetricKey, _ text: String) -> SymmetricKey {
            SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: key)))
        }
        let secret = SymmetricKey(data: Data("AWS4\(credentials.secretKey)".utf8))
        return hmac(hmac(hmac(hmac(secret, day), region), service), "aws4_request")
    }

    static func canonicalRequest(
        method: String,
        encodedPath: String,
        query: [(String, String)],
        headers: [(String, String)],
        payloadHash: String
    ) -> (request: String, signedHeaders: String) {
        let encodedQuery: [(name: String, value: String)] = query.map { (encode($0.0), encode($0.1)) }
        let sortedQuery = encodedQuery.sorted { a, b in a.name == b.name ? a.value < b.value : a.name < b.name }
        let canonicalQuery = sortedQuery.map { "\($0.name)=\($0.value)" }.joined(separator: "&")

        // Names in lower case, values without surrounding spaces and with inner runs of spaces
        // made one; a header given twice is joined with commas.
        var merged: [String: [String]] = [:]
        for (name, value) in headers {
            let collapsed = value.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            merged[name.lowercased(), default: []].append(collapsed.trimmingCharacters(in: .whitespaces))
        }
        let names = merged.keys.sorted()
        let canonicalHeaders = names.map { "\($0):\(merged[$0, default: []].joined(separator: ","))\n" }.joined()
        let signedHeaders = names.joined(separator: ";")
        let path = encodedPath.isEmpty ? "/" : encodedPath
        let request = [method, path, canonicalQuery, canonicalHeaders, signedHeaders, payloadHash].joined(separator: "\n")
        return (request, signedHeaders)
    }

    static func stringToSign(amzDate: String, scope: String, canonicalRequest: String) -> String {
        ["AWS4-HMAC-SHA256", amzDate, scope, SHA256.hash(data: Data(canonicalRequest.utf8)).hex].joined(separator: "\n")
    }

    private static let unreserved: Set<UInt8> = Set(Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~".utf8))

    /// Percent-encodes everything but the unreserved characters of RFC 3986, as SigV4 requires.
    static func encode(_ text: String, keepSlash: Bool = false) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for byte in text.utf8 {
            if unreserved.contains(byte) || (keepSlash && byte == UInt8(ascii: "/")) {
                result.unicodeScalars.append(Unicode.Scalar(byte))
            } else {
                result += String(format: "%%%02X", byte)
            }
        }
        return result
    }

    /// `20150830T123600Z`, the form of `x-amz-date`.
    static func amzDate(_ date: Date) -> String {
        var seconds = time_t(date.timeIntervalSince1970.rounded(.down))
        var parts = tm()
        gmtime_r(&seconds, &parts)
        return String(format: "%04d%02d%02dT%02d%02d%02dZ", parts.tm_year + 1900, parts.tm_mon + 1, parts.tm_mday, parts.tm_hour, parts.tm_min, parts.tm_sec)
    }
}

extension Digest {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

extension HashedAuthenticationCode {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
