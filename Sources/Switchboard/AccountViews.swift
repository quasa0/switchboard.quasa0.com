import AppKit
import SwiftUI
import SwitchboardCore

private enum Palette {
    static let canvas = adaptive(light: 0xFAFAFA, dark: 0x0A0A0A)
    static let paper = adaptive(light: 0xFFFFFF, dark: 0x171717)
    static let ink = adaptive(light: 0x171717, dark: 0xEDEDED)
    static let muted = adaptive(light: 0x666666, dark: 0xA1A1A1)
    static let faint = adaptive(light: 0xEAEAEA, dark: 0x292929)
    static let accent = ink
    static let accentWash = faint
    static let green = ink
    static let greenWash = faint
    static let accentText = adaptive(light: 0x0068D6, dark: 0x52A8FF)
    static let warning = adaptive(light: 0x8F5200, dark: 0xFFB224)
    static let danger = adaptive(light: 0xC42B30, dark: 0xFF757A)
    static let errorWash = adaptive(light: 0xFFF0F0, dark: 0x2A1314)
    static let meter = ink
    static let edge = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.09) : NSColor.black.withAlphaComponent(0.07)
    })

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

private struct AccountActionTarget: Identifiable {
    let provider: SubscriptionProvider
    let account: SavedAccount
    var id: String { "\(provider.rawValue)-\(account.id.uuidString)" }
}

private struct PreserveDisabledControlAppearanceKey: EnvironmentKey {
    static let defaultValue = false
}

private extension EnvironmentValues {
    var preservesDisabledControlAppearance: Bool {
        get { self[PreserveDisabledControlAppearanceKey.self] }
        set { self[PreserveDisabledControlAppearanceKey.self] = newValue }
    }
}

private struct StableDisabledMenuAppearance<LabelView: View>: ViewModifier {
    let disabled: Bool
    let label: LabelView
    @Environment(\.preservesDisabledControlAppearance) private var preservesAppearance

    func body(content: Content) -> some View {
        // Native menus dim their labels independently of ButtonStyle. Keep the
        // disabled menu in place and draw the same inert label above it.
        content
            .disabled(disabled)
            .opacity(disabled && preservesAppearance ? 0 : 1)
            .overlay {
                if disabled && preservesAppearance {
                    label.environment(\.isEnabled, true)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }
}

struct AccountListView: View {
    @ObservedObject var model: DashboardModel
    @State private var accountToAdd: SubscriptionProvider?
    @State private var accountToRename: AccountActionTarget?
    @State private var accountToRenew: AccountActionTarget?
    @State private var accountToViewResets: AccountActionTarget?
    @State private var accountToRemove: AccountActionTarget?

    private var isPresentingAccountAction: Bool {
        accountToAdd != nil || accountToRename != nil || accountToRenew != nil
            || accountToViewResets != nil || accountToRemove != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(model.providers, id: \.provider) { providerModel in
                            ProviderAccountSection(
                                model: providerModel,
                                wideLayout: geometry.size.width >= 950,
                                isBlocked: model.isBlocked || isPresentingAccountAction,
                                onAdd: { accountToAdd = providerModel.provider },
                                onRename: { accountToRename = AccountActionTarget(provider: providerModel.provider, account: $0) },
                                onSetRenewal: { accountToRenew = AccountActionTarget(provider: providerModel.provider, account: $0) },
                                onViewResets: { accountToViewResets = AccountActionTarget(provider: providerModel.provider, account: $0) },
                                onRemove: { accountToRemove = AccountActionTarget(provider: providerModel.provider, account: $0) }
                            )
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 4)
                    .padding(.bottom, 24)
                }
            }
            footer
        }
        .frame(minWidth: 620, idealWidth: 1120, minHeight: 490, idealHeight: 780)
        .background(Palette.canvas)
        .foregroundStyle(Palette.ink)
        .environment(\.preservesDisabledControlAppearance, model.providers.contains { $0.switchingAccountID != nil })
        .sheet(item: $accountToAdd) { provider in
            AddAccountSheet(model: model.model(for: provider))
        }
        .sheet(item: $accountToRename) { target in
            RenameAccountSheet(model: model.model(for: target.provider), account: target.account)
        }
        .sheet(item: $accountToRenew) { target in
            RenewalDateSheet(model: model.model(for: target.provider), account: target.account)
        }
        .sheet(item: $accountToViewResets) { target in
            ResetDetailsSheet(account: target.account, provider: target.provider)
        }
        .alert("Remove saved account?", isPresented: Binding(
            get: { accountToRemove != nil },
            set: { if !$0 { accountToRemove = nil } }
        ), presenting: accountToRemove) { target in
            Button("Cancel", role: .cancel) { accountToRemove = nil }
            Button("Remove", role: .destructive) {
                accountToRemove = nil
                Task { await model.model(for: target.provider).remove(target.account) }
            }
        } message: { target in
            Text("Remove \(target.account.label) from Switchboard? This deletes its saved login. It does not cancel the subscription or sign \(target.provider.cliName) out.")
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            headerContent(compact: false)
            headerContent(compact: true)
        }
    }

    private func headerContent(compact: Bool) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Palette.muted)
                .frame(width: 25)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 11) {
                    Text("Switchboard")
                        .font(.system(size: 20, weight: .semibold))
                        .tracking(-0.5)
                        .fixedSize()
                    if !compact {
                        Text("\(model.accountCount) accounts")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.muted)
                    }
                }
                Text(model.isDemo ? "Preview · Sample accounts" : "Choose your next session.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 12)
            if !compact { TimelineView(.periodic(from: .now, by: 60)) { context in
                Text(model.isDemo ? "Auto refresh · 5 min" : model.nextRefreshAt.map {
                    "Next refresh \(dueInterval($0, now: context.date))"
                } ?? "Auto refresh · 5 min")
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
            }.fixedSize() }
            Button { Task { await model.refresh() } } label: {
                HStack(spacing: 7) {
                    ZStack {
                        Image(systemName: "arrow.clockwise")
                            .opacity(model.isRefreshing ? 0 : 1)
                        if model.isRefreshing { ProgressView().controlSize(.mini) }
                    }
                    .frame(width: 14, height: 14)
                    Text("Refresh all")
                }
            }
            .buttonStyle(ActionButtonStyle(prominent: false, staticFeedback: true))
            .help("Refresh all accounts and usage (⌘R)")
            .accessibilityLabel("Refresh all accounts and usage")
            .keyboardShortcut("r", modifiers: .command)
            .disabled(model.isBlocked || isPresentingAccountAction)

            Menu {
                Button("Add Claude account") { accountToAdd = .claude }
                Button("Add ChatGPT account") { accountToAdd = .chatGPT }
            } label: {
                addAccountMenuLabel
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .buttonStyle(ActionButtonStyle(prominent: false))
            .fixedSize()
            .modifier(StableDisabledMenuAppearance(disabled: model.isBlocked || isPresentingAccountAction,
                                                  label: addAccountMenuLabel))
            .accessibilityLabel("Add account")
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 12)
    }

    private var addAccountMenuLabel: some View {
        Label("Add account", systemImage: "plus")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Palette.ink)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Palette.faint).frame(height: 0.7)
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "arrow.turn.down.right").font(.system(size: 11))
                Text("Close Codex before switching. Restart Claude Code after switching.")
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 10)
                DesktopUpdateControl(updates: model.updates, accountOperationActive: model.isBlocked)
                Image(systemName: "lock.shield").font(.system(size: 12))
                    .help("Saved logins stay in your Mac’s Keychain.")
                    .accessibilityLabel("Saved logins stay in your Mac’s Keychain")
            }
            .foregroundStyle(Palette.muted)
            .padding(.horizontal, 24)
            .padding(.vertical, 13)
        }
    }
}

