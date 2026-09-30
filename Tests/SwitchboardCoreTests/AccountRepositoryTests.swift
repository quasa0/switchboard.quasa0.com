import Foundation
import XCTest
@testable import SwitchboardCore

final class AccountRepositoryTests: RepositoryTestCase {
    func testFailedResetReadKeepsPreviousGrantsAndObservationTimeForThatAccount() throws {
        let a = try repository.capture(snapshot()), b = try repository.capture(snapshot("b"))
        let checked = Date(timeIntervalSince1970:1_790_000_000)
        let resets = try ClaudeResetSnapshot.parse(["eligible":true,"grants":[]],checkedAt:checked)
        try repository.setClaudeBilling(a.id,billing:ClaudeBillingSnapshot(status:"active",resetSnapshot:resets,resetReadFailed:false))
        try repository.setClaudeBilling(a.id,billing:ClaudeBillingSnapshot(status:"active",resetReadFailed:true))
        let accounts = try repository.accounts()
        XCTAssertEqual(accounts.first(where:{$0.id==a.id})?.claudeBilling?.resetSnapshot,resets)
        XCTAssertEqual(accounts.first(where:{$0.id==a.id})?.claudeBilling?.resetReadFailed,true)
        XCTAssertNil(accounts.first(where:{$0.id==b.id})?.claudeBilling)
        let empty = try ClaudeResetSnapshot.parse(["eligible":true,"grants":[]])
        try repository.setClaudeBilling(a.id,billing:ClaudeBillingSnapshot(status:"active",resetSnapshot:empty,resetReadFailed:false))
        XCTAssertEqual(try repository.accounts().first(where:{$0.id==a.id})?.claudeBilling?.resetSnapshot,empty)
    }

    func testWebBillingIsMetadataOnlyAndSurvivesCredentialRecapture() throws {
        let first = try snapshot()
        try seedLive(first)
        let account = try repository.capture(first)
        let secretsBefore = secrets.values, writesBefore = secrets.writes
        let configBefore = try Data(contentsOf: installation.configFile)
        let billing = ClaudeBillingSnapshot(checkedAt: Date(timeIntervalSince1970: 1_790_000_000),
            status: "active", nextChargeDate: "2026-09-27", giftPaidThrough: "2027-01-27")
        try repository.withLock { try repository.setClaudeBilling(account.id, billing: billing) }
        XCTAssertEqual(try repository.accounts().first?.claudeBilling, billing)
        XCTAssertEqual(secrets.values, secretsBefore)
        XCTAssertEqual(secrets.writes, writesBefore)
        XCTAssertEqual(try Data(contentsOf: installation.configFile), configBefore)
        XCTAssertEqual(try repository.capture(first).claudeBilling, billing)
        XCTAssertThrowsError(try repository.setClaudeBilling(UUID(), billing: billing))
        XCTAssertEqual(try repository.accounts().first?.claudeBilling, billing)
    }

    func testManualRenewalIsScopedToAccountPersistsAndNeverChangesLiveLogin() throws {
        let first = try snapshot(), second = try snapshot("b")
        try seedLive(first, config: ["theme": "dark"])
        let a = try repository.capture(first, label: "Personal"), b = try repository.capture(second, label: "Work")
        let originalConfig = try Data(contentsOf: installation.configFile)
        let originalLive = secrets.value(installation: installation)
        let originalSecrets = secrets.values, originalWrites = secrets.writes, originalDeletes = secrets.deletes
        let renewal = Date(timeIntervalSince1970: 1_817_265_723.5)
        try repository.withLock { try repository.setRenewal(a.id, date: renewal) }
        var expected = a
        expected.renewalAt = renewal
        XCTAssertEqual(try repository.accounts(), [expected, b])
        XCTAssertEqual(secrets.values, originalSecrets)
        XCTAssertEqual(secrets.writes, originalWrites)
        XCTAssertEqual(secrets.deletes, originalDeletes)

        let reopened = AccountRepository(directory: repository.directory, secrets: secrets, installation: installation)
        XCTAssertEqual(try reopened.accounts(), [expected, b])
        let recaptured = try reopened.capture(snapshot(token: "synthetic-renewal-rotated"))
        XCTAssertEqual(recaptured, expected)
        let postCaptureSecrets = secrets.values, postCaptureWrites = secrets.writes
        try reopened.withLock { try reopened.setRenewal(a.id, date: nil) }
        XCTAssertEqual(try reopened.accounts(), [a, b])
        XCTAssertEqual(secrets.values, postCaptureSecrets)
        XCTAssertEqual(secrets.writes, postCaptureWrites)
        XCTAssertEqual(secrets.deletes, originalDeletes)
        XCTAssertEqual(secrets.value(installation: installation), originalLive)
        XCTAssertEqual(try Data(contentsOf: installation.configFile), originalConfig)
    }

