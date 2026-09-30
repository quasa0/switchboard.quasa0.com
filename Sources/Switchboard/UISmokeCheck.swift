import AppKit
import SwiftUI
import SwitchboardCore

enum UIPreviewState: String, CaseIterable {
    case accounts, empty, loading, error, unavailable, exhausted, switching
    case longLabel = "long-label"
    case missingFiveHour = "missing-five-hour"
}

struct UILaunchOptions {
    let requiresDemo: Bool
    let runsCredentialSmoke: Bool
    let runsUISmoke: Bool
    let checksQuit: Bool
    let rendersPreview: Bool
    let previewState: UIPreviewState
    let previewProvider: SubscriptionProvider?
    let previewWidth: CGFloat
    let previewHeight: CGFloat
    let isDark: Bool
    let renderOutput: URL?
    let smokeOutput: URL
    let validationError: String?

    init(arguments: [String]) {
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1),
                  !arguments[index + 1].hasPrefix("--") else { return nil }
            return arguments[index + 1]
        }

        let uiOnly = arguments.contains {
            $0.hasPrefix("--demo") || $0.hasPrefix("--update-smoke") || $0.hasPrefix("--render-preview") ||
            $0.hasPrefix("--preview-") || $0.hasPrefix("--ui-smoke-test") ||
            $0 == "--empty" || $0 == "--dark" || $0 == "--light"
        }
        // Parse all UI modes before DashboardModel can construct either account engine. Combining a
        // UI flag with the credential smoke flag still selects the UI-only path.
        requiresDemo = uiOnly || UpdateSmokeCheck.fixtureMarker != nil || arguments.contains("--smoke-test") || arguments.contains("--check-quit")
        runsCredentialSmoke = arguments.contains("--smoke-test") && !uiOnly
        runsUISmoke = arguments.contains("--ui-smoke-test")
        checksQuit = arguments.contains("--check-quit")
        rendersPreview = arguments.contains("--render-preview")
        isDark = arguments.contains("--dark")

        var failure: String?
        let providerName = value(after: "--preview-provider")
        previewProvider = providerName.flatMap(SubscriptionProvider.init(rawValue:))
        if arguments.contains("--preview-provider"), providerName.flatMap(SubscriptionProvider.init(rawValue:)) == nil {
            failure = "Choose --preview-provider claude or chatGPT."
        }
        let stateName = value(after: "--preview-state")
        previewState = stateName.flatMap(UIPreviewState.init(rawValue:)) ?? (arguments.contains("--empty") ? .empty : .accounts)
        if arguments.contains("--preview-state"), stateName.flatMap(UIPreviewState.init(rawValue:)) == nil {
            failure = "Choose --preview-state accounts, empty, loading, error, unavailable, exhausted, switching, long-label, or missing-five-hour."
        }

        if arguments.contains("--preview-width") {
            if let raw = value(after: "--preview-width"), let width = Double(raw), width.isFinite, (620...1600).contains(width) {
                previewWidth = CGFloat(width)
            } else {
                previewWidth = 1120
                failure = "Use --preview-width with a number from 620 to 1600."
            }
        } else { previewWidth = 1120 }

        if arguments.contains("--preview-height") {
            if let raw = value(after: "--preview-height"), let height = Double(raw), height.isFinite, (490...1600).contains(height) {
                previewHeight = CGFloat(height)
            } else {
                previewHeight = 780
                failure = "Use --preview-height with a number from 490 to 1600."
            }
        } else { previewHeight = 780 }

        renderOutput = value(after: "--render-preview").map { URL(fileURLWithPath: $0) }
        if rendersPreview && renderOutput == nil { failure = "Give --render-preview a PNG output path." }
        smokeOutput = value(after: "--ui-smoke-test").map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("switchboard-ui-smoke-\(UUID().uuidString)")
        validationError = failure
    }
}

struct UIRenderRecord: Codable {
    let file: String
    let state: String
    let provider: String
    let dark: Bool
    let width: Double
    let height: Double
    let pixelWidth: Int
    let pixelHeight: Int
}

struct UISmokeReport: Codable {
    let credentialAccess: Bool
    let assertions: [String]
    let renders: [UIRenderRecord]
    let quitCleanupPassed: Bool

