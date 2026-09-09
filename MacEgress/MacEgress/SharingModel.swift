import AppKit
import Foundation
import Network
import Observation
import UniformTypeIdentifiers

enum SharingState: String {
    case stopped = "Stopped", connecting = "Connecting", verifying = "Verifying"
    case sharing = "Sharing", stopping = "Stopping", disconnected = "Disconnected"
    var running: Bool { self == .connecting || self == .verifying || self == .sharing || self == .stopping }
}

struct HelperEvent: Decodable, Sendable {
    let event: String
    var message: String?
    var ip: String?
    var directory: String?
    var uploaded: Int64?
    var downloaded: Int64?
    var active: Int?
}

@MainActor @Observable
final class SharingModel {
    private(set) var state: SharingState = .stopped
    private(set) var device: DeviceConnection?
    private(set) var exitIP: String?
    private(set) var uploaded: Int64 = 0
    private(set) var downloaded: Int64 = 0
    private(set) var activeConnections = 0
    private(set) var sessionDirectory: String?
    private(set) var busy = false
    private(set) var manifestURL: URL?
    private(set) var privateKeyURL: URL?
    private(set) var replacingDevice = false
    var needsImport: Bool { device == nil || replacingDevice }
    var canSaveDevice: Bool { manifestURL != nil && privateKeyURL != nil && !busy && !state.running }
    var consent = false
    var message = "Import a device connection to get started."
    @ObservationIgnored private let store = DeviceStore()
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var control: Pipe?
    @ObservationIgnored private var reader: Task<Void, Never>?
    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private var lastPath: String?
    @ObservationIgnored private var sleepObserver: NSObjectProtocol?
    @ObservationIgnored private var stopMessage: String?
    @ObservationIgnored private var sessionID: UUID?
    @ObservationIgnored private var ownedSessionRoot: URL?
    @ObservationIgnored private var importDirectory: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var candidates = [home.appendingPathComponent(".local", isDirectory: true), home]
        #if DEBUG
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        candidates.insert(repository.appendingPathComponent(".local", isDirectory: true), at: 0)
        #endif
        return candidates.first {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        } ?? home
    }()

    init(preview: Bool = false, initialDevice: DeviceConnection? = nil) {
        device = initialDevice
        guard !preview else { return }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.stop(reason: "Mac went to sleep. Start again when you are ready.") }
        }
        Task { await load() }
    }

    private func load() async {
        busy = true
        defer { busy = false }
        do {
            device = try await store.load()
            if device != nil { message = "Ready when you are. Sharing never starts automatically." }
        } catch { message = error.localizedDescription }
    }

    func beginImport() {
        guard !state.running, !busy else { return }
        replacingDevice = true
        consent = false
    }

    func cancelImport() {
        guard !busy else { return }
        replacingDevice = false
        manifestURL = nil
        privateKeyURL = nil
    }

    func chooseManifest() {
        if let url = chooseFile(title: "Choose manifest", types: [.json]) { manifestURL = url }
    }

    func choosePrivateKey() {
        if let url = chooseFile(title: "Choose private key") { privateKeyURL = url }
    }

    private func chooseFile(title: String, types: [UTType]? = nil) -> URL? {
        guard !state.running, !busy else { return nil }
        busy = true
        defer { busy = false }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = "Choose"
        if let types { panel.allowedContentTypes = types }
        panel.showsHiddenFiles = true
        panel.directoryURL = importDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        importDirectory = url.deletingLastPathComponent()
        return url
    }

    func saveDevice() async {
        guard canSaveDevice, let manifestURL, let keyURL = privateKeyURL else { return }
        busy = true
        defer { busy = false }
        do {
            let manifestData = try Data(contentsOf: manifestURL)
            let keyData = try Data(contentsOf: keyURL)
            guard manifestData.count < 16384, keyData.count < 16384,
                  let key = String(data: keyData, encoding: .utf8) else { throw DeviceError.invalidKey }
            let imported = DeviceConnection(manifest: try JSONDecoder().decode(RelayManifest.self, from: manifestData), private_key: key)
            try imported.validate()
            try await store.save(imported)
            device = imported
            consent = false
            state = .stopped
            exitIP = nil
            replacingDevice = false
            self.manifestURL = nil
            privateKeyURL = nil
            message = "Device saved in Keychain. Review the sharing notice before starting."
        } catch { message = error.localizedDescription }
    }

    func forgetDevice() async {
        guard !state.running, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await store.remove()
            device = nil
            consent = false
            exitIP = nil
            message = "Device removed from this Mac's Keychain. Relay enrollment was not revoked."
        } catch { message = error.localizedDescription }
    }

    func start() {
        guard !state.running, !busy, consent, let device else { return }
        do {
            try device.validate()
            guard let executables = Bundle.main.executableURL?.deletingLastPathComponent(),
                  FileManager.default.isExecutableFile(atPath: executables.appendingPathComponent("mac-session").path),
                  FileManager.default.isExecutableFile(atPath: executables.appendingPathComponent("mac-proxy").path) else {
                throw DeviceError.missingHelpers
            }
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true).appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.example.MacEgress", isDirectory: true)
            let sessions = support.appendingPathComponent("Sessions", isDirectory: true)
                .appendingPathComponent("run-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            ownedSessionRoot = sessions
            let child = Process()
            let input = Pipe()
            let output = Pipe()
            let id = UUID()
            child.executableURL = executables.appendingPathComponent("mac-session")
            child.arguments = ["-sessions", sessions.path, "-proxy", executables.appendingPathComponent("mac-proxy").path]
            child.standardInput = input
            child.standardOutput = output
            child.standardError = FileHandle.nullDevice
            child.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
            child.terminationHandler = { [weak self] process in
                // This helper owns a separate process group; kill residual children after a crash.
                kill(-process.processIdentifier, SIGKILL)
                Task { @MainActor in
                    await self?.reader?.value
                    self?.finished(id: id)
                }
            }
            process = child
            control = input
            sessionID = id
            stopMessage = nil
            exitIP = nil
            uploaded = 0
            downloaded = 0
            activeConnections = 0
            state = .connecting
            message = "Starting the local proxy and encrypted tunnel…"
            try child.run()
            reader = Task { [weak self] in
                do {
                    for try await line in output.fileHandleForReading.bytes.lines {
                        guard let event = try? JSONDecoder().decode(HelperEvent.self, from: Data(line.utf8)) else { continue }
                        self?.receive(event, id: id)
                    }
                } catch { self?.stop(reason: "Lost contact with the sharing helper. Start again to reconnect.") }
            }
            var payload = try JSONEncoder().encode(device)
            payload.append(0x0a)
            try input.fileHandleForWriting.write(contentsOf: payload)
            startMonitoring()
        } catch {
            if let process, process.isRunning { stop(reason: error.localizedDescription) }
            else {
                process = nil
                control = nil
                sessionID = nil
                removeOwnedSessionFiles()
                state = .disconnected
                message = error.localizedDescription
            }
        }
    }

    func receive(_ event: HelperEvent, id: UUID) {
        guard id == sessionID, state != .stopping else { return }
        switch event.event {
        case "verifying":
            state = .verifying
            sessionDirectory = event.directory
            message = "Comparing this Mac's IP with a request through the relay…"
        case "sharing":
            state = .sharing
            exitIP = event.ip
            sessionDirectory = event.directory
            message = "The relay route matches this Mac. Only the three test hosts are allowed."
        case "stats":
            uploaded = event.uploaded ?? 0
            downloaded = event.downloaded ?? 0
            activeConnections = event.active ?? 0
        case "error":
            message = event.message ?? "Sharing disconnected."
            stopMessage = message
        default: break
        }
    }

    func stop(reason: String? = nil) {
        guard let child = process else { return }
        stopMessage = reason ?? "Sharing stopped. Existing connections closed; session credentials removed."
        state = .stopping
        message = "Closing the tunnel and proxy…"
        monitor?.cancel()
        monitor = nil
        lastPath = nil
        try? control?.fileHandleForWriting.close()
        if child.isRunning { child.terminate() }
        let id = sessionID
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, self.sessionID == id, child.isRunning else { return }
            kill(-child.processIdentifier, SIGKILL)
            kill(child.processIdentifier, SIGKILL)
        }
    }

    private func finished(id: UUID) {
        guard sessionID == id else { return }
        process = nil
        control = nil
        sessionID = nil
        reader = nil
        monitor?.cancel()
        monitor = nil
        lastPath = nil
        activeConnections = 0
        sessionDirectory = nil
        removeOwnedSessionFiles()
        state = stopMessage?.hasPrefix("Sharing stopped.") == true ? .stopped : .disconnected
        message = stopMessage ?? "The sharing helper exited. Check enrollment and connectivity, then start again."
        consent = false
    }

    private func startMonitoring() {
        let pathMonitor = NWPathMonitor()
        lastPath = nil
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let fingerprint = "\(path.status)-\(path.availableInterfaces.map(\.name).sorted())-\(path.isExpensive)-\(path.supportsIPv4)-\(path.supportsIPv6)"
            Task { @MainActor [weak self] in
                guard let self, self.state.running, self.state != .stopping else { return }
                if let previous = self.lastPath, previous != fingerprint {
                    self.stop(reason: "Network changed. Start again to verify the new route.")
                } else if path.status != .satisfied {
                    self.stop(reason: "Network disconnected. Start again when you are online.")
                }
                self.lastPath = fingerprint
            }
        }
        monitor = pathMonitor
        pathMonitor.start(queue: DispatchQueue(label: "mac-egress.network"))
    }

    private func removeOwnedSessionFiles() {
        // This exact UUID directory was created by this start attempt, not imported from a manifest.
        if let ownedSessionRoot { try? FileManager.default.removeItem(at: ownedSessionRoot) }
        ownedSessionRoot = nil
    }

    func revealSession() {
        guard state == .sharing, let sessionDirectory else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: sessionDirectory)
    }
    func quit() { NSApp.terminate(nil) }
}