private struct DesktopUpdateControl: View {
    @ObservedObject var updates: DesktopUpdates
    let accountOperationActive: Bool
    @State private var confirmsRestart = false

    var body: some View {
        Group {
            switch updates.state.status {
            case .available:
                Button { updates.download() } label: {
                    Label("Update \(updates.state.version ?? "")", systemImage: "arrow.down.circle")
                }
                .disabled(!updates.canDownload)
            case .downloading:
                Text(updates.state.progress.map { "Downloading \(Int($0))%" } ?? "Downloading update…")
                    .monospacedDigit()
            case .ready:
                Button { confirmsRestart = true } label: {
                    Label("Restart to update", systemImage: "arrow.clockwise")
                }
                .disabled(!updates.canInstall || accountOperationActive)
                .help(accountOperationActive ? "Finish the account operation before restarting." : "Install the verified update and reopen Switchboard.")
            case .installing: Text("Restarting…")
            case .checking: Text("Checking for updates…")
            case .error:
                Button("Retry update check") { updates.check() }.disabled(!updates.canCheck)
            case .idle, .disabled: EmptyView()
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(Palette.ink)
        .buttonStyle(UpdateActionStyle())
        .help(updates.state.message ?? "Switchboard updates")
        .alert("Restart to update Switchboard?", isPresented: $confirmsRestart) {
            Button("Cancel", role: .cancel) {}
            Button("Update and restart") { if !accountOperationActive { updates.install() } }
        } message: {
            Text("Switchboard will install version \(updates.state.version ?? "") and reopen. Your saved accounts stay on this Mac.")
        }
    }
}

private struct UpdateActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Rectangle())
    }
}

private struct ProviderAccountSection: View {
    @ObservedObject var model: AppModel
    @State private var connectingBilling: SavedAccount?
    let wideLayout: Bool
    let isBlocked: Bool
    let onAdd: () -> Void
    let onRename: (SavedAccount) -> Void
    let onSetRenewal: (SavedAccount) -> Void
    let onViewResets: (SavedAccount) -> Void
    let onRemove: (SavedAccount) -> Void

    private var metricTitles: [String] {
        // Keep reported Fable slots in the grid even when their contents are hidden.
        let metrics = model.accounts.flatMap { accountUsageMetrics($0.usage, provider: model.provider, showsFable: true) }
        let generalIDs = model.provider == .claude ? ["weekly", "five-hour"] : ["five-hour", "weekly"]
        let ordered = generalIDs.flatMap { id in metrics.filter { $0.id == id } }
            + metrics.filter(\.isFeatured)
            + metrics.filter { !$0.isFeatured && $0.id != "five-hour" && $0.id != "weekly" }
        return ordered.reduce(into: []) { titles, metric in
            if !titles.contains(metric.title) { titles.append(metric.title) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader
            if let loadError = model.loadError {
                MessageStrip(symbol: "exclamationmark.circle", text: loadError, isError: true)
            }
            if let error = model.error {
                MessageStrip(symbol: "exclamationmark.circle", text: error, isError: true)
            } else if model.accounts.isEmpty, model.loadError == nil, let notice = model.notice {
                MessageStrip(symbol: "checkmark.circle", text: notice, isError: false)
            }

            if model.accounts.isEmpty {
                if model.isLoading {
                    ProgressView("Loading \(model.provider.displayName) accounts…")
                        .frame(maxWidth: .infinity, minHeight: 130)
                } else if model.loadError != nil {
                    unavailableState
                } else {
                    emptyState
                }
            } else {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    decisionSummary(now: context.date)
                }
                VStack(spacing: 0) {
                    ForEach(model.accounts) { account in
                        AccountRow(
                            account: account,
                            provider: model.provider,
                            wideLayout: wideLayout,
                            metricTitles: metricTitles,
                            showsFable: model.showsFableUsage,
                            showsManualResets: true,
                            isActive: account.id == model.activeID,
                            isBusy: isBlocked || connectingBilling != nil,
                            isSwitching: account.id == model.switchingAccountID,
                            usageError: model.usageErrors[account.id],
                            billingError: model.billingErrors[account.id],
                            onSwitch: { Task { await model.switchAccount(account) } },
                            onRename: { onRename(account) },
                            onSetRenewal: { onSetRenewal(account) },
                            onViewResets: { onViewResets(account) },
                            onConnectBilling: { connectingBilling = account },
                            onRemove: { onRemove(account) }
                        )
                    }
                }
                if let current = model.current, model.activeID == nil, !model.loginInProgress {
                    unsavedLogin(current)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .sheet(item: $connectingBilling) { account in
            ClaudeBillingSheet(account: account, model: model)
        }
    }

    @ViewBuilder
    private func decisionSummary(now: Date) -> some View {
        let recommendedID = AccountReadiness.recommendation(accounts: model.accounts,
            failedIDs: Set(model.usageErrors.keys), now: now)
        if let account = model.accounts.first(where: { $0.id == recommendedID }) {
            let readiness = AccountReadiness(usage: account.usage, now: now)
            let mixedPlans = Set(model.accounts.map { model.provider.planLabel($0.usage?.reportedPlan ?? $0.plan) }).count > 1
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(mixedPlans ? "Most % left ·" : account.id == model.activeID ? "Stay on" : "Use") \(account.label)")
                            .font(.system(size: 16, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(account.label)
                        Text("\(Int((readiness.remaining ?? 0).rounded()))% headroom")
                            .font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize()
                    }
                    Text("\(mixedPlans ? "Different plans have different task budgets" : "Most general headroom")\(readiness.resetAt.map { " · \(readiness.limitingWindow ?? "Limit") \(resetCountdown($0, now: now).lowercased())" } ?? "")")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
            }
            .padding(.vertical, 3)
            .help("Compares fresh general-window percentages, not task capacity across plans. Named model limits and credits are shown below. Equal percentages favor the earlier reset.")
        } else {
            Text(model.isRefreshing ? "Checking which account is ready…" : "Check the limits below before switching.")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Palette.muted)
                .padding(.vertical, 9)
        }
    }

    private var sectionHeader: some View {
        HStack(spacing: 8) {
            Text(model.provider.displayName)
                .font(.system(size: 15, weight: .semibold))
            Text("\(model.accounts.count)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Palette.muted)
                .accessibilityLabel("\(model.accounts.count) saved accounts")
            Spacer(minLength: 12)
            if model.provider == .claude {
                Toggle("Show Fable usage", isOn: $model.showsFableUsage)
                    .toggleStyle(NeutralCheckboxStyle())
                    .font(.system(size: 11))
                    .fixedSize()
                    .help("Show Fable's weekly limit after the weekly and five-hour limits. This only changes the dashboard.")
                    .accessibilityIdentifier("show-fable-usage")
            }
            Button(action: onAdd) {
                Label("Add account", systemImage: "plus")
            }
            .buttonStyle(ActionButtonStyle(prominent: false))
            .disabled(isBlocked)
            .accessibilityLabel("Add \(model.provider.displayName) account")
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("No saved \(model.provider.displayName) accounts", systemImage: "person.crop.rectangle.stack")
                .font(.system(size: 13, weight: .medium))
            Text("Save a \(model.provider.cliName) login to see its limits and switch accounts.")
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            if let current = model.current {
                Text("Signed in as \(current.email)")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .textSelection(.enabled)
            }
            Button("Add \(model.provider.displayName) account", action: onAdd)
                .buttonStyle(ActionButtonStyle(prominent: true))
                .disabled(isBlocked)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Palette.paper, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.edge, lineWidth: 1))
    }

    private var unavailableState: some View {
        HStack(spacing: 14) {
            Text("Accounts couldn’t be loaded.")
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
            Spacer(minLength: 8)
            Button("Try again") { Task { await model.load() } }
                .buttonStyle(ActionButtonStyle(prominent: false))
                .disabled(isBlocked)
        }
        .padding(16)
        .background(Palette.paper, in: RoundedRectangle(cornerRadius: 16))
    }

    private func unsavedLogin(_ current: CurrentLogin) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 18))
                .foregroundStyle(Palette.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text("Your current login isn’t saved.").font(.system(size: 12, weight: .medium))
                Text(current.email).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Save login", action: onAdd)
                .buttonStyle(ActionButtonStyle(prominent: false))
                .disabled(isBlocked)
        }
        .padding(14)
        .background(Palette.accentWash.opacity(0.4), in: RoundedRectangle(cornerRadius: 13))
    }
}

