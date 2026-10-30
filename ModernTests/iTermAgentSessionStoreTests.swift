//
//  iTermAgentSessionStoreTests.swift
//  iTerm2
//

import XCTest
@testable import iTerm2SharedARC

final class iTermAgentSessionStoreTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func write(_ text: String, to name: String) throws -> String {
        let url = folder.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    func testCopilotSessionWithQuotedName() throws {
        let path = try write("""
            id: abc
            cwd: /tmp/project
            client_name: github/cli
            name: 'It''s: a test'
            updated_at: 2026-10-30T20:39:02.367Z
            """, to: "workspace.yaml")
        let modified = Date(timeIntervalSince1970: 0)
        let session = try XCTUnwrap(iTermAgentSessionStore.parseCopilotSession(id: "abc", yamlPath: path, modified: modified))
        XCTAssertEqual(session.title, "It's: a test")
        XCTAssertEqual(session.workingDirectory, "/tmp/project")
        XCTAssertGreaterThan(session.lastActive, modified)
        XCTAssertEqual(session.resumeCommand, "copilot --yolo --experimental --resume abc")
    }

    func testCopilotSessionSkipsUnnamedAndNonCLISessions() throws {
        let unnamed = try write("id: a\nclient_name: github/cli\n", to: "unnamed.yaml")
        XCTAssertNil(iTermAgentSessionStore.parseCopilotSession(id: "a", yamlPath: unnamed, modified: Date()))
        let sdk = try write("id: b\nclient_name: sdk\nname: Hello\n", to: "sdk.yaml")
        XCTAssertNil(iTermAgentSessionStore.parseCopilotSession(id: "b", yamlPath: sdk, modified: Date()))
    }

    func testClaudeTitlePrefersCustomThenAITitle() throws {
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"<command-name>/clear</command-name>"},"cwd":"/tmp/repo"}"#,
            #"{"type":"user","message":{"role":"user","content":"fix the\nbuild"},"cwd":"/tmp/repo"}"#,
            #"{"type":"ai-title","aiTitle":"Fix build","sessionId":"x"}"#,
        ]
        let path = try write(lines.joined(separator: "\n"), to: "x.jsonl")
        var session = try XCTUnwrap(iTermAgentSessionStore.parseClaudeSession(id: "x", path: path, modified: Date()))
        XCTAssertEqual(session.title, "Fix build")
        XCTAssertEqual(session.workingDirectory, "/tmp/repo")
        XCTAssertEqual(session.resumeCommand, "claude --resume x")

        let renamed = try write((lines + [#"{"type":"custom-title","customTitle":"Mine","sessionId":"x"}"#]).joined(separator: "\n"), to: "y.jsonl")
        session = try XCTUnwrap(iTermAgentSessionStore.parseClaudeSession(id: "x", path: renamed, modified: Date()))
        XCTAssertEqual(session.title, "Mine")
    }

    func testClaudeTitleFallsBackToFirstPrompt() throws {
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"<local-command-caveat>x</local-command-caveat>"}}"#,
            #"{"type":"user","message":{"role":"user","content":"fix the\nbuild"},"cwd":"/tmp/repo"}"#,
        ]
        let path = try write(lines.joined(separator: "\n"), to: "z.jsonl")
        let session = try XCTUnwrap(iTermAgentSessionStore.parseClaudeSession(id: "z", path: path, modified: Date()))
        XCTAssertEqual(session.title, "fix the build")
    }

    func testAgeString() {
        let now = Date()
        XCTAssertEqual(iTermAgentSessionsPanel.ageString(since: now.addingTimeInterval(-30), now: now), "now")
        XCTAssertEqual(iTermAgentSessionsPanel.ageString(since: now.addingTimeInterval(-15 * 60), now: now), "15m ago")
        XCTAssertEqual(iTermAgentSessionsPanel.ageString(since: now.addingTimeInterval(-5 * 3600), now: now), "5h ago")
        XCTAssertEqual(iTermAgentSessionsPanel.ageString(since: now.addingTimeInterval(-3 * 86400), now: now), "3d ago")
        XCTAssertEqual(iTermAgentSessionsPanel.ageString(since: now.addingTimeInterval(-21 * 86400), now: now), "3w ago")
    }
}
