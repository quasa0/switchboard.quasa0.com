import Foundation
import XCTest
@testable import SwitchboardCore

class CodexTestCase: XCTestCase {
    var root: URL!
    var installation: CodexInstallation!
    var secrets: MemorySecretStore!
    var repository: CodexAccountRepository!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SwitchboardCodexTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        installation = CodexInstallation(home: root.appendingPathComponent("user"), environment: [:])
        secrets = MemorySecretStore()
        repository = CodexAccountRepository(directory: root.appendingPathComponent("saved"), secrets: secrets, installation: installation)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func snapshot(_ user: String = "a", workspace: String? = nil, token: String = "original", refreshed: String = "2026-09-24T09:00:00Z", plan: String = "pro",
                  authClaims: [String: Any] = [:], jwtClaims: [String: Any] = [:]) throws -> CodexCredentialSnapshot {
        let auth: [String: Any] = ["chatgpt_user_id": "user-\(user)", "chatgpt_account_id": workspace ?? "workspace-\(user)", "chatgpt_plan_type": plan]
        let claims: [String: Any] = ["email": "\(user)@example.test", "sub": "user-\(user)",
            "https://api.openai.com/auth": auth.merging(authClaims, uniquingKeysWith: { _, new in new })]
        // Stable token bytes let repository tests compare newly constructed copies.
        let payload = try JSONSerialization.data(withJSONObject: claims.merging(jwtClaims, uniquingKeysWith: { _, new in new }), options: [.sortedKeys]).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let object: [String: Any] = ["auth_mode": "chatgpt", "OPENAI_API_KEY": NSNull(), "last_refresh": refreshed,
            "tokens": ["id_token": "header.\(payload).signature", "access_token": "synthetic-\(user)-\(token)", "refresh_token": "synthetic-refresh-\(user)-\(token)", "account_id": workspace ?? "workspace-\(user)", "future_token_field": true],
            "future_field": ["must_survive": "猫"]]
        return CodexCredentialSnapshot(authJSON: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }
    func seed(_ snapshot: CodexCredentialSnapshot) throws { try privateWrite(snapshot.authJSON, to: installation.authFile) }
}

final class CodexStorageTests: CodexTestCase {
    func testSubscriptionPeriodUsesMatchingClaimsWithoutChangingCredentialPayload() throws {
        let credential = try snapshot(authClaims: [
            "chatgpt_subscription_active_start": 1_758_672_000,
            "chatgpt_subscription_active_until": "2026-10-24T12:30:45.125+02:00",
            "chatgpt_subscription_last_checked": "2026-09-24T09:20:00Z",
            "will_renew": true,
            "poid": "unrelated-workspace",
            "organizations": [["id": "unrelated-workspace", "is_default": true]]
        ], jwtClaims: ["iat": 1_000_000_000, "exp": 4_102_444_800])
        let before = credential.authJSON
        let identity = try credential.validated()
        let period = try XCTUnwrap(identity.subscriptionPeriod)
        XCTAssertEqual(period.startsAt, Date(timeIntervalSince1970: 1_758_672_000))
        XCTAssertEqual(period.endsAt, try XCTUnwrap(SubscriptionDateParser.parse("2026-10-24T10:30:45.125Z")))
        XCTAssertEqual(period.checkedAt, SubscriptionDateParser.parse("2026-09-24T09:20:00Z"))
        XCTAssertEqual(period.source, .codexIDToken)
        XCTAssertNil(period.willRenew, "The known ID-token contract does not establish automatic renewal.")
        XCTAssertEqual(identity.organizationUUID, "workspace-a")
        XCTAssertEqual(credential.authJSON, before)
    }

    func testAbsentOrMalformedSubscriptionMetadataDoesNotRejectLogin() throws {
        XCTAssertNil(try snapshot().validated().subscriptionPeriod)
        for value in [NSNull(), "", "not a date", "2026-10-24", true, ["date": "2026-10-24"], 1_790_000_000_000] as [Any] {
            let identity = try snapshot(authClaims: ["chatgpt_subscription_active_until": value]).validated()
            XCTAssertEqual(identity.accountUUID, "user-a")
            XCTAssertNil(identity.subscriptionPeriod)
        }
        let invalidWindow = try snapshot(authClaims: [
            "chatgpt_subscription_active_start": "2026-11-01T00:00:00Z",
            "chatgpt_subscription_active_until": "2026-10-01T00:00:00Z"
        ]).validated()
        XCTAssertNil(invalidWindow.subscriptionPeriod)
        let invalidOptionalDates = try snapshot(authClaims: [
            "chatgpt_subscription_active_start": "unknown",
            "chatgpt_subscription_active_until": "2026-10-01T00:00:00Z",
            "chatgpt_subscription_last_checked": false
        ]).validated()
        XCTAssertNotNil(invalidOptionalDates.subscriptionPeriod)
        XCTAssertNil(invalidOptionalDates.subscriptionPeriod?.startsAt)
        XCTAssertNil(invalidOptionalDates.subscriptionPeriod?.checkedAt)
    }

    func testSubscriptionMetadataRequiresExplicitMatchingAccountClaim() throws {
        let identity = try snapshot(authClaims: [
            "chatgpt_account_id": NSNull(),
            "poid": "workspace-a",
            "chatgpt_subscription_active_until": "2026-10-01T00:00:00Z"
        ]).validated()
        XCTAssertEqual(identity.organizationUUID, "workspace-a")
        XCTAssertNil(identity.subscriptionPeriod, "A token-file account ID alone does not associate subscription claims.")
        XCTAssertThrowsError(try snapshot(authClaims: [
            "chatgpt_account_id": "another-account",
            "chatgpt_subscription_active_until": "2026-10-01T00:00:00Z"
        ]).validated())
    }

