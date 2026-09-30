import Foundation

public extension SubscriptionProvider {
    /// Formats provider plan names; only verified Claude tiers carry a multiplier.
    /// Accepts provider identifiers and display labels so cached metadata needs no credential refresh.
    func planLabel(_ rawPlan: String) -> String {
        let trimmed = rawPlan.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = trimmed.lowercased().replacingOccurrences(of: "×", with: "x")
            .filter { $0.isLetter || $0.isNumber }
        switch self {
        case .claude:
            // Anthropic defines Max tiers relative to Pro's per-session allowance.
            // https://support.claude.com/en/articles/11049741-what-is-the-max-plan
            switch key {
            case "pro", "pro1x": return "Pro · 1×"
            case "max5x", "defaultclaudemax5x": return "Max · 5×"
            case "max20x", "defaultclaudemax20x": return "Max · 20×"
            default: break
            }
        case .chatGPT:
            // Plan identifiers do not establish a current allowance multiplier.
            // https://learn.chatgpt.com/docs/pricing
            switch key {
            case "plus": return "Plus"
            case "prolite": return "Pro Lite"
            case "pro": return "Pro"
            // TEMP-COMPAT 2026-09-30: normalize inferred tier labels saved by Switchboard <= 0.5.2;
            // these account files store formatted labels rather than provider IDs. Remove after a
            // metadata schema migration requires raw provider IDs for every saved account. Delete
            // these plus1x/pro5x/pro10x/pro20x cases and the cached-label regression below.
            case "plus1x": return "Plus"
            case "pro5x": return "Pro Lite"
            case "pro10x", "pro20x": return "Pro"
            case "chatgpt": return "ChatGPT"
            default: break
            }
        }
        guard !trimmed.isEmpty else { return displayName }
        // Unknown enterprise/custom plans retain their name without an inferred allowance.
        return trimmed.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ").capitalized
    }
}

public struct SavedAccount: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var label: String
    public var email: String
    public var accountUUID: String
    public var organizationUUID: String
    public var plan: String
    public var addedAt: Date
    public var lastUsedAt: Date?
    public var usage: UsageSnapshot?
    /// A renewal date entered by the user. Never inferred from token expiry or usage resets.
    public var renewalAt: Date?
    /// Automatic provider metadata. A manual renewalAt remains an explicit display override.
    public var subscriptionPeriod: SubscriptionPeriod?
    /// Billing metadata from this account's separate Claude web session.
    public var claudeBilling: ClaudeBillingSnapshot?

    public init(id: UUID = UUID(), label: String, email: String, accountUUID: String,
                organizationUUID: String, plan: String, addedAt: Date = Date(),
                lastUsedAt: Date? = nil, usage: UsageSnapshot? = nil, renewalAt: Date? = nil,
                subscriptionPeriod: SubscriptionPeriod? = nil, claudeBilling: ClaudeBillingSnapshot? = nil) {
        self.id = id; self.label = label; self.email = email
        self.accountUUID = accountUUID; self.organizationUUID = organizationUUID
        self.plan = plan; self.addedAt = addedAt; self.lastUsedAt = lastUsedAt; self.usage = usage
        self.renewalAt = renewalAt
        self.subscriptionPeriod = subscriptionPeriod
        self.claudeBilling = claudeBilling
    }
    public var initials: String {
        let words = label.split(separator: " ")
        return String(words.prefix(2).compactMap(\.first)).uppercased()
    }
}

public struct UsageWindow: Codable, Equatable, Sendable {
    public var utilization: Double
    public var resetsAt: Date?
    public init(utilization: Double, resetsAt: Date?) {
        self.utilization = utilization; self.resetsAt = resetsAt
    }
    public var fraction: Double { min(1, max(0, utilization / 100)) }
}

public struct UsageSnapshot: Codable, Equatable, Sendable {
    public var fiveHour: UsageWindow?
    public var sevenDay: UsageWindow?
    public var sevenDaySonnet: UsageWindow?
    public var sevenDayOpus: UsageWindow?
    public var fetchedAt: Date
    public var modelScoped: [NamedUsageWindow]
    /// Provider-reported manual reset credits. Nil means the provider did not report them.
    public var manualResets: ManualResetSummary?
    /// Credit balances retain their bucket identity. Nil means no credit data was reported.
    public var creditBalances: [UsageCreditBalance]?
    public var reportedPlan: String?
    public var claudeResetSnapshot: ClaudeResetSnapshot?
    public var claudeResetReadFailed: Bool?
    public init(fiveHour: UsageWindow? = nil, sevenDay: UsageWindow? = nil,
                sevenDaySonnet: UsageWindow? = nil, sevenDayOpus: UsageWindow? = nil,
                fetchedAt: Date = Date(), modelScoped: [NamedUsageWindow] = [],
                manualResets: ManualResetSummary? = nil, creditBalances: [UsageCreditBalance]? = nil,
                reportedPlan: String? = nil, claudeResetSnapshot: ClaudeResetSnapshot? = nil,
                claudeResetReadFailed: Bool? = nil) {
        self.fiveHour = fiveHour; self.sevenDay = sevenDay
        self.sevenDaySonnet = sevenDaySonnet; self.sevenDayOpus = sevenDayOpus
        self.fetchedAt = fetchedAt
        self.modelScoped = modelScoped
        self.manualResets = manualResets
        self.creditBalances = creditBalances
        self.reportedPlan = reportedPlan
        self.claudeResetSnapshot = claudeResetSnapshot
        self.claudeResetReadFailed = claudeResetReadFailed
    }
}

