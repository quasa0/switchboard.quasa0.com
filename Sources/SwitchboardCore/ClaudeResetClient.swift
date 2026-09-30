import Foundation

/// Read-only grant metadata through the saved Claude Code OAuth login. The CLI owns token refresh.
public struct ClaudeResetClient {
    public init() {}

    public func fetch(credential: OAuthCredential) async throws -> ClaudeResetSnapshot {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: RejectRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let request = try Self.request(credential: credential)
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        return try Self.parse(data, response: response)
    }

    public static func request(credential: OAuthCredential) throws -> URLRequest {
        guard credential.scopes.contains("user:profile"), !credential.accessToken.isEmpty,
              !credential.accessToken.contains(where: { $0.isNewline }) else {
            throw SwitchboardError.message("Claude reset details need a subscription login with profile access.")
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1")!,
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    public static func parse(_ data: Data, response: URLResponse, checkedAt: Date = Date()) throws -> ClaudeResetSnapshot {
        let failure = SwitchboardError.message("Claude reset details could not be read. Saved grants were kept.")
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url?.scheme == "https", response.url?.host == "api.anthropic.com",
              data.count <= 524_288,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let grants = object["cedar_ember"] as? [String: Any] else { throw failure }
        return try ClaudeResetSnapshot.parse(grants, checkedAt: checkedAt)
    }
}

private final class RejectRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

extension SavedAccount {
    /// Both transports report the same grants. Use the most recently observed source.
    public var claudeResets: ClaudeResetSnapshot? {
        [usage?.claudeResetSnapshot, claudeBilling?.resetSnapshot].compactMap { $0 }.max { $0.checkedAt < $1.checkedAt }
    }
    public var claudeResetsReadFailed: Bool {
        if let oauth = usage?.claudeResetSnapshot,
           oauth.checkedAt >= (claudeBilling?.resetSnapshot?.checkedAt ?? .distantPast) {
            return usage?.claudeResetReadFailed == true
        }
        if claudeBilling?.resetSnapshot != nil { return claudeBilling?.resetReadFailed == true }
        return claudeBilling?.resetReadFailed == true || usage?.claudeResetReadFailed == true
    }
}
