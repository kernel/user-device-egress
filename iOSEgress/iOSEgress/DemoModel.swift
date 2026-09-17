import Foundation
import Network
import Observation
import UIKit

@MainActor @Observable
final class DemoModel {
    private(set) var ready = false
    private(set) var running = false
    private(set) var stopping = false
    private(set) var stage = 0
    private(set) var status = "Getting ready"
    private(set) var message = "Loading this device's enrollment."
    private(set) var pairing = false
    private(set) var tenant = "Not enrolled"
    private(set) var phoneIP = "—"
    private(set) var browserIP = "—"
    private(set) var matched = false
    private(set) var checks = 0
    private(set) var uploaded: Int64 = 0
    private(set) var downloaded: Int64 = 0
    private(set) var screenshot: UIImage?
    private(set) var screenshotDate: Date?
    private(set) var currentHost = "Waiting for a cloud browser"
    private(set) var recovery: DemoRecovery?
    var apiKey = ""
    var consent = false
    var showSetup = false
    var setupMessage = ""

    @ObservationIgnored private let store = DeviceStore()
    @ObservationIgnored private var settings: DeviceSettings?
    @ObservationIgnored private var tunnel: Tunnel?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var frames: Task<Void, Never>?
    @ObservationIgnored private var metrics: Task<Void, Never>?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var lastPath: String?
    @ObservationIgnored private var stopRequested = false
    @ObservationIgnored private var stopReason = ""
    @ObservationIgnored private var backgroundTime: UIBackgroundTaskIdentifier = .invalid

    var enrolled: Bool { settings?.manifest.isEmpty == false }
    var canStart: Bool { ready && enrolled && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && consent && !running && recovery == nil }

    init(preview: Bool = false) {
        if preview { ready = true; status = "Ready to connect"; message = "Set up your phone to begin."; return }
        Task { await load() }
    }

    private func load() async {
        do {
            if let saved = try await store.load(DeviceSettings.self, account: "settings") { settings = saved }
            else {
                let key = try await Task.detached { try Tunnel.generateKey() }.value
                let new = DeviceSettings(privateKey: key)
                try await store.save(new, account: "settings")
                settings = new
            }
            guard let settings else { return }
            apiKey = settings.apiKey
            updateTenant(settings.manifest)
            recovery = try await store.load(DemoRecovery.self, account: "recovery")
            ready = true
            status = recovery == nil ? "Ready to connect" : "Cleanup needed"
            message = recovery == nil ? "Your phone supplies the internet. Kernel supplies the browser." : "A previous run left cloud resources to clean up. The phone tunnel is stopped."
        } catch { status = "Setup error"; message = error.localizedDescription }
    }

    private func updateTenant(_ manifest: String) {
        struct Enrollment: Decodable { let tenant: String }
        tenant = (try? JSONDecoder().decode(Enrollment.self, from: Data(manifest.utf8)).tenant) ?? "Not enrolled"
    }

    func pair(_ invitation: PairingInvitation) async {
        guard !running, !pairing, recovery == nil, !enrolled, var saved = settings else { return }
        pairing = true
        setupMessage = "Connecting this iPhone…"
        defer { pairing = false }
        do {
            saved.manifest = try await PairingClient.redeem(invitation, publicKey: Tunnel.publicKey(saved.privateKey))
            try await store.save(saved, account: "settings")
            settings = saved
            updateTenant(saved.manifest)
            setupMessage = "This iPhone is connected."
            if !saved.apiKey.isEmpty { showSetup = false }
        } catch {
            // URLSession errors can include a URL, but our request URL never contains the invitation token.
            setupMessage = "\(error.localizedDescription) You can scan the same code again before it expires."
        }
    }

