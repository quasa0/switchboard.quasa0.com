import XCTest
import Foundation
import Darwin
@testable import SwitchboardCore

final class CodexUsageTests: XCTestCase {
    func testCreditOnlyResponsePreservesDecimalBalancePlanAndUnlimited() throws {
        let reply = """
        {"result":{"rateLimitsByLimitId":{
          "codex":{"planType":"pro","credits":{"hasCredits":true,"unlimited":false,"balance":"65000.125"}},
          "workspace":{"credits":{"hasCredits":true,"unlimited":true,"balance":null}}
        }}}
        """
        let usage = try CodexUsageClient.parseUsageResponse(Data(reply.utf8))
        XCTAssertNil(usage.fiveHour)
        XCTAssertNil(usage.sevenDay)
        XCTAssertNil(usage.manualResets)
        XCTAssertEqual(usage.reportedPlan, "pro")
        XCTAssertEqual(usage.creditBalances?.map(\.id), ["codex", "workspace"])
        XCTAssertEqual(usage.creditBalances?.first?.balance, "65000.125")
        XCTAssertEqual(usage.creditBalances?.last?.unlimited, true)
        XCTAssertNil(usage.creditBalances?.last?.balance)
        XCTAssertEqual(try JSONDecoder().decode(UsageSnapshot.self, from: JSONEncoder().encode(usage)), usage)
    }

    func testZeroUnknownAndMissingCreditBalancesStayDistinct() throws {
        XCTAssertNil(try CodexUsageClient.parseUsageResponse(Data(Self.reply.utf8)).creditBalances)
        for balance in ["\"0\"", "null"] {
            let reply = "{\"result\":{\"rateLimits\":{\"credits\":{\"hasCredits\":false,\"unlimited\":false,\"balance\":\(balance)}}}}"
            let usage = try CodexUsageClient.parseUsageResponse(Data(reply.utf8))
            XCTAssertEqual(usage.creditBalances?.first?.hasCredits, false)
            XCTAssertEqual(usage.creditBalances?.first?.balance, balance == "null" ? nil : "0")
        }
        for balance in ["-1", "NaN", "1,000", "USD 10", "1e5"] {
            let reply = "{\"result\":{\"rateLimits\":{\"credits\":{\"hasCredits\":true,\"unlimited\":false,\"balance\":\"\(balance)\"}}}}"
            XCTAssertThrowsError(try CodexUsageClient.parseUsageResponse(Data(reply.utf8)))
        }
    }

