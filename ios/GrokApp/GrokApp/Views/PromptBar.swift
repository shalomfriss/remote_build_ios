// Copyright (c) 2026 Pedro Shakour
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// Upstream prompt chrome (`prompt_widget`): input then info line below.
/// Default placeholder `"Build anything"` (prompt_widget/mod.rs).
/// TUI sends via Enter (`ActionId::SendPrompt`). Soft keyboard needs a phone-only
/// `[send]` control — same action, not a chat bubble button.
struct PromptBar: View {
    @Binding var draft: String
    @Binding var isFocused: Bool
    let modelLine: String
    let theme: GrokTheme
    let onSend: () -> Void
    var placeholder: String = "Build anything"

    @FocusState private var fieldFocused: Bool
    private let promptFont = Font.body.monospaced()

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(fieldFocused ? theme.promptBorderActive : theme.promptBorder)
                .frame(height: 1)

            // Single row: ❯ · Build anything · [send] (center-aligned, not baseline-drift).
            HStack(alignment: .center, spacing: 8) {
                Text("❯")
                    .font(promptFont)
                    .foregroundStyle(theme.accentUser)
                    .frame(height: 44)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: focusPrompt)

                TextField(placeholder, text: $draft)
                    .font(promptFont)
                    .foregroundStyle(theme.textPrimary)
                    .tint(theme.running)
                    .textInputAutocapitalization(.sentences)
                    .textFieldStyle(.plain)
                    .lineLimit(1)
                    .focused($fieldFocused)
                    .submitLabel(.send)
                    .onSubmit { sendPrompt() }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("Done", action: dismissKeyboard)
                        }
                    }

                Button(action: sendPrompt) {
                    Text("[send]")
                        .font(.caption.monospaced())
                        .foregroundStyle(canSend ? theme.accentUser : theme.textSecondary.opacity(0.45))
                        .frame(height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(theme.bgTerminal)

            Rectangle()
                .fill(theme.promptBorder)
                .frame(height: 1)
            HStack {
                Text(modelLine.isEmpty ? " " : modelLine)
                    .font(.caption2.monospaced())
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(theme.bgTerminal)
            .contentShape(Rectangle())
            .onTapGesture(perform: focusPrompt)
        }
        .onChange(of: fieldFocused) { _, focused in
            if isFocused != focused {
                isFocused = focused
            }
        }
        .onChange(of: isFocused) { _, focused in
            if fieldFocused != focused {
                fieldFocused = focused
            }
        }
    }

    private func focusPrompt() {
        isFocused = true
        fieldFocused = true
    }

    private func dismissKeyboard() {
        fieldFocused = false
        isFocused = false
    }

    private func sendPrompt() {
        guard canSend else { return }
        dismissKeyboard()
        onSend()
    }
}

#Preview {
    PromptBar(
        draft: .constant(""),
        isFocused: .constant(true),
        modelLine: "grok-build-0.1 · plan",
        theme: .grokNightFallback,
        onSend: {}
    )
}
