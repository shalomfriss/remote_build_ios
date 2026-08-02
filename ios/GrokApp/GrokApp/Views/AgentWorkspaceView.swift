// Copyright (c) 2026 Pedro Shakour
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

struct AgentWorkspaceView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedTab = WorkspaceTab.speech
    @State private var isSimulatorFullScreen = false

    var body: some View {
        TabView(selection: $selectedTab) {
            AgentSessionView()
                .tabItem {
                    Label("Speech", systemImage: "waveform")
                }
                .tag(WorkspaceTab.speech)

            RemoteSimulatorView(
                isFullScreen: false,
                onToggleFullScreen: { isSimulatorFullScreen = true }
            )
                .tabItem {
                    Label("Simulator", systemImage: "iphone")
                }
                .tag(WorkspaceTab.simulator)
        }
        .tint(model.theme.textPrimary)
        .overlay(alignment: .bottomTrailing) {
            Group {
                if selectedTab == .speech {
                    if !model.isPromptFocused {
                        Button("Run", systemImage: "play.fill", action: runProject)
                            .labelStyle(.iconOnly)
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.circle)
                            .controlSize(.large)
                            .frame(minWidth: 44, minHeight: 44)
                            .disabled(!model.canRunCurrentProject)
                    }
                } else {
                    Button(
                        "Full Screen",
                        systemImage: "arrow.up.left.and.arrow.down.right",
                        action: showSimulatorFullScreen
                    )
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                    .frame(minWidth: 44, minHeight: 44)
                }
            }
            .frame(width: 44, height: 44)
            .padding(.trailing, 82)
            .padding(.bottom, 4)
            .offset(y: 10)
        }
        .onChange(of: selectedTab) { _, tab in
            guard tab == .simulator else { return }
            model.isPromptFocused = false
            Task { await model.refreshSimulatorURL() }
        }
        .fullScreenCover(isPresented: $isSimulatorFullScreen) {
            RemoteSimulatorView(
                isFullScreen: true,
                onToggleFullScreen: { isSimulatorFullScreen = false }
            )
            .environmentObject(model)
            .ignoresSafeArea()
            .statusBarHidden()
        }
    }

    private func runProject() {
        model.runCurrentProject()
        model.isPromptFocused = false
    }

    private func showSimulatorFullScreen() {
        isSimulatorFullScreen = true
    }
}