    func testManualRenewalForMissingAccountFailsWithoutChangingMetadataOrLogin() throws {
        let first = try snapshot()
        try seedLive(first)
        try repository.capture(first)
        let metadataFile = repository.directory.appendingPathComponent("accounts.json")
        let metadata = try Data(contentsOf: metadataFile), config = try Data(contentsOf: installation.configFile)
        let originalSecrets = secrets.values, originalWrites = secrets.writes
        XCTAssertThrowsError(try repository.withLock { try repository.setRenewal(UUID(), date: Date()) })
        XCTAssertEqual(try Data(contentsOf: metadataFile), metadata)
        XCTAssertEqual(try Data(contentsOf: installation.configFile), config)
        XCTAssertEqual(secrets.values, originalSecrets)
        XCTAssertEqual(secrets.writes, originalWrites)
    }

    func testSwitchRoundTripSavesRotatedTokenAndPreservesUnrelatedSettingsAndCredentials() throws {
        let first = try snapshot("a")
        let second = try snapshot("b")
        let caches = ["additionalModelOptionsCache", "additionalModelOptionsAnsweredAt",
                      "additionalModelCostsCache", "modelAccessCache", "orgModelDefaultCache",
                      "cachedArtifactRoster", "artifactRosterDenied", "lastSeenOrgDefaultUpdatedAt",
                      "clientDataCache", "clientDataCacheSlots", "autoCompactWindowsCache",
                      "cachedUsageUtilization", "githubWebConnectionStatusCache", "startupPrefetchedAt"]
        var config: [String: Any] = ["theme": "dark", "projects": ["/project": ["hasTrustDialogAccepted": true]],
                                     "mcpServers": ["local": ["command": "example"]]]
        caches.forEach { config[$0] = ["staleAccount": "a"] }
        let unrelated: [String: Any] = ["mcpOAuth": ["server-one": ["accessToken": "synthetic-mcp-secret"]],
                                         "unrelatedCredential": "synthetic-other-secret"]
        var siblings = unrelated
        for key in ["organizationUuid", "trustedDeviceToken", "enterpriseGateway", "designOauth"] {
            siblings[key] = "account-a-only"
        }
        try seedLive(first, config: config, credentialSiblings: siblings)
        try repository.withLock { try repository.captureCurrent(label: "Personal") }
        let accountA = try XCTUnwrap(repository.accounts().first)
        let accountB = try repository.withLock { try repository.capture(second, label: "Work") }

        let rotated = try snapshot("a", token: "synthetic-rotated-a")
        var liveCredentials = try jsonObject(XCTUnwrap(secrets.value(installation: installation)))
        liveCredentials["claudeAiOauth"] = try jsonObject(rotated.oauth)
        secrets.seed(try jsonData(liveCredentials), installation: installation)

        try repository.withLock { try repository.activate(accountB.id) }
        XCTAssertEqual(try token(repository.credential(for: accountA.id)), "synthetic-rotated-a")
        XCTAssertEqual(try token(XCTUnwrap(repository.live.snapshot())), "synthetic-access-b")
        XCTAssertEqual(try repository.state().activeID, accountB.id)
        let switchedConfig = try readObject(installation.configFile)
        XCTAssertEqual(switchedConfig["theme"] as? String, "dark")
        try assertJSONEqual(jsonData(XCTUnwrap(switchedConfig["projects"])), jsonData(XCTUnwrap(config["projects"])))
        try assertJSONEqual(jsonData(XCTUnwrap(switchedConfig["mcpServers"])), jsonData(XCTUnwrap(config["mcpServers"])))
        for key in caches { XCTAssertNil(switchedConfig[key], "Account cache survived: \(key)") }
        let switchedCredentials = try jsonObject(XCTUnwrap(secrets.value(installation: installation)))
        for (key, value) in unrelated {
            try assertJSONEqual(jsonData(XCTUnwrap(switchedCredentials[key])), jsonData(value))
        }
        for key in ["organizationUuid", "trustedDeviceToken", "enterpriseGateway", "designOauth"] {
            XCTAssertNil(switchedCredentials[key], "Account credential survived: \(key)")
        }
        let appliedOAuth = try XCTUnwrap(switchedCredentials["claudeAiOauth"] as? [String: Any])
        XCTAssertNotNil(appliedOAuth["futureTokenMetadata"])

        try repository.withLock { try repository.activate(accountA.id) }
        XCTAssertEqual(try token(XCTUnwrap(repository.live.snapshot())), "synthetic-rotated-a")
        XCTAssertEqual(try token(repository.credential(for: accountB.id)), "synthetic-access-b")
        XCTAssertEqual(try repository.state().activeID, accountA.id)
        let rollback = try XCTUnwrap(secrets.read(service: AccountRepository.vaultService, account: "previous-login"))
        XCTAssertEqual(try token(JSONDecoder().decode(CredentialSnapshot.self, from: rollback)), "synthetic-access-b")
    }