    func writeAfterQuitCleanup(to directory: URL) throws {
        let finished = UISmokeReport(credentialAccess: credentialAccess, assertions: assertions,
                                    renders: renders, quitCleanupPassed: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(finished).write(to: directory.appendingPathComponent("ui-smoke-report.json"), options: .atomic)
    }
}

struct UIVerificationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor enum UIPreviewRenderer {
    static func render(model: DashboardModel, state: UIPreviewState, to output: URL,
                       width: CGFloat = 1120, height: CGFloat = 780, dark: Bool = false) async throws -> UIRenderRecord {
        guard model.isCredentialFreePreview else {
            throw UIVerificationError(message: "Refusing to render a model with live account access.")
        }
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        NSApp.appearance = appearance
        let view = AccountListView(model: model)
            .frame(width: width, height: height)
            .environment(\.colorScheme, dark ? .dark : .light)
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: hostingView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = hostingView
        window.orderFrontRegardless()
        defer { window.close() }
        hostingView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        // Allow native scroll content to complete its display pass.
        try await Task.sleep(nanoseconds: 200_000_000)
        hostingView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            throw UIVerificationError(message: "The preview bitmap could not be created.")
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]), data.count > 1000 else {
            throw UIVerificationError(message: "The preview PNG could not be created.")
        }
        try data.write(to: output, options: .atomic)
        return UIRenderRecord(file: output.lastPathComponent, state: state.rawValue, provider: "all", dark: dark,
                              width: Double(width), height: Double(height),
                              pixelWidth: bitmap.pixelsWide, pixelHeight: bitmap.pixelsHigh)
    }
}

