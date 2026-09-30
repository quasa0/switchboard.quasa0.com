import AppKit
import SwiftUI
import WebKit
import SwitchboardCore

/// A separate first-party web session for each saved account. Cookies stay inside WebKit.
@MainActor final class ClaudeBillingSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published private(set) var isChecking = false
    @Published private(set) var status = "Sign in to Claude with this account, then choose Read details."
    @Published private(set) var popupWebView: WKWebView?
    let account: SavedAccount
    let webView: WKWebView?
    private var loadCompletion: CheckedContinuation<Void, Error>?
    private var loadTimeout: Task<Void, Never>?
    private var stopped = false

    static func isConnected(_ id: UUID) -> Bool {
        UserDefaults.standard.bool(forKey: "claudeBillingConnected.\(id.uuidString)")
    }
    static func setConnected(_ connected: Bool, for id: UUID) {
        UserDefaults.standard.set(connected, forKey: "claudeBillingConnected.\(id.uuidString)")
    }

    static func forget(_ id: UUID) async throws {
        setConnected(false, for: id)
        try await WKWebsiteDataStore.remove(forIdentifier: id)
    }

    init(account: SavedAccount, enabled: Bool = true, ephemeral: Bool = false) {
        self.account = account
        if enabled {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = ephemeral ? .nonPersistent() : WKWebsiteDataStore(forIdentifier: account.id)
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
            webView = WKWebView(frame: .zero, configuration: configuration)
        } else { webView = nil }
        super.init()
        webView?.navigationDelegate = self
        webView?.uiDelegate = self
    }

    func open() {
        guard !stopped, let webView, webView.url == nil else { return }
        webView.load(URLRequest(url: URL(string: "https://claude.ai/settings/billing")!))
    }

    func retry() {
        guard !stopped, !isChecking else { return }
        closePopup()
        status = "Sign in to Claude with this account, then choose Read details."
        webView?.load(URLRequest(url: URL(string: "https://claude.ai/settings/billing")!))
    }

    func connectDesktop() async throws -> ClaudeBillingSnapshot {
        guard !stopped, !isChecking, let webView else { throw CancellationError() }
        isChecking = true
        defer { isChecking = false }
        status = "Checking Claude Desktop sign-in…"
        let probe = ClaudeBillingSession(account: account, ephemeral: true)
        defer { probe.stop() }
        do {
            // Read only after the explicit button action. Verify in a temporary store first.
            let source = try await Task.detached { try ClaudeDesktopSession().read() }.value
            try Task.checkCancellation()
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: "sessionKey", .value: source.value, .domain: source.domain,
                .path: "/", .secure: "TRUE", HTTPCookiePropertyKey("HttpOnly"): "TRUE"]
            if let expiry = source.expiresAt { properties[.expires] = expiry }
            guard let cookie = HTTPCookie(properties: properties), let probeView = probe.webView else {
                throw SwitchboardError.message("Claude Desktop sign-in could not be connected.")
            }
            await probeView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
            let billing = try await probe.refresh()
            try Task.checkCancellation()
            guard !stopped else { throw CancellationError() }
            let verified = await probeView.configuration.websiteDataStore.httpCookieStore.allCookies()
                .filter { $0.name == "sessionKey" && ["claude.ai", ".claude.ai"].contains($0.domain) && $0.isSecure }
            guard !verified.isEmpty else { throw SwitchboardError.message("Claude Desktop sign-in expired. Sign in again.") }
            let store = webView.configuration.websiteDataStore.httpCookieStore
            for existing in await store.allCookies() where existing.name == "sessionKey" {
                await store.deleteCookie(existing)
            }
            for cookie in verified { await store.setCookie(cookie) }
            status = "Claude Desktop sign-in connected."
            return billing
        } catch {
            let safe = error as? SwitchboardError ?? SwitchboardError.message("Claude Desktop sign-in could not be read. Sign in inside Switchboard or try again.")
            status = safe.localizedDescription
            if Task.isCancelled || stopped { throw CancellationError() }
            throw safe
        }
    }

    /// Existing connected sessions refresh without presenting another login or touching CLI credentials.
    func refresh() async throws -> ClaudeBillingSnapshot {
        guard !stopped, webView != nil else { throw CancellationError() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                loadCompletion = continuation
                loadTimeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
                    self?.finishLoad(.failure(SwitchboardError.message("Claude billing did not load. Connect billing again from account options.")))
                }
                open()
            }
            try Task.checkCancellation()
            return try await read()
        } onCancel: {
            Task { @MainActor [weak self] in self?.stop() }
        }
    }

    func read() async throws -> ClaudeBillingSnapshot {
        guard !stopped, !isChecking, let webView,
              webView.url?.scheme == "https", webView.url?.host == "claude.ai" else {
            throw SwitchboardError.message("Finish signing in to Claude, then choose Read details.")
        }
        isChecking = true
        defer { isChecking = false }
        status = "Checking the account, billing dates, and limit resets…"
        do {
            // Fixed first-party GETs. No browser cookies or access tokens cross the WebKit bridge.
            let result = try await webView.callAsyncJavaScript(Self.billingScript,
                arguments: ["expectedAccount": account.accountUUID, "expectedOrganization": account.organizationUUID],
                in: nil, contentWorld: .defaultClient)
            guard !stopped, !Task.isCancelled else { throw CancellationError() }
            guard let raw = result as? String, raw.utf8.count <= 32_768,
                  let data = raw.data(using: .utf8),
                  let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SwitchboardError.message("Claude returned an unreadable billing response.")
            }
            if let failure = envelope["error"] as? String {
                switch failure {
                case "wrongAccount": throw SwitchboardError.message("This browser is signed in to another Claude account. Sign in as \(account.email).")
                case "signedOut": throw SwitchboardError.message("Sign in to Claude as \(account.email), then choose Read details.")
                default: throw SwitchboardError.message("Claude billing is unavailable. Your saved billing dates were kept.")
                }
            }
            let snapshot = try ClaudeBillingSnapshot.parseBridge(data,
                expectedAccountUUID: account.accountUUID, expectedOrganizationUUID: account.organizationUUID)
            status = snapshot.resetReadFailed == true ? "Billing connected. Reset details could not be read." : "Billing dates and limit resets connected."
            return snapshot
        } catch {
            // WebKit errors can contain page details; publish only our fixed, account-scoped errors.
            let safe = error as? SwitchboardError ?? SwitchboardError.message("Couldn’t read Claude billing. Finish signing in, then try again.")
            status = safe.localizedDescription
            if Task.isCancelled || stopped { throw CancellationError() }
            throw safe
        }
    }

    func stop() {
        stopped = true
        closePopup()
        webView?.stopLoading()
        finishLoad(.failure(CancellationError()))
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
    }

    private func finishLoad(_ result: Result<Void, Error>) {
        loadTimeout?.cancel(); loadTimeout = nil
        let continuation = loadCompletion; loadCompletion = nil
        continuation?.resume(with: result)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        finishLoad(.success(()))
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadFailed(webView, error: error)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadFailed(webView, error: error)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard !stopped, popupWebView == nil,
              navigationAction.request.url == nil || navigationAction.request.url?.scheme == "https" ||
              navigationAction.request.url?.absoluteString == "about:blank" else { return nil }
        // Returning the configured child preserves window.opener and Google's completion flow.
        let popup = WKWebView(frame: .zero, configuration: configuration)
        popup.navigationDelegate = self
        popup.uiDelegate = self
        popupWebView = popup
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        if webView === popupWebView { closePopup() }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loadFailed(webView, error: nil)
    }
    private func loadFailed(_ view: WKWebView, error: Error?) {
        if (error as NSError?)?.code == NSURLErrorCancelled { return }
        status = "The sign-in page could not load. Choose Retry sign-in, or use Claude Desktop. Saved dates were kept."
        if view === webView { finishLoad(.failure(SwitchboardError.message(status))) }
    }
    func closePopup() {
        popupWebView?.stopLoading()
        popupWebView?.navigationDelegate = nil
        popupWebView?.uiDelegate = nil
        popupWebView = nil
    }

    private static let billingScript = #"""
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 10000);
    const get = async path => {
      const r = await fetch(path, {credentials: 'include', signal: controller.signal,
        cache: 'no-store', redirect: 'error', headers: {'Accept':'application/json'}});
      if (!r.ok) throw new Error(r.status === 401 || r.status === 403 ? 'signedOut' : 'unavailable');
      return await r.json();
    };
    try {
      const bootstrap = await get('/api/bootstrap?statsig_hashing_algorithm=djb2&growthbook_format=sdk&include_system_prompts=false');
      const account = bootstrap.account;
      const memberships = account?.memberships;
      if (!account?.uuid) return JSON.stringify({error:'signedOut'});
      if (account.uuid !== expectedAccount || !Array.isArray(memberships) ||
          !memberships.some(m => m.organization?.uuid === expectedOrganization))
        return JSON.stringify({error:'wrongAccount'});
      const details = await get('/api/organizations/' + encodeURIComponent(expectedOrganization) + '/subscription_details');
      const fields = ['next_charge_at','next_charge_date','plan_ending_at','plan_ending_before',
        'status','payment_paused_until','gift_details'];
      const selected = Object.fromEntries(fields.filter(k => k in details).map(k => [k,details[k]]));
      if (selected.gift_details) selected.gift_details = {paid_through: selected.gift_details.paid_through};
      let resetDetails = null;
      try {
        const usage = await get('/api/organizations/' + encodeURIComponent(expectedOrganization) + '/usage?cedar_ember=1&skip_spend=1');
        const resets = usage?.cedar_ember;
        if (resets && typeof resets.eligible === 'boolean' && Array.isArray(resets.grants)) {
          const fields = ['id','resets_left','clears','starts_at','ends_at','paused','usable_now'];
          resetDetails = {eligible:resets.eligible, grants:resets.grants.map(grant =>
            Object.fromEntries(fields.filter(k => k in grant).map(k => [k,grant[k]])))};
        }
      } catch { /* Keep billing independent of missing or failed reset data. */ }
      return JSON.stringify({accountUUID:account.uuid,organizationUUID:expectedOrganization,details:selected,resetDetails});
    } catch(e) { return JSON.stringify({error:e.message === 'signedOut' ? 'signedOut':'unavailable'}); }
    finally { clearTimeout(timeout); }
    """#
}

private struct ClaudeBillingWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct ClaudeBillingSheet: View {
    let account: SavedAccount
    @ObservedObject var model: AppModel
    @StateObject private var session: ClaudeBillingSession
    @Environment(\.dismiss) private var dismiss
    @State private var readTask: Task<Void, Never>?
    @State private var saving = false

    init(account: SavedAccount, model: AppModel) {
        self.account = account; self.model = model
        _session = StateObject(wrappedValue: ClaudeBillingSession(account: account, enabled: !model.isDemo))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect Claude billing").font(.system(size: 20, weight: .semibold))
            Text(account.email).font(.system(size: 13, weight: .medium))
            Text("Reset details use your saved Claude Code login automatically. Billing dates need a web sign-in. Sign in here or connect Claude Desktop. The session stays on this Mac. Resets are never applied here.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if let webView = session.webView {
                ClaudeBillingWebView(webView: webView)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Text("Billing sign-in is disabled in preview mode.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: 14) {
                Button("Retry sign-in") { session.retry() }.disabled(saving || session.isChecking || model.isDemo)
                if !model.isDemo, ClaudeDesktopSession.isInstalled {
                    Button("Use Claude Desktop sign-in") {
                        readTask = Task {
                            saving = true
                            defer { saving = false }
                            do {
                                let billing = try await session.connectDesktop()
                                try Task.checkCancellation()
                                if await model.saveClaudeBilling(account: account, billing: billing) { dismiss() }
                            } catch { /* The session exposes a sanitized, actionable message. */ }
                        }
                    }.disabled(saving || session.isChecking)
                }
                Spacer()
            }
            HStack(spacing: 14) {
                Text(session.status).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
                Spacer(minLength: 8)
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Read details") {
                    readTask = Task {
                        saving = true
                        defer { saving = false }
                        do {
                            let billing = try await session.read()
                            try Task.checkCancellation()
                            if await model.saveClaudeBilling(account: account, billing: billing) { dismiss() }
                        } catch { /* The session exposes a sanitized, actionable message. */ }
                    }
                }
                .buttonStyle(ActionButtonStyle(prominent: true, staticFeedback: true)).keyboardShortcut(.defaultAction)
                .disabled(saving || session.isChecking || model.isDemo)
            }
        }
        .padding(20).frame(width: 840, height: 640)
        .onAppear { session.open() }
        .onDisappear { readTask?.cancel(); session.stop() }
        .sheet(isPresented: Binding(get: { session.popupWebView != nil }, set: { if !$0 { session.closePopup() } })) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Sign in to Claude").font(.headline)
                    Spacer()
                    Button("Close") { session.closePopup() }.keyboardShortcut(.cancelAction)
                }
                if let popup = session.popupWebView { ClaudeBillingWebView(webView: popup) }
                Text(session.status).font(.system(size: 12)).foregroundStyle(.secondary)
            }.padding(16).frame(width: 720, height: 600)
        }
    }
}
