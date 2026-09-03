// Copyright (c) 2026 Pedro Shakour
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Maps ACP `session/update` events into scrollback mutations (pager tracker subset).
/// Thinking modes follow `ThinkingBlock` in upstream `scrollback/blocks/thinking.rs`.
@MainActor
final class ScrollbackTracker {
    private(set) var entries: [ScrollbackEntry] = []
    private var streamingAssistantID: UUID?
    private var streamingThoughtID: UUID?
    private var pendingAssistantChunks: [String] = []
    private var pendingThoughtChunks: [String] = []
    private var toolEntries: [String: UUID] = [:]
    private(set) var expandedVerbGroupIDs: Set<UUID> = []
    private var pendingNotificationTask: Task<Void, Never>?

    private static let streamingRefreshInterval = Duration.milliseconds(50)
    private static let maximumToolDetailLength = 12_000

    var onChange: (([ScrollbackEntry]) -> Void)?

    func reset() {
        pendingNotificationTask?.cancel()
        pendingNotificationTask = nil
        entries.removeAll()
        streamingAssistantID = nil
        streamingThoughtID = nil
        pendingAssistantChunks.removeAll(keepingCapacity: true)
        pendingThoughtChunks.removeAll(keepingCapacity: true)
        toolEntries.removeAll()
        expandedVerbGroupIDs.removeAll()
        notify()
    }

    /// Replace a loaded transcript with its final conversational message.
    /// Session history can contain hundreds of tool/thinking updates that should
    /// not be replayed into the compact phone UI.
    func showOnlyLatestMessage(kind: ScrollbackKind?, text: String?) {
        streamingAssistantID = nil
        streamingThoughtID = nil
        pendingAssistantChunks.removeAll(keepingCapacity: true)
        pendingThoughtChunks.removeAll(keepingCapacity: true)
        toolEntries.removeAll()
        expandedVerbGroupIDs.removeAll()

        let message = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let kind, (kind == .user || kind == .assistant), !message.isEmpty {
            entries = [ScrollbackEntry(kind: kind, text: message)]
        } else {
            entries = []
        }
        notify()
    }

    func appendUser(_ text: String) {
        entries.append(ScrollbackEntry(kind: .user, text: text))
        notify()
    }

    func appendSystem(_ text: String) {
        entries.append(ScrollbackEntry(kind: .system, text: text))
        notify()
    }

    func appendError(_ text: String) {
        entries.append(ScrollbackEntry(kind: .error, text: text))
        notify()
    }

    func handleSessionUpdate(_ update: [String: ACPProtocol.JSONValue]) {
        let kind = update["sessionUpdate"]?.stringValue ?? ""
        switch kind {
        case "agent_message_chunk":
            guard let content = update["content"]?.objectValue,
                  let text = content["text"]?.stringValue, !text.isEmpty else { return }
            appendAssistantChunk(text)
        case "agent_thought_chunk":
            guard let content = update["content"]?.objectValue,
                  let text = content["text"]?.stringValue, !text.isEmpty else { return }
            appendThoughtChunk(text)
        case "tool_call":
            finalizeStreaming(notifying: false)
            let toolId = update["toolCallId"]?.stringValue ?? UUID().uuidString
            let title = update["title"]?.stringValue ?? update["kind"]?.stringValue ?? "Tool"
            let toolKind = update["kind"]?.stringValue
            let status = update["status"]?.stringValue ?? "in_progress"
            let input = jsonSnippet(update["rawInput"])
            let entry = ScrollbackEntry(
                kind: .tool,
                text: title,
                isCollapsed: true,
                toolTitle: title,
                toolKind: toolKind,
                toolStatus: status,
                toolDetail: input,
                toolCallId: toolId
            )
            entries.append(entry)
            toolEntries[toolId] = entry.id
            notify()
        case "tool_call_update":
            let toolId = update["toolCallId"]?.stringValue ?? ""
            let status = update["status"]?.stringValue ?? "updated"
            let output = jsonSnippet(update["rawOutput"])
            if let diffTitle = parseEditDiff(from: update) {
                handleEditDiff(title: diffTitle.title, hunks: diffTitle.hunks)
            }
            if let existing = toolEntries[toolId], let idx = entries.firstIndex(where: { $0.id == existing }) {
                var e = entries[idx]
                e.toolStatus = status
                if let title = update["title"]?.stringValue { e.toolTitle = title }
                if let k = update["kind"]?.stringValue { e.toolKind = k }
                if !output.isEmpty {
                    e.toolDetail = Self.appendingToolDetail(output, to: e.toolDetail)
                }
                entries[idx] = e
            } else {
                entries.append(ScrollbackEntry(
                    kind: .tool,
                    text: update["title"]?.stringValue ?? "Tool",
                    isCollapsed: true,
                    toolTitle: update["title"]?.stringValue,
                    toolKind: update["kind"]?.stringValue,
                    toolStatus: status,
                    toolDetail: output,
                    toolCallId: toolId
                ))
            }
            if status == "completed" || status == "failed" {
                finalizeStreaming(notifying: false)
                collapseFinishedThoughts(notifying: false)
            }
            notify(coalescing: status != "completed" && status != "failed")
        case "plan":
            finalizeStreaming(notifying: false)
            // Body only — no invented "plan" / "Plan updated" chrome.
            let planText = planEntriesText(update["entries"])
            guard !planText.isEmpty else { return }
            entries.append(ScrollbackEntry(kind: .plan, text: planText))
            notify()
        default:
            break
        }
    }

