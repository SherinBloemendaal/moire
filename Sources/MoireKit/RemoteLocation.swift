import Foundation

/// A folder on a server, as the user types it: `sftp://user@host:22/srv/app`, `ftp://host/pub`,
/// `ftps://host/site`, `ftpes://host/site` or `s3://bucket/prefix`. Never holds a password.
public struct RemoteLocation: Sendable, Hashable, Codable {
    public enum Scheme: String, Sendable, Hashable, Codable, CaseIterable {
        case sftp
        /// Plain FTP. The password travels unencrypted.
        case ftp
        /// FTP over TLS from the first byte (implicit TLS, usually port 990).
        case ftps
        /// FTP that switches to TLS with `AUTH TLS` before logging in (explicit TLS, port 21).
        case ftpes
        case s3

        public var isFTP: Bool { self == .ftp || self == .ftps || self == .ftpes }

        public var title: String {
            switch self {
            case .sftp: "SFTP"
            case .ftp: "FTP"
            case .ftps: "FTPS"
            case .ftpes: "FTPS (explicit)"
            case .s3: "S3"
            }
        }
    }

    /// For S3 and storage that speaks its API (Cloudflare R2, MinIO, Backblaze B2).
    public struct S3Options: Sendable, Hashable, Codable {
        /// Such as `https://<account>.r2.cloudflarestorage.com` or `http://localhost:9000`.
        /// Empty for AWS itself.
        public var endpoint: String
        /// Empty to take it from the profile or the environment, then `us-east-1`.
        public var region: String
        /// A profile in `~/.aws/credentials` and `~/.aws/config`. Empty for the default chain.
        public var profile: String

        public init(endpoint: String = "", region: String = "", profile: String = "") {
            self.endpoint = endpoint
            self.region = region
            self.profile = profile
        }
    }

    public var scheme: Scheme
    public var user: String?
    /// The server, or the bucket for S3.
    public var host: String
    public var port: Int?
    /// The folder, as in the URL: starts with `/`, or is empty for the default folder.
    public var path: String
    public var s3: S3Options

    public init(scheme: Scheme, user: String? = nil, host: String, port: Int? = nil, path: String = "", s3: S3Options = S3Options()) {
        self.scheme = scheme
        self.user = user.flatMap { $0.isEmpty ? nil : $0 }
        self.host = host
        self.port = port
        self.path = path
        self.s3 = s3
    }

    /// Reads a typed URL. A password in it is returned separately, so it can go to the Keychain.
    public static func parse(_ text: String) throws -> (location: RemoteLocation, password: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed), let rawScheme = components.scheme?.lowercased() else {
            throw RemoteError("\"\(trimmed)\" is not a server address. Type one like sftp://user@host/folder.")
        }
        guard let scheme = Scheme(rawValue: rawScheme) else {
            throw RemoteError("Moire cannot connect to \(rawScheme):// addresses. Use sftp://, ftp://, ftps://, ftpes:// or s3://.")
        }
        guard let host = components.host, !host.isEmpty else {
            throw RemoteError(scheme == .s3 ? "Add the bucket name: s3://bucket/folder." : "Add the server name: \(rawScheme)://host/folder.")
        }
        if scheme == .s3, components.user != nil || components.port != nil {
            throw RemoteError("An s3:// address holds only the bucket and the folder. Set the endpoint, region and profile separately.")
        }
        var path = components.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if path == "/" && scheme == .s3 { path = "" }
        let location = RemoteLocation(scheme: scheme, user: components.user, host: host, port: components.port, path: path)
        return (location, components.password.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// The address without a password.
    public var url: String {
        var components = URLComponents()
        components.scheme = scheme.rawValue
        components.user = user
        components.host = host
        components.port = port
        components.path = path
        return components.string ?? "\(scheme.rawValue)://\(host)\(path)"
    }

    /// The last folder name, or the server when the path is empty.
    public var name: String {
        let last = path.split(separator: "/").last.map(String.init)
        return last ?? host
    }

    public var displayName: String {
        guard scheme == .s3 else { return url }
        let endpoint = s3.endpoint.isEmpty ? "" : " on \(URL(string: s3.endpoint)?.host ?? s3.endpoint)"
        return url + endpoint
    }
}
