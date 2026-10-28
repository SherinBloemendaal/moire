import Foundation

/// A remote server or the tool that talks to it reported a problem. The message is shown as is.
public struct RemoteError: LocalizedError, Sendable, Hashable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}