    func saveSettings() async {
        guard !running, !pairing, var saved = settings else { return }
        do {
            let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { throw DemoError("Enter a Kernel API key for this demo.") }
            // A pending cleanup must use the account that created those resources.
            guard recovery == nil || key == saved.apiKey else { throw DemoError("Clean up the previous run before changing API keys.") }
            saved.apiKey = key
            try await store.save(saved, account: "settings")
            settings = saved; apiKey = key
            setupMessage = "Saved in this iPhone's Keychain."
            if enrolled { showSetup = false }
        } catch { setupMessage = error.localizedDescription }
    }

    func start() {
        guard canStart, let settings else { return }
        // Persist the API key through Setup first so interrupted runs can recover.
        guard settings.apiKey == apiKey.trimmingCharacters(in: .whitespacesAndNewlines), !settings.apiKey.isEmpty else {
            showSetup = true; setupMessage = "Save your API key before starting."; return
        }
        running = true; stopping = false; stopRequested = false; stopReason = ""
        stage = 0; checks = 0; matched = false; phoneIP = "—"; browserIP = "—"
        screenshot = nil; screenshotDate = nil; uploaded = 0; downloaded = 0
        currentHost = "Waiting for a cloud browser"
        UIApplication.shared.isIdleTimerDisabled = true
        work = Task { await run(settings) }
    }

    private func ensureRunning() throws {
        if stopRequested { throw CancellationError() }
    }

    private func persistRecovery() async throws {
        if let recovery { try await store.save(recovery, account: "recovery") }
    }

    private func run(_ settings: DeviceSettings) async {
        let api = KernelAPI(key: settings.apiKey)
        do {
            status = "Connecting your phone"
            message = "Opening an encrypted tunnel and verifying the relay route."
            let connection = try Tunnel(manifest: settings.manifest, key: settings.privateKey)
            tunnel = connection
            startMetrics(connection)
            startPathMonitor()
            try await Task.detached { try connection.start() }.value
            try ensureRunning()
            phoneIP = try connection.snapshot().ip
            stage = 1; status = "Creating Kernel proxy"
            let record = DemoRecovery()
            recovery = record
            recovery?.proxyRequested = true
            try await persistRecovery()
            let proxy = try await api.createProxy(name: record.name, config: connection.proxyConfig())
            recovery?.proxyID = proxy.id
            try await persistRecovery()
            try ensureRunning()
            stage = 2; status = "Launching cloud browser"
            recovery?.browserRequested = true
            try await persistRecovery()
            let browser = try await api.createBrowser(name: record.name, proxyID: proxy.id)
            recovery?.browserID = browser.session_id
            try await persistRecovery()
            try ensureRunning()
            stage = 3; status = "Checking browser egress"
            frames = Task { await captureFrames(api, browserID: browser.session_id) }
            let end = Date().addingTimeInterval(180)
            var index = 0
            while !stopRequested && Date() < end {
                let host = ["checkip.amazonaws.com", "api.ipify.org"][index % 2]
                matched = false
                currentHost = host
                let direct = try await Task.detached { try connection.directIP(host: host) }.value
                try ensureRunning()
                let observed = try await api.navigate(browserID: browser.session_id, host: host)
                try ensureRunning()
                phoneIP = direct; browserIP = observed.ip
                guard observed.host == host, observed.ip == direct else { throw DemoError("IP mismatch. The demo stopped instead of claiming a verified route.") }
                matched = true; checks += 1; stage = 4; status = "Same IP. Different device."
                message = "A real Kernel browser is using this phone's connection. Screenshots refresh every 2 seconds."
                index += 1
                try await Task.sleep(for: .seconds(6))
            }
            if !stopRequested { stopReason = "Three-minute demo complete. Cloud resources deleted." }
        } catch is CancellationError {
            if stopReason.isEmpty { stopReason = "Demo stopped." }
        } catch {
            if stopReason.isEmpty { stopReason = error.localizedDescription }
        }
        tunnel?.stop()
        frames?.cancel(); metrics?.cancel(); pathMonitor?.cancel()
        matched = false; stopping = true; status = "Cleaning up"
        do {
            try await cleanResources(api)
            status = "Stopped"
            message = stopReason.isEmpty ? "Demo stopped. Cloud resources deleted." : stopReason
        } catch {
            status = "Cleanup needed"
            message = "Phone sharing is stopped. \(error.localizedDescription) Retry cleanup before starting another demo."
        }
        tunnel = nil; work = nil; running = false; stopping = false; consent = false
        UIApplication.shared.isIdleTimerDisabled = false
        endBackgroundTime()
    }