    func testMainWindowsUseActualDurationAndUnixSeconds() throws {
        let result = try CodexUsageClient.parseUsageResponse(Data(Self.reply.utf8), fetchedAt: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(result.fiveHour?.utilization, 12)
        XCTAssertEqual(result.fiveHour?.fraction, 0.12)
        XCTAssertEqual(result.sevenDay?.utilization, 103)
        XCTAssertEqual(result.sevenDay?.fraction, 1)
        XCTAssertEqual(result.fiveHour?.resetsAt, Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertNil(result.sevenDay?.resetsAt)
        XCTAssertEqual(result.fetchedAt, Date(timeIntervalSince1970: 100))
        XCTAssertTrue(result.modelScoped.isEmpty)
    }

    func testMapTakesPrecedenceAndRetainsAllNamedBuckets() throws {
        let reply = """
        {"result":{
          "rateLimits":{"limitId":"codex","primary":{"usedPercent":99,"windowDurationMins":300}},
          "rateLimitsByLimitId":{
            "zeta":{"limitName":"Research","primary":{"usedPercent":8,"windowDurationMins":10080}},
            "codex":{"secondary":{"usedPercent":31,"windowDurationMins":300}},
            "alpha":{"normalModelSlug":"Fast model","primary":{"usedPercent":14,"windowDurationMins":60}}
          }
        }}
        """
        let result = try CodexUsageClient.parseUsageResponse(Data(reply.utf8))
        XCTAssertEqual(result.fiveHour?.utilization, 31)
        XCTAssertEqual(result.modelScoped.map(\.name), ["Fast model · 1-hour limit", "Research · weekly limit"])
        XCTAssertEqual(result.modelScoped.map(\.window.utilization), [14, 8])
    }

    func testUnknownDurationsRemainUnknownInsteadOfFiveHourOrWeekly() throws {
        let reply = """
        {"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":0},"secondary":{"usedPercent":41,"windowDurationMins":null}}}}
        """
        let result = try CodexUsageClient.parseUsageResponse(Data(reply.utf8))
        XCTAssertNil(result.fiveHour)
        XCTAssertNil(result.sevenDay)
        XCTAssertEqual(result.modelScoped.map(\.name), ["Codex · primary limit · duration unavailable", "Codex · secondary limit · duration unavailable"])
        XCTAssertEqual(result.modelScoped.first?.window.utilization, 0)
    }

    func testDistinctBucketsWithMatchingLabelsAndValuesArePreserved() throws {
        let reply = """
        {"result":{"rateLimitsByLimitId":{
          "a":{"limitName":"Model","primary":{"usedPercent":20,"windowDurationMins":60}},
          "b":{"limitName":"Model","primary":{"usedPercent":20,"windowDurationMins":60}}
        }}}
        """
        let result = try CodexUsageClient.parseUsageResponse(Data(reply.utf8))
        XCTAssertEqual(result.modelScoped.count, 2)
    }

    func testSpecificBucketCannotMasqueradeAsGeneralFiveHourLimit() throws {
        let reply = """
        {"result":{"rateLimits":{"limitId":"codex_model","limitName":"Special model","primary":{"usedPercent":75,"windowDurationMins":300}}}}
        """
        let result = try CodexUsageClient.parseUsageResponse(Data(reply.utf8))
        XCTAssertNil(result.fiveHour)
        XCTAssertEqual(result.modelScoped.first?.name, "Special model · 5-hour limit")
    }

    func testNonstandardWindowDurationsStayVisible() throws {
        let reply = """
        {"result":{"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":15},"secondary":{"usedPercent":80,"windowDurationMins":2880}}}}
        """
        let result = try CodexUsageClient.parseUsageResponse(Data(reply.utf8))
        XCTAssertEqual(result.modelScoped.map(\.name), ["Codex · 15-minute limit", "Codex · 2-day limit"])
    }

    func testNullOrMissingUsageDoesNotBecomeZero() {
        for reply in ["{\"result\":{}}", "{\"result\":{\"rateLimits\":{\"primary\":null,\"secondary\":null}}}"] {
            XCTAssertThrowsError(try CodexUsageClient.parseUsageResponse(Data(reply.utf8)))
        }
    }

    func testManualResetDetailsPreserveCountExpiryAndProviderFields() throws {
        let reply = """
        {"result":{"rateLimitResetCredits":{"availableCount":4,"credits":[
          {"id":"credit-a","resetType":"codexRateLimits","status":"available","grantedAt":1780000000,"expiresAt":1790000000,"title":"Earned reset","description":"Provider explanation"},
          {"id":"credit-b","resetType":"codexRateLimits","status":"redeeming","grantedAt":1770000000,"expiresAt":1780000000,"title":null,"description":null},
          {"id":"credit-c","resetType":"futureResetType","status":"futureStatus","grantedAt":1775000000,"expiresAt":null}
        ]}}}
        """
        let result = try CodexUsageClient.parseUsageResponse(Data(reply.utf8))
        let summary = try XCTUnwrap(result.manualResets)
        XCTAssertEqual(summary.availableCount, 4, "A capped detail list must not replace the provider count")
        let credits = try XCTUnwrap(summary.credits)
        XCTAssertEqual(credits.map(\.id), ["credit-a", "credit-b", "credit-c"])
        XCTAssertEqual(credits[0].grantedAt, Date(timeIntervalSince1970: 1_780_000_000))
        XCTAssertEqual(credits[0].expiresAt, Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertEqual(credits[0].title, "Earned reset")
        XCTAssertEqual(credits[0].detail, "Provider explanation")
        XCTAssertEqual(credits[1].status, "redeeming")
        XCTAssertEqual(credits[1].expiresAt, Date(timeIntervalSince1970: 1_780_000_000), "Past due dates remain provider data")
        XCTAssertNil(credits[2].expiresAt)
        XCTAssertEqual(credits[2].resetType, "futureResetType")
        XCTAssertEqual(credits[2].status, "futureStatus")
        XCTAssertNil(result.fiveHour)
        XCTAssertNil(result.sevenDay)
    }

    func testUnavailableManualResetsDifferFromReportedZero() throws {
        let missing = try CodexUsageClient.parseUsageResponse(Data(Self.reply.utf8))
        XCTAssertNil(missing.manualResets)
        let nullReply = """
        {"result":{"rateLimits":{"primary":{"usedPercent":10,"windowDurationMins":300}},"rateLimitResetCredits":null}}
        """
        XCTAssertNil(try CodexUsageClient.parseUsageResponse(Data(nullReply.utf8)).manualResets)
        let zeroReply = """
        {"result":{"rateLimitResetCredits":{"availableCount":0,"credits":[]}}}
        """
        let reportedZero = try CodexUsageClient.parseUsageResponse(Data(zeroReply.utf8))
        XCTAssertEqual(reportedZero.manualResets?.availableCount, 0)
        XCTAssertEqual(reportedZero.manualResets?.credits, [])
    }

    func testKnownManualResetCountDoesNotInventMissingDetails() throws {
        for details in ["", ",\"credits\":null"] {
            let reply = "{\"result\":{\"rateLimitResetCredits\":{\"availableCount\":3\(details)}}}"
            let summary = try XCTUnwrap(CodexUsageClient.parseUsageResponse(Data(reply.utf8)).manualResets)
            XCTAssertEqual(summary.availableCount, 3)
            XCTAssertNil(summary.credits)
        }
        let fetchedEmpty = "{\"result\":{\"rateLimitResetCredits\":{\"availableCount\":3,\"credits\":[]}}}"
        let summary = try XCTUnwrap(CodexUsageClient.parseUsageResponse(Data(fetchedEmpty.utf8)).manualResets)
        XCTAssertEqual(summary.availableCount, 3)
        XCTAssertEqual(summary.credits, [])
    }

    func testInvalidManualResetCountAndDatesAreRejected() {
        let invalid = [
            "{\"availableCount\":-1}",
            "{\"availableCount\":1,\"credits\":[{\"id\":\"a\",\"resetType\":\"codexRateLimits\",\"status\":\"available\",\"grantedAt\":-1}]}",
            "{\"availableCount\":1,\"credits\":[{\"id\":\"a\",\"resetType\":\"codexRateLimits\",\"status\":\"available\",\"grantedAt\":1780000000,\"expiresAt\":-1}]}",
            "{\"availableCount\":1,\"credits\":[{\"id\":\"\",\"resetType\":\"codexRateLimits\",\"status\":\"available\",\"grantedAt\":1780000000}]}"
        ]
        for metadata in invalid {
            let reply = "{\"result\":{\"rateLimitResetCredits\":\(metadata)}}"
            XCTAssertThrowsError(try CodexUsageClient.parseUsageResponse(Data(reply.utf8)))
        }
    }

    func testManualResetMetadataRoundTripsAndAbsentSavedFieldDecodes() throws {
        let credit = ManualResetCredit(id: "credit-a", resetType: "codexRateLimits", status: "available",
            grantedAt: Date(timeIntervalSince1970: 1_780_000_000), expiresAt: Date(timeIntervalSince1970: 1_790_000_000),
            title: "Earned reset", detail: "Provider explanation")
        let snapshot = UsageSnapshot(sevenDay: UsageWindow(utilization: 24, resetsAt: nil),
            manualResets: ManualResetSummary(availableCount: 2, credits: [credit]))
        let data = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(UsageSnapshot.self, from: data), snapshot)
        var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        saved.removeValue(forKey: "manualResets")
        let withoutMetadata = try JSONDecoder().decode(UsageSnapshot.self, from: JSONSerialization.data(withJSONObject: saved))
        XCTAssertNil(withoutMetadata.manualResets)
        XCTAssertEqual(withoutMetadata.sevenDay, snapshot.sevenDay)
    }

    func testInvalidPercentDurationAndResetDateAreRejected() {
        for window in ["{\"usedPercent\":-1}", "{\"usedPercent\":25,\"windowDurationMins\":0}", "{\"usedPercent\":25,\"resetsAt\":-10}"] {
            let reply = "{\"result\":{\"rateLimits\":{\"primary\":\(window)}}}"
            XCTAssertThrowsError(try CodexUsageClient.parseUsageResponse(Data(reply.utf8)))
        }
    }

    func testErrorsAndUnsupportedShapesNeverExposeRawContents() {
        let secret = "synthetic-secret-must-not-appear"
        for reply in ["{\"error\":{\"code\":-32600,\"message\":\"\(secret)\"}}", "{\"result\":{\"rateLimits\":\"\(secret)\"}}"] {
            XCTAssertThrowsError(try CodexUsageClient.parseUsageResponse(Data(reply.utf8))) { error in
                XCTAssertFalse(error.localizedDescription.contains(secret))
            }
        }
    }

    func testAccountOnlyProtocolUsesSelectedAuthAndNormalQuit() async throws {
        let fixture = try Fixture(script: Self.protocolPreamble + """
        assert os.environ['CODEX_HOME'] == str(Path(__file__).parent / 'profile')
        assert os.environ['HOME'] == str(Path(__file__).parent / 'profile' / 'home')
        assert os.environ['CODEX_INTERNAL_APP_SERVER_REMOTE_CONTROL_DISABLED'] == '1'
        assert not any(k in os.environ for k in ['OPENAI_API_KEY', 'CODEX_API_KEY', 'OPENAI_BASE_URL', 'CODEX_LOGIN_ISSUER', 'CODEX_APP_SERVER_URL', 'ANTHROPIC_API_KEY'])
        assert Path.cwd().name.startswith('switchboard-codex-usage-')
        for override in ['cli_auth_credentials_store="file"', 'model_provider="openai"', 'chatgpt_base_url="https://chatgpt.com/backend-api"', 'features.plugins=false', 'features.apps=false', 'features.hooks=false', 'analytics.enabled=false', 'feedback.enabled=false']:
            assert override in sys.argv
        assert sys.argv[-3:] == ['app-server', '--listen', 'stdio://']
        print(json.dumps({'method':'account/updated','params':{}}), flush=True)
        request = handshake()
        assert request['method'] == 'account/rateLimits/read'
        assert request['params'] == {'excludeResetCreditDetails':False}
        Path(os.environ['CODEX_HOME'], 'auth.json').write_text('synthetic-refreshed-auth')
        reply = json.loads(\(Self.pythonString(Self.reply)))
        reply['result']['rateLimitResetCredits'] = {'availableCount':2,'credits':None}
        reply['id'] = request['id']
        print(json.dumps(reply), flush=True)
        assert sys.stdin.read() == ''
        Path(__file__ + '.clean-exit').write_text('yes')
        """)
        defer { fixture.remove() }
        let result = try await CodexUsageClient(executable: fixture.executable).fetch(installation: fixture.installation)
        XCTAssertEqual(result.fiveHour?.utilization, 12)
        XCTAssertEqual(result.manualResets?.availableCount, 2)
        XCTAssertEqual(try String(contentsOf: fixture.installation.authFile, encoding: .utf8), "synthetic-refreshed-auth")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.executable.path + ".clean-exit"))
        try fixture.assertChildStopped()
    }

