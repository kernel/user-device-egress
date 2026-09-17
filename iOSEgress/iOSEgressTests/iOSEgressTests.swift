import Foundation
import Testing
@testable import iOSEgress

// This session never reaches Kernel or a relay.
private final class StubProtocol: URLProtocol, @unchecked Sendable {
    final class State: @unchecked Sendable {
        let lock = NSLock()
        var replies: [(Int, Data)] = []
        var requests: [URLRequest] = []
        func reset(_ values: [(Int, Data)]) { lock.withLock { replies = values; requests = [] } }
        func receive(_ request: URLRequest) -> (Int, Data) {
            lock.withLock {
                requests.append(request)
                return replies.isEmpty ? (599, Data()) : replies.removeFirst()
            }
        }
        func captured() -> [URLRequest] { lock.withLock { requests } }
    }
    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (code, data) = Self.state.receive(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized)
struct iOSEgressTests {
    @Test func pairingInvitationRequiresHTTPSPublicRelayAndSecretFragment() throws {
        let token = String(repeating: "x", count: 43)
        let invitation = try PairingInvitation("https://1.1.1.1/pair#\(token)")
        #expect(invitation.host == "1.1.1.1")
        #expect(invitation.endpoint.absoluteString == "https://1.1.1.1/v1/pair")
        #expect(!invitation.endpoint.absoluteString.contains(token))
        for invalid in ["http://1.1.1.1/pair#\(token)", "https://127.0.0.1/pair#\(token)",
                        "https://10.0.0.1/pair#\(token)", "https://192.168.1.1/pair#\(token)",
                        "https://1.1.1.1:8443/pair#\(token)", "https://user@1.1.1.1/pair#\(token)",
                        "https://1.1.1.1/pair?token=\(token)", "https://1.1.1.1/pair#short",
                        "https://example.com/pair#\(token)", "https://1.1.1.1/other#\(token)"] {
            #expect(throws: (any Error).self) { try PairingInvitation(invalid) }
        }
    }

    private func api(_ replies: [(Int, String)]) -> KernelAPI {
        StubProtocol.state.reset(replies.map { ($0.0, Data($0.1.utf8)) })
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return KernelAPI(key: "test-only", session: URLSession(configuration: config))
    }

    @Test func bridgeValidatesEnrollmentAndStopsWithoutNetwork() throws {
        let key = try Tunnel.generateKey()
        let publicKey = try Tunnel.publicKey(key).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(publicKey.hasPrefix("ssh-ed25519 "))
        let manifest: [String: Any] = ["tenant": "phone", "ip": "1.1.1.1", "port": 20008,
                                     "ssh_port": 40008, "tunnel_port": 30008,
                                     "ssh_user": "relay_phone", "host_key": publicKey]
        let raw = String(decoding: try JSONSerialization.data(withJSONObject: manifest), as: UTF8.self)
        try Tunnel.validateManifest(raw)
        #expect(throws: (any Error).self) { try Tunnel.validateManifest("{}") }
        let tunnel = try Tunnel(manifest: raw, key: key)
        let other = try Tunnel(manifest: raw, key: key)
        defer { tunnel.stop(); other.stop() }
        #expect(try tunnel.proxyConfig().password != other.proxyConfig().password)
        tunnel.stop()
        #expect(try tunnel.snapshot().state == "stopped")
        #expect(throws: (any Error).self) { try tunnel.start() }
    }

