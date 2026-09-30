import Foundation
import Darwin

public struct CodexInstallation: Sendable, Equatable {
    /// The resolved CODEX_HOME, not the user's home directory.
    public let home: URL
    public let configurationEnvironment: [String: String]
    let checksSystemConfiguration: Bool
    public var authFile: URL { home.appendingPathComponent("auth.json") }
    public var configFile: URL { home.appendingPathComponent("config.toml") }

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        let custom = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 }
        self.home = (custom.map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex"))
            .standardizedFileURL.resolvingSymlinksInPath()
        configurationEnvironment = ["CODEX_HOME": self.home.path]
        checksSystemConfiguration = home.standardizedFileURL == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
    }

    private init(directory: URL) {
        home = directory.standardizedFileURL.resolvingSymlinksInPath()
        configurationEnvironment = ["CODEX_HOME": home.path, "HOME": home.appendingPathComponent("home").path]
        checksSystemConfiguration = false
    }

    public static func isolated(at directory: URL) -> CodexInstallation { .init(directory: directory) }

    /// File-only support deliberately avoids probing Codex's Keychain entry.
    public func requireFileStorage() throws {
        var files = [configFile]
        if checksSystemConfiguration {
            files += [URL(fileURLWithPath: "/etc/codex/config.toml"), URL(fileURLWithPath: "/etc/codex/requirements.toml")]
        }
        for file in files where FileManager.default.fileExists(atPath: file.path) {
            let data = try Data(contentsOf: file)
            guard data.count <= 1_048_576, let contents = String(data: data, encoding: .utf8) else {
                throw SwitchboardError.message("Codex's configuration could not be checked. No login was changed.")
            }
            // Only a plain, root-level file setting is safe to interpret without a TOML parser.
            // Unusual quoted/dotted/table forms fail closed rather than guessing the active backend.
            var atRoot = true
            for line in contents.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#") || trimmed.isEmpty { continue }
                if trimmed.hasPrefix("[") { atRoot = false }
                if let assignment = trimmed.firstIndex(of: "="), trimmed[..<assignment].contains("\\") {
                    throw SwitchboardError.message("Codex uses escaped configuration keys that Switchboard cannot safely interpret. No login was changed.")
                }
                if trimmed.contains("cli_auth_credentials_store") {
                    let plainFile = trimmed.range(of: #"^cli_auth_credentials_store\s*=\s*(?:"file"|'file')\s*(?:#.*)?$"#, options: .regularExpression) != nil
                    guard atRoot && plainFile else {
                        throw SwitchboardError.message("Switchboard currently supports Codex's file credential store. This configuration uses another or unrecognized store. Your Codex login and settings were not changed.")
                    }
                }
                if trimmed.contains("forced_login_method") || trimmed.contains("forced_chatgpt_workspace_id") {
                    throw SwitchboardError.message("This Codex configuration restricts login methods or workspaces. Switchboard cannot safely change its account.")
                }
            }
        }
    }
}

public struct CodexCredentialSnapshot: Codable, Equatable, Sendable {
    /// Preserve the complete official CLI payload, including future fields.
    public var authJSON: Data
    public init(authJSON: Data) { self.authJSON = authJSON }

