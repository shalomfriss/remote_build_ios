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

    func testRejectsNonTCPOrIncompleteEndpoint() {
        XCTAssertNil(CompanionConfig.parseRemoteAddress("https://example.test:7391"))
        XCTAssertNil(CompanionConfig.parseRemoteAddress("tcp://example.test"))
        XCTAssertNil(CompanionConfig.parseRemoteAddress("tcp://example.test:70000"))
    }
}
