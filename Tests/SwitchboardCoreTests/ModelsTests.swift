import Foundation
import XCTest
@testable import SwitchboardCore

final class ModelsTests: RepositoryTestCase {
    func testPlanNamesAreDerivedFromRateLimitTier() throws {
        XCTAssertEqual(try snapshot().validated().0.plan, "Max · 20×")
        XCTAssertEqual(try snapshot(tier: "default_claude_max_5x").validated().0.plan, "Max · 5×")
        XCTAssertEqual(try snapshot(tier: "unknown-new-tier").validated().0.plan, "Max")
    }

    func testTierLabelNormalizesCachedMetadataWithoutChangingIt() throws {
        let claude = try snapshot().validated().0
        var cached = SavedAccount(label: "Personal", email: claude.email, accountUUID: claude.accountUUID,
            organizationUUID: claude.organizationUUID, plan: "Max 20×")
        let original = cached
        XCTAssertEqual(SubscriptionProvider.claude.planLabel(cached.plan), "Max · 20×")
        XCTAssertEqual(cached, original)
        cached.plan = "Prolite"
        XCTAssertEqual(SubscriptionProvider.chatGPT.planLabel(cached.plan), "Pro Lite")
        cached.plan = "Pro"
        XCTAssertEqual(SubscriptionProvider.chatGPT.planLabel(cached.plan), "Pro")
        XCTAssertEqual(SubscriptionProvider.claude.planLabel(cached.plan), "Pro · 1×")
    }

    func testTierLabelRemainsStableAfterRepeatedFormattingAndPreservesUnknownPlans() {
        for (provider, labels) in [(SubscriptionProvider.claude, ["Max · 5×", "Max · 20×", "Pro · 1×"]),
                                   (.chatGPT, ["Plus", "Pro Lite", "Pro", "ChatGPT"])] {
            for label in labels { XCTAssertEqual(provider.planLabel(provider.planLabel(label)), label) }
            XCTAssertEqual(provider.planLabel("custom_enterprise_plan"), "Custom Enterprise Plan")
            XCTAssertEqual(provider.planLabel("business"), "Business")
        }
    }

    func testCachedCodexMultipliersNoLongerClaimCurrentAllowance() {
        for label in ["Pro · 10×", "Pro · 20×", "pro20x"] {
            XCTAssertEqual(SubscriptionProvider.chatGPT.planLabel(label), "Pro")
        }
        XCTAssertEqual(SubscriptionProvider.chatGPT.planLabel("Pro · 5×"), "Pro Lite")
        XCTAssertEqual(SubscriptionProvider.chatGPT.planLabel("Plus · 1×"), "Plus")
    }

    func testClaudeProUsesBaselineWithoutGuessingUnrecognizedMaxTier() throws {
        let valid = try snapshot(tier: "future-tier")
        var oauth = try jsonObject(valid.oauth)
        oauth["subscriptionType"] = "pro"
        let (login, _) = try CredentialSnapshot(oauth: jsonData(oauth), identity: valid.identity).validated()
        XCTAssertEqual(login.plan, "Pro · 1×")
        XCTAssertEqual(try valid.validated().0.plan, "Max")
    }

    func testSavedAccountDecodesExistingMetadataWithoutInventingRenewal() throws {
        let id = UUID()
        let metadata: [String: Any] = ["id": id.uuidString, "label": "Personal", "email": "synthetic@example.test",
            "accountUUID": "account-a", "organizationUUID": "org-a", "plan": "Max 20×", "addedAt": 0]
        let decoded = try JSONDecoder().decode(SavedAccount.self, from: JSONSerialization.data(withJSONObject: metadata))
        XCTAssertEqual(decoded, SavedAccount(id: id, label: "Personal", email: "synthetic@example.test",
            accountUUID: "account-a", organizationUUID: "org-a", plan: "Max 20×",
            addedAt: Date(timeIntervalSinceReferenceDate: 0)))
        XCTAssertNil(decoded.renewalAt)
        XCTAssertNil(decoded.subscriptionPeriod)
    }

