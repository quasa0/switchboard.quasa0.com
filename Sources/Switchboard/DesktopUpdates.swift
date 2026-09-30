import AppKit
import Combine
import Sparkle
import SwitchboardCore

/// T3's desktop update interaction, backed by Sparkle's signed native installer.
/// Account engines and credentials are never involved in update checks or downloads.
@MainActor final class DesktopUpdates: NSObject, ObservableObject, SPUUserDriver, SPUUpdaterDelegate {
    @Published private(set) var state = DesktopUpdateState()
    private var updater: SPUUpdater?
    private var pollTask: Task<Void, Never>?
    private var offerReply: ((SPUUserUpdateChoice) -> Void)?
    private var installReply: ((SPUUserUpdateChoice) -> Void)?
    private var cancelDownload: (() -> Void)?
    private var expectedBytes: UInt64 = 0
    private var receivedBytes: UInt64 = 0
    private var wantsDownload = false
    private var stopping = false
    private let demo: Bool
    private var testFeed: URL?
    private var availabilityObservation: NSKeyValueObservation?
    var onStateChange: ((DesktopUpdateState) -> Void)?

    init(demo: Bool) {
        self.demo = demo
        super.init()
    }

    var canCheck: Bool { !stopping && updater?.canCheckForUpdates == true && state.status != .downloading && state.status != .installing }
    var canDownload: Bool { !stopping && state.status == .available && (offerReply != nil || canCheck) }
    var canInstall: Bool { !stopping && state.status == .ready && installReply != nil }

    func start(testFeed: URL? = nil) {
        guard (!demo || testFeed != nil), !stopping, updater == nil, Bundle.main.bundleURL.pathExtension == "app" else { return }
        // Test feeds are accepted only by credential-free demo launches on loopback.
        if let testFeed { guard demo, testFeed.scheme == "http", testFeed.host == "127.0.0.1" else { return } }
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
        self.updater = updater
        self.testFeed = testFeed
        // The app owns scheduling and requires a download click on every build.
        updater.automaticallyChecksForUpdates = false
        updater.automaticallyDownloadsUpdates = false
        do { try updater.start() }
        catch { state.message = "Updates are unavailable in this build."; return }
        state.status = .idle
        availabilityObservation = updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.objectWillChange.send() }
        }
        if testFeed != nil { return }
        // Match T3's startup delay and polling cadence. Sparkle's own scheduler is disabled.
        pollTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            while !Task.isCancelled {
                guard let self, !self.stopping else { return }
                self.check()
                do { try await Task.sleep(for: .seconds(240)) } catch { return }
            }
        }
    }

    func check() {
        guard canCheck, state.status != .ready else { return }
        state.status = .checking; state.message = nil
        updater?.checkForUpdateInformation()
    }

    func download() {
        guard canDownload else { return }
        wantsDownload = true
        state.status = .downloading; state.progress = 0; state.message = nil
        if let reply = offerReply { offerReply = nil; reply(.install) }
        else { updater?.checkForUpdates() }
    }

    /// Called only after the app's restart confirmation, with no account operation active.
    func install() {
        guard canInstall, let reply = installReply else { return }
        installReply = nil
        state.status = .installing; state.message = nil
        reply(.install)
    }

    func stop() {
        stopping = true; pollTask?.cancel(); pollTask = nil
        cancelDownload?(); cancelDownload = nil
        if state.status != .installing {
            // Sparkle otherwise installs a prepared update on ordinary quit. T3 does not.
            installReply?(.skip); installReply = nil
            offerReply?(.dismiss); offerReply = nil
        }
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        if !wantsDownload { state.status = .checking }
    }
    func showUpdateFound(with appcastItem: SUAppcastItem, state update: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard !stopping, !appcastItem.isInformationOnlyUpdate else { reply(.dismiss); return }
        state.version = appcastItem.displayVersionString
        if wantsDownload { wantsDownload = false; reply(.install) }
        else { state.status = .available; offerReply = reply }
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        state.checkFinished(error: false); wantsDownload = false; acknowledgement(); publish()
    }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        state.status = state.version == nil ? .error : .available
        state.message = "The update could not finish. Try again."
        state.progress = nil; wantsDownload = false
        acknowledgement(); publish()
    }
    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        state.status = .downloading; state.progress = 0
        expectedBytes = 0; receivedBytes = 0; cancelDownload = cancellation; publish()
    }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) { expectedBytes = expectedContentLength }
    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedBytes += length
        if expectedBytes > 0 { state.received(Double(receivedBytes) / Double(expectedBytes) * 100) }
    }
    func showDownloadDidStartExtractingUpdate() { cancelDownload = nil; state.progress = 100 }
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard !stopping else { reply(.skip); return }
        state.status = .ready; state.progress = 100; installReply = reply; publish()
    }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        state.status = .installing; publish()
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func dismissUpdateInstallation() { offerReply = nil; installReply = nil; cancelDownload = nil; wantsDownload = false }
    func showUpdateInFocus() { NSApp.activate(ignoringOtherApps: true) }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        guard !item.isInformationOnlyUpdate else { state.checkFinished(error: false); publish(); return }
        if !wantsDownload { state.found(item.displayVersionString) }
        state.checkedAt = Date(); publish()
    }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) { state.checkFinished(error: false); publish() }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        if state.status == .checking { state.checkFinished(error: true); publish() }
    }
    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? { [] }
    func feedURLString(for updater: SPUUpdater) -> String? { testFeed?.absoluteString }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        objectWillChange.send()
        publish()
    }
    func setPreviewState(_ value: DesktopUpdateState) { guard demo else { return }; state = value }
    private func publish() { onStateChange?(state) }
}
