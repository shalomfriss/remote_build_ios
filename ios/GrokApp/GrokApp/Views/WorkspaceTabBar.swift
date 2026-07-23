// Copyright (c) 2026 Pedro Shakour
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

struct WorkspaceTabBar: View {
    @Binding var selection: WorkspaceTab
    let theme: GrokTheme

    var body: some View {
        HStack(spacing: 0) {
            tabButton(
                title: "Speech",
                systemImage: "waveform",
                tab: .speech
            )
            tabButton(
                title: "Simulator",
                systemImage: "iphone",
                tab: .simulator
            )
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
        .background(theme.bgBase)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(theme.promptBorder)
                .frame(height: 1)
        }
    }

    private func tabButton(
        title: String,
        systemImage: String,
        tab: WorkspaceTab
    ) -> some View {
        VStack(spacing: 2) {
            Image(systemName: systemImage)
                .font(.title3)
            Text(title)
                .font(.caption)
        }
        .foregroundStyle(selection == tab ? theme.textPrimary : theme.textSecondary)
        .frame(maxWidth: .infinity, minHeight: 50)
        .contentShape(Rectangle())
        .onTapGesture {
            selection = tab
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(selection == tab ? .isSelected : [])
        .accessibilityAction {
            selection = tab
        }
    }
}
