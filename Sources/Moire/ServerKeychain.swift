import Foundation
import MoireKit
import Security

/// FTP passwords, kept as internet passwords in the login Keychain. They never go into
/// UserDefaults or the list of recent servers.
enum ServerKeychain {
    private static func query(for location: RemoteLocation) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: location.host,
            kSecAttrAccount as String: location.user ?? "anonymous",
            kSecAttrProtocol as String: location.scheme == .ftp ? kSecAttrProtocolFTP : kSecAttrProtocolFTPS,
        ]
        if let port = location.port { query[kSecAttrPort as String] = port }
        return query
    }

    static func password(for location: RemoteLocation) -> String? {
        var query = query(for: location)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ password: String, for location: RemoteLocation) throws {
        let data = Data(password.utf8)
        let status = SecItemUpdate(query(for: location) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw error(status) }
        var item = query(for: location)
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = location.url
        item[kSecAttrComment as String] = "Saved by Moire"
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw error(added) }
    }

    private static func error(_ status: OSStatus) -> RemoteError {
        let text = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
        return RemoteError("Could not save the password in the Keychain: \(text)")
    }
}

/// Servers connected to before, newest first. Holds addresses and S3 settings, never passwords.
enum RecentServers {
    private static let key = "recentServers"
    static let limit = 10

    static func load() -> [RemoteLocation] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([RemoteLocation].self, from: data)) ?? []
    }

    static func add(_ location: RemoteLocation) {
        let list = [location] + load().filter { $0 != location }
        store(Array(list.prefix(limit)))
    }

    static func remove(_ location: RemoteLocation) {
        store(load().filter { $0 != location })
    }

    private static func store(_ list: [RemoteLocation]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