    func testAutomaticPeriodAndManualRenewalRemainIndependentInSavedMetadata() throws {
        let period = SubscriptionPeriod(endsAt: Date(timeIntervalSince1970: 1_790_000_000),
            checkedAt: Date(timeIntervalSince1970: 1_789_000_000), source: .codexIDToken)
        var account = SavedAccount(label: "Personal", email: "synthetic@example.test", accountUUID: "account-a",
            organizationUUID: "org-a", plan: "Pro", renewalAt: Date(timeIntervalSince1970: 1_791_000_000),
            subscriptionPeriod: period)
        let decoded = try JSONDecoder().decode(SavedAccount.self, from: JSONEncoder().encode(account))
        XCTAssertEqual(decoded, account)
        XCTAssertNotEqual(decoded.renewalAt, decoded.subscriptionPeriod?.endsAt)
        account.renewalAt = nil
        XCTAssertEqual(account.subscriptionPeriod, period)
        XCTAssertNil(CurrentLogin(email: "synthetic@example.test", accountUUID: "account-a",
            organizationUUID: "org-a", plan: "Pro").subscriptionPeriod)
    }

    func testManualRenewalRoundTripsAndSurvivesCredentialRecapture() throws {
        var saved = try repository.capture(snapshot(), label: "Personal")
        saved.renewalAt = Date(timeIntervalSince1970: 1_817_265_723.5)
        let encoded = try JSONEncoder().encode([saved])
        try privateWrite(encoded, to: repository.directory.appendingPathComponent("accounts.json"))
        XCTAssertEqual(try repository.accounts(), [saved])
        let recaptured = try repository.capture(snapshot(token: "synthetic-rotated-token"))
        XCTAssertEqual(recaptured, saved)
        XCTAssertEqual(try repository.accounts().first?.renewalAt, saved.renewalAt)
        saved.renewalAt = nil
        let cleared = try JSONDecoder().decode(SavedAccount.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(cleared, saved)
        XCTAssertNil(cleared.renewalAt)
    }

    func testRejectsEmptyTokenMissingInferenceScopeAndEmptyIdentity() throws {
        let valid = try snapshot()
        for replacement: [String: Any] in [["accessToken": ""], ["scopes": ["user:profile"]]] {
            var oauth = try jsonObject(valid.oauth)
            oauth.merge(replacement) { _, new in new }
            let invalid = try CredentialSnapshot(oauth: jsonData(oauth), identity: valid.identity)
            XCTAssertThrowsError(try invalid.validated())
        }
        for field in ["accountUuid", "emailAddress"] {
            var identity = try jsonObject(valid.identity)
            identity[field] = ""
            let invalid = try CredentialSnapshot(oauth: valid.oauth, identity: jsonData(identity))
            XCTAssertThrowsError(try invalid.validated())
        }
    }

    func testMissingOptionalIdentityOrganizationAndPlanHaveStableDefaults() throws {
        let valid = try snapshot()
        var oauth = try jsonObject(valid.oauth)
        oauth.removeValue(forKey: "rateLimitTier")
        oauth.removeValue(forKey: "subscriptionType")
        var identity = try jsonObject(valid.identity)
        identity.removeValue(forKey: "organizationUuid")
        let (login, _) = try CredentialSnapshot(oauth: jsonData(oauth), identity: jsonData(identity)).validated()
        XCTAssertEqual(login.organizationUUID, "")
        XCTAssertEqual(login.plan, "Claude")
    }

    func testRefreshIsNeededForExpiredOrMissingExpiryButNotFutureToken() throws {
        var oauth = try jsonObject(snapshot().oauth)
        XCTAssertFalse(try JSONDecoder().decode(OAuthCredential.self, from: jsonData(oauth)).needsRefresh)
        oauth["expiresAt"] = 1_000.0
        XCTAssertTrue(try JSONDecoder().decode(OAuthCredential.self, from: jsonData(oauth)).needsRefresh)
        oauth.removeValue(forKey: "expiresAt")
        XCTAssertTrue(try JSONDecoder().decode(OAuthCredential.self, from: jsonData(oauth)).needsRefresh)
    }

    func testUsageFractionsClampToDisplayRange() {
        XCTAssertEqual(UsageWindow(utilization: -5, resetsAt: nil).fraction, 0)
        XCTAssertEqual(UsageWindow(utilization: 37, resetsAt: nil).fraction, 0.37, accuracy: 0.0001)
        XCTAssertEqual(UsageWindow(utilization: 175, resetsAt: nil).fraction, 1)
    }
}