struct AccountUsageMetric: Identifiable {
    let id: String
    let title: String
    let window: UsageWindow
    var isFeatured = false
}

/// Only reported windows become meters. Missing fields do not mean zero usage or a failed request.
func accountUsageMetrics(_ usage: UsageSnapshot?, provider: SubscriptionProvider, showsFable: Bool = false) -> [AccountUsageMetric] {
    guard let usage else { return [] }
    var metrics: [AccountUsageMetric] = []
    let featuredIndex = provider == .claude ? usage.modelScoped.firstIndex {
        $0.name.range(of: "\\bfable\\b", options: [.regularExpression, .caseInsensitive]) != nil
    } : nil
    let generalWindows = provider == .claude
        ? [("weekly", "Weekly limit", usage.sevenDay), ("five-hour", "Five-hour limit", usage.fiveHour)]
        : [("five-hour", "Five-hour limit", usage.fiveHour), ("weekly", "Weekly limit", usage.sevenDay)]
    for (id, title, window) in generalWindows {
        if let window { metrics.append(AccountUsageMetric(id: id, title: title, window: window)) }
    }
    if showsFable, let featuredIndex {
        let scoped = usage.modelScoped[featuredIndex]
        metrics.append(AccountUsageMetric(id: "model-\(featuredIndex)", title: "Weekly \(scoped.name)",
                                          window: scoped.window, isFeatured: true))
    }
    for (index, scoped) in usage.modelScoped.enumerated() where index != featuredIndex {
        if provider == .claude, !showsFable,
           scoped.name.range(of: "\\bfable\\b", options: [.regularExpression, .caseInsensitive]) != nil { continue }
        metrics.append(AccountUsageMetric(id: "model-\(index)",
                                          title: provider == .claude ? "Weekly \(scoped.name)" : scoped.name,
                                          window: scoped.window))
    }
    if provider == .claude {
        if let window = usage.sevenDaySonnet {
            metrics.append(AccountUsageMetric(id: "sonnet", title: "Weekly Sonnet", window: window))
        }
        if let window = usage.sevenDayOpus {
            metrics.append(AccountUsageMetric(id: "opus", title: "Weekly Opus", window: window))
        }
    }
    return metrics
}

struct AccountBillingDatePresentation {
    let date: Date
    let label: String
    let explanation: String
    let displayText: String?

    init(date: Date, label: String, explanation: String, displayText: String? = nil) {
        self.date = date
        self.label = label
        self.explanation = explanation
        self.displayText = displayText
    }
}

/// Manual overrides remain authoritative; reported period boundaries are not payment guarantees.
func accountBillingDate(_ account: SavedAccount, now: Date = Date()) -> AccountBillingDatePresentation? {
    if let renewal = account.renewalAt {
        return AccountBillingDatePresentation(
            date: renewal,
            label: renewal > now ? "Renews" : "Renewal",
            explanation: "Renewal date entered manually: \(renewal.formatted(date: .complete, time: .shortened)). This overrides the automatically reported date. Clear the manual override in account options to restore automatic metadata."
        )
    }
    if let billing = account.claudeBilling {
        return claudeBillingDate(billing, now: now)
    }
    guard let period = account.subscriptionPeriod else { return nil }
    let label: String
    if period.endsAt <= now {
        label = "Last period ended"
    } else {
        switch period.willRenew {
        case .some(true): label = "Renews"
        case .some(false): label = "Ends"
        case nil: label = "Period ends"
        }
    }
    let source: String
    switch period.source {
    case .codexIDToken: source = "Codex ID token"
    case .claudeBilling: source = "Claude billing"
    }
    var details = ["Subscription period ends \(period.endsAt.formatted(date: .complete, time: .shortened)).", "Source: \(source)."]
    if let startsAt = period.startsAt {
        details.append("Period began \(startsAt.formatted(date: .complete, time: .shortened)).")
    }
    if let checkedAt = period.checkedAt {
        details.append("Checked \(checkedAt.formatted(date: .complete, time: .shortened)).")
    } else {
        details.append("Check time unavailable.")
    }
    switch period.willRenew {
    case .some(true): details.append("The provider reports automatic renewal.")
    case .some(false): details.append("The provider reports no automatic renewal.")
    case nil: details.append("Automatic renewal is not confirmed.")
    }
    details.append("This is a reported subscription period boundary, not a guaranteed charge date.")
    return AccountBillingDatePresentation(date: period.endsAt, label: label, explanation: details.joined(separator: " "))
}

private struct ClaudeBillingDisplayDate {
    let date: Date
    let dateOnly: String?
}

