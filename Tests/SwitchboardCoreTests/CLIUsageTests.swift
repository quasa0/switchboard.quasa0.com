import XCTest
import Foundation
import Darwin
@testable import SwitchboardCore

final class CLIUsageTests: XCTestCase {
    func testUsagePercentagesNullWindowsAndResetDates() throws {
        let result = try CLIUsageClient.parseUsageResponse(Data(Self.reply.utf8), fetchedAt: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(result.fiveHour?.utilization, 12.5)
        XCTAssertEqual(result.fiveHour?.fraction, 0.125)
        XCTAssertEqual(result.sevenDay?.utilization, 103)
        XCTAssertEqual(result.sevenDay?.fraction, 1)
        XCTAssertNil(result.sevenDaySonnet)
        XCTAssertNotNil(result.fiveHour?.resetsAt)
        XCTAssertNotNil(result.sevenDay?.resetsAt)
        XCTAssertEqual(result.fetchedAt, Date(timeIntervalSince1970: 100))
    }

    func testUnavailableUsageIsNotShownAsZero() {
        let reply = """
        {"type":"control_response","response":{"subtype":"success","response":{"rate_limits_available":false,"rate_limits":null}}}
        """
        XCTAssertThrowsError(try CLIUsageClient.parseUsageResponse(Data(reply.utf8)))
    }

    func testRecognizedSubscriptionWithoutUsageDoesNotSuggestSigningIn() {
        let reply = """
        {"type":"control_response","response":{"subtype":"success","response":{"rate_limits_available":true,"rate_limits":null}}}
        """
        XCTAssertThrowsError(try CLIUsageClient.parseUsageResponse(Data(reply.utf8))) { error in
            XCTAssertTrue(error.localizedDescription.contains("recognized this subscription"))
            XCTAssertFalse(error.localizedDescription.contains("Sign in"))
        }
    }

    func testNamedModelWindowsPreserveLabelsAndIgnoreUnknownUtilization() throws {
        let reply = """
        {"type":"control_response","response":{"subtype":"success","response":{"rate_limits_available":true,"rate_limits":{"model_scoped":[{"display_name":"Fable 5","utilization":41.25,"resets_at":"2026-09-27T14:00:00Z"},{"display_name":"Another model","utilization":null,"resets_at":null}]}}}}
        """
        let result = try CLIUsageClient.parseUsageResponse(Data(reply.utf8))
        XCTAssertEqual(result.modelScoped.count, 1)
        XCTAssertEqual(result.modelScoped.first?.name, "Fable 5")
        XCTAssertEqual(result.modelScoped.first?.window.utilization, 41.25)
        XCTAssertNotNil(result.modelScoped.first?.window.resetsAt)
        XCTAssertTrue(try CLIUsageClient.parseUsageResponse(Data(Self.reply.utf8)).modelScoped.isEmpty)
    }

    func testFableRawServerLimitSurvivesMissingFeatureFlagProjection() throws {
        let reply = """
        {"type":"control_response","response":{"subtype":"success","response":{"rate_limits_available":true,"rate_limits":{"limits":[
          {"kind":"weekly_all","group":"weekly","percent":35,"resets_at":"2026-09-27T14:00:00Z"},
          {"kind":"weekly_scoped","group":"weekly","percent":0,"resets_at":"2026-09-27T14:00:00Z","scope":{"model":{"display_name":"Fable 5"}}},
          {"kind":"weekly_scoped","group":"weekly","percent":null,"resets_at":null,"scope":{"model":{"display_name":"Unknown usage"}}},
          {"kind":"weekly_scoped","group":"weekly","resets_at":null,"scope":{"model":{"display_name":"Missing usage"}}},
          {"kind":"weekly_scoped","group":"weekly","percent":8,"resets_at":null,"scope":{"surface":{"display_name":"Web"}}},
          {"kind":"session","group":"session","percent":75,"resets_at":null,"scope":{"model":{"display_name":"Fable 5"}}}
        ]}}}}
        """
        let result = try CLIUsageClient.parseUsageResponse(Data(reply.utf8))
        XCTAssertEqual(result.modelScoped.count, 1)
        XCTAssertEqual(result.modelScoped.first?.name, "Fable 5")
        XCTAssertEqual(result.modelScoped.first?.window.utilization, 0)
        XCTAssertNotNil(result.modelScoped.first?.window.resetsAt)
    }

    func testRawAndProjectedModelLimitsDeduplicateOnlyMatchingWindows() throws {
        let reply = """
        {"type":"control_response","response":{"subtype":"success","response":{"rate_limits_available":true,"rate_limits":{
          "limits":[
            {"kind":"weekly_scoped","group":"weekly","percent":42,"resets_at":"2026-09-27T14:00:00Z","scope":{"model":{"display_name":"Fable 5"}}},
            {"kind":"weekly_scoped","group":"weekly","percent":64,"resets_at":"2026-09-28T14:00:00Z","scope":{"model":{"display_name":"Fable 5"}}}
          ],
          "model_scoped":[
            {"display_name":"FABLE 5","utilization":42,"resets_at":"2026-09-27T14:00:00.000Z"},
            {"display_name":"Fable 5","utilization":7,"resets_at":"2026-09-29T14:00:00Z"}
          ]
        }}}}
        """
        let result = try CLIUsageClient.parseUsageResponse(Data(reply.utf8))
        XCTAssertEqual(result.modelScoped.map(\.name), ["Fable 5", "Fable 5", "Fable 5"])
        XCTAssertEqual(result.modelScoped.map(\.window.utilization), [42, 64, 7])
        XCTAssertEqual(Set(result.modelScoped.compactMap(\.window.resetsAt)).count, 3)
    }

    func testInvalidUsageResponseDoesNotExposeItsContents() {
        let secret = "synthetic-secret-must-not-appear"
        let reply = """
        {"type":"control_response","response":{"subtype":"error","error":"\(secret)"}}
        """
        XCTAssertThrowsError(try CLIUsageClient.parseUsageResponse(Data(reply.utf8))) { error in
            XCTAssertFalse(error.localizedDescription.contains(secret))
        }
    }

    func testCLIProtocolUsesNoModelPromptAndReapsChild() async throws {
        let fixture = try Fixture(script: """
        import json, os, sys, time
        from pathlib import Path
        Path(__file__ + '.pid').write_text(str(os.getpid()))
        assert '--no-session-persistence' in sys.argv
        assert '--strict-mcp-config' in sys.argv
        assert '--setting-sources' in sys.argv
        assert sys.argv[sys.argv.index('--setting-sources') + 1] == ''
        assert not any(k in os.environ for k in ['ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'CLAUDE_CODE_OAUTH_TOKEN', 'ANTHROPIC_BASE_URL', 'CLAUDE_CODE_USE_BEDROCK'])
        assert 'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC' not in os.environ
        assert os.environ['DISABLE_TELEMETRY'] == '1'
        assert os.environ['DISABLE_ERROR_REPORTING'] == '1'
        assert Path.cwd().name.startswith('switchboard-usage-')
        assert Path(os.environ['ANTHROPIC_CONFIG_DIR']).parent.resolve() == Path.cwd()
        first = json.loads(sys.stdin.readline())
        assert first['type'] == 'control_request'
        assert first['request']['subtype'] == 'initialize'
        print(json.dumps({'type':'control_response','response':{'subtype':'success','request_id':first['request_id'],'response':{}}}), flush=True)
        second = json.loads(sys.stdin.readline())
        assert second['type'] == 'control_request'
        assert second['request'] == {'subtype':'get_usage','skip_behaviors':True}
        reply = json.loads(\(Self.pythonString(Self.reply)))
        reply['response']['request_id'] = second['request_id']
        print(json.dumps(reply), flush=True)
        time.sleep(60)
        """)
        defer { fixture.remove() }
        let result = try await CLIUsageClient(executable: fixture.executable).fetch(installation: fixture.installation)
        XCTAssertEqual(result.fiveHour?.utilization, 12.5)
        try fixture.assertChildStopped()
    }

    func testTimeoutReapsChild() async throws {
        let fixture = try Fixture(script: Self.waitingScript)
        defer { fixture.remove() }
        do {
            _ = try await CLIUsageClient(executable: fixture.executable, timeout: 2).fetch(installation: fixture.installation)
            XCTFail("Expected timeout")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("in time"))
        }
        try fixture.assertChildStopped()
    }

