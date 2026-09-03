// Copyright (c) 2026 Pedro Shakour
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Network
import SwiftUI
import Combine

@MainActor
final class AppModel: ObservableObject {
    @Published var screen: AppScreen = .welcome
    @Published var messages: [ScrollbackEntry] = []
    @Published var draft: String = ""
    @Published var alwaysApprove: Bool = false {
        didSet {
            acp.alwaysApprove = alwaysApprove
            chrome.alwaysApprove = alwaysApprove
        }
    }
    @Published var themeName: String = "GrokNight" {
        didSet {
            guard themeName != oldValue else { return }
            theme = GrokTheme.load(named: themeName)
        }
    }
    @Published var sessionTitle: String = "loading..."
    @Published var chrome = SessionChrome()
    @Published private(set) var theme = GrokTheme.load(named: "GrokNight")
    @Published var permissionRequest: PermissionRequest?
    @Published var isPromptFocused: Bool = false
    @Published var apiKeyDraft: String = ""
    @Published var acpHostDraft: String = ""
    @Published var acpPortDraft: String = "2419"
    @Published var pairPinDraft: String = ""
    @Published var fingerprintDraft: String = ""
    @Published var setupError: String?
    /// Setup Connect button: idle → checking (spinner) → succeeded / failed.
    @Published var connectionPhase: ConnectionPhase = .idle
    @Published var workspaceFiles: [String] = []
    @Published var fileFilter: String = ""
    @Published var sessionListEntries: [SessionListEntry] = []
    @Published var isLoadingSessions = false
    @Published var sessionListError: String?
    @Published var showTimestamps: Bool = AppSettings.showTimestamps
    @Published var showThinkingBlocks: Bool = AppSettings.showThinkingBlocks
    /// Upstream dashboard roster from `x.ai/sessions/list` (falls back to session/list).
    @Published var dashboardRows: [DashboardRowModel] = []
    /// Shell-owned `[ui]` values from companion `config_get` (Mac ~/.grok/config.toml).
    @Published var shellConfig: [String: Bool] = [:]
    @Published var shellConfigStrings: [String: String] = [:]
    @Published var shellConfigPath: String = ""
    @Published var mermaidRenderError: String?
    /// Shown in agent chrome when transport drops and reconnect is in progress.
    @Published var reconnectBanner: String?
    @Published var simulatorURL: URL?
    @Published var simulatorBuildStatus: String?
    @Published var simulatorBuildError: String?
    @Published private(set) var isSimulatorRunPending = false
    @Published var isNamingProject = false
    @Published var projectNameDraft = ""
    @Published private(set) var savedEntryPoints: [CompanionConfig.EntryPoint] = []
    @Published private(set) var isManuallyDisconnected = false

    @Published private(set) var acp = ACPClient()
    let companionBrowser = CompanionBrowser()
    private var acpBagForward: AnyCancellable?
    private var browserBagForward: AnyCancellable?
    private var isReconnecting = false
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttemptID: UUID?
    private var resumeTask: Task<Void, Never>?
    private var activeResumeAttempt: UUID?
    private var manuallyDisconnectedSessionID: String?
    private var activeProjectID: String?
    private var projectClients: [String: ACPClient] = [:]
    private var projectNames: [String: String] = [:]
    private var projectCwds: [String: String] = [:]
    private var persistedWelcomeCwd: String?
    private var persistedWelcomeGitBranch: String?
    private var persistedWelcomeIsWorktree: Bool?
    private var simulatorStatusByProject: [String: String] = [:]
    private var simulatorErrorByProject: [String: String] = [:]
    private var simulatorOutputByProject: [String: String] = [:]
    private var simulatorGenerationByProject: [String: Int] = [:]
    private var simulatorPendingProjects: Set<String> = []
    private var simulatorRepairAttemptsByProject: [String: Int] = [:]

    private static let maximumSimulatorRepairAttempts = 3
    private static let maximumSimulatorRepairLogLength = 12_000

    var hasAPIKey: Bool { KeychainHelper.hasAPIKey }

    /// Provider-neutral ACP bridge endpoint and pairing PIN.
    var canStartSession: Bool {
        if preferredBonjourEndpoint != nil {
            return CompanionConfig.hasSavedSecret
        }
        return CompanionConfig.hasHost && CompanionConfig.hasSavedSecret
    }

    var hasChangelog: Bool {
        Bundle.main.url(forResource: "0.2.99", withExtension: "md", subdirectory: "changelogs") != nil
            || Bundle.main.url(forResource: "0.2.99", withExtension: "md") != nil
    }

    var changelogTitle: String {
        guard let text = loadChangelogText() else { return "Changelog" }
        for line in text.split(separator: "\n") {
            let s = String(line).trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("# ") {
                return String(s.dropFirst(2))
            }
        }
        return "Changelog"
    }

    var changelogBody: String {
        loadChangelogText() ?? ""
    }

