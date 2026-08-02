// Copyright (c) 2026 Pedro Shakour
// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import GrokApp

final class ACPProtocolTests: XCTestCase {
    func testDecodePairResult() {
        let line = #"{"grok_pair_result":{"ok":true,"token":"abc123"}}"#
        let result = ACPProtocol.decodePairResult(line)
        XCTAssertEqual(result?.ok, true)
        XCTAssertEqual(result?.token, "abc123")
    }

    func testEncodeInitializeRequest() {
        let req = ACPProtocol.JSONRPCRequest(
            method: "initialize",
            params: ACPProtocol.initializeParams(),
            id: 1
        )
        let data = ACPProtocol.encodeLine(req)
        XCTAssertNotNil(data)
        let s = String(data: data!, encoding: .utf8)!
        XCTAssertTrue(s.contains("initialize"))
        XCTAssertFalse(s.contains("\\/"))
    }

    func testJSONValueRoundTrip() throws {
        let value = ACPProtocol.JSONValue.object([
            "sessionId": .string("sess-1"),
            "count": .int(3),
        ])
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(ACPProtocol.JSONValue.self, from: data)
        XCTAssertEqual(decoded["sessionId"]?.stringValue, "sess-1")
    }

    func testSessionLoadUsesSelectedAbsoluteWorkingDirectory() {
        let params = ACPProtocol.sessionLoadParams(
            sessionId: "session-1",
            cwd: "/tmp/project"
        )
        XCTAssertEqual(params["sessionId"]?.stringValue, "session-1")
        XCTAssertEqual(params["cwd"]?.stringValue, "/tmp/project")
    }

    func testSessionNewIncludesTrimmedProjectName() {
        let params = ACPProtocol.sessionNewParams(projectName: "  Trail Notes  ")
        XCTAssertEqual(params["projectName"]?.stringValue, "Trail Notes")
    }

    func testSessionListEntryPrefersProjectName() {
        let entry = SessionListEntry(
            id: "session-1",
            title: "Build a notes app",
            cwd: "/tmp/trail-notes",
            projectName: "Trail Notes"
        )

        XCTAssertEqual(entry.displayName, "Trail Notes")
    }
}
