import Foundation
import Testing
@testable import iOSEgressBackground

private final class DiagnosticTransport: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var response = Data()
    private static var captured: URLRequest?
    static func prepare(_ json: String) { lock.withLock { response = Data(json.utf8); captured = nil } }
    static var lastRequest: URLRequest? { lock.withLock { captured } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let data = Self.lock.withLock { Self.captured = request; return Self.response }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized)
struct KernelDiagnosticTests {
    private func api(reply: String = "{}") -> KernelAPI {
        DiagnosticTransport.prepare(reply)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DiagnosticTransport.self]
        return KernelAPI(key: "account-secret-test-only", session: URLSession(configuration: configuration))
    }

    private func body() throws -> [String: Any] {
        let request = try #require(DiagnosticTransport.lastRequest)
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func observerIsBoundedAndReceivesOnlyItsOwnCDPCredential() async throws {
        let client = api()
        try await client.startDiagnosticObserver(browser: .init(session_id: "b", name: nil, cdp_ws_url: "wss://example.com/session-only"))
        #expect(DiagnosticTransport.lastRequest?.url?.path == "/browsers/b/process/spawn")
        let json = try body()
        #expect(json["command"] as? String == "node")
        #expect(json["timeout_sec"] as? Int == 460)
        #expect(json["env"] as? [String: String] == ["EGRESS_DIAGNOSTIC_CDP": "wss://example.com/session-only"])
        #expect(!(String(describing: json).contains("account-secret-test-only")))
        #expect(RemoteDiagnostic.observerCode.contains("450000"))
        #expect(RemoteDiagnostic.observerCode.contains("Browser.getVersion"))
        #expect(RemoteDiagnostic.observerCode.contains("renameSync"))
    }

    @Test func missingOrInsecureObserverEndpointFailsBeforeAnyRequest() async throws {
        let client = api()
        for endpoint: String? in [nil, "ws://example.com/session"] {
            await #expect(throws: (any Error).self) {
                try await client.startDiagnosticObserver(browser: .init(session_id: "b", name: nil, cdp_ws_url: endpoint))
            }
        }
        #expect(DiagnosticTransport.lastRequest == nil)
    }

    @Test func foregroundDefaultAndDiagnosticTimeoutRemainDistinct() async throws {
        for (timeout, expected) in [(nil as Int?, 120), (600, 600)] {
            let client = api(reply: #"{"session_id":"b"}"#)
            if let timeout { _ = try await client.createBrowser(name: "test", proxyID: "p", timeoutSeconds: timeout) }
            else { _ = try await client.createBrowser(name: "test", proxyID: "p") }
            let json = try body()
            #expect(json["timeout_seconds"] as? Int == expected)
            #expect(json["proxy_id"] as? String == "p")
        }
        let client = api()
        await #expect(throws: (any Error).self) { try await client.createBrowser(name: "test", proxyID: "p", timeoutSeconds: 601) }
        #expect(DiagnosticTransport.lastRequest == nil)
    }

    @Test func diagnosticDecodesObserverHeartbeatWithoutChangingSamples() async throws {
        let client = api(reply: #"{"success":true,"result":{"runID":"test","now":10000,"done":false,"samples":[],"observerHeartbeat":9000}}"#)
        let probe = try await client.diagnostic(browserID: "b", code: RemoteDiagnostic.pollCode)
        #expect(probe.observerHeartbeat == 9000)
        #expect(probe.samples.isEmpty)
        #expect(try body()["timeout_sec"] as? Int == 30)
    }
}