    public func validated() throws -> CurrentLogin {
        let object = try payload()
        let mode = object["auth_mode"] as? String
        guard mode == nil || mode == "chatgpt",
              mode != nil || object["OPENAI_API_KEY"] == nil || object["OPENAI_API_KEY"] is NSNull,
              ["agent_identity", "personal_access_token", "bedrock_api_key", "bedrock_access_keys"].allSatisfy({ object[$0] == nil || object[$0] is NSNull }),
              let tokens = object["tokens"] as? [String: Any],
              let idToken = tokens["id_token"] as? String,
              let access = tokens["access_token"] as? String, !access.isEmpty,
              let refresh = tokens["refresh_token"] as? String, !refresh.isEmpty else { throw invalidLogin() }
        let parts = idToken.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty }) else { throw invalidLogin() }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auth = claims["https://api.openai.com/auth"] as? [String: Any],
              let email = (claims["email"] as? String) ?? ((claims["https://api.openai.com/profile"] as? [String: Any])?["email"] as? String), !email.isEmpty,
              let user = (auth["chatgpt_user_id"] as? String) ?? (auth["user_id"] as? String) ?? (claims["sub"] as? String), !user.isEmpty,
              let workspace = (tokens["account_id"] as? String) ?? (auth["chatgpt_account_id"] as? String), !workspace.isEmpty else { throw invalidLogin() }
        if let claimWorkspace = auth["chatgpt_account_id"] as? String, claimWorkspace != workspace { throw invalidLogin() }
        let rawPlan = auth["chatgpt_plan_type"] as? String ?? "ChatGPT"
        let plan = SubscriptionProvider.chatGPT.planLabel(rawPlan)
        let period = subscriptionPeriod(auth: auth, claims: claims, accountID: workspace)
        return CurrentLogin(email: email, accountUUID: user, organizationUUID: workspace, plan: plan,
                            subscriptionPeriod: period)
    }

    private func subscriptionPeriod(auth: [String: Any], claims: [String: Any], accountID: String) -> SubscriptionPeriod? {
        // The CLI preserves these ID-token claims even though account/read omits them.
        // https://github.com/router-for-me/CLIProxyAPI/blob/main/internal/auth/codex/jwt_parser.go
        guard auth["chatgpt_account_id"] as? String == accountID,
              let endsAt = SubscriptionDateParser.parse(auth["chatgpt_subscription_active_until"]) else { return nil }
        let startsAt = SubscriptionDateParser.parse(auth["chatgpt_subscription_active_start"])
        if let startsAt, startsAt > endsAt { return nil }
        // Codex can advance last_refresh while retaining an old ID token. Use its own observation time.
        let checkedAt = SubscriptionDateParser.parse(auth["chatgpt_subscription_last_checked"])
            ?? SubscriptionDateParser.parse(claims["iat"])
        return SubscriptionPeriod(startsAt: startsAt, endsAt: endsAt, checkedAt: checkedAt,
                                  source: .codexIDToken)
    }

    var refreshedAt: Date? {
        guard let object = try? payload(), let raw = object["last_refresh"] as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }

    private func payload() throws -> [String: Any] {
        guard authJSON.count <= 2_097_152,
              let object = try? JSONSerialization.jsonObject(with: authJSON) as? [String: Any] else { throw invalidLogin() }
        return object
    }
    private func invalidLogin() -> SwitchboardError {
        .message("This is not a reusable ChatGPT subscription login. Sign in with ChatGPT through Codex, then save the account.")
    }
}

public final class CodexLoginStore {
    public let installation: CodexInstallation
    public init(installation: CodexInstallation) { self.installation = installation }

    public func snapshot() throws -> CodexCredentialSnapshot? {
        try installation.requireFileStorage()
        var attributes = stat()
        if lstat(installation.authFile.path, &attributes) != 0 {
            if errno == ENOENT { return nil }
            throw SwitchboardError.message("Codex's login file could not be read. No login was changed.")
        }
        guard attributes.st_mode & S_IFMT == S_IFREG, attributes.st_size <= 2_097_152 else {
            throw SwitchboardError.message("Codex's auth.json must be a regular file. No login was changed.")
        }
        let result = CodexCredentialSnapshot(authJSON: try Data(contentsOf: installation.authFile))
        _ = try result.validated()
        return result
    }

    public func apply(_ target: CodexCredentialSnapshot) throws {
        try apply(target, ifUnchangedFrom: snapshot())
    }

    public func apply(_ target: CodexCredentialSnapshot, ifUnchangedFrom expected: CodexCredentialSnapshot?) throws {
        _ = try target.validated()
        guard try snapshot() == expected else {
            throw SwitchboardError.message("Codex updated its login during the switch. Nothing was replaced. Try switching again.")
        }
        try privateWrite(target.authJSON, to: installation.authFile)
    }

    /// Only app-owned usage profiles can repair malformed bytes. Live auth always fails closed.
    func applyUsageCopy(_ target: CodexCredentialSnapshot) throws {
        guard installation.configurationEnvironment["HOME"] != nil else {
            throw SwitchboardError.message("Cannot repair a shared Codex login through a usage profile.")
        }
        try installation.requireFileStorage()
        _ = try target.validated()
        var attributes = stat()
        if lstat(installation.authFile.path, &attributes) != 0 {
            guard errno == ENOENT else { throw SwitchboardError.message("Cannot read the saved usage profile.") }
            try apply(target)
            return
        }
        guard attributes.st_mode & S_IFMT == S_IFREG, attributes.st_size <= 2_097_152 else {
            throw SwitchboardError.message("The saved usage login must be a regular file. No login was changed.")
        }
        let before = try Data(contentsOf: installation.authFile)
        if (try? CodexCredentialSnapshot(authJSON: before).validated()) != nil {
            try apply(target, ifUnchangedFrom: CodexCredentialSnapshot(authJSON: before))
        } else {
            guard try Data(contentsOf: installation.authFile) == before else {
                throw SwitchboardError.message("The saved usage profile changed. Refresh again.")
            }
            try privateWrite(target.authJSON, to: installation.authFile)
        }
    }
}
