import Darwin
import Foundation
import UIKit

enum ExperimentMode: String, Codable, CaseIterable, Identifiable {
    case continued, baseline
    var id: String { rawValue }
    var title: String { self == .continued ? "Continued processing" : "Baseline (no background task)" }
}

enum DiagnosticPlan: String, Codable, CaseIterable, Identifiable {
    case short, fiveMinutes, bursty
    var id: String { rawValue }
    var count: Int { self == .fiveMinutes ? 60 : 12 }
    var gapAfter: Int { self == .bursty ? 4 : 0 }
    var gapSeconds: Int { self == .bursty ? 60 : 0 }
    var title: String {
        switch self {
        case .short: "12 requests · about 1 minute"
        case .fiveMinutes: "60 requests · about 5 minutes"
        case .bursty: "12 requests · includes a 60-second pause"
        }
    }
}

struct CloudSample: Codable, Sendable, Equatable {
    let index: Int
    let started: Double
    let finished: Double
    let ip: String?
    let error: String?
}

struct CloudProbe: Codable, Sendable {
    let runID: String
    let now: Double
    let done: Bool
    let samples: [CloudSample]
    var observerHeartbeat: Double? = nil
}

struct ExperimentReport: Codable, Sendable {
    struct Event: Codable, Sendable {
        let at: Date
        let kind: String
        let detail: String
    }
    struct BackgroundWindow: Codable, Sendable {
        let start: Date
        var end: Date?
    }
    var id = UUID().uuidString.lowercased()
    var created = Date()
    let mode: ExperimentMode
    let plan: DiagnosticPlan
    let osVersion: String
    let deviceModel: String
    let batteryLevel: Float
    let batteryState: Int
    let lowPowerMode: Bool
    let network: String
    var outcome = "Starting"
    var expectedIP = ""
    var events: [Event] = []
    var backgrounds: [BackgroundWindow] = []
    var samples: [CloudSample] = []
    var clockOffsetMilliseconds: Double?
    var clockUncertaintyMilliseconds: Double?
    var cleanupComplete = false

    var matchedCount: Int { samples.filter { $0.error == nil && $0.ip == expectedIP && !expectedIP.isEmpty }.count }

    // Count only requests whose entire interval is unambiguously backgrounded.
    // Add two seconds of guard time beyond the measured clock uncertainty.
    func backgroundMatchedCount(asOf now: Date = Date()) -> Int {
        guard let offset = clockOffsetMilliseconds, let uncertainty = clockUncertaintyMilliseconds else { return 0 }
        let margin = uncertainty + 2000
        return samples.filter { sample in
            guard sample.error == nil, sample.ip == expectedIP, !expectedIP.isEmpty else { return false }
            let start = (sample.started - offset - margin) / 1000
            let end = (sample.finished - offset + margin) / 1000
            return backgrounds.contains { window in
                start >= window.start.timeIntervalSince1970 && end <= (window.end ?? now).timeIntervalSince1970
            }
        }.count
    }

    mutating func enterBackground(at now: Date = Date()) {
        guard backgrounds.last?.end != nil || backgrounds.isEmpty else { return }
        backgrounds.append(.init(start: now))
    }

    mutating func enterForeground(at now: Date = Date()) {
        if let last = backgrounds.indices.last, backgrounds[last].end == nil { backgrounds[last].end = now }
    }

    mutating func accept(_ probe: CloudProbe) throws {
        guard probe.runID == id, probe.now.isFinite, probe.samples.count <= plan.count,
              probe.samples.enumerated().allSatisfy({ $0.offset == $0.element.index && $0.element.finished >= $0.element.started }),
              probe.samples.count >= samples.count,
              Array(probe.samples.prefix(samples.count)) == samples else { throw DemoError("Cloud diagnostic returned inconsistent results.") }
        samples = probe.samples
    }
}

enum ExperimentEnvironment {
    static var debuggerAttached: Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let result = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        return result != 0 || (info.kp_proc.p_flag & P_TRACED) != 0
    }
    static var simulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }
    static var deviceModel: String {
        var info = utsname(); uname(&info)
        return withUnsafeBytes(of: &info.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

// Non-secret journals must remain writable during a lock test. Credentials retain
// the existing WhenUnlockedThisDeviceOnly Keychain policy and are loaded before Start.
@MainActor
final class ExperimentFiles {
    private let directory: URL
    init(directory: URL? = nil) throws {
        self.directory = try directory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("BackgroundLab", isDirectory: true)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true,
                                               attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var url = self.directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
    func save<T: Encodable>(_ value: T, name: String) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: directory.appendingPathComponent(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func load<T: Decodable>(_ type: T.Type, name: String) throws -> T? {
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(contentsOf: url))
    }
    func clearRecovery() throws {
        let url = directory.appendingPathComponent("recovery.json")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    func loadLatestReport() throws -> ExperimentReport? {
        // Retired workloads may have an incompatible report. Never let display
        // history prevent startup or recovery; leave the saved exports untouched.
        do { return try load(ExperimentReport.self, name: "latest.json") }
        catch is DecodingError { return nil }
    }
    func reportURL(_ id: String) -> URL { directory.appendingPathComponent("report-\(id).json") }
}
