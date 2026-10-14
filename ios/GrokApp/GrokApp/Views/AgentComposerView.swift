// Copyright (c) 2026 Pedro Shakour
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// Owns rapidly-changing keyboard and dictation state so partial transcription
/// updates do not invalidate the session's potentially large scrollback.
struct AgentComposerView: View {
    @EnvironmentObject private var model: AppModel
    @State private var draft = ""

    private var isThemeDraft: Bool {
        let normalized = draft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "/theme"
            || normalized.hasPrefix("/theme ")
            || normalized == "/t"
            || normalized.hasPrefix("/t ")
    }

    private var atFileQuery: String? {
        guard let at = draft.lastIndex(of: "@") else { return nil }
        let fragment = String(draft[draft.index(after: at)...])
        guard !fragment.contains(" "), !fragment.contains("\n") else { return nil }
        return fragment
    }

    private var filteredAtFiles: [String] {
        guard let query = atFileQuery?.lowercased(), !query.isEmpty else {
            return model.workspaceFiles
        }
        return model.workspaceFiles
            .filter { $0.lowercased().contains(query) }
            .sorted { first, second in
                let firstLowercase = first.lowercased()
                let secondLowercase = second.lowercased()
                let firstHasPrefix = firstLowercase.hasPrefix(query)
                let secondHasPrefix = secondLowercase.hasPrefix(query)
                if firstHasPrefix != secondHasPrefix { return firstHasPrefix }
                return firstLowercase < secondLowercase
            }
    }

    private var filteredSlashCommands: [SlashCommand] {
        guard draft.hasPrefix("/") else { return [] }
        let filter = String(draft.dropFirst()).lowercased()
        guard !filter.isEmpty else { return SlashCommand.builtins }
        return SlashCommand.builtins.filter {
            $0.name.dropFirst().lowercased().contains(filter)
                || $0.summary.lowercased().contains(filter)
        }
    }

    var body: some View {
        Group {
            if isThemeDraft {
                ThemeSuggestDropdown(
                    themes: model.availableThemes,
                    activeTheme: model.themeName,
                    theme: model.theme,
                    onSelect: selectTheme
                )
            } else if atFileQuery != nil {
                FileSuggestDropdown(
                    files: filteredAtFiles,
                    theme: model.theme,
                    onSelect: insertAtFile
                )
            } else if draft.hasPrefix("/") {
                SlashDropdown(
                    commands: filteredSlashCommands,
                    theme: model.theme,
                    onSelect: { draft = $0.name + " " }
                )
            }
        }
        .task(id: atFileQuery != nil) {
            guard atFileQuery != nil, model.workspaceFiles.isEmpty else { return }
            await model.refreshWorkspaceFiles()
        }

        TurnStatusBar(
            activity: model.chrome.turnActivity,
            isRunning: model.acp.isRunning,
            turnStartedAt: model.chrome.turnStartedAt,
            phaseStartedAt: model.chrome.phaseStartedAt,
            turnTokensUsed: model.chrome.turnTokensUsed,
            queuedPromptCount: model.chrome.queuedPromptCount,
            theme: model.theme,
            onStop: model.stopTurn
        )
        PromptBar(
            draft: $draft,
            isFocused: $model.isPromptFocused,
            modelLine: model.chrome.promptInfoLine,
            theme: model.theme,
            onSend: sendDraft
        )
        .task(consumeExternalDraft)
        .onChange(of: model.draft) { _, newValue in
            guard !newValue.isEmpty, newValue != draft else { return }
            draft = newValue
            model.draft = ""
        }
    }

    private func consumeExternalDraft() async {
        guard !model.draft.isEmpty else { return }
        draft = model.draft
        model.draft = ""
    }

    private func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        model.submitPrompt(text)
    }

    private func selectTheme(_ name: String) {
        model.setTheme(name)
        draft = ""
    }

    private func insertAtFile(_ path: String) {
        if let at = draft.lastIndex(of: "@") {
            let prefix = String(draft[..<draft.index(after: at)])
            draft = prefix + path
        } else {
            let reference = path.hasPrefix("@") ? path : "@\(path)"
            draft += (draft.isEmpty ? "" : " ") + reference
        }
        model.isPromptFocused = true
    }
}
