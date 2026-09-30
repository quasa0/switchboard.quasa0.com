import Combine
import SwiftUI
import SwitchboardCore

/// Both providers remain live in the same dashboard. Each account action keeps its
/// owning provider model, so it cannot accidentally target another provider's login.
@MainActor final class DashboardModel: ObservableObject {
    let claude: AppModel
    let chatGPT: AppModel
    let updates: DesktopUpdates
    private var subscriptions = Set<AnyCancellable>()
    private var refreshTask: Task<Void, Never>?
    private var autoRefreshTask: Task<Void, Never>?
    @Published private(set) var nextRefreshAt: Date?
    private var stopping = false
    @Published private var refreshingAll = false

    init(demo: Bool = false, empty: Bool = false, previewState: UIPreviewState? = nil,
         previewProvider: SubscriptionProvider? = nil) {
        let preview = demo || empty || previewState != nil || previewProvider != nil
        let state = previewState ?? (empty ? .empty : .accounts)
        updates = DesktopUpdates(demo: preview)
        claude = AppModel(demo: preview,
            previewState: preview ? (previewProvider == nil || previewProvider == .claude ? state : .accounts) : nil,
            provider: .claude)
        chatGPT = AppModel(demo: preview,
            previewState: preview ? (previewProvider == nil || previewProvider == .chatGPT ? state : .accounts) : nil,
            provider: .chatGPT)
        for model in providers {
            model.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &subscriptions)
        }
    }

    var providers: [AppModel] { [claude, chatGPT] }
    func model(for provider: SubscriptionProvider) -> AppModel { provider == .claude ? claude : chatGPT }
    var isDemo: Bool { providers.allSatisfy(\.isDemo) }
    var isCredentialFreePreview: Bool { providers.allSatisfy(\.isCredentialFreePreview) }
    var accountCount: Int { providers.reduce(0) { $0 + $1.accounts.count } }
    var isBusy: Bool { providers.contains(where: \.isBusy) }
    var isLoading: Bool { providers.contains(where: \.isLoading) }
    var isRefreshing: Bool { refreshingAll || providers.contains(where: \.isRefreshing) }
    var loginInProgress: Bool { providers.contains(where: \.loginInProgress) }
    var isBlocked: Bool { isBusy || isLoading || isRefreshing || loginInProgress }

    func startAutoRefresh() {
        guard !isDemo, !stopping, autoRefreshTask == nil else { return }
        nextRefreshAt = Date().addingTimeInterval(300)
        autoRefreshTask = Task { [weak self] in
            let clock = ContinuousClock()
            var nextTick = clock.now.advanced(by: .seconds(300))
            while !Task.isCancelled {
                do { try await clock.sleep(until: nextTick) }
                catch { return }
                guard let self, !self.stopping else { return }
                // A sign-in or switch owns the login until it finishes. Skip this tick.
                if !self.isBlocked { await self.refresh() }
                nextTick = nextTick.advanced(by: .seconds(300))
                // After sleep or an unusually long check, resume without a catch-up burst.
                if nextTick <= clock.now { nextTick = clock.now.advanced(by: .seconds(300)) }
                let delay = clock.now.duration(to: nextTick).components
                self.nextRefreshAt = Date().addingTimeInterval(Double(delay.seconds) + Double(delay.attoseconds) / 1e18)
            }
        }
    }

    func refresh() async {
        guard !stopping, !isBusy, !isRefreshing, !loginInProgress else { return }
        refreshingAll = true
        defer { refreshingAll = false }
        let task = Task { [claude, chatGPT] in
            // These engines use separate credential stores. One slow provider must
            // not delay the other provider's account list or usage result.
            async let claudeRefresh: Void = claude.refresh()
            async let chatGPTRefresh: Void = chatGPT.refresh()
            _ = await (claudeRefresh, chatGPTRefresh)
        }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    func shutdown() async {
        stopping = true
        updates.stop()
        autoRefreshTask?.cancel()
        refreshTask?.cancel()
        // Cancel the child models before awaiting the dashboard task: their
        // usage tasks own the CLI processes and must be allowed to reap them.
        async let claudeShutdown: Void = claude.shutdown()
        async let chatGPTShutdown: Void = chatGPT.shutdown()
        _ = await (claudeShutdown, chatGPTShutdown)
        await refreshTask?.value
        await autoRefreshTask?.value
        autoRefreshTask = nil
        nextRefreshAt = nil
    }
}
