import Foundation
import Darwin

/// Reads the selected ChatGPT subscription through Codex's account-only app-server API.
/// The CLI owns OAuth refresh. The caller must collect its auth file even if this read fails.
public struct CodexUsageClient: Sendable {
    public let executable: URL
    private let timeout: TimeInterval

    public init(executable: URL) {
        self.executable = executable
        self.timeout = 30
    }

    init(executable: URL, timeout: TimeInterval) {
        self.executable = executable
        self.timeout = timeout
    }

    public func fetch(installation: CodexInstallation) async throws -> UsageSnapshot {
        let operation = CodexUsageProcess(executable: executable, installation: installation, timeout: timeout)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(with: Result { try operation.run() })
                }
            }
        } onCancel: {
            operation.cancel()
        }
    }

    static func parseUsageResponse(_ data: Data, fetchedAt: Date = Date()) throws -> UsageSnapshot {
        let reply: CodexUsageReply
        do { reply = try JSONDecoder().decode(CodexUsageReply.self, from: data) }
        catch { throw unsupportedResponse() }
        if let error = reply.error { throw error.displayError(stage: "account/rateLimits/read") }
        guard let result = reply.result else { throw unsupportedResponse() }

        // Both views are part of the app-server contract. A named map entry takes
        // precedence over the same bucket in the single-snapshot projection.
        var buckets = result.rateLimitsByLimitId ?? [:]
        if let single = result.rateLimits {
            let id = nonempty(single.limitId) ?? "codex"
            if buckets[id] == nil { buckets[id] = single }
        }
        var snapshot = UsageSnapshot(fetchedAt: fetchedAt, manualResets: try result.rateLimitResetCredits?.summary())
        let keys = buckets.keys.sorted { lhs, rhs in
            if lhs == "codex" { return rhs != "codex" }
            if rhs == "codex" { return false }
            return lhs < rhs
        }
        for key in keys {
            guard let bucket = buckets[key] else { continue }
            let name = nonempty(bucket.limitName) ?? nonempty(bucket.normalModelSlug)
                ?? (key == "codex" ? "Codex" : key)
            if key == "codex" { snapshot.reportedPlan = nonempty(bucket.planType) }
            if let credits = bucket.credits {
                if let balance = credits.balance {
                    guard balance.count <= 100,
                          balance.range(of: #"^[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil else {
                        throw SwitchboardError.message("Codex returned an invalid credit balance. Refresh again.")
                    }
                }
                if snapshot.creditBalances == nil { snapshot.creditBalances = [] }
                snapshot.creditBalances?.append(UsageCreditBalance(id: key, name: name,
                    hasCredits: credits.hasCredits, unlimited: credits.unlimited, balance: credits.balance))
            }
            for (position, value) in [("Primary", bucket.primary), ("Secondary", bucket.secondary)] {
                guard let value else { continue }
                let window = try value.window()
                if key == "codex", value.windowDurationMins == 300, snapshot.fiveHour == nil {
                    snapshot.fiveHour = window
                } else if key == "codex", value.windowDurationMins == 10_080, snapshot.sevenDay == nil {
                    snapshot.sevenDay = window
                } else {
                    let label = "\(name) · \(try value.durationLabel(position: position))"
                    // Distinct bucket IDs can share a display label and current values.
                    snapshot.modelScoped.append(NamedUsageWindow(name: label, window: window))
                }
            }
        }
        guard snapshot.fiveHour != nil || snapshot.sevenDay != nil || !snapshot.modelScoped.isEmpty || snapshot.manualResets != nil || snapshot.creditBalances != nil else {
            throw SwitchboardError.message("Codex recognized this subscription but did not return usage windows. Refresh again.")
        }
        return snapshot
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private static func unsupportedResponse() -> SwitchboardError {
        .message("Codex returned an unsupported usage format. Update Codex, then refresh again.")
    }
}

