// Copyright (c) 2026 Pedro Shakour
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Network

/// Typed ACP client: TLS pairing → initialize → resume/create session → prompt.
@MainActor
final class ACPClient: ObservableObject {
    @Published private(set) var isConnected = false
    @Published private(set) var isPaired = false
    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?
    @Published private(set) var sessionId: String?
    @Published private(set) var currentModelId: String?
    /// True after initialize and session restore/creation succeeded.
    @Published private(set) var sessionReady = false

    let tracker = ScrollbackTracker()

    private var connection: NWConnection?
    private var webSocketTask: URLSessionWebSocketTask?
    private var webSocketSession: URLSession?
    private var receiveBuffer = Data()
    private var requestID = 0
    private var pendingPrompt: String?
    private var pendingPermissionID: ACPProtocol.JSONValue?
    private var lastTurnActivity: String?
    private var turnTokenBaseline: Int?
    private var preferredEndpoint: NWEndpoint?
    private var pendingRequests: [Int: CheckedContinuation<ACPProtocol.JSONRPCResponse, Error>] = [:]
    private var rpcTimeoutTasks: [Int: Task<Void, Never>] = [:]
    private var handshakeTask: Task<Void, Never>?
    private var connectTimeoutTask: Task<Void, Never>?
    private var lineWaiter: CheckedContinuation<String, Error>?
    private var lineTimeoutTask: Task<Void, Never>?
    /// TOFU: leaf fingerprint observed during TLS (persisted only after PIN succeeds).
    private let tlsFingerprintCapture = TLSFingerprintCapture()

    var alwaysApprove = false

    var onModelChanged: ((String) -> Void)?
    var onPermissionRequest: ((PermissionRequest) -> Void)?
    var onChromeChanged: ((SessionChrome) -> Void)?
    var onRosterChanged: (([RosterSessionEntry]) -> Void)?
    var onTransportLost: (() -> Void)?

    private var preserveSessionIdOnReconnect: String?
    private var preserveSessionCwdOnReconnect: String?
    private var showLatestMessageOnReconnect = false
    private var pendingProjectName: String?
    private var receiveLoopActive = false
    private var isReplayingSessionHistory = false
    private var replayedMessageKind: ScrollbackKind?
    private var replayedMessageText = ""
    private var replayedChunkKind: ScrollbackKind?

    private(set) var chrome = SessionChrome()
    private var rosterById: [String: RosterSessionEntry] = [:]

    func setPreferredEndpoint(_ endpoint: NWEndpoint?) {
        preferredEndpoint = endpoint
    }

    func connect() {
        if connection != nil || webSocketTask != nil {
            return
        }
        lastError = nil
        sessionReady = false
        isPaired = false
        receiveBuffer = Data()
        receiveLoopActive = false

        let ep = CompanionConfig.resolved()
        if ep.useWebSocket {
            connectWebSocket(ep: ep)
            return
        }

        tlsFingerprintCapture.clear()
        if let preferred = preferredEndpoint {
            let params = CompanionTLS.connectionParameters(
                useTLS: ep.useTLS,
                pinnedFingerprint: CompanionConfig.pinnedFingerprint.nilIfEmpty,
                capture: tlsFingerprintCapture
            )
            connection = NWConnection(to: preferred, using: params)
            startConnection()
            return
        }

        guard !ep.host.isEmpty else {
            fail("Could not reach companion")
            return
        }
        guard let port = NWEndpoint.Port(rawValue: UInt16(ep.port)) else {
            fail("Could not reach companion")
            return
        }
        let params = CompanionTLS.connectionParameters(
            useTLS: ep.useTLS,
            pinnedFingerprint: CompanionConfig.pinnedFingerprint.nilIfEmpty,
            capture: tlsFingerprintCapture
        )
        let host = NWEndpoint.Host(ep.host)
        connection = NWConnection(host: host, port: port, using: params)
        startConnection()
    }

    /// Public companion transport over standard HTTPS/WebSocket infrastructure.
    private func connectWebSocket(ep: CompanionConfig.Endpoint) {
        var components = URLComponents()
        let useTLS = CompanionConfig.normalizedTLS(
            requestedTLS: ep.useTLS,
            useWebSocket: true,
            port: ep.port
        )
        components.scheme = useTLS ? "wss" : "ws"
        components.host = ep.host
        components.port = ep.port
        components.path = "/acp"
        guard let url = components.url else {
            fail("Could not reach companion")
            return
        }

        let session = URLSession(configuration: .default)
        webSocketSession = session
        var request = URLRequest(url: url)
        request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
        let task = session.webSocketTask(with: request)
        webSocketTask = task

        connectTimeoutTask?.cancel()
        connectTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard let self, !Task.isCancelled else { return }
            guard !self.isConnected else { return }
            self.fail("Could not reach companion — is `agent-phone` running?")
        }

