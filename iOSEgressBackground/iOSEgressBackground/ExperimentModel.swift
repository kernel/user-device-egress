import BackgroundTasks
import Foundation
import Network
import Observation
import SwiftUI
import UIKit

// Expiration can arrive off the main actor. Closing the Go session must not wait
// for UI updates, an in-flight Kernel request, or a protected Keychain write.
final class SessionStopper: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var tunnel: Tunnel?
    var isStopped: Bool { lock.withLock { stopped } }
    func attach(_ tunnel: Tunnel) {
        let close = lock.withLock { if stopped { return true }; self.tunnel = tunnel; return false }
        if close { tunnel.stop() }
    }
    func stop() {
        let tunnel = lock.withLock { stopped = true; return self.tunnel }
        tunnel?.stop()
    }
}

@MainActor @Observable
final class ExperimentModel {
    var mode: ExperimentMode = .continued
    var plan: DiagnosticPlan = .short
    var apiKey = ""
    var consent = false
    var showSetup = false
    private(set) var pairing = false
    private(set) var ready = false
    private(set) var running = false
    private(set) var stopping = false
    private(set) var status = "Loading"
    private(set) var message = "Preparing the experiment."
    var setupMessage = ""
    private(set) var tenant = "Not paired"
    private(set) var report: ExperimentReport?
    private(set) var reportURL: URL?
    private(set) var recovery: DemoRecovery?
    private(set) var network = "Unknown"
    private(set) var protectedDataAvailable = UIApplication.shared.isProtectedDataAvailable
    var enrolled: Bool { settings?.manifest.isEmpty == false }
    var canStart: Bool { ready && enrolled && !apiKey.isEmpty && consent && !running && !pairing && recovery == nil }

    @ObservationIgnored private let keychain = DeviceStore()
    @ObservationIgnored private var files: ExperimentFiles?
    @ObservationIgnored private var settings: DeviceSettings?
    @ObservationIgnored private var tunnel: Tunnel?
    @ObservationIgnored private var stopper = SessionStopper()
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var launchTimeout: Task<Void, Never>?
    @ObservationIgnored private var systemTask: BGContinuedProcessingTask?
    @ObservationIgnored private var waitingForLaunch = false
    @ObservationIgnored private var registered = false
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var stopReason = ""
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var scene: ScenePhase = .active
    @ObservationIgnored private var cleanupTime: UIBackgroundTaskIdentifier = .invalid
    private var taskID: String { Bundle.main.bundleIdentifier! + ".networkDiagnostic" }

