// Copyright (c) 2026 Pedro Shakour
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import WebKit

struct RemoteSimulatorView: View {
    @EnvironmentObject private var model: AppModel
    @State private var webError: String?

    var body: some View {
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
                SimulatorWebView(url: url, error: $webError)
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
        .background(model.theme.bgBase)
        .task {
            await model.refreshSimulatorURL()
        }
    }

    private func retry() {
        webError = nil
        Task { await model.refreshSimulatorURL() }
    }
}

private struct SimulatorWebView: UIViewRepresentable {
    let url: URL
    @Binding var error: String?

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
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
