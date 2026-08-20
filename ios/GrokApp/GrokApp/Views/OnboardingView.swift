// Copyright (c) 2026 Pedro Shakour
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @FocusState private var focused: Field?
    @State private var showAdvanced = false
    @State private var showLegacyBridge = false
    var isSettings: Bool = false

    private enum Field { case host, port, secret, fingerprint }

    private var isChecking: Bool {
        if case .checking = model.connectionPhase { return true }
        return false
    }

    private var isConnectedOK: Bool {
        if case .succeeded = model.connectionPhase { return true }
        return model.acp.sessionReady
    }

    var body: some View {
        let theme = model.theme
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header(theme: theme)
                secretConnectSection(theme: theme)
                connectionStatus(theme: theme)
                entryPointsSection(theme: theme)

                DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                    advancedSection(theme: theme)
                }
                .font(.caption.monospaced())
                .foregroundStyle(theme.textSecondary)
                .tint(theme.textPrimary)

                if showAdvanced {
                    DisclosureGroup("Discover bridge on LAN", isExpanded: $showLegacyBridge) {
                        legacyBridgeSection(theme: theme)
                    }
                    .font(.caption.monospaced())
                    .foregroundStyle(theme.textSecondary)
                    .tint(theme.textPrimary)
                }

            }
            .padding(24)
        }
        .background(theme.bgBase)
        .onAppear {
            model.loadConnectionDrafts()
            if model.acpHostDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                model.acpHostDraft = "127.0.0.1"
            }
            if model.acpPortDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || model.acpPortDraft == String(CompanionConfig.defaultWebSocketPort) {
                model.acpPortDraft = String(CompanionConfig.defaultPort)
            }
            model.startLegacyBonjourBrowse()
        }
        .onChange(of: model.companionBrowser.peers) { _, peers in
            model.selectBonjourPeerIfAppropriate(from: peers)
        }
        .onChange(of: focused) { _, field in
            if field == .host {
                model.clearBonjourPreference()
            }
        }
        .onDisappear { model.stopLegacyBonjourBrowse() }
    }

    private func header(theme: GrokTheme) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("← Back") { model.showWelcome() }
                .font(.body.monospaced())
                .foregroundStyle(theme.textSecondary)
                .disabled(isChecking)
            Text(isSettings ? "Connection" : "Setup")
                .font(.title3.monospaced().weight(.semibold))
                .foregroundStyle(theme.textPrimary)
            Text("Run `agent-phone` on your Mac, then paste its pairing PIN here.")
                .font(.caption.monospaced())
                .foregroundStyle(theme.textSecondary)
        }
    }

    private func secretConnectSection(theme: GrokTheme) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mac terminal")
                .font(.caption.monospaced())
                .foregroundStyle(theme.textSecondary)
            Text("./companion/scripts/agent-phone\n# remote: add --ngrok; copy endpoint + PIN")
                .font(.caption2.monospaced())
                .foregroundStyle(theme.textPrimary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.bgTerminal)
                .overlay(Rectangle().stroke(theme.promptBorder, lineWidth: 1))

            Text("Companion address")
                .font(.caption.monospaced())
                .foregroundStyle(theme.textSecondary)
            TextField("auto-discovered or tcp://host:port", text: $model.acpHostDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.caption.monospaced())
                .foregroundStyle(theme.textPrimary)
                .padding(12)
                .background(theme.bgTerminal)
                .overlay(Rectangle().stroke(focused == .host ? theme.textPrimary : theme.promptBorder, lineWidth: 1))
                .focused($focused, equals: .host)
                .disabled(isChecking || isConnectedOK)

            Text("Pairing PIN")
                .font(.caption.monospaced())
                .foregroundStyle(theme.textSecondary)
            TextField("from agent-phone", text: $model.pairPinDraft)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.title3.monospaced())
                .foregroundStyle(theme.textPrimary)
                .padding(12)
                .background(theme.bgTerminal)
                .overlay(Rectangle().stroke(focused == .secret ? theme.textPrimary : theme.promptBorder, lineWidth: 1))
                .focused($focused, equals: .secret)
                .disabled(isChecking || isConnectedOK)

            if isConnectedOK {
                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Circle().fill(theme.accentSuccess).frame(width: 6, height: 6)
                        Text("connected")
                            .font(.body.monospaced())
                            .foregroundStyle(theme.textPrimary)
                    }
                    Button("Disconnect", systemImage: "cable.connector.slash") {
                        model.disconnectFromCompanion()
                    }
                    .font(.caption.monospaced())
                    .foregroundStyle(theme.accentError)
                    .frame(minHeight: 44)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .overlay(Rectangle().stroke(theme.promptBorder, lineWidth: 1))
            } else {
                Button {
                    model.connectWithPINAndVerify()
                } label: {
                    HStack(spacing: 8) {
                        if isChecking {
                            ProgressView()
                                .controlSize(.mini)
                                .tint(theme.textPrimary)
                        }
                        Text(isChecking ? "connecting…" : (model.isManuallyDisconnected ? "reconnect" : "connect"))
                            .font(.body.monospaced())
                            .foregroundStyle(theme.bgBase)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(theme.textPrimary)
                }
                .buttonStyle(.plain)
                .disabled(isChecking)
            }
        }
    }

    private func entryPointsSection(theme: GrokTheme) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Saved entry points")
                    .font(.caption.monospaced())
                    .foregroundStyle(theme.textSecondary)
                Spacer()
                Button("Save Entry Point", systemImage: "plus", action: model.saveCurrentEntryPoint)
                    .font(.caption.monospaced())
                    .disabled(isChecking || model.acpHostDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if model.savedEntryPoints.isEmpty {
                Text("Save an address to switch between LAN and remote companions quickly.")
                    .font(.caption.monospaced())
                    .foregroundStyle(theme.textSecondary)
            } else {
                ForEach(model.savedEntryPoints) { entryPoint in
                    HStack(spacing: 8) {
                        Button {
                            model.useEntryPoint(entryPoint)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entryPoint.name)
                                    .font(.body.monospaced())
                                    .foregroundStyle(theme.textPrimary)
                                Text(entryPoint.address)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(theme.textSecondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .disabled(isChecking)

                        Button("Delete \(entryPoint.name)", systemImage: "trash") {
                            model.deleteEntryPoint(entryPoint)
                        }
                        .labelStyle(.iconOnly)
                        .foregroundStyle(theme.accentError)
                        .frame(minWidth: 44, minHeight: 44)
                        .disabled(isChecking)
                    }
                    .padding(.horizontal, 10)
                    .background(theme.bgTerminal)
                    .overlay(Rectangle().stroke(theme.promptBorder, lineWidth: 1))
                }
            }
        }
    }

    @ViewBuilder
    private func connectionStatus(theme: GrokTheme) -> some View {
        switch model.connectionPhase {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: 8) {
                Circle().fill(theme.textSecondary).frame(width: 6, height: 6)
                Text("connecting…")
                    .font(.caption.monospaced())
                    .foregroundStyle(theme.textSecondary)
            }
        case .succeeded:
            VStack(alignment: .leading, spacing: 12) {
                Button {
                    model.finishSetupAfterSuccessfulConnect()
                } label: {
                    Text("continue")
                        .font(.body.monospaced())
                        .foregroundStyle(theme.bgBase)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(theme.textPrimary)
                }
                .buttonStyle(.plain)
            }
        case .failed(let message):
            HStack(alignment: .top, spacing: 8) {
                Circle().fill(theme.accentError).frame(width: 6, height: 6).padding(.top, 4)
                Text(message)
                    .font(.caption.monospaced())
                    .foregroundStyle(theme.textPrimary)
            }
        }
    }

    private func advancedSection(theme: GrokTheme) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Local bridge port")
                .font(.caption2.monospaced())
                .foregroundStyle(theme.textSecondary)
            TextField("port", text: $model.acpPortDraft)
                .keyboardType(.numberPad)
                .font(.caption.monospaced())
                .padding(10)
                .background(theme.bgTerminal)
                .overlay(Rectangle().stroke(theme.promptBorder, lineWidth: 1))
                .focused($focused, equals: .port)
                .disabled(isChecking)
        }
        .padding(.top, 8)
    }

    private func legacyBridgeSection(theme: GrokTheme) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Bonjour discovery for the same TLS bridge on your local network.")
                .font(.caption2.monospaced())
                .foregroundStyle(theme.textSecondary)
            if model.companionBrowser.peers.isEmpty {
                Text("No Bonjour peers found")
                    .font(.caption.monospaced())
                    .foregroundStyle(theme.textSecondary)
            } else {
                ForEach(model.companionBrowser.peers) { peer in
                    Button {
                        model.selectBonjourPeer(peer)
                    } label: {
                        HStack {
                            Text(peer.name)
                                .font(.caption.monospaced())
                                .foregroundStyle(theme.textPrimary)
                            Spacer()
                            if let short = peer.fingerprintShort {
                                Text(short)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(theme.textSecondary)
                            }
                        }
                        .padding(10)
                        .background(theme.bgTerminal)
                        .overlay(Rectangle().stroke(theme.promptBorder, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            TextField("TLS cert fingerprint (optional)", text: $model.fingerprintDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.caption.monospaced())
                .padding(10)
                .background(theme.bgTerminal)
                .overlay(Rectangle().stroke(theme.promptBorder, lineWidth: 1))
                .focused($focused, equals: .fingerprint)
                .disabled(isChecking)
        }
        .padding(.top, 8)
    }
}
