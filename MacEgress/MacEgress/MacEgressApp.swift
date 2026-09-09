import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: SharingModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.state.running else { return .terminateNow }
        model.stop()
        Task {
            while model.state.running { try? await Task.sleep(for: .milliseconds(50)) }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct MacEgressApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = SharingModel()
    var body: some Scene {
        MenuBarExtra("Mac Egress", systemImage: model.state == .sharing ? "network.badge.shield.half.filled" : "network") {
            ContentView(model: model).onAppear { delegate.model = model }
        }
        .menuBarExtraStyle(.window)
    }
}