private func claudeBillingDate(_ billing: ClaudeBillingSnapshot, now: Date) -> AccountBillingDatePresentation? {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let today = calendar.startOfDay(for: now)
    let checked = "Source: Claude billing. Checked \(billing.checkedAt.formatted(date: .complete, time: .shortened))."
    let status = billing.status.map { " Reported status: \($0)." } ?? ""

    if let coverage = billing.giftPaidThrough, let date = utcBillingDate(coverage) {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        let label = date < today ? "Gift covered through" : "Gift covers through"
        return AccountBillingDatePresentation(
            date: date,
            label: label,
            explanation: "Gift coverage includes \(coverage), a date without a time of day. \(checked)\(status) This is gift coverage, not a guaranteed charge date.",
            displayText: "\(label) \(formatter.string(from: date))"
        )
    }

    func candidate(exact: Date?, dateOnly: String?) -> ClaudeBillingDisplayDate? {
        if let exact { return ClaudeBillingDisplayDate(date: exact, dateOnly: nil) }
        guard let dateOnly, let date = utcBillingDate(dateOnly) else { return nil }
        return ClaudeBillingDisplayDate(date: date, dateOnly: dateOnly)
    }
    let nextCharge = candidate(exact: billing.nextChargeAt, dateOnly: billing.nextChargeDate)
    let planEnd = candidate(exact: billing.planEndingAt, dateOnly: billing.planEndingDate)
    func chargePrecedesPlanEnd(_ charge: ClaudeBillingDisplayDate) -> Bool {
        guard let planEnd else { return true }
        if charge.dateOnly != nil || planEnd.dateOnly != nil {
            return calendar.startOfDay(for: charge.date) < calendar.startOfDay(for: planEnd.date)
        }
        return charge.date < planEnd.date
    }
    let selected: ClaudeBillingDisplayDate
    let label: String
    if billing.status?.lowercased() != "trialing", let nextCharge,
       chargePrecedesPlanEnd(nextCharge) {
        selected = nextCharge
        label = nextCharge.dateOnly != nil ? (nextCharge.date < today ? "Reported charge" : "Next charge")
            : (nextCharge.date < now ? "Reported charge" : "Next charge")
    } else if let planEnd {
        selected = planEnd
        label = planEnd.dateOnly != nil ? (planEnd.date < today ? "Plan ended" : "Plan ends")
            : (planEnd.date < now ? "Plan ended" : "Plan ends")
    } else { return nil }

    if let day = selected.dateOnly {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return AccountBillingDatePresentation(
            date: selected.date,
            label: label,
            explanation: "\(label): \(day), reported as a date without a time of day. \(checked)\(status) Billing dates can change and do not guarantee a charge.",
            displayText: "\(label) \(formatter.string(from: selected.date))"
        )
    }
    return AccountBillingDatePresentation(
        date: selected.date,
        label: label,
        explanation: "\(label): \(selected.date.formatted(date: .complete, time: .shortened)). \(checked)\(status) Billing dates can change and do not guarantee a charge."
    )
}

private func utcBillingDate(_ raw: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.isLenient = false
    guard let date = formatter.date(from: raw), formatter.string(from: date) == raw else { return nil }
    return date
}

private struct AccountRow: View {
    let account: SavedAccount
    let provider: SubscriptionProvider
    let wideLayout: Bool
    let metricTitles: [String]
    let showsFable: Bool
    let showsManualResets: Bool
    let isActive: Bool
    let isBusy: Bool
    let isSwitching: Bool
    let usageError: String?
    let billingError: String?
    let onSwitch: () -> Void
    let onRename: () -> Void
    let onSetRenewal: () -> Void
    let onViewResets: () -> Void
    let onConnectBilling: () -> Void
    let onRemove: () -> Void
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    private var hasCustomName: Bool {
        account.label.caseInsensitiveCompare(account.email) != .orderedSame
    }

    private var metrics: [AccountUsageMetric] {
        accountUsageMetrics(account.usage, provider: provider, showsFable: showsFable)
    }

    var body: some View {
        Button(action: onSwitch) {
            VStack(alignment: .leading, spacing: 10) {
                if wideLayout {
                    HStack(alignment: .top, spacing: 24) {
                        identity.frame(width: 220, alignment: .leading)
                        usageContent
                        actionIndicator
                    }
                    .frame(minHeight: 74, alignment: .top)
                } else {
                    HStack(alignment: .center, spacing: 12) {
                        identity.frame(maxWidth: .infinity, alignment: .leading)
                        actionIndicator
                    }
                    if !metrics.isEmpty || account.usage != nil && showsManualResets {
                        usageContent.padding(.top, 5)
                    } else {
                        unavailableUsage
                    }
                }
                if let usageError {
                    Label(usageError, systemImage: "exclamationmark.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let billingError {
                    Label("Billing check failed: \(billingError)", systemImage: "exclamationmark.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(AccountRowButtonStyle())
        .background(isActive ? Palette.greenWash.opacity(0.27) : isHovered ? Palette.paper.opacity(0.55) : Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.edge).frame(height: 0.7).padding(.horizontal, 16)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1).fill(Palette.green)
                .frame(width: 2).padding(.vertical, 15).opacity(isActive ? 1 : 0)
                .allowsHitTesting(false)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 2)
                .stroke(Palette.accentText, lineWidth: 2)
                .padding(-2)
                .opacity(isFocused ? 1 : 0)
                .allowsHitTesting(false)
        }
        .focusEffectDisabled()
        .focused($isFocused)
        .disabled(isActive || isBusy)
        .accessibilityLabel(hasCustomName
                             ? "\(provider.displayName), \(account.label), \(account.email), \(provider.planLabel(account.plan))"
                             : "\(provider.displayName), \(account.email), \(provider.planLabel(account.plan))")
        .accessibilityValue("\(isActive ? "Active account. " : "")\(renewalDescription) \(usageDescription)")
        .accessibilityHint(isActive ? "Used for new \(provider.cliName) sessions" : "Switch \(provider.cliName) to this account")
        .onHover { isHovered = $0 }
        .overlay(alignment: .topTrailing) {
            options.padding(.trailing, 13).padding(.top, 15)
        }
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(account.label)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(hasCustomName ? .tail : .middle)
                .help(hasCustomName ? "\(account.label)\n\(account.email)" : account.email)
            if hasCustomName {
                Text(account.email)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(account.email)
            }
            HStack(spacing: 8) {
                PlanBadge(label: provider.planLabel(account.usage?.reportedPlan ?? account.plan))
                if let usage = account.usage {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text("\(usageError == nil ? "Checked" : "Saved") \(relativeDate(usage.fetchedAt, now: context.date))")
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(usageError == nil ? Palette.muted : Palette.danger)
                    .lineLimit(1)
                    .help("Last successful usage check: \(usage.fetchedAt.formatted(date: .complete, time: .shortened))")
                }
            }
            TimelineView(.periodic(from: .now, by: 60)) { context in
                readinessLabel(now: context.date)
            }
            TimelineView(.periodic(from: .now, by: 60)) { context in
                if let billingDate = accountBillingDate(account, now: context.date) {
                    Text(billingDate.displayText ?? "\(billingDate.label) \(compactDueDate(billingDate.date)) · \(dueInterval(billingDate.date, now: context.date))")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(billingDate.explanation)
                } else {
                    Text("Billing date unavailable")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.muted)
                        .help("No subscription-period date was reported. You can enter a manual renewal override in account options.")
                }
            }
        }
    }

