import Foundation

/// General quota comparison. Percentages are not comparable task budgets across plans.
public struct AccountReadiness: Equatable, Sendable {
    public enum Status: Sendable { case ready, limited, exhausted, stale, unknown }
    public let status: Status
    public let remaining: Double?
    public let limitingWindow: String?
    public let resetAt: Date?
    public let windowIDs: Set<String>

    public init(usage: UsageSnapshot?, failed: Bool = false, now: Date = Date()) {
        let windows: [(String, UsageWindow)] = [
            usage?.fiveHour.map { ("5h", $0) }, usage?.sevenDay.map { ("Weekly", $0) }
        ].compactMap { $0 }
        windowIDs = Set(windows.map(\.0))
        let tightest = windows.min { $0.1.fraction > $1.1.fraction }
        remaining = tightest.map { (1 - $0.1.fraction) * 100 }
        limitingWindow = tightest?.0
        resetAt = tightest?.1.resetsAt
        guard let usage else { status = .unknown; return }
        guard !failed, now.timeIntervalSince(usage.fetchedAt) <= 600,
              usage.fetchedAt.timeIntervalSince(now) <= 60,
              !windows.contains(where: { $0.1.resetsAt.map { $0 <= now } ?? false }) else {
            status = .stale; return
        }
        guard let remaining else { status = .unknown; return }
        status = remaining <= 0 ? .exhausted : remaining <= 10 ? .limited : .ready
    }

    public static func recommendation(accounts: [SavedAccount], failedIDs: Set<UUID> = [],
                                      now: Date = Date()) -> UUID? {
        let readings = accounts.map { ($0, AccountReadiness(usage: $0.usage, failed: failedIDs.contains($0.id), now: now)) }
        let candidates = readings.filter { $0.1.status == .ready || $0.1.status == .limited }
        // Different reported windows cannot support a fair single ranking.
        guard let basis = candidates.first?.1.windowIDs,
              candidates.allSatisfy({ $0.1.windowIDs == basis }) else { return nil }
        return candidates.sorted {
            if $0.1.remaining != $1.1.remaining { return $0.1.remaining! > $1.1.remaining! }
            let left = $0.1.resetAt ?? .distantFuture, right = $1.1.resetAt ?? .distantFuture
            if left != right { return left < right }
            return $0.0.id.uuidString < $1.0.id.uuidString
        }.first?.0.id
    }
}
