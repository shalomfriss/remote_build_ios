// Copyright (c) 2026 Pedro Shakour
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

struct AgentWorkspaceView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedTab = WorkspaceTab.speech

    var body: some View {
        TabView(selection: $selectedTab) {
            AgentSessionView()
                .tabItem {
                    Label("Speech", systemImage: "waveform")
                }
                .tag(WorkspaceTab.speech)

            RemoteSimulatorView()
                .tabItem {
                    Label("Simulator", systemImage: "iphone")
                }
                .tag(WorkspaceTab.simulator)
        }
        .tint(model.theme.textPrimary)
        .onChange(of: selectedTab) { _, tab in
            guard tab == .simulator else { return }
            model.isPromptFocused = false
            Task { await model.refreshSimulatorURL() }
        }
    }
}
