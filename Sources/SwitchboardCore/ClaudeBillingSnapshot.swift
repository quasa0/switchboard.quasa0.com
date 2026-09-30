import Foundation

/// Display metadata from Claude's authenticated subscription-details response.
/// Date-only values retain their calendar meaning instead of acquiring an invented local time.
public struct ClaudeBillingSnapshot: Codable, Equatable, Sendable {
    public var checkedAt: Date
    public var status: String?
    public var nextChargeAt: Date?
    public var nextChargeDate: String?
    public var planEndingAt: Date?
    /// The provider's `plan_ending_before` calendar date.
    public var planEndingDate: String?
    /// Gift coverage includes this complete UTC calendar day.
    public var giftPaidThrough: String?
    public var paymentPausedUntil: Date?
    public var resetSnapshot: ClaudeResetSnapshot?
    public var resetReadFailed: Bool?

    public init(checkedAt: Date = Date(), status: String? = nil, nextChargeAt: Date? = nil,
                nextChargeDate: String? = nil, planEndingAt: Date? = nil,
                planEndingDate: String? = nil, giftPaidThrough: String? = nil,
                paymentPausedUntil: Date? = nil, resetSnapshot: ClaudeResetSnapshot? = nil,
                resetReadFailed: Bool? = nil) {
        self.checkedAt = checkedAt
        self.status = status
        self.nextChargeAt = nextChargeAt
        self.nextChargeDate = nextChargeDate
        self.planEndingAt = planEndingAt
        self.planEndingDate = planEndingDate
        self.giftPaidThrough = giftPaidThrough
        self.paymentPausedUntil = paymentPausedUntil
        self.resetSnapshot = resetSnapshot
        self.resetReadFailed = resetReadFailed
    }

    /// Validates the web-to-native identity boundary before reading any billing fields.
    /// The bridge must return only its verified account, organization, and subscription details.
    public static func parseBridge(_ data: Data, expectedAccountUUID: String,
                                   expectedOrganizationUUID: String,
                                   checkedAt: Date = Date()) throws -> ClaudeBillingSnapshot {
        guard data.count <= 1_048_576,
              !expectedAccountUUID.isEmpty, !expectedOrganizationUUID.isEmpty,
              expectedAccountUUID == expectedAccountUUID.trimmingCharacters(in: .whitespacesAndNewlines),
              expectedOrganizationUUID == expectedOrganizationUUID.trimmingCharacters(in: .whitespacesAndNewlines),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              Set(["accountUUID", "organizationUUID", "details"]).isSubset(of: Set(object.keys)),
              Set(object.keys).isSubset(of: Set(["accountUUID", "organizationUUID", "details", "resetDetails"])),
              let accountUUID = object["accountUUID"] as? String,
              let organizationUUID = object["organizationUUID"] as? String else { throw invalidResponse }
        guard accountUUID == expectedAccountUUID, organizationUUID == expectedOrganizationUUID else {
            throw SwitchboardError.message("This billing connection belongs to a different Claude account or organization. Sign in with the saved account.")
        }
        guard let details = object["details"] as? [String: Any],
              let detailsData = try? JSONSerialization.data(withJSONObject: details) else { throw invalidResponse }
        var snapshot = try parse(detailsData, checkedAt: checkedAt)
        if let raw = object["resetDetails"] {
            if let resets = raw as? [String: Any],
               let parsed = try? ClaudeResetSnapshot.parse(resets, checkedAt: checkedAt) {
                snapshot.resetSnapshot = parsed
                snapshot.resetReadFailed = false
            } else { snapshot.resetReadFailed = true }
        }
        return snapshot
    }

    /// Reads the first-party `/api/organizations/{uuid}/subscription_details` object.
    /// Payment methods, invoice URLs, customer identifiers, and other fields are never retained.
    public static func parse(_ data: Data, checkedAt: Date = Date()) throws -> ClaudeBillingSnapshot {
        do {
            guard data.count <= 1_048_576,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["error"] == nil || object["error"] is NSNull,
                  object["type"] as? String != "error" else { throw invalidResponse }
            let knownKeys: Set<String> = ["status", "next_charge_at", "next_charge_date", "plan_ending_at",
                                          "plan_ending_before", "gift_details", "payment_paused_until"]
            guard !knownKeys.isDisjoint(with: object.keys) else { throw invalidResponse }

            let status = try string("status", in: object)
            if let status {
                guard !status.isEmpty, status.utf8.count <= 128,
                      status == status.trimmingCharacters(in: .whitespacesAndNewlines) else {
                    throw invalidResponse
                }
            }
            var giftPaidThrough: String?
            if let gift = object["gift_details"], !(gift is NSNull) {
                guard let gift = gift as? [String: Any] else { throw invalidResponse }
                giftPaidThrough = try calendarDate("paid_through", in: gift)
            }
            var paymentPausedUntil: Date?
            if let raw = object["payment_paused_until"], !(raw is NSNull) {
                // Claude's billing UI passes this field to DateTime.fromSeconds().
                guard raw is NSNumber, let date = SubscriptionDateParser.parse(raw) else { throw invalidResponse }
                paymentPausedUntil = date
            }
            return ClaudeBillingSnapshot(checkedAt: checkedAt, status: status,
                nextChargeAt: try timestamp("next_charge_at", in: object),
                nextChargeDate: try calendarDate("next_charge_date", in: object),
                planEndingAt: try timestamp("plan_ending_at", in: object),
                planEndingDate: try calendarDate("plan_ending_before", in: object),
                giftPaidThrough: giftPaidThrough, paymentPausedUntil: paymentPausedUntil)
        } catch {
            // JSON/type errors can contain parts of the response. Keep billing data out of diagnostics.
            throw invalidResponse
        }
    }

    private static var invalidResponse: SwitchboardError {
        .message("Claude returned invalid billing details. Open the billing connection and try again.")
    }

    private static func string(_ key: String, in object: [String: Any]) throws -> String? {
        guard let value = object[key], !(value is NSNull) else { return nil }
        guard let string = value as? String else { throw invalidResponse }
        return string
    }

    private static func calendarDate(_ key: String, in object: [String: Any]) throws -> String? {
        guard let value = try string(key, in: object) else { return nil }
        guard validCalendarDate(value) else { throw invalidResponse }
        return value
    }

    private static func validCalendarDate(_ value: String) -> Bool {
        guard value.utf8.count == 10,
              value.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil else {
            return false
        }
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...9999).contains(parts[0]) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        guard let date = calendar.date(from: components) else { return false }
        let actual = calendar.dateComponents([.year, .month, .day], from: date)
        return actual.year == parts[0] && actual.month == parts[1] && actual.day == parts[2]
    }

    private static func timestamp(_ key: String, in object: [String: Any]) throws -> Date? {
        guard let value = try string(key, in: object) else { return nil }
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T(?:[01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](?:\.[0-9]+)?(?:Z|[+-](?:[01][0-9]|2[0-3]):[0-5][0-9])$"#,
                          options: .regularExpression) != nil,
              validCalendarDate(String(value.prefix(10))),
              let date = SubscriptionDateParser.parse(value) else { throw invalidResponse }
        return date
    }
}
