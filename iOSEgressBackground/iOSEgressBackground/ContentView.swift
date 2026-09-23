import SwiftUI

struct ContentView: View {
    @Bindable var model: ExperimentModel
    @State private var manualCleanup = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Can your phone keep providing egress after you leave the app?")
                        .font(.title2.weight(.semibold))
                    Text("A finite cloud-browser diagnostic—not an always-on proxy. Results are measured in the cloud, not inferred from a phone timer.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Section("Experiment") {
                    Picker("Runtime", selection: $model.mode) {
                        ForEach(ExperimentMode.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Workload", selection: $model.plan) {
                        ForEach(DiagnosticPlan.allCases) { Text($0.title).tag($0) }
                    }
                    LabeledContent("Network", value: model.network).font(.caption)
                    LabeledContent("Protected data", value: model.protectedDataAvailable ? "Available" : "Locked")
                    Text("Run once in each mode. Wait for “you can leave the app,” then switch apps or lock the phone. Test without Xcode's debugger attached.")
                        .font(.caption).foregroundStyle(.secondary)
                }.disabled(model.running)
                if let report = model.report {
                    Section("Measured results") {
                        LabeledContent("Requests measured", value: "\(report.samples.count) / \(report.plan.count)")
                        ProgressView(value: Double(report.samples.count), total: Double(report.plan.count))
                        LabeledContent("Matched phone IP", value: "\(report.matchedCount)")
                        LabeledContent("Wholly in background", value: "\(report.backgroundMatchedCount())")
                            .foregroundStyle(.teal)
                        LabeledContent("Expected exit IP", value: report.expectedIP.isEmpty ? "Verifying…" : report.expectedIP)
                            .font(.caption.monospaced())
                        Text("Background count uses cloud timestamps, recorded app lifecycle, clock uncertainty, and a 2-second guard. No count means no demonstrated background success.")
                            .font(.caption).foregroundStyle(.secondary)
                        if let last = report.samples.last {
                            Text("Latest request: \(last.error ?? last.ip ?? "no result")").font(.caption.monospaced())
                        }
                    }
                }
                Section {
                    Text(model.status).font(.headline)
                    Text(model.message).font(.subheadline).textSelection(.enabled)
                    if model.recovery != nil && !model.running {
                        Button("Retry cloud cleanup", action: model.retryCleanup)
                        Text(model.recovery?.name ?? "").font(.caption.monospaced()).textSelection(.enabled)
                        Button("I removed the browser and proxy manually…") { manualCleanup = true }
                    }
                    if let url = model.reportURL, !model.running {
                        ShareLink(item: url) { Label("Export experiment report", systemImage: "square.and.arrow.up") }
                        Text("Report includes public IPs and device/network observations. No keys or proxy passwords. Share deliberately.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let report = model.report, !report.events.isEmpty {
                    Section("Timeline") {
                        ForEach(Array(report.events.enumerated()), id: \.offset) { _, event in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack { Text(event.kind).font(.caption.bold()); Spacer(); Text(event.at, style: .time).font(.caption.monospaced()) }
                                Text(event.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Background Lab").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Setup", systemImage: "slider.horizontal.3") { model.showSetup = true }
                        .disabled(model.running || !model.ready)
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 12) {
                    if !model.running && model.enrolled && !model.apiKey.isEmpty && model.recovery == nil {
                        Toggle("Run this finite diagnostic using my connection and temporary, billable Kernel resources.", isOn: $model.consent)
                            .font(.caption)
                    }
                    Button {
                        if model.running { model.stop() }
                        else if !model.enrolled || model.apiKey.isEmpty { model.showSetup = true }
                        else { model.start() }
                    } label: {
                        Label(model.running ? (model.stopping ? "Stopping & cleaning up" : "Stop experiment") : (model.enrolled && !model.apiKey.isEmpty ? "Start diagnostic" : "Set up this experiment"), systemImage: model.running ? "stop.fill" : "play.fill")
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large).tint(model.running ? .orange : .teal)
                    .disabled(!model.ready || model.stopping || model.recovery != nil && !model.running || (!model.running && model.enrolled && !model.apiKey.isEmpty && !model.canStart))
                }.padding().background(.regularMaterial)
            }
            .sheet(isPresented: $model.showSetup) { BackgroundSetupView(model: model) }
            .alert("Confirm manual cleanup", isPresented: $manualCleanup) {
                Button("Browser and proxy removed", role: .destructive) { model.confirmManualCleanup() }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Delete the matching browser BEFORE its proxy in Kernel. This button only clears the local recovery record.") }
        }
    }
}

#Preview {
    ContentView(model: ExperimentModel(preview: true))
}
