import Foundation
import EgressCore

struct TunnelSnapshot: Decodable, Sendable {
    struct Stats: Decodable, Sendable {
        let uploaded: Int64
        let downloaded: Int64
        let active: Int
    }
    let state: String
    let message: String
    let ip: String
    let stats: Stats
}

// The Go Session synchronizes its mutable state and permits concurrent Stop.
final class Tunnel: @unchecked Sendable {
    private let session: MobileSession

    init(manifest: String, key: String, expedia: Bool = false) throws {
        var error: NSError?
        let value = expedia ? MobileNewExpediaSession(manifest, key, &error) : MobileNewSession(manifest, key, &error)
        guard let value else {
            throw error ?? NSError(domain: "iOSEgress", code: 1)
        }
        session = value
    }

    func start() throws { try session.start() }
    func stop() { session.stop() }
    func snapshot() throws -> TunnelSnapshot {
        try JSONDecoder().decode(TunnelSnapshot.self, from: Data(session.snapshot().utf8))
    }
    func proxyConfig() throws -> ProxyConfiguration {
        try JSONDecoder().decode(ProxyConfiguration.self, from: Data(session.proxyConfig().utf8))
    }
    func directIP(host: String) throws -> String {
        var error: NSError?
        let ip = session.directIP(host, error: &error)
        if let error { throw error }
        return ip
    }

    static func generateKey() throws -> String {
        var error: NSError?
        let key = MobileGenerateKey(&error)
        if let error { throw error }
        return key
    }
    static func publicKey(_ privateKey: String) throws -> String {
        var error: NSError?
        let key = MobilePublicKey(privateKey, &error)
        if let error { throw error }
        return key
    }
    static func validateManifest(_ text: String) throws {
        var error: NSError?
        guard MobileValidateManifest(text, &error) else {
            throw error ?? NSError(domain: "iOSEgress", code: 2)
        }
    }
}