private struct CodexUsageReply: Decodable {
    var result: Payload?
    var error: CodexUsageFailure?
    struct Payload: Decodable {
        var rateLimits: Bucket?
        var rateLimitsByLimitId: [String: Bucket]?
        var rateLimitResetCredits: ResetCredits?
    }
    struct ResetCredits: Decodable {
        var availableCount: Int
        var credits: [ResetCredit]?
        func summary() throws -> ManualResetSummary {
            guard availableCount >= 0 else {
                throw SwitchboardError.message("Codex returned an invalid manual reset count. Refresh again.")
            }
            return ManualResetSummary(availableCount: availableCount, credits: try credits?.map { try $0.credit() })
        }
    }
    struct ResetCredit: Decodable {
        var id: String
        var resetType: String
        var status: String
        var grantedAt: Int64
        var expiresAt: Int64?
        var title: String?
        var description: String?
        func credit() throws -> ManualResetCredit {
            guard !id.isEmpty, grantedAt >= 0, expiresAt.map({ $0 >= 0 }) ?? true else {
                throw SwitchboardError.message("Codex returned invalid manual reset details. Refresh again.")
            }
            return ManualResetCredit(id: id, resetType: resetType, status: status,
                grantedAt: Date(timeIntervalSince1970: Double(grantedAt)),
                expiresAt: expiresAt.map { Date(timeIntervalSince1970: Double($0)) },
                title: title, detail: description)
        }
    }
    struct Bucket: Decodable {
        var limitId: String?
        var limitName: String?
        var normalModelSlug: String?
        var primary: Window?
        var secondary: Window?
        var planType: String?
        var credits: Credits?
    }
    struct Credits: Decodable {
        var hasCredits: Bool
        var unlimited: Bool
        var balance: String?
    }
    struct Window: Decodable {
        var usedPercent: Double
        var windowDurationMins: Int64?
        var resetsAt: Double?

        func window() throws -> UsageWindow {
            guard usedPercent.isFinite, usedPercent >= 0,
                  windowDurationMins.map({ $0 > 0 }) ?? true,
                  resetsAt.map({ $0.isFinite && $0 >= 0 }) ?? true else {
                throw SwitchboardError.message("Codex returned invalid usage values. Refresh again.")
            }
            return UsageWindow(utilization: usedPercent, resetsAt: resetsAt.map(Date.init(timeIntervalSince1970:)))
        }

        func durationLabel(position: String) throws -> String {
            guard let minutes = windowDurationMins else { return "\(position.lowercased()) limit · duration unavailable" }
            guard minutes > 0 else { throw SwitchboardError.message("Codex returned an invalid quota duration. Refresh again.") }
            if minutes == 10_080 { return "weekly limit" }
            if minutes.isMultiple(of: 1_440) { return "\(minutes / 1_440)-day limit" }
            if minutes.isMultiple(of: 60) { return "\(minutes / 60)-hour limit" }
            return "\(minutes)-minute limit"
        }
    }
}

private final class CodexUsageProcess: @unchecked Sendable {
    private let executable: URL
    private let installation: CodexInstallation
    private let timeout: TimeInterval
    private let cancellationLock = NSLock()
    private var cancelled = false
    private let initializeID = "switchboard-initialize"
    private let accountID = "switchboard-account"
    private let usageID = "switchboard-usage"
    private let refreshID = "switchboard-refresh"
    private let retryUsageID = "switchboard-usage-retry"
    private let maximumOutputBytes = 2 * 1024 * 1024
    private let maximumLineBytes = 1024 * 1024

    init(executable: URL, installation: CodexInstallation, timeout: TimeInterval) {
        self.executable = executable
        self.installation = installation
        self.timeout = timeout
    }

    func cancel() {
        cancellationLock.lock()
        cancelled = true
        cancellationLock.unlock()
    }