    private func captureFrames(_ api: KernelAPI, browserID: String) async {
        while !Task.isCancelled && !stopRequested {
            do {
                let data = try await api.screenshot(browserID: browserID)
                guard !Task.isCancelled, !stopRequested else { return }
                if let image = UIImage(data: data) { screenshot = image; screenshotDate = Date() }
                try await Task.sleep(for: .seconds(2))
            } catch {
                if Task.isCancelled { return }
                // Keep the timestamp visible so a stale frame never looks like live video.
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func startMetrics(_ connection: Tunnel) {
        metrics = Task {
            while !Task.isCancelled && !stopRequested {
                if let snapshot = try? connection.snapshot() {
                    uploaded = snapshot.stats.uploaded; downloaded = snapshot.stats.downloaded
                    if snapshot.state == "failed" { stop(reason: snapshot.message); return }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        lastPath = nil
        monitor.pathUpdateHandler = { [weak self] path in
            let current = "\(path.status)-\(path.availableInterfaces.map(\.name).sorted())-\(path.isExpensive)-\(path.supportsIPv4)-\(path.supportsIPv6)"
            let online = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self, self.running, !self.stopping else { return }
                let changed = self.lastPath != nil && self.lastPath != current
                self.lastPath = current
                if changed || !online {
                    self.stop(reason: "Network changed. Start a new demo to verify its route.")
                }
            }
        }
        pathMonitor = monitor
        monitor.start(queue: DispatchQueue(label: "iphone-egress.path"))
    }

    func stop(reason: String = "Demo stopped. Cloud resources deleted.") {
        guard running, !stopping else { return }
        stopRequested = true; stopping = true; stopReason = reason
        status = "Stopping"; matched = false
        tunnel?.stop(); frames?.cancel(); metrics?.cancel(); pathMonitor?.cancel()
        // Do not cancel an in-flight create: capture its ID, journal it, then delete it.
    }

    func enteredBackground() {
        guard running else { return }
        if backgroundTime == .invalid {
            backgroundTime = UIApplication.shared.beginBackgroundTask(withName: "Finish demo cleanup") { [weak self] in
                Task { @MainActor [weak self] in self?.endBackgroundTime() }
            }
        }
        stop(reason: "Sharing stopped because the app left the foreground.")
    }

    private func endBackgroundTime() {
        if backgroundTime != .invalid { UIApplication.shared.endBackgroundTask(backgroundTime); backgroundTime = .invalid }
    }

    private func cleanResources(_ api: KernelAPI) async throws {
        guard let record = recovery else { return }
        try await DemoCleanup.run(api, record: record) { updated in
            self.recovery = updated
            try await self.persistRecovery()
        }
        try await store.remove(account: "recovery")
        recovery = nil
    }

    func retryCleanup() {
        guard !running, let settings, !settings.apiKey.isEmpty else { return }
        running = true; stopping = true
        Task {
            defer { running = false; stopping = false }
            do {
                try await cleanResources(KernelAPI(key: settings.apiKey))
                status = "Stopped"; message = "Cloud browser and proxy deleted. Ready for a new demo."
            } catch { status = "Cleanup needed"; message = error.localizedDescription }
        }
    }

    func confirmManualCleanup() async {
        guard !running else { return }
        do {
            try await store.remove(account: "recovery"); recovery = nil
            status = "Stopped"; message = "Recovery record cleared after your manual cleanup confirmation."
        } catch { message = error.localizedDescription }
    }
}