    @ViewBuilder
    private var usageContent: some View {
        if !metrics.isEmpty || account.usage != nil && showsManualResets {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 22, alignment: .top), count: 3),
                      alignment: .leading, spacing: 18) {
                ForEach(metricTitles, id: \.self) { title in
                    if let metric = metrics.first(where: { $0.title == title }) {
                        UsageMeter(title: metric.title, window: metric.window)
                    } else {
                        Color.clear.frame(height: 66).accessibilityHidden(true)
                    }
                }
                if provider == .chatGPT {
                    CreditBalanceView(balances: account.usage?.creditBalances)
                }
                if showsManualResets {
                    if provider == .claude {
                        ClaudeResetSummaryView(account: account)
                    } else {
                        ManualResetSummaryView(summary: account.usage?.manualResets)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            unavailableUsage
        }
    }

    private func readinessLabel(now: Date) -> some View {
        let readiness = AccountReadiness(usage: account.usage, failed: usageError != nil, now: now)
        let text: String
        let color: Color
        switch readiness.status {
        case .ready: text = "Ready · \(Int((readiness.remaining ?? 0).rounded()))% \(readiness.limitingWindow ?? "") left"; color = Palette.ink
        case .limited: text = "Low headroom · \(Int((readiness.remaining ?? 0).rounded()))% left"; color = Palette.warning
        case .exhausted: text = "\(readiness.limitingWindow ?? "General") limit reached"; color = Palette.danger
        case .stale: text = "Refresh needed"; color = Palette.warning
        case .unknown: text = "General limits unavailable"; color = Palette.muted
        }
        return Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(color)
    }

    private var unavailableUsage: some View {
        Text(account.usage != nil ? "No quota windows reported"
             : usageError == nil ? "Usage hasn’t been checked" : "Usage unavailable")
            .font(.system(size: 12))
            .foregroundStyle(usageError == nil ? Palette.muted : Palette.danger)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actionIndicator: some View {
        HStack(spacing: 5) {
            if isSwitching {
                ProgressView().controlSize(.mini).frame(width: 12, height: 12)
                Text("Switching…")
            } else {
                Color.clear.frame(width: 1, height: 12).accessibilityHidden(true)
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Palette.ink)
        .frame(width: 90, height: 28)
        .padding(.trailing, 34)
        .help(isActive ? "Used for new \(provider.cliName) sessions" : "Switch \(provider.cliName) to this account")
    }

    private var options: some View {
        Menu {
            if provider == .claude {
                Button(account.claudeBilling == nil ? "Connect billing…" : "Refresh billing…",
                       systemImage: "creditcard", action: onConnectBilling)
            }
            if account.usage?.manualResets != nil || account.claudeResets != nil {
                Button("Manual reset details…", systemImage: "arrow.counterclockwise", action: onViewResets)
            }
            Button(account.renewalAt == nil ? "Set renewal override…" : "Edit renewal override…",
                   systemImage: "calendar", action: onSetRenewal)
            Button("Rename account…", systemImage: "pencil", action: onRename)
            Divider()
            Button("Remove saved account…", systemImage: "trash", role: .destructive, action: onRemove)
        } label: {
            optionsLabel
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .modifier(StableDisabledMenuAppearance(disabled: isBusy, label: optionsLabel))
        .help("Options for \(provider.displayName) account \(account.label): set renewal date, rename, or remove")
        .accessibilityLabel("Options for \(provider.displayName) account \(account.label)")
        .accessibilityIdentifier("account-options-\(provider.rawValue)-\(account.id.uuidString)")
    }

    private var optionsLabel: some View {
        Label("Options for \(provider.displayName) account \(account.label)", systemImage: "ellipsis")
            .labelStyle(.iconOnly)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Palette.muted)
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
    }

    private var usageDescription: String {
        let descriptions = metrics.map { metric in
            "\(metric.title) \(remainingPercentage(metric.window)) percent remaining, \(usagePercentage(metric.window)) percent used. \(metric.window.fraction >= 1 ? "Limit reached. " : "")\(resetDescription(metric.window.resetsAt))."
        }
        let emptyDescription = account.usage == nil
            ? (usageError == nil ? "Usage hasn’t been checked." : "Usage unavailable.")
            : "No quota windows reported."
        let windows = descriptions.isEmpty ? emptyDescription : descriptions.joined(separator: " ")
        let failure = usageError.map { "Usage check failed: \($0)" } ?? ""
        let resets: String
        if provider == .claude, let snapshot = account.claudeResets {
            resets = snapshot.grants.map {
                "\($0.title), \($0.resetsLeft) unused, \($0.paused ? "paused" : $0.usableNow ? "usable now" : "conditionally usable"), \($0.expiresAt.map { "expires \($0.formatted(date: .complete, time: .shortened))" } ?? "expiry not reported")."
            }.joined(separator: " ") + " Reset data checked \(snapshot.checkedAt.formatted(date: .abbreviated, time: .shortened))."
        } else if let summary = account.usage?.manualResets {
            let dates = summary.credits?.filter { $0.status == "available" }.enumerated().map { index, credit in
                "Reset \(index + 1) \(credit.expiresAt.map { "expires \($0.formatted(date: .complete, time: .shortened))" } ?? "has no expiry")."
            }.joined(separator: " ") ?? "Expiry details unavailable."
            resets = "\(summary.availableCount) manual resets available. \(dates)"
        } else { resets = showsManualResets ? "Manual resets unavailable." : "" }
        return "\(windows) \(resets) \(failure)"
    }

    private var renewalDescription: String {
        let date = accountBillingDate(account)?.explanation ?? "Billing date unavailable. No subscription-period date was reported."
        let failure = billingError.map { " Billing check failed: \($0)" } ?? ""
        return date + failure
    }
}

private struct UsageMeter: View {
    let title: String
    let window: UsageWindow

    private var color: Color {
        if window.fraction >= 1 { return Palette.danger }
        if window.fraction >= 0.9 { return Palette.warning }
        return Palette.meter
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .help(title)
                Spacer(minLength: 0)
                Text("\(remainingPercentage(window))%")
                    .font(.system(size: 21, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(window.fraction >= 1 ? Palette.danger : Palette.ink)
                    .fixedSize()
                    .help("\(remainingPercentage(window))% remaining · \(usagePercentage(window))% used\(window.fraction >= 1 ? " · Limit reached" : "")")
            }
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.faint.opacity(0.7))
                    if window.fraction < 1 {
                        Capsule().fill(color).frame(width: geometry.size.width * (1 - window.fraction))
                    }
                }
            }
            .frame(height: 4)
            .accessibilityHidden(true)
            TimelineView(.periodic(from: .now, by: 60)) { context in
                VStack(alignment: .leading, spacing: 4) {
                    Text(resetCountdown(window.resetsAt, now: context.date))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(window.resetsAt == nil ? Palette.muted : Palette.ink)
                    Text(resetDateText(window.resetsAt, now: context.date))
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.9)
                .help(window.resetsAt?.formatted(date: .complete, time: .shortened) ?? "Reset time unavailable")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CreditBalanceView: View {
    let balances: [UsageCreditBalance]?
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Usage credits").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.muted)
            if let balances, !balances.isEmpty {
                ForEach(balances) { credit in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(credit.unlimited ? "Unlimited" : formatted(credit.balance) ?? (credit.hasCredits ? "Available" : "None available"))
                            .font(.system(size: 21, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(credit.hasCredits || credit.unlimited ? Palette.ink : Palette.muted)
                            .lineLimit(1).minimumScaleFactor(0.8)
                        Text(balances.count > 1 ? credit.name : "Beyond included usage")
                            .font(.system(size: 11)).foregroundStyle(Palette.muted)
                        if credit.balance == nil && !credit.unlimited {
                            Text("Balance not reported").font(.system(size: 10)).foregroundStyle(Palette.muted)
                        }
                    }
                }
            } else {
                Text("Not reported").font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .help("Provider-reported usage credits, separate from manual resets. This interface does not report grant history or credit expiry dates.")
    }
    private func formatted(_ balance: String?) -> String? {
        guard let balance else { return nil }
        let number = NSDecimalNumber(string: balance, locale: Locale(identifier: "en_US_POSIX"))
        guard number != .notANumber, balance.filter(\.isNumber).count <= 38 else { return balance }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = balance.split(separator: ".").dropFirst().first?.count ?? 0
        return formatter.string(from: number) ?? balance
    }
}

private struct ClaudeResetSummaryView: View {
    let account: SavedAccount

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 7) {
                Text("Manual resets").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.muted)
                if let snapshot = account.claudeResets {
                    let grants = snapshot.unexpiredGrants(at: context.date)
                    if !grants.isEmpty {
                        ForEach(grants) { grant in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(grant.title) · \(grant.resetsLeft) \(snapshot.eligible && grant.isAvailable(at: context.date) ? "available" : "unused")")
                                    .font(.system(size: 13, weight: .semibold))
                                Text(grant.expiresAt.map { "Expires \(compactDueDate($0))" } ?? "Expiry not reported")
                                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
                                if grant.paused {
                                    Text("Paused").font(.system(size: 10)).foregroundStyle(Palette.muted)
                                } else if let start = grant.startsAt, start > context.date {
                                    Text("Starts \(compactDueDate(start))").font(.system(size: 10)).foregroundStyle(Palette.muted)
                                } else if !snapshot.eligible || !grant.usableNow {
                                    Text("Use conditions apply").font(.system(size: 10)).foregroundStyle(Palette.muted)
                                }
                            }
                        }
                    } else if snapshot.confirmsGrantInventory {
                        Text("None available").font(.system(size: 12)).foregroundStyle(Palette.muted)
                    } else {
                        Text("Not confirmed").font(.system(size: 12)).foregroundStyle(Palette.muted)
                        Text("Connect billing to check Claude web resets")
                            .font(.system(size: 10)).foregroundStyle(Palette.muted)
                            .help("Claude Code did not report an account-wide reset balance.\(snapshot.ineligibleReason.map { " Provider reason: \($0)." } ?? "")")
                    }
                    if account.claudeResetsReadFailed || context.date.timeIntervalSince(snapshot.checkedAt) > 600 {
                        Text("Saved reset data · Refresh needed").font(.system(size: 10)).foregroundStyle(Palette.warning)
                    }
                } else {
                    Text("Unavailable").font(.system(size: 12)).foregroundStyle(Palette.muted)
                    Text(account.claudeResetsReadFailed ? "Reset check failed" : "Refresh usage to check resets")
                        .font(.system(size: 10)).foregroundStyle(Palette.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

private struct ManualResetSummaryView: View {
    let summary: ManualResetSummary?

    private var availableCredits: [ManualResetCredit] {
        (summary?.credits?.filter { $0.status == "available" } ?? []).sorted {
            ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Manual resets")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.muted)
            if let summary {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("\(summary.availableCount)")
                        .font(.system(size: 15, weight: .semibold))
                        .monospacedDigit()
                    Text("available")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                }
                ForEach(Array(availableCredits.enumerated()), id: \.offset) { index, credit in
                    if let expiry = credit.expiresAt {
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            ViewThatFits(in: .horizontal) {
                                HStack(alignment: .firstTextBaseline, spacing: 4) {
                                    Text("Reset \(index + 1) · \(expiry > context.date ? dueInterval(expiry, now: context.date) : "expired")")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(expiry > context.date ? Palette.ink : Palette.muted)
                                    Text("· \(compactDueDate(expiry))")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Palette.muted)
                                }
                                .fixedSize(horizontal: true, vertical: false)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Reset \(index + 1) · \(expiry > context.date ? dueInterval(expiry, now: context.date) : "expired")")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(expiry > context.date ? Palette.ink : Palette.muted)
                                    Text(compactDueDate(expiry))
                                        .font(.system(size: 11))
                                        .foregroundStyle(Palette.muted)
                                }
                            }
                            .lineLimit(1)
                            .help("Reset \(index + 1) expires \(expiry.formatted(date: .complete, time: .shortened)). Status reported by provider: \(credit.status).")
                        }
                    } else {
                        Text("Reset \(index + 1) · No expiry")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.muted)
                    }
                }
                if summary.credits == nil {
                    Text("Expiry details unavailable")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.muted)
                } else if summary.availableCount > availableCredits.count {
                    Text("More expiry details unavailable")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.muted)
                }
            } else {
                Text("Unavailable")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct ResetDetailsSheet: View {
    let account: SavedAccount
    let provider: SubscriptionProvider
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Manual resets")
                .font(.system(size: 21, weight: .semibold))
            Text("\(provider.displayName) · \(account.email)")
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
            if provider == .claude, let snapshot = account.claudeResets {
                Text("Read-only · Use resets in Claude Settings → Usage.")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(snapshot.grants) { grant in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(grant.title).font(.system(size: 13, weight: .semibold))
                                let state = (grant.expiresAt.map { $0 <= Date() } ?? false) ? "Expired"
                                    : grant.resetsLeft == 0 ? "Used"
                                    : grant.paused ? "Paused"
                                    : (grant.startsAt.map { $0 > Date() } ?? false) ? "Not started"
                                    : !snapshot.eligible ? "Unavailable on this Claude surface"
                                    : grant.usableNow ? "Usable now" : "Use conditions apply"
                                Text("\(grant.resetsLeft) unused · \(state)")
                                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
                                Text(grant.expiresAt.map { "Expires \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Expiry not reported")
                                    .font(.system(size: 12, weight: .medium))
                                Divider()
                            }
                        }
                        if snapshot.grants.isEmpty {
                            Text(snapshot.confirmsGrantInventory ? "No reset grants reported."
                                 : "Claude Code did not confirm the reset balance. Connect billing to check Claude's website.")
                            if let reason = snapshot.ineligibleReason {
                                Text("Provider reason: \(reason)").font(.system(size: 11)).foregroundStyle(Palette.muted)
                            }
                        }
                    }
                }.frame(maxHeight: 360)
                Text("Checked \(snapshot.checkedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
            } else if let summary = account.usage?.manualResets {
                Text("\(summary.availableCount) available")
                    .font(.system(size: 16, weight: .semibold))
                if let credits = summary.credits {
                    if credits.isEmpty {
                        Text("The provider returned no individual reset details.")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.muted)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                ForEach(Array(credits.enumerated()), id: \.offset) { index, credit in
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack(alignment: .firstTextBaseline) {
                                            Text(credit.title ?? "Reset \(index + 1)")
                                                .font(.system(size: 13, weight: .semibold))
                                            Spacer()
                                            Text(credit.status.capitalized)
                                                .font(.system(size: 11))
                                                .foregroundStyle(Palette.muted)
                                        }
                                        if let detail = credit.detail, !detail.isEmpty {
                                            Text(detail).font(.system(size: 12)).foregroundStyle(Palette.muted)
                                        }
                                        Text("Granted \(credit.grantedAt.formatted(date: .abbreviated, time: .shortened))")
                                            .font(.system(size: 11)).foregroundStyle(Palette.muted)
                                        Text(credit.expiresAt.map { "Expires \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "No expiry")
                                            .font(.system(size: 12, weight: .medium))
                                        Divider()
                                    }
                                    .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .frame(maxHeight: 360)
                    }
                } else {
                    Text("The available count was reported without individual expiry details.")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                }
            } else {
                Text("Manual reset information is unavailable.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
            }
            if provider != .claude, let usage = account.usage {
                Text("Checked \(usage.fetchedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
        .frame(width: 490)
        .background(Palette.canvas)
        .foregroundStyle(Palette.ink)
        .onExitCommand { dismiss() }
    }
}

private func usagePercentage(_ window: UsageWindow) -> String {
    window.utilization.formatted(.number.precision(.fractionLength(0...1)))
}

private func remainingPercentage(_ window: UsageWindow) -> String {
    (100 * (1 - window.fraction)).formatted(.number.precision(.fractionLength(0...1)))
}

private struct PlanBadge: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Palette.muted)
            .fixedSize()
    }
}

private struct AddAccountSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var authorizationCode = ""
    @FocusState private var labelFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(model.loginInProgress ? "Finish signing in" : "Add a \(model.provider.displayName) account")
                        .font(.system(size: 23, weight: .semibold)).tracking(-0.5)
                    Text(model.loginInProgress ? "Your browser handles the sign-in." : "Keep a login ready for whenever you need it.")
                        .font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                Spacer()
                SwitchboardMark(size: 35)
            }

            if model.loginInProgress {
                VStack(alignment: .leading, spacing: 14) {
                    loginStep(number: "1", text: "Choose the account you want to add in your browser.")
                    loginStep(number: "2", text: model.provider == .chatGPT
                              ? "Complete the Codex sign-in with your ChatGPT account."
                              : "Complete the Claude Code sign-in.")
                    loginStep(number: "3", text: "Return here and save the new login.")
                }
                .padding(17)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.paper, in: RoundedRectangle(cornerRadius: 12))

                if model.provider == .claude {
                    DisclosureGroup("Browser gave you a code?") {
                        HStack(spacing: 8) {
                            TextField("Paste the sign-in code", text: $authorizationCode)
                                .textFieldStyle(.roundedBorder)
                                .privacySensitive()
                                .autocorrectionDisabled()
                                .accessibilityLabel("Claude sign-in code")
                            Button("Continue") {
                                Task {
                                    await model.submitLoginCode(authorizationCode)
                                    if model.error == nil { authorizationCode = "" }
                                }
                            }
                            .disabled(model.isBusy || model.isRefreshing || authorizationCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        .padding(.top, 8)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                }
            } else if let current = model.current {
                HStack(spacing: 11) {
                    Image(systemName: "terminal").font(.system(size: 21)).foregroundStyle(Palette.accent)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Current \(model.provider.cliName) login")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Palette.muted)
                        Text(current.email).font(.system(size: 13, weight: .medium)).textSelection(.enabled)
                    }
                    Spacer()
                    PlanBadge(label: model.provider.planLabel(current.plan))
                }
                .padding(16)
                .background(Palette.paper, in: RoundedRectangle(cornerRadius: 12))
            } else {
                MessageStrip(symbol: "terminal", text: model.provider == .chatGPT
                             ? "Sign in to Codex with your ChatGPT account to add your subscription."
                             : "Sign in with the official Claude Code CLI to add your first account.", isError: false)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 5) {
                    Text("Account name").font(.system(size: 12, weight: .medium))
                    Text("optional").font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                TextField("e.g. Personal or Work", text: $label)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .focused($labelFocused)
                    .disabled(model.isBusy || model.isRefreshing)
                    .accessibilityLabel("Account name")
            }

            if let error = model.error {
                MessageStrip(symbol: "exclamationmark.circle", text: error, isError: true)
            }

            if !model.loginInProgress {
                VStack(spacing: 11) {
                    if model.current != nil {
                        Button {
                            Task {
                                await model.saveCurrent(label: label)
                                if model.error == nil { dismiss() }
                            }
                        } label: {
                            Label("Save current login", systemImage: "square.and.arrow.down")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(ActionButtonStyle(prominent: true))
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.isBusy || model.isRefreshing)
                    }
                    Button {
                        Task { await model.beginLogin() }
                    } label: {
                        HStack {
                            Text(model.current == nil ? "Sign in to \(model.provider.cliName)" : "Sign in another account")
                            Spacer()
                            Image(systemName: "arrow.up.right")
                        }
                    }
                    .buttonStyle(ActionButtonStyle(prominent: model.current == nil))
                    .disabled(model.isBusy || model.isRefreshing)
                    Text("Opens the official \(model.provider.cliName) sign-in in your browser.")
                        .font(.system(size: 10)).foregroundStyle(Palette.muted)
                }
            }

            HStack {
                Label("Saved securely in your Mac’s Keychain", systemImage: "lock.shield")
                    .font(.system(size: 10)).foregroundStyle(Palette.muted)
                Spacer()
                Button("Cancel") {
                    Task {
                        if model.loginInProgress { await model.cancelLogin() }
                        if !model.loginInProgress { dismiss() }
                    }
                }
                .keyboardShortcut(.cancelAction)
                .disabled(model.isBusy)
                if model.loginInProgress {
                    Button {
                        Task {
                            await model.finishLogin(label: label)
                            if !model.loginInProgress && model.error == nil { dismiss() }
                        }
                    } label: {
                        Text(model.isBusy ? "Saving…" : "Save new login")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.ink)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isBusy || model.isRefreshing)
                }
            }
        }
        .padding(28)
        .frame(width: 485)
        .background(Palette.canvas)
        .foregroundStyle(Palette.ink)
        .interactiveDismissDisabled(model.loginInProgress || model.isBusy)
        .onAppear { labelFocused = true }
    }

    private func loginStep(number: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(number).font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Palette.accent)
                .frame(width: 19, height: 19)
                .background(Palette.accentWash, in: Circle())
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct RenewalDateSheet: View {
    @ObservedObject var model: AppModel
    let account: SavedAccount
    @Environment(\.dismiss) private var dismiss
    @State private var renewalDate = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Renewal date override")
                .font(.system(size: 21, weight: .semibold))
            Text(account.email)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
            Text("Enter a manual renewal date from your billing settings. This local override takes priority over automatic metadata. Clearing it restores the automatically reported date when available.")
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            DatePicker("Manual renewal date", selection: $renewalDate, displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.compact)
                .controlSize(.large)
                .accessibilityLabel("Manual subscription renewal date and time")
                .disabled(model.isBusy || model.isRefreshing)
            if let error = model.error {
                MessageStrip(symbol: "exclamationmark.circle", text: error, isError: true)
            }
            HStack {
                if account.renewalAt != nil {
                    Button("Clear override", role: .destructive) { save(nil) }
                        .disabled(model.isBusy || model.isRefreshing)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isBusy)
                Button("Save date") { save(renewalDate) }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.ink)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isBusy || model.isRefreshing)
            }
        }
        .padding(26)
        .frame(width: 450)
        .background(Palette.canvas)
        .foregroundStyle(Palette.ink)
        .onAppear { renewalDate = account.renewalAt ?? account.subscriptionPeriod?.endsAt ?? Date() }
        .interactiveDismissDisabled(model.isBusy)
    }

    private func save(_ date: Date?) {
        Task {
            await model.setRenewal(account: account, date: date)
            if model.error == nil { dismiss() }
        }
    }
}