@MainActor enum UISmokeCheck {
    static func run(model: DashboardModel, output: URL) async throws -> UISmokeReport {
        try require(model.isCredentialFreePreview, "UI smoke must have no account engines.")
        try checkSafeLaunchFlags()
        try checkBillingDatePresentation()
        try await checkBillingPopup()
        let fixture = DashboardModel(demo: true)
        try require(fixture.isCredentialFreePreview && fixture.accountCount == 4,
                    "Both providers' synthetic accounts were not initialized together.")
        try require(fixture.providers.map(\.provider) == [.claude, .chatGPT] &&
                    fixture.claude.activeID != nil && fixture.chatGPT.activeID != nil,
                    "Both independent active accounts must exist on the same dashboard.")
        try require(fixture.chatGPT.accounts.map { SubscriptionProvider.chatGPT.planLabel($0.plan) } == ["Pro", "Pro Lite"],
                    "ChatGPT preview tiers must distinguish the reported Pro and Pro Lite identifiers.")
        try require(fixture.chatGPT.accounts[0].usage?.creditBalances?.first?.balance == "12500" &&
                    fixture.chatGPT.accounts[1].usage?.creditBalances?.first?.balance == "0",
                    "Usage credits must remain separate from manual reset counts.")
        fixture.startAutoRefresh()
        try require(fixture.nextRefreshAt == nil, "Preview must never start background usage polling.")
        try require(!fixture.claude.showsFableUsage, "Fable usage must start hidden in a credential-free preview.")
        let hiddenFable = accountUsageMetrics(fixture.claude.accounts[0].usage, provider: .claude)
        try require(hiddenFable.map(\.id) == ["weekly", "five-hour"],
                    "Claude must show weekly then five-hour limits with Fable hidden.")
        let visibleFable = accountUsageMetrics(fixture.claude.accounts[0].usage, provider: .claude, showsFable: true)
        try require(Array(visibleFable.prefix(2).map(\.id)) == ["weekly", "five-hour"] && visibleFable[2].isFeatured,
                    "Enabling Fable must put it third without changing general-limit order.")
        try require(fixture.claude.accounts.allSatisfy { $0.usage?.manualResets == nil } &&
                    fixture.chatGPT.accounts[0].usage?.manualResets?.availableCount == 3 &&
                    fixture.chatGPT.accounts[0].usage?.manualResets?.credits?.count == 3 &&
                    fixture.chatGPT.accounts[1].usage?.manualResets?.availableCount == 0,
                    "Manual reset fixtures must distinguish provider-unavailable data from reported positive and zero counts.")
        for provider in SubscriptionProvider.allCases {
            try await checkProviderActions(in: fixture, provider: provider)
        }
        try require(fixture.accountCount == 0, "Dashboard account count did not track provider removals.")
        fixture.claude.isBusy = true
        try require(fixture.isBusy && fixture.isBlocked, "Dashboard missed Claude's busy state.")
        fixture.claude.isBusy = false
        fixture.chatGPT.loginInProgress = true
        try require(fixture.loginInProgress && fixture.isBlocked, "Dashboard missed ChatGPT's sign-in state.")
        fixture.chatGPT.loginInProgress = false
        try require(!fixture.isBlocked, "Dashboard remained blocked after provider operations completed.")
        await fixture.shutdown()

        let stopped = DashboardModel(demo: true)
        let stoppedAccounts = stopped.providers.map(\.accounts)
        let stoppedActiveIDs = stopped.providers.map(\.activeID)
        let stoppedCurrent = stopped.providers.map(\.current)
        await stopped.shutdown()
        await stopped.refresh()
        for providerModel in stopped.providers {
            await providerModel.switchAccount(providerModel.accounts[1])
            await providerModel.setRenewal(account: providerModel.accounts[0], date: Date().addingTimeInterval(100))
        }
        try require(stopped.providers.map(\.accounts) == stoppedAccounts &&
                    stopped.providers.map(\.activeID) == stoppedActiveIDs &&
                    stopped.providers.map(\.current) == stoppedCurrent && !stopped.isRefreshing,
                    "Shutdown must prevent new refresh, account switching, or metadata changes.")

        let cases: [(String, UIPreviewState, Bool, CGFloat)] = [
            ("accounts-light", .accounts, false, 1120),
            ("accounts-dark", .accounts, true, 1120),
            ("empty", .empty, false, 1120),
            ("loading", .loading, false, 1120),
            ("error", .error, false, 1120),
            ("unavailable", .unavailable, false, 1120),
            ("exhausted", .exhausted, false, 1120),
            ("switching", .switching, false, 1120),
            ("long-label", .longLabel, false, 1120),
            ("missing-five-hour", .missingFiveHour, false, 1120),
            ("minimum-width", .accounts, false, 620)
        ]
        var records: [UIRenderRecord] = []
        for (name, state, dark, width) in cases {
            let sample = DashboardModel(demo: true, previewState: state)
            records.append(try await UIPreviewRenderer.render(model: sample, state: state,
                to: output.appendingPathComponent("\(name).png"), width: width, dark: dark))
            try require(sample.isCredentialFreePreview, "A render fixture acquired live account access.")
        }
        let fable = DashboardModel(demo: true)
        let preservedUsage = fable.claude.accounts.map(\.usage)
        fable.claude.showsFableUsage = true
        try require(fable.claude.accounts.map(\.usage) == preservedUsage && !fable.chatGPT.showsFableUsage,
                    "The Fable checkbox must change display only and leave the other provider unchanged.")
        for dark in [false, true] {
            records.append(try await UIPreviewRenderer.render(model: fable, state: .accounts,
                to: output.appendingPathComponent(dark ? "fable-enabled-dark.png" : "fable-enabled.png"), dark: dark))
        }
        let completed = DashboardModel(demo: true)
        for providerModel in completed.providers { await providerModel.switchAccount(providerModel.accounts[1]) }
        records.append(try await UIPreviewRenderer.render(model: completed, state: .accounts,
            to: output.appendingPathComponent("switch-completed.png")))
        let restrictedResets = DashboardModel(demo: true)
        restrictedResets.claude.accounts[0].usage?.claudeResetSnapshot?.eligible = false
        restrictedResets.claude.accounts[0].usage?.claudeResetSnapshot?.grants[0].usableNow = false
        restrictedResets.claude.accounts[1].usage?.claudeResetSnapshot?.eligible = false
        restrictedResets.claude.accounts[1].usage?.claudeResetSnapshot?.ineligibleReason = "surface"
        try require(restrictedResets.claude.accounts[0].claudeResets?.unexpiredGrants(at: Date()).count == 1 &&
                    restrictedResets.claude.accounts[1].claudeResets?.confirmsGrantInventory == false,
                    "Surface eligibility must preserve owned grants and leave an empty ineligible balance unconfirmed.")
        for dark in [false, true] {
            records.append(try await UIPreviewRenderer.render(model: restrictedResets, state: .accounts,
                to: output.appendingPathComponent(dark ? "restricted-resets-dark.png" : "restricted-resets.png"), dark: dark))
        }
        let compactSwitch = DashboardModel(demo: true, previewState: .switching)
        records.append(try await UIPreviewRenderer.render(model: compactSwitch, state: .switching,
            to: output.appendingPathComponent("switching-minimum-width.png"), width: 620))
        let partialFailure = DashboardModel(demo: true, previewState: .error, previewProvider: .chatGPT)
        try require(partialFailure.claude.usageErrors.isEmpty && !partialFailure.chatGPT.usageErrors.isEmpty,
                    "A ChatGPT fixture error contaminated the Claude accounts.")
        records.append(try await UIPreviewRenderer.render(model: partialFailure, state: .error,
            to: output.appendingPathComponent("one-provider-error.png")))

        for provider in SubscriptionProvider.allCases {
            let sample = DashboardModel(demo: true)
            let other = sample.model(for: provider == .claude ? .chatGPT : .claude)
            other.accounts = []; other.activeID = nil; other.current = nil
            try require(sample.accountCount == 2, "A single-provider fixture retained the other provider's accounts.")
            let name = provider == .claude ? "only-claude" : "only-chatgpt"
            records.append(try await UIPreviewRenderer.render(model: sample, state: .accounts,
                to: output.appendingPathComponent("\(name).png")))
        }
        let restored = DashboardModel(demo: true, previewState: .missingFiveHour)
        try require(restored.providers.allSatisfy { $0.accounts.allSatisfy { $0.usage != nil && $0.usage?.fiveHour == nil } },
                    "Missing-five-hour fixtures must keep successful usage snapshots for both providers.")
        for providerModel in restored.providers {
            for account in providerModel.accounts {
                let metrics = accountUsageMetrics(account.usage, provider: providerModel.provider)
                try require(!metrics.contains(where: { $0.id == "five-hour" }) &&
                            metrics.contains(where: { $0.id == "weekly" && $0.window == account.usage?.sevenDay }),
                            "A missing five-hour meter must stay hidden while the reported weekly window remains visible.")
            }
            let weekly = providerModel.accounts[0].usage?.sevenDay
            providerModel.usageErrors[providerModel.accounts[0].id] = "Synthetic retained usage error"
            providerModel.accounts[0].usage?.fiveHour = UsageWindow(utilization: 17, resetsAt: Date().addingTimeInterval(3_600))
            let metrics = accountUsageMetrics(providerModel.accounts[0].usage, provider: providerModel.provider)
            try require(metrics.contains(where: { $0.id == "five-hour" && $0.window.utilization == 17 }) &&
                        metrics.contains(where: { $0.id == "weekly" && $0.window == weekly }),
                        "A newly reported five-hour window did not return without changing weekly usage.")
            try require(providerModel.usageErrors[providerModel.accounts[0].id] == "Synthetic retained usage error",
                        "A metric update discarded an unrelated usage error.")
            providerModel.usageErrors = [:]
        }
        records.append(try await UIPreviewRenderer.render(model: restored, state: .accounts,
            to: output.appendingPathComponent("five-hour-restored.png")))

        let resetStates = DashboardModel(demo: true)
        resetStates.chatGPT.accounts[0].usage?.manualResets = ManualResetSummary(availableCount: 4, credits: nil)
        resetStates.chatGPT.accounts[1].usage?.manualResets = ManualResetSummary(availableCount: 3, credits: [
            ManualResetCredit(id: "sample-no-expiry", resetType: "codexRateLimits", status: "available",
                grantedAt: Date().addingTimeInterval(-86_400), expiresAt: nil, title: "No expiry"),
            ManualResetCredit(id: "sample-past-expiry", resetType: "codexRateLimits", status: "available",
                grantedAt: Date().addingTimeInterval(-30 * 86_400), expiresAt: Date().addingTimeInterval(-60), title: "Awaiting updated status")
        ])
        try require(resetStates.chatGPT.accounts[0].usage?.manualResets?.credits == nil &&
                    resetStates.chatGPT.accounts[1].usage?.manualResets?.availableCount == 3 &&
                    resetStates.chatGPT.accounts[1].usage?.manualResets?.credits?.count == 2,
                    "Missing or capped reset details must not replace the reported available count.")
        records.append(try await UIPreviewRenderer.render(model: resetStates, state: .accounts,
            to: output.appendingPathComponent("manual-reset-states.png")))

        let automaticBilling = DashboardModel(demo: true)
        let billingNow = Date()
        let giftFormatter = DateFormatter()
        giftFormatter.locale = Locale(identifier: "en_US_POSIX")
        giftFormatter.calendar = Calendar(identifier: .gregorian)
        giftFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        giftFormatter.dateFormat = "yyyy-MM-dd"
        automaticBilling.claude.accounts[0].claudeBilling = ClaudeBillingSnapshot(
            checkedAt: billingNow, status: "trialing", nextChargeAt: billingNow.addingTimeInterval(5 * 86_400),
            giftPaidThrough: giftFormatter.string(from: billingNow.addingTimeInterval(90 * 86_400)))
        automaticBilling.claude.accounts[1].claudeBilling = ClaudeBillingSnapshot(
            checkedAt: billingNow, status: "canceled", nextChargeAt: billingNow.addingTimeInterval(30 * 86_400),
            planEndingAt: billingNow.addingTimeInterval(7 * 86_400))
        automaticBilling.chatGPT.accounts[0].subscriptionPeriod = SubscriptionPeriod(
            endsAt: billingNow.addingTimeInterval(9 * 86_400), checkedAt: billingNow,
            willRenew: true, source: .codexIDToken)
        automaticBilling.chatGPT.accounts[1].subscriptionPeriod = SubscriptionPeriod(
            endsAt: billingNow.addingTimeInterval(-3 * 86_400), checkedAt: billingNow.addingTimeInterval(-4 * 86_400),
            source: .codexIDToken)
        let failedBillingID = automaticBilling.claude.accounts[1].id
        let retainedBilling = automaticBilling.claude.accounts[1].claudeBilling
        automaticBilling.claude.billingErrors[failedBillingID] = "Saved billing date kept. Reconnect billing to try again."
        automaticBilling.claude.usageErrors[failedBillingID] = "Saved usage kept. Refresh to try again."
        try require(automaticBilling.claude.accounts[1].claudeBilling == retainedBilling &&
                    automaticBilling.claude.billingErrors[failedBillingID] != nil &&
                    automaticBilling.claude.usageErrors[failedBillingID] != nil,
                    "Billing and usage failures must coexist without replacing cached billing metadata.")
        records.append(try await UIPreviewRenderer.render(model: automaticBilling, state: .accounts,
            to: output.appendingPathComponent("automatic-billing.png"), dark: true))

        for status: DesktopUpdateState.Status in [.available, .downloading, .ready, .error] {
            let dashboard = DashboardModel(demo: true)
            var state = DesktopUpdateState(status: status)
            state.version = "0.6.0"; state.progress = status == .downloading ? 42 : nil
            dashboard.updates.setPreviewState(state)
            records.append(try await UIPreviewRenderer.render(model: dashboard, state: .accounts,
                to: output.appendingPathComponent("update-\(status.rawValue).png"), dark: true))
        }
        return UISmokeReport(credentialAccess: false,
            assertions: ["Every UI flag selects demo before model initialization", "No account engines in preview dashboards",
                         "Both providers and active accounts coexist", "Each provider switch updates only its own identity",
                         "ChatGPT sample plans distinguish Pro 20× and Pro 5×",
                         "Manual reset counts preserve unavailable, zero, capped details, due dates, and no expiry",
                         "Automatic billing distinguishes renewal certainty, elapsed periods, and unavailable dates",
                         "Manual renewal overrides take precedence and clearing restores automatic dates",
                         "Claude gift coverage keeps its whole UTC date and takes precedence over monthly charges",
                         "Claude cancellation and trial dates do not invent renewals",
                         "Billing and usage failures preserve their independent cached data",
                         "Preview billing sessions construct no WebView or web data store",
                         "Each provider switch includes its session notice", "Rename and remove preserve sibling provider state",
                         "Remove preserves simulated current login", "Preview sign-in stays in memory",
                         "Dashboard count and busy state aggregate both providers", "One provider error leaves the other healthy",
                         "Shutdown prevents subsequent refresh, switch, and renewal changes",
                         "Successful usage without five-hour data and later restoration both render"],
            renders: records, quitCleanupPassed: false)
    }