public struct UsageCreditBalance: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var hasCredits: Bool
    public var unlimited: Bool
    /// Provider decimal string, not a currency amount or an inferred grant.
    public var balance: String?
    public init(id: String, name: String, hasCredits: Bool, unlimited: Bool, balance: String?) {
        self.id = id; self.name = name; self.hasCredits = hasCredits
        self.unlimited = unlimited; self.balance = balance
    }
}

public struct ManualResetSummary: Codable, Equatable, Sendable {
    /// Authoritative provider count. The detail list can contain fewer rows.
    public var availableCount: Int
    /// Nil means details are unavailable; an empty array is an explicitly empty result.
    public var credits: [ManualResetCredit]?
    public init(availableCount: Int, credits: [ManualResetCredit]? = nil) {
        self.availableCount = availableCount; self.credits = credits
    }
}

public struct ManualResetCredit: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var resetType: String
    /// Preserve provider state, including future states, without inferring availability.
    public var status: String
    public var grantedAt: Date
    /// Nil means this reported credit has no expiry.
    public var expiresAt: Date?
    public var title: String?
    public var detail: String?
    public init(id: String, resetType: String, status: String, grantedAt: Date,
                expiresAt: Date?, title: String? = nil, detail: String? = nil) {
        self.id = id; self.resetType = resetType; self.status = status
        self.grantedAt = grantedAt; self.expiresAt = expiresAt
        self.title = title; self.detail = detail
    }
}

public struct NamedUsageWindow: Codable, Equatable, Sendable {
    public var name: String
    public var window: UsageWindow
    public init(name: String, window: UsageWindow) { self.name = name; self.window = window }
}

public struct CurrentLogin: Equatable, Sendable {
    public var email: String
    public var accountUUID: String
    public var organizationUUID: String
    public var plan: String
    public var subscriptionPeriod: SubscriptionPeriod?
    public init(email: String, accountUUID: String, organizationUUID: String, plan: String,
                subscriptionPeriod: SubscriptionPeriod? = nil) {
        self.email = email; self.accountUUID = accountUUID
        self.organizationUUID = organizationUUID; self.plan = plan
        self.subscriptionPeriod = subscriptionPeriod
    }
}

public struct SwitchboardState: Sendable {
    public var accounts: [SavedAccount]
    public var current: CurrentLogin?
    public var activeID: UUID?
}

public enum SwitchboardError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case let .message(message) = self { return message }; return nil }
}

public struct CredentialSnapshot: Codable, Equatable, Sendable {
    public var oauth: Data
    public var identity: Data
    public init(oauth: Data, identity: Data) { self.oauth = oauth; self.identity = identity }

    public func validated() throws -> (CurrentLogin, OAuthCredential) {
        let token = try JSONDecoder().decode(OAuthCredential.self, from: oauth)
        let account = try JSONDecoder().decode(ClaudeIdentity.self, from: identity)
        guard !token.accessToken.isEmpty, !account.accountUuid.isEmpty, !account.emailAddress.isEmpty,
              token.scopes.contains("user:inference") else {
            throw SwitchboardError.message("This is not a Claude subscription login. Run claude auth login --claudeai first.")
        }
        let rawPlan: String
        if token.rateLimitTier == "default_claude_max_20x" { rawPlan = "Max 20×" }
        else if token.rateLimitTier == "default_claude_max_5x" { rawPlan = "Max 5×" }
        else { rawPlan = token.subscriptionType ?? "Claude" }
        let plan = SubscriptionProvider.claude.planLabel(rawPlan)
        return (CurrentLogin(email: account.emailAddress, accountUUID: account.accountUuid,
                             organizationUUID: account.organizationUuid ?? "", plan: plan), token)
    }
}

public struct OAuthCredential: Codable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Double?
    public var scopes: [String]
    public var subscriptionType: String?
    public var rateLimitTier: String?
    public var needsRefresh: Bool { (expiresAt ?? 0) / 1000 < Date().timeIntervalSince1970 + 60 }
}

private struct ClaudeIdentity: Decodable {
    var accountUuid: String
    var emailAddress: String
    var organizationUuid: String?
}