    init(preview: Bool = false) {
        if preview { ready = true; status = "Ready"; message = "Run the same diagnostic with and without continued processing."; return }
        UIDevice.current.isBatteryMonitoringEnabled = true
        registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                guard let self, let continued = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false); return
                }
                self.receive(continued)
            }
        }
        monitorNetwork()
        Task { await load() }
    }

    private func load() async {
        do {
            files = try ExperimentFiles()
            settings = try await keychain.load(DeviceSettings.self, account: "settings")
            if settings == nil {
                let key = try await Task.detached { try Tunnel.generateKey() }.value
                settings = DeviceSettings(privateKey: key)
                try await keychain.save(settings!, account: "settings")
            }
            apiKey = settings?.apiKey ?? ""
            updateTenant()
            recovery = try files?.load(DemoRecovery.self, name: "recovery.json")
            report = try files?.loadLatestReport()
            if let report { reportURL = files?.reportURL(report.id) }
            ready = true
            status = recovery == nil ? "Ready" : "Cleanup needed"
            message = recovery == nil ? "Choose a diagnostic. Start without a debugger, then leave the app when prompted." : "A prior run was interrupted. Its tunnel is stopped; clean up cloud resources before restarting."
        } catch { status = "Setup error"; message = error.localizedDescription }
    }

    private func updateTenant() {
        struct Enrollment: Decodable { let tenant: String }
        tenant = (try? JSONDecoder().decode(Enrollment.self, from: Data((settings?.manifest ?? "").utf8)).tenant) ?? "Not paired"
    }

    func pair(_ invitation: PairingInvitation) async {
        guard !running, !pairing, !enrolled, recovery == nil, var saved = settings else { return }
        pairing = true; defer { pairing = false }
        setupMessage = "Pairing this experiment…"
        do {
            saved.manifest = try await PairingClient.redeem(invitation, publicKey: Tunnel.publicKey(saved.privateKey))
            try await keychain.save(saved, account: "settings")
            settings = saved; updateTenant(); setupMessage = "Experiment paired."
        } catch { setupMessage = error.localizedDescription }
    }

    func saveSetup() async {
        guard !running, !pairing, var saved = settings else { return }
        do {
            let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, recovery == nil || key == saved.apiKey else { throw DemoError("Provide a demo key; finish pending cleanup before changing accounts.") }
            saved.apiKey = key
            try await keychain.save(saved, account: "settings")
            settings = saved; apiKey = key
            setupMessage = "Saved in this app's Keychain."
            if enrolled { showSetup = false }
        } catch { setupMessage = error.localizedDescription }
    }

    func start() {
        guard canStart, let settings, UIApplication.shared.applicationState == .active else { return }
        guard settings.apiKey == apiKey else {
            message = "Save the edited API key in Setup before starting."
            showSetup = true
            return
        }
        guard !ExperimentEnvironment.simulator, !ExperimentEnvironment.debuggerAttached else {
            status = "Unattached physical device required"
            message = "Stop the Xcode run, then open this app from the Home Screen. A debugger or simulator invalidates this experiment."
            return
        }
        running = true; stopping = false; stopped = false; stopReason = ""; stopper = SessionStopper(); reportURL = nil
        report = ExperimentReport(mode: mode, plan: plan, osVersion: UIDevice.current.systemVersion,
                                  deviceModel: ExperimentEnvironment.deviceModel, batteryLevel: UIDevice.current.batteryLevel,
                                  batteryState: UIDevice.current.batteryState.rawValue,
                                  lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled, network: network)
        do {
            try record("user_start", mode.rawValue)
            if mode == .continued {
                guard registered else { throw DemoError("Background task registration failed.") }
                waitingForLaunch = true
                status = "Requesting continued processing"
                let request = BGContinuedProcessingTaskRequest(identifier: taskID, title: "Check phone egress", subtitle: "\(plan.count) cloud-browser requests")
                request.strategy = .fail
                request.requiredResources = []
                try BGTaskScheduler.shared.submit(request)
                launchTimeout = Task {
                    try? await Task.sleep(for: .seconds(15))
                    if !Task.isCancelled && waitingForLaunch { reject("Scheduler did not deliver a task within 15 seconds; no tunnel was started.") }
                }
            } else { begin(settings) }
        } catch { reject("Scheduling/start failed: \(error.localizedDescription)") }
    }

    private func receive(_ task: BGContinuedProcessingTask) {
        guard waitingForLaunch, running, !stopped, let settings else { task.setTaskCompleted(success: false); return }
        waitingForLaunch = false; launchTimeout?.cancel()
        systemTask = task
        let cancellation = stopper
        task.expirationHandler = { [weak self] in
            cancellation.stop()
            Task { @MainActor [weak self] in self?.expire() }
        }
        task.progress.totalUnitCount = Int64(report!.plan.count)
        task.progress.completedUnitCount = 0
        begin(settings)
    }

    private func begin(_ settings: DeviceSettings) { work = Task { await run(settings) } }

    private func reject(_ reason: String) {
        waitingForLaunch = false; launchTimeout?.cancel()
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskID)
        stopped = true; running = false; consent = false
        status = "Not started"; message = reason
        report?.outcome = reason
        try? record("request_rejected", reason)
        completeSystemTask(false)
    }

    private func ensureRunning() throws { if stopped || stopper.isStopped { throw CancellationError() } }

    private func run(_ settings: DeviceSettings) async {
        let api = KernelAPI(key: settings.apiKey)
        var completed = false
        do {
            try record("task_started", report!.mode.rawValue)
            status = "Connecting"; message = "Stay in the app until the cloud diagnostic starts."
            let connection = try Tunnel(manifest: settings.manifest, key: settings.privateKey)
            tunnel = connection; stopper.attach(connection)
            try await Task.detached { try connection.start() }.value
            try ensureRunning()
            report?.expectedIP = try connection.snapshot().ip
            try record("route_verified", "Direct and relayed phone IPs match")
            let id = report!.id
            recovery = DemoRecovery(name: "background-egress-" + id, proxyRequested: true)
            try persistRecovery()
            let proxy = try await api.createProxy(name: recovery!.name, config: connection.proxyConfig())
            recovery?.proxyID = proxy.id; try persistRecovery(); try ensureRunning()
            recovery?.browserRequested = true; try persistRecovery()
            let browser = try await api.createBrowser(name: recovery!.name, proxyID: proxy.id, timeoutSeconds: 600)
            recovery?.browserID = browser.session_id; try persistRecovery(); try ensureRunning()
            _ = try await api.diagnostic(browserID: browser.session_id, code: RemoteDiagnostic.startCode(runID: id, plan: report!.plan))
            try ensureRunning()
            try await api.startDiagnosticObserver(browser: browser)
            try ensureRunning()
            var observerReady = false
            for _ in 0..<10 {
                let probe = try await api.diagnostic(browserID: browser.session_id, code: RemoteDiagnostic.pollCode)
                if let beat = probe.observerHeartbeat, probe.now - beat < 5000 { observerReady = true; break }
                try await Task.sleep(for: .seconds(1))
                try ensureRunning()
            }
            guard observerReady else { throw DemoError("Independent cloud observer did not connect; diagnostic cannot be trusted.") }
            try record("observer_connected", "Bounded VM-side CDP observer prevents browser standby independently of phone")
            // Calibrate with a fast poll, not the slower browser navigation/start call.
            let sent = Date()
            var probe = try await api.diagnostic(browserID: browser.session_id, code: RemoteDiagnostic.pollCode)
            let received = Date()
            report?.clockOffsetMilliseconds = probe.now - (sent.timeIntervalSince1970 + received.timeIntervalSince1970) * 500
            report?.clockUncertaintyMilliseconds = received.timeIntervalSince(sent) * 500
            try record("cloud_started", "Independent remote request loop started; safe to leave app")
            status = "Running — you can leave the app"
            message = "Switch apps or lock the phone. Return after the selected diagnostic duration; results come from cloud-side timestamps."
            let deadline = Date().addingTimeInterval(480)
            while !stopped {
                try report?.accept(probe)
                if !probe.done && probe.now - (probe.observerHeartbeat ?? 0) > 10000 {
                    throw DemoError("Cloud observer lost; results are inconclusive, not evidence of iOS suspension.")
                }
                systemTask?.progress.completedUnitCount = Int64(probe.samples.count)
                systemTask?.updateTitle("Check phone egress", subtitle: "\(probe.samples.count) of \(report!.plan.count) requests measured")
                try saveReport()
                if probe.done {
                    completed = probe.samples.count == report!.plan.count && report!.matchedCount == report!.plan.count
                    report?.outcome = completed ? "Diagnostic complete" : "Diagnostic completed with missing or failed requests"
                    break
                }
                if Date() >= deadline { throw DemoError("Eight-minute experiment deadline reached.") }
                if try connection.snapshot().state == "failed" { throw DemoError("Phone tunnel failed; inspect cloud samples and network conditions.") }
                try await Task.sleep(for: .seconds(3))
                try ensureRunning()
                probe = try await api.diagnostic(browserID: browser.session_id, code: RemoteDiagnostic.pollCode)
            }
        } catch is CancellationError {
            report?.outcome = stopReason.isEmpty ? "Stopped" : stopReason
        } catch {
            report?.outcome = stopped ? stopReason : error.localizedDescription
        }
        // No more diagnostic traffic after this point. This small UIKit allowance
        // is only for deletion/journaling, never for running the experiment.
        stopper.stop(); stopped = true; stopping = true
        status = "Cleaning up"
        beginCleanupTime()
        do {
            try record("tunnel_stopped", report?.outcome ?? "Stopped")
            try await cleanResources(api)
            report?.cleanupComplete = true
            try record("cleanup_complete", "Browser deleted before proxy")
            status = "Finished"; message = report?.outcome ?? "Stopped"
        } catch {
            status = "Cleanup needed"; message = "Phone tunnel is stopped. \(error.localizedDescription)"
            try? record("cleanup_pending", "Retry cleanup when the app is open")
        }
        completeSystemTask(completed && recovery == nil)
        endCleanupTime()
        tunnel = nil; work = nil; running = false; stopping = false; consent = false
    }

    private func persistRecovery() throws { if let recovery { try files?.save(recovery, name: "recovery.json") } }

    private func cleanResources(_ api: KernelAPI) async throws {
        guard let recovery else { return }
        try await DemoCleanup.run(api, record: recovery) { updated in
            self.recovery = updated; try self.persistRecovery()
        }
        try files?.clearRecovery(); self.recovery = nil
    }

    func retryCleanup() {
        guard !running, let settings else { return }
        running = true; stopping = true
        Task {
            defer { running = false; stopping = false }
            do {
                try await cleanResources(KernelAPI(key: settings.apiKey))
                report?.cleanupComplete = true; try saveReport()
                status = "Finished"; message = "Cloud resources deleted. Ready for another run."
            } catch { status = "Cleanup needed"; message = error.localizedDescription }
        }
    }

    func confirmManualCleanup() {
        guard !running else { return }
        do { try files?.clearRecovery(); recovery = nil; status = "Ready" }
        catch { message = error.localizedDescription }
    }

    func stop(reason: String = "Stopped by user") {
        guard running, !stopping else { return }
        stopper.stop(); stopped = true; stopping = true; stopReason = reason; report?.outcome = reason
        status = "Stopping"
        try? record("stop_requested", reason)
        if waitingForLaunch { reject(reason); stopping = false }
        // In-flight creates are not cancelled: retain their IDs for ordered cleanup.
    }

    private func expire() {
        try? record("system_expiration_or_cancellation", "iOS does not distinguish these in this callback")
        stop(reason: "System expired or cancelled continued processing")
        // Do not wait on cloud deletion to release the system task.
        completeSystemTask(false)
    }

    private func completeSystemTask(_ success: Bool) {
        guard let task = systemTask else { return }
        systemTask = nil; task.expirationHandler = nil
        task.setTaskCompleted(success: success)
    }

    func sceneChanged(_ phase: ScenePhase) {
        let old = scene; scene = phase
        guard running else { return }
        if phase == .background { report?.enterBackground() }
        else if old == .background { report?.enterForeground() }
        do { try record("scene", String(describing: phase)) }
        catch { stop(reason: "Could not persist lifecycle observations") }
    }

    func protectionChanged(available: Bool) {
        protectedDataAvailable = available
        guard running else { return }
        do { try record("protected_data", protectedDataAvailable ? "available" : "unavailable") }
        catch { stop(reason: "Could not persist lock observation") }
    }

    private func saveReport() throws {
        guard let report else { return }
        try files?.save(report, name: "latest.json")
        try files?.save(report, name: "report-\(report.id).json")
        reportURL = files?.reportURL(report.id)
    }

    private func record(_ kind: String, _ detail: String) throws {
        report?.events.append(.init(at: Date(), kind: kind, detail: detail))
        try saveReport()
    }

    private func monitorNetwork() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let kind = path.usesInterfaceType(.wifi) ? "Wi-Fi" : path.usesInterfaceType(.cellular) ? "Cellular" : "Other"
            let value = "\(kind); \(path.status); expensive=\(path.isExpensive); IPv4=\(path.supportsIPv4); IPv6=\(path.supportsIPv6)"
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.running && self.network != "Unknown" && self.network != value { self.stop(reason: "Network path changed") }
                self.network = value
            }
        }
        pathMonitor = monitor; monitor.start(queue: DispatchQueue(label: "background-lab.path"))
    }

    private func beginCleanupTime() {
        guard UIApplication.shared.applicationState != .active, cleanupTime == .invalid else { return }
        cleanupTime = UIApplication.shared.beginBackgroundTask(withName: "Delete diagnostic resources") { [weak self] in
            Task { @MainActor [weak self] in self?.endCleanupTime() }
        }
    }
    private func endCleanupTime() {
        guard cleanupTime != .invalid else { return }
        UIApplication.shared.endBackgroundTask(cleanupTime); cleanupTime = .invalid
    }
}
