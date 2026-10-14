// Copyright (c) 2026 Pedro Shakour
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import WebKit

struct RemoteSimulatorView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var session: SimulatorWebSession
    let isActive: Bool
    let isFullScreen: Bool
    let onToggleFullScreen: () -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                Group {
                    if !isActive {
                        Color.clear
                    } else if let webError = session.error {
                        ContentUnavailableView {
                            Label("Simulator could not load", systemImage: "exclamationmark.triangle")
                        } description: {
                            Text(webError)
                        } actions: {
                            Button("Retry", action: retry)
                        }
                    } else if let url = model.simulatorURL {
                        SimulatorWebView(
                            session: session,
                            url: url,
                            fillsViewport: isFullScreen
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
                    VStack(spacing: 12) {
                        Label(
                            model.simulatorBuildError ?? "The iOS app could not be built.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(.red)

                        Button("Retry Build", systemImage: "arrow.clockwise") {
                            model.runCurrentProject()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canRunCurrentProject)
                    }
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding()
                }

                if isFullScreen {
                    DraggableFullScreenExitButton(
                        containerSize: geometry.size,
                        safeAreaInsets: geometry.safeAreaInsets,
                        action: onToggleFullScreen
                    )
                    .zIndex(2)
                }
            }
            .coordinateSpace(name: "simulator-full-screen")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(model.theme.bgBase)
        .task(id: isActive) {
            // TabView keeps inactive tabs mounted. Only the visible simulator
            // owns a WebContent process and polling loop; full-screen replaces
            // the tab's renderer instead of creating a second live stream.
            guard isActive else { return }
            await model.monitorSimulator()
        }
    }

    private func retry() {
        session.retry()
        Task { await model.refreshSimulatorURL() }
    }
}

private struct DraggableFullScreenExitButton: View {
    private static let buttonSize: CGFloat = 52
    private static let edgeInset: CGFloat = 12

    let containerSize: CGSize
    let safeAreaInsets: EdgeInsets
    let action: () -> Void

    @State private var position: CGPoint?
    @State private var dragOrigin: CGPoint?

    var body: some View {
        Button("Exit Full Screen", systemImage: "arrow.down.right.and.arrow.up.left", action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .tint(.orange)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .frame(width: Self.buttonSize, height: Self.buttonSize)
            .contentShape(.circle)
            .position(resolvedPosition())
            .highPriorityGesture(
                DragGesture(minimumDistance: 5, coordinateSpace: .named("simulator-full-screen"))
                    .onChanged { value in
                        let origin = dragOrigin ?? resolvedPosition()
                        dragOrigin = origin
                        position = clamped(
                            CGPoint(
                                x: origin.x + value.translation.width,
                                y: origin.y + value.translation.height
                            )
                        )
                    }
                    .onEnded { value in
                        let origin = dragOrigin ?? resolvedPosition()
                        position = clamped(
                            CGPoint(
                                x: origin.x + value.translation.width,
                                y: origin.y + value.translation.height
                            )
                        )
                        dragOrigin = nil
                    }
            )
            .accessibilityHint("Drag to move this button. Tap to leave full screen.")
    }

    private func resolvedPosition() -> CGPoint {
        if let position {
            return clamped(position)
        }

        let radius = Self.buttonSize / 2
        return clamped(
            CGPoint(
                x: containerSize.width - Self.edgeInset - radius,
                y: containerSize.height - safeAreaInsets.bottom - Self.edgeInset - radius
            )
        )
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        let radius = Self.buttonSize / 2
        let minimumX = Self.edgeInset + radius
        let maximumX = max(minimumX, containerSize.width - Self.edgeInset - radius)
        let minimumY = safeAreaInsets.top + Self.edgeInset + radius
        let maximumY = max(
            minimumY,
            containerSize.height - safeAreaInsets.bottom - Self.edgeInset - radius
        )
        return CGPoint(
            x: min(max(point.x, minimumX), maximumX),
            y: min(max(point.y, minimumY), maximumY)
        )
    }
}

@MainActor
final class SimulatorWebSession: NSObject, ObservableObject, WKNavigationDelegate {
    @Published private(set) var error: String?

    let webView: WKWebView