    private func checkCancellation() throws {
        cancellationLock.lock()
        let isCancelled = cancelled
        cancellationLock.unlock()
        if isCancelled { throw CancellationError() }
    }

    func run() throws -> UsageSnapshot {
        try checkCancellation()
        let manager = FileManager.default
        let scratch = manager.temporaryDirectory.appendingPathComponent("switchboard-codex-usage-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: scratch) }

        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = scratch
        process.environment = environment()
        // Process-only overrides retain the canonical auth file and its refreshes without
        // inheriting provider endpoints, plugin warmups, hooks, or analytics from config.toml.
        process.arguments = [
            "-c", "cli_auth_credentials_store=\"file\"",
            "-c", "model_provider=\"openai\"",
            "-c", "chatgpt_base_url=\"https://chatgpt.com/backend-api\"",
            "-c", "features.plugins=false", "-c", "features.apps=false", "-c", "features.hooks=false",
            "-c", "analytics.enabled=false", "-c", "feedback.enabled=false",
            "app-server", "--listen", "stdio://"
        ]
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        defer {
            // EOF permits a normal app-server shutdown. Bound every subsequent wait and
            // reap the child even when a protocol read fails or its task is cancelled.
            try? input.fileHandleForWriting.close()
            if process.isRunning { waitBriefly(process) }
            if process.isRunning {
                process.terminate()
                waitBriefly(process)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            if process.processIdentifier > 0 { process.waitUntilExit() }
            for handle in [input.fileHandleForReading, output.fileHandleForReading,
                           output.fileHandleForWriting, errors.fileHandleForReading, errors.fileHandleForWriting] {
                try? handle.close()
            }
        }
        do { try process.run() }
        catch { throw SwitchboardError.message("Cannot start Codex. Select a working Codex installation.") }
        try output.fileHandleForWriting.close()
        try errors.fileHandleForWriting.close()
        try input.fileHandleForReading.close()
        let outputFD = output.fileHandleForReading.fileDescriptor
        let errorFD = errors.fileHandleForReading.fileDescriptor
        for fd in [outputFD, errorFD] {
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                throw SwitchboardError.message("Cannot read Codex's usage response.")
            }
        }
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) >= 0 else {
            throw SwitchboardError.message("Cannot open Codex's account channel.")
        }
        try send(method: "initialize", id: initializeID,
                 params: ["clientInfo": ["name": "switchboard", "title": "Switchboard", "version": "0.5.2"]],
                 to: input.fileHandleForWriting)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var bytesSeen = 0
        var lineBuffer = Data()
        var expectedID = initializeID
        var openOutput = true, openErrors = true
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)