private struct RenameAccountSheet: View {
    @ObservedObject var model: AppModel
    let account: SavedAccount
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Rename account").font(.system(size: 21, weight: .semibold))
            Text(account.email).font(.system(size: 12)).foregroundStyle(Palette.muted)
            TextField("Account name", text: $label)
                .textFieldStyle(.roundedBorder).controlSize(.large).focused($focused)
            if let error = model.error {
                MessageStrip(symbol: "exclamationmark.circle", text: error, isError: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save name") {
                    Task {
                        await model.rename(account, label: label)
                        if model.error == nil { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent).tint(Palette.ink).keyboardShortcut(.defaultAction)
                .disabled(model.isBusy || model.isRefreshing || label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(26).frame(width: 390)
        .background(Palette.canvas)
        .onAppear { label = account.label; focused = true }
        .interactiveDismissDisabled(model.isBusy)
    }
}

struct MenuContentView: View {
    @ObservedObject var model: DashboardModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ProviderMenuGroup(model: model.claude, isBlocked: model.isBlocked)
        Divider()
        ProviderMenuGroup(model: model.chatGPT, isBlocked: model.isBlocked)
        Divider()
        Button("Open Switchboard") {
            openWindow(id: "dashboard")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("o", modifiers: .command)
        Button("Refresh all usage") { Task { await model.refresh() } }
            .disabled(model.isBlocked)
        Divider()
        Button("Quit Switchboard") { NSApp.terminate(nil) }.keyboardShortcut("q", modifiers: .command)
    }
}

private struct ProviderMenuGroup: View {
    @ObservedObject var model: AppModel
    let isBlocked: Bool

    var body: some View {
        Text("\(model.provider.displayName) · \(model.provider.cliName)")
        if model.accounts.isEmpty {
            Text(model.isLoading ? "Loading accounts…" : model.loadError == nil ? "No saved accounts" : "Accounts unavailable — open Switchboard")
        } else if model.loadError != nil {
            Text("Active account unknown — open Switchboard")
        }
        ForEach(model.accounts) { account in
            Button {
                Task { await model.switchAccount(account) }
            } label: {
                if model.activeID == account.id {
                    Label(account.label, systemImage: "checkmark")
                } else {
                    Text(account.label)
                }
            }
            .disabled(isBlocked || model.activeID == account.id)
        }
    }
}

private struct SwitchboardMark: View {
    var size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.29)
                .fill(Palette.ink)
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: size * 0.40, weight: .medium))
                .foregroundStyle(Palette.canvas)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct MessageStrip: View {
    let symbol: String
    let text: String
    let isError: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 12)).padding(.top, 1)
            Text(text).font(.system(size: 11)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(isError ? Palette.danger : Palette.muted)
        .padding(12)
        .background(isError ? Palette.errorWash : Palette.faint.opacity(0.28), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

private struct NeutralCheckboxStyle: ToggleStyle {
    @FocusState private var isFocused: Bool

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(configuration.isOn ? Palette.ink : Palette.paper)
                    .overlay(RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(configuration.isOn ? Palette.ink : Palette.muted, lineWidth: 1))
                    .overlay {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Palette.canvas)
                            .opacity(configuration.isOn ? 1 : 0)
                    }
                    .frame(width: 14, height: 14)
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .stroke(Palette.ink, lineWidth: 2).padding(-3)
                        .opacity(isFocused ? 1 : 0))
                    .accessibilityHidden(true)
                configuration.label.foregroundStyle(Palette.ink)
            }
            .frame(minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .focusEffectDisabled()
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.checkbox)
        }
    }
}

