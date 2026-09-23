import SwiftUI

struct BackgroundSetupView: View {
    @Bindable var model: ExperimentModel
    @Environment(\.dismiss) private var dismiss
    @State private var scanning = false
    @State private var link = ""
    @State private var invitation: PairingInvitation?
    @State private var confirming = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Pair the experiment") {
                    if model.enrolled {
                        Label("Experiment paired", systemImage: "checkmark.circle.fill").foregroundStyle(.teal)
                        LabeledContent("Device", value: model.tenant)
                    } else {
                        Button("Scan pairing code", systemImage: "qrcode.viewfinder") { scanning = true }
                            .disabled(model.pairing || model.recovery != nil)
                        Text("This is a separate app with its own device key. Use a fresh code; the foreground app's enrollment is unchanged.")
                            .font(.caption).foregroundStyle(.secondary)
                        DisclosureGroup("Paste a pairing link instead") {
                            SecureField("Pairing link", text: $link).textInputAutocapitalization(.never).autocorrectionDisabled()
                            Button("Use link") { receive(link); link = "" }.disabled(model.pairing || model.recovery != nil || link.isEmpty)
                        }
                        if model.pairing { ProgressView("Pairing…") }
                    }
                }
                Section("Kernel demo account") {
                    SecureField("Kernel API key", text: $model.apiKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("Developer-only setup. Credentials stay in this app's protected Keychain; starting a run loads them into memory before a lock test.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Save setup") { Task { await model.saveSetup() } }.disabled(model.pairing || model.apiKey.isEmpty)
                }
                if !model.setupMessage.isEmpty { Section { Text(model.setupMessage).textSelection(.enabled) } }
            }
            .navigationTitle("Experiment setup").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.disabled(model.pairing) } }
            .interactiveDismissDisabled(model.pairing)
            .sheet(isPresented: $scanning, onDismiss: { if invitation != nil { confirming = true } }) { PairingScanner(scanned: receive) }
            .alert("Pair this experiment?", isPresented: $confirming) {
                Button("Connect") { if let value = invitation { Task { await model.pair(value); invitation = nil } } }
                Button("Cancel", role: .cancel) { invitation = nil }
            } message: { Text("Connect to relay \(invitation?.host ?? "") using this app's own device identity.") }
        }
    }
    private func receive(_ value: String) {
        do { invitation = try PairingInvitation(value); if !scanning { confirming = true } }
        catch { model.setupMessage = error.localizedDescription }
    }
}
