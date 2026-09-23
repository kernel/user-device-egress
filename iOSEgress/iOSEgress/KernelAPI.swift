import Foundation

struct ProxyConfiguration: Codable, Sendable {
    let host: String
    let port: Int
    let username: String
    let password: String
}

struct KernelProxy: Decodable, Sendable {
    let id: String
    let name: String?
}

struct KernelBrowser: Decodable, Sendable {
    let session_id: String
    let name: String?
    let cdp_ws_url: String?
}

struct IPResult: Decodable, Sendable {
    let ip: String
    let host: String
}

actor KernelAPI {
    private let key: String
    private let session: URLSession

    init(key: String, session: URLSession? = nil) {
        self.key = key
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 40
        configuration.timeoutIntervalForResource = 60
        configuration.urlCache = nil
        self.session = session ?? URLSession(configuration: configuration)
    }

    func request(_ method: String, _ path: String, body: Data? = nil, allowMissing: Bool = false) async throws -> Data {
        guard let url = URL(string: "https://api.onkernel.com" + path) else { throw DemoError("Invalid API path.") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DemoError("Kernel returned an invalid response.") }
        if allowMissing && http.statusCode == 404 { return Data() }
        guard (200..<300).contains(http.statusCode) else {
            // Do not display response bodies: they may contain request credentials.
            let hint = http.statusCode == 401 ? "Check your Kernel API key." : "Check access, quota, and connectivity."
            throw DemoError("Kernel \(method) \(path.split(separator: "?").first ?? "") returned \(http.statusCode). \(hint)")
        }
        return data
    }

    func createProxy(name: String, config: ProxyConfiguration) async throws -> KernelProxy {
        struct Body: Encodable { let type = "custom"; let protocolName = "https"; let name: String; let config: ProxyConfiguration
            enum CodingKeys: String, CodingKey { case type, protocolName = "protocol", name, config }
        }
        return try JSONDecoder().decode(KernelProxy.self, from: await request("POST", "/proxies", body: JSONEncoder().encode(Body(name: name, config: config))))
    }

    func createBrowser(name: String, proxyID: String, timeoutSeconds: Int = 120) async throws -> KernelBrowser {
        guard (10...600).contains(timeoutSeconds) else { throw DemoError("Invalid browser timeout.") }
        struct Body: Encodable {
            let name: String; let proxy_id: String
            let headless = false; let timeout_seconds: Int
            let viewport = ["width": 1024, "height": 768]
        }
        return try JSONDecoder().decode(KernelBrowser.self, from: await request("POST", "/browsers", body: JSONEncoder().encode(Body(name: name, proxy_id: proxyID, timeout_seconds: timeoutSeconds))))
    }

    func navigate(browserID: String, host: String) async throws -> IPResult {
        guard ["checkip.amazonaws.com", "api.ipify.org"].contains(host) else { throw DemoError("Only demo IP-check sites are allowed.") }
        // Only typography changes. The displayed IP is the website's original text.
        let code = """
        const response = await page.goto('https://\(host)/?egress=' + Date.now(),
          {waitUntil: 'domcontentloaded', timeout: 25000});
        if (!response.ok()) throw new Error('IP service failed');
        const ip = (await page.locator('body').innerText()).trim();
        await page.addStyleTag({content: 'html{background:#101b21;color:#bcf4dc}body{min-height:70vh;display:grid;place-items:center;margin:0;font:72px ui-monospace,monospace}pre{font:inherit}'});
        return {ip, host: '\(host)'};
        """
        struct Body: Encodable { let code: String; let timeout_sec = 30 }
        struct Response: Decodable { let success: Bool; let result: IPResult? }
        let result = try JSONDecoder().decode(Response.self, from: await request("POST", "/browsers/\(browserID)/playwright/execute", body: JSONEncoder().encode(Body(code: code))))
        guard result.success, let value = result.result else { throw DemoError("The cloud browser could not load the IP-check page.") }
        return value
    }

    func screenshot(browserID: String) async throws -> Data {
        let data = try await request("POST", "/browsers/\(browserID)/computer/screenshot")
        guard data.count < 12_000_000 else { throw DemoError("Screenshot was unexpectedly large.") }
        return data
    }

    func deleteBrowser(_ id: String) async throws { _ = try await request("DELETE", "/browsers/\(id)", allowMissing: true) }
    func deleteProxy(_ id: String) async throws { _ = try await request("DELETE", "/proxies/\(id)", allowMissing: true) }

    func findBrowser(name: String) async throws -> KernelBrowser? {
        let data = try await request("GET", "/browsers/\(name)", allowMissing: true)
        return data.isEmpty ? nil : try JSONDecoder().decode(KernelBrowser.self, from: data)
    }

    func findProxy(name: String) async throws -> KernelProxy? {
        let data = try await request("GET", "/proxies?name=\(name)&limit=100")
        let matches = try JSONDecoder().decode([KernelProxy].self, from: data).filter { $0.name == name }
        guard matches.count <= 1 else { throw DemoError("Multiple matching proxies. Inspect the recovery name in Kernel before continuing.") }
        return matches.first
    }
}