    func testSubscriptionObservationDoesNotAdvanceWithTokenRefreshOrExpiry() throws {
        let periodClaims: [String: Any] = ["chatgpt_subscription_active_until": "2025-09-01T00:00:00Z"]
        let first = try snapshot(refreshed: "2026-09-24T09:00:00Z", authClaims: periodClaims,
                                 jwtClaims: ["iat": 1_700_000_000, "exp": 4_102_444_800]).validated()
        let later = try snapshot(refreshed: "2027-09-24T09:00:00Z", authClaims: periodClaims,
                                 jwtClaims: ["iat": 1_700_000_000, "exp": 4_102_444_900]).validated()
        let period = try XCTUnwrap(first.subscriptionPeriod)
        XCTAssertEqual(period.checkedAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(period.endsAt, SubscriptionDateParser.parse("2025-09-01T00:00:00Z"))
        XCTAssertEqual(later.subscriptionPeriod, period, "A past period stays past; reading it must not project a new renewal.")
        let undated = try snapshot(authClaims: periodClaims, jwtClaims: ["exp": 4_102_444_800]).validated()
        XCTAssertNil(undated.subscriptionPeriod?.checkedAt)
    }

    func testIdentityAndFullPayloadSurviveAtomicSwitch() throws {
        let first = try snapshot(), second = try snapshot("b")
        try seed(first)
        try privateWrite(Data("model = \"example\"\n".utf8), to: installation.configFile)
        let originalConfig = try Data(contentsOf: installation.configFile)
        try repository.live.apply(second, ifUnchangedFrom: first)
        XCTAssertEqual(try repository.live.snapshot(), second)
        XCTAssertEqual(try second.validated(), CurrentLogin(email: "b@example.test", accountUUID: "user-b", organizationUUID: "workspace-b", plan: "Pro"))
        XCTAssertEqual(try Data(contentsOf: installation.configFile), originalConfig)
        let attributes = try FileManager.default.attributesOfItem(atPath: installation.authFile.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testTokenPlanIdentityUsesProviderTiersWithoutChangingAuthPayload() throws {
        for (rawPlan, expected) in [("prolite", "Pro Lite"), ("pro", "Pro"), ("plus", "Plus"),
                                    ("future_custom", "Future Custom"), ("business", "Business")] {
            let credential = try snapshot(plan: rawPlan)
            let original = credential.authJSON
            XCTAssertEqual(try credential.validated().plan, expected)
            XCTAssertEqual(credential.authJSON, original)
        }
    }
    func testRejectsChangedLiveCredentialBeforeAtomicReplacement() throws {
        let first = try snapshot(), rotated = try snapshot(token: "rotated")
        try seed(rotated)
        XCTAssertThrowsError(try repository.live.apply(snapshot("b"), ifUnchangedFrom: first))
        XCTAssertEqual(try repository.live.snapshot(), rotated)
    }
    func testUnsupportedStoresNeverChangeCredentials() throws {
        let original = try snapshot()
        try seed(original)
        for configuration in ["cli_auth_credentials_store = \"keyring\"", "cli_auth_credentials_store = 'auto'", "[profile]\ncli_auth_credentials_store = \"file\"", "'cli_auth_credentials_store' = \"file\"", "\"cli_auth_credentials\\u005fstore\" = \"keyring\""] {
            try privateWrite(Data(configuration.utf8), to: installation.configFile)
            XCTAssertThrowsError(try repository.live.apply(snapshot("b")))
            XCTAssertEqual(try Data(contentsOf: installation.authFile), original.authJSON)
            XCTAssertTrue(secrets.writes.isEmpty)
        }
    }
    func testExplicitFileStoreCommentsAndDefaultAreAccepted() throws {
        try installation.requireFileStorage()
        try privateWrite(Data("# cli_auth_credentials_store = \"auto\"\ncli_auth_credentials_store = 'file' # local\n[features]\nplugins = false\n".utf8), to: installation.configFile)
        try installation.requireFileStorage()
    }
    func testRejectsAPIKeyMalformedAndNonrefreshableLogins() throws {
        for raw in ["{}", "not json", "{\"OPENAI_API_KEY\":\"synthetic\"}"] {
            XCTAssertThrowsError(try CodexCredentialSnapshot(authJSON: Data(raw.utf8)).validated())
        }
        var object = try JSONSerialization.jsonObject(with: snapshot().authJSON) as! [String: Any]
        object["auth_mode"] = "chatgptAuthTokens"
        XCTAssertThrowsError(try CodexCredentialSnapshot(authJSON: JSONSerialization.data(withJSONObject: object)).validated())
        object["auth_mode"] = "chatgpt"
        var tokens = object["tokens"] as! [String: Any]
        tokens["account_id"] = "different-workspace"
        object["tokens"] = tokens
        XCTAssertThrowsError(try CodexCredentialSnapshot(authJSON: JSONSerialization.data(withJSONObject: object)).validated())
    }
    func testRejectsSymlinkWithoutChangingTarget() throws {
        let target = root.appendingPathComponent("protected.json"), original = try snapshot()
        try privateWrite(original.authJSON, to: target)
        try FileManager.default.createDirectory(at: installation.home, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: installation.authFile, withDestinationURL: target)
        XCTAssertThrowsError(try repository.live.apply(snapshot("b")))
        XCTAssertEqual(try Data(contentsOf: target), original.authJSON)
        try FileManager.default.removeItem(at: target)
        XCTAssertThrowsError(try repository.live.apply(snapshot("b")))
    }
}
