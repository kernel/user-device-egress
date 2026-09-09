import Foundation
import Security
import Darwin

struct RelayManifest: Codable, Equatable, Sendable {
    let tenant: String
    let ip: String
    let port: Int
    let ssh_port: Int
    let tunnel_port: Int
    let ssh_user: String
    let host_key: String

    func validate() throws {
        var address = in_addr()
        guard inet_pton(AF_INET, ip, &address) == 1,
              tenant.range(of: "^[a-z][a-z0-9]{0,19}$", options: .regularExpression) != nil,
              (20000...29999).contains(port), ssh_port == port + 20000,
              tunnel_port == port + 10000, ssh_user == "relay_" + tenant else {
            throw DeviceError.invalidManifest
        }
        let parts = host_key.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard !host_key.contains("\n"), !host_key.contains("\r"),
              parts.count >= 2, parts[0] == "ssh-ed25519",
              Data(base64Encoded: String(parts[1]))?.count == 51 else {
            throw DeviceError.invalidManifest
        }
    }
}

struct DeviceConnection: Codable, Sendable {
    let manifest: RelayManifest
    let private_key: String

    func validate() throws {
        try manifest.validate()
        guard private_key.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----\n"),
              private_key.utf8.count < 16384 else { throw DeviceError.invalidKey }
    }
}

enum DeviceError: LocalizedError {
    case invalidManifest, invalidKey, keychain(OSStatus), missingHelpers
    var errorDescription: String? {
        switch self {
        case .invalidManifest: "That is not a valid relay enrollment manifest. Import the JSON returned by tenant.sh enroll."
        case .invalidKey: "Choose the matching OpenSSH private key, not the .pub file. Passphrase-protected keys are not supported in this prototype."
        case .keychain(let status): "Keychain could not access the device connection (\(status)). Unlock your login keychain and try again."
        case .missingHelpers: "The bundled helpers are missing. Install Go on the build Mac and rebuild the Xcode project."
        }
    }
}

// Blocking Keychain work stays off the main actor. One item holds the paired manifest/key.
actor DeviceStore {
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "\(Bundle.main.bundleIdentifier ?? "com.example.MacEgress").device",
         kSecAttrAccount as String: "enrolled-device", kSecAttrSynchronizable as String: false]
    }
    func load() throws -> DeviceConnection? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw DeviceError.keychain(status) }
        let device = try JSONDecoder().decode(DeviceConnection.self, from: data)
        try device.validate()
        return device
    }
    func save(_ device: DeviceConnection) throws {
        try device.validate()
        let data = try JSONEncoder().encode(device)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var request = query
            request[kSecValueData as String] = data
            request[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(request as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw DeviceError.keychain(status) }
    }
    func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw DeviceError.keychain(status) }
    }
}
