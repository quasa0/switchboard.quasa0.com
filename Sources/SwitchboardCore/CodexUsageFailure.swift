import Foundation

/// Classifies the CLI's errors without displaying URLs, response bodies, or credentials.
struct CodexUsageFailure: Decodable {
    let code: Int?
    private let message: String?

    var isAuthenticationFailure: Bool {
        guard let text = message?.lowercased() else { return false }
        // CLI-owned OAuth errors. Do not treat protocol, permission, or network errors as logout.
        return text.contains("refresh token has already been used")
            || text.contains("refresh token has been revoked")
            || text.contains("refresh token was revoked")
            || text.contains("refresh token was already used")
            || text.contains("refresh token has expired")
            || text.contains("refresh_token_reused") || text.contains("refresh_token_invalidated")
            || text.contains("refresh_token_expired")
            || text.contains("your access token could not be refreshed. please log out and sign in again.")
            || text.contains("you have since logged out or signed in to another account")
    }

    var httpStatus: Int? {
        guard let message else { return nil }
        // account/read can reject auth during workspace discovery before the
        // rate-limit endpoint runs. This is a fixed CLI error, not a raw body.
        if message == "workspace routing discovery unauthorized (401)" { return 401 }
        // Match the backend client's status header only, never numbers in its URL/body.
        let pattern = #"^failed to fetch codex rate limits: (?:GET|POST) https://[^\s]+ failed: ([1-5][0-9]{2})(?:\s|;)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
              let range = Range(match.range(at: 1), in: message) else { return nil }
        return Int(message[range])
    }

    func displayError(stage: String) -> SwitchboardError {
        switch httpStatus {
        case 401:
            return .message("Codex's usage service rejected this login (HTTP 401). Sign in to this account again, then refresh.")
        case 403:
            return .message("Codex's usage service denied access (HTTP 403). Check this workspace's Codex access in the CLI, then refresh.")
        case 429:
            return .message("Codex's usage service is rate limiting requests (HTTP 429). Wait before refreshing again.")
        case .some(500...599):
            return .message("Codex's usage service is unavailable (HTTP \(httpStatus!)). Refresh later.")
        case .some(let status):
            return .message("Codex's usage service returned HTTP \(status). Check Codex in Terminal, then refresh.")
        case nil: break
        }
        if stage == "account/read", let message {
            switch message {
            case "workspace routing discovery failed":
                return .message("Codex could not reach this account's workspace service. Refresh again. Signing out will not fix a network or service failure.")
            case "workspace routing discovery timed out":
                return .message("Codex's workspace check timed out. Refresh again.")
            case "selected workspace missing from routing discovery":
                return .message("Codex could not find this login's selected workspace. Sign in to this account through Switchboard, then refresh.")
            case "account changed during workspace routing discovery":
                return .message("Codex's login changed during its workspace check. The saved login was preserved. Refresh again.")
            case "failed to load workspace requirements", "failed to reload workspace requirements",
                 "configuration changed during workspace routing discovery; retry account/read":
                return .message("Codex could not load stable workspace settings. Refresh again; if this persists, check the Codex configuration.")
            default: break
            }
        }
        if code == -32601 || code == -32602 {
            return .message("This Codex version rejected \(stage) (RPC \(code!)). Update Codex, then refresh.")
        }
        let detail = code.map { " (RPC \($0))" } ?? ""
        return .message("Codex failed during \(stage)\(detail). Check Codex in Terminal, then refresh. No usage data was returned.")
    }
}
