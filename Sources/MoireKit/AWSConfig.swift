import Foundation

/// Where an S3 request goes and how it is signed, worked out like the AWS command line tools do:
/// the environment first, then the profile in `~/.aws/credentials` and `~/.aws/config`.
public struct AWSSettings: Sendable, Hashable {
    /// `nil` when nothing was found: requests then go out unsigned, which public buckets allow.
    public var credentials: AWSCredentials?
    public var region: String
    /// A custom endpoint (R2, MinIO, B2), or `nil` for AWS itself.
    public var endpoint: URL?

    public init(credentials: AWSCredentials?, region: String, endpoint: URL?) {
        self.credentials = credentials
        self.region = region
        self.endpoint = endpoint
    }

    /// Reads the profile files and the environment of this process.
    public static func resolve(_ options: RemoteLocation.S3Options) throws -> AWSSettings {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let credentialsFile = environment["AWS_SHARED_CREDENTIALS_FILE"].map { URL(filePath: ($0 as NSString).expandingTildeInPath) }
            ?? home.appending(path: ".aws/credentials")
        let configFile = environment["AWS_CONFIG_FILE"].map { URL(filePath: ($0 as NSString).expandingTildeInPath) }
            ?? home.appending(path: ".aws/config")
        return try resolve(
            options,
            environment: environment,
            credentialsFile: (try? String(contentsOf: credentialsFile, encoding: .utf8)) ?? "",
            configFile: (try? String(contentsOf: configFile, encoding: .utf8)) ?? "",
            runProcess: runCredentialProcess
        )
    }

    static func resolve(
        _ options: RemoteLocation.S3Options,
        environment: [String: String],
        credentialsFile: String,
        configFile: String,
        runProcess: (String) throws -> AWSCredentials
    ) throws -> AWSSettings {
        let credentialSections = AWSConfigFile.parse(credentialsFile)
        let configSections = AWSConfigFile.parse(configFile)
        let explicit = options.profile.trimmingCharacters(in: .whitespaces)
        let profileName = explicit.isEmpty ? (environment["AWS_PROFILE"].flatMap { $0.isEmpty ? nil : $0 } ?? "default") : explicit

        let fromCredentials = credentialSections[profileName] ?? [:]
        let fromConfig = configSections[profileName == "default" ? "default" : "profile \(profileName)"]
            ?? configSections[profileName] ?? [:]
        let profileExists = credentialSections[profileName] != nil || configSections[profileName == "default" ? "default" : "profile \(profileName)"] != nil
            || configSections[profileName] != nil
        var environmentKeys: AWSCredentials?
        if explicit.isEmpty, let key = environment["AWS_ACCESS_KEY_ID"], let secret = environment["AWS_SECRET_ACCESS_KEY"], !key.isEmpty, !secret.isEmpty {
            environmentKeys = AWSCredentials(accessKey: key, secretKey: secret, sessionToken: environment["AWS_SESSION_TOKEN"].flatMap { $0.isEmpty ? nil : $0 })
        }
        let namedProfile = !explicit.isEmpty || (environment["AWS_PROFILE"]?.isEmpty == false && environmentKeys == nil)
        if namedProfile, !profileExists {
            throw RemoteError("There is no AWS profile \"\(profileName)\" in ~/.aws/credentials or ~/.aws/config.")
        }
        // Credentials file values win over the config file, as in the AWS tools.
        let profile = fromConfig.merging(fromCredentials) { _, credential in credential }

        var credentials: AWSCredentials?
        if let environmentKeys {
            credentials = environmentKeys
        } else if let key = profile["aws_access_key_id"], let secret = profile["aws_secret_access_key"] {
            credentials = AWSCredentials(accessKey: key, secretKey: secret, sessionToken: profile["aws_session_token"])
        } else if let command = profile["credential_process"] {
            credentials = try runProcess(command)
        } else if profile["sso_session"] != nil || profile["sso_start_url"] != nil || profile["role_arn"] != nil {
            throw RemoteError("""
                The AWS profile "\(profileName)" signs in with SSO or a role, which Moire does not do itself. \
                Add this line to the profile in ~/.aws/config and try again: \
                credential_process = aws configure export-credentials --profile \(profileName) --format process
                """)
        }

        func value(_ explicit: String, _ variables: [String], _ key: String) -> String? {
            let trimmed = explicit.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
            for variable in variables {
                if let value = environment[variable], !value.isEmpty { return value }
            }
            return profile[key]
        }

        let region = value(options.region, ["AWS_REGION", "AWS_DEFAULT_REGION"], "region") ?? "us-east-1"
        var endpoint: URL?
        if let text = value(options.endpoint, ["AWS_ENDPOINT_URL_S3", "AWS_ENDPOINT_URL"], "endpoint_url") {
            let withScheme = text.contains("://") ? text : "https://\(text)"
            guard let url = URL(string: withScheme), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host != nil else {
                throw RemoteError("\"\(text)\" is not an endpoint address. Type one like https://s3.example.com.")
            }
            endpoint = url
        }
        return AWSSettings(credentials: credentials, region: region, endpoint: endpoint)
    }

    /// Runs a profile's `credential_process` and reads the JSON it prints.
    static func runCredentialProcess(_ command: String) throws -> AWSCredentials {
        let process = try ChildProcess(executable: "/bin/sh", arguments: ["-c", command])
        process.closeInput()
        let output = try process.readToEnd()
        let code = process.wait()
        guard code == 0 else {
            let text = process.errorOutput()
            throw RemoteError("The credential_process of the AWS profile failed\(text.isEmpty ? " with exit code \(code)" : ": \(text)")")
        }
        return try parseCredentialProcess(output)
    }

    static func parseCredentialProcess(_ output: Data) throws -> AWSCredentials {
        struct Output: Decodable {
            let AccessKeyId: String
            let SecretAccessKey: String
            let SessionToken: String?
        }
        guard let parsed = try? JSONDecoder().decode(Output.self, from: output) else {
            throw RemoteError("The credential_process of the AWS profile did not print the expected JSON.")
        }
        return AWSCredentials(accessKey: parsed.AccessKeyId, secretKey: parsed.SecretAccessKey, sessionToken: parsed.SessionToken)
    }
}

/// The INI-style files of the AWS tools.
enum AWSConfigFile {
    /// Section name to keys. Keys are lower case; `#` and `;` start comments. Indented lines
    /// (nested settings such as `s3 =` blocks) are skipped.
    static func parse(_ text: String) -> [String: [String: String]] {
        var sections: [String: [String: String]] = [:]
        var current: String?
        for rawLine in text.split(whereSeparator: \.isNewline) {
            if rawLine.first == " " || rawLine.first == "\t" { continue }
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                let name = line.dropFirst().dropLast().split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
                current = name
                sections[name, default: [:]] = sections[name] ?? [:]
                continue
            }
            guard let current, let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.isEmpty { continue }
            sections[current, default: [:]][key] = value
        }
        return sections
    }
}