    func testCapturingSameAccountUpsertsButOrganizationCreatesSeparateEntry() throws {
        let initial = try repository.capture(snapshot(), label: "  Personal  ")
        let usage = UsageSnapshot(fiveHour: UsageWindow(utilization: 42, resetsAt: nil))
        try repository.updateUsage(initial.id, usage: usage)
        let repeated = try repository.capture(snapshot(token: "synthetic-new-token"), label: "\n ")
        XCTAssertEqual(initial.id, repeated.id)
        XCTAssertEqual(initial.addedAt, repeated.addedAt)
        XCTAssertEqual(repeated.label, "Personal")
        XCTAssertEqual(repeated.usage, usage)
        XCTAssertEqual(try repository.accounts().count, 1)
        XCTAssertEqual(try token(repository.credential(for: initial.id)), "synthetic-new-token")

        let otherOrganization = try repository.capture(snapshot(organization: "other-organization"), label: "Work")
        XCTAssertNotEqual(otherOrganization.id, initial.id)
        XCTAssertEqual(otherOrganization.accountUUID, initial.accountUUID)
        XCTAssertEqual(try repository.accounts().count, 2)
    }

    func testMetadataContainsDisplayInformationButNoCredentials() throws {
        let account = try repository.withLock { try repository.capture(snapshot(), label: "Personal") }
        try repository.updateUsage(account.id, usage: UsageSnapshot(fiveHour: UsageWindow(utilization: 12, resetsAt: nil)))
        let metadata = try String(contentsOf: repository.directory.appendingPathComponent("accounts.json"), encoding: .utf8)
        XCTAssertTrue(metadata.contains("a@example.test"))
        XCTAssertTrue(metadata.contains("Personal"))
        for secret in ["synthetic-access", "synthetic-refresh", "accessToken", "refreshToken", "claudeAiOauth", "futureTokenMetadata"] {
            XCTAssertFalse(metadata.contains(secret), "Secret field was written to account metadata: \(secret)")
        }
    }

    func testMissingTargetCredentialCannotReplaceLiveLogin() throws {
        let first = try snapshot()
        try seedLive(first, config: ["theme": "dark"])
        let missing = try repository.capture(snapshot("b"))
        try secrets.delete(service: AccountRepository.vaultService, account: missing.id.uuidString)
        let originalKeychain = secrets.value(installation: installation)
        let originalConfig = try Data(contentsOf: installation.configFile)

        XCTAssertThrowsError(try repository.withLock { try repository.activate(missing.id) })
        XCTAssertEqual(secrets.value(installation: installation), originalKeychain)
        XCTAssertEqual(try Data(contentsOf: installation.configFile), originalConfig)
        XCTAssertEqual(try repository.accounts().count, 2)
        let savedCurrent = try XCTUnwrap(repository.accounts().first { $0.accountUUID == "account-a" })
        XCTAssertEqual(try token(repository.credential(for: savedCurrent.id)), "synthetic-access-a")
    }

