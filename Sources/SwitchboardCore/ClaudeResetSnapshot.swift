import Foundation

/// Read-only reset grants from Claude's account-scoped usage response.
public struct ClaudeResetSnapshot: Codable, Equatable, Sendable {
    public var checkedAt: Date
    public var eligible: Bool
    public var grants: [Grant]

    public struct Grant: Codable, Identifiable, Equatable, Sendable {
        public var id: String
        public var resetsLeft: Int
        public var clears: [String]
        public var startsAt: Date?
        public var expiresAt: Date?
        public var paused: Bool
        public var usableNow: Bool

        public var title: String {
            let session = clears.contains("five_hour")
            let weekly = clears.contains { $0.hasPrefix("seven_day") }
            if session && weekly { return "Full reset" }
            if session && clears.allSatisfy({ $0 == "five_hour" }) { return "5-hour reset" }
            if weekly && !session { return "Weekly reset" }
            return "Other reset"
        }

        public func isAvailable(at now: Date) -> Bool {
            resetsLeft > 0 && !paused && (expiresAt == nil || expiresAt! > now) && (startsAt == nil || startsAt! <= now)
        }
    }

    public static func parse(_ object: [String: Any], checkedAt: Date = Date()) throws -> Self {
        let failure = SwitchboardError.message("Claude reset details are unavailable. Refresh usage again.")
        guard let eligible = object["eligible"] as? Bool,
              CFGetTypeID(object["eligible"] as CFTypeRef) == CFBooleanGetTypeID(),
              let rows = object["grants"] as? [[String: Any]], rows.count <= 100 else { throw failure }
        var seen = Set<String>()
        let grants = try rows.map { row -> Grant in
            guard let id = row["id"] as? String, !id.isEmpty, id.utf8.count <= 128,
                  seen.insert(id).inserted,
                  let left = row["resets_left"] as? NSNumber,
                  CFGetTypeID(left) != CFBooleanGetTypeID(), left.doubleValue.isFinite,
                  left.doubleValue >= 0, left.doubleValue <= 10_000,
                  left.doubleValue.rounded() == left.doubleValue,
                  let clears = row["clears"] as? [String], !clears.isEmpty, clears.count <= 32,
                  clears.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }),
                  let paused = (row["paused"] ?? false) as? Bool,
                  CFGetTypeID((row["paused"] ?? false) as CFTypeRef) == CFBooleanGetTypeID(),
                  let usable = (row["usable_now"] ?? false) as? Bool,
                  CFGetTypeID((row["usable_now"] ?? false) as CFTypeRef) == CFBooleanGetTypeID() else { throw failure }
            let expiry = timestamp(row["ends_at"])
            if let value = row["ends_at"], !(value is NSNull), expiry == nil { throw failure }
            let start = timestamp(row["starts_at"])
            if let value = row["starts_at"], !(value is NSNull), start == nil { throw failure }
            return Grant(id: id, resetsLeft: left.intValue, clears: clears, startsAt: start,
                         expiresAt: expiry, paused: paused, usableNow: usable)
        }
        return Self(checkedAt: checkedAt, eligible: eligible, grants: grants)
    }

    private static func timestamp(_ value: Any?) -> Date? {
        guard let text = value as? String,
              text.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T(?:[01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](?:\.[0-9]+)?(?:Z|[+-](?:[01][0-9]|2[0-3]):[0-5][0-9])$"#,
                         options: .regularExpression) != nil else { return nil }
        return SubscriptionDateParser.parse(text)
    }
}
