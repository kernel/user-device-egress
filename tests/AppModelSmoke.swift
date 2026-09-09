// Standalone real-model smoke test when Xcode's test service cannot launch.
// Compile with DeviceConnection.swift and SharingModel.swift; place the two built helpers beside it.
import AppKit
import Foundation

enum SmokeError: Error { case failed(String) }

@main
struct AppModelSmoke {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 3 else {
            throw SmokeError.failed("Usage: AppModelSmoke MANIFEST PRIVATE_KEY")
        }
        _ = NSApplication.shared
        let manifest = try JSONDecoder().decode(RelayManifest.self,
            from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let key = try String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)
        let model = SharingModel(preview: true, initialDevice: DeviceConnection(manifest: manifest, private_key: key))
        model.consent = true
        model.start()
        let deadline = Date().addingTimeInterval(60)
        while (model.state == .connecting || model.state == .verifying) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard model.state == .sharing, let directory = model.sessionDirectory else {
            let message = model.message
            model.stop()
            while model.state.running { try await Task.sleep(for: .milliseconds(50)) }
            throw SmokeError.failed(message)
        }
        print("PASS Swift model: sharing with verified egress \(model.exitIP ?? "missing")")
        // Let at least one live stats event arrive.
        try await Task.sleep(for: .seconds(2))
        guard model.uploaded > 0, model.downloaded > 0 else {
            model.stop()
            throw SmokeError.failed("missing traffic counters")
        }
        model.stop()
        let stopDeadline = Date().addingTimeInterval(6)
        while model.state.running && Date() < stopDeadline { try await Task.sleep(for: .milliseconds(50)) }
        guard model.state == .stopped, !model.consent, !FileManager.default.fileExists(atPath: directory) else {
            throw SmokeError.failed("stop did not clear state, consent, and session files")
        }
        print("PASS Swift model: counters updated; Stop closed the session and removed its credentials")
    }
}
