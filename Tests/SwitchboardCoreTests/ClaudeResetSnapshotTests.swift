import Foundation
import XCTest
@testable import SwitchboardCore

final class ClaudeResetSnapshotTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private var grant: [String: Any] {
        ["id":"synthetic-reset", "resets_left":1, "clears":["five_hour","seven_day"],
         "starts_at":"2026-09-22T16:00:00Z", "ends_at":"2026-10-22T16:00:00Z",
         "paused":false, "usable_now":true]
    }

    func testFullSessionAndWeeklyResetTypesComeFromClearedWindows() throws {
        for (clears,title) in [(["five_hour","seven_day","seven_day_overage_included"],"Full reset"),
                               (["five_hour"],"5-hour reset"),(["seven_day"],"Weekly reset"),
                               (["future_window"],"Other reset")] {
            var row = grant; row["clears"] = clears
            let value = try ClaudeResetSnapshot.parse(["eligible":true,"grants":[row]], checkedAt: now)
            XCTAssertEqual(value.grants[0].title,title)
            XCTAssertEqual(value.grants[0].resetsLeft,1)
            XCTAssertEqual(value.checkedAt,now)
        }
    }

    func testPausedExpiredFutureAndUsedGrantsAreNotAvailable() throws {
        let sample = try ClaudeResetSnapshot.parse(["eligible":true,"grants":[grant]])
        let start = try XCTUnwrap(sample.grants[0].startsAt)
        let expiry = try XCTUnwrap(sample.grants[0].expiresAt)
        XCTAssertFalse(sample.grants[0].isAvailable(at:start.addingTimeInterval(-1)))
        XCTAssertTrue(sample.grants[0].isAvailable(at:start))
        XCTAssertFalse(sample.grants[0].isAvailable(at:expiry))
        for (field,value) in [("paused",true as Any),("resets_left",0 as Any)] {
            var row=grant; row[field]=value
            XCTAssertFalse(try ClaudeResetSnapshot.parse(["eligible":true,"grants":[row]]).grants[0].isAvailable(at:start))
        }
    }

    func testUnknownMissingAndMalformedDataDoNotBecomeZeroResets() throws {
        for body: [String:Any] in [[:],["eligible":true],["eligible":1,"grants":[]],
                                  ["eligible":true,"grants":NSNull()]] {
            XCTAssertThrowsError(try ClaudeResetSnapshot.parse(body))
        }
        for (field,value) in [("resets_left",true as Any),("resets_left",-1 as Any),
                              ("resets_left",1.5 as Any),("ends_at","2026-10-22" as Any),
                              ("paused",1 as Any),("clears",[] as Any)] {
            var row=grant; row[field]=value
            XCTAssertThrowsError(try ClaudeResetSnapshot.parse(["eligible":true,"grants":[row]]))
        }
        XCTAssertThrowsError(try ClaudeResetSnapshot.parse(["eligible":true,"grants":[grant,grant]]))
        XCTAssertEqual(try ClaudeResetSnapshot.parse(["eligible":false,"grants":[]]).grants,[])
        var noExpiry = grant
        noExpiry["ends_at"] = NSNull()
        noExpiry["paused"] = nil
        noExpiry["usable_now"] = nil
        let value = try ClaudeResetSnapshot.parse(["eligible": true, "grants": [noExpiry]])
        XCTAssertNil(value.grants[0].expiresAt)
        XCTAssertFalse(value.grants[0].usableNow)
        XCTAssertTrue(value.grants[0].isAvailable(at: try XCTUnwrap(value.grants[0].startsAt)))
    }

    func testIdentityBoundaryAndUnavailableResetReadPreserveBilling() throws {
        let envelope: [String:Any] = ["accountUUID":"a","organizationUUID":"o", "details":["status":"active"],
                                    "resetDetails":["eligible":true,"grants":[grant]]]
        let data = try JSONSerialization.data(withJSONObject:envelope)
        let value = try ClaudeBillingSnapshot.parseBridge(data,expectedAccountUUID:"a",expectedOrganizationUUID:"o")
        XCTAssertNotNil(value.resetSnapshot)
        XCTAssertEqual(value.resetReadFailed,false)
        XCTAssertThrowsError(try ClaudeBillingSnapshot.parseBridge(data,expectedAccountUUID:"b",expectedOrganizationUUID:"o"))
        var failed=envelope; failed["resetDetails"]=NSNull()
        let result = try ClaudeBillingSnapshot.parseBridge(JSONSerialization.data(withJSONObject:failed),expectedAccountUUID:"a",expectedOrganizationUUID:"o")
        XCTAssertEqual(result.status,"active")
        XCTAssertNil(result.resetSnapshot)
        XCTAssertEqual(result.resetReadFailed,true)
    }

    func testOnlyResetDisplayMetadataSurvivesEncoding() throws {
        var row=grant; row["event_props"]=["token":"synthetic-private-value"]
        let value = try ClaudeResetSnapshot.parse(["eligible":true,"grants":[row],"private":"synthetic-private-value"])
        let data = try JSONEncoder().encode(value)
        XCTAssertFalse(String(decoding:data,as:UTF8.self).contains("synthetic-private-value"))
        XCTAssertEqual(try JSONDecoder().decode(ClaudeResetSnapshot.self,from:data),value)
    }

    func testSurfaceEligibilityDoesNotHideOwnedUnexpiredGrants() throws {
        var row = grant
        row["usable_now"] = false
        let snapshot = try ClaudeResetSnapshot.parse(["eligible": false, "ineligible_reason": "surface", "grants": [row]])
        let start = try XCTUnwrap(snapshot.grants.first?.startsAt)
        XCTAssertTrue(snapshot.confirmsGrantInventory)
        XCTAssertEqual(snapshot.unexpiredGrants(at: start).map(\.resetsLeft), [1])
        XCTAssertFalse(snapshot.grants[0].usableNow)
        for (field, value) in [("paused", true as Any), ("starts_at", "2026-10-01T16:00:00Z" as Any)] {
            var restricted = row; restricted[field] = value
            let result = try ClaudeResetSnapshot.parse(["eligible": true, "grants": [restricted]])
            XCTAssertEqual(result.unexpiredGrants(at: start).count, 1)
            XCTAssertFalse(result.grants[0].isAvailable(at: start))
        }
        XCTAssertTrue(snapshot.unexpiredGrants(at: try XCTUnwrap(snapshot.grants[0].expiresAt)).isEmpty)
    }

    func testIneligibleEmptyResponseDoesNotConfirmZeroAndUnavailableIsFailedRead() throws {
        for reason in ["surface", "cli_version", "config_off", "tier", "no_grant", "unknown"] {
            let value = try ClaudeResetSnapshot.parse(["eligible": false, "ineligible_reason": reason, "grants": []])
            XCTAssertFalse(value.confirmsGrantInventory)
            XCTAssertEqual(value.ineligibleReason, reason)
        }
        XCTAssertTrue(try ClaudeResetSnapshot.parse(["eligible": true, "grants": []]).confirmsGrantInventory)
        XCTAssertThrowsError(try ClaudeResetSnapshot.parse(["eligible": false, "ineligible_reason": "unavailable", "grants": []]))
        let sanitized = try ClaudeResetSnapshot.parse(["eligible": false, "ineligible_reason": "synthetic-private-value", "grants": []])
        XCTAssertEqual(sanitized.ineligibleReason, "unknown")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(sanitized), as: UTF8.self).contains("synthetic-private-value"))
        let existing = Data(#"{"checkedAt":0,"eligible":false,"grants":[]}"#.utf8)
        XCTAssertFalse(try JSONDecoder().decode(ClaudeResetSnapshot.self, from: existing).confirmsGrantInventory)
    }
}
