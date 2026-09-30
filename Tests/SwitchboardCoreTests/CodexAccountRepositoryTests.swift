import Foundation
import XCTest
@testable import SwitchboardCore

final class CodexAccountRepositoryTests: CodexTestCase {
    func testAutomaticPeriodPersistsAndUpdatesWithoutReplacingManualRenewalOrLiveLogin() throws {
        let live = try snapshot()
        try seed(live)
        let first = try snapshot("b", authClaims: [
            "chatgpt_subscription_active_until": "2026-10-24T09:00:00Z",
            "chatgpt_subscription_last_checked": "2026-09-24T09:00:00Z"
        ])
        let saved = try repository.capture(first)
        let manual = Date(timeIntervalSince1970: 1_850_000_000)
        try repository.setRenewal(saved.id, date: manual)
        let updated = try snapshot("b", token: "rotated", authClaims: [
            "chatgpt_subscription_active_until": "2026-11-24T09:00:00Z",
            "chatgpt_subscription_last_checked": "2026-10-24T09:00:00Z"
        ])
        let recaptured = try repository.capture(updated)
        XCTAssertEqual(recaptured.subscriptionPeriod, try updated.validated().subscriptionPeriod)
        XCTAssertEqual(recaptured.renewalAt, manual)
        let reopened = CodexAccountRepository(directory: repository.directory, secrets: secrets, installation: installation)
        XCTAssertEqual(try reopened.accounts(), [recaptured])
        XCTAssertEqual(try Data(contentsOf: installation.authFile), live.authJSON)
        let metadata = try String(contentsOf: repository.directory.appendingPathComponent("accounts.json"), encoding: .utf8)
        XCTAssertTrue(metadata.contains("codexIDToken"))
        XCTAssertFalse(metadata.contains("access_token"))
        XCTAssertFalse(metadata.contains("id_token"))
        try reopened.setRenewal(saved.id, date: nil)
        XCTAssertEqual(try reopened.accounts().first?.subscriptionPeriod, recaptured.subscriptionPeriod)
    }

    func testOmittedMalformedOrOlderClaimsKeepTheOriginalObservationTime() throws {
        let original = try snapshot(authClaims: [
            "chatgpt_subscription_active_until": "2026-10-24T09:00:00Z",
            "chatgpt_subscription_last_checked": "2026-09-24T09:00:00Z"
        ])
        let saved = try repository.capture(original)
        let missing = try snapshot(refreshed: "2027-01-01T00:00:00Z")
        let malformed = try snapshot(authClaims: ["chatgpt_subscription_active_until": false])
        let older = try snapshot(authClaims: [
            "chatgpt_subscription_active_until": "2026-09-24T09:00:00Z",
            "chatgpt_subscription_last_checked": "2026-08-24T09:00:00Z"
        ])
        for credential in [missing, malformed, older] {
            let recaptured = try repository.capture(credential)
            XCTAssertEqual(recaptured.subscriptionPeriod, saved.subscriptionPeriod)
            XCTAssertEqual(recaptured.id, saved.id)
        }
    }

    func testAutomaticPeriodsRemainScopedToSavedWorkspace() throws {
        let personal = try repository.capture(snapshot(authClaims: [
            "chatgpt_subscription_active_until": "2026-10-24T09:00:00Z"
        ]))
        let workspace = try repository.capture(snapshot(workspace: "different-workspace", authClaims: [
            "chatgpt_subscription_active_until": "2026-11-01T00:00:00Z"
        ]))
        XCTAssertNotEqual(personal.id, workspace.id)
        XCTAssertNotEqual(personal.subscriptionPeriod?.endsAt, workspace.subscriptionPeriod?.endsAt)
        XCTAssertEqual(try repository.accounts(), [personal, workspace])
    }

    func testOrdinaryUsageCollectionAddsPeriodToPreviouslySavedAccount() throws {
        let live = try snapshot()
        try seed(live)
        let saved = try repository.capture(snapshot("b"))
        XCTAssertNil(saved.subscriptionPeriod)
        let installation = try repository.prepareUsage(saved.id)
        let rotated = try snapshot("b", token: "usage-refresh", authClaims: [
            "chatgpt_subscription_active_until": "2026-10-24T09:00:00Z",
            "chatgpt_subscription_last_checked": "2026-09-24T09:00:00Z"
        ])
        try CodexLoginStore(installation: installation).apply(rotated)
        try repository.collectUsageCredentials(saved.id, from: installation)
        XCTAssertEqual(try repository.accounts().first?.subscriptionPeriod, try rotated.validated().subscriptionPeriod)
        XCTAssertEqual(try repository.credential(for: saved.id), rotated)
        XCTAssertEqual(try repository.live.snapshot(), live)
    }

