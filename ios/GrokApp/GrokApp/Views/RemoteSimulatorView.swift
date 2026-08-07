// Copyright (c) 2026 Pedro Shakour
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import UIKit

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
                        url: previewURL(for: url),
                        fillsViewport: isFullScreen,
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
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button("Exit Full Screen", systemImage: "arrow.down.right.and.arrow.up.left", action: onToggleFullScreen)
                            .labelStyle(.iconOnly)
                            .buttonStyle(.bordered)
                            .tint(.orange)
                            .buttonBorderShape(.circle)
                            .controlSize(.large)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.trailing, 30)
                .padding(.bottom, 32)
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

    private func previewURL(for url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        var queryItems = components.queryItems ?? []
        if !queryItems.contains(where: { $0.name == "codec" }) {
            queryItems.append(URLQueryItem(name: "codec", value: "mjpeg"))
            components.queryItems = queryItems
        }
        return components.url ?? url
    }
}

private struct SimulatorWebView: UIViewRepresentable {
    let url: URL
    let fillsViewport: Bool
    @Binding var error: String?

    func makeUIView(context: Context) -> SimulatorImageView {
        let imageView = SimulatorImageView()
        imageView.backgroundColor = .clear
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        context.coordinator.imageView = imageView
        return imageView
    }

    func updateUIView(_ imageView: SimulatorImageView, context: Context) {
        imageView.contentMode = .scaleAspectFit
        context.coordinator.start(baseURL: url)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(error: $error)
    }

    static func dismantleUIView(_ uiView: SimulatorImageView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let error: Binding<String?>
        private var discoveryTask: URLSessionDataTask?
        private var streamTask: URLSessionDataTask?
        private var streamSession: URLSession?
        private var buffer = Data()
        private var currentBaseURL: URL?
        weak var imageView: UIImageView?

        init(error: Binding<String?>) {
            self.error = error
        }

        func start(baseURL: URL) {
            guard currentBaseURL != baseURL else { return }
            stop()
            currentBaseURL = baseURL

            guard let apiURL = endpointURL(path: "/api", relativeTo: baseURL) else {
                report("The simulator endpoint is invalid.")
                return
            }

            discoveryTask = URLSession.shared.dataTask(with: apiURL) { [weak self] data, response, requestError in
                guard let self, self.currentBaseURL == baseURL else { return }
                if let requestError {
                    self.report(requestError.localizedDescription)
                    return
                }
                guard let http = response as? HTTPURLResponse, http.statusCode < 400,
                      let data,
                      let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let advertisedStream = payload["streamUrl"] as? String,
                      let streamURL = URL(string: advertisedStream),
                      let reachableStreamURL = self.endpointURL(
                        path: streamURL.path,
                        relativeTo: baseURL
                      ) else {
                    self.report("The simulator did not provide a usable video stream.")
                    return
                }
                self.openStream(reachableStreamURL)
            }
            discoveryTask?.resume()
        }

        func stop() {
            discoveryTask?.cancel()
            streamTask?.cancel()
            streamSession?.invalidateAndCancel()
            discoveryTask = nil
            streamTask = nil
            streamSession = nil
            buffer.removeAll(keepingCapacity: false)
            currentBaseURL = nil
        }

        private func openStream(_ streamURL: URL) {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
            streamSession = session
            streamTask = session.dataTask(with: streamURL)
            streamTask?.resume()
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            buffer.append(data)
            let startMarker = Data([0xFF, 0xD8])
            let endMarker = Data([0xFF, 0xD9])

            while let start = buffer.range(of: startMarker),
                  let end = buffer.range(of: endMarker, in: start.lowerBound..<buffer.endIndex) {
                let frame = buffer.subdata(in: start.lowerBound..<end.upperBound)
                buffer.removeSubrange(buffer.startIndex..<end.upperBound)
                guard let image = UIImage(data: frame) else { continue }
                DispatchQueue.main.async { [weak self] in
                    self?.error.wrappedValue = nil
                    self?.imageView?.image = image
                }
            }

            if buffer.count > 12_000_000 {
                buffer.removeAll(keepingCapacity: true)
            }
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didCompleteWithError completionError: Error?
        ) {
            if let completionError = completionError as? URLError,
               completionError.code != .cancelled {
                report(completionError.localizedDescription)
            }
        }

        private func endpointURL(path: String, relativeTo baseURL: URL) -> URL? {
            guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
                return nil
            }
            components.path = path
            components.query = nil
            components.fragment = nil
            return components.url
        }

        private func report(_ message: String) {
            DispatchQueue.main.async { [weak self] in
                self?.error.wrappedValue = message
            }
        }
    }
}

private final class SimulatorImageView: UIImageView {
    override var intrinsicContentSize: CGSize { .zero }
}