        task.resume()
        receiveLoopActive = true
        receiveWebSocketLoop()
        handshakeTask = Task { @MainActor [weak self, weak task] in
            guard let self, let task else { return }
            do {
                try await self.waitUntilWebSocketOpen(task)
            } catch {
                guard self.webSocketTask === task else { return }
                self.fail("Could not reach companion: \(error.localizedDescription)")
                return
            }
            guard self.webSocketTask === task else { return }
            await self.runConnectPipeline()
        }
    }

    private func waitUntilWebSocketOpen(_ task: URLSessionWebSocketTask) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    /// Drop transport and reconnect; optionally resume the prior ACP session.
    func reconnect(
        preserveSessionId sessionId: String?,
        cwd: String? = nil,
        showLatestMessage: Bool = false
    ) {
        preserveSessionIdOnReconnect = sessionId
        preserveSessionCwdOnReconnect = cwd
        showLatestMessageOnReconnect = showLatestMessage
        teardownTransport()
        connect()
    }

    private func teardownTransport() {
        handshakeTask?.cancel()
        handshakeTask = nil
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        for (_, cont) in pendingRequests {
            cont.resume(throwing: ACPClientError.cancelled)
        }
        pendingRequests.removeAll()
        for task in rpcTimeoutTasks.values {
            task.cancel()
        }
        rpcTimeoutTasks.removeAll()
        if let waiter = lineWaiter {
            lineWaiter = nil
            waiter.resume(throwing: ACPClientError.cancelled)
        }
        lineTimeoutTask?.cancel()
        lineTimeoutTask = nil
        receiveLoopActive = false
        // Clear references before cancellation. Network.framework may deliver a
        // delayed `.cancelled` or receive callback after reconnect has already
        // installed a new transport; stale callbacks must not tear that one down.
        let oldConnection = connection
        connection = nil
        oldConnection?.stateUpdateHandler = nil
        oldConnection?.cancel()
        let oldWebSocketTask = webSocketTask
        webSocketTask = nil
        oldWebSocketTask?.cancel(with: .goingAway, reason: nil)
        let oldWebSocketSession = webSocketSession
        webSocketSession = nil
        oldWebSocketSession?.invalidateAndCancel()
        isConnected = false
        isPaired = false
        isRunning = false
        sessionReady = false
        pendingPrompt = nil
        pendingPermissionID = nil
    }

    private func startConnection() {
        guard let conn = connection else { return }
        connectTimeoutTask?.cancel()
        connectTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, !Task.isCancelled else { return }
            guard !self.isConnected else { return }
            self.fail("Could not reach companion")
        }
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            Task { @MainActor [weak self, weak conn] in
                guard let self, let conn else { return }
                guard self.connection === conn else { return }
                switch state {
                case .ready:
                    self.connectTimeoutTask?.cancel()
                    self.connectTimeoutTask = nil
                    self.isConnected = true
                    self.receiveLoop()
                    self.handshakeTask = Task { await self.runConnectPipeline() }
                case .waiting:
                    break
                case .failed(let error):
                    self.fail("Could not reach agent: \(error.localizedDescription)")
                case .cancelled:
                    self.isConnected = false
                    self.connection = nil
                    self.sessionReady = false
                default:
                    break
                }
            }
        }
        conn.start(queue: .global(qos: .userInitiated))
    }

    func disconnect() {
        preserveSessionIdOnReconnect = nil
        preserveSessionCwdOnReconnect = nil
        showLatestMessageOnReconnect = false
        teardownTransport()
        sessionId = nil
    }

    func sendPrompt(_ text: String) {
        guard !text.isEmpty else { return }
        isRunning = true
        chrome.turnStartedAt = Date()
        chrome.phaseStartedAt = Date()
        chrome.turnTokensUsed = nil
        turnTokenBaseline = chrome.contextUsed
        lastTurnActivity = chrome.turnActivity
        tracker.finalizeStreaming()
        if sessionReady, sessionId != nil {
            Task { await sendSessionPrompt(text) }
        } else {
            pendingPrompt = text
            if (connection != nil || webSocketTask != nil), !isConnected {
                disconnect()
            }
            connect()
        }
    }

    func stop() {
        Task {
            var params: [String: ACPProtocol.JSONValue] = [:]
            if let sessionId { params["sessionId"] = .string(sessionId) }
            _ = try? await sendRPC(method: "session/cancel", params: .object(params))
            tracker.finalizeStreaming()
            isRunning = false
            clearTurnTimers()
        }
    }

    private func clearTurnTimers() {
        chrome.turnStartedAt = nil
        chrome.phaseStartedAt = nil
        chrome.turnTokensUsed = nil
        chrome.turnActivity = nil
        turnTokenBaseline = nil
        lastTurnActivity = nil
        publishChrome()
    }

    private func setTurnActivity(_ activity: String?) {
        if activity != lastTurnActivity {
            chrome.phaseStartedAt = Date()
            lastTurnActivity = activity
        }
        chrome.turnActivity = activity
        publishChrome()
    }

    func respondToPermission(optionId: String) {
        guard let pendingPermissionID else { return }
        let reply = ACPProtocol.permissionReply(id: pendingPermissionID, optionId: optionId)
        guard let data = ACPProtocol.encodeLine(reply) else { return }
        Task { try? await sendRaw(data) }
        self.pendingPermissionID = nil
    }

    func respondToPermission(approved: Bool, alwaysApprove: Bool) {
        guard let pendingPermissionID else { return }
        let reply = ACPProtocol.permissionReply(
            id: pendingPermissionID,
            approved: approved,
            alwaysApprove: alwaysApprove
        )
        guard let data = ACPProtocol.encodeLine(reply) else { return }
        Task { try? await sendRaw(data) }
        self.pendingPermissionID = nil
    }

    func listSessions() async -> [SessionListEntry] {
        guard isPaired else { return [] }
        do {
            let resp = try await sendRPC(
                method: ACPProtocol.sessionListMethod,
                params: .object([:])
            )
            return parseSessionListResponse(resp)
        } catch {
            // Compatibility with the original xAI extension.
            do {
                let response = try await sendRPC(
                    method: ACPProtocol.legacySessionListMethod,
                    params: .object([:])
                )
                return parseSessionListResponse(response)
            } catch {
                return []
            }
        }
    }

    /// Live fleet roster (`x.ai/sessions/list`) — dashboard activity glyphs.
    func listRoster() async -> [RosterSessionEntry] {
        guard isPaired else { return [] }
        do {
            let resp = try await sendRPC(
                method: ACPProtocol.sessionsListMethod,
                params: .object([:])
            )
            guard let sessions = resp.result?["sessions"]?.arrayValue else { return [] }
            let entries = sessions.compactMap { parseRosterEntry($0) }
            for e in entries { rosterById[e.id] = e }
            return entries
        } catch {
            return []
        }
    }

    func loadSession(
        _ sessionId: String,
        cwd: String? = nil,
        showLatestMessage: Bool = false
    ) async throws {
        beginSessionHistoryReplay()
        let response: ACPProtocol.JSONRPCResponse
        do {
            response = try await sendRPC(
                method: ACPProtocol.sessionLoadMethod,
                params: ACPProtocol.sessionLoadParams(sessionId: sessionId, cwd: cwd)
            )
        } catch {
            endSessionHistoryReplay(showLatestMessage: false)
            throw error
        }
        endSessionHistoryReplay(showLatestMessage: showLatestMessage)
        let loadedSessionId = response.result?["sessionId"]?.stringValue ?? sessionId
        self.sessionId = loadedSessionId
        sessionReady = true
        chrome.sessionId = loadedSessionId
        if let cwd, cwd.hasPrefix("/") {
            chrome.cwd = cwd
        }
        if let modelID = response.result?["models"]?["currentModelId"]?.stringValue {
            currentModelId = modelID
            chrome.modelId = modelID
            onModelChanged?(modelID)
        }
        if let result = response.result?.objectValue {
            applyContextWindow(from: result)
        }
        publishChrome()
        await refreshSessionInfo()
        await refreshBilling()
        let restorableSessionId = sessionId.hasPrefix("grok-project:")
            ? sessionId
            : loadedSessionId
        CompanionConfig.saveLastSession(
            id: restorableSessionId,
            cwd: cwd?.isEmpty == false ? cwd : chrome.cwd
        )
    }

    func renderMermaid(source: String, themeDark: Bool) async throws -> Data {
        let resp = try await sendRPC(
            method: ACPProtocol.companionMermaidRenderMethod,
            params: .object([
                "source": .string(source),
                "theme": .string(themeDark ? "dark" : "light"),
                "quality": .string("open"),
                "width": .int(960),
            ])
        )
        guard let b64 = resp.result?["pngBase64"]?.stringValue,
              let data = Data(base64Encoded: b64) else {
            throw ACPClientError.rpc("mermaid render returned no PNG")
        }
        return data
    }

    func fetchShellConfig() async -> [String: ACPProtocol.JSONValue] {
        guard isPaired else { return [:] }
        do {
            let resp = try await sendRPC(
                method: ACPProtocol.companionConfigGetMethod,
                params: .object([:])
            )
            return resp.result?["values"]?.objectValue ?? [:]
        } catch {
            return [:]
        }
    }

    func setShellConfig(_ values: [String: ACPProtocol.JSONValue]) async throws -> [String: ACPProtocol.JSONValue] {
        let resp = try await sendRPC(
            method: ACPProtocol.companionConfigSetMethod,
            params: .object(["values": .object(values)])
        )
        return resp.result?["values"]?.objectValue ?? [:]
    }

    func fetchSimulatorURL() async -> URL? {
        await fetchSimulatorInfo().url
    }

    func runSimulatorApp() async throws {
        _ = try await sendRPC(
            method: ACPProtocol.companionSimulatorRunMethod,
            params: .object([:])
        )
    }

    func fetchSimulatorInfo() async -> (url: URL?, status: String?, error: String?) {
        guard isPaired else { return (nil, nil, nil) }
        do {
            let response = try await sendRPC(
                method: ACPProtocol.companionSimulatorInfoMethod,
                params: .object([:])
            )
            let value = response.result?["url"]?.stringValue ?? ""
            return (
                url: URL(string: value),
                status: response.result?["status"]?.stringValue,
                error: response.result?["error"]?.stringValue
            )
        } catch {
            return (nil, nil, nil)
        }
    }

    func refreshBilling() async {
        guard isPaired else { return }
        do {
            let resp = try await sendRPC(
                method: ACPProtocol.billingMethod,
                params: .object([:]),
                timeout: 2
            )
            applyBillingResult(resp.result)
        } catch {
            // Billing is optional — many sessions omit the extension.
        }
    }

    private func parseSessionListEntry(_ value: ACPProtocol.JSONValue) -> SessionListEntry? {
        guard case .object(let obj) = value else { return nil }
        let id = obj["sessionId"]?.stringValue ?? obj["session_id"]?.stringValue
        guard let id, !id.isEmpty else { return nil }
        let standardTitle = obj["title"]?.stringValue ?? ""
        let summary = obj["summary"]?.stringValue ?? ""
        let firstPrompt = obj["firstPrompt"]?.stringValue ?? obj["first_prompt"]?.stringValue ?? ""
        let title: String
        if !standardTitle.isEmpty {
            title = standardTitle
        } else if !summary.isEmpty {
            title = summary
        } else if !firstPrompt.isEmpty {
            title = String(firstPrompt.prefix(80))
        } else {
            title = "session \(id.prefix(8))"
        }
        let cwd = obj["cwd"]?.stringValue ?? ""
        let projectName = obj["projectName"]?.stringValue
            ?? obj["project_name"]?.stringValue
        return SessionListEntry(
            id: id,
            title: title,
            cwd: cwd,
            projectName: projectName
        )
    }

    private func parseSessionListResponse(_ response: ACPProtocol.JSONRPCResponse) -> [SessionListEntry] {
        guard let result = response.result else { return [] }
        let payload = result["data"]?.objectValue ?? result.objectValue ?? [:]
        let sessions = payload["sessions"]?.arrayValue ?? result["sessions"]?.arrayValue ?? []
        return sessions.compactMap { parseSessionListEntry($0) }
    }

    private func parseRosterEntry(_ value: ACPProtocol.JSONValue) -> RosterSessionEntry? {
        guard case .object(let obj) = value else { return nil }
        let id = obj["sessionId"]?.stringValue ?? obj["session_id"]?.stringValue
        guard let id, !id.isEmpty else { return nil }
        let title = obj["title"]?.stringValue
        let cwd = obj["cwd"]?.stringValue ?? ""
        let activityRaw = (obj["activity"]?.stringValue ?? "idle").lowercased()
        let activity: RosterSessionEntry.Activity
        switch activityRaw {
        case "working": activity = .working
        case "needs_input", "needsinput": activity = .needsInput
        case "dormant": activity = .dormant
        case "completed": activity = .completed
        case "dead": activity = .dead
        default: activity = .idle
        }
        let lastMs = obj["lastChangeUnixMs"]?.intValue
            ?? obj["last_change_unix_ms"]?.intValue
        return RosterSessionEntry(
            id: id,
            title: title,
            cwd: cwd,
            activity: activity,
            lastChangeUnixMs: lastMs.map { Int64($0) }
        )
    }

    func listWorkspaceFiles() async -> [String] {
        guard isPaired else { return [] }
        do {
            let resp = try await sendRPC(
                method: ACPProtocol.workspaceListMethod,
                params: .object(["cwd": .string(".")])
            )
            guard let files = resp.result?["files"], case .array(let arr) = files else { return [] }
            return arr.compactMap { $0.stringValue }
        } catch {
            return []
        }
    }

    /// New project on an already-open transport — `session/new` without reconnect.
    func startFreshSession(named projectName: String) async {
        guard isConnected, isPaired, sessionReady else {
            pendingProjectName = projectName
            connect()
            return
        }
        isRunning = false
        pendingPrompt = nil
        do {
            try await createSession(projectName: projectName)
        } catch {
            fail(error.localizedDescription)
        }
    }

    // MARK: - Pipeline

    private func runConnectPipeline() async {
        do {
            let ep = CompanionConfig.resolved()
            let hasPin = !CompanionConfig.savedPIN.isEmpty
            let hasToken = CompanionConfig.pairToken != nil
            if hasPin || hasToken {
                try await performPairing()
                if !ep.useWebSocket,
                   let observed = tlsFingerprintCapture.fingerprint,
                   CompanionConfig.pinnedFingerprint.isEmpty {
                    CompanionConfig.pinnedFingerprint = observed
                }
            } else if ep.useTLS {
                throw ACPClientError.pairingRequired
            } else {
                isPaired = true
            }
            _ = try await sendRPC(
                method: "initialize",
                params: ACPProtocol.initializeParams()
            )

            if let resumeId = preserveSessionIdOnReconnect, !resumeId.isEmpty {
                let resumeCwd = preserveSessionCwdOnReconnect
                let showLatestMessage = showLatestMessageOnReconnect
                preserveSessionIdOnReconnect = nil
                preserveSessionCwdOnReconnect = nil
                showLatestMessageOnReconnect = false
                try await loadSession(
                    resumeId,
                    cwd: resumeCwd,
                    showLatestMessage: showLatestMessage
                )
            } else if let projectName = pendingProjectName?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                      !projectName.isEmpty {
                pendingProjectName = nil
                try await createSession(projectName: projectName)
            } else {
                pendingProjectName = nil
                if !(await resumeLastProjectIfAvailable()) {
                    try await createSession(projectName: nil)
                }
            }

            isConnected = true
            connectTimeoutTask?.cancel()
            connectTimeoutTask = nil
            if let pending = pendingPrompt {
                pendingPrompt = nil
                chrome.turnActivity = "Thinking…"
                publishChrome()
                await sendSessionPrompt(pending)
            }
        } catch {
            if error is CancellationError || (error as? ACPClientError) == .cancelled {
                return
            }
            fail(error.localizedDescription)
        }
    }

    private func resumeLastProjectIfAvailable() async -> Bool {
        var candidates: [SessionListEntry] = []
        // The registry is the source of truth for project restoration. Opening
        // its synthetic ID creates a fresh ACP session in the existing folder,
        // avoiding a full replay of an old provider conversation on Connect.
        if let registeredProject = await fetchLastRegisteredProject() {
            candidates.append(registeredProject)
        }
        if let last = CompanionConfig.lastSession,
           !candidates.contains(where: { $0.id == last.id }) {
            candidates.append(SessionListEntry(
                id: last.id,
                title: "Last project",
                cwd: last.cwd ?? "",
                projectName: "Last project"
            ))
        }

        for candidate in candidates {
            do {
                try await loadSession(
                    candidate.id,
                    cwd: candidate.cwd.isEmpty ? nil : candidate.cwd,
                    showLatestMessage: true
                )
                return true
            } catch {
                continue
            }
        }
        CompanionConfig.clearLastSession()
        return false
    }

    private func fetchLastRegisteredProject() async -> SessionListEntry? {
        do {
            let response = try await sendRPC(
                method: ACPProtocol.companionLastProjectMethod,
                params: .object([:])
            )
            guard let result = response.result?.objectValue,
                  let id = result["sessionId"]?.stringValue,
                  !id.isEmpty,
                  let cwd = result["cwd"]?.stringValue,
                  !cwd.isEmpty else {
                return nil
            }
            let projectName = result["projectName"]?.stringValue
            return SessionListEntry(
                id: id,
                title: projectName ?? "Last project",
                cwd: cwd,
                projectName: projectName
            )
        } catch {
            return nil
        }
    }

    private func createSession(projectName: String?) async throws {
        let sessionResp = try await sendRPC(
            method: "session/new",
            params: ACPProtocol.sessionNewParams(projectName: projectName)
        )
        guard let result = sessionResp.result,
              let sid = result["sessionId"]?.stringValue else {
            throw ACPClientError.handshakeFailed("No sessionId")
        }
        sessionId = sid
        sessionReady = true
        chrome.sessionId = sid
        if let modelID = result["models"]?["currentModelId"]?.stringValue {
            currentModelId = modelID
            chrome.modelId = modelID
            onModelChanged?(modelID)
        }
        if let object = result.objectValue {
            applyContextWindow(from: object)
        }
        if let cwd = result["cwd"]?.stringValue, !cwd.isEmpty {
            chrome.cwd = cwd
        }
        publishChrome()
        await refreshSessionInfo()
        await refreshBilling()
        if projectName != nil {
            CompanionConfig.saveLastSession(id: sid, cwd: chrome.cwd)
        }
    }

    private func performPairing() async throws {
        let pin = CompanionConfig.savedPIN
        let token = CompanionConfig.pairToken
        var body = ACPProtocol.PairBody()
        if let token, !token.isEmpty {
            body.token = token
        } else if !pin.isEmpty {
            body.pin = pin
        } else {
            throw ACPClientError.pairingRequired
        }
        let req = ACPProtocol.PairRequest(grok_pair: body)
        guard let data = ACPProtocol.encodeLine(req) else {
            throw ACPClientError.encodeFailed
        }
        let line = try await sendAndAwaitLine(data, timeout: 10)
        guard let result = ACPProtocol.decodePairResult(line) else {
            throw ACPClientError.pairingFailed("Invalid pair response")
        }
        guard result.ok else {
            throw ACPClientError.pairingFailed(result.error ?? "Pairing rejected")
        }
        if let newToken = result.token {
            CompanionConfig.pairToken = newToken
        }
        isPaired = true
    }

    private func sendSessionPrompt(_ text: String) async {
        guard let sessionId else {
            tracker.appendError("No ACP session yet")
            isRunning = false
            return
        }
        do {
            let id = nextID()
            let req = ACPProtocol.JSONRPCRequest(
                method: "session/prompt",
                params: ACPProtocol.sessionPromptParams(sessionId: sessionId, text: text),
                id: id
            )
            guard let data = ACPProtocol.encodeLine(req) else { throw ACPClientError.encodeFailed }
            try await sendRaw(data)
            chrome.turnActivity = "Thinking…"
            chrome.turnStartedAt = chrome.turnStartedAt ?? Date()
            chrome.phaseStartedAt = chrome.phaseStartedAt ?? Date()
            publishChrome()
        } catch {
            tracker.appendError(error.localizedDescription)
            isRunning = false
            chrome.turnActivity = nil
            publishChrome()
        }
    }

    private func refreshSessionInfo() async {
        guard let sessionId else { return }
        do {
            let resp = try await sendRPC(
                method: "x.ai/session/info",
                params: .object(["sessionId": .string(sessionId)]),
                timeout: 2
            )
            guard let result = resp.result else { return }
            let data = result["data"]?.objectValue ?? result.objectValue ?? [:]
            if let cwd = data["cwd"]?.stringValue ?? result["cwd"]?.stringValue, !cwd.isEmpty {
                chrome.cwd = cwd
            }
            if let model = data["model"]?.stringValue
                ?? data["resolvedModelId"]?.stringValue
                ?? data["modelDisplayName"]?.stringValue
                ?? result["model"]?.stringValue {
                chrome.modelId = model
                currentModelId = model
                onModelChanged?(model)
            }
            if let effort = data["reasoningEffort"]?.stringValue
                ?? data["reasoning_effort"]?.stringValue
                ?? data["effort"]?.stringValue {
                chrome.modelEffort = effort
            }
            if let ctx = data["context"]?.objectValue ?? result["context"]?.objectValue {
                chrome.contextUsed = ctx["used"]?.intValue
                if let total = ctx["total"]?.intValue, total > 0 {
                    chrome.contextTotal = total
                }
            }
            applyContextWindow(from: data)
            if let obj = result.objectValue {
                applyContextWindow(from: obj)
            }
            publishChrome()
        } catch {
            // Extension optional.
        }
    }

    private func publishChrome() {
        chrome.alwaysApprove = alwaysApprove
        onChromeChanged?(chrome)
    }

    // MARK: - RPC

    private func nextID() -> Int {
        requestID += 1
        return requestID
    }

    private func sendRPC(
        method: String,
        params: ACPProtocol.JSONValue,
        timeout: TimeInterval = 30
    ) async throws -> ACPProtocol.JSONRPCResponse {
        let id = nextID()
        let req = ACPProtocol.JSONRPCRequest(method: method, params: params, id: id)
        guard let data = ACPProtocol.encodeLine(req) else { throw ACPClientError.encodeFailed }
        return try await withCheckedThrowingContinuation { cont in
            // Register before writing. Local ACP agents can respond before the
            // Network.framework send completion callback fires.
            pendingRequests[id] = cont
            rpcTimeoutTasks[id] = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard let self, !Task.isCancelled else { return }
                self.rpcTimeoutTasks[id] = nil
                if let pending = self.pendingRequests.removeValue(forKey: id) {
                    pending.resume(throwing: ACPClientError.timeout)
                }
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await self.sendRaw(data)
                } catch {
                    self.rpcTimeoutTasks.removeValue(forKey: id)?.cancel()
                    if let pending = self.pendingRequests.removeValue(forKey: id) {
                        pending.resume(throwing: error)
                    }
                }
            }
        }
    }

    private func sendRaw(_ data: Data) async throws {
        if let ws = webSocketTask {
            guard let text = String(data: data, encoding: .utf8) else {
                throw ACPClientError.encodeFailed
            }
            // Official serve strips trailing newlines from WS text frames.
            let payload = text.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
            try await ws.send(.string(payload))
            return
        }
        guard let connection else { throw ACPClientError.notConnected }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) }
                else { cont.resume() }
            })
        }
    }

    /// Official `grok agent serve` delivers one JSON-RPC message per WS text frame.
    private func receiveWebSocketLoop() {
        guard receiveLoopActive, let task = webSocketTask else { return }
        task.receive { [weak self, weak task] result in
            Task { @MainActor [weak self, weak task] in
                guard let self, let task, self.receiveLoopActive else { return }
                guard self.webSocketTask === task else { return }
                switch result {
                case .failure(let error):
                    if self.sessionReady {
                        self.handleTransportDrop()
                    } else {
                        self.fail("Could not reach companion: \(error.localizedDescription)")
                    }
                case .success(let message):
                    switch message {
                    case .string(let text):
                        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
                        if trimmed != "ping", !trimmed.isEmpty {
                            self.handleLine(trimmed)
                        }
                    case .data(let data):
                        if let s = String(data: data, encoding: .utf8) {
                            let trimmed = s.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
                            if trimmed != "ping", !trimmed.isEmpty {
                                self.handleLine(trimmed)
                            }
                        }
                    @unknown default:
                        break
                    }
                    self.receiveWebSocketLoop()
                }
            }
        }
    }

    private func handleTransportDrop() {
        let wasReady = sessionReady
        let priorSession = sessionId
        teardownTransport()
        sessionId = priorSession
        sessionReady = false
        if wasReady {
            preserveSessionIdOnReconnect = priorSession
            onTransportLost?()
        }
    }

    private func sendAndAwaitLine(_ data: Data, timeout: TimeInterval) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            // Pairing replies are also local and can arrive immediately.
            lineWaiter = cont
            lineTimeoutTask?.cancel()
            lineTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard let self, !Task.isCancelled, let waiter = self.lineWaiter else { return }
                self.lineWaiter = nil
                self.lineTimeoutTask = nil
                waiter.resume(throwing: ACPClientError.timeout)
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await self.sendRaw(data)
                } catch {
                    self.lineTimeoutTask?.cancel()
                    self.lineTimeoutTask = nil
                    if let waiter = self.lineWaiter {
                        self.lineWaiter = nil
                        waiter.resume(throwing: error)
                    }
                }
            }
        }
    }

    // MARK: - Receive

    private func receiveLoop() {
        guard let activeConnection = connection else { return }
        activeConnection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak activeConnection] data, _, isComplete, error in
            Task { @MainActor [weak self, weak activeConnection] in
                guard let self, let activeConnection else { return }
                guard self.connection === activeConnection else { return }
                if let data, !data.isEmpty { self.receiveBuffer.append(data); self.processBuffer() }
                if let error {
                    if self.sessionReady {
                        self.handleTransportDrop()
                    } else {
                        self.fail("Agent connection closed: \(error.localizedDescription)")
                    }
                    return
                }
                if isComplete {
                    if self.sessionReady {
                        self.handleTransportDrop()
                    } else {
                        self.fail("Agent closed the connection during setup")
                    }
                    return
                }
                self.receiveLoop()
            }
        }
    }

    private func processBuffer() {
        while let line = extractLine() {
            handleLine(line)
        }
    }

    private func extractLine() -> String? {
        guard let range = receiveBuffer.firstRange(of: Data([0x0A])) else { return nil }
        let lineData = receiveBuffer.subdata(in: receiveBuffer.startIndex..<range.lowerBound)
        receiveBuffer.removeSubrange(receiveBuffer.startIndex...range.lowerBound)
        return String(data: lineData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    private func handleLine(_ line: String) {
        if let waiter = lineWaiter {
            lineWaiter = nil
            lineTimeoutTask?.cancel()
            lineTimeoutTask = nil
            waiter.resume(returning: line)
            return
        }
        if line.contains(ACPProtocol.pairResultPrefix) {
            return
        }
        guard let msg = ACPProtocol.decodeLine(line) else { return }

        if let method = msg.method {
            if method == "session/update" || method.hasSuffix("/session_notification") {
                if let params = msg.params?.objectValue {
                    applyNotificationMeta(params["_meta"]?.objectValue)
                    if let update = params["update"]?.objectValue {
                        let kind = update["sessionUpdate"]?.stringValue ?? ""
                        let isHistoryReplay = isReplayingSessionHistory
                        if isHistoryReplay {
                            captureReplayedMessage(from: update)
                        }
                        if kind == "current_mode_update" || kind == "currentModeUpdate" {
                            let modeId = update["currentModeId"]?.stringValue
                                ?? update["modeId"]?.stringValue
                                ?? ""
                            chrome.planMode = modeId.lowercased().contains("plan")
                            publishChrome()
                        } else if kind == "model_changed" || kind == "modelChanged" {
                            if let model = update["model_id"]?.stringValue
                                ?? update["modelId"]?.stringValue
                                ?? update["currentModelId"]?.stringValue {
                                chrome.modelId = model
                                currentModelId = model
                                onModelChanged?(model)
                            }
                            if let effort = update["reasoning_effort"]?.stringValue
                                ?? update["reasoningEffort"]?.stringValue
                                ?? update["effort"]?.stringValue {
                                chrome.modelEffort = effort
                            }
                            publishChrome()
                        } else if kind == "goal_updated" || kind == "goalUpdated" {
                            applyGoalUpdate(update)
                        } else if !isHistoryReplay {
                            if kind == "tool_call" {
                                let title = update["title"]?.stringValue ?? ""
                                if !title.isEmpty {
                                    setTurnActivity(title)
                                }
                            } else if kind == "agent_thought_chunk" {
                                setTurnActivity("Thinking…")
                            } else if kind == "agent_message_chunk" {
                                setTurnActivity("Responding…")
                            }
                            tracker.handleSessionUpdate(update)
                        }
                    }
                }
            } else if method == "x.ai/git_head_changed" {
                if let params = msg.params?.objectValue {
                    chrome.gitBranch = params["branch"]?.stringValue
                    chrome.isWorktree = params["isWorktree"]?.boolValue ?? false
                    chrome.mainRepo = params["mainRepo"]?.stringValue
                    publishChrome()
                }
            } else if method == "x.ai/queue/changed" {
                // Upstream turn_status queue hint — entries[] length when present.
                if let params = msg.params?.objectValue {
                    let entries = params["entries"]?.arrayValue ?? []
                    chrome.queuedPromptCount = entries.count
                    publishChrome()
                }
            } else if method == "x.ai/mcp/init_progress" {
                if let params = msg.params?.objectValue {
                    chrome.mcpTotal = params["total"]?.intValue
                    chrome.mcpConnected = params["connected"]?.intValue
                    publishChrome()
                }
            } else if method == "x.ai/mcp_initialized" {
                chrome.mcpTotal = nil
                chrome.mcpConnected = nil
                publishChrome()
            } else if method == "x.ai/sessions/changed" {
                if let params = msg.params?.objectValue {
                    applyRosterChanged(params)
                }
            } else if method == "x.ai/settings/update" {
                // Remote settings snapshot — subscription tier / gates only when present.
                if let params = msg.params?.objectValue,
                   let tier = params["subscription_tier_display"]?.stringValue
                    ?? params["subscriptionTierDisplay"]?.stringValue,
                   !tier.isEmpty {
                    // Tier alone is not a credits chip; billing poll owns percent.
                    _ = tier
                }
            } else if method == "session/request_permission" {
                pendingPermissionID = msg.id
                let params = msg.params?.objectValue
                let toolCall = params?["toolCall"]?.objectValue
                let title = permissionTitle(toolCall: toolCall)
                let options = parsePermissionOptions(params?["options"])
                setTurnActivity("Waiting…")
                if alwaysApprove {
                    if let pick = autoApproveOption(from: options) {
                        respondToPermission(optionId: pick)
                    } else {
                        respondToPermission(approved: true, alwaysApprove: true)
                    }
                } else {
                    onPermissionRequest?(PermissionRequest(
                        message: title,
                        title: toolCall?["title"]?.stringValue,
                        options: options,
                        requestId: msg.id
                    ))
                }
            }
            return
        }

        if let idVal = msg.id {
            let id: Int?
            switch idVal {
            case .int(let i): id = i
            case .string(let s): id = Int(s)
            default: id = nil
            }
            if let id, let cont = pendingRequests.removeValue(forKey: id) {
                rpcTimeoutTasks.removeValue(forKey: id)?.cancel()
                if let error = msg.error {
                    let parts = [error.message, error.data].compactMap { $0 }.filter { !$0.isEmpty }
                    cont.resume(throwing: ACPClientError.rpc(parts.joined(separator: ": ")))
                } else {
                    cont.resume(returning: msg)
                }
            }
            // session/prompt result carries stopReason even if id type mismatched above.
            if let stop = msg.result?["stopReason"]?.stringValue, !stop.isEmpty {
                tracker.finalizeStreaming()
                tracker.collapseFinishedThoughts()
                isRunning = false
                clearTurnTimers()
                Task { await refreshSessionInfo() }
            }
            return
        }
    }

    private func beginSessionHistoryReplay() {
        isReplayingSessionHistory = true
        replayedMessageKind = nil
        replayedMessageText = ""
        replayedChunkKind = nil
    }

    private func captureReplayedMessage(from update: [String: ACPProtocol.JSONValue]) {
        let updateKind = update["sessionUpdate"]?.stringValue ?? ""
        let messageKind: ScrollbackKind?
        switch updateKind {
        case "user_message_chunk":
            messageKind = .user
        case "agent_message_chunk":
            messageKind = .assistant
        default:
            replayedChunkKind = nil
            return
        }

        guard let messageKind,
              let content = update["content"]?.objectValue,
              let text = content["text"]?.stringValue,
              !text.isEmpty else {
            return
        }
        if replayedChunkKind == messageKind {
            replayedMessageText += text
        } else {
            replayedMessageKind = messageKind
            replayedMessageText = text
        }
        replayedChunkKind = messageKind
    }

    private func endSessionHistoryReplay(showLatestMessage: Bool) {
        isReplayingSessionHistory = false
        if showLatestMessage {
            tracker.showOnlyLatestMessage(
                kind: replayedMessageKind,
                text: replayedMessageText
            )
        }
        replayedMessageKind = nil
        replayedMessageText = ""
        replayedChunkKind = nil
    }

    private func applyNotificationMeta(_ meta: [String: ACPProtocol.JSONValue]?) {
        guard let meta else { return }
        if let used = meta["totalTokens"]?.intValue {
            chrome.contextUsed = used
            if isRunning {
                if let baseline = turnTokenBaseline {
                    chrome.turnTokensUsed = max(0, used - baseline)
                } else {
                    chrome.turnTokensUsed = used
                }
            }
            publishChrome()
        }
    }

    private func applyGoalUpdate(_ update: [String: ACPProtocol.JSONValue]) {
        let status = (update["status"]?.stringValue ?? "").lowercased()
        let phase = (update["phase"]?.stringValue ?? "").lowercased()
        if status == "cleared" || status == "complete" {
            chrome.goalPhaseLabel = nil
            chrome.goalActive = false
            publishChrome()
            return
        }
        let label: String
        switch phase {
        case "planning": label = "Planning"
        case "executing": label = "Executing"
        case "idle": label = "Idle"
        default:
            if status.contains("pause") {
                label = "Paused"
            } else if !status.isEmpty {
                label = status.replacingOccurrences(of: "_", with: " ").capitalized
            } else {
                label = "Active"
            }
        }
        chrome.goalPhaseLabel = label
        chrome.goalActive = status == "active" || status.isEmpty
        publishChrome()
    }

    private func applyBillingResult(_ result: ACPProtocol.JSONValue?) {
        guard let result else { return }
        let config = result["config"]?.objectValue ?? result.objectValue
        guard let config else { return }
        if let pct = config["creditUsagePercent"]?.doubleValue
            ?? config["credit_usage_percent"]?.doubleValue
            ?? config["usagePct"]?.doubleValue {
            chrome.creditsUsedPercent = pct
            publishChrome()
        }
    }

    private func applyRosterChanged(_ params: [String: ACPProtocol.JSONValue]) {
        if let removed = params["removed"]?.arrayValue {
            for idVal in removed {
                if let id = idVal.stringValue {
                    rosterById.removeValue(forKey: id)
                }
            }
        }
        if let upserted = params["upserted"]?.arrayValue {
            for item in upserted {
                if let entry = parseRosterEntry(item) {
                    rosterById[entry.id] = entry
                }
            }
        }
        let sorted = rosterById.values.sorted { a, b in
            (a.lastChangeUnixMs ?? 0) > (b.lastChangeUnixMs ?? 0)
        }
        onRosterChanged?(sorted)
    }

    /// Upstream `acp_handler/permissions.rs` title patterns.
    private func permissionTitle(toolCall: [String: ACPProtocol.JSONValue]?) -> String {
        guard let toolCall else { return "Allow?" }
        if let title = toolCall["title"]?.stringValue, !title.isEmpty {
            return "Allow \(title)?"
        }
        let kind = (toolCall["kind"]?.stringValue ?? "").lowercased()
        switch kind {
        case "edit": return "Allow Edit?"
        case "execute": return "Allow Execute?"
        case "delete": return "Allow Delete?"
        default: return "Allow?"
        }
    }

    private func parsePermissionOptions(_ value: ACPProtocol.JSONValue?) -> [PermissionOption] {
        guard let value, case .array(let arr) = value else { return [] }
        return arr.compactMap { item -> PermissionOption? in
            guard case .object(let obj) = item else { return nil }
            let optionId = obj["optionId"]?.stringValue ?? obj["option_id"]?.stringValue
            let name = obj["name"]?.stringValue
            let kind = obj["kind"]?.stringValue ?? ""
            guard let optionId, let name else { return nil }
            return PermissionOption(optionId: optionId, name: name, kind: kind)
        }
    }

    private func autoApproveOption(from options: [PermissionOption]) -> String? {
        if let always = options.first(where: {
            $0.kind.lowercased().contains("allowalways") || $0.kind == "allow_always"
        }) {
            return always.optionId
        }
        if let once = options.first(where: {
            $0.kind.lowercased().contains("allowonce") || $0.kind == "allow_once"
        }) {
            return once.optionId
        }
        return options.first?.optionId
    }

    /// Pull context window from session/new or session/info payloads when present.
    private func applyContextWindow(from result: [String: ACPProtocol.JSONValue]) {
        if let models = result["models"]?.objectValue {
            if let cw = models["contextWindow"]?.intValue
                ?? models["context_window"]?.intValue
                ?? models["contextWindowTokens"]?.intValue,
               cw > 0 {
                chrome.contextTotal = cw
            }
            // availableModels[{id}].contextWindow
            if chrome.contextTotal == nil,
               let mid = models["currentModelId"]?.stringValue,
               let avail = models["availableModels"]?.objectValue
                ?? models["available_models"]?.objectValue,
               let entry = avail[mid]?.objectValue,
               let cw = entry["contextWindow"]?.intValue
                ?? entry["context_window"]?.intValue
                ?? entry["contextWindowTokens"]?.intValue,
               cw > 0 {
                chrome.contextTotal = cw
            }
        }
        if let cw = result["contextWindowTokens"]?.intValue
            ?? result["context_window_tokens"]?.intValue,
           cw > 0 {
            chrome.contextTotal = cw
        }
    }

    private func fail(_ message: String, showInScrollback: Bool = false) {
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        handshakeTask?.cancel()
        handshakeTask = nil
        lastError = message
        isRunning = false
        sessionReady = false
        chrome.turnActivity = nil
        publishChrome()
        teardownTransport()
        if showInScrollback {
            tracker.appendError(message)
        }
    }
}

enum ACPClientError: LocalizedError, Equatable {
    case notConnected
    case encodeFailed
    case handshakeFailed(String)
    case pairingRequired
    case pairingFailed(String)
    case timeout
    case cancelled
    case rpc(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected"
        case .encodeFailed: return "Failed to encode request"
        case .handshakeFailed(let m): return m
        case .pairingRequired: return "Paste the PIN printed by `agent-phone`"
        case .pairingFailed(let m): return m
        case .timeout: return "Companion timed out"
        case .cancelled: return "Cancelled"
        case .rpc(let m): return m
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
