import Foundation

public enum CodexAuthenticationError: LocalizedError {
    case rejected, unauthorized, noWorkingCopy, loginChanged
    public var errorDescription: String? {
        switch self {
        case .rejected: return "Codex rejected this saved login. Reconnect this account in Switchboard: Add account → Sign in another account → Save new login."
        case .unauthorized: return "Codex rejected this saved login (HTTP 401). Reconnect this account in Switchboard: Add account → Sign in another account → Save new login."
        case .noWorkingCopy: return "No working saved ChatGPT login remains. Reconnect this account in Switchboard: Add account → Sign in another account → Save new login."
        case .loginChanged: return "Codex changed its login during the usage check. The new login was preserved. Refresh again."
        }
    }
}

/// Retries authentication failures only. Recovery never replaces the user's shared login.
public enum CodexUsageRecovery {
    public static func fetch(_ id: UUID, repository: CodexAccountRepository,
                             using fetch: (CodexInstallation) async throws -> UsageSnapshot) async throws {
        var attempted: [CodexCredentialSnapshot] = []
        var lastFailure: Error = CodexAuthenticationError.noWorkingCopy
        var forceIsolated = false
        // Shared login, primary, interrupted profile, and up to three historical copies.
        for _ in 0..<6 {
            try Task.checkCancellation()
            let installation: CodexInstallation
            do {
                installation = try repository.withLock { try repository.prepareUsage(id, excluding: attempted, forceIsolated: forceIsolated) }
            } catch is CodexAuthenticationError { throw lastFailure }
            let original = try repository.withLock { try repository.preparedCredential(id) }
            attempted.append(original)
            let result: Result<UsageSnapshot, Error>
            do { result = .success(try await fetch(installation)) }
            catch { result = .failure(error) }
            var collectionFailure: Error?
            // Retain token rotations on success, failure, and cancellation.
            do { try repository.withLock { try repository.collectUsageCredentials(id, from: installation) } }
            catch { collectionFailure = error }
            try Task.checkCancellation()
            if let collectionFailure {
                guard collectionFailure is CodexAuthenticationError else { throw collectionFailure }
                if installation == repository.live.installation {
                    // Logout can remove or replace the shared file without invalidating
                    // its saved token. Check that copy once in our isolated profile.
                    attempted.removeLast()
                    forceIsolated = true
                }
                lastFailure = collectionFailure
                continue
            }
            switch result {
            case .success(let usage):
                try repository.withLock { try repository.updateUsage(id, usage: usage) }
                return
            case .failure(let error):
                guard error is CodexAuthenticationError else { throw error }
                lastFailure = error
            }
        }
        throw lastFailure
    }
}