    func testManualRenewalIsScopedToAccountPersistsAndNeverChangesLiveLogin() throws {
        let first = try snapshot(), second = try snapshot("b")
        try seed(first)
        try privateWrite(Data("model = \"synthetic-model\"\n".utf8), to: installation.configFile)
        let a = try repository.capture(first, label: "Personal"), b = try repository.capture(second, label: "Work")
        let originalConfig = try Data(contentsOf: installation.configFile)
        let originalAuth = try Data(contentsOf: installation.authFile)
        let originalSecrets = secrets.values, originalWrites = secrets.writes, originalDeletes = secrets.deletes
        let renewal = Date(timeIntervalSince1970: 1_817_265_723.5)
        try repository.withLock { try repository.setRenewal(b.id, date: renewal) }
        var expected = b
        expected.renewalAt = renewal
        XCTAssertEqual(try repository.accounts(), [a, expected])
        XCTAssertEqual(secrets.values, originalSecrets)
        XCTAssertEqual(secrets.writes, originalWrites)
        XCTAssertEqual(secrets.deletes, originalDeletes)

        let reopened = CodexAccountRepository(directory: repository.directory, secrets: secrets, installation: installation)
        XCTAssertEqual(try reopened.accounts(), [a, expected])
        let recaptured = try reopened.capture(snapshot("b", token: "synthetic-renewal-rotated"))
        XCTAssertEqual(recaptured, expected)
        let postCaptureSecrets = secrets.values, postCaptureWrites = secrets.writes
        try reopened.withLock { try reopened.setRenewal(b.id, date: nil) }
        XCTAssertEqual(try reopened.accounts(), [a, b])
        XCTAssertEqual(secrets.values, postCaptureSecrets)
        XCTAssertEqual(secrets.writes, postCaptureWrites)
        XCTAssertEqual(secrets.deletes, originalDeletes)
        XCTAssertEqual(try Data(contentsOf: installation.authFile), originalAuth)
        XCTAssertEqual(try Data(contentsOf: installation.configFile), originalConfig)
    }

    func testManualRenewalForMissingAccountFailsWithoutChangingMetadataOrLogin() throws {
        let first = try snapshot()
        try seed(first)
        try repository.capture(first)
        let metadataFile = repository.directory.appendingPathComponent("accounts.json")
        let metadata = try Data(contentsOf: metadataFile), auth = try Data(contentsOf: installation.authFile)
        let originalSecrets = secrets.values, originalWrites = secrets.writes
        XCTAssertThrowsError(try repository.withLock { try repository.setRenewal(UUID(), date: Date()) })
        XCTAssertEqual(try Data(contentsOf: metadataFile), metadata)
        XCTAssertEqual(try Data(contentsOf: installation.authFile), auth)
        XCTAssertEqual(secrets.values, originalSecrets)
        XCTAssertEqual(secrets.writes, originalWrites)
    }