    func handleEditDiff(title: String, hunks: [DiffHunk]) {
        finalizeStreaming(notifying: false)
        entries.append(ScrollbackEntry(kind: .diff, text: title, diffHunks: hunks))
        notify()
    }

    private func appendAssistantChunk(_ text: String) {
        if streamingAssistantID != nil {
            pendingAssistantChunks.append(text)
        } else {
            finalizeThought()
            let entry = ScrollbackEntry(kind: .assistant, text: text, isStreaming: true)
            streamingAssistantID = entry.id
            entries.append(entry)
        }
        notify(coalescing: true)
    }

    private func appendThoughtChunk(_ text: String) {
        if streamingThoughtID != nil {
            pendingThoughtChunks.append(text)
        } else {
            finalizeAssistant()
            // streaming() + default_display_mode Truncated while running.
            let entry = ScrollbackEntry(
                kind: .thinking,
                text: text,
                isStreaming: true,
                isCollapsed: false,
                thinkingMode: .truncated,
                thoughtStartedAt: Date.now
            )
            streamingThoughtID = entry.id
            entries.append(entry)
        }
        notify(coalescing: true)
    }

    func finalizeStreaming(notifying: Bool = true) {
        finalizeAssistant()
        finalizeThought()
        if notifying {
            notify()
        }
    }

    private func finalizeAssistant() {
        flushAssistantText()
        guard let id = streamingAssistantID, let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        var e = entries[idx]
        e.isStreaming = false
        entries[idx] = e
        streamingAssistantID = nil
    }

    private func finalizeThought() {
        flushThoughtText()
        guard let id = streamingThoughtID, let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        var e = entries[idx]
        e.isStreaming = false
        // finished_display_mode → Collapsed
        e.isCollapsed = true
        e.thinkingMode = .collapsed
        if e.thoughtElapsedMs == nil, let start = e.thoughtStartedAt {
            e.thoughtElapsedMs = Int64(Date.now.timeIntervalSince(start) * 1000)
        }
        entries[idx] = e
        streamingThoughtID = nil
    }

    func toggleFold(id: UUID) {
        if let entry = entries.first(where: { $0.id == id }), entry.kind == .verbGroup {
            if expandedVerbGroupIDs.contains(id) {
                expandedVerbGroupIDs.remove(id)
            } else {
                expandedVerbGroupIDs.insert(id)
            }
            notify()
            return
        }
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        var e = entries[idx]
        if e.kind == .thinking {
            // thinking.rs next_fold_mode
            if e.isStreaming {
                e.thinkingMode = (e.thinkingMode == .expanded) ? .truncated : .expanded
            } else {
                e.thinkingMode = (e.thinkingMode == .collapsed) ? .expanded : .collapsed
            }
            e.isCollapsed = (e.thinkingMode == .collapsed)
        } else if e.kind == .tool {
            e.isCollapsed.toggle()
        } else {
            return
        }
        entries[idx] = e
        notify()
    }

    func toggleThoughtCollapse(id: UUID) { toggleFold(id: id) }
    func toggleToolCollapse(id: UUID) { toggleFold(id: id) }

