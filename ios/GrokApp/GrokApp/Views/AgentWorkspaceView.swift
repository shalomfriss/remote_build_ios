// Copyright (c) 2026 Pedro Shakour
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

struct AgentWorkspaceView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedTab = WorkspaceTab.speech

    var body: some View {
        ZStack {
            if selectedTab == .speech {
                AgentSessionView()
            } else {
                RemoteSimulatorView()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            WorkspaceTabBar(selection: $selectedTab, theme: model.theme)
        }
        .onChange(of: selectedTab) { _, tab in
            guard tab == .simulator else { return }
            model.isPromptFocused = false
            Task { await model.refreshSimulatorURL() }
        }
    }
}
