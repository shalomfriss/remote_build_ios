// Copyright (c) 2026 Pedro Shakour
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

struct WorkspaceTabBar: View {
    @Binding var selectedTab: WorkspaceTab
    let theme: GrokTheme
    let canRun: Bool
    let onRun: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: selectSpeech) {
                Label("Speech", systemImage: "waveform")
                    .frame(maxWidth: .infinity)
            }
            .foregroundStyle(selectedTab == .speech ? theme.textPrimary : theme.textSecondary)

            Button(action: selectSimulator) {
                Label("Simulator", systemImage: "iphone")
                    .frame(maxWidth: .infinity)
            }
            .foregroundStyle(selectedTab == .simulator ? theme.textPrimary : theme.textSecondary)

            Button(action: onRun) {
                HStack(spacing: 4) {
                    Text("Run")
                    Image(systemName: "chevron.right")
                        .accessibilityHidden(true)
                }
                .fontWeight(.semibold)
                .padding(.horizontal, 14)
            }
            .foregroundStyle(theme.bgBase)
            .background(theme.textPrimary, in: Capsule())
            .disabled(!canRun)
            .opacity(canRun ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .frame(minHeight: 48)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(theme.promptBorder)
                .frame(height: 1)
        }
    }

    private func selectSpeech() {
        selectedTab = .speech
    }

    private func selectSimulator() {
        selectedTab = .simulator
    }
}
