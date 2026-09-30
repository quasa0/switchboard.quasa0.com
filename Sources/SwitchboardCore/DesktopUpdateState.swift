import Foundation

/// The desktop flow used by T3 Code: check → offer → download → confirmed restart.
public struct DesktopUpdateState: Equatable, Sendable {
    public enum Status: String, Sendable { case disabled, idle, checking, available, downloading, ready, installing, error }
    public var status: Status = .disabled
    public var version: String?
    public var progress: Double?
    public var message: String?
    public var checkedAt: Date?
    public init(status: Status = .disabled) { self.status = status }

    public mutating func found(_ version: String) {
        guard status != .ready && status != .installing && status != .downloading else { return }
        self.version = version; status = .available; message = nil; progress = nil
    }
    public mutating func checkFinished(error: Bool, at date: Date = Date()) {
        checkedAt = date
        // A failed later check must not erase an already verified download.
        guard status != .ready && status != .installing && status != .downloading else { return }
        if error { status = .error; message = "Could not check for updates. Try again." }
        else { status = .idle; version = nil; message = nil }
    }
    public mutating func received(_ percent: Double) {
        guard status == .downloading, percent.isFinite else { return }
        progress = min(100, max(0, percent))
    }
}
