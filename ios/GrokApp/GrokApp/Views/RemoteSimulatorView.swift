// Copyright (c) 2026 Pedro Shakour
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import WebKit

struct RemoteSimulatorView: View {
    @EnvironmentObject private var model: AppModel
    @State private var webError: String?
    let isFullScreen: Bool
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
                        error: $webError
                    )
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
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button("Exit Full Screen", systemImage: "arrow.down.right.and.arrow.up.left", action: onToggleFullScreen)
                            .labelStyle(.iconOnly)
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.circle)
                            .controlSize(.large)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.trailing, 82)
                .padding(.bottom, 4)
                .offset(y: 10)
            }
        }
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

private struct SimulatorWebView: UIViewRepresentable {
    let url: URL
    let fillsViewport: Bool
    @Binding var error: String?

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: """
                const style = document.createElement('style');
                style.textContent = `
                    a[href*="github.com/EvanBacon/serve-sim"],
                    a[aria-label="Open serve-sim"] {
                        display: none !important;
                    }
                    button[aria-label="Open WebKit DevTools"] {
                        display: none !important;
                    }
                `;
                document.documentElement.appendChild(style);
                """,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        if fillsViewport {
            // serve-sim restores its last simulator width from localStorage after
            // stream metadata arrives. Give the full-screen preview isolated
            // storage with the maximum scale so that late restore still fits the
            // expanded viewport instead of snapping back to the tab's width.
            configuration.websiteDataStore = .nonPersistent()
            configuration.userContentController.addUserScript(
                WKUserScript(
                    source: "localStorage.setItem('serve-sim:simulator-frame-scale', '3')",
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true
                )
            )
        }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard webView.url != url else { return }
        webView.load(URLRequest(url: url))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(error: $error)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let error: Binding<String?>

        init(error: Binding<String?>) {
            self.error = error
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
            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation?,
            withError error: Error
        ) {
            self.error.wrappedValue = error.localizedDescription
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation?,
            withError error: Error
        ) {
            self.error.wrappedValue = error.localizedDescription
        }
    }
}