    func testCancellationReapsChild() async throws {
        let fixture = try Fixture(script: Self.waitingScript)
        defer { fixture.remove() }
        let task = Task { try await CLIUsageClient(executable: fixture.executable).fetch(installation: fixture.installation) }
        // Wait for Python's readiness marker before testing cancellation of a running child.
        for _ in 0..<500 {
            if FileManager.default.fileExists(atPath: fixture.pidFile.path) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {} catch {
            XCTFail("Expected cancellation; received \(error.localizedDescription)")
        }
        try fixture.assertChildStopped()
    }

    private static let waitingScript = """
    import os, time
    from pathlib import Path
    Path(__file__ + '.pid').write_text(str(os.getpid()))
    time.sleep(60)
    """

    private static let reply = """
    {"type":"control_response","response":{"subtype":"success","response":{"rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":12.5,"resets_at":"2026-09-23T20:00:00.123Z"},"seven_day":{"utilization":103,"resets_at":"2026-09-27T14:00:00Z"},"seven_day_sonnet":null,"seven_day_opus":{"utilization":null,"resets_at":null}}}}}
    """

    private static func pythonString(_ string: String) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: string, options: [.fragmentsAllowed]), encoding: .utf8)!
    }

    private struct Fixture {
        let directory: URL
        let executable: URL
        let installation: ClaudeInstallation
        var pidFile: URL { URL(fileURLWithPath: executable.path + ".pid") }

        init(script: String) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("switchboard-cli-test-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            executable = directory.appendingPathComponent("fixture")
            try Data(("#!/usr/bin/env python3\n" + script + "\n").utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            installation = .isolated(at: directory.appendingPathComponent("profile"))
        }

        func assertChildStopped(file: StaticString = #filePath, line: UInt = #line) throws {
            let contents = try String(contentsOf: pidFile, encoding: .utf8)
            let pid = try XCTUnwrap(Int32(contents), file: file, line: line)
            XCTAssertEqual(kill(pid, 0), -1, file: file, line: line)
            XCTAssertEqual(errno, ESRCH, file: file, line: line)
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }
}
