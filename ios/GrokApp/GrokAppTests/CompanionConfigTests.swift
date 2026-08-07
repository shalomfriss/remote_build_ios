// Copyright (c) 2026 Pedro Shakour
// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import GrokApp

final class CompanionConfigTests: XCTestCase {
    func testParsesNgrokTCPEndpoint() {
        XCTAssertEqual(
            CompanionConfig.parseRemoteAddress("tcp://2.tcp.us-cal-1.ngrok.io:24162"),
            .init(host: "2.tcp.us-cal-1.ngrok.io", port: 24_162)
        )
    }

    func testParsesHostAndPortWithoutScheme() {
        XCTAssertEqual(
            CompanionConfig.parseRemoteAddress("example.test:7391"),
            .init(host: "example.test", port: 7_391)
        )
    }

    func testParsesSecureWebSocketEndpointOnDefaultHTTPSPort() {
        XCTAssertEqual(
            CompanionConfig.parseRemoteAddress("wss://build-buddy.ngrok-free.app/acp"),
            .init(
                host: "build-buddy.ngrok-free.app",
                port: 443,
                useTLS: true,
                useWebSocket: true
            )
        )
    }

    func testPort443WebSocketCannotBeDowngradedToPlaintext() {
        XCTAssertTrue(
            CompanionConfig.normalizedTLS(
                requestedTLS: false,
                useWebSocket: true,
                port: 443
            )
        )
        XCTAssertFalse(
            CompanionConfig.normalizedTLS(
                requestedTLS: false,
                useWebSocket: true,
                port: 80
            )
        )
    }

    func testNgrokPlainWebSocketIsMigratedToSecurePort() {
        XCTAssertEqual(
            CompanionConfig.parseRemoteAddress("ws://build-buddy.ngrok-free.app:80/acp"),
            .init(
                host: "build-buddy.ngrok-free.app",
                port: 443,
                useTLS: true,
                useWebSocket: true
            )
        )
    }

    func testRejectsNonTCPOrIncompleteEndpoint() {
        XCTAssertNil(CompanionConfig.parseRemoteAddress("tcp://example.test"))
        XCTAssertNil(CompanionConfig.parseRemoteAddress("tcp://example.test:70000"))
    }

    func testRecognizesPublicHostAsRemotelyReachable() {
        XCTAssertTrue(CompanionConfig.isRemotelyReachableHost("6.tcp.us-cal-1.ngrok.io"))
        XCTAssertTrue(CompanionConfig.isRemotelyReachableHost("203.0.113.10"))
    }

    func testRejectsLANAndLoopbackHostsAsRemoteFallbacks() {
        XCTAssertFalse(CompanionConfig.isRemotelyReachableHost("127.0.0.1"))
        XCTAssertFalse(CompanionConfig.isRemotelyReachableHost("192.168.1.215"))
        XCTAssertFalse(CompanionConfig.isRemotelyReachableHost("10.0.0.4"))
        XCTAssertFalse(CompanionConfig.isRemotelyReachableHost("build-mac.local"))
    }
}