    func testCorruptTargetCredentialCannotReplaceLiveLogin() throws {
        try seedLive(snapshot())
        let target = try repository.capture(snapshot("b"))
        secrets.values[SecretKey(service: AccountRepository.vaultService, account: target.id.uuidString)] = Data("corrupt".utf8)
        let originalKeychain = secrets.value(installation: installation)
        let originalConfig = try Data(contentsOf: installation.configFile)

        XCTAssertThrowsError(try repository.withLock { try repository.activate(target.id) })
        XCTAssertEqual(secrets.value(installation: installation), originalKeychain)
        XCTAssertEqual(try Data(contentsOf: installation.configFile), originalConfig)
    }

    func testInvalidCurrentLoginStopsSwitchWithoutDiscardingEitherSavedAccount() throws {
        let accountA = try repository.capture(snapshot())
        let accountB = try repository.capture(snapshot("b"))
        try seedLive(snapshot())
        secrets.seed(Data("invalid-json".utf8), installation: installation)
        let originalConfig = try Data(contentsOf: installation.configFile)
        let originalValues = secrets.values

        XCTAssertThrowsError(try repository.withLock { try repository.activate(accountB.id) })
        XCTAssertEqual(secrets.values, originalValues)
        XCTAssertEqual(try Data(contentsOf: installation.configFile), originalConfig)
        XCTAssertEqual(try token(repository.credential(for: accountA.id)), "synthetic-access-a")
        XCTAssertEqual(try token(repository.credential(for: accountB.id)), "synthetic-access-b")
    }

    func testRemovingActiveAccountDeletesSavedCopyAndProfileButDoesNotLogOutCLI() throws {
        let first = try snapshot()
        try seedLive(first)
        let account = try repository.capture(first)
        let profile = repository.usageInstallation(account.id)
        try ClaudeLoginStore(installation: profile, secrets: secrets).apply(first)
        let originalKeychain = secrets.value(installation: installation)
        let originalConfig = try Data(contentsOf: installation.configFile)

        try repository.withLock { try repository.remove(account.id) }
        XCTAssertTrue(try repository.accounts().isEmpty)
        XCTAssertThrowsError(try repository.credential(for: account.id))
        XCTAssertEqual(secrets.value(installation: installation), originalKeychain)
        XCTAssertEqual(try Data(contentsOf: installation.configFile), originalConfig)
        XCTAssertNil(secrets.value(installation: profile))
        XCTAssertFalse(FileManager.default.fileExists(atPath: profile.configDirectory.path))
    }

    func testPrepareAndCollectInactiveUsagePreservesRotatedCredentialsWithoutChangingActiveAccount() throws {
        let first = try snapshot()
        try seedLive(first)
        let active = try repository.capture(first, label: "Personal")
        let inactive = try repository.capture(snapshot("b"), label: "Work")
        let originalKeychain = secrets.value(installation: installation)
        let originalConfig = try Data(contentsOf: installation.configFile)

        let profile = try repository.prepareUsage(inactive.id)
        XCTAssertNotEqual(profile.keychainService, installation.keychainService)
        XCTAssertEqual(try token(XCTUnwrap(ClaudeLoginStore(installation: profile, secrets: secrets).snapshot())), "synthetic-access-b")
        try ClaudeLoginStore(installation: profile, secrets: secrets).apply(snapshot("b", token: "synthetic-refreshed-b"))
        try repository.collectUsageCredentials(inactive.id, from: profile)
        XCTAssertEqual(try token(repository.credential(for: inactive.id)), "synthetic-refreshed-b")
        XCTAssertEqual(try repository.accounts().first { $0.id == inactive.id }?.label, "Work")
        XCTAssertEqual(secrets.value(installation: installation), originalKeychain)
        XCTAssertEqual(try Data(contentsOf: installation.configFile), originalConfig)
        XCTAssertEqual(try repository.state().activeID, active.id)

        let nextProfile = try repository.prepareUsage(inactive.id)
        XCTAssertEqual(try token(XCTUnwrap(ClaudeLoginStore(installation: nextProfile, secrets: secrets).snapshot())), "synthetic-refreshed-b")
    }

