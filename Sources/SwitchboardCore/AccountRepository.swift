import Foundation
import Darwin

public final class AccountRepository {
    public static let vaultService = "com.quasa0.switchboard.accounts"
    public let directory: URL
    public let secrets: SecretStore
    public let live: ClaudeLoginStore
    public let vaultService: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(directory: URL, secrets: SecretStore, installation: ClaudeInstallation,
                vaultService: String = AccountRepository.vaultService) {
        self.directory = directory; self.secrets = secrets
        self.vaultService = vaultService
        self.live = ClaudeLoginStore(installation: installation, secrets: secrets)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    public func withLock<T>(_ operation: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(directory.appendingPathComponent("accounts.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw SwitchboardError.message("Cannot open the account lock.") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            throw SwitchboardError.message("Another Switchboard window is updating accounts. Try again.")
        }
        defer { flock(fd, LOCK_UN) }
        return try operation()
    }

    public func accounts() throws -> [SavedAccount] {
        let url = directory.appendingPathComponent("accounts.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try decoder.decode([SavedAccount].self, from: Data(contentsOf: url))
    }
    private func save(_ accounts: [SavedAccount]) throws {
        try privateWrite(encoder.encode(accounts), to: directory.appendingPathComponent("accounts.json"))
    }
    public func credential(for id: UUID) throws -> CredentialSnapshot {
        guard let data = try secrets.read(service: vaultService, account: id.uuidString) else {
            throw SwitchboardError.message("The saved login is missing from Keychain. Sign in and save this account again.")
        }
        let snapshot = try decoder.decode(CredentialSnapshot.self, from: data)
        _ = try snapshot.validated()
        return snapshot
    }
    public func state() throws -> SwitchboardState {
        try recoverInterruptedSwitch()
        let accounts = try accounts()
        let current = try live.snapshot()?.validated().0
        return SwitchboardState(accounts: accounts, current: current, activeID: accounts.first {
            $0.accountUUID == current?.accountUUID && $0.organizationUUID == current?.organizationUUID
        }?.id)
    }

    @discardableResult
    public func capture(_ snapshot: CredentialSnapshot, label: String = "") throws -> SavedAccount {
        let (identity, _) = try snapshot.validated()
        var accounts = try accounts()
        let index = accounts.firstIndex { $0.accountUUID == identity.accountUUID && $0.organizationUUID == identity.organizationUUID }
        var account = index.map { accounts[$0] } ?? SavedAccount(label: identity.email, email: identity.email,
            accountUUID: identity.accountUUID, organizationUUID: identity.organizationUUID, plan: identity.plan)
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { account.label = String(trimmed.prefix(80)) }
        account.email = identity.email; account.plan = identity.plan
        let previous = try secrets.read(service: vaultService, account: account.id.uuidString)
        try secrets.write(encoder.encode(snapshot), service: vaultService, account: account.id.uuidString)
        if let index { accounts[index] = account } else { accounts.append(account) }
        do { try save(accounts) }
        catch {
            if let previous { try? secrets.write(previous, service: vaultService, account: account.id.uuidString) }
            else { try? secrets.delete(service: vaultService, account: account.id.uuidString) }
            throw error
        }
        return account
    }

    public func captureCurrent(label: String) throws {
        guard let current = try live.snapshot() else {
            throw SwitchboardError.message("No Claude subscription login was found. Choose Sign in another account.")
        }
        try capture(current, label: label)
    }

    public func activate(_ id: UUID) throws {
        try recoverInterruptedSwitch()
        // Re-read after lock acquisition: the CLI may have rotated its token since the UI loaded.
        if let current = try live.snapshot() { try capture(current) }
        let target = try credential(for: id)
        guard try accounts().contains(where: { $0.id == id }) else {
            throw SwitchboardError.message("This account is no longer saved.")
        }
        // Persist the previous login before touching Claude's files. It also survives a power loss.
        let current = try live.snapshot()
        if let current {
            try secrets.write(encoder.encode(current), service: vaultService, account: "previous-login")
        }
        let journal = PendingSwitch(before: current, target: target)
        try secrets.write(encoder.encode(journal), service: vaultService, account: "pending-switch")
        // Retain recovery data on every failure, including failed rollback without a prior login.
        try live.apply(target)
        // A leftover journal after a successful switch is harmless and cleared on the next read.
        try? secrets.delete(service: vaultService, account: "pending-switch")
    }

    private struct PendingSwitch: Codable {
        var before: CredentialSnapshot?
        var target: CredentialSnapshot
    }

    public func recoverInterruptedSwitch() throws {
        guard let data = try secrets.read(service: vaultService, account: "pending-switch") else { return }
        let journal = try decoder.decode(PendingSwitch.self, from: data)
        let credentials = try live.credentialState().data
        let oauth = try credentials.map(jsonObject)?["claudeAiOauth"].map(jsonData)
        if oauth == journal.target.oauth {
            try live.apply(journal.target)
        } else if let before = journal.before, oauth == before.oauth {
            try live.apply(before)
        } else if oauth == nil, journal.before == nil {
            // The app stopped before its first credential write. Nothing needs restoring.
        } else {
            throw SwitchboardError.message("A switch was interrupted and Claude's login changed afterward. Your saved accounts are intact. Quit Claude Code and reopen Switchboard; if this persists, restore the previous-login Keychain snapshot before switching.")
        }
        try secrets.delete(service: vaultService, account: "pending-switch")
    }

    public func rename(_ id: UUID, label: String) throws {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { throw SwitchboardError.message("Enter an account name.") }
        var accounts = try accounts()
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].label = String(label.prefix(80))
        try save(accounts)
    }

    public func setRenewal(_ id: UUID, date: Date?) throws {
        var accounts = try accounts()
        guard let index = accounts.firstIndex(where: { $0.id == id }) else {
            throw SwitchboardError.message("This account is no longer saved.")
        }
        accounts[index].renewalAt = date
        try save(accounts)
    }

    public func setClaudeBilling(_ id: UUID, billing: ClaudeBillingSnapshot) throws {
        var accounts = try accounts()
        guard let index = accounts.firstIndex(where: { $0.id == id }) else {
            throw SwitchboardError.message("This account is no longer saved.")
        }
        var updated = billing
        if updated.resetReadFailed == true, updated.resetSnapshot == nil {
            updated.resetSnapshot = accounts[index].claudeBilling?.resetSnapshot
        }
        accounts[index].claudeBilling = updated
        try save(accounts)
    }

    public func remove(_ id: UUID) throws {
        // Removing a saved entry never logs out or revokes the active CLI login.
        let existing = try accounts()
        let previous = try secrets.read(service: vaultService, account: id.uuidString)
        try secrets.delete(service: vaultService, account: id.uuidString)
        do { try save(existing.filter { $0.id != id }) }
        catch {
            if let previous { try? secrets.write(previous, service: vaultService, account: id.uuidString) }
            throw error
        }
        let profile = usageInstallation(id)
        try? secrets.delete(service: profile.keychainService, account: profile.keychainAccount)
        try? FileManager.default.removeItem(at: profile.configDirectory)
    }

    public func updateUsage(_ id: UUID, usage: UsageSnapshot) throws {
        var accounts = try accounts()
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        var updated = usage
        if updated.claudeResetReadFailed == true, updated.claudeResetSnapshot == nil {
            updated.claudeResetSnapshot = accounts[index].usage?.claudeResetSnapshot
        }
        accounts[index].usage = updated
        try save(accounts)
    }

    public func usageInstallation(_ id: UUID) -> ClaudeInstallation {
        .isolated(at: directory.appendingPathComponent("profiles/\(id.uuidString)", isDirectory: true))
    }

    public func prepareUsage(_ id: UUID) throws -> ClaudeInstallation {
        let state = try state()
        if state.activeID == id {
            if let current = try live.snapshot() { try capture(current) }
            // snapshot() already checked the active store. Do not reread Keychain
            // just to grant access: the helper read never changed access permissions.
            return live.installation
        }
        let installation = usageInstallation(id)
        try ClaudeLoginStore(installation: installation, secrets: secrets).apply(credential(for: id))
        return installation
    }

    public func collectUsageCredentials(_ id: UUID, from installation: ClaudeInstallation) throws {
        guard let snapshot = try ClaudeLoginStore(installation: installation, secrets: secrets).snapshot() else { return }
        let identity = try snapshot.validated().0
        guard let account = try accounts().first(where: { $0.id == id }),
              identity.accountUUID == account.accountUUID, identity.organizationUUID == account.organizationUUID else {
            throw SwitchboardError.message("The CLI login changed during the usage check. Refresh again.")
        }
        try capture(snapshot)
    }
}
