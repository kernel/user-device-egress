import Foundation
import Security

struct DeviceSettings: Codable, Sendable {
    var privateKey: String
    var manifest: String = ""
    var apiKey: String = ""
}

struct DemoRecovery: Codable, Sendable {
    var name = "iphone-egress-" + UUID().uuidString.lowercased()
    var proxyID: String?
    var browserID: String?
    var proxyRequested = false
    var browserRequested = false
}

struct DemoError: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// One actor serializes Keychain access. Device keys and the optional demo API key
// are never written to Documents, UserDefaults, logs, or the exported public key.
actor DeviceStore {
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "\(Bundle.main.bundleIdentifier ?? "iOSEgress").demo",
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    func load<T: Decodable & Sendable>(_ type: T.Type, account: String) throws -> T? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else {
            throw DemoError("Unlock your iPhone to access the demo's Keychain (\(status)).")
        }
        return try JSONDecoder().decode(type, from: data)
    }

    func save<T: Encodable & Sendable>(_ value: T, account: String) throws {
        let data = try JSONEncoder().encode(value)
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(account)
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(q as CFDictionary, nil)
            guard added == errSecSuccess else { throw DemoError("Could not save to Keychain (\(added)).") }
        } else if status != errSecSuccess {
            throw DemoError("Could not update Keychain (\(status)).")
        }
    }

    func remove(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DemoError("Could not clear recovery data (\(status)).")
        }
    }
}