    /// Collapse finished thoughts (upstream: thinking → Collapsed on turn end).
    func collapseFinishedThoughts(notifying: Bool = true) {
        for idx in entries.indices where entries[idx].kind == .thinking && !entries[idx].isStreaming {
            entries[idx].isCollapsed = true
            entries[idx].thinkingMode = .collapsed
        }
        if notifying {
            notify()
        }
    }

    private func planEntriesText(_ value: ACPProtocol.JSONValue?) -> String {
        guard let value else { return "" }
        if case .string(let s) = value { return s }
        if case .array(let arr) = value {
            return arr.compactMap { item -> String? in
                guard case .object(let o) = item else { return item.stringValue }
                let content = o["content"]?.stringValue ?? o["text"]?.stringValue
                let status = o["status"]?.stringValue
                if let content, let status { return "[\(status)] \(content)" }
                return content
            }.joined(separator: "\n")
        }
        return jsonSnippet(value)
    }

    private func jsonSnippet(_ value: ACPProtocol.JSONValue?) -> String {
        guard let value else { return "" }
        if case .string(let s) = value { return s }
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(value),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s.count > 400 ? String(s.prefix(400)) + "…" : s
    }

    private func notify(coalescing: Bool = false) {
        if coalescing {
            guard pendingNotificationTask == nil else { return }
            pendingNotificationTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.streamingRefreshInterval)
                guard let self, !Task.isCancelled else { return }
                self.pendingNotificationTask = nil
                self.publishChange()
            }
            return
        }

        pendingNotificationTask?.cancel()
        pendingNotificationTask = nil
        publishChange()
    }

    private func publishChange() {
        flushStreamingText()
        // Consumers need the source entries for title/state derivation. Folding is
        // applied once by AppModel using the active thinking-display preference.
        onChange?(entries)
    }

    private func flushStreamingText() {
        flushAssistantText()
        flushThoughtText()
    }

    private func flushAssistantText() {
        guard !pendingAssistantChunks.isEmpty,
              let id = streamingAssistantID,
              let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].text += pendingAssistantChunks.joined()
        entries[idx].isStreaming = true
        pendingAssistantChunks.removeAll(keepingCapacity: true)
    }

    private func flushThoughtText() {
        guard !pendingThoughtChunks.isEmpty,
              let id = streamingThoughtID,
              let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].text += pendingThoughtChunks.joined()
        entries[idx].isStreaming = true
        if entries[idx].thinkingMode == .collapsed {
            entries[idx].thinkingMode = .truncated
        }
        pendingThoughtChunks.removeAll(keepingCapacity: true)
    }

    private static func appendingToolDetail(_ newDetail: String, to existing: String?) -> String {
        let combined = [existing, newDetail]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        guard combined.count > maximumToolDetailLength else { return combined }

        let retainedSuffix = combined.suffix(maximumToolDetailLength)
        return "… earlier output omitted …\n" + String(retainedSuffix)
    }

    /// Display layer: verb-group fold + thinking visibility.
    func displayEntries(showThinking: Bool = AppSettings.showThinkingBlocks) -> [ScrollbackEntry] {
        var base = entries
        if !showThinking {
            base = base.filter { $0.kind != .thinking }
        }
        return VerbGroupLogic.fold(base, expandedGroupIDs: expandedVerbGroupIDs, showThinking: showThinking).0
    }

    private func parseEditDiff(from update: [String: ACPProtocol.JSONValue]) -> (title: String, hunks: [DiffHunk])? {
        guard let content = update["content"]?.arrayValue ?? update["fields"]?.objectValue?["content"]?.arrayValue else {
            return nil
        }
        var hunks: [DiffHunk] = []
        var path = update["title"]?.stringValue ?? "Edit"
        for item in content {
            guard case .object(let obj) = item else { continue }
            let type = obj["type"]?.stringValue ?? ""
            guard type == "diff" else { continue }
            let filePath = obj["path"]?.stringValue ?? obj["file_path"]?.stringValue ?? path
            path = filePath
            let oldText = obj["oldText"]?.stringValue ?? obj["old_text"]?.stringValue ?? ""
            let newText = obj["newText"]?.stringValue ?? obj["new_text"]?.stringValue ?? ""
            let oldLines = oldText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let newLines = newText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            hunks.append(DiffHunk(oldLines: oldLines, newLines: newLines, path: filePath))
        }
        guard !hunks.isEmpty else { return nil }
        return (path, hunks)
    }
}

struct DiffHunk: Equatable, Identifiable {
    let id = UUID()
    let oldLines: [String]
    let newLines: [String]
    let path: String
}
