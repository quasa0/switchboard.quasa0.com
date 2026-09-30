import Foundation
import SwitchboardCore

actor CodexAccountEngine: SubscriptionEngine {
    private let repository: CodexAccountRepository
    private var login: CodexLoginSession?
    private var refreshing = false

    init() {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Switchboard/codex")
        repository = CodexAccountRepository(directory: directory, secrets: KeychainStore(), installation: CodexInstallation())
    }

    func state() throws -> SwitchboardState { try repository.withLock { try repository.state() } }
    func savedAccounts() throws -> [SavedAccount] { try repository.withLock { try repository.accounts() } }
    func saveCurrent(label: String) throws { try repository.withLock { try repository.captureCurrent(label: label) } }
    func activate(_ id: UUID) throws {
        guard !refreshing else { throw SwitchboardError.message("Wait for the usage check to finish, then switch accounts.") }
        try repository.withLock { try repository.activate(id) }
    }
    func rename(_ id: UUID, label: String) throws { try repository.withLock { try repository.rename(id, label: label) } }
    func setRenewal(_ id: UUID, date: Date?) throws { try repository.withLock { try repository.setRenewal(id, date: date) } }
    func remove(_ id: UUID) throws { try repository.withLock { try repository.remove(id) } }

    func usage(_ id: UUID) async throws {
        refreshing = true
        defer { refreshing = false }
        let executable = try CodexExecutable.find()
        try await CodexUsageRecovery.fetch(id, repository: repository) { installation in
            try await CodexUsageClient(executable: executable).fetch(installation: installation)
        }
    }

    func beginLogin() throws {
        guard login == nil else { return }
        let directory = repository.directory.appendingPathComponent("login/\(UUID().uuidString)")
        let session = try CodexLoginSession(directory: directory, executable: CodexExecutable.find())
        do { try session.start(); login = session }
        catch { session.stop(); try? FileManager.default.removeItem(at: directory); throw error }
    }
    func submitLoginCode(_ code: String) throws {
        throw SwitchboardError.message("Complete the Codex sign-in in your browser, then save the new login.")
    }
    func finishLogin(label: String) throws {
        guard let login else { throw SwitchboardError.message("Start a new sign-in first.") }
        try login.checkFinished()
        guard let snapshot = try CodexLoginStore(installation: login.installation).snapshot() else {
            throw SwitchboardError.message("Codex has not saved a ChatGPT login yet.")
        }
        try repository.withLock { _ = try repository.capture(snapshot, label: label) }
        try cancelLogin()
    }
    func cancelLogin() throws {
        guard let login else { return }
        login.stop()
        try FileManager.default.removeItem(at: login.installation.home)
        self.login = nil
    }
    func shutdown() { try? cancelLogin() }
}