    private func loadChangelogText() -> String? {
        let url = Bundle.main.url(forResource: "0.2.99", withExtension: "md", subdirectory: "changelogs")
            ?? Bundle.main.url(forResource: "0.2.99", withExtension: "md")
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    var availableThemes: [String] {
        GrokTheme.availableThemeNames().filter { $0.lowercased() != "auto" }
    }

    var isThemeDraft: Bool {
        let d = draft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return d == "/theme" || d.hasPrefix("/theme ") || d == "/t" || d.hasPrefix("/t ")
    }

    var atFileQuery: String? {
        guard let at = draft.lastIndex(of: "@") else { return nil }
        let fragment = String(draft[draft.index(after: at)...])
        if fragment.contains(" ") || fragment.contains("\n") { return nil }
        return fragment
    }

    var filteredAtFiles: [String] {
        guard let query = atFileQuery?.lowercased() else { return workspaceFiles }
        if query.isEmpty { return workspaceFiles }
        return workspaceFiles
            .filter { $0.lowercased().contains(query) }
            .sorted { a, b in
                let al = a.lowercased(), bl = b.lowercased()
                let ap = al.hasPrefix(query), bp = bl.hasPrefix(query)
                if ap != bp { return ap }
                return al < bl
            }
    }

    @Published private(set) var preferredBonjourEndpoint: NWEndpoint?

    init() {
        // Never honor leftover smoke UserDefaults — wipe if present (polluted sims).
        UserDefaults.standard.removeObject(forKey: "GROK_LIVE_SMOKE_PROMPT")
        UserDefaults.standard.removeObject(forKey: "GROK_LIVE_SMOKE_AUTO_AGENT")

        loadConnectionDrafts()
        wireACP()
        // Always land on Welcome (official pager). Setup is opened from the welcome menu.
        screen = .welcome
    }

    func loadConnectionDrafts() {
        apiKeyDraft = KeychainHelper.loadAPIKey() ?? ""
        let ep = CompanionConfig.resolved()
        acpHostDraft = ep.useWebSocket
            ? "\(ep.useTLS ? "wss" : "ws")://\(ep.host)/acp"
            : ep.host
        acpPortDraft = String(ep.port)
        pairPinDraft = CompanionConfig.savedPIN
        fingerprintDraft = CompanionConfig.pinnedFingerprint
        savedEntryPoints = CompanionConfig.savedEntryPoints
    }

    private func wireACP(_ client: ACPClient? = nil) {
        let client = client ?? acp
        // Forward ACPClient publishes so AgentStatusBar connection dot refreshes.
        acpBagForward = client.objectWillChange.sink { [weak self, weak client] _ in
            guard let self, let client, self.acp === client else { return }
            self.objectWillChange.send()
        }
        browserBagForward = companionBrowser.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        client.alwaysApprove = alwaysApprove
        client.onModelChanged = { [weak self, weak client] modelId in
            guard let self, let client, self.acp === client else { return }
            self.chrome.modelId = modelId
        }
        client.onChromeChanged = { [weak self, weak client] chrome in
            guard let self, let client, self.acp === client else { return }
            var c = chrome
            c.alwaysApprove = self.alwaysApprove
            if self.chrome != c {
                self.chrome = c
            }
            if self.persistedWelcomeCwd != c.cwd
                || self.persistedWelcomeGitBranch != c.gitBranch
                || self.persistedWelcomeIsWorktree != c.isWorktree {
                CompanionConfig.persistWelcomeLocation(
                    cwd: c.cwd,
                    gitBranch: c.gitBranch,
                    isWorktree: c.isWorktree
                )
                self.persistedWelcomeCwd = c.cwd
                self.persistedWelcomeGitBranch = c.gitBranch
                self.persistedWelcomeIsWorktree = c.isWorktree
            }
            if c.sessionId != nil, self.sessionTitle == "loading..." || self.sessionTitle.hasPrefix("session ") {
                self.sessionTitle = c.loadingTitle
            }
        }
        client.onPermissionRequest = { [weak self, weak client] request in
            guard let self, let client, self.acp === client else { return }
            self.permissionRequest = request
        }
        client.onRosterChanged = { [weak self, weak client] entries in
            guard let self, let client, self.acp === client else { return }
            if self.screen == .dashboard {
                self.refreshDashboardActivity()
            }
        }
        client.onTransportLost = { [weak self, weak client] in
            guard let self, let client, self.acp === client else { return }
            self.handleTransportLost()
        }
        client.tracker.onChange = { [weak self, weak client] entries in
            guard let self, let client, self.acp === client else { return }
            self.messages = client.tracker.displayEntries(showThinking: self.showThinkingBlocks)
            self.refreshSessionTitle(from: entries)
        }
    }

    /// Upstream session title: first user prompt → `session {8}` → `loading...`
    private func refreshSessionTitle(from entries: [ScrollbackEntry]) {
        if let firstUser = entries.first(where: { $0.kind == .user })?.text
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !firstUser.isEmpty {
            let truncated = firstUser.count > 60 ? String(firstUser.prefix(57)) + "…" : firstUser
            sessionTitle = truncated
            return
        }
        if let sid = acp.sessionId, !sid.isEmpty {
            sessionTitle = "session \(sid.prefix(8))"
            return
        }
        sessionTitle = "loading..."
    }

    func showWelcome() {
        companionBrowser.stop()
        screen = .welcome
    }

    func showDashboard() {
        screen = .dashboard
        Task { await reloadDashboardFromSessionList() }
    }

    func startNewSessionFromDashboard() {
        // Ask for the project name before dispatching a new agent.
        requestNewProject()
    }

    func openDashboardRow(_ row: DashboardRowModel) {
        if let sid = row.sessionId, !sid.isEmpty {
            if let client = projectClients[sid] {
                activateProjectClient(client, projectID: sid)
                screen = .agent
                reconnectBanner = client.sessionReady ? nil : client.lastError
                Task { await refreshSimulatorURL() }
            } else {
                resumeSession(
                    id: sid,
                    cwd: projectCwds[sid],
                    projectName: row.title
                )
            }
        } else {
            showAgent()
        }
    }

    func reloadDashboardFromSessionList() async {
        guard canStartSession else {
            dashboardRows = []
            return
        }
        if !acp.isConnected {
            acp.connect()
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        let entries = await acp.listSessions()
        sessionListEntries = entries
        dashboardRows = entries.map { e in
            let title: String
            if !e.title.isEmpty {
                title = e.title
            } else if !e.cwd.isEmpty {
                title = e.cwd
            } else {
                title = e.id
            }
            return DashboardRowModel(
                sessionId: e.id,
                title: title,
                state: .idle,
                activity: nil,
                ageLabel: nil
            )
        }
        refreshDashboardActivity()
    }

    func refreshDashboardActivity() {
        var rowsBySession = Dictionary(
            uniqueKeysWithValues: dashboardRows.compactMap { row in
                row.sessionId.map { ($0, row) }
            }
        )
        for (projectID, client) in projectClients {
            let state: DashboardRowModel.State
            let activity: String?
            if client.isRunning {
                state = .working
                activity = client.chrome.turnActivity ?? "working"
            } else if client.sessionReady {
                state = .idle
                activity = "ready"
            } else {
                state = .needsInput
                activity = client.lastError ?? "reconnecting"
            }
            let title = projectNames[projectID]
                ?? projectCwds[projectID].map { URL(fileURLWithPath: $0).lastPathComponent }
                ?? "Project"
            rowsBySession[projectID] = DashboardRowModel(
                sessionId: projectID,
                title: title,
                state: state,
                activity: activity,
                ageLabel: nil
            )
        }
        let catalogOrder = sessionListEntries.map(\.id)
        let remaining = rowsBySession.keys.filter { !catalogOrder.contains($0) }.sorted()
        dashboardRows = (catalogOrder + remaining).compactMap { rowsBySession[$0] }
    }

    private func applyRosterToDashboard(_ roster: [RosterSessionEntry]) {
        dashboardRows = roster.map { e in
            DashboardRowModel(
                sessionId: e.id,
                title: e.displayTitle,
                state: e.dashboardState,
                activity: e.activity == .working ? "working" : (e.activity == .needsInput ? "awaiting" : nil),
                ageLabel: e.ageLabel
            )
        }
    }

    func renderMermaidPNG(source: String) async -> Data? {
        mermaidRenderError = nil
        do {
            if !acp.isConnected {
                acp.connect()
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
            return try await acp.renderMermaid(source: source, themeDark: theme.isDark)
        } catch {
            mermaidRenderError = error.localizedDescription
            return nil
        }
    }

    func reloadShellConfig() async {
        guard acp.isPaired || acp.isConnected else { return }
        let values = await acp.fetchShellConfig()
        var bools: [String: Bool] = [:]
        var strings: [String: String] = [:]
        for (k, v) in values {
            if let b = v.boolValue {
                bools[k] = b
            } else if let s = v.stringValue {
                strings[k] = s
            }
        }
        shellConfig = bools
        shellConfigStrings = strings
    }

    func setShellBool(_ key: String, _ value: Bool) async {
        do {
            let updated = try await acp.setShellConfig([key: .bool(value)])
            if let b = updated[key]?.boolValue {
                shellConfig[key] = b
            } else {
                shellConfig[key] = value
            }
            if key == "show_thinking_blocks" {
                showThinkingBlocks = value
                AppSettings.showThinkingBlocks = value
                refreshDisplayedMessages()
            }
            if key == "show_timestamps" {
                showTimestamps = value
                AppSettings.showTimestamps = value
            }
        } catch {
            setupError = error.localizedDescription
        }
    }

    func setShellString(_ key: String, _ value: String) async {
        do {
            let updated = try await acp.setShellConfig([key: .string(value)])
            if let s = updated[key]?.stringValue {
                shellConfigStrings[key] = s
            } else {
                shellConfigStrings[key] = value
            }
        } catch {
            setupError = error.localizedDescription
        }
    }

    func showOnboarding() {
        loadConnectionDrafts()
        setupError = nil
        screen = .onboarding
    }

    func showSettings() {
        screen = .pagerSettings
        Task { await reloadShellConfig() }
    }

    func showCompanionSettings() {
        loadConnectionDrafts()
        setupError = nil
        screen = .settings
    }

    func startLegacyBonjourBrowse() {
        companionBrowser.start()
    }

    func stopLegacyBonjourBrowse() {
        companionBrowser.stop()
    }

    /// Reconnect after background / Wi‑Fi blip — preserves session when possible.
    /// When `reloadSession` is true, replace a socket that may have been suspended by
    /// iOS and reload the server-side session so updates received while backgrounded
    /// are reflected immediately.
    func reconnectTransportIfNeeded(reloadSession: Bool = false) {
        guard !isManuallyDisconnected else { return }
        guard canStartSession else { return }
        guard screen == .agent || screen == .dashboard else { return }
        let resumeId = manuallyDisconnectedSessionID ?? acp.sessionId
        guard !acp.sessionReady || (reloadSession && resumeId?.isEmpty == false) else {
            reconnectBanner = nil
            Task { simulatorURL = await acp.fetchSimulatorURL() }
            return
        }
        if isReconnecting {
            guard reloadSession else { return }
            // A reconnect started before suspension cannot prove it replayed all
            // server updates. Replace it with the foreground session reload.
            reconnectTask?.cancel()
        }
        isReconnecting = true
        reconnectBanner = "Reconnecting…"
        reconnectTask?.cancel()
        let reconnectAttemptID = UUID()
        self.reconnectAttemptID = reconnectAttemptID
        acp.reconnect(
            preserveSessionId: resumeId,
            cwd: chrome.cwd,
            showLatestMessage: reloadSession
        )
        reconnectTask = Task { @MainActor in
            defer {
                if self.reconnectAttemptID == reconnectAttemptID {
                    self.isReconnecting = false
                    self.reconnectTask = nil
                    self.reconnectAttemptID = nil
                }
            }
            var deadline = Date.now.addingTimeInterval(20)
            var triedRemoteFallback = false
            while Date.now < deadline {
                guard !Task.isCancelled, !self.isManuallyDisconnected else { return }
                if self.acp.sessionReady {
                    self.manuallyDisconnectedSessionID = nil
                    self.simulatorURL = await self.acp.fetchSimulatorURL()
                    self.reconnectBanner = nil
                    return
                }
                if let err = self.acp.lastError, !err.isEmpty {
                    if !triedRemoteFallback,
                       self.preferredBonjourEndpoint != nil,
                       CompanionConfig.hasRemoteEndpoint {
                        triedRemoteFallback = true
                        self.clearBonjourPreference()
                        self.reconnectBanner = "Switching to remote connection…"
                        self.acp.reconnect(
                            preserveSessionId: resumeId,
                            cwd: self.chrome.cwd,
                            showLatestMessage: reloadSession
                        )
                        deadline = Date.now.addingTimeInterval(20)
                        continue
                    }
                    self.reconnectBanner = err
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            self.reconnectBanner = "Could not reconnect — open Setup"
        }
    }

    private func handleTransportLost() {
        guard !isManuallyDisconnected else { return }
        guard screen == .agent || screen == .dashboard else { return }
        simulatorURL = nil
        reconnectBanner = "Disconnected — reconnecting…"
        // Resume owns its reconnect target and retry budget. Starting the generic
        // reconnect loop here would race it and can cancel the selected project load.
        guard activeResumeAttempt == nil else { return }
        reconnectTransportIfNeeded()
    }

    func refreshDisplayedMessages() {
        messages = acp.tracker.displayEntries(showThinking: showThinkingBlocks)
    }

    func showThemePicker() {
        screen = .themePicker
    }

    func showSessionPicker() {
        guard canStartSession else { showOnboarding(); return }
        screen = .sessionPicker
    }

    func showChangelog() {
        screen = .changelog
    }

    func refreshSessionList() async {
        isLoadingSessions = true
        sessionListError = nil
        defer { isLoadingSessions = false }
        if !acp.sessionReady {
            acp.connect()
            let deadline = Date.now.addingTimeInterval(15)
            while Date.now < deadline, !acp.sessionReady {
                if Task.isCancelled { return }
                if let error = acp.lastError, !error.isEmpty {
                    sessionListError = error
                    sessionListEntries = []
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        guard acp.sessionReady else {
            sessionListError = "Timed out connecting to the agent"
            sessionListEntries = []
            return
        }
        sessionListEntries = await acp.listSessions()
    }

    func resumeSession(
        id: String,
        cwd: String? = nil,
        projectName: String? = nil
    ) {
        guard canStartSession else { showOnboarding(); return }
        if let existing = projectClients[id],
           existing.isConnected || existing.sessionReady || existing.isRunning {
            activateProjectClient(existing, projectID: id)
            screen = .agent
            reconnectBanner = nil
            Task { await refreshSimulatorURL() }
            return
        }
        resumeTask?.cancel()
        let attemptID = UUID()
        activeResumeAttempt = attemptID
        if let existing = projectClients[id] {
            existing.disconnect()
        }
        let client = ACPClient()
        projectClients[id] = client
        if let cwd, !cwd.isEmpty {
            projectCwds[id] = cwd
        }
        if let projectName, !projectName.isEmpty {
            projectNames[id] = projectName
        }
        activateProjectClient(client, projectID: id)
        screen = .agent
        if let preferredBonjourEndpoint {
            client.setPreferredEndpoint(preferredBonjourEndpoint)
        } else {
            client.setPreferredEndpoint(nil)
        }
        let resumeDisplayName = projectName ?? "project"
        reconnectBanner = "Starting \(resumeDisplayName) from scratch…"
        resumeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.activeResumeAttempt == attemptID {
                    self.activeResumeAttempt = nil
                }
            }

            await self.reconnectAndResumeSession(id: id, cwd: cwd)
        }
    }

    private func activateProjectClient(_ client: ACPClient, projectID: String) {
        if activeProjectID == nil, acp !== client {
            acp.disconnect()
        }
        activeProjectID = projectID
        acp = client
        wireACP(client)
        client.alwaysApprove = alwaysApprove
        chrome = client.chrome
        messages = client.tracker.displayEntries(showThinking: showThinkingBlocks)
        permissionRequest = nil
        simulatorURL = nil
        simulatorBuildStatus = simulatorStatusByProject[projectID]
        simulatorBuildError = simulatorErrorByProject[projectID]
        isSimulatorRunPending = simulatorPendingProjects.contains(projectID)
        sessionTitle = projectNames[projectID] ?? "loading..."
        refreshSessionTitle(from: messages)
    }

    private func reconnectAndResumeSession(id: String, cwd: String?) async {
        var switchedToRemoteEndpoint = preferredBonjourEndpoint == nil

        for attempt in 1...3 {
            guard !Task.isCancelled else { return }
            if attempt > 1 {
                reconnectBanner = "Retrying connection (\(attempt)/3)…"
                try? await Task.sleep(for: .milliseconds(500 * attempt))
            }

            acp.reconnect(
                preserveSessionId: id,
                cwd: cwd,
                showLatestMessage: true
            )
            let deadline = Date.now.addingTimeInterval(25)
            while Date.now < deadline {
                guard !Task.isCancelled else { return }
                if acp.sessionReady,
                   acp.sessionId == id || id.hasPrefix("grok-project:") {
                    simulatorURL = await acp.fetchSimulatorURL()
                    reconnectBanner = nil
                    return
                }
                if acp.lastError?.isEmpty == false {
                    break
                }
                try? await Task.sleep(for: .milliseconds(250))
            }

            if !switchedToRemoteEndpoint,
               preferredBonjourEndpoint != nil,
               CompanionConfig.hasRemoteEndpoint {
                switchedToRemoteEndpoint = true
                clearBonjourPreference()
                reconnectBanner = "Switching to remote connection…"
            }
        }

        let message = acp.lastError ?? "Could not reconnect to companion"
        reconnectBanner = "Resume failed: \(message)"
        acp.tracker.appendError(message)
    }

    func showFilePicker() {
        fileFilter = ""
        screen = .filePicker
        Task { await refreshWorkspaceFiles() }
    }

    func selectBonjourPeer(_ peer: CompanionPeer) {
        preferredBonjourEndpoint = peer.endpoint
        acp.setPreferredEndpoint(peer.endpoint)
        if let endpoint = peer.remoteEndpoint,
           let remote = CompanionConfig.parseRemoteAddress(endpoint) {
            CompanionConfig.save(
                host: remote.host,
                port: remote.port,
                useTLS: remote.useTLS,
                useWebSocket: remote.useWebSocket
            )
        }
        if let fp = peer.fingerprint, !fp.isEmpty {
            fingerprintDraft = fp
        }
        // Bonjour is only an in-memory preference. Preserve a public endpoint
        // so reconnect can fail over when the phone leaves Wi-Fi.
        acpHostDraft = peer.name
        setupError = nil
        connectionPhase = .idle
    }

    func selectBonjourPeerIfAppropriate(from peers: [CompanionPeer]) {
        guard preferredBonjourEndpoint == nil, let peer = peers.first else { return }
        let host = acpHostDraft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard host.isEmpty || host == "127.0.0.1" || host == "localhost" else { return }
        selectBonjourPeer(peer)
    }

    /// Connect to the provider-neutral ACP bridge with its six-digit pairing PIN.
    func connectWithPINAndVerify() {
        isManuallyDisconnected = false
        let secret = pairPinDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard secret.count >= 4 else {
            let msg = "Paste the PIN printed by `agent-phone`."
            setupError = msg
            connectionPhase = .failed(msg)
            return
        }

        if let remote = CompanionConfig.parseRemoteAddress(acpHostDraft) {
            preferredBonjourEndpoint = nil
            acp.setPreferredEndpoint(nil)
            acpHostDraft = remote.host
            acpPortDraft = String(remote.port)
            CompanionConfig.save(
                host: remote.host,
                port: remote.port,
                useTLS: remote.useTLS,
                useWebSocket: remote.useWebSocket
            )
        } else if preferredBonjourEndpoint == nil {
            preferredBonjourEndpoint = nil
            acp.setPreferredEndpoint(nil)
            if acpHostDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                acpHostDraft = "127.0.0.1"
            }
            if acpPortDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                acpPortDraft = String(CompanionConfig.defaultPort)
            }
            let port = Int(acpPortDraft) ?? CompanionConfig.defaultPort
            let host = acpHostDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            CompanionConfig.save(host: host, port: port, useTLS: true, useWebSocket: false)
        }

        let optionalFP = fingerprintDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        CompanionConfig.savePairing(pin: secret, fingerprint: optionalFP, token: nil)
        setupError = nil
        Task { await verifyCompanionConnection() }
    }

    /// After a successful probe, open the project restored by the ACP handshake.
    func finishSetupAfterSuccessfulConnect() {
        guard case .succeeded = connectionPhase else { return }
        CompanionConfig.isOnboarded = true
        companionBrowser.stop()
        // Keep the restored ACP session alive; showAgent reuses it.
        connectionPhase = .succeeded
        showAgent()
    }

    private func verifyCompanionConnection(allowBonjourFallback: Bool = true) async {
        var setupRetriesRemaining = 2
        var deadline = Date.now.addingTimeInterval(30)
        connectionPhase = .checking
        setupError = nil
        acp.disconnect()
        acp.tracker.reset()
        if let preferredBonjourEndpoint {
            acp.setPreferredEndpoint(preferredBonjourEndpoint)
        }
        acp.connect()

        while Date.now < deadline {
            if Task.isCancelled || isManuallyDisconnected { return }
            if let err = acp.lastError, !err.isEmpty {
                if setupRetriesRemaining > 0, isRecoverableSetupDisconnect(err) {
                    setupRetriesRemaining -= 1
                    setupError = "Agent restarted during setup. Reconnecting…"
                    acp.disconnect()
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled, !isManuallyDisconnected else { return }
                    if let preferredBonjourEndpoint {
                        acp.setPreferredEndpoint(preferredBonjourEndpoint)
                    }
                    acp.connect()
                    deadline = Date.now.addingTimeInterval(30)
                    continue
                }
                if await retryWithRemoteCompanion() {
                    return
                }
                if allowBonjourFallback, await retryWithDiscoveredCompanion(after: err) {
                    return
                }
                connectionPhase = .failed(err)
                setupError = err
                acp.disconnect()
                return
            }
            if acp.sessionReady, acp.sessionId != nil {
                manuallyDisconnectedSessionID = nil
                simulatorURL = await acp.fetchSimulatorURL()
                connectionPhase = .succeeded
                setupError = nil
                let pinned = CompanionConfig.pinnedFingerprint
                if !pinned.isEmpty {
                    fingerprintDraft = pinned
                }
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        let msg = acp.lastError
            ?? "Could not reach agent — is `agent-phone` running?"
        if await retryWithRemoteCompanion() {
            return
        }
        if allowBonjourFallback, await retryWithDiscoveredCompanion(after: msg) {
            return
        }
        connectionPhase = .failed(msg)
        setupError = msg
        acp.disconnect()
    }

    private func isRecoverableSetupDisconnect(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("closed the connection during setup")
            || normalized.contains("agent connection closed")
    }

    private func retryWithRemoteCompanion() async -> Bool {
        guard preferredBonjourEndpoint != nil,
              CompanionConfig.hasRemoteEndpoint else {
            return false
        }
        clearBonjourPreference()
        connectionPhase = .checking
        setupError = "LAN connection unavailable. Trying the remote endpoint…"
        await verifyCompanionConnection(allowBonjourFallback: false)
        return true
    }

    private func retryWithDiscoveredCompanion(after error: String) async -> Bool {
        guard error.localizedCaseInsensitiveContains("could not reach"),
              preferredBonjourEndpoint == nil,
              let peer = companionBrowser.peers.first else {
            return false
        }
        acp.disconnect()
        selectBonjourPeer(peer)
        let pin = pairPinDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let fingerprint = fingerprintDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        CompanionConfig.savePairing(pin: pin, fingerprint: fingerprint, token: nil)
        await verifyCompanionConnection(allowBonjourFallback: false)
        return true
    }

    func clearBonjourPreference() {
        preferredBonjourEndpoint = nil
        acp.setPreferredEndpoint(nil)
    }

    func saveAPIKeyOnly() -> Bool {
        let trimmed = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            setupError = "Paste your xAI API key from console.x.ai"
            return false
        }
        do {
            try KeychainHelper.saveAPIKey(trimmed)
            setupError = nil
            return true
        } catch {
            setupError = error.localizedDescription
            return false
        }
    }

    func saveManualCompanion() {
        if let remote = CompanionConfig.parseRemoteAddress(acpHostDraft) {
            acpHostDraft = remote.useWebSocket
                ? "\(remote.useTLS ? "wss" : "ws")://\(remote.host)/acp"
                : remote.host
            acpPortDraft = String(remote.port)
            CompanionConfig.save(
                host: remote.host,
                port: remote.port,
                useTLS: remote.useTLS,
                useWebSocket: remote.useWebSocket
            )
            preferredBonjourEndpoint = nil
            acp.setPreferredEndpoint(nil)
            return
        }
        let port = Int(acpPortDraft.trimmingCharacters(in: .whitespacesAndNewlines))
            ?? CompanionConfig.defaultPort
        let host = acpHostDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        CompanionConfig.save(host: host, port: port, useTLS: true, useWebSocket: false)
        preferredBonjourEndpoint = nil
        acp.setPreferredEndpoint(nil)
    }

    func saveCurrentEntryPoint() {
        saveManualCompanion()
        CompanionConfig.saveEntryPoint(endpoint: CompanionConfig.resolved())
        savedEntryPoints = CompanionConfig.savedEntryPoints
    }

    func useEntryPoint(_ entryPoint: CompanionConfig.EntryPoint) {
        manuallyDisconnectedSessionID = acp.sessionId
        acp.disconnect()
        clearBonjourPreference()
        CompanionConfig.save(
            host: entryPoint.host,
            port: entryPoint.port,
            useTLS: entryPoint.useTLS,
            useWebSocket: entryPoint.useWebSocket
        )
        acpHostDraft = entryPoint.address
        acpPortDraft = String(entryPoint.port)
        connectionPhase = .idle
        setupError = nil
        isManuallyDisconnected = true
    }

    func deleteEntryPoint(_ entryPoint: CompanionConfig.EntryPoint) {
        CompanionConfig.deleteEntryPoint(id: entryPoint.id)
        savedEntryPoints = CompanionConfig.savedEntryPoints
    }

    func disconnectFromCompanion() {
        manuallyDisconnectedSessionID = acp.sessionId
        isManuallyDisconnected = true
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttemptID = nil
        resumeTask?.cancel()
        resumeTask = nil
        activeResumeAttempt = nil
        isReconnecting = false
        reconnectBanner = "Disconnected"
        simulatorURL = nil
        connectionPhase = .idle
        acp.disconnect()
    }

    func reconnectToCompanion() {
        guard isManuallyDisconnected || !acp.sessionReady else { return }
        isManuallyDisconnected = false
        reconnectBanner = nil
        if screen == .onboarding || screen == .settings {
            connectWithPINAndVerify()
        } else {
            reconnectTransportIfNeeded()
        }
    }

    func savePairing() {
        CompanionConfig.savePairing(
            pin: pairPinDraft.trimmingCharacters(in: .whitespacesAndNewlines),
            fingerprint: fingerprintDraft.trimmingCharacters(in: .whitespacesAndNewlines),
            token: CompanionConfig.pairToken
        )
    }

    func completeSetupAndStart() {
        connectWithPINAndVerify()
    }

    func showAgent() {
        guard canStartSession else {
            setupError = "Connect a companion first."
            showOnboarding()
            return
        }
        screen = .agent
        // Reuse live ACP session — tearing down caused red dot + hung prompts.
        if acp.sessionReady {
            Task { simulatorURL = await acp.fetchSimulatorURL() }
            return
        }
        acp.disconnect()
        acp.tracker.reset()
        if let preferredBonjourEndpoint {
            acp.setPreferredEndpoint(preferredBonjourEndpoint)
        } else {
            acp.setPreferredEndpoint(nil)
        }
        acp.connect()
        Task {
            while !acp.sessionReady && acp.lastError == nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            simulatorURL = await acp.fetchSimulatorURL()
        }
    }

    func refreshSimulatorURL() async {
        let client = acp
        let activeID = activeProjectID
        let projectID = activeID ?? "active-project"
        let info = await client.fetchSimulatorInfo()
        applySimulatorInfo(info, client: client, projectID: projectID)
        guard acp === client, activeProjectID == activeID else { return }
        simulatorURL = info.url
    }

    func monitorSimulator() async {
        while !Task.isCancelled {
            await refreshSimulatorURL()
            try? await Task.sleep(for: .seconds(1))
        }
    }

    var canRunCurrentProject: Bool {
        acp.sessionReady
            && !acp.isRunning
            && !isSimulatorRunInProgress
    }

    var isSimulatorRunInProgress: Bool {
        isSimulatorRunPending
            || simulatorBuildStatus == "queued"
            || simulatorBuildStatus == "building"
            || simulatorBuildStatus == "repairing"
    }

    func runCurrentProject() {
        guard canRunCurrentProject else { return }
        let client = acp
        let projectID = activeProjectID ?? "active-project"
        client.tracker.appendUser("run the project")
        simulatorPendingProjects.insert(projectID)
        isSimulatorRunPending = true
        simulatorBuildStatus = "queued"
        simulatorBuildError = nil
        simulatorStatusByProject[projectID] = "queued"
        simulatorErrorByProject[projectID] = nil
        simulatorOutputByProject[projectID] = ""
        simulatorGenerationByProject[projectID] = nil
        simulatorRepairAttemptsByProject[projectID] = 0
        client.tracker.appendSystem("[ios-build] Build queued")
        Task { @MainActor [weak self] in
            guard let self else { return }
            let minimumIndicatorEnd = ContinuousClock.now.advanced(by: .seconds(1))
            do {
                try await client.runSimulatorApp()
                await self.ensureSimulatorBuildSucceeds(client: client, projectID: projectID)
            } catch {
                self.simulatorStatusByProject[projectID] = "failed"
                self.simulatorErrorByProject[projectID] = error.localizedDescription
                if self.activeProjectID == projectID, self.acp === client {
                    self.simulatorBuildStatus = "failed"
                    self.simulatorBuildError = error.localizedDescription
                }
                client.tracker.appendError(error.localizedDescription)
            }
            let remaining = ContinuousClock.now.duration(to: minimumIndicatorEnd)
            if remaining > .zero {
                try? await Task.sleep(for: remaining)
            }
            self.simulatorPendingProjects.remove(projectID)
            if self.activeProjectID == projectID, self.acp === client {
                self.isSimulatorRunPending = false
            }
        }
    }

    private func ensureSimulatorBuildSucceeds(client: ACPClient, projectID: String) async {
        var generationToReplace: Int?

        while !Task.isCancelled {
            guard let info = await waitForSimulatorBuild(
                client: client,
                projectID: projectID,
                afterGeneration: generationToReplace
            ) else {
                return
            }
            guard info.status == "failed" else {
                simulatorRepairAttemptsByProject[projectID] = nil
                return
            }

            let repairAttempts = simulatorRepairAttemptsByProject[projectID] ?? 0
            guard Self.isSimulatorCompileFailure(info),
                  repairAttempts < Self.maximumSimulatorRepairAttempts,
                  let failedGeneration = info.generation else {
                return
            }

            let nextAttempt = repairAttempts + 1
            simulatorRepairAttemptsByProject[projectID] = nextAttempt
            simulatorStatusByProject[projectID] = "repairing"
            if activeProjectID == projectID || (activeProjectID == nil && projectID == "active-project"),
               acp === client {
                simulatorBuildStatus = "repairing"
            }
            client.tracker.appendSystem(
                "[ios-build] Compile failed. Asking the agent to repair the project "
                    + "(attempt \(nextAttempt)/\(Self.maximumSimulatorRepairAttempts))."
            )
            client.sendPrompt(Self.simulatorRepairPrompt(for: info))

            guard await waitForAgentTurnToFinish(client) else {
                setSimulatorFailure(
                    "The automatic build repair timed out.",
                    client: client,
                    projectID: projectID
                )
                return
            }
            generationToReplace = failedGeneration
        }
    }

    private func waitForAgentTurnToFinish(_ client: ACPClient) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(600))
        while !Task.isCancelled, ContinuousClock.now < deadline {
            if !client.isRunning {
                return true
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    private func waitForSimulatorBuild(
        client: ACPClient,
        projectID: String,
        afterGeneration: Int?
    ) async -> SimulatorBuildInfo? {
        let deadline = ContinuousClock.now.advanced(by: .seconds(300))
        repeat {
            let info = await client.fetchSimulatorInfo()
            applySimulatorInfo(info, client: client, projectID: projectID)
            let isNewGeneration: Bool
            if let afterGeneration {
                isNewGeneration = info.generation.map { $0 > afterGeneration } ?? false
            } else {
                isNewGeneration = true
            }
            if isNewGeneration, info.status == "ready" || info.status == "failed" {
                return info
            }
            try? await Task.sleep(for: .milliseconds(500))
        } while !Task.isCancelled && ContinuousClock.now < deadline

        let lastStatus = simulatorStatusByProject[projectID]
        guard lastStatus == "queued" || lastStatus == "building" || lastStatus == "repairing" else {
            return nil
        }
        let timeoutError = "The simulator build timed out. Check the companion output."
        setSimulatorFailure(timeoutError, client: client, projectID: projectID)
        return nil
    }

    private func setSimulatorFailure(
        _ error: String,
        client: ACPClient,
        projectID: String
    ) {
        simulatorStatusByProject[projectID] = "failed"
        simulatorErrorByProject[projectID] = error
        if activeProjectID == projectID || (activeProjectID == nil && projectID == "active-project"),
           acp === client {
            simulatorBuildStatus = "failed"
            simulatorBuildError = error
        }
        client.tracker.appendError(error)
    }

    static func isSimulatorCompileFailure(_ info: SimulatorBuildInfo) -> Bool {
        guard info.status == "failed", let error = info.error else { return false }
        return error.localizedCaseInsensitiveContains("iOS Simulator build failed")
            || error.localizedCaseInsensitiveContains("exit 65")
    }

    static func simulatorRepairPrompt(for info: SimulatorBuildInfo) -> String {
        let output = String(info.output.suffix(maximumSimulatorRepairLogLength))
        let diagnostic = [info.error, output.isEmpty ? nil : output]
            .compactMap { $0 }
            .joined(separator: "\n\n")
        return """
        The iOS Simulator build failed with xcodebuild exit 65. Diagnose the compiler
        errors below, edit the existing project to fix them, and run xcodebuild for an
        iOS Simulator. Keep fixing errors and do not finish the turn until the project
        compiles successfully. Do not only explain the failure.

        Build diagnostics:
        \(diagnostic)
        """
    }

    private func applySimulatorInfo(
        _ info: SimulatorBuildInfo,
        client: ACPClient,
        projectID: String
    ) {
        let previousStatus = simulatorStatusByProject[projectID]
        let previousGeneration = simulatorGenerationByProject[projectID]
        let isStaleRepairFailure = previousStatus == "repairing"
            && info.status == "failed"
            && info.generation == previousGeneration
        if let generation = info.generation,
           simulatorGenerationByProject[projectID] != generation {
            simulatorGenerationByProject[projectID] = generation
            simulatorOutputByProject[projectID] = ""
        }

        let previousOutput = simulatorOutputByProject[projectID] ?? ""
        let newOutput: String
        if info.output.hasPrefix(previousOutput) {
            newOutput = String(info.output.dropFirst(previousOutput.count))
        } else {
            newOutput = info.output
        }
        simulatorOutputByProject[projectID] = info.output
        let displayOutput = newOutput.trimmingCharacters(in: .newlines)
        if !displayOutput.isEmpty {
            client.tracker.appendSystem(displayOutput)
        }

        if isStaleRepairFailure {
            return
        }
        simulatorStatusByProject[projectID] = info.status
        simulatorErrorByProject[projectID] = info.error
        if activeProjectID == projectID || (activeProjectID == nil && projectID == "active-project"),
           acp === client {
            simulatorURL = info.url
            simulatorBuildStatus = info.status
            simulatorBuildError = info.error
        }
        if info.status == "failed", previousStatus != "failed", let error = info.error {
            client.tracker.appendError(error)
        }
    }

    func requestNewProject() {
        guard canStartSession else { showOnboarding(); return }
        projectNameDraft = ""
        isNamingProject = true
    }

    var canCreateNamedProject: Bool {
        !projectNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func createNamedProject() {
        let name = projectNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        isNamingProject = false
        startNewSession(named: name)
    }

    private func startNewSession(named projectName: String) {
        let projectID = "new-project:\(UUID().uuidString)"
        let client = ACPClient()
        projectClients[projectID] = client
        projectNames[projectID] = projectName
        activateProjectClient(client, projectID: projectID)
        if let preferredBonjourEndpoint {
            client.setPreferredEndpoint(preferredBonjourEndpoint)
        }
        draft = ""
        messages = []
        sessionTitle = projectName
        screen = .agent
        Task { await client.startFreshSession(named: projectName) }
    }

    /// Upstream welcome prompt submit: type a message → enter agent session with that prompt.
    func startSessionFromWelcomePrompt() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard canStartSession else { showOnboarding(); return }
        draft = ""
        acp.tracker.reset()
        showAgent()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            self.acp.tracker.appendUser(text)
            self.acp.sendPrompt(text)
        }
    }

    /// Welcome "Resume Project" (ctrl+s) — project picker UI.
    func resumeProjectFromWelcome() {
        showSessionPicker()
    }

    /// Upstream welcome Quit — return stays on welcome (iOS has no process exit).
    func quitFromWelcome() {
        draft = ""
        for client in projectClients.values {
            client.disconnect()
        }
        projectClients.removeAll()
        projectNames.removeAll()
        projectCwds.removeAll()
        simulatorStatusByProject.removeAll()
        simulatorErrorByProject.removeAll()
        simulatorOutputByProject.removeAll()
        simulatorGenerationByProject.removeAll()
        simulatorPendingProjects.removeAll()
        simulatorRepairAttemptsByProject.removeAll()
        activeProjectID = nil
        acp.disconnect()
        acp = ACPClient()
        wireACP()
        messages = []
        screen = .welcome
    }

    func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        if text.hasPrefix("/") {
            handleSlashCommand(text)
            draft = ""
            return
        }
        if text.contains("@") {
            // In-prompt @ references stay in agent — no FilePicker navigation.
        }

        acp.tracker.appendUser(text)
        draft = ""
        acp.sendPrompt(text)
    }

    func insertFileReference(_ path: String) {
        if let at = draft.lastIndex(of: "@") {
            let prefix = String(draft[..<draft.index(after: at)])
            draft = prefix + path
        } else {
            let ref = path.hasPrefix("@") ? path : "@\(path)"
            draft += (draft.isEmpty ? "" : " ") + ref
        }
        screen = .agent
    }

    func insertAtFile(_ path: String) {
        insertFileReference(path)
    }

    func selectThemeFromDraft(_ name: String) {
        setTheme(name)
        draft = ""
        screen = .agent
    }

    func stopTurn() { acp.stop() }

    func approvePermission(optionId: String) {
        acp.respondToPermission(optionId: optionId)
        permissionRequest = nil
    }

    func selectPermission(optionId: String) {
        let kind = permissionRequest?.options.first(where: { $0.optionId == optionId })?.kind.lowercased() ?? ""
        if kind.contains("allowalways") || kind == "allow_always" {
            alwaysApprove = true
        }
        approvePermission(optionId: optionId)
    }

    func approvePermission(always: Bool) {
        if always { alwaysApprove = true }
        if let req = permissionRequest, !req.options.isEmpty {
            let pick = req.options.first(where: {
                always
                    ? ($0.kind.lowercased().contains("allowalways") || $0.kind == "allow_always")
                    : ($0.kind.lowercased().contains("allowonce") || $0.kind == "allow_once")
            }) ?? req.options.first
            if let pick {
                selectPermission(optionId: pick.optionId)
                return
            }
        }
        acp.respondToPermission(approved: true, alwaysApprove: always)
        permissionRequest = nil
    }

    func denyPermission() {
        if let req = permissionRequest,
           let reject = req.options.first(where: {
               $0.kind.lowercased().contains("reject") || $0.kind.contains("deny")
           }) {
            approvePermission(optionId: reject.optionId)
            return
        }
        acp.respondToPermission(approved: false, alwaysApprove: false)
        permissionRequest = nil
    }

    func toggleTimestamps() {
        showTimestamps.toggle()
        AppSettings.showTimestamps = showTimestamps
    }

    func toggleThinkingBlocks() {
        showThinkingBlocks.toggle()
        AppSettings.showThinkingBlocks = showThinkingBlocks
        messages = acp.tracker.displayEntries(showThinking: showThinkingBlocks)
    }

    func setTheme(_ name: String) {
        themeName = name
    }

    func signOut() {
        KeychainHelper.deleteAPIKey()
        apiKeyDraft = ""
        pairPinDraft = ""
        fingerprintDraft = ""
        CompanionConfig.isOnboarded = false
        CompanionConfig.clearPairing()
        CompanionConfig.save(host: "127.0.0.1", port: CompanionConfig.defaultWebSocketPort, useTLS: false, useWebSocket: true)
        preferredBonjourEndpoint = nil
        acp.setPreferredEndpoint(nil)
        acp.disconnect()
        acp.tracker.reset()
        messages = []
        connectionPhase = .idle
        setupError = nil
        objectWillChange.send()
        showOnboarding()
    }

    func refreshWorkspaceFiles() async {
        workspaceFiles = await acp.listWorkspaceFiles()
        // No invented fake paths when companion returns empty.
    }

    var filteredWorkspaceFiles: [String] {
        let f = fileFilter.lowercased()
        if f.isEmpty { return workspaceFiles }
        return workspaceFiles.filter { $0.lowercased().contains(f) }
    }

    private func handleSlashCommand(_ text: String) {
        let resolved = SlashCommandCatalog.resolve(text)
        let command = resolved.split(separator: " ").first.map(String.init) ?? resolved
        switch command.lowercased() {
        case "/new", "/clear":
            sessionTitle = "loading..."
            acp.disconnect()
            acp.tracker.reset()
            messages = []
            acp.connect()
        case "/theme", "/t":
            draft = command + " "
        case "/timestamps":
            toggleTimestamps()
        case "/settings", "/config", "/preferences", "/prefs":
            if resolved.lowercased().contains("show_thinking_blocks") {
                toggleThinkingBlocks()
            } else {
                showSettings()
            }
        case "/always-approve":
            alwaysApprove.toggle()
            acp.alwaysApprove = alwaysApprove
        case "/home", "/welcome", "/quit", "/exit":
            acp.disconnect()
            showWelcome()
        case "/dashboard":
            showDashboard()
        default:
            // Forward to grok agent (official slash handling lives in the Mac harness).
            acp.tracker.appendUser(resolved)
            acp.sendPrompt(resolved)
        }
    }

    var slashFilter: String? {
        guard draft.hasPrefix("/") else { return nil }
        let body = String(draft.dropFirst())
        return body.isEmpty ? nil : body
    }

    var filteredSlashCommands: [SlashCommand] {
        guard let filter = slashFilter?.lowercased() else { return SlashCommand.builtins }
        return SlashCommand.builtins.filter {
            $0.name.dropFirst().lowercased().contains(filter) || $0.summary.lowercased().contains(filter)
        }
    }
}
