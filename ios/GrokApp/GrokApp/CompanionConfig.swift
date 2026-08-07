// Copyright (c) 2026 Pedro Shakour
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// User-configurable companion endpoint, pairing, and TLS fingerprint.
enum CompanionConfig {
    struct Endpoint: Equatable {
        var host: String
        var port: Int
        var useTLS: Bool
        /// Legacy direct WebSocket mode. The provider-neutral bridge uses TCP+TLS.
        var useWebSocket: Bool
    }

    struct RemoteAddress: Equatable {
        var host: String
        var port: Int
        var useTLS: Bool = true
        var useWebSocket: Bool = false
    }

    static let defaultPort = 7391
    /// Legacy Grok WebSocket bind port.
    static let defaultWebSocketPort = 2419
    static let bonjourType = "_grok-build._tcp"
    static let bonjourName = "Grok Build"

    private static let hostKey = "GROK_ACP_HOST"
    private static let portKey = "GROK_ACP_PORT"
    private static let onboardedKey = "GROK_ONBOARDED"
    private static let pinKey = "GROK_PAIR_PIN"
    private static let tokenKey = "GROK_PAIR_TOKEN"
    private static let fingerprintKey = "GROK_CERT_FINGERPRINT"
    private static let tlsKey = "GROK_USE_TLS"
    private static let wsKey = "GROK_USE_WEBSOCKET"
    private static let lastSessionIDKey = "GROK_LAST_SESSION_ID"
    private static let lastSessionCwdKey = "GROK_LAST_SESSION_CWD"

    static var isOnboarded: Bool {
        get { UserDefaults.standard.bool(forKey: onboardedKey) }
        set { UserDefaults.standard.set(newValue, forKey: onboardedKey) }
    }

    static var pairToken: String? {
        get { UserDefaults.standard.string(forKey: tokenKey) }
        set {
            if let newValue, !newValue.isEmpty {
                UserDefaults.standard.set(newValue, forKey: tokenKey)
            } else {
                UserDefaults.standard.removeObject(forKey: tokenKey)
            }
        }
    }

    static var savedPIN: String {
        get { UserDefaults.standard.string(forKey: pinKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: pinKey) }
    }

    static var pinnedFingerprint: String {
        get { UserDefaults.standard.string(forKey: fingerprintKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: fingerprintKey) }
    }