    func testRoundTripPreservesRotationsPreviousLoginAndMetadata() throws {
        let first = try snapshot(), second = try snapshot("b")
        try seed(first)
        let a = try repository.capture(first, label: "Personal"), b = try repository.capture(second, label: "Work")
        let rotated = try snapshot(token: "rotated", refreshed: "2026-09-24T10:00:00Z")
        try seed(rotated)
        try repository.withLock { try repository.activate(b.id) }
        XCTAssertEqual(try repository.credential(for: a.id), rotated)
        XCTAssertEqual(try repository.live.snapshot(), second)
        try repository.withLock { try repository.activate(a.id) }
        XCTAssertEqual(try repository.live.snapshot(), rotated)
        XCTAssertEqual(try repository.state().activeID, a.id)
        let previous = try XCTUnwrap(secrets.read(service: CodexAccountRepository.vaultService, account: "previous-login"))
        XCTAssertEqual(try JSONDecoder().decode(CodexCredentialSnapshot.self, from: previous), second)
        let metadata = try String(contentsOf: repository.directory.appendingPathComponent("accounts.json"), encoding: .utf8)
        XCTAssertFalse(metadata.contains("synthetic")); XCTAssertFalse(metadata.contains("refresh_token"))
        XCTAssertEqual(try repository.accounts().first { $0.id == a.id }?.label, "Personal")
    }
    func testIdentityIncludesWorkspaceAndPreservesUsageOnRecapture() throws {
        let account = try repository.capture(snapshot(), label: "Personal")
        let usage = UsageSnapshot(fiveHour: .init(utilization: 42, resetsAt: nil))
        try repository.updateUsage(account.id, usage: usage)
        let recaptured = try repository.capture(snapshot(token: "rotated"))
        XCTAssertEqual(recaptured.id, account.id); XCTAssertEqual(recaptured.usage, usage)
        XCTAssertEqual(recaptured.label, "Personal")
        let workspace = try repository.capture(snapshot(workspace: "team"))
        XCTAssertNotEqual(workspace.id, account.id)
    }
    func testUsageUsesLiveFileForActiveAccountAndCollectsInactiveRefresh() throws {
        let first = try snapshot(), second = try snapshot("b")
        try seed(first)
        let a = try repository.capture(first), b = try repository.capture(second)
        let liveProfile = try repository.prepareUsage(a.id)
        XCTAssertEqual(liveProfile.home, installation.home)
        XCTAssertThrowsError(try repository.activate(b.id))
        let liveRotated = try snapshot(token: "live-refresh", refreshed: "2026-09-24T11:00:00Z")
        try seed(liveRotated)
        try repository.collectUsageCredentials(a.id, from: liveProfile)
        XCTAssertEqual(try repository.credential(for: a.id), liveRotated)
        let profile = try repository.prepareUsage(b.id)
        XCTAssertNotEqual(profile.home, installation.home)
        let inactiveRotated = try snapshot("b", token: "inactive-refresh", refreshed: "2026-09-24T12:00:00Z")
        try CodexLoginStore(installation: profile).apply(inactiveRotated)
        try repository.collectUsageCredentials(b.id, from: profile)
        XCTAssertEqual(try repository.credential(for: b.id), inactiveRotated)
        XCTAssertEqual(try repository.live.snapshot(), liveRotated)
    }
    func testStaleUsageCannotOverwriteNewerCapture() throws {
        try seed(snapshot())
        let account = try repository.capture(snapshot("b"))
        let profile = try repository.prepareUsage(account.id)
        let newer = try snapshot("b", token: "new-browser-login", refreshed: "2026-09-24T13:00:00Z")
        try repository.capture(newer)
        XCTAssertThrowsError(try repository.collectUsageCredentials(account.id, from: profile))
        XCTAssertEqual(try repository.credential(for: account.id), newer)
        // Collection failure releases the in-flight guard.
        try repository.activate(account.id)
        XCTAssertEqual(try repository.live.snapshot(), newer)
    }
    func testInterruptedUsageRotationIsRecoveredBeforeSwitch() throws {
        try seed(snapshot())
        let account = try repository.capture(snapshot("b"))
        let profile = try repository.prepareUsage(account.id)
        let rotated = try snapshot("b", token: "recovered", refreshed: "2026-09-24T14:00:00Z")
        try CodexLoginStore(installation: profile).apply(rotated)
        let reopened = CodexAccountRepository(directory: repository.directory, secrets: secrets, installation: installation)
        try reopened.activate(account.id)
        XCTAssertEqual(try reopened.credential(for: account.id), rotated)
        XCTAssertEqual(try reopened.live.snapshot(), rotated)
    }
    func testMissingPrimaryRestoresFromBackupAndRemovalPreservesLiveLogin() throws {
        let first = try snapshot()
        try seed(first)
        let saved = try repository.capture(snapshot("b"))
        try secrets.delete(service: CodexAccountRepository.vaultService, account: saved.id.uuidString)
        try repository.activate(saved.id)
        XCTAssertEqual(try repository.live.snapshot(), try snapshot("b"))
        try repository.remove(saved.id)
        XCTAssertEqual(try repository.live.snapshot(), try snapshot("b"))
    }
    func testLockExcludesOtherRepository() throws {
        let other = CodexAccountRepository(directory: repository.directory, secrets: secrets, installation: installation)
        try repository.withLock { XCTAssertThrowsError(try other.withLock { () }) }
        try other.withLock { () }
    }
}
