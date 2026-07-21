// Copyright (c) 2026 Pedro Shakour
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import WebKit

struct RemoteSimulatorView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if let url = model.simulatorURL {
                SimulatorWebView(url: url)
            } else {
                ContentUnavailableView {
                    Label("Simulator unavailable", systemImage: "iphone.slash")
                } description: {
                    Text("Start agent-phone with simulator support, then reconnect.")
                } actions: {
                    Button("Retry") {
                        Task { await model.refreshSimulatorURL() }
                    }
                }
            }
        }
        .background(model.theme.bgBase)
        .task {
            if model.simulatorURL == nil {
                await model.refreshSimulatorURL()
            }
        }
    }
}

private struct SimulatorWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard webView.url != url else { return }
        webView.load(URLRequest(url: url))
    }
}