struct ActionButtonStyle: ButtonStyle {
    var prominent: Bool
    var staticFeedback = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.preservesDisabledControlAppearance) private var preservesDisabledControlAppearance
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var keyboardEvent: Bool {
        NSApp.currentEvent?.type == .keyDown || NSApp.currentEvent?.type == .keyUp
    }

    func makeBody(configuration: Configuration) -> some View {
        let moving = !staticFeedback && !reduceMotion && !keyboardEvent
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 13)
            .frame(minHeight: 34)
            .foregroundStyle(prominent ? Palette.canvas : Palette.ink)
            .background(prominent ? Palette.ink : Palette.paper, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(prominent ? Color.clear : Palette.edge, lineWidth: 1))
            .shadow(color: .black.opacity(prominent ? 0 : 0.04), radius: 1, x: 0, y: 1)
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(Palette.accentText, lineWidth: 2).padding(-3).opacity(isFocused ? 1 : 0))
            .opacity(isEnabled || preservesDisabledControlAppearance ? (configuration.isPressed ? 0.82 : 1) : 0.45)
            .scaleEffect(moving && configuration.isPressed ? 0.96 : 1)
            .animation(moving ? .timingCurve(0.2, 0, 0, 1, duration: 0.15) : nil, value: configuration.isPressed)
            .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct AccountRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        // Account switching is frequent. Keep the surface still and the usage legible.
        configuration.label.background(Palette.ink.opacity(configuration.isPressed ? 0.035 : 0))
    }
}

