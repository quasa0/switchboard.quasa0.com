import Foundation
import XCTest
@testable import SwitchboardCore

final class ClaudeResetClientTests: RepositoryTestCase {
    func testOAuthRequestIsReadOnlyAndFixedToProvider() throws {
        let token = OAuthCredential(accessToken: "synthetic-token", scopes: ["user:profile", "user:inference"])
        let request = try ClaudeResetClient.request(credential: token)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        XCTAssertNil(request.httpBody)
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertThrowsError(try ClaudeResetClient.request(credential: OAuthCredential(accessToken: "synthetic-token", scopes: ["user:inference"])))
    }

    func testMissingFailedAndZeroResponsesRemainDistinct() throws {
        let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!
        let valid = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let data = Data(#"{"cedar_ember":{"eligible":true,"grants":[]},"private":"synthetic-not-retained"}"#.utf8)
        let value = try ClaudeResetClient.parse(data, response: valid)
        XCTAssertEqual(value.grants, [])
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(value), as: UTF8.self).contains("synthetic-not-retained"))
        XCTAssertThrowsError(try ClaudeResetClient.parse(Data("{}".utf8), response: valid))
        for status in [401, 403, 429, 500, 302] {
            XCTAssertThrowsError(try ClaudeResetClient.parse(data, response: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!))
        }
        XCTAssertThrowsError(try ClaudeResetClient.parse(data, response: HTTPURLResponse(url: URL(string: "https://other.example/usage")!, statusCode: 200, httpVersion: nil, headerFields: nil)!))
    }

    func testFailedGrantReadKeepsAccountScopedCacheAndSuccessfulZeroClearsIt() throws {
        let first = try repository.capture(snapshot())
        let second = try repository.capture(snapshot("b"))
        let reset = ClaudeResetSnapshot(checkedAt: Date(timeIntervalSince1970: 100), eligible: true, grants: [])
        try repository.updateUsage(first.id, usage: UsageSnapshot(claudeResetSnapshot: reset, claudeResetReadFailed: false))
        try repository.updateUsage(first.id, usage: UsageSnapshot(fiveHour: UsageWindow(utilization: 50, resetsAt: nil), claudeResetReadFailed: true))
        var saved = try repository.accounts()
        XCTAssertEqual(saved.first(where: { $0.id == first.id })?.usage?.claudeResetSnapshot, reset)
        XCTAssertEqual(saved.first(where: { $0.id == first.id })?.usage?.fiveHour?.utilization, 50)
        XCTAssertNil(saved.first(where: { $0.id == second.id })?.usage?.claudeResetSnapshot)
        let newer = ClaudeResetSnapshot(checkedAt: Date(timeIntervalSince1970: 200), eligible: false, grants: [])
        try repository.updateUsage(first.id, usage: UsageSnapshot(claudeResetSnapshot: newer, claudeResetReadFailed: false))
        saved = try repository.accounts()
        XCTAssertEqual(saved.first(where: { $0.id == first.id })?.claudeResets, newer)
        XCTAssertEqual(saved.first(where: { $0.id == first.id })?.claudeResetsReadFailed, false)
    }
}