    private static func checkProviderActions(in dashboard: DashboardModel, provider: SubscriptionProvider) async throws {
        let selected = dashboard.model(for: provider)
        let sibling = dashboard.model(for: provider == .claude ? .chatGPT : .claude)
        let siblingAccounts = sibling.accounts, siblingActiveID = sibling.activeID, siblingCurrent = sibling.current
        let siblingErrors = sibling.usageErrors
        func siblingUnchanged() throws {
            try require(sibling.accounts == siblingAccounts && sibling.activeID == siblingActiveID &&
                        sibling.current == siblingCurrent && sibling.usageErrors == siblingErrors,
                        "A \(provider.rawValue) operation changed its sibling provider's accounts or identity.")
        }
        let first = selected.accounts[0], second = selected.accounts[1]
        let automaticDate = accountBillingDate(first)?.date
        let manualDate = Date().addingTimeInterval(60 * 86_400)
        await selected.setRenewal(account: first, date: manualDate)
        try require(selected.accounts[0].renewalAt == manualDate &&
                    accountBillingDate(selected.accounts[0])?.date == manualDate &&
                    selected.accounts[0].subscriptionPeriod == first.subscriptionPeriod &&
                    selected.accounts[0].claudeBilling == first.claudeBilling,
                    "A manual renewal override must win without changing automatic billing metadata.")
        try siblingUnchanged()
        await selected.setRenewal(account: selected.accounts[0], date: nil)
        try require(selected.accounts[0].renewalAt == nil && accountBillingDate(selected.accounts[0])?.date == automaticDate,
                    "Clearing a manual renewal override must restore the provider's automatic date.")
        try siblingUnchanged()
        await selected.switchAccount(second)
        try require(selected.activeID == second.id && selected.current?.accountUUID == second.accountUUID,
                    "Switching \(provider.rawValue) did not update its in-memory identity.")
        try require(selected.switchingAccountID == nil && !selected.isBusy,
                    "Switching left its progress state active after completion.")
        let notice = provider == .claude ? "Restart open Claude Code sessions" : "Start a new Codex session"
        try require(selected.notice?.contains(notice) == true, "Switching omitted its provider's session notice.")
        try siblingUnchanged()
        await selected.rename(second, label: "\(provider.rawValue) projects")
        try require(selected.accounts.first(where: { $0.id == second.id })?.label == "\(provider.rawValue) projects",
                    "Renaming did not update the selected provider's account.")
        try siblingUnchanged()
        await selected.remove(first)
        try require(selected.accounts.count == 1 && selected.activeID == second.id,
                    "Removing an inactive account changed the selected provider's active identity.")
        try siblingUnchanged()
        await selected.remove(second)
        try require(selected.accounts.isEmpty && selected.activeID == nil && selected.current?.accountUUID == second.accountUUID,
                    "Removing the saved active account did not preserve its simulated CLI login.")
        try siblingUnchanged()
        await selected.beginLogin()
        try require(!selected.loginInProgress && selected.isCredentialFreePreview,
                    "Preview sign-in attempted to start a real login.")
        try siblingUnchanged()
    }

