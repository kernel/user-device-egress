import Foundation
import Testing
@testable import MacEgress

struct MacEgressTests {

    private var manifest: RelayManifest {
        RelayManifest(tenant: "device", ip: "192.0.2.20", port: 20000, ssh_port: 40000,
            tunnel_port: 30000, ssh_user: "relay_device",
            host_key: "ssh-ed25519 " + Data(repeating: 0, count: 51).base64EncodedString())
    }
    @Test func validManifestRoundTrips() throws {
        try manifest.validate()
        #expect(try JSONDecoder().decode(RelayManifest.self, from: JSONEncoder().encode(manifest)) == manifest)
    }
    @Test func otherTenantIdentityIsRejected() {
        let bad = RelayManifest(tenant: "device", ip: manifest.ip, port: 20000, ssh_port: 40000,
            tunnel_port: 30000, ssh_user: "relay_someoneelse", host_key: manifest.host_key)
        #expect(throws: DeviceError.self) { try bad.validate() }
    }
    @Test func sshHostKeyCommentsAreAllowed() throws {
        let commented = RelayManifest(tenant: "device", ip: manifest.ip, port: 20000, ssh_port: 40000,
            tunnel_port: 30000, ssh_user: "relay_device", host_key: manifest.host_key + " operator@relay")
        try commented.validate()
    }
    @Test func hostKeyInjectionIsRejected() {
        let bad = RelayManifest(tenant: "device", ip: manifest.ip, port: 20000, ssh_port: 40000,
            tunnel_port: 30000, ssh_user: "relay_device", host_key: manifest.host_key + "\nother-host key")
        #expect(throws: DeviceError.self) { try bad.validate() }
    }
    @Test func publicKeyCannotBeImportedAsPrivateKey() {
        let device = DeviceConnection(manifest: manifest, private_key: manifest.host_key)
        #expect(throws: DeviceError.self) { try device.validate() }
    }
    @Test @MainActor func noConsentNeverStartsSharing() {
        let model = SharingModel(preview: true)
        model.start()
        #expect(model.state == .stopped)
        #expect(model.sessionDirectory == nil)
    }
    @Test @MainActor func importRequiresBothFiles() async {
        let model = SharingModel(preview: true)
        #expect(model.needsImport)
        #expect(!model.canSaveDevice)
        await model.saveDevice()
        #expect(model.device == nil)
        #expect(!model.busy)
    }
    @Test @MainActor func cancellingReplacementKeepsSavedDevice() {
        let saved = DeviceConnection(manifest: manifest, private_key: "unused test placeholder")
        let model = SharingModel(preview: true, initialDevice: saved)
        #expect(!model.needsImport)
        model.consent = true
        model.beginImport()
        #expect(model.needsImport)
        #expect(!model.consent)
        model.cancelImport()
        #expect(!model.needsImport)
        #expect(model.device?.manifest == manifest)
        #expect(!model.canSaveDevice)
    }
    @Test @MainActor func staleHelperEventsAreIgnored() {
        let model = SharingModel(preview: true)
        model.receive(HelperEvent(event: "sharing", ip: "192.0.2.1"), id: UUID())
        #expect(model.state == .stopped)
        #expect(model.exitIP == nil)
    }
    @Test func transitionalStatesCountAsRunning() {
        #expect(SharingState.connecting.running)
        #expect(SharingState.verifying.running)
        #expect(SharingState.stopping.running)
        #expect(!SharingState.disconnected.running)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_EGRESS_LIVE_MANIFEST"] != nil))
    @MainActor func liveStartStop() async throws {
        let environment = ProcessInfo.processInfo.environment
        let manifestURL = URL(fileURLWithPath: try #require(environment["MAC_EGRESS_LIVE_MANIFEST"]))
        let keyURL = URL(fileURLWithPath: try #require(environment["MAC_EGRESS_LIVE_KEY"]))
        let connection = DeviceConnection(
            manifest: try JSONDecoder().decode(RelayManifest.self, from: Data(contentsOf: manifestURL)),
            private_key: try String(contentsOf: keyURL, encoding: .utf8))
        let model = SharingModel(preview: true, initialDevice: connection)
        model.consent = true
        model.start()
        defer { model.stop() }
        let deadline = Date().addingTimeInterval(60)
        while (model.state == .connecting || model.state == .verifying) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        try #require(model.state == .sharing, "\(model.message)")
        let directory = try #require(model.sessionDirectory)
        #expect(model.exitIP != nil)
        model.stop()
        let stopDeadline = Date().addingTimeInterval(6)
        while model.state.running && Date() < stopDeadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(model.state == .stopped)
        #expect(!model.consent)
        #expect(!FileManager.default.fileExists(atPath: directory))
    }
}
