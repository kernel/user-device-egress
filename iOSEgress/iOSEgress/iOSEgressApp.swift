//
//  iOSEgressApp.swift
//  iOSEgress
//
//  Created by Rafael Garcia on 9/16/26.
//

import SwiftUI

@main
struct iOSEgressApp: App {
    @State private var model = DemoModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { model.enteredBackground() }
                }
        }
    }
}