    func testUnauthorizedAccountDiscoveryRefreshesOnceBeforeReadingUsage() async throws {
        let fixture = try Fixture(script: Self.protocolPreamble + """
        account = account_request()
        print(json.dumps({'id':account['id'],'error':{'code':-32603,'message':'workspace routing discovery unauthorized (401)'}}), flush=True)
        refresh = json.loads(sys.stdin.readline())
        assert refresh['method'] == 'account/read'
        assert refresh['params'] == {'refreshToken':True}
        Path(os.environ['CODEX_HOME'], 'auth.json').write_text('synthetic-rotated-at-discovery')
        print(json.dumps({'id':refresh['id'],'result':{'account':{'type':'chatgpt'}}}), flush=True)
        usage = json.loads(sys.stdin.readline())
        assert usage['method'] == 'account/rateLimits/read'
        reply = json.loads(\(Self.pythonString(Self.reply)))
        reply['id'] = usage['id']
        print(json.dumps(reply), flush=True)
        assert sys.stdin.read() == ''
        """)
        defer { fixture.remove() }
        let result = try await CodexUsageClient(executable: fixture.executable).fetch(installation: fixture.installation)
        XCTAssertEqual(result.fiveHour?.utilization, 12)
        XCTAssertEqual(try String(contentsOf: fixture.installation.authFile, encoding: .utf8), "synthetic-rotated-at-discovery")
        try fixture.assertChildStopped()
    }