    func testPrepareActiveUsageCapturesCurrentTokenAndUsesLiveInstallation() throws {
        let account = try repository.capture(snapshot())
        try seedLive(snapshot(token: "synthetic-cli-rotated-a"))
        let prepared = try repository.prepareUsage(account.id)
        XCTAssertEqual(prepared.configFile, installation.configFile)
        XCTAssertEqual(prepared.keychainService, installation.keychainService)
        XCTAssertEqual(try token(repository.credential(for: account.id)), "synthetic-cli-rotated-a")
    }

    func testCollectRejectsAnotherIdentityWithoutOverwritingSavedCredential() throws {
        let account = try repository.capture(snapshot())
        let profile = repository.usageInstallation(account.id)
        try ClaudeLoginStore(installation: profile, secrets: secrets).apply(snapshot("b"))
        let previous = try repository.credential(for: account.id)
        XCTAssertThrowsError(try repository.collectUsageCredentials(account.id, from: profile))
        XCTAssertEqual(try repository.credential(for: account.id), previous)
        XCTAssertEqual(try repository.accounts().count, 1)
    }

    func testAnotherRepositoryCannotMutateWhileLockIsHeld() throws {
        let other = AccountRepository(directory: repository.directory, secrets: secrets, installation: installation)
        var ranOperation = false
        try repository.withLock {
            XCTAssertThrowsError(try other.withLock { ranOperation = true })
        }
        XCTAssertFalse(ranOperation)
        try other.withLock { ranOperation = true }
        XCTAssertTrue(ranOperation)
    }

    func testCaptureRollsBackVaultWhenMetadataCannotBeWritten() throws {
        let saved = try repository.capture(snapshot(), label: "Personal")
        let originalValues = secrets.values
        let metadataFile = repository.directory.appendingPathComponent("accounts.json")
        let originalMetadata = try Data(contentsOf: metadataFile)

        try withReadOnlyDirectory(repository.directory) {
            XCTAssertThrowsError(try repository.capture(snapshot(token: "synthetic-new-token"), label: "Changed"))
        }
        XCTAssertEqual(secrets.values, originalValues)
        XCTAssertEqual(try Data(contentsOf: metadataFile), originalMetadata)
        XCTAssertEqual(try repository.accounts(), [saved])
    }

    func testCaptureRemovesNewVaultEntryWhenMetadataCannotBeWritten() throws {
        let saved = try repository.capture(snapshot())
        let originalValues = secrets.values
        let metadataFile = repository.directory.appendingPathComponent("accounts.json")
        let originalMetadata = try Data(contentsOf: metadataFile)

        try withReadOnlyDirectory(repository.directory) {
            XCTAssertThrowsError(try repository.capture(snapshot("b")))
        }
        XCTAssertEqual(secrets.values, originalValues)
        XCTAssertEqual(try Data(contentsOf: metadataFile), originalMetadata)
        XCTAssertEqual(try repository.accounts(), [saved])
    }

    func testRemovalRestoresVaultWhenMetadataCannotBeWritten() throws {
        let saved = try repository.capture(snapshot())
        let originalValues = secrets.values
        let metadataFile = repository.directory.appendingPathComponent("accounts.json")
        let originalMetadata = try Data(contentsOf: metadataFile)

        try withReadOnlyDirectory(repository.directory) {
            XCTAssertThrowsError(try repository.remove(saved.id))
        }
        XCTAssertEqual(secrets.values, originalValues)
        XCTAssertEqual(try Data(contentsOf: metadataFile), originalMetadata)
        XCTAssertEqual(try repository.accounts(), [saved])
    }
}
