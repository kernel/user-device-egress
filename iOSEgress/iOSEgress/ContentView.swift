import SwiftUI

struct ContentView: View {
    @Bindable var model: DemoModel
    @State private var confirmCleanup = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("IPHONE EGRESS LAB", systemImage: "network")
                            .font(.caption.weight(.semibold)).tracking(2).foregroundStyle(.secondary)
                        if !model.running {
                            Text("Your connection.\nA cloud browser.")
                                .font(.system(size: 34, weight: .semibold, design: .rounded))
                            Text("Watch a Kernel browser reach the internet through this device.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    ipCard
                    browserCard
                    if model.running {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(["Phone tunnel", "Kernel proxy", "Cloud browser", "IP verified"].enumerated()), id: \.offset) { index, label in
                                HStack(spacing: 12) {
                                    Image(systemName: model.stage > index ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(model.stage > index ? Color.mint : Color.secondary)
                                    Text(label).font(.subheadline)
                                    Spacer()
                                    if model.stage == index && !model.stopping { ProgressView().controlSize(.small) }
                                }
                            }
                        }.padding(20).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.status).font(.headline)
                        Text(model.message).font(.subheadline).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if model.recovery != nil && !model.running {
                        VStack(alignment: .leading, spacing: 12) {
                            Button("Retry cloud cleanup", systemImage: "arrow.clockwise", action: model.retryCleanup)
                                .buttonStyle(.borderedProminent)
                            Text(model.recovery?.name ?? "").font(.caption.monospaced()).textSelection(.enabled)
                            Button("I already removed these resources in Kernel…") { confirmCleanup = true }
                                .font(.caption)
                        }
                    }
                    Text("Foreground experiment · 3-minute demo\nTest sites only. No website TLS interception. Leaving the app stops sharing.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(20)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Device Egress")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Setup", systemImage: "slider.horizontal.3") { model.showSetup = true }
                        .disabled(model.running || !model.ready)
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 12) {
                if !model.running && model.enrolled && !model.apiKey.isEmpty && model.recovery == nil {
                    Toggle("Use my connection and create temporary, billable Kernel resources.", isOn: $model.consent)
                        .font(.caption).tint(.teal)
                }
                Button {
                    if model.running { model.stop() }
                    else if !model.enrolled || model.apiKey.isEmpty { model.showSetup = true }
                    else { model.start() }
                } label: {
                    HStack(spacing: 10) {
                        if model.stopping { ProgressView() }
                        else { Image(systemName: model.running ? "stop.fill" : "play.fill") }
                        Text(model.running ? (model.stopping ? "Stopping & cleaning up" : "Stop demo") : (model.enrolled && !model.apiKey.isEmpty ? "Start live demo" : "Set up this iPhone"))
                            .fontWeight(.semibold)
                    }.frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent).tint(model.running ? .orange : .teal).controlSize(.large)
                .disabled(!model.ready || model.stopping || model.recovery != nil && !model.running || (!model.running && model.enrolled && !model.apiKey.isEmpty && !model.canStart))
                }.padding(.horizontal, 20).padding(.vertical, 12).background(.regularMaterial)
            }
            .sheet(isPresented: $model.showSetup) { SetupView(model: model) }
            .alert("Confirm manual cleanup", isPresented: $confirmCleanup) {
                Button("Resources removed", role: .destructive) { Task { await model.confirmManualCleanup() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Only clear this record after deleting the matching browser, then its proxy, in Kernel. This button does not delete cloud resources.")
            }
        }
    }

    private var ipCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label(model.matched ? "VERIFIED MATCH" : "ROUTE VERIFICATION", systemImage: model.matched ? "checkmark.shield.fill" : "point.3.connected.trianglepath.dotted")
                    .font(.caption.weight(.semibold)).tracking(1)
                    .foregroundStyle(model.matched ? Color.mint : Color.secondary)
                Spacer()
                if model.checks > 0 { Text("\(model.checks) checks").font(.caption).foregroundStyle(.secondary) }
            }
            VStack(alignment: .leading, spacing: 16) {
                ipRow("THIS DEVICE", icon: "iphone", value: model.phoneIP)
                Divider()
                ipRow("KERNEL BROWSER", icon: "cloud", value: model.browserIP)
            }
            HStack(spacing: 6) {
                Text("Cloud"); Image(systemName: "arrow.right"); Text("Relay")
                Image(systemName: "arrow.right"); Text("iPhone").fontWeight(.semibold)
                Image(systemName: "arrow.right"); Text("Internet")
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
    }

    private func ipRow(_ label: String, icon: String, value: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.title2).frame(width: 28).foregroundStyle(.teal)
            VStack(alignment: .leading, spacing: 5) {
                Text(label).font(.caption2.weight(.semibold)).tracking(1).foregroundStyle(.secondary)
                Text(value).font(.system(.title3, design: .monospaced).weight(.medium))
                    .lineLimit(1).minimumScaleFactor(0.6).textSelection(.enabled)
            }
        }
    }

    private var browserCard: some View {
        VStack(spacing: 0) {
            HStack {
                Circle().fill(model.running && model.screenshot != nil ? Color.mint : Color.gray).frame(width: 7, height: 7)
                Text(model.currentHost).font(.caption.monospaced()).lineLimit(1)
                Spacer()
                Image(systemName: "lock.shield")
            }.padding(14).foregroundStyle(.white.opacity(0.8)).background(Color(red: 0.07, green: 0.11, blue: 0.14))
            ZStack {
                Color(red: 0.06, green: 0.1, blue: 0.13)
                if let image = model.screenshot {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    VStack(spacing: 14) {
                        Image(systemName: "desktopcomputer").font(.system(size: 42, weight: .ultraLight))
                        Text("A real browser, running in the cloud").font(.subheadline)
                        Text("Its screenshots will appear here.").font(.caption).foregroundStyle(.white.opacity(0.5))
                    }.foregroundStyle(.white.opacity(0.8)).padding()
                }
            }.aspectRatio(4 / 3, contentMode: .fit)
            HStack {
                if let date = model.screenshotDate {
                    Text("Captured \(date, style: .relative) ago").font(.caption2)
                } else { Text("SCREENSHOT FEED").font(.caption2).tracking(1) }
                Spacer()
                Text("↑ \(bytes(model.uploaded))  ↓ \(bytes(model.downloaded))").font(.caption2.monospaced())
            }.foregroundStyle(.secondary).padding(14).background(.regularMaterial)
        }.clipShape(RoundedRectangle(cornerRadius: 24))
    }

    private func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }
}