    func testAccountAndUsageUnauthorizedShareOneRefreshBudget() async throws {
        let fixture = try Fixture(script: Self.protocolPreamble + """
        account = account_request()
        print(json.dumps({'id':account['id'],'error':{'code':-32603,'message':'workspace routing discovery unauthorized (401)'}}), flush=True)
        refresh = json.loads(sys.stdin.readline())
        assert refresh['params'] == {'refreshToken':True}
        print(json.dumps({'id':refresh['id'],'result':{'account':{'type':'chatgpt'}}}), flush=True)
        usage = json.loads(sys.stdin.readline())
        assert usage['method'] == 'account/rateLimits/read'
        print(json.dumps({'id':usage['id'],'error':{'code':-32603,'message':'failed to fetch codex rate limits: GET https://example.test/usage failed: 401 Unauthorized; body=synthetic-private'}}), flush=True)
        assert sys.stdin.read() == ''
        Path(__file__ + '.clean-exit').write_text('yes')
        """)
        defer { fixture.remove() }
        do {
            _ = try await CodexUsageClient(executable: fixture.executable).fetch(installation: fixture.installation)
            XCTFail("Expected typed authentication failure")
        } catch {
            XCTAssertTrue(error is CodexAuthenticationError)
            XCTAssertFalse(error.localizedDescription.contains("synthetic-private"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.executable.path + ".clean-exit"))
        try fixture.assertChildStopped()
    }

    func testWorkspaceNetworkFailureDoesNotRefreshOrRequireLogout() async throws {
        let fixture = try Fixture(script: Self.protocolPreamble + """
        account = account_request()
        print(json.dumps({'id':account['id'],'error':{'code':-32603,'message':'workspace routing discovery failed'}}), flush=True)
        assert sys.stdin.read() == ''
        Path(__file__ + '.clean-exit').write_text('yes')
        """)
        defer { fixture.remove() }
        do {
            _ = try await CodexUsageClient(executable: fixture.executable).fetch(installation: fixture.installation)
            XCTFail("Expected workspace service failure")
        } catch {
            XCTAssertFalse(error is CodexAuthenticationError)
            XCTAssertTrue(error.localizedDescription.contains("workspace service"))
            XCTAssertFalse(error.localizedDescription.contains("Sign in"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.executable.path + ".clean-exit"))
        try fixture.assertChildStopped()
    }

    func testUnauthorizedUsageRefreshesOnceAndRetainsRotatedCredentials() async throws {
        let fixture = try Fixture(script: Self.protocolPreamble + """
        request = handshake()
        print(json.dumps({'id':request['id'], 'error':{'code':-32603,'message':'failed to fetch codex rate limits: GET https://chatgpt.com/backend-api/wham/usage failed: 401 Unauthorized; content-type=application/json; body=synthetic-private'}}), flush=True)
        refresh = json.loads(sys.stdin.readline())
        assert refresh['method'] == 'account/read'
        assert refresh['params'] == {'refreshToken':True}
        Path(os.environ['CODEX_HOME'], 'auth.json').write_text('synthetic-rotated-after-401')
        print(json.dumps({'id':refresh['id'],'result':{'account':{'type':'chatgpt'}}}), flush=True)
        retry = json.loads(sys.stdin.readline())
        assert retry['method'] == 'account/rateLimits/read'
        assert retry['id'] != request['id']
        reply = json.loads(\(Self.pythonString(Self.reply)))
        reply['id'] = retry['id']
        print(json.dumps(reply), flush=True)
        assert sys.stdin.read() == ''
        """)
        defer { fixture.remove() }
        let result = try await CodexUsageClient(executable: fixture.executable).fetch(installation: fixture.installation)
        XCTAssertEqual(result.sevenDay?.utilization, 103)
        XCTAssertEqual(try String(contentsOf: fixture.installation.authFile, encoding: .utf8), "synthetic-rotated-after-401")
        try fixture.assertChildStopped()
    }

    func testRepeatedUnauthorizedStopsAfterOneRefreshWithoutLeakingDiagnostics() async throws {
        let fixture = try Fixture(script: Self.protocolPreamble + """
        request = handshake()
        failure = {'code':-32603,'message':'failed to fetch codex rate limits: GET https://chatgpt.com/backend-api/wham/usage failed: 401 Unauthorized; body=synthetic-secret'}
        print(json.dumps({'id':request['id'],'error':failure}), flush=True)
        refresh = json.loads(sys.stdin.readline())
        assert refresh['params'] == {'refreshToken':True}
        Path(os.environ['CODEX_HOME'], 'auth.json').write_text('synthetic-refreshed-auth')
        print(json.dumps({'id':refresh['id'],'result':{'account':{'type':'chatgpt'}}}), flush=True)
        retry = json.loads(sys.stdin.readline())
        print(json.dumps({'id':retry['id'],'error':failure}), flush=True)
        assert sys.stdin.read() == ''
        Path(__file__ + '.clean-exit').write_text('yes')
        """)
        defer { fixture.remove() }
        do {
            _ = try await CodexUsageClient(executable: fixture.executable).fetch(installation: fixture.installation)
            XCTFail("Expected the second 401 to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("HTTP 401"))
            XCTAssertFalse(error.localizedDescription.contains("synthetic-secret"))
            XCTAssertFalse(error.localizedDescription.contains("https://"))
        }
        XCTAssertEqual(try String(contentsOf: fixture.installation.authFile, encoding: .utf8), "synthetic-refreshed-auth")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.executable.path + ".clean-exit"))
        try fixture.assertChildStopped()
    }

    func testForbiddenUsageDoesNotRefreshOrMisdiagnoseExpiredLogin() async throws {
        let fixture = try Fixture(script: Self.protocolPreamble + """
        request = handshake()
        print(json.dumps({'id':request['id'],'error':{'code':-32603,'message':'failed to fetch codex rate limits: GET https://chatgpt.com/backend-api/wham/usage failed: 403 Forbidden; body=synthetic-private'}}), flush=True)
        assert sys.stdin.read() == ''
        Path(__file__ + '.clean-exit').write_text('yes')
        """)
        defer { fixture.remove() }
        do {
            _ = try await CodexUsageClient(executable: fixture.executable).fetch(installation: fixture.installation)
            XCTFail("Expected forbidden usage")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("HTTP 403"))
            XCTAssertTrue(error.localizedDescription.contains("workspace"))
            XCTAssertFalse(error.localizedDescription.contains("expired"))
            XCTAssertFalse(error.localizedDescription.contains("synthetic-private"))
        }
        XCTAssertEqual(try String(contentsOf: fixture.installation.authFile, encoding: .utf8), "synthetic-original-auth")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.executable.path + ".clean-exit"))
        try fixture.assertChildStopped()
    }

    func testErrorClassifierUsesStatusHeaderOnlyAndRedactsAllRawDetails() throws {
        for status in [401, 403, 429, 502] {
            let data = try jsonData(["code": -32603, "message": "failed to fetch codex rate limits: GET https://example.test/usage failed: \(status) Error; body=synthetic-secret"])
            let error = try JSONDecoder().decode(CodexUsageFailure.self, from: data)
            XCTAssertEqual(error.httpStatus, status)
            XCTAssertTrue(error.displayError(stage: "account/rateLimits/read").localizedDescription.contains("HTTP \(status)"))
            XCTAssertFalse(error.displayError(stage: "account/rateLimits/read").localizedDescription.contains("synthetic-secret"))
        }
        let data = try jsonData(["code": -32602, "message": "synthetic-private 401 Unauthorized"])
        let error = try JSONDecoder().decode(CodexUsageFailure.self, from: data)
        XCTAssertNil(error.httpStatus)
        XCTAssertTrue(error.displayError(stage: "account/read").localizedDescription.contains("Update Codex"))
        XCTAssertTrue(error.displayError(stage: "account/read").localizedDescription.contains("RPC -32602"))
        for message in ["workspace routing discovery failed", "workspace routing discovery timed out",
                        "selected workspace missing from routing discovery", "synthetic-private 401 Unauthorized",
                        "body=workspace routing discovery unauthorized (401)"] {
            let failure = try JSONDecoder().decode(CodexUsageFailure.self,
                from: jsonData(["code": -32603, "message": message]))
            XCTAssertNil(failure.httpStatus)
            XCTAssertFalse(failure.isAuthenticationFailure)
        }
    }

    func testRPCErrorPreservesRefreshedAuthAndHidesDiagnostics() async throws {
        let fixture = try Fixture(script: Self.protocolPreamble + """
        request = handshake()
        Path(os.environ['CODEX_HOME'], 'auth.json').write_text('synthetic-refreshed-auth')
        print('synthetic-secret-must-not-appear', file=sys.stderr, flush=True)
        print(json.dumps({'id':request['id'], 'error':{'code':-32603,'message':'synthetic-secret-must-not-appear'}}), flush=True)
        sys.stdin.read()
        """)
        defer { fixture.remove() }
        do {
            _ = try await CodexUsageClient(executable: fixture.executable).fetch(installation: fixture.installation)
            XCTFail("Expected RPC failure")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("synthetic-secret-must-not-appear"))
        }
        XCTAssertEqual(try String(contentsOf: fixture.installation.authFile, encoding: .utf8), "synthetic-refreshed-auth")
        try fixture.assertChildStopped()
    }

    func testNonChatGPTLoginStopsBeforeUsageRequest() async throws {
        let fixture = try Fixture(script: Self.protocolPreamble + """
        first = json.loads(sys.stdin.readline())
        print(json.dumps({'id':first['id'],'result':{}}), flush=True)
        assert json.loads(sys.stdin.readline())['method'] == 'initialized'
        account = json.loads(sys.stdin.readline())
        print(json.dumps({'id':account['id'],'result':{'account':{'type':'apiKey'},'requiresOpenaiAuth':True}}), flush=True)
        assert sys.stdin.read() == ''
        Path(__file__ + '.no-usage').write_text('yes')
        """)
        defer { fixture.remove() }
        do {
            _ = try await CodexUsageClient(executable: fixture.executable).fetch(installation: fixture.installation)
            XCTFail("Expected subscription requirement")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("ChatGPT"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.executable.path + ".no-usage"))
        try fixture.assertChildStopped()
    }

    func testTimeoutReapsSIGTERMResistantChild() async throws {
        let fixture = try Fixture(script: Self.protocolPreamble + """
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        time.sleep(60)
        """)
        defer { fixture.remove() }
        do {
            _ = try await CodexUsageClient(executable: fixture.executable, timeout: 0.25).fetch(installation: fixture.installation)
            XCTFail("Expected timeout")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("in time"))
        }
        try fixture.assertChildStopped()
    }

    func testCancellationReapsChild() async throws {
        let fixture = try Fixture(script: Self.protocolPreamble + "time.sleep(60)\n")
        defer { fixture.remove() }
        let task = Task { try await CodexUsageClient(executable: fixture.executable).fetch(installation: fixture.installation) }
        for _ in 0..<100 {
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

    func testEarlyExitDoesNotSignalParent() async throws {
        let fixture = try Fixture(script: Self.protocolPreamble + "sys.exit(0)\n")
        defer { fixture.remove() }
        do {
            _ = try await CodexUsageClient(executable: fixture.executable).fetch(installation: fixture.installation)
            XCTFail("Expected closed channel")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("closed"))
        }
        try fixture.assertChildStopped()
    }

    func testOversizedLineIsBoundedAndChildIsReaped() async throws {
        let fixture = try Fixture(script: Self.protocolPreamble + """
        sys.stdout.write('x' * (1024 * 1024 + 1))
        sys.stdout.flush()
        time.sleep(60)
        """)
        defer { fixture.remove() }
        do {
            _ = try await CodexUsageClient(executable: fixture.executable).fetch(installation: fixture.installation)
            XCTFail("Expected bounded output")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("too much output"))
        }
        try fixture.assertChildStopped()
    }

    func testStderrOutputIsBoundedAndDiscarded() async throws {
        let fixture = try Fixture(script: Self.protocolPreamble + """
        sys.stderr.write('synthetic-private-diagnostic' * 100000)
        sys.stderr.flush()
        time.sleep(60)
        """)
        defer { fixture.remove() }
        do {
            _ = try await CodexUsageClient(executable: fixture.executable).fetch(installation: fixture.installation)
            XCTFail("Expected bounded output")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("too much output"))
            XCTAssertFalse(error.localizedDescription.contains("synthetic-private-diagnostic"))
        }
        try fixture.assertChildStopped()
    }

    private static let protocolPreamble = """
    import json, os, signal, sys, time
    from pathlib import Path
    Path(__file__ + '.pid').write_text(str(os.getpid()))
    def account_request():
        first = json.loads(sys.stdin.readline())
        assert first['method'] == 'initialize'
        assert first['params']['clientInfo']['name'] == 'switchboard'
        print(json.dumps({'id':first['id'],'result':{}}), flush=True)
        assert json.loads(sys.stdin.readline()) == {'method':'initialized'}
        account = json.loads(sys.stdin.readline())
        assert account['method'] == 'account/read'
        assert account['params'] == {'refreshToken':False}
        return account
    def handshake():
        account = account_request()
        print(json.dumps({'id':account['id'],'result':{'account':{'type':'chatgpt','email':'sample@example.test','planType':'plus'},'requiresOpenaiAuth':True}}), flush=True)
        return json.loads(sys.stdin.readline())

    """

    private static let reply = """
    {"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":103,"windowDurationMins":10080,"resetsAt":null},"secondary":{"usedPercent":12,"windowDurationMins":300,"resetsAt":1790000000}}}}
    """

    private static func pythonString(_ string: String) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: string, options: [.fragmentsAllowed]), encoding: .utf8)!
    }

    private struct Fixture {
        let directory: URL
        let executable: URL
        let installation: CodexInstallation
        var pidFile: URL { URL(fileURLWithPath: executable.path + ".pid") }

        init(script: String) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("switchboard-codex-usage-test-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            executable = directory.appendingPathComponent("fixture")
            try Data(("#!/usr/bin/env python3\n" + script + "\n").utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            installation = .isolated(at: directory.appendingPathComponent("profile"))
            try FileManager.default.createDirectory(at: installation.home.appendingPathComponent("home"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data("synthetic-original-auth".utf8).write(to: installation.authFile)
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