        while true {
            try checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw SwitchboardError.message("Codex did not return usage in time. Refresh again.")
            }
            var descriptors = [
                pollfd(fd: openOutput ? outputFD : -1, events: Int16(POLLIN | POLLHUP), revents: 0),
                pollfd(fd: openErrors ? errorFD : -1, events: Int16(POLLIN | POLLHUP), revents: 0)
            ]
            let polled = poll(&descriptors, nfds_t(descriptors.count), 100)
            if polled < 0, errno != EINTR {
                throw SwitchboardError.message("The Codex usage connection failed. Refresh again.")
            }
            for index in descriptors.indices where descriptors[index].revents != 0 {
                let count = Darwin.read(descriptors[index].fd, &buffer, buffer.count)
                if count < 0 {
                    if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue }
                    throw SwitchboardError.message("The Codex usage connection closed unexpectedly.")
                }
                if count == 0 {
                    if index == 0 { openOutput = false } else { openErrors = false }
                    continue
                }
                bytesSeen += count
                guard bytesSeen <= maximumOutputBytes else { throw oversizedResponse() }
                // Raw stderr and RPC errors may contain credentials or account details.
                if index == 1 { continue }
                lineBuffer.append(contentsOf: buffer.prefix(count))
                while let newline = lineBuffer.firstIndex(of: 10) {
                    let line = Data(lineBuffer[..<newline])
                    lineBuffer.removeSubrange(...newline)
                    guard line.count <= maximumLineBytes else { throw oversizedResponse() }
                    guard let frame = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          frame["id"] as? String == expectedID else { continue }
                    if let errorObject = frame["error"], !(errorObject is NSNull) {
                        let failure = try JSONDecoder().decode(CodexUsageFailure.self, from: jsonData(errorObject))
                        // Either account discovery or usage can reject the access token.
                        // Ask the CLI to refresh once across both stages, retaining its
                        // rotated auth file even if the subsequent read fails.
                        if [accountID, usageID].contains(expectedID), failure.httpStatus == 401 {
                            expectedID = refreshID
                            try send(method: "account/read", id: refreshID, params: ["refreshToken": true],
                                     to: input.fileHandleForWriting)
                            continue
                        }
                        if failure.httpStatus == 401 { throw CodexAuthenticationError.unauthorized }
                        if failure.isAuthenticationFailure { throw CodexAuthenticationError.rejected }
                        let stage = expectedID == initializeID ? "initialize"
                            : ([accountID, refreshID].contains(expectedID) ? "account/read" : "account/rateLimits/read")
                        throw failure.displayError(stage: stage)
                    }
                    guard let result = frame["result"] as? [String: Any] else {
                        throw SwitchboardError.message("Codex returned an unsupported account response. Update Codex, then refresh again.")
                    }
                    if expectedID == initializeID {
                        try send(method: "initialized", to: input.fileHandleForWriting)
                        expectedID = accountID
                        try send(method: "account/read", id: accountID, params: ["refreshToken": false],
                                 to: input.fileHandleForWriting)
                    } else if expectedID == accountID || expectedID == refreshID {
                        guard let account = result["account"] as? [String: Any], account["type"] as? String == "chatgpt" else {
                            throw CodexAuthenticationError.noWorkingCopy
                        }
                        expectedID = expectedID == refreshID ? retryUsageID : usageID
                        try send(method: "account/rateLimits/read", id: expectedID, params: ["excludeResetCreditDetails": false],
                                 to: input.fileHandleForWriting)
                    } else {
                        return try CodexUsageClient.parseUsageResponse(line)
                    }
                }
                guard lineBuffer.count <= maximumLineBytes else { throw oversizedResponse() }
            }
            if !openOutput || (!process.isRunning && polled == 0) {
                throw SwitchboardError.message("Codex closed before returning usage. Update Codex or check the saved login, then refresh again.")
            }
        }
    }

    private func environment() -> [String: String] {
        let allowed = ["PATH", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "__CF_USER_TEXT_ENCODING",
                       "SSL_CERT_FILE", "SSL_CERT_DIR", "NODE_EXTRA_CA_CERTS"]
        var env = ProcessInfo.processInfo.environment.filter { allowed.contains($0.key) }
        env["PATH"] = env["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["HOME"] = installation.configurationEnvironment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        env["CODEX_HOME"] = installation.home.path
        // Suppress a persisted Remote Control preference for this child only.
        env["CODEX_INTERNAL_APP_SERVER_REMOTE_CONTROL_DISABLED"] = "1"
        return env
    }

    private func send(method: String, id: String? = nil, params: [String: Any]? = nil, to handle: FileHandle) throws {
        var frame: [String: Any] = ["method": method]
        if let id { frame["id"] = id }
        if let params { frame["params"] = params }
        var data = try JSONSerialization.data(withJSONObject: frame)
        data.append(10)
        do { try handle.write(contentsOf: data) }
        catch { throw SwitchboardError.message("Codex closed its account channel. Refresh again.") }
    }

    private func waitBriefly(_ process: Process) {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.5
        while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline { usleep(10_000) }
    }

    private func oversizedResponse() -> SwitchboardError {
        .message("Codex returned too much output. Update Codex, then refresh again.")
    }
}