    private var currentURL: URL?
    private var fillsViewport = false

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: Self.presentationScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )

        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        webView.navigationDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.allowsBackForwardNavigationGestures = false
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.bounces = false
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.delaysContentTouches = false
        webView.scrollView.canCancelContentTouches = false
    }

    func update(url: URL, fillsViewport: Bool) {
        let urlChanged = currentURL != url

        currentURL = url

        if urlChanged || webView.url == nil {
            error = nil
            webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        }

        if self.fillsViewport != fillsViewport {
            self.fillsViewport = fillsViewport
            applyPresentationMode()
        } else {
            notifyViewportChanged()
        }
    }

    func retry() {
        error = nil
        guard let currentURL else { return }
        webView.load(URLRequest(url: currentURL, cachePolicy: .reloadIgnoringLocalCacheData))
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        if let response = navigationResponse.response as? HTTPURLResponse,
           response.statusCode >= 400 {
            error = "The simulator endpoint returned HTTP \(response.statusCode). "
                + "Restart agent-phone or check the tunnel."
            decisionHandler(.cancel)
            return
        }
        error = nil
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        error = nil
        applyPresentationMode()
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation?,
        withError navigationError: Error
    ) {
        recordNavigationError(navigationError)
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation?,
        withError navigationError: Error
    ) {
        recordNavigationError(navigationError)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // WKWebView can terminate its renderer while detached during the
        // full-screen transition. Reload it in place so the stream recovers.
        webView.reload()
    }

    private func recordNavigationError(_ navigationError: Error) {
        let nsError = navigationError as NSError
        guard nsError.code != NSURLErrorCancelled else { return }
        error = navigationError.localizedDescription
    }

    private func applyPresentationMode() {
        let value = fillsViewport ? "true" : "false"
        webView.evaluateJavaScript(
            "document.documentElement.toggleAttribute('data-build-buddy-full-screen', \(value)); window.dispatchEvent(new Event('resize'));"
        )
    }

    private func notifyViewportChanged() {
        webView.evaluateJavaScript("window.dispatchEvent(new Event('resize'));")
    }

    private static let presentationScript = """
        (() => {
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

            let fitScheduled = false;
            const markSimulatorElements = () => {
                fitScheduled = false;
                const status = document.querySelector('[aria-label="Simulator status"]');
                const shell = status?.parentElement;
                const viewport = shell?.parentElement;
                const surface = shell?.querySelector('.relative.max-h-full');
                const floatingControls = document.querySelector('[aria-label="Open tools panel"]')?.parentElement;

                viewport?.setAttribute('data-build-buddy-simulator-viewport', '');
                shell?.setAttribute('data-build-buddy-simulator-shell', '');
                surface?.setAttribute('data-build-buddy-simulator-surface', '');
                floatingControls?.setAttribute('data-build-buddy-simulator-controls', '');
            };
            const scheduleFit = () => {
                if (fitScheduled) return;
                fitScheduled = true;
                window.requestAnimationFrame(markSimulatorElements);
            };
            new MutationObserver(scheduleFit).observe(
                document.documentElement,
                { childList: true, subtree: true }
            );
            document.addEventListener('DOMContentLoaded', scheduleFit, { once: true });
            scheduleFit();

            const style = document.createElement('style');
            style.textContent = `
                a[href*="github.com/EvanBacon/serve-sim"],
                a[aria-label="Open serve-sim"],
                button[aria-label="Open WebKit DevTools"] {
                    display: none !important;
                }

                html[data-build-buddy-full-screen],
                html[data-build-buddy-full-screen] body,
                html[data-build-buddy-full-screen] #root,
                html[data-build-buddy-full-screen] #root > div,
                html[data-build-buddy-full-screen] [data-build-buddy-simulator-viewport] {
                    width: 100% !important;
                    height: 100% !important;
                    box-sizing: border-box !important;
                }

                html[data-build-buddy-full-screen] body,
                html[data-build-buddy-full-screen] #root,
                html[data-build-buddy-full-screen] #root > div,
                html[data-build-buddy-full-screen] [data-build-buddy-simulator-viewport] {
                    margin: 0 !important;
                    padding: 0 !important;
                    gap: 0 !important;
                    overflow: hidden !important;
                }

                html[data-build-buddy-full-screen] [aria-label="Simulator status"],
                html[data-build-buddy-full-screen] [aria-label="Simulator actions"],
                html[data-build-buddy-full-screen] [aria-label="Accessibility overlay"],
                html[data-build-buddy-full-screen] [aria-label^="Resize simulator width"],
                html[data-build-buddy-full-screen] [data-build-buddy-simulator-controls] {
                    display: none !important;
                }

                html[data-build-buddy-full-screen] [data-build-buddy-simulator-shell] {
                    width: 100% !important;
                    height: 100% !important;
                    max-width: 100% !important;
                    max-height: 100% !important;
                    gap: 0 !important;
                }

                html[data-build-buddy-full-screen] [data-build-buddy-simulator-surface] {
                    max-width: 100vw !important;
                    max-height: 100vh !important;
                }
            `;
            document.documentElement.appendChild(style);
        })();
        """
}

private final class SimulatorWebContainerView: UIView {
    private weak var hostedWebView: WKWebView?

    func host(_ webView: WKWebView) {
        guard hostedWebView !== webView || webView.superview !== self else { return }
        hostedWebView = webView
        addSubview(webView)
        setNeedsLayout()
    }

    func detachHostedWebView() {
        guard hostedWebView?.superview === self else { return }
        hostedWebView?.removeFromSuperview()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        hostedWebView?.frame = bounds
    }
}

private struct SimulatorWebView: UIViewRepresentable {
    let session: SimulatorWebSession
    let url: URL
    let fillsViewport: Bool

    func makeUIView(context: Context) -> SimulatorWebContainerView {
        let container = SimulatorWebContainerView()
        container.host(session.webView)
        return container
    }

    func updateUIView(_ container: SimulatorWebContainerView, context: Context) {
        container.host(session.webView)
        session.update(url: url, fillsViewport: fillsViewport)
    }

    static func dismantleUIView(_ container: SimulatorWebContainerView, coordinator: Void) {
        container.detachHostedWebView()
    }
}
