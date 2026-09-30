import Foundation
import Darwin
import XCTest
@testable import SwitchboardCore

final class CodexUsageRecoveryTests: CodexTestCase {
    private let usage = UsageSnapshot(sevenDay: .init(utilization: 20, resetsAt: nil))

    func testAccountReadUnauthorizedRetriesBackupThroughActualUsageClient() async throws {
        let working = try snapshot(token: "working")
        let revoked = try snapshot(token: "revoked", refreshed: "2026-09-30T12:00:00Z")
        let desktop = try snapshot("b")
        let account = try repository.capture(working)
        try repository.capture(revoked)
        try seed(desktop)
        let executable = root.appendingPathComponent("synthetic-codex")
        let trace = root.appendingPathComponent("trace")
        let script = """
        #!/usr/bin/env python3
        import json, os, sys
        from pathlib import Path
        trace = Path(__file__).parent / 'trace'
        with trace.open('a') as out: out.write(str(os.getpid()) + '\\n')
        def reply(request, result=None, error=None):
            print(json.dumps({'id':request['id'], **({'error':error} if error else {'result':result})}), flush=True)
        first = json.loads(sys.stdin.readline())
        assert first['method'] == 'initialize'
        reply(first, {})
        assert json.loads(sys.stdin.readline())['method'] == 'initialized'
        auth = json.loads(Path(os.environ['CODEX_HOME'], 'auth.json').read_text())
        account = json.loads(sys.stdin.readline())
        assert account['method'] == 'account/read' and account['params'] == {'refreshToken':False}
        if auth['tokens']['access_token'].endswith('-revoked'):
            failure = {'code':-32603,'message':'workspace routing discovery unauthorized (401)'}
            reply(account, error=failure)
            refresh = json.loads(sys.stdin.readline())
            assert refresh['method'] == 'account/read' and refresh['params'] == {'refreshToken':True}
            reply(refresh, error=failure)
        else:
            assert auth['tokens']['access_token'].endswith('-working')
            reply(account, {'account':{'type':'chatgpt'}})
            usage = json.loads(sys.stdin.readline())
            assert usage['method'] == 'account/rateLimits/read'
            reply(usage, {'rateLimits':{'limitId':'codex','secondary':{'usedPercent':20,'windowDurationMins':10080}}})
        assert sys.stdin.read() == ''
        with trace.open('a') as out: out.write('clean\\n')
        """
        try privateWrite(Data(script.utf8), to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try await CodexUsageRecovery.fetch(account.id, repository: repository) { profile in
            try await CodexUsageClient(executable: executable).fetch(installation: profile)
        }
        XCTAssertEqual(try repository.credential(for: account.id), working)
        XCTAssertEqual(try repository.live.snapshot(), desktop)
        XCTAssertEqual(try repository.accounts().first?.usage?.sevenDay?.utilization, 20)
        let events = try String(contentsOf: trace, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(events.filter { $0 == "clean" }.count, 2)
        for pidText in events where pidText != "clean" {
            let pid = try XCTUnwrap(Int32(pidText))
            XCTAssertEqual(kill(pid, 0), -1)
            XCTAssertEqual(errno, ESRCH)
        }
    }

    func testDesktopLogoutUsesSavedCopyWithoutRestoringSharedLogin() async throws {
        let original = try snapshot()
        try seed(original)
        let account = try repository.capture(original)
        try FileManager.default.removeItem(at: installation.authFile)
        var checks = 0
        try await CodexUsageRecovery.fetch(account.id, repository: repository) { profile in
            checks += 1
            XCTAssertNotEqual(profile, self.installation)
            XCTAssertEqual(try CodexLoginStore(installation: profile).snapshot(), original)
            return self.usage
        }
        XCTAssertEqual(checks, 1)
        XCTAssertNil(try repository.live.snapshot())
        XCTAssertEqual(try repository.accounts().first?.usage, usage)
    }

    func testRevokedPrimaryRetriesHistoricalCopyAndKeepsOtherDesktopAccount() async throws {
        let working = try snapshot(token: "working")
        let rejected = try snapshot(token: "revoked", refreshed: "2026-09-30T12:00:00Z")
        let account = try repository.capture(working)
        try repository.capture(rejected)
        let desktop = try snapshot("b")
        try seed(desktop)
        var attempts: [CodexCredentialSnapshot] = []
        let rotated = try snapshot(token: "working-rotated", refreshed: "2026-09-30T13:00:00Z")
        try await CodexUsageRecovery.fetch(account.id, repository: repository) { profile in
            let credential = try XCTUnwrap(CodexLoginStore(installation: profile).snapshot())
            attempts.append(credential)
            if credential == rejected { throw CodexAuthenticationError.rejected }
            XCTAssertEqual(credential, working)
            try CodexLoginStore(installation: profile).apply(rotated)
            return self.usage
        }
        XCTAssertEqual(attempts, [rejected, working])
        XCTAssertEqual(try repository.credential(for: account.id), rotated)
        XCTAssertEqual(try repository.live.snapshot(), desktop)
    }

    func testDesktopChangesDuringCheckRetriesSavedCopyWithoutPublishingWrongUsage() async throws {
        let original = try snapshot(), replacement = try snapshot("b")
        try seed(original)
        let account = try repository.capture(original)
        var attempts = 0
        try await CodexUsageRecovery.fetch(account.id, repository: repository) { profile in
            attempts += 1
            if attempts == 1 {
                XCTAssertEqual(profile, self.installation)
                try self.seed(replacement)
                return UsageSnapshot(sevenDay: .init(utilization: 99, resetsAt: nil))
            }
            XCTAssertNotEqual(profile, self.installation)
            return self.usage
        }
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(try repository.accounts().first?.usage, usage)
        XCTAssertEqual(try repository.live.snapshot(), replacement)
    }

    func testMissingOrCorruptPrimaryCanRecoverHistory() async throws {
        let working = try snapshot(), newer = try snapshot(token: "newer")
        let account = try repository.capture(working)
        try repository.capture(newer)
        try secrets.write(Data("corrupt".utf8), service: repository.vaultService, account: account.id.uuidString)
        try await CodexUsageRecovery.fetch(account.id, repository: repository) { profile in
            XCTAssertEqual(try CodexLoginStore(installation: profile).snapshot(), working)
            return self.usage
        }
        XCTAssertEqual(try repository.credential(for: account.id), working)
    }

    func testNetworkFailureDoesNotTryOldTokensAndRetainsRotation() async throws {
        let account = try repository.capture(snapshot(token: "old"))
        try repository.capture(snapshot(token: "primary"))
        let rotated = try snapshot(token: "rotated", refreshed: "2026-09-30T13:00:00Z")
        var attempts = 0
        do {
            try await CodexUsageRecovery.fetch(account.id, repository: repository) { profile in
                attempts += 1
                try CodexLoginStore(installation: profile).apply(rotated)
                throw SwitchboardError.message("Synthetic HTTP 503")
            }
            XCTFail("Expected service failure")
        } catch { XCTAssertEqual(error.localizedDescription, "Synthetic HTTP 503") }
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(try repository.credential(for: account.id), rotated)
    }

    func testAllRevokedCopiesAreBoundedAndCachedUsageSurvives() async throws {
        let account = try repository.capture(snapshot(token: "0"))
        try repository.updateUsage(account.id, usage: usage)
        for i in 1...7 { try repository.capture(snapshot(token: String(i))) }
        var attempts: [CodexCredentialSnapshot] = []
        do {
            try await CodexUsageRecovery.fetch(account.id, repository: repository) { profile in
                attempts.append(try XCTUnwrap(CodexLoginStore(installation: profile).snapshot()))
                throw CodexAuthenticationError.rejected
            }
            XCTFail("Expected authentication failure")
        } catch { XCTAssertTrue(error is CodexAuthenticationError) }
        XCTAssertEqual(attempts.count, 4, "Primary plus three distinct historical copies")
        XCTAssertEqual(Set(attempts.map(\.authJSON)).count, 4)
        XCTAssertEqual(try repository.accounts().first?.usage, usage)
        try repository.remove(account.id)
        XCTAssertNil(try secrets.read(service: repository.vaultService, account: "\(account.id.uuidString).backups"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.usageInstallation(account.id).home.path))
    }

    func testKeychainReadFailureIsNotTreatedAsMissingPrimary() async throws {
        let account = try repository.capture(snapshot())
        secrets.beforeRead = { key in
            if key.account == account.id.uuidString { throw SwitchboardError.message("Keychain unavailable") }
        }
        do {
            try await CodexUsageRecovery.fetch(account.id, repository: repository) { _ in
                XCTFail("Must not launch a usage process")
                return self.usage
            }
            XCTFail("Expected Keychain failure")
        } catch { XCTAssertEqual(error.localizedDescription, "Keychain unavailable") }
    }

    func testFailedPrimaryWriteRollsBackBackupHistoryAndMetadata() throws {
        let account = try repository.capture(snapshot())
        let original = secrets.values
        let metadata = try repository.accounts()
        secrets.beforeWrite = { key in
            if key.account == account.id.uuidString { throw SwitchboardError.message("Synthetic failed write") }
        }
        XCTAssertThrowsError(try repository.capture(snapshot(token: "new")))
        XCTAssertEqual(secrets.values, original)
        XCTAssertEqual(try repository.accounts(), metadata)
    }

    func testCancellationRetainsRotationAndReleasesUsageGuard() async throws {
        let account = try repository.capture(snapshot())
        let rotated = try snapshot(token: "cancelled-rotation", refreshed: "2026-09-30T14:00:00Z")
        do {
            try await CodexUsageRecovery.fetch(account.id, repository: repository) { profile in
                try CodexLoginStore(installation: profile).apply(rotated)
                throw CancellationError()
            }
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try repository.credential(for: account.id), rotated)
        XCTAssertNil(try repository.accounts().first?.usage)
        try repository.activate(account.id)
        XCTAssertEqual(try repository.live.snapshot(), rotated)
    }

    func testOtherAccountBackupsNeverEnterAUsageProfile() async throws {
        let account = try repository.capture(snapshot())
        try secrets.delete(service: repository.vaultService, account: account.id.uuidString)
        try secrets.write(JSONEncoder().encode([snapshot("b")]), service: repository.vaultService,
            account: "\(account.id.uuidString).backups")
        do {
            try await CodexUsageRecovery.fetch(account.id, repository: repository) { _ in
                XCTFail("An unrelated login must never be used")
                return self.usage
            }
            XCTFail("Expected missing account credential")
        } catch { XCTAssertTrue(error is CodexAuthenticationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.usageInstallation(account.id).authFile.path))
    }

    func testFirstCaptureHasRedundantBackupBeforeAnyUsageOrRotation() async throws {
        let original = try snapshot()
        let account = try repository.capture(original)
        try secrets.delete(service: repository.vaultService, account: account.id.uuidString)
        try await CodexUsageRecovery.fetch(account.id, repository: repository) { profile in
            XCTAssertEqual(try CodexLoginStore(installation: profile).snapshot(), original)
            return self.usage
        }
        XCTAssertEqual(try repository.credential(for: account.id), original)
    }

    func testCorruptOwnedUsageProfileRepairsFromVaultButLinkedFilesRemainUntouched() async throws {
        let original = try snapshot(), desktop = try snapshot("b")
        try seed(desktop)
        let account = try repository.capture(original)
        let profile = repository.usageInstallation(account.id)
        try privateWrite(Data("corrupt".utf8), to: profile.authFile)
        try await CodexUsageRecovery.fetch(account.id, repository: repository) { installation in
            XCTAssertEqual(try CodexLoginStore(installation: installation).snapshot(), original)
            return self.usage
        }
        XCTAssertEqual(try repository.live.snapshot(), desktop)
        try FileManager.default.removeItem(at: profile.authFile)
        let target = root.appendingPathComponent("unrelated.json")
        try privateWrite(original.authJSON, to: target)
        try FileManager.default.createSymbolicLink(at: profile.authFile, withDestinationURL: target)
        XCTAssertThrowsError(try repository.prepareUsage(account.id))
        XCTAssertEqual(try Data(contentsOf: target), original.authJSON)
    }
}
