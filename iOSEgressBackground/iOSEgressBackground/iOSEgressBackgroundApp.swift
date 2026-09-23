import SwiftUI
import UIKit

@main
struct iOSEgressBackgroundApp: App {
    @State private var model = ExperimentModel()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .onChange(of: phase) { _, phase in model.sceneChanged(phase) }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in model.protectionChanged(available: false) }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)) { _ in model.protectionChanged(available: true) }
        }
    }
}
