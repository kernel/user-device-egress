import Foundation

struct PairingInvitation: Equatable, Sendable {
    let host: String
    let token: String
    var endpoint: URL { URL(string: "https://\(host)/v1/pair")! }

    init(_ text: String) throws {
        guard text.count < 512, let url = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", let host = url.host,
              url.port == nil, url.user == nil, url.password == nil,
              url.path == "/pair", url.query == nil,
              let token = url.fragment, token.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil else {
            throw DemoError("This isn't a Device Egress pairing code. Scan the code generated for this demo.")
        }
        // Relay deployment currently uses a public IPv4 address with a trusted IP certificate.
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, octets.allSatisfy({ value in
            guard let n = UInt8(value) else { return false }
            return String(n) == value
        }), let first = UInt8(octets[0]), let second = UInt8(octets[1]),
              first != 0, first != 10, first != 127, first < 224,
              !(first == 169 && second == 254), !(first == 172 && (16...31).contains(second)),
              !(first == 192 && second == 168), !(first == 100 && (64...127).contains(second)) else {
            throw DemoError("Pairing requires a public relay address.")
        }
        self.host = host; self.token = token
    }
}

private final class NoPairingRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum PairingClient {
    static func redeem(_ invitation: PairingInvitation, publicKey: String) async throws -> String {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 55
        config.timeoutIntervalForResource = 60
        config.urlCache = nil
        let session = URLSession(configuration: config, delegate: NoPairingRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: invitation.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["token": invitation.token, "public_key": publicKey.trimmingCharacters(in: .whitespacesAndNewlines)])
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw DemoError("Pairing returned an invalid response.") }
        guard http.statusCode == 200 else {
            switch http.statusCode {
            case 403, 410: throw DemoError("That pairing code expired or is no longer valid. Ask for a new code.")
            case 409: throw DemoError("That code is already in use or needs administrator recovery. Ask for a new code.")
            case 429: throw DemoError("Too many pairing attempts. Wait a minute and scan again.")
            default: throw DemoError("Pairing couldn't finish. Scan the same code to retry before it expires.")
            }
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 16384 else { throw DemoError("Pairing response was too large.") }
            data.append(byte)
        }
        guard let manifest = String(data: data, encoding: .utf8) else { throw DemoError("Invalid relay connection.") }
        try Tunnel.validateManifest(manifest)
        struct Address: Decodable { let ip: String }
        guard try JSONDecoder().decode(Address.self, from: data).ip == invitation.host else {
            throw DemoError("The returned relay doesn't match the pairing code.")
        }
        return manifest
    }
}
