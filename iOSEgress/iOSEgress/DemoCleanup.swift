import Foundation

@MainActor
enum DemoCleanup {
    static func run(_ api: KernelAPI, record original: DemoRecovery,
                    save: (DemoRecovery) async throws -> Void) async throws {
        var record = original
        if record.browserRequested {
            if record.browserID == nil {
                guard let browser = try await api.findBrowser(name: record.name) else {
                    throw DemoError("Browser creation was interrupted. Check \(record.name) in Kernel; its outcome is not yet known.")
                }
                record.browserID = browser.session_id
                try await save(record)
            }
            if let id = record.browserID { try await api.deleteBrowser(id) }
            record.browserRequested = false; record.browserID = nil
            try await save(record)
        }
        // An unknown creation outcome or failed deletion must leave the proxy attached.
        if record.proxyRequested {
            if record.proxyID == nil {
                guard let proxy = try await api.findProxy(name: record.name) else {
                    throw DemoError("Proxy creation was interrupted. Check \(record.name) in Kernel; its outcome is not yet known.")
                }
                record.proxyID = proxy.id
                try await save(record)
            }
            if let id = record.proxyID { try await api.deleteProxy(id) }
        }
    }
}
