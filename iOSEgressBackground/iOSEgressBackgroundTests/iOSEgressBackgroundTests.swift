import Foundation
import Testing
@testable import iOSEgressBackground

struct iOSEgressBackgroundTests {
    private func report() -> ExperimentReport {
        var report = ExperimentReport(mode: .continued, plan: .short, osVersion: "test",
                                      deviceModel: "test", batteryLevel: 1, batteryState: 1,
                                      lowPowerMode: false, network: "test")
        report.expectedIP = "1.2.3.4"
        report.clockOffsetMilliseconds = 1000
        report.clockUncertaintyMilliseconds = 100
        return report
    }

    private func sample(_ index: Int = 0, start: Double = 111000, finish: Double = 112000,
                        ip: String? = "1.2.3.4", error: String? = nil) -> CloudSample {
        .init(index: index, started: start, finished: finish, ip: ip, error: error)
    }

    @Test func onlyWhollyBackgroundSuccessfulRequestsCount() {
        var report = report()
        report.enterBackground(at: Date(timeIntervalSince1970: 100))
        report.enterForeground(at: Date(timeIntervalSince1970: 120))
        report.samples = [sample(), sample(start: 102000), sample(finish: 119000),
                          sample(ip: "9.9.9.9"), sample(error: "TimeoutError")]
        #expect(report.matchedCount == 3)
        #expect(report.backgroundMatchedCount() == 1)
    }

    @Test func uncalibratedOrForegroundResultsAreNotBackgroundProof() {
        var report = report(); report.samples = [sample()]
        #expect(report.backgroundMatchedCount() == 0)
        report.enterBackground(at: Date(timeIntervalSince1970: 100))
        report.clockOffsetMilliseconds = nil
        #expect(report.backgroundMatchedCount() == 0)
    }

    @Test func openWindowUsesObservationTimeNotAnUnlimitedFuture() {
        var report = report(); report.samples = [sample()]
        report.enterBackground(at: Date(timeIntervalSince1970: 100))
        #expect(report.backgroundMatchedCount(asOf: Date(timeIntervalSince1970: 112)) == 0)
        #expect(report.backgroundMatchedCount(asOf: Date(timeIntervalSince1970: 115)) == 1)
    }

    @Test func lifecycleWindowsDoNotDuplicateOrOverlap() {
        var report = report()
        report.enterForeground()
        report.enterBackground(at: Date(timeIntervalSince1970: 100))
        report.enterBackground(at: Date(timeIntervalSince1970: 101))
        report.enterForeground(at: Date(timeIntervalSince1970: 120))
        report.enterForeground(at: Date(timeIntervalSince1970: 121))
        report.enterBackground(at: Date(timeIntervalSince1970: 130))
        #expect(report.backgrounds.count == 2)
        #expect(report.backgrounds[0].end == Date(timeIntervalSince1970: 120))
        #expect(report.backgrounds[1].end == nil)
    }

    @Test func cloudSnapshotsMustExtendTheSameRunWithoutRewritingHistory() throws {
        var report = report()
        func probe(_ samples: [CloudSample], id: String? = nil) -> CloudProbe {
            .init(runID: id ?? report.id, now: 200000, done: false, samples: samples)
        }
        let first = probe([sample()]); try report.accept(first)
        let repeated = probe([sample()]); try report.accept(repeated)
        let invalid = [probe([], id: "wrong"), probe([]), probe([sample(ip: "9.9.9.9")]),
                       probe([sample(), sample(3)]), probe([sample(), sample(1, finish: 1)])]
        for value in invalid { #expect(throws: (any Error).self) { try report.accept(value) } }
        let next = probe([sample(), sample(1)]); try report.accept(next)
        #expect(report.samples.count == 2)
    }

    @Test func workloadsAreFiniteAndCloudLoopReturnsWithoutAwaitingCompletion() throws {
        let id = UUID().uuidString
        for plan in DiagnosticPlan.allCases {
            let code = try RemoteDiagnostic.startCode(runID: id, plan: plan)
            #expect(code.contains("index<\(plan.count)"))
            #expect(code.contains("void (async () =>"))
            #expect(code.contains("cache:'no-store'"))
            #expect(code.contains("Date.now() + 420000"))
            #expect(code.contains("await sleep(\(plan.gapSeconds * 1000))"))
        }
        #expect(DiagnosticPlan.fiveMinutes.count == 60)
        #expect(DiagnosticPlan.bursty.gapSeconds == 60)
        #expect(throws: (any Error).self) { try RemoteDiagnostic.startCode(runID: "';bad", plan: .short) }
    }

    @Test @MainActor func journalSurvivesRoundTripAndCleanupOnlyRemovesRecovery() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let files = try ExperimentFiles(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recovery = DemoRecovery(name: "test-run", proxyID: "p", browserID: "b", proxyRequested: true, browserRequested: true)
        try files.save(recovery, name: "recovery.json")
        let report = report(); try files.save(report, name: "latest.json")
        #expect(try files.load(DemoRecovery.self, name: "recovery.json")?.browserID == "b")
        #expect(try files.load(ExperimentReport.self, name: "latest.json")?.id == report.id)
        // Simulator filesystems do not implement iOS data-protection classes.
        #if !targetEnvironment(simulator)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("recovery.json").path)
        #expect(attributes[.protectionKey] as? FileProtectionType == .completeUntilFirstUserAuthentication)
        #endif
        try files.clearRecovery(); try files.clearRecovery()
        #expect(try files.load(DemoRecovery.self, name: "recovery.json") == nil)
        #expect(try files.load(ExperimentReport.self, name: "latest.json") != nil)
    }

    @Test @MainActor func retiredReportDoesNotBlockStartupOrEraseRecovery() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let files = try ExperimentFiles(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recovery = DemoRecovery(name: "prior-run", browserID: "b", browserRequested: true)
        try files.save(recovery, name: "recovery.json")
        try files.save(["plan": "retired-workload"], name: "latest.json")
        #expect(try files.loadLatestReport() == nil)
        #expect(try files.load(DemoRecovery.self, name: "recovery.json")?.browserID == "b")
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("latest.json").path))
        try files.save(report(), name: "latest.json")
        #expect(try files.loadLatestReport()?.plan == .short)
    }

    @Test func expirationBeforeTunnelAttachmentPreventsStart() throws {
        let stopper = SessionStopper(); stopper.stop()
        #expect(stopper.isStopped)
        let key = try Tunnel.generateKey()
        let manifest: [String: Any] = ["tenant": "test", "ip": "1.1.1.1", "port": 20000,
                                     "ssh_port": 40000, "tunnel_port": 30000,
                                     "ssh_user": "relay_test", "host_key": try Tunnel.publicKey(key).trimmingCharacters(in: .whitespacesAndNewlines)]
        let raw = String(decoding: try JSONSerialization.data(withJSONObject: manifest), as: UTF8.self)
        let tunnel = try Tunnel(manifest: raw, key: key)
        stopper.attach(tunnel); stopper.stop()
        #expect(try tunnel.snapshot().state == "stopped")
        #expect(throws: (any Error).self) { try tunnel.start() }
    }

    @Test @MainActor func unpairedPreviewCannotStartOrSubmitWork() {
        let model = ExperimentModel(preview: true)
        model.apiKey = "test-only"; model.consent = true
        #expect(!model.canStart)
        model.start()
        #expect(!model.running)
    }

    @Test func builtAppPermitsExactlyItsContinuedProcessingIdentifier() {
        #expect(Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] == [Bundle.main.bundleIdentifier! + ".networkDiagnostic"])
        #expect(Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] == ["processing"])
    }
}
