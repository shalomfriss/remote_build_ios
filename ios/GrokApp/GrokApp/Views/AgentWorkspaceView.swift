// Copyright (c) 2026 Pedro Shakour
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

struct AgentWorkspaceView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TabView {
            AgentSessionView()
                .tabItem {
                    Label("Speech", systemImage: "waveform")
                }

            RemoteSimulatorView()
                .tabItem {
                    Label("Simulator", systemImage: "iphone")
                }
        }
        .tint(model.theme.textPrimary)
    }
}
