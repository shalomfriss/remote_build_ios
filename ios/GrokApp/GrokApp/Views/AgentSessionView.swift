// Copyright (c) 2026 Pedro Shakour
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// Agent session: upstream pager chrome only (status + scrollback + turn + prompt).
struct AgentSessionView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let theme = model.theme
        VStack(spacing: 0) {
            AgentStatusBar(
                chrome: model.chrome,
                theme: theme,
                isConnected: model.acp.sessionReady && model.reconnectBanner == nil,
                onBack: { model.showWelcome() },
                onDisconnect: model.disconnectFromCompanion,
                onReconnect: model.reconnectToCompanion
            )
            if let banner = model.reconnectBanner {
                HStack(spacing: 8) {
                    Circle()
                        .fill(theme.textSecondary)
                        .frame(width: 6, height: 6)
                    Text(banner)
                        .font(.caption.monospaced())
                        .foregroundStyle(theme.textSecondary)
                    Spacer(minLength: 0)
                    if model.isManuallyDisconnected {
                        Button("Reconnect", action: model.reconnectToCompanion)
                            .font(.caption.monospaced())
                            .foregroundStyle(theme.textPrimary)
                    } else if banner.contains("Setup") {
                        Button("Setup") { model.showOnboarding() }
                            .font(.caption.monospaced())
                            .foregroundStyle(theme.textPrimary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(theme.bgBase)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(theme.promptBorder).frame(height: 1)
                }
            }
            ScrollbackView(
                entries: model.messages,
                theme: theme,
                refreshID: model.scrollbackRefreshID,
                showTimestamps: model.showTimestamps,
                onToggleFold: { id in model.acp.tracker.toggleFold(id: id) },
                onOpenMermaid: { source in await model.renderMermaidPNG(source: source) },
                onDismissKeyboard: dismissKeyboard
            )
            .background(theme.bgTerminal)
            if let permission = model.permissionRequest {
                PermissionBanner(
                    message: permission.message,
                    options: permission.options,
                    selectedOptionId: permission.selectedOptionId,
                    theme: theme,
                    onSelect: { model.selectPermission(optionId: $0) }
                )
            }
            AgentComposerView()
        }
        .background(theme.bgBase)
    }

    private func dismissKeyboard() {
        model.isPromptFocused = false
    }
}

#Preview {
    AgentSessionView()
        .environmentObject(AppModel())
}