    private static func checkBillingPopup() async throws {
        // Only inline HTML in an ephemeral store. No network, accounts, cookies, or Keychain.
        let account = SavedAccount(label: "Popup fixture", email: "popup@synthetic.example",
                                   accountUUID: "synthetic-popup", organizationUUID: "synthetic-org", plan: "Pro")
        let session = ClaudeBillingSession(account: account, ephemeral: true)
        defer { session.stop() }
        guard let parent = session.webView else { throw UIVerificationError(message: "Popup fixture was not created.") }
        parent.loadHTMLString("<html><head><title>synthetic-opener</title></head><body>Sign-in fixture</body></html>", baseURL: nil)
        for _ in 0..<100 {
            if !parent.isLoading, parent.url != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        _ = try await parent.evaluateJavaScript("window.open('about:blank'); true")
        for _ in 0..<100 {
            if let popup = session.popupWebView, !popup.isLoading { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard let popup = session.popupWebView else { throw UIVerificationError(message: "Sign-in popup replaced its parent.") }
        try require(popup !== parent && popup.configuration.websiteDataStore === parent.configuration.websiteDataStore,
                    "Sign-in popup must preserve its parent and isolated data store.")
        let title = try await popup.evaluateJavaScript("window.opener.document.title") as? String
        try require(title == "synthetic-opener", "Sign-in popup lost window.opener.")
        _ = try await popup.evaluateJavaScript("window.close(); true")
        for _ in 0..<100 {
            if session.popupWebView == nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try require(session.popupWebView == nil, "Sign-in popup did not close after completion.")
        let retained = try await parent.evaluateJavaScript("document.title") as? String
        try require(retained == "synthetic-opener", "Closing sign-in popup changed its parent page.")
    }

    private static func checkBillingDatePresentation() throws {
        let iso = ISO8601DateFormatter()
        let now = iso.date(from: "2026-09-24T12:00:00Z")!
        let future = iso.date(from: "2026-10-24T12:00:00Z")!
        var account = SavedAccount(label: "Billing fixture", email: "billing@sample.example",
            accountUUID: "billing-fixture", organizationUUID: "billing-org", plan: "Pro")
        try require(accountBillingDate(account, now: now) == nil,
                    "Absent subscription metadata must not invent a billing date.")

        account.subscriptionPeriod = SubscriptionPeriod(endsAt: future, checkedAt: now, source: .codexIDToken)
        try require(accountBillingDate(account, now: now)?.label == "Period ends" &&
                    accountBillingDate(account, now: now)?.explanation.contains("Source: Codex ID token.") == true &&
                    accountBillingDate(account, now: now)?.explanation.contains("Checked ") == true,
                    "Unknown renewal certainty must show a period end with its source and observation time.")
        account.subscriptionPeriod?.willRenew = true
        try require(accountBillingDate(account, now: now)?.label == "Renews",
                    "Confirmed automatic renewal should be labeled Renews.")
        account.subscriptionPeriod?.willRenew = false
        try require(accountBillingDate(account, now: now)?.label == "Ends",
                    "A nonrenewing subscription should be labeled Ends.")
        account.subscriptionPeriod?.willRenew = nil
        account.subscriptionPeriod?.endsAt = now.addingTimeInterval(-1)
        try require(accountBillingDate(account, now: now)?.label == "Last period ended",
                    "An elapsed cached period must not claim that account authentication expired.")

        let giftDay = "2027-01-27"
        let giftMidnight = iso.date(from: "2027-01-27T00:00:00Z")!
        account.claudeBilling = ClaudeBillingSnapshot(checkedAt: now, status: "trialing", nextChargeAt: future,
            giftPaidThrough: giftDay)
        let gift = accountBillingDate(account, now: now)
        try require(gift?.date == giftMidnight && gift?.label == "Gift covers through" &&
                    gift?.displayText?.hasPrefix("Gift covers through ") == true &&
                    gift?.displayText?.contains(":") == false &&
                    gift?.explanation.contains(giftDay) == true &&
                    gift?.explanation.contains("date without a time of day") == true,
                    "Gift coverage must preempt a monthly charge without presenting an invented midnight or local cutoff.")
        try require(accountBillingDate(account, now: giftMidnight.addingTimeInterval(86_399))?.label == "Gift covers through" &&
                    accountBillingDate(account, now: giftMidnight.addingTimeInterval(86_400))?.label == "Gift covered through",
                    "Gift coverage must include its complete UTC calendar day.")

        let override = now.addingTimeInterval(2 * 86_400)
        account.renewalAt = override
        try require(accountBillingDate(account, now: now)?.date == override &&
                    accountBillingDate(account, now: now)?.explanation.contains("entered manually") == true,
                    "A manual override must take precedence over both Claude billing and subscription-period metadata.")
        account.renewalAt = nil
        try require(accountBillingDate(account, now: now)?.date == giftMidnight,
                    "Clearing an override must expose the saved gift coverage again.")

        let planEnd = now.addingTimeInterval(7 * 86_400)
        account.claudeBilling = ClaudeBillingSnapshot(checkedAt: now, status: "canceled", nextChargeAt: future,
            planEndingAt: planEnd)
        try require(accountBillingDate(account, now: now)?.date == planEnd &&
                    accountBillingDate(account, now: now)?.label == "Plan ends",
                    "A reported charge after cancellation must not override the earlier plan end.")
        account.claudeBilling?.nextChargeAt = planEnd
        try require(accountBillingDate(account, now: now)?.label == "Plan ends",
                    "A same-time charge is not before the plan end.")
        account.claudeBilling?.status = "trialing"
        account.claudeBilling?.nextChargeAt = now.addingTimeInterval(86_400)
        try require(accountBillingDate(account, now: now)?.label == "Plan ends",
                    "Trial metadata must prefer the reported plan end over a potential charge.")
        account.claudeBilling?.planEndingAt = nil
        try require(accountBillingDate(account, now: now) == nil,
                    "A trial-only potential charge must not become a fabricated renewal.")

        account.claudeBilling = ClaudeBillingSnapshot(checkedAt: now, status: "active",
            nextChargeAt: iso.date(from: "2026-10-24T01:00:00Z")!, planEndingDate: "2026-10-24")
        try require(accountBillingDate(account, now: now)?.label == "Plan ends" &&
                    accountBillingDate(account, now: now)?.displayText != nil,
                    "An exact charge and a date-only plan end on the same UTC day must not acquire a guessed ordering.")
        account.claudeBilling?.nextChargeAt = nil
        account.claudeBilling?.nextChargeDate = "2026-10-23"
        try require(accountBillingDate(account, now: now)?.label == "Next charge" &&
                    accountBillingDate(account, now: now)?.displayText != nil,
                    "A date-only charge before the plan end should retain its date-only presentation.")
        account.claudeBilling = ClaudeBillingSnapshot(checkedAt: now, paymentPausedUntil: future)
        try require(accountBillingDate(account, now: now) == nil,
                    "A payment pause alone must not become a renewal or resurrect older period metadata.")

        let session = ClaudeBillingSession(account: account, enabled: false)
        defer { session.stop() }
        session.open()
        try require(session.webView == nil && !session.isChecking,
                    "Preview billing sessions must never create a WebView or start a billing request.")
    }

    private static func checkSafeLaunchFlags() throws {
        let cases = [
            ["--demo"], ["--update-smoke", "invalid"], ["--empty"], ["--dark"], ["--light"], ["--check-quit"],
            ["--render-preview", "/tmp/example.png"], ["--preview-state", "error"],
            ["--preview-width", "620"], ["--preview-height", "780"], ["--ui-smoke-test"],
            ["--preview-state", "missing-five-hour"],
            ["--preview-provider", "chatGPT"], ["--preview-provider", "invalid"],
            ["--ui-smoke-test", "--smoke-test"], ["--demo", "--smoke-test"],
            ["--preview-state", "invalid"], ["--preview-width", "invalid"]
        ]
        for arguments in cases {
            let options = UILaunchOptions(arguments: ["Switchboard"] + arguments)
            try require(options.requiresDemo && !options.runsCredentialSmoke,
                        "A UI flag selected the credential-backed launch path.")
            let sample = DashboardModel(demo: options.requiresDemo, previewState: options.previewState, previewProvider: options.previewProvider)
            try require(sample.isCredentialFreePreview, "A UI flag initialized an account engine.")
        }
        let defaults = UILaunchOptions(arguments: ["Switchboard", "--demo"])
        try require(defaults.previewProvider == nil && defaults.previewWidth == 1120 && defaults.previewHeight == 780,
                    "The default preview must show the unified dashboard at its standard size.")
        try require(DashboardModel(empty: true).isCredentialFreePreview,
                    "An empty-state preview initialized an account engine.")
        try require(DashboardModel(previewState: .error).isCredentialFreePreview,
                    "A named-state preview initialized an account engine.")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw UIVerificationError(message: message) }
    }
}