struct SetupView: View {
    @Bindable var model: DemoModel
    @Environment(\.dismiss) private var dismiss
    @State private var scanning = false
    @State private var pasteLink = ""
    @State private var invitation: PairingInvitation?
    @State private var confirming = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if model.enrolled {
                        Label("This iPhone is connected", systemImage: "checkmark.circle.fill").foregroundStyle(.teal)
                        LabeledContent("Device", value: model.tenant)
                    } else {
                        Button("Scan pairing code", systemImage: "qrcode.viewfinder") { scanning = true }
                            .disabled(model.pairing || model.recovery != nil)
                        Text("Scan the code on your Mac. The app takes care of the secure connection—no files to move.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        DisclosureGroup("Have a pairing link instead?") {
                            SecureField("Paste pairing link", text: $pasteLink)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                            Button("Use pairing link") { receive(pasteLink); pasteLink = "" }
                                .disabled(model.pairing || model.recovery != nil || pasteLink.isEmpty)
                        }
                        if model.pairing { ProgressView("Connecting this iPhone…") }
                    }
                } header: { Text("1 · Pair your iPhone") }
                Section {
                    SecureField("Kernel API key", text: $model.apiKey)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("Use a dedicated demo key. This development app stores it in Keychain to create a browser and proxy, then delete them when the demo ends.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Save setup") { Task { await model.saveSettings() } }
                        .disabled(model.pairing || model.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } header: { Text("2 · Connect Kernel") }
                if !model.setupMessage.isEmpty {
                    Section { Text(model.setupMessage).font(.callout).textSelection(.enabled) }
                }
                Section {
                    Text("Keep the app visible during this first experiment. Background continuation is a separate follow-up. API calls and screenshot downloads use the phone directly; browser website traffic uses the relay tunnel.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("One-time setup").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.disabled(model.pairing) } }
            .interactiveDismissDisabled(model.pairing)
            .sheet(isPresented: $scanning, onDismiss: { if invitation != nil { confirming = true } }) { PairingScanner(scanned: receive) }
            .alert("Connect this iPhone?", isPresented: $confirming) {
                Button("Connect") {
                    if let value = invitation { Task { await model.pair(value); invitation = nil } }
                }
                Button("Cancel", role: .cancel) { invitation = nil }
            } message: {
                Text("Only use codes supplied for this demo. Relay: \(invitation?.host ?? ""). Your private device key stays on this iPhone.")
            }
        }
    }

    private func receive(_ text: String) {
        do { invitation = try PairingInvitation(text); if !scanning { confirming = true } }
        catch { model.setupMessage = error.localizedDescription }
    }
}

#Preview {
    ContentView(model: DemoModel(preview: true))
}
