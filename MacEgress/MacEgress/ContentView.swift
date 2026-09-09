import SwiftUI

struct ContentView: View {
    @Bindable var model: SharingModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: model.state == .sharing ? "network.badge.shield.half.filled" : "network")
                    .font(.title).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Mac Egress").font(.headline)
                    Text("Your connection. A cloud browser.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.state == .connecting || model.state == .verifying || model.state == .stopping {
                    ProgressView().controlSize(.small)
                }
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    LabeledContent("Status", value: model.state.rawValue).accessibilityIdentifier("sharing-status")
                    if let device = model.device {
                        LabeledContent("Device", value: device.manifest.tenant)
                        LabeledContent("Relay", value: "\(device.manifest.ip):\(device.manifest.port)").font(.caption.monospaced())
                    }
                    LabeledContent(model.state == .sharing ? "Verified exit IP" : "Last verified IP", value: model.exitIP ?? "—")
                        .font(.body.monospaced())
                    Text(model.message).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }.padding(8)
            }
            if model.needsImport {
                VStack(alignment: .leading, spacing: 12) {
                    fileSelection("1. Manifest (.json)", url: model.manifestURL,
                        button: "Choose manifest…", action: model.chooseManifest)
                    fileSelection("2. Private key (not .pub)", url: model.privateKeyURL,
                        button: "Choose private key…", action: model.choosePrivateKey)
                    Text("Both files are required. The private key is saved in your login Keychain.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Save device") { Task { await model.saveDevice() } }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                            .disabled(!model.canSaveDevice).accessibilityIdentifier("save-device")
                        if model.device != nil {
                            Button("Cancel") { model.cancelImport() }.disabled(model.busy)
                        }
                    }
                }.disabled(model.busy)
            } else {
                if model.state == .sharing {
                    HStack {
                        metric("Sent", model.uploaded)
                        Spacer()
                        metric("Received", model.downloaded)
                        Spacer()
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Connections").font(.caption).foregroundStyle(.secondary)
                            Text("\(model.activeConnections)").monospacedDigit()
                        }
                    }
                    Text("Includes route checks. Verified every 30 seconds.").font(.caption).foregroundStyle(.secondary)
                }
                if !model.state.running {
                    Toggle(isOn: $model.consent) {
                        Text("Allow this relay session to use my Mac’s internet connection.").font(.callout)
                    }.toggleStyle(.checkbox).accessibilityIdentifier("sharing-consent")
                }
                Button {
                    if model.state.running { model.stop() } else { model.start() }
                } label: {
                    Text(model.state.running ? "Stop sharing" : "Start sharing").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(model.busy || model.state == .stopping || (!model.state.running && !model.consent))
                .accessibilityIdentifier("sharing-toggle")
            }
            Text("Routing prototype · HTTPS test hosts only\nNo website TLS interception. No system proxy changes.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Menu("Connection") {
                    Button("Import device connection…") { model.beginImport() }
                        .disabled(model.state.running || model.busy)
                    Button("Forget saved device", role: .destructive) { Task { await model.forgetDevice() } }
                        .disabled(model.device == nil || model.state.running || model.busy)
                    Divider()
                    Button("Reveal active session files…") { model.revealSession() }.disabled(model.state != .sharing)
                }.menuStyle(.borderlessButton).fixedSize()
                Spacer()
                Button("Quit") { model.quit() }.keyboardShortcut("q")
            }
        }.padding(20).frame(width: 384)
    }
    private func fileSelection(_ label: String, url: URL?, button: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.callout.weight(.medium))
            HStack {
                Button(button, action: action)
                Text(url?.lastPathComponent ?? "No file selected")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .help(url?.path ?? "No file selected")
            }
        }
    }
    private func metric(_ label: String, _ bytes: Int64) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)).monospacedDigit()
        }
    }
}

#Preview {
    ContentView(model: SharingModel(preview: true))
}
