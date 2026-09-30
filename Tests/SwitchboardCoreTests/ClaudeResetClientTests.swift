import Foundation
import XCTest
@testable import SwitchboardCore

final class ClaudeResetClientTests: RepositoryTestCase {
    func testOAuthRequestIsReadOnlyAndFixedToProvider() throws {
        let token = OAuthCredential(accessToken: "synthetic-token", scopes: ["user:profile", "user:inference"])
        let request = try ClaudeResetClient.request(credential: token, cliVersion: "2.1.285")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "claude-cli/2.1.285 (external, cli, client-app/switchboard)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-app"), "cli")
        XCTAssertNil(request.httpBody)
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertThrowsError(try ClaudeResetClient.request(credential: OAuthCredential(accessToken: "synthetic-token", scopes: ["user:inference"]), cliVersion: "2.1.285"))
        for version in [nil, "", "2.1.285\r\nInjected: yes", "2.1.285\n", "made-up"] {
            XCTAssertThrowsError(try ClaudeResetClient.request(credential: token, cliVersion: version))
        }
    }

    func testSurfaceRestrictedOAuthDoesNotReplaceWebInventoryOrItsFailureState() throws {
        var account = try repository.capture(snapshot())
        let grant = try ClaudeResetSnapshot.parse(["eligible":true,"grants":[
            ["id":"synthetic-grant","resets_left":1,"clears":["five_hour","seven_day"]]
        ]], checkedAt: Date(timeIntervalSince1970: 100))
        account.claudeBilling = ClaudeBillingSnapshot(checkedAt: grant.checkedAt, status: "active",
            resetSnapshot: grant, resetReadFailed: true)
        let restricted = ClaudeResetSnapshot(checkedAt: Date(timeIntervalSince1970: 200), eligible: false,
            grants: [], ineligibleReason: "surface")
        account.usage = UsageSnapshot(claudeResetSnapshot: restricted, claudeResetReadFailed: false)
        XCTAssertEqual(account.claudeResets, grant)
        XCTAssertTrue(account.claudeResetsReadFailed)
        account.claudeBilling?.resetReadFailed = false
        XCTAssertFalse(account.claudeResetsReadFailed)
        account.usage?.claudeResetSnapshot = ClaudeResetSnapshot(checkedAt: restricted.checkedAt, eligible: true, grants: [])
        XCTAssertEqual(account.claudeResets?.grants, [])
        account.claudeBilling = nil
        account.usage?.claudeResetSnapshot = restricted
        XCTAssertFalse(try XCTUnwrap(account.claudeResets).confirmsGrantInventory)
    }

    func testInstalledVersionUsesOnlyMatchingPublicNativeOrPackageMetadata() throws {
        let directory = repository.directory.appendingPathComponent("synthetic-cli")
        let versions = directory.appendingPathComponent("versions")
        try FileManager.default.createDirectory(at: versions, withIntermediateDirectories: true)
        let native = versions.appendingPathComponent("2.1.285")
        try Data().write(to: native)
        let link = directory.appendingPathComponent("claude")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: native)
        XCTAssertEqual(ClaudeExecutable.installedVersion(at: link), "2.1.285")
        let npm = directory.appendingPathComponent("npm")
        try FileManager.default.createDirectory(at: npm, withIntermediateDirectories: true)
        let package = npm.appendingPathComponent("package.json")
        try Data(#"{"name":"@anthropic-ai/claude-code","version":"2.1.286"}"#.utf8).write(to: package)
        XCTAssertEqual(ClaudeExecutable.installedVersion(at: npm.appendingPathComponent("cli.js")), "2.1.286")
        try Data(#"{"name":"unrelated-package","version":"2.1.286"}"#.utf8).write(to: package)
        XCTAssertNil(ClaudeExecutable.installedVersion(at: npm.appendingPathComponent("cli.js")))
        XCTAssertNil(ClaudeExecutable.installedVersion(at: directory.appendingPathComponent("unknown")))
        try Data(repeating: 65, count: 65_537).write(to: package)
        XCTAssertNil(ClaudeExecutable.installedVersion(at: npm.appendingPathComponent("cli.js")))
    }

    func testUnconfirmedAndInBandFailedReadsKeepPriorInventoryUntilConfirmedZero() throws {
        let account = try repository.capture(snapshot())
        let old = try ClaudeResetSnapshot.parse(["eligible":true,"grants":[
            ["id":"synthetic-grant","resets_left":1,"clears":["five_hour","seven_day"]]
        ]], checkedAt: Date(timeIntervalSince1970: 100))
        try repository.updateUsage(account.id, usage: UsageSnapshot(claudeResetSnapshot: old, claudeResetReadFailed: false))
        try repository.setClaudeBilling(account.id, billing: ClaudeBillingSnapshot(checkedAt: old.checkedAt,
            status: "active", resetSnapshot: old, resetReadFailed: false))
        let restricted = ClaudeResetSnapshot(checkedAt: Date(timeIntervalSince1970: 200), eligible: false, grants: [])
        try repository.updateUsage(account.id, usage: UsageSnapshot(claudeResetSnapshot: restricted, claudeResetReadFailed: false))
        try repository.setClaudeBilling(account.id, billing: ClaudeBillingSnapshot(checkedAt: restricted.checkedAt,
            status: "active", resetSnapshot: restricted, resetReadFailed: false))
        var saved = try XCTUnwrap(repository.accounts().first)
        XCTAssertEqual(saved.usage?.claudeResetSnapshot, old)
        XCTAssertEqual(saved.claudeBilling?.resetSnapshot, old)
        XCTAssertTrue(saved.claudeResetsReadFailed)
        try repository.updateUsage(account.id, usage: UsageSnapshot(claudeResetReadFailed: true))
        saved = try XCTUnwrap(repository.accounts().first)
        XCTAssertEqual(saved.usage?.claudeResetSnapshot, old)
        let zero = ClaudeResetSnapshot(checkedAt: restricted.checkedAt, eligible: true, grants: [])
        try repository.updateUsage(account.id, usage: UsageSnapshot(claudeResetSnapshot: zero, claudeResetReadFailed: false))
        XCTAssertEqual(try repository.accounts().first?.claudeResets, zero)
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
        let newer = ClaudeResetSnapshot(checkedAt: Date(timeIntervalSince1970: 200), eligible: true, grants: [])
        try repository.updateUsage(first.id, usage: UsageSnapshot(claudeResetSnapshot: newer, claudeResetReadFailed: false))
        saved = try repository.accounts()
        XCTAssertEqual(saved.first(where: { $0.id == first.id })?.claudeResets, newer)
        XCTAssertEqual(saved.first(where: { $0.id == first.id })?.claudeResetsReadFailed, false)
    }
}
