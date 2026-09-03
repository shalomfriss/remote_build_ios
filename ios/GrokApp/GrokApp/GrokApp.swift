// Copyright (c) 2026 Pedro Shakour
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

@main
struct GrokApp: App {
    @StateObject private var model = AppModel()
    @State private var wasBackgrounded = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                // Hard bg so launch never flashes the default white window.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(hex: "#141414").ignoresSafeArea())
                .background(model.theme.bgBase.ignoresSafeArea())
                .preferredColorScheme(model.themeName.lowercased().contains("day") ? .light : .dark)
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .background:
                        wasBackgrounded = true
                    case .active:
                        model.reconnectTransportIfNeeded(reloadSession: wasBackgrounded)
                        wasBackgrounded = false
                    case .inactive:
                        break
                    @unknown default:
                        break
                    }
                }
        }
    }
}