    static func bundledPort() -> Int {
        if let url = Bundle.main.url(forResource: "companion.defaults", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let port = obj["port"] as? Int, port > 0 {
            return port
        }
        return defaultWebSocketPort
    }

    /// Absolute Mac workspace for `session/new` (official serve rejects relative cwd).
    static func workspaceCwd() -> String {
        if let stored = UserDefaults.standard.string(forKey: "GROK_WORKSPACE_CWD")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           stored.hasPrefix("/") {
            return stored
        }
        if let url = Bundle.main.url(forResource: "companion.defaults", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let cwd = obj["cwd"] as? String,
           cwd.hasPrefix("/") {
            return cwd
        }
        // Fallback absolute path accepted by `grok agent serve`.
        return "/tmp"
    }

    static func saveWorkspaceCwd(_ cwd: String) {
        let c = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        if c.hasPrefix("/") {
            UserDefaults.standard.set(c, forKey: "GROK_WORKSPACE_CWD")
        }
    }

    static func resolved() -> Endpoint {
        let useWS = UserDefaults.standard.bool(forKey: wsKey)
        let useTLS = UserDefaults.standard.object(forKey: tlsKey) as? Bool
        let host = UserDefaults.standard.string(forKey: hostKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let storedPort = UserDefaults.standard.integer(forKey: portKey)
        let resolvedHost = host.isEmpty ? "127.0.0.1" : host
        let defaultPort = useWS ? defaultWebSocketPort : defaultPort
        let migratedPort = storedPort == defaultWebSocketPort ? Self.defaultPort : storedPort
        let resolvedPort = normalizedPort(
            host: resolvedHost,
            requestedPort: migratedPort > 0 ? migratedPort : defaultPort,
            useWebSocket: useWS
        )
        return Endpoint(
            host: resolvedHost,
            port: resolvedPort,
            useTLS: normalizedTLS(
                requestedTLS: useTLS ?? true,
                useWebSocket: useWS,
                port: resolvedPort
            ),
            useWebSocket: useWS
        )
    }

    static func save(host: String, port: Int, useTLS: Bool = true, useWebSocket: Bool = false) {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedPort = port > 0 ? port : (useWebSocket ? defaultWebSocketPort : defaultPort)
        let savedPort = normalizedPort(
            host: h,
            requestedPort: requestedPort,
            useWebSocket: useWebSocket
        )
        UserDefaults.standard.set(h, forKey: hostKey)
        UserDefaults.standard.set(savedPort, forKey: portKey)
        UserDefaults.standard.set(
            normalizedTLS(requestedTLS: useTLS, useWebSocket: useWebSocket, port: savedPort),
            forKey: tlsKey
        )
        UserDefaults.standard.set(useWebSocket, forKey: wsKey)
    }

    /// HTTPS WebSocket endpoints cannot be downgraded to plaintext by stale preferences.
    static func normalizedTLS(requestedTLS: Bool, useWebSocket: Bool, port: Int) -> Bool {
        requestedTLS || (useWebSocket && port == 443)
    }

    /// ngrok's public HTTP origin is HTTPS-only for the companion WebSocket route.
    static func normalizedPort(host: String, requestedPort: Int, useWebSocket: Bool) -> Int {
        if useWebSocket,
           requestedPort == 80,
           host.lowercased().hasSuffix(".ngrok-free.app") {
            return 443
        }
        return requestedPort
    }

    /// Parses the TCP or WSS endpoint printed by `agent-phone --ngrok`.
    static func parseRemoteAddress(_ value: String) -> RemoteAddress? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "tcp://\(trimmed)"
        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              ["tcp", "ws", "wss", "http", "https"].contains(scheme),
              let host = components.host,
              !host.isEmpty,
              let port = components.port ?? (["wss", "https"].contains(scheme) ? 443 : (["ws", "http"].contains(scheme) ? 80 : nil)),
              (1...65_535).contains(port),
              components.path.isEmpty || components.path == "/" || components.path == "/acp",
              components.query == nil,
              components.fragment == nil else {
            return nil
        }
        let useWebSocket = ["ws", "wss", "http", "https"].contains(scheme)
        let normalizedPort = normalizedPort(
            host: host,
            requestedPort: port,
            useWebSocket: useWebSocket
        )
        return RemoteAddress(
            host: host,
            port: normalizedPort,
            useTLS: normalizedTLS(
                requestedTLS: ["tcp", "wss", "https"].contains(scheme),
                useWebSocket: useWebSocket,
                port: normalizedPort
            ),
            useWebSocket: useWebSocket
        )
    }

    /// Whether a configured host is suitable as an off-LAN fallback.
    static func isRemotelyReachableHost(_ value: String) -> Bool {
        let host = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !host.isEmpty,
              host != "localhost",
              !host.hasSuffix(".local"),
              host != "::1",
              !host.contains(where: { $0.isWhitespace }) else {
            return false
        }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        if octets.count == 4 {
            guard octets.allSatisfy({ (0...255).contains($0) }) else { return false }
            if octets[0] == 10 || octets[0] == 127 || octets[0] == 0 { return false }
            if octets[0] == 169 && octets[1] == 254 { return false }
            if octets[0] == 172 && (16...31).contains(octets[1]) { return false }
            if octets[0] == 192 && octets[1] == 168 { return false }
        }
        return true
    }

    static var hasRemoteEndpoint: Bool {
        isRemotelyReachableHost(resolved().host)
    }

    static var hasHost: Bool {
        !resolved().host.isEmpty
    }

    /// Saved bridge pairing PIN (stored under the original compatibility key).
    static var hasSavedSecret: Bool {
        !savedPIN.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Golden path: WebSocket serve with a pasted Secret.
    static var isWebSocketServe: Bool {
        resolved().useWebSocket
    }

    static func clearPairing() {
        pairToken = nil
        savedPIN = ""
        pinnedFingerprint = ""
    }

    static func savePairing(pin: String, fingerprint: String, token: String?) {
        savedPIN = pin
        pinnedFingerprint = fingerprint
        pairToken = token
    }

    static var lastSession: (id: String, cwd: String?)? {
        guard let id = UserDefaults.standard.string(forKey: lastSessionIDKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty else {
            return nil
        }
        let cwd = UserDefaults.standard.string(forKey: lastSessionCwdKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (id, cwd?.isEmpty == false ? cwd : nil)
    }

    static func saveLastSession(id: String, cwd: String?) {
        let sessionID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionID.isEmpty else { return }
        UserDefaults.standard.set(sessionID, forKey: lastSessionIDKey)
        if let cwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines),
           !cwd.isEmpty {
            UserDefaults.standard.set(cwd, forKey: lastSessionCwdKey)
        } else {
            UserDefaults.standard.removeObject(forKey: lastSessionCwdKey)
        }
    }

    static func clearLastSession() {
        UserDefaults.standard.removeObject(forKey: lastSessionIDKey)
        UserDefaults.standard.removeObject(forKey: lastSessionCwdKey)
    }

    // MARK: - Welcome top_bar location (last known companion cwd/git)

    private static let lastCwdKey = "GROK_LAST_CWD"
    private static let lastGitKey = "GROK_LAST_GIT_BRANCH"
    private static let lastWorktreeKey = "GROK_LAST_IS_WORKTREE"

    static func persistWelcomeLocation(cwd: String, gitBranch: String?, isWorktree: Bool) {
        if !cwd.isEmpty {
            UserDefaults.standard.set(cwd, forKey: lastCwdKey)
        }
        if let gitBranch {
            UserDefaults.standard.set(gitBranch, forKey: lastGitKey)
        }
        UserDefaults.standard.set(isWorktree, forKey: lastWorktreeKey)
    }

    static func welcomeLocation() -> (cwd: String, gitBranch: String?, isWorktree: Bool) {
        (
            UserDefaults.standard.string(forKey: lastCwdKey) ?? "",
            UserDefaults.standard.string(forKey: lastGitKey),
            UserDefaults.standard.bool(forKey: lastWorktreeKey)
        )
    }
}
