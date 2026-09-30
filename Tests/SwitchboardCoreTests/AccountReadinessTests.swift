import Foundation
import XCTest
@testable import SwitchboardCore

final class AccountReadinessTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private func usage(_ five: Double?, _ week: Double, age: Double = 0, reset: Double = 3600) -> UsageSnapshot {
        UsageSnapshot(fiveHour: five.map { .init(utilization: $0, resetsAt: now.addingTimeInterval(reset)) },
            sevenDay: .init(utilization: week, resetsAt: now.addingTimeInterval(reset + 86_400)),
            fetchedAt: now.addingTimeInterval(-age))
    }
    private func account(_ usage: UsageSnapshot) -> SavedAccount {
        SavedAccount(label: "Test", email: "test@example.test", accountUUID: UUID().uuidString,
            organizationUUID: "test", plan: "Pro", usage: usage)
    }
    func testTightestGeneralWindowDeterminesReadiness() {
        let ready = AccountReadiness(usage: usage(20, 70), now: now)
        XCTAssertEqual(ready.status, .ready)
        XCTAssertEqual(ready.remaining!, 30, accuracy: 0.001)
        XCTAssertEqual(ready.limitingWindow, "Weekly")
        XCTAssertEqual(AccountReadiness(usage: usage(95, 20), now: now).status, .limited)
        XCTAssertEqual(AccountReadiness(usage: usage(100, 20), now: now).status, .exhausted)
        XCTAssertEqual(AccountReadiness(usage: usage(nil, 20), now: now).status, .ready)
    }
    func testErrorsOldDataAndElapsedResetsCannotClaimReady() {
        XCTAssertEqual(AccountReadiness(usage: nil, now: now).status, .unknown)
        XCTAssertEqual(AccountReadiness(usage: usage(0, 0), failed: true, now: now).status, .stale)
        XCTAssertEqual(AccountReadiness(usage: usage(0, 0, age: 601), now: now).status, .stale)
        XCTAssertEqual(AccountReadiness(usage: usage(0, 0, reset: -1), now: now).status, .stale)
        XCTAssertEqual(AccountReadiness(usage: usage(0, 0, age: -61), now: now).status, .stale)
    }
    func testRecommendationExcludesFailedExhaustedAndIncomparableWindows() {
        let a = account(usage(70, 10)), b = account(usage(10, 40)), empty = account(usage(100, 0))
        XCTAssertEqual(AccountReadiness.recommendation(accounts: [a, b, empty], now: now), b.id)
        XCTAssertEqual(AccountReadiness.recommendation(accounts: [a, b], failedIDs: [b.id], now: now), a.id)
        XCTAssertNil(AccountReadiness.recommendation(accounts: [a, account(usage(nil, 10))], now: now))
        XCTAssertNil(AccountReadiness.recommendation(accounts: [empty], now: now))
    }
    func testEqualHeadroomFavorsEarlierResetWithoutTreatingNamedLimitAsGeneral() {
        var a = account(usage(30, 10, reset: 7200)), b = account(usage(30, 10, reset: 3600))
        a.usage?.modelScoped = [.init(name: "Special model", window: .init(utilization: 100, resetsAt: nil))]
        XCTAssertEqual(AccountReadiness.recommendation(accounts: [a, b], now: now), b.id)
        XCTAssertEqual(AccountReadiness(usage: a.usage, now: now).status, .ready)
    }
}