private func relativeDate(_ date: Date, now: Date = Date()) -> String {
    let age = max(0, now.timeIntervalSince(date))
    if age < 60 { return "just now" }
    if age < 3600 { return "\(Int(age / 60))m ago" }
    if age < 86400 { return "\(Int(age / 3600))h ago" }
    return "\(Int(age / 86400))d ago"
}

private func resetDescription(_ date: Date?) -> String {
    guard let date else { return "Reset time unavailable" }
    return "Resets \(date.formatted(date: .complete, time: .shortened))"
}

private func compactDueDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("MMMdjm")
    return formatter.string(from: date)
}

private func dueInterval(_ date: Date, now: Date = Date()) -> String {
    let seconds = date.timeIntervalSince(now)
    let minutes = max(1, Int(ceil(abs(seconds) / 60)))
    let days = minutes / 1440
    let hours = (minutes % 1440) / 60
    let value: String
    if days > 0 { value = "\(days)d \(hours)h" }
    else if hours > 0 { value = "\(hours)h \(minutes % 60)m" }
    else { value = "\(minutes)m" }
    return seconds >= 0 ? "in \(value)" : "\(value) ago"
}

private func resetCountdown(_ date: Date?, now: Date = Date()) -> String {
    guard let date else { return "Reset time unknown" }
    let remaining = date.timeIntervalSince(now)
    if remaining <= 0 { return "Reset time passed" }
    let minutes = max(1, Int(ceil(remaining / 60)))
    let days = minutes / 1440
    let hours = (minutes % 1440) / 60
    if days > 0 { return "Resets in \(days)d \(hours)h" }
    return hours > 0 ? "Resets in \(hours)h \(minutes % 60)m" : "Resets in \(minutes)m"
}

private func resetDateText(_ date: Date?, now: Date = Date()) -> String {
    guard let date else { return "Refresh to check" }
    let time = date.formatted(date: .omitted, time: .shortened)
    if Calendar.current.isDate(date, inSameDayAs: now) { return "Today at \(time)" }
    if let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now),
       Calendar.current.isDate(date, inSameDayAs: tomorrow) { return "Tomorrow at \(time)" }
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("EEE d MMM jm")
    return formatter.string(from: date)
}
