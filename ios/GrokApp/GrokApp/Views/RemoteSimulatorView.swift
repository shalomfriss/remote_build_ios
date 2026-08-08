// Copyright (c) 2026 Pedro Shakour
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import WebKit

struct RemoteSimulatorView: View {
    @EnvironmentObject private var model: AppModel
    @State private var webError: String?
    let isFullScreen: Bool
    let reloadID: UUID
    let onToggleFullScreen: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            Group {
                if let webError {
                    ContentUnavailableView {
                        Label("Simulator could not load", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(webError)
                    } actions: {
                        Button("Retry", action: retry)
                    }
                } else if let url = model.simulatorURL {
                    SimulatorWebView(
                        url: url,
                        fillsViewport: isFullScreen,
                        reloadID: reloadID,
                        error: $webError
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView {
                        Label("Simulator unavailable", systemImage: "iphone.slash")
                    } description: {
                        Text("Start agent-phone with simulator support, then reconnect.")
                    } actions: {
                        Button("Retry", action: retry)
                    }
                }
            }

            if model.simulatorBuildStatus == "queued" || model.simulatorBuildStatus == "building" {
                Label("Building and launching iOS app…", systemImage: "hammer")
                    .padding()
                    .background(.regularMaterial, in: Capsule())
                    .padding()
            } else if model.simulatorBuildStatus == "failed" {
                Label(
                    model.simulatorBuildError ?? "The iOS app could not be built.",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.red)
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding()
            }

            if isFullScreen {
                DraggableFullScreenExitButton(action: onToggleFullScreen)
                    .zIndex(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(model.theme.bgBase)
        .task {
            // The tab remains mounted beneath the full-screen cover and owns the
            // polling loop, so the cover should not start a duplicate monitor.
            guard !isFullScreen else { return }
            await model.monitorSimulator()
        }
    }

    private func retry() {
        webError = nil
        Task { await model.refreshSimulatorURL() }
    }
}

private struct DraggableFullScreenExitButton: View {
    private static let buttonSize: CGFloat = 52
    private static let edgeInset: CGFloat = 12

    let action: () -> Void

    @State private var position: CGPoint?
    @State private var dragOrigin: CGPoint?

    var body: some View {
        GeometryReader { geometry in
            Button("Exit Full Screen", systemImage: "arrow.down.right.and.arrow.up.left", action: action)
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .tint(.orange)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .frame(width: Self.buttonSize, height: Self.buttonSize)
                .contentShape(.circle)
                .position(resolvedPosition(in: geometry))
                .highPriorityGesture(
                    DragGesture(minimumDistance: 5, coordinateSpace: .named("simulator-full-screen"))
                        .onChanged { value in
                            let origin = dragOrigin ?? resolvedPosition(in: geometry)
                            dragOrigin = origin
                            position = clamped(
                                CGPoint(
                                    x: origin.x + value.translation.width,
                                    y: origin.y + value.translation.height
                                ),
                                in: geometry
                            )
                        }
                        .onEnded { value in
                            let origin = dragOrigin ?? resolvedPosition(in: geometry)
                            position = clamped(
                                CGPoint(
                                    x: origin.x + value.translation.width,
                                    y: origin.y + value.translation.height
                                ),
                                in: geometry
                            )
                            dragOrigin = nil
                        }
                )
                .accessibilityHint("Drag to move this button. Tap to leave full screen.")
        }
        .coordinateSpace(name: "simulator-full-screen")
    }

    private func resolvedPosition(in geometry: GeometryProxy) -> CGPoint {
        if let position {
            return clamped(position, in: geometry)
        }

        let radius = Self.buttonSize / 2
        return clamped(
            CGPoint(
                x: geometry.size.width - Self.edgeInset - radius,
                y: geometry.size.height - geometry.safeAreaInsets.bottom - Self.edgeInset - radius
            ),
            in: geometry
        )
    }

    private func clamped(_ point: CGPoint, in geometry: GeometryProxy) -> CGPoint {
        let radius = Self.buttonSize / 2
        let minimumX = Self.edgeInset + radius
        let maximumX = max(minimumX, geometry.size.width - Self.edgeInset - radius)
        let minimumY = geometry.safeAreaInsets.top + Self.edgeInset + radius
        let maximumY = max(
            minimumY,
            geometry.size.height - geometry.safeAreaInsets.bottom - Self.edgeInset - radius
        )
        return CGPoint(
            x: min(max(point.x, minimumX), maximumX),
            y: min(max(point.y, minimumY), maximumY)
        )
    }
}

private struct SimulatorWebView: UIViewRepresentable {
    let url: URL
    let fillsViewport: Bool
    let reloadID: UUID
    @Binding var error: String?

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.websiteDataStore = .nonPersistent()
        let simulatorScaleScript = fillsViewport
            ? "localStorage.setItem('serve-sim:simulator-frame-scale', '3');"
            : "localStorage.removeItem('serve-sim:simulator-frame-scale');"
        let fullScreenPresentationScript = fillsViewport ? """
            const fitSimulatorToViewport = () => {
                const status = document.querySelector('[aria-label="Simulator status"]');
                const shell = status?.parentElement;
                const viewport = shell?.parentElement;
                const surface = shell?.querySelector('.relative.max-h-full');
                const stream = surface?.firstElementChild;
                const floatingControls = document.querySelector('[aria-label="Open tools panel"]')?.parentElement;

                viewport?.setAttribute('data-build-buddy-simulator-viewport', '');
                shell?.setAttribute('data-build-buddy-simulator-shell', '');
                surface?.setAttribute('data-build-buddy-simulator-surface', '');
                stream?.setAttribute('data-build-buddy-simulator-stream', '');
                floatingControls?.setAttribute('data-build-buddy-simulator-controls', '');
            };

            const simulatorObserver = new MutationObserver(fitSimulatorToViewport);
            simulatorObserver.observe(document.documentElement, { childList: true, subtree: true });
            document.addEventListener('DOMContentLoaded', fitSimulatorToViewport);
            fitSimulatorToViewport();
            """ : ""
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: """
                \(simulatorScaleScript)
                const codecFallbackKey = 'build-buddy:codec-fallback-at';
                const codecFallbackAt = Number(sessionStorage.getItem(codecFallbackKey) || 0);
                const useCodecFallback = codecFallbackAt > 0 && Date.now() - codecFallbackAt < 60000;
                if (useCodecFallback) {
                    localStorage.setItem('serve-sim:codec', 'mjpeg');
                } else {
                    sessionStorage.removeItem(codecFallbackKey);
                    localStorage.removeItem('serve-sim:codec');
                }
                window.setTimeout(() => {
                    if (useCodecFallback) return;
                    const isStillConnecting = Array.from(document.querySelectorAll('span'))
                        .some((element) => element.textContent?.trim() === 'Connecting...');
                    if (isStillConnecting) {
                        sessionStorage.setItem(codecFallbackKey, String(Date.now()));
                        localStorage.setItem('serve-sim:codec', 'mjpeg');
                        window.location.reload();
                    }
                }, 10000);
                \(fullScreenPresentationScript)
                const style = document.createElement('style');
                style.textContent = `
                    a[href*="github.com/EvanBacon/serve-sim"],
                    a[aria-label="Open serve-sim"],
                    button[aria-label="Open WebKit DevTools"] {
                        display: none !important;
                    }

                    \(fillsViewport ? """
                    html, body, #root, #root > div,
                    [data-build-buddy-simulator-viewport],
                    [data-build-buddy-simulator-shell],
                    [data-build-buddy-simulator-surface],
                    [data-build-buddy-simulator-stream] {
                        width: 100% !important;
                        height: 100% !important;
                        max-width: none !important;
                        max-height: none !important;
                        box-sizing: border-box !important;
                    }

                    html, body, #root, #root > div,
                    [data-build-buddy-simulator-viewport] {
                        margin: 0 !important;
                        padding: 0 !important;
                        gap: 0 !important;
                        overflow: hidden !important;
                    }

                    [aria-label="Simulator status"],
                    [aria-label="Simulator actions"],
                    [aria-label="Accessibility overlay"],
                    [data-build-buddy-simulator-controls] {
                        display: none !important;
                    }

                    [data-build-buddy-simulator-shell] {
                        gap: 0 !important;
                    }

                    [data-build-buddy-simulator-surface] {
                        aspect-ratio: auto !important;
                    }

                    [data-build-buddy-simulator-surface] > :not([data-build-buddy-simulator-stream]) {
                        display: none !important;
                        pointer-events: none !important;
                    }

                    [data-build-buddy-simulator-stream] {
                        border-radius: 0 !important;
                        pointer-events: auto !important;
                    }
                    """ : "")
                `;
                document.documentElement.appendChild(style);
                """,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.bounces = false
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let reloadRequested = context.coordinator.consumeReloadRequest(reloadID)
        guard reloadRequested || webView.url != url else { return }
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(error: $error, reloadID: reloadID)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let error: Binding<String?>
        private var reloadID: UUID

        init(error: Binding<String?>, reloadID: UUID) {
            self.error = error
            self.reloadID = reloadID
        }

        func consumeReloadRequest(_ reloadID: UUID) -> Bool {
            guard self.reloadID != reloadID else { return false }
            self.reloadID = reloadID
            return true
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            if let response = navigationResponse.response as? HTTPURLResponse,
               response.statusCode >= 400 {
                error.wrappedValue = "The simulator endpoint returned HTTP \(response.statusCode). Restart agent-phone or check the tunnel."
                decisionHandler(.cancel)
                return
            }
            error.wrappedValue = nil
            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation?,
            withError navigationError: Error
        ) {
            error.wrappedValue = navigationError.localizedDescription
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation?,
            withError navigationError: Error
        ) {
            error.wrappedValue = navigationError.localizedDescription
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            webView.reload()
        }
    }
}
