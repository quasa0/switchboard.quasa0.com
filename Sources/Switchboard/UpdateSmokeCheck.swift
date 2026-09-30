import AppKit
import SwitchboardCore

/// A bundled, loopback-only updater fixture. It cannot construct account engines.
@MainActor enum UpdateSmokeCheck {
    nonisolated static var fixtureMarker: URL? {
        guard Bundle.main.bundleIdentifier?.hasPrefix("com.quasa0.switchboard.update-test.") == true,
              let path = Bundle.main.object(forInfoDictionaryKey: "SwitchboardUpdateTestMarker") as? String else { return nil }
        return URL(fileURLWithPath: path)
    }

    static func run(model: DashboardModel, arguments: [String]) async throws {
        guard model.isCredentialFreePreview, fixtureMarker != nil,
              let index = arguments.firstIndex(of: "--update-smoke"), arguments.count > index + 3,
              let feed = URL(string: arguments[index + 1]), feed.scheme == "http", feed.host == "127.0.0.1" else {
            throw UIVerificationError(message: "Updater smoke requires an isolated demo bundle and loopback feed.")
        }
        let output = URL(fileURLWithPath: arguments[index + 2])
        let mode = arguments[index + 3]
        let updates = model.updates
        var transitions: [String] = []
        updates.onStateChange = { state in
            if transitions.last != state.status.rawValue { transitions.append(state.status.rawValue) }
        }
        updates.start(testFeed: feed)
        try await wait { updates.canCheck }
        updates.check()
        try await wait { updates.state.status != .checking }
        if ["no-update", "unsupported-os", "check-error", "unsigned-feed"].contains(mode) {
            let expected: DesktopUpdateState.Status = ["no-update", "unsupported-os"].contains(mode) ? .idle : .error
            guard updates.state.status == expected else { throw UIVerificationError(message: "Unexpected check result") }
        } else {
            try await wait { updates.canDownload }
            updates.download()
            try await wait { updates.state.status == .ready || updates.state.message != nil }
            if mode == "invalid-signature" {
                guard updates.state.status != .ready, updates.state.message != nil else {
                    throw UIVerificationError(message: "An invalid update became installable")
                }
            } else {
                guard updates.canInstall else { throw UIVerificationError(message: "Update did not become ready") }
            }
        }
        let report: [String: Any] = ["mode": mode, "credentialAccess": false, "status": updates.state.status.rawValue,
                                   "transitions": transitions, "version": updates.state.version ?? ""]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output)
        if ["install", "development-install"].contains(mode) { updates.install() }
        else { NSApp.terminate(nil) }
    }

    private static func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw UIVerificationError(message: "Updater fixture timed out") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