    @Test func createsHTTPSProxyThenAttachedBrowser() async throws {
        let client = api([(201, #"{"id":"proxy1"}"#), (201, #"{"session_id":"browser1"}"#)])
        let proxy = try await client.createProxy(name: "test-run", config: .init(host: "1.1.1.1", port: 20008, username: "session", password: "test-password"))
        let browser = try await client.createBrowser(name: "test-run", proxyID: proxy.id)
        #expect(browser.session_id == "browser1")
        let requests = StubProtocol.state.captured()
        #expect(requests.map(\.httpMethod) == ["POST", "POST"])
        #expect(requests.map { $0.url!.path } == ["/proxies", "/browsers"])
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer test-only" })
        let proxyBody = try body(requests[0])
        #expect(proxyBody["protocol"] as? String == "https")
        #expect(proxyBody["type"] as? String == "custom")
        #expect(try body(requests[1])["proxy_id"] as? String == "proxy1")
    }

    @Test func navigationIsAllowlistedAndReturnsRealIPResult() async throws {
        let client = api([(200, #"{"success":true,"result":{"ip":"1.2.3.4","host":"api.ipify.org"}}"#)])
        await #expect(throws: (any Error).self) { try await client.navigate(browserID: "browser1", host: "localhost") }
        #expect(StubProtocol.state.captured().isEmpty)
        let result = try await client.navigate(browserID: "browser1", host: "api.ipify.org")
        #expect(result.ip == "1.2.3.4")
        let request = try #require(StubProtocol.state.captured().first)
        let json = try body(request)
        #expect(json["timeout_sec"] as? Int == 30)
        #expect((json["code"] as? String)?.contains("innerText()") == true)
    }

    @Test func failedBrowserDeletionNeverDeletesProxy() async throws {
        let client = api([(503, "unavailable")])
        let record = recovery()
        await #expect(throws: (any Error).self) {
            try await DemoCleanup.run(client, record: record) { _ in }
        }
        #expect(StubProtocol.state.captured().map { $0.url!.path } == ["/browsers/browser1"])
    }

    @Test @MainActor func deletesBrowserBeforeProxyAndJournalsProgress() async throws {
        let client = api([(204, ""), (204, "")])
        var saved: [DemoRecovery] = []
        try await DemoCleanup.run(client, record: recovery()) { saved.append($0) }
        #expect(StubProtocol.state.captured().map { $0.url!.path } == ["/browsers/browser1", "/proxies/proxy1"])
        #expect(saved.count == 1)
        #expect(saved.first?.browserRequested == false)
        #expect(saved.first?.proxyRequested == true)
    }

    @Test func interruptedCreationWithUnknownOutcomePreservesProxy() async throws {
        let client = api([(404, "")])
        var record = recovery(); record.browserID = nil
        let pending = record
        await #expect(throws: (any Error).self) {
            try await DemoCleanup.run(client, record: pending) { _ in }
        }
        #expect(StubProtocol.state.captured().map(\.httpMethod) == ["GET"])
    }

    @Test func cleanupRecoversLostBrowserIDByUniqueName() async throws {
        let client = api([(200, #"{"session_id":"recovered-browser"}"#), (204, ""), (204, "")])
        var record = recovery(); record.browserID = nil
        try await DemoCleanup.run(client, record: record) { _ in }
        #expect(StubProtocol.state.captured().map { $0.url!.path } == ["/browsers/test-run", "/browsers/recovered-browser", "/proxies/proxy1"])
    }

    @Test func alreadyDeletedKnownResourcesAreSafeToRetry() async throws {
        let client = api([(404, ""), (404, "")])
        try await DemoCleanup.run(client, record: recovery()) { _ in }
        #expect(StubProtocol.state.captured().count == 2)
    }

    @Test func errorDoesNotExposeResponseSecrets() async throws {
        let client = api([(401, "secret-from-response")])
        do {
            _ = try await client.createBrowser(name: "test-run", proxyID: "proxy1")
            Issue.record("Expected authentication error")
        } catch {
            #expect(!error.localizedDescription.contains("secret-from-response"))
            #expect(error.localizedDescription.contains("401"))
        }
    }

    @Test @MainActor func cannotStartWithoutEnrollmentAndConsent() {
        let model = DemoModel(preview: true)
        model.apiKey = "test-only"; model.consent = true
        #expect(!model.canStart)
        model.start()
        #expect(!model.running)
    }

    private func recovery() -> DemoRecovery {
        DemoRecovery(name: "test-run", proxyID: "proxy1", browserID: "browser1", proxyRequested: true, browserRequested: true)
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                data.append(contentsOf: bytes.prefix(count))
            }
        }
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
